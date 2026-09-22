#import <UIKit/UIKit.h>
#import "YTMUOfflinePlayer.h"

#pragma mark - Downloaded playlist / album (a folder in YTMusicUltimate)

@interface YTMUCollection : NSObject
@property (nonatomic, strong) NSURL *folder;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, strong) UIImage *cover;
@property (nonatomic, strong) NSArray<NSURL *> *files;       // sorted by track number
@property (nonatomic, strong) NSArray<NSString *> *formats;  // e.g. @[@"m4a", @"mp3"]
@property (nonatomic) BOOL isAlbum;
@property (nonatomic, copy) NSString *artist;
@property (nonatomic, copy) NSString *year;

+ (NSArray<NSURL *> *)audioFilesInFolder:(NSURL *)folder;
// Every subfolder with audio in it. Reads only the first song's tags (fast).
+ (NSArray<YTMUCollection *> *)collectionsInFolder:(NSURL *)root;
- (NSArray<YTMUOfflineTrack *> *)loadTracks; // reads all songs (slow, off main thread)
- (NSString *)subtitle;                      // "Album • C418 • 2013" / "Playlist • 51 songs"
@end

#pragma mark - Shared helpers

FOUNDATION_EXPORT UIColor *YTMUAverageColor(UIImage *image);
FOUNDATION_EXPORT NSString *YTMUFormatTime(NSTimeInterval seconds);

@interface YTMUBadgeLabel : UILabel
+ (instancetype)badgeWithText:(NSString *)text;
@end

#pragma mark - Cells

@interface YTMUTrackCell : UITableViewCell
- (void)configureWithTrack:(YTMUOfflineTrack *)track showNumber:(BOOL)showNumber isCurrent:(BOOL)isCurrent;
@end

@interface YTMUCollectionCell : UITableViewCell
- (void)configureWithCollection:(YTMUCollection *)collection;
@end

#pragma mark - Screens

// Album / playlist page, presented full screen
@interface YTMUCollectionViewController : UIViewController
- (instancetype)initWithCollection:(YTMUCollection *)collection;
@property (nonatomic, copy) void (^onChange)(void); // files deleted etc.
@end

// YTM-style Now Playing screen for downloaded songs
@interface YTMUNowPlayingViewController : UIViewController
@end

// Small bar with the current song, tap opens Now Playing
@interface YTMUMiniPlayerView : UIView
@property (nonatomic, weak) UIViewController *presenter;
@end
