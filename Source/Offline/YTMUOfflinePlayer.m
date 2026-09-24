#import "YTMUOfflinePlayer.h"
#import <MediaPlayer/MediaPlayer.h>

NSString *const YTMUOfflinePlayerDidChangeNotification = @"YTMUOfflinePlayerDidChange";
NSString *const YTMUOfflinePlayerProgressNotification = @"YTMUOfflinePlayerProgress";

#pragma mark - Remote ownership

// YES from the moment offline music starts until YTM plays something again
static BOOL ytmuOwnsRemote = NO;
static NSTimeInterval ytmuOwnedSince = 0;
static BOOL ytmuRegisteringTargets = NO;
static BOOL ytmuWritingNowPlaying = NO;

BOOL YTMUOfflinePlayerOwnsRemote(void) {
    return ytmuOwnsRemote;
}

BOOL YTMUOfflinePlayerIsRegisteringTargets(void) {
    return ytmuRegisteringTargets;
}

BOOL YTMUOfflinePlayerIsWritingNowPlaying(void) {
    return ytmuWritingNowPlaying;
}

#pragma mark - Track

@implementation YTMUOfflineTrack

static NSString *YTMUMetadataString(AVMetadataItem *item) {
    NSString *value = item.stringValue;
    return value.length ? value : nil;
}

+ (instancetype)trackWithURL:(NSURL *)url fallbackArtwork:(UIImage *)fallback {
    return [self trackWithURL:url fallbackArtwork:fallback readArtwork:YES];
}

+ (instancetype)lightTrackWithURL:(NSURL *)url {
    YTMUOfflineTrack *track = [self trackWithURL:url fallbackArtwork:nil readArtwork:NO];
    NSDate *date = nil;
    [url getResourceValue:&date forKey:NSURLCreationDateKey error:nil];
    track.addedDate = date;
    return track;
}

// Embedded cover, else "Name.png" next to the file, else the folder's cover.png
+ (UIImage *)artworkForURL:(NSURL *)url {
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];
    for (AVMetadataItem *item in asset.commonMetadata) {
        if ([item.commonKey isEqualToString:AVMetadataCommonKeyArtwork] && item.dataValue) {
            UIImage *image = [UIImage imageWithData:item.dataValue];
            if (image)
                return image;
        }
    }
    UIImage *png = [UIImage imageWithContentsOfFile:[[url URLByDeletingPathExtension] URLByAppendingPathExtension:@"png"].path];
    if (png)
        return png;
    return [UIImage imageWithContentsOfFile:[[url URLByDeletingLastPathComponent] URLByAppendingPathComponent:@"cover.png"].path];
}

- (void)loadArtworkIfNeeded {
    if (!self.artwork && self.url)
        self.artwork = [YTMUOfflineTrack artworkForURL:self.url];
}

- (void)loadThumbnailIfNeeded {
    if (self.thumbnail || !self.url)
        return;
    UIImage *image = self.artwork ?: [YTMUOfflineTrack artworkForURL:self.url];
    if (!image)
        return;
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.opaque = YES;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(56, 56) format:format];
    self.thumbnail = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        // Aspect fill into the square
        CGSize size = image.size;
        CGFloat scale = MAX(56.0 / MAX(size.width, 1), 56.0 / MAX(size.height, 1));
        CGSize drawn = CGSizeMake(size.width * scale, size.height * scale);
        [image drawInRect:CGRectMake((56 - drawn.width) / 2.0, (56 - drawn.height) / 2.0, drawn.width, drawn.height)];
    }];
}

+ (instancetype)trackWithURL:(NSURL *)url fallbackArtwork:(UIImage *)fallback readArtwork:(BOOL)readArtwork {
    YTMUOfflineTrack *track = [YTMUOfflineTrack new];
    track.url = url;
    track.format = url.pathExtension.lowercaseString;

    // "288. Title.m4a" -> number 288, title "Title" (used when tags are missing)
    NSString *baseName = url.lastPathComponent.stringByDeletingPathExtension;
    NSRegularExpression *numbered = [NSRegularExpression regularExpressionWithPattern:@"^(\\d+)\\.\\s+(.+)$" options:0 error:nil];
    NSTextCheckingResult *match = [numbered firstMatchInString:baseName options:0 range:NSMakeRange(0, baseName.length)];
    if (match) {
        track.number = [[baseName substringWithRange:[match rangeAtIndex:1]] integerValue];
        track.title = [baseName substringWithRange:[match rangeAtIndex:2]];
    } else {
        track.title = baseName;
    }

    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];
    for (AVMetadataItem *item in asset.commonMetadata) {
        NSString *key = item.commonKey;
        if ([key isEqualToString:AVMetadataCommonKeyTitle] && YTMUMetadataString(item))
            track.title = YTMUMetadataString(item);
        else if ([key isEqualToString:AVMetadataCommonKeyArtist] && YTMUMetadataString(item))
            track.artist = YTMUMetadataString(item);
        else if ([key isEqualToString:AVMetadataCommonKeyAlbumName] && YTMUMetadataString(item))
            track.album = YTMUMetadataString(item);
        else if (readArtwork && [key isEqualToString:AVMetadataCommonKeyArtwork] && !track.artwork && item.dataValue)
            track.artwork = [UIImage imageWithData:item.dataValue];
        else if ([key isEqualToString:AVMetadataCommonKeyCreationDate] && YTMUMetadataString(item).length >= 4)
            track.year = [YTMUMetadataString(item) substringToIndex:4];
    }

    // Album artist, track number and year aren't "common" keys: look at the raw tags
    for (NSString *format in asset.availableMetadataFormats) {
        for (AVMetadataItem *item in [asset metadataForFormat:format]) {
            NSString *identifier = item.identifier;
            if ([identifier isEqualToString:AVMetadataIdentifieriTunesMetadataAlbumArtist] ||
                [identifier isEqualToString:AVMetadataIdentifierID3MetadataBand]) {
                if (YTMUMetadataString(item))
                    track.albumArtist = YTMUMetadataString(item);
            } else if ([identifier isEqualToString:AVMetadataIdentifierID3MetadataTrackNumber]) {
                NSInteger number = [YTMUMetadataString(item) integerValue];
                if (number > 0)
                    track.number = number;
            } else if ([identifier isEqualToString:AVMetadataIdentifieriTunesMetadataTrackNumber]) {
                NSData *data = item.dataValue;
                if (data.length >= 4) {
                    const uint8_t *b = data.bytes;
                    NSInteger number = ((NSInteger)b[2] << 8) | b[3];
                    if (number > 0)
                        track.number = number;
                } else if ([item.value isKindOfClass:[NSNumber class]] && [(NSNumber *)item.value integerValue] > 0) {
                    track.number = [(NSNumber *)item.value integerValue];
                }
            } else if (!track.year && ([identifier isEqualToString:AVMetadataIdentifierID3MetadataYear] ||
                                       [identifier isEqualToString:AVMetadataIdentifieriTunesMetadataReleaseDate])) {
                NSString *year = YTMUMetadataString(item);
                if (year.length >= 4)
                    track.year = [year substringToIndex:4];
            }
        }
    }

    // Duration without CoreMedia: frames / sample rate
    AVAudioFile *file = [[AVAudioFile alloc] initForReading:url error:nil];
    if (file && file.fileFormat.sampleRate > 0)
        track.duration = (NSTimeInterval)file.length / file.fileFormat.sampleRate;

    if (!track.artwork)
        track.artwork = fallback;
    return track;
}

@end

#pragma mark - Player

@interface YTMUOfflinePlayer () <AVAudioPlayerDelegate>
- (void)releaseRemote;
- (void)unregisterRemoteCommands;
- (BOOL)handlesCommand:(id)command;
@property (nonatomic, readwrite) NSArray<YTMUOfflineTrack *> *tracks;
@property (nonatomic, strong) NSArray<NSNumber *> *order;   // play order (indexes into tracks)
@property (nonatomic) NSInteger position;                   // position in order
@property (nonatomic, readwrite) BOOL isShuffled;
@property (nonatomic, strong) AVAudioPlayer *audioPlayer;
@property (nonatomic, strong) NSTimer *progressTimer;
@property (nonatomic, strong) NSMutableArray *commandTargets;
@end

@implementation YTMUOfflinePlayer

+ (instancetype)shared {
    static YTMUOfflinePlayer *shared = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        shared = [YTMUOfflinePlayer new];
        shared.commandTargets = [NSMutableArray array];
        // YouTube Music started playing something: step aside
        [[NSNotificationCenter defaultCenter] addObserver:shared selector:@selector(appPlayerDidActivate:) name:@"YTMUPlayerDidActivateVideo" object:nil];
    });
    return shared;
}

- (void)appPlayerDidActivate:(NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self releaseRemote];
        if (self.audioPlayer.isPlaying)
            [self pause];
    });
}

#pragma mark Remote ownership

- (void)takeRemote {
    ytmuOwnsRemote = YES;
    ytmuOwnedSince = [NSDate timeIntervalSinceReferenceDate];
    [self registerRemoteCommands];
}

// YTM is playing again: its lock-screen controls take over
- (void)releaseRemote {
    if (!ytmuOwnsRemote)
        return;
    ytmuOwnsRemote = NO;
    [self unregisterRemoteCommands];
}

- (BOOL)handlesCommand:(id)command {
    for (NSArray *pair in self.commandTargets) {
        if (pair[0] == command)
            return YES;
    }
    return NO;
}

#pragma mark State

- (YTMUOfflineTrack *)currentTrack {
    if (self.position < 0 || self.position >= (NSInteger)self.order.count)
        return nil;
    NSInteger index = self.order[(NSUInteger)self.position].integerValue;
    return index < (NSInteger)self.tracks.count ? self.tracks[(NSUInteger)index] : nil;
}

- (BOOL)isPlaying {
    return self.audioPlayer.isPlaying;
}

- (NSTimeInterval)currentTime {
    return self.audioPlayer.currentTime;
}

- (NSTimeInterval)duration {
    return self.audioPlayer ? self.audioPlayer.duration : self.currentTrack.duration;
}

- (void)notifyChange {
    [self updateNowPlaying];
    [[NSNotificationCenter defaultCenter] postNotificationName:YTMUOfflinePlayerDidChangeNotification object:self];
}

#pragma mark Queue

- (NSArray<NSNumber *> *)orderStartingAt:(NSInteger)startIndex shuffled:(BOOL)shuffled {
    NSMutableArray<NSNumber *> *order = [NSMutableArray array];
    for (NSUInteger i = 0; i < self.tracks.count; i++)
        [order addObject:@(i)];
    if (!shuffled)
        return order;

    // Fisher-Yates, then move the start song to the front
    for (NSUInteger i = order.count; i > 1; i--)
        [order exchangeObjectAtIndex:i - 1 withObjectAtIndex:arc4random_uniform((uint32_t)i)];
    if (startIndex >= 0) {
        [order removeObject:@(startIndex)];
        [order insertObject:@(startIndex) atIndex:0];
    }
    return order;
}

- (void)playTracks:(NSArray<YTMUOfflineTrack *> *)tracks startIndex:(NSInteger)index shuffle:(BOOL)shuffle {
    if (tracks.count == 0)
        return;
    self.tracks = tracks;
    self.isShuffled = shuffle;
    NSInteger start = (index >= 0 && index < (NSInteger)tracks.count) ? index : (shuffle ? (NSInteger)arc4random_uniform((uint32_t)tracks.count) : 0);
    self.order = [self orderStartingAt:start shuffled:shuffle];
    self.position = shuffle ? 0 : start;
    [self loadCurrentAndPlay:YES];
}

- (void)setShuffled:(BOOL)shuffled {
    if (self.tracks.count == 0) {
        self.isShuffled = shuffled;
        return;
    }
    NSInteger current = self.order[(NSUInteger)self.position].integerValue;
    self.isShuffled = shuffled;
    self.order = [self orderStartingAt:current shuffled:shuffled];
    self.position = shuffled ? 0 : current;
    [self notifyChange];
}

- (void)cycleRepeatMode {
    self.repeatMode = (self.repeatMode + 1) % 3;
    [self notifyChange];
}

#pragma mark Playback

- (void)activateSession {
    AVAudioSession *session = [AVAudioSession sharedInstance];
    [session setCategory:AVAudioSessionCategoryPlayback error:nil];
    [session setActive:YES error:nil];
}

- (void)loadCurrentAndPlay:(BOOL)autoplay {
    YTMUOfflineTrack *track = self.currentTrack;
    [self.audioPlayer stop];
    self.audioPlayer = nil;
    if (!track) {
        [self notifyChange];
        return;
    }

    YTMUPauseAppPlayer();
    [self activateSession];
    [self takeRemote];
    [track loadArtworkIfNeeded]; // library tracks come without cover
    YTMURecordHistory(track.url, NO);

    self.audioPlayer = [[AVAudioPlayer alloc] initWithContentsOfURL:track.url error:nil];
    self.audioPlayer.delegate = self;
    [self.audioPlayer prepareToPlay];
    if (autoplay)
        [self.audioPlayer play];

    [self startProgressTimer];
    [self notifyChange];
}

- (void)play {
    if (!self.audioPlayer) {
        [self loadCurrentAndPlay:YES];
        return;
    }
    YTMUPauseAppPlayer();
    [self activateSession];
    [self takeRemote];
    [self.audioPlayer play];
    [self startProgressTimer];
    [self notifyChange];
}

- (void)pause {
    [self.audioPlayer pause];
    [self notifyChange];
}

- (void)togglePlayPause {
    if (self.isPlaying)
        [self pause];
    else
        [self play];
}

- (void)next {
    if (self.order.count == 0)
        return;
    if (self.position + 1 < (NSInteger)self.order.count) {
        self.position++;
    } else if (self.repeatMode == YTMURepeatAll) {
        self.position = 0;
    } else {
        // End of the list: stop on the last song, back at its start
        [self.audioPlayer stop];
        self.audioPlayer.currentTime = 0;
        [self notifyChange];
        return;
    }
    [self loadCurrentAndPlay:YES];
}

- (void)previous {
    if (self.audioPlayer.currentTime > 3.0 || self.position == 0) {
        self.audioPlayer.currentTime = 0;
        [self notifyChange];
        return;
    }
    self.position--;
    [self loadCurrentAndPlay:YES];
}

- (void)seekTo:(NSTimeInterval)time {
    self.audioPlayer.currentTime = MAX(0, MIN(time, self.audioPlayer.duration));
    [self notifyChange];
}

- (void)stop {
    [self.audioPlayer stop];
    self.audioPlayer = nil;
    self.tracks = @[];
    self.order = @[];
    self.position = 0;
    [self.progressTimer invalidate];
    self.progressTimer = nil;
    [self unregisterRemoteCommands];
    ytmuOwnsRemote = NO;
    ytmuWritingNowPlaying = YES;
    [MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo = nil;
    ytmuWritingNowPlaying = NO;
    [[NSNotificationCenter defaultCenter] postNotificationName:YTMUOfflinePlayerDidChangeNotification object:self];
}

- (void)audioPlayerDidFinishPlaying:(AVAudioPlayer *)player successfully:(BOOL)flag {
    if (self.repeatMode == YTMURepeatOne) {
        player.currentTime = 0;
        [player play];
        [self notifyChange];
        return;
    }
    [self next];
}

- (void)startProgressTimer {
    if (self.progressTimer)
        return;
    __weak __typeof(self) weakSelf = self;
    self.progressTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *timer) {
        [[NSNotificationCenter defaultCenter] postNotificationName:YTMUOfflinePlayerProgressNotification object:weakSelf];
    }];
}

#pragma mark Lock screen

- (void)updateNowPlaying {
    YTMUOfflineTrack *track = self.currentTrack;
    // Not ours while YTM has the lock screen
    if (!track || !self.audioPlayer || !ytmuOwnsRemote)
        return;

    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    info[MPMediaItemPropertyTitle] = track.title ?: @"";
    if (track.artist)
        info[MPMediaItemPropertyArtist] = track.artist;
    if (track.album)
        info[MPMediaItemPropertyAlbumTitle] = track.album;
    info[MPMediaItemPropertyPlaybackDuration] = @(self.audioPlayer.duration);
    info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = @(self.audioPlayer.currentTime);
    info[MPNowPlayingInfoPropertyPlaybackRate] = @(self.audioPlayer.isPlaying ? 1.0 : 0.0);

    UIImage *artwork = track.artwork;
    if (artwork) {
        info[MPMediaItemPropertyArtwork] = [[MPMediaItemArtwork alloc] initWithBoundsSize:artwork.size requestHandler:^UIImage *(CGSize size) {
            return artwork;
        }];
    }
    ytmuWritingNowPlaying = YES;
    [MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo = info;
    ytmuWritingNowPlaying = NO;
}

- (void)registerRemoteCommands {
    if (self.commandTargets.count)
        return;
    MPRemoteCommandCenter *center = [MPRemoteCommandCenter sharedCommandCenter];
    __weak __typeof(self) weakSelf = self;
    // Our targets must not get wrapped by YTMURemoteGuard.x
    ytmuRegisteringTargets = YES;

    [self.commandTargets addObject:@[center.playCommand, [center.playCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {
        [weakSelf play];
        return MPRemoteCommandHandlerStatusSuccess;
    }]]];
    [self.commandTargets addObject:@[center.pauseCommand, [center.pauseCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {
        [weakSelf pause];
        return MPRemoteCommandHandlerStatusSuccess;
    }]]];
    [self.commandTargets addObject:@[center.togglePlayPauseCommand, [center.togglePlayPauseCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {
        [weakSelf togglePlayPause];
        return MPRemoteCommandHandlerStatusSuccess;
    }]]];
    [self.commandTargets addObject:@[center.nextTrackCommand, [center.nextTrackCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {
        [weakSelf next];
        return MPRemoteCommandHandlerStatusSuccess;
    }]]];
    [self.commandTargets addObject:@[center.previousTrackCommand, [center.previousTrackCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {
        [weakSelf previous];
        return MPRemoteCommandHandlerStatusSuccess;
    }]]];
    [self.commandTargets addObject:@[center.changePlaybackPositionCommand, [center.changePlaybackPositionCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {
        if ([event isKindOfClass:[MPChangePlaybackPositionCommandEvent class]])
            [weakSelf seekTo:((MPChangePlaybackPositionCommandEvent *)event).positionTime];
        return MPRemoteCommandHandlerStatusSuccess;
    }]]];
    ytmuRegisteringTargets = NO;

    // YTM may have greyed some of them out
    for (NSArray *pair in self.commandTargets)
        ((MPRemoteCommand *)pair[0]).enabled = YES;
}

- (void)unregisterRemoteCommands {
    for (NSArray *pair in self.commandTargets) {
        MPRemoteCommand *command = pair[0];
        [command removeTarget:pair[1]];
    }
    [self.commandTargets removeAllObjects];
}

@end

BOOL YTMUOfflinePlayerHandlesCommand(id command) {
    return ytmuOwnsRemote && [[YTMUOfflinePlayer shared] handlesCommand:command];
}

BOOL YTMUOfflinePlayerShouldBlockAppNowPlaying(NSDictionary *info) {
    if (!ytmuOwnsRemote)
        return NO;
    id rate = info[MPNowPlayingInfoPropertyPlaybackRate];
    BOOL appIsPlaying = [rate isKindOfClass:[NSNumber class]] && [(NSNumber *)rate doubleValue] > 0;
    // Right after the offline start YTM can still report its old "playing" state
    if (appIsPlaying && [NSDate timeIntervalSinceReferenceDate] - ytmuOwnedSince > 2.0) {
        // YTM really plays again (resumed from its own UI): step aside
        ytmuOwnsRemote = NO;
        dispatch_async(dispatch_get_main_queue(), ^{
            YTMUOfflinePlayer *player = [YTMUOfflinePlayer shared];
            if (ytmuOwnsRemote) // offline music was started again meanwhile
                return;
            [player unregisterRemoteCommands];
            if (player.isPlaying)
                [player pause];
        });
        return NO;
    }
    return YES;
}
