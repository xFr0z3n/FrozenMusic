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

+ (NSArray<NSString *> *)allLanguages {
    return [MLKTranslateAllLanguages().allObjects sortedArrayUsingSelector:@selector(compare:)];
}

+ (NSMutableSet<NSString *> *)downloading {
    static NSMutableSet<NSString *> *set;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        set = [NSMutableSet set];
    });
    return set;
}

+ (BOOL)isDownloading:(NSString *)language {
    return [[self downloading] containsObject:language ?: @""];
}

+ (void)downloadLanguage:(NSString *)language
                progress:(void (^)(double))progress
              completion:(void (^)(NSString *))completion {
    void (^finish)(NSString *) = ^(NSString *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [[self downloading] removeObject:language ?: @""];
            completion(error);
        });
    };
    if (![self isSupportedLanguage:language]) {
        finish(@"This language can't be translated offline");
        return;
    }
    if ([self isModelReady:language]) {
        finish(nil);
        return;
    }
    [[self downloading] addObject:language];
    MLKTranslateRemoteModel *model = [MLKTranslateRemoteModel translateRemoteModelWithLanguage:(MLKTranslateLanguage)language];
    MLKModelDownloadConditions *conditions = [[MLKModelDownloadConditions alloc] initWithAllowsCellularAccess:YES
                                                                                  allowsBackgroundDownloading:YES];
    NSProgress *download = [[MLKModelManager modelManager] downloadModel:model conditions:conditions];

    // Progress while it downloads, done / failed from ML Kit's notifications
    __block NSTimer *timer = nil;
    __block id succeeded = nil, failed = nil;
    void (^cleanup)(void) = ^{
        [timer invalidate];
        timer = nil;
        if (succeeded)
            [[NSNotificationCenter defaultCenter] removeObserver:succeeded];
        if (failed)
            [[NSNotificationCenter defaultCenter] removeObserver:failed];
        succeeded = failed = nil;
    };
    // Called from the main queue (settings screen)
    timer = [NSTimer scheduledTimerWithTimeInterval:0.3 repeats:YES block:^(NSTimer *t) {
        if (progress)
            progress(download.fractionCompleted);
    }];
    succeeded = [[NSNotificationCenter defaultCenter] addObserverForName:MLKModelDownloadDidSucceedNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        MLKRemoteModel *done = note.userInfo[MLKModelDownloadUserInfoKeyRemoteModel];
        if (![done isEqual:model] && ![done.name isEqualToString:model.name])
            return;
        cleanup();
        finish(nil);
    }];
    failed = [[NSNotificationCenter defaultCenter] addObserverForName:MLKModelDownloadDidFailNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        MLKRemoteModel *done = note.userInfo[MLKModelDownloadUserInfoKeyRemoteModel];
        if (![done isEqual:model] && ![done.name isEqualToString:model.name])
            return;
        NSError *error = note.userInfo[MLKModelDownloadUserInfoKeyError];
        cleanup();
        finish(error.localizedDescription.length ? error.localizedDescription : @"Download failed");
    }];
}

+ (void)deleteLanguage:(NSString *)language completion:(void (^)(NSString *))completion {
    void (^finish)(NSString *) = ^(NSString *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(error);
        });
    };
    if (![self isSupportedLanguage:language] || [language isEqualToString:MLKTranslateLanguageEnglish]) {
        finish(nil);
        return;
    }
    MLKTranslateRemoteModel *model = [MLKTranslateRemoteModel translateRemoteModelWithLanguage:(MLKTranslateLanguage)language];
    [[MLKModelManager modelManager] deleteDownloadedModel:model completion:^(NSError *error) {
        finish(error.localizedDescription);
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
        finish(nil, @"No internet, and this language isn't downloaded for offline translation. Download it in FrozenMusic > Offline translation.");
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
