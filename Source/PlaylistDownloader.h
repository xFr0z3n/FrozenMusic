#import <UIKit/UIKit.h>

// Downloads a whole YouTube Music playlist as tagged .m4a files into
// Documents/YTMusicUltimate/<Playlist name>/  ("288. Title.m4a")
//
// Tags per file: title, artist, album = playlist name, album artist = playlist
// name, track = playlist position, comment = YouTube Music link, embedded cover.
// Songs already downloaded (tracked by video ID) are skipped; if a song moved
// in the playlist, its file is renamed and its track number updated.
@interface YTMUPlaylistDownloader : NSObject
+ (instancetype)sharedDownloader;
@property (nonatomic, readonly) BOOL running;
- (void)startWithBrowseID:(NSString *)browseID; // "VLPL..." from the playlist page
@end
