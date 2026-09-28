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
// Checked before and has no lyrics (answers without asking again)
+ (BOOL)isKnownWithoutLyrics:(YTMUOfflineTrack *)track;
// Lyrics without timing: looks for a synced version (online, or the same song saved elsewhere)
// once per song and launch, saves it and hands it over (main queue). Nothing if there's none.
+ (void)findSyncedVersionForTrack:(YTMUOfflineTrack *)track completion:(void (^)(YTMULyrics *lyrics))completion;

// Language the lyrics are in (nil if unsure) and the device language
- (NSString *)languageCode;
+ (NSString *)deviceLanguageCode;
// One translated string per line (empty for ♪ / blank lines). Google when there's internet,
// without internet Google's on-device ML Kit models (languages downloaded in FrozenMusic >
// Offline translation). Never hangs: answers within ~20 s. Main queue.
- (void)translationForTrack:(YTMUOfflineTrack *)track presenter:(UIViewController *)presenter
                 completion:(void (^)(NSArray<NSString *> *translation, NSString *credit, NSString *error))completion;
+ (BOOL)canTranslateOnDevice;
@end

// "Lyrics/<song>.lrc" of a downloaded song
FOUNDATION_EXPORT NSURL *YTMULyricsFileForAudio(NSURL *audioURL);
// Downloads (background thread, blocks): writes the song's lyrics file. refresh: ask again even
// when there is one (replaced with the newest, removed when the song has none). NO = no lyrics
FOUNDATION_EXPORT BOOL YTMUSaveLyricsForDownload(NSURL *audioURL, NSString *videoID, NSString *title, NSString *artist, NSTimeInterval duration, BOOL refresh);
// Same in the background, once per launch (songs downloaded before lyrics existed)
FOUNDATION_EXPORT void YTMUPrefetchLyricsForSong(NSURL *audioURL, NSString *videoID, NSString *title, NSString *artist, NSTimeInterval duration);
// Lyrics follow their song when it's renamed / deleted
FOUNDATION_EXPORT void YTMUMoveLyrics(NSURL *fromAudioURL, NSURL *toAudioURL);
FOUNDATION_EXPORT void YTMUDeleteLyrics(NSURL *audioURL);
// Removes lyrics of songs no longer in the folder
FOUNDATION_EXPORT void YTMUCleanLyricsFolder(NSURL *folder);
// The offline translator (FMMLTranslator in FrozenMLTranslate.framework), nil when not in this build
FOUNDATION_EXPORT Class YTMUOfflineTranslatorClass(void);
