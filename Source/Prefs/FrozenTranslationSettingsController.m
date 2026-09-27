#import "FrozenTranslationSettingsController.h"
#import "FrozenMusicSettingsController.h"
#import "../Offline/YTMULyrics.h"
#import <objc/message.h>

typedef NS_ENUM(NSInteger, FrozenTranslationSection) {
    FrozenTranslationSectionYours,
    FrozenTranslationSectionDownloaded,
    FrozenTranslationSectionOthers,
    FrozenTranslationSectionCount
};

@interface FrozenTranslationSettingsController ()
@property (nonatomic) Class translator;
@property (nonatomic, copy) NSString *deviceLanguage;
@property (nonatomic, copy) NSArray<NSString *> *downloaded;
@property (nonatomic, copy) NSArray<NSString *> *others;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *progress; // downloading: 0...1
@end

@implementation FrozenTranslationSettingsController

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Offline translation";
    self.translator = YTMUOfflineTranslatorClass();
    self.deviceLanguage = [[YTMULyrics deviceLanguageCode] componentsSeparatedByString:@"-"].firstObject.lowercaseString;
    self.progress = [NSMutableDictionary dictionary];
    [self reloadLanguages];
}

#pragma mark Translator (FrozenMLTranslate.framework)

- (NSArray<NSString *> *)allLanguages {
    SEL selector = NSSelectorFromString(@"allLanguages");
    if (!self.translator || ![self.translator respondsToSelector:selector])
        return @[];
    NSArray *languages = ((NSArray *(*)(id, SEL))objc_msgSend)(self.translator, selector);
    return [languages isKindOfClass:[NSArray class]] ? languages : @[];
}

- (BOOL)isReady:(NSString *)language {
    SEL selector = NSSelectorFromString(@"isModelReady:");
    return self.translator && [self.translator respondsToSelector:selector] &&
           ((BOOL (*)(id, SEL, NSString *))objc_msgSend)(self.translator, selector, language);
}

- (NSString *)nameOf:(NSString *)language {
    NSString *name = [[NSLocale currentLocale] localizedStringForLanguageCode:language];
    return name.length ? [name capitalizedStringWithLocale:[NSLocale currentLocale]] : language;
}

- (void)reloadLanguages {
    NSMutableArray *downloaded = [NSMutableArray array], *others = [NSMutableArray array];
    for (NSString *language in [self allLanguages]) {
        if ([language isEqualToString:self.deviceLanguage])
            continue;
        if ([language isEqualToString:@"en"] || [self isReady:language])
            [downloaded addObject:language];
        else
            [others addObject:language];
    }
    NSComparator byName = ^NSComparisonResult(NSString *a, NSString *b) {
        return [[self nameOf:a] localizedCaseInsensitiveCompare:[self nameOf:b]];
    };
    self.downloaded = [downloaded sortedArrayUsingComparator:byName];
    self.others = [others sortedArrayUsingComparator:byName];
    [self.tableView reloadData];
}

- (NSString *)languageAt:(NSIndexPath *)indexPath {
    switch (indexPath.section) {
        case FrozenTranslationSectionYours: return self.deviceLanguage;
        case FrozenTranslationSectionDownloaded: return self.downloaded[(NSUInteger)indexPath.row];
        default: return self.others[(NSUInteger)indexPath.row];
    }
}

#pragma mark Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return self.translator ? FrozenTranslationSectionCount : 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (!self.translator)
        return 0;
    switch (section) {
        case FrozenTranslationSectionYours: return [[self allLanguages] containsObject:self.deviceLanguage] ? 1 : 0;
        case FrozenTranslationSectionDownloaded: return (NSInteger)self.downloaded.count;
        default: return (NSInteger)self.others.count;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (!self.translator)
        return nil;
    switch (section) {
        case FrozenTranslationSectionYours: return @"Your language";
        case FrozenTranslationSectionDownloaded: return self.downloaded.count ? @"Downloaded" : nil;
        default: return @"Available";
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (!self.translator)
        return @"Offline translation isn't part of this build (only IPAs built with the GitHub Actions workflow have it). Translate still works with internet.";
    if (section == FrozenTranslationSectionYours)
        return @"With internet, Translate in the lyrics uses Google. Without internet it uses the languages downloaded here (about 30 MB each, English is built in). "
               @"Download your language and the languages of the lyrics you want to translate offline.";
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    NSString *language = [self languageAt:indexPath];
    cell.textLabel.text = [self nameOf:language];

    NSNumber *fraction = self.progress[language];
    BOOL builtIn = [language isEqualToString:@"en"];
    BOOL ready = builtIn || [self isReady:language];
    if (fraction) {
        cell.detailTextLabel.text = [NSString stringWithFormat:@"Downloading… %ld%%", (long)lround(fraction.doubleValue * 100)];
        UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
        [spinner startAnimating];
        cell.accessoryView = spinner;
    } else if (builtIn) {
        cell.detailTextLabel.text = @"Built in";
    } else {
        cell.detailTextLabel.text = ready ? @"Downloaded" : @"Not downloaded · about 30 MB";
        UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
        UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:20 weight:UIImageSymbolWeightRegular];
        [button setImage:[UIImage systemImageNamed:ready ? @"trash" : @"icloud.and.arrow.down" withConfiguration:config] forState:UIControlStateNormal];
        button.tintColor = ready ? [UIColor systemRedColor] : FrozenMusicBlue();
        button.frame = CGRectMake(0, 0, 44, 44);
        button.accessibilityIdentifier = language;
        [button addTarget:self action:ready ? @selector(deleteTapped:) : @selector(downloadTapped:) forControlEvents:UIControlEventTouchUpInside];
        cell.accessoryView = button;
    }
    return cell;
}

#pragma mark Download / delete

- (void)downloadTapped:(UIButton *)sender {
    NSString *language = sender.accessibilityIdentifier;
    SEL selector = NSSelectorFromString(@"downloadLanguage:progress:completion:");
    if (!language.length || self.progress[language] || ![self.translator respondsToSelector:selector])
        return;
    self.progress[language] = @0;
    [self.tableView reloadData];
    __weak __typeof(self) weakSelf = self;
    void (^progress)(double) = ^(double fraction) {
        __strong __typeof(weakSelf) self = weakSelf;
        if (!self || !self.progress[language])
            return;
        self.progress[language] = @(fraction);
        [self refreshRowOf:language];
    };
    void (^completion)(NSString *) = ^(NSString *error) {
        __strong __typeof(weakSelf) self = weakSelf;
        if (!self)
            return;
        [self.progress removeObjectForKey:language];
        [self reloadLanguages];
        if (error.length)
            [self showMessage:[NSString stringWithFormat:@"%@ couldn't be downloaded: %@", [self nameOf:language], error]];
    };
    ((void (*)(id, SEL, NSString *, void (^)(double), void (^)(NSString *)))objc_msgSend)(self.translator, selector, language, progress, completion);
}

- (void)deleteTapped:(UIButton *)sender {
    NSString *language = sender.accessibilityIdentifier;
    SEL selector = NSSelectorFromString(@"deleteLanguage:completion:");
    if (!language.length || ![self.translator respondsToSelector:selector])
        return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"Delete %@?", [self nameOf:language]]
                                                                   message:@"Lyrics in this language can then only be translated with internet."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:LOC(@"CANCEL") style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:LOC(@"DELETE") style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        __weak __typeof(self) weakSelf = self;
        ((void (*)(id, SEL, NSString *, void (^)(NSString *)))objc_msgSend)(self.translator, selector, language, ^(NSString *error) {
            [weakSelf reloadLanguages];
            if (error.length)
                [weakSelf showMessage:error];
        });
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)refreshRowOf:(NSString *)language {
    for (NSIndexPath *indexPath in self.tableView.indexPathsForVisibleRows) {
        if ([[self languageAt:indexPath] isEqualToString:language]) {
            UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:indexPath];
            NSNumber *fraction = self.progress[language];
            if (cell && fraction)
                cell.detailTextLabel.text = [NSString stringWithFormat:@"Downloading… %ld%%", (long)lround(fraction.doubleValue * 100)];
        }
    }
}

- (void)showMessage:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Offline translation" message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
