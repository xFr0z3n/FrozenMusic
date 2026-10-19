#import <UIKit/UIKit.h>

// FrozenSC > Discord RPC: set up the Discord status in the app instead of
// (or on top of) the GitHub Actions secrets. Presented modally from FrozenSC's settings.
@interface FrozenSCDiscordSettingsController : UITableViewController <UITextFieldDelegate>
@end

// SoundCloud orange (#FF5500)
FOUNDATION_EXPORT UIColor *FrozenSCOrange(void);
