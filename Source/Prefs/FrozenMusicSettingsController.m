#import "FrozenMusicSettingsController.h"
#import "FrozenDiscordSettingsController.h"

// Discord RPC page on top, then the switches, then the links
typedef NS_ENUM(NSInteger, FrozenMusicSection) {
    FrozenMusicSectionDiscord,
    FrozenMusicSectionToggles,
    FrozenMusicSectionLinks,
    FrozenMusicSectionCount
};

static NSString *const FrozenMusicWebsite = @"https://fr0z3n.com";
static NSString *const FrozenMusicRepo = @"https://github.com/xFr0z3n/YTMusicUltimate";

UIColor *FrozenMusicBlue(void) {
    return [UIColor colorWithRed:135 / 255.0 green:207 / 255.0 blue:236 / 255.0 alpha:1.0];
}

static UIImage *FrozenMusicBundleIcon(NSString *name) {
    NSString *path = [NSBundle.ytmu_defaultBundle pathForResource:name ofType:@"png" inDirectory:@"icons"];
    UIImage *image = path ? [UIImage imageWithContentsOfFile:path] : nil;
    return [image imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
}

@implementation FrozenMusicSettingsController

- (NSArray<NSDictionary *> *)toggles {
    return @[
        @{@"title": @"Original YTM album look", @"desc": @"Albums show track numbers instead of cover art, like YouTube Music's album pages", @"key": @"frozenAlbumLook"},
        @{@"title": @"Player hue with OLED", @"desc": @"Keep the cover-colored hue in the full player when OLED Dark Theme is on", @"key": @"frozenOledPlayerHue"},
        @{@"title": @"YTM volume boost look", @"desc": @"Volume Boost panel in YouTube Music's style: grey, or black with OLED Dark Theme, with a white slider", @"key": @"frozenVolumeLook"},
        @{@"title": @"Snappy", @"desc": @"Everything in the Downloads tab opens and closes instantly, without animations", @"key": @"frozenSnappy"}
    ];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"FrozenMusic";

    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    [self.view addSubview:self.tableView];
    [NSLayoutConstraint activateConstraints:@[
        [self.tableView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor]
    ]];

    // Logo on top
    UIImage *logo = FrozenMusicBundleIcon(@"frozenmusic-logo@3x");
    if (logo) {
        UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 1, 150)];
        UIImageView *logoView = [[UIImageView alloc] initWithImage:logo];
        logoView.contentMode = UIViewContentModeScaleAspectFit;
        logoView.frame = CGRectMake(0, 16, 1, 118);
        logoView.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        [header addSubview:logoView];
        self.tableView.tableHeaderView = header;
    }
}

#pragma mark Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return FrozenMusicSectionCount;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch (section) {
        case FrozenMusicSectionDiscord: return 1;
        case FrozenMusicSectionToggles: return (NSInteger)[self toggles].count;
        default: return 2;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return section == FrozenMusicSectionLinks ? LOC(@"LINKS") : nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return section == FrozenMusicSectionLinks ? @"\nFrozenMusic by Fr0z3n" : nil;
}

- (void)tableView:(UITableView *)tableView willDisplayFooterView:(UIView *)view forSection:(NSInteger)section {
    if (section == FrozenMusicSectionLinks)
        ((UITableViewHeaderFooterView *)view).textLabel.textAlignment = NSTextAlignmentCenter;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.detailTextLabel.numberOfLines = 0;
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    cell.textLabel.adjustsFontSizeToFitWidth = YES;

    if (indexPath.section == FrozenMusicSectionDiscord) {
        cell.textLabel.text = @"Discord RPC";
        cell.detailTextLabel.text = @"Show what you're listening to on Discord";
        cell.imageView.image = [UIImage systemImageNamed:@"gamecontroller.fill"];
        cell.imageView.tintColor = [UIColor colorWithRed:88 / 255.0 green:101 / 255.0 blue:242 / 255.0 alpha:1.0]; // Discord blurple
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return cell;
    }

    if (indexPath.section == FrozenMusicSectionToggles) {
        NSDictionary *toggle = [self toggles][(NSUInteger)indexPath.row];
        NSDictionary *prefs = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"YTMUltimate"];
        cell.textLabel.text = toggle[@"title"];
        cell.detailTextLabel.text = toggle[@"desc"];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;

        ABCSwitch *switchControl = [[NSClassFromString(@"ABCSwitch") alloc] init];
        switchControl.onTintColor = FrozenMusicBlue();
        switchControl.tag = indexPath.row;
        switchControl.on = [prefs[toggle[@"key"]] boolValue];
        [switchControl addTarget:self action:@selector(toggleSwitch:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = switchControl;
        return cell;
    }

    // Links, like YTMusicUltimate's
    cell.textLabel.textColor = FrozenMusicBlue();
    if (indexPath.row == 0) {
        cell.textLabel.text = @"fr0z3n.com";
        cell.detailTextLabel.text = @"Website";
        cell.imageView.image = FrozenMusicBundleIcon(@"fr0z3n-24@2x");
    } else {
        cell.textLabel.text = @"GitHub";
        cell.detailTextLabel.text = @"FrozenMusic source code";
        cell.imageView.image = FrozenMusicBundleIcon(@"github-24@2x");
    }
    return cell;
}

- (BOOL)tableView:(UITableView *)tableView shouldHighlightRowAtIndexPath:(NSIndexPath *)indexPath {
    return indexPath.section != FrozenMusicSectionToggles;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == FrozenMusicSectionDiscord) {
        [self.navigationController pushViewController:[FrozenDiscordSettingsController new] animated:YES];
        return;
    }
    if (indexPath.section != FrozenMusicSectionLinks)
        return;
    NSURL *url = [NSURL URLWithString:indexPath.row == 0 ? FrozenMusicWebsite : FrozenMusicRepo];
    [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
}

- (void)toggleSwitch:(UISwitch *)sender {
    NSDictionary *toggle = [self toggles][(NSUInteger)sender.tag];
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSMutableDictionary *prefs = [NSMutableDictionary dictionaryWithDictionary:[defaults dictionaryForKey:@"YTMUltimate"]];
    prefs[toggle[@"key"]] = @(sender.isOn);
    [defaults setObject:prefs forKey:@"YTMUltimate"];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"FrozenMusicSettingsChanged" object:nil];
}

@end
