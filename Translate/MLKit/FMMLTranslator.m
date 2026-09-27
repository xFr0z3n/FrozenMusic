#import "FMMLTranslator.h"
#import <MLKitCommon/MLKitCommon.h>
#import <MLKitTranslate/MLKitTranslate.h>

@implementation FMMLTranslator

+ (BOOL)isSupportedLanguage:(NSString *)language {
    return language.length && [MLKTranslateAllLanguages() containsObject:(MLKTranslateLanguage)language];
}

// English is always on the device, other languages once their model is downloaded
+ (BOOL)isModelReady:(NSString *)language {
    if ([language isEqualToString:MLKTranslateLanguageEnglish])
        return YES;
    MLKTranslateRemoteModel *model = [MLKTranslateRemoteModel translateRemoteModelWithLanguage:(MLKTranslateLanguage)language];
    return model && [[MLKModelManager modelManager] isModelDownloaded:model];
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
            if (translator)
                translators[key] = translator;
        }
        return translator;
    }
}

+ (void)prepareSource:(NSString *)source target:(NSString *)target {
    if (![self isSupportedLanguage:source] || ![self isSupportedLanguage:target] || [source isEqualToString:target])
        return;
    if ([self isModelReady:source] && [self isModelReady:target])
        return;
    MLKTranslator *translator = [self translatorFrom:source to:target];
    MLKModelDownloadConditions *conditions = [[MLKModelDownloadConditions alloc] initWithAllowsCellularAccess:YES
                                                                                  allowsBackgroundDownloading:YES];
    [translator downloadModelIfNeededWithConditions:conditions completion:^(NSError *error) {
        if (error)
            NSLog(@"[FrozenMusic] offline translation model not downloaded: %@", error.localizedDescription);
    }];
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
    if (!texts.count) {
        finish(nil, @"Nothing to translate");
        return;
    }
    if (![self isSupportedLanguage:source] || ![self isSupportedLanguage:target]) {
        finish(nil, @"This language can't be translated offline");
        return;
    }
    if ([source isEqualToString:target]) {
        finish(texts, nil);
        return;
    }
    if (![self isModelReady:source] || ![self isModelReady:target]) {
        finish(nil, @"No internet, and this language isn't downloaded for offline translation yet. Translate it once with internet.");
        return;
    }

    MLKTranslator *translator = [self translatorFrom:source to:target];
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
                    failure = @"Offline translation failed";
            }
            dispatch_group_leave(group);
        }];
    }
    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        finish(failure ? nil : results, failure);
    });
}

@end
