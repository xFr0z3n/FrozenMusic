#import "FrozenMusicSettingsController.h"

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

// Same size as the other link icons (24 pt)
static UIImage *FrozenMusicIconSized(UIImage *image) {
    if (!image)
        return nil;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(24, 24)];
    UIImage *sized = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        UIBezierPath *clip = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, 24, 24) cornerRadius:5];
        [clip addClip];
        [image drawInRect:CGRectMake(0, 0, 24, 24)];
    }];
    return [sized imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
}

// fr0z3n.com's own icon (what the site shows as its icon), cached after the first load
static NSURL *FrozenMusicSiteIconCache(void) {
    NSURL *caches = [[[NSFileManager defaultManager] URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask] lastObject];
    return [caches URLByAppendingPathComponent:@"frozenmusic-site-icon.png"];
}

static void FrozenMusicLoadSiteIcon(void (^done)(UIImage *icon)) {
    UIImage *cached = [UIImage imageWithContentsOfFile:FrozenMusicSiteIconCache().path];
    if (cached) {
        done(cached);
        return;
    }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSMutableArray<NSString *> *candidates = [NSMutableArray array];
        // Icon links the page itself declares, then the usual places
        NSData *htmlData = [NSData dataWithContentsOfURL:[NSURL URLWithString:FrozenMusicWebsite]];
        NSString *html = htmlData ? [[NSString alloc] initWithData:htmlData encoding:NSUTF8StringEncoding] : nil;
        if (html) {
            NSRegularExpression *links = [NSRegularExpression regularExpressionWithPattern:@"<link[^>]+rel=[\"'][^\"']*icon[^\"']*[\"'][^>]*>" options:NSRegularExpressionCaseInsensitive error:nil];
            NSRegularExpression *href = [NSRegularExpression regularExpressionWithPattern:@"href=[\"']([^\"']+)[\"']" options:NSRegularExpressionCaseInsensitive error:nil];
            for (NSTextCheckingResult *link in [links matchesInString:html options:0 range:NSMakeRange(0, html.length)]) {
                NSString *tag = [html substringWithRange:link.range];
                NSTextCheckingResult *match = [href firstMatchInString:tag options:0 range:NSMakeRange(0, tag.length)];
                if (match) {
                    NSURL *url = [NSURL URLWithString:[tag substringWithRange:[match rangeAtIndex:1]] relativeToURL:[NSURL URLWithString:FrozenMusicWebsite]];
                    if (url.absoluteString.length)
                        [candidates insertObject:url.absoluteString atIndex:0]; // later tags are usually the big ones
                }
            }
        }
        [candidates addObjectsFromArray:@[[FrozenMusicWebsite stringByAppendingString:@"/apple-touch-icon.png"],
                                          [FrozenMusicWebsite stringByAppendingString:@"/favicon.png"],
                                          [FrozenMusicWebsite stringByAppendingString:@"/favicon.ico"]]];
        UIImage *icon = nil;
        for (NSString *candidate in candidates) {
            NSData *data = [NSData dataWithContentsOfURL:[NSURL URLWithString:candidate]];
            icon = data ? [UIImage imageWithData:data] : nil;
            if (icon) {
                [UIImagePNGRepresentation(icon) writeToURL:FrozenMusicSiteIconCache() atomically:YES];
                break;
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            done(icon);
        });
    });
}

@interface FrozenMusicSettingsController ()
@property (nonatomic, strong) UIImage *siteIcon;
@end

@implementation FrozenMusicSettingsController

- (NSArray<NSDictionary *> *)toggles {
    return @[
        @{@"title": @"Original YTM album look", @"desc": @"Albums show track numbers instead of cover art, like YouTube Music's album pages", @"key": @"frozenAlbumLook"},
        @{@"title": @"Player hue with OLED", @"desc": @"Keep the cover-colored hue in the full player when OLED Dark Theme is on", @"key": @"frozenOledPlayerHue"}
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

    __weak __typeof(self) weakSelf = self;
    FrozenMusicLoadSiteIcon(^(UIImage *icon) {
        weakSelf.siteIcon = icon;
        [weakSelf.tableView reloadSections:[NSIndexSet indexSetWithIndex:1] withRowAnimation:UITableViewRowAnimationNone];
    });
}

#pragma mark Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 2;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return section == 0 ? (NSInteger)[self toggles].count : 2;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return section == 1 ? LOC(@"LINKS") : nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return section == 1 ? @"\nFrozenMusic by Fr0z3n" : nil;
}

- (void)tableView:(UITableView *)tableView willDisplayFooterView:(UIView *)view forSection:(NSInteger)section {
    if (section == 1)
        ((UITableViewHeaderFooterView *)view).textLabel.textAlignment = NSTextAlignmentCenter;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.detailTextLabel.numberOfLines = 0;
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    cell.textLabel.adjustsFontSizeToFitWidth = YES;

    if (indexPath.section == 0) {
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
        cell.imageView.image = FrozenMusicIconSized(self.siteIcon) ?: [UIImage systemImageNamed:@"globe"];
        cell.imageView.tintColor = FrozenMusicBlue();
    } else {
        cell.textLabel.text = @"GitHub";
        cell.detailTextLabel.text = @"FrozenMusic source code";
        cell.imageView.image = FrozenMusicBundleIcon(@"github-24@2x");
    }
    return cell;
}

- (BOOL)tableView:(UITableView *)tableView shouldHighlightRowAtIndexPath:(NSIndexPath *)indexPath {
    return indexPath.section == 1;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section != 1)
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
