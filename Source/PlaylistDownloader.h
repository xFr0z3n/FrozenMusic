#import <UIKit/UIKit.h>

// Downloads a whole YouTube Music playlist as tagged .m4a files into
// Documents/YTMusicUltimate/<Playlist name>/  ("288. Title.m4a")
//
// Tags per file: title, artist, album = playlist name, album artist = playlist
// name, track = playlist position, comment = YouTube Music link, embedded cover.
// Songs already downloaded (tracked by video ID) are skipped; if a song moved
// in the playlist, its file is renamed and its track number updated.
// Implemented in Downloading.x: finds the stream of `videoID` around the player.
// Returns @{@"hls": ..., @"author": ...} or @{@"diag": ...}
FOUNDATION_EXPORT NSDictionary *YTMUStreamInfoForVideo(NSArray *startObjects, NSString *videoID);
// Implemented in Downloading.x: the lock-screen info (title, artist, albumTitle) of the current song
FOUNDATION_EXPORT NSDictionary *YTMUCurrentNowPlayingInfo(void);

@interface YTMUPlaylistDownloader : NSObject
+ (instancetype)sharedDownloader;
@property (nonatomic, readonly) BOOL running;
// Texts shown on the page (from accessibility), set right before start: fallback for the title
@property (nonatomic, copy) NSArray<NSDictionary *> *pageTexts;
- (void)startWithBrowseID:(NSString *)browseID; // "VLPL..." from the playlist page
@end
