#import "FMMLTranslator.h"
#import <MLKitCommon/MLKitCommon.h>
#import <MLKitTranslate/MLKitTranslate.h>

@implementation FMMLTranslator

+ (BOOL)isSupported {
    return YES;
}

// One translator per language pair, kept alive while it works
+ (MLKTranslator *)translatorFrom:(NSString *)source to:(NSString *)target {
    static NSMutableDictionary<NSString *, MLKTranslator *> *translators;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        translators = [NSMutableDictionary dictionary];
    });
    NSString *key = [NSString stringWithFormat:@"%@>%@", source, target];
    @synchronized (translators) {
        MLKTranslator *translator = translators[key];
        if (!translator) {
            MLKTranslatorOptions *options = [[MLKTranslatorOptions alloc] initWithSourceLanguage:(MLKTranslateLanguage)source
                                                                                  targetLanguage:(MLKTranslateLanguage)target];
            translator = [MLKTranslator translatorWithOptions:options];
            translators[key] = translator;
        }
        return translator;
    }
}

+ (void)translateTexts:(NSArray<NSString *> *)texts
                source:(NSString *)source
                target:(NSString *)target
            completion:(void (^)(NSArray<NSString *> *, NSString *))completion {
    void (^finish)(NSArray<NSString *> *, NSString *) = ^(NSArray<NSString *> *result, NSString *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(result, error);
        });
    };
    if (!texts.count || !source.length || !target.length) {
        finish(nil, @"Nothing to translate");
        return;
    }
    if ([source isEqualToString:target]) {
        finish(texts, nil);
        return;
    }

    MLKTranslator *translator = [self translatorFrom:source to:target];
    if (!translator) {
        finish(nil, @"This language can't be translated offline");
        return;
    }
    // First time for this language: download its model (Wi-Fi or mobile data), then offline
    MLKModelDownloadConditions *conditions = [[MLKModelDownloadConditions alloc] initWithAllowsCellularAccess:YES
                                                                                  allowsBackgroundDownloading:YES];
    [translator downloadModelIfNeededWithConditions:conditions completion:^(NSError *downloadError) {
        if (downloadError) {
            finish(nil, @"The translation model couldn't be downloaded");
            return;
        }
        // All lines at once
        NSMutableArray<NSString *> *results = [NSMutableArray arrayWithCapacity:texts.count];
        for (NSUInteger i = 0; i < texts.count; i++)
            [results addObject:@""];
        __block NSString *failure = nil;
        dispatch_group_t group = dispatch_group_create();
        for (NSUInteger i = 0; i < texts.count; i++) {
            dispatch_group_enter(group);
            [translator translateText:texts[i] completion:^(NSString *translated, NSError *error) {
                @synchronized (results) {
                    if (translated && !error)
                        results[i] = translated;
                    else
                        failure = @"Translation failed";
                }
                dispatch_group_leave(group);
            }];
        }
        dispatch_group_notify(group, dispatch_get_main_queue(), ^{
            finish(failure ? nil : results, failure);
        });
    }];
}

@end
