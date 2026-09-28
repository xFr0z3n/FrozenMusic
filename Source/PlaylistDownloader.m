#import "PlaylistDownloader.h"
#import "FFMpegDownloader.h"
#import "MP3Encoder.h"
#import "Offline/YTMULyrics.h"
#import "Offline/YTMUOfflinePlayer.h"
#import "Offline/YTMUDownloadPanel.h"
#import "Offline/YTMUOfflineUI.h"
#import "Headers/YTPlayerViewController.h"
#import <sys/utsname.h>
#import <objc/message.h>

#pragma mark - YTM's Next button

static UIViewController *YTMUFindNowPlayingScreen(UIViewController *vc, Class nowPlayingClass, NSUInteger depth) {
    if (!vc || depth > 14)
        return nil;
    if ([vc isKindOfClass:nowPlayingClass])
        return vc;
    for (UIViewController *child in vc.childViewControllers) {
        UIViewController *found = YTMUFindNowPlayingScreen(child, nowPlayingClass, depth + 1);
        if (found)
            return found;
    }
    return YTMUFindNowPlayingScreen(vc.presentedViewController, nowPlayingClass, depth + 1);
}

// Same as tapping Next in YTM's player (the Now Playing screen exists even when collapsed)
static BOOL YTMUTapAppNextButton(void) {
    Class nowPlayingClass = NSClassFromString(@"YTMNowPlayingViewController");
    SEL nextSelector = NSSelectorFromString(@"didTapNextButton");
    if (!nowPlayingClass)
        return NO;
    for (UIWindow *window in [UIApplication sharedApplication].windows) {
        UIViewController *nowPlaying = YTMUFindNowPlayingScreen(window.rootViewController, nowPlayingClass, 0);
        if (nowPlaying && [nowPlaying respondsToSelector:nextSelector]) {
            ((void (*)(id, SEL))objc_msgSend)(nowPlaying, nextSelector);
            return YES;
        }
    }
    return NO;
}

#pragma mark - Track model

@interface YTMUPlaylistTrack : NSObject
@property (nonatomic) NSInteger position;
@property (nonatomic, copy) NSString *videoID;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *artist;
@property (nonatomic, copy) NSString *thumbnailURL;
@property (nonatomic, copy) NSString *album; // 3rd column in the web track list
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
@property (nonatomic, weak) YTMUDownloadPanel *hud; // the downloader's box on screen
@property (nonatomic, copy) NSArray<NSString *> *steps; // what this run does, in order
@property (nonatomic) BOOL askingStop;                  // stop question is on screen
@property (atomic, copy) NSString *skippedStep;         // step the user skipped
@property (nonatomic, copy) NSString *buttonsKey;       // which buttons the top box shows
@property (nonatomic, strong) NSMutableSet<NSString *> *lapSeen; // songs we have, played since the last new one
@property (atomic) BOOL listIncomplete;                 // song list didn't load completely: nothing is removed
@property (atomic, copy) NSDictionary<NSString *, NSNumber *> *slotTitles; // greyed-out songs of the list: file title -> place
@property (atomic) NSUInteger removedCount;             // songs no longer in the list, removed from the folder
@property (nonatomic, copy) NSArray<YTMUPlaylistTrack *> *listTracks; // the list as it is now, in order
@property (nonatomic, strong) NSOperationQueue *downloadOps;  // songs downloading at the same time
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSData *> *coverCache; // cover URL -> JPEG
@property (nonatomic, copy) NSString *statusTitle, *statusStep, *statusDetails;
@property (nonatomic) float statusProgress;
@property (nonatomic, strong) dispatch_queue_t workQueue;
@property (nonatomic) UIBackgroundTaskIdentifier backgroundTask;
@property (nonatomic, copy) NSString *deviceModel;
@property (nonatomic, copy) NSString *systemVersion;
@property (nonatomic, copy) NSString *appVersion;
// Filled while loading: album pages get real album tags, playlists use the playlist name
@property (nonatomic) BOOL isAlbum;
@property (nonatomic, copy) NSString *albumArtist;
@property (nonatomic, copy) NSString *artistChannelID; // albums: first song's artist (UC...), for creator.png
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
@property (nonatomic) BOOL finishingUp; // final pass (lyrics, cover) running
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
@property (nonatomic) NSUInteger activationCount; // song changes seen (Next-button fallback)
@property (nonatomic, copy) NSString *collectionCoverURL; // playlist / album cover for cover.png
@property (nonatomic, copy) NSString *firstTrackCoverURL; // album fallback
@property (nonatomic, copy) NSString *collectionDetails;  // page description
@property (nonatomic, copy) NSString *creatorName;        // playlist owner / album artist
@property (nonatomic, copy) NSString *creatorImageURL;
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
    self.askingStop = NO;
    [YTMUDownloadPanel showMessage:title details:details symbol:iconName];
    self.hud = nil;
}

// Box in the middle while loading (with Cancel)
- (void)showProgress:(NSString *)title details:(NSString *)details progress:(float)progress {
    YTMUDownloadPanel *panel = self.hud;
    if (!panel || panel.atTop || panel != [YTMUDownloadPanel current]) {
        panel = [YTMUDownloadPanel showCentered];
        __weak __typeof(self) weakSelf = self;
        panel.buttons = @[[YTMUPanelButton buttonWithTitle:LOC(@"CANCEL") style:YTMUPanelButtonSecondary handler:^{
            [weakSelf cancelPressed:nil];
        }]];
        self.hud = panel;
    }
    panel.step = nil;
    panel.title = title;
    panel.details = details;
    panel.progress = progress;
}

// "Step 2 of 4 · Downloading"
- (NSString *)stepText:(NSString *)name {
    NSUInteger index = [self.steps indexOfObject:name];
    if (index == NSNotFound || self.steps.count < 2)
        return name;
    return [NSString stringWithFormat:@"Step %lu of %lu · %@", (unsigned long)index + 1, (unsigned long)self.steps.count, name];
}

// Small box at the top: the page below stays usable (so you can press Play), Stop in the box
- (void)showStatus:(NSString *)title step:(NSString *)step details:(NSString *)details progress:(float)progress {
    self.statusTitle = title;
    self.statusStep = step;
    self.statusDetails = details;
    self.statusProgress = progress;
    // Stopping: only the "Stopping…" box (step nil) until the summary
    if (self.askingStop || (self.cancelled && step))
        return;
    YTMUDownloadPanel *panel = self.hud;
    BOOL fresh = NO;
    if (!panel || !panel.atTop || panel != [YTMUDownloadPanel current]) {
        panel = [YTMUDownloadPanel showAtTop];
        self.hud = panel;
        fresh = YES;
    }
    // Downloading and Lyrics can be skipped (e.g. songs that won't play), Stop always
    BOOL canSkip = !self.cancelled && ([step isEqualToString:@"Downloading"] || [step isEqualToString:@"Lyrics"]) && ![step isEqualToString:self.skippedStep];
    NSString *key = self.cancelled ? @"none" : (canSkip ? @"skip" : @"stop");
    if (fresh || ![key isEqualToString:self.buttonsKey]) {
        self.buttonsKey = key;
        __weak __typeof(self) weakSelf = self;
        NSMutableArray<YTMUPanelButton *> *buttons = [NSMutableArray array];
        if (canSkip) {
            [buttons addObject:[YTMUPanelButton buttonWithTitle:@"Skip step" style:YTMUPanelButtonSecondary handler:^{
                [weakSelf skipStep];
            }]];
        }
        if (!self.cancelled) {
            [buttons addObject:[YTMUPanelButton buttonWithTitle:@"Stop" style:YTMUPanelButtonDestructive handler:^{
                [weakSelf askToStop];
            }]];
        }
        panel.buttons = buttons;
    }
    panel.title = title;
    panel.step = [self stepText:step];
    panel.details = details;
    panel.progress = progress;
}

// Downloading: the songs that didn't come yet are left out (e.g. not playable).
// Lyrics: the songs not checked yet keep the lyrics they have.
- (void)skipStep {
    if (!self.running || self.cancelled)
        return;
    NSString *step = self.statusStep;
    if ([step isEqualToString:@"Downloading"] && self.capturing) {
        self.skippedStep = step;
        id player = self.lastPlayer;
        [self endCaptureListingMissing:NO skipped:YES];
        if ([player respondsToSelector:@selector(pause)])
            [player performSelector:@selector(pause)];
    } else if ([step isEqualToString:@"Lyrics"]) {
        self.skippedStep = step;
        [self showStatus:self.statusTitle step:step details:@"Skipping the rest…" progress:self.statusProgress];
    }
}

- (void)askToStop {
    // Loading / choosing the format: that box has its own Cancel
    if (!self.running || self.cancelled || !self.steps)
        return;
    self.askingStop = YES;
    YTMUDownloadPanel *panel = [YTMUDownloadPanel showCentered];
    panel.title = self.isAlbum ? @"Stop the album download?" : @"Stop the playlist download?";
    panel.details = @"Everything stops right away. Songs saved so far are kept.";
    __weak __typeof(self) weakSelf = self;
    panel.buttons = @[
        [YTMUPanelButton buttonWithTitle:@"Stop" style:YTMUPanelButtonDestructive handler:^{
            weakSelf.askingStop = NO;
            [weakSelf stopByUser];
        }],
        [YTMUPanelButton buttonWithTitle:@"Keep going" style:YTMUPanelButtonSecondary handler:^{
            __strong __typeof(weakSelf) strongSelf = weakSelf;
            strongSelf.askingStop = NO;
            if (!strongSelf.running) {
                [YTMUDownloadPanel dismissCurrent];
                return;
            }
            strongSelf.hud = nil;
            [strongSelf showStatus:strongSelf.statusTitle step:strongSelf.statusStep details:strongSelf.statusDetails progress:strongSelf.statusProgress];
        }],
    ];
    self.hud = panel;
}

- (void)cancelPressed:(UIButton *)sender {
    self.cancelled = YES;
    self.hud.details = @"Stopping…";
    self.hud.buttons = @[];
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
        [self askToStop];
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
    self.askingStop = NO;
    self.steps = nil;
    self.skippedStep = nil;
    self.buttonsKey = nil;
    self.isAlbum = [browseID hasPrefix:@"MPREb_"] || [browseID hasPrefix:@"VLOLAK5uy_"];
    self.albumArtist = nil;
    self.albumYear = nil;
    self.albumCoverURL = nil;
    self.collectionCoverURL = nil;
    self.firstTrackCoverURL = nil;
    self.collectionDetails = nil;
    self.creatorName = nil;
    self.creatorImageURL = nil;
    self.artistChannelID = nil;

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
            // The page itself is the most reliable source for albums
            NSString *pageTitle = [self pageHeading];
            NSString *finalTitle = (self.isAlbum && pageTitle.length) ? pageTitle : title;
            if (!finalTitle.length)
                finalTitle = [self titleFromPageTextsExcluding:tracks];
            if (self.isAlbum)
                [self fillAlbumInfoFromPageTexts];
            if (!self.creatorName.length)
                self.creatorName = self.isAlbum ? self.albumArtist : [self pageCreatorFromTexts];
            self.titleIsGuess = finalTitle.length == 0;
            [self confirmDownloadOfTracks:tracks title:finalTitle.length ? finalTitle : (self.isAlbum ? @"Album" : @"Playlist")];
        });
    });
}

- (void)finishWithMessage:(NSString *)title details:(NSString *)details icon:(NSString *)icon {
    [self endKeepAlive];
    self.running = NO;
    [self showMessage:title details:details icon:icon];
}

#pragma mark Title fallback from the page

// Creator from the page texts: albums show the artist above the title,
// playlists show the owner below it
- (BOOL)isCreatorCandidate:(NSString *)label {
    if (label.length < 2 || label.length > 60 || [label containsString:@"•"])
        return NO;
    NSString *lower = label.lowercaseString;
    for (NSString *prefix in @[@"edit", @"download", @"play", @"shuffle", @"save", @"more", @"share", @"view", @"action", @"add ", @"resume", @"back", @"search"]) {
        if ([lower hasPrefix:prefix])
            return NO;
    }
    for (NSString *word in @[@"views", @"songs", @"tracks", @"comments", @"hrs", @"mins", @"ago", @"public", @"private", @"unlisted"]) {
        if ([lower containsString:word])
            return NO;
    }
    return YES;
}

- (NSString *)pageCreatorFromTexts {
    NSUInteger headingIndex = NSNotFound;
    for (NSUInteger i = 0; i < self.pageTexts.count; i++) {
        if ([self.pageTexts[i][@"header"] boolValue]) {
            headingIndex = i;
            break;
        }
    }
    if (headingIndex == NSNotFound)
        return nil;

    // Playlists: first real label after the title ("Fr0z3n")
    for (NSUInteger i = headingIndex + 1; i < self.pageTexts.count; i++) {
        NSString *label = self.pageTexts[i][@"label"];
        if ([self isCreatorCandidate:label])
            return label;
    }
    return nil;
}

- (NSString *)pageHeading {
    for (NSDictionary *text in self.pageTexts) {
        NSString *label = text[@"label"];
        if ([text[@"header"] boolValue] && ![text[@"button"] boolValue] && label.length)
            return label;
    }
    return nil;
}

// Album page header reads like: "Yeat" (artist button), "90 comments • 2026", "COCOON" (heading)
- (void)fillAlbumInfoFromPageTexts {
    NSUInteger headingIndex = NSNotFound;
    for (NSUInteger i = 0; i < self.pageTexts.count; i++) {
        if ([self.pageTexts[i][@"header"] boolValue]) {
            headingIndex = i;
            break;
        }
    }

    if (!self.albumArtist.length && headingIndex != NSNotFound) {
        for (NSUInteger i = 0; i < headingIndex; i++) {
            NSDictionary *text = self.pageTexts[i];
            NSString *label = text[@"label"];
            if ([text[@"button"] boolValue] && label.length && label.length < 60 && ![label containsString:@"•"]) {
                self.albumArtist = label;
                break;
            }
        }
    }

    if (!self.albumYear.length) {
        NSRegularExpression *yearRegex = [NSRegularExpression regularExpressionWithPattern:@"\\b(19|20)\\d{2}\\b" options:0 error:nil];
        for (NSDictionary *text in self.pageTexts) {
            NSString *label = text[@"label"];
            if (![label containsString:@"•"])
                continue;
            NSTextCheckingResult *match = [yearRegex firstMatchInString:label options:0 range:NSMakeRange(0, label.length)];
            if (match) {
                self.albumYear = [label substringWithRange:match.range];
                break;
            }
        }
    }
}

- (NSString *)titleFromPageTextsExcluding:(NSArray<YTMUPlaylistTrack *> *)tracks {
    NSMutableSet<NSString *> *exclude = [NSMutableSet set];
    for (YTMUPlaylistTrack *track in tracks) {
        if (track.title)
            [exclude addObject:track.title.lowercaseString];
        if (track.artist)
            [exclude addObject:track.artist.lowercaseString];
    }
    NSArray *noise = @[@"download", @"play", @"shuffle", @"save", @"more", @"comments", @"share", @"edit", @"back", @"search", @"add a song", @"library", @"home", @"samples", @"downloads"];

    // 1. Something marked as a heading (also when a song has the same name)
    for (NSDictionary *text in self.pageTexts) {
        NSString *label = text[@"label"];
        if ([text[@"header"] boolValue] && ![text[@"button"] boolValue] && label.length)
            return label;
    }
    // 2. First plain text that isn't a button, a stats line or a song on the page
    for (NSDictionary *text in self.pageTexts) {
        NSString *label = text[@"label"];
        NSString *lower = label.lowercaseString;
        if ([text[@"button"] boolValue] || label.length < 2 || label.length > 120)
            continue;
        if ([label containsString:@"•"] || [label containsString:@"\n"] || [exclude containsObject:lower])
            continue;
        BOOL isNoise = NO;
        for (NSString *word in noise) {
            if ([lower isEqualToString:word] || [lower hasPrefix:[word stringByAppendingString:@" "]])
                isNoise = YES;
        }
        if (!isNoise && self.albumArtist.length && [lower isEqualToString:self.albumArtist.lowercaseString])
            isNoise = YES;
        if (!isNoise)
            return label;
    }
    return nil;
}

#pragma mark Playlist fetching (InnerTube web API)

// Artist page picture (round avatar if there is one, else the header image)
- (NSString *)artistImageURLForChannel:(NSString *)channelID {
    NSString *baseURL = @"https://music.youtube.com/youtubei/v1/browse?prettyPrint=false";
    NSDictionary *response = YTMUPostJSON(baseURL, @{@"context": [self webContext], @"browseId": channelID}, [self webHeaders]);
    if (!response)
        return nil;
    for (NSString *key in @[@"foregroundThumbnail", @"thumbnail"]) {
        for (NSString *headerKey in @[@"musicVisualHeaderRenderer", @"musicImmersiveHeaderRenderer", @"musicResponsiveHeaderRenderer"]) {
            id header = YTMUFindFirst(response, headerKey);
            NSArray *thumbs = YTMUFindFirst(YTMUFindFirst(header, key), @"thumbnails");
            NSString *url = [thumbs isKindOfClass:[NSArray class]] ? YTMUPath(thumbs, @[@-1, @"url"]) : nil;
            if ([url isKindOfClass:[NSString class]] && url.length)
                return YTMUBigThumbnail(url);
        }
    }
    return nil;
}

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

        // Creator (playlist owner / album artist) with its round picture
        NSString *strapline = YTMUText(YTMUFindFirst(header, @"straplineTextOne"));
        if (strapline.length && !self.creatorName.length)
            self.creatorName = strapline;
        NSArray *straplineThumbs = YTMUFindFirst(YTMUFindFirst(header, @"straplineThumbnail"), @"thumbnails");
        NSString *straplineURL = [straplineThumbs isKindOfClass:[NSArray class]] ? YTMUPath(straplineThumbs, @[@-1, @"url"]) : nil;
        if ([straplineURL isKindOfClass:[NSString class]] && !self.creatorImageURL)
            self.creatorImageURL = YTMUBigThumbnail(straplineURL);

        NSString *headerDetails = YTMUText(YTMUFindFirst(YTMUFindFirst(header, @"description"), @"description"))
                                  ?: YTMUText(YTMUFindFirst(header, @"description"));
        if (headerDetails.length && !self.collectionDetails.length)
            self.collectionDetails = headerDetails;

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

    // Newer header layout: creator in a "facepile" (avatar stack) with name + picture
    id avatarStack = YTMUFindFirst(response, @"avatarStackViewModel");
    if (avatarStack) {
        NSString *stackName = YTMUPath(avatarStack, @[@"text", @"content"]);
        if ([stackName isKindOfClass:[NSString class]] && stackName.length && !self.creatorName.length)
            self.creatorName = stackName;
        NSArray *sources = YTMUPath(avatarStack, @[@"avatars", @0, @"avatarViewModel", @"image", @"sources"]);
        NSString *avatarURL = [sources isKindOfClass:[NSArray class]] ? YTMUPath(sources, @[@-1, @"url"]) : nil;
        if ([avatarURL isKindOfClass:[NSString class]] && !self.creatorImageURL)
            self.creatorImageURL = YTMUBigThumbnail(avatarURL);
    }

    if (!self.collectionDetails.length) {
        NSString *metaDetails = YTMUPath(response, @[@"microformat", @"microformatDataRenderer", @"description"]);
        if ([metaDetails isKindOfClass:[NSString class]])
            self.collectionDetails = metaDetails;
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
    self.listIncomplete = NO;
    NSMutableDictionary<NSString *, NSNumber *> *slots = [NSMutableDictionary dictionary];

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
            NSArray *columns = item[@"flexColumns"];
            if (![videoID isKindOfClass:[NSString class]] || videoID.length == 0) {
                // Unavailable (greyed out) song: keeps its number slot, and a copy downloaded
                // earlier stays (it's still in the list)
                NSString *slotTitle = YTMUText(YTMUPath(columns, @[@0, @"musicResponsiveListItemFlexColumnRenderer", @"text"]));
                if (slotTitle.length)
                    slots[YTMUCleanName(slotTitle).lowercaseString] = @(position);
                continue;
            }

            YTMUPlaylistTrack *track = [YTMUPlaylistTrack new];
            track.position = position;
            track.videoID = videoID;
            track.title = YTMUText(YTMUPath(columns, @[@0, @"musicResponsiveListItemFlexColumnRenderer", @"text"])) ?: @"Unknown";
            track.artist = YTMUText(YTMUPath(columns, @[@1, @"musicResponsiveListItemFlexColumnRenderer", @"text"]));
            track.album = YTMUText(YTMUPath(columns, @[@2, @"musicResponsiveListItemFlexColumnRenderer", @"text"]));
            if (!self.artistChannelID) {
                NSString *channel = YTMUPath(columns, @[@1, @"musicResponsiveListItemFlexColumnRenderer", @"text", @"runs", @0, @"navigationEndpoint", @"browseEndpoint", @"browseId"]);
                if ([channel isKindOfClass:[NSString class]] && [channel hasPrefix:@"UC"])
                    self.artistChannelID = channel;
            }
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
            if (!next)
                next = YTMUPostJSON(baseURL, @{@"context": [self webContext], @"continuation": token}, [self webHeaders]);
            if (!next)
                self.listIncomplete = YES; // more songs exist but didn't load
        } else {
            NSString *legacy = YTMUPath(YTMUFindFirst(scope, @"nextContinuationData"), @[@"continuation"]);
            if ([legacy isKindOfClass:[NSString class]]) {
                NSString *escaped = [legacy stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
                NSString *url = [NSString stringWithFormat:@"%@&ctoken=%@&continuation=%@&type=next", baseURL, escaped, escaped];
                next = YTMUPostJSON(url, @{@"context": [self webContext]}, [self webHeaders]);
                if (!next)
                    self.listIncomplete = YES;
            }
        }
        if (next && page == 199)
            self.listIncomplete = YES;
        scope = next;

        dispatch_async(dispatch_get_main_queue(), ^{
            self.hud.details = [NSString stringWithFormat:@"%lu songs found", (unsigned long)tracks.count];
        });
    }

    self.slotTitles = slots;

    // Album data without a header (album playlists): most common album / artist of its songs
    if (self.isAlbum && titleOut && !(*titleOut).length && tracks.count) {
        NSCountedSet<NSString *> *albums = [NSCountedSet set];
        NSCountedSet<NSString *> *artists = [NSCountedSet set];
        for (YTMUPlaylistTrack *track in tracks) {
            if (track.album.length)
                [albums addObject:track.album];
            if (track.artist.length)
                [artists addObject:track.artist];
        }
        NSString *bestAlbum = nil, *bestArtist = nil;
        for (NSString *album in albums) {
            if (!bestAlbum || [albums countForObject:album] > [albums countForObject:bestAlbum])
                bestAlbum = album;
        }
        for (NSString *artist in artists) {
            if (!bestArtist || [artists countForObject:artist] > [artists countForObject:bestArtist])
                bestArtist = artist;
        }
        if (bestAlbum.length)
            *titleOut = bestAlbum;
        if (!self.albumArtist.length && bestArtist.length)
            self.albumArtist = bestArtist;
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
    return [self fileNameForTrack:track format:self.format ?: @"m4a"];
}

- (NSString *)fileNameForTrack:(YTMUPlaylistTrack *)track format:(NSString *)format {
    return [NSString stringWithFormat:@"%ld. %@.%@", (long)track.position, YTMUCleanName(track.title), format];
}

// Video ID of an index key ("<id>" or "mp3:<id>"), nil for other keys ("_unavailable")
static NSString *YTMUVideoIDOfIndexKey(NSString *key) {
    if (![key isKindOfClass:[NSString class]] || [key hasPrefix:@"_"])
        return nil;
    return [key hasPrefix:@"mp3:"] ? [key substringFromIndex:4] : key;
}

// "12. Title (2).m4a" -> "title": to find a downloaded song among the list's greyed-out ones
static NSString *YTMUTitleOfFileName(NSString *fileName) {
    NSString *name = fileName.stringByDeletingPathExtension;
    NSRange dot = [name rangeOfString:@". "];
    if (dot.location != NSNotFound && dot.location > 0 && dot.location <= 5)
        name = [name substringFromIndex:NSMaxRange(dot)];
    NSRegularExpression *copyNumber = [NSRegularExpression regularExpressionWithPattern:@" \\(\\d+\\)$" options:0 error:nil];
    name = [copyNumber stringByReplacingMatchesInString:name options:0 range:NSMakeRange(0, name.length) withTemplate:@""];
    return name.lowercaseString;
}

// Place of a downloaded song that is greyed out in the list now (0 = not one of them)
- (NSInteger)slotOfFileName:(NSString *)fileName {
    return [self.slotTitles[YTMUTitleOfFileName(fileName)] integerValue];
}

// Downloaded songs (both formats) that are no longer in the list
- (NSArray<NSString *> *)indexKeysNotInList:(NSArray<YTMUPlaylistTrack *> *)tracks index:(NSDictionary *)index folder:(NSURL *)folder {
    NSMutableSet<NSString *> *ids = [NSMutableSet set];
    for (YTMUPlaylistTrack *track in tracks)
        [ids addObject:track.videoID];
    NSMutableArray<NSString *> *keys = [NSMutableArray array];
    for (NSString *key in index) {
        NSString *videoID = YTMUVideoIDOfIndexKey(key);
        NSDictionary *entry = index[key];
        if (!videoID || [ids containsObject:videoID] || ![entry isKindOfClass:[NSDictionary class]] || ![entry[@"file"] isKindOfClass:[NSString class]])
            continue;
        if ([self slotOfFileName:entry[@"file"]] > 0)
            continue; // greyed out, but still in the list
        if ([[NSFileManager defaultManager] fileExistsAtPath:[folder URLByAppendingPathComponent:entry[@"file"]].path])
            [keys addObject:key];
    }
    return keys;
}

#pragma mark Confirm

- (void)confirmDownloadOfTracks:(NSArray<YTMUPlaylistTrack *> *)tracks title:(NSString *)title {
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

    NSMutableString *message = [NSMutableString stringWithFormat:@"Already downloaded: %lu as .m4a, %lu as .mp3", (unsigned long)existingM4A, (unsigned long)existingMP3];
    if (unavailable)
        [message appendFormat:@"\n%lu weren't playable last time", (unsigned long)unavailable];
    NSUInteger removals = self.listIncomplete ? 0 : [self indexKeysNotInList:tracks index:index folder:folder].count;
    if (removals)
        [message appendFormat:@"\n%lu no longer in the %@ (removed from the folder)", (unsigned long)removals, self.isAlbum ? @"album" : @"playlist"];
    if (self.listIncomplete)
        [message appendString:@"\nNot every song could be loaded: songs are only added and reordered this time"];
    [message appendString:@"\n\n.m4a: original quality, fastest\n.mp3: converted (~190 kbps), a few seconds more per song"];
    [message appendString:@"\n\nAfter you confirm, press Play on this page: the player jumps through the songs while they download. Keep YouTube Music open (tip: mute your phone). The folder follows the list's current order."];
    [message appendFormat:@"\n\nFiles › YouTube Music › YTMusicUltimate › %@", YTMUCleanName(title)];

    NSUInteger missingM4A = tracks.count - existingM4A;
    NSUInteger missingMP3 = tracks.count - existingMP3;
    NSString *m4aTitle = missingM4A ? [NSString stringWithFormat:@"Download %lu as .m4a", (unsigned long)missingM4A] : @"Update .m4a";
    NSString *mp3Title = missingMP3 ? [NSString stringWithFormat:@"Download %lu as .mp3", (unsigned long)missingMP3] : @"Update .mp3";

    YTMUDownloadPanel *panel = [YTMUDownloadPanel showCentered];
    panel.step = [NSString stringWithFormat:@"%@ · %lu songs", self.isAlbum ? @"Album" : @"Playlist", (unsigned long)tracks.count];
    panel.title = title;
    panel.details = message;
    __weak __typeof(self) weakSelf = self;
    panel.buttons = @[
        [YTMUPanelButton buttonWithTitle:m4aTitle style:YTMUPanelButtonPrimary handler:^{
            weakSelf.format = @"m4a";
            [weakSelf beginCaptureOfTracks:tracks title:title];
        }],
        [YTMUPanelButton buttonWithTitle:mp3Title style:YTMUPanelButtonSecondary handler:^{
            weakSelf.format = @"mp3";
            [weakSelf beginCaptureOfTracks:tracks title:title];
        }],
        [YTMUPanelButton buttonWithTitle:LOC(@"CANCEL") style:YTMUPanelButtonPlain handler:^{
            [weakSelf finishWithMessage:@"Cancelled" details:nil icon:@"xmark"];
        }],
    ];
    self.hud = panel;
}

#pragma mark Capture mode

- (void)beginCaptureOfTracks:(NSArray<YTMUPlaylistTrack *> *)tracks title:(NSString *)title {
    if (self.steps || !self.running)
        return;
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
    self.lapSeen = [NSMutableSet set];
    self.finishingUp = NO;
    self.lastCapturedID = nil;

    self.pendingByTitle = [NSMutableDictionary dictionary];
    self.pendingByNorm = [NSMutableDictionary dictionary];
    self.strayCount = 0;
    self.sawActivation = NO;

    NSMutableSet<NSString *> *allIDs = [NSMutableSet set];
    NSMutableSet<NSString *> *titles = [NSMutableSet set];
    NSMutableSet<NSString *> *norms = [NSMutableSet set];
    for (YTMUPlaylistTrack *track in tracks) {
        [allIDs addObject:track.videoID];
        NSString *titleKey = YTMUTitleKey(track.title);
        NSString *normKey = YTMUNormTitle(track.title);
        [titles addObject:titleKey];
        if (normKey.length)
            [norms addObject:normKey];
        if ([self isTrackDownloaded:track index:self.index folder:self.folder]) {
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
    self.listTracks = tracks;
    self.removedCount = 0;
    self.coverCache = [NSMutableDictionary dictionary];
    self.downloadOps = [NSOperationQueue new];
    self.downloadOps.maxConcurrentOperationCount = 3;
    self.downloadOps.qualityOfService = NSQualityOfServiceUserInitiated;
    BOOL hasSongs = NO;
    for (NSString *key in self.index) {
        if (YTMUVideoIDOfIndexKey(key)) {
            hasSongs = YES;
            break;
        }
    }

    // What this run does, shown step by step
    NSMutableArray<NSString *> *steps = [NSMutableArray array];
    if (hasSongs)
        [steps addObject:@"Checking songs"];
    if (self.pending.count)
        [steps addObject:@"Downloading"];
    [steps addObject:@"Lyrics"];
    [steps addObject:@"Cover & info"];
    self.steps = steps;

    [self beginKeepAlive];
    [MobileFFmpegConfig setStatisticsDelegate:nil];

    if (!hasSongs) {
        [self startCaptureOrFinish];
        return;
    }
    // Songs that are already there first: the folder is brought to the list's current order
    // (renamed + renumbered), songs no longer in the list are removed
    [self showStatus:[self statusTitleWith:nil] step:@"Checking songs" details:@"Checking the songs you have…" progress:0];
    dispatch_async(self.workQueue, ^{
        [self syncFolderWithList:tracks];
        NSUInteger moved = self.movedCount, removed = self.removedCount, have = self.skippedCount;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!self.running || self.cancelled)
                return;
            NSMutableString *result = [NSMutableString stringWithFormat:@"%lu songs there", (unsigned long)have];
            if (moved)
                [result appendFormat:@" · %lu moved", (unsigned long)moved];
            if (removed)
                [result appendFormat:@" · %lu removed", (unsigned long)removed];
            if (!moved && !removed)
                [result appendString:@" · order matches"];
            [self showStatus:[self statusTitleWith:nil] step:@"Checking songs" details:result progress:1];
            // Long enough to read it
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.7 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (self.running && !self.cancelled)
                    [self startCaptureOrFinish];
            });
        });
    });
}

// "Playlist name · .m4a"
- (NSString *)statusTitleWith:(NSString *)suffix {
    NSString *title = [NSString stringWithFormat:@"%@ · .%@", self.collectionTitle ?: @"", self.format ?: @"m4a"];
    return suffix.length ? [title stringByAppendingFormat:@" · %@", suffix] : title;
}

- (void)startCaptureOrFinish {
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

// Work queue. Makes the folder match the list 1:1: every downloaded song (.m4a and .mp3) gets
// the name and track number of its current place, songs no longer in the list are removed.
// Two passes (all moving files to temporary names first), so songs can swap places freely.
- (void)syncFolderWithList:(NSArray<YTMUPlaylistTrack *> *)tracks {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSURL *folder = self.folder;
    NSMutableDictionary<NSString *, YTMUPlaylistTrack *> *byID = [NSMutableDictionary dictionary];
    for (YTMUPlaylistTrack *track in tracks) {
        if (!byID[track.videoID])
            byID[track.videoID] = track;
    }
    BOOL changed = NO;

    // Songs no longer in the list (only when the whole list loaded)
    if (!self.listIncomplete) {
        for (NSString *key in [self indexKeysNotInList:tracks index:self.index folder:folder]) {
            if (self.cancelled)
                break;
            NSURL *url = [folder URLByAppendingPathComponent:self.index[key][@"file"]];
            if ([fm removeItemAtURL:url error:nil]) {
                YTMUDeleteLyrics(url);
                [self.index removeObjectForKey:key];
                self.removedCount++;
                changed = YES;
            }
        }
    }

    // Entries whose file is gone are forgotten (downloaded again)
    NSMutableArray<NSDictionary *> *moves = [NSMutableArray array];
    NSArray<NSString *> *keys = [self.index.allKeys copy];
    NSUInteger checked = 0;
    NSTimeInterval lastReport = 0;
    for (NSString *key in keys) {
        if (self.cancelled)
            break;
        NSString *videoID = YTMUVideoIDOfIndexKey(key);
        NSDictionary *entry = self.index[key];
        if (!videoID || ![entry isKindOfClass:[NSDictionary class]])
            continue;
        checked++;
        NSString *file = [entry[@"file"] isKindOfClass:[NSString class]] ? entry[@"file"] : nil;
        NSURL *url = file ? [folder URLByAppendingPathComponent:file] : nil;
        if (!url || ![fm fileExistsAtPath:url.path]) {
            [self.index removeObjectForKey:key];
            changed = YES;
            continue;
        }
        YTMUPlaylistTrack *track = byID[videoID];
        NSInteger slot = track ? 0 : [self slotOfFileName:file];
        if (!track && slot > 0) {
            // Greyed out in the list: keeps its file, moves with its place
            track = [YTMUPlaylistTrack new];
            track.videoID = videoID;
            track.position = slot;
            NSString *title = file.stringByDeletingPathExtension;
            NSRange dot = [title rangeOfString:@". "];
            track.title = (dot.location != NSNotFound && dot.location <= 5) ? [title substringFromIndex:NSMaxRange(dot)] : title;
        }
        if (!track)
            continue; // not in the (incompletely loaded) list: left as it is
        NSString *format = [key hasPrefix:@"mp3:"] ? @"mp3" : @"m4a";
        NSString *wanted = [self fileNameForTrack:track format:format];
        if (![wanted isEqualToString:file] || [entry[@"position"] integerValue] != track.position)
            [moves addObject:@{@"key": key, @"track": track, @"from": url, @"name": wanted, @"format": format}];

        NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
        if (now - lastReport > 0.1) {
            lastReport = now;
            NSUInteger checkedNow = checked, total = keys.count;
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!self.running || self.cancelled || self.capturing)
                    return;
                [self showStatus:[self statusTitleWith:nil] step:@"Checking songs"
                         details:[NSString stringWithFormat:@"%lu songs checked", (unsigned long)checkedNow]
                        progress:total ? MIN(1.f, (float)checkedNow / (float)total) * 0.5f : 0];
            });
        }
    }

    // Pass 1: out of the way (temporary names)
    NSMutableArray<NSDictionary *> *parked = [NSMutableArray array];
    for (NSDictionary *move in moves) {
        if (self.cancelled)
            break;
        NSURL *from = move[@"from"];
        NSURL *temp = [folder URLByAppendingPathComponent:[NSString stringWithFormat:@".ytmu-move-%@.%@", [NSUUID UUID].UUIDString, move[@"format"]]];
        if ([fm moveItemAtURL:from toURL:temp error:nil]) {
            YTMUMoveLyrics(from, temp);
            NSMutableDictionary *parkedMove = [move mutableCopy];
            parkedMove[@"temp"] = temp;
            [parked addObject:parkedMove];
        }
    }
    // Pass 2: final names + track numbers (runs even when stopped, so nothing stays parked)
    NSUInteger done = 0;
    for (NSDictionary *move in parked) {
        YTMUPlaylistTrack *track = move[@"track"];
        NSString *key = move[@"key"];
        NSURL *temp = move[@"temp"];
        NSString *name = move[@"name"];
        NSURL *target = [folder URLByAppendingPathComponent:name];
        // A file that isn't one of ours has the name: keep both
        for (NSUInteger n = 2; [fm fileExistsAtPath:target.path] && n < 100; n++) {
            name = [NSString stringWithFormat:@"%@ (%lu).%@", name.stringByDeletingPathExtension, (unsigned long)n, move[@"format"]];
            target = [folder URLByAppendingPathComponent:name];
        }
        if (![fm moveItemAtURL:temp toURL:target error:nil])
            continue;
        YTMUMoveLyrics(temp, target);
        if ([move[@"format"] isEqualToString:@"mp3"])
            YTMUPatchMP3TrackNumber(target, track.position);
        else
            YTMUPatchTrackNumber(target, track.position);
        NSMutableDictionary *entry = [self.index[key] mutableCopy];
        entry[@"file"] = name;
        entry[@"position"] = @(track.position);
        self.index[key] = entry;
        self.movedCount++;
        changed = YES;
        done++;
        NSUInteger doneNow = done, total = parked.count;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!self.running || self.cancelled || self.capturing)
                return;
            [self showStatus:[self statusTitleWith:nil] step:@"Checking songs"
                     details:[NSString stringWithFormat:@"Reordering %lu / %lu", (unsigned long)doneNow, (unsigned long)total]
                    progress:0.5f + 0.5f * (float)doneNow / (float)total];
        });
    }
    if (changed)
        [self saveIndex:self.index inFolder:folder];
    // The Downloads tab shows the list's order again (not an old order from Edit)
    YTMUClearSavedOrder(YTMUTrackOrderKey(folder));
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
            details = [details stringByAppendingFormat:@"\nSaving the last %lu %@…", (unsigned long)self.queuedCount, self.queuedCount == 1 ? @"song" : @"songs"];
    }

    [self showStatus:[self statusTitleWith:nil] step:@"Downloading" details:details progress:total ? (float)finished / (float)total : 0];
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
        self.activationCount++;
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
            if (![self endLapIfRepeated:videoID player:player])
                [self skipAheadInPlayer:player attempt:0];
            return;
        }

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self capturePlayer:player video:video attempt:0];
        });
    });
}

// A song we already have is playing. Seen before since the last new song = the player went
// all the way round (the missing ones don't play, e.g. unavailable) -> done instead of looping.
- (BOOL)endLapIfRepeated:(NSString *)videoID player:(id)player {
    if (!videoID)
        return NO;
    if (![self.lapSeen containsObject:videoID]) {
        [self.lapSeen addObject:videoID];
        return NO;
    }
    [self endCaptureListingMissing:YES];
    if ([player respondsToSelector:@selector(pause)])
        [player performSelector:@selector(pause)];
    return YES;
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
        if (![self endLapIfRepeated:videoID player:player])
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
            // (after at least one song of the list played)
            if (self.strayCount >= 2 && (self.pending.count < self.totalToDownload || self.lapSeen.count > 0)) {
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
    [self.lapSeen removeAllObjects]; // a new song: the lap starts over

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

    // Up to 3 songs download at the same time while the player moves on
    [self.downloadOps addOperationWithBlock:^{
        [self downloadTrack:track hlsManifest:hls author:author];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.queuedCount--;
            [self updateStatus];
            [self checkDone];
        });
    }];

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

// Moves the player on to the next song: YTM's own Next button first (instant, no
// stall), the old "seek to the last second" only if that didn't change the song
- (void)skipAheadInPlayer:(id)player attempt:(NSInteger)attempt {
    if (!self.capturing || ![player isKindOfClass:NSClassFromString(@"YTPlayerViewController")])
        return;

    NSString *before = [self videoIDOfPlayer:player];
    NSUInteger activations = self.activationCount;
    if (before && YTMUTapAppNextButton()) {
        self.lastActivity = [NSDate timeIntervalSinceReferenceDate];
        // Nothing happened (no Now Playing screen yet?): fall back to seeking
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (self.capturing && self.activationCount == activations && [[self videoIDOfPlayer:player] isEqualToString:before])
                [self seekToEndInPlayer:player attempt:0];
        });
        return;
    }
    [self seekToEndInPlayer:player attempt:attempt];
}

// Jumps to the song's last second so the player moves on to the next one
- (void)seekToEndInPlayer:(id)player attempt:(NSInteger)attempt {
    if (!self.capturing || ![player isKindOfClass:NSClassFromString(@"YTPlayerViewController")])
        return;

    YTPlayerViewController *playerVC = player;
    CGFloat duration = [playerVC respondsToSelector:@selector(currentVideoTotalMediaTime)] ? playerVC.currentVideoTotalMediaTime : 0;
    if (duration > 3.0 && [playerVC respondsToSelector:@selector(seekToTime:)]) {
        self.lastActivity = [NSDate timeIntervalSinceReferenceDate];
        [playerVC seekToTime:duration - 1.0];
    } else if (attempt < 10) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self seekToEndInPlayer:player attempt:attempt + 1];
        });
    }
}

- (void)endCaptureListingMissing:(BOOL)listMissing {
    [self endCaptureListingMissing:listMissing skipped:NO];
}

// skipped: the user skipped the rest (not remembered as unplayable)
- (void)endCaptureListingMissing:(BOOL)listMissing skipped:(BOOL)skipped {
    if (!self.capturing && !self.pending.count)
        return;
    self.capturing = NO;
    [self.watchdog invalidate];
    self.watchdog = nil;
    if (skipped) {
        NSArray *remaining = [self.pending.allValues sortedArrayUsingComparator:^NSComparisonResult(YTMUPlaylistTrack *a, YTMUPlaylistTrack *b) {
            return a.position < b.position ? NSOrderedAscending : (a.position > b.position ? NSOrderedDescending : NSOrderedSame);
        }];
        for (YTMUPlaylistTrack *track in remaining)
            [self.failures addObject:[NSString stringWithFormat:@"%ld. %@ (skipped)", (long)track.position, track.title]];
    } else if (listMissing) {
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
    [self showStatus:[self statusTitleWith:nil] step:nil details:@"Stopping…" progress:-1];
    self.hud.buttons = @[];
    [self checkDone];
}

- (void)checkDone {
    if (!self.running || self.capturing || self.queuedCount > 0 || self.finishingUp)
        return;
    self.finishingUp = YES;

    // Let the renumber pass finish (and save cover.png) before summing up
    NSString *coverURL = self.collectionCoverURL ?: self.albumCoverURL ?: self.firstTrackCoverURL;
    NSString *creatorURL = self.creatorImageURL;
    UIImage *pageAvatar = self.isAlbum ? self.pageAvatar : nil;
    NSString *artistChannel = self.isAlbum ? self.artistChannelID : nil;
    NSString *creator = self.creatorName;
    NSString *details = self.collectionDetails;
    NSURL *folder = self.folder;
    NSString *statusTitle = [self statusTitleWith:nil];
    dispatch_async(self.workQueue, ^{
        // Stopped: nothing more (no lyrics, no cover), straight to the summary
        BOOL stopped = self.cancelled;
        NSDictionary *index = [self.index copy]; // the work queue's own (downloads are done)
        // Every song is saved now: lyrics of all songs of the list (new ones fetched, the others
        // checked again so they're the newest: wrong ones replaced, removed ones marked as none).
        // A progress box shows it before the summary.
        if (folder && !stopped) {
            NSMutableArray<NSDictionary *> *songs = [NSMutableArray array];
            [index enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSDictionary *entry, BOOL *stop) {
                if (![entry isKindOfClass:[NSDictionary class]] || ![entry[@"file"] isKindOfClass:[NSString class]])
                    return;
                NSURL *audioURL = [folder URLByAppendingPathComponent:entry[@"file"]];
                if (![[NSFileManager defaultManager] fileExistsAtPath:audioURL.path])
                    return;
                [songs addObject:@{@"url": audioURL, @"key": key}];
            }];
            NSUInteger total = songs.count;
            __block NSUInteger done = 0, found = 0;
            void (^report)(void) = ^{
                NSUInteger doneNow = done, foundNow = found;
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (self.cancelled || [self.skippedStep isEqualToString:@"Lyrics"])
                        return;
                    NSString *line = total ? [NSString stringWithFormat:@"%lu / %lu songs checked · %lu with lyrics", (unsigned long)doneNow, (unsigned long)total, (unsigned long)foundNow]
                                           : @"No songs to check";
                    [self showStatus:statusTitle step:@"Lyrics" details:line progress:total ? (float)doneNow / (float)total : 1];
                });
            };
            report();
            dispatch_group_t group = dispatch_group_create();
            dispatch_semaphore_t slots = dispatch_semaphore_create(6);
            for (NSDictionary *song in songs) {
                dispatch_semaphore_wait(slots, DISPATCH_TIME_FOREVER);
                if (self.cancelled || [self.skippedStep isEqualToString:@"Lyrics"]) {
                    dispatch_semaphore_signal(slots);
                    break;
                }
                dispatch_group_async(group, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                    NSURL *audioURL = song[@"url"];
                    NSString *key = song[@"key"];
                    YTMUOfflineTrack *track = [YTMUOfflineTrack lightTrackWithURL:audioURL];
                    NSString *videoID = track.videoID ?: ([key hasPrefix:@"mp3:"] ? [key substringFromIndex:4] : key);
                    BOOL hasLyrics = YTMUSaveLyricsForDownload(audioURL, videoID, track.title, track.artist, track.duration, YES);
                    @synchronized (songs) {
                        done++;
                        if (hasLyrics)
                            found++;
                    }
                    report();
                    dispatch_semaphore_signal(slots);
                });
            }
            dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
            stopped = self.cancelled;
            if (!stopped)
                YTMUCleanLyricsFolder(folder);
        }
        if (folder && !stopped) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!self.cancelled)
                    [self showStatus:statusTitle step:@"Cover & info" details:@"Saving cover, creator and description…" progress:-1];
            });
        }
        NSString *creatorImageURL = creatorURL;
        // Albums without a picture on the page: the artist's own page has one
        if (folder && !stopped && !creatorImageURL && !pageAvatar && artistChannel)
            creatorImageURL = [self artistImageURLForChannel:artistChannel];
        if (folder && !stopped && self.downloadedCount + self.skippedCount > 0) {
            if (coverURL) {
                UIImage *cover = [UIImage imageWithData:YTMUGet(coverURL)];
                NSData *png = cover ? UIImagePNGRepresentation(cover) : nil;
                [png writeToURL:[folder URLByAppendingPathComponent:@"cover.png"] atomically:YES];
            }
            // Albums: the artist picture from the page (web data has none for album-playlists)
            if (pageAvatar && !creatorImageURL) {
                NSData *png = UIImagePNGRepresentation(pageAvatar);
                [png writeToURL:[folder URLByAppendingPathComponent:@"creator.png"] atomically:YES];
            }
            if (creatorImageURL) {
                UIImage *image = [UIImage imageWithData:YTMUGet(creatorImageURL)];
                NSData *png = image ? UIImagePNGRepresentation(image) : nil;
                [png writeToURL:[folder URLByAppendingPathComponent:@"creator.png"] atomically:YES];
            }
            if (creator.length)
                [creator writeToURL:[folder URLByAppendingPathComponent:@"creator.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
            if (details.length)
                [details writeToURL:[folder URLByAppendingPathComponent:@"description.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            self.finishingUp = NO;
            if (!self.running || self.capturing || self.queuedCount > 0)
                return;

            NSMutableString *summary = [NSMutableString stringWithFormat:@"%lu downloaded · %lu already there", (unsigned long)self.downloadedCount, (unsigned long)self.skippedCount];
            if (self.movedCount)
                [summary appendFormat:@" (%lu moved)", (unsigned long)self.movedCount];
            if (self.removedCount)
                [summary appendFormat:@" · %lu removed", (unsigned long)self.removedCount];
            [summary appendFormat:@" · %lu not downloaded", (unsigned long)self.failures.count];
            if (self.failures.count) {
                [UIPasteboard generalPasteboard].string = [self.failures componentsJoinedByString:@"\n"];
                [summary appendString:@"\nThe list of songs not downloaded was copied to the clipboard"];
            }
            BOOL stoppedNow = self.cancelled;
            [self finishWithMessage:stoppedNow ? @"Stopped" : LOC(@"DONE") details:summary icon:stoppedNow ? @"xmark" : @"checkmark"];
        });
    });
}

#pragma mark Download one song (work queue)

- (void)addFailure:(NSString *)text {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.failures addObject:text];
    });
}

// Cover as JPEG, loaded once per URL (an album's songs share one)
- (NSData *)coverJPEGForURL:(NSString *)coverURL {
    if (!coverURL.length)
        return nil;
    @synchronized (self.coverCache) {
        NSData *cached = self.coverCache[coverURL];
        if (cached)
            return cached.length ? cached : nil;
    }
    UIImage *image = [UIImage imageWithData:YTMUGet(coverURL)];
    NSData *jpeg = image ? UIImageJPEGRepresentation(image, 0.92) : nil;
    if (jpeg) {
        @synchronized (self.coverCache) {
            self.coverCache[coverURL] = jpeg;
        }
    }
    return jpeg;
}

// Download queue (several at once): download, tags + cover, into the folder.
// Lyrics follow separately so they don't hold up the next song.
- (void)downloadTrack:(YTMUPlaylistTrack *)track hlsManifest:(NSString *)hls author:(NSString *)author {
    if (self.cancelled)
        return;

    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *title = self.collectionTitle;

    NSString *audioURL = YTMUAudioURLFromManifest(YTMUGet(hls)) ?: YTMUAudioURLFromManifest(YTMUGet(hls));
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

    // One ffmpeg download at a time (cover, conversion, lyrics of the others run alongside);
    // a failed or empty download is tried once more
    static dispatch_semaphore_t ffmpegSlot;
    static dispatch_once_t ffmpegOnce;
    dispatch_once(&ffmpegOnce, ^{
        ffmpegSlot = dispatch_semaphore_create(1);
    });
    int returnCode = RETURN_CODE_SUCCESS;
    for (NSInteger attempt = 0; attempt < 2 && !self.cancelled; attempt++) {
        dispatch_semaphore_wait(ffmpegSlot, DISPATCH_TIME_FOREVER);
        returnCode = self.cancelled ? RETURN_CODE_CANCEL : [MobileFFmpeg executeWithArguments:arguments];
        dispatch_semaphore_signal(ffmpegSlot);
        NSDictionary *attributes = [fm attributesOfItemAtPath:tempPath error:nil];
        if (returnCode == RETURN_CODE_SUCCESS && attributes.fileSize > 16 * 1024)
            break;
        if (returnCode == RETURN_CODE_SUCCESS)
            returnCode = 1; // no audio came through
        [fm removeItemAtPath:tempPath error:nil];
    }
    if (self.cancelled || returnCode != RETURN_CODE_SUCCESS) {
        [fm removeItemAtPath:tempPath error:nil];
        if (returnCode != RETURN_CODE_CANCEL && !self.cancelled)
            [self addFailure:[NSString stringWithFormat:@"%ld. %@ (download failed, ffmpeg %d)", (long)track.position, track.title, returnCode]];
        return;
    }

    // Cover: album cover for albums, else the song's own artwork
    NSString *coverURL = (self.isAlbum && self.albumCoverURL) ? self.albumCoverURL : track.thumbnailURL;
    NSData *jpeg = [self coverJPEGForURL:coverURL];

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

    // The index belongs to the work queue
    NSString *indexKey = [self indexKeyForVideoID:track.videoID];
    dispatch_sync(self.workQueue, ^{
        self.index[indexKey] = [@{@"file": fileName, @"position": @(track.position)} mutableCopy];
        [self saveIndex:self.index inFolder:self.folder];
    });

    // Lyrics come in the Lyrics step, once every song is saved

    dispatch_async(dispatch_get_main_queue(), ^{
        self.downloadedCount++;
    });
}

@end