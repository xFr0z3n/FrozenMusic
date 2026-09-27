#import "YTMULyricsViewController.h"
#import "YTMUOfflineUI.h"
#import "YTMUActionSheet.h"
#import <QuartzCore/QuartzCore.h>
#import <CoreImage/CoreImage.h>

static const CGFloat YTMULyricsSideInset = 43;
static const CGFloat YTMULyricsDimAlpha = 0.3;

// YTM's lyrics background: the cover itself, heavily blurred (dimmed by an overlay).
// Made in the background as soon as a song shows in the player (YTMUPrepareLyricsBackdrop),
// kept per cover, so opening the lyrics finds it ready.
static NSCache<UIImage *, UIImage *> *YTMULyricsBackdropCache(void) {
    static NSCache *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cache = [NSCache new];
        cache.countLimit = 10;
    });
    return cache;
}

static UIImage *YTMULyricsBackdrop(UIImage *cover) {
    if (!cover.CGImage)
        return nil;
    UIImage *cached = [YTMULyricsBackdropCache() objectForKey:cover];
    if (cached)
        return cached;
    const CGFloat side = 160;
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.scale = 1;
    format.opaque = YES;
    UIImage *small = [[[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(side, side) format:format] imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [cover drawInRect:CGRectMake(0, 0, side, side)];
    }];
    CIImage *input = [[CIImage imageWithCGImage:small.CGImage] imageByClampingToExtent];
    CIFilter *blur = [CIFilter filterWithName:@"CIGaussianBlur"];
    [blur setValue:input forKey:kCIInputImageKey];
    [blur setValue:@18 forKey:kCIInputRadiusKey];
    CIImage *output = [blur.outputImage imageByCroppingToRect:CGRectMake(0, 0, side, side)];
    if (!output)
        return nil;
    static CIContext *context;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        context = [CIContext contextWithOptions:nil];
    });
    CGImageRef image = [context createCGImage:output fromRect:output.extent];
    if (!image)
        return nil;
    UIImage *result = [UIImage imageWithCGImage:image];
    CGImageRelease(image);
    [YTMULyricsBackdropCache() setObject:result forKey:cover];
    return result;
}

void YTMUPrepareLyricsBackdrop(UIImage *cover) {
    if (!cover.CGImage || [YTMULyricsBackdropCache() objectForKey:cover])
        return;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        YTMULyricsBackdrop(cover);
    });
}

#pragma mark - Display link target (holds the screen weakly)

@interface YTMULyricsTicker : NSObject
@property (nonatomic, copy) void (^block)(void);
+ (instancetype)tickerWithBlock:(void (^)(void))block;
- (void)fire;
@end

@implementation YTMULyricsTicker

+ (instancetype)tickerWithBlock:(void (^)(void))block {
    YTMULyricsTicker *ticker = [YTMULyricsTicker new];
    ticker.block = block;
    return ticker;
}

- (void)fire {
    if (self.block)
        self.block();
}

@end

#pragma mark - Line cell

@interface YTMULyricCell : UITableViewCell
@property (nonatomic, strong) UILabel *lineLabel;
@property (nonatomic, strong) UILabel *translationLabel;
- (void)setBright:(BOOL)bright;
@end

@implementation YTMULyricCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (!self)
        return nil;
    self.backgroundColor = [UIColor clearColor];
    self.selectionStyle = UITableViewCellSelectionStyleNone;

    self.lineLabel = [UILabel new];
    self.lineLabel.font = [UIFont systemFontOfSize:24 weight:UIFontWeightBold];
    self.lineLabel.numberOfLines = 0;
    self.translationLabel = [UILabel new];
    self.translationLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    self.translationLabel.numberOfLines = 0;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[self.lineLabel, self.translationLabel]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 4;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:6],
        [stack.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-6],
        [stack.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:YTMULyricsSideInset],
        [stack.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-YTMULyricsSideInset]
    ]];
    return self;
}

- (void)setBright:(BOOL)bright {
    UIColor *color = [UIColor colorWithWhite:1.0 alpha:bright ? 1.0 : YTMULyricsDimAlpha];
    self.lineLabel.textColor = color;
    self.translationLabel.textColor = [UIColor colorWithWhite:1.0 alpha:bright ? 0.7 : YTMULyricsDimAlpha * 0.8];
}

@end

#pragma mark - Pill button (Share / Translate)

// Translucent (blurred, lightly white) pill like YTM's; white with black content when active
static const NSInteger YTMULyricsPillBlurTag = 7301;

static UIButton *YTMULyricsPill(NSString *title, NSString *symbol) {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.layer.cornerRadius = 23;
    button.clipsToBounds = YES;
    button.backgroundColor = [UIColor clearColor];

    UIVisualEffectView *blur = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark]];
    blur.contentView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.1];
    blur.userInteractionEnabled = NO;
    blur.tag = YTMULyricsPillBlurTag;
    // Always behind the icon + title: UIButton adds its image view later, below other subviews
    blur.layer.zPosition = -1;
    blur.frame = button.bounds;
    blur.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [button insertSubview:blur atIndex:0];

    button.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    [button setTitle:title forState:UIControlStateNormal];
    button.imageEdgeInsets = UIEdgeInsetsMake(0, -5, 0, 5);
    button.titleEdgeInsets = UIEdgeInsetsMake(0, 5, 0, -5);
    button.contentEdgeInsets = UIEdgeInsetsMake(0, 25, 0, 25);
    button.accessibilityIdentifier = symbol;
    [button.heightAnchor constraintEqualToConstant:46].active = YES;
    return button;
}

static void YTMUStyleLyricsPill(UIButton *button, BOOL active) {
    UIColor *content = active ? [UIColor blackColor] : [UIColor whiteColor];
    [button viewWithTag:YTMULyricsPillBlurTag].hidden = active;
    button.backgroundColor = active ? [UIColor whiteColor] : [UIColor clearColor];
    [button setTitleColor:content forState:UIControlStateNormal];
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:19 weight:UIImageSymbolWeightRegular];
    UIImage *icon = [UIImage systemImageNamed:button.accessibilityIdentifier withConfiguration:config];
    [button setImage:[icon imageWithTintColor:content renderingMode:UIImageRenderingModeAlwaysOriginal] forState:UIControlStateNormal];
    [button setImage:[icon imageWithTintColor:content renderingMode:UIImageRenderingModeAlwaysOriginal] forState:UIControlStateHighlighted];
    [button layoutIfNeeded];
    button.imageView.layer.zPosition = 1;
    button.titleLabel.layer.zPosition = 1;
}

#pragma mark - Screen

@interface YTMULyricsViewController () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) YTMUOfflineTrack *track;
@property (nonatomic, strong) YTMULyrics *lyrics;
@property (nonatomic, copy) NSArray<NSString *> *translation;
@property (nonatomic) BOOL showsTranslation;
@property (nonatomic) BOOL translating;
@property (nonatomic, copy) NSString *translationCredit;  // "Translated on device" / "Translated by Google"
@property (nonatomic) BOOL selecting;                 // Share: picking lines
@property (nonatomic, strong) NSMutableIndexSet *selectedLines;
@property (nonatomic) NSInteger currentLine;
@property (nonatomic, strong) NSDate *autoScrollPausedUntil;
@property (nonatomic, strong) CADisplayLink *displayLink;
@property (nonatomic) BOOL didInitialScroll;
@property (nonatomic) BOOL foreignLyrics;             // not in the phone's language: Translate shown

@property (nonatomic, strong) UIImageView *artworkView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *artistLabel;
@property (nonatomic, strong) UIButton *playButton;
@property (nonatomic, strong) UIButton *nextButton;
@property (nonatomic, strong) UILabel *headerLabel;
@property (nonatomic, strong) UIView *panel;
@property (nonatomic, strong) UIImageView *backdropView;
@property (nonatomic, weak) UIImage *backdropCover;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UILabel *footerLabel;
@property (nonatomic, strong) UILabel *messageLabel;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) UIStackView *pills;
@property (nonatomic, strong) UIButton *shareButton;
@property (nonatomic, strong) UIButton *translateButton;
@end

@implementation YTMULyricsViewController

- (instancetype)initWithTrack:(YTMUOfflineTrack *)track lyrics:(YTMULyrics *)lyrics {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _track = track;
        _lyrics = lyrics;
        _currentLine = -1;
        _selectedLines = [NSMutableIndexSet indexSet];
        self.modalPresentationStyle = UIModalPresentationFullScreen;
    }
    return self;
}

- (UIStatusBarStyle)preferredStatusBarStyle {
    return UIStatusBarStyleLightContent;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = YTMUBackgroundColor();
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;

    // Mini player row: tap = back to the player
    UIView *miniRow = [UIView new];
    miniRow.translatesAutoresizingMaskIntoConstraints = NO;
    [miniRow addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(close)]];
    self.artworkView = [UIImageView new];
    self.artworkView.contentMode = UIViewContentModeScaleAspectFill;
    self.artworkView.clipsToBounds = YES;
    self.artworkView.layer.cornerRadius = 4;
    self.artworkView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.08];
    self.artworkView.translatesAutoresizingMaskIntoConstraints = NO;
    self.titleLabel = [UILabel new];
    self.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    self.titleLabel.textColor = [UIColor whiteColor];
    self.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.artistLabel = [UILabel new];
    self.artistLabel.font = [UIFont systemFontOfSize:14];
    self.artistLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.62];
    self.artistLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.playButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.playButton.tintColor = [UIColor whiteColor];
    self.playButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.playButton addTarget:self action:@selector(playTapped) forControlEvents:UIControlEventTouchUpInside];
    // Skip, left of play / pause
    self.nextButton = [UIButton buttonWithType:UIButtonTypeSystem];
    UIImageSymbolConfiguration *nextConfig = [UIImageSymbolConfiguration configurationWithPointSize:20 weight:UIImageSymbolWeightSemibold];
    [self.nextButton setImage:[UIImage systemImageNamed:@"forward.end.fill" withConfiguration:nextConfig] forState:UIControlStateNormal];
    self.nextButton.tintColor = [UIColor whiteColor];
    self.nextButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.nextButton addTarget:self action:@selector(nextTapped) forControlEvents:UIControlEventTouchUpInside];
    for (UIView *view in @[self.artworkView, self.titleLabel, self.artistLabel, self.playButton, self.nextButton])
        [miniRow addSubview:view];

    UIView *grabber = [UIView new];
    grabber.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.3];
    grabber.layer.cornerRadius = 2.5;
    grabber.translatesAutoresizingMaskIntoConstraints = NO;

    // "Lyrics" + ✕ (swipe down here closes too)
    UIView *header = [UIView new];
    header.translatesAutoresizingMaskIntoConstraints = NO;
    UISwipeGestureRecognizer *swipeDown = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(close)];
    swipeDown.direction = UISwipeGestureRecognizerDirectionDown;
    [header addGestureRecognizer:swipeDown];
    UISwipeGestureRecognizer *rowSwipe = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(close)];
    rowSwipe.direction = UISwipeGestureRecognizerDirectionDown;
    [miniRow addGestureRecognizer:rowSwipe];
    self.headerLabel = [UILabel new];
    self.headerLabel.text = @"Lyrics";
    self.headerLabel.font = [UIFont systemFontOfSize:22 weight:UIFontWeightBold];
    self.headerLabel.textColor = [UIColor whiteColor];
    self.headerLabel.translatesAutoresizingMaskIntoConstraints = NO;
    UIButton *closeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    UIImageSymbolConfiguration *closeConfig = [UIImageSymbolConfiguration configurationWithPointSize:20 weight:UIImageSymbolWeightRegular];
    [closeButton setImage:[UIImage systemImageNamed:@"xmark" withConfiguration:closeConfig] forState:UIControlStateNormal];
    closeButton.tintColor = [UIColor whiteColor];
    closeButton.translatesAutoresizingMaskIntoConstraints = NO;
    [closeButton addTarget:self action:@selector(closeTapped) forControlEvents:UIControlEventTouchUpInside];
    [header addSubview:self.headerLabel];
    [header addSubview:closeButton];

    // Lyrics on the blurred cover, like YTM
    self.panel = [UIView new];
    self.panel.clipsToBounds = YES;
    self.panel.backgroundColor = [UIColor colorWithWhite:0.08 alpha:1];
    self.panel.translatesAutoresizingMaskIntoConstraints = NO;
    self.backdropView = [UIImageView new];
    self.backdropView.contentMode = UIViewContentModeScaleAspectFill;
    self.backdropView.translatesAutoresizingMaskIntoConstraints = NO;
    UIView *dim = [UIView new];
    dim.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
    dim.translatesAutoresizingMaskIntoConstraints = NO;
    [self.panel addSubview:self.backdropView];
    [self.panel addSubview:dim];
    [NSLayoutConstraint activateConstraints:@[
        [self.backdropView.topAnchor constraintEqualToAnchor:self.panel.topAnchor],
        [self.backdropView.bottomAnchor constraintEqualToAnchor:self.panel.bottomAnchor],
        [self.backdropView.leadingAnchor constraintEqualToAnchor:self.panel.leadingAnchor],
        [self.backdropView.trailingAnchor constraintEqualToAnchor:self.panel.trailingAnchor],
        [dim.topAnchor constraintEqualToAnchor:self.panel.topAnchor],
        [dim.bottomAnchor constraintEqualToAnchor:self.panel.bottomAnchor],
        [dim.leadingAnchor constraintEqualToAnchor:self.panel.leadingAnchor],
        [dim.trailingAnchor constraintEqualToAnchor:self.panel.trailingAnchor]
    ]];

    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.tableView.backgroundColor = [UIColor clearColor];
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 44;
    self.tableView.indicatorStyle = UIScrollViewIndicatorStyleWhite;
    self.tableView.contentInset = UIEdgeInsetsMake(50, 0, 120, 0);
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.tableView registerClass:[YTMULyricCell class] forCellReuseIdentifier:@"line"];
    [self.panel addSubview:self.tableView];

    self.messageLabel = [UILabel new];
    self.messageLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    self.messageLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.62];
    self.messageLabel.textAlignment = NSTextAlignmentCenter;
    self.messageLabel.hidden = YES;
    self.messageLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.spinner.color = [UIColor whiteColor];
    self.spinner.hidesWhenStopped = YES;
    self.spinner.translatesAutoresizingMaskIntoConstraints = NO;
    [self.panel addSubview:self.messageLabel];
    [self.panel addSubview:self.spinner];

    // Share / Translate, floating at the bottom (Share: pick lines, then Share again)
    self.shareButton = YTMULyricsPill(@"Share", @"arrowshape.turn.up.right");
    [self.shareButton addTarget:self action:@selector(shareTapped) forControlEvents:UIControlEventTouchUpInside];
    self.translateButton = YTMULyricsPill(@"Translate", @"translate");
    [self.translateButton addTarget:self action:@selector(toggleTranslation) forControlEvents:UIControlEventTouchUpInside];
    self.pills = [[UIStackView alloc] initWithArrangedSubviews:@[self.shareButton, self.translateButton]];
    self.pills.axis = UILayoutConstraintAxisHorizontal;
    self.pills.spacing = 18;
    self.pills.translatesAutoresizingMaskIntoConstraints = NO;
    [self.panel addSubview:self.pills];

    for (UIView *view in @[miniRow, grabber, header, self.panel])
        [self.view addSubview:view];

    [NSLayoutConstraint activateConstraints:@[
        [miniRow.topAnchor constraintEqualToAnchor:safe.topAnchor constant:4],
        [miniRow.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [miniRow.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [miniRow.heightAnchor constraintEqualToConstant:56],
        [self.artworkView.leadingAnchor constraintEqualToAnchor:miniRow.leadingAnchor constant:16],
        [self.artworkView.centerYAnchor constraintEqualToAnchor:miniRow.centerYAnchor],
        [self.artworkView.widthAnchor constraintEqualToConstant:48],
        [self.artworkView.heightAnchor constraintEqualToConstant:48],
        [self.playButton.trailingAnchor constraintEqualToAnchor:miniRow.trailingAnchor constant:-10],
        [self.playButton.centerYAnchor constraintEqualToAnchor:miniRow.centerYAnchor],
        [self.playButton.widthAnchor constraintEqualToConstant:44],
        [self.playButton.heightAnchor constraintEqualToConstant:44],
        [self.nextButton.trailingAnchor constraintEqualToAnchor:self.playButton.leadingAnchor constant:-4],
        [self.nextButton.centerYAnchor constraintEqualToAnchor:miniRow.centerYAnchor],
        [self.nextButton.widthAnchor constraintEqualToConstant:44],
        [self.nextButton.heightAnchor constraintEqualToConstant:44],
        [self.titleLabel.leadingAnchor constraintEqualToAnchor:self.artworkView.trailingAnchor constant:16],
        [self.titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.nextButton.leadingAnchor constant:-12],
        [self.titleLabel.bottomAnchor constraintEqualToAnchor:miniRow.centerYAnchor constant:-1],
        [self.artistLabel.leadingAnchor constraintEqualToAnchor:self.titleLabel.leadingAnchor],
        [self.artistLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.nextButton.leadingAnchor constant:-12],
        [self.artistLabel.topAnchor constraintEqualToAnchor:miniRow.centerYAnchor constant:2],

        [grabber.topAnchor constraintEqualToAnchor:miniRow.bottomAnchor constant:10],
        [grabber.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [grabber.widthAnchor constraintEqualToConstant:36],
        [grabber.heightAnchor constraintEqualToConstant:5],

        [header.topAnchor constraintEqualToAnchor:grabber.bottomAnchor constant:8],
        [header.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [header.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [header.heightAnchor constraintEqualToConstant:54],
        [self.headerLabel.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:16],
        [self.headerLabel.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
        [closeButton.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-8],
        [closeButton.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
        [closeButton.widthAnchor constraintEqualToConstant:44],
        [closeButton.heightAnchor constraintEqualToConstant:44],

        [self.panel.topAnchor constraintEqualToAnchor:header.bottomAnchor],
        [self.panel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.panel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.panel.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.tableView.topAnchor constraintEqualToAnchor:self.panel.topAnchor],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.panel.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.panel.trailingAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.panel.bottomAnchor],
        [self.messageLabel.centerXAnchor constraintEqualToAnchor:self.panel.centerXAnchor],
        [self.messageLabel.centerYAnchor constraintEqualToAnchor:self.panel.centerYAnchor constant:-40],
        [self.spinner.centerXAnchor constraintEqualToAnchor:self.panel.centerXAnchor],
        [self.spinner.centerYAnchor constraintEqualToAnchor:self.panel.centerYAnchor constant:-40],
        [self.pills.centerXAnchor constraintEqualToAnchor:self.panel.centerXAnchor],
        [self.pills.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-12]
    ]];

    self.footerLabel = [UILabel new];
    self.footerLabel.font = [UIFont systemFontOfSize:15];
    self.footerLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.62];
    self.footerLabel.numberOfLines = 0;

    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserver:self selector:@selector(playerChanged) name:YTMUOfflinePlayerDidChangeNotification object:nil];
    [self showTrack];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_displayLink invalidate];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (!self.displayLink) {
        // Weak proxy: the display link must not keep the screen alive
        __weak __typeof(self) weakSelf = self;
        self.displayLink = [CADisplayLink displayLinkWithTarget:[YTMULyricsTicker tickerWithBlock:^{
            [weakSelf tick];
        }] selector:@selector(fire)];
        self.displayLink.preferredFramesPerSecond = 12;
        [self.displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    }
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self.displayLink invalidate];
    self.displayLink = nil;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self sizeFooter];
    if (!self.didInitialScroll && self.lyrics.synced && self.tableView.bounds.size.height > 0) {
        self.didInitialScroll = YES;
        [self tick];
        [self scrollToCurrentAnimated:NO];
    }
}

- (void)close {
    [self dismissViewControllerAnimated:YTMUAnimations() completion:nil];
}

// ✕ while picking lines to share: back to the lyrics, else close
- (void)closeTapped {
    if (self.selecting)
        [self stopSelecting];
    else
        [self close];
}

#pragma mark Song

- (void)showTrack {
    YTMUOfflineTrack *track = self.track;
    self.artworkView.image = track.artwork;
    self.titleLabel.text = track.title;
    self.artistLabel.text = track.artist;
    [self refreshPlayButton];

    // Blurred cover: ready from the player (cached), else the cover's color right away and
    // the blur fades in a moment later (never a black background)
    [track loadArtworkIfNeeded];
    UIImage *cover = track.artwork;
    if (cover != self.backdropCover || !self.backdropView.image) {
        self.backdropCover = cover;
        self.panel.backgroundColor = cover ? YTMUHueColor(cover) : [UIColor colorWithWhite:0.08 alpha:1];
        UIImage *ready = cover ? [YTMULyricsBackdropCache() objectForKey:cover] : nil;
        self.backdropView.image = ready;
        self.backdropView.alpha = 1;
        if (cover && !ready) {
            self.backdropView.alpha = 0;
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                UIImage *backdrop = YTMULyricsBackdrop(cover);
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (self.backdropCover != cover)
                        return;
                    self.backdropView.image = backdrop;
                    [UIView animateWithDuration:YTMUDuration(0.25) animations:^{
                        self.backdropView.alpha = 1;
                    }];
                });
            });
        }
    }

    self.translation = nil;
    self.showsTranslation = NO;
    self.translating = NO;
    self.selecting = NO;
    self.headerLabel.text = @"Lyrics";
    [self.selectedLines removeAllIndexes];
    self.currentLine = -1;
    self.autoScrollPausedUntil = nil;
    self.didInitialScroll = NO;
    [self showLyrics:self.lyrics];
}

- (void)showLyrics:(YTMULyrics *)lyrics {
    self.lyrics = lyrics;
    NSString *language = [lyrics languageCode];
    NSString *device = [YTMULyrics deviceLanguageCode];
    self.foreignLyrics = language.length >= 2 && device.length >= 2 &&
                         ![[language substringToIndex:2] isEqualToString:[device substringToIndex:2]];
    [self.spinner stopAnimating];
    self.messageLabel.hidden = lyrics != nil;
    self.messageLabel.text = @"No lyrics available";
    self.tableView.hidden = lyrics == nil;
    [self refreshPills];
    [self refreshFooter];
    [self.tableView reloadData];
    [self.tableView setContentOffset:CGPointMake(0, -self.tableView.adjustedContentInset.top) animated:NO];
    [self.view setNeedsLayout];
}

- (void)playerChanged {
    YTMUOfflineTrack *current = [YTMUOfflinePlayer shared].currentTrack;
    if (!current) {
        [self close];
        return;
    }
    [self refreshPlayButton];
    if ([current.url isEqual:self.track.url])
        return;

    // Next song: its lyrics (saved, else fetched)
    self.track = current;
    self.lyrics = nil;
    [self showTrack];
    self.messageLabel.hidden = YES;
    self.tableView.hidden = YES;
    [self.spinner startAnimating];
    [YTMULyrics loadForTrack:current completion:^(YTMULyrics *lyrics, BOOL offline) {
        if (![[YTMUOfflinePlayer shared].currentTrack.url isEqual:current.url] || self.track != current)
            return;
        [self showLyrics:lyrics];
        if (!lyrics && offline)
            self.messageLabel.text = @"No lyrics available offline";
    }];
}

- (void)refreshPlayButton {
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:22 weight:UIImageSymbolWeightSemibold];
    NSString *symbol = [YTMUOfflinePlayer shared].isPlaying ? @"pause.fill" : @"play.fill";
    [self.playButton setImage:[UIImage systemImageNamed:symbol withConfiguration:config] forState:UIControlStateNormal];
}

- (void)playTapped {
    [[YTMUOfflinePlayer shared] togglePlayPause];
}

- (void)nextTapped {
    [[YTMUOfflinePlayer shared] next];
}

#pragma mark Sync

// Line playing right now (last one that started), -1 before the first
- (NSInteger)lineForTime:(NSTimeInterval)time {
    NSInteger found = -1;
    NSArray<YTMULyricLine *> *lines = self.lyrics.lines;
    for (NSInteger i = 0; i < (NSInteger)lines.count; i++) {
        if (lines[(NSUInteger)i].time <= time + 0.15)
            found = i;
        else
            break;
    }
    return found;
}

- (void)tick {
    if (!self.lyrics.synced || self.tableView.hidden)
        return;
    NSInteger line = [self lineForTime:[YTMUOfflinePlayer shared].currentTime];
    if (line == self.currentLine)
        return;
    NSInteger previous = self.currentLine;
    self.currentLine = line;
    if (self.selecting)
        return;
    for (NSNumber *row in @[@(previous), @(line)]) {
        if (row.integerValue < 0)
            continue;
        YTMULyricCell *cell = [self.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:row.integerValue inSection:0]];
        if (cell) {
            [UIView transitionWithView:cell.contentView duration:YTMUDuration(0.2) options:UIViewAnimationOptionTransitionCrossDissolve animations:^{
                [cell setBright:row.integerValue == line];
            } completion:nil];
        }
    }
    [self scrollToCurrentAnimated:YTMUAnimations()];
}

// Current line a bit below the top (the one before stays visible), like YTM
- (void)scrollToCurrentAnimated:(BOOL)animated {
    if (self.selecting || self.currentLine < 0 || self.currentLine >= [self.tableView numberOfRowsInSection:0])
        return;
    if (self.autoScrollPausedUntil && [self.autoScrollPausedUntil timeIntervalSinceNow] > 0)
        return;
    CGRect row = [self.tableView rectForRowAtIndexPath:[NSIndexPath indexPathForRow:self.currentLine inSection:0]];
    UIEdgeInsets inset = self.tableView.adjustedContentInset;
    CGFloat maxOffset = MAX(-inset.top, self.tableView.contentSize.height + inset.bottom - self.tableView.bounds.size.height);
    CGFloat offset = MIN(MAX(row.origin.y - 90, -inset.top), maxOffset);
    [self.tableView setContentOffset:CGPointMake(0, offset) animated:animated];
}

- (void)scrollViewWillBeginDragging:(UIScrollView *)scrollView {
    self.autoScrollPausedUntil = [NSDate distantFuture];
}

- (void)scrollViewDidEndDragging:(UIScrollView *)scrollView willDecelerate:(BOOL)decelerate {
    if (!decelerate)
        self.autoScrollPausedUntil = [NSDate dateWithTimeIntervalSinceNow:3];
}

- (void)scrollViewDidEndDecelerating:(UIScrollView *)scrollView {
    self.autoScrollPausedUntil = [NSDate dateWithTimeIntervalSinceNow:3];
}

#pragma mark Table

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)self.lyrics.lines.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    YTMULyricCell *cell = [tableView dequeueReusableCellWithIdentifier:@"line" forIndexPath:indexPath];
    YTMULyricLine *line = self.lyrics.lines[(NSUInteger)indexPath.row];
    // Blank lines of plain lyrics: a gap between verses
    cell.lineLabel.text = line.text.length ? line.text : @" ";
    NSString *translated = self.showsTranslation && (NSUInteger)indexPath.row < self.translation.count ? self.translation[(NSUInteger)indexPath.row] : nil;
    cell.translationLabel.text = translated;
    cell.translationLabel.hidden = translated.length == 0;

    BOOL bright;
    if (self.selecting)
        bright = [self.selectedLines containsIndex:(NSUInteger)indexPath.row];
    else if (self.lyrics.synced)
        bright = indexPath.row == self.currentLine;
    else
        bright = YES;
    [cell setBright:bright];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    YTMULyricLine *line = self.lyrics.lines[(NSUInteger)indexPath.row];
    if (self.selecting) {
        if (!line.text.length || [line.text isEqualToString:@"♪"])
            return;
        NSUInteger row = (NSUInteger)indexPath.row;
        if ([self.selectedLines containsIndex:row])
            [self.selectedLines removeIndex:row];
        else
            [self.selectedLines addIndex:row];
        [tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
        [self refreshPills];
        return;
    }
    // Tap a line: play from there
    if (!self.lyrics.synced || line.time < 0)
        return;
    YTMUOfflinePlayer *player = [YTMUOfflinePlayer shared];
    [player seekTo:line.time];
    if (!player.isPlaying)
        [player play];
    self.autoScrollPausedUntil = nil;
    [self tick];
    [self scrollToCurrentAnimated:YTMUAnimations()];
}

- (void)refreshFooter {
    NSMutableArray *parts = [NSMutableArray array];
    if (self.lyrics.source.length)
        [parts addObject:self.lyrics.source];
    if (self.showsTranslation && self.translationCredit.length)
        [parts addObject:self.translationCredit];
    self.footerLabel.text = [parts componentsJoinedByString:@"\n"];
    self.tableView.tableFooterView = parts.count ? [self footerContainer] : nil;
    [self sizeFooter];
}

- (UIView *)footerContainer {
    UIView *container = self.footerLabel.superview;
    if (!container) {
        container = [UIView new];
        [container addSubview:self.footerLabel];
    }
    return container;
}

- (void)sizeFooter {
    UIView *footer = self.tableView.tableFooterView;
    if (!footer || self.tableView.bounds.size.width <= 0)
        return;
    CGFloat width = self.tableView.bounds.size.width - YTMULyricsSideInset * 2;
    CGSize size = [self.footerLabel sizeThatFits:CGSizeMake(width, CGFLOAT_MAX)];
    CGRect labelFrame = CGRectMake(YTMULyricsSideInset, 24, width, ceil(size.height));
    if (CGRectEqualToRect(self.footerLabel.frame, labelFrame) && footer.frame.size.width == self.tableView.bounds.size.width)
        return;
    self.footerLabel.frame = labelFrame;
    footer.frame = CGRectMake(0, 0, self.tableView.bounds.size.width, CGRectGetMaxY(labelFrame) + 12);
    self.tableView.tableFooterView = footer;
}

#pragma mark Share

- (void)refreshPills {
    BOOL hasLyrics = self.lyrics.lines.count > 0;
    // Share stays while picking lines (white = active); Translate only for lyrics
    // that aren't in the phone's language
    self.shareButton.hidden = !hasLyrics;
    self.translateButton.hidden = !hasLyrics || self.selecting || !self.foreignLyrics;
    YTMUStyleLyricsPill(self.shareButton, self.selecting);
    YTMUStyleLyricsPill(self.translateButton, self.showsTranslation);
    [self.translateButton setTitle:self.translating ? @"Translating…" : @"Translate" forState:UIControlStateNormal];
}

- (void)shareTapped {
    if (!self.selecting)
        [self startSelecting];
    else if (self.selectedLines.count)
        [self shareSelection];
    else
        [self stopSelecting];
}

- (void)startSelecting {
    self.selecting = YES;
    [self.selectedLines removeAllIndexes];
    // Start with the line that's playing
    YTMULyricLine *current = self.currentLine >= 0 && self.currentLine < (NSInteger)self.lyrics.lines.count ? self.lyrics.lines[(NSUInteger)self.currentLine] : nil;
    if (current.text.length && ![current.text isEqualToString:@"♪"])
        [self.selectedLines addIndex:(NSUInteger)self.currentLine];
    self.headerLabel.text = @"Select lyrics";
    [self refreshPills];
    [self.tableView reloadData];
}

- (void)stopSelecting {
    self.selecting = NO;
    [self.selectedLines removeAllIndexes];
    self.headerLabel.text = @"Lyrics";
    [self refreshPills];
    [self.tableView reloadData];
    self.autoScrollPausedUntil = nil;
    [self scrollToCurrentAnimated:YTMUAnimations()];
}

- (void)shareSelection {
    if (!self.selectedLines.count)
        return;
    NSMutableArray *texts = [NSMutableArray array];
    [self.selectedLines enumerateIndexesUsingBlock:^(NSUInteger index, BOOL *stop) {
        if (index < self.lyrics.lines.count)
            [texts addObject:self.lyrics.lines[index].text];
    }];
    NSString *credit = self.track.artist.length ? [NSString stringWithFormat:@"%@ · %@", self.track.title, self.track.artist] : self.track.title;
    NSString *text = [NSString stringWithFormat:@"%@\n\n%@", [texts componentsJoinedByString:@"\n"], credit ?: @""];

    UIActivityViewController *activity = [[UIActivityViewController alloc] initWithActivityItems:@[text] applicationActivities:nil];
    activity.popoverPresentationController.sourceView = self.shareButton;
    activity.popoverPresentationController.sourceRect = self.shareButton.bounds;
    __weak __typeof(self) weakSelf = self;
    activity.completionWithItemsHandler = ^(UIActivityType type, BOOL completed, NSArray *items, NSError *error) {
        if (completed)
            [weakSelf stopSelecting];
    };
    [self presentViewController:activity animated:YES completion:nil];
}

#pragma mark Translate

- (void)toggleTranslation {
    if (self.translating)
        return;
    if (self.showsTranslation || self.translation) {
        self.showsTranslation = !self.showsTranslation;
        [self translationChanged];
        return;
    }
    self.translating = YES;
    [self refreshPills];
    YTMULyrics *lyrics = self.lyrics;
    [lyrics translationForTrack:self.track presenter:self completion:^(NSArray<NSString *> *translation, NSString *credit, NSString *error) {
        self.translating = NO;
        if (self.lyrics != lyrics) {
            [self refreshPills];
            return;
        }
        if (!translation) {
            [self refreshPills];
            YTMUShowInfoBox(self, error.length ? error : @"Translation isn't available right now");
            return;
        }
        self.translation = translation;
        self.translationCredit = credit;
        self.showsTranslation = YES;
        [self translationChanged];
    }];
}

- (void)translationChanged {
    [self refreshPills];
    [self refreshFooter];
    [self.tableView reloadData];
    [self.tableView layoutIfNeeded];
    self.autoScrollPausedUntil = nil;
    [self scrollToCurrentAnimated:NO];
}

@end
