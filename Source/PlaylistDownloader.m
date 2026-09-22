#import "PlaylistDownloader.h"
#import "FFMpegDownloader.h"
#import "MP3Encoder.h"
#import "Headers/YTPlayerViewController.h"
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

// Reads a property only if the object really has it (never throws)
static id YTMUObj(id object, NSString *key) {
    if (!object || ![object respondsToSelector:NSSelectorFromString(key)])
        return nil;
    @try {
        return [object valueForKey:key];
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static NSString *YTMUTitleKey(NSString *title) {
    return [[title lowercaseString] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] ?: @"";
}

// Loose title for matching other versions of a song:
// "Yeat - EARNËD IT (Music Video)" and "EARNËD IT" both become "earnëd it"
static NSString *YTMUNormTitle(NSString *title) {
    if (!title.length)
        return @"";
    NSString *t = title.lowercaseString;
    static NSRegularExpression *brackets = nil, *spaces = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        brackets = [NSRegularExpression regularExpressionWithPattern:@"\\s*[\\(\\[][^\\)\\]]*[\\)\\]]" options:0 error:nil];
        spaces = [NSRegularExpression regularExpressionWithPattern:@"\\s+" options:0 error:nil];
    });
    t = [brackets stringByReplacingMatchesInString:t options:0 range:NSMakeRange(0, t.length) withTemplate:@""];
    NSRange dash = [t rangeOfString:@" - " options:NSBackwardsSearch];
    if (dash.location != NSNotFound && NSMaxRange(dash) < t.length)
        t = [t substringFromIndex:NSMaxRange(dash)];
    for (NSString *noise in @[@"official music video", @"official video", @"official audio", @"music video", @"lyric video", @"visualizer", @"lyrics"])
        t = [t stringByReplacingOccurrencesOfString:noise withString:@""];
    t = [spaces stringByReplacingMatchesInString:t options:0 range:NSMakeRange(0, t.length) withTemplate:@" "];
    return [t stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
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

// Updates the ID3 "TRCK" number in place when the new number has the same
// number of digits (a longer number would need the whole tag rewritten)
static BOOL YTMUPatchMP3TrackNumber(NSURL *fileURL, NSInteger position) {
    NSMutableData *file = [NSMutableData dataWithContentsOfURL:fileURL];
    const uint8_t *b = file.bytes;
    if (file.length < 10 || memcmp(b, "ID3", 3) != 0 || b[3] != 3)
        return NO;
    NSUInteger tagEnd = 10 + (((NSUInteger)b[6] & 0x7F) << 21 | ((NSUInteger)b[7] & 0x7F) << 14 | ((NSUInteger)b[8] & 0x7F) << 7 | ((NSUInteger)b[9] & 0x7F));
    NSString *number = [NSString stringWithFormat:@"%ld", (long)position];

    for (NSUInteger offset = 10; offset + 10 <= tagEnd && offset + 10 <= file.length;) {
        uint32_t size = ((uint32_t)b[offset + 4] << 24) | ((uint32_t)b[offset + 5] << 16) | ((uint32_t)b[offset + 6] << 8) | (uint32_t)b[offset + 7];
        if (b[offset] == 0 || size == 0 || offset + 10 + size > file.length)
            return NO;
        if (memcmp(b + offset, "TRCK", 4) == 0) {
            NSUInteger payload = offset + 10;
            uint8_t encoding = b[payload];
            NSData *newText = nil;
            NSUInteger textStart = payload + 1;
            if (encoding == 1) {
                textStart += 2; // BOM
                newText = [number dataUsingEncoding:NSUTF16LittleEndianStringEncoding];
            } else if (encoding == 0) {
                newText = [number dataUsingEncoding:NSASCIIStringEncoding];
            }
            NSUInteger oldLength = payload + size - textStart;
            if (!newText || newText.length != oldLength)
                return NO;
            [file replaceBytesInRange:NSMakeRange(textStart, oldLength) withBytes:newText.bytes];
            return [file writeToURL:fileURL atomically:YES];
        }
        offset += 10 + size;
    }
    return NO;
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

// Capture mode: the player loads each song, the tweak grabs its stream
@property (nonatomic, copy) NSString *collectionTitle;
@property (nonatomic, strong) NSURL *folder;
@property (nonatomic, strong) NSMutableDictionary *index; // only touched on workQueue after setup
@property (nonatomic, strong) NSMutableDictionary<NSString *, YTMUPlaylistTrack *> *pending;
@property (nonatomic, strong) NSSet<NSString *> *allVideoIDs;
@property (nonatomic) BOOL capturing;
@property (nonatomic) NSUInteger totalToDownload;
@property (nonatomic) NSUInteger downloadedCount;
@property (nonatomic) NSUInteger skippedCount;
@property (nonatomic) NSUInteger queuedCount;
@property (atomic) NSUInteger movedCount;
@property (nonatomic, strong) NSMutableArray<NSString *> *failures;
@property (nonatomic, copy) NSString *lastCapturedID;
@property (nonatomic, strong) NSMutableDictionary<NSString *, YTMUPlaylistTrack *> *pendingByTitle;
@property (nonatomic, strong) NSSet<NSString *> *knownTitles;
@property (nonatomic) NSUInteger strayCount;
@property (nonatomic) BOOL sawActivation;
@property (nonatomic) BOOL titleIsGuess;          // page title couldn't be read
@property (nonatomic, strong) NSSet<NSString *> *unavailableIDs; // "never played" last time
@property (nonatomic, copy) NSString *format;     // @"m4a" or @"mp3"
@property (nonatomic, strong) NSMutableDictionary<NSString *, YTMUPlaylistTrack *> *pendingByNorm;
@property (nonatomic, strong) NSSet<NSString *> *knownNorms;
@property (nonatomic, weak) id lastPlayer;
@property (nonatomic) NSTimeInterval lastActivity;
@property (nonatomic, strong) NSTimer *watchdog;
@property (nonatomic, copy) NSString *collectionCoverURL; // playlist / album cover for cover.png
@property (nonatomic, copy) NSString *firstTrackCoverURL; // album fallback
@property (nonatomic, strong) FFMpegDownloader *coverWriter;
@end

@implementation YTMUPlaylistDownloader

+ (instancetype)sharedDownloader {
    static YTMUPlaylistDownloader *shared = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        shared = [YTMUPlaylistDownloader new];
        shared.workQueue = dispatch_queue_create("ytmu.playlist.download", DISPATCH_QUEUE_SERIAL);
        shared.backgroundTask = UIBackgroundTaskInvalid;
        [[NSNotificationCenter defaultCenter] addObserver:shared selector:@selector(playerDidActivate:) name:@"YTMUPlayerDidActivateVideo" object:nil];
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

// Small status box at the top that lets taps through (so you can press Play)
- (void)showStatus:(NSString *)title details:(NSString *)details progress:(float)progress {
    if (!self.hud || self.hud.userInteractionEnabled) {
        [self.hud hideAnimated:NO];
        UIWindow *window = [UIApplication sharedApplication].keyWindow;
        if (!window)
            return;
        self.hud = [MBProgressHUD showHUDAddedTo:window animated:YES];
        self.hud.userInteractionEnabled = NO;
        self.hud.offset = CGPointMake(0.f, -MBProgressMaxOffset);
        self.hud.mode = MBProgressHUDModeAnnularDeterminate;
        self.hud.label.numberOfLines = 1;
        self.hud.detailsLabel.numberOfLines = 0;
    }
    self.hud.progress = progress;
    self.hud.label.text = title;
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
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Playlist download running"
                                                                       message:@"Stop it? Songs saved so far are kept."
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"Stop" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
            [self stopByUser];
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"Keep going" style:UIAlertActionStyleCancel handler:nil]];
        [[self topViewController] presentViewController:alert animated:YES completion:nil];
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
    self.isAlbum = [browseID hasPrefix:@"MPREb_"] || [browseID hasPrefix:@"VLOLAK5uy_"];
    self.albumArtist = nil;
    self.albumYear = nil;
    self.albumCoverURL = nil;
    self.collectionCoverURL = nil;
    self.firstTrackCoverURL = nil;

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
            self.titleIsGuess = title.length == 0;
            [self confirmDownloadOfTracks:tracks title:title.length ? title : (self.isAlbum ? @"Album" : @"Playlist")];
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
    for (NSString *headerKey in @[@"musicResponsiveHeaderRenderer", @"musicDetailHeaderRenderer", @"musicEditablePlaylistDetailHeaderRenderer", @"musicImmersiveHeaderRenderer", @"musicVisualHeaderRenderer"]) {
        id header = YTMUFindFirst(response, headerKey);
        NSString *title = YTMUText(YTMUFindFirst(header, @"title"));
        if (!title.length)
            continue;
        if (titleOut)
            *titleOut = title;

        NSArray *headerThumbs = YTMUFindFirst(header, @"thumbnails");
        NSString *headerCover = [headerThumbs isKindOfClass:[NSArray class]] ? YTMUPath(headerThumbs, @[@-1, @"url"]) : nil;
        if ([headerCover isKindOfClass:[NSString class]] && !self.collectionCoverURL)
            self.collectionCoverURL = YTMUBigThumbnail(headerCover);

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

    if (!self.collectionCoverURL) {
        NSString *metaCover = YTMUPath(response, @[@"microformat", @"microformatDataRenderer", @"thumbnail", @"thumbnails", @-1, @"url"]);
        if ([metaCover isKindOfClass:[NSString class]])
            self.collectionCoverURL = YTMUBigThumbnail(metaCover);
    }

    // Title fallback: page description, e.g. "Minecraft - Volume Beta - Album by C418"
    if (titleOut && !(*titleOut).length) {
        NSString *metaTitle = YTMUPath(response, @[@"microformat", @"microformatDataRenderer", @"title"]);
        if ([metaTitle isKindOfClass:[NSString class]] && metaTitle.length) {
            for (NSString *marker in @[@" - Album by ", @" - EP by ", @" - Single by ", @" - Playlist by "]) {
                NSRange range = [metaTitle rangeOfString:marker options:NSBackwardsSearch];
                if (range.location != NSNotFound) {
                    if (self.isAlbum && !self.albumArtist.length)
                        self.albumArtist = [metaTitle substringFromIndex:NSMaxRange(range)];
                    metaTitle = [metaTitle substringToIndex:range.location];
                    break;
                }
            }
            *titleOut = metaTitle;
        }
    }
    if (titleOut && !(*titleOut).length) {
        NSString *anyTitle = YTMUText(YTMUFindFirst(YTMUFindFirst(response, @"header"), @"title"));
        if (anyTitle.length)
            *titleOut = anyTitle;
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

#pragma mark Files + index

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

// m4a entries use the plain video ID (older runs), mp3 entries "mp3:<id>"
- (NSString *)indexKeyForVideoID:(NSString *)videoID format:(NSString *)format {
    return [format isEqualToString:@"mp3"] ? [@"mp3:" stringByAppendingString:videoID] : videoID;
}

- (NSString *)indexKeyForVideoID:(NSString *)videoID {
    return [self indexKeyForVideoID:videoID format:self.format ?: @"m4a"];
}

- (BOOL)isTrackDownloaded:(YTMUPlaylistTrack *)track index:(NSDictionary *)index folder:(NSURL *)folder {
    return [self isTrackDownloaded:track index:index folder:folder format:self.format ?: @"m4a"];
}

- (BOOL)isTrackDownloaded:(YTMUPlaylistTrack *)track index:(NSDictionary *)index folder:(NSURL *)folder format:(NSString *)format {
    NSDictionary *entry = index[[self indexKeyForVideoID:track.videoID format:format]];
    NSString *file = [entry isKindOfClass:[NSDictionary class]] ? entry[@"file"] : nil;
    return file && [[NSFileManager defaultManager] fileExistsAtPath:[folder URLByAppendingPathComponent:file].path];
}

- (NSString *)fileNameForTrack:(YTMUPlaylistTrack *)track {
    return [NSString stringWithFormat:@"%ld. %@.%@", (long)track.position, YTMUCleanName(track.title), self.format ?: @"m4a"];
}

#pragma mark Confirm

- (void)confirmDownloadOfTracks:(NSArray<YTMUPlaylistTrack *> *)tracks title:(NSString *)title {
    [self.hud hideAnimated:YES];
    self.hud = nil;

    NSURL *folder = [self folderForTitle:title];
    NSDictionary *index = [self loadIndexInFolder:folder];
    NSUInteger existingM4A = 0, existingMP3 = 0, unavailable = 0;
    NSArray *unavailableList = [index[@"_unavailable"] isKindOfClass:[NSArray class]] ? index[@"_unavailable"] : @[];
    for (YTMUPlaylistTrack *track in tracks) {
        BOOL hasM4A = [self isTrackDownloaded:track index:index folder:folder format:@"m4a"];
        BOOL hasMP3 = [self isTrackDownloaded:track index:index folder:folder format:@"mp3"];
        if (hasM4A)
            existingM4A++;
        if (hasMP3)
            existingMP3++;
        if (!hasM4A && !hasMP3 && [unavailableList containsObject:track.videoID])
            unavailable++;
    }

    NSString *unavailableNote = unavailable ? [NSString stringWithFormat:@"\n%lu weren't playable last time.", (unsigned long)unavailable] : @"";
    NSString *message = [NSString stringWithFormat:@"%lu songs. Already downloaded: %lu as .m4a, %lu as .mp3.%@\n\n.m4a = original quality, fastest. .mp3 = converted (~190 kbps), a few seconds extra per song.\n\nAfter you confirm, press Play on this page. The player jumps through the songs while they download. Keep YTM open (tip: mute your phone).\n\nSaved in Files > YouTube Music > YTMusicUltimate > %@",
                         (unsigned long)tracks.count, (unsigned long)existingM4A, (unsigned long)existingMP3, unavailableNote, YTMUCleanName(title)];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];

    NSUInteger missingM4A = tracks.count - existingM4A;
    NSUInteger missingMP3 = tracks.count - existingMP3;
    NSString *m4aTitle = missingM4A ? [NSString stringWithFormat:@"Download %lu as .m4a", (unsigned long)missingM4A] : @"Update .m4a order only";
    NSString *mp3Title = missingMP3 ? [NSString stringWithFormat:@"Download %lu as .mp3", (unsigned long)missingMP3] : @"Update .mp3 order only";

    [alert addAction:[UIAlertAction actionWithTitle:m4aTitle style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        self.format = @"m4a";
        [self beginCaptureOfTracks:tracks title:title];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:mp3Title style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        self.format = @"mp3";
        [self beginCaptureOfTracks:tracks title:title];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:LOC(@"CANCEL") style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) {
        [self finishWithMessage:@"Cancelled" details:nil icon:nil];
    }]];

    [[self topViewController] presentViewController:alert animated:YES completion:nil];
}

#pragma mark Capture mode

- (void)beginCaptureOfTracks:(NSArray<YTMUPlaylistTrack *> *)tracks title:(NSString *)title {
    self.collectionTitle = title;
    self.folder = [self folderForTitle:title];
    [[NSFileManager defaultManager] createDirectoryAtURL:self.folder withIntermediateDirectories:YES attributes:nil error:nil];

    self.index = [self loadIndexInFolder:self.folder];
    NSArray *unavailableList = [self.index[@"_unavailable"] isKindOfClass:[NSArray class]] ? self.index[@"_unavailable"] : @[];
    self.unavailableIDs = [NSSet setWithArray:unavailableList];
    self.pending = [NSMutableDictionary dictionary];
    self.failures = [NSMutableArray array];
    self.coverWriter = [FFMpegDownloader new];
    self.downloadedCount = 0;
    self.skippedCount = 0;
    self.queuedCount = 0;
    self.movedCount = 0;
    self.lastCapturedID = nil;

    self.pendingByTitle = [NSMutableDictionary dictionary];
    self.pendingByNorm = [NSMutableDictionary dictionary];
    self.strayCount = 0;
    self.sawActivation = NO;

    NSMutableSet<NSString *> *allIDs = [NSMutableSet set];
    NSMutableSet<NSString *> *titles = [NSMutableSet set];
    NSMutableSet<NSString *> *norms = [NSMutableSet set];
    NSMutableArray<YTMUPlaylistTrack *> *existing = [NSMutableArray array];
    for (YTMUPlaylistTrack *track in tracks) {
        [allIDs addObject:track.videoID];
        NSString *titleKey = YTMUTitleKey(track.title);
        NSString *normKey = YTMUNormTitle(track.title);
        [titles addObject:titleKey];
        if (normKey.length)
            [norms addObject:normKey];
        if ([self isTrackDownloaded:track index:self.index folder:self.folder]) {
            [existing addObject:track];
            self.skippedCount++;
        } else {
            self.pending[track.videoID] = track;
            if (!self.pendingByTitle[titleKey])
                self.pendingByTitle[titleKey] = track;
            if (normKey.length && !self.pendingByNorm[normKey])
                self.pendingByNorm[normKey] = track;
        }
    }
    self.allVideoIDs = allIDs;
    self.knownTitles = titles;
    self.knownNorms = norms;
    self.totalToDownload = self.pending.count;

    [self beginKeepAlive];
    [MobileFFmpegConfig setStatisticsDelegate:nil];

    // Songs that are already there: only fix name + track number if they moved
    dispatch_async(self.workQueue, ^{
        [self renumberExistingTracks:existing];
    });

    if (self.pending.count == 0) {
        self.capturing = NO;
        [self checkDone];
        return;
    }

    self.capturing = YES;
    self.lastActivity = [NSDate timeIntervalSinceReferenceDate];
    [self.watchdog invalidate];
    self.watchdog = [NSTimer scheduledTimerWithTimeInterval:4.0 target:self selector:@selector(watchdogTick) userInfo:nil repeats:YES];
    [self updateStatus];
}

// If the player stalls (paused, missed a song change), nudge it on
- (void)watchdogTick {
    if (!self.capturing) {
        [self.watchdog invalidate];
        self.watchdog = nil;
        return;
    }
    id player = self.lastPlayer;
    if (!player || [NSDate timeIntervalSinceReferenceDate] - self.lastActivity < 10.0)
        return;
    self.lastActivity = [NSDate timeIntervalSinceReferenceDate];

    NSString *videoID = [self videoIDOfPlayer:player];
    if (videoID && ![videoID isEqualToString:self.lastCapturedID])
        [self capturePlayer:player video:nil attempt:0];
    else
        [self skipAheadInPlayer:player attempt:0];
    if ([player respondsToSelector:@selector(play)])
        [player performSelector:@selector(play)];
}

- (void)renumberExistingTracks:(NSArray<YTMUPlaylistTrack *> *)tracks {
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL changed = NO;
    for (YTMUPlaylistTrack *track in tracks) {
        NSString *key = [self indexKeyForVideoID:track.videoID];
        NSMutableDictionary *entry = [self.index[key] mutableCopy];
        if ([entry[@"position"] integerValue] == track.position)
            continue;
        NSString *fileName = [self fileNameForTrack:track];
        NSURL *oldURL = [self.folder URLByAppendingPathComponent:entry[@"file"]];
        NSURL *newURL = [self.folder URLByAppendingPathComponent:fileName];
        if (![fm fileExistsAtPath:newURL.path] && [fm moveItemAtURL:oldURL toURL:newURL error:nil]) {
            if ([self.format isEqualToString:@"mp3"])
                YTMUPatchMP3TrackNumber(newURL, track.position);
            else
                YTMUPatchTrackNumber(newURL, track.position);
            entry[@"file"] = fileName;
            entry[@"position"] = @(track.position);
            self.index[key] = entry;
            self.movedCount++;
            changed = YES;
        }
    }
    if (changed)
        [self saveIndex:self.index inFolder:self.folder];
}

- (void)updateStatus {
    NSUInteger total = self.totalToDownload;
    NSUInteger captured = total - self.pending.count;
    NSUInteger finished = self.downloadedCount + self.failures.count;
    NSString *details;

    if (self.capturing && captured == 0 && !self.sawActivation) {
        // Tell the user where the missing songs start (skips rolling through old ones)
        // First missing songs that were playable before (unplayable ones are still tried)
        NSArray *ordered = [self.pending.allValues sortedArrayUsingComparator:^NSComparisonResult(YTMUPlaylistTrack *a, YTMUPlaylistTrack *b) {
            return a.position < b.position ? NSOrderedAscending : (a.position > b.position ? NSOrderedDescending : NSOrderedSame);
        }];
        NSMutableArray<YTMUPlaylistTrack *> *candidates = [NSMutableArray array];
        for (YTMUPlaylistTrack *track in ordered) {
            if (![self.unavailableIDs containsObject:track.videoID])
                [candidates addObject:track];
            if (candidates.count == 2)
                break;
        }
        BOOL onlyUnplayable = candidates.count == 0 && ordered.count > 0;
        if (onlyUnplayable)
            [candidates addObjectsFromArray:[ordered subarrayWithRange:NSMakeRange(0, MIN((NSUInteger)2, ordered.count))]];
        YTMUPlaylistTrack *first = candidates.firstObject;
        if (onlyUnplayable) {
            details = [NSString stringWithFormat:@"Tap #%ld \"%@\" to start there\n(it wasn't playable last time)", (long)first.position, first.title];
        } else if (self.skippedCount > 0 && first && first.position > 1) {
            details = [NSString stringWithFormat:@"Tap #%ld \"%@\" to start there", (long)first.position, first.title];
            if (candidates.count > 1)
                details = [details stringByAppendingFormat:@"\n(won't play? tap #%ld \"%@\")", (long)candidates[1].position, candidates[1].title];
            details = [details stringByAppendingString:@"\nor press Play to start from the top"];
        } else {
            details = @"Press Play on this page now";
        }
    } else if (self.capturing && captured == 0) {
        details = [NSString stringWithFormat:@"Skipping songs you already have… (%lu to download)", (unsigned long)total];
    } else {
        details = [NSString stringWithFormat:@"Captured %lu / %lu · saved %lu", (unsigned long)captured, (unsigned long)total, (unsigned long)self.downloadedCount];
        if (self.failures.count)
            details = [details stringByAppendingFormat:@" · %lu failed", (unsigned long)self.failures.count];
        if (!self.capturing && self.queuedCount > 0)
            details = [details stringByAppendingString:@"\nFinishing downloads…"];
    }

    NSString *statusTitle = [NSString stringWithFormat:@"%@ · .%@", self.collectionTitle ?: @"", self.format ?: @"m4a"];
    [self showStatus:statusTitle details:details progress:total ? (float)finished / (float)total : 0];
}

// Posted by Downloading.x whenever the player starts a new song
- (void)playerDidActivate:(NSNotification *)notification {
    id player = notification.object;
    id video = notification.userInfo[@"video"];
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.capturing)
            return;
        self.lastPlayer = player;
        self.lastActivity = [NSDate timeIntervalSinceReferenceDate];
        if (!self.sawActivation) {
            self.sawActivation = YES;
            [self updateStatus];
        }

        // Song we already have: skip right away, no need to wait for its data
        NSString *videoID = [self videoIDOfPlayer:player];
        // (the ID can still be the previous song's for a moment, that one equals lastCapturedID)
        if (videoID && ![videoID isEqualToString:self.lastCapturedID] &&
            !self.pending[videoID] && [self.allVideoIDs containsObject:videoID]) {
            self.lastCapturedID = videoID;
            [self skipAheadInPlayer:player attempt:0];
            return;
        }

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self capturePlayer:player video:video attempt:0];
        });
    });
}

- (YTMUPlaylistTrack *)pendingTrackMatchingTitle:(NSString *)title {
    YTMUPlaylistTrack *track = self.pendingByTitle[YTMUTitleKey(title)];
    if (track)
        return track;
    NSString *norm = YTMUNormTitle(title);
    if (norm.length == 0)
        return nil;
    track = self.pendingByNorm[norm];
    if (track)
        return track;
    // Partial match, e.g. extra words in a video title
    for (NSString *key in self.pendingByNorm) {
        if (key.length >= 4 && ([norm containsString:key] || [key containsString:norm]))
            return self.pendingByNorm[key];
    }
    return nil;
}

- (BOOL)isKnownTitle:(NSString *)title {
    if ([self.knownTitles containsObject:YTMUTitleKey(title)])
        return YES;
    NSString *norm = YTMUNormTitle(title);
    return norm.length && [self.knownNorms containsObject:norm];
}

- (NSString *)videoIDOfPlayer:(id)player {
    id videoID = YTMUObj(player, @"currentVideoID") ?: YTMUObj(player, @"contentVideoID");
    return [videoID isKindOfClass:[NSString class]] && ((NSString *)videoID).length ? videoID : nil;
}

- (void)capturePlayer:(id)player video:(id)video attempt:(NSInteger)attempt {
    if (!self.capturing || !player)
        return;

    NSString *videoID = [self videoIDOfPlayer:player];
    if (!videoID) {
        if (attempt < 6) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [self capturePlayer:player video:video attempt:attempt + 1];
            });
        }
        return;
    }
    if ([videoID isEqualToString:self.lastCapturedID])
        return;

    // Known song we already have
    YTMUPlaylistTrack *track = self.pending[videoID];
    if (!track && [self.allVideoIDs containsObject:videoID]) {
        self.lastCapturedID = videoID;
        self.strayCount = 0;
        [self skipAheadInPlayer:player attempt:0];
        return;
    }

    // Search around the activated song + player for this song's stream
    NSMutableArray *starts = [NSMutableArray array];
    if (video)
        [starts addObject:video];
    [starts addObject:player];
    NSDictionary *info = YTMUStreamInfoForVideo(starts, videoID);
    NSString *hls = [info[@"hls"] isKindOfClass:[NSString class]] ? info[@"hls"] : nil;

    if (!hls.length && attempt < 8) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self capturePlayer:player video:video attempt:attempt + 1];
        });
        return;
    }

    // YTM sometimes plays another version (other video ID) of a playlist song: match by title
    NSString *playingTitle = [info[@"title"] isKindOfClass:[NSString class]] ? info[@"title"] : nil;
    if (!track && playingTitle)
        track = [self pendingTrackMatchingTitle:playingTitle];

    if (!track) {
        self.lastCapturedID = videoID;
        if (playingTitle && [self isKnownTitle:playingTitle]) {
            self.strayCount = 0; // other version of a song we already have
        } else {
            self.strayCount++;
            // Two songs in a row that aren't in the list: autoplay after the end
            if (self.strayCount >= 2 && self.pending.count < self.totalToDownload) {
                [self endCaptureListingMissing:YES];
                if ([player respondsToSelector:@selector(pause)])
                    [player performSelector:@selector(pause)];
                return;
            }
        }
        [self skipAheadInPlayer:player attempt:0];
        return;
    }
    self.strayCount = 0;

    if (!hls.length) {
        self.lastCapturedID = videoID;
        [self.pending removeObjectForKey:track.videoID];
        [self.pendingByTitle removeObjectForKey:YTMUTitleKey(track.title)];
    [self.pendingByNorm removeObjectForKey:YTMUNormTitle(track.title)];
        [self.failures addObject:[NSString stringWithFormat:@"%ld. %@ (no stream: %@)", (long)track.position, track.title, info[@"diag"] ?: @"?"]];
        [self afterCaptureInPlayer:player];
        return;
    }

    NSString *author = [info[@"author"] isKindOfClass:[NSString class]] ? info[@"author"] : nil;

    // Page title unknown: take album name + artist from the lock-screen info
    if (self.titleIsGuess) {
        self.titleIsGuess = NO;
        NSDictionary *nowPlaying = YTMUCurrentNowPlayingInfo();
        NSString *npAlbum = [nowPlaying[@"albumTitle"] isKindOfClass:[NSString class]] ? nowPlaying[@"albumTitle"] : nil;
        NSString *npArtist = [nowPlaying[@"artist"] isKindOfClass:[NSString class]] ? nowPlaying[@"artist"] : nil;
        if (npAlbum.length) {
            self.collectionTitle = npAlbum;
            self.folder = [self folderForTitle:npAlbum];
            [[NSFileManager defaultManager] createDirectoryAtURL:self.folder withIntermediateDirectories:YES attributes:nil error:nil];
            if (self.isAlbum && !self.albumArtist.length && npArtist.length)
                self.albumArtist = npArtist;
        }
    }

    if (!self.firstTrackCoverURL && self.isAlbum)
        self.firstTrackCoverURL = track.thumbnailURL;
    self.lastCapturedID = videoID;
    [self.pending removeObjectForKey:track.videoID];
    [self.pendingByTitle removeObjectForKey:YTMUTitleKey(track.title)];
    [self.pendingByNorm removeObjectForKey:YTMUNormTitle(track.title)];
    self.queuedCount++;

    dispatch_async(self.workQueue, ^{
        [self downloadTrack:track hlsManifest:hls author:author];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.queuedCount--;
            [self updateStatus];
            [self checkDone];
        });
    });

    [self afterCaptureInPlayer:player];
}

- (void)afterCaptureInPlayer:(id)player {
    if (self.pending.count == 0) {
        [self endCaptureListingMissing:NO];
        if ([player respondsToSelector:@selector(pause)])
            [player performSelector:@selector(pause)];
    } else {
        [self skipAheadInPlayer:player attempt:0];
    }
    [self updateStatus];
}

// Jumps to the song's last second so the player moves on to the next one
- (void)skipAheadInPlayer:(id)player attempt:(NSInteger)attempt {
    if (!self.capturing || ![player isKindOfClass:NSClassFromString(@"YTPlayerViewController")])
        return;

    YTPlayerViewController *playerVC = player;
    CGFloat duration = [playerVC respondsToSelector:@selector(currentVideoTotalMediaTime)] ? playerVC.currentVideoTotalMediaTime : 0;
    if (duration > 3.0 && [playerVC respondsToSelector:@selector(seekToTime:)]) {
        self.lastActivity = [NSDate timeIntervalSinceReferenceDate];
        [playerVC seekToTime:duration - 1.0];
    } else if (attempt < 10) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self skipAheadInPlayer:player attempt:attempt + 1];
        });
    }
}

- (void)endCaptureListingMissing:(BOOL)listMissing {
    self.capturing = NO;
    [self.watchdog invalidate];
    self.watchdog = nil;
    if (listMissing) {
        NSArray *remaining = [self.pending.allValues sortedArrayUsingComparator:^NSComparisonResult(YTMUPlaylistTrack *a, YTMUPlaylistTrack *b) {
            return a.position < b.position ? NSOrderedAscending : (a.position > b.position ? NSOrderedDescending : NSOrderedSame);
        }];
        NSMutableArray<NSString *> *neverPlayed = [NSMutableArray array];
        for (YTMUPlaylistTrack *track in remaining) {
            [self.failures addObject:[NSString stringWithFormat:@"%ld. %@ (never played, probably unavailable)", (long)track.position, track.title]];
            [neverPlayed addObject:track.videoID];
        }
        // Remember them, so the start hint skips them next time
        if (neverPlayed.count) {
            dispatch_async(self.workQueue, ^{
                NSMutableSet *all = [NSMutableSet setWithArray:[self.index[@"_unavailable"] isKindOfClass:[NSArray class]] ? self.index[@"_unavailable"] : @[]];
                [all addObjectsFromArray:neverPlayed];
                self.index[@"_unavailable"] = all.allObjects;
                [self saveIndex:self.index inFolder:self.folder];
            });
        }
    }
    [self.pending removeAllObjects];
    [self updateStatus];
    [self checkDone];
}

- (void)stopByUser {
    self.cancelled = YES;
    self.capturing = NO;
    [self.watchdog invalidate];
    self.watchdog = nil;
    [self.pending removeAllObjects];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [MobileFFmpeg cancel];
    });
    [self checkDone];
}

- (void)checkDone {
    if (!self.running || self.capturing || self.queuedCount > 0)
        return;

    // Let the renumber pass finish (and save cover.png) before summing up
    NSString *coverURL = self.collectionCoverURL ?: self.albumCoverURL ?: self.firstTrackCoverURL;
    NSURL *folder = self.folder;
    dispatch_async(self.workQueue, ^{
        if (coverURL && folder && self.downloadedCount + self.skippedCount > 0) {
            UIImage *cover = [UIImage imageWithData:YTMUGet(coverURL)];
            NSData *png = cover ? UIImagePNGRepresentation(cover) : nil;
            [png writeToURL:[folder URLByAppendingPathComponent:@"cover.png"] atomically:YES];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!self.running || self.capturing || self.queuedCount > 0)
                return;

            NSMutableString *summary = [NSMutableString stringWithFormat:@"%lu downloaded · %lu already there", (unsigned long)self.downloadedCount, (unsigned long)self.skippedCount];
            if (self.movedCount)
                [summary appendFormat:@" (%lu renumbered)", (unsigned long)self.movedCount];
            [summary appendFormat:@" · %lu failed", (unsigned long)self.failures.count];
            if (self.failures.count) {
                [UIPasteboard generalPasteboard].string = [self.failures componentsJoinedByString:@"\n"];
                [summary appendString:@"\nFailed songs copied to clipboard"];
            }
            BOOL stopped = self.cancelled;
            [self finishWithMessage:stopped ? @"Stopped" : LOC(@"DONE") details:summary icon:stopped ? @"xmark" : @"checkmark"];
        });
    });
}

#pragma mark Download one song (work queue)

- (void)addFailure:(NSString *)text {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.failures addObject:text];
    });
}

- (void)downloadTrack:(YTMUPlaylistTrack *)track hlsManifest:(NSString *)hls author:(NSString *)author {
    if (self.cancelled)
        return;

    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *title = self.collectionTitle;

    NSString *audioURL = YTMUAudioURLFromManifest(YTMUGet(hls));
    if (!audioURL) {
        [self addFailure:[NSString stringWithFormat:@"%ld. %@ (no audio in stream)", (long)track.position, track.title]];
        return;
    }

    // Metadata
    //   playlist: album + album artist = playlist name
    //   album:    album = album name, album artist = album's artist, year
    NSString *artist = track.artist.length ? track.artist : nil;
    if (!artist.length && self.isAlbum)
        artist = self.albumArtist;
    if (!artist.length)
        artist = author;
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

    // Download (no re-encoding)
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
    if (returnCode != RETURN_CODE_SUCCESS) {
        [fm removeItemAtPath:tempPath error:nil];
        if (returnCode != RETURN_CODE_CANCEL && !self.cancelled)
            [self addFailure:[NSString stringWithFormat:@"%ld. %@ (ffmpeg error %d)", (long)track.position, track.title, returnCode]];
        return;
    }

    // Cover: album cover for albums, else the song's own artwork
    NSString *coverURL = (self.isAlbum && self.albumCoverURL) ? self.albumCoverURL : track.thumbnailURL;
    UIImage *coverImage = coverURL ? [UIImage imageWithData:YTMUGet(coverURL)] : nil;
    NSData *jpeg = coverImage ? UIImageJPEGRepresentation(coverImage, 0.92) : nil;

    NSString *finishedPath = tempPath;
    if ([self.format isEqualToString:@"mp3"]) {
        // Convert to MP3 (LAME) with ID3 tags + cover
        NSString *mp3Path = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.mp3", track.videoID]];
        NSString *error = [YTMUMP3Encoder convertFile:[NSURL fileURLWithPath:tempPath]
                                                toMP3:[NSURL fileURLWithPath:mp3Path]
                                             metadata:metadata
                                            coverJPEG:jpeg];
        [fm removeItemAtPath:tempPath error:nil];
        if (error) {
            [fm removeItemAtPath:mp3Path error:nil];
            [self addFailure:[NSString stringWithFormat:@"%ld. %@ (mp3: %@)", (long)track.position, track.title, error]];
            return;
        }
        finishedPath = mp3Path;
    } else if (jpeg) {
        [self.coverWriter writeCoverAtom:jpeg intoFile:[NSURL fileURLWithPath:tempPath]];
    }

    // Into the playlist folder
    NSString *fileName = [self fileNameForTrack:track];
    NSURL *finalURL = [self.folder URLByAppendingPathComponent:fileName];
    [fm removeItemAtURL:finalURL error:nil];
    if (![fm moveItemAtURL:[NSURL fileURLWithPath:finishedPath] toURL:finalURL error:nil]) {
        [fm removeItemAtPath:finishedPath error:nil];
        [self addFailure:[NSString stringWithFormat:@"%ld. %@ (couldn't save file)", (long)track.position, track.title]];
        return;
    }

    self.index[[self indexKeyForVideoID:track.videoID]] = [@{@"file": fileName, @"position": @(track.position)} mutableCopy];
    [self saveIndex:self.index inFolder:self.folder];

    dispatch_async(dispatch_get_main_queue(), ^{
        self.downloadedCount++;
    });
}

@end
