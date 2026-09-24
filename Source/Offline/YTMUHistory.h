#import <UIKit/UIKit.h>
#import "YTMUOfflineUI.h"

// What was played / opened in the Downloads tab, newest first.
// Paths are stored relative to Documents/YTMusicUltimate (the app folder changes on reinstall).
FOUNDATION_EXPORT void YTMURecordHistory(NSURL *url, BOOL isCollection);
FOUNDATION_EXPORT void YTMURemoveFromHistory(NSURL *url);

// YTM-style "History": Today / Yesterday / This week / Last week / Earlier
@interface YTMUHistoryViewController : UIViewController
- (instancetype)initWithRoot:(NSURL *)root;
@property (nonatomic, copy) void (^onChange)(void); // something was deleted
@end
