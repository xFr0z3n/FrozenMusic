#import <UIKit/UIKit.h>

@class YTMUOfflineTrack;

// One line of lyrics. time < 0: not synced
@interface YTMULyricLine : NSObject
@property (nonatomic) NSTimeInterval time;
@property (nonatomic, copy) NSString *text;
@end

// Lyrics of a song, saved in the app for offline use (by video ID, so renaming
// or reordering downloads never loses them). YouTube Music's own lyrics first
// (synced when it has them), LRCLIB as fallback.
@interface YTMULyrics : NSObject
@property (nonatomic, copy) NSArray<YTMULyricLine *> *lines;
@property (nonatomic) BOOL synced;
@property (nonatomic, copy) NSString *source; // "Source: LyricFind"

// Saved lyrics, else fetched (online). nil = none available. Completion on the main queue.
+ (void)loadForTrack:(YTMUOfflineTrack *)track completion:(void (^)(YTMULyrics *lyrics, BOOL offline))completion;
+ (YTMULyrics *)savedLyricsForTrack:(YTMUOfflineTrack *)track;

// Language the lyrics are in (nil if unsure) and the device language
- (NSString *)languageCode;
+ (NSString *)deviceLanguageCode;
// One translated string per line (empty for ♪ / blank lines), saved after the first time.
// iOS 18+: Apple's on-device translation (offline once iOS has the languages; it asks
// to download them, shown on `presenter`). Older iOS: Google, online. Main queue.
- (void)translationForTrack:(YTMUOfflineTrack *)track presenter:(UIViewController *)presenter
                 completion:(void (^)(NSArray<NSString *> *translation, NSString *credit, NSString *error))completion;
+ (BOOL)canTranslateOnDevice;
@end

// Downloads call this: fetch + save the lyrics in the background (skipped when already saved)
FOUNDATION_EXPORT void YTMUPrefetchLyrics(NSString *videoID, NSString *title, NSString *artist, NSTimeInterval duration);
