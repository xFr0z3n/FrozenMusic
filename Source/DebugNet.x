// TEMPORARY - delete after we know how YTM sends its stream ("player") requests.
// Records a short summary of the app's youtubei requests (no login values),
// Shake the phone to copy the report.

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "Utils/MBProgressHUD/MBProgressHUD.h"

static NSMutableArray<NSString *> *ytmuNetLog = nil;
static NSMutableDictionary<NSString *, NSNumber *> *ytmuPathCounts = nil;
static NSUInteger ytmuYoutubeiCount = 0;

static NSString *YTMUHexPrefix(NSData *data, NSUInteger count) {
    NSMutableString *hex = [NSMutableString string];
    const uint8_t *bytes = data.bytes;
    for (NSUInteger i = 0; i < MIN(count, data.length); i++)
        [hex appendFormat:@"%02x", bytes[i]];
    return hex;
}

// Looks for a protobuf string field of length 11 (like a video ID)
static NSString *YTMUFindVideoIDField(NSData *data) {
    const uint8_t *b = data.bytes;
    NSUInteger n = data.length;
    for (NSUInteger i = 0; i + 13 <= n; i++) {
        if (b[i + 1] != 0x0B)
            continue;
        BOOL ok = YES;
        for (NSUInteger j = 0; j < 11; j++) {
            uint8_t c = b[i + 2 + j];
            if (!((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_' || c == '-')) {
                ok = NO;
                break;
            }
        }
        if (ok)
            return [NSString stringWithFormat:@"tag 0x%02x at %lu: %@", b[i],
                    (unsigned long)i, [[NSString alloc] initWithBytes:b + i + 2 length:11 encoding:NSASCIIStringEncoding]];
    }
    return @"none";
}

static void YTMURecordRequest(NSURLRequest *request, NSData *body, NSString *method, id session) {
    NSURL *url = request.URL;
    if (![url.absoluteString containsString:@"youtubei"])
        return;

    NSDictionary *h = request.allHTTPHeaderFields;

    // Skip the tweak's own playlist requests (JSON with only 4-5 basic headers)
    NSString *contentType = h[@"Content-Type"] ?: h[@"content-type"];
    if ([contentType containsString:@"json"] && h.count <= 5)
        return;

    // "task resume" duplicates dataTask entries, only count it for the path list
    BOOL isResume = [method isEqualToString:@"task resume"];

    @synchronized ([NSNull class]) {
        if (!ytmuNetLog)
            ytmuNetLog = [NSMutableArray array];
        if (!ytmuPathCounts)
            ytmuPathCounts = [NSMutableDictionary dictionary];

        if (isResume) {
            ytmuYoutubeiCount++;
            NSString *path = url.path ?: @"?";
            ytmuPathCounts[path] = @(ytmuPathCounts[path].integerValue + 1);
        }

        NSString *lowerPath = url.path.lowercaseString;
        BOOL interesting = [lowerPath containsString:@"player"] || [lowerPath containsString:@"watch"];
        if (!interesting)
            return;

        // Upload tasks carry the body separately, prefer that entry
        NSData *payload = body ?: request.HTTPBody;
        if (isResume && !payload)
            return;

        NSMutableArray *headerNames = [NSMutableArray array];
        for (NSString *key in h)
            [headerNames addObject:key];
        NSString *entry = [NSString stringWithFormat:
            @"--- %@ via %@ (%@)\nhost: %@ path: %@\ncontent-type: %@\ncontent-encoding: %@\nclient: %@ %@\nheaders: %@\nbody: %lu bytes%@, starts %@\nvideo-id field: %@",
            method, NSStringFromClass([session class]), [NSDate date],
            url.host, url.path,
            h[@"Content-Type"] ?: h[@"content-type"] ?: @"-",
            h[@"Content-Encoding"] ?: h[@"content-encoding"] ?: @"-",
            h[@"X-YouTube-Client-Name"] ?: h[@"x-youtube-client-name"] ?: @"-",
            h[@"X-YouTube-Client-Version"] ?: h[@"x-youtube-client-version"] ?: @"-",
            [headerNames componentsJoinedByString:@", "],
            (unsigned long)payload.length,
            request.HTTPBodyStream ? @" (+stream)" : @"",
            YTMUHexPrefix(payload, 12),
            payload ? YTMUFindVideoIDField(payload) : @"-"];

        [ytmuNetLog addObject:entry];
        if (ytmuNetLog.count > 8)
            [ytmuNetLog removeObjectAtIndex:0];
    }
}

%hook NSURLSession
- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request {
    YTMURecordRequest(request, nil, @"dataTask", self);
    return %orig;
}
- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler {
    YTMURecordRequest(request, nil, @"dataTask+block", self);
    return %orig;
}
- (NSURLSessionUploadTask *)uploadTaskWithRequest:(NSURLRequest *)request fromData:(NSData *)bodyData {
    YTMURecordRequest(request, bodyData, @"uploadTask", self);
    return %orig;
}
- (NSURLSessionUploadTask *)uploadTaskWithRequest:(NSURLRequest *)request fromData:(NSData *)bodyData completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler {
    YTMURecordRequest(request, bodyData, @"uploadTask+block", self);
    return %orig;
}
%end

// Catches tasks created through subclasses / other paths too
@interface __NSCFLocalSessionTask : NSURLSessionTask
@end

%hook __NSCFLocalSessionTask
- (void)resume {
    NSURLRequest *request = self.originalRequest;
    if (request)
        YTMURecordRequest(request, nil, @"task resume", self);
    %orig;
}
%end

// Shake the phone to copy the report (the download button can't be used,
// because Downloading.x handles that tap first and doesn't pass it on)
%hook UIWindow
- (void)motionEnded:(UIEventSubtype)motion withEvent:(UIEvent *)event {
    %orig;
    if (motion != UIEventSubtypeMotionShake)
        return;

    NSString *report;
    @synchronized ([NSNull class]) {
        NSMutableArray *paths = [NSMutableArray array];
        for (NSString *path in [ytmuPathCounts keysSortedByValueUsingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b) { return [b compare:a]; }])
            [paths addObject:[NSString stringWithFormat:@"%@ x%@", path, ytmuPathCounts[path]]];

        report = [NSString stringWithFormat:@"YTMU net debug v2\napp youtubei requests: %lu\npaths:\n%@\n\nwatch/player requests:\n%@",
                  (unsigned long)ytmuYoutubeiCount,
                  paths.count ? [paths componentsJoinedByString:@"\n"] : @"(none)",
                  ytmuNetLog.count ? [ytmuNetLog componentsJoinedByString:@"\n"] : @"(none)"];
    }
    [UIPasteboard generalPasteboard].string = report;

    MBProgressHUD *hud = [MBProgressHUD showHUDAddedTo:self animated:YES];
    hud.mode = MBProgressHUDModeText;
    hud.userInteractionEnabled = NO;
    hud.label.text = @"Network debug copied";
    hud.detailsLabel.text = [NSString stringWithFormat:@"%lu requests seen", (unsigned long)ytmuYoutubeiCount];
    [hud hideAnimated:YES afterDelay:2.5];
}
%end
