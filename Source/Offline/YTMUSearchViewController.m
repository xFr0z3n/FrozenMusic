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

typedef NS_ENUM(NSInteger, YTMUSearchSection) {
    YTMUSearchSectionSongs = 0,
    YTMUSearchSectionCollections,
    YTMUSearchSectionPeople,
    YTMUSearchSectionCount
};

@interface YTMUSearchViewController () <UITableViewDataSource, UITableViewDelegate, UITextFieldDelegate>
@property (nonatomic, strong) NSURL *root;
@property (nonatomic, strong) NSArray<YTMUCollection *> *collections;
@property (nonatomic, strong) NSArray<YTMUOfflineTrack *> *library;
@property (nonatomic, strong) NSArray<YTMUCollection *> *people;
@property (nonatomic, strong) NSArray<NSString *> *history;
@property (nonatomic, strong) NSArray<YTMUOfflineTrack *> *songResults;
@property (nonatomic, strong) NSArray<YTMUCollection *> *collectionResults;
@property (nonatomic, strong) NSArray<YTMUCollection *> *peopleResults;
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
        _people = @[];
        _songResults = @[];
        _collectionResults = @[];
        _peopleResults = @[];
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

    [self.view addSubview:self.tableView];
    [self.view addSubview:bar];
    [self.view addSubview:self.emptyLabel];

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

        [self.tableView.topAnchor constraintEqualToAnchor:bar.bottomAnchor constant:6],
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
        NSMutableArray<YTMUCollection *> *people = [[YTMUCollection artistsFromCollections:collections library:library] mutableCopy];
        [people addObjectsFromArray:[YTMUCollection creatorsFromCollections:collections]];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.library = library;
            self.people = people;
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
        [self.tableView reloadData];
        return;
    }

    NSArray<NSString *> *words = [[YTMUFold(self.field.text) componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]];

    NSMutableArray<YTMUOfflineTrack *> *songs = [NSMutableArray array];
    for (YTMUOfflineTrack *track in self.library) {
        NSString *text = [NSString stringWithFormat:@"%@ %@ %@", track.title ?: @"", track.artist ?: @"", track.album ?: @""];
        if (YTMUMatches(text, words))
            [songs addObject:track];
    }
    NSMutableArray<YTMUCollection *> *collections = [NSMutableArray array];
    for (YTMUCollection *collection in self.collections) {
        NSString *text = [NSString stringWithFormat:@"%@ %@", collection.name ?: @"", collection.isAlbum ? (collection.artist ?: @"") : @""];
        if (YTMUMatches(text, words))
            [collections addObject:collection];
    }
    NSMutableArray<YTMUCollection *> *people = [NSMutableArray array];
    for (YTMUCollection *person in self.people) {
        if (YTMUMatches(person.name, words))
            [people addObject:person];
    }

    self.songResults = songs;
    self.collectionResults = collections;
    self.peopleResults = people;
    // Library still loading counts as "not found yet" only once it's there
    self.emptyLabel.hidden = !self.library || songs.count + collections.count + people.count > 0;
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
    switch (section) {
        case YTMUSearchSectionSongs:
            return self.songResults;
        case YTMUSearchSectionCollections:
            return self.collectionResults;
        case YTMUSearchSectionPeople:
            return self.peopleResults;
        default:
            return @[];
    }
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)[self itemsInSection:section].count;
}

- (NSString *)titleForSection:(NSInteger)section {
    if (!self.isSearching || [self itemsInSection:section].count == 0)
        return nil;
    return @[@"Songs", @"Playlists & albums", @"Artists & creators"][(NSUInteger)section];
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    NSString *title = [self titleForSection:section];
    if (!title)
        return nil;
    UIView *header = [UIView new];
    header.backgroundColor = self.view.backgroundColor;
    UILabel *label = [UILabel new];
    label.text = title;
    label.font = [UIFont systemFontOfSize:20 weight:UIFontWeightBold];
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
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:track.title message:track.artist preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Share" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        UIActivityViewController *activity = [[UIActivityViewController alloc] initWithActivityItems:@[track.url] applicationActivities:nil];
        activity.popoverPresentationController.sourceView = sender;
        activity.popoverPresentationController.sourceRect = sender.bounds;
        [self presentViewController:activity animated:YES completion:nil];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Open song" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        YTMUOpenInFiles([track.url URLByDeletingLastPathComponent]);
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = sender;
    sheet.popoverPresentationController.sourceRect = sender.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
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
