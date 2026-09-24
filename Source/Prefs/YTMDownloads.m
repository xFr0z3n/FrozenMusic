#import "YTMDownloads.h"
#import "../Offline/YTMUOfflineUI.h"
#import "../Offline/YTMUSearchViewController.h"
#import "../Offline/YTMUHistory.h"
#import "../Offline/YTMUActionSheet.h"

// Chips at the top, like YTM's Library
typedef NS_ENUM(NSInteger, YTMUFilter) {
    YTMUFilterNone = 0,
    YTMUFilterPlaylists,
    YTMUFilterSongs,
    YTMUFilterAlbums,
    YTMUFilterArtists,
    YTMUFilterCreators
};

typedef NS_ENUM(NSInteger, YTMUDownloadsSection) {
    YTMUSectionNowPlaying = 0,
    YTMUSectionCollections,
    YTMUSectionSongs,
    YTMUSectionCount
};

@interface YTMDownloads ()
@property (nonatomic, strong) NSArray<YTMUCollection *> *collections;
@property (nonatomic, strong) NSArray<YTMUOfflineTrack *> *songs;
@property (nonatomic, strong) UIStackView *emptyView;
@property (nonatomic) BOOL loading;
@property (nonatomic, strong) YTMUMiniPlayerView *miniPlayer;
@property (nonatomic, strong) NSLayoutConstraint *miniPlayerBottom;
@property (nonatomic, strong) NSMapTable<UIView *, NSArray<NSNumber *> *> *hiddenAppPlayerViews; // view -> old alpha, hidden, interaction
@property (nonatomic, strong) NSTimer *appPlayerTimer;
@property (nonatomic) BOOL keepAppPlayer;
@property (nonatomic) NSUInteger syncTicks;
@property (nonatomic, weak) UIView *cachedPivotBar;
@property (nonatomic) YTMUFilter filter;
@property (nonatomic, strong) NSArray<YTMUOfflineTrack *> *library;   // every song, for Songs / Artists
@property (nonatomic, strong) NSArray<YTMUCollection *> *people;       // artists or creators
@property (nonatomic) BOOL loadingLibrary;
@property (nonatomic, strong) UIView *chipHeader;
@property (nonatomic, strong) UIScrollView *chipBar;
@property (nonatomic, strong) UIView *topBar;        // "Downloads" + history / search / ⋮, inside YTM's top bar
@property (nonatomic, strong) UIView *topBarNormal;
@property (nonatomic, strong) UIView *topBarEditing; // X ... Done
@property (nonatomic) BOOL editingOrder;
@property (nonatomic, strong) CADisplayLink *topBarLink; // every frame during transitions
@property (nonatomic) NSInteger topBarFrames;
@property (nonatomic) BOOL lastOwnPageOnTop;
@end

#pragma mark - YTM's player while the Downloads tab is open

static UIView *YTMUFindView(UIView *view, Class cls, NSUInteger depth) {
    if (!view || !cls || depth > 20)
        return nil;
    if ([view isKindOfClass:cls])
        return view;
    for (UIView *subview in view.subviews) {
        UIView *found = YTMUFindView(subview, cls, depth + 1);
        if (found)
            return found;
    }
    return nil;
}

// Biggest view controller around YTM's player (watch screen + mini player)
// whose view contains neither the Downloads tab nor the tab bar
static void YTMUCollectAppPlayers(UIViewController *vc, NSArray<UIView *> *keep, NSMutableArray<UIViewController *> *output, NSUInteger depth) {
    if (!vc || depth > 14)
        return;
    Class watchClass = NSClassFromString(@"YTMWatchViewController");
    if (watchClass && [vc isKindOfClass:watchClass]) {
        UIViewController *outer = vc;
        while (outer.parentViewController.isViewLoaded) {
            UIView *parentView = outer.parentViewController.view;
            BOOL containsKept = NO;
            for (UIView *view in keep)
                containsKept = containsKept || [view isDescendantOfView:parentView];
            if (containsKept)
                break;
            outer = outer.parentViewController;
        }
        if (![output containsObject:outer])
            [output addObject:outer];
        return;
    }
    for (UIViewController *child in vc.childViewControllers)
        YTMUCollectAppPlayers(child, keep, output, depth + 1);
    YTMUCollectAppPlayers(vc.presentedViewController, keep, output, depth + 1);
}

@implementation YTMDownloads

- (NSURL *)rootFolder {
    NSURL *documents = [[[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask] lastObject];
    return [documents URLByAppendingPathComponent:@"YTMusicUltimate"];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.collections = @[];
    self.songs = @[];
    self.view.backgroundColor = YTMUBackgroundColor();

    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.backgroundColor = [UIColor clearColor];
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 64;
    self.tableView.sectionHeaderHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedSectionHeaderHeight = 44;
    if (@available(iOS 15.0, *))
        self.tableView.sectionHeaderTopPadding = 0;
    // Room for YTM's top bar, then the filter chips
    [self buildChipHeader];
    // Top inset follows YTM's top bar (see layoutTopBar)
    self.tableView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    self.tableView.contentInset = UIEdgeInsetsMake(110, 0, 170, 0);
    self.tableView.contentOffset = CGPointMake(0, -110);
    [self buildTopBar];
    [self.tableView registerClass:[YTMUTrackCell class] forCellReuseIdentifier:@"track"];
    [self.tableView registerClass:[YTMUCollectionCell class] forCellReuseIdentifier:@"collection"];
    [self.view addSubview:self.tableView];

    [NSLayoutConstraint activateConstraints:@[
        [self.tableView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor]
    ]];

    [self buildEmptyView];

    // Offline mini player above YTM's tab bar (YTM's own player is hidden on this tab)
    self.miniPlayer = [YTMUMiniPlayerView new];
    self.miniPlayer.presenter = self;
    self.miniPlayer.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.miniPlayer];
    self.miniPlayerBottom = [self.miniPlayer.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor];
    [NSLayoutConstraint activateConstraints:@[
        self.miniPlayerBottom,
        [self.miniPlayer.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.miniPlayer.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.miniPlayer.heightAnchor constraintEqualToConstant:64]
    ]];
    self.hiddenAppPlayerViews = [NSMapTable weakToStrongObjectsMapTable];

    // Tab switches don't always tell child view controllers: keep checking
    __weak __typeof(self) weakSelf = self;
    self.appPlayerTimer = [NSTimer timerWithTimeInterval:0.25 repeats:YES block:^(NSTimer *timer) {
        [weakSelf syncAppPlayer];
    }];
    // Also while scrolling / during transitions
    [[NSRunLoop mainRunLoop] addTimer:self.appPlayerTimer forMode:NSRunLoopCommonModes];

    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserver:self selector:@selector(reloadData) name:@"ReloadDataNotification" object:nil];
    [center addObserver:self selector:@selector(playerChanged) name:YTMUOfflinePlayerDidChangeNotification object:nil];
    // A song started in YTM (other tab, lock screen...): give its player back
    [center addObserver:self selector:@selector(appPlayerDidActivate) name:@"YTMUPlayerDidActivateVideo" object:nil];
    [self reloadData];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self guardTopBar];
    if (self.view.window)
        [self layoutTopBar:YES];
    [self reloadData]; // playlist downloads may have finished meanwhile
    [self.miniPlayer refresh];
    // Hide before anything is drawn (coming back from a playlist or another tab)
    if (!self.keepAppPlayer)
        [self hideAppPlayerForced:YES];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    self.keepAppPlayer = NO;
    [self syncAppPlayer];
    [self layoutMiniPlayer];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self guardTopBar];
    // Leaving the tab: YTM's logo comes back right away. Our own pages (player,
    // playlist, search...) cover everything, so the bar just stays for them.
    dispatch_async(dispatch_get_main_queue(), ^{
        if (![self ytmu_ownScreenOnTop])
            [self layoutTopBar:NO];
    });
    // Our own playlist page / Now Playing slides over: keep YTM's player hidden
    dispatch_async(dispatch_get_main_queue(), ^{
        [self syncAppPlayer];
    });
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self layoutMiniPlayer];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self.appPlayerTimer invalidate];
    [self showAppPlayer];
}

#pragma mark Filter chips

- (NSArray<NSString *> *)chipTitles {
    return @[@"Playlists", @"Songs", @"Albums", @"Artists", @"Creators"];
}

- (void)buildChipHeader {
    self.chipHeader = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 320, 52)];
    self.chipBar = [[UIScrollView alloc] initWithFrame:CGRectMake(0, 2, 320, 42)];
    self.chipBar.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    self.chipBar.showsHorizontalScrollIndicator = NO;
    self.chipBar.alwaysBounceHorizontal = YES;
    [self.chipHeader addSubview:self.chipBar];
    self.tableView.tableHeaderView = self.chipHeader;
    [self rebuildChips];
}

#pragma mark Top bar ("Downloads" instead of YTM's logo)

- (UIButton *)topBarButton:(NSString *)symbol action:(SEL)action {
    return [self topBarButton:symbol action:action width:44];
}

- (UIButton *)topBarButton:(NSString *)symbol action:(SEL)action width:(CGFloat)width {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:17 weight:UIImageSymbolWeightRegular];
    [button setImage:[UIImage systemImageNamed:symbol withConfiguration:config] forState:UIControlStateNormal];
    button.tintColor = [UIColor whiteColor];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [button.widthAnchor constraintEqualToConstant:width].active = YES;
    [button.heightAnchor constraintEqualToConstant:40].active = YES;
    return button;
}

- (void)buildTopBar {
    self.topBar = [UIView new];
    self.topBar.backgroundColor = YTMUBackgroundColor();
    self.topBar.hidden = YES;

    // Normal: title left, history / search / ⋮ right (YTM's avatar stays visible next to it)
    self.topBarNormal = [UIView new];
    self.topBarNormal.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    UILabel *title = [UILabel new];
    title.text = @"Downloads";
    title.font = [UIFont systemFontOfSize:25 weight:UIFontWeightSemibold];
    title.textColor = [UIColor whiteColor];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    UIButton *history = [self topBarButton:@"clock.arrow.circlepath" action:@selector(openHistory)];
    UIButton *search = [self topBarButton:@"magnifyingglass" action:@selector(openSearch)];
    UIButton *more = [self topBarButton:@"ellipsis" action:@selector(showTopMenu:) width:26];
    // Vertical ⋮ drawn upright (a rotated button would keep its wide frame)
    UIImage *dots = [more imageForState:UIControlStateNormal];
    if (dots) {
        UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(dots.size.height, dots.size.width)];
        UIImage *vertical = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
            CGContextTranslateCTM(context.CGContext, dots.size.height / 2.0, dots.size.width / 2.0);
            CGContextRotateCTM(context.CGContext, (CGFloat)M_PI_2);
            [dots drawInRect:CGRectMake(-dots.size.width / 2.0, -dots.size.height / 2.0, dots.size.width, dots.size.height)];
        }];
        [more setImage:[vertical imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate] forState:UIControlStateNormal];
    }
    UIStackView *buttons = [[UIStackView alloc] initWithArrangedSubviews:@[history, search, more]];
    buttons.spacing = 4;
    buttons.translatesAutoresizingMaskIntoConstraints = NO;
    [self.topBarNormal addSubview:title];
    [self.topBarNormal addSubview:buttons];
    [NSLayoutConstraint activateConstraints:@[
        [title.leadingAnchor constraintEqualToAnchor:self.topBarNormal.leadingAnchor constant:16],
        [title.centerYAnchor constraintEqualToAnchor:self.topBarNormal.centerYAnchor],
        [buttons.trailingAnchor constraintEqualToAnchor:self.topBarNormal.trailingAnchor],
        [buttons.centerYAnchor constraintEqualToAnchor:self.topBarNormal.centerYAnchor]
    ]];

    // Edit: X left, Done right
    self.topBarEditing = [UIView new];
    self.topBarEditing.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.topBarEditing.hidden = YES;
    UIButton *cancel = [self topBarButton:@"xmark" action:@selector(cancelEditingOrder)];
    UIButton *done = [UIButton buttonWithType:UIButtonTypeSystem];
    [done setTitle:@"Done" forState:UIControlStateNormal];
    [done setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    done.titleLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightSemibold];
    done.translatesAutoresizingMaskIntoConstraints = NO;
    [done addTarget:self action:@selector(finishEditingOrder) forControlEvents:UIControlEventTouchUpInside];
    [self.topBarEditing addSubview:cancel];
    [self.topBarEditing addSubview:done];
    [NSLayoutConstraint activateConstraints:@[
        [cancel.leadingAnchor constraintEqualToAnchor:self.topBarEditing.leadingAnchor constant:10],
        [cancel.centerYAnchor constraintEqualToAnchor:self.topBarEditing.centerYAnchor],
        [done.trailingAnchor constraintEqualToAnchor:self.topBarEditing.trailingAnchor constant:-12],
        [done.centerYAnchor constraintEqualToAnchor:self.topBarEditing.centerYAnchor]
    ]];

    [self.topBar addSubview:self.topBarNormal];
    [self.topBar addSubview:self.topBarEditing];
}

// YTM's own top bar (logo + avatar) sits above this tab: find it and put ours inside
- (UIView *)appTopBarInWindow:(UIWindow *)window {
    CGFloat safeTop = window.safeAreaInsets.top;
    BOOL wasHidden = self.topBar.hidden;
    self.topBar.hidden = YES; // don't find ourselves
    UIView *hit = [window hitTest:CGPointMake(60, safeTop + 22) withEvent:nil];
    self.topBar.hidden = wasHidden;
    for (UIView *view = hit; view && view != window; view = view.superview) {
        if (view == self.view || [view isDescendantOfView:self.view])
            return nil; // nothing above us there
        CGRect frame = [view convertRect:view.bounds toView:nil];
        if (frame.size.width >= window.bounds.size.width - 1 && frame.size.height < 200 && CGRectGetMaxY(frame) > safeTop + 20)
            return view;
    }
    return nil;
}

- (void)layoutTopBar:(BOOL)onScreen {
    UIWindow *window = self.view.window;
    if (!onScreen || !window) {
        self.topBar.hidden = YES;
        return;
    }
    CGFloat safeTop = window.safeAreaInsets.top;
    CGFloat width = window.bounds.size.width;
    // YTM can rebuild its bar (e.g. after full-screen pages): find it every time
    UIView *host = [self appTopBarInWindow:window] ?: self.view;
    if (self.topBar.superview != host)
        [host addSubview:self.topBar];
    [host bringSubviewToFront:self.topBar];

    // Same height as YTM's bar, leaving its avatar (right) visible
    CGRect hostInWindow = [host convertRect:host.bounds toView:nil];
    CGFloat barHeight = host == self.view ? 52 : MAX(44, MIN(70, CGRectGetMaxY(hostInWindow) - safeTop));
    CGRect frameInWindow = CGRectMake(0, safeTop, host == self.view ? width : width - 50, barHeight);
    self.topBar.frame = [host convertRect:frameInWindow fromView:nil];
    self.topBar.backgroundColor = [self barColorOf:host];
    self.topBar.hidden = NO;

    // List starts right below the bar
    CGFloat inset = CGRectGetMaxY([self.view convertRect:frameInWindow fromView:nil]);
    if (fabs(self.tableView.contentInset.top - inset) > 0.5) {
        BOOL atTop = self.tableView.contentOffset.y <= -self.tableView.contentInset.top + 1;
        UIEdgeInsets insets = self.tableView.contentInset;
        insets.top = inset;
        self.tableView.contentInset = insets;
        self.tableView.scrollIndicatorInsets = insets;
        if (atTop)
            self.tableView.contentOffset = CGPointMake(0, -inset);
    }
}

// YTM's bar color (so no darker box shows around our part)
- (UIColor *)barColorOf:(UIView *)host {
    for (UIView *view = host; view && view != self.view; view = view.superview) {
        UIColor *color = view.backgroundColor;
        CGFloat red = 0, green = 0, blue = 0, alpha = 0;
        if (color && [color getRed:&red green:&green blue:&blue alpha:&alpha] && alpha > 0.9)
            return color;
    }
    return YTMUBackgroundColor();
}

// Around page transitions YTM re-shows its logo: keep ours on top every frame for a moment
- (void)guardTopBar {
    self.topBarFrames = 90;
    if (self.topBarLink)
        return;
    self.topBarLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(topBarTick)];
    [self.topBarLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

- (void)topBarTick {
    if (--self.topBarFrames <= 0) {
        [self.topBarLink invalidate];
        self.topBarLink = nil;
    }
    BOOL ownPageOnTop = !self.topBar.hidden && [self ytmu_ownScreenOnTop];
    [self layoutTopBar:[self ytmu_isOnScreen] || ownPageOnTop];
}

- (void)presentViewController:(UIViewController *)viewController animated:(BOOL)animated completion:(void (^)(void))completion {
    [self guardTopBar];
    [super presentViewController:viewController animated:animated completion:completion];
}

- (void)openHistory {
    YTMUHistoryViewController *history = [[YTMUHistoryViewController alloc] initWithRoot:[self rootFolder]];
    history.modalPresentationStyle = UIModalPresentationFullScreen;
    __weak __typeof(self) weakSelf = self;
    history.onChange = ^{
        [weakSelf reloadData];
    };
    [self presentViewController:history animated:YES completion:nil];
}

- (void)showTopMenu:(UIButton *)sender {
    YTMUActionSheet *sheet = [YTMUActionSheet sheetWithTitle:@"Downloads" subtitle:[NSString stringWithFormat:@"%lu playlists & albums • %lu songs", (unsigned long)self.collections.count, (unsigned long)self.songs.count]];
    __weak __typeof(self) weakSelf = self;
    [sheet addAction:[YTMUSheetAction actionWithTitle:@"Edit" symbol:@"line.3.horizontal.decrease" handler:^{
        [weakSelf startEditingOrder];
    }]];
    [sheet presentFrom:self];
}

#pragma mark Edit (reorder playlists & albums, songs)

- (void)startEditingOrder {
    if (self.filter != YTMUFilterNone) {
        self.filter = YTMUFilterNone;
        [self rebuildChips];
    }
    self.editingOrder = YES;
    self.topBarNormal.hidden = YES;
    self.topBarEditing.hidden = NO;
    self.chipBar.userInteractionEnabled = NO;
    self.chipBar.alpha = 0.4;
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

- (void)stopEditingOrder {
    self.editingOrder = NO;
    self.topBarNormal.hidden = NO;
    self.topBarEditing.hidden = YES;
    self.chipBar.userInteractionEnabled = YES;
    self.chipBar.alpha = 1.0;
    [self setTableEditingKeepingPosition:NO];
}

- (void)cancelEditingOrder {
    [self stopEditingOrder];
    [self reloadData]; // back to the saved order
}

- (void)finishEditingOrder {
    YTMUSaveOrder([self.collections valueForKey:@"folder"], @"collections");
    YTMUSaveOrder([self.songs valueForKey:@"url"], YTMUTrackOrderKey([self rootFolder]));
    [self stopEditingOrder];
    [self.tableView reloadData];
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    return self.editingOrder;
}

- (BOOL)tableView:(UITableView *)tableView canMoveRowAtIndexPath:(NSIndexPath *)indexPath {
    return self.editingOrder && self.filter == YTMUFilterNone &&
           (indexPath.section == YTMUSectionCollections || indexPath.section == YTMUSectionSongs);
}

- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath {
    return UITableViewCellEditingStyleNone;
}

- (BOOL)tableView:(UITableView *)tableView shouldIndentWhileEditingRowAtIndexPath:(NSIndexPath *)indexPath {
    return NO;
}

// Rows stay in their own section
- (NSIndexPath *)tableView:(UITableView *)tableView targetIndexPathForMoveFromRowAtIndexPath:(NSIndexPath *)source toProposedIndexPath:(NSIndexPath *)proposed {
    if (proposed.section == source.section)
        return proposed;
    NSInteger rows = [self tableView:tableView numberOfRowsInSection:source.section];
    return [NSIndexPath indexPathForRow:(proposed.section < source.section ? 0 : rows - 1) inSection:source.section];
}

- (void)tableView:(UITableView *)tableView moveRowAtIndexPath:(NSIndexPath *)source toIndexPath:(NSIndexPath *)destination {
    if (source.section == YTMUSectionCollections) {
        NSMutableArray *items = [self.collections mutableCopy];
        id item = items[(NSUInteger)source.row];
        [items removeObjectAtIndex:(NSUInteger)source.row];
        [items insertObject:item atIndex:(NSUInteger)destination.row];
        self.collections = items;
    } else if (source.section == YTMUSectionSongs) {
        NSMutableArray *items = [self.songs mutableCopy];
        id item = items[(NSUInteger)source.row];
        [items removeObjectAtIndex:(NSUInteger)source.row];
        [items insertObject:item atIndex:(NSUInteger)destination.row];
        self.songs = items;
    }
}

- (UIButton *)chipWithTitle:(NSString *)title symbol:(NSString *)symbol selected:(BOOL)selected tag:(NSInteger)tag {
    UIButton *chip = [UIButton buttonWithType:UIButtonTypeCustom];
    UIColor *background = selected ? [UIColor colorWithWhite:0.94 alpha:1.0] : [UIColor colorWithWhite:1.0 alpha:0.12];
    UIColor *foreground = selected ? [UIColor blackColor] : [UIColor colorWithWhite:0.98 alpha:1.0];
    chip.backgroundColor = background;
    chip.layer.cornerRadius = 8.0;
    chip.tag = tag;
    if (title) {
        [chip setTitle:title forState:UIControlStateNormal];
        [chip setTitleColor:foreground forState:UIControlStateNormal];
        chip.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
        chip.contentEdgeInsets = UIEdgeInsetsMake(0, 14, 0, 14);
    } else {
        UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:14 weight:UIImageSymbolWeightSemibold];
        [chip setImage:[[UIImage systemImageNamed:symbol withConfiguration:config] imageWithTintColor:foreground renderingMode:UIImageRenderingModeAlwaysOriginal] forState:UIControlStateNormal];
        chip.contentEdgeInsets = UIEdgeInsetsMake(0, 11, 0, 11);
    }
    [chip addTarget:self action:@selector(chipTapped:) forControlEvents:UIControlEventTouchUpInside];
    [chip sizeToFit];
    return chip;
}

- (void)rebuildChips {
    for (UIView *view in self.chipBar.subviews)
        [view removeFromSuperview];

    // Nothing picked: all chips. Picked: [X] [Chosen], like YTM
    NSMutableArray<UIButton *> *chips = [NSMutableArray array];
    if (self.filter == YTMUFilterNone) {
        NSArray<NSString *> *titles = [self chipTitles];
        for (NSUInteger i = 0; i < titles.count; i++)
            [chips addObject:[self chipWithTitle:titles[i] symbol:nil selected:NO tag:(NSInteger)i + 1]];
    } else {
        [chips addObject:[self chipWithTitle:nil symbol:@"xmark" selected:YES tag:0]];
        [chips addObject:[self chipWithTitle:[self chipTitles][(NSUInteger)self.filter - 1] symbol:nil selected:YES tag:self.filter]];
    }

    CGFloat x = 16;
    for (UIButton *chip in chips) {
        chip.frame = CGRectMake(x, 4, MAX(chip.bounds.size.width, 36), 34);
        [self.chipBar addSubview:chip];
        x += chip.bounds.size.width + 8;
    }
    self.chipBar.contentSize = CGSizeMake(x + 8, 42);
    self.chipBar.contentOffset = CGPointZero;
}

- (void)chipTapped:(UIButton *)chip {
    YTMUFilter filter = (YTMUFilter)chip.tag;
    // Tapping the chosen chip again, or X: back to everything
    self.filter = (filter == self.filter) ? YTMUFilterNone : filter;
    [self rebuildChips];
    [self loadLibraryIfNeeded];
    [self.tableView setContentOffset:CGPointMake(0, -self.tableView.adjustedContentInset.top) animated:NO];
    [self.tableView reloadData];
}

- (BOOL)filterNeedsLibrary {
    return self.filter == YTMUFilterSongs || self.filter == YTMUFilterArtists || self.filter == YTMUFilterCreators;
}

// Songs / Artists read every file's tags (cached after the first time)
- (void)loadLibraryIfNeeded {
    if (![self filterNeedsLibrary] || self.loadingLibrary)
        return;
    if (self.library) {
        [self updatePeople];
        return;
    }
    self.loadingLibrary = YES;
    UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    spinner.color = [UIColor whiteColor];
    spinner.frame = CGRectMake(0, 0, 1, 60);
    [spinner startAnimating];
    self.tableView.tableFooterView = spinner;

    NSURL *root = [self rootFolder];
    NSArray<YTMUCollection *> *collections = self.collections;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray<YTMUOfflineTrack *> *library = [YTMUCollection libraryTracksInFolder:root collections:collections];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.library = library;
            self.loadingLibrary = NO;
            self.tableView.tableFooterView = nil;
            [self updatePeople];
            [self.tableView reloadData];
        });
    });
}

- (void)updatePeople {
    if (self.filter == YTMUFilterArtists)
        self.people = [YTMUCollection artistsFromCollections:self.collections library:self.library ?: @[]];
    else if (self.filter == YTMUFilterCreators)
        self.people = [YTMUCollection creatorsFromCollections:self.collections];
    else
        self.people = @[];
}

// Rows of the chosen chip
- (NSArray *)filterItems {
    switch (self.filter) {
        case YTMUFilterPlaylists:
            return [self.collections filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"isAlbum == NO"]];
        case YTMUFilterAlbums:
            return [self.collections filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"isAlbum == YES"]];
        case YTMUFilterSongs:
            return self.library ?: @[];
        case YTMUFilterArtists:
        case YTMUFilterCreators:
            return self.people ?: @[];
        default:
            return @[];
    }
}

- (void)openSearch {
    YTMUSearchViewController *search = [[YTMUSearchViewController alloc] initWithRoot:[self rootFolder] collections:self.collections library:self.library];
    search.modalPresentationStyle = UIModalPresentationFullScreen;
    __weak __typeof(self) weakSelf = self;
    search.onChange = ^{
        [weakSelf reloadData];
    };
    [self presentViewController:search animated:YES completion:nil];
}

- (void)openCollection:(YTMUCollection *)collection {
    [self openCollection:collection finding:NO];
}

- (void)openCollection:(YTMUCollection *)collection finding:(BOOL)finding {
    YTMUCollectionViewController *page = [[YTMUCollectionViewController alloc] initWithCollection:collection];
    page.startsFinding = finding;
    page.modalPresentationStyle = UIModalPresentationFullScreen;
    __weak __typeof(self) weakSelf = self;
    page.onChange = ^{
        [weakSelf reloadData];
    };
    [self presentViewController:page animated:YES completion:nil];
}

#pragma mark YTM's player

- (BOOL)ytmu_isOnScreen {
    UIWindow *window = self.view.window;
    if (!window)
        return NO;
    for (UIView *view = self.view; view; view = view.superview) {
        if (view.hidden || view.alpha < 0.01)
            return NO;
    }
    if (!CGRectIntersectsRect([self.view convertRect:self.view.bounds toView:nil], window.bounds))
        return NO;
    // Another tab's page could sit on top of this one
    CGPoint center = [self.view convertPoint:CGPointMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds)) toView:nil];
    UIView *hit = [window hitTest:center withEvent:nil];
    return hit && [hit isDescendantOfView:self.view];
}

// Something we opened from this tab is on top (playlist page, Now Playing, menus)
- (BOOL)ytmu_ownScreenOnTop {
    UIWindow *window = self.view.window ?: [UIApplication sharedApplication].keyWindow;
    for (UIViewController *vc = window.rootViewController.presentedViewController; vc; vc = vc.presentedViewController) {
        if ([vc isKindOfClass:[YTMUCollectionViewController class]] || [vc isKindOfClass:[YTMUNowPlayingViewController class]] ||
            [vc isKindOfClass:[YTMUSearchViewController class]] || [vc isKindOfClass:[YTMUHistoryViewController class]] ||
            [vc isKindOfClass:[YTMUActionSheet class]])
            return YES;
        // Menus / share sheets opened while YTM's player was already hidden here
        if (self.hiddenAppPlayerViews.count && ([vc isKindOfClass:[UIAlertController class]] || [vc isKindOfClass:[UIActivityViewController class]]))
            return YES;
    }
    return NO;
}

// Runs every 0.25 s while this tab exists: YTM's player hidden exactly while we're visible
- (void)syncAppPlayer {
    // One of our pages opened / closed (also ones opened from search, history...)
    BOOL anyOwnPage = [self ytmu_ownScreenOnTop];
    if (anyOwnPage != self.lastOwnPageOnTop) {
        self.lastOwnPageOnTop = anyOwnPage;
        [self guardTopBar];
    }
    BOOL ownPageOnTop = !self.topBar.hidden && anyOwnPage;
    [self layoutTopBar:[self ytmu_isOnScreen] || ownPageOnTop];
    if (!self.keepAppPlayer && ([self ytmu_isOnScreen] || (self.hiddenAppPlayerViews.count && [self ytmu_ownScreenOnTop])))
        [self hideAppPlayerForced:NO];
    else
        [self showAppPlayer];
}

- (void)hideAppPlayerForced:(BOOL)forced {
    UIWindow *window = self.view.window ?: [UIApplication sharedApplication].keyWindow;
    if (!window)
        return;

    // Already hidden: just make sure YTM didn't show it again
    if (self.hiddenAppPlayerViews.count && !forced && ++self.syncTicks % 4 != 0) {
        for (UIView *view in self.hiddenAppPlayerViews.keyEnumerator.allObjects) {
            view.alpha = 0.0;
            view.hidden = YES;
        }
        return;
    }

    NSMutableArray<UIView *> *keep = [NSMutableArray arrayWithObject:self.view];
    UIView *pivotBar = [self ytmu_pivotBar];
    if (pivotBar)
        [keep addObject:pivotBar];
    NSMutableArray<UIViewController *> *players = [NSMutableArray array];
    YTMUCollectAppPlayers(window.rootViewController, keep, players, 0);
    for (UIViewController *player in players) {
        UIView *view = player.isViewLoaded ? player.view : nil;
        BOOL containsKept = NO;
        for (UIView *kept in keep)
            containsKept = containsKept || [kept isDescendantOfView:view];
        if (!view || containsKept)
            continue;
        if (![self.hiddenAppPlayerViews objectForKey:view])
            [self.hiddenAppPlayerViews setObject:@[@(view.alpha), @(view.hidden), @(view.userInteractionEnabled)] forKey:view];
        view.alpha = 0.0;
        view.hidden = YES;
        view.userInteractionEnabled = NO;
    }
}

- (void)showAppPlayer {
    for (UIView *view in self.hiddenAppPlayerViews.keyEnumerator.allObjects) {
        NSArray<NSNumber *> *old = [self.hiddenAppPlayerViews objectForKey:view];
        view.alpha = old[0].doubleValue;
        view.hidden = old[1].boolValue;
        view.userInteractionEnabled = old[2].boolValue;
    }
    [self.hiddenAppPlayerViews removeAllObjects];
}

- (void)appPlayerDidActivate {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.hiddenAppPlayerViews.count)
            return;
        // Started from the lock screen while on this tab: leave YTM's player until the tab is reopened
        self.keepAppPlayer = YES;
        [self showAppPlayer];
    });
}

// Sits right on top of YTM's tab bar
- (void)layoutMiniPlayer {
    CGFloat inset = self.view.safeAreaInsets.bottom;
    UIView *pivotBar = [self ytmu_pivotBar];
    if (pivotBar && !pivotBar.hidden) {
        CGRect frame = [pivotBar convertRect:pivotBar.bounds toView:self.view];
        CGFloat fromBottom = self.view.bounds.size.height - CGRectGetMinY(frame);
        if (fromBottom > 0 && fromBottom < self.view.bounds.size.height / 2)
            inset = fromBottom;
    }
    if (fabs(self.miniPlayerBottom.constant + inset) > 0.5)
        self.miniPlayerBottom.constant = -inset;
}

// YTM's tab bar (cached, it lives as long as the app)
- (UIView *)ytmu_pivotBar {
    UIView *cached = self.cachedPivotBar;
    if (cached.window)
        return cached;
    cached = YTMUFindView(self.view.window, NSClassFromString(@"YTPivotBarView"), 0);
    self.cachedPivotBar = cached;
    return cached;
}

- (void)buildEmptyView {
    UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage imageNamed:@"yt_outline_audio_48pt" inBundle:[NSBundle mainBundle] compatibleWithTraitCollection:nil]];
    icon.tintColor = [[UIColor whiteColor] colorWithAlphaComponent:0.8];
    icon.contentMode = UIViewContentModeScaleAspectFit;
    [icon.widthAnchor constraintEqualToConstant:48].active = YES;
    [icon.heightAnchor constraintEqualToConstant:48].active = YES;

    UILabel *label = [UILabel new];
    label.text = LOC(@"EMPTY");
    label.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.8];
    label.font = [UIFont systemFontOfSize:16];
    label.numberOfLines = 0;
    label.textAlignment = NSTextAlignmentCenter;

    self.emptyView = [[UIStackView alloc] initWithArrangedSubviews:@[icon, label]];
    self.emptyView.axis = UILayoutConstraintAxisVertical;
    self.emptyView.alignment = UIStackViewAlignmentCenter;
    self.emptyView.spacing = 20;
    self.emptyView.translatesAutoresizingMaskIntoConstraints = NO;
    self.emptyView.hidden = YES;
    [self.view addSubview:self.emptyView];
    [NSLayoutConstraint activateConstraints:@[
        [self.emptyView.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.emptyView.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [self.emptyView.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.view.leadingAnchor constant:20]
    ]];
}

#pragma mark Data

- (void)reloadData {
    if (self.loading)
        return;
    self.loading = YES;
    NSURL *root = [self rootFolder];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray<YTMUCollection *> *collections = [YTMUCollection collectionsInFolder:root];

        // Single songs in the main folder, with their separate .png cover
        NSMutableArray<YTMUOfflineTrack *> *songs = [NSMutableArray array];
        for (NSURL *file in [YTMUCollection audioFilesInFolder:root]) {
            NSURL *pngURL = [[file URLByDeletingPathExtension] URLByAppendingPathExtension:@"png"];
            UIImage *png = [UIImage imageWithContentsOfFile:pngURL.path];
            [songs addObject:[YTMUOfflineTrack trackWithURL:file fallbackArtwork:png]];
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            self.collections = collections;
            self.songs = songs;
            self.loading = NO;
            self.emptyView.hidden = collections.count > 0 || songs.count > 0;
            self.library = nil; // files may have changed (cached tags make this quick)
            [self loadLibraryIfNeeded];
            if (self.filter == YTMUFilterPlaylists || self.filter == YTMUFilterAlbums)
                [self updatePeople];
            [self.tableView reloadData];
        });
    });
}

- (void)playerChanged {
    if (!self.editingOrder)
        [self.tableView reloadData];
}

- (BOOL)hasNowPlaying {
    return [YTMUOfflinePlayer shared].currentTrack != nil;
}

#pragma mark Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return self.filter == YTMUFilterNone ? YTMUSectionCount : 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (self.filter != YTMUFilterNone)
        return (NSInteger)[self filterItems].count;
    switch (section) {
        case YTMUSectionNowPlaying:
            return [self hasNowPlaying] ? 1 : 0;
        case YTMUSectionCollections:
            return (NSInteger)self.collections.count;
        case YTMUSectionSongs:
            return (NSInteger)self.songs.count;
        default:
            return 0;
    }
}

- (NSString *)titleForSection:(NSInteger)section {
    if (self.filter != YTMUFilterNone)
        return nil;
    switch (section) {
        case YTMUSectionNowPlaying:
            return [self hasNowPlaying] ? @"Now playing" : nil;
        case YTMUSectionCollections:
            return self.collections.count ? @"Playlists & albums" : nil;
        case YTMUSectionSongs:
            return self.songs.count ? @"Songs" : nil;
        default:
            return nil;
    }
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    NSString *title = [self titleForSection:section];
    if (!title)
        return nil;

    UIView *header = [UIView new];
    header.backgroundColor = self.view.backgroundColor;
    UILabel *label = [UILabel new];
    label.text = title;
    label.font = [UIFont systemFontOfSize:22 weight:UIFontWeightBold];
    label.textColor = [UIColor whiteColor];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [header addSubview:label];
    [NSLayoutConstraint activateConstraints:@[
        [label.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:16],
        [label.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-16],
        [label.topAnchor constraintEqualToAnchor:header.topAnchor constant:14],
        [label.bottomAnchor constraintEqualToAnchor:header.bottomAnchor constant:-6]
    ]];
    return header;
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    return [self titleForSection:section] ? UITableViewAutomaticDimension : CGFLOAT_MIN;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    __weak __typeof(self) weakSelf = self;
    if (self.filter != YTMUFilterNone) {
        id item = [self filterItems][(NSUInteger)indexPath.row];
        if ([item isKindOfClass:[YTMUOfflineTrack class]]) {
            YTMUOfflineTrack *track = item;
            YTMUTrackCell *cell = [tableView dequeueReusableCellWithIdentifier:@"track" forIndexPath:indexPath];
            YTMUOfflinePlayer *player = [YTMUOfflinePlayer shared];
            [cell configureWithTrack:track isCurrent:[player.currentTrack.url isEqual:track.url] isPlaying:player.isPlaying];
            cell.onMenu = ^(UIButton *sender) {
                [weakSelf showMenuForSong:track from:sender];
            };
            return cell;
        }
        YTMUCollection *collection = item;
        YTMUCollectionCell *cell = [tableView dequeueReusableCellWithIdentifier:@"collection" forIndexPath:indexPath];
        [cell configureWithCollection:collection];
        cell.onMenu = ^(UIButton *sender) {
            YTMUShowCollectionMenuFull(collection, weakSelf, sender, ^{
                [weakSelf reloadData];
            }, nil, collection.kind ? nil : ^{
                [weakSelf openCollection:collection finding:YES];
            });
        };
        return cell;
    }

    if (indexPath.section == YTMUSectionNowPlaying) {
        YTMUTrackCell *cell = [tableView dequeueReusableCellWithIdentifier:@"track" forIndexPath:indexPath];
        YTMUOfflinePlayer *player = [YTMUOfflinePlayer shared];
        [cell configureWithTrack:player.currentTrack isCurrent:YES isPlaying:player.isPlaying];
        return cell;
    }

    if (indexPath.section == YTMUSectionCollections) {
        YTMUCollectionCell *cell = [tableView dequeueReusableCellWithIdentifier:@"collection" forIndexPath:indexPath];
        YTMUCollection *collection = self.collections[(NSUInteger)indexPath.row];
        [cell configureWithCollection:collection];
        cell.onMenu = ^(UIButton *sender) {
            YTMUShowCollectionMenuFull(collection, weakSelf, sender, ^{
                [weakSelf reloadData];
            }, nil, collection.kind ? nil : ^{
                [weakSelf openCollection:collection finding:YES];
            });
        };
        return cell;
    }

    if (indexPath.section == YTMUSectionSongs) {
        YTMUTrackCell *cell = [tableView dequeueReusableCellWithIdentifier:@"track" forIndexPath:indexPath];
        YTMUOfflineTrack *track = self.songs[(NSUInteger)indexPath.row];
        YTMUOfflinePlayer *player = [YTMUOfflinePlayer shared];
        BOOL isCurrent = [player.currentTrack.url isEqual:track.url];
        [cell configureWithTrack:track isCurrent:isCurrent isPlaying:player.isPlaying];
        cell.onMenu = ^(UIButton *sender) {
            [weakSelf showMenuForSong:track from:sender];
        };
        return cell;
    }

    return [UITableViewCell new];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (self.editingOrder)
        return;

    if (self.filter != YTMUFilterNone) {
        NSArray *items = [self filterItems];
        id item = items[(NSUInteger)indexPath.row];
        if ([item isKindOfClass:[YTMUOfflineTrack class]]) {
            [[YTMUOfflinePlayer shared] playTracks:items startIndex:indexPath.row shuffle:NO];
            YTMUNowPlayingViewController *nowPlaying = [YTMUNowPlayingViewController new];
            nowPlaying.modalPresentationStyle = UIModalPresentationFullScreen;
            [self presentViewController:nowPlaying animated:YES completion:nil];
        } else {
            [self openCollection:item];
        }
        return;
    }

    if (indexPath.section == YTMUSectionNowPlaying) {
        YTMUNowPlayingViewController *nowPlaying = [YTMUNowPlayingViewController new];
        nowPlaying.modalPresentationStyle = UIModalPresentationFullScreen;
        [self presentViewController:nowPlaying animated:YES completion:nil];
    } else if (indexPath.section == YTMUSectionCollections) {
        [self openCollection:self.collections[(NSUInteger)indexPath.row]];
    } else if (indexPath.section == YTMUSectionSongs) {
        YTMUOfflinePlayer *player = [YTMUOfflinePlayer shared];
        [player playTracks:self.songs startIndex:indexPath.row shuffle:NO];
        YTMUNowPlayingViewController *nowPlaying = [YTMUNowPlayingViewController new];
        nowPlaying.modalPresentationStyle = UIModalPresentationFullScreen;
        [self presentViewController:nowPlaying animated:YES completion:nil];
    }
}

#pragma mark Song menu

- (void)showMenuForSong:(YTMUOfflineTrack *)track from:(UIButton *)sender {
    NSURL *pngURL = [[track.url URLByDeletingPathExtension] URLByAppendingPathExtension:@"png"];
    __weak __typeof(self) weakSelf = self;
    NSMutableArray<YTMUSheetAction *> *extras = [NSMutableArray array];
    // Renaming playlist songs would break their index, only single downloads
    BOOL isSingle = [[track.url URLByDeletingLastPathComponent].path isEqualToString:[self rootFolder].path];
    if (isSingle) {
        [extras addObject:[YTMUSheetAction actionWithTitle:@"Rename" symbol:@"pencil" handler:^{
            [weakSelf renameSong:track];
        }]];
    }
    YTMUShowSongMenu(track, self, extras, ^{
        [weakSelf confirmDeleteURL:track.url name:track.url.lastPathComponent.stringByDeletingPathExtension extraURL:pngURL];
    });
}

#pragma mark Actions

- (void)shareItems:(NSArray *)items from:(UIView *)source {
    if (items.count == 0)
        return;
    UIActivityViewController *activity = [[UIActivityViewController alloc] initWithActivityItems:items applicationActivities:nil];
    activity.excludedActivityTypes = @[UIActivityTypeAssignToContact, UIActivityTypePrint];
    UIPopoverPresentationController *popover = activity.popoverPresentationController;
    if (popover && source) {
        popover.sourceView = source;
        popover.sourceRect = source.bounds;
    }
    [self presentViewController:activity animated:YES completion:nil];
}

- (void)confirmDeleteURL:(NSURL *)url name:(NSString *)name extraURL:(NSURL *)extraURL {
    YTAlertView *alertView = [NSClassFromString(@"YTAlertView") confirmationDialogWithAction:^{
        YTMUOfflinePlayer *player = [YTMUOfflinePlayer shared];
        if ([player.currentTrack.url.path hasPrefix:url.path])
            [player stop];
        [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
        if (extraURL)
            [[NSFileManager defaultManager] removeItemAtURL:extraURL error:nil];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self reloadData];
        });
    } actionTitle:LOC(@"DELETE")];
    alertView.title = @"YTMusicUltimate";
    alertView.subtitle = [NSString stringWithFormat:LOC(@"DELETE_MESSAGE"), name];
    [alertView show];
}

- (void)renameSong:(YTMUOfflineTrack *)track {
    NSURL *audioURL = track.url;
    NSURL *coverURL = [[audioURL URLByDeletingPathExtension] URLByAppendingPathExtension:@"png"];

    UITextView *textView = [[UITextView alloc] init];
    textView.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.15];
    textView.layer.cornerRadius = 3.0;
    textView.layer.borderWidth = 1.0;
    textView.layer.borderColor = [[UIColor grayColor] colorWithAlphaComponent:0.5].CGColor;
    textView.textColor = [UIColor whiteColor];
    textView.text = audioURL.lastPathComponent.stringByDeletingPathExtension;
    textView.font = [UIFont systemFontOfSize:14.0];

    YTAlertView *alertView = [NSClassFromString(@"YTAlertView") confirmationDialogWithAction:^{
        NSString *newName = [textView.text stringByReplacingOccurrencesOfString:@"/" withString:@""];
        if (newName.length == 0)
            return;
        NSURL *folder = [audioURL URLByDeletingLastPathComponent];
        NSURL *newAudioURL = [folder URLByAppendingPathComponent:[NSString stringWithFormat:@"%@.%@", newName, audioURL.pathExtension]];
        NSURL *newCoverURL = [folder URLByAppendingPathComponent:[newName stringByAppendingString:@".png"]];

        BOOL moved = [[NSFileManager defaultManager] moveItemAtURL:audioURL toURL:newAudioURL error:nil];
        [[NSFileManager defaultManager] moveItemAtURL:coverURL toURL:newCoverURL error:nil];
        if (moved) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self reloadData];
                [[NSClassFromString(@"YTMToastController") alloc] showMessage:LOC(@"DONE")];
            });
        }
    } actionTitle:LOC(@"RENAME")];
    alertView.title = @"YTMusicUltimate";

    UIView *customView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, alertView.frameForDialog.size.width - 50, 75)];
    textView.frame = customView.frame;
    [customView addSubview:textView];
    alertView.customContentView = customView;
    [alertView show];
}

@end