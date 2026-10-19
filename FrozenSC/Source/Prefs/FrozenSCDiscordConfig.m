#import "FrozenSCDiscordConfig.h"
#import <Security/Security.h>

NSString *const FrozenSCDiscordTokenKey = @"token";
NSString *const FrozenSCDiscordAppIDKey = @"appID";
NSString *const FrozenSCDiscordWebDAVURLKey = @"webdavURL";
NSString *const FrozenSCDiscordWebDAVUserKey = @"webdavUser";
NSString *const FrozenSCDiscordWebDAVPassKey = @"webdavPass";
NSString *const FrozenSCDiscordPublicURLKey = @"publicURL";

static NSString *const FrozenSCDiscordDefaultsKey = @"FrozenSCDiscordRPC";
static NSString *const FrozenSCDiscordKeychainService = @"com.fr0z3n.frozensc.discord";

static BOOL FrozenSCDiscordIsSecret(NSString *key) {
    return [key isEqualToString:FrozenSCDiscordTokenKey] || [key isEqualToString:FrozenSCDiscordWebDAVPassKey];
}

static NSDictionary *FrozenSCDiscordDefaults(void) {
    NSDictionary *stored = [[NSUserDefaults standardUserDefaults] dictionaryForKey:FrozenSCDiscordDefaultsKey];
    return [stored isKindOfClass:[NSDictionary class]] ? stored : @{};
}

static void FrozenSCDiscordSetDefaultsValue(NSString *key, id value) {
    NSMutableDictionary *stored = [FrozenSCDiscordDefaults() mutableCopy];
    if (value)
        stored[key] = value;
    else
        [stored removeObjectForKey:key];
    [[NSUserDefaults standardUserDefaults] setObject:stored forKey:FrozenSCDiscordDefaultsKey];
}

static NSMutableDictionary *FrozenSCDiscordKeychainQuery(NSString *key) {
    return [@{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: FrozenSCDiscordKeychainService,
        (__bridge id)kSecAttrAccount: key
    } mutableCopy];
}

NSString *FrozenSCDiscordStoredValue(NSString *key) {
    if (FrozenSCDiscordIsSecret(key)) {
        NSMutableDictionary *query = FrozenSCDiscordKeychainQuery(key);
        query[(__bridge id)kSecReturnData] = @YES;
        query[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
        CFTypeRef result = NULL;
        if (SecItemCopyMatching((__bridge CFDictionaryRef)query, &result) == errSecSuccess && result) {
            NSData *data = (__bridge_transfer NSData *)result;
            NSString *value = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            if (value.length)
                return value;
        }
    }
    // Everything else, and secrets when the Keychain isn't available (some sideload signers)
    NSString *value = FrozenSCDiscordDefaults()[key];
    return [value isKindOfClass:[NSString class]] && value.length ? value : nil;
}

void FrozenSCDiscordSetStoredValue(NSString *key, NSString *value) {
    value = [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (FrozenSCDiscordIsSecret(key)) {
        SecItemDelete((__bridge CFDictionaryRef)FrozenSCDiscordKeychainQuery(key));
        FrozenSCDiscordSetDefaultsValue(key, nil);
        if (!value.length)
            return;
        NSMutableDictionary *item = FrozenSCDiscordKeychainQuery(key);
        item[(__bridge id)kSecValueData] = [value dataUsingEncoding:NSUTF8StringEncoding];
        item[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleAfterFirstUnlock;
        if (SecItemAdd((__bridge CFDictionaryRef)item, NULL) != errSecSuccess)
            FrozenSCDiscordSetDefaultsValue(key, value);
        return;
    }
    FrozenSCDiscordSetDefaultsValue(key, value.length ? value : nil);
}

void FrozenSCDiscordClearStoredValues(void) {
    for (NSString *key in @[FrozenSCDiscordTokenKey, FrozenSCDiscordAppIDKey, FrozenSCDiscordWebDAVURLKey,
                            FrozenSCDiscordWebDAVUserKey, FrozenSCDiscordWebDAVPassKey, FrozenSCDiscordPublicURLKey])
        FrozenSCDiscordSetStoredValue(key, nil);
}

BOOL FrozenSCDiscordEnabled(void) {
    NSNumber *enabled = FrozenSCDiscordDefaults()[@"enabled"];
    return [enabled isKindOfClass:[NSNumber class]] ? enabled.boolValue : YES;
}

void FrozenSCDiscordSetEnabled(BOOL enabled) {
    FrozenSCDiscordSetDefaultsValue(@"enabled", @(enabled));
}
