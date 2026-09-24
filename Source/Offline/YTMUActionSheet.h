#import <UIKit/UIKit.h>

// One option in a YTM-style menu sheet
@interface YTMUSheetAction : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *symbol;  // SF Symbol name
@property (nonatomic, copy) void (^handler)(void);
+ (instancetype)actionWithTitle:(NSString *)title symbol:(NSString *)symbol handler:(void (^)(void))handler;
@end

// YTM's bottom sheet: title + subtitle + ✕, big tiles (Play next, Share...),
// then icon rows. Dark grey, or pure black with the OLED theme.
@interface YTMUActionSheet : UIViewController
+ (instancetype)sheetWithTitle:(NSString *)title subtitle:(NSString *)subtitle;
- (void)addTile:(YTMUSheetAction *)action;
- (void)addAction:(YTMUSheetAction *)action;
- (void)presentFrom:(UIViewController *)presenter;
@end

// Small message box in the middle of the screen ("No album found"), fades out by itself
FOUNDATION_EXPORT void YTMUShowInfoBox(UIViewController *presenter, NSString *text);
