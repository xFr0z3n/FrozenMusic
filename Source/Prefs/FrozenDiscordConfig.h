#import <Foundation/Foundation.h>

// Discord RPC setup made in the app (FrozenMusic > Discord RPC).
// Each value set here overrides the matching build secret (GitHub Actions).
FOUNDATION_EXPORT NSString *const FrozenDiscordTokenKey;
FOUNDATION_EXPORT NSString *const FrozenDiscordAppIDKey;
FOUNDATION_EXPORT NSString *const FrozenDiscordWebDAVURLKey;
FOUNDATION_EXPORT NSString *const FrozenDiscordWebDAVUserKey;
FOUNDATION_EXPORT NSString *const FrozenDiscordWebDAVPassKey;
FOUNDATION_EXPORT NSString *const FrozenDiscordPublicURLKey;

// Value saved in the app (token and password live in the Keychain), nil if none
FOUNDATION_EXPORT NSString *FrozenDiscordStoredValue(NSString *key);
// nil / empty removes it
FOUNDATION_EXPORT void FrozenDiscordSetStoredValue(NSString *key, NSString *value);
FOUNDATION_EXPORT void FrozenDiscordClearStoredValues(void);

// Master switch, on unless turned off
FOUNDATION_EXPORT BOOL FrozenDiscordEnabled(void);
FOUNDATION_EXPORT void FrozenDiscordSetEnabled(BOOL enabled);

// From DiscordRPC.x: the value built into this IPA from the repo secrets, nil if none
FOUNDATION_EXPORT NSString *YTMUDiscordBuildValue(NSString *key);
