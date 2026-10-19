#import "FrozenSCDiscordSettingsController.h"
#import "FrozenSCDiscordConfig.h"

static NSString *const FrozenSCDiscordPortalURL = @"https://discord.com/developers/applications";
static NSString *const FrozenSCNextcloudURL = @"https://nextcloud.com/sign-up/";

UIColor *FrozenSCOrange(void) {
    return [UIColor colorWithRed:1.0 green:85.0 / 255.0 blue:0.0 alpha:1.0];
}

typedef NS_ENUM(NSInteger, FrozenSCDiscordSection) {
    FrozenSCDiscordSectionStatus,
    FrozenSCDiscordSectionDiscord,
    FrozenSCDiscordSectionArtwork,
    FrozenSCDiscordSectionSecrets,
    FrozenSCDiscordSectionHelp,
    FrozenSCDiscordSectionCount
};

@interface FrozenSCDiscordSettingsController ()
@property (nonatomic) BOOL changed; // saved, but only used after a restart
@end

@implementation FrozenSCDiscordSettingsController

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

// Text fields: key, title, placeholder, secure, keyboard
- (NSArray<NSDictionary *> *)fieldsForSection:(NSInteger)section {
    if (section == FrozenSCDiscordSectionDiscord) {
        return @[
            @{@"key": FrozenSCDiscordAppIDKey, @"title": @"App ID", @"placeholder": @"Application ID", @"keyboard": @(UIKeyboardTypeNumberPad)},
            @{@"key": FrozenSCDiscordTokenKey, @"title": @"Token", @"placeholder": @"Discord token", @"secure": @YES}
        ];
    }
    if (section == FrozenSCDiscordSectionArtwork) {
        return @[
            @{@"key": FrozenSCDiscordWebDAVURLKey, @"title": @"WebDAV", @"placeholder": @"WebDAV folder URL", @"keyboard": @(UIKeyboardTypeURL)},
            @{@"key": FrozenSCDiscordWebDAVUserKey, @"title": @"Username", @"placeholder": @"Username"},
            @{@"key": FrozenSCDiscordWebDAVPassKey, @"title": @"Password", @"placeholder": @"App password", @"secure": @YES},
            @{@"key": FrozenSCDiscordPublicURLKey, @"title": @"Share link", @"placeholder": @"Public share link", @"keyboard": @(UIKeyboardTypeURL)}
        ];
    }
    return @[];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Discord RPC";
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;

    // Presented modally: Close on the left, and ✓ (restart to apply) on the right.
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose
                                                                                          target:self
                                                                                          action:@selector(closeTapped:)];
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
    return FrozenSCDiscordStoredValue(key) ?: FrozenSCDiscordBuildValue(key);
}

- (NSString *)statusText {
    if (!FrozenSCDiscordEnabled())
        return @"Off";

    NSArray *discordKeys = @[FrozenSCDiscordAppIDKey, FrozenSCDiscordTokenKey];
    NSArray *artworkKeys = @[FrozenSCDiscordWebDAVURLKey, FrozenSCDiscordWebDAVUserKey, FrozenSCDiscordWebDAVPassKey, FrozenSCDiscordPublicURLKey];
    for (NSString *key in discordKeys) {
        if (![self resolvedValue:key].length)
            return @"Not set up yet: add your App ID and token below";
    }

    BOOL fromApp = NO, fromBuild = NO;
    for (NSString *key in [discordKeys arrayByAddingObjectsFromArray:artworkKeys]) {
        if (FrozenSCDiscordStoredValue(key))
            fromApp = YES;
        else if (FrozenSCDiscordBuildValue(key))
            fromBuild = YES;
    }
    NSString *source = fromApp && fromBuild ? @"in-app setup + build secrets" : (fromApp ? @"in-app setup" : @"build secrets");

    BOOL artwork = [[self resolvedValue:FrozenSCDiscordPublicURLKey] containsString:@"/s/"];
    for (NSString *key in artworkKeys) {
        if (![self resolvedValue:key].length)
            artwork = NO;
    }
    NSString *status = [NSString stringWithFormat:@"Ready, uses %@, %@", source, artwork ? @"with cover art" : @"without cover art"];
    return self.changed ? [status stringByAppendingString:@"\nRestart to apply (✓ at the top right)"] : status;
}

- (NSString *)buildSecretsText {
    NSArray *names = @[@"App ID", @"Token", @"WebDAV URL", @"Username", @"Password", @"Share link"];
    NSArray *keys = @[FrozenSCDiscordAppIDKey, FrozenSCDiscordTokenKey, FrozenSCDiscordWebDAVURLKey,
                      FrozenSCDiscordWebDAVUserKey, FrozenSCDiscordWebDAVPassKey, FrozenSCDiscordPublicURLKey];
    NSMutableArray *found = [NSMutableArray array];
    for (NSUInteger i = 0; i < keys.count; i++) {
        if (FrozenSCDiscordBuildValue(keys[i]))
            [found addObject:names[i]];
    }
    return found.count ? [found componentsJoinedByString:@", "] : @"None";
}

#pragma mark Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return FrozenSCDiscordSectionCount;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch (section) {
        case FrozenSCDiscordSectionDiscord:
        case FrozenSCDiscordSectionArtwork:
            return (NSInteger)[self fieldsForSection:section].count;
        case FrozenSCDiscordSectionHelp:
            return 3;
        default:
            return 1;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case FrozenSCDiscordSectionDiscord: return @"Discord";
        case FrozenSCDiscordSectionArtwork: return @"Cover art (optional)";
        case FrozenSCDiscordSectionSecrets: return @"Build secrets (alternative)";
        case FrozenSCDiscordSectionHelp: return @"Help";
        default: return nil;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    switch (section) {
        case FrozenSCDiscordSectionStatus:
            return @"Shows what you're listening to on SoundCloud as your Discord status: song, artist, progress and cover art. "
                   @"Changes are used after restarting SoundCloud, tap ✓ at the top right.";
        case FrozenSCDiscordSectionDiscord:
            return @"App ID: open the Discord Developer Portal (link below), tap New Application, give it a name "
                   @"(for example SoundCloud) and create it. Copy the Application ID from General Information. "
                   @"Nothing else has to be set up there.\n\n"
                   @"Token: your Discord account token, the status is set from your account the same way the desktop app does it. "
                   @"Keep it private, anyone who has it can log into your account. "
                   @"Discord doesn't officially support using your account token like this, so use it at your own risk.";
        case FrozenSCDiscordSectionArtwork:
            return @"For cover art, FrozenSC uploads the song's cover to your own WebDAV storage and Discord loads it from a public link. "
                   @"Nextcloud works out of the box, on your own server or from a provider:\n\n"
                   @"1. Create a folder, for example discord-art.\n"
                   @"2. Share it with a public share link and paste that link here (looks like https://cloud.example.com/s/AbC123).\n"
                   @"3. WebDAV folder URL: https://cloud.example.com/remote.php/dav/files/USERNAME/discord-art/ "
                   @"(Nextcloud shows your WebDAV address under Files > Files settings).\n"
                   @"4. Create an app password under Settings > Security > Devices & sessions and use it with your username.\n\n"
                   @"Without this your status still works, just without the cover.";
        case FrozenSCDiscordSectionSecrets:
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
        case FrozenSCDiscordSectionStatus: {
            cell.textLabel.text = @"Discord RPC";
            cell.detailTextLabel.text = [self statusText];
            UISwitch *switchControl = [[UISwitch alloc] init];
            switchControl.onTintColor = FrozenSCOrange();
            switchControl.on = FrozenSCDiscordEnabled();
            [switchControl addTarget:self action:@selector(toggleEnabled:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = switchControl;
            return cell;
        }
        case FrozenSCDiscordSectionDiscord:
        case FrozenSCDiscordSectionArtwork:
            return [self fieldCell:[self fieldsForSection:indexPath.section][(NSUInteger)indexPath.row]];
        case FrozenSCDiscordSectionSecrets:
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
        cell.textLabel.textColor = FrozenSCOrange();
    } else if (indexPath.row == 1) {
        cell.textLabel.text = @"Nextcloud";
        cell.detailTextLabel.text = @"Get Nextcloud storage for the cover art";
        cell.textLabel.textColor = FrozenSCOrange();
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
    textField.text = FrozenSCDiscordStoredValue(key);
    // Empty field + secret in the build: say where the value comes from
    textField.placeholder = FrozenSCDiscordBuildValue(key) ? @"From build secret" : field[@"placeholder"];
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
    return indexPath.section == FrozenSCDiscordSectionHelp;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section != FrozenSCDiscordSectionHelp)
        return;
    if (indexPath.row < 2) {
        NSURL *url = [NSURL URLWithString:indexPath.row == 0 ? FrozenSCDiscordPortalURL : FrozenSCNextcloudURL];
        [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
        return;
    }

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Clear in-app setup?"
                                                                   message:@"Everything entered on this page is removed. Secrets built into the app stay."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Clear" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        [self.view endEditing:YES];
        FrozenSCDiscordClearStoredValues();
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
    NSString *old = FrozenSCDiscordStoredValue(key) ?: @"";
    FrozenSCDiscordSetStoredValue(key, textField.text);
    NSString *saved = FrozenSCDiscordStoredValue(key) ?: @"";
    textField.text = saved; // trimmed
    if (![old isEqualToString:saved]) {
        self.changed = YES;
        [self reloadStatus];
    }
}

- (void)toggleEnabled:(UISwitch *)sender {
    FrozenSCDiscordSetEnabled(sender.isOn);
    self.changed = YES;
    [self reloadStatus];
}

- (void)reloadStatus {
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:FrozenSCDiscordSectionStatus] withRowAnimation:UITableViewRowAnimationNone];
}

- (void)closeTapped:(id)sender {
    [self.view endEditing:YES];
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)applyTapped:(id)sender {
    [self.view endEditing:YES];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Warning"
                                                                   message:@"This action will close SoundCloud to apply changes. Are you sure?"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleDefault handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Restart Now" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
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
