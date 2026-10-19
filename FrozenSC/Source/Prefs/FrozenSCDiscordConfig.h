#import <Foundation/Foundation.h>

// Discord RPC setup made in the app (FrozenSC > Discord RPC).
// Each value set here overrides the matching build secret (GitHub Actions).
FOUNDATION_EXPORT NSString *const FrozenSCDiscordTokenKey;
FOUNDATION_EXPORT NSString *const FrozenSCDiscordAppIDKey;
FOUNDATION_EXPORT NSString *const FrozenSCDiscordWebDAVURLKey;
FOUNDATION_EXPORT NSString *const FrozenSCDiscordWebDAVUserKey;
FOUNDATION_EXPORT NSString *const FrozenSCDiscordWebDAVPassKey;
FOUNDATION_EXPORT NSString *const FrozenSCDiscordPublicURLKey;

// Value saved in the app (token and password live in the Keychain), nil if none
FOUNDATION_EXPORT NSString *FrozenSCDiscordStoredValue(NSString *key);
// nil / empty removes it
FOUNDATION_EXPORT void FrozenSCDiscordSetStoredValue(NSString *key, NSString *value);
FOUNDATION_EXPORT void FrozenSCDiscordClearStoredValues(void);

// Master switch, on unless turned off
FOUNDATION_EXPORT BOOL FrozenSCDiscordEnabled(void);
FOUNDATION_EXPORT void FrozenSCDiscordSetEnabled(BOOL enabled);

// From DiscordRPC.x: the value built into this IPA from the repo secrets, nil if none
FOUNDATION_EXPORT NSString *FrozenSCDiscordBuildValue(NSString *key);
