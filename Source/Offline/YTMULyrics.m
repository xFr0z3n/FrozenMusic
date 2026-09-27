#import "YTMULyrics.h"
#import "YTMUOfflinePlayer.h"
#import <CommonCrypto/CommonCrypto.h>
#import <NaturalLanguage/NaturalLanguage.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/message.h>
#import <dlfcn.h>

@implementation YTMULyricLine
@end

#pragma mark - Earlier versions kept lyrics inside the app: read once, moved to the Lyrics folder

static NSURL *YTMULegacyFile(NSString *videoID, NSString *title, NSString *artist) {
    NSURL *support = [[[NSFileManager defaultManager] URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask] firstObject];
    NSURL *folder = [[support URLByAppendingPathComponent:@"FrozenMusic" isDirectory:YES] URLByAppendingPathComponent:@"Lyrics" isDirectory:YES];
    NSCharacterSet *invalid = [[NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"] invertedSet];
    NSString *key = nil;
    if (videoID.length >= 6 && [videoID rangeOfCharacterFromSet:invalid].location == NSNotFound) {
        key = videoID;
    } else if (title.length) {
        NSString *text = [[NSString stringWithFormat:@"%@|%@", title, artist ?: @""] lowercaseString];
        const char *cString = text.UTF8String;
        unsigned char digest[CC_SHA1_DIGEST_LENGTH];
        CC_SHA1(cString, (CC_LONG)strlen(cString), digest);
        NSMutableString *hash = [NSMutableString stringWithString:@"t_"];
        for (int i = 0; i < 10; i++)
            [hash appendFormat:@"%02x", digest[i]];
        key = hash;
    }
    return key ? [folder URLByAppendingPathComponent:[key stringByAppendingPathExtension:@"json"]] : nil;
}

static YTMULyrics *YTMULegacyLyrics(NSString *videoID, NSString *title, NSString *artist) {
    NSURL *file = YTMULegacyFile(videoID, title, artist);
    NSData *data = file ? [NSData dataWithContentsOfURL:file] : nil;
    NSDictionary *json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    NSArray *rows = [json isKindOfClass:[NSDictionary class]] ? json[@"lines"] : nil;
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

static void YTMUForgetLegacyLyrics(NSString *videoID, NSString *title, NSString *artist) {
    NSURL *file = YTMULegacyFile(videoID, title, artist);
    if (file)
        [[NSFileManager defaultManager] removeItemAtURL:file error:nil];
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


// Lyrics as LRC text ("[mm:ss.xx] line" when synced)
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

// Lyrics the previous version wrote into downloaded files (©lyr / USLT): read once to move
// them into the Lyrics folder
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

#pragma mark - Lyrics files: "Lyrics/<song>.lrc" next to the songs
// (in the playlist / album folder, or in YTMusicUltimate for single songs)

NSURL *YTMULyricsFileForAudio(NSURL *audioURL) {
    if (!audioURL.isFileURL || !audioURL.lastPathComponent.length)
        return nil;
    NSURL *folder = [[audioURL URLByDeletingLastPathComponent] URLByAppendingPathComponent:@"Lyrics" isDirectory:YES];
    return [folder URLByAppendingPathComponent:[audioURL.lastPathComponent.stringByDeletingPathExtension stringByAppendingPathExtension:@"lrc"]];
}

static NSString *YTMULyricsTagValue(NSString *text) {
    NSString *flat = [[text componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]] componentsJoinedByString:@" "];
    return [flat stringByReplacingOccurrencesOfString:@"]" withString:@")"];
}

// Standard LRC: [ti:] [ar:] tags, our [source:] tag, then the lines
static NSString *YTMULyricsFileText(YTMULyrics *lyrics, NSString *title, NSString *artist) {
    NSMutableString *text = [NSMutableString string];
    if (title.length)
        [text appendFormat:@"[ti:%@]\n", YTMULyricsTagValue(title)];
    if (artist.length)
        [text appendFormat:@"[ar:%@]\n", YTMULyricsTagValue(artist)];
    if (lyrics.source.length)
        [text appendFormat:@"[source:%@]\n", YTMULyricsTagValue(lyrics.source)];
    NSString *body = YTMULyricsLRC(lyrics);
    if (body.length)
        [text appendFormat:@"%@\n", body];
    return text;
}

static YTMULyrics *YTMULyricsFromFileText(NSString *text) {
    NSRegularExpression *tag = [NSRegularExpression regularExpressionWithPattern:@"^\\[([A-Za-z]+):(.*)\\]\\s*$" options:0 error:nil];
    NSRegularExpression *timed = [NSRegularExpression regularExpressionWithPattern:@"^\\[\\d+:\\d+" options:0 error:nil];
    NSString *source = nil;
    BOOL synced = NO;
    NSMutableArray<NSString *> *rows = [NSMutableArray array];
    NSString *unified = [[text stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"] stringByReplacingOccurrencesOfString:@"\r" withString:@"\n"];
    for (NSString *row in [unified componentsSeparatedByString:@"\n"]) {
        NSTextCheckingResult *match = [tag firstMatchInString:row options:0 range:NSMakeRange(0, row.length)];
        if (match) {
            if ([[[row substringWithRange:[match rangeAtIndex:1]] lowercaseString] isEqualToString:@"source"])
                source = [[row substringWithRange:[match rangeAtIndex:2]] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            continue;
        }
        if ([timed firstMatchInString:row options:0 range:NSMakeRange(0, row.length)])
            synced = YES;
        [rows addObject:row];
    }
    NSString *body = [rows componentsJoinedByString:@"\n"];
    YTMULyrics *lyrics = synced ? YTMUParseLRC(body) : YTMUUnsyncedLyrics(body, nil);
    lyrics.source = source.length ? source : nil;
    return lyrics;
}

static YTMULyrics *YTMUReadLyricsFile(NSURL *audioURL) {
    NSURL *file = YTMULyricsFileForAudio(audioURL);
    NSString *text = file ? [NSString stringWithContentsOfURL:file encoding:NSUTF8StringEncoding error:nil] : nil;
    return text.length ? YTMULyricsFromFileText(text) : nil;
}

static BOOL YTMUWriteLyricsFile(NSURL *audioURL, YTMULyrics *lyrics, NSString *title, NSString *artist) {
    NSURL *file = YTMULyricsFileForAudio(audioURL);
    if (!file || !lyrics.lines.count)
        return NO;
    [[NSFileManager defaultManager] createDirectoryAtURL:[file URLByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:nil];
    return [YTMULyricsFileText(lyrics, title, artist) writeToURL:file atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

void YTMUMoveLyrics(NSURL *fromAudioURL, NSURL *toAudioURL) {
    NSURL *from = YTMULyricsFileForAudio(fromAudioURL), *to = YTMULyricsFileForAudio(toAudioURL);
    NSFileManager *fm = [NSFileManager defaultManager];
    if (!from || !to || [from isEqual:to] || ![fm fileExistsAtPath:from.path])
        return;
    [fm createDirectoryAtURL:[to URLByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:nil];
    [fm removeItemAtURL:to error:nil];
    [fm moveItemAtURL:from toURL:to error:nil];
}

void YTMUDeleteLyrics(NSURL *audioURL) {
    NSURL *file = YTMULyricsFileForAudio(audioURL);
    if (!file)
        return;
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm removeItemAtURL:file error:nil];
    NSURL *folder = [file URLByDeletingLastPathComponent];
    if (![fm contentsOfDirectoryAtPath:folder.path error:nil].count)
        [fm removeItemAtURL:folder error:nil];
}

void YTMUCleanLyricsFolder(NSURL *folder) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSURL *lyricsFolder = [folder URLByAppendingPathComponent:@"Lyrics" isDirectory:YES];
    NSArray<NSURL *> *lyricsFiles = [fm contentsOfDirectoryAtURL:lyricsFolder includingPropertiesForKeys:nil options:NSDirectoryEnumerationSkipsHiddenFiles error:nil];
    if (!lyricsFiles.count)
        return;
    NSMutableSet<NSString *> *songs = [NSMutableSet set];
    for (NSURL *file in [fm contentsOfDirectoryAtURL:folder includingPropertiesForKeys:nil options:NSDirectoryEnumerationSkipsHiddenFiles error:nil]) {
        NSString *extension = file.pathExtension.lowercaseString;
        if ([extension isEqualToString:@"m4a"] || [extension isEqualToString:@"mp3"])
            [songs addObject:file.lastPathComponent.stringByDeletingPathExtension];
    }
    // Lyrics of songs that are gone
    for (NSURL *file in lyricsFiles) {
        if ([file.pathExtension.lowercaseString isEqualToString:@"lrc"] && ![songs containsObject:file.lastPathComponent.stringByDeletingPathExtension])
            [fm removeItemAtURL:file error:nil];
    }
    if (![fm contentsOfDirectoryAtPath:lyricsFolder.path error:nil].count)
        [fm removeItemAtURL:lyricsFolder error:nil];
}

static void YTMUPrepareOfflineTranslation(YTMULyrics *lyrics);

// Lyrics file of a song: already there, moved over from an earlier version, else fetched.
// *unreliable: no internet / YouTube busy (worth trying again later)
static YTMULyrics *YTMUEnsureLyricsFile(NSURL *audioURL, NSString *videoID, NSString *title, NSString *artist, NSTimeInterval duration, BOOL *unreliable) {
    YTMULyrics *lyrics = YTMUReadLyricsFile(audioURL);
    if (lyrics)
        return lyrics;
    lyrics = YTMULegacyLyrics(videoID, title, artist) ?: YTMUEmbeddedLyrics(audioURL);
    BOOL noNetwork = NO;
    if (!lyrics)
        lyrics = YTMUFetchLyrics(videoID, title, artist, duration, &noNetwork);
    if (lyrics && YTMUWriteLyricsFile(audioURL, lyrics, title, artist)) {
        YTMUForgetLegacyLyrics(videoID, title, artist);
        // Other language: get the offline translation model now, while there's internet
        YTMUPrepareOfflineTranslation(lyrics);
    }
    if (unreliable)
        *unreliable = !lyrics && noNetwork;
    return lyrics;
}

BOOL YTMUSaveLyricsForDownload(NSURL *audioURL, NSString *videoID, NSString *title, NSString *artist, NSTimeInterval duration) {
    BOOL unreliable = NO;
    YTMULyrics *lyrics = YTMUEnsureLyricsFile(audioURL, videoID, title, artist, duration, &unreliable);
    if (!lyrics && unreliable) {
        // YouTube busy / connection hiccup: once more after a moment
        [NSThread sleepForTimeInterval:2];
        lyrics = YTMUEnsureLyricsFile(audioURL, videoID, title, artist, duration, NULL);
    }
    return lyrics != nil;
}

// A few at once, a short pause after each (YouTube doesn't like bursts)
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

void YTMUPrefetchLyricsForSong(NSURL *audioURL, NSString *videoID, NSString *title, NSString *artist, NSTimeInterval duration) {
    NSURL *file = YTMULyricsFileForAudio(audioURL);
    if (!file || [[NSFileManager defaultManager] fileExistsAtPath:file.path])
        return;
    // Once per song and app launch (songs without lyrics aren't asked over and over)
    static NSMutableSet<NSString *> *asked;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        asked = [NSMutableSet set];
    });
    @synchronized (asked) {
        if ([asked containsObject:audioURL.path])
            return;
        [asked addObject:audioURL.path];
    }
    YTMULyricsBackground(^{
        YTMUSaveLyricsForDownload(audioURL, videoID, title, artist, duration);
    });
}


#pragma mark - YTMULyrics

@implementation YTMULyrics

+ (YTMULyrics *)savedLyricsForTrack:(YTMUOfflineTrack *)track {
    return YTMUReadLyricsFile(track.url);
}

+ (void)loadForTrack:(YTMUOfflineTrack *)track completion:(void (^)(YTMULyrics *, BOOL))completion {
    NSString *videoID = track.videoID, *title = track.title, *artist = track.artist;
    NSURL *url = track.url;
    NSTimeInterval duration = track.duration;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        BOOL offline = NO;
        YTMULyrics *lyrics = YTMUEnsureLyricsFile(url, videoID, title, artist, duration, &offline);
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


#pragma mark - Translation: Google with internet, the offline model without

static NSString *const YTMUCreditOffline = @"Translated offline";
static NSString *const YTMUCreditGoogle = @"Translated by Google";

// FrozenMLTranslate.framework (Google's on-device ML Kit models, iOS 15.5+) in the app's
// Frameworks folder, added by the GitHub Actions workflow and loaded on first use.
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
        if (candidate && [candidate respondsToSelector:NSSelectorFromString(@"translateTexts:source:target:completion:")] &&
            [candidate respondsToSelector:NSSelectorFromString(@"prepareSource:target:")])
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

// Downloads the offline model for these lyrics' language (once, in the background) so
// translating works later without internet. Nothing is translated here.
static void YTMUPrepareOfflineTranslation(YTMULyrics *lyrics) {
    NSString *source = YTMUBaseLanguage([lyrics languageCode]);
    NSString *target = YTMUBaseLanguage([YTMULyrics deviceLanguageCode]);
    if (source.length < 2 || target.length < 2 || [source isEqualToString:target])
        return;
    dispatch_async(dispatch_get_main_queue(), ^{
        Class translator = YTMUOfflineTranslator();
        if (translator)
            ((void (*)(id, SEL, NSString *, NSString *))objc_msgSend)(translator, NSSelectorFromString(@"prepareSource:target:"), source, target);
    });
}

// Offline model, only with its language downloaded (never waits for the internet).
// Completion on the main queue, always within 20 seconds
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
    if (!translator || !texts.count || source.length < 2) {
        completion(nil, !translator ? @"No internet connection" : @"Translation isn't available for these lyrics");
        return;
    }
    __block BOOL finished = NO;
    void (^finish)(NSArray<NSString *> *, NSString *) = ^(NSArray<NSString *> *result, NSString *error) {
        if (finished)
            return;
        finished = YES;
        completion(result, error);
    };
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        finish(nil, @"Offline translation didn't respond");
    });
    void (^done)(NSArray<NSString *> *, NSString *) = ^(NSArray<NSString *> *translated, NSString *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (translated.count != texts.count) {
                finish(nil, error.length ? error : @"Translation isn't available right now");
                return;
            }
            NSMutableArray<NSString *> *result = [NSMutableArray array];
            for (NSUInteger i = 0; i < lines.count; i++)
                [result addObject:@""];
            for (NSUInteger i = 0; i < indexes.count; i++)
                result[indexes[i].unsignedIntegerValue] = translated[i];
            finish(result, nil);
        });
    };
    ((void (*)(id, SEL, NSArray *, NSString *, NSString *, void (^)(NSArray<NSString *> *, NSString *)))objc_msgSend)(
        translator, NSSelectorFromString(@"translateTexts:source:target:completion:"), texts, YTMUBaseLanguage(source), YTMUBaseLanguage(target), done);
}

- (void)translationForTrack:(YTMUOfflineTrack *)track presenter:(UIViewController *)presenter completion:(void (^)(NSArray<NSString *> *, NSString *, NSString *))completion {
    NSString *target = [YTMULyrics deviceLanguageCode];
    NSString *source = [self languageCode];
    NSArray<YTMULyricLine *> *lines = self.lines;
    YTMULyrics *lyrics = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        // With internet: Google
        NSArray<NSString *> *online = YTMUGoogleTranslateLines(lines, target);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (online) {
                completion(online, YTMUCreditGoogle, nil);
                // Offline model for next time
                YTMUPrepareOfflineTranslation(lyrics);
                return;
            }
            // No internet (or Google unreachable): the offline model
            YTMUTranslateOffline(lines, source, target, ^(NSArray<NSString *> *result, NSString *error) {
                completion(result, result ? YTMUCreditOffline : nil, error);
            });
        });
    });
}

@end
