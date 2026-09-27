#import "YTMULyricsViewController.h"
#import "YTMUOfflineUI.h"
#import "YTMUActionSheet.h"
#import <QuartzCore/QuartzCore.h>

static const CGFloat YTMULyricsSideInset = 40;
static const CGFloat YTMULyricsDimAlpha = 0.35;

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
        [stack.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:7],
        [stack.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-7],
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

static UIButton *YTMULyricsPill(NSString *title, NSString *symbol) {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.layer.cornerRadius = 22;
    button.clipsToBounds = YES;
    button.backgroundColor = [UIColor colorWithWhite:0.2 alpha:0.75];
    button.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    [button setTitle:title forState:UIControlStateNormal];
    [button setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [button setTitleColor:[UIColor colorWithWhite:1.0 alpha:0.4] forState:UIControlStateDisabled];
    if (symbol) {
        UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:18 weight:UIImageSymbolWeightMedium];
        UIImage *image = [UIImage systemImageNamed:symbol withConfiguration:config];
        [button setImage:[image imageWithTintColor:[UIColor whiteColor] renderingMode:UIImageRenderingModeAlwaysOriginal] forState:UIControlStateNormal];
        button.imageEdgeInsets = UIEdgeInsetsMake(0, -6, 0, 6);
        button.titleEdgeInsets = UIEdgeInsetsMake(0, 6, 0, -6);
    }
    button.contentEdgeInsets = UIEdgeInsetsMake(0, symbol ? 26 : 22, 0, symbol ? 26 : 22);
    [button.heightAnchor constraintEqualToConstant:44].active = YES;
    return button;
}

#pragma mark - Screen

@interface YTMULyricsViewController () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) YTMUOfflineTrack *track;
@property (nonatomic, strong) YTMULyrics *lyrics;
@property (nonatomic, copy) NSArray<NSString *> *translation;
@property (nonatomic) BOOL showsTranslation;
@property (nonatomic) BOOL translating;
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
@property (nonatomic, strong) UILabel *headerLabel;
@property (nonatomic, strong) UIView *panel;
@property (nonatomic, strong) CALayer *hueLayer;
@property (nonatomic, strong) CAGradientLayer *glowLayer;
@property (nonatomic, strong) CAGradientLayer *topShadeLayer;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UILabel *footerLabel;
@property (nonatomic, strong) UILabel *messageLabel;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) UIStackView *pills;
@property (nonatomic, strong) UIButton *shareButton;
@property (nonatomic, strong) UIButton *translateButton;
@property (nonatomic, strong) UIButton *cancelButton;
@property (nonatomic, strong) UIButton *confirmShareButton;
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
    for (UIView *view in @[self.artworkView, self.titleLabel, self.artistLabel, self.playButton])
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
    [closeButton addTarget:self action:@selector(close) forControlEvents:UIControlEventTouchUpInside];
    [header addSubview:self.headerLabel];
    [header addSubview:closeButton];

    // Lyrics on the cover's hue
    self.panel = [UIView new];
    self.panel.clipsToBounds = YES;
    self.panel.translatesAutoresizingMaskIntoConstraints = NO;
    self.hueLayer = [CALayer layer];
    self.glowLayer = [CAGradientLayer layer];
    self.glowLayer.type = kCAGradientLayerRadial;
    self.glowLayer.startPoint = CGPointMake(0.5, 0.0);
    self.glowLayer.endPoint = CGPointMake(1.25, 0.55);
    self.topShadeLayer = [CAGradientLayer layer];
    self.topShadeLayer.colors = @[(__bridge id)[UIColor colorWithWhite:0 alpha:0.35].CGColor, (__bridge id)[UIColor colorWithWhite:0 alpha:0].CGColor];
    [self.panel.layer addSublayer:self.hueLayer];
    [self.panel.layer addSublayer:self.glowLayer];
    [self.panel.layer addSublayer:self.topShadeLayer];

    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.tableView.backgroundColor = [UIColor clearColor];
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 44;
    self.tableView.indicatorStyle = UIScrollViewIndicatorStyleWhite;
    self.tableView.contentInset = UIEdgeInsetsMake(24, 0, 110, 0);
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

    // Share / Translate, floating at the bottom
    self.shareButton = YTMULyricsPill(@"Share", @"arrowshape.turn.up.right");
    [self.shareButton addTarget:self action:@selector(startSelecting) forControlEvents:UIControlEventTouchUpInside];
    self.translateButton = YTMULyricsPill(@"Translate", @"character.bubble");
    [self.translateButton addTarget:self action:@selector(toggleTranslation) forControlEvents:UIControlEventTouchUpInside];
    self.cancelButton = YTMULyricsPill(@"Cancel", nil);
    [self.cancelButton addTarget:self action:@selector(stopSelecting) forControlEvents:UIControlEventTouchUpInside];
    self.confirmShareButton = YTMULyricsPill(@"Share", @"arrowshape.turn.up.right");
    [self.confirmShareButton addTarget:self action:@selector(shareSelection) forControlEvents:UIControlEventTouchUpInside];
    self.pills = [[UIStackView alloc] initWithArrangedSubviews:@[self.shareButton, self.translateButton, self.cancelButton, self.confirmShareButton]];
    self.pills.axis = UILayoutConstraintAxisHorizontal;
    self.pills.spacing = 12;
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
        [self.playButton.trailingAnchor constraintEqualToAnchor:miniRow.trailingAnchor constant:-12],
        [self.playButton.centerYAnchor constraintEqualToAnchor:miniRow.centerYAnchor],
        [self.playButton.widthAnchor constraintEqualToConstant:44],
        [self.playButton.heightAnchor constraintEqualToConstant:44],
        [self.titleLabel.leadingAnchor constraintEqualToAnchor:self.artworkView.trailingAnchor constant:16],
        [self.titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.playButton.leadingAnchor constant:-12],
        [self.titleLabel.bottomAnchor constraintEqualToAnchor:miniRow.centerYAnchor constant:-1],
        [self.artistLabel.leadingAnchor constraintEqualToAnchor:self.titleLabel.leadingAnchor],
        [self.artistLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.playButton.leadingAnchor constant:-12],
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
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.hueLayer.frame = self.panel.bounds;
    self.glowLayer.frame = self.panel.bounds;
    self.topShadeLayer.frame = CGRectMake(0, 0, self.panel.bounds.size.width, 28);
    [CATransaction commit];
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

#pragma mark Song

- (void)showTrack {
    YTMUOfflineTrack *track = self.track;
    self.artworkView.image = track.artwork;
    self.titleLabel.text = track.title;
    self.artistLabel.text = track.artist;
    [self refreshPlayButton];

    // Hue: dark version of the cover's color with a lighter glow on top, like YTM
    UIColor *hue = YTMUHueColor(track.artwork);
    CGFloat h = 0, sat = 0, bright = 0, alpha = 0;
    [hue getHue:&h saturation:&sat brightness:&bright alpha:&alpha];
    self.hueLayer.backgroundColor = [UIColor colorWithHue:h saturation:sat brightness:0.2 alpha:1].CGColor;
    self.glowLayer.colors = @[(__bridge id)[UIColor colorWithHue:h saturation:sat * 0.9 brightness:0.36 alpha:0.9].CGColor,
                              (__bridge id)[UIColor colorWithHue:h saturation:sat brightness:0.2 alpha:0].CGColor];

    self.translation = nil;
    self.showsTranslation = NO;
    self.selecting = NO;
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
    if (self.showsTranslation)
        [parts addObject:@"Translated by Google"];
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
    // Translate only when the lyrics aren't in the phone's language
    BOOL foreign = self.foreignLyrics;

    self.shareButton.hidden = !hasLyrics || self.selecting;
    self.translateButton.hidden = !hasLyrics || self.selecting || !foreign;
    self.cancelButton.hidden = !self.selecting;
    self.confirmShareButton.hidden = !self.selecting;
    self.confirmShareButton.enabled = self.selectedLines.count > 0;
    self.confirmShareButton.alpha = self.selectedLines.count > 0 ? 1 : 0.6;

    // Translate on: white pill like YTM's active chips
    BOOL active = self.showsTranslation;
    self.translateButton.backgroundColor = active ? [UIColor whiteColor] : [UIColor colorWithWhite:0.2 alpha:0.75];
    [self.translateButton setTitleColor:active ? [UIColor blackColor] : [UIColor whiteColor] forState:UIControlStateNormal];
    [self.translateButton setTitle:self.translating ? @"Translating…" : @"Translate" forState:UIControlStateNormal];
    UIImage *icon = [self.translateButton imageForState:UIControlStateNormal];
    [self.translateButton setImage:[icon imageWithTintColor:active ? [UIColor blackColor] : [UIColor whiteColor] renderingMode:UIImageRenderingModeAlwaysOriginal] forState:UIControlStateNormal];
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
    activity.popoverPresentationController.sourceView = self.confirmShareButton;
    activity.popoverPresentationController.sourceRect = self.confirmShareButton.bounds;
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
    [lyrics translationForTrack:self.track completion:^(NSArray<NSString *> *translation) {
        self.translating = NO;
        if (self.lyrics != lyrics) {
            [self refreshPills];
            return;
        }
        if (!translation) {
            [self refreshPills];
            YTMUShowInfoBox(self, @"Translation isn't available right now");
            return;
        }
        self.translation = translation;
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
