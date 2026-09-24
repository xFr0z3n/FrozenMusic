#import "FrozenDiscordConfig.h"
#import <Security/Security.h>

NSString *const FrozenDiscordTokenKey = @"token";
NSString *const FrozenDiscordAppIDKey = @"appID";
NSString *const FrozenDiscordWebDAVURLKey = @"webdavURL";
NSString *const FrozenDiscordWebDAVUserKey = @"webdavUser";
NSString *const FrozenDiscordWebDAVPassKey = @"webdavPass";
NSString *const FrozenDiscordPublicURLKey = @"publicURL";

static NSString *const FrozenDiscordDefaultsKey = @"FrozenDiscordRPC";
static NSString *const FrozenDiscordKeychainService = @"com.fr0z3n.frozenmusic.discord";

static BOOL FrozenDiscordIsSecret(NSString *key) {
    return [key isEqualToString:FrozenDiscordTokenKey] || [key isEqualToString:FrozenDiscordWebDAVPassKey];
}

static NSDictionary *FrozenDiscordDefaults(void) {
    NSDictionary *stored = [[NSUserDefaults standardUserDefaults] dictionaryForKey:FrozenDiscordDefaultsKey];
    return [stored isKindOfClass:[NSDictionary class]] ? stored : @{};
}

static void FrozenDiscordSetDefaultsValue(NSString *key, id value) {
    NSMutableDictionary *stored = [FrozenDiscordDefaults() mutableCopy];
    if (value)
        stored[key] = value;
    else
        [stored removeObjectForKey:key];
    [[NSUserDefaults standardUserDefaults] setObject:stored forKey:FrozenDiscordDefaultsKey];
}

static NSMutableDictionary *FrozenDiscordKeychainQuery(NSString *key) {
    return [@{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: FrozenDiscordKeychainService,
        (__bridge id)kSecAttrAccount: key
    } mutableCopy];
}

NSString *FrozenDiscordStoredValue(NSString *key) {
    if (FrozenDiscordIsSecret(key)) {
        NSMutableDictionary *query = FrozenDiscordKeychainQuery(key);
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
    NSString *value = FrozenDiscordDefaults()[key];
    return [value isKindOfClass:[NSString class]] && value.length ? value : nil;
}

void FrozenDiscordSetStoredValue(NSString *key, NSString *value) {
    value = [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (FrozenDiscordIsSecret(key)) {
        SecItemDelete((__bridge CFDictionaryRef)FrozenDiscordKeychainQuery(key));
        FrozenDiscordSetDefaultsValue(key, nil);
        if (!value.length)
            return;
        NSMutableDictionary *item = FrozenDiscordKeychainQuery(key);
        item[(__bridge id)kSecValueData] = [value dataUsingEncoding:NSUTF8StringEncoding];
        item[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleAfterFirstUnlock;
        if (SecItemAdd((__bridge CFDictionaryRef)item, NULL) != errSecSuccess)
            FrozenDiscordSetDefaultsValue(key, value);
        return;
    }
    FrozenDiscordSetDefaultsValue(key, value.length ? value : nil);
}

void FrozenDiscordClearStoredValues(void) {
    for (NSString *key in @[FrozenDiscordTokenKey, FrozenDiscordAppIDKey, FrozenDiscordWebDAVURLKey,
                            FrozenDiscordWebDAVUserKey, FrozenDiscordWebDAVPassKey, FrozenDiscordPublicURLKey])
        FrozenDiscordSetStoredValue(key, nil);
}

BOOL FrozenDiscordEnabled(void) {
    NSNumber *enabled = FrozenDiscordDefaults()[@"enabled"];
    return [enabled isKindOfClass:[NSNumber class]] ? enabled.boolValue : YES;
}

void FrozenDiscordSetEnabled(BOOL enabled) {
    FrozenDiscordSetDefaultsValue(@"enabled", @(enabled));
}
