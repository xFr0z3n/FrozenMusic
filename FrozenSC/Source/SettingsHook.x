#import <UIKit/UIKit.h>
#import "Prefs/FrozenSCDiscordConfig.h"
#import "Prefs/FrozenSCDiscordSettingsController.h"

// FrozenSC's settings screen (opened by long-pressing in the SoundCloud tab bar) is a plain
// UITableView whose data source is a NexaSCSettingsViewController. Its rows come from a nested
// array: settingsSections[section][row] = an item dictionary with keys like "title"/"icon"/"type".
//
// We add our own one-row section at the end. Because NexaSCSettingsViewController drives the whole
// table off that array (number of sections = settingsSections.count, rows = section array count,
// cell = item dict), simply appending a section makes our row render natively with its own icon
// and title. Tapping it dispatches on item["type"]; an unknown type is a no-op there, so we catch
// our type in a didSelect hook and open the Discord RPC screen ourselves.

static NSString *const kFrozenSCDiscordRowType = @"frozensc_discord_rpc";

// The item our injected row carries. Same {title, icon, type} shape as the shipping action rows
// ("Support Me", "Contact Me"), so the existing cell renders it without special handling.
static NSDictionary *FrozenSCDiscordRowItem(void) {
    return @{
        @"title": @"Discord RPC",
        @"icon": @"antenna.radiowaves.left.and.right",
        @"type": kFrozenSCDiscordRowType
    };
}

// Topmost presented view controller in the active window, so the modal shows reliably even though
// the settings view controller is a child inside the player popup rather than a navigation stack.
static UIViewController *FrozenSCTopViewController(UIViewController *base) {
    UIViewController *root = nil;
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]] ||
            scene.activationState != UISceneActivationStateForegroundActive)
            continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window.isKeyWindow) { root = window.rootViewController; break; }
        }
        if (root) break;
    }
    UIViewController *top = root ?: base;
    while (top.presentedViewController)
        top = top.presentedViewController;
    return top;
}

%hook NexaSCSettingsViewController

// Append our section once the sections array exists.
- (void)setupSettingsData {
    %orig;

    NSArray *sections = [self valueForKey:@"settingsSections"];
    if (![sections isKindOfClass:[NSArray class]])
        return;

    // Don't add twice (setupSettingsData may run again on refresh).
    for (id section in sections) {
        if (![section isKindOfClass:[NSArray class]]) continue;
        for (id item in (NSArray *)section) {
            if ([item isKindOfClass:[NSDictionary class]] &&
                [((NSDictionary *)item)[@"type"] isEqual:kFrozenSCDiscordRowType])
                return;
        }
    }

    NSMutableArray *updated = [sections mutableCopy];
    [updated addObject:@[ FrozenSCDiscordRowItem() ]];
    [self setValue:[updated copy] forKey:@"settingsSections"];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    NSArray *sections = [self valueForKey:@"settingsSections"];
    NSDictionary *item = nil;
    if ([sections isKindOfClass:[NSArray class]] && indexPath.section < (NSInteger)sections.count) {
        id section = sections[indexPath.section];
        if ([section isKindOfClass:[NSArray class]] && indexPath.row < (NSInteger)[(NSArray *)section count])
            item = ((NSArray *)section)[indexPath.row];
    }

    if ([item isKindOfClass:[NSDictionary class]] &&
        [item[@"type"] isEqual:kFrozenSCDiscordRowType]) {
        [tableView deselectRowAtIndexPath:indexPath animated:YES];

        FrozenSCDiscordSettingsController *discord = [FrozenSCDiscordSettingsController new];
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:discord];
        nav.modalPresentationStyle = UIModalPresentationFormSheet;
        [FrozenSCTopViewController(self) presentViewController:nav animated:YES completion:nil];
        return;
    }

    %orig;
}

%end
