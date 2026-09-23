#import <MediaPlayer/MediaPlayer.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "YTMUOfflinePlayer.h"

// While the offline player owns the lock screen, YTM's own remote command
// handlers (next, play, ...) must do nothing, otherwise a skip on the lock
// screen / Dynamic Island skips both players and YTM starts playing again.
// Every handler YTM adds is wrapped so it is skipped while offline music is on.

typedef MPRemoteCommandHandlerStatus (^YTMURemoteHandler)(MPRemoteCommandEvent *event);

static const void *kYTMUTargetEntriesKey = &kYTMUTargetEntriesKey;

static YTMURemoteHandler YTMUGuardedHandler(YTMURemoteHandler handler) {
    YTMURemoteHandler original = [handler copy];
    return [^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {
        if (YTMUOfflinePlayerOwnsRemote())
            return MPRemoteCommandHandlerStatusSuccess;
        return original(event);
    } copy];
}

// target -> [[token, selector name], ...] for targets added with addTarget:action:
static NSMapTable *YTMUTargetEntries(id command, BOOL create) {
    NSMapTable *map = objc_getAssociatedObject(command, kYTMUTargetEntriesKey);
    if (!map && create) {
        map = [NSMapTable weakToStrongObjectsMapTable];
        objc_setAssociatedObject(command, kYTMUTargetEntriesKey, map, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return map;
}

static BOOL YTMUIsIntegerType(const char *type) {
    if (!type)
        return NO;
    char c = type[0];
    return c == 'q' || c == 'Q' || c == 'l' || c == 'L' || c == 'i' || c == 'I';
}

%hook MPRemoteCommand

- (id)addTargetWithHandler:(YTMURemoteHandler)handler {
    if (!handler || YTMUOfflinePlayerIsRegisteringTargets())
        return %orig;
    return %orig(YTMUGuardedHandler(handler));
}

- (void)addTarget:(id)target action:(SEL)action {
    // Leave our own and MediaPlayer's internal targets alone
    if (!target || !action || YTMUOfflinePlayerIsRegisteringTargets() ||
        [NSBundle bundleForClass:[target class]] == [NSBundle bundleForClass:[MPRemoteCommand class]]) {
        %orig;
        return;
    }

    // Turn target/action into a guarded block handler
    __weak id weakTarget = target;
    YTMURemoteHandler handler = ^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {
        id strongTarget = weakTarget;
        if (!strongTarget || ![strongTarget respondsToSelector:action])
            return MPRemoteCommandHandlerStatusCommandFailed;
        NSMethodSignature *signature = [strongTarget methodSignatureForSelector:action];
        BOOL takesEvent = signature.numberOfArguments > 2;
        if (YTMUIsIntegerType(signature.methodReturnType)) {
            if (takesEvent)
                return (MPRemoteCommandHandlerStatus)((NSInteger (*)(id, SEL, id))objc_msgSend)(strongTarget, action, event);
            return (MPRemoteCommandHandlerStatus)((NSInteger (*)(id, SEL))objc_msgSend)(strongTarget, action);
        }
        if (takesEvent)
            ((void (*)(id, SEL, id))objc_msgSend)(strongTarget, action, event);
        else
            ((void (*)(id, SEL))objc_msgSend)(strongTarget, action);
        return MPRemoteCommandHandlerStatusSuccess;
    };

    id token = [self addTargetWithHandler:handler];
    if (!token)
        return;
    NSMapTable *map = YTMUTargetEntries(self, YES);
    NSMutableArray *entries = [map objectForKey:target] ?: [NSMutableArray array];
    [entries addObject:@[token, NSStringFromSelector(action)]];
    [map setObject:entries forKey:target];
}

- (void)removeTarget:(id)target action:(SEL)action {
    NSMapTable *map = YTMUTargetEntries(self, NO);
    NSMutableArray *entries = target ? [map objectForKey:target] : nil;
    if (!entries) {
        %orig;
        return;
    }
    NSString *name = action ? NSStringFromSelector(action) : nil;
    for (NSArray *entry in [entries copy]) {
        if (!name || [entry[1] isEqualToString:name]) {
            [self removeTarget:entry[0]];
            [entries removeObject:entry];
        }
    }
    if (entries.count == 0)
        [map removeObjectForKey:target];
}

- (void)removeTarget:(id)target {
    NSMapTable *map = YTMUTargetEntries(self, NO);
    NSMutableArray *entries = target ? [map objectForKey:target] : nil;
    if (!entries) {
        %orig;
        return;
    }
    [map removeObjectForKey:target];
    for (NSArray *entry in entries)
        [self removeTarget:entry[0]];
}

// YTM greys out next/previous at the end of its own queue: keep ours usable
- (void)setEnabled:(BOOL)enabled {
    if (!enabled && YTMUOfflinePlayerHandlesCommand(self))
        enabled = YES;
    %orig(enabled);
}

%end
