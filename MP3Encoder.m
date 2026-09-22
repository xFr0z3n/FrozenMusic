#import "MP3Encoder.h"
#import <AVFoundation/AVFoundation.h>
#import "Utils/lame/lame.h" // copied there by the "Build LAME" step in the GitHub workflow

#pragma mark - ID3v2.3 writer

static void YTMUAppendBE32(NSMutableData *data, uint32_t value) {
    uint8_t bytes[4] = {(uint8_t)(value >> 24), (uint8_t)(value >> 16), (uint8_t)(value >> 8), (uint8_t)value};
    [data appendBytes:bytes length:4];
}

static NSData *YTMUID3Frame(NSString *frameID, NSData *payload) {
    NSMutableData *frame = [NSMutableData data];
    [frame appendData:[frameID dataUsingEncoding:NSASCIIStringEncoding]];
    YTMUAppendBE32(frame, (uint32_t)payload.length);
    uint8_t flags[2] = {0, 0};
    [frame appendBytes:flags length:2];
    [frame appendData:payload];
    return frame;
}

// UTF-16 with BOM (encoding 1): works for any language, read by Windows and players
static void YTMUAppendUTF16(NSMutableData *data, NSString *text, BOOL terminate) {
    uint8_t bom[2] = {0xFF, 0xFE};
    [data appendBytes:bom length:2];
    [data appendData:[text dataUsingEncoding:NSUTF16LittleEndianStringEncoding] ?: [NSData data]];
    if (terminate) {
        uint8_t zero[2] = {0, 0};
        [data appendBytes:zero length:2];
    }
}

static NSData *YTMUID3TextFrame(NSString *frameID, NSString *text) {
    NSMutableData *payload = [NSMutableData data];
    uint8_t encoding = 1;
    [payload appendBytes:&encoding length:1];
    YTMUAppendUTF16(payload, text, NO);
    return YTMUID3Frame(frameID, payload);
}

static NSData *YTMUID3Tag(NSDictionary<NSString *, NSString *> *metadata, NSData *coverJPEG) {
    NSMutableData *frames = [NSMutableData data];

    NSDictionary<NSString *, NSString *> *textFrames = @{
        @"title": @"TIT2",
        @"artist": @"TPE1",
        @"album": @"TALB",
        @"album_artist": @"TPE2",
        @"track": @"TRCK",
        @"date": @"TYER"
    };
    for (NSString *key in @[@"title", @"artist", @"album", @"album_artist", @"track", @"date"]) {
        NSString *value = metadata[key];
        if ([value isKindOfClass:[NSString class]] && value.length)
            [frames appendData:YTMUID3TextFrame(textFrames[key], value)];
    }

    // COMM: encoding, language, empty description, text
    NSString *comment = metadata[@"comment"];
    if ([comment isKindOfClass:[NSString class]] && comment.length) {
        NSMutableData *payload = [NSMutableData data];
        uint8_t encoding = 1;
        [payload appendBytes:&encoding length:1];
        [payload appendBytes:"eng" length:3];
        YTMUAppendUTF16(payload, @"", YES);
        YTMUAppendUTF16(payload, comment, NO);
        [frames appendData:YTMUID3Frame(@"COMM", payload)];
    }

    // APIC: front cover
    if (coverJPEG.length) {
        NSMutableData *payload = [NSMutableData data];
        uint8_t encoding = 0;
        [payload appendBytes:&encoding length:1];
        [payload appendBytes:"image/jpeg\0" length:11];
        uint8_t pictureType = 3; // front cover
        [payload appendBytes:&pictureType length:1];
        uint8_t emptyDescription = 0;
        [payload appendBytes:&emptyDescription length:1];
        [payload appendData:coverJPEG];
        [frames appendData:YTMUID3Frame(@"APIC", payload)];
    }

    // Header: "ID3", version 2.3, no flags, size as 4x7-bit "synchsafe" number
    NSMutableData *tag = [NSMutableData dataWithBytes:"ID3\x03\x00\x00" length:6];
    uint32_t size = (uint32_t)frames.length;
    uint8_t synchsafe[4] = {
        (uint8_t)((size >> 21) & 0x7F), (uint8_t)((size >> 14) & 0x7F),
        (uint8_t)((size >> 7) & 0x7F), (uint8_t)(size & 0x7F)
    };
    [tag appendBytes:synchsafe length:4];
    [tag appendData:frames];
    return tag;
}

#pragma mark - Encoder

@implementation YTMUMP3Encoder

+ (NSString *)convertFile:(NSURL *)inputURL
                    toMP3:(NSURL *)outputURL
                 metadata:(NSDictionary<NSString *, NSString *> *)metadata
                coverJPEG:(NSData *)coverJPEG {
    // 1. Decode to 16-bit PCM with Apple's own decoder
    NSError *error = nil;
    AVAudioFile *file = [[AVAudioFile alloc] initForReading:inputURL commonFormat:AVAudioPCMFormatInt16 interleaved:YES error:&error];
    if (!file)
        return @"couldn't read audio";

    AVAudioFormat *format = file.processingFormat;
    AVAudioChannelCount channels = format.channelCount;
    if (channels < 1 || channels > 2)
        return @"unsupported channel count";

    const AVAudioFrameCount chunkFrames = 8192;
    AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:chunkFrames];
    if (!buffer)
        return @"couldn't create audio buffer";

    // 2. LAME setup: VBR quality 2 (~190 kbps), no automatic tags (we write our own)
    lame_t lame = lame_init();
    if (!lame)
        return @"encoder init failed";
    lame_set_in_samplerate(lame, (int)format.sampleRate);
    lame_set_num_channels(lame, (int)channels);
    if (channels == 1)
        lame_set_mode(lame, MONO);
    lame_set_VBR(lame, vbr_default);
    lame_set_VBR_quality(lame, 2.0f);
    lame_set_quality(lame, 3);
    lame_set_write_id3tag_automatic(lame, 0);
    lame_set_bWriteVbrTag(lame, 1);
    if (lame_init_params(lame) < 0) {
        lame_close(lame);
        return @"encoder setup failed";
    }

    NSString *audioPath = [outputURL.path stringByAppendingString:@".audio"];
    FILE *out = fopen(audioPath.fileSystemRepresentation, "wb+");
    if (!out) {
        lame_close(lame);
        return @"couldn't create file";
    }

    const int mp3Capacity = (int)(1.25 * chunkFrames) + 7200;
    unsigned char *mp3Buffer = malloc((size_t)mp3Capacity);
    NSString *failure = nil;

    // 3. Encode chunk by chunk
    while (YES) {
        BOOL read = [file readIntoBuffer:buffer frameCount:chunkFrames error:&error];
        if (!read) {
            if (file.framePosition >= file.length)
                break; // end of file
            failure = @"decoding failed";
            break;
        }
        AVAudioFrameCount frames = buffer.frameLength;
        if (frames == 0)
            break;

        short *pcm = buffer.int16ChannelData[0]; // interleaved: all channels in [0]
        int written = channels == 2
            ? lame_encode_buffer_interleaved(lame, pcm, (int)frames, mp3Buffer, mp3Capacity)
            : lame_encode_buffer(lame, pcm, NULL, (int)frames, mp3Buffer, mp3Capacity);
        if (written < 0) {
            failure = @"encoding failed";
            break;
        }
        if (written > 0)
            fwrite(mp3Buffer, 1, (size_t)written, out);
    }

    if (!failure) {
        int flushed = lame_encode_flush(lame, mp3Buffer, mp3Capacity);
        if (flushed > 0)
            fwrite(mp3Buffer, 1, (size_t)flushed, out);

        // VBR header (correct length/seeking in players) goes into the first frame
        size_t tagSize = lame_get_lametag_frame(lame, mp3Buffer, (size_t)mp3Capacity);
        if (tagSize > 0 && tagSize <= (size_t)mp3Capacity) {
            fseek(out, 0, SEEK_SET);
            fwrite(mp3Buffer, 1, tagSize, out);
        }
    }

    fclose(out);
    free(mp3Buffer);
    lame_close(lame);

    if (failure) {
        [[NSFileManager defaultManager] removeItemAtPath:audioPath error:nil];
        return failure;
    }

    // 4. Final file = ID3 tag + MP3 audio
    NSData *audio = [NSData dataWithContentsOfFile:audioPath];
    [[NSFileManager defaultManager] removeItemAtPath:audioPath error:nil];
    if (audio.length == 0)
        return @"no audio written";

    NSMutableData *result = [YTMUID3Tag(metadata, coverJPEG) mutableCopy];
    [result appendData:audio];
    [[NSFileManager defaultManager] removeItemAtURL:outputURL error:nil];
    return [result writeToURL:outputURL atomically:YES] ? nil : @"couldn't save mp3";
}

@end
