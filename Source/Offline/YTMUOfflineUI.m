#import "YTMUOfflineUI.h"
#import <QuartzCore/QuartzCore.h>
#include <float.h>

#pragma mark - Helpers

UIColor *YTMUAverageColor(UIImage *image) {
    CGImageRef cgImage = image.CGImage;
    if (!cgImage)
        return [UIColor colorWithWhite:0.18 alpha:1.0];

    unsigned char rgba[4] = {0, 0, 0, 0};
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(rgba, 1, 1, 8, 4, colorSpace, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGContextDrawImage(context, CGRectMake(0, 0, 1, 1), cgImage);
    CGContextRelease(context);
    CGColorSpaceRelease(colorSpace);

    // Darkened like YTM's backgrounds
    return [UIColor colorWithRed:rgba[0] / 255.0 * 0.65 green:rgba[1] / 255.0 * 0.65 blue:rgba[2] / 255.0 * 0.65 alpha:1.0];
}

NSString *YTMUFormatTime(NSTimeInterval seconds) {
    if (!isfinite(seconds) || seconds < 0)
        seconds = 0;
    NSInteger total = (NSInteger)llround(seconds);
    if (total >= 3600)
        return [NSString stringWithFormat:@"%ld:%02ld:%02ld", (long)(total / 3600), (long)((total / 60) % 60), (long)(total % 60)];
    return [NSString stringWithFormat:@"%ld:%02ld", (long)(total / 60), (long)(total % 60)];
}

// YTMusicUltimate > Themes > OLED Dark Theme
BOOL YTMUIsOLED(void) {
    NSDictionary *prefs = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"YTMUltimate"];
    return [prefs[@"YTMUltimateIsEnabled"] boolValue] && [prefs[@"oledTheme"] boolValue];
}

UIColor *YTMUBackgroundColor(void) {
    return YTMUIsOLED() ? [UIColor blackColor] : [UIColor colorWithRed:3 / 255.0 green:3 / 255.0 blue:3 / 255.0 alpha:1.0];
}

static UIColor *YTMUBackground(void) {
    return YTMUBackgroundColor();
}

// Real white: "Low contrast" dims [UIColor whiteColor] app-wide, YTM's headers stay white
// (built from a CGColor: colorWithWhite: goes through the hooked whiteColor too)
static UIColor *YTMUPureWhite(void) {
    static UIColor *white = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        CGFloat components[4] = {1.0, 1.0, 1.0, 1.0};
        CGColorRef color = CGColorCreate(space, components);
        white = [UIColor colorWithCGColor:color];
        CGColorRelease(color);
        CGColorSpaceRelease(space);
    });
    return white;
}

// Top color of the Now Playing gradient (none with OLED)
static UIColor *YTMUGradientTop(UIImage *artwork) {
    return YTMUIsOLED() ? [UIColor blackColor] : YTMUAverageColor(artwork);
}

static UIColor *YTMUSecondaryText(void) {
    return [UIColor colorWithWhite:1.0 alpha:0.62];
}

// YTM-style hue: one color for the whole cover, where colorful pixels count
// far more than grey/black ones (a dark cover with orange sparks gives orange,
// a red/grey cover gives a red-tinted brown), at a fixed dim brightness.
UIColor *YTMUHueColor(UIImage *cover) {
    CGImageRef cgImage = cover.CGImage;
    if (!cgImage)
        return [UIColor colorWithWhite:0.16 alpha:1.0];

    const size_t side = 32;
    unsigned char *pixels = calloc(side * side * 4, 1);
    if (!pixels)
        return [UIColor colorWithWhite:0.16 alpha:1.0];
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(pixels, side, side, 8, side * 4, colorSpace, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGContextSetInterpolationQuality(context, kCGInterpolationMedium);
    CGContextDrawImage(context, CGRectMake(0, 0, side, side), cgImage);
    CGContextRelease(context);
    CGColorSpaceRelease(colorSpace);

    double r = 0, g = 0, b = 0, weightSum = 0, satSum = 0;
    for (size_t i = 0; i < side * side; i++) {
        double pr = pixels[i * 4] / 255.0, pg = pixels[i * 4 + 1] / 255.0, pb = pixels[i * 4 + 2] / 255.0;
        double maxC = MAX(pr, MAX(pg, pb)), minC = MIN(pr, MIN(pg, pb));
        double saturation = maxC > 0 ? (maxC - minC) / maxC : 0;
        // Vivid + bright pixels dominate; plain pixels still count a little
        double weight = 0.03 + pow(saturation, 2.0) * maxC * 4.0;
        r += pr * weight;
        g += pg * weight;
        b += pb * weight;
        weightSum += weight;
        satSum += saturation * maxC;
    }
    free(pixels);

    UIColor *mixed = [UIColor colorWithRed:r / weightSum green:g / weightSum blue:b / weightSum alpha:1.0];
    CGFloat hue = 0, saturation = 0, brightness = 0, alpha = 0;
    [mixed getHue:&hue saturation:&saturation brightness:&brightness alpha:&alpha];
    // Covers with only a bit of color stay more muted
    double colorfulness = MIN(1.0, satSum / (side * side) * 3.0);
    saturation = MIN(saturation, 0.35 + 0.3 * colorfulness);
    return [UIColor colorWithHue:hue saturation:saturation brightness:0.36 alpha:1.0];
}

// YTM-style palette hue: the cover's 3 main colors (k-means, colorful pixels
// count more), each placed left/middle/right where it sits in the cover,
// dimmed like YTM. Returned as a 3x1 image to be stretched over the header.
UIImage *YTMUHueImage(UIImage *cover) {
    CGImageRef cgImage = cover.CGImage;
    if (!cgImage)
        return nil;

    const int side = 32, k = 3, count = 32 * 32;
    unsigned char *pixels = calloc(count * 4, 1);
    if (!pixels)
        return nil;
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(pixels, side, side, 8, side * 4, colorSpace, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGContextDrawImage(context, CGRectMake(0, 0, side, side), cgImage);
    CGContextRelease(context);
    CGColorSpaceRelease(colorSpace);

    double rgb[32 * 32][3], weight[32 * 32];
    for (int i = 0; i < count; i++) {
        double r = pixels[i * 4] / 255.0, g = pixels[i * 4 + 1] / 255.0, b = pixels[i * 4 + 2] / 255.0;
        double maxC = MAX(r, MAX(g, b)), minC = MIN(r, MIN(g, b));
        double saturation = maxC > 0 ? (maxC - minC) / maxC : 0;
        rgb[i][0] = r;
        rgb[i][1] = g;
        rgb[i][2] = b;
        weight[i] = 0.15 + saturation * maxC * 3.0;
    }
    free(pixels);

    // Start: most colorful pixel, then each next = farthest from the chosen ones
    double centers[3][3];
    int best = 0;
    for (int i = 1; i < count; i++) {
        if (weight[i] > weight[best])
            best = i;
    }
    memcpy(centers[0], rgb[best], sizeof(centers[0]));
    for (int c = 1; c < k; c++) {
        double farthest = -1;
        int pick = 0;
        for (int i = 0; i < count; i++) {
            double nearest = DBL_MAX;
            for (int j = 0; j < c; j++) {
                double d = pow(rgb[i][0] - centers[j][0], 2) + pow(rgb[i][1] - centers[j][1], 2) + pow(rgb[i][2] - centers[j][2], 2);
                nearest = MIN(nearest, d);
            }
            if (nearest * weight[i] > farthest) {
                farthest = nearest * weight[i];
                pick = i;
            }
        }
        memcpy(centers[c], rgb[pick], sizeof(centers[c]));
    }

    double sumX[3] = {0}, total[3] = {0};
    for (int iteration = 0; iteration < 8; iteration++) {
        double sums[3][3] = {{0}};
        memset(sumX, 0, sizeof(sumX));
        memset(total, 0, sizeof(total));
        for (int i = 0; i < count; i++) {
            int nearest = 0;
            double nearestD = DBL_MAX;
            for (int c = 0; c < k; c++) {
                double d = pow(rgb[i][0] - centers[c][0], 2) + pow(rgb[i][1] - centers[c][1], 2) + pow(rgb[i][2] - centers[c][2], 2);
                if (d < nearestD) {
                    nearestD = d;
                    nearest = c;
                }
            }
            for (int ch = 0; ch < 3; ch++)
                sums[nearest][ch] += rgb[i][ch] * weight[i];
            sumX[nearest] += (i % side) * weight[i];
            total[nearest] += weight[i];
        }
        for (int c = 0; c < k; c++) {
            if (total[c] <= 0)
                continue;
            for (int ch = 0; ch < 3; ch++)
                centers[c][ch] = sums[c][ch] / total[c];
        }
    }

    // Left to right by where each color mostly is in the cover
    int order[3] = {0, 1, 2};
    double meanX[3];
    for (int c = 0; c < k; c++)
        meanX[c] = total[c] > 0 ? sumX[c] / total[c] : side / 2.0;
    for (int a = 0; a < k; a++) {
        for (int b = a + 1; b < k; b++) {
            if (meanX[order[b]] < meanX[order[a]]) {
                int swap = order[a];
                order[a] = order[b];
                order[b] = swap;
            }
        }
    }

    NSMutableArray<UIColor *> *colors = [NSMutableArray array];
    for (int slot = 0; slot < 3; slot++) {
        const double *c = centers[order[slot]];
        UIColor *color = [UIColor colorWithRed:c[0] green:c[1] blue:c[2] alpha:1.0];
        CGFloat hue = 0, saturation = 0, brightness = 0, alpha = 0;
        [color getHue:&hue saturation:&saturation brightness:&brightness alpha:&alpha];
        // Dim like YTM: bright parts ~0.42, dark parts stay dark
        brightness = MAX(0.10, MIN(0.42, brightness * 0.55));
        saturation = MIN(saturation, 0.65);
        [colors addObject:[UIColor colorWithHue:hue saturation:saturation brightness:brightness alpha:1.0]];
    }

    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.scale = 1.0;
    format.opaque = YES;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(3, 1) format:format];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *rendererContext) {
        for (NSUInteger slot = 0; slot < colors.count; slot++) {
            [colors[slot] setFill];
            UIRectFill(CGRectMake(slot, 0, 1, 1));
        }
    }];
}

// Vertical gradient layer (class looked up at runtime, no extra linking)
static CAGradientLayer *YTMUGradientLayer(UIColor *top) {
    CAGradientLayer *gradient = (CAGradientLayer *)[NSClassFromString(@"CAGradientLayer") layer];
    gradient.colors = @[(id)top.CGColor, (id)YTMUBackground().CGColor];
    gradient.locations = @[@0.0, @1.0];
    return gradient;
}

static UIButton *YTMUIconButton(NSString *symbol, CGFloat pointSize, UIColor *tint) {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:pointSize weight:UIImageSymbolWeightSemibold];
    [button setImage:[UIImage systemImageNamed:symbol withConfiguration:config] forState:UIControlStateNormal];
    button.tintColor = tint;
    button.translatesAutoresizingMaskIntoConstraints = NO;
    return button;
}

static UIButton *YTMUCircleButton(NSString *symbol, CGFloat diameter, CGFloat pointSize, UIColor *background, UIColor *tint) {
    UIButton *button = YTMUIconButton(symbol, pointSize, tint);
    button.backgroundColor = background;
    button.layer.cornerRadius = diameter / 2.0;
    [button.widthAnchor constraintEqualToConstant:diameter].active = YES;
    [button.heightAnchor constraintEqualToConstant:diameter].active = YES;
    return button;
}

static UILabel *YTMULabel(UIFont *font, UIColor *color) {
    UILabel *label = [UILabel new];
    label.font = font;
    label.textColor = color;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    return label;
}

static void YTMUShare(NSArray *items, UIViewController *presenter, UIView *source) {
    if (items.count == 0 || !presenter)
        return;
    UIActivityViewController *activity = [[UIActivityViewController alloc] initWithActivityItems:items applicationActivities:nil];
    activity.excludedActivityTypes = @[UIActivityTypeAssignToContact, UIActivityTypePrint];
    UIPopoverPresentationController *popover = activity.popoverPresentationController;
    if (popover && source) {
        popover.sourceView = source;
        popover.sourceRect = source.bounds;
    }
    [presenter presentViewController:activity animated:YES completion:nil];
}

#pragma mark - Custom order (Edit)

static NSString *YTMUOrderDefaultsKey(NSString *key) {
    return [@"YTMUOrder:" stringByAppendingString:key];
}

NSArray<NSURL *> *YTMUApplySavedOrder(NSArray<NSURL *> *urls, NSString *key) {
    NSArray<NSString *> *saved = [[NSUserDefaults standardUserDefaults] arrayForKey:YTMUOrderDefaultsKey(key)];
    if (saved.count == 0)
        return urls;
    NSMutableDictionary<NSString *, NSNumber *> *position = [NSMutableDictionary dictionary];
    for (NSUInteger i = 0; i < saved.count; i++)
        position[saved[i]] = @(i);
    // Saved ones in their order, new ones (not in the list) keep their place at the top
    return [urls sortedArrayWithOptions:NSSortStable usingComparator:^NSComparisonResult(NSURL *a, NSURL *b) {
        NSNumber *pa = position[a.lastPathComponent], *pb = position[b.lastPathComponent];
        if (!pa && !pb)
            return NSOrderedSame;
        if (!pa)
            return NSOrderedAscending;
        if (!pb)
            return NSOrderedDescending;
        return [pa compare:pb];
    }];
}

void YTMUSaveOrder(NSArray<NSURL *> *urls, NSString *key) {
    [[NSUserDefaults standardUserDefaults] setObject:[urls valueForKey:@"lastPathComponent"] forKey:YTMUOrderDefaultsKey(key)];
}

NSString *YTMUTrackOrderKey(NSURL *folder) {
    return [@"tracks:" stringByAppendingString:folder.lastPathComponent ?: @""];
}

#pragma mark - Collection model

@implementation YTMUCollection

+ (NSArray<NSURL *> *)audioFilesInFolder:(NSURL *)folder {
    NSArray<NSURL *> *contents = [[NSFileManager defaultManager] contentsOfDirectoryAtURL:folder
                                                                includingPropertiesForKeys:nil
                                                                                   options:NSDirectoryEnumerationSkipsHiddenFiles
                                                                                     error:nil];
    NSMutableArray<NSURL *> *audio = [NSMutableArray array];
    for (NSURL *url in contents) {
        NSString *extension = url.pathExtension.lowercaseString;
        if ([extension isEqualToString:@"m4a"] || [extension isEqualToString:@"mp3"])
            [audio addObject:url];
    }
    // "2. X" before "10. Y": numeric compare
    [audio sortUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) {
        return [a.lastPathComponent compare:b.lastPathComponent options:NSNumericSearch | NSCaseInsensitiveSearch];
    }];
    return YTMUApplySavedOrder(audio, YTMUTrackOrderKey(folder));
}

+ (NSArray<YTMUCollection *> *)collectionsInFolder:(NSURL *)root {
    NSArray<NSURL *> *contents = [[NSFileManager defaultManager] contentsOfDirectoryAtURL:root
                                                                includingPropertiesForKeys:@[NSURLIsDirectoryKey, NSURLContentModificationDateKey]
                                                                                   options:NSDirectoryEnumerationSkipsHiddenFiles
                                                                                     error:nil];
    NSMutableArray<YTMUCollection *> *collections = [NSMutableArray array];
    for (NSURL *url in contents) {
        NSNumber *isDirectory = nil;
        [url getResourceValue:&isDirectory forKey:NSURLIsDirectoryKey error:nil];
        if (!isDirectory.boolValue)
            continue;

        NSArray<NSURL *> *files = [self audioFilesInFolder:url];
        if (files.count == 0)
            continue;

        YTMUCollection *collection = [YTMUCollection new];
        collection.folder = url;
        collection.name = url.lastPathComponent;
        collection.files = files;

        NSMutableOrderedSet<NSString *> *formats = [NSMutableOrderedSet orderedSet];
        for (NSURL *file in files)
            [formats addObject:file.pathExtension.lowercaseString];
        collection.formats = formats.array;

        // First song tells us album vs playlist (playlists: album artist = playlist name)
        YTMUOfflineTrack *first = [YTMUOfflineTrack trackWithURL:files.firstObject fallbackArtwork:nil];
        BOOL albumArtistIsName = first.albumArtist && [first.albumArtist caseInsensitiveCompare:collection.name] == NSOrderedSame;
        collection.isAlbum = first.albumArtist.length && !albumArtistIsName;
        collection.artist = collection.isAlbum ? first.albumArtist : nil;
        collection.year = collection.isAlbum ? first.year : nil;

        UIImage *cover = [UIImage imageWithContentsOfFile:[url URLByAppendingPathComponent:@"cover.png"].path];
        collection.cover = cover ?: first.artwork;
        collection.creatorImage = [UIImage imageWithContentsOfFile:[url URLByAppendingPathComponent:@"creator.png"].path];
        collection.details = [NSString stringWithContentsOfURL:[url URLByAppendingPathComponent:@"description.txt"] encoding:NSUTF8StringEncoding error:nil];
        collection.creator = [NSString stringWithContentsOfURL:[url URLByAppendingPathComponent:@"creator.txt"] encoding:NSUTF8StringEncoding error:nil];
        [collections addObject:collection];
    }

    // Newest first, like "Recent activity"
    [collections sortUsingComparator:^NSComparisonResult(YTMUCollection *a, YTMUCollection *b) {
        NSDate *dateA = nil, *dateB = nil;
        [a.folder getResourceValue:&dateA forKey:NSURLContentModificationDateKey error:nil];
        [b.folder getResourceValue:&dateB forKey:NSURLContentModificationDateKey error:nil];
        NSDate *first = dateB ?: [NSDate distantPast];
        NSDate *second = dateA ?: [NSDate distantPast];
        return [first compare:second];
    }];
    // Order from Edit, if any
    NSArray<NSURL *> *ordered = YTMUApplySavedOrder([collections valueForKey:@"folder"], @"collections");
    NSMutableArray<YTMUCollection *> *sorted = [NSMutableArray array];
    for (NSURL *folder in ordered) {
        for (YTMUCollection *collection in collections) {
            if ([collection.folder isEqual:folder]) {
                [sorted addObject:collection];
                break;
            }
        }
    }
    return sorted;
}

- (NSArray<YTMUOfflineTrack *> *)loadTracks {
    NSMutableArray<YTMUOfflineTrack *> *tracks = [NSMutableArray array];
    for (NSURL *file in self.files) {
        // Artist / creator lists mix folders: each song finds its own cover
        YTMUOfflineTrack *track = [YTMUOfflineTrack trackWithURL:file fallbackArtwork:self.kind ? nil : self.cover];
        [track loadArtworkIfNeeded];
        [tracks addObject:track];
    }
    return tracks;
}

+ (NSArray<YTMUOfflineTrack *> *)libraryTracksInFolder:(NSURL *)root collections:(NSArray<YTMUCollection *> *)collections {
    static NSMutableDictionary<NSString *, NSArray *> *cache = nil; // path -> @[date, track]
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cache = [NSMutableDictionary dictionary];
    });

    NSMutableArray<NSURL *> *files = [[self audioFilesInFolder:root] mutableCopy];
    for (YTMUCollection *collection in collections)
        [files addObjectsFromArray:collection.files];

    NSMutableArray<YTMUOfflineTrack *> *tracks = [NSMutableArray array];
    for (NSURL *file in files) {
        NSDate *date = nil;
        [file getResourceValue:&date forKey:NSURLContentModificationDateKey error:nil];
        YTMUOfflineTrack *track = nil;
        @synchronized (cache) {
            NSArray *entry = cache[file.path];
            if (entry && [entry[0] isEqual:date ?: [NSNull null]])
                track = entry[1];
        }
        if (!track) {
            track = [YTMUOfflineTrack lightTrackWithURL:file];
            @synchronized (cache) {
                cache[file.path] = @[date ?: [NSNull null], track];
            }
        }
        [tracks addObject:track];
    }

    // Recently added first
    [tracks sortUsingComparator:^NSComparisonResult(YTMUOfflineTrack *a, YTMUOfflineTrack *b) {
        return [(b.addedDate ?: [NSDate distantPast]) compare:(a.addedDate ?: [NSDate distantPast])];
    }];
    return tracks;
}

static NSArray<NSURL *> *YTMUSortedByTitle(NSArray<YTMUOfflineTrack *> *tracks) {
    NSArray *sorted = [tracks sortedArrayUsingComparator:^NSComparisonResult(YTMUOfflineTrack *a, YTMUOfflineTrack *b) {
        return [a.title ?: @"" localizedCaseInsensitiveCompare:b.title ?: @""];
    }];
    return [sorted valueForKey:@"url"];
}

+ (NSArray<YTMUCollection *> *)artistsFromCollections:(NSArray<YTMUCollection *> *)collections library:(NSArray<YTMUOfflineTrack *> *)library {
    NSMutableDictionary<NSString *, YTMUCollection *> *byName = [NSMutableDictionary dictionary];
    for (YTMUCollection *album in collections) {
        NSString *name = [(album.creator.length ? album.creator : album.artist) stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (!album.isAlbum || name.length == 0)
            continue;
        YTMUCollection *artist = byName[name.lowercaseString];
        if (!artist) {
            artist = [YTMUCollection new];
            artist.kind = @"Artist";
            artist.name = name;
            byName[name.lowercaseString] = artist;
        }
        if (!artist.cover)
            artist.cover = album.creatorImage;
        if (!artist.creatorImage)
            artist.creatorImage = album.creatorImage;
    }

    for (YTMUCollection *artist in byName.allValues) {
        // Every song tagged with this artist, from any playlist / album / single download
        NSMutableArray<YTMUOfflineTrack *> *matches = [NSMutableArray array];
        NSMutableSet<NSString *> *seen = [NSMutableSet set];
        for (YTMUOfflineTrack *track in library) {
            // Song artist tag contains the name ("Yeat, Drake"), or an album of theirs
            // (playlists use the playlist name as album artist, so that only counts exactly)
            BOOL byArtist = track.artist.length && [track.artist rangeOfString:artist.name options:NSCaseInsensitiveSearch].location != NSNotFound;
            BOOL byAlbum = track.albumArtist.length && [track.albumArtist caseInsensitiveCompare:artist.name] == NSOrderedSame;
            if ((byArtist || byAlbum) && ![seen containsObject:track.url.path]) {
                [seen addObject:track.url.path];
                [matches addObject:track];
            }
        }
        artist.files = YTMUSortedByTitle(matches);
    }

    NSArray *artists = [byName.allValues filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"files.@count > 0"]];
    return [artists sortedArrayUsingComparator:^NSComparisonResult(YTMUCollection *a, YTMUCollection *b) {
        return [a.name localizedCaseInsensitiveCompare:b.name];
    }];
}

+ (NSArray<YTMUCollection *> *)creatorsFromCollections:(NSArray<YTMUCollection *> *)collections {
    NSMutableDictionary<NSString *, YTMUCollection *> *byName = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSMutableOrderedSet<NSURL *> *> *filesByName = [NSMutableDictionary dictionary];
    for (YTMUCollection *playlist in collections) {
        NSString *name = [playlist.creator stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (playlist.isAlbum || name.length == 0)
            continue;
        NSString *key = name.lowercaseString;
        YTMUCollection *creator = byName[key];
        if (!creator) {
            creator = [YTMUCollection new];
            creator.kind = @"Creator";
            creator.name = name;
            byName[key] = creator;
            filesByName[key] = [NSMutableOrderedSet orderedSet];
        }
        if (!creator.cover)
            creator.cover = playlist.creatorImage;
        if (!creator.creatorImage)
            creator.creatorImage = playlist.creatorImage;
        [filesByName[key] addObjectsFromArray:playlist.files];
    }
    for (NSString *key in byName)
        byName[key].files = filesByName[key].array;

    return [byName.allValues sortedArrayUsingComparator:^NSComparisonResult(YTMUCollection *a, YTMUCollection *b) {
        return [a.name localizedCaseInsensitiveCompare:b.name];
    }];
}

- (NSString *)subtitle {
    // Artists / creators: just how many songs you have of them
    if (self.kind)
        return [NSString stringWithFormat:@"%lu %@", (unsigned long)self.files.count, self.files.count == 1 ? @"track" : @"tracks"];
    NSMutableArray<NSString *> *parts = [NSMutableArray arrayWithObject:self.isAlbum ? @"Album" : @"Playlist"];
    NSString *by = self.isAlbum ? self.artist : [self.creator stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (by.length)
        [parts addObject:by];
    if (self.year.length)
        [parts addObject:self.year];
    [parts addObject:[NSString stringWithFormat:@"%lu %@", (unsigned long)self.files.count, self.files.count == 1 ? @"track" : @"tracks"]];
    return [parts componentsJoinedByString:@" • "];
}

@end

#pragma mark - Playlist menu

void YTMUOpenInFiles(NSURL *folder) {
    NSString *path = [folder.path stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLPathAllowedCharacterSet]];
    NSURL *filesURL = path ? [NSURL URLWithString:[@"shareddocuments://" stringByAppendingString:path]] : nil;
    if (filesURL)
        [[UIApplication sharedApplication] openURL:filesURL options:@{} completionHandler:nil];
}

void YTMUShowCollectionMenu(YTMUCollection *collection, UIViewController *presenter, UIView *source, void (^onDeleted)(void)) {
    YTMUShowCollectionMenuWithEdit(collection, presenter, source, onDeleted, nil);
}

void YTMUShowCollectionMenuWithEdit(YTMUCollection *collection, UIViewController *presenter, UIView *source, void (^onDeleted)(void), void (^onEdit)(void)) {
    YTMUShowCollectionMenuFull(collection, presenter, source, onDeleted, onEdit, nil);
}

void YTMUShowCollectionMenuFull(YTMUCollection *collection, UIViewController *presenter, UIView *source, void (^onDeleted)(void), void (^onEdit)(void), void (^onFind)(void)) {
    if (!collection || !presenter)
        return;
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:collection.name
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    if (onFind) {
        [sheet addAction:[UIAlertAction actionWithTitle:collection.isAlbum ? @"Find in album" : @"Find in playlist" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            onFind();
        }]];
    }
    if (onEdit) {
        [sheet addAction:[UIAlertAction actionWithTitle:@"Edit" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            onEdit();
        }]];
    }
    if (collection.kind) {
        // Artist / creator: play, shuffle or share everything you have of them
        for (NSNumber *shuffle in @[@NO, @YES]) {
            [sheet addAction:[UIAlertAction actionWithTitle:shuffle.boolValue ? @"Shuffle" : @"Play" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
                dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                    NSArray<YTMUOfflineTrack *> *tracks = [collection loadTracks];
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [[YTMUOfflinePlayer shared] playTracks:tracks startIndex:shuffle.boolValue ? -1 : 0 shuffle:shuffle.boolValue];
                    });
                });
            }]];
        }
        [sheet addAction:[UIAlertAction actionWithTitle:@"Share all" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            YTMUShare(collection.files, presenter, source);
        }]];
        [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
        sheet.popoverPresentationController.sourceView = source;
        sheet.popoverPresentationController.sourceRect = source.bounds;
        [presenter presentViewController:sheet animated:YES completion:nil];
        return;
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Share" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        YTMUShare(collection.files, presenter, source);
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Open folder" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        // Files app, right inside this playlist's folder
        YTMUOpenInFiles(collection.folder);
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Delete download" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:collection.name
                                                                       message:collection.isAlbum ? @"Delete all downloaded songs of this album?" : @"Delete all downloaded songs of this playlist?"
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"Delete" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *deleteAction) {
            YTMUOfflinePlayer *player = [YTMUOfflinePlayer shared];
            if ([player.currentTrack.url.path hasPrefix:collection.folder.path])
                [player stop];
            [[NSFileManager defaultManager] removeItemAtURL:collection.folder error:nil];
            if (onDeleted)
                onDeleted();
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
        [presenter presentViewController:alert animated:YES completion:nil];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = source;
    sheet.popoverPresentationController.sourceRect = source.bounds;
    [presenter presentViewController:sheet animated:YES completion:nil];
}

#pragma mark - Badge

@implementation YTMUBadgeLabel

+ (instancetype)badgeWithText:(NSString *)text {
    YTMUBadgeLabel *badge = [YTMUBadgeLabel new];
    badge.text = text;
    badge.font = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
    badge.textColor = [UIColor colorWithWhite:1.0 alpha:0.85];
    badge.textAlignment = NSTextAlignmentCenter;
    badge.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.35].CGColor;
    badge.layer.borderWidth = 1.0;
    badge.layer.cornerRadius = 4.0;
    badge.translatesAutoresizingMaskIntoConstraints = NO;
    [badge setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [badge setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    return badge;
}

- (CGSize)intrinsicContentSize {
    CGSize size = [super intrinsicContentSize];
    return CGSizeMake(size.width + 10, size.height + 4);
}

@end

#pragma mark - Equalizer bars

@interface YTMUEqualizerView ()
@property (nonatomic, strong) NSArray<UIView *> *bars;
@property (nonatomic) BOOL animating;
@end

@implementation YTMUEqualizerView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self)
        return nil;
    NSMutableArray<UIView *> *bars = [NSMutableArray array];
    for (NSUInteger i = 0; i < 3; i++) {
        UIView *bar = [UIView new];
        bar.backgroundColor = [UIColor whiteColor];
        bar.layer.cornerRadius = 1.0;
        [self addSubview:bar];
        [bars addObject:bar];
    }
    self.bars = bars;
    // iOS drops layer animations in the background: restart them when back
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(restartIfAnimating) name:UIApplicationWillEnterForegroundNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(restartIfAnimating) name:UIApplicationDidBecomeActiveNotification object:nil];
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)restartIfAnimating {
    if (self.animating)
        [self startAnimations];
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (self.window && self.animating)
        [self startAnimations];
}

- (CGSize)intrinsicContentSize {
    return CGSizeMake(16, 14);
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width = 3.0, gap = 2.5;
    CGFloat height = self.bounds.size.height;
    for (NSUInteger i = 0; i < self.bars.count; i++) {
        UIView *bar = self.bars[i];
        CGFloat barHeight = height * (i == 1 ? 1.0 : 0.66);
        bar.layer.anchorPoint = CGPointMake(0.5, 1.0);
        bar.frame = CGRectMake(i * (width + gap), height - barHeight, width, barHeight);
        bar.center = CGPointMake(i * (width + gap) + width / 2.0, height);
    }
    // Only when an animation got lost: restarting on every layout made the bars jump
    if (self.animating && ![self.bars.firstObject.layer animationForKey:@"bounce"])
        [self startAnimations];
}

- (void)setAnimating:(BOOL)animating {
    if (_animating == animating) {
        if (animating && ![self.bars.firstObject.layer animationForKey:@"bounce"])
            [self startAnimations];
        return;
    }
    _animating = animating;
    if (animating)
        [self startAnimations];
    else
        [self stopAnimations];
}

- (void)startAnimations {
    NSArray<NSNumber *> *durations = @[@0.42, @0.30, @0.50];
    for (NSUInteger i = 0; i < self.bars.count; i++) {
        UIView *bar = self.bars[i];
        [bar.layer removeAllAnimations];
        CABasicAnimation *animation = [CABasicAnimation animationWithKeyPath:@"transform.scale.y"];
        animation.fromValue = @0.25;
        animation.toValue = @1.0;
        animation.duration = durations[i].doubleValue;
        animation.autoreverses = YES;
        animation.repeatCount = HUGE_VALF;
        [bar.layer addAnimation:animation forKey:@"bounce"];
    }
}

- (void)stopAnimations {
    for (UIView *bar in self.bars)
        [bar.layer removeAllAnimations];
}

@end

#pragma mark - Edit mode handles

// YTM shows the "≡" drag handle on the left: move UIKit's reorder control there
static void YTMUMoveReorderControlLeft(UITableViewCell *cell) {
    if (!cell.editing)
        return;
    // The queue keeps YTM's handle on the right
    if ([cell isKindOfClass:[YTMUTrackCell class]] && ((YTMUTrackCell *)cell).keepsReorderOnRight) {
        for (UIView *view in cell.subviews) {
            if (![NSStringFromClass([view class]) containsString:@"Reorder"])
                continue;
            UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:20 weight:UIImageSymbolWeightRegular];
            UIImage *handle = [[UIImage systemImageNamed:@"line.3.horizontal" withConfiguration:config] imageWithTintColor:[UIColor whiteColor] renderingMode:UIImageRenderingModeAlwaysOriginal];
            for (UIView *subview in view.subviews) {
                if ([subview isKindOfClass:[UIImageView class]]) {
                    ((UIImageView *)subview).image = handle;
                    subview.contentMode = UIViewContentModeCenter;
                    subview.frame = view.bounds;
                }
            }
        }
        return;
    }
    for (UIView *view in cell.subviews) {
        if (![NSStringFromClass([view class]) containsString:@"Reorder"])
            continue;
        view.frame = CGRectMake(6, 0, 44, cell.bounds.size.height);
        UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:20 weight:UIImageSymbolWeightRegular];
        UIImage *handle = [[UIImage systemImageNamed:@"line.3.horizontal" withConfiguration:config] imageWithTintColor:[UIColor whiteColor] renderingMode:UIImageRenderingModeAlwaysOriginal];
        for (UIView *subview in view.subviews) {
            if ([subview isKindOfClass:[UIImageView class]]) {
                ((UIImageView *)subview).image = handle;
                subview.contentMode = UIViewContentModeCenter;
                subview.frame = view.bounds;
            }
        }
        cell.contentView.frame = CGRectMake(44, 0, cell.bounds.size.width - 44, cell.bounds.size.height);
    }
}

#pragma mark - Track cell

@interface YTMUTrackCell ()
@property (nonatomic, strong) UIImageView *artworkView;
@property (nonatomic, strong) UIView *equalizerBackground;
@property (nonatomic, strong) YTMUEqualizerView *equalizer;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *subtitleLabel;
@property (nonatomic, strong) UIButton *menuButton;
@property (nonatomic, strong) NSURL *artworkURL;
@end

@implementation YTMUTrackCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (!self)
        return nil;

    self.backgroundColor = [UIColor clearColor];
    UIView *selected = [UIView new];
    selected.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.08];
    self.selectedBackgroundView = selected;

    self.artworkView = [UIImageView new];
    self.artworkView.contentMode = UIViewContentModeScaleAspectFill;
    self.artworkView.clipsToBounds = YES;
    self.artworkView.layer.cornerRadius = 4.0;
    self.artworkView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.08];
    self.artworkView.translatesAutoresizingMaskIntoConstraints = NO;

    self.equalizerBackground = [UIView new];
    self.equalizerBackground.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.45];
    self.equalizerBackground.layer.cornerRadius = 4.0;
    self.equalizerBackground.translatesAutoresizingMaskIntoConstraints = NO;
    self.equalizerBackground.hidden = YES;

    self.equalizer = [YTMUEqualizerView new];
    self.equalizer.translatesAutoresizingMaskIntoConstraints = NO;

    self.titleLabel = YTMULabel([UIFont systemFontOfSize:16 weight:UIFontWeightSemibold], [UIColor whiteColor]);
    self.subtitleLabel = YTMULabel([UIFont systemFontOfSize:14], YTMUSecondaryText());

    UIStackView *texts = [[UIStackView alloc] initWithArrangedSubviews:@[self.titleLabel, self.subtitleLabel]];
    texts.axis = UILayoutConstraintAxisVertical;
    texts.spacing = 3;
    texts.translatesAutoresizingMaskIntoConstraints = NO;

    // Vertical ⋮ like YTM's song rows (only where onMenu is set)
    self.menuButton = YTMUIconButton(@"ellipsis", 16, [UIColor whiteColor]);
    self.menuButton.transform = CGAffineTransformMakeRotation((CGFloat)M_PI_2);
    self.menuButton.hidden = YES;
    [self.menuButton addTarget:self action:@selector(menuTapped:) forControlEvents:UIControlEventTouchUpInside];

    [self.contentView addSubview:self.artworkView];
    [self.contentView addSubview:self.equalizerBackground];
    [self.equalizerBackground addSubview:self.equalizer];
    [self.contentView addSubview:texts];
    [self.contentView addSubview:self.menuButton];

    [NSLayoutConstraint activateConstraints:@[
        [self.artworkView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16],
        [self.artworkView.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
        [self.artworkView.widthAnchor constraintEqualToConstant:48],
        [self.artworkView.heightAnchor constraintEqualToConstant:48],
        [self.artworkView.topAnchor constraintGreaterThanOrEqualToAnchor:self.contentView.topAnchor constant:8],
        [self.artworkView.bottomAnchor constraintLessThanOrEqualToAnchor:self.contentView.bottomAnchor constant:-8],

        [self.equalizerBackground.leadingAnchor constraintEqualToAnchor:self.artworkView.leadingAnchor],
        [self.equalizerBackground.trailingAnchor constraintEqualToAnchor:self.artworkView.trailingAnchor],
        [self.equalizerBackground.topAnchor constraintEqualToAnchor:self.artworkView.topAnchor],
        [self.equalizerBackground.bottomAnchor constraintEqualToAnchor:self.artworkView.bottomAnchor],
        [self.equalizer.centerXAnchor constraintEqualToAnchor:self.equalizerBackground.centerXAnchor],
        [self.equalizer.centerYAnchor constraintEqualToAnchor:self.equalizerBackground.centerYAnchor],
        [self.equalizer.widthAnchor constraintEqualToConstant:16],
        [self.equalizer.heightAnchor constraintEqualToConstant:14],

        [self.menuButton.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-4],
        [self.menuButton.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
        [self.menuButton.widthAnchor constraintEqualToConstant:44],
        [self.menuButton.heightAnchor constraintEqualToConstant:44],

        // Long titles / artists end in "…" before the ⋮
        [texts.leadingAnchor constraintEqualToAnchor:self.artworkView.trailingAnchor constant:14],
        [texts.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
        [texts.trailingAnchor constraintEqualToAnchor:self.menuButton.leadingAnchor constant:-4],
        [self.contentView.heightAnchor constraintGreaterThanOrEqualToConstant:64]
    ]];
    return self;
}

- (void)setOnMenu:(void (^)(UIButton *))onMenu {
    _onMenu = [onMenu copy];
    self.menuButton.hidden = _onMenu == nil;
}

- (void)setSubtitleText:(NSString *)text {
    self.subtitleLabel.text = text;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    YTMUMoveReorderControlLeft(self);
}

- (void)setEditing:(BOOL)editing animated:(BOOL)animated {
    [super setEditing:editing animated:animated];
    self.menuButton.alpha = editing ? 0.0 : 1.0;
}

- (void)prepareForReuse {
    [super prepareForReuse];
    self.onMenu = nil;
}

- (void)menuTapped:(UIButton *)sender {
    if (self.onMenu)
        self.onMenu(sender);
}

- (void)configureWithTrack:(YTMUOfflineTrack *)track isCurrent:(BOOL)isCurrent isPlaying:(BOOL)isPlaying {
    self.titleLabel.text = track.title;

    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    if (track.artist.length)
        [parts addObject:track.artist];
    if (track.duration > 0)
        [parts addObject:YTMUFormatTime(track.duration)];
    self.subtitleLabel.text = [parts componentsJoinedByString:@" • "];

    self.artworkView.image = track.artwork ?: track.thumbnail;
    self.artworkURL = track.url;
    if (!self.artworkView.image && track.url) {
        __weak __typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            [track loadThumbnailIfNeeded];
            dispatch_async(dispatch_get_main_queue(), ^{
                if ([weakSelf.artworkURL isEqual:track.url] && track.thumbnail)
                    weakSelf.artworkView.image = track.thumbnail;
            });
        });
    }
    self.equalizerBackground.hidden = !isCurrent;
    [self.equalizer setAnimating:isCurrent && isPlaying];
}

@end

#pragma mark - Collection cell

@interface YTMUCollectionCell ()
@property (nonatomic, strong) UIImageView *coverView;
@property (nonatomic, strong) UIButton *menuButton;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *subtitleLabel;
@end

@implementation YTMUCollectionCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (!self)
        return nil;

    self.backgroundColor = [UIColor clearColor];
    UIView *selected = [UIView new];
    selected.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.08];
    self.selectedBackgroundView = selected;

    self.coverView = [UIImageView new];
    self.coverView.contentMode = UIViewContentModeScaleAspectFill;
    self.coverView.clipsToBounds = YES;
    self.coverView.layer.cornerRadius = 4.0;
    self.coverView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.08];
    self.coverView.translatesAutoresizingMaskIntoConstraints = NO;

    self.titleLabel = YTMULabel([UIFont systemFontOfSize:16 weight:UIFontWeightSemibold], [UIColor whiteColor]);
    self.titleLabel.numberOfLines = 1;
    self.subtitleLabel = YTMULabel([UIFont systemFontOfSize:14], YTMUSecondaryText());
    self.subtitleLabel.numberOfLines = 1;

    UIStackView *texts = [[UIStackView alloc] initWithArrangedSubviews:@[self.titleLabel, self.subtitleLabel]];
    texts.axis = UILayoutConstraintAxisVertical;
    texts.spacing = 3;
    texts.translatesAutoresizingMaskIntoConstraints = NO;

    // Vertical ⋮ like YTM's library rows
    self.menuButton = YTMUIconButton(@"ellipsis", 16, [UIColor whiteColor]);
    self.menuButton.transform = CGAffineTransformMakeRotation((CGFloat)M_PI_2);
    [self.menuButton addTarget:self action:@selector(menuTapped:) forControlEvents:UIControlEventTouchUpInside];

    [self.contentView addSubview:self.coverView];
    [self.contentView addSubview:texts];
    [self.contentView addSubview:self.menuButton];

    [NSLayoutConstraint activateConstraints:@[
        [self.coverView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16],
        [self.coverView.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
        [self.coverView.widthAnchor constraintEqualToConstant:56],
        [self.coverView.heightAnchor constraintEqualToConstant:56],
        [self.coverView.topAnchor constraintGreaterThanOrEqualToAnchor:self.contentView.topAnchor constant:8],
        [self.coverView.bottomAnchor constraintLessThanOrEqualToAnchor:self.contentView.bottomAnchor constant:-8],

        [self.menuButton.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-4],
        [self.menuButton.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
        [self.menuButton.widthAnchor constraintEqualToConstant:44],
        [self.menuButton.heightAnchor constraintEqualToConstant:44],

        [texts.leadingAnchor constraintEqualToAnchor:self.coverView.trailingAnchor constant:14],
        [texts.trailingAnchor constraintEqualToAnchor:self.menuButton.leadingAnchor constant:-4],
        [texts.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
        [self.contentView.heightAnchor constraintGreaterThanOrEqualToConstant:72]
    ]];
    return self;
}

- (void)menuTapped:(UIButton *)sender {
    if (self.onMenu)
        self.onMenu(sender);
}

- (void)layoutSubviews {
    [super layoutSubviews];
    YTMUMoveReorderControlLeft(self);
}

- (void)setEditing:(BOOL)editing animated:(BOOL)animated {
    [super setEditing:editing animated:animated];
    self.menuButton.alpha = editing ? 0.0 : 1.0;
}

- (void)configureWithCollection:(YTMUCollection *)collection {
    self.coverView.image = collection.cover;
    self.coverView.layer.cornerRadius = collection.kind ? 28.0 : 4.0;
    self.titleLabel.text = collection.name;
    self.subtitleLabel.text = collection.subtitle;
}

@end

#pragma mark - Mini player

@interface YTMUMiniPlayerView ()
@property (nonatomic, strong) UIImageView *artworkView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *artistLabel;
@property (nonatomic, strong) UIButton *playButton;
@property (nonatomic, strong) UIButton *nextButton;
@property (nonatomic, strong) UIProgressView *progress;
@end

@implementation YTMUMiniPlayerView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self)
        return nil;

    self.backgroundColor = YTMUIsOLED() ? [UIColor blackColor] : [UIColor colorWithWhite:0.11 alpha:1.0];

    self.progress = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleBar];
    self.progress.progressTintColor = [UIColor whiteColor];
    self.progress.trackTintColor = [UIColor colorWithWhite:1.0 alpha:0.15];
    self.progress.translatesAutoresizingMaskIntoConstraints = NO;

    self.artworkView = [UIImageView new];
    self.artworkView.contentMode = UIViewContentModeScaleAspectFill;
    self.artworkView.clipsToBounds = YES;
    self.artworkView.layer.cornerRadius = 3.0;
    self.artworkView.translatesAutoresizingMaskIntoConstraints = NO;

    self.titleLabel = YTMULabel([UIFont systemFontOfSize:15 weight:UIFontWeightSemibold], [UIColor whiteColor]);
    self.artistLabel = YTMULabel([UIFont systemFontOfSize:13], YTMUSecondaryText());

    self.playButton = YTMUIconButton(@"play.fill", 18, [UIColor whiteColor]);
    self.nextButton = YTMUIconButton(@"forward.end.fill", 17, [UIColor whiteColor]);
    [self.playButton addTarget:self action:@selector(playTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.nextButton addTarget:self action:@selector(nextTapped) forControlEvents:UIControlEventTouchUpInside];

    UIStackView *texts = [[UIStackView alloc] initWithArrangedSubviews:@[self.titleLabel, self.artistLabel]];
    texts.axis = UILayoutConstraintAxisVertical;
    texts.spacing = 2;
    texts.translatesAutoresizingMaskIntoConstraints = NO;

    for (UIView *view in @[self.progress, self.artworkView, texts, self.playButton, self.nextButton])
        [self addSubview:view];

    [NSLayoutConstraint activateConstraints:@[
        [self.progress.topAnchor constraintEqualToAnchor:self.topAnchor],
        [self.progress.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [self.progress.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [self.progress.heightAnchor constraintEqualToConstant:2],

        [self.artworkView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:12],
        [self.artworkView.topAnchor constraintEqualToAnchor:self.topAnchor constant:10],
        [self.artworkView.widthAnchor constraintEqualToConstant:44],
        [self.artworkView.heightAnchor constraintEqualToConstant:44],

        [texts.leadingAnchor constraintEqualToAnchor:self.artworkView.trailingAnchor constant:12],
        [texts.centerYAnchor constraintEqualToAnchor:self.artworkView.centerYAnchor],
        [texts.trailingAnchor constraintLessThanOrEqualToAnchor:self.playButton.leadingAnchor constant:-12],

        [self.playButton.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-16],
        [self.playButton.centerYAnchor constraintEqualToAnchor:self.artworkView.centerYAnchor],
        [self.playButton.widthAnchor constraintEqualToConstant:34],
        [self.nextButton.trailingAnchor constraintEqualToAnchor:self.playButton.leadingAnchor constant:-10],
        [self.nextButton.centerYAnchor constraintEqualToAnchor:self.artworkView.centerYAnchor],
        [self.nextButton.widthAnchor constraintEqualToConstant:34]
    ]];

    [self addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(openNowPlaying)]];

    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserver:self selector:@selector(refresh) name:YTMUOfflinePlayerDidChangeNotification object:nil];
    [center addObserver:self selector:@selector(refreshProgress) name:YTMUOfflinePlayerProgressNotification object:nil];
    [self refresh];
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)setOnVisibilityChange:(void (^)(BOOL))onVisibilityChange {
    _onVisibilityChange = [onVisibilityChange copy];
    if (_onVisibilityChange)
        _onVisibilityChange(!self.hidden);
}

- (void)refresh {
    YTMUOfflinePlayer *player = [YTMUOfflinePlayer shared];
    YTMUOfflineTrack *track = player.currentTrack;
    BOOL visible = track != nil;
    if (self.hidden == visible) {
        self.hidden = !visible;
        if (self.onVisibilityChange)
            self.onVisibilityChange(visible);
    }
    self.artworkView.image = track.artwork;
    self.titleLabel.text = track.title;
    self.artistLabel.text = track.artist;
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:18 weight:UIImageSymbolWeightSemibold];
    [self.playButton setImage:[UIImage systemImageNamed:player.isPlaying ? @"pause.fill" : @"play.fill" withConfiguration:config] forState:UIControlStateNormal];
    [self refreshProgress];
}

- (void)refreshProgress {
    YTMUOfflinePlayer *player = [YTMUOfflinePlayer shared];
    self.progress.progress = player.duration > 0 ? (float)(player.currentTime / player.duration) : 0;
}

- (void)playTapped {
    [[YTMUOfflinePlayer shared] togglePlayPause];
}

- (void)nextTapped {
    [[YTMUOfflinePlayer shared] next];
}

- (void)openNowPlaying {
    YTMUNowPlayingViewController *nowPlaying = [YTMUNowPlayingViewController new];
    nowPlaying.modalPresentationStyle = UIModalPresentationFullScreen;
    [self.presenter presentViewController:nowPlaying animated:YES completion:nil];
}

@end

#pragma mark - Now Playing

@interface YTMUNowPlayingViewController () <UITableViewDataSource, UITableViewDelegate, UIGestureRecognizerDelegate>
@property (nonatomic, strong) CAGradientLayer *gradient;
@property (nonatomic, strong) UIImageView *artworkView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *artistLabel;
@property (nonatomic, strong) UISlider *slider;
@property (nonatomic, strong) UILabel *elapsedLabel;
@property (nonatomic, strong) UILabel *remainingLabel;
@property (nonatomic, strong) UIButton *shuffleButton;
@property (nonatomic, strong) UIButton *previousButton;
@property (nonatomic, strong) UIButton *playButton;
@property (nonatomic, strong) UIButton *nextButton;
@property (nonatomic, strong) UIButton *repeatButton;
@property (nonatomic) BOOL scrubbing;
// Queue ("Up next"): bottom bar opens it, artwork makes room
@property (nonatomic, strong) UIView *upNextBar;
@property (nonatomic, strong) UILabel *upNextLabel;
@property (nonatomic, strong) UIView *queueView;
@property (nonatomic, strong) UILabel *queueSourceLabel;
@property (nonatomic, strong) UITableView *queueTable;
@property (nonatomic, strong) NSArray<YTMUOfflineTrack *> *queueItems;
@property (nonatomic, strong) NSLayoutConstraint *artworkAspect;
@property (nonatomic, strong) NSLayoutConstraint *artworkCollapsed;
@property (nonatomic, strong) NSLayoutConstraint *titleTop;
@property (nonatomic) BOOL showingQueue;
@property (nonatomic) BOOL movingQueueItem;
@end

@implementation YTMUNowPlayingViewController

- (UIStatusBarStyle)preferredStatusBarStyle {
    return UIStatusBarStyleLightContent;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = YTMUBackground();

    self.gradient = YTMUGradientLayer(YTMUIsOLED() ? [UIColor blackColor] : [UIColor colorWithWhite:0.18 alpha:1.0]);
    [self.view.layer insertSublayer:self.gradient atIndex:0];

    UIButton *closeButton = YTMUIconButton(@"chevron.down", 22, [UIColor whiteColor]);
    [closeButton addTarget:self action:@selector(close) forControlEvents:UIControlEventTouchUpInside];

    // Vertical ⋮ top right, like YTM
    UIButton *menuButton = YTMUIconButton(@"ellipsis", 20, [UIColor whiteColor]);
    menuButton.transform = CGAffineTransformMakeRotation((CGFloat)M_PI_2);
    [menuButton addTarget:self action:@selector(showMenu:) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:menuButton];
    [NSLayoutConstraint activateConstraints:@[
        [menuButton.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-16],
        [menuButton.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:8],
        [menuButton.widthAnchor constraintEqualToConstant:44],
        [menuButton.heightAnchor constraintEqualToConstant:44]
    ]];

    self.artworkView = [UIImageView new];
    self.artworkView.contentMode = UIViewContentModeScaleAspectFill;
    self.artworkView.clipsToBounds = YES;
    self.artworkView.layer.cornerRadius = 8.0;
    self.artworkView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.06];
    self.artworkView.translatesAutoresizingMaskIntoConstraints = NO;

    self.titleLabel = YTMULabel([UIFont systemFontOfSize:24 weight:UIFontWeightBold], [UIColor whiteColor]);
    self.artistLabel = YTMULabel([UIFont systemFontOfSize:17], YTMUSecondaryText());
    self.slider = [UISlider new];
    self.slider.minimumTrackTintColor = [UIColor whiteColor];
    self.slider.maximumTrackTintColor = [UIColor colorWithWhite:1.0 alpha:0.25];
    UIImageSymbolConfiguration *thumbConfig = [UIImageSymbolConfiguration configurationWithPointSize:12];
    UIImage *thumb = [[UIImage systemImageNamed:@"circle.fill" withConfiguration:thumbConfig] imageWithTintColor:[UIColor whiteColor] renderingMode:UIImageRenderingModeAlwaysOriginal];
    [self.slider setThumbImage:thumb forState:UIControlStateNormal];
    self.slider.translatesAutoresizingMaskIntoConstraints = NO;
    [self.slider addTarget:self action:@selector(scrubStarted) forControlEvents:UIControlEventTouchDown];
    [self.slider addTarget:self action:@selector(scrubChanged) forControlEvents:UIControlEventValueChanged];
    [self.slider addTarget:self action:@selector(scrubEnded) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];

    self.elapsedLabel = YTMULabel([UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightRegular], YTMUSecondaryText());
    self.remainingLabel = YTMULabel([UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightRegular], YTMUSecondaryText());

    self.shuffleButton = YTMUIconButton(@"shuffle", 22, [UIColor whiteColor]);
    self.previousButton = YTMUIconButton(@"backward.end.fill", 30, [UIColor whiteColor]);
    self.playButton = YTMUCircleButton(@"play.fill", 76, 32, [UIColor whiteColor], [UIColor blackColor]);
    self.nextButton = YTMUIconButton(@"forward.end.fill", 30, [UIColor whiteColor]);
    self.repeatButton = YTMUIconButton(@"repeat", 22, [UIColor whiteColor]);
    [self.shuffleButton addTarget:self action:@selector(shuffleTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.previousButton addTarget:self action:@selector(previousTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.playButton addTarget:self action:@selector(playTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.nextButton addTarget:self action:@selector(nextTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.repeatButton addTarget:self action:@selector(repeatTapped) forControlEvents:UIControlEventTouchUpInside];

    UIStackView *controls = [[UIStackView alloc] initWithArrangedSubviews:@[self.shuffleButton, self.previousButton, self.playButton, self.nextButton, self.repeatButton]];
    controls.axis = UILayoutConstraintAxisHorizontal;
    controls.distribution = UIStackViewDistributionEqualCentering;
    controls.alignment = UIStackViewAlignmentCenter;
    controls.translatesAutoresizingMaskIntoConstraints = NO;

    // Bottom: grabber + song title (cut with …), tap / swipe up = queue
    self.upNextBar = [UIView new];
    self.upNextBar.translatesAutoresizingMaskIntoConstraints = NO;
    UIView *grabber = [UIView new];
    grabber.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.3];
    grabber.layer.cornerRadius = 2.5;
    grabber.translatesAutoresizingMaskIntoConstraints = NO;
    self.upNextLabel = YTMULabel([UIFont systemFontOfSize:15 weight:UIFontWeightSemibold], YTMUSecondaryText());
    self.upNextLabel.textAlignment = NSTextAlignmentCenter;
    self.upNextLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [self.upNextBar addSubview:grabber];
    [self.upNextBar addSubview:self.upNextLabel];
    [self.upNextBar addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(showQueue)]];
    UISwipeGestureRecognizer *swipeUp = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(showQueue)];
    swipeUp.direction = UISwipeGestureRecognizerDirectionUp;
    [self.upNextBar addGestureRecognizer:swipeUp];

    [self buildQueueView];

    for (UIView *view in @[closeButton, self.artworkView, self.titleLabel, self.artistLabel, self.slider, self.elapsedLabel, self.remainingLabel, controls, self.upNextBar, self.queueView])
        [self.view addSubview:view];
    [self.view bringSubviewToFront:menuButton];

    self.artworkAspect = [self.artworkView.heightAnchor constraintEqualToAnchor:self.artworkView.widthAnchor];
    self.artworkCollapsed = [self.artworkView.heightAnchor constraintEqualToConstant:0];
    self.titleTop = [self.titleLabel.topAnchor constraintEqualToAnchor:self.artworkView.bottomAnchor constant:36];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [closeButton.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [closeButton.topAnchor constraintEqualToAnchor:safe.topAnchor constant:8],
        [closeButton.widthAnchor constraintEqualToConstant:44],
        [closeButton.heightAnchor constraintEqualToConstant:44],

        [self.artworkView.topAnchor constraintEqualToAnchor:closeButton.bottomAnchor constant:28],
        [self.artworkView.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:28],
        [self.artworkView.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-28],
        self.artworkAspect,

        self.titleTop,
        [self.titleLabel.leadingAnchor constraintEqualToAnchor:self.artworkView.leadingAnchor],
        [self.titleLabel.trailingAnchor constraintEqualToAnchor:self.artworkView.trailingAnchor],

        [self.artistLabel.topAnchor constraintEqualToAnchor:self.titleLabel.bottomAnchor constant:4],
        [self.artistLabel.leadingAnchor constraintEqualToAnchor:self.artworkView.leadingAnchor],
        [self.artistLabel.trailingAnchor constraintEqualToAnchor:self.artworkView.trailingAnchor],

        [self.slider.topAnchor constraintEqualToAnchor:self.artistLabel.bottomAnchor constant:24],
        [self.slider.leadingAnchor constraintEqualToAnchor:self.artworkView.leadingAnchor],
        [self.slider.trailingAnchor constraintEqualToAnchor:self.artworkView.trailingAnchor],

        [self.elapsedLabel.topAnchor constraintEqualToAnchor:self.slider.bottomAnchor constant:6],
        [self.elapsedLabel.leadingAnchor constraintEqualToAnchor:self.slider.leadingAnchor],
        [self.remainingLabel.topAnchor constraintEqualToAnchor:self.slider.bottomAnchor constant:6],
        [self.remainingLabel.trailingAnchor constraintEqualToAnchor:self.slider.trailingAnchor],

        [controls.topAnchor constraintEqualToAnchor:self.elapsedLabel.bottomAnchor constant:22],
        [controls.leadingAnchor constraintEqualToAnchor:self.artworkView.leadingAnchor],
        [controls.trailingAnchor constraintEqualToAnchor:self.artworkView.trailingAnchor],
        [controls.bottomAnchor constraintLessThanOrEqualToAnchor:self.upNextBar.topAnchor constant:-12],

        [self.upNextBar.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:40],
        [self.upNextBar.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-40],
        [self.upNextBar.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor],
        [self.upNextBar.heightAnchor constraintEqualToConstant:60],
        [grabber.topAnchor constraintEqualToAnchor:self.upNextBar.topAnchor constant:10],
        [grabber.centerXAnchor constraintEqualToAnchor:self.upNextBar.centerXAnchor],
        [grabber.widthAnchor constraintEqualToConstant:36],
        [grabber.heightAnchor constraintEqualToConstant:5],
        [self.upNextLabel.topAnchor constraintEqualToAnchor:grabber.bottomAnchor constant:14],
        [self.upNextLabel.leadingAnchor constraintEqualToAnchor:self.upNextBar.leadingAnchor],
        [self.upNextLabel.trailingAnchor constraintEqualToAnchor:self.upNextBar.trailingAnchor],

        [self.queueView.topAnchor constraintEqualToAnchor:controls.bottomAnchor constant:16],
        [self.queueView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.queueView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.queueView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]
    ]];

    // Swipe down closes, like YTM
    UISwipeGestureRecognizer *swipe = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(close)];
    swipe.direction = UISwipeGestureRecognizerDirectionDown;
    swipe.delegate = self;
    [self.view addGestureRecognizer:swipe];

    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserver:self selector:@selector(refresh) name:YTMUOfflinePlayerDidChangeNotification object:nil];
    [center addObserver:self selector:@selector(refreshProgress) name:YTMUOfflinePlayerProgressNotification object:nil];
    [self refresh];
}

// Scrolling the queue must not close the player
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {
    return ![touch.view isDescendantOfView:self.queueTable];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    self.gradient.frame = self.view.bounds;
}

- (void)refresh {
    YTMUOfflinePlayer *player = [YTMUOfflinePlayer shared];
    YTMUOfflineTrack *track = player.currentTrack;
    if (!track) {
        [self close];
        return;
    }

    self.artworkView.image = track.artwork;
    self.titleLabel.text = track.title;
    self.artistLabel.text = track.artist;
    self.upNextLabel.text = track.title;
    [self reloadQueue];
    self.gradient.colors = @[(id)YTMUGradientTop(track.artwork).CGColor, (id)YTMUBackground().CGColor];

    UIImageSymbolConfiguration *playConfig = [UIImageSymbolConfiguration configurationWithPointSize:32 weight:UIImageSymbolWeightSemibold];
    [self.playButton setImage:[UIImage systemImageNamed:player.isPlaying ? @"pause.fill" : @"play.fill" withConfiguration:playConfig] forState:UIControlStateNormal];

    self.shuffleButton.tintColor = player.isShuffled ? [UIColor whiteColor] : [UIColor colorWithWhite:1.0 alpha:0.45];
    UIImageSymbolConfiguration *smallConfig = [UIImageSymbolConfiguration configurationWithPointSize:22 weight:UIImageSymbolWeightSemibold];
    [self.repeatButton setImage:[UIImage systemImageNamed:player.repeatMode == YTMURepeatOne ? @"repeat.1" : @"repeat" withConfiguration:smallConfig] forState:UIControlStateNormal];
    self.repeatButton.tintColor = player.repeatMode == YTMURepeatOff ? [UIColor colorWithWhite:1.0 alpha:0.45] : [UIColor whiteColor];

    [self refreshProgress];
}

- (void)refreshProgress {
    if (self.scrubbing)
        return;
    YTMUOfflinePlayer *player = [YTMUOfflinePlayer shared];
    NSTimeInterval duration = player.duration;
    self.slider.maximumValue = duration > 0 ? (float)duration : 1;
    self.slider.value = (float)player.currentTime;
    self.elapsedLabel.text = YTMUFormatTime(player.currentTime);
    self.remainingLabel.text = YTMUFormatTime(duration);
}

- (void)scrubStarted {
    self.scrubbing = YES;
}

- (void)scrubChanged {
    self.elapsedLabel.text = YTMUFormatTime(self.slider.value);
}

- (void)scrubEnded {
    [[YTMUOfflinePlayer shared] seekTo:self.slider.value];
    self.scrubbing = NO;
}

- (void)shuffleTapped {
    YTMUOfflinePlayer *player = [YTMUOfflinePlayer shared];
    [player setShuffled:!player.isShuffled];
}

- (void)previousTapped {
    [[YTMUOfflinePlayer shared] previous];
}

- (void)playTapped {
    [[YTMUOfflinePlayer shared] togglePlayPause];
}

- (void)nextTapped {
    [[YTMUOfflinePlayer shared] next];
}

- (void)repeatTapped {
    [[YTMUOfflinePlayer shared] cycleRepeatMode];
}

- (void)showMenu:(UIButton *)sender {
    YTMUOfflineTrack *track = [YTMUOfflinePlayer shared].currentTrack;
    if (!track)
        return;
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:track.title message:track.artist preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Share" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        YTMUShare(@[track.url], self, sender);
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Open folder" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        YTMUOpenInFiles([track.url URLByDeletingLastPathComponent]);
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Add to queue" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [[YTMUOfflinePlayer shared] addToQueue:track];
    }]];
    // Stops everything: players disappear like nothing was played yet
    [sheet addAction:[UIAlertAction actionWithTitle:@"Dismiss queue" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        [[YTMUOfflinePlayer shared] stop];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = sender;
    sheet.popoverPresentationController.sourceRect = sender.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

#pragma mark Queue

- (void)buildQueueView {
    self.queueView = [UIView new];
    self.queueView.backgroundColor = YTMUBackground();
    self.queueView.alpha = 0;
    self.queueView.hidden = YES;
    self.queueView.translatesAutoresizingMaskIntoConstraints = NO;

    UIView *grabber = [UIView new];
    grabber.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.3];
    grabber.layer.cornerRadius = 2.5;
    grabber.translatesAutoresizingMaskIntoConstraints = NO;
    UILabel *playingFrom = YTMULabel([UIFont systemFontOfSize:14], YTMUSecondaryText());
    playingFrom.text = @"Playing from";
    self.queueSourceLabel = YTMULabel([UIFont systemFontOfSize:16 weight:UIFontWeightSemibold], [UIColor whiteColor]);

    // Tap / swipe down on the header: back to the big artwork
    UIView *header = [UIView new];
    header.translatesAutoresizingMaskIntoConstraints = NO;
    [header addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(hideQueue)]];
    UISwipeGestureRecognizer *swipeDown = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(hideQueue)];
    swipeDown.direction = UISwipeGestureRecognizerDirectionDown;
    [header addGestureRecognizer:swipeDown];
    for (UIView *view in @[grabber, playingFrom, self.queueSourceLabel])
        [header addSubview:view];

    self.queueTable = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.queueTable.backgroundColor = [UIColor clearColor];
    self.queueTable.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.queueTable.dataSource = self;
    self.queueTable.delegate = self;
    self.queueTable.rowHeight = UITableViewAutomaticDimension;
    self.queueTable.estimatedRowHeight = 64;
    self.queueTable.allowsSelectionDuringEditing = YES;
    self.queueTable.editing = YES; // handles always on, like YTM
    self.queueTable.translatesAutoresizingMaskIntoConstraints = NO;
    [self.queueTable registerClass:[YTMUTrackCell class] forCellReuseIdentifier:@"queue"];

    [self.queueView addSubview:header];
    [self.queueView addSubview:self.queueTable];
    [NSLayoutConstraint activateConstraints:@[
        [header.topAnchor constraintEqualToAnchor:self.queueView.topAnchor],
        [header.leadingAnchor constraintEqualToAnchor:self.queueView.leadingAnchor],
        [header.trailingAnchor constraintEqualToAnchor:self.queueView.trailingAnchor],
        [grabber.topAnchor constraintEqualToAnchor:header.topAnchor constant:8],
        [grabber.centerXAnchor constraintEqualToAnchor:header.centerXAnchor],
        [grabber.widthAnchor constraintEqualToConstant:36],
        [grabber.heightAnchor constraintEqualToConstant:5],
        [playingFrom.topAnchor constraintEqualToAnchor:grabber.bottomAnchor constant:14],
        [playingFrom.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:16],
        [self.queueSourceLabel.topAnchor constraintEqualToAnchor:playingFrom.bottomAnchor constant:2],
        [self.queueSourceLabel.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:16],
        [self.queueSourceLabel.trailingAnchor constraintLessThanOrEqualToAnchor:header.trailingAnchor constant:-16],
        [self.queueSourceLabel.bottomAnchor constraintEqualToAnchor:header.bottomAnchor constant:-8],

        [self.queueTable.topAnchor constraintEqualToAnchor:header.bottomAnchor],
        [self.queueTable.leadingAnchor constraintEqualToAnchor:self.queueView.leadingAnchor],
        [self.queueTable.trailingAnchor constraintEqualToAnchor:self.queueView.trailingAnchor],
        [self.queueTable.bottomAnchor constraintEqualToAnchor:self.queueView.bottomAnchor]
    ]];
}

- (void)reloadQueue {
    if (!self.showingQueue || self.movingQueueItem)
        return;
    YTMUOfflinePlayer *player = [YTMUOfflinePlayer shared];
    self.queueItems = player.queue;
    self.queueSourceLabel.text = player.sourceName.length ? player.sourceName : @"Downloads";
    [self.queueTable reloadData];
}

- (void)showQueue {
    if (self.showingQueue)
        return;
    self.showingQueue = YES;
    [self reloadQueue];
    self.queueView.hidden = NO;
    self.artworkAspect.active = NO;
    self.artworkCollapsed.active = YES;
    self.titleTop.constant = 4;
    [UIView animateWithDuration:0.3 animations:^{
        self.artworkView.alpha = 0;
        self.upNextBar.alpha = 0;
        self.queueView.alpha = 1;
        [self.view layoutIfNeeded];
    }];
    // Current song at the top of the list
    NSInteger position = [YTMUOfflinePlayer shared].queuePosition;
    if (position >= 0 && position < (NSInteger)self.queueItems.count)
        [self.queueTable scrollToRowAtIndexPath:[NSIndexPath indexPathForRow:position inSection:0] atScrollPosition:UITableViewScrollPositionTop animated:NO];
}

- (void)hideQueue {
    if (!self.showingQueue)
        return;
    self.showingQueue = NO;
    self.artworkCollapsed.active = NO;
    self.artworkAspect.active = YES;
    self.titleTop.constant = 36;
    [UIView animateWithDuration:0.3 animations:^{
        self.artworkView.alpha = 1;
        self.upNextBar.alpha = 1;
        self.queueView.alpha = 0;
        [self.view layoutIfNeeded];
    } completion:^(BOOL finished) {
        if (!self.showingQueue)
            self.queueView.hidden = YES;
    }];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)self.queueItems.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    YTMUTrackCell *cell = [tableView dequeueReusableCellWithIdentifier:@"queue" forIndexPath:indexPath];
    cell.keepsReorderOnRight = YES;
    YTMUOfflinePlayer *player = [YTMUOfflinePlayer shared];
    BOOL isCurrent = indexPath.row == player.queuePosition;
    [cell configureWithTrack:self.queueItems[(NSUInteger)indexPath.row] isCurrent:isCurrent isPlaying:player.isPlaying];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    [[YTMUOfflinePlayer shared] playQueueIndex:indexPath.row];
}

- (BOOL)tableView:(UITableView *)tableView canMoveRowAtIndexPath:(NSIndexPath *)indexPath {
    return YES;
}

- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath {
    return UITableViewCellEditingStyleNone;
}

- (BOOL)tableView:(UITableView *)tableView shouldIndentWhileEditingRowAtIndexPath:(NSIndexPath *)indexPath {
    return NO;
}

- (void)tableView:(UITableView *)tableView moveRowAtIndexPath:(NSIndexPath *)source toIndexPath:(NSIndexPath *)destination {
    // The table already shows the new order: don't reload it in the middle of the move
    self.movingQueueItem = YES;
    [[YTMUOfflinePlayer shared] moveQueueItemFrom:source.row to:destination.row];
    self.movingQueueItem = NO;
    self.queueItems = [YTMUOfflinePlayer shared].queue;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.queueTable reloadData]; // equalizer follows the playing song
    });
}

- (void)close {
    if (self.showingQueue) {
        [self hideQueue];
        return;
    }
    if (self.presentingViewController && !self.isBeingDismissed)
        [self dismissViewControllerAnimated:YES completion:nil];
}

@end

#pragma mark - Album / playlist page

@interface YTMUCollectionViewController () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) YTMUCollection *collection;
@property (nonatomic, strong) NSArray<YTMUOfflineTrack *> *tracks;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UIView *headerView;
@property (nonatomic, strong) CAGradientLayer *gradient;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) YTMUMiniPlayerView *miniPlayer;
@property (nonatomic, strong) NSLayoutConstraint *miniPlayerHeight;
@property (nonatomic, strong) UILabel *detailsLabel;
- (void)updateMiniPlayerHeight;
@property (nonatomic, strong) UIButton *moreButton;
@property (nonatomic, strong) UIStackView *detailsSpacingColumn;
@property (nonatomic, strong) CALayer *backdrop;
@property (nonatomic, strong) UIButton *backButton;
@property (nonatomic, strong) UIView *editBar;
@property (nonatomic, strong) NSArray<YTMUOfflineTrack *> *tracksBeforeEdit;
@property (nonatomic, strong) UIView *findBar;
@property (nonatomic, strong) UITextField *findField;
@property (nonatomic, strong) NSArray<YTMUOfflineTrack *> *foundTracks; // nil = not searching
@property (nonatomic) BOOL detailsExpanded;
@end

@implementation YTMUCollectionViewController

- (instancetype)initWithCollection:(YTMUCollection *)collection {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _collection = collection;
        _tracks = @[];
    }
    return self;
}

- (UIStatusBarStyle)preferredStatusBarStyle {
    return UIStatusBarStyleLightContent;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = YTMUBackground();

    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.tableView.backgroundColor = [UIColor clearColor];
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 64;
    self.tableView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.tableView registerClass:[YTMUTrackCell class] forCellReuseIdentifier:@"track"];
    [self.view addSubview:self.tableView];

    self.miniPlayer = [YTMUMiniPlayerView new];
    self.miniPlayer.presenter = self;
    self.miniPlayer.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.miniPlayer];

    self.miniPlayerHeight = [self.miniPlayer.heightAnchor constraintEqualToConstant:0];
    self.miniPlayerHeight.active = YES;
    __weak __typeof(self) weakSelf = self;
    self.miniPlayer.onVisibilityChange = ^(BOOL visible) {
        [weakSelf updateMiniPlayerHeight];
    };

    UIButton *backButton = [UIButton buttonWithType:UIButtonTypeSystem];
    UIImageSymbolConfiguration *backConfig = [UIImageSymbolConfiguration configurationWithPointSize:20 weight:UIImageSymbolWeightRegular];
    [backButton setImage:[UIImage systemImageNamed:@"chevron.left" withConfiguration:backConfig] forState:UIControlStateNormal];
    backButton.tintColor = [UIColor colorWithWhite:1.0 alpha:0.55];
    backButton.translatesAutoresizingMaskIntoConstraints = NO;
    [backButton addTarget:self action:@selector(back) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:backButton];
    self.backButton = backButton;

    // Edit mode bar: X (cancel) left, Done right, like YTM
    self.editBar = [UIView new];
    self.editBar.backgroundColor = YTMUBackground();
    self.editBar.hidden = YES;
    self.editBar.translatesAutoresizingMaskIntoConstraints = NO;
    UIButton *cancelEdit = YTMUIconButton(@"xmark", 22, [UIColor whiteColor]);
    [cancelEdit addTarget:self action:@selector(cancelEditing) forControlEvents:UIControlEventTouchUpInside];
    UIButton *doneEdit = [UIButton buttonWithType:UIButtonTypeSystem];
    [doneEdit setTitle:@"Done" forState:UIControlStateNormal];
    [doneEdit setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    doneEdit.titleLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightSemibold];
    doneEdit.translatesAutoresizingMaskIntoConstraints = NO;
    [doneEdit addTarget:self action:@selector(finishEditing) forControlEvents:UIControlEventTouchUpInside];
    [self.editBar addSubview:cancelEdit];
    [self.editBar addSubview:doneEdit];
    [self.view addSubview:self.editBar];
    [NSLayoutConstraint activateConstraints:@[
        [self.editBar.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.editBar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.editBar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.editBar.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:52],
        [cancelEdit.leadingAnchor constraintEqualToAnchor:self.editBar.leadingAnchor constant:12],
        [cancelEdit.bottomAnchor constraintEqualToAnchor:self.editBar.bottomAnchor constant:-4],
        [cancelEdit.widthAnchor constraintEqualToConstant:44],
        [cancelEdit.heightAnchor constraintEqualToConstant:44],
        [doneEdit.trailingAnchor constraintEqualToAnchor:self.editBar.trailingAnchor constant:-20],
        [doneEdit.centerYAnchor constraintEqualToAnchor:cancelEdit.centerYAnchor]
    ]];

    // "Find in playlist": search field over the top, the list filters live
    self.findBar = [UIView new];
    self.findBar.backgroundColor = YTMUBackground();
    self.findBar.hidden = YES;
    self.findBar.translatesAutoresizingMaskIntoConstraints = NO;
    UIView *fieldBox = [UIView new];
    fieldBox.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.13];
    fieldBox.layer.cornerRadius = 20;
    fieldBox.translatesAutoresizingMaskIntoConstraints = NO;
    UIImageView *glass = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"magnifyingglass"]];
    glass.tintColor = YTMUSecondaryText();
    glass.translatesAutoresizingMaskIntoConstraints = NO;
    self.findField = [UITextField new];
    self.findField.font = [UIFont systemFontOfSize:17];
    self.findField.textColor = [UIColor whiteColor];
    self.findField.tintColor = [UIColor whiteColor];
    self.findField.keyboardAppearance = UIKeyboardAppearanceDark;
    self.findField.returnKeyType = UIReturnKeySearch;
    self.findField.clearButtonMode = UITextFieldViewModeWhileEditing;
    self.findField.autocorrectionType = UITextAutocorrectionTypeNo;
    self.findField.attributedPlaceholder = [[NSAttributedString alloc] initWithString:self.collection.isAlbum ? @"Find in album" : @"Find in playlist"
                                                                            attributes:@{NSForegroundColorAttributeName: [UIColor colorWithWhite:1.0 alpha:0.55]}];
    self.findField.translatesAutoresizingMaskIntoConstraints = NO;
    [self.findField addTarget:self action:@selector(findChanged) forControlEvents:UIControlEventEditingChanged];
    [self.findField addTarget:self.findField action:@selector(resignFirstResponder) forControlEvents:UIControlEventEditingDidEndOnExit];
    UIButton *cancelFind = [UIButton buttonWithType:UIButtonTypeSystem];
    [cancelFind setTitle:@"Cancel" forState:UIControlStateNormal];
    [cancelFind setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    cancelFind.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightMedium];
    cancelFind.translatesAutoresizingMaskIntoConstraints = NO;
    [cancelFind setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [cancelFind addTarget:self action:@selector(stopFinding) forControlEvents:UIControlEventTouchUpInside];
    [fieldBox addSubview:glass];
    [fieldBox addSubview:self.findField];
    [self.findBar addSubview:fieldBox];
    [self.findBar addSubview:cancelFind];
    [self.view addSubview:self.findBar];
    [NSLayoutConstraint activateConstraints:@[
        [self.findBar.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.findBar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.findBar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.findBar.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:56],
        [fieldBox.leadingAnchor constraintEqualToAnchor:self.findBar.leadingAnchor constant:16],
        [fieldBox.bottomAnchor constraintEqualToAnchor:self.findBar.bottomAnchor constant:-8],
        [fieldBox.heightAnchor constraintEqualToConstant:40],
        [fieldBox.trailingAnchor constraintEqualToAnchor:cancelFind.leadingAnchor constant:-12],
        [cancelFind.trailingAnchor constraintEqualToAnchor:self.findBar.trailingAnchor constant:-16],
        [cancelFind.centerYAnchor constraintEqualToAnchor:fieldBox.centerYAnchor],
        [glass.leadingAnchor constraintEqualToAnchor:fieldBox.leadingAnchor constant:12],
        [glass.centerYAnchor constraintEqualToAnchor:fieldBox.centerYAnchor],
        [self.findField.leadingAnchor constraintEqualToAnchor:glass.trailingAnchor constant:8],
        [self.findField.trailingAnchor constraintEqualToAnchor:fieldBox.trailingAnchor constant:-8],
        [self.findField.topAnchor constraintEqualToAnchor:fieldBox.topAnchor],
        [self.findField.bottomAnchor constraintEqualToAnchor:fieldBox.bottomAnchor]
    ]];

    [NSLayoutConstraint activateConstraints:@[
        [self.tableView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.miniPlayer.topAnchor],

        [self.miniPlayer.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.miniPlayer.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.miniPlayer.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

        [backButton.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:5],
        [backButton.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:0],
        [backButton.widthAnchor constraintEqualToConstant:36],
        [backButton.heightAnchor constraintEqualToConstant:36]
    ]];

    [self buildHeader];

    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.spinner.color = [UIColor whiteColor];
    [self.spinner startAnimating];
    self.tableView.tableFooterView = self.spinner;

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(playerChanged) name:YTMUOfflinePlayerDidChangeNotification object:nil];
    if (self.startsFinding)
        dispatch_async(dispatch_get_main_queue(), ^{
            [self startFinding];
        });
    if (!self.collection.kind && self.collection.folder)
        YTMURecordHistory(self.collection.folder, YES);
    [self loadTracks];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)updateMiniPlayerHeight {
    self.miniPlayerHeight.constant = self.miniPlayer.hidden ? 0 : 64 + self.view.safeAreaInsets.bottom;
}

- (void)viewSafeAreaInsetsDidChange {
    [super viewSafeAreaInsetsDidChange];
    [self updateMiniPlayerHeight];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.miniPlayer refresh];
    [self updateMiniPlayerHeight];
}

- (void)loadTracks {
    YTMUCollection *collection = self.collection;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray<YTMUOfflineTrack *> *tracks = [collection loadTracks];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.tracks = tracks;
            [self.spinner stopAnimating];
            self.tableView.tableFooterView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 1, 24)];
            [self.tableView reloadData];
        });
    });
}

- (void)buildHeader {
    UIView *header = [UIView new];
    // Cover-colored hue at the top, like YTM (also with OLED: only the rest is black)
    self.backdrop = [CALayer layer];
    UIImage *hue = YTMUHueImage(self.collection.cover);
    if (hue) {
        // 3 pixels stretched with linear filtering = soft blend of the cover's colors
        self.backdrop.contents = (__bridge id)hue.CGImage;
        self.backdrop.contentsGravity = @"resize";
        self.backdrop.magnificationFilter = @"linear";
    } else {
        self.backdrop.backgroundColor = YTMUHueColor(self.collection.cover).CGColor;
    }
    // Fades into the page background
    self.gradient = (CAGradientLayer *)[NSClassFromString(@"CAGradientLayer") layer];
    self.gradient.colors = @[(id)[UIColor blackColor].CGColor, (id)[UIColor clearColor].CGColor];
    self.gradient.locations = @[@0.2, @0.7];
    self.backdrop.mask = self.gradient;
    [header.layer insertSublayer:self.backdrop atIndex:0];

    UIImageView *cover = [[UIImageView alloc] initWithImage:self.collection.cover];
    cover.contentMode = UIViewContentModeScaleAspectFill;
    cover.clipsToBounds = YES;
    cover.layer.cornerRadius = self.collection.kind ? 110.0 : 6.0;
    cover.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.06];
    cover.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *title = YTMULabel([UIFont systemFontOfSize:28 weight:UIFontWeightBold], YTMUPureWhite());
    title.text = self.collection.name;
    title.textAlignment = NSTextAlignmentCenter;
    title.numberOfLines = 3;

    // Creator: round picture + name, like YTM
    UIImageView *creatorImage = [[UIImageView alloc] initWithImage:self.collection.creatorImage];
    creatorImage.contentMode = UIViewContentModeScaleAspectFill;
    creatorImage.clipsToBounds = YES;
    creatorImage.layer.cornerRadius = 12.0;
    creatorImage.translatesAutoresizingMaskIntoConstraints = NO;
    [creatorImage.widthAnchor constraintEqualToConstant:24].active = YES;
    [creatorImage.heightAnchor constraintEqualToConstant:24].active = YES;
    creatorImage.hidden = self.collection.creatorImage == nil;

    UILabel *creatorLabel = YTMULabel([UIFont systemFontOfSize:15 weight:UIFontWeightMedium], [UIColor whiteColor]);
    creatorLabel.text = self.collection.creator;

    UIStackView *creatorRow = [[UIStackView alloc] initWithArrangedSubviews:@[creatorImage, creatorLabel]];
    creatorRow.axis = UILayoutConstraintAxisHorizontal;
    creatorRow.spacing = 8;
    creatorRow.alignment = UIStackViewAlignmentCenter;
    creatorRow.hidden = self.collection.creator.length == 0;

    // "Playlist • Fr0z3n • 47 tracks" with the .m4a / .mp3 badge right next to it
    UILabel *subtitle = YTMULabel([UIFont systemFontOfSize:15], YTMUSecondaryText());
    subtitle.text = self.collection.subtitle;
    subtitle.textAlignment = NSTextAlignmentCenter;
    subtitle.numberOfLines = 2;
    [subtitle setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];

    UIStackView *infoRow = [[UIStackView alloc] initWithArrangedSubviews:@[subtitle]];
    infoRow.axis = UILayoutConstraintAxisHorizontal;
    infoRow.spacing = 6;
    infoRow.alignment = UIStackViewAlignmentCenter;
    for (NSString *format in self.collection.formats) {
        UILabel *dot = YTMULabel([UIFont systemFontOfSize:15], YTMUSecondaryText());
        dot.text = @"•";
        [infoRow addArrangedSubview:dot];
        [infoRow addArrangedSubview:[YTMUBadgeLabel badgeWithText:[@"." stringByAppendingString:format]]];
    }

    // Description, 2 lines; "...More" only when it doesn't fit
    self.detailsLabel = YTMULabel([UIFont systemFontOfSize:14], YTMUSecondaryText());
    self.detailsLabel.text = [self.collection.details stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    self.detailsLabel.textAlignment = NSTextAlignmentCenter;
    self.detailsLabel.numberOfLines = 2;
    self.detailsLabel.hidden = self.detailsLabel.text.length == 0;

    self.moreButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.moreButton setTitle:@"...More" forState:UIControlStateNormal];
    [self.moreButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.moreButton.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    self.moreButton.hidden = YES; // decided in viewDidLayoutSubviews
    [self.moreButton addTarget:self action:@selector(toggleDetails) forControlEvents:UIControlEventTouchUpInside];

    UIButton *shuffle = YTMUCircleButton(@"shuffle", 48, 19, [UIColor colorWithWhite:1.0 alpha:0.12], YTMUPureWhite());
    UIButton *play = YTMUCircleButton(@"play.fill", 64, 26, YTMUPureWhite(), [UIColor blackColor]);
    UIButton *menu = YTMUCircleButton(@"ellipsis", 48, 19, [UIColor colorWithWhite:1.0 alpha:0.12], YTMUPureWhite());
    menu.transform = CGAffineTransformMakeRotation((CGFloat)M_PI_2); // vertical ⋮ like YTM
    [shuffle addTarget:self action:@selector(shuffleAll) forControlEvents:UIControlEventTouchUpInside];
    [play addTarget:self action:@selector(playAll) forControlEvents:UIControlEventTouchUpInside];
    [menu addTarget:self action:@selector(showMenu:) forControlEvents:UIControlEventTouchUpInside];

    UIStackView *buttons = [[UIStackView alloc] initWithArrangedSubviews:@[shuffle, play, menu]];
    buttons.axis = UILayoutConstraintAxisHorizontal;
    buttons.spacing = 22;
    buttons.alignment = UIStackViewAlignmentCenter;

    // Hidden rows (no creator / description / More) collapse with their spacing
    UIStackView *column = [[UIStackView alloc] initWithArrangedSubviews:@[title, creatorRow, infoRow, self.detailsLabel, self.moreButton, buttons]];
    column.axis = UILayoutConstraintAxisVertical;
    column.alignment = UIStackViewAlignmentCenter;
    column.spacing = 8;
    [column setCustomSpacing:4 afterView:title];
    [column setCustomSpacing:6 afterView:creatorRow];
    [column setCustomSpacing:8 afterView:infoRow];
    [column setCustomSpacing:0 afterView:self.detailsLabel];
    [column setCustomSpacing:20 afterView:self.moreButton];
    column.translatesAutoresizingMaskIntoConstraints = NO;
    // Space above the buttons when the description is the last text
    self.detailsSpacingColumn = column;

    [header addSubview:column];

    CGFloat top = UIApplication.sharedApplication.keyWindow.safeAreaInsets.top + 48;
    // Artists / creators: their saved picture is tiny, so no picture, text moves up
    NSLayoutConstraint *columnTop = [column.topAnchor constraintEqualToAnchor:header.topAnchor constant:top];
    if (!self.collection.kind) {
        [header addSubview:cover];
        [NSLayoutConstraint activateConstraints:@[
            [cover.topAnchor constraintEqualToAnchor:header.topAnchor constant:top],
            [cover.centerXAnchor constraintEqualToAnchor:header.centerXAnchor],
            [cover.widthAnchor constraintEqualToConstant:220],
            [cover.heightAnchor constraintEqualToConstant:220]
        ]];
        columnTop = [column.topAnchor constraintEqualToAnchor:cover.bottomAnchor constant:18];
    }
    [NSLayoutConstraint activateConstraints:@[
        columnTop,
        [column.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:24],
        [column.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-24],
        [column.bottomAnchor constraintEqualToAnchor:header.bottomAnchor constant:-16],

        [title.widthAnchor constraintEqualToAnchor:column.widthAnchor],
        [self.detailsLabel.widthAnchor constraintEqualToAnchor:column.widthAnchor],
        [infoRow.widthAnchor constraintLessThanOrEqualToAnchor:column.widthAnchor]
    ]];

    self.headerView = header;
}

// "...More" only for descriptions longer than 2 lines
- (void)updateMoreButton {
    NSString *text = self.detailsLabel.text;
    CGFloat width = self.view.bounds.size.width - 48;
    BOOL tooLong = NO;
    if (text.length && width > 0) {
        UIFont *font = self.detailsLabel.font;
        CGRect rect = [text boundingRectWithSize:CGSizeMake(width, CGFLOAT_MAX)
                                         options:NSStringDrawingUsesLineFragmentOrigin
                                      attributes:@{NSFontAttributeName: font}
                                         context:nil];
        tooLong = ceil(rect.size.height) > ceil(font.lineHeight * 2.0) + 1.0;
    }
    if (self.moreButton.hidden == tooLong)
        self.moreButton.hidden = !tooLong;
    // Without "...More" the buttons need the gap right after the description
    [self.detailsSpacingColumn setCustomSpacing:tooLong ? 0 : 20 afterView:self.detailsLabel];
}

- (void)toggleDetails {
    self.detailsExpanded = !self.detailsExpanded;
    self.detailsLabel.numberOfLines = self.detailsExpanded ? 0 : 2;
    [self.moreButton setTitle:self.detailsExpanded ? @"Less" : @"...More" forState:UIControlStateNormal];
    [self.headerView setNeedsLayout];
    [self.headerView layoutIfNeeded];
    [self.view setNeedsLayout];
}

- (void)showMenu:(UIButton *)sender {
    __weak __typeof(self) weakSelf = self;
    // Edit (reorder) only for real playlists / albums
    YTMUShowCollectionMenuFull(self.collection, self, sender, ^{
        if (weakSelf.onChange)
            weakSelf.onChange();
        [weakSelf dismissViewControllerAnimated:YES completion:nil];
    }, self.collection.kind ? nil : ^{
        [weakSelf startEditing];
    }, ^{
        [weakSelf startFinding];
    });
}

#pragma mark Find in playlist

- (NSArray<YTMUOfflineTrack *> *)visibleTracks {
    return self.foundTracks ?: self.tracks;
}

- (void)startFinding {
    if (self.tableView.editing)
        return;
    self.findBar.hidden = NO;
    self.backButton.hidden = YES;
    self.findField.text = @"";
    self.foundTracks = self.tracks;
    [self.tableView reloadData];
    [self.findField becomeFirstResponder];
}

- (void)stopFinding {
    [self.findField resignFirstResponder];
    self.findBar.hidden = YES;
    self.backButton.hidden = NO;
    self.foundTracks = nil;
    [self.tableView reloadData];
}

- (void)findChanged {
    NSString *query = [self.findField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (query.length == 0) {
        self.foundTracks = self.tracks;
    } else {
        NSArray<NSString *> *words = [query componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        NSMutableArray<YTMUOfflineTrack *> *found = [NSMutableArray array];
        for (YTMUOfflineTrack *track in self.tracks) {
            NSString *text = [NSString stringWithFormat:@"%@ %@ %@", track.title ?: @"", track.artist ?: @"", track.album ?: @""];
            BOOL all = YES;
            for (NSString *word in words) {
                if (word.length && [text rangeOfString:word options:NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch].location == NSNotFound)
                    all = NO;
            }
            if (all)
                [found addObject:track];
        }
        self.foundTracks = found;
    }
    [self.tableView reloadData];
}

#pragma mark Edit (reorder songs)

- (void)startEditing {
    if (self.tracks.count < 2)
        return;
    if (self.foundTracks)
        [self stopFinding];
    self.tracksBeforeEdit = self.tracks;
    self.editBar.hidden = NO;
    self.backButton.hidden = YES;
    [self setTableEditingKeepingPosition:YES];
}

// Switching edit mode must not move the list
- (void)setTableEditingKeepingPosition:(BOOL)editing {
    CGPoint offset = self.tableView.contentOffset;
    [UIView performWithoutAnimation:^{
        [self.tableView setEditing:editing animated:NO];
        [self.tableView reloadData];
        [self.tableView layoutIfNeeded];
        self.tableView.contentOffset = offset;
    }];
}

- (void)endEditing {
    self.editBar.hidden = YES;
    self.backButton.hidden = NO;
    [self setTableEditingKeepingPosition:NO];
}

- (void)cancelEditing {
    self.tracks = self.tracksBeforeEdit ?: self.tracks;
    [self endEditing];
}

- (void)finishEditing {
    NSArray<NSURL *> *order = [self.tracks valueForKey:@"url"];
    if (self.collection.folder)
        YTMUSaveOrder(order, YTMUTrackOrderKey(self.collection.folder));
    self.collection.files = order;
    [self endEditing];
    if (self.onChange)
        self.onChange();
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    return tableView.editing;
}

- (BOOL)tableView:(UITableView *)tableView canMoveRowAtIndexPath:(NSIndexPath *)indexPath {
    return YES;
}

- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath {
    return UITableViewCellEditingStyleNone;
}

- (BOOL)tableView:(UITableView *)tableView shouldIndentWhileEditingRowAtIndexPath:(NSIndexPath *)indexPath {
    return NO;
}

- (void)tableView:(UITableView *)tableView moveRowAtIndexPath:(NSIndexPath *)sourceIndexPath toIndexPath:(NSIndexPath *)destinationIndexPath {
    NSMutableArray<YTMUOfflineTrack *> *tracks = [self.tracks mutableCopy];
    YTMUOfflineTrack *track = tracks[(NSUInteger)sourceIndexPath.row];
    [tracks removeObjectAtIndex:(NSUInteger)sourceIndexPath.row];
    [tracks insertObject:track atIndex:(NSUInteger)destinationIndexPath.row];
    self.tracks = tracks;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    // Size the header to its content once the width is known
    CGFloat width = self.view.bounds.size.width;
    if (width <= 0)
        return;
    [self updateMoreButton];
    CGSize size = [self.headerView systemLayoutSizeFittingSize:CGSizeMake(width, UILayoutFittingCompressedSize.height)
                                 withHorizontalFittingPriority:UILayoutPriorityRequired
                                       verticalFittingPriority:UILayoutPriorityFittingSizeLevel];
    if (self.tableView.tableHeaderView != self.headerView || fabs(self.headerView.frame.size.height - size.height) > 0.5 ||
        fabs(self.headerView.frame.size.width - width) > 0.5) {
        self.headerView.frame = CGRectMake(0, 0, width, size.height);
        self.backdrop.frame = self.headerView.bounds;
        self.gradient.frame = self.backdrop.bounds;
        self.tableView.tableHeaderView = self.headerView;
    }
}

- (void)playerChanged {
    [self.tableView reloadData];
}

#pragma mark Actions

- (void)back {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)playAll {
    [[YTMUOfflinePlayer shared] playTracks:self.tracks startIndex:0 shuffle:NO];
    [YTMUOfflinePlayer shared].sourceName = self.collection.name;
}

- (void)shuffleAll {
    [[YTMUOfflinePlayer shared] playTracks:self.tracks startIndex:-1 shuffle:YES];
    [YTMUOfflinePlayer shared].sourceName = self.collection.name;
}

- (void)shareAll:(UIButton *)sender {
    YTMUShare(self.collection.files, self, sender);
}

#pragma mark Table

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)self.visibleTracks.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    YTMUTrackCell *cell = [tableView dequeueReusableCellWithIdentifier:@"track" forIndexPath:indexPath];
    YTMUOfflineTrack *track = self.visibleTracks[(NSUInteger)indexPath.row];
    YTMUOfflinePlayer *player = [YTMUOfflinePlayer shared];
    BOOL isCurrent = [player.currentTrack.url isEqual:track.url];
    [cell configureWithTrack:track isCurrent:isCurrent isPlaying:player.isPlaying];
    __weak __typeof(self) weakSelf = self;
    cell.onMenu = ^(UIButton *sender) {
        [weakSelf showMenuForTrack:track from:sender];
    };
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    YTMUOfflinePlayer *player = [YTMUOfflinePlayer shared];
    // Found songs play within the whole playlist
    YTMUOfflineTrack *track = self.visibleTracks[(NSUInteger)indexPath.row];
    NSUInteger index = [self.tracks indexOfObject:track];
    [self.findField resignFirstResponder];
    [player playTracks:self.tracks startIndex:index == NSNotFound ? 0 : (NSInteger)index shuffle:player.isShuffled];
    player.sourceName = self.collection.name;
}

- (void)showMenuForTrack:(YTMUOfflineTrack *)track from:(UIButton *)sender {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:track.title message:track.artist preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Add to queue" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [[YTMUOfflinePlayer shared] addToQueue:track];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Share" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        YTMUShare(@[track.url], self, sender);
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Delete download" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        [self confirmDeleteTrack:track completion:^(BOOL deleted) {
        }];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = sender;
    sheet.popoverPresentationController.sourceRect = sender.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)confirmDeleteTrack:(YTMUOfflineTrack *)track completion:(void (^)(BOOL))completion {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:track.title
                                                                   message:@"Delete this downloaded song?"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Delete" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        YTMUOfflinePlayer *player = [YTMUOfflinePlayer shared];
        if ([player.currentTrack.url isEqual:track.url])
            [player stop];
        [[NSFileManager defaultManager] removeItemAtURL:track.url error:nil];
        NSMutableArray *tracks = [self.tracks mutableCopy];
        [tracks removeObject:track];
        self.tracks = tracks;
        if (self.foundTracks) {
            NSMutableArray *found = [self.foundTracks mutableCopy];
            [found removeObject:track];
            self.foundTracks = found;
        }
        if (self.collection.folder) {
            self.collection.files = [YTMUCollection audioFilesInFolder:self.collection.folder];
        } else {
            NSMutableArray<NSURL *> *files = [self.collection.files mutableCopy];
            [files removeObject:track.url];
            self.collection.files = files;
        }
        [self.tableView reloadData];
        if (self.onChange)
            self.onChange();
        completion(YES);
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) {
        completion(NO);
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end