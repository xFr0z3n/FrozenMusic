#import <Foundation/Foundation.h>

// Offline lyrics translation for FrozenMusic with Google's on-device ML Kit models.
// Built by the GitHub Actions workflow into FrozenMLTranslate.framework (with ML Kit
// linked in) and loaded by the tweak at runtime. Language models (~30 MB each) are
// downloaded while there's internet; translating itself never needs the internet.
@interface FMMLTranslator : NSObject
// Downloads the models for this language pair in the background (Wi-Fi or mobile data)
+ (void)prepareSource:(NSString *)source target:(NSString *)target;
// Only with both models on the device: never waits for a download. Language codes like
// "ja", "en", "zh". Completion on the main queue: one translation per text, or nil + error
+ (void)translateTexts:(NSArray<NSString *> *)texts
                source:(NSString *)source
                target:(NSString *)target
            completion:(void (^)(NSArray<NSString *> *translations, NSString *error))completion;
@end
