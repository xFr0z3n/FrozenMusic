#import "YTMUHistory.h"
#import "YTMUActionSheet.h"

static NSString *const YTMUHistoryKey = @"YTMUPlayHistory";

// "Song.m4a" or "Playlist/1. Song.m4a" - whatever comes after Documents/YTMusicUltimate/.
// (File URLs can start with /private/var or /var: comparing whole paths missed every song.)
static NSString *YTMURelativePath(NSURL *url) {
    NSString *path = url.path;
    NSRange root = [path rangeOfString:@"/Documents/YTMusicUltimate/" options:NSBackwardsSearch];
    if (root.location == NSNotFound)
        return nil;
    NSString *relative = [path substringFromIndex:NSMaxRange(root)];
    return relative.length ? relative : nil;
}

static NSArray<NSDictionary *> *YTMUHistoryEntries(void) {
    NSArray *entries = [[NSUserDefaults standardUserDefaults] arrayForKey:YTMUHistoryKey];
    return [entries isKindOfClass:[NSArray class]] ? entries : @[];
}

void YTMURemoveFromHistory(NSURL *url) {
    NSString *relative = YTMURelativePath(url);
    if (!relative)
        return;
    NSMutableArray *entries = [YTMUHistoryEntries() mutableCopy];
    for (NSDictionary *entry in [entries copy]) {
        if ([entry[@"path"] isEqual:relative])
            [entries removeObject:entry];
    }
    [[NSUserDefaults standardUserDefaults] setObject:entries forKey:YTMUHistoryKey];
}

void YTMURecordHistory(NSURL *url, BOOL isCollection) {
    NSString *relative = YTMURelativePath(url);
    if (!relative)
        return;
    NSMutableArray *entries = [YTMUHistoryEntries() mutableCopy];
    for (NSDictionary *entry in [entries copy]) {
        if ([entry[@"path"] isEqual:relative])
            [entries removeObject:entry];
    }
    [entries insertObject:@{@"path": relative, @"collection": @(isCollection), @"date": [NSDate date]} atIndex:0];
    while (entries.count > 300)
        [entries removeLastObject];
    [[NSUserDefaults standardUserDefaults] setObject:entries forKey:YTMUHistoryKey];
}

#pragma mark - Screen

@interface YTMUHistoryViewController () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) NSURL *root;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UILabel *emptyLabel;
@property (nonatomic, strong) NSArray<NSString *> *sectionTitles;
@property (nonatomic, strong) NSArray<NSArray *> *sections; // YTMUOfflineTrack / YTMUCollection
@end

@implementation YTMUHistoryViewController

- (instancetype)initWithRoot:(NSURL *)root {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _root = root;
        _sectionTitles = @[];
        _sections = @[];
    }
    return self;
}

- (UIStatusBarStyle)preferredStatusBarStyle {
    return UIStatusBarStyleLightContent;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = YTMUBackgroundColor();

    UIButton *back = [UIButton buttonWithType:UIButtonTypeSystem];
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:20 weight:UIImageSymbolWeightRegular];
    [back setImage:[UIImage systemImageNamed:@"chevron.left" withConfiguration:config] forState:UIControlStateNormal];
    back.tintColor = [UIColor whiteColor];
    back.translatesAutoresizingMaskIntoConstraints = NO;
    [back addTarget:self action:@selector(close) forControlEvents:UIControlEventTouchUpInside];

    UILabel *title = [UILabel new];
    title.text = @"History";
    title.font = [UIFont systemFontOfSize:24 weight:UIFontWeightMedium];
    title.textColor = [UIColor whiteColor];
    title.translatesAutoresizingMaskIntoConstraints = NO;

    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.tableView.backgroundColor = [UIColor clearColor];
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 64;
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    if (@available(iOS 15.0, *))
        self.tableView.sectionHeaderTopPadding = 0;
    [self.tableView registerClass:[YTMUTrackCell class] forCellReuseIdentifier:@"track"];
    [self.tableView registerClass:[YTMUCollectionCell class] forCellReuseIdentifier:@"collection"];

    self.emptyLabel = [UILabel new];
    self.emptyLabel.text = @"Nothing played yet";
    self.emptyLabel.font = [UIFont systemFontOfSize:17];
    self.emptyLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.7];
    self.emptyLabel.hidden = YES;
    self.emptyLabel.translatesAutoresizingMaskIntoConstraints = NO;

    [self.view addSubview:self.tableView];
    [self.view addSubview:back];
    [self.view addSubview:title];
    [self.view addSubview:self.emptyLabel];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [back.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:8],
        [back.topAnchor constraintEqualToAnchor:safe.topAnchor constant:4],
        [back.widthAnchor constraintEqualToConstant:44],
        [back.heightAnchor constraintEqualToConstant:44],
        [title.leadingAnchor constraintEqualToAnchor:back.trailingAnchor constant:14],
        [title.centerYAnchor constraintEqualToAnchor:back.centerYAnchor],

        [self.tableView.topAnchor constraintEqualToAnchor:back.bottomAnchor constant:8],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

        [self.emptyLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.emptyLabel.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor]
    ]];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(playerChanged) name:YTMUOfflinePlayerDidChangeNotification object:nil];
    [self reload];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)close {
    [self dismissViewControllerAnimated:YTMUAnimations() completion:nil];
}

- (void)playerChanged {
    [self.tableView reloadData];
}

#pragma mark Data

- (void)reload {
    NSURL *root = self.root;
    NSArray<NSDictionary *> *entries = YTMUHistoryEntries();
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray<YTMUCollection *> *collections = [YTMUCollection collectionsInFolder:root];
        NSCalendar *calendar = [NSCalendar currentCalendar];
        NSDate *now = [NSDate date];
        NSDate *today = [calendar startOfDayForDate:now];
        NSDate *yesterday = [calendar dateByAddingUnit:NSCalendarUnitDay value:-1 toDate:today options:0];
        NSDate *thisWeek = nil, *lastWeek = nil;
        NSTimeInterval weekLength = 0;
        [calendar rangeOfUnit:NSCalendarUnitWeekOfYear startDate:&thisWeek interval:&weekLength forDate:now];
        lastWeek = [thisWeek dateByAddingTimeInterval:-weekLength];

        NSArray<NSString *> *titles = @[@"Today", @"Yesterday", @"This week", @"Last week", @"Earlier"];
        NSMutableArray<NSMutableArray *> *buckets = [NSMutableArray array];
        for (NSUInteger i = 0; i < titles.count; i++)
            [buckets addObject:[NSMutableArray array]];

        for (NSDictionary *entry in entries) {
            NSString *relative = entry[@"path"];
            NSDate *date = entry[@"date"];
            if (![relative isKindOfClass:[NSString class]] || ![date isKindOfClass:[NSDate class]])
                continue;
            NSURL *url = [root URLByAppendingPathComponent:relative];
            if (![[NSFileManager defaultManager] fileExistsAtPath:url.path])
                continue; // deleted meanwhile

            id item = nil;
            if ([entry[@"collection"] boolValue]) {
                for (YTMUCollection *collection in collections) {
                    if ([collection.folder.path isEqualToString:url.path]) {
                        item = collection;
                        break;
                    }
                }
            } else {
                item = [YTMUOfflineTrack lightTrackWithURL:url];
            }
            if (!item)
                continue;

            NSUInteger bucket = 4;
            if ([date compare:today] != NSOrderedAscending)
                bucket = 0;
            else if ([date compare:yesterday] != NSOrderedAscending)
                bucket = 1;
            else if (thisWeek && [date compare:thisWeek] != NSOrderedAscending)
                bucket = 2;
            else if (lastWeek && [date compare:lastWeek] != NSOrderedAscending)
                bucket = 3;
            [buckets[bucket] addObject:item];
        }

        NSMutableArray<NSString *> *sectionTitles = [NSMutableArray array];
        NSMutableArray<NSArray *> *sections = [NSMutableArray array];
        for (NSUInteger i = 0; i < titles.count; i++) {
            if (buckets[i].count) {
                [sectionTitles addObject:titles[i]];
                [sections addObject:buckets[i]];
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            self.sectionTitles = sectionTitles;
            self.sections = sections;
            self.emptyLabel.hidden = sections.count > 0;
            [self.tableView reloadData];
        });
    });
}

#pragma mark Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return (NSInteger)self.sections.count;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)self.sections[(NSUInteger)section].count;
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    UIView *header = [UIView new];
    header.backgroundColor = self.view.backgroundColor;
    UILabel *label = [UILabel new];
    label.text = self.sectionTitles[(NSUInteger)section];
    label.font = [UIFont systemFontOfSize:26 weight:UIFontWeightBold];
    label.textColor = [UIColor whiteColor];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [header addSubview:label];
    [NSLayoutConstraint activateConstraints:@[
        [label.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:16],
        [label.topAnchor constraintEqualToAnchor:header.topAnchor constant:18],
        [label.bottomAnchor constraintEqualToAnchor:header.bottomAnchor constant:-10]
    ]];
    return header;
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    return UITableViewAutomaticDimension;
}

- (CGFloat)tableView:(UITableView *)tableView estimatedHeightForHeaderInSection:(NSInteger)section {
    return 60;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    __weak __typeof(self) weakSelf = self;
    id item = self.sections[(NSUInteger)indexPath.section][(NSUInteger)indexPath.row];
    if ([item isKindOfClass:[YTMUOfflineTrack class]]) {
        YTMUOfflineTrack *track = item;
        YTMUTrackCell *cell = [tableView dequeueReusableCellWithIdentifier:@"track" forIndexPath:indexPath];
        YTMUOfflinePlayer *player = [YTMUOfflinePlayer shared];
        [cell configureWithTrack:track isCurrent:[player.currentTrack.url isEqual:track.url] isPlaying:player.isPlaying];
        [cell setSubtitleText:track.artist.length ? [@"Song • " stringByAppendingString:track.artist] : @"Song"];
        cell.onMenu = ^(UIButton *sender) {
            [weakSelf showMenuForTrack:track from:sender];
        };
        return cell;
    }
    YTMUCollection *collection = item;
    YTMUCollectionCell *cell = [tableView dequeueReusableCellWithIdentifier:@"collection" forIndexPath:indexPath];
    [cell configureWithCollection:collection];
    cell.onMenu = ^(UIButton *sender) {
        YTMUShowCollectionMenu(collection, weakSelf, sender, ^{
            [weakSelf somethingDeleted];
        });
    };
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    id item = self.sections[(NSUInteger)indexPath.section][(NSUInteger)indexPath.row];
    if ([item isKindOfClass:[YTMUOfflineTrack class]]) {
        [[YTMUOfflinePlayer shared] playTracks:@[item] startIndex:0 shuffle:NO];
        YTMUNowPlayingViewController *nowPlaying = [YTMUNowPlayingViewController new];
        nowPlaying.modalPresentationStyle = UIModalPresentationFullScreen;
        [self presentViewController:nowPlaying animated:YTMUAnimations() completion:nil];
    } else {
        YTMUCollectionViewController *page = [[YTMUCollectionViewController alloc] initWithCollection:item];
        page.modalPresentationStyle = UIModalPresentationFullScreen;
        __weak __typeof(self) weakSelf = self;
        page.onChange = ^{
            [weakSelf somethingDeleted];
        };
        [self presentViewController:page animated:YTMUAnimations() completion:^{
            [weakSelf reload]; // it moved to the top
        }];
    }
}

- (void)somethingDeleted {
    if (self.onChange)
        self.onChange();
    [self reload];
}

- (void)showMenuForTrack:(YTMUOfflineTrack *)track from:(UIButton *)sender {
    __weak __typeof(self) weakSelf = self;
    YTMUSheetAction *remove = [YTMUSheetAction actionWithTitle:@"Remove from history" symbol:@"ytmu.trash" handler:^{
        YTMURemoveFromHistory(track.url);
        [weakSelf reload];
    }];
    YTMUShowSongMenu(track, self, @[remove], nil);
}

@end
