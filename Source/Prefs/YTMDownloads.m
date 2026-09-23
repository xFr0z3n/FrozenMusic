#import "YTMDownloads.h"
#import "../Offline/YTMUOfflineUI.h"

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
    // Room for YTM's top bar, mini player and tab bar
    self.tableView.tableHeaderView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 1, 64)];
    self.tableView.contentInset = UIEdgeInsetsMake(0, 0, 170, 0);
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
        if ([vc isKindOfClass:[YTMUCollectionViewController class]] || [vc isKindOfClass:[YTMUNowPlayingViewController class]])
            return YES;
        // Menus / share sheets opened while YTM's player was already hidden here
        if (self.hiddenAppPlayerViews.count && ([vc isKindOfClass:[UIAlertController class]] || [vc isKindOfClass:[UIActivityViewController class]]))
            return YES;
    }
    return NO;
}

// Runs every 0.25 s while this tab exists: YTM's player hidden exactly while we're visible
- (void)syncAppPlayer {
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
            [self.tableView reloadData];
        });
    });
}

- (void)playerChanged {
    [self.tableView reloadData];
}

- (BOOL)hasNowPlaying {
    return [YTMUOfflinePlayer shared].currentTrack != nil;
}

#pragma mark Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return YTMUSectionCount;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
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
        __weak __typeof(self) weakSelf = self;
        cell.onMenu = ^(UIButton *sender) {
            YTMUShowCollectionMenu(collection, weakSelf, sender, ^{
                [weakSelf reloadData];
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
        __weak __typeof(self) weakSelf = self;
        cell.onMenu = ^(UIButton *sender) {
            [weakSelf showMenuForSong:track from:sender];
        };
        return cell;
    }

    return [UITableViewCell new];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    if (indexPath.section == YTMUSectionNowPlaying) {
        YTMUNowPlayingViewController *nowPlaying = [YTMUNowPlayingViewController new];
        nowPlaying.modalPresentationStyle = UIModalPresentationFullScreen;
        [self presentViewController:nowPlaying animated:YES completion:nil];
    } else if (indexPath.section == YTMUSectionCollections) {
        YTMUCollectionViewController *page = [[YTMUCollectionViewController alloc] initWithCollection:self.collections[(NSUInteger)indexPath.row]];
        page.modalPresentationStyle = UIModalPresentationFullScreen;
        __weak __typeof(self) weakSelf = self;
        page.onChange = ^{
            [weakSelf reloadData];
        };
        [self presentViewController:page animated:YES completion:nil];
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
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:track.title message:track.artist preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Share" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [self shareItems:@[track.url] from:sender];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Open song" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        // YTMusicUltimate folder in the Files app
        NSString *path = [[self rootFolder].path stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLPathAllowedCharacterSet]];
        NSURL *filesURL = path ? [NSURL URLWithString:[@"shareddocuments://" stringByAppendingString:path]] : nil;
        if (filesURL)
            [[UIApplication sharedApplication] openURL:filesURL options:@{} completionHandler:nil];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Rename" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [self renameSong:track];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Delete download" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        [self confirmDeleteURL:track.url name:track.url.lastPathComponent.stringByDeletingPathExtension extraURL:pngURL];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = sender;
    sheet.popoverPresentationController.sourceRect = sender.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
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