#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <Photos/Photos.h>
#import "Utils/MobileFFmpeg/MobileFFmpegConfig.h"
#import "Utils/MobileFFmpeg/MobileFFmpeg.h"
#import "Utils/MobileFFmpeg/MobileFFprobe.h"
#import "Utils/MBProgressHUD/MBProgressHUD.h"
#import "Headers/Localization.h"

@class YTMUDownloadPanel;

@interface FFMpegDownloader : NSObject <LogDelegate, StatisticsDelegate>
@property (nonatomic, weak) YTMUDownloadPanel *panel; // progress box (Downloads tab style, OLED aware)
@property (nonatomic, strong) NSString *tempName;
@property (nonatomic, strong) NSString *mediaName;
@property (nonatomic) NSInteger duration;
@property (nonatomic, copy) NSString *format; // "m4a" (default) or "mp3"
@property (nonatomic, copy) NSString *videoID; // set: the song's lyrics are saved to YTMusicUltimate/Lyrics

// metadata keys: title, artist, album, album_artist, track, date, comment
- (void)downloadAudio:(NSString *)audioURL metadata:(NSDictionary<NSString *, NSString *> *)metadata coverData:(NSData *)coverData;
- (void)downloadAudio:(NSString *)audioURL; // old call, no tags
- (void)downloadImage:(NSURL *)link;
- (void)shareMedia:(NSURL *)mediaURL;
// Inserts a JPEG cover into an ffmpeg-written .m4a in place. NO = file untouched.
- (BOOL)writeCoverAtom:(NSData *)jpegData intoFile:(NSURL *)fileURL;
@end
