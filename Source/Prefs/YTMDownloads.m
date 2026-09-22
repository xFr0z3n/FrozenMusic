#import "YTMDownloads.h"
#import "../Offline/YTMUOfflineUI.h"

typedef NS_ENUM(NSInteger, YTMUDownloadsSection) {
    YTMUSectionNowPlaying = 0,
    YTMUSectionCollections,
    YTMUSectionSongs,
    YTMUSectionActions,
    YTMUSectionCount
};

@interface YTMDownloads ()
@property (nonatomic, strong) NSArray<YTMUCollection *> *collections;
@property (nonatomic, strong) NSArray<YTMUOfflineTrack *> *songs;
@property (nonatomic, strong) UIStackView *emptyView;
@property (nonatomic) BOOL loading;
@end

@implementation YTMDownloads

- (NSURL *)rootFolder {
    NSURL *documents = [[[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask] lastObject];
    return [documents URLByAppendingPathComponent:@"YTMusicUltimate"];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.collections = @[];
    self.songs = @[];
    self.view.backgroundColor = [UIColor colorWithRed:3 / 255.0 green:3 / 255.0 blue:3 / 255.0 alpha:1.0];

    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.backgroundColor = [UIColor clearColor];
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 72;
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

    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserver:self selector:@selector(reloadData) name:@"ReloadDataNotification" object:nil];
    [center addObserver:self selector:@selector(playerChanged) name:YTMUOfflinePlayerDidChangeNotification object:nil];
    [self reloadData];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadData]; // playlist downloads may have finished meanwhile
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
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
        case YTMUSectionActions:
            return (self.collections.count || self.songs.count) ? 2 : 0;
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
        [cell configureWithTrack:[YTMUOfflinePlayer shared].currentTrack showNumber:NO isCurrent:YES];
        return cell;
    }

    if (indexPath.section == YTMUSectionCollections) {
        YTMUCollectionCell *cell = [tableView dequeueReusableCellWithIdentifier:@"collection" forIndexPath:indexPath];
        [cell configureWithCollection:self.collections[(NSUInteger)indexPath.row]];
        return cell;
    }

    if (indexPath.section == YTMUSectionSongs) {
        YTMUTrackCell *cell = [tableView dequeueReusableCellWithIdentifier:@"track" forIndexPath:indexPath];
        YTMUOfflineTrack *track = self.songs[(NSUInteger)indexPath.row];
        BOOL isCurrent = [[YTMUOfflinePlayer shared].currentTrack.url isEqual:track.url];
        [cell configureWithTrack:track showNumber:NO isCurrent:isCurrent];
        return cell;
    }

    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"action"];
    if (!cell)
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"action"];
    BOOL isRemove = indexPath.row == 1;
    cell.backgroundColor = [UIColor clearColor];
    cell.textLabel.text = isRemove ? LOC(@"REMOVE_ALL") : LOC(@"SHARE_ALL");
    cell.textLabel.textColor = [UIColor whiteColor];
    cell.imageView.image = [UIImage systemImageNamed:isRemove ? @"trash" : @"square.and.arrow.up.on.square"];
    cell.imageView.tintColor = isRemove ? [UIColor systemRedColor] : [UIColor colorWithRed:30.0 / 255.0 green:150.0 / 255.0 blue:245.0 / 255.0 alpha:1.0];
    return cell;
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
    } else if (indexPath.section == YTMUSectionActions) {
        if (indexPath.row == 0)
            [self shareAll:[tableView cellForRowAtIndexPath:indexPath]];
        else
            [self removeAll];
    }
}

#pragma mark Swipe actions

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == YTMUSectionCollections) {
        YTMUCollection *collection = self.collections[(NSUInteger)indexPath.row];
        UIContextualAction *share = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:nil handler:^(UIContextualAction *action, UIView *sourceView, void (^completion)(BOOL)) {
            [self shareItems:collection.files from:sourceView];
            completion(YES);
        }];
        share.image = [UIImage systemImageNamed:@"square.and.arrow.up"];
        share.backgroundColor = [UIColor systemBlueColor];

        UIContextualAction *delete = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:nil handler:^(UIContextualAction *action, UIView *sourceView, void (^completion)(BOOL)) {
            [self confirmDeleteURL:collection.folder name:collection.name extraURL:nil];
            completion(YES);
        }];
        delete.image = [UIImage systemImageNamed:@"trash"];
        return [UISwipeActionsConfiguration configurationWithActions:@[delete, share]];
    }

    if (indexPath.section == YTMUSectionSongs) {
        YTMUOfflineTrack *track = self.songs[(NSUInteger)indexPath.row];
        NSURL *pngURL = [[track.url URLByDeletingPathExtension] URLByAppendingPathExtension:@"png"];

        UIContextualAction *share = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:nil handler:^(UIContextualAction *action, UIView *sourceView, void (^completion)(BOOL)) {
            [self shareItems:@[track.url] from:sourceView];
            completion(YES);
        }];
        share.image = [UIImage systemImageNamed:@"square.and.arrow.up"];
        share.backgroundColor = [UIColor systemBlueColor];

        UIContextualAction *rename = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:nil handler:^(UIContextualAction *action, UIView *sourceView, void (^completion)(BOOL)) {
            [self renameSong:track];
            completion(YES);
        }];
        rename.image = [UIImage systemImageNamed:@"pencil"];
        rename.backgroundColor = [UIColor systemOrangeColor];

        UIContextualAction *delete = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:nil handler:^(UIContextualAction *action, UIView *sourceView, void (^completion)(BOOL)) {
            [self confirmDeleteURL:track.url name:track.url.lastPathComponent.stringByDeletingPathExtension extraURL:pngURL];
            completion(YES);
        }];
        delete.image = [UIImage systemImageNamed:@"trash"];

        UISwipeActionsConfiguration *configuration = [UISwipeActionsConfiguration configurationWithActions:@[delete, rename, share]];
        configuration.performsFirstActionWithFullSwipe = YES;
        return configuration;
    }
    return nil;
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

- (void)shareAll:(UIView *)source {
    NSMutableArray<NSURL *> *files = [NSMutableArray array];
    for (YTMUCollection *collection in self.collections)
        [files addObjectsFromArray:collection.files];
    for (YTMUOfflineTrack *song in self.songs)
        [files addObject:song.url];
    [self shareItems:files from:source];
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

- (void)removeAll {
    NSURL *root = [self rootFolder];
    YTAlertView *alertView = [NSClassFromString(@"YTAlertView") confirmationDialogWithAction:^{
        [[YTMUOfflinePlayer shared] stop];
        [[NSFileManager defaultManager] removeItemAtURL:root error:nil];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self reloadData];
        });
    } actionTitle:LOC(@"DELETE")];
    alertView.title = @"YTMusicUltimate";
    alertView.subtitle = [NSString stringWithFormat:LOC(@"DELETE_MESSAGE"), LOC(@"ALL_DOWNLOADS")];
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
