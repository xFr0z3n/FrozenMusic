#import <MediaPlayer/MediaPlayer.h>
#import <UIKit/UIKit.h>
#import <CommonCrypto/CommonCrypto.h>
#import "Prefs/FrozenSCDiscordConfig.h"

// Build secrets: placeholders substituted by GitHub Actions at build time, never commit real values.
// Values set in the app (FrozenSC > Discord RPC) override them one by one.
//   kNextcloudWebDAVURL  = WebDAV *folder* URL, MUST end with a trailing slash
//                          e.g. https://cloud.example.com/remote.php/dav/files/USER/discord-art/
//   kNextcloudPublicURL  = public *folder share* base URL, NO trailing slash
//                          e.g. https://cloud.example.com/s/AbCdEfGhIjKlmNo
static NSString * const kBuildDiscordToken       = @"__DISCORD_TOKEN__";
static NSString * const kBuildDiscordAppID       = @"__DISCORD_APP_ID__";
static NSString * const kBuildNextcloudWebDAVURL = @"__NEXTCLOUD_WEBDAV_URL__";
static NSString * const kBuildNextcloudUser      = @"__NEXTCLOUD_USER__";
static NSString * const kBuildNextcloudPass      = @"__NEXTCLOUD_PASS__";
static NSString * const kBuildNextcloudPublicURL = @"__NEXTCLOUD_PUBLIC_URL__";

// A placeholder the build didn't fill in (no secret set) counts as empty
static NSString *FrozenSCCleanBuildValue(NSString *value) {
    value = [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!value.length || ([value hasPrefix:@"__"] && [value hasSuffix:@"__"]))
        return nil;
    return value;
}

NSString *FrozenSCDiscordBuildValue(NSString *key) {
    NSDictionary *build = @{
        FrozenSCDiscordTokenKey: kBuildDiscordToken,
        FrozenSCDiscordAppIDKey: kBuildDiscordAppID,
        FrozenSCDiscordWebDAVURLKey: kBuildNextcloudWebDAVURL,
        FrozenSCDiscordWebDAVUserKey: kBuildNextcloudUser,
        FrozenSCDiscordWebDAVPassKey: kBuildNextcloudPass,
        FrozenSCDiscordPublicURLKey: kBuildNextcloudPublicURL
    };
    return FrozenSCCleanBuildValue(build[key]);
}

// Settings used for this launch (changes apply after a restart)
static NSDictionary<NSString *, NSString *> *FrozenSCDiscordSettings(void) {
    static NSDictionary *settings;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableDictionary *resolved = [NSMutableDictionary dictionary];
        for (NSString *key in @[FrozenSCDiscordTokenKey, FrozenSCDiscordAppIDKey, FrozenSCDiscordWebDAVURLKey,
                                FrozenSCDiscordWebDAVUserKey, FrozenSCDiscordWebDAVPassKey, FrozenSCDiscordPublicURLKey]) {
            NSString *value = FrozenSCDiscordStoredValue(key) ?: FrozenSCDiscordBuildValue(key);
            if (value.length)
                resolved[key] = value;
        }
        // WebDAV folder URL must end with "/", public share link must not
        NSString *webdav = resolved[FrozenSCDiscordWebDAVURLKey];
        if (webdav.length && ![webdav hasSuffix:@"/"])
            resolved[FrozenSCDiscordWebDAVURLKey] = [webdav stringByAppendingString:@"/"];
        NSString *share = resolved[FrozenSCDiscordPublicURLKey];
        while ([share hasSuffix:@"/"])
            share = [share substringToIndex:share.length - 1];
        if (share.length)
            resolved[FrozenSCDiscordPublicURLKey] = share;
        settings = [resolved copy];
    });
    return settings;
}

#define kDiscordToken       (FrozenSCDiscordSettings()[FrozenSCDiscordTokenKey] ?: @"")
#define kDiscordAppID       (FrozenSCDiscordSettings()[FrozenSCDiscordAppIDKey] ?: @"")
#define kNextcloudWebDAVURL (FrozenSCDiscordSettings()[FrozenSCDiscordWebDAVURLKey] ?: @"")
#define kNextcloudUser      (FrozenSCDiscordSettings()[FrozenSCDiscordWebDAVUserKey] ?: @"")
#define kNextcloudPass      (FrozenSCDiscordSettings()[FrozenSCDiscordWebDAVPassKey] ?: @"")
#define kNextcloudPublicURL (FrozenSCDiscordSettings()[FrozenSCDiscordPublicURLKey] ?: @"")

// Status needs a token + app ID; cover art additionally the WebDAV folder and its share link
static BOOL FrozenSCDiscordActive(void) {
    static BOOL active;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        active = FrozenSCDiscordEnabled() && kDiscordToken.length && kDiscordAppID.length;
    });
    return active;
}

static BOOL FrozenSCDiscordArtworkReady(void) {
    return kNextcloudWebDAVURL.length && kNextcloudUser.length && kNextcloudPass.length &&
           [kNextcloudPublicURL containsString:@"/s/"];
}

// Asset-key cache (trackKey -> mp: key), persisted across launches
static NSString * const kAssetCacheDefaultsKey = @"FrozenSCAssetKeyCache";
static const NSTimeInterval kAssetCacheTTL = 24 * 60 * 60; // 24h, then re-register
static const NSUInteger kAssetCacheMaxEntries = 300;

// Shared presence state — mutated only on the main queue
static NSString *gTrackTitle = nil;
static NSString *gTrackArtist = nil;
static NSString *gTrackAlbum = nil;
static double gTrackDuration = 0;
static NSTimeInterval gTrackStartEpoch = 0;
static NSString *gTrackImageKey = nil;
static BOOL gPresenceActive = NO;
static NSString *gLastTrackKey = nil;
static NSInteger gClearToken = 0;
static NSInteger gArtToken = 0;   // debounce token for artwork uploads
static UIImage *gPendingArtwork = nil;

static void FrozenSCPushPresence(void);
static NSTimeInterval gLastPushTime = 0; // last update sent to Discord
static BOOL gPushPending = NO;

#pragma mark - Small helpers

// Stable short hash for per-track artwork filenames
static NSString *FrozenSCHashKey(NSString *s) {
    const char *cstr = s.UTF8String ?: "";
    unsigned char digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1(cstr, (CC_LONG)strlen(cstr), digest);
    NSMutableString *hex = [NSMutableString stringWithCapacity:16];
    for (int i = 0; i < 8; i++) [hex appendFormat:@"%02x", digest[i]];
    return hex;
}

static NSMutableDictionary *FrozenSCAssetCache(void) {
    static NSMutableDictionary *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSDictionary *stored = [[NSUserDefaults standardUserDefaults] dictionaryForKey:kAssetCacheDefaultsKey];
        cache = [stored isKindOfClass:[NSDictionary class]] ? [stored mutableCopy] : [NSMutableDictionary new];
    });
    return cache;
}

// Returns a cached mp: key for this track, or nil if absent/expired
static NSString *FrozenSCCachedAssetKey(NSString *trackKey) {
    NSDictionary *entry = FrozenSCAssetCache()[trackKey];
    if (![entry isKindOfClass:[NSDictionary class]]) return nil;
    NSTimeInterval ts = [entry[@"ts"] doubleValue];
    if ([[NSDate date] timeIntervalSince1970] - ts > kAssetCacheTTL) return nil;
    NSString *key = entry[@"key"];
    return [key isKindOfClass:[NSString class]] ? key : nil;
}

static void FrozenSCStoreAssetKey(NSString *trackKey, NSString *assetKey) {
    if (!trackKey.length || !assetKey.length) return;
    NSMutableDictionary *cache = FrozenSCAssetCache();
    cache[trackKey] = @{ @"key": assetKey, @"ts": @([[NSDate date] timeIntervalSince1970]) };
    if (cache.count > kAssetCacheMaxEntries) {
        NSArray *oldestFirst = [cache keysSortedByValueUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            return [(NSNumber *)a[@"ts"] compare:(NSNumber *)b[@"ts"]];
        }];
        NSUInteger overflow = cache.count - kAssetCacheMaxEntries;
        for (NSString *k in [oldestFirst subarrayWithRange:NSMakeRange(0, overflow)]) {
            [cache removeObjectForKey:k];
        }
    }
    [[NSUserDefaults standardUserDefaults] setObject:cache forKey:kAssetCacheDefaultsKey];
}

#pragma mark - Gateway client

@interface FrozenSCDiscordGateway : NSObject <NSURLSessionWebSocketDelegate>
+ (instancetype)shared;
- (void)connect;
- (void)sendActivityTitle:(NSString *)title
                   artist:(NSString *)artist
                    album:(NSString *)album
                 imageKey:(NSString *)imageKey
              durationSec:(double)durationSec
               startEpoch:(NSTimeInterval)startEpoch;
- (void)clearPresence;
@property (nonatomic, readonly) BOOL identified;
@end

@implementation FrozenSCDiscordGateway {
    NSURLSession *_session;
    NSURLSessionWebSocketTask *_socket;
    dispatch_source_t _heartbeatTimer;
    NSInteger _sequence;
    BOOL _identified;
    BOOL _connecting;
    // RESUME state
    NSString *_sessionID;
    NSString *_resumeURL;
    BOOL _resuming;
    // reconnect / liveness
    BOOL _awaitingAck;
    NSInteger _reconnectAttempts;
    BOOL _reconnectScheduled;
}

- (BOOL)identified { return _identified; }

+ (instancetype)shared {
    static FrozenSCDiscordGateway *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [FrozenSCDiscordGateway new]; });
    return instance;
}

- (void)connect {
    if (_socket || _connecting) return;
    _connecting = YES;
    _identified = NO;
    _awaitingAck = NO;
    _resuming = (_sessionID.length > 0 && _resumeURL.length > 0);
    if (!_resuming) _sequence = 0;

    NSString *urlStr;
    if (_resuming) {
        NSString *base = [_resumeURL hasSuffix:@"/"] ? _resumeURL : [_resumeURL stringByAppendingString:@"/"];
        urlStr = [NSString stringWithFormat:@"%@?v=10&encoding=json", base];
        NSLog(@"[FrozenSC] gateway connecting (resume)");
    } else {
        urlStr = @"wss://gateway.discord.gg/?v=10&encoding=json";
        NSLog(@"[FrozenSC] gateway connecting (fresh)");
    }

    NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
    // Delegate + completion handlers on the main queue -> all gateway state is main-queue-only
    _session = [NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:[NSOperationQueue mainQueue]];
    _socket = [_session webSocketTaskWithURL:[NSURL URLWithString:urlStr]];
    _socket.maximumMessageSize = 16 * 1024 * 1024;
    [_socket resume];
    [self receiveLoop];
}

- (void)receiveLoop {
    __weak typeof(self) weakSelf = self;
    [_socket receiveMessageWithCompletionHandler:^(NSURLSessionWebSocketMessage *message, NSError *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        if (error) {
            NSLog(@"[FrozenSC] gateway receive error: %@", error.localizedDescription);
            [self teardownKeepingSession:YES];
            [self scheduleReconnectWithBackoff];
            return;
        }
        if (message.type == NSURLSessionWebSocketMessageTypeString) {
            NSData *data = [message.string dataUsingEncoding:NSUTF8StringEncoding];
            NSDictionary *payload = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            [self handlePayload:payload];
        }
        [self receiveLoop];
    }];
}

- (void)handlePayload:(NSDictionary *)payload {
    if (!payload) return;
    if (payload[@"s"] && payload[@"s"] != [NSNull null]) {
        _sequence = [payload[@"s"] integerValue];
    }
    int op = [payload[@"op"] intValue];

    switch (op) {
        case 10: { // HELLO
            NSLog(@"[FrozenSC] gateway HELLO");
            NSDictionary *d = payload[@"d"];
            NSTimeInterval interval = [d[@"heartbeat_interval"] doubleValue] / 1000.0;
            [self startHeartbeat:interval];
            if (_resuming) [self sendResume];
            else [self identify];
            break;
        }
        case 0: { // DISPATCH
            NSString *t = payload[@"t"];
            if ([t isEqualToString:@"READY"]) {
                NSDictionary *d = payload[@"d"];
                NSString *sid = d[@"session_id"];
                NSString *rurl = d[@"resume_gateway_url"];
                if ([sid isKindOfClass:[NSString class]]) _sessionID = sid;
                if ([rurl isKindOfClass:[NSString class]]) _resumeURL = rurl;
                NSLog(@"[FrozenSC] gateway READY (session stored)");
                [self markLive];
            } else if ([t isEqualToString:@"RESUMED"]) {
                NSLog(@"[FrozenSC] gateway RESUMED");
                [self markLive];
            }
            break;
        }
        case 1: // heartbeat request
            [self sendHeartbeatRaw];
            break;
        case 11: // heartbeat ACK
            _awaitingAck = NO;
            break;
        case 7: // RECONNECT — server asks us to resume elsewhere
            NSLog(@"[FrozenSC] gateway RECONNECT requested");
            [self teardownKeepingSession:YES];
            [self scheduleReconnectAfter:0.5];
            break;
        case 9: { // INVALID SESSION — d:true means still resumable
            BOOL resumable = [payload[@"d"] boolValue];
            NSLog(@"[FrozenSC] gateway INVALID SESSION (resumable=%d)", resumable);
            [self teardownKeepingSession:resumable];
            // Discord docs: wait a short randomized delay before re-identifying
            [self scheduleReconnectAfter:2.0 + arc4random_uniform(3)];
            break;
        }
        default:
            break;
    }
}

- (void)markLive {
    _identified = YES;
    _connecting = NO;
    _resuming = NO;
    _reconnectAttempts = 0;
    FrozenSCPushPresence();
}

- (void)startHeartbeat:(NSTimeInterval)interval {
    if (_heartbeatTimer) { dispatch_source_cancel(_heartbeatTimer); _heartbeatTimer = nil; }
    _heartbeatTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(_heartbeatTimer,
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(interval * NSEC_PER_SEC)),
        (uint64_t)(interval * NSEC_PER_SEC), 1 * NSEC_PER_SEC);
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(_heartbeatTimer, ^{ [weakSelf heartbeatTick]; });
    dispatch_resume(_heartbeatTimer);
}

- (void)heartbeatTick {
    // No ACK since the last beat -> zombie connection. Kill and resume.
    if (_awaitingAck) {
        NSLog(@"[FrozenSC] heartbeat ACK missed, reconnecting");
        [self teardownKeepingSession:YES];
        [self scheduleReconnectAfter:0.5];
        return;
    }
    _awaitingAck = YES;
    [self sendHeartbeatRaw];
}

- (void)sendHeartbeatRaw {
    [self send:@{ @"op": @(1), @"d": _sequence ? @(_sequence) : [NSNull null] }];
}

- (void)identify {
    [self send:@{
        @"op": @(2),
        @"d": @{
            @"token": kDiscordToken,
            @"properties": @{ @"os": @"iOS", @"browser": @"FrozenSC", @"device": @"FrozenSC" },
            @"presence": @{ @"status": @"online", @"afk": @NO }
        }
    }];
}

- (void)sendResume {
    [self send:@{
        @"op": @(6),
        @"d": @{
            @"token": kDiscordToken,
            @"session_id": _sessionID ?: @"",
            @"seq": @(_sequence)
        }
    }];
}

- (void)sendActivityTitle:(NSString *)title
                   artist:(NSString *)artist
                    album:(NSString *)album
                 imageKey:(NSString *)imageKey
              durationSec:(double)durationSec
               startEpoch:(NSTimeInterval)startEpoch {
    if (!_identified) { [self connect]; return; } // READY/RESUMED re-pushes for us

    // Without a known length only the start goes out (Discord counts up instead of ending early)
    NSMutableDictionary *timestamps = [@{ @"start": @((long long)llround(startEpoch * 1000)) } mutableCopy];
    if (durationSec > 0)
        timestamps[@"end"] = @((long long)llround((startEpoch + durationSec) * 1000));
    NSMutableDictionary *activity = [@{
        @"name": @"SoundCloud",
        @"type": @(2),
        @"details": title ?: @"",
        @"state": artist ?: @"",
        @"application_id": kDiscordAppID,
        @"timestamps": timestamps
    } mutableCopy];

    if (imageKey.length > 0) {
        NSMutableDictionary *assets = [@{ @"large_image": imageKey } mutableCopy];
        // Only add hover text if it's meaningfully different from what's already visible.
        if (album.length && ![album isEqualToString:artist] && ![album isEqualToString:title]) {
            assets[@"large_text"] = album;
        }
        activity[@"assets"] = assets;
    }

    [self send:@{
        @"op": @(3),
        @"d": @{ @"since": @(0), @"activities": @[ activity ], @"status": @"online", @"afk": @NO }
    }];
}

- (void)clearPresence {
    if (!_identified) return;
    [self send:@{
        @"op": @(3),
        @"d": @{ @"since": @(0), @"activities": @[], @"status": @"online", @"afk": @NO }
    }];
}

- (void)send:(NSDictionary *)payload {
    if (!_socket) return;
    NSData *data = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
    NSString *str = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!str) return;
    NSURLSessionWebSocketMessage *msg = [[NSURLSessionWebSocketMessage alloc] initWithString:str];
    __weak typeof(self) weakSelf = self;
    [_socket sendMessage:msg completionHandler:^(NSError *error) {
        if (!error) return;
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        NSLog(@"[FrozenSC] gateway send error: %@", error.localizedDescription);
        [self teardownKeepingSession:YES];
        [self scheduleReconnectWithBackoff];
    }];
}

- (void)teardownKeepingSession:(BOOL)keep {
    if (_heartbeatTimer) { dispatch_source_cancel(_heartbeatTimer); _heartbeatTimer = nil; }
    [_socket cancel];
    _socket = nil;
    [_session invalidateAndCancel];
    _session = nil;
    _identified = NO;
    _connecting = NO;
    _awaitingAck = NO;
    if (!keep) {
        _sessionID = nil;
        _resumeURL = nil;
    }
}

// Exponential backoff: 1s, 2s, 4s ... capped at 30s. Reset on READY/RESUMED.
- (void)scheduleReconnectWithBackoff {
    NSTimeInterval delay = MIN(pow(2.0, (double)_reconnectAttempts), 30.0);
    _reconnectAttempts++;
    [self scheduleReconnectAfter:delay];
}

- (void)scheduleReconnectAfter:(NSTimeInterval)delay {
    if (_reconnectScheduled) return;
    _reconnectScheduled = YES;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        self->_reconnectScheduled = NO;
        // Only chase the connection while something is actually playing;
        // otherwise reconnect lazily on the next presence push.
        if (gPresenceActive) [self connect];
    });
}

@end

#pragma mark - Presence push (reads shared state)

// Sends what's playing now (or clears it when nothing is)
static void FrozenSCSendPresenceNow(void) {
    gLastPushTime = [[NSDate date] timeIntervalSince1970];
    if (gPresenceActive) {
        [[FrozenSCDiscordGateway shared] sendActivityTitle:gTrackTitle
                                                    artist:gTrackArtist
                                                     album:gTrackAlbum
                                                  imageKey:gTrackImageKey
                                               durationSec:gTrackDuration
                                                startEpoch:gTrackStartEpoch];
    } else {
        [[FrozenSCDiscordGateway shared] clearPresence];
    }
}

// Discord quietly drops presence updates that come too fast (about 5 per 20 s), which could
// leave an earlier song showing after a few skips. So one update every 4 s at most, and the
// newest state always goes out when the time is up.
static const NSTimeInterval kPresenceInterval = 4.0;

static void FrozenSCPushPresence(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            FrozenSCPushPresence();
        });
        return;
    }
    NSTimeInterval wait = gLastPushTime + kPresenceInterval - [[NSDate date] timeIntervalSince1970];
    if (wait <= 0) {
        FrozenSCSendPresenceNow();
        return;
    }
    if (gPushPending)
        return;
    gPushPending = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(wait * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        gPushPending = NO;
        FrozenSCSendPresenceNow();
    });
}

#pragma mark - Artwork upload + external asset registration

static void FrozenSCRegisterExternalAsset(NSString *imageURL, void (^completion)(NSString *assetKey));

// Per-track filename derived from trackKey -> no overwrite race between
// an in-flight registration for track A and a fresh upload for track B.
static void FrozenSCResolveArtwork(UIImage *artwork, NSString *trackKey, void (^completion)(NSString *assetKey)) {
    NSData *jpeg = UIImageJPEGRepresentation(artwork, 0.8);
    if (!jpeg) { completion(nil); return; }

    NSString *filename = [NSString stringWithFormat:@"%@.jpg", FrozenSCHashKey(trackKey)];
    NSString *putURLString = [kNextcloudWebDAVURL stringByAppendingString:filename]; // folder URL ends with /

    NSMutableURLRequest *putReq = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:putURLString]];
    putReq.HTTPMethod = @"PUT";
    NSString *authString = [NSString stringWithFormat:@"%@:%@", kNextcloudUser, kNextcloudPass];
    NSString *authBase64 = [[authString dataUsingEncoding:NSUTF8StringEncoding] base64EncodedStringWithOptions:0];
    [putReq setValue:[NSString stringWithFormat:@"Basic %@", authBase64] forHTTPHeaderField:@"Authorization"];
    putReq.HTTPBody = jpeg;

    NSURLSessionDataTask *uploadTask = [[NSURLSession sharedSession] dataTaskWithRequest:putReq
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            NSInteger status = [(NSHTTPURLResponse *)response statusCode];
            NSLog(@"[FrozenSC] WebDAV PUT %@ status=%ld", filename, (long)status);
            if (error || status >= 400) { completion(nil); return; }
            // Public folder-share download URL for this single file
            NSString *previewBase = [kNextcloudPublicURL stringByReplacingOccurrencesOfString:@"/s/"
                                                                        withString:@"/apps/files_sharing/publicpreview/"];
            NSString *publicURL = [NSString stringWithFormat:@"%@?file=%%2F%@&x=512&y=512&a=true", previewBase, filename];
            FrozenSCRegisterExternalAsset(publicURL, completion);
        }];
    [uploadTask resume];
}

static void FrozenSCRegisterExternalAsset(NSString *imageURL, void (^completion)(NSString *assetKey)) {
    NSString *endpoint = [NSString stringWithFormat:@"https://discord.com/api/v10/applications/%@/external-assets", kDiscordAppID];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:endpoint]];
    req.HTTPMethod = @"POST";
    [req setValue:kDiscordToken forHTTPHeaderField:@"Authorization"];
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:@{ @"urls": @[ imageURL ] } options:0 error:nil];

    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            NSInteger status = [(NSHTTPURLResponse *)response statusCode];
            if (error || !data || status >= 400) {
                NSLog(@"[FrozenSC] external-assets failed status=%ld", (long)status);
                completion(nil);
                return;
            }
            NSArray *arr = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if (![arr isKindOfClass:[NSArray class]] || arr.count == 0) { completion(nil); return; }
            NSString *path = [arr.firstObject objectForKey:@"external_asset_path"];
            NSLog(@"[FrozenSC] external asset resolved");
            completion(path ? [@"mp:" stringByAppendingString:path] : nil);
        }];
    [task resume];
}

// Debounced artwork resolution: only fires after the user stops skipping for ~800ms,
// so flying through tracks doesn't flood Nextcloud + Discord's external-assets endpoint.
static void FrozenSCScheduleArtwork(UIImage *artwork, NSString *trackKey) {
    if (!artwork || !FrozenSCDiscordArtworkReady()) return;
    gPendingArtwork = artwork;
    NSInteger myToken = ++gArtToken;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        // Bail if another skip happened since, or we've moved off this track
        if (myToken != gArtToken) return;
        if (![gLastTrackKey isEqualToString:trackKey]) return;

        UIImage *img = gPendingArtwork;
        if (!img) return;

        FrozenSCResolveArtwork(img, trackKey, ^(NSString *assetKey) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!assetKey) return;
                FrozenSCStoreAssetKey(trackKey, assetKey); // cache even if we've moved on — replays get instant art
                // Only apply if this is still both the newest request AND the current track
                if (myToken == gArtToken && [gLastTrackKey isEqualToString:trackKey]) {
                    gTrackImageKey = assetKey;
                    FrozenSCPushPresence();
                }
            });
        });
    });
}

#pragma mark - Hook

@interface MPNowPlayingInfoCenter (FrozenSC)
- (void)frozensc_handleNowPlayingInfo:(NSDictionary *)info;
- (void)frozensc_scheduleClear;
@end

%hook MPNowPlayingInfoCenter

- (void)setNowPlayingInfo:(NSDictionary *)info {
    %orig;
    if (FrozenSCDiscordActive())
        [self frozensc_handleNowPlayingInfo:info];
}

%new
- (void)frozensc_handleNowPlayingInfo:(NSDictionary *)info {
    BOOL playing = NO;
    NSString *title = @"", *artist = @"", *album = @"";
    double duration = 0, elapsed = 0;
    UIImage *artworkImage = nil;

    if (info) {
        NSNumber *rate = info[MPNowPlayingInfoPropertyPlaybackRate] ?: @(0);
        playing = [rate floatValue] > 0;
        title  = info[MPMediaItemPropertyTitle] ?: @"";
        artist = info[MPMediaItemPropertyArtist] ?: @"";
        album  = info[MPMediaItemPropertyAlbumTitle] ?: @"";
        duration = [info[MPMediaItemPropertyPlaybackDuration] doubleValue];
        elapsed  = [info[MPNowPlayingInfoPropertyElapsedPlaybackTime] doubleValue];
        MPMediaItemArtwork *artworkObj = info[MPMediaItemPropertyArtwork];
        artworkImage = artworkObj ? [artworkObj imageWithSize:CGSizeMake(512, 512)] : nil;
    }

    if (!info || !playing || title.length == 0) {
        [self frozensc_scheduleClear];
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        gClearToken++; // cancel any pending debounced clear

        NSString *trackKey = [NSString stringWithFormat:@"%@|%@", title, artist];
        NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
        double position = elapsed, length = duration;

        if (![trackKey isEqualToString:gLastTrackKey] || !gPresenceActive) {
            BOOL sameTrack = [trackKey isEqualToString:gLastTrackKey];
            gLastTrackKey = trackKey;
            gTrackTitle = title;
            gTrackArtist = artist;
            gTrackAlbum = album;
            gTrackDuration = length;
            gTrackStartEpoch = now - position;
            gPresenceActive = YES;

            // Cache hit -> art shows instantly with the very first push, no upload at all
            if (!sameTrack || !gTrackImageKey)
                gTrackImageKey = FrozenSCCachedAssetKey(trackKey);

            NSLog(@"[FrozenSC] NEW TRACK: %@ — %@%@", title, artist,
                  gTrackImageKey ? @" (art cached)" : @"");
            FrozenSCPushPresence();                              // text + progress (+art on cache hit)
            if (!gTrackImageKey) {
                FrozenSCScheduleArtwork(artworkImage, trackKey); // debounced art only when needed
            }
        } else {
            if (!gTrackImageKey && artworkImage) {
                FrozenSCScheduleArtwork(artworkImage, trackKey);
            }
            BOOL changed = NO;
            if (length > 0 && fabs(length - gTrackDuration) > 1.0) {
                gTrackDuration = length; // the real length arrived
                changed = YES;
            }
            if (fabs(position - (now - gTrackStartEpoch)) > 2.0) {
                gTrackStartEpoch = now - position; // seek / buffering / replay
                changed = YES;
            }
            if (changed)
                FrozenSCPushPresence();
        }
    });
}

%new
- (void)frozensc_scheduleClear {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSInteger myToken = ++gClearToken;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (myToken == gClearToken) {
                NSLog(@"[FrozenSC] clearing presence");
                gPresenceActive = NO;
                gLastTrackKey = nil;
                gTrackImageKey = nil;
                gPendingArtwork = nil;
                FrozenSCPushPresence();
            }
        });
    });
}

%end

#pragma mark - App lifecycle: clear presence on termination

static void FrozenSCClearOnExit(void) {
    gPresenceActive = NO;
    gLastTrackKey = nil;
    gTrackImageKey = nil;
    gPendingArtwork = nil;
    [[FrozenSCDiscordGateway shared] clearPresence];
}

%ctor {
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationWillTerminateNotification
                                                      object:nil queue:nil
                                                  usingBlock:^(NSNotification *note) {
        NSLog(@"[FrozenSC] termination notification, clearing presence");
        FrozenSCClearOnExit();
    }];
}
