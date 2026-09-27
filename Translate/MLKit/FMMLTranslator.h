#import <Foundation/Foundation.h>

// Offline lyrics translation for FrozenMusic with Google's on-device ML Kit models.
// Built by the GitHub Actions workflow into FrozenMLTranslate.framework (with ML Kit
// linked in) and loaded by the tweak at runtime. A language model (~30 MB) is
// downloaded once per language, after that translating works without internet.
@interface FMMLTranslator : NSObject
+ (BOOL)isSupported;
// Language codes like "ja", "en", "zh". Completion on the main queue:
// one translation per text (same order), or nil + error message
+ (void)translateTexts:(NSArray<NSString *> *)texts
                source:(NSString *)source
                target:(NSString *)target
            completion:(void (^)(NSArray<NSString *> *translations, NSString *error))completion;
@end
