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

static UIColor *YTMUBackground(void) {
    return [UIColor colorWithRed:3 / 255.0 green:3 / 255.0 blue:3 / 255.0 alpha:1.0];
}

static UIColor *YTMUSecondaryText(void) {
    return [UIColor colorWithWhite:1.0 alpha:0.62];
}

static UIColor *YTMUAccent(void) {
    return [UIColor colorWithRed:1.0 green:0.0 blue:0.2 alpha:1.0];
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
    if (self.artist.length)
        [parts addObject:self.artist];
    if (self.year.length)
        [parts addObject:self.year];
    [parts addObject:[NSString stringWithFormat:@"%lu %@", (unsigned long)self.files.count, self.files.count == 1 ? @"song" : @"songs"]];
    return [parts componentsJoinedByString:@" • "];
}

@end

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

#pragma mark - Track cell

@interface YTMUTrackCell ()
@property (nonatomic, strong) UIImageView *artworkView;
@property (nonatomic, strong) UILabel *numberLabel;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *subtitleLabel;
@property (nonatomic, strong) YTMUBadgeLabel *badge;
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

    self.numberLabel = YTMULabel([UIFont monospacedDigitSystemFontOfSize:16 weight:UIFontWeightMedium], YTMUSecondaryText());
    self.numberLabel.textAlignment = NSTextAlignmentCenter;

    self.titleLabel = YTMULabel([UIFont systemFontOfSize:16 weight:UIFontWeightSemibold], [UIColor whiteColor]);
    self.subtitleLabel = YTMULabel([UIFont systemFontOfSize:14], YTMUSecondaryText());
    self.badge = [YTMUBadgeLabel badgeWithText:@""];

    UIStackView *texts = [[UIStackView alloc] initWithArrangedSubviews:@[self.titleLabel, self.subtitleLabel]];
    texts.axis = UILayoutConstraintAxisVertical;
    texts.spacing = 3;
    texts.translatesAutoresizingMaskIntoConstraints = NO;

    [self.contentView addSubview:self.artworkView];
    [self.contentView addSubview:self.numberLabel];
    [self.contentView addSubview:texts];
    [self.contentView addSubview:self.badge];

    [NSLayoutConstraint activateConstraints:@[
        [self.artworkView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16],
        [self.artworkView.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
        [self.artworkView.widthAnchor constraintEqualToConstant:48],
        [self.artworkView.heightAnchor constraintEqualToConstant:48],
        [self.artworkView.topAnchor constraintGreaterThanOrEqualToAnchor:self.contentView.topAnchor constant:8],
        [self.artworkView.bottomAnchor constraintLessThanOrEqualToAnchor:self.contentView.bottomAnchor constant:-8],

        [self.numberLabel.centerXAnchor constraintEqualToAnchor:self.artworkView.centerXAnchor],
        [self.numberLabel.centerYAnchor constraintEqualToAnchor:self.artworkView.centerYAnchor],

        [texts.leadingAnchor constraintEqualToAnchor:self.artworkView.trailingAnchor constant:14],
        [texts.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
        [texts.trailingAnchor constraintLessThanOrEqualToAnchor:self.badge.leadingAnchor constant:-10],

        [self.badge.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16],
        [self.badge.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
        [self.contentView.heightAnchor constraintGreaterThanOrEqualToConstant:64]
    ]];
    return self;
}

- (void)configureWithTrack:(YTMUOfflineTrack *)track showNumber:(BOOL)showNumber isCurrent:(BOOL)isCurrent {
    self.titleLabel.text = track.title;
    self.titleLabel.textColor = isCurrent ? YTMUAccent() : [UIColor whiteColor];

    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    if (track.artist.length)
        [parts addObject:track.artist];
    if (track.duration > 0)
        [parts addObject:YTMUFormatTime(track.duration)];
    self.subtitleLabel.text = [parts componentsJoinedByString:@" • "];

    self.badge.text = [@"." stringByAppendingString:track.format ?: @""];
    [self.badge invalidateIntrinsicContentSize];

    self.numberLabel.hidden = !showNumber;
    self.artworkView.hidden = showNumber;
    self.numberLabel.text = track.number > 0 ? [NSString stringWithFormat:@"%ld", (long)track.number] : @"–";
    self.artworkView.image = showNumber ? nil : track.artwork;
}

@end

#pragma mark - Collection cell

@interface YTMUCollectionCell ()
@property (nonatomic, strong) UIImageView *coverView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *subtitleLabel;
@property (nonatomic, strong) UIStackView *badges;
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

    self.titleLabel = YTMULabel([UIFont systemFontOfSize:17 weight:UIFontWeightSemibold], [UIColor whiteColor]);
    self.subtitleLabel = YTMULabel([UIFont systemFontOfSize:14], YTMUSecondaryText());
    self.subtitleLabel.numberOfLines = 2;

    self.badges = [UIStackView new];
    self.badges.axis = UILayoutConstraintAxisHorizontal;
    self.badges.spacing = 6;
    self.badges.alignment = UIStackViewAlignmentLeading;

    UIView *badgeRow = [UIView new];
    self.badges.translatesAutoresizingMaskIntoConstraints = NO;
    [badgeRow addSubview:self.badges];
    [NSLayoutConstraint activateConstraints:@[
        [self.badges.leadingAnchor constraintEqualToAnchor:badgeRow.leadingAnchor],
        [self.badges.topAnchor constraintEqualToAnchor:badgeRow.topAnchor],
        [self.badges.bottomAnchor constraintEqualToAnchor:badgeRow.bottomAnchor],
        [self.badges.trailingAnchor constraintLessThanOrEqualToAnchor:badgeRow.trailingAnchor]
    ]];

    UIStackView *texts = [[UIStackView alloc] initWithArrangedSubviews:@[self.titleLabel, self.subtitleLabel, badgeRow]];
    texts.axis = UILayoutConstraintAxisVertical;
    texts.spacing = 4;
    texts.translatesAutoresizingMaskIntoConstraints = NO;

    [self.contentView addSubview:self.coverView];
    [self.contentView addSubview:texts];

    [NSLayoutConstraint activateConstraints:@[
        [self.coverView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16],
        [self.coverView.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
        [self.coverView.widthAnchor constraintEqualToConstant:72],
        [self.coverView.heightAnchor constraintEqualToConstant:72],
        [self.coverView.topAnchor constraintGreaterThanOrEqualToAnchor:self.contentView.topAnchor constant:8],
        [self.coverView.bottomAnchor constraintLessThanOrEqualToAnchor:self.contentView.bottomAnchor constant:-8],

        [texts.leadingAnchor constraintEqualToAnchor:self.coverView.trailingAnchor constant:16],
        [texts.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16],
        [texts.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
        [self.contentView.heightAnchor constraintGreaterThanOrEqualToConstant:88]
    ]];
    return self;
}

- (void)configureWithCollection:(YTMUCollection *)collection {
    self.coverView.image = collection.cover;
    self.titleLabel.text = collection.name;
    self.subtitleLabel.text = collection.subtitle;
    for (UIView *view in [self.badges.arrangedSubviews copy]) {
        [self.badges removeArrangedSubview:view];
        [view removeFromSuperview];
    }
    for (NSString *format in collection.formats)
        [self.badges addArrangedSubview:[YTMUBadgeLabel badgeWithText:[@"." stringByAppendingString:format]]];
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

    self.backgroundColor = [UIColor colorWithWhite:0.11 alpha:1.0];

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

    self.playButton = YTMUIconButton(@"play.fill", 22, [UIColor whiteColor]);
    self.nextButton = YTMUIconButton(@"forward.end.fill", 20, [UIColor whiteColor]);
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

        [self.nextButton.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-16],
        [self.nextButton.centerYAnchor constraintEqualToAnchor:self.artworkView.centerYAnchor],
        [self.nextButton.widthAnchor constraintEqualToConstant:36],
        [self.playButton.trailingAnchor constraintEqualToAnchor:self.nextButton.leadingAnchor constant:-12],
        [self.playButton.centerYAnchor constraintEqualToAnchor:self.artworkView.centerYAnchor],
        [self.playButton.widthAnchor constraintEqualToConstant:36]
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

- (void)refresh {
    YTMUOfflinePlayer *player = [YTMUOfflinePlayer shared];
    YTMUOfflineTrack *track = player.currentTrack;
    self.hidden = track == nil;
    self.artworkView.image = track.artwork;
    self.titleLabel.text = track.title;
    self.artistLabel.text = track.artist;
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:22 weight:UIImageSymbolWeightSemibold];
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
@property (nonatomic, strong) YTMUBadgeLabel *badge;
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

    self.gradient = YTMUGradientLayer([UIColor colorWithWhite:0.18 alpha:1.0]);
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
    self.badge = [YTMUBadgeLabel badgeWithText:@""];

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

    for (UIView *view in @[closeButton, self.artworkView, self.titleLabel, self.artistLabel, self.badge, self.slider, self.elapsedLabel, self.remainingLabel, controls])
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
        [self.titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.badge.leadingAnchor constant:-10],
        [self.badge.trailingAnchor constraintEqualToAnchor:self.artworkView.trailingAnchor],
        [self.badge.centerYAnchor constraintEqualToAnchor:self.titleLabel.centerYAnchor],

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
    self.badge.text = [@"." stringByAppendingString:track.format ?: @""];
    [self.badge invalidateIntrinsicContentSize];
    self.gradient.colors = @[(id)YTMUAverageColor(track.artwork).CGColor, (id)YTMUBackground().CGColor];

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

    UIButton *backButton = YTMUIconButton(@"chevron.left", 20, [UIColor whiteColor]);
    backButton.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.35];
    backButton.layer.cornerRadius = 20;
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
        [self.miniPlayer.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-64],

        [backButton.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:12],
        [backButton.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:6],
        [backButton.widthAnchor constraintEqualToConstant:40],
        [backButton.heightAnchor constraintEqualToConstant:40]
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
    self.gradient = YTMUGradientLayer(YTMUAverageColor(self.collection.cover));
    [header.layer insertSublayer:self.gradient atIndex:0];

    UIImageView *cover = [[UIImageView alloc] initWithImage:self.collection.cover];
    cover.contentMode = UIViewContentModeScaleAspectFill;
    cover.clipsToBounds = YES;
    cover.layer.cornerRadius = 8.0;
    cover.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.06];
    cover.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *title = YTMULabel([UIFont systemFontOfSize:28 weight:UIFontWeightBold], [UIColor whiteColor]);
    title.text = self.collection.name;
    title.textAlignment = NSTextAlignmentCenter;
    title.numberOfLines = 2;

    UILabel *subtitle = YTMULabel([UIFont systemFontOfSize:15], YTMUSecondaryText());
    subtitle.text = self.collection.subtitle;
    subtitle.textAlignment = NSTextAlignmentCenter;
    subtitle.numberOfLines = 2;

    UIStackView *badges = [UIStackView new];
    badges.axis = UILayoutConstraintAxisHorizontal;
    badges.spacing = 6;
    badges.translatesAutoresizingMaskIntoConstraints = NO;
    for (NSString *format in self.collection.formats)
        [badges addArrangedSubview:[YTMUBadgeLabel badgeWithText:[@"." stringByAppendingString:format]]];

    UIButton *shuffle = YTMUCircleButton(@"shuffle", 52, 20, [UIColor colorWithWhite:1.0 alpha:0.12], [UIColor whiteColor]);
    UIButton *play = YTMUCircleButton(@"play.fill", 68, 28, [UIColor whiteColor], [UIColor blackColor]);
    UIButton *share = YTMUCircleButton(@"square.and.arrow.up", 52, 20, [UIColor colorWithWhite:1.0 alpha:0.12], [UIColor whiteColor]);
    [shuffle addTarget:self action:@selector(shuffleAll) forControlEvents:UIControlEventTouchUpInside];
    [play addTarget:self action:@selector(playAll) forControlEvents:UIControlEventTouchUpInside];
    [share addTarget:self action:@selector(shareAll:) forControlEvents:UIControlEventTouchUpInside];

    UIStackView *buttons = [[UIStackView alloc] initWithArrangedSubviews:@[shuffle, play, share]];
    buttons.axis = UILayoutConstraintAxisHorizontal;
    buttons.spacing = 28;
    buttons.alignment = UIStackViewAlignmentCenter;
    buttons.translatesAutoresizingMaskIntoConstraints = NO;

    for (UIView *view in @[cover, title, subtitle, badges, buttons])
        [header addSubview:view];

    CGFloat top = UIApplication.sharedApplication.keyWindow.safeAreaInsets.top + 56;
    [NSLayoutConstraint activateConstraints:@[
        [cover.topAnchor constraintEqualToAnchor:header.topAnchor constant:top],
        [cover.centerXAnchor constraintEqualToAnchor:header.centerXAnchor],
        [cover.widthAnchor constraintEqualToConstant:240],
        [cover.heightAnchor constraintEqualToConstant:240],

        [title.topAnchor constraintEqualToAnchor:cover.bottomAnchor constant:24],
        [title.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:24],
        [title.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-24],

        [subtitle.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:8],
        [subtitle.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:24],
        [subtitle.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-24],

        [badges.topAnchor constraintEqualToAnchor:subtitle.bottomAnchor constant:10],
        [badges.centerXAnchor constraintEqualToAnchor:header.centerXAnchor],

        [buttons.topAnchor constraintEqualToAnchor:badges.bottomAnchor constant:22],
        [buttons.centerXAnchor constraintEqualToAnchor:header.centerXAnchor],
        [buttons.bottomAnchor constraintEqualToAnchor:header.bottomAnchor constant:-20]
    ]];

    self.headerView = header;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    // Size the header to its content once the width is known
    CGFloat width = self.view.bounds.size.width;
    if (width <= 0)
        return;
    CGSize size = [self.headerView systemLayoutSizeFittingSize:CGSizeMake(width, UILayoutFittingCompressedSize.height)
                                 withHorizontalFittingPriority:UILayoutPriorityRequired
                                       verticalFittingPriority:UILayoutPriorityFittingSizeLevel];
    if (self.tableView.tableHeaderView != self.headerView || fabs(self.headerView.frame.size.height - size.height) > 0.5 ||
        fabs(self.headerView.frame.size.width - width) > 0.5) {
        self.headerView.frame = CGRectMake(0, 0, width, size.height);
        self.gradient.frame = self.headerView.bounds;
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
    BOOL isCurrent = [[YTMUOfflinePlayer shared].currentTrack.url isEqual:track.url];
    // Albums show track numbers, playlists the song artwork (like YTM)
    [cell configureWithTrack:track showNumber:self.collection.isAlbum isCurrent:isCurrent];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    YTMUOfflinePlayer *player = [YTMUOfflinePlayer shared];
    [player playTracks:self.tracks startIndex:indexPath.row shuffle:player.isShuffled];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    YTMUOfflineTrack *track = self.tracks[(NSUInteger)indexPath.row];

    UIContextualAction *share = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:nil handler:^(UIContextualAction *action, UIView *sourceView, void (^completion)(BOOL)) {
        YTMUShare(@[track.url], self, sourceView);
        completion(YES);
    }];
    share.image = [UIImage systemImageNamed:@"square.and.arrow.up"];
    share.backgroundColor = [UIColor systemBlueColor];

    UIContextualAction *delete = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:nil handler:^(UIContextualAction *action, UIView *sourceView, void (^completion)(BOOL)) {
        [self confirmDeleteTrack:track completion:completion];
    }];
    delete.image = [UIImage systemImageNamed:@"trash"];

    return [UISwipeActionsConfiguration configurationWithActions:@[delete, share]];
}

- (void)confirmDeleteTrack:(YTMUOfflineTrack *)track completion:(void (^)(BOOL))completion {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:track.title
                                                                   message:@"Delete this downloaded song?"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Delete" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
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
