#import "YTMUSearchViewController.h"

static NSString *const YTMUSearchHistoryKey = @"YTMUSearchHistory";

#pragma mark - History storage

static NSArray<NSString *> *YTMUSearchHistory(void) {
    NSArray *history = [[NSUserDefaults standardUserDefaults] arrayForKey:YTMUSearchHistoryKey];
    return [history isKindOfClass:[NSArray class]] ? history : @[];
}

static void YTMUSaveSearchHistory(NSArray<NSString *> *history) {
    [[NSUserDefaults standardUserDefaults] setObject:history forKey:YTMUSearchHistoryKey];
}

// Newest first, no duplicates, 50 max
static void YTMUAddToSearchHistory(NSString *query) {
    NSString *trimmed = [query stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0)
        return;
    NSMutableArray<NSString *> *history = [YTMUSearchHistory() mutableCopy];
    for (NSString *old in [history copy]) {
        if ([old caseInsensitiveCompare:trimmed] == NSOrderedSame)
            [history removeObject:old];
    }
    [history insertObject:trimmed atIndex:0];
    while (history.count > 50)
        [history removeLastObject];
    YTMUSaveSearchHistory(history);
}

static NSString *YTMUFold(NSString *text) {
    return [text ?: @"" stringByFoldingWithOptions:NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch locale:nil];
}

// Every word of the query appears somewhere in the text
static BOOL YTMUMatches(NSString *text, NSArray<NSString *> *words) {
    NSString *folded = YTMUFold(text);
    for (NSString *word in words) {
        if (word.length && ![folded containsString:word])
            return NO;
    }
    return YES;
}

#pragma mark - History row

@interface YTMUHistoryCell : UITableViewCell
@property (nonatomic, strong) UILabel *queryLabel;
@property (nonatomic, strong) UIButton *fillButton;
@property (nonatomic, copy) void (^onFill)(void);
@end

@implementation YTMUHistoryCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (!self)
        return nil;
    self.backgroundColor = [UIColor clearColor];
    UIView *selected = [UIView new];
    selected.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.08];
    self.selectedBackgroundView = selected;

    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:21 weight:UIImageSymbolWeightMedium];
    UIImageView *clock = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"clock.arrow.circlepath" withConfiguration:config]];
    clock.tintColor = [UIColor whiteColor];
    clock.contentMode = UIViewContentModeCenter;
    clock.translatesAutoresizingMaskIntoConstraints = NO;

    self.queryLabel = [UILabel new];
    self.queryLabel.font = [UIFont systemFontOfSize:17];
    self.queryLabel.textColor = [UIColor whiteColor];
    self.queryLabel.translatesAutoresizingMaskIntoConstraints = NO;

    // ↖ puts the search into the field without running it
    self.fillButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.fillButton setImage:[UIImage systemImageNamed:@"arrow.up.left" withConfiguration:config] forState:UIControlStateNormal];
    self.fillButton.tintColor = [UIColor whiteColor];
    self.fillButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.fillButton addTarget:self action:@selector(fillTapped) forControlEvents:UIControlEventTouchUpInside];

    [self.contentView addSubview:clock];
    [self.contentView addSubview:self.queryLabel];
    [self.contentView addSubview:self.fillButton];
    [NSLayoutConstraint activateConstraints:@[
        [clock.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:20],
        [clock.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
        [clock.widthAnchor constraintEqualToConstant:30],

        [self.queryLabel.leadingAnchor constraintEqualToAnchor:clock.trailingAnchor constant:22],
        [self.queryLabel.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
        [self.queryLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.fillButton.leadingAnchor constant:-8],

        [self.fillButton.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-10],
        [self.fillButton.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
        [self.fillButton.widthAnchor constraintEqualToConstant:44],
        [self.fillButton.heightAnchor constraintEqualToConstant:44],
        [self.contentView.heightAnchor constraintGreaterThanOrEqualToConstant:48]
    ]];
    return self;
}

- (void)fillTapped {
    if (self.onFill)
        self.onFill();
}

@end

#pragma mark - Search screen

// Same order as YTM: artists, albums, songs (then playlists and their creators)
typedef NS_ENUM(NSInteger, YTMUSearchSection) {
    YTMUSearchSectionArtists = 0,
    YTMUSearchSectionAlbums,
    YTMUSearchSectionSongs,
    YTMUSearchSectionPlaylists,
    YTMUSearchSectionCreators,
    YTMUSearchSectionCount
};

@interface YTMUSearchViewController () <UITableViewDataSource, UITableViewDelegate, UITextFieldDelegate>
@property (nonatomic, strong) NSURL *root;
@property (nonatomic, strong) NSArray<YTMUCollection *> *collections;
@property (nonatomic, strong) NSArray<YTMUOfflineTrack *> *library;
@property (nonatomic, strong) NSArray<YTMUCollection *> *artists;
@property (nonatomic, strong) NSArray<YTMUCollection *> *creators;
@property (nonatomic, strong) NSArray<NSString *> *history;
@property (nonatomic, strong) NSArray<NSArray *> *results; // one array per YTMUSearchSection
@property (nonatomic) NSInteger chipSection;              // -1 = all
@property (nonatomic, strong) UIScrollView *chipBar;
@property (nonatomic, strong) NSLayoutConstraint *chipBarHeight;
@property (nonatomic, strong) UITextField *field;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UILabel *emptyLabel;
@property (nonatomic, strong) UIView *confirmOverlay;
@end

@implementation YTMUSearchViewController

- (instancetype)initWithRoot:(NSURL *)root collections:(NSArray<YTMUCollection *> *)collections library:(NSArray<YTMUOfflineTrack *> *)library {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _root = root;
        _collections = collections ?: @[];
        _library = library;
        _artists = @[];
        _creators = @[];
        _results = @[@[], @[], @[], @[], @[]];
        _chipSection = -1;
    }
    return self;
}

- (UIStatusBarStyle)preferredStatusBarStyle {
    return UIStatusBarStyleLightContent;
}

- (BOOL)isSearching {
    return [self.field.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]].length > 0;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = YTMUBackgroundColor();
    self.history = YTMUSearchHistory();

    // Rounded search bar with the back arrow inside, like YTM
    UIView *bar = [UIView new];
    bar.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.13];
    bar.layer.cornerRadius = 24;
    bar.translatesAutoresizingMaskIntoConstraints = NO;

    UIButton *back = [UIButton buttonWithType:UIButtonTypeSystem];
    UIImageSymbolConfiguration *backConfig = [UIImageSymbolConfiguration configurationWithPointSize:19 weight:UIImageSymbolWeightSemibold];
    [back setImage:[UIImage systemImageNamed:@"chevron.left" withConfiguration:backConfig] forState:UIControlStateNormal];
    back.tintColor = [UIColor whiteColor];
    back.translatesAutoresizingMaskIntoConstraints = NO;
    [back addTarget:self action:@selector(close) forControlEvents:UIControlEventTouchUpInside];

    self.field = [UITextField new];
    self.field.font = [UIFont systemFontOfSize:18];
    self.field.textColor = [UIColor whiteColor];
    self.field.tintColor = [UIColor whiteColor];
    self.field.attributedPlaceholder = [[NSAttributedString alloc] initWithString:@"Search in library" attributes:@{NSForegroundColorAttributeName: [UIColor colorWithWhite:1.0 alpha:0.55]}];
    self.field.returnKeyType = UIReturnKeySearch;
    self.field.autocorrectionType = UITextAutocorrectionTypeNo;
    self.field.clearButtonMode = UITextFieldViewModeWhileEditing;
    self.field.keyboardAppearance = UIKeyboardAppearanceDark;
    self.field.delegate = self;
    self.field.translatesAutoresizingMaskIntoConstraints = NO;
    [self.field addTarget:self action:@selector(textChanged) forControlEvents:UIControlEventEditingChanged];

    [bar addSubview:back];
    [bar addSubview:self.field];

    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.tableView.backgroundColor = [UIColor clearColor];
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 56;
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    if (@available(iOS 15.0, *))
        self.tableView.sectionHeaderTopPadding = 0;
    [self.tableView registerClass:[YTMUHistoryCell class] forCellReuseIdentifier:@"history"];
    [self.tableView registerClass:[YTMUTrackCell class] forCellReuseIdentifier:@"track"];
    [self.tableView registerClass:[YTMUCollectionCell class] forCellReuseIdentifier:@"collection"];
    UILongPressGestureRecognizer *hold = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(historyHeld:)];
    [self.tableView addGestureRecognizer:hold];

    self.emptyLabel = [UILabel new];
    self.emptyLabel.text = @"No results in your library";
    self.emptyLabel.font = [UIFont systemFontOfSize:17];
    self.emptyLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.7];
    self.emptyLabel.textAlignment = NSTextAlignmentCenter;
    self.emptyLabel.hidden = YES;
    self.emptyLabel.translatesAutoresizingMaskIntoConstraints = NO;

    // Result chips (Artists, Albums, Songs, ...) like YTM
    self.chipBar = [UIScrollView new];
    self.chipBar.showsHorizontalScrollIndicator = NO;
    self.chipBar.translatesAutoresizingMaskIntoConstraints = NO;

    [self.view addSubview:self.tableView];
    [self.view addSubview:bar];
    [self.view addSubview:self.chipBar];
    [self.view addSubview:self.emptyLabel];
    self.chipBarHeight = [self.chipBar.heightAnchor constraintEqualToConstant:0];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [bar.topAnchor constraintEqualToAnchor:safe.topAnchor constant:6],
        [bar.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [bar.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
        [bar.heightAnchor constraintEqualToConstant:48],

        [back.leadingAnchor constraintEqualToAnchor:bar.leadingAnchor constant:8],
        [back.centerYAnchor constraintEqualToAnchor:bar.centerYAnchor],
        [back.widthAnchor constraintEqualToConstant:40],
        [back.heightAnchor constraintEqualToConstant:40],

        [self.field.leadingAnchor constraintEqualToAnchor:back.trailingAnchor constant:8],
        [self.field.trailingAnchor constraintEqualToAnchor:bar.trailingAnchor constant:-12],
        [self.field.topAnchor constraintEqualToAnchor:bar.topAnchor],
        [self.field.bottomAnchor constraintEqualToAnchor:bar.bottomAnchor],

        [self.chipBar.topAnchor constraintEqualToAnchor:bar.bottomAnchor constant:8],
        [self.chipBar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.chipBar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        self.chipBarHeight,

        [self.tableView.topAnchor constraintEqualToAnchor:self.chipBar.bottomAnchor constant:2],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

        [self.emptyLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.emptyLabel.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [self.emptyLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.view.leadingAnchor constant:24]
    ]];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(playerChanged) name:YTMUOfflinePlayerDidChangeNotification object:nil];
    [self loadLibrary];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (!self.isSearching && !self.presentedViewController)
        [self.field becomeFirstResponder];
}

- (void)close {
    [self.field resignFirstResponder];
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)playerChanged {
    if (self.isSearching)
        [self.tableView reloadData];
}

#pragma mark Data

- (void)loadLibrary {
    NSArray<YTMUCollection *> *collections = self.collections;
    NSArray<YTMUOfflineTrack *> *known = self.library;
    NSURL *root = self.root;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray<YTMUOfflineTrack *> *library = known ?: [YTMUCollection libraryTracksInFolder:root collections:collections];
        NSArray<YTMUCollection *> *artists = [YTMUCollection artistsFromCollections:collections library:library];
        NSArray<YTMUCollection *> *creators = [YTMUCollection creatorsFromCollections:collections];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.library = library;
            self.artists = artists;
            self.creators = creators;
            [self updateResults];
        });
    });
}

- (void)textChanged {
    [self updateResults];
}

- (void)updateResults {
    if (!self.isSearching) {
        self.history = YTMUSearchHistory();
        self.emptyLabel.hidden = YES;
        self.chipSection = -1;
        [self rebuildChips];
        [self.tableView reloadData];
        return;
    }

    NSArray<NSString *> *words = [[YTMUFold(self.field.text) componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]];

    NSMutableArray<YTMUOfflineTrack *> *songs = [NSMutableArray array];
    NSMutableSet<NSString *> *songPaths = [NSMutableSet set];
    for (YTMUOfflineTrack *track in self.library) {
        NSString *text = [NSString stringWithFormat:@"%@ %@ %@", track.title ?: @"", track.artist ?: @"", track.album ?: @""];
        if (YTMUMatches(text, words) && ![songPaths containsObject:track.url.path]) {
            [songs addObject:track];
            [songPaths addObject:track.url.path];
        }
    }
    // Name matches, or it holds one of the songs found ("blind spot" -> C418, his album)
    BOOL (^holdsSong)(YTMUCollection *) = ^BOOL(YTMUCollection *collection) {
        for (NSURL *file in collection.files) {
            if ([songPaths containsObject:file.path])
                return YES;
        }
        return NO;
    };
    NSMutableArray<YTMUCollection *> *artists = [NSMutableArray array];
    for (YTMUCollection *artist in self.artists) {
        if (YTMUMatches(artist.name, words) || holdsSong(artist))
            [artists addObject:artist];
    }
    NSMutableArray<YTMUCollection *> *albums = [NSMutableArray array];
    NSMutableArray<YTMUCollection *> *playlists = [NSMutableArray array];
    for (YTMUCollection *collection in self.collections) {
        NSString *text = [NSString stringWithFormat:@"%@ %@", collection.name ?: @"", collection.isAlbum ? (collection.artist ?: @"") : @""];
        if (YTMUMatches(text, words) || holdsSong(collection))
            [(collection.isAlbum ? albums : playlists) addObject:collection];
    }
    NSMutableArray<YTMUCollection *> *creators = [NSMutableArray array];
    for (YTMUCollection *creator in self.creators) {
        if (YTMUMatches(creator.name, words) || holdsSong(creator))
            [creators addObject:creator];
    }

    self.results = @[artists, albums, songs, playlists, creators];
    NSUInteger total = artists.count + albums.count + songs.count + playlists.count + creators.count;
    if (self.chipSection >= 0 && [self.results[(NSUInteger)self.chipSection] count] == 0)
        self.chipSection = -1;
    // Library still loading counts as "not found yet" only once it's there
    self.emptyLabel.hidden = !self.library || total > 0;
    [self rebuildChips];
    [self.tableView reloadData];
}

#pragma mark Chips

- (void)rebuildChips {
    for (UIView *view in self.chipBar.subviews)
        [view removeFromSuperview];
    NSArray<NSString *> *titles = @[@"Artists", @"Albums", @"Songs", @"Playlists", @"Creators"];
    CGFloat x = 16;
    if (self.isSearching) {
        for (NSUInteger i = 0; i < titles.count; i++) {
            if ([self.results[i] count] == 0)
                continue;
            BOOL selected = self.chipSection == (NSInteger)i;
            UIButton *chip = [UIButton buttonWithType:UIButtonTypeCustom];
            chip.backgroundColor = selected ? [UIColor colorWithWhite:0.94 alpha:1.0] : [UIColor colorWithWhite:1.0 alpha:0.12];
            chip.layer.cornerRadius = 8;
            [chip setTitle:titles[i] forState:UIControlStateNormal];
            [chip setTitleColor:selected ? [UIColor blackColor] : [UIColor whiteColor] forState:UIControlStateNormal];
            chip.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
            chip.contentEdgeInsets = UIEdgeInsetsMake(0, 12, 0, 12);
            chip.tag = (NSInteger)i;
            [chip addTarget:self action:@selector(chipTapped:) forControlEvents:UIControlEventTouchUpInside];
            [chip sizeToFit];
            chip.frame = CGRectMake(x, 0, chip.bounds.size.width, 34);
            [self.chipBar addSubview:chip];
            x += chip.bounds.size.width + 8;
        }
    }
    self.chipBar.contentSize = CGSizeMake(x + 8, 34);
    self.chipBarHeight.constant = x > 16 ? 34 : 0;
}

- (void)chipTapped:(UIButton *)chip {
    self.chipSection = (self.chipSection == chip.tag) ? -1 : chip.tag;
    [self rebuildChips];
    [self.tableView reloadData];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    YTMUAddToSearchHistory(textField.text);
    [textField resignFirstResponder];
    return YES;
}

#pragma mark Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return self.isSearching ? YTMUSearchSectionCount : 1;
}

- (NSArray *)itemsInSection:(NSInteger)section {
    if (!self.isSearching)
        return self.history;
    if (section < 0 || section >= (NSInteger)self.results.count)
        return @[];
    // A chip shows only its own section
    if (self.chipSection >= 0 && section != self.chipSection)
        return @[];
    return self.results[(NSUInteger)section];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)[self itemsInSection:section].count;
}

- (NSString *)titleForSection:(NSInteger)section {
    if (!self.isSearching || [self itemsInSection:section].count == 0)
        return nil;
    return @[@"Artists", @"Albums", @"Songs", @"Playlists", @"Creators"][(NSUInteger)section];
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    NSString *title = [self titleForSection:section];
    if (!title)
        return nil;
    UIView *header = [UIView new];
    header.backgroundColor = self.view.backgroundColor;
    UILabel *label = [UILabel new];
    label.text = title;
    label.font = [UIFont systemFontOfSize:26 weight:UIFontWeightBold];
    label.textColor = [UIColor whiteColor];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [header addSubview:label];
    [NSLayoutConstraint activateConstraints:@[
        [label.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:16],
        [label.topAnchor constraintEqualToAnchor:header.topAnchor constant:12],
        [label.bottomAnchor constraintEqualToAnchor:header.bottomAnchor constant:-4]
    ]];
    return header;
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    return [self titleForSection:section] ? UITableViewAutomaticDimension : CGFLOAT_MIN;
}

- (CGFloat)tableView:(UITableView *)tableView estimatedHeightForHeaderInSection:(NSInteger)section {
    return [self titleForSection:section] ? 40 : CGFLOAT_MIN;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    __weak __typeof(self) weakSelf = self;
    id item = [self itemsInSection:indexPath.section][(NSUInteger)indexPath.row];

    if (!self.isSearching) {
        NSString *query = item;
        YTMUHistoryCell *cell = [tableView dequeueReusableCellWithIdentifier:@"history" forIndexPath:indexPath];
        cell.queryLabel.text = query;
        cell.onFill = ^{
            weakSelf.field.text = query;
            [weakSelf updateResults];
            [weakSelf.field becomeFirstResponder];
        };
        return cell;
    }

    if ([item isKindOfClass:[YTMUOfflineTrack class]]) {
        YTMUOfflineTrack *track = item;
        YTMUTrackCell *cell = [tableView dequeueReusableCellWithIdentifier:@"track" forIndexPath:indexPath];
        YTMUOfflinePlayer *player = [YTMUOfflinePlayer shared];
        [cell configureWithTrack:track isCurrent:[player.currentTrack.url isEqual:track.url] isPlaying:player.isPlaying];
        // "C418 • Minecraft - Volume Beta" like YTM's search
        NSMutableArray<NSString *> *parts = [NSMutableArray array];
        if (track.artist.length)
            [parts addObject:track.artist];
        if (track.album.length)
            [parts addObject:track.album];
        if (parts.count)
            [cell setSubtitleText:[parts componentsJoinedByString:@" • "]];
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
    NSArray *items = [self itemsInSection:indexPath.section];
    id item = items[(NSUInteger)indexPath.row];

    if (!self.isSearching) {
        self.field.text = item;
        YTMUAddToSearchHistory(item);
        [self updateResults];
        [self.field resignFirstResponder];
        return;
    }

    YTMUAddToSearchHistory(self.field.text);
    [self.field resignFirstResponder];
    if ([item isKindOfClass:[YTMUOfflineTrack class]]) {
        [[YTMUOfflinePlayer shared] playTracks:items startIndex:indexPath.row shuffle:NO];
        YTMUNowPlayingViewController *nowPlaying = [YTMUNowPlayingViewController new];
        nowPlaying.modalPresentationStyle = UIModalPresentationFullScreen;
        [self presentViewController:nowPlaying animated:YES completion:nil];
    } else {
        YTMUCollectionViewController *page = [[YTMUCollectionViewController alloc] initWithCollection:item];
        page.modalPresentationStyle = UIModalPresentationFullScreen;
        __weak __typeof(self) weakSelf = self;
        page.onChange = ^{
            [weakSelf somethingDeleted];
        };
        [self presentViewController:page animated:YES completion:nil];
    }
}

- (void)somethingDeleted {
    if (self.onChange)
        self.onChange();
    self.collections = [YTMUCollection collectionsInFolder:self.root];
    self.library = nil;
    [self loadLibrary];
}

#pragma mark Song menu

- (void)showMenuForTrack:(YTMUOfflineTrack *)track from:(UIButton *)sender {
    YTMUShowSongMenu(track, self, @[], nil);
}

#pragma mark Remove from history (hold)

- (void)historyHeld:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan || self.isSearching)
        return;
    NSIndexPath *indexPath = [self.tableView indexPathForRowAtPoint:[gesture locationInView:self.tableView]];
    if (!indexPath || (NSUInteger)indexPath.row >= self.history.count)
        return;
    [self.field resignFirstResponder];
    [self confirmRemoveQuery:self.history[(NSUInteger)indexPath.row]];
}

// YTM-style box: dark grey, or pure black with the OLED theme
- (void)confirmRemoveQuery:(NSString *)query {
    [self.confirmOverlay removeFromSuperview];

    UIView *overlay = [[UIView alloc] initWithFrame:self.view.bounds];
    overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    overlay.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.5];

    UIView *box = [UIView new];
    BOOL oled = YTMUIsOLED();
    box.backgroundColor = oled ? [UIColor blackColor] : [UIColor colorWithRed:0.165 green:0.165 blue:0.165 alpha:1.0];
    box.layer.cornerRadius = 4;
    if (oled) {
        box.layer.borderWidth = 1.0;
        box.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.15].CGColor;
    }
    box.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *title = [UILabel new];
    title.text = query;
    title.font = [UIFont systemFontOfSize:22 weight:UIFontWeightMedium];
    title.textColor = [UIColor whiteColor];
    title.numberOfLines = 2;
    title.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *message = [UILabel new];
    message.text = @"Remove from search history?";
    message.font = [UIFont systemFontOfSize:16];
    message.textColor = [UIColor colorWithWhite:1.0 alpha:0.7];
    message.numberOfLines = 0;
    message.translatesAutoresizingMaskIntoConstraints = NO;

    UIButton *cancel = [UIButton buttonWithType:UIButtonTypeSystem];
    [cancel setTitle:@"Cancel" forState:UIControlStateNormal];
    UIButton *remove = [UIButton buttonWithType:UIButtonTypeSystem];
    [remove setTitle:@"Remove" forState:UIControlStateNormal];
    for (UIButton *button in @[cancel, remove]) {
        [button setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        button.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightMedium];
        button.translatesAutoresizingMaskIntoConstraints = NO;
    }
    [cancel addTarget:self action:@selector(dismissConfirm) forControlEvents:UIControlEventTouchUpInside];
    [remove addTarget:self action:@selector(removeConfirmed:) forControlEvents:UIControlEventTouchUpInside];
    remove.accessibilityValue = query;

    [overlay addSubview:box];
    for (UIView *view in @[title, message, cancel, remove])
        [box addSubview:view];

    [NSLayoutConstraint activateConstraints:@[
        [box.centerXAnchor constraintEqualToAnchor:overlay.centerXAnchor],
        [box.centerYAnchor constraintEqualToAnchor:overlay.centerYAnchor],
        [box.widthAnchor constraintEqualToConstant:MIN(self.view.bounds.size.width - 52, 340)],

        [title.topAnchor constraintEqualToAnchor:box.topAnchor constant:24],
        [title.leadingAnchor constraintEqualToAnchor:box.leadingAnchor constant:24],
        [title.trailingAnchor constraintEqualToAnchor:box.trailingAnchor constant:-24],

        [message.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:14],
        [message.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],
        [message.trailingAnchor constraintEqualToAnchor:title.trailingAnchor],

        [remove.topAnchor constraintEqualToAnchor:message.bottomAnchor constant:30],
        [remove.trailingAnchor constraintEqualToAnchor:box.trailingAnchor constant:-24],
        [remove.bottomAnchor constraintEqualToAnchor:box.bottomAnchor constant:-16],
        [cancel.centerYAnchor constraintEqualToAnchor:remove.centerYAnchor],
        [cancel.trailingAnchor constraintEqualToAnchor:remove.leadingAnchor constant:-36]
    ]];

    // Tap outside = cancel
    UIButton *outside = [UIButton buttonWithType:UIButtonTypeCustom];
    outside.frame = overlay.bounds;
    outside.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [outside addTarget:self action:@selector(dismissConfirm) forControlEvents:UIControlEventTouchUpInside];
    [overlay insertSubview:outside atIndex:0];

    overlay.alpha = 0;
    [self.view addSubview:overlay];
    self.confirmOverlay = overlay;
    [UIView animateWithDuration:0.15 animations:^{
        overlay.alpha = 1;
    }];
}

- (void)dismissConfirm {
    UIView *overlay = self.confirmOverlay;
    self.confirmOverlay = nil;
    [UIView animateWithDuration:0.15 animations:^{
        overlay.alpha = 0;
    } completion:^(BOOL finished) {
        [overlay removeFromSuperview];
    }];
}

- (void)removeConfirmed:(UIButton *)sender {
    NSString *query = sender.accessibilityValue;
    NSMutableArray<NSString *> *history = [YTMUSearchHistory() mutableCopy];
    if (query)
        [history removeObject:query];
    YTMUSaveSearchHistory(history);
    [self dismissConfirm];
    [self updateResults];
}

@end
