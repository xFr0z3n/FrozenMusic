#import <UIKit/UIKit.h>

typedef NS_ENUM(NSInteger, YTMUPanelButtonStyle) {
    YTMUPanelButtonPrimary,     // white pill
    YTMUPanelButtonSecondary,   // grey pill
    YTMUPanelButtonDestructive, // grey pill, red text
    YTMUPanelButtonPlain        // text only
};

@interface YTMUPanelButton : NSObject
+ (instancetype)buttonWithTitle:(NSString *)title style:(YTMUPanelButtonStyle)style handler:(void (^)(void))handler;
@property (nonatomic, copy) NSString *title;
@property (nonatomic) YTMUPanelButtonStyle style;
@property (nonatomic, copy) void (^handler)(void);
@end

// Box of the playlist / album downloader in the Downloads tab's style (grey card, black
// with a thin border with OLED Dark Theme): confirm, step-by-step progress, stop, summary.
// One at a time, main thread only.
@interface YTMUDownloadPanel : UIView
// Centered over a dimmed screen (blocks taps)
+ (YTMUDownloadPanel *)showCentered;
// Compact at the top: only the box itself takes taps, the page below stays usable (Play)
+ (YTMUDownloadPanel *)showAtTop;
// Centered summary with an icon that goes away by itself (or on tap)
+ (void)showMessage:(NSString *)title details:(NSString *)details symbol:(NSString *)symbol;
+ (YTMUDownloadPanel *)current;
+ (void)dismissCurrent;

@property (nonatomic, readonly) BOOL atTop;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *step;    // small line above the title ("STEP 2 OF 4 · DOWNLOADING")
@property (nonatomic, copy) NSString *details;
@property (nonatomic) float progress;          // 0...1, < 0: spinner, NAN: none
@property (nonatomic, copy) NSArray<YTMUPanelButton *> *buttons;
- (void)dismiss;
@end
