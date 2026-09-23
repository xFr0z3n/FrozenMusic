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
@property (nonatomic, copy) NSString *details;               // description.txt
@property (nonatomic, copy) NSString *creator;               // creator.txt
@property (nonatomic, strong) UIImage *creatorImage;         // creator.png

+ (NSArray<NSURL *> *)audioFilesInFolder:(NSURL *)folder;
// Every subfolder with audio in it. Reads only the first song's tags (fast).
+ (NSArray<YTMUCollection *> *)collectionsInFolder:(NSURL *)root;
- (NSArray<YTMUOfflineTrack *> *)loadTracks; // reads all songs (slow, off main thread)
- (NSString *)subtitle;                      // "Album • C418 • 2013 • 30 songs"
@end

#pragma mark - Shared helpers

FOUNDATION_EXPORT UIColor *YTMUAverageColor(UIImage *image);
FOUNDATION_EXPORT BOOL YTMUIsOLED(void);               // OLED Dark Theme setting on
FOUNDATION_EXPORT UIColor *YTMUBackgroundColor(void);  // pure black with OLED
FOUNDATION_EXPORT NSString *YTMUFormatTime(NSTimeInterval seconds);

@interface YTMUBadgeLabel : UILabel
+ (instancetype)badgeWithText:(NSString *)text;
@end

// The 3 bars YTM shows on the song that's playing
@interface YTMUEqualizerView : UIView
- (void)setAnimating:(BOOL)animating;
@end

#pragma mark - Cells

@interface YTMUTrackCell : UITableViewCell
@property (nonatomic, copy) void (^onMenu)(UIButton *sender); // ⋮ shown only when set
- (void)configureWithTrack:(YTMUOfflineTrack *)track isCurrent:(BOOL)isCurrent isPlaying:(BOOL)isPlaying;
@end

@interface YTMUCollectionCell : UITableViewCell
@property (nonatomic, copy) void (^onMenu)(UIButton *sender); // ⋮ tapped
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
@property (nonatomic, copy) void (^onVisibilityChange)(BOOL visible); // also called right when set
- (void)refresh;
@end

// Share / Delete download sheet for a downloaded playlist or album
FOUNDATION_EXPORT void YTMUShowCollectionMenu(YTMUCollection *collection, UIViewController *presenter, UIView *source, void (^onDeleted)(void));