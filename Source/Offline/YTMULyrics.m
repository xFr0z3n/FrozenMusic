#import "YTMULyrics.h"
#import "YTMUOfflinePlayer.h"
#import <CommonCrypto/CommonCrypto.h>
#import <NaturalLanguage/NaturalLanguage.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/message.h>
#import <dlfcn.h>

@implementation YTMULyricLine
@end

#pragma mark - Storage (Application Support/FrozenMusic/Lyrics/<video ID>.json)

static const NSTimeInterval YTMULyricsMissingRetry = 24 * 60 * 60; // "none" is asked again after a day

static NSURL *YTMULyricsFolder(void) {
    static NSURL *folder;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSURL *support = [[[NSFileManager defaultManager] URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask] firstObject];
        folder = [[support URLByAppendingPathComponent:@"FrozenMusic" isDirectory:YES] URLByAppendingPathComponent:@"Lyrics" isDirectory:YES];
        [[NSFileManager defaultManager] createDirectoryAtURL:folder withIntermediateDirectories:YES attributes:nil error:nil];
    });
    return folder;
}

// Video ID when known, else a hash of title + artist (songs that didn't come from YTM)
static NSString *YTMULyricsKey(NSString *videoID, NSString *title, NSString *artist) {
    NSCharacterSet *invalid = [[NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"] invertedSet];
    if (videoID.length >= 6 && [videoID rangeOfCharacterFromSet:invalid].location == NSNotFound)
        return videoID;
    if (!title.length)
        return nil;
    NSString *text = [[NSString stringWithFormat:@"%@|%@", title, artist ?: @""] lowercaseString];
    const char *cString = text.UTF8String;
    unsigned char digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1(cString, (CC_LONG)strlen(cString), digest);
    NSMutableString *hash = [NSMutableString stringWithString:@"t_"];
    for (int i = 0; i < 10; i++)
        [hash appendFormat:@"%02x", digest[i]];
    return hash;
}

static NSURL *YTMULyricsFile(NSString *key) {
    return [YTMULyricsFolder() URLByAppendingPathComponent:[key stringByAppendingPathExtension:@"json"]];
}

static NSDictionary *YTMULyricsRead(NSString *key) {
    if (!key)
        return nil;
    NSData *data = [NSData dataWithContentsOfURL:YTMULyricsFile(key)];
    id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    return [json isKindOfClass:[NSDictionary class]] ? json : nil;
}

static void YTMULyricsWrite(NSString *key, NSDictionary *json) {
    NSData *data = key ? [NSJSONSerialization dataWithJSONObject:json options:0 error:nil] : nil;
    [data writeToURL:YTMULyricsFile(key) atomically:YES];
}

static BOOL YTMULyricsMissingIsFresh(NSDictionary *json) {
    return [json[@"missing"] boolValue] &&
           [[NSDate date] timeIntervalSince1970] - [json[@"date"] doubleValue] < YTMULyricsMissingRetry;
}

static YTMULyrics *YTMULyricsFromJSON(NSDictionary *json) {
    NSArray *rows = json[@"lines"];
    if (![rows isKindOfClass:[NSArray class]] || rows.count == 0)
        return nil;
    NSMutableArray *lines = [NSMutableArray array];
    for (NSArray *row in rows) {
        if (![row isKindOfClass:[NSArray class]] || row.count < 2 || ![row[1] isKindOfClass:[NSString class]])
            continue;
        YTMULyricLine *line = [YTMULyricLine new];
        double ms = [row[0] respondsToSelector:@selector(doubleValue)] ? [row[0] doubleValue] : -1;
        line.time = ms < 0 ? -1 : ms / 1000.0;
        line.text = row[1];
        [lines addObject:line];
    }
    if (!lines.count)
        return nil;
    YTMULyrics *lyrics = [YTMULyrics new];
    lyrics.lines = lines;
    lyrics.synced = [json[@"synced"] boolValue];
    lyrics.source = [json[@"source"] isKindOfClass:[NSString class]] ? json[@"source"] : nil;
    return lyrics;
}

static NSDictionary *YTMULyricsToJSON(YTMULyrics *lyrics) {
    NSMutableArray *rows = [NSMutableArray array];
    for (YTMULyricLine *line in lyrics.lines)
        [rows addObject:@[@(line.time < 0 ? -1 : llround(line.time * 1000)), line.text ?: @""]];
    NSMutableDictionary *json = [@{@"v": @1, @"synced": @(lyrics.synced), @"lines": rows} mutableCopy];
    if (lyrics.source.length)
        json[@"source"] = lyrics.source;
    return json;
}

#pragma mark - Network (background queues only)

static NSURLSession *YTMULyricsSession(void) {
    static NSURLSession *session;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // No cookies: plain public requests, like a logged out client
        NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        config.timeoutIntervalForRequest = 15;
        session = [NSURLSession sessionWithConfiguration:config];
    });
    return session;
}

static BOOL YTMUIsOfflineError(NSError *error) {
    if (![error.domain isEqualToString:NSURLErrorDomain])
        return NO;
    switch (error.code) {
        case NSURLErrorNotConnectedToInternet:
        case NSURLErrorNetworkConnectionLost:
        case NSURLErrorTimedOut:
        case NSURLErrorCannotFindHost:
        case NSURLErrorCannotConnectToHost:
        case NSURLErrorDNSLookupFailed:
        case NSURLErrorDataNotAllowed:
        case NSURLErrorInternationalRoamingOff:
            return YES;
        default:
            return NO;
    }
}

// Blocking request. *status: HTTP status, 0 when the request itself failed.
// *offline: the answer can't be trusted (no internet, timeout, rate limit, server error),
// so "no lyrics" must not be remembered
static NSData *YTMULyricsLoad(NSURLRequest *request, NSInteger *status, BOOL *offline) {
    __block NSData *result = nil;
    __block NSInteger code = 0;
    __block BOOL noNetwork = NO;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [[YTMULyricsSession() dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error)
            noNetwork = YTMUIsOfflineError(error);
        else
            code = [response isKindOfClass:[NSHTTPURLResponse class]] ? ((NSHTTPURLResponse *)response).statusCode : 0;
        if (code == 200)
            result = data;
        dispatch_semaphore_signal(done);
    }] resume];
    BOOL finished = dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(25 * NSEC_PER_SEC))) == 0;
    if (status)
        *status = code;
    BOOL unreliable = !finished || noNetwork || (!result && (code == 0 || code == 429 || code >= 500));
    if (offline && unreliable)
        *offline = YES;
    return finished ? result : nil;
}

static id YTMUInnerTube(NSString *endpoint, NSDictionary *body, NSString *client, NSString *version, BOOL *offline) {
    NSString *language = [YTMULyrics deviceLanguageCode];
    NSMutableDictionary *payload = [body mutableCopy];
    payload[@"context"] = @{@"client": @{@"clientName": client, @"clientVersion": version, @"hl": language, @"gl": @"US"}};
    NSString *url = [NSString stringWithFormat:@"https://music.youtube.com/youtubei/v1/%@?prettyPrint=false", endpoint];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
    request.HTTPMethod = @"POST";
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:@"Mozilla/5.0" forHTTPHeaderField:@"User-Agent"];
    NSData *data = YTMULyricsLoad(request, NULL, offline);
    return data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
}

// First value stored under `key` anywhere in the response
static id YTMUFindKey(id object, NSString *key) {
    if ([object isKindOfClass:[NSDictionary class]]) {
        id value = ((NSDictionary *)object)[key];
        if (value)
            return value;
        for (id child in ((NSDictionary *)object).allValues) {
            id found = YTMUFindKey(child, key);
            if (found)
                return found;
        }
    } else if ([object isKindOfClass:[NSArray class]]) {
        for (id child in (NSArray *)object) {
            id found = YTMUFindKey(child, key);
            if (found)
                return found;
        }
    }
    return nil;
}

// The "Lyrics" tab of the song: browse ID "MPLYt_..."
static NSString *YTMUFindLyricsBrowseID(id object) {
    if ([object isKindOfClass:[NSDictionary class]]) {
        NSDictionary *browse = ((NSDictionary *)object)[@"browseEndpoint"];
        NSString *browseID = [browse isKindOfClass:[NSDictionary class]] ? browse[@"browseId"] : nil;
        if ([browseID isKindOfClass:[NSString class]] && [browseID hasPrefix:@"MPLY"])
            return browseID;
        for (id child in ((NSDictionary *)object).allValues) {
            NSString *found = YTMUFindLyricsBrowseID(child);
            if (found)
                return found;
        }
    } else if ([object isKindOfClass:[NSArray class]]) {
        for (id child in (NSArray *)object) {
            NSString *found = YTMUFindLyricsBrowseID(child);
            if (found)
                return found;
        }
    }
    return nil;
}

static NSString *YTMURunsText(id runsHolder) {
    NSArray *runs = [runsHolder isKindOfClass:[NSDictionary class]] ? runsHolder[@"runs"] : nil;
    if (![runs isKindOfClass:[NSArray class]])
        return nil;
    NSMutableString *text = [NSMutableString string];
    for (NSDictionary *run in runs) {
        if ([run isKindOfClass:[NSDictionary class]] && [run[@"text"] isKindOfClass:[NSString class]])
            [text appendString:run[@"text"]];
    }
    return text.length ? text : nil;
}

static NSArray<NSString *> *YTMUSplitLines(NSString *text) {
    NSString *unified = [[text stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"] stringByReplacingOccurrencesOfString:@"\r" withString:@"\n"];
    NSMutableArray *lines = [[unified componentsSeparatedByString:@"\n"] mutableCopy];
    while (lines.count && ![lines.lastObject stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]].length)
        [lines removeLastObject];
    while (lines.count && ![lines.firstObject stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]].length)
        [lines removeObjectAtIndex:0];
    return lines;
}

static YTMULyrics *YTMUUnsyncedLyrics(NSString *text, NSString *source) {
    NSMutableArray *lines = [NSMutableArray array];
    for (NSString *row in YTMUSplitLines(text)) {
        YTMULyricLine *line = [YTMULyricLine new];
        line.time = -1;
        line.text = [row stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        [lines addObject:line];
    }
    if (!lines.count)
        return nil;
    YTMULyrics *lyrics = [YTMULyrics new];
    lyrics.lines = lines;
    lyrics.source = source;
    return lyrics;
}

// YouTube Music: song -> Lyrics tab -> synced lyrics (mobile client), else the plain text
static YTMULyrics *YTMUFetchYTMLyrics(NSString *videoID, BOOL *offline) {
    id next = YTMUInnerTube(@"next", @{@"videoId": videoID}, @"WEB_REMIX", @"1.20250101.01.00", offline);
    NSString *browseID = YTMUFindLyricsBrowseID(next);
    if (!browseID)
        return nil;

    id timed = YTMUInnerTube(@"browse", @{@"browseId": browseID}, @"ANDROID_MUSIC", @"7.21.50", offline);
    NSArray *timedData = YTMUFindKey(timed, @"timedLyricsData");
    if ([timedData isKindOfClass:[NSArray class]] && timedData.count) {
        NSMutableArray *lines = [NSMutableArray array];
        for (NSDictionary *item in timedData) {
            if (![item isKindOfClass:[NSDictionary class]])
                continue;
            NSString *text = [item[@"lyricLine"] isKindOfClass:[NSString class]] ? item[@"lyricLine"] : @"";
            NSDictionary *cue = [item[@"cueRange"] isKindOfClass:[NSDictionary class]] ? item[@"cueRange"] : nil;
            id start = cue[@"startTimeMilliseconds"];
            if (![start respondsToSelector:@selector(doubleValue)])
                continue;
            YTMULyricLine *line = [YTMULyricLine new];
            line.time = [start doubleValue] / 1000.0;
            text = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            line.text = text.length ? text : @"♪";
            [lines addObject:line];
        }
        if (lines.count) {
            YTMULyrics *lyrics = [YTMULyrics new];
            lyrics.lines = lines;
            lyrics.synced = YES;
            NSString *source = YTMUFindKey(timed, @"sourceMessage");
            lyrics.source = [source isKindOfClass:[NSString class]] ? source : nil;
            return lyrics;
        }
    }

    id plain = YTMUInnerTube(@"browse", @{@"browseId": browseID}, @"WEB_REMIX", @"1.20250101.01.00", offline);
    NSDictionary *shelf = YTMUFindKey(plain, @"musicDescriptionShelfRenderer");
    if (![shelf isKindOfClass:[NSDictionary class]])
        return nil;
    NSString *text = YTMURunsText(shelf[@"description"]);
    return text ? YTMUUnsyncedLyrics(text, YTMURunsText(shelf[@"footer"])) : nil;
}

// "[01:02.34] text" (several time tags per line allowed), empty lines = ♪
static YTMULyrics *YTMUParseLRC(NSString *lrc) {
    NSRegularExpression *tag = [NSRegularExpression regularExpressionWithPattern:@"^\\[(\\d+):(\\d+(?:[.:]\\d+)?)\\]" options:0 error:nil];
    NSMutableArray<YTMULyricLine *> *lines = [NSMutableArray array];
    for (NSString *raw in YTMUSplitLines(lrc)) {
        NSString *rest = raw;
        NSMutableArray<NSNumber *> *times = [NSMutableArray array];
        NSTextCheckingResult *match;
        while ((match = [tag firstMatchInString:rest options:0 range:NSMakeRange(0, rest.length)])) {
            double minutes = [[rest substringWithRange:[match rangeAtIndex:1]] doubleValue];
            double seconds = [[[rest substringWithRange:[match rangeAtIndex:2]] stringByReplacingOccurrencesOfString:@":" withString:@"."] doubleValue];
            [times addObject:@(minutes * 60 + seconds)];
            rest = [rest substringFromIndex:NSMaxRange(match.range)];
        }
        NSString *text = [rest stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        for (NSNumber *time in times) {
            YTMULyricLine *line = [YTMULyricLine new];
            line.time = time.doubleValue;
            line.text = text.length ? text : @"♪";
            [lines addObject:line];
        }
    }
    if (!lines.count)
        return nil;
    [lines sortUsingComparator:^NSComparisonResult(YTMULyricLine *a, YTMULyricLine *b) {
        return a.time < b.time ? NSOrderedAscending : (a.time > b.time ? NSOrderedDescending : NSOrderedSame);
    }];
    // Like YTM: ♪ during the intro
    if (lines.firstObject.time > 2 && ![lines.firstObject.text isEqualToString:@"♪"]) {
        YTMULyricLine *intro = [YTMULyricLine new];
        intro.time = 0;
        intro.text = @"♪";
        [lines insertObject:intro atIndex:0];
    }
    YTMULyrics *lyrics = [YTMULyrics new];
    lyrics.lines = lines;
    lyrics.synced = YES;
    return lyrics;
}

static NSURLRequest *YTMULRCLIBRequest(NSString *path, NSDictionary<NSString *, NSString *> *query) {
    NSURLComponents *components = [NSURLComponents componentsWithString:[@"https://lrclib.net/api/" stringByAppendingString:path]];
    NSMutableArray *items = [NSMutableArray array];
    [query enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *value, BOOL *stop) {
        [items addObject:[NSURLQueryItem queryItemWithName:key value:value]];
    }];
    components.queryItems = items;
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:components.URL];
    [request setValue:@"FrozenMusic (https://github.com/xFr0z3n/FrozenMusic)" forHTTPHeaderField:@"User-Agent"];
    return request;
}

static YTMULyrics *YTMULyricsFromLRCLIB(NSDictionary *entry) {
    if (![entry isKindOfClass:[NSDictionary class]] || [entry[@"instrumental"] boolValue])
        return nil;
    YTMULyrics *lyrics = nil;
    if ([entry[@"syncedLyrics"] isKindOfClass:[NSString class]])
        lyrics = YTMUParseLRC(entry[@"syncedLyrics"]);
    if (!lyrics && [entry[@"plainLyrics"] isKindOfClass:[NSString class]])
        lyrics = YTMUUnsyncedLyrics(entry[@"plainLyrics"], nil);
    lyrics.source = @"Source: LRCLIB";
    return lyrics;
}

static YTMULyrics *YTMUFetchLRCLIB(NSString *title, NSString *artist, NSTimeInterval duration, BOOL *offline) {
    NSMutableDictionary *query = [@{@"track_name": title} mutableCopy];
    if (artist.length)
        query[@"artist_name"] = artist;
    NSMutableDictionary *exact = [query mutableCopy];
    if (duration > 0)
        exact[@"duration"] = [NSString stringWithFormat:@"%ld", (long)llround(duration)];

    NSData *data = YTMULyricsLoad(YTMULRCLIBRequest(@"get", exact), NULL, offline);
    YTMULyrics *lyrics = data ? YTMULyricsFromLRCLIB([NSJSONSerialization JSONObjectWithData:data options:0 error:nil]) : nil;
    if (lyrics)
        return lyrics;

    data = YTMULyricsLoad(YTMULRCLIBRequest(@"search", query), NULL, offline);
    NSArray *results = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (![results isKindOfClass:[NSArray class]])
        return nil;
    // Prefer a synced result
    YTMULyrics *plain = nil;
    for (NSDictionary *entry in [results subarrayWithRange:NSMakeRange(0, MIN(results.count, (NSUInteger)10))]) {
        YTMULyrics *candidate = YTMULyricsFromLRCLIB(entry);
        if (candidate.synced)
            return candidate;
        if (!plain)
            plain = candidate;
    }
    return plain;
}

// Everything that can be asked. nil + *offline = couldn't reach the internet
static YTMULyrics *YTMUFetchLyrics(NSString *videoID, NSString *title, NSString *artist, NSTimeInterval duration, BOOL *offline) {
    YTMULyrics *lyrics = nil;
    BOOL ytmOffline = NO, lrclibOffline = NO;
    if (videoID.length)
        lyrics = YTMUFetchYTMLyrics(videoID, &ytmOffline);
    if (!lyrics && title.length)
        lyrics = YTMUFetchLRCLIB(title, artist, duration, &lrclibOffline);
    if (offline)
        *offline = !lyrics && ((videoID.length && ytmOffline) || (title.length && lrclibOffline));
    return lyrics;
}

static void YTMUPretranslate(NSString *key, YTMULyrics *lyrics);

// Fetch + save (lyrics, or a "none" marker when nothing exists)
static YTMULyrics *YTMUFetchAndSave(NSString *key, NSString *videoID, NSString *title, NSString *artist, NSTimeInterval duration, BOOL *offline) {
    BOOL noNetwork = NO;
    YTMULyrics *lyrics = YTMUFetchLyrics(videoID, title, artist, duration, &noNetwork);
    if (lyrics) {
        YTMULyricsWrite(key, YTMULyricsToJSON(lyrics));
        // Other language: translated offline right away, ready without internet
        YTMUPretranslate(key, lyrics);
    }
    else if (!noNetwork)
        YTMULyricsWrite(key, @{@"v": @1, @"missing": @YES, @"date": @([[NSDate date] timeIntervalSince1970])});
    if (offline)
        *offline = noNetwork;
    return lyrics;
}

// Lyrics as LRC text ("[mm:ss.xx] line" when synced), what gets written into the file's tags
static NSString *YTMULyricsLRC(YTMULyrics *lyrics) {
    NSMutableArray *rows = [NSMutableArray array];
    for (YTMULyricLine *line in lyrics.lines) {
        if (lyrics.synced && line.time >= 0) {
            NSInteger minutes = (NSInteger)(line.time / 60);
            double seconds = line.time - minutes * 60;
            [rows addObject:[NSString stringWithFormat:@"[%02ld:%05.2f]%@", (long)minutes, seconds, line.text ?: @""]];
        } else {
            [rows addObject:line.text ?: @""];
        }
    }
    return rows.count ? [rows componentsJoinedByString:@"\n"] : nil;
}

// Lyrics written into a downloaded file (©lyr / USLT): LRC or plain text
static YTMULyrics *YTMUEmbeddedLyrics(NSURL *url) {
    if (!url)
        return nil;
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];
    for (NSString *format in asset.availableMetadataFormats) {
        for (AVMetadataItem *item in [asset metadataForFormat:format]) {
            NSString *identifier = item.identifier;
            if (![identifier isEqualToString:AVMetadataIdentifieriTunesMetadataLyrics] &&
                ![identifier isEqualToString:AVMetadataIdentifierID3MetadataUnsynchronizedLyric])
                continue;
            NSString *text = item.stringValue;
            if (!text.length)
                continue;
            BOOL timed = [text rangeOfString:@"^\\[\\d+:\\d+" options:NSRegularExpressionSearch].location != NSNotFound;
            YTMULyrics *lyrics = timed ? YTMUParseLRC(text) : YTMUUnsyncedLyrics(text, nil);
            if (lyrics)
                return lyrics;
        }
    }
    return nil;
}

// Some downloads at once, a short pause after each (YouTube doesn't like bursts)
static void YTMULyricsBackground(dispatch_block_t work) {
    static dispatch_queue_t queue;
    static dispatch_semaphore_t slots;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("frozenmusic.lyrics.prefetch", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_CONCURRENT, QOS_CLASS_UTILITY, 0));
        slots = dispatch_semaphore_create(3);
    });
    dispatch_async(queue, ^{
        dispatch_semaphore_wait(slots, DISPATCH_TIME_FOREVER);
        work();
        [NSThread sleepForTimeInterval:0.15];
        dispatch_semaphore_signal(slots);
    });
}

static void YTMUPrefetchLyricsAttempt(NSString *key, NSString *videoID, NSString *title, NSString *artist, NSTimeInterval duration, NSInteger attempt) {
    YTMULyricsBackground(^{
        NSDictionary *saved = YTMULyricsRead(key);
        if (saved[@"lines"] || YTMULyricsMissingIsFresh(saved))
            return;
        BOOL unreliable = NO;
        YTMUFetchAndSave(key, videoID, title, artist, duration, &unreliable);
        // No internet / rate limited: try again a bit later
        if (unreliable && attempt < 3) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20 * (attempt + 1) * NSEC_PER_SEC)), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                YTMUPrefetchLyricsAttempt(key, videoID, title, artist, duration, attempt + 1);
            });
        }
    });
}

void YTMUPrefetchLyrics(NSString *videoID, NSString *title, NSString *artist, NSTimeInterval duration) {
    NSString *key = YTMULyricsKey(videoID, title, artist);
    if (key)
        YTMUPrefetchLyricsAttempt(key, videoID, title, artist, duration, 0);
}

NSString *YTMULyricsForDownload(NSString *videoID, NSString *title, NSString *artist, NSTimeInterval duration) {
    NSString *key = YTMULyricsKey(videoID, title, artist);
    if (!key)
        return nil;
    NSDictionary *saved = YTMULyricsRead(key);
    YTMULyrics *lyrics = YTMULyricsFromJSON(saved);
    if (!lyrics && !YTMULyricsMissingIsFresh(saved)) {
        BOOL unreliable = NO;
        lyrics = YTMUFetchAndSave(key, videoID, title, artist, duration, &unreliable);
        if (!lyrics && unreliable) // one more try, then the background retries take over
            lyrics = YTMUFetchAndSave(key, videoID, title, artist, duration, &unreliable);
        if (!lyrics && unreliable)
            YTMUPrefetchLyrics(videoID, title, artist, duration);
    }
    return lyrics ? YTMULyricsLRC(lyrics) : nil;
}

#pragma mark - YTMULyrics

@implementation YTMULyrics

+ (NSString *)keyForTrack:(YTMUOfflineTrack *)track {
    return YTMULyricsKey(track.videoID, track.title, track.artist);
}

// Saved in the app, else written into the file itself (then saved for next time)
+ (YTMULyrics *)savedLyricsForTrack:(YTMUOfflineTrack *)track {
    NSString *key = [self keyForTrack:track];
    YTMULyrics *lyrics = YTMULyricsFromJSON(YTMULyricsRead(key));
    if (!lyrics) {
        lyrics = YTMUEmbeddedLyrics(track.url);
        if (lyrics && key)
            YTMULyricsWrite(key, YTMULyricsToJSON(lyrics));
    }
    return lyrics;
}

+ (void)loadForTrack:(YTMUOfflineTrack *)track completion:(void (^)(YTMULyrics *, BOOL))completion {
    NSString *key = [self keyForTrack:track];
    NSString *videoID = track.videoID, *title = track.title, *artist = track.artist;
    NSURL *url = track.url;
    NSTimeInterval duration = track.duration;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        YTMULyrics *lyrics = nil;
        BOOL offline = NO;
        NSDictionary *saved = YTMULyricsRead(key);
        if (saved[@"lines"])
            lyrics = YTMULyricsFromJSON(saved);
        if (!lyrics) {
            lyrics = YTMUEmbeddedLyrics(url);
            if (lyrics && key)
                YTMULyricsWrite(key, YTMULyricsToJSON(lyrics));
        }
        if (!lyrics && key && !YTMULyricsMissingIsFresh(saved))
            lyrics = YTMUFetchAndSave(key, videoID, title, artist, duration, &offline);
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(lyrics, offline);
        });
    });
}

+ (NSString *)deviceLanguageCode {
    NSString *preferred = [NSLocale preferredLanguages].firstObject ?: @"en";
    if ([preferred hasPrefix:@"zh-Hant"] || [preferred hasPrefix:@"zh-TW"] || [preferred hasPrefix:@"zh-HK"])
        return @"zh-TW";
    if ([preferred hasPrefix:@"zh"])
        return @"zh-CN";
    return [preferred componentsSeparatedByString:@"-"].firstObject.lowercaseString ?: @"en";
}

- (NSString *)languageCode {
    NSMutableString *text = [NSMutableString string];
    for (YTMULyricLine *line in self.lines) {
        if (![line.text isEqualToString:@"♪"])
            [text appendFormat:@"%@\n", line.text];
    }
    if (!text.length)
        return nil;
    NLLanguageRecognizer *recognizer = [NLLanguageRecognizer new];
    [recognizer processString:text];
    NSString *language = recognizer.dominantLanguage;
    return [language isEqualToString:NLLanguageUndetermined] ? nil : language;
}

// Google translate (what YTM's own "Translate" uses), lines joined by \n
static NSArray<NSString *> *YTMUTranslateChunk(NSArray<NSString *> *texts, NSString *target) {
    NSString *joined = [texts componentsJoinedByString:@"\n"];
    NSURLComponents *components = [NSURLComponents componentsWithString:@"https://translate.googleapis.com/translate_a/single"];
    components.queryItems = @[[NSURLQueryItem queryItemWithName:@"client" value:@"gtx"],
                              [NSURLQueryItem queryItemWithName:@"sl" value:@"auto"],
                              [NSURLQueryItem queryItemWithName:@"tl" value:target],
                              [NSURLQueryItem queryItemWithName:@"dt" value:@"t"],
                              [NSURLQueryItem queryItemWithName:@"q" value:joined]];
    NSData *data = components.URL ? YTMULyricsLoad([NSURLRequest requestWithURL:components.URL], NULL, NULL) : nil;
    NSArray *json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    NSArray *segments = [json isKindOfClass:[NSArray class]] && json.count ? json[0] : nil;
    if (![segments isKindOfClass:[NSArray class]])
        return nil;
    NSMutableString *translated = [NSMutableString string];
    for (NSArray *segment in segments) {
        if ([segment isKindOfClass:[NSArray class]] && segment.count && [segment[0] isKindOfClass:[NSString class]])
            [translated appendString:segment[0]];
    }
    NSMutableArray *result = [NSMutableArray array];
    for (NSString *line in [translated componentsSeparatedByString:@"\n"])
        [result addObject:[line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]];
    while (result.count > texts.count && ![result.lastObject length])
        [result removeLastObject];
    return result;
}

// Google (online): only lines with words, in chunks that keep the URL short. nil on failure
static NSArray<NSString *> *YTMUGoogleTranslateLines(NSArray<YTMULyricLine *> *lines, NSString *target) {
    NSMutableArray<NSNumber *> *indexes = [NSMutableArray array];
    for (NSUInteger i = 0; i < lines.count; i++) {
        NSString *text = lines[i].text;
        if (text.length && ![text isEqualToString:@"♪"])
            [indexes addObject:@(i)];
    }
    if (!indexes.count)
        return nil;
    NSMutableArray<NSString *> *result = [NSMutableArray array];
    for (NSUInteger i = 0; i < lines.count; i++)
        [result addObject:@""];
    NSUInteger start = 0;
    while (start < indexes.count) {
        NSMutableArray<NSString *> *chunk = [NSMutableArray array];
        NSUInteger size = 0;
        NSUInteger end = start;
        while (end < indexes.count) {
            NSString *text = lines[indexes[end].unsignedIntegerValue].text;
            NSUInteger encoded = [text stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]].length + 3;
            if (chunk.count && size + encoded > 1500)
                break;
            [chunk addObject:text];
            size += encoded;
            end++;
        }
        NSArray<NSString *> *translated = YTMUTranslateChunk(chunk, target);
        if (translated.count != chunk.count) {
            // Lines got merged: translate them one by one
            NSMutableArray *single = [NSMutableArray array];
            for (NSString *text in chunk) {
                NSArray *one = YTMUTranslateChunk(@[text], target);
                if (!one.count)
                    return nil;
                [single addObject:[one componentsJoinedByString:@" "]];
            }
            translated = single;
        }
        for (NSUInteger i = 0; i < chunk.count; i++)
            result[indexes[start + i].unsignedIntegerValue] = translated[i];
        start = end;
    }
    return result;
}

static NSString *const YTMUCreditOffline = @"Translated offline";
static NSString *const YTMUCreditGoogle = @"Translated by Google";

static void YTMUSaveTranslation(NSString *key, NSString *target, NSArray<NSString *> *translation, NSString *credit) {
    NSDictionary *saved = YTMULyricsRead(key);
    if (!saved[@"lines"])
        return;
    NSMutableDictionary *updated = [saved mutableCopy];
    NSMutableDictionary *all = [([saved[@"translations"] isKindOfClass:[NSDictionary class]] ? saved[@"translations"] : @{}) mutableCopy];
    all[target] = translation;
    all[[target stringByAppendingString:@"#credit"]] = credit;
    updated[@"translations"] = all;
    YTMULyricsWrite(key, updated);
}

// Offline translation: FrozenMLTranslate.framework (Google's on-device ML Kit models, iOS 15.5+)
// in the app's Frameworks folder, added by the GitHub Actions workflow and loaded on first use.
// nil when it isn't there (jailbreak .deb, local builds) or can't load
static Class YTMUOfflineTranslator(void) {
    static Class translator;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *path = [[NSBundle mainBundle].privateFrameworksPath stringByAppendingPathComponent:@"FrozenMLTranslate.framework/FrozenMLTranslate"];
        if (![[NSFileManager defaultManager] fileExistsAtPath:path])
            return;
        if (!dlopen(path.fileSystemRepresentation, RTLD_NOW)) {
            NSLog(@"[FrozenMusic] offline translation not loaded: %s", dlerror());
            return;
        }
        Class candidate = NSClassFromString(@"FMMLTranslator");
        SEL supported = NSSelectorFromString(@"isSupported");
        if (candidate && [candidate respondsToSelector:supported] &&
            [candidate respondsToSelector:NSSelectorFromString(@"translateTexts:source:target:completion:")] &&
            ((BOOL (*)(id, SEL))objc_msgSend)(candidate, supported))
            translator = candidate;
    });
    return translator;
}

+ (BOOL)canTranslateOnDevice {
    return YTMUOfflineTranslator() != nil;
}

// ML Kit wants plain language codes: "zh-Hans" / "zh-CN" -> "zh", "pt-BR" -> "pt"
static NSString *YTMUBaseLanguage(NSString *code) {
    return [code componentsSeparatedByString:@"-"].firstObject.lowercaseString;
}

// Offline model translation of the real lines (♪ / blank stay empty), completion on the main queue
static void YTMUTranslateOffline(NSArray<YTMULyricLine *> *lines, NSString *source, NSString *target, void (^completion)(NSArray<NSString *> *result, NSString *error)) {
    Class translator = YTMUOfflineTranslator();
    NSMutableArray<NSNumber *> *indexes = [NSMutableArray array];
    NSMutableArray<NSString *> *texts = [NSMutableArray array];
    for (NSUInteger i = 0; i < lines.count; i++) {
        NSString *text = lines[i].text;
        if (text.length && ![text isEqualToString:@"♪"]) {
            [indexes addObject:@(i)];
            [texts addObject:text];
        }
    }
    if (!translator || !texts.count || !source.length) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(nil, !source.length ? @"The language of these lyrics isn't clear" : @"Nothing to translate");
        });
        return;
    }
    void (^done)(NSArray<NSString *> *, NSString *) = ^(NSArray<NSString *> *translated, NSString *error) {
        if (translated.count != texts.count) {
            completion(nil, error.length ? error : @"Translation isn't available right now");
            return;
        }
        NSMutableArray<NSString *> *result = [NSMutableArray array];
        for (NSUInteger i = 0; i < lines.count; i++)
            [result addObject:@""];
        for (NSUInteger i = 0; i < indexes.count; i++)
            result[indexes[i].unsignedIntegerValue] = translated[i];
        completion(result, nil);
    };
    // ML Kit calls are made from the main queue
    dispatch_async(dispatch_get_main_queue(), ^{
        ((void (*)(id, SEL, NSArray *, NSString *, NSString *, void (^)(NSArray<NSString *> *, NSString *)))objc_msgSend)(
            translator, NSSelectorFromString(@"translateTexts:source:target:completion:"), texts, YTMUBaseLanguage(source), YTMUBaseLanguage(target), done);
    });
}

// Downloads: lyrics in another language get translated right away (model downloaded once),
// so Translate works offline instantly later
static void YTMUPretranslate(NSString *key, YTMULyrics *lyrics) {
    if (!key || !lyrics.lines.count || !YTMUOfflineTranslator())
        return;
    NSString *source = [lyrics languageCode];
    NSString *target = [YTMULyrics deviceLanguageCode];
    if (source.length < 2 || [YTMUBaseLanguage(source) isEqualToString:YTMUBaseLanguage(target)])
        return;
    NSDictionary *translations = YTMULyricsRead(key)[@"translations"];
    if ([translations isKindOfClass:[NSDictionary class]] && [translations[target] isKindOfClass:[NSArray class]])
        return;
    NSArray<YTMULyricLine *> *lines = lyrics.lines;
    YTMUTranslateOffline(lines, source, target, ^(NSArray<NSString *> *result, NSString *error) {
        if (!result)
            return;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            YTMUSaveTranslation(key, target, result, YTMUCreditOffline);
        });
    });
}

- (void)translationForTrack:(YTMUOfflineTrack *)track presenter:(UIViewController *)presenter completion:(void (^)(NSArray<NSString *> *, NSString *, NSString *))completion {
    NSString *key = [YTMULyrics keyForTrack:track];
    NSString *target = [YTMULyrics deviceLanguageCode];
    NSString *source = [self languageCode];
    NSArray<YTMULyricLine *> *lines = self.lines;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSDictionary *saved = YTMULyricsRead(key);
        NSDictionary *translations = [saved[@"translations"] isKindOfClass:[NSDictionary class]] ? saved[@"translations"] : @{};
        NSArray *cached = translations[target];
        NSString *cachedCredit = [translations[[target stringByAppendingString:@"#credit"]] isKindOfClass:[NSString class]] ? translations[[target stringByAppendingString:@"#credit"]] : YTMUCreditGoogle;
        dispatch_async(dispatch_get_main_queue(), ^{
            if ([cached isKindOfClass:[NSArray class]] && cached.count == lines.count) {
                completion(cached, cachedCredit, nil);
                return;
            }

            if (YTMUOfflineTranslator()) {
                // Offline model (downloaded once per language)
                YTMUTranslateOffline(lines, source, target, ^(NSArray<NSString *> *result, NSString *error) {
                    if (result) {
                        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                            YTMUSaveTranslation(key, target, result, YTMUCreditOffline);
                        });
                    }
                    completion(result, result ? YTMUCreditOffline : nil, error);
                });
                return;
            }

            // No offline translator in this build: Google (needs internet)
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                NSArray<NSString *> *result = YTMUGoogleTranslateLines(lines, target);
                if (result)
                    YTMUSaveTranslation(key, target, result, YTMUCreditGoogle);
                dispatch_async(dispatch_get_main_queue(), ^{
                    completion(result, YTMUCreditGoogle, result ? nil : @"Translation isn't available right now");
                });
            });
        });
    });
}

@end
