#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import "../Headers/YTAlertView.h"
#import "../Headers/YTMToastController.h"
#import "../Headers/Localization.h"

// Downloads tab: playlists & albums (folders) + single songs, YTM style,
// played with the built-in offline player (Source/Offline)
@interface YTMDownloads : UIViewController <UITableViewDelegate, UITableViewDataSource>
@property (nonatomic, strong) UITableView *tableView;
@end
