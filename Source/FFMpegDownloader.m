#import "FFMpegDownloader.h"

// iTunes-style JPEG data type (value of kCMMetadataBaseDataType_JPEG),
// written as a literal so CoreMedia doesn't have to be linked
static NSString *const YTMUJPEGDataType = @"com.apple.metadata.datatype.JPEG";

@implementation FFMpegDownloader {
    Statistics *statistics;
}

- (void)statisticsCallback:(Statistics *)newStatistics {
    dispatch_async(dispatch_get_main_queue(), ^{
        self->statistics = newStatistics;
        [self updateProgressDialog];
    });
}

- (void)downloadAudio:(NSString *)audioURL {
    [self downloadAudio:audioURL metadata:nil coverData:nil];
}

- (void)downloadAudio:(NSString *)audioURL metadata:(NSDictionary<NSString *, NSString *> *)metadata coverData:(NSData *)coverData {
    statistics = nil;
    [MobileFFmpegConfig resetStatistics];
    [self setActive];

    self.hud = [MBProgressHUD showHUDAddedTo:[UIApplication sharedApplication].keyWindow animated:YES];
    self.hud.mode = MBProgressHUDModeAnnularDeterminate;
    self.hud.label.text = LOC(@"DOWNLOADING");

    NSFileManager *fm = [NSFileManager defaultManager];
    NSURL *documentsURL = [[fm URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask] lastObject];
    NSURL *folderURL = [documentsURL URLByAppendingPathComponent:@"YTMusicUltimate"];
    NSURL *rawURL = [documentsURL URLByAppendingPathComponent:[NSString stringWithFormat:@"%@.m4a", self.tempName]];
    NSURL *taggedURL = [documentsURL URLByAppendingPathComponent:[NSString stringWithFormat:@"%@_tagged.m4a", self.tempName]];
    NSURL *outputURL = [folderURL URLByAppendingPathComponent:[NSString stringWithFormat:@"%@.m4a", self.mediaName]];
    NSURL *coverURL = [folderURL URLByAppendingPathComponent:[NSString stringWithFormat:@"%@.png", self.mediaName]];

    [fm createDirectoryAtURL:folderURL withIntermediateDirectories:YES attributes:nil error:nil];
    [fm removeItemAtURL:rawURL error:nil];
    [fm removeItemAtURL:taggedURL error:nil];

    // Argument array instead of one string, so titles with spaces/quotes are safe
    NSMutableArray<NSString *> *arguments = [@[@"-y", @"-i", audioURL, @"-map", @"0:a:0", @"-c", @"copy"] mutableCopy];
    for (NSString *key in @[@"title", @"artist", @"album", @"album_artist", @"track", @"date", @"comment"]) {
        NSString *value = metadata[key];
        if ([value isKindOfClass:[NSString class]] && value.length > 0) {
            [arguments addObject:@"-metadata"];
            [arguments addObject:[NSString stringWithFormat:@"%@=%@", key, value]];
        }
    }
    [arguments addObject:rawURL.path];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        int returnCode = [MobileFFmpeg executeWithArguments:arguments];

        dispatch_async(dispatch_get_main_queue(), ^{
            if (returnCode == RETURN_CODE_SUCCESS) {
                if (self.hud.mode == MBProgressHUDModeAnnularDeterminate) {
                    self.hud.progress = 1.0f;
                    self.hud.detailsLabel.text = @"100%";
                }

                [self addCover:coverData metadata:metadata inputURL:rawURL fallbackURL:taggedURL completion:^(NSURL *finishedURL) {

                    [fm removeItemAtURL:outputURL error:nil]; // re-download overwrites
                    BOOL isMoved = [fm moveItemAtURL:finishedURL toURL:outputURL error:nil];
                    [fm removeItemAtURL:rawURL error:nil];
                    [fm removeItemAtURL:taggedURL error:nil];

                    // Separate cover next to the file, used by the Downloads tab
                    if (isMoved && coverData.length > 0)
                        [coverData writeToURL:coverURL atomically:YES];

                    if (isMoved) {
                        [[NSNotificationCenter defaultCenter] postNotificationName:@"ReloadDataNotification" object:nil];
                        [self showResultWithText:LOC(@"DONE") icon:@"checkmark" delay:3.0];
                    } else {
                        [self showResultWithText:LOC(@"OOPS") icon:@"xmark" delay:3.0];
                    }
                }];
            } else if (returnCode == RETURN_CODE_CANCEL) {
                [self.hud hideAnimated:YES];
                [fm removeItemAtURL:rawURL error:nil];
            } else {
                [self showResultWithText:LOC(@"OOPS") icon:@"xmark" delay:3.0];
                [UIPasteboard generalPasteboard].string = [NSString stringWithFormat:@"Command execution failed with rc=%d and output=%@.\n", returnCode, [MobileFFmpegConfig getLastCommandOutput]];
                [fm removeItemAtURL:rawURL error:nil];
            }
        });
    });
}

// Adds the cover: first by writing it straight into the file's tag box,
// if that isn't possible by rewriting the file with AVFoundation.
// Calls back with the file that should be kept.
- (void)addCover:(NSData *)coverData
        metadata:(NSDictionary<NSString *, NSString *> *)metadata
        inputURL:(NSURL *)inputURL
     fallbackURL:(NSURL *)fallbackURL
      completion:(void (^)(NSURL *finishedURL))completion {
    UIImage *image = coverData.length > 0 ? [UIImage imageWithData:coverData] : nil;
    NSData *jpegData = image ? UIImageJPEGRepresentation(image, 0.92) : nil;
    if (!jpegData) {
        completion(inputURL);
        return;
    }

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        BOOL embedded = [self writeCoverAtom:jpegData intoFile:inputURL];

        dispatch_async(dispatch_get_main_queue(), ^{
            if (embedded) {
                completion(inputURL);
                return;
            }

            [self embedCover:coverData metadata:metadata inputURL:inputURL outputURL:fallbackURL completion:^(BOOL success) {
                completion(success ? fallbackURL : inputURL);
            }];
        });
    });
}

#pragma mark - Direct cover writing (MP4 boxes)

static uint32_t YTMUReadUInt32(const uint8_t *bytes) {
    return ((uint32_t)bytes[0] << 24) | ((uint32_t)bytes[1] << 16) | ((uint32_t)bytes[2] << 8) | (uint32_t)bytes[3];
}

static void YTMUWriteUInt32(uint8_t *bytes, uint32_t value) {
    bytes[0] = (value >> 24) & 0xFF;
    bytes[1] = (value >> 16) & 0xFF;
    bytes[2] = (value >> 8) & 0xFF;
    bytes[3] = value & 0xFF;
}

// Finds a child box of `type` between start and end. Returns its offset or NSNotFound.
static NSUInteger YTMUFindBox(const uint8_t *bytes, NSUInteger start, NSUInteger end, const char *type, uint32_t *outSize) {
    NSUInteger offset = start;
    while (offset + 8 <= end) {
        uint32_t size = YTMUReadUInt32(bytes + offset);
        if (size < 8 || offset + size > end)
            return NSNotFound; // 64-bit or broken sizes: don't touch the file
        if (memcmp(bytes + offset + 4, type, 4) == 0) {
            if (outSize)
                *outSize = size;
            return offset;
        }
        offset += size;
    }
    return NSNotFound;
}

// Inserts a "covr" entry into moov/udta/meta/ilst. Only done when moov is the
// last box in the file (ffmpeg's default), because then no audio data offsets
// change. Returns NO without modifying anything if the layout isn't as expected.
- (BOOL)writeCoverAtom:(NSData *)jpegData intoFile:(NSURL *)fileURL {
    NSMutableData *file = [NSMutableData dataWithContentsOfURL:fileURL];
    if (file.length < 16 || jpegData.length == 0)
        return NO;

    const uint8_t *bytes = file.bytes;
    NSUInteger length = file.length;

    uint32_t moovSize = 0, udtaSize = 0, metaSize = 0, ilstSize = 0;
    NSUInteger moov = YTMUFindBox(bytes, 0, length, "moov", &moovSize);
    if (moov == NSNotFound || moov + moovSize != length)
        return NO;

    NSUInteger udta = YTMUFindBox(bytes, moov + 8, moov + moovSize, "udta", &udtaSize);
    if (udta == NSNotFound)
        return NO;

    NSUInteger meta = YTMUFindBox(bytes, udta + 8, udta + udtaSize, "meta", &metaSize);
    if (meta == NSNotFound)
        return NO;

    // meta is a "full box": 4 extra bytes (version + flags) before its children
    NSUInteger ilst = YTMUFindBox(bytes, meta + 12, meta + metaSize, "ilst", &ilstSize);
    if (ilst == NSNotFound)
        return NO;

    if (YTMUFindBox(bytes, ilst + 8, ilst + ilstSize, "covr", NULL) != NSNotFound)
        return YES; // already has a cover

    // covr box = [size]["covr"] + data box = [size]["data"][type 13 = JPEG][locale 0][image]
    uint32_t dataBoxSize = (uint32_t)(16 + jpegData.length);
    uint32_t covrBoxSize = 8 + dataBoxSize;

    NSMutableData *covr = [NSMutableData dataWithLength:24];
    uint8_t *c = covr.mutableBytes;
    YTMUWriteUInt32(c, covrBoxSize);
    memcpy(c + 4, "covr", 4);
    YTMUWriteUInt32(c + 8, dataBoxSize);
    memcpy(c + 12, "data", 4);
    YTMUWriteUInt32(c + 16, 13);
    YTMUWriteUInt32(c + 20, 0);
    [covr appendData:jpegData];

    // Grow every parent box by the inserted size
    uint64_t newMoovSize = (uint64_t)moovSize + covrBoxSize;
    if (newMoovSize > UINT32_MAX)
        return NO;

    uint8_t *m = file.mutableBytes;
    YTMUWriteUInt32(m + ilst, ilstSize + covrBoxSize);
    YTMUWriteUInt32(m + meta, metaSize + covrBoxSize);
    YTMUWriteUInt32(m + udta, udtaSize + covrBoxSize);
    YTMUWriteUInt32(m + moov, (uint32_t)newMoovSize);

    [file replaceBytesInRange:NSMakeRange(ilst + ilstSize, 0) withBytes:covr.bytes length:covr.length];

    return [file writeToURL:fileURL atomically:YES];
}

// Backup: rewrites the file with Apple's own writer (no re-encoding) to embed the cover.
// Keeps the tags ffmpeg wrote and fills in any that AVFoundation couldn't read.
- (void)embedCover:(NSData *)coverData
          metadata:(NSDictionary<NSString *, NSString *> *)metadata
          inputURL:(NSURL *)inputURL
         outputURL:(NSURL *)outputURL
        completion:(void (^)(BOOL success))completion {
    UIImage *image = coverData.length > 0 ? [UIImage imageWithData:coverData] : nil;
    NSData *jpegData = image ? UIImageJPEGRepresentation(image, 0.92) : nil;
    if (!jpegData) {
        completion(NO);
        return;
    }

    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:inputURL options:nil];
    AVAssetExportSession *session = [AVAssetExportSession exportSessionWithAsset:asset presetName:AVAssetExportPresetPassthrough];
    if (!session || ![session.supportedFileTypes containsObject:AVFileTypeAppleM4A]) {
        completion(NO);
        return;
    }

    NSMutableArray<AVMetadataItem *> *items = [NSMutableArray array];
    NSMutableSet<NSString *> *existing = [NSMutableSet set];
    for (AVMetadataItem *item in asset.metadata) {
        if ([item.identifier isEqualToString:AVMetadataIdentifieriTunesMetadataCoverArt])
            continue;
        [items addObject:item];
        if (item.identifier)
            [existing addObject:item.identifier];
    }

    NSDictionary<NSString *, NSString *> *fallbackKeys = @{
        @"title": AVMetadataIdentifieriTunesMetadataSongName,
        @"artist": AVMetadataIdentifieriTunesMetadataArtist,
        @"album": AVMetadataIdentifieriTunesMetadataAlbum,
        @"album_artist": AVMetadataIdentifieriTunesMetadataAlbumArtist
    };
    for (NSString *key in fallbackKeys) {
        NSString *identifier = fallbackKeys[key];
        NSString *value = metadata[key];
        if ([existing containsObject:identifier] || ![value isKindOfClass:[NSString class]] || value.length == 0)
            continue;
        AVMutableMetadataItem *item = [AVMutableMetadataItem metadataItem];
        item.identifier = identifier;
        item.value = value;
        [items addObject:item];
    }

    AVMutableMetadataItem *artwork = [AVMutableMetadataItem metadataItem];
    artwork.identifier = AVMetadataIdentifieriTunesMetadataCoverArt;
    artwork.dataType = YTMUJPEGDataType;
    artwork.value = jpegData;
    [items addObject:artwork];

    session.outputURL = outputURL;
    session.outputFileType = AVFileTypeAppleM4A;
    session.metadata = items;

    [session exportAsynchronouslyWithCompletionHandler:^{
        BOOL success = session.status == AVAssetExportSessionStatusCompleted;
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(success);
        });
    }];
}

- (void)showResultWithText:(NSString *)text icon:(NSString *)iconName delay:(NSTimeInterval)delay {
    if (!self.hud)
        self.hud = [MBProgressHUD showHUDAddedTo:[UIApplication sharedApplication].keyWindow animated:YES];

    self.hud.mode = MBProgressHUDModeCustomView;
    self.hud.label.text = text;
    self.hud.label.numberOfLines = 0;
    self.hud.detailsLabel.text = nil;
    [self.hud.button setTitle:nil forState:UIControlStateNormal];
    [[self.hud.button.superview viewWithTag:998] removeFromSuperview];

    UIImageView *iconView = [[UIImageView alloc] initWithImage:[self imageWithSystemIconNamed:iconName]];
    iconView.contentMode = UIViewContentModeScaleAspectFit;
    self.hud.customView = iconView;

    [self.hud hideAnimated:YES afterDelay:delay];
}

- (void)logCallback:(long)executionId :(int)level :(NSString*)message {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSLog(@"%@", message);
    });
}

- (void)setActive {
    [MobileFFmpegConfig setLogDelegate:self];
    [MobileFFmpegConfig setStatisticsDelegate:self];
}

- (void)updateProgressDialog {
    if (statistics == nil || self.duration <= 0)
        return;

    int timeInMilliseconds = [statistics getTime];
    if (timeInMilliseconds <= 0)
        return;

    double percentage = MIN(1.0, (timeInMilliseconds / 1000.0) / (double)self.duration);

    if (self.hud && self.hud.mode == MBProgressHUDModeAnnularDeterminate) {
        self.hud.progress = percentage;
        self.hud.detailsLabel.text = [NSString stringWithFormat:@"%d%%", (int)(percentage * 100)];
        [self.hud.button setTitle:LOC(@"CANCEL") forState:UIControlStateNormal];
        [self.hud.button removeTarget:self action:@selector(cancelDownloading:) forControlEvents:UIControlEventTouchUpInside];
        [self.hud.button addTarget:self action:@selector(cancelDownloading:) forControlEvents:UIControlEventTouchUpInside];

        UIView *buttonSuperview = self.hud.button.superview;
        if (![buttonSuperview viewWithTag:998]) {
            UIButton *cancelButton = [UIButton buttonWithType:UIButtonTypeSystem];
            [cancelButton setTag:998];
            UIImage *cancelImage = [[UIImage systemImageNamed:@"x.circle"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
            [cancelButton setImage:cancelImage forState:UIControlStateNormal];
            [cancelButton setTintColor:[[UIColor labelColor] colorWithAlphaComponent:0.7]];
            [cancelButton addTarget:self action:@selector(cancelHUD:) forControlEvents:UIControlEventTouchUpInside];
            [buttonSuperview addSubview:cancelButton];

            cancelButton.translatesAutoresizingMaskIntoConstraints = NO;
            [NSLayoutConstraint activateConstraints:@[
                [cancelButton.topAnchor constraintEqualToAnchor:buttonSuperview.topAnchor constant:5.0],
                [cancelButton.leadingAnchor constraintEqualToAnchor:buttonSuperview.leadingAnchor constant:5.0],
                [cancelButton.widthAnchor constraintEqualToConstant:17.0],
                [cancelButton.heightAnchor constraintEqualToConstant:17.0]
            ]];
        }
    }
}

- (void)cancelDownloading:(UIButton *)sender {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [MobileFFmpeg cancel];
    });
}

- (void)cancelHUD:(UIButton *)sender {
    [self.hud hideAnimated:YES];
}

- (void)downloadImage:(NSURL *)link {
    self.hud = [MBProgressHUD showHUDAddedTo:[UIApplication sharedApplication].keyWindow animated:YES];
    self.hud.mode = MBProgressHUDModeIndeterminate;

    // Fetch off the main thread, save + show result on it
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSData *imageData = link ? [NSData dataWithContentsOfURL:link] : nil;
        UIImage *image = imageData ? [UIImage imageWithData:imageData] : nil;

        dispatch_async(dispatch_get_main_queue(), ^{
            if (image) {
                UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil);
                [self showResultWithText:LOC(@"SAVED_TO_PHOTOS") icon:@"checkmark" delay:2.0];
            } else {
                [self showResultWithText:LOC(@"OOPS") icon:@"xmark" delay:2.0];
            }
        });
    });
}

- (UIImage *)imageWithSystemIconNamed:(NSString *)iconName {
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(36, 36)];
    UIImage *image = [renderer imageWithActions:^(UIGraphicsImageRendererContext * _Nonnull rendererContext) {
        UIImage *iconImage = [UIImage systemImageNamed:iconName];
        UIView *imageView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 36, 36)];
        UIImageView *iconImageView = [[UIImageView alloc] initWithImage:iconImage];
        iconImageView.contentMode = UIViewContentModeScaleAspectFit;
        iconImageView.clipsToBounds = YES;
        iconImageView.tintColor = [[UIColor labelColor] colorWithAlphaComponent:0.7f];
        iconImageView.frame = imageView.bounds;

        [imageView addSubview:iconImageView];
        [imageView.layer renderInContext:rendererContext.CGContext];
    }];
    return image;
}

- (void)shareMedia:(NSURL *)mediaURL {
    UIActivityViewController *activityViewController = [[UIActivityViewController alloc] initWithActivityItems:@[mediaURL] applicationActivities:nil];
    activityViewController.excludedActivityTypes = @[UIActivityTypeAssignToContact, UIActivityTypePrint];

    [activityViewController setCompletionWithItemsHandler:^(NSString *activityType, BOOL completed, NSArray *returnedItems, NSError *activityError) {
        [[NSFileManager defaultManager] removeItemAtURL:mediaURL error:nil];
    }];

    UIViewController *rootViewController = [UIApplication sharedApplication].keyWindow.rootViewController;
    [rootViewController presentViewController:activityViewController animated:YES completion:nil];
}

@end
