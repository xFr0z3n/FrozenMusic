#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "FFMpegDownloader.h"
#import "PlaylistDownloader.h"
#import "Headers/YTUIResources.h"
#import "Headers/YTMActionSheetController.h"
#import "Headers/YTMActionRowView.h"
#import "Headers/YTIPlayerOverlayRenderer.h"
#import "Headers/YTIPlayerOverlayActionSupportedRenderers.h"
#import "Headers/YTMNowPlayingViewController.h"
#import "Headers/YTPlayerView.h"
#import "Headers/YTIThumbnailDetails_Thumbnail.h"
#import "Headers/YTIFormatStream.h"
#import "Headers/YTAlertView.h"
#import "Headers/ELMNodeController.h"

// -----------------------------------------------------------------------------
// Downloading.x (rewritten)
//
// Old version crashed on newer YTM: it assumed
//   NowPlayingVC.parentViewController.playerViewController.playerResponse
// and one of those links no longer exists -> unrecognized selector -> crash.
//
// New version searches around the Now Playing screen for the player response,
// checking every step first, so a missing link just means "not found" instead
// of a crash. Output is a tagged .m4a (title, artist, album, album artist,
// video link) with the cover embedded.
// -----------------------------------------------------------------------------

static BOOL YTMU(NSString *key) {
    NSDictionary *YTMUltimateDict = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"YTMUltimate"];
    return [YTMUltimateDict[key] boolValue];
}

@interface UIView ()
- (UIViewController *)_viewControllerForAncestor;
@end

#pragma mark - Track info

@interface YTMUTrackInfo : NSObject
@property (nonatomic, strong) YTPlayerResponse *playerResponse;
@property (nonatomic, strong) id playerViewController; // may be nil
@end

@implementation YTMUTrackInfo
@end

#pragma mark - Safe lookup helpers

// Reads `key` from `object` only if it really exists. Never throws, never crashes.
// Plain names use the getter, "_names" read the instance variable directly.
static id YTMUSafeValue(id object, NSString *key) {
    if (!object || key.length == 0)
        return nil;

    if ([key hasPrefix:@"_"]) {
        Ivar ivar = class_getInstanceVariable([object class], key.UTF8String);
        if (!ivar)
            return nil;
        const char *type = ivar_getTypeEncoding(ivar);
        if (!type || type[0] != '@')
            return nil;
    } else {
        SEL selector = NSSelectorFromString(key);
        if (![object respondsToSelector:selector])
            return nil;
        NSMethodSignature *signature = [object methodSignatureForSelector:selector];
        if (!signature || signature.numberOfArguments != 2 || signature.methodReturnType[0] != '@')
            return nil;
    }

    @try {
        return [object valueForKey:key];
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static NSString *YTMUSafeString(id object, NSString *key) {
    id value = YTMUSafeValue(object, key);
    return [value isKindOfClass:[NSString class]] ? value : nil;
}

static NSString *YTMUManifestURL(id playerResponse) {
    id playerData = YTMUSafeValue(playerResponse, @"playerData");
    id streamingData = YTMUSafeValue(playerData, @"streamingData");
    return YTMUSafeString(streamingData, @"hlsManifestURL");
}

// Walks outwards from the Now Playing screen (breadth-first, limited) until it
// finds a player response that has a stream manifest.
static YTMUTrackInfo *YTMUFindTrack(NSArray *startObjects) {
    Class responseClass = NSClassFromString(@"YTPlayerResponse");
    if (!responseClass)
        return nil;

    NSArray<NSString *> *keys = @[
        @"playerResponse", @"_playerResponse",
        @"playerViewController", @"_playerViewController",
        @"playerController", @"_playerController",
        @"player", @"_player",
        @"playerViewDelegate", @"_playerViewDelegate",
        @"parentViewController", @"parentResponder", @"_parentResponder",
        @"delegate", @"_delegate"
    ];

    NSHashTable *visited = [NSHashTable hashTableWithOptions:NSPointerFunctionsObjectPointerPersonality |
                                                             NSPointerFunctionsWeakMemory];
    NSMutableArray *queue = [NSMutableArray array];
    NSMutableArray<NSNumber *> *depths = [NSMutableArray array];

    for (id object in startObjects) {
        if (object) {
            [queue addObject:object];
            [depths addObject:@0];
        }
    }

    id lastPlayerVC = nil;
    NSUInteger inspected = 0;

    while (queue.count > 0 && inspected < 300) {
        id object = queue.firstObject;
        NSInteger depth = depths.firstObject.integerValue;
        [queue removeObjectAtIndex:0];
        [depths removeObjectAtIndex:0];

        if ([visited containsObject:object])
            continue;
        [visited addObject:object];
        inspected++;

        if ([object isKindOfClass:responseClass]) {
            if (YTMUManifestURL(object).length > 0) {
                YTMUTrackInfo *info = [YTMUTrackInfo new];
                info.playerResponse = object;
                info.playerViewController = lastPlayerVC;
                return info;
            }
            continue;
        }

        // Remember the player controller for video ID / duration
        if ([object respondsToSelector:@selector(contentVideoID)] &&
            [object respondsToSelector:@selector(playerResponse)])
            lastPlayerVC = object;

        if (depth >= 7)
            continue;

        for (NSString *key in keys) {
            id next = YTMUSafeValue(object, key);
            if (next && ![visited containsObject:next]) {
                [queue addObject:next];
                [depths addObject:@(depth + 1)];
            }
        }
    }

    return nil;
}

static UIViewController *YTMUNowPlayingController(UIView *view) {
    UIViewController *vc = [view respondsToSelector:@selector(_viewControllerForAncestor)] ? view._viewControllerForAncestor : nil;
    Class nowPlayingClass = NSClassFromString(@"YTMNowPlayingViewController");

    for (UIViewController *current = vc; current; current = current.parentViewController) {
        if ((nowPlayingClass && [current isKindOfClass:nowPlayingClass]) ||
            [NSStringFromClass([current class]) containsString:@"NowPlaying"])
            return current;
    }
    return nil;
}

#pragma mark - Stream lookup for the playlist downloader

static void YTMUAddPlayerScreens(UIViewController *vc, NSMutableArray *output, NSUInteger depth) {
    if (!vc || depth > 12)
        return;
    NSString *name = NSStringFromClass([vc class]);
    if ([name containsString:@"NowPlaying"] || [name containsString:@"Watch"] || [name containsString:@"PlayerViewController"])
        [output addObject:vc];
    for (UIViewController *child in vc.childViewControllers)
        YTMUAddPlayerScreens(child, output, depth + 1);
    YTMUAddPlayerScreens(vc.presentedViewController, output, depth + 1);
}

// Same kind of search as the single-song download, but it only accepts the
// stream of `videoID`. Returns @{hls, author} or @{diag} describing what it saw.
NSDictionary *YTMUStreamInfoForVideo(NSArray *startObjects, NSString *videoID) {
    Class wrapperClass = NSClassFromString(@"YTPlayerResponse");
    Class protoClass = NSClassFromString(@"YTIPlayerResponse");

    NSMutableArray *starts = [NSMutableArray array];
    for (id object in startObjects) {
        if (object && object != [NSNull null])
            [starts addObject:object];
    }
    YTMUAddPlayerScreens([UIApplication sharedApplication].keyWindow.rootViewController, starts, 0);

    NSArray<NSString *> *keys = @[
        @"playerResponse", @"_playerResponse", @"playerData", @"_playerData",
        @"activeVideo", @"_activeVideo", @"singleVideo", @"_singleVideo",
        @"contentVideo", @"_contentVideo", @"videoController", @"_videoController",
        @"playerViewController", @"_playerViewController",
        @"playerController", @"_playerController",
        @"player", @"_player",
        @"playerViewDelegate", @"_playerViewDelegate",
        @"parentViewController", @"parentResponder", @"_parentResponder",
        @"delegate", @"_delegate"
    ];

    NSHashTable *visited = [NSHashTable hashTableWithOptions:NSPointerFunctionsObjectPointerPersonality | NSPointerFunctionsWeakMemory];
    NSMutableArray *queue = [starts mutableCopy];
    NSMutableArray<NSNumber *> *depths = [NSMutableArray array];
    for (NSUInteger i = 0; i < queue.count; i++)
        [depths addObject:@0];

    NSMutableArray<NSString *> *seen = [NSMutableArray array];
    NSUInteger inspected = 0;

    while (queue.count > 0 && inspected < 600) {
        id object = queue.firstObject;
        NSInteger depth = depths.firstObject.integerValue;
        [queue removeObjectAtIndex:0];
        [depths removeObjectAtIndex:0];
        if ([visited containsObject:object])
            continue;
        [visited addObject:object];
        inspected++;

        id proto = nil;
        if (wrapperClass && [object isKindOfClass:wrapperClass])
            proto = YTMUSafeValue(object, @"playerData");
        else if (protoClass && [object isKindOfClass:protoClass])
            proto = object;

        if (proto) {
            NSString *hls = YTMUSafeString(YTMUSafeValue(proto, @"streamingData"), @"hlsManifestURL");
            id details = YTMUSafeValue(proto, @"videoDetails");
            NSString *responseID = YTMUSafeString(details, @"videoId");
            if (hls.length && (!responseID.length || [responseID isEqualToString:videoID])) {
                NSMutableDictionary *result = [NSMutableDictionary dictionary];
                result[@"hls"] = hls;
                NSString *author = YTMUSafeString(details, @"author");
                if (author)
                    result[@"author"] = author;
                NSString *title = YTMUSafeString(details, @"title");
                if (title)
                    result[@"title"] = title;
                return result;
            }
            NSString *note = [NSString stringWithFormat:@"%@%@", responseID.length ? responseID : @"?", hls.length ? @"+hls" : @"-hls"];
            if (![seen containsObject:note] && seen.count < 6)
                [seen addObject:note];
            continue;
        }

        if (depth >= 8)
            continue;

        for (NSString *key in keys) {
            id next = YTMUSafeValue(object, key);
            if (next && ![visited containsObject:next]) {
                [queue addObject:next];
                [depths addObject:@(depth + 1)];
            }
        }
    }

    NSString *diag = [NSString stringWithFormat:@"want %@, found %@, %lu objects checked",
                      videoID ?: @"?", seen.count ? [seen componentsJoinedByString:@" "] : @"no player data", (unsigned long)inspected];
    return @{@"diag": diag};
}

#pragma mark - Playlist page helpers

// Download badge inside a page header (playlist, album, ...) and not Now Playing
static BOOL YTMUIsCollectionHeader(UIView *view) {
    UIViewController *vc = [view respondsToSelector:@selector(_viewControllerForAncestor)] ? view._viewControllerForAncestor : nil;
    BOOL header = NO;
    for (UIViewController *current = vc; current; current = current.parentViewController) {
        NSString *name = NSStringFromClass([current class]);
        if ([name containsString:@"NowPlaying"])
            return NO;
        if ([name containsString:@"Header"])
            header = YES;
    }
    return header;
}

// Reads "VLPL..." the same way YTMTab.x reads its tab's browse ID
static NSString *YTMUBrowseIDOfController(id controller) {
    id navEndpoint = YTMUSafeValue(controller, @"_navEndpoint") ?: YTMUSafeValue(controller, @"_navigationEndpoint");
    id browseEndpoint = YTMUSafeValue(navEndpoint, @"browseEndpoint");
    return YTMUSafeString(browseEndpoint, @"browseId");
}

static NSString *YTMUBrowseIDInTree(UIViewController *vc, UIView *view, Class browseClass, NSUInteger depth) {
    if (!vc || depth > 12)
        return nil;
    if ([vc isKindOfClass:browseClass] && vc.isViewLoaded && [view isDescendantOfView:vc.view]) {
        NSString *browseID = YTMUBrowseIDOfController(vc);
        if ([browseID hasPrefix:@"VL"] || [browseID hasPrefix:@"MPREb_"])
            return browseID;
    }
    for (UIViewController *child in vc.childViewControllers) {
        NSString *found = YTMUBrowseIDInTree(child, view, browseClass, depth + 1);
        if (found)
            return found;
    }
    return YTMUBrowseIDInTree(vc.presentedViewController, view, browseClass, depth + 1);
}

// Playlist pages prefer playlist IDs, album pages prefer album IDs
static BOOL YTMUPreferPlaylistIDs = YES;

// Finds a playlist/album ID in a string, best match for the current page type
static NSString *YTMUCollectionIDInString(NSString *text) {
    if (text.length == 0)
        return nil;
    static NSRegularExpression *regex = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        regex = [NSRegularExpression regularExpressionWithPattern:@"(MPREb_[A-Za-z0-9_-]{5,}|VL[A-Za-z0-9_-]{10,}|OLAK5uy_[A-Za-z0-9_-]{5,}|PL[A-Za-z0-9_-]{16,})" options:0 error:nil];
    });

    NSString *best = nil;
    NSInteger bestRank = 99;
    for (NSTextCheckingResult *match in [regex matchesInString:text options:0 range:NSMakeRange(0, text.length)]) {
        NSString *candidate = [text substringWithRange:match.range];
        NSInteger rank;
        if (YTMUPreferPlaylistIDs)
            rank = [candidate hasPrefix:@"VL"] ? 0 : [candidate hasPrefix:@"PL"] ? 1 : [candidate hasPrefix:@"OLAK5uy_"] ? 2 : 3;
        else
            rank = [candidate hasPrefix:@"MPREb_"] ? 0 : [candidate hasPrefix:@"OLAK5uy_"] ? 1 : [candidate hasPrefix:@"VL"] ? 2 : 3;
        if (rank < bestRank) {
            best = candidate;
            bestRank = rank;
        }
    }
    return best;
}

// Looks through an object's own YT* fields (and one level deeper) for an ID
static NSString *YTMUScanObjectForID(id object, NSInteger depth, NSHashTable *seen) {
    if (!object || [seen containsObject:object])
        return nil;
    [seen addObject:object];

    if ([object isKindOfClass:[NSString class]])
        return YTMUCollectionIDInString(object);

    NSString *className = NSStringFromClass([object class]);
    // Protobuf models (YTI...) print all their fields in their description
    if ([className hasPrefix:@"YTI"]) {
        NSString *description = [object description];
        // Skip whole-page data (full of other songs' album links), headers are small
        if (description.length > 300000)
            return nil;
        return YTMUCollectionIDInString(description);
    }

    if ([object isKindOfClass:[NSArray class]]) {
        NSUInteger count = 0;
        for (id item in (NSArray *)object) {
            if (++count > 20)
                break;
            NSString *found = YTMUScanObjectForID(item, depth - 1, seen);
            if (found)
                return found;
        }
        return nil;
    }

    if (depth <= 0 || [object isKindOfClass:[UIView class]])
        return nil;

    for (Class cls = [object class]; cls; cls = class_getSuperclass(cls)) {
        NSString *name = NSStringFromClass(cls);
        if (![name hasPrefix:@"YT"] && ![name hasPrefix:@"ELM"])
            break; // stop at UIKit / Foundation base classes

        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList(cls, &count);
        for (unsigned int i = 0; i < count; i++) {
            const char *type = ivar_getTypeEncoding(ivars[i]);
            const char *ivarName = ivar_getName(ivars[i]);
            if (!type || type[0] != '@' || !ivarName)
                continue;
            id value = YTMUSafeValue(object, [NSString stringWithUTF8String:ivarName]);
            NSString *found = YTMUScanObjectForID(value, depth - 1, seen);
            if (found) {
                free(ivars);
                return found;
            }
        }
        free(ivars);
    }
    return nil;
}

static NSArray<UIViewController *> *YTMUControllersAround(UIView *view) {
    NSMutableArray<UIViewController *> *controllers = [NSMutableArray array];
    UIViewController *vc = [view respondsToSelector:@selector(_viewControllerForAncestor)] ? view._viewControllerForAncestor : nil;
    for (UIViewController *current = vc; current; current = current.parentViewController) {
        if (![controllers containsObject:current])
            [controllers addObject:current];
    }
    for (UIResponder *responder = view; responder && controllers.count < 12; responder = responder.nextResponder) {
        if (![responder isKindOfClass:[UIViewController class]])
            continue;
        UIViewController *controller = (UIViewController *)responder;
        if (![controllers containsObject:controller])
            [controllers addObject:controller];
    }
    return controllers;
}

static NSString *YTMUDebugReport(UIView *view) {
    NSMutableString *report = [NSMutableString stringWithString:@"YTMU collection ID debug\n"];
    for (UIViewController *vc in YTMUControllersAround(view)) {
        [report appendFormat:@"\n%@:", NSStringFromClass([vc class])];
        for (Class cls = [vc class]; cls; cls = class_getSuperclass(cls)) {
            NSString *name = NSStringFromClass(cls);
            if (![name hasPrefix:@"YT"] && ![name hasPrefix:@"ELM"])
                break;
            unsigned int count = 0;
            Ivar *ivars = class_copyIvarList(cls, &count);
            for (unsigned int i = 0; i < count; i++) {
                const char *type = ivar_getTypeEncoding(ivars[i]);
                if (type && type[0] == '@')
                    [report appendFormat:@" %s%s", ivar_getName(ivars[i]), type];
            }
            free(ivars);
        }
    }
    return report;
}

static NSString *YTMUPlaylistBrowseID(UIView *view) {
    Class browseClass = NSClassFromString(@"YTMBrowseViewController");
    if (!view)
        return nil;

    // 1. Walk up from the tapped button
    for (UIResponder *responder = view; responder; responder = responder.nextResponder) {
        if ([responder isKindOfClass:browseClass]) {
            NSString *browseID = YTMUBrowseIDOfController(responder);
            if ([browseID hasPrefix:@"VL"] || [browseID hasPrefix:@"MPREb_"])
                return browseID;
        }
    }

    // 2. Search all screens for the browse page that contains the button
    NSString *fromTree = YTMUBrowseIDInTree(view.window.rootViewController, view, browseClass, 0);
    if (fromTree)
        return fromTree;

    // 3. Search the header's own data for any playlist / album ID
    YTMUPreferPlaylistIDs = NO;
    for (UIViewController *vc in YTMUControllersAround(view)) {
        if ([NSStringFromClass([vc class]) containsString:@"Playlist"])
            YTMUPreferPlaylistIDs = YES;
    }
    NSHashTable *seen = [NSHashTable hashTableWithOptions:NSPointerFunctionsObjectPointerPersonality];
    for (UIViewController *vc in YTMUControllersAround(view)) {
        NSString *found = YTMUScanObjectForID(vc, 3, seen);
        if (found)
            return found;
    }
    return nil;
}

#pragma mark - Metadata helpers

static NSString *YTMUCleanFileName(NSString *name) {
    NSCharacterSet *bad = [NSCharacterSet characterSetWithCharactersInString:@"/\\:?*\"<>|"];
    NSString *clean = [[name componentsSeparatedByCharactersInSet:bad] componentsJoinedByString:@""];
    clean = [clean stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return clean.length > 0 ? clean : @"Unknown";
}

static NSString *YTMUCleanArtist(NSString *artist) {
    if ([artist hasSuffix:@" - Topic"])
        artist = [artist substringToIndex:artist.length - 8];
    return artist;
}

// What YTM shows on the lock screen for the current song (has the album name).
// String keys = MPMediaItemProperty* values, so no MediaPlayer linking needed.
// Last lock-screen info YTM set (YTM uses its own player session, so the
// global MPNowPlayingInfoCenter can be empty - the hook below catches it)
static NSDictionary *ytmuLastNowPlayingInfo = nil;

static NSDictionary *YTMUNowPlayingInfo(void) {
    @synchronized ([NSNull class]) {
        if (ytmuLastNowPlayingInfo.count)
            return ytmuLastNowPlayingInfo;
    }
    Class centerClass = NSClassFromString(@"MPNowPlayingInfoCenter");
    if (!centerClass)
        return nil;
    if (![centerClass respondsToSelector:@selector(defaultCenter)])
        return nil;
    id center = ((id (*)(id, SEL))objc_msgSend)(centerClass, @selector(defaultCenter));
    id info = YTMUSafeValue(center, @"nowPlayingInfo");
    return [info isKindOfClass:[NSDictionary class]] ? info : nil;
}

NSDictionary *YTMUCurrentNowPlayingInfo(void) {
    return YTMUNowPlayingInfo();
}

static NSString *YTMUBestThumbnailURL(id videoDetails) {
    id thumbnailDetails = YTMUSafeValue(videoDetails, @"thumbnail");
    id thumbnails = YTMUSafeValue(thumbnailDetails, @"thumbnailsArray");
    if (![thumbnails isKindOfClass:[NSArray class]] || ((NSArray *)thumbnails).count == 0)
        return nil;

    YTIThumbnailDetails_Thumbnail *thumbnail = ((NSArray *)thumbnails).lastObject;
    NSString *url = YTMUSafeString(thumbnail, @"URL");
    if (!url)
        return nil;

    unsigned int width = [thumbnail respondsToSelector:@selector(width)] ? thumbnail.width : 0;
    if (width == 0)
        return url;

    // Ask for the big version of square YTM artwork
    NSString *sizePart = [NSString stringWithFormat:@"w%u-h%u-", width, width];
    return [url stringByReplacingOccurrencesOfString:sizePart withString:@"w1200-h1200-"];
}

#pragma mark - Hook

@interface MPNowPlayingInfoCenter : NSObject
@end

%hook MPNowPlayingInfoCenter
- (void)setNowPlayingInfo:(NSDictionary *)info {
    %orig;
    if ([info isKindOfClass:[NSDictionary class]] && info.count) {
        @synchronized ([NSNull class]) {
            ytmuLastNowPlayingInfo = [info copy];
        }
    }
}
%end

// Tells the playlist downloader whenever the player starts a new song
// (same hook SponsorBlock.x uses)
%hook YTPlayerViewController
- (void)playbackController:(id)arg1 didActivateVideo:(id)arg2 withPlaybackData:(id)arg3 {
    %orig;
    [[NSNotificationCenter defaultCenter] postNotificationName:@"YTMUPlayerDidActivateVideo"
                                                        object:self
                                                      userInfo:arg2 ? @{@"video": arg2} : nil];
}
%end

@interface ELMTouchCommandPropertiesHandler : NSObject
- (void)ytmu_downloadAudio:(YTMUTrackInfo *)info;
- (void)ytmu_downloadCoverImage:(YTMUTrackInfo *)info;
- (NSString *)ytmu_audioURLFromManifest:(NSURL *)manifest;
@end

%hook ELMTouchCommandPropertiesHandler
- (void)handleTap {
    if (class_getInstanceVariable([self class], "_controller") == NULL ||
        class_getInstanceVariable([self class], "_tapRecognizer") == NULL) {
        return %orig;
    }

    ELMNodeController *node = YTMUSafeValue(self, @"_controller");
    UIGestureRecognizer *tapRecognizer = YTMUSafeValue(self, @"_tapRecognizer");
    NSString *nodeKey = YTMUSafeString(node, @"key");

    if (![nodeKey isEqualToString:@"music_download_badge_1"])
        return %orig;

    BOOL wantsAudio = YTMU(@"downloadAudio");
    BOOL wantsCover = YTMU(@"downloadCoverImage");
    if (!wantsAudio && !wantsCover)
        return %orig;

    UIView *tappedView = [tapRecognizer isKindOfClass:[UIGestureRecognizer class]] ? tapRecognizer.view : nil;

    // Download badge on a playlist page -> download the whole playlist
    if (wantsAudio && YTMUIsCollectionHeader(tappedView)) {
        NSString *browseID = YTMUPlaylistBrowseID(tappedView);
        if (browseID.length) {
            [[YTMUPlaylistDownloader sharedDownloader] startWithBrowseID:browseID];
        } else {
            [UIPasteboard generalPasteboard].string = YTMUDebugReport(tappedView);
            YTAlertView *alertView = [%c(YTAlertView) infoDialog];
            alertView.title = LOC(@"OOPS");
            alertView.subtitle = @"Couldn't read this page's ID. Debug info was copied to your clipboard.";
            [alertView show];
        }
        return;
    }

    UIViewController *playingVC = YTMUNowPlayingController(tappedView);
    if (!playingVC)
        return %orig;

    NSMutableArray *startObjects = [NSMutableArray arrayWithObject:playingVC];
    if (tappedView)
        [startObjects addObject:tappedView];
    YTMUTrackInfo *info = YTMUFindTrack(startObjects);
    if (!info) {
        YTAlertView *alertView = [%c(YTAlertView) infoDialog];
        alertView.title = LOC(@"DONT_RUSH");
        alertView.subtitle = LOC(@"DONT_RUSH_DESC");
        [alertView show];
        return;
    }

    if (wantsAudio && wantsCover) {
        YTMActionSheetController *sheetController = [%c(YTMActionSheetController) musicActionSheetController];
        sheetController.sourceView = tappedView;
        [sheetController addHeaderWithTitle:LOC(@"SELECT_ACTION") subtitle:nil];

        [sheetController addAction:[%c(YTActionSheetAction) actionWithTitle:LOC(@"DOWNLOAD_AUDIO") iconImage:[%c(YTUIResources) audioOutline] style:0 handler:^ {
            [self ytmu_downloadAudio:info];
        }]];

        [sheetController addAction:[%c(YTActionSheetAction) actionWithTitle:LOC(@"DOWNLOAD_COVER") iconImage:[%c(YTUIResources) outlineImageWithColor:[UIColor whiteColor]] style:0 handler:^ {
            [self ytmu_downloadCoverImage:info];
        }]];

        [sheetController addAction:[%c(YTActionSheetAction) actionWithTitle:LOC(@"DOWNLOAD_PREMIUM") iconImage:[%c(YTUIResources) downloadOutline] secondaryIconImage:[%c(YTUIResources) youtubePremiumBadgeLight] accessibilityIdentifier:nil handler:^ {
            return %orig;
        }]];

        [sheetController presentFromViewController:playingVC animated:YES completion:nil];
    } else if (wantsAudio) {
        [self ytmu_downloadAudio:info];
    } else {
        [self ytmu_downloadCoverImage:info];
    }
}

%new
- (void)ytmu_downloadAudio:(YTMUTrackInfo *)info {
    id playerData = YTMUSafeValue(info.playerResponse, @"playerData");
    id videoDetails = YTMUSafeValue(playerData, @"videoDetails");

    NSString *title = YTMUSafeString(videoDetails, @"title") ?: @"Unknown";
    NSString *artist = YTMUCleanArtist(YTMUSafeString(videoDetails, @"author") ?: @"Unknown");
    NSString *videoID = YTMUSafeString(info.playerViewController, @"contentVideoID") ?:
                        YTMUSafeString(videoDetails, @"videoId");
    NSString *manifestURL = YTMUManifestURL(info.playerResponse);
    NSString *thumbnailURL = YTMUBestThumbnailURL(videoDetails);

    // Album + nicer artist + duration from the lock screen info, if it's the same song
    NSString *album = nil;
    double duration = 0;
    NSDictionary *nowPlaying = YTMUNowPlayingInfo();
    NSString *npTitle = [nowPlaying[@"title"] isKindOfClass:[NSString class]] ? nowPlaying[@"title"] : nil;
    if ([npTitle isEqualToString:title]) {
        NSString *npAlbum = [nowPlaying[@"albumTitle"] isKindOfClass:[NSString class]] ? nowPlaying[@"albumTitle"] : nil;
        NSString *npArtist = [nowPlaying[@"artist"] isKindOfClass:[NSString class]] ? nowPlaying[@"artist"] : nil;
        NSNumber *npDuration = [nowPlaying[@"playbackDuration"] isKindOfClass:[NSNumber class]] ? nowPlaying[@"playbackDuration"] : nil;
        if (npAlbum.length > 0)
            album = npAlbum;
        if (npArtist.length > 0)
            artist = YTMUCleanArtist(npArtist);
        duration = npDuration.doubleValue;
    }
    if (duration <= 0 && [info.playerViewController respondsToSelector:@selector(currentVideoTotalMediaTime)])
        duration = [(YTPlayerViewController *)info.playerViewController currentVideoTotalMediaTime];

    NSMutableDictionary *metadata = [NSMutableDictionary dictionary];
    metadata[@"title"] = title;
    metadata[@"artist"] = artist;
    metadata[@"album_artist"] = artist;
    if (album)
        metadata[@"album"] = album;
    if (videoID.length > 0)
        metadata[@"comment"] = [NSString stringWithFormat:@"https://music.youtube.com/watch?v=%@", videoID];

    NSString *mediaName = YTMUCleanFileName([NSString stringWithFormat:@"%@ - %@", artist, title]);
    NSString *tempName = videoID.length > 0 ? videoID : [NSUUID UUID].UUIDString;

    // Network work off the main thread (the old code froze the UI here)
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *audioURL = manifestURL ? [self ytmu_audioURLFromManifest:[NSURL URLWithString:manifestURL]] : nil;
        NSData *coverData = thumbnailURL ? [NSData dataWithContentsOfURL:[NSURL URLWithString:thumbnailURL]] : nil;

        dispatch_async(dispatch_get_main_queue(), ^{
            if (audioURL.length == 0) {
                YTAlertView *alertView = [%c(YTAlertView) infoDialog];
                alertView.title = LOC(@"OOPS");
                alertView.subtitle = LOC(@"LINK_NOT_FOUND");
                [alertView show];
                return;
            }

            FFMpegDownloader *ffmpeg = [[FFMpegDownloader alloc] init];
            ffmpeg.tempName = tempName;
            ffmpeg.mediaName = mediaName;
            ffmpeg.duration = (NSInteger)round(duration);
            [ffmpeg downloadAudio:audioURL metadata:metadata coverData:coverData];
        });
    });
}

%new
- (NSString *)ytmu_audioURLFromManifest:(NSURL *)manifest {
    NSData *manifestData = manifest ? [NSData dataWithContentsOfURL:manifest] : nil;
    if (!manifestData)
        return nil;

    NSString *manifestString = [[NSString alloc] initWithData:manifestData encoding:NSUTF8StringEncoding];
    NSArray *manifestLines = [manifestString componentsSeparatedByString:@"\n"];

    // 234 = best AAC audio, 233 = lower quality fallback
    for (NSString *groupID in @[@"234", @"233"]) {
        NSString *searchString = [NSString stringWithFormat:@"TYPE=AUDIO,GROUP-ID=\"%@\"", groupID];
        for (NSString *line in manifestLines) {
            if (![line containsString:searchString])
                continue;

            NSRange startRange = [line rangeOfString:@"https://"];
            NSRange endRange = [line rangeOfString:@"index.m3u8"];
            if (startRange.location != NSNotFound && endRange.location != NSNotFound &&
                NSMaxRange(endRange) > startRange.location) {
                NSRange targetRange = NSMakeRange(startRange.location, NSMaxRange(endRange) - startRange.location);
                return [line substringWithRange:targetRange];
            }
        }
    }

    return nil;
}

%new
- (void)ytmu_downloadCoverImage:(YTMUTrackInfo *)info {
    id playerData = YTMUSafeValue(info.playerResponse, @"playerData");
    id videoDetails = YTMUSafeValue(playerData, @"videoDetails");
    NSString *thumbnailURL = YTMUBestThumbnailURL(videoDetails);
    if (!thumbnailURL)
        return;

    NSString *bigURL = [thumbnailURL stringByReplacingOccurrencesOfString:@"w1200-h1200-" withString:@"w2048-h2048-"];
    FFMpegDownloader *ffmpeg = [[FFMpegDownloader alloc] init];
    [ffmpeg downloadImage:[NSURL URLWithString:bigURL]];
}
%end
