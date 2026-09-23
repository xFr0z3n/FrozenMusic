#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>

// Posted when the song, play state, shuffle or repeat changes
FOUNDATION_EXPORT NSString *const YTMUOfflinePlayerDidChangeNotification;
// Posted about twice a second while playing (progress bars)
FOUNDATION_EXPORT NSString *const YTMUOfflinePlayerProgressNotification;

// Implemented in Downloading.x: pauses YouTube Music's own player
FOUNDATION_EXPORT void YTMUPauseAppPlayer(void);

// Lock screen / Control Center ownership (used by the hooks in YTMURemoteGuard.x
// and Downloading.x so YTM's own handlers stay quiet while offline music is on)
FOUNDATION_EXPORT BOOL YTMUOfflinePlayerOwnsRemote(void);
FOUNDATION_EXPORT BOOL YTMUOfflinePlayerIsRegisteringTargets(void);
FOUNDATION_EXPORT BOOL YTMUOfflinePlayerHandlesCommand(id command);
FOUNDATION_EXPORT BOOL YTMUOfflinePlayerIsWritingNowPlaying(void);
// YES = drop this lock-screen info YTM wants to set (offline player is showing its own)
FOUNDATION_EXPORT BOOL YTMUOfflinePlayerShouldBlockAppNowPlaying(NSDictionary *info);

#pragma mark - Track

@interface YTMUOfflineTrack : NSObject
@property (nonatomic, strong) NSURL *url;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *artist;
@property (nonatomic, copy) NSString *album;
@property (nonatomic, copy) NSString *albumArtist;
@property (nonatomic, copy) NSString *year;
@property (nonatomic, copy) NSString *format;     // "m4a" / "mp3"
@property (nonatomic) NSInteger number;           // track number (0 = unknown)
@property (nonatomic) NSTimeInterval duration;
@property (nonatomic, strong) UIImage *artwork;

// Reads the file's tags + cover. Slow for big lists: call off the main thread.
+ (instancetype)trackWithURL:(NSURL *)url fallbackArtwork:(UIImage *)fallback;
@end

#pragma mark - Player

typedef NS_ENUM(NSInteger, YTMURepeatMode) {
    YTMURepeatOff = 0,
    YTMURepeatAll,
    YTMURepeatOne
};

@interface YTMUOfflinePlayer : NSObject
+ (instancetype)shared;

@property (nonatomic, readonly) NSArray<YTMUOfflineTrack *> *tracks;
@property (nonatomic, readonly) YTMUOfflineTrack *currentTrack;
@property (nonatomic, readonly) BOOL isPlaying;
@property (nonatomic, readonly) BOOL isShuffled;
@property (nonatomic) YTMURepeatMode repeatMode;
@property (nonatomic, readonly) NSTimeInterval currentTime;
@property (nonatomic, readonly) NSTimeInterval duration;

- (void)playTracks:(NSArray<YTMUOfflineTrack *> *)tracks startIndex:(NSInteger)index shuffle:(BOOL)shuffle;
- (void)togglePlayPause;
- (void)play;
- (void)pause;
- (void)next;
- (void)previous;
- (void)seekTo:(NSTimeInterval)time;
- (void)setShuffled:(BOOL)shuffled;
- (void)cycleRepeatMode;
- (void)stop;
@end
