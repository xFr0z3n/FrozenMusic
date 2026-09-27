#import <UIKit/UIKit.h>

@class YTMUOfflineTrack;

// One line of lyrics. time < 0: not synced
@interface YTMULyricLine : NSObject
@property (nonatomic) NSTimeInterval time;
@property (nonatomic, copy) NSString *text;
@end

// Lyrics of a song: YouTube Music's own lyrics first (synced when it has them),
// LRCLIB as fallback.
@interface YTMULyrics : NSObject
@property (nonatomic, copy) NSArray<YTMULyricLine *> *lines;
@property (nonatomic) BOOL synced;
@property (nonatomic, copy) NSString *source; // "Source: LyricFind"

// Lyrics are plain .lrc files in a "Lyrics" folder next to the songs: in the playlist /
// album folder, or in YTMusicUltimate for single songs ("Lyrics/<song file name>.lrc").
// Nothing is kept inside the app or written into the music files.

// Saved lyrics, else fetched (online) and saved. nil = none available. Completion on the main queue.
+ (void)loadForTrack:(YTMUOfflineTrack *)track completion:(void (^)(YTMULyrics *lyrics, BOOL offline))completion;
+ (YTMULyrics *)savedLyricsForTrack:(YTMUOfflineTrack *)track;

// Language the lyrics are in (nil if unsure) and the device language
- (NSString *)languageCode;
+ (NSString *)deviceLanguageCode;
// One translated string per line (empty for ♪ / blank lines). Google when there's internet,
// without internet Google's on-device ML Kit model (its language is downloaded while online,
// e.g. when the song is downloaded). Never hangs: answers within ~20 s. Main queue.
- (void)translationForTrack:(YTMUOfflineTrack *)track presenter:(UIViewController *)presenter
                 completion:(void (^)(NSArray<NSString *> *translation, NSString *credit, NSString *error))completion;
+ (BOOL)canTranslateOnDevice;
@end

// "Lyrics/<song>.lrc" of a downloaded song
FOUNDATION_EXPORT NSURL *YTMULyricsFileForAudio(NSURL *audioURL);
// Downloads (background thread, blocks): writes the song's lyrics file. NO when it has none
FOUNDATION_EXPORT BOOL YTMUSaveLyricsForDownload(NSURL *audioURL, NSString *videoID, NSString *title, NSString *artist, NSTimeInterval duration);
// Same in the background, once per launch (songs downloaded before lyrics existed)
FOUNDATION_EXPORT void YTMUPrefetchLyricsForSong(NSURL *audioURL, NSString *videoID, NSString *title, NSString *artist, NSTimeInterval duration);
// Lyrics follow their song when it's renamed / deleted
FOUNDATION_EXPORT void YTMUMoveLyrics(NSURL *fromAudioURL, NSURL *toAudioURL);
FOUNDATION_EXPORT void YTMUDeleteLyrics(NSURL *audioURL);
// Removes lyrics of songs no longer in the folder
FOUNDATION_EXPORT void YTMUCleanLyricsFolder(NSURL *folder);
