#import <UIKit/UIKit.h>
#import "YTMULyrics.h"
#import "YTMUOfflinePlayer.h"

// YTM's lyrics screen for downloaded songs: mini player on top, synced lyrics
// on the cover's hue (current line bright, tap a line to jump there), Share and Translate
@interface YTMULyricsViewController : UIViewController
- (instancetype)initWithTrack:(YTMUOfflineTrack *)track lyrics:(YTMULyrics *)lyrics;
@end

// Blurred-cover background made ahead of time (the full player calls this for its song)
FOUNDATION_EXPORT void YTMUPrepareLyricsBackdrop(UIImage *cover);
