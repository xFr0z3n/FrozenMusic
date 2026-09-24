#import "FrozenDiscordSettingsController.h"
#import "FrozenDiscordConfig.h"
#import "FrozenMusicSettingsController.h"

static NSString *const FrozenDiscordPortalURL = @"https://discord.com/developers/applications";
static NSString *const FrozenNextcloudURL = @"https://nextcloud.com/sign-up/";

typedef NS_ENUM(NSInteger, FrozenDiscordSection) {
    FrozenDiscordSectionStatus,
    FrozenDiscordSectionDiscord,
    FrozenDiscordSectionArtwork,
    FrozenDiscordSectionSecrets,
    FrozenDiscordSectionHelp,
    FrozenDiscordSectionCount
};

@interface FrozenDiscordSettingsController ()
@property (nonatomic) BOOL changed; // saved, but only used after a restart
@end

@implementation FrozenDiscordSettingsController

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

// Text fields: key, title, placeholder, secure, keyboard
- (NSArray<NSDictionary *> *)fieldsForSection:(NSInteger)section {
    if (section == FrozenDiscordSectionDiscord) {
        return @[
            @{@"key": FrozenDiscordAppIDKey, @"title": @"App ID", @"placeholder": @"Application ID", @"keyboard": @(UIKeyboardTypeNumberPad)},
            @{@"key": FrozenDiscordTokenKey, @"title": @"Token", @"placeholder": @"Discord token", @"secure": @YES}
        ];
    }
    if (section == FrozenDiscordSectionArtwork) {
        return @[
            @{@"key": FrozenDiscordWebDAVURLKey, @"title": @"WebDAV", @"placeholder": @"WebDAV folder URL", @"keyboard": @(UIKeyboardTypeURL)},
            @{@"key": FrozenDiscordWebDAVUserKey, @"title": @"Username", @"placeholder": @"Username"},
            @{@"key": FrozenDiscordWebDAVPassKey, @"title": @"Password", @"placeholder": @"App password", @"secure": @YES},
            @{@"key": FrozenDiscordPublicURLKey, @"title": @"Share link", @"placeholder": @"Public share link", @"keyboard": @(UIKeyboardTypeURL)}
        ];
    }
    return @[];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Discord RPC";
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;

    // Same as YTMusicUltimate's ✓: close the app so the new setup is used on the next launch
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"checkmark"]
                                                                              style:UIBarButtonItemStylePlain
                                                                             target:self
                                                                             action:@selector(applyTapped:)];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self.view endEditing:YES]; // saves the field being edited
}

#pragma mark Values

// What the next launch will use: the app's value, else the build secret
- (NSString *)resolvedValue:(NSString *)key {
    return FrozenDiscordStoredValue(key) ?: YTMUDiscordBuildValue(key);
}

- (NSString *)statusText {
    if (!FrozenDiscordEnabled())
        return @"Off";

    NSArray *discordKeys = @[FrozenDiscordAppIDKey, FrozenDiscordTokenKey];
    NSArray *artworkKeys = @[FrozenDiscordWebDAVURLKey, FrozenDiscordWebDAVUserKey, FrozenDiscordWebDAVPassKey, FrozenDiscordPublicURLKey];
    for (NSString *key in discordKeys) {
        if (![self resolvedValue:key].length)
            return @"Not set up yet: add your App ID and token below";
    }

    BOOL fromApp = NO, fromBuild = NO;
    for (NSString *key in [discordKeys arrayByAddingObjectsFromArray:artworkKeys]) {
        if (FrozenDiscordStoredValue(key))
            fromApp = YES;
        else if (YTMUDiscordBuildValue(key))
            fromBuild = YES;
    }
    NSString *source = fromApp && fromBuild ? @"in-app setup + build secrets" : (fromApp ? @"in-app setup" : @"build secrets");

    BOOL artwork = [[self resolvedValue:FrozenDiscordPublicURLKey] containsString:@"/s/"];
    for (NSString *key in artworkKeys) {
        if (![self resolvedValue:key].length)
            artwork = NO;
    }
    NSString *status = [NSString stringWithFormat:@"Ready, uses %@, %@", source, artwork ? @"with cover art" : @"without cover art"];
    return self.changed ? [status stringByAppendingString:@"\nRestart to apply (✓ at the top right)"] : status;
}

- (NSString *)buildSecretsText {
    NSArray *names = @[@"App ID", @"Token", @"WebDAV URL", @"Username", @"Password", @"Share link"];
    NSArray *keys = @[FrozenDiscordAppIDKey, FrozenDiscordTokenKey, FrozenDiscordWebDAVURLKey,
                      FrozenDiscordWebDAVUserKey, FrozenDiscordWebDAVPassKey, FrozenDiscordPublicURLKey];
    NSMutableArray *found = [NSMutableArray array];
    for (NSUInteger i = 0; i < keys.count; i++) {
        if (YTMUDiscordBuildValue(keys[i]))
            [found addObject:names[i]];
    }
    return found.count ? [found componentsJoinedByString:@", "] : @"None";
}

#pragma mark Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return FrozenDiscordSectionCount;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch (section) {
        case FrozenDiscordSectionDiscord:
        case FrozenDiscordSectionArtwork:
            return (NSInteger)[self fieldsForSection:section].count;
        case FrozenDiscordSectionHelp:
            return 3;
        default:
            return 1;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case FrozenDiscordSectionDiscord: return @"Discord";
        case FrozenDiscordSectionArtwork: return @"Cover art (optional)";
        case FrozenDiscordSectionSecrets: return @"Build secrets (alternative)";
        case FrozenDiscordSectionHelp: return @"Help";
        default: return nil;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    switch (section) {
        case FrozenDiscordSectionStatus:
            return @"Shows what you're listening to as your Discord status: song, artist, progress and cover art. "
                   @"Changes are used after restarting YouTube Music, tap ✓ at the top right.";
        case FrozenDiscordSectionDiscord:
            return @"App ID: open the Discord Developer Portal (link below), tap New Application, give it a name "
                   @"(for example YouTube Music) and create it. Copy the Application ID from General Information. "
                   @"Nothing else has to be set up there.\n\n"
                   @"Token: your Discord account token, the status is set from your account the same way the desktop app does it. "
                   @"Keep it private, anyone who has it can log into your account. "
                   @"Discord doesn't officially support using your account token like this, so use it at your own risk.";
        case FrozenDiscordSectionArtwork:
            return @"For cover art, FrozenMusic uploads the song's cover to your own WebDAV storage and Discord loads it from a public link. "
                   @"Nextcloud works out of the box, on your own server or from a provider:\n\n"
                   @"1. Create a folder, for example discord-art.\n"
                   @"2. Share it with a public share link and paste that link here (looks like https://cloud.example.com/s/AbC123).\n"
                   @"3. WebDAV folder URL: https://cloud.example.com/remote.php/dav/files/USERNAME/discord-art/ "
                   @"(Nextcloud shows your WebDAV address under Files > Files settings).\n"
                   @"4. Create an app password under Settings > Security > Devices & sessions and use it with your username.\n\n"
                   @"Without this your status still works, just without the cover.";
        case FrozenDiscordSectionSecrets:
            return @"Instead of setting it up here, you can add these repository secrets to your fork "
                   @"(Settings > Secrets and variables > Actions): DISCORD_APP_ID, DISCORD_TOKEN, NEXTCLOUD_WEBDAV_URL, "
                   @"NEXTCLOUD_USER, NEXTCLOUD_PASS and NEXTCLOUD_PUBLIC_URL. The next IPA you build has them built in. "
                   @"Anything filled in above is used instead of the matching secret.";
        default:
            return nil;
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.detailTextLabel.numberOfLines = 0;
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;

    switch (indexPath.section) {
        case FrozenDiscordSectionStatus: {
            cell.textLabel.text = @"Discord RPC";
            cell.detailTextLabel.text = [self statusText];
            ABCSwitch *switchControl = [[NSClassFromString(@"ABCSwitch") alloc] init];
            switchControl.onTintColor = FrozenMusicBlue();
            switchControl.on = FrozenDiscordEnabled();
            [switchControl addTarget:self action:@selector(toggleEnabled:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = switchControl;
            return cell;
        }
        case FrozenDiscordSectionDiscord:
        case FrozenDiscordSectionArtwork:
            return [self fieldCell:[self fieldsForSection:indexPath.section][(NSUInteger)indexPath.row]];
        case FrozenDiscordSectionSecrets:
            cell.textLabel.text = @"In this build";
            cell.detailTextLabel.text = [self buildSecretsText];
            return cell;
        default:
            break;
    }

    // Help
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    if (indexPath.row == 0) {
        cell.textLabel.text = @"Discord Developer Portal";
        cell.detailTextLabel.text = @"Create the application and copy its ID";
        cell.textLabel.textColor = FrozenMusicBlue();
    } else if (indexPath.row == 1) {
        cell.textLabel.text = @"Nextcloud";
        cell.detailTextLabel.text = @"Get Nextcloud storage for the cover art";
        cell.textLabel.textColor = FrozenMusicBlue();
    } else {
        cell.textLabel.text = @"Clear in-app setup";
        cell.detailTextLabel.text = @"Removes everything entered here, build secrets stay";
        cell.textLabel.textColor = [UIColor systemRedColor];
    }
    return cell;
}

- (UITableViewCell *)fieldCell:(NSDictionary *)field {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;

    UILabel *title = [UILabel new];
    title.text = field[@"title"];
    title.font = [UIFont systemFontOfSize:17];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    [title setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [title setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];

    NSString *key = field[@"key"];
    UITextField *textField = [UITextField new];
    textField.accessibilityIdentifier = key;
    textField.text = FrozenDiscordStoredValue(key);
    // Empty field + secret in the build: say where the value comes from
    textField.placeholder = YTMUDiscordBuildValue(key) ? @"From build secret" : field[@"placeholder"];
    textField.secureTextEntry = [field[@"secure"] boolValue];
    textField.keyboardType = field[@"keyboard"] ? (UIKeyboardType)[field[@"keyboard"] integerValue] : UIKeyboardTypeDefault;
    textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    textField.autocorrectionType = UITextAutocorrectionTypeNo;
    textField.spellCheckingType = UITextSpellCheckingTypeNo;
    textField.clearButtonMode = UITextFieldViewModeWhileEditing;
    textField.returnKeyType = UIReturnKeyDone;
    textField.textAlignment = NSTextAlignmentRight;
    textField.delegate = self;
    textField.translatesAutoresizingMaskIntoConstraints = NO;
    [textField addTarget:self action:@selector(fieldEnded:) forControlEvents:UIControlEventEditingDidEnd];

    [cell.contentView addSubview:title];
    [cell.contentView addSubview:textField];
    UILayoutGuide *margins = cell.contentView.layoutMarginsGuide;
    [NSLayoutConstraint activateConstraints:@[
        [title.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
        [title.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
        [textField.leadingAnchor constraintEqualToAnchor:title.trailingAnchor constant:12],
        [textField.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor],
        [textField.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
        [cell.contentView.heightAnchor constraintGreaterThanOrEqualToConstant:48]
    ]];
    return cell;
}

- (BOOL)tableView:(UITableView *)tableView shouldHighlightRowAtIndexPath:(NSIndexPath *)indexPath {
    return indexPath.section == FrozenDiscordSectionHelp;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section != FrozenDiscordSectionHelp)
        return;
    if (indexPath.row < 2) {
        NSURL *url = [NSURL URLWithString:indexPath.row == 0 ? FrozenDiscordPortalURL : FrozenNextcloudURL];
        [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
        return;
    }

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Clear in-app setup?"
                                                                   message:@"Everything entered on this page is removed. Secrets built into the app stay."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:LOC(@"CANCEL") style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Clear" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        [self.view endEditing:YES];
        FrozenDiscordClearStoredValues();
        self.changed = YES;
        [self.tableView reloadData];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark Editing

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

- (void)fieldEnded:(UITextField *)textField {
    NSString *key = textField.accessibilityIdentifier;
    if (!key.length)
        return;
    NSString *old = FrozenDiscordStoredValue(key) ?: @"";
    FrozenDiscordSetStoredValue(key, textField.text);
    NSString *saved = FrozenDiscordStoredValue(key) ?: @"";
    textField.text = saved; // trimmed
    if (![old isEqualToString:saved]) {
        self.changed = YES;
        [self reloadStatus];
    }
}

- (void)toggleEnabled:(UISwitch *)sender {
    FrozenDiscordSetEnabled(sender.isOn);
    self.changed = YES;
    [self reloadStatus];
}

- (void)reloadStatus {
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:FrozenDiscordSectionStatus] withRowAnimation:UITableViewRowAnimationNone];
}

- (void)applyTapped:(id)sender {
    [self.view endEditing:YES];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:LOC(@"WARNING") message:LOC(@"APPLY_MESSAGE") preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:LOC(@"CANCEL") style:UIAlertActionStyleDefault handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:LOC(@"YES") style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSUserDefaults standardUserDefaults] synchronize];
            [[UIApplication sharedApplication] performSelector:@selector(suspend)];
            [NSThread sleepForTimeInterval:1.0];
            exit(0);
        });
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
