#import <Foundation/Foundation.h>

// Offline lyrics translation for FrozenMusic with Google's on-device ML Kit models.
// Built by the GitHub Actions workflow into FrozenMLTranslate.framework (with ML Kit
// linked in) and loaded by the tweak at runtime. Language models (~30 MB each) are
// downloaded while there's internet; translating itself never needs the internet.
@interface FMMLTranslator : NSObject
// Language management (FrozenMusic > Offline translation). Codes like "ja", "de", "zh".
+ (NSArray<NSString *> *)allLanguages;            // every language ML Kit translates
+ (BOOL)isModelReady:(NSString *)language;         // on the device (English always is)
+ (BOOL)isDownloading:(NSString *)language;
// Downloads one language's model (Wi-Fi or mobile data); progress 0...1 and completion on the main queue
+ (void)downloadLanguage:(NSString *)language
                progress:(void (^)(double fraction))progress
              completion:(void (^)(NSString *error))completion;
+ (void)deleteLanguage:(NSString *)language completion:(void (^)(NSString *error))completion;
// Only with both models on the device: never waits for a download. Language codes like
// "ja", "en", "zh". Completion on the main queue: one translation per text, or nil + error
+ (void)translateTexts:(NSArray<NSString *> *)texts
                source:(NSString *)source
                target:(NSString *)target
            completion:(void (^)(NSArray<NSString *> *translations, NSString *error))completion;
@end
