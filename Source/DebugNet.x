// TEMPORARY - delete after we know how YTM sends its stream ("player") requests.
// Records a short summary of the app's youtubei requests (no login values),
// and copies the report when you tap a download button.

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "Utils/MBProgressHUD/MBProgressHUD.h"

static NSMutableArray<NSString *> *ytmuNetLog = nil;
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

    @synchronized ([NSNull class]) {
        if (!ytmuNetLog)
            ytmuNetLog = [NSMutableArray array];
        ytmuYoutubeiCount++;

        if (![url.path containsString:@"player"])
            return;

        NSData *payload = body ?: request.HTTPBody;
        NSMutableArray *headerNames = [NSMutableArray array];
        for (NSString *key in request.allHTTPHeaderFields)
            [headerNames addObject:key];

        NSDictionary *h = request.allHTTPHeaderFields;
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
        if (ytmuNetLog.count > 6)
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

@interface ELMTouchCommandPropertiesHandler : NSObject
@end

%hook ELMTouchCommandPropertiesHandler
- (void)handleTap {
    @try {
        id node = class_getInstanceVariable([self class], "_controller") ? [self valueForKey:@"_controller"] : nil;
        NSString *key = [node respondsToSelector:NSSelectorFromString(@"key")] ? [node valueForKey:@"key"] : nil;
        if ([key isKindOfClass:[NSString class]] && [key isEqualToString:@"music_download_badge_1"]) {
            NSString *report;
            @synchronized ([NSNull class]) {
                report = [NSString stringWithFormat:@"YTMU net debug\nyoutubei requests seen: %lu\nplayer requests:\n%@",
                          (unsigned long)ytmuYoutubeiCount,
                          ytmuNetLog.count ? [ytmuNetLog componentsJoinedByString:@"\n"] : @"(none)"];
            }
            [UIPasteboard generalPasteboard].string = report;

            dispatch_async(dispatch_get_main_queue(), ^{
                UIWindow *window = [UIApplication sharedApplication].keyWindow;
                if (!window)
                    return;
                MBProgressHUD *hud = [MBProgressHUD showHUDAddedTo:window animated:YES];
                hud.mode = MBProgressHUDModeText;
                hud.userInteractionEnabled = NO;
                hud.label.text = @"Network debug copied";
                [hud hideAnimated:YES afterDelay:2.5];
            });
        }
    } @catch (__unused NSException *exception) {
    }
    %orig;
}
%end
