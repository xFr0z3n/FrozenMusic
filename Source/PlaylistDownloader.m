#import "PlaylistDownloader.h"
#import "FFMpegDownloader.h"
#import <sys/utsname.h>

#pragma mark - Track model

@interface YTMUPlaylistTrack : NSObject
@property (nonatomic) NSInteger position;
@property (nonatomic, copy) NSString *videoID;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *artist;
@property (nonatomic, copy) NSString *thumbnailURL;
@end

@implementation YTMUPlaylistTrack
@end

#pragma mark - Small helpers

static NSURLSession *YTMUSession(void) {
    static NSURLSession *session = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        config.timeoutIntervalForRequest = 30;
        session = [NSURLSession sessionWithConfiguration:config];
    });
    return session;
}

// Synchronous request (only ever called from the background work queue)
static NSData *YTMUSendRequestFull(NSURLRequest *request, NSInteger *statusOut, NSDictionary **headersOut) {
    __block NSData *result = nil;
    __block NSInteger status = 0;
    __block NSDictionary *headers = nil;
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);

    NSURLSessionDataTask *task = [YTMUSession() dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (!error)
            result = data;
        if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
            status = ((NSHTTPURLResponse *)response).statusCode;
            headers = ((NSHTTPURLResponse *)response).allHeaderFields;
        }
        dispatch_semaphore_signal(semaphore);
    }];
    [task resume];
    if (dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(180 * NSEC_PER_SEC))) != 0)
        [task cancel];

    if (statusOut)
        *statusOut = status;
    if (headersOut)
        *headersOut = headers;
    return result;
}

static NSData *YTMUSendRequest(NSURLRequest *request, NSInteger *statusOut) {
    return YTMUSendRequestFull(request, statusOut, NULL);
}

// Downloads a googlevideo audio file in 10 MB pieces (avoids YouTube's throttling)
static BOOL YTMUDownloadInChunks(NSString *urlString, NSString *userAgent, NSString *path, BOOL (^isCancelled)(void)) {
    NSURL *url = urlString.length ? [NSURL URLWithString:urlString] : nil;
    if (!url)
        return NO;

    [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil];
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!handle)
        return NO;

    const long long chunkSize = 10 * 1024 * 1024;
    long long offset = 0;
    long long total = -1;
    BOOL success = NO;

    for (int round = 0; round < 200; round++) {
        if (isCancelled && isCancelled())
            break;

        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
        [request setValue:[NSString stringWithFormat:@"bytes=%lld-%lld", offset, offset + chunkSize - 1] forHTTPHeaderField:@"Range"];
        if (userAgent.length)
            [request setValue:userAgent forHTTPHeaderField:@"User-Agent"];

        NSInteger status = 0;
        NSDictionary *headers = nil;
        NSData *data = YTMUSendRequestFull(request, &status, &headers);
        if (data.length == 0 || (status != 200 && status != 206))
            break;

        [handle writeData:data];
        offset += (long long)data.length;

        if (status == 200) { // server sent the whole file at once
            success = YES;
            break;
        }

        // "Content-Range: bytes 0-10485759/3456789"
        NSString *contentRange = nil;
        for (NSString *key in headers) {
            if ([key caseInsensitiveCompare:@"Content-Range"] == NSOrderedSame)
                contentRange = headers[key];
        }
        NSRange slash = [contentRange rangeOfString:@"/" options:NSBackwardsSearch];
        if (slash.location != NSNotFound)
            total = [[contentRange substringFromIndex:slash.location + 1] longLongValue];

        if (total > 0 && offset >= total) {
            success = YES;
            break;
        }
        if (total <= 0 && (long long)data.length < chunkSize) {
            success = YES; // unknown size, short piece = last piece
            break;
        }
    }

    [handle closeFile];
    if (!success)
        [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    return success;
}

static NSData *YTMUGet(NSString *urlString) {
    NSURL *url = urlString.length ? [NSURL URLWithString:urlString] : nil;
    if (!url)
        return nil;
    NSInteger status = 0;
    NSData *data = YTMUSendRequest([NSURLRequest requestWithURL:url], &status);
    return (status >= 200 && status < 300) ? data : nil;
}

static NSDictionary *YTMUPostJSON(NSString *urlString, NSDictionary *body, NSDictionary<NSString *, NSString *> *headers) {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlString]];
    request.HTTPMethod = @"POST";
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    for (NSString *key in headers)
        [request setValue:headers[key] forHTTPHeaderField:key];
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];

    NSInteger status = 0;
    NSData *data = YTMUSendRequest(request, &status);
    if (!data)
        return nil;
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [json isKindOfClass:[NSDictionary class]] ? json : nil;
}

// Follows a path of dictionary keys / array indexes, returns nil if anything is missing
static id YTMUPath(id node, NSArray *path) {
    for (id step in path) {
        if ([step isKindOfClass:[NSString class]] && [node isKindOfClass:[NSDictionary class]])
            node = ((NSDictionary *)node)[step];
        else if ([step isKindOfClass:[NSNumber class]] && [node isKindOfClass:[NSArray class]]) {
            NSArray *array = node;
            NSInteger index = [step integerValue];
            if (index < 0)
                index += (NSInteger)array.count;
            node = (index >= 0 && index < (NSInteger)array.count) ? array[(NSUInteger)index] : nil;
        } else
            return nil;
        if (!node)
            return nil;
    }
    return node;
}

// First value stored under `key` anywhere inside `node` (depth-first)
static id YTMUFindFirst(id node, NSString *key) {
    if ([node isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = node;
        if (dict[key])
            return dict[key];
        for (id value in dict.allValues) {
            id found = YTMUFindFirst(value, key);
            if (found)
                return found;
        }
    } else if ([node isKindOfClass:[NSArray class]]) {
        for (id value in (NSArray *)node) {
            id found = YTMUFindFirst(value, key);
            if (found)
                return found;
        }
    }
    return nil;
}

// All values stored under `key`, arrays walked in order
static void YTMUCollectAll(id node, NSString *key, NSMutableArray *output) {
    if ([node isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = node;
        if (dict[key]) {
            [output addObject:dict[key]];
            return;
        }
        for (id value in dict.allValues)
            YTMUCollectAll(value, key, output);
    } else if ([node isKindOfClass:[NSArray class]]) {
        for (id value in (NSArray *)node)
            YTMUCollectAll(value, key, output);
    }
}

static NSString *YTMUText(id textNode) {
    if (![textNode isKindOfClass:[NSDictionary class]])
        return nil;
    NSString *simple = textNode[@"simpleText"];
    if ([simple isKindOfClass:[NSString class]])
        return simple;
    NSArray *runs = textNode[@"runs"];
    if (![runs isKindOfClass:[NSArray class]])
        return nil;
    NSMutableString *text = [NSMutableString string];
    for (NSDictionary *run in runs) {
        NSString *part = [run isKindOfClass:[NSDictionary class]] ? run[@"text"] : nil;
        if ([part isKindOfClass:[NSString class]])
            [text appendString:part];
    }
    return text.length ? text : nil;
}

static NSString *YTMUCleanName(NSString *name) {
    NSCharacterSet *bad = [NSCharacterSet characterSetWithCharactersInString:@"/\\:?*\"<>|"];
    NSString *clean = [[name componentsSeparatedByCharactersInSet:bad] componentsJoinedByString:@""];
    clean = [clean stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (clean.length > 120)
        clean = [clean substringToIndex:120];
    return clean.length ? clean : @"Unknown";
}

static NSString *YTMUBigThumbnail(NSString *url) {
    if (!url)
        return nil;
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"w\\d+-h\\d+" options:0 error:nil];
    return [regex stringByReplacingMatchesInString:url options:0 range:NSMakeRange(0, url.length) withTemplate:@"w1200-h1200"];
}

static NSString *YTMUAudioURLFromManifest(NSData *manifestData) {
    NSString *manifest = manifestData ? [[NSString alloc] initWithData:manifestData encoding:NSUTF8StringEncoding] : nil;
    NSArray *lines = [manifest componentsSeparatedByString:@"\n"];
    for (NSString *groupID in @[@"234", @"233"]) {
        NSString *search = [NSString stringWithFormat:@"TYPE=AUDIO,GROUP-ID=\"%@\"", groupID];
        for (NSString *line in lines) {
            if (![line containsString:search])
                continue;
            NSRange start = [line rangeOfString:@"https://"];
            NSRange end = [line rangeOfString:@"index.m3u8"];
            if (start.location != NSNotFound && end.location != NSNotFound && NSMaxRange(end) > start.location)
                return [line substringWithRange:NSMakeRange(start.location, NSMaxRange(end) - start.location)];
        }
    }
    return nil;
}

#pragma mark - Track number patch (m4a "trkn" tag, same size, in place)

static uint32_t YTMUBE32(const uint8_t *bytes) {
    return ((uint32_t)bytes[0] << 24) | ((uint32_t)bytes[1] << 16) | ((uint32_t)bytes[2] << 8) | (uint32_t)bytes[3];
}

static NSUInteger YTMUBox(const uint8_t *bytes, NSUInteger start, NSUInteger end, const char *type, uint32_t *sizeOut) {
    NSUInteger offset = start;
    while (offset + 8 <= end) {
        uint32_t size = YTMUBE32(bytes + offset);
        if (size < 8 || offset + size > end)
            return NSNotFound;
        if (memcmp(bytes + offset + 4, type, 4) == 0) {
            if (sizeOut)
                *sizeOut = size;
            return offset;
        }
        offset += size;
    }
    return NSNotFound;
}

static BOOL YTMUPatchTrackNumber(NSURL *fileURL, NSInteger position) {
    NSMutableData *file = [NSMutableData dataWithContentsOfURL:fileURL];
    if (file.length < 16 || position < 1 || position > 65535)
        return NO;
    const uint8_t *bytes = file.bytes;
    uint32_t moovSize = 0, udtaSize = 0, metaSize = 0, ilstSize = 0, trknSize = 0;

    NSUInteger moov = YTMUBox(bytes, 0, file.length, "moov", &moovSize);
    if (moov == NSNotFound) return NO;
    NSUInteger udta = YTMUBox(bytes, moov + 8, moov + moovSize, "udta", &udtaSize);
    if (udta == NSNotFound) return NO;
    NSUInteger meta = YTMUBox(bytes, udta + 8, udta + udtaSize, "meta", &metaSize);
    if (meta == NSNotFound) return NO;
    NSUInteger ilst = YTMUBox(bytes, meta + 12, meta + metaSize, "ilst", &ilstSize);
    if (ilst == NSNotFound) return NO;
    NSUInteger trkn = YTMUBox(bytes, ilst + 8, ilst + ilstSize, "trkn", &trknSize);
    // trkn > data box: [size]["data"][type][locale][0 0][track hi][track lo]...
    if (trkn == NSNotFound || trknSize < 8 + 16 + 4 || memcmp(bytes + trkn + 12, "data", 4) != 0)
        return NO;

    uint8_t *m = file.mutableBytes;
    NSUInteger payload = trkn + 8 + 16;
    m[payload + 2] = (uint8_t)((position >> 8) & 0xFF);
    m[payload + 3] = (uint8_t)(position & 0xFF);
    return [file writeToURL:fileURL atomically:YES];
}

#pragma mark - Downloader

@interface YTMUPlaylistDownloader ()
@property (nonatomic, readwrite) BOOL running;
@property (atomic) BOOL cancelled;
@property (nonatomic, strong) MBProgressHUD *hud;
@property (nonatomic, strong) dispatch_queue_t workQueue;
@property (nonatomic) UIBackgroundTaskIdentifier backgroundTask;
@property (nonatomic, copy) NSString *deviceModel;
@property (nonatomic, copy) NSString *systemVersion;
@property (nonatomic, copy) NSString *appVersion;
// Filled while loading: album pages get real album tags, playlists use the playlist name
@property (nonatomic) BOOL isAlbum;
@property (nonatomic, copy) NSString *albumArtist;
@property (nonatomic, copy) NSString *albumYear;
@property (nonatomic, copy) NSString *albumCoverURL;
@end

@implementation YTMUPlaylistDownloader

+ (instancetype)sharedDownloader {
    static YTMUPlaylistDownloader *shared = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        shared = [YTMUPlaylistDownloader new];
        shared.workQueue = dispatch_queue_create("ytmu.playlist.download", DISPATCH_QUEUE_SERIAL);
        shared.backgroundTask = UIBackgroundTaskInvalid;
    });
    return shared;
}

#pragma mark UI helpers (main thread)

- (UIViewController *)topViewController {
    UIViewController *vc = [UIApplication sharedApplication].keyWindow.rootViewController;
    while (vc.presentedViewController)
        vc = vc.presentedViewController;
    return vc;
}

- (void)showMessage:(NSString *)title details:(NSString *)details icon:(NSString *)iconName {
    [self.hud hideAnimated:NO];
    UIWindow *window = [UIApplication sharedApplication].keyWindow;
    if (!window)
        return;

    MBProgressHUD *hud = [MBProgressHUD showHUDAddedTo:window animated:YES];
    hud.mode = iconName ? MBProgressHUDModeCustomView : MBProgressHUDModeText;
    if (iconName) {
        UIImageView *icon = [[UIImageView alloc] initWithImage:[[UIImage systemImageNamed:iconName] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate]];
        icon.tintColor = [[UIColor labelColor] colorWithAlphaComponent:0.7f];
        icon.contentMode = UIViewContentModeScaleAspectFit;
        [icon.widthAnchor constraintEqualToConstant:36].active = YES;
        [icon.heightAnchor constraintEqualToConstant:36].active = YES;
        hud.customView = icon;
    }
    hud.label.text = title;
    hud.label.numberOfLines = 0;
    hud.detailsLabel.text = details;
    [hud hideAnimated:YES afterDelay:4.0];
    self.hud = nil;
}

- (void)showProgress:(NSString *)title details:(NSString *)details progress:(float)progress {
    if (!self.hud) {
        UIWindow *window = [UIApplication sharedApplication].keyWindow;
        if (!window)
            return;
        self.hud = [MBProgressHUD showHUDAddedTo:window animated:YES];
        [self.hud.button setTitle:LOC(@"CANCEL") forState:UIControlStateNormal];
        [self.hud.button addTarget:self action:@selector(cancelPressed:) forControlEvents:UIControlEventTouchUpInside];
    }
    self.hud.mode = progress < 0 ? MBProgressHUDModeIndeterminate : MBProgressHUDModeAnnularDeterminate;
    if (progress >= 0)
        self.hud.progress = progress;
    self.hud.label.text = title;
    self.hud.label.numberOfLines = 1;
    self.hud.detailsLabel.text = details;
}

- (void)cancelPressed:(UIButton *)sender {
    self.cancelled = YES;
    self.hud.detailsLabel.text = @"Stopping…";
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [MobileFFmpeg cancel];
    });
}

- (void)beginKeepAlive {
    [UIApplication sharedApplication].idleTimerDisabled = YES;
    if (self.backgroundTask == UIBackgroundTaskInvalid) {
        __weak __typeof(self) weakSelf = self;
        self.backgroundTask = [[UIApplication sharedApplication] beginBackgroundTaskWithName:@"YTMUPlaylistDownload" expirationHandler:^{
            [weakSelf endBackgroundTaskIfNeeded];
        }];
    }
}

- (void)endBackgroundTaskIfNeeded {
    if (self.backgroundTask != UIBackgroundTaskInvalid) {
        [[UIApplication sharedApplication] endBackgroundTask:self.backgroundTask];
        self.backgroundTask = UIBackgroundTaskInvalid;
    }
}

- (void)endKeepAlive {
    [UIApplication sharedApplication].idleTimerDisabled = NO;
    [self endBackgroundTaskIfNeeded];
}

#pragma mark Start

- (void)startWithBrowseID:(NSString *)browseID {
    if (self.running) {
        [self showMessage:@"Playlist download already running" details:nil icon:nil];
        return;
    }
    // PL... / OLAK5uy_... (album as playlist) -> VL..., albums stay MPREb_...
    if ([browseID hasPrefix:@"PL"] || [browseID hasPrefix:@"OLAK5uy_"] || [browseID hasPrefix:@"RD"])
        browseID = [@"VL" stringByAppendingString:browseID];
    if (![browseID hasPrefix:@"VL"] && ![browseID hasPrefix:@"MPREb_"]) {
        [self showMessage:LOC(@"OOPS") details:@"This page type isn't supported" icon:@"xmark"];
        return;
    }

    self.running = YES;
    self.cancelled = NO;
    self.isAlbum = [browseID hasPrefix:@"MPREb_"];
    self.albumArtist = nil;
    self.albumYear = nil;
    self.albumCoverURL = nil;

    // Device info is read here on the main thread
    struct utsname systemInfo;
    uname(&systemInfo);
    self.deviceModel = [NSString stringWithUTF8String:systemInfo.machine] ?: @"iPhone16,2";
    self.systemVersion = [UIDevice currentDevice].systemVersion ?: @"18.0";
    self.appVersion = [NSBundle mainBundle].infoDictionary[@"CFBundleShortVersionString"] ?: @"8.0";

    [self showProgress:@"Loading playlist…" details:nil progress:-1];

    dispatch_async(self.workQueue, ^{
        NSString *title = nil;
        NSArray<YTMUPlaylistTrack *> *tracks = [self fetchPlaylist:browseID title:&title];

        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.cancelled) {
                [self finishWithMessage:@"Cancelled" details:nil icon:@"xmark"];
                return;
            }
            if (tracks.count == 0) {
                [self finishWithMessage:LOC(@"OOPS") details:@"Couldn't load the songs (private playlists aren't supported yet)" icon:@"xmark"];
                return;
            }
            [self confirmDownloadOfTracks:tracks title:title ?: @"Playlist"];
        });
    });
}

- (void)finishWithMessage:(NSString *)title details:(NSString *)details icon:(NSString *)icon {
    [self endKeepAlive];
    self.running = NO;
    [self showMessage:title details:details icon:icon];
}

#pragma mark Playlist fetching (InnerTube web API)

- (NSDictionary *)webContext {
    return @{@"client": @{@"clientName": @"WEB_REMIX", @"clientVersion": @"1.20250310.01.00", @"hl": @"en", @"gl": @"US"}};
}

- (NSDictionary *)webHeaders {
    return @{
        @"User-Agent": @"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36",
        @"Origin": @"https://music.youtube.com",
        @"X-YouTube-Client-Name": @"67",
        @"X-YouTube-Client-Version": @"1.20250310.01.00"
    };
}

- (NSArray<YTMUPlaylistTrack *> *)fetchPlaylist:(NSString *)browseID title:(NSString **)titleOut {
    NSMutableArray<YTMUPlaylistTrack *> *tracks = [NSMutableArray array];
    NSString *baseURL = @"https://music.youtube.com/youtubei/v1/browse?prettyPrint=false";

    NSDictionary *response = YTMUPostJSON(baseURL, @{@"context": [self webContext], @"browseId": browseID}, [self webHeaders]);
    if (!response)
        return tracks;

    // Title (+ artist and year for albums) from the page header
    for (NSString *headerKey in @[@"musicResponsiveHeaderRenderer", @"musicDetailHeaderRenderer", @"musicEditablePlaylistDetailHeaderRenderer"]) {
        id header = YTMUFindFirst(response, headerKey);
        NSString *title = YTMUText(YTMUFindFirst(header, @"title"));
        if (!title.length)
            continue;
        if (titleOut)
            *titleOut = title;

        if (self.isAlbum) {
            // Artist: "straplineTextOne" (new layout) or the linked run in the subtitle
            NSString *artist = YTMUText(YTMUFindFirst(header, @"straplineTextOne"));
            NSArray *runs = YTMUPath(YTMUFindFirst(header, @"subtitle"), @[@"runs"]);
            if (!artist.length && [runs isKindOfClass:[NSArray class]]) {
                for (NSDictionary *run in runs) {
                    if ([run isKindOfClass:[NSDictionary class]] && run[@"navigationEndpoint"] && [run[@"text"] isKindOfClass:[NSString class]]) {
                        artist = run[@"text"];
                        break;
                    }
                }
            }
            if (artist.length)
                self.albumArtist = artist;

            // Year: any 4-digit year in the subtitle ("Album • 2013")
            NSString *subtitle = YTMUText(YTMUFindFirst(header, @"subtitle"));
            NSRegularExpression *yearRegex = [NSRegularExpression regularExpressionWithPattern:@"\\b(19|20)\\d{2}\\b" options:0 error:nil];
            NSTextCheckingResult *year = subtitle ? [yearRegex firstMatchInString:subtitle options:0 range:NSMakeRange(0, subtitle.length)] : nil;
            if (year)
                self.albumYear = [subtitle substringWithRange:year.range];

            // One cover for every song of the album
            NSArray *thumbnails = YTMUFindFirst(header, @"thumbnails");
            NSString *coverURL = [thumbnails isKindOfClass:[NSArray class]] ? YTMUPath(thumbnails, @[@-1, @"url"]) : nil;
            if ([coverURL isKindOfClass:[NSString class]])
                self.albumCoverURL = YTMUBigThumbnail(coverURL);
        }
        break;
    }

    // Only look inside the track list, not suggestions etc.
    id scope = YTMUFindFirst(response, self.isAlbum ? @"musicShelfRenderer" : @"musicPlaylistShelfRenderer") ?: response;
    NSInteger position = 0;
    NSString *previousToken = nil;

    for (NSUInteger page = 0; page < 200 && scope && !self.cancelled; page++) {
        NSMutableArray *items = [NSMutableArray array];
        YTMUCollectAll(scope, @"musicResponsiveListItemRenderer", items);

        for (NSDictionary *item in items) {
            if (![item isKindOfClass:[NSDictionary class]])
                continue;
            position++;

            NSString *videoID = YTMUPath(item, @[@"playlistItemData", @"videoId"]);
            if (![videoID isKindOfClass:[NSString class]])
                videoID = YTMUFindFirst(item[@"overlay"], @"videoId");
            if (![videoID isKindOfClass:[NSString class]] || videoID.length == 0)
                continue; // unavailable song, keeps its number slot

            NSArray *columns = item[@"flexColumns"];
            YTMUPlaylistTrack *track = [YTMUPlaylistTrack new];
            track.position = position;
            track.videoID = videoID;
            track.title = YTMUText(YTMUPath(columns, @[@0, @"musicResponsiveListItemFlexColumnRenderer", @"text"])) ?: @"Unknown";
            track.artist = YTMUText(YTMUPath(columns, @[@1, @"musicResponsiveListItemFlexColumnRenderer", @"text"]));
            NSString *thumb = YTMUPath(item, @[@"thumbnail", @"musicThumbnailRenderer", @"thumbnail", @"thumbnails", @-1, @"url"]);
            track.thumbnailURL = [thumb isKindOfClass:[NSString class]] ? YTMUBigThumbnail(thumb) : nil;
            [tracks addObject:track];
        }

        // Next chunk (long playlists load 100 songs at a time)
        NSString *token = YTMUPath(YTMUFindFirst(scope, @"continuationCommand"), @[@"token"]);
        NSDictionary *next = nil;
        if ([token isKindOfClass:[NSString class]] && [token isEqualToString:previousToken])
            token = nil; // same page again, stop
        if ([token isKindOfClass:[NSString class]]) {
            previousToken = token;
            next = YTMUPostJSON(baseURL, @{@"context": [self webContext], @"continuation": token}, [self webHeaders]);
        } else {
            NSString *legacy = YTMUPath(YTMUFindFirst(scope, @"nextContinuationData"), @[@"continuation"]);
            if ([legacy isKindOfClass:[NSString class]]) {
                NSString *escaped = [legacy stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
                NSString *url = [NSString stringWithFormat:@"%@&ctoken=%@&continuation=%@&type=next", baseURL, escaped, escaped];
                next = YTMUPostJSON(url, @{@"context": [self webContext]}, [self webHeaders]);
            }
        }
        scope = next;

        dispatch_async(dispatch_get_main_queue(), ^{
            self.hud.detailsLabel.text = [NSString stringWithFormat:@"%lu songs found", (unsigned long)tracks.count];
        });
    }

    // Album page without a readable track list: load the album's playlist form instead
    if (self.isAlbum && [browseID hasPrefix:@"MPREb_"] && tracks.count == 0 && !self.cancelled) {
        NSString *audioPlaylistID = YTMUFindFirst(response, @"audioPlaylistId");
        if ([audioPlaylistID isKindOfClass:[NSString class]] && audioPlaylistID.length) {
            NSString *albumTitle = titleOut ? *titleOut : nil;
            NSArray<YTMUPlaylistTrack *> *fallback = [self fetchPlaylist:[@"VL" stringByAppendingString:audioPlaylistID] title:titleOut];
            if (albumTitle.length && titleOut)
                *titleOut = albumTitle; // keep the album name
            return fallback;
        }
    }

    return tracks;
}

#pragma mark Stream lookup (InnerTube iOS API)

// Finds audio for a video. Returns the player response and fills:
//   hlsURL    - HLS audio playlist (best, same as the single-song download), or
//   directURL - plain AAC m4a file (format 140) + the user agent to fetch it with
- (NSDictionary *)streamForVideoID:(NSString *)videoID
                            hlsURL:(NSString **)hlsOut
                         directURL:(NSString **)directOut
                         userAgent:(NSString **)userAgentOut
                            reason:(NSString **)reasonOut {
    NSString *osUnderscore = [self.systemVersion stringByReplacingOccurrencesOfString:@"." withString:@"_"];
    NSString *vrUserAgent = @"com.google.android.apps.youtube.vr.oculus/1.62.27 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip";

    NSArray<NSDictionary *> *clients = @[
        @{@"name": @"IOS_MUSIC", @"id": @"26", @"version": self.appVersion,
          @"ua": [NSString stringWithFormat:@"com.google.ios.youtubemusic/%@ (%@; U; CPU iOS %@ like Mac OS X;)", self.appVersion, self.deviceModel, osUnderscore],
          @"client": @{@"deviceMake": @"Apple", @"deviceModel": self.deviceModel, @"osName": @"iPhone", @"osVersion": self.systemVersion}},
        @{@"name": @"IOS", @"id": @"5", @"version": @"20.10.4",
          @"ua": [NSString stringWithFormat:@"com.google.ios.youtube/20.10.4 (%@; U; CPU iOS %@ like Mac OS X;)", self.deviceModel, osUnderscore],
          @"client": @{@"deviceMake": @"Apple", @"deviceModel": self.deviceModel, @"osName": @"iPhone", @"osVersion": self.systemVersion}},
        @{@"name": @"ANDROID_VR", @"id": @"28", @"version": @"1.62.27",
          @"ua": vrUserAgent,
          @"client": @{@"deviceMake": @"Oculus", @"deviceModel": @"Quest 3", @"androidSdkVersion": @32, @"osName": @"Android", @"osVersion": @"12L"}}
    ];

    NSMutableArray<NSString *> *reasons = [NSMutableArray array];
    for (NSDictionary *client in clients) {
        if (self.cancelled)
            break;

        NSMutableDictionary *clientContext = [client[@"client"] mutableCopy];
        clientContext[@"clientName"] = client[@"name"];
        clientContext[@"clientVersion"] = client[@"version"];
        clientContext[@"hl"] = @"en";
        clientContext[@"gl"] = @"US";

        NSDictionary *body = @{
            @"context": @{@"client": clientContext},
            @"videoId": videoID,
            @"contentCheckOk": @YES,
            @"racyCheckOk": @YES
        };
        NSDictionary *headers = @{
            @"User-Agent": client[@"ua"],
            @"X-YouTube-Client-Name": client[@"id"],
            @"X-YouTube-Client-Version": client[@"version"]
        };

        NSDictionary *response = YTMUPostJSON(@"https://youtubei.googleapis.com/youtubei/v1/player?prettyPrint=false", body, headers);

        // HLS first
        NSString *hls = YTMUPath(response, @[@"streamingData", @"hlsManifestUrl"]);
        if ([hls isKindOfClass:[NSString class]] && hls.length) {
            if (hlsOut)
                *hlsOut = hls;
            return response;
        }

        // Plain AAC file: format 140, else best other audio/mp4 with a direct link
        NSArray *formats = YTMUPath(response, @[@"streamingData", @"adaptiveFormats"]);
        NSString *best = nil;
        NSInteger bestBitrate = -1;
        BOOL sawCiphered = NO;
        if ([formats isKindOfClass:[NSArray class]]) {
            for (NSDictionary *format in formats) {
                if (![format isKindOfClass:[NSDictionary class]])
                    continue;
                NSString *mime = format[@"mimeType"];
                if (![mime isKindOfClass:[NSString class]] || ![mime hasPrefix:@"audio/mp4"])
                    continue;
                NSString *url = format[@"url"];
                if (![url isKindOfClass:[NSString class]]) {
                    if (format[@"signatureCipher"] || format[@"cipher"])
                        sawCiphered = YES;
                    continue;
                }
                NSInteger bitrate = [format[@"itag"] integerValue] == 140 ? NSIntegerMax : [format[@"bitrate"] integerValue];
                if (bitrate > bestBitrate) {
                    best = url;
                    bestBitrate = bitrate;
                }
            }
        }
        if (best) {
            if (directOut)
                *directOut = best;
            if (userAgentOut)
                *userAgentOut = client[@"ua"];
            return response;
        }

        NSString *status = YTMUPath(response, @[@"playabilityStatus", @"reason"]) ?: YTMUPath(response, @[@"playabilityStatus", @"status"]);
        NSString *what = !response ? @"request failed"
                       : ![status isKindOfClass:[NSString class]] ? @"no status"
                       : [status isEqualToString:@"OK"] ? (sawCiphered ? @"OK, only protected links" : @"OK, no audio links")
                       : status;
        [reasons addObject:[NSString stringWithFormat:@"%@: %@", client[@"name"], what]];
    }

    if (reasonOut)
        *reasonOut = [reasons componentsJoinedByString:@"; "];
    return nil;
}

#pragma mark Confirm + download loop

- (NSURL *)folderForTitle:(NSString *)title {
    NSURL *documents = [[[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask] lastObject];
    return [[documents URLByAppendingPathComponent:@"YTMusicUltimate"] URLByAppendingPathComponent:YTMUCleanName(title)];
}

- (NSMutableDictionary *)loadIndexInFolder:(NSURL *)folder {
    NSData *data = [NSData dataWithContentsOfURL:[folder URLByAppendingPathComponent:@".ytmu_index.json"]];
    id json = data ? [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil] : nil;
    return [json isKindOfClass:[NSMutableDictionary class]] ? json : [NSMutableDictionary dictionary];
}

- (void)saveIndex:(NSDictionary *)index inFolder:(NSURL *)folder {
    NSData *data = [NSJSONSerialization dataWithJSONObject:index options:NSJSONWritingPrettyPrinted error:nil];
    [data writeToURL:[folder URLByAppendingPathComponent:@".ytmu_index.json"] atomically:YES];
}

- (BOOL)isTrackDownloaded:(YTMUPlaylistTrack *)track index:(NSDictionary *)index folder:(NSURL *)folder {
    NSDictionary *entry = index[track.videoID];
    NSString *file = [entry isKindOfClass:[NSDictionary class]] ? entry[@"file"] : nil;
    return file && [[NSFileManager defaultManager] fileExistsAtPath:[folder URLByAppendingPathComponent:file].path];
}

- (void)confirmDownloadOfTracks:(NSArray<YTMUPlaylistTrack *> *)tracks title:(NSString *)title {
    [self.hud hideAnimated:YES];
    self.hud = nil;

    NSURL *folder = [self folderForTitle:title];
    NSDictionary *index = [self loadIndexInFolder:folder];
    NSUInteger existing = 0;
    for (YTMUPlaylistTrack *track in tracks) {
        if ([self isTrackDownloaded:track index:index folder:folder])
            existing++;
    }
    NSUInteger missing = tracks.count - existing;

    NSString *message = [NSString stringWithFormat:@"%lu songs, %lu already downloaded.\n\nSaved as .m4a in Files > YouTube Music > YTMusicUltimate > %@",
                         (unsigned long)tracks.count, (unsigned long)existing, YTMUCleanName(title)];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];

    NSString *actionTitle = missing > 0 ? [NSString stringWithFormat:@"Download %lu", (unsigned long)missing] : @"Update order only";
    [alert addAction:[UIAlertAction actionWithTitle:actionTitle style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [self runDownloadOfTracks:tracks title:title];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:LOC(@"CANCEL") style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) {
        [self finishWithMessage:@"Cancelled" details:nil icon:nil];
    }]];

    [[self topViewController] presentViewController:alert animated:YES completion:nil];
}

- (void)runDownloadOfTracks:(NSArray<YTMUPlaylistTrack *> *)tracks title:(NSString *)title {
    [self beginKeepAlive];
    [MobileFFmpegConfig setStatisticsDelegate:nil];
    [self showProgress:title details:@"Starting…" progress:0];

    dispatch_async(self.workQueue, ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        NSURL *folder = [self folderForTitle:title];
        [fm createDirectoryAtURL:folder withIntermediateDirectories:YES attributes:nil error:nil];

        NSMutableDictionary *index = [self loadIndexInFolder:folder];
        NSMutableArray<NSString *> *failures = [NSMutableArray array];
        NSUInteger downloaded = 0, skipped = 0, moved = 0;
        FFMpegDownloader *coverWriter = [FFMpegDownloader new];

        for (NSUInteger i = 0; i < tracks.count && !self.cancelled; i++) {
            YTMUPlaylistTrack *track = tracks[i];
            NSString *fileName = [NSString stringWithFormat:@"%ld. %@.m4a", (long)track.position, YTMUCleanName(track.title)];
            NSURL *finalURL = [folder URLByAppendingPathComponent:fileName];

            float progress = (float)i / (float)tracks.count;
            NSString *details = [NSString stringWithFormat:@"%lu / %lu\n%@", (unsigned long)(i + 1), (unsigned long)tracks.count, track.title];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!self.cancelled)
                    [self showProgress:title details:details progress:progress];
            });

            // Already downloaded: only fix name + track number if the song moved
            if ([self isTrackDownloaded:track index:index folder:folder]) {
                NSMutableDictionary *entry = [index[track.videoID] mutableCopy];
                if ([entry[@"position"] integerValue] != track.position) {
                    NSURL *oldURL = [folder URLByAppendingPathComponent:entry[@"file"]];
                    if (![fm fileExistsAtPath:finalURL.path] && [fm moveItemAtURL:oldURL toURL:finalURL error:nil]) {
                        YTMUPatchTrackNumber(finalURL, track.position);
                        entry[@"file"] = fileName;
                        entry[@"position"] = @(track.position);
                        index[track.videoID] = entry;
                        [self saveIndex:index inFolder:folder];
                        moved++;
                    }
                }
                skipped++;
                continue;
            }

            // 1. Stream: HLS if YouTube offers it, else the plain AAC file
            NSString *reason = nil, *hlsURL = nil, *directURL = nil, *userAgent = nil;
            NSDictionary *player = [self streamForVideoID:track.videoID hlsURL:&hlsURL directURL:&directURL userAgent:&userAgent reason:&reason];
            NSString *audioURL = hlsURL ? YTMUAudioURLFromManifest(YTMUGet(hlsURL)) : nil;
            NSString *rawPath = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"%@_raw.m4a", track.videoID]];

            if (!audioURL && directURL) {
                __weak __typeof(self) weakSelf = self;
                if (YTMUDownloadInChunks(directURL, userAgent, rawPath, ^BOOL { return weakSelf.cancelled; }))
                    audioURL = rawPath; // ffmpeg reads the local file and only adds tags
                else
                    reason = @"audio download failed";
            }
            if (!audioURL) {
                if (!self.cancelled)
                    [failures addObject:[NSString stringWithFormat:@"%ld. %@ (%@)", (long)track.position, track.title, reason ?: @"no audio stream"]];
                continue;
            }

            // 2. Metadata
            //    playlist: album + album artist = playlist name
            //    album:    album = album name, album artist = album's artist, year
            id authorValue = YTMUPath(player, @[@"videoDetails", @"author"]);
            NSString *artist = track.artist.length ? track.artist : nil;
            if (!artist.length && self.isAlbum)
                artist = self.albumArtist;
            if (!artist.length && [authorValue isKindOfClass:[NSString class]])
                artist = authorValue;
            if ([artist hasSuffix:@" - Topic"])
                artist = [artist substringToIndex:artist.length - 8];

            NSMutableDictionary *metadata = [NSMutableDictionary dictionary];
            metadata[@"title"] = track.title;
            if (artist.length)
                metadata[@"artist"] = artist;
            metadata[@"album"] = title;
            if (self.isAlbum) {
                metadata[@"album_artist"] = self.albumArtist.length ? self.albumArtist : (artist ?: title);
                if (self.albumYear.length)
                    metadata[@"date"] = self.albumYear;
            } else {
                metadata[@"album_artist"] = title;
            }
            metadata[@"track"] = [NSString stringWithFormat:@"%ld", (long)track.position];
            metadata[@"comment"] = [NSString stringWithFormat:@"https://music.youtube.com/watch?v=%@", track.videoID];

            // 3. Download
            NSString *tempPath = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.m4a", track.videoID]];
            [fm removeItemAtPath:tempPath error:nil];

            NSMutableArray<NSString *> *arguments = [@[@"-y", @"-i", audioURL, @"-map", @"0:a:0", @"-c", @"copy"] mutableCopy];
            for (NSString *key in @[@"title", @"artist", @"album", @"album_artist", @"track", @"date", @"comment"]) {
                NSString *value = metadata[key];
                if (value.length) {
                    [arguments addObject:@"-metadata"];
                    [arguments addObject:[NSString stringWithFormat:@"%@=%@", key, value]];
                }
            }
            [arguments addObject:tempPath];

            int returnCode = [MobileFFmpeg executeWithArguments:arguments];
            [fm removeItemAtPath:rawPath error:nil];
            if (returnCode != RETURN_CODE_SUCCESS) {
                [fm removeItemAtPath:tempPath error:nil];
                if (returnCode != RETURN_CODE_CANCEL)
                    [failures addObject:[NSString stringWithFormat:@"%ld. %@ (ffmpeg error %d)", (long)track.position, track.title, returnCode]];
                continue;
            }

            // 4. Cover (browse thumbnail, else video thumbnail)
            NSString *coverURL = (self.isAlbum && self.albumCoverURL) ? self.albumCoverURL : track.thumbnailURL;
            if (!coverURL) {
                NSString *fallback = YTMUPath(player, @[@"videoDetails", @"thumbnail", @"thumbnails", @-1, @"url"]);
                coverURL = [fallback isKindOfClass:[NSString class]] ? fallback : nil;
            }
            UIImage *coverImage = [UIImage imageWithData:YTMUGet(coverURL)];
            NSData *jpeg = coverImage ? UIImageJPEGRepresentation(coverImage, 0.92) : nil;
            if (jpeg)
                [coverWriter writeCoverAtom:jpeg intoFile:[NSURL fileURLWithPath:tempPath]];

            // 5. Move into the playlist folder
            [fm removeItemAtURL:finalURL error:nil];
            if (![fm moveItemAtURL:[NSURL fileURLWithPath:tempPath] toURL:finalURL error:nil]) {
                [fm removeItemAtPath:tempPath error:nil];
                [failures addObject:[NSString stringWithFormat:@"%ld. %@ (couldn't save file)", (long)track.position, track.title]];
                continue;
            }

            index[track.videoID] = [@{@"file": fileName, @"position": @(track.position)} mutableCopy];
            [self saveIndex:index inFolder:folder];
            downloaded++;

            [NSThread sleepForTimeInterval:0.3]; // be gentle with YouTube
        }

        BOOL wasCancelled = self.cancelled;
        NSString *summary = [NSString stringWithFormat:@"%lu downloaded · %lu already there%@ · %lu failed",
                             (unsigned long)downloaded, (unsigned long)skipped,
                             moved ? [NSString stringWithFormat:@" (%lu renumbered)", (unsigned long)moved] : @"",
                             (unsigned long)failures.count];

        dispatch_async(dispatch_get_main_queue(), ^{
            NSString *details = summary;
            if (failures.count) {
                [UIPasteboard generalPasteboard].string = [failures componentsJoinedByString:@"\n"];
                details = [summary stringByAppendingString:@"\nFailed songs copied to clipboard"];
            }
            [self finishWithMessage:wasCancelled ? @"Stopped" : LOC(@"DONE") details:details icon:wasCancelled ? @"xmark" : @"checkmark"];
        });
    });
}

@end