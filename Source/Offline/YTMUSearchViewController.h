#import <UIKit/UIKit.h>
#import "YTMUOfflineUI.h"

// "Search in library" for downloads: history (tap, fill with ↖, hold to remove),
// live results for songs, playlists & albums, artists & creators
@interface YTMUSearchViewController : UIViewController
- (instancetype)initWithRoot:(NSURL *)root
                 collections:(NSArray<YTMUCollection *> *)collections
                     library:(NSArray<YTMUOfflineTrack *> *)library;
@property (nonatomic, copy) void (^onChange)(void); // something was deleted
@end
