#import "YTMUOfflineUI.h"
#import <QuartzCore/QuartzCore.h>

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

// YTM-style hue: the cover shrunk to 3x3 pixels (a strong blur), darkened.
// Shown stretched with linear filtering it becomes a soft multi-color glow.
static UIImage *YTMUBackdropImage(UIImage *cover) {
    CGImageRef cgImage = cover.CGImage;
    if (!cgImage)
        return nil;
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.scale = 1.0;
    format.opaque = YES;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(3, 3) format:format];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        CGContextSetInterpolationQuality(context.CGContext, kCGInterpolationHigh);
        [cover drawInRect:CGRectMake(0, 0, 3, 3)];
        [[UIColor colorWithWhite:0.0 alpha:0.58] setFill];
        UIRectFillUsingBlendMode(CGRectMake(0, 0, 3, 3), kCGBlendModeNormal);
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
    return audio;
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
    return collections;
}

- (NSArray<YTMUOfflineTrack *> *)loadTracks {
    NSMutableArray<YTMUOfflineTrack *> *tracks = [NSMutableArray array];
    for (NSURL *file in self.files)
        [tracks addObject:[YTMUOfflineTrack trackWithURL:file fallbackArtwork:self.cover]];
    return tracks;
}

- (NSString *)subtitle {
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

void YTMUShowCollectionMenu(YTMUCollection *collection, UIViewController *presenter, UIView *source, void (^onDeleted)(void)) {
    if (!collection || !presenter)
        return;
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:collection.name
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Share" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        YTMUShare(collection.files, presenter, source);
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Open folder" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        // Files app, right inside this playlist's folder
        NSString *path = [collection.folder.path stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLPathAllowedCharacterSet]];
        NSURL *filesURL = [NSURL URLWithString:[@"shareddocuments://" stringByAppendingString:path ?: @""]];
        if (filesURL)
            [[UIApplication sharedApplication] openURL:filesURL options:@{} completionHandler:nil];
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
    return self;
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
    if (self.animating)
        [self startAnimations];
}

- (void)setAnimating:(BOOL)animating {
    if (_animating == animating)
        return;
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

#pragma mark - Track cell

@interface YTMUTrackCell ()
@property (nonatomic, strong) UIImageView *artworkView;
@property (nonatomic, strong) UIView *equalizerBackground;
@property (nonatomic, strong) YTMUEqualizerView *equalizer;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *subtitleLabel;
@property (nonatomic, strong) UIButton *menuButton;
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

    self.artworkView.image = track.artwork;
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

- (void)configureWithCollection:(YTMUCollection *)collection {
    self.coverView.image = collection.cover;
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

@interface YTMUNowPlayingViewController ()
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

    for (UIView *view in @[closeButton, self.artworkView, self.titleLabel, self.artistLabel, self.slider, self.elapsedLabel, self.remainingLabel, controls])
        [self.view addSubview:view];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [closeButton.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [closeButton.topAnchor constraintEqualToAnchor:safe.topAnchor constant:8],
        [closeButton.widthAnchor constraintEqualToConstant:44],
        [closeButton.heightAnchor constraintEqualToConstant:44],

        [self.artworkView.topAnchor constraintEqualToAnchor:closeButton.bottomAnchor constant:28],
        [self.artworkView.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:28],
        [self.artworkView.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-28],
        [self.artworkView.heightAnchor constraintEqualToAnchor:self.artworkView.widthAnchor],

        [self.titleLabel.topAnchor constraintEqualToAnchor:self.artworkView.bottomAnchor constant:36],
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
        [controls.bottomAnchor constraintLessThanOrEqualToAnchor:safe.bottomAnchor constant:-20]
    ]];

    // Swipe down closes, like YTM
    UISwipeGestureRecognizer *swipe = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(close)];
    swipe.direction = UISwipeGestureRecognizerDirectionDown;
    [self.view addGestureRecognizer:swipe];

    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserver:self selector:@selector(refresh) name:YTMUOfflinePlayerDidChangeNotification object:nil];
    [center addObserver:self selector:@selector(refreshProgress) name:YTMUOfflinePlayerProgressNotification object:nil];
    [self refresh];
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

- (void)close {
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
    UIImage *backdrop = YTMUBackdropImage(self.collection.cover);
    self.backdrop = [CALayer layer];
    self.backdrop.contents = (__bridge id)backdrop.CGImage;
    self.backdrop.contentsGravity = @"resize";
    self.backdrop.magnificationFilter = @"linear";
    // Fades into the page background
    self.gradient = (CAGradientLayer *)[NSClassFromString(@"CAGradientLayer") layer];
    self.gradient.colors = @[(id)[UIColor blackColor].CGColor, (id)[UIColor clearColor].CGColor];
    self.gradient.locations = @[@0.2, @0.7];
    self.backdrop.mask = self.gradient;
    [header.layer insertSublayer:self.backdrop atIndex:0];

    UIImageView *cover = [[UIImageView alloc] initWithImage:self.collection.cover];
    cover.contentMode = UIViewContentModeScaleAspectFill;
    cover.clipsToBounds = YES;
    cover.layer.cornerRadius = 6.0;
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

    [header addSubview:cover];
    [header addSubview:column];

    CGFloat top = UIApplication.sharedApplication.keyWindow.safeAreaInsets.top + 48;
    [NSLayoutConstraint activateConstraints:@[
        [cover.topAnchor constraintEqualToAnchor:header.topAnchor constant:top],
        [cover.centerXAnchor constraintEqualToAnchor:header.centerXAnchor],
        [cover.widthAnchor constraintEqualToConstant:220],
        [cover.heightAnchor constraintEqualToConstant:220],

        [column.topAnchor constraintEqualToAnchor:cover.bottomAnchor constant:18],
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
    YTMUShowCollectionMenu(self.collection, self, sender, ^{
        if (self.onChange)
            self.onChange();
        [self dismissViewControllerAnimated:YES completion:nil];
    });
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
}

- (void)shuffleAll {
    [[YTMUOfflinePlayer shared] playTracks:self.tracks startIndex:-1 shuffle:YES];
}

- (void)shareAll:(UIButton *)sender {
    YTMUShare(self.collection.files, self, sender);
}

#pragma mark Table

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)self.tracks.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    YTMUTrackCell *cell = [tableView dequeueReusableCellWithIdentifier:@"track" forIndexPath:indexPath];
    YTMUOfflineTrack *track = self.tracks[(NSUInteger)indexPath.row];
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
    [player playTracks:self.tracks startIndex:indexPath.row shuffle:player.isShuffled];
}

- (void)showMenuForTrack:(YTMUOfflineTrack *)track from:(UIButton *)sender {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:track.title message:track.artist preferredStyle:UIAlertControllerStyleActionSheet];
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
        self.collection.files = [YTMUCollection audioFilesInFolder:self.collection.folder];
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