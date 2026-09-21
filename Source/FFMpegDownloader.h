#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <Photos/Photos.h>
#import "Utils/MobileFFmpeg/MobileFFmpegConfig.h"
#import "Utils/MobileFFmpeg/MobileFFmpeg.h"
#import "Utils/MobileFFmpeg/MobileFFprobe.h"
#import "Utils/MBProgressHUD/MBProgressHUD.h"
#import "Headers/Localization.h"

@interface FFMpegDownloader : NSObject <LogDelegate, StatisticsDelegate>
@property (nonatomic, strong) MBProgressHUD *hud;
@property (nonatomic, strong) NSString *tempName;
@property (nonatomic, strong) NSString *mediaName;
@property (nonatomic) NSInteger duration;

// metadata keys: title, artist, album, album_artist, track, date, comment
- (void)downloadAudio:(NSString *)audioURL metadata:(NSDictionary<NSString *, NSString *> *)metadata coverData:(NSData *)coverData;
- (void)downloadAudio:(NSString *)audioURL; // old call, no tags
- (void)downloadImage:(NSURL *)link;
- (void)shareMedia:(NSURL *)mediaURL;
@end#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <Photos/Photos.h>
#import "Utils/MobileFFmpeg/MobileFFmpegConfig.h"
#import "Utils/MobileFFmpeg/MobileFFmpeg.h"
#import "Utils/MobileFFmpeg/MobileFFprobe.h"
#import "Utils/MBProgressHUD/MBProgressHUD.h"
#import "Headers/Localization.h"

@interface FFMpegDownloader : NSObject <LogDelegate, StatisticsDelegate>
@property (nonatomic, strong) MBProgressHUD *hud;
@property (nonatomic, strong) NSString *tempName;
@property (nonatomic, strong) NSString *mediaName;
@property (nonatomic) NSInteger duration;
- (void)downloadAudio:(NSString *)audioURL;
- (void)downloadImage:(NSURL *)link;
- (void)shareMedia:(NSURL *)mediaURL;
@end
