// TEMPORARY - delete this file after we have the playlist download button's key.
// Shows a small popup with the internal name of every tapped button and copies it.

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "Utils/MBProgressHUD/MBProgressHUD.h"

@interface UIView ()
- (UIViewController *)_viewControllerForAncestor;
@end

@interface ELMTouchCommandPropertiesHandler : NSObject
@end

static id YTMUDebugValue(id object, const char *ivarName) {
    if (!object || !class_getInstanceVariable([object class], ivarName))
        return nil;
    @try {
        return [object valueForKey:[NSString stringWithUTF8String:ivarName]];
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

%hook ELMTouchCommandPropertiesHandler
- (void)handleTap {
    @try {
        id node = YTMUDebugValue(self, "_controller");
        id tapRecognizer = YTMUDebugValue(self, "_tapRecognizer");

        NSString *key = nil;
        if ([node respondsToSelector:NSSelectorFromString(@"key")]) {
            id value = [node valueForKey:@"key"];
            key = [value isKindOfClass:[NSString class]] ? value : nil;
        }

        UIView *view = [tapRecognizer isKindOfClass:[UIGestureRecognizer class]] ? ((UIGestureRecognizer *)tapRecognizer).view : nil;
        NSMutableArray<NSString *> *chain = [NSMutableArray array];
        UIViewController *vc = [view respondsToSelector:@selector(_viewControllerForAncestor)] ? view._viewControllerForAncestor : nil;
        for (; vc && chain.count < 6; vc = vc.parentViewController)
            [chain addObject:NSStringFromClass([vc class])];

        NSString *text = [NSString stringWithFormat:@"key: %@\nnode: %@\nview: %@\nVCs: %@",
                          key ?: @"(none)",
                          node ? NSStringFromClass([node class]) : @"(none)",
                          view ? NSStringFromClass([view class]) : @"(none)",
                          chain.count ? [chain componentsJoinedByString:@" > "] : @"(none)"];

        [UIPasteboard generalPasteboard].string = text;

        dispatch_async(dispatch_get_main_queue(), ^{
            UIWindow *window = [UIApplication sharedApplication].keyWindow;
            if (!window)
                return;
            MBProgressHUD *hud = [MBProgressHUD showHUDAddedTo:window animated:YES];
            hud.mode = MBProgressHUDModeText;
            hud.userInteractionEnabled = NO; // touches pass through
            hud.label.text = @"Tap debug (copied)";
            hud.detailsLabel.text = text;
            [hud hideAnimated:YES afterDelay:5.0];
        });
    } @catch (__unused NSException *exception) {
    }

    %orig;
}
%end
