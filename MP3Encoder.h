#import <Foundation/Foundation.h>

// Converts an audio file (e.g. the downloaded .m4a) to MP3 with LAME
// (VBR ~190 kbps) and writes ID3v2.3 tags + embedded cover.
//
// metadata keys: title, artist, album, album_artist, track, date, comment
// Returns nil on success, otherwise a short error text.
@interface YTMUMP3Encoder : NSObject
+ (NSString *)convertFile:(NSURL *)inputURL
                    toMP3:(NSURL *)outputURL
                 metadata:(NSDictionary<NSString *, NSString *> *)metadata
                coverJPEG:(NSData *)coverJPEG;
@end
