#import <UIKit/UIKit.h>
#import "../Headers/Localization.h"

// FrozenMusic's own settings (offline player / Downloads tab) + links
@interface FrozenMusicSettingsController : UIViewController <UITableViewDelegate, UITableViewDataSource>
@property (nonatomic, strong) UITableView *tableView;
@end

// Light blue of the FrozenMusic logo (#87CFEC)
FOUNDATION_EXPORT UIColor *FrozenMusicBlue(void);
