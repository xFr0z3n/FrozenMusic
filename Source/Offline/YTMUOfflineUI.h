#import <UIKit/UIKit.h>
#import "YTMUOfflinePlayer.h"

@class YTMUSheetAction;

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
@property (nonatomic, copy) NSString *kind;                  // nil = folder, @"Artist" / @"Creator" = built from tags

+ (NSArray<NSURL *> *)audioFilesInFolder:(NSURL *)folder;
// Every subfolder with audio in it. Reads only the first song's tags (fast).
+ (NSArray<YTMUCollection *> *)collectionsInFolder:(NSURL *)root;
- (NSArray<YTMUOfflineTrack *> *)loadTracks; // reads all songs (slow, off main thread)
- (NSString *)subtitle;                      // "Album • C418 • 2013 • 30 tracks"

// Every downloaded song (single ones + all folders), tags only, cached by file date. Slow the first time.
+ (NSArray<YTMUOfflineTrack *> *)libraryTracksInFolder:(NSURL *)root collections:(NSArray<YTMUCollection *> *)collections;
// Album artists (creator.png/.txt of albums) with every song tagged with their name
+ (NSArray<YTMUCollection *> *)artistsFromCollections:(NSArray<YTMUCollection *> *)collections library:(NSArray<YTMUOfflineTrack *> *)library;
// Playlist creators (creator.png/.txt of playlists) with all songs of their playlists
+ (NSArray<YTMUCollection *> *)creatorsFromCollections:(NSArray<YTMUCollection *> *)collections;
@end

#pragma mark - Custom order (Edit), saved by file / folder name

FOUNDATION_EXPORT NSArray<NSURL *> *YTMUApplySavedOrder(NSArray<NSURL *> *urls, NSString *key);
FOUNDATION_EXPORT void YTMUSaveOrder(NSArray<NSURL *> *urls, NSString *key);
FOUNDATION_EXPORT NSString *YTMUTrackOrderKey(NSURL *folder); // songs of a folder ("collections" = folders)

#pragma mark - Shared helpers

FOUNDATION_EXPORT UIColor *YTMUAverageColor(UIImage *image);
FOUNDATION_EXPORT UIColor *YTMUHueColor(UIImage *cover); // YTM-like page hue from a cover
FOUNDATION_EXPORT UIImage *YTMUHueImage(UIImage *cover); // 3x1 palette of the cover for the hue
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
- (void)setSubtitleText:(NSString *)text; // after configure: custom second line
@property (nonatomic) BOOL keepsReorderOnRight;   // queue: drag handle stays on the right
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
@property (nonatomic) BOOL startsFinding;            // open with "Find in playlist"
- (void)startFinding;
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

// Opens a folder in the Files app
FOUNDATION_EXPORT void YTMUOpenInFiles(NSURL *folder);

// Share / Delete download sheet for a downloaded playlist or album
FOUNDATION_EXPORT void YTMUShowCollectionMenu(YTMUCollection *collection, UIViewController *presenter, UIView *source, void (^onDeleted)(void));
// YTM-style song sheet: Play next / Share, Add to queue, Go to album / artist,
// Open song, extra rows, Delete download (when onDelete is set)
FOUNDATION_EXPORT void YTMUShowSongMenu(YTMUOfflineTrack *track, UIViewController *presenter, NSArray<YTMUSheetAction *> *extraActions, void (^onDelete)(void));

// With "Find in playlist" + "Edit" on top
FOUNDATION_EXPORT void YTMUShowCollectionMenuFull(YTMUCollection *collection, UIViewController *presenter, UIView *source, void (^onDeleted)(void), void (^onEdit)(void), void (^onFind)(void));
// Same, with "Edit" on top (reorder the songs)
FOUNDATION_EXPORT void YTMUShowCollectionMenuWithEdit(YTMUCollection *collection, UIViewController *presenter, UIView *source, void (^onDeleted)(void), void (^onEdit)(void));