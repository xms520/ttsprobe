/*
 * localtts.m — 第三 TTS 后端：本地系统语音（AVSpeechSynthesizer 离线合成）
 * 背景: edge-tts 公开端点已被微软按客户端指纹封锁（老/新域名、多 token 算法/UA/头组合全部 403，
 *       本机与真机双端验证），改为系统自带 TTS —— 离线、免费、无 key、无风控。
 * 输出: AVSpeechSynthesizer.write(iOS13+) 逐 buffer 合成 → 拼接 → AVAudioConverter 转
 *       16k mono int16 → 封 WAV → 交主单元 DecodeToPCM（与 MP3 后端同一管线）。
 * 音色: 运行时枚举系统已装语音（zh-CN/zh-HK/zh-TW/en/ja 优先），显示名 "本地·名字(语言)"。
 */
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

NSUInteger LocalVoiceCount(void);
NSString *LocalVoiceDisplay(NSUInteger i);
NSString *LocalVoiceID(NSUInteger i);
NSString *LocalDisplayForID(NSString *vid);
void LocalSetLogPath(NSString *p);
void RequestLocalTTS(NSString *text, NSString *voiceID, float rate, void (^done)(NSData *audio, NSError *error));

/* ===== 日志（与主单元同一文件，行首 [LOCAL] 区分） ===== */
static NSString *g_lcLogPath = nil;
void LocalSetLogPath(NSString *p) { g_lcLogPath = [p copy]; }
static void LocalLog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[LOCAL] %@", s);
    if (!g_lcLogPath) return;
    @autoreleasepool {
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:g_lcLogPath];
        if (!fh) {
            [[NSFileManager defaultManager] createFileAtPath:g_lcLogPath contents:nil attributes:nil];
            fh = [NSFileHandle fileHandleForWritingAtPath:g_lcLogPath];
        }
        if (fh) {
            [fh seekToEndOfFile];
            [fh writeData:[[NSString stringWithFormat:@"[LOCAL] %@\n", s] dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        }
    }
}

/* ===== 音色表：启动时枚举系统语音（懒加载，最多 16 个，中文优先） ===== */
static NSArray *g_lcVoices = nil;   /* AVSpeechSynthesisVoice 数组 */

static void LocalLoadVoices(void) {
    if (g_lcVoices) return;
    @try {
        NSArray *all = [AVSpeechSynthesisVoice speechVoices] ?: @[];
        NSMutableArray *zh = [NSMutableArray array], *en = [NSMutableArray array], *other = [NSMutableArray array];
        for (AVSpeechSynthesisVoice *v in all) {
            NSString *lang = v.language ?: @"";
            if ([lang hasPrefix:@"zh"]) [zh addObject:v];
            else if ([lang hasPrefix:@"en"]) [en addObject:v];
            else if ([lang hasPrefix:@"ja"]) [other addObject:v];
        }
        /* 中文优先；同语言里增强音质(2)排前 */
        NSComparator cmp = ^NSComparisonResult(AVSpeechSynthesisVoice *a, AVSpeechSynthesisVoice *b) {
            if (a.quality != b.quality) return (a.quality > b.quality) ? NSOrderedAscending : NSOrderedDescending;
            return [a.language compare:b.language];
        };
        [zh sortUsingComparator:cmp]; [en sortUsingComparator:cmp]; [other sortUsingComparator:cmp];
        NSMutableArray *r = [NSMutableArray array];
        [r addObjectsFromArray:zh]; [r addObjectsFromArray:en]; [r addObjectsFromArray:other];
        if (r.count > 16) r = [[r subarrayWithRange:NSMakeRange(0, 16)] mutableCopy];
        g_lcVoices = [r copy];
        LocalLog(@"[voices] 系统语音 %lu 个可用（zh=%lu en=%lu）", (unsigned long)g_lcVoices.count,
                 (unsigned long)zh.count, (unsigned long)en.count);
    } @catch (NSException *e) {
        LocalLog(@"[voices] 枚举异常 %@", e);
        g_lcVoices = @[];
    }
}

NSUInteger LocalVoiceCount(void) { LocalLoadVoices(); return g_lcVoices.count; }
NSString *LocalVoiceDisplay(NSUInteger i) {
    LocalLoadVoices();
    if (i >= g_lcVoices.count) return nil;
    AVSpeechSynthesisVoice *v = g_lcVoices[i];
    NSString *q = (v.quality == AVSpeechSynthesisVoiceQualityEnhanced) ? @"·增强" : @"";
    return [NSString stringWithFormat:@"本地·%@(%@%@)", v.name ?: @"?", v.language ?: @"?", q];
}
NSString *LocalVoiceID(NSUInteger i) {
    LocalLoadVoices();
    if (i >= g_lcVoices.count) return nil;
    AVSpeechSynthesisVoice *v = g_lcVoices[i];
    return v.identifier;
}
NSString *LocalDisplayForID(NSString *vid) {
    LocalLoadVoices();
    for (AVSpeechSynthesisVoice *v in g_lcVoices)
        if ([v.identifier isEqualToString:vid]) {
            NSString *q = (v.quality == AVSpeechSynthesisVoiceQualityEnhanced) ? @"·增强" : @"";
            return [NSString stringWithFormat:@"本地·%@(%@%@)", v.name ?: @"?", v.language ?: @"?", q];
        }
    return vid;
}

/* ===== WAV 封装（16k mono 16bit） ===== */
static NSData *LocalMakeWav(NSData *pcm) {
    NSUInteger n = pcm.length;
    NSMutableData *w = [NSMutableData dataWithCapacity:44 + n];
    uint32_t sr = 16000, bps = 16, ch = 1;
    uint32_t byteRate = sr * ch * bps / 8, dataLen = (uint32_t)n, riffLen = 36 + dataLen;
    [w appendBytes:"RIFF" length:4]; [w appendBytes:&riffLen length:4]; [w appendBytes:"WAVE" length:4];
    [w appendBytes:"fmt " length:4]; uint32_t fmtLen = 16, fmtCode = 1;
    [w appendBytes:&fmtLen length:4]; [w appendBytes:&fmtCode length:2]; [w appendBytes:&ch length:2];
    [w appendBytes:&sr length:4]; [w appendBytes:&byteRate length:4];
    uint16_t blockAlign = (uint16_t)(ch * bps / 8), bits = bps;
    [w appendBytes:&blockAlign length:2]; [w appendBytes:&bits length:2];
    [w appendBytes:"data" length:4]; [w appendBytes:&dataLen length:4];
    [w appendData:pcm];
    return w;
}

/* ===== 合成主流程（AVSpeechSynthesizer.write，iOS13+） ===== */
void RequestLocalTTS(NSString *text, NSString *voiceID, float rate, void (^done)(NSData *audio, NSError *error)) {
    if (!text.length) { if (done) done(nil, [NSError errorWithDomain:@"local" code:1
        userInfo:@{NSLocalizedDescriptionKey:@"文本为空"}]); return; }
    if (@available(iOS 13.0, *)) {
        LocalLoadVoices();
        AVSpeechSynthesisVoice *voice = nil;
        for (AVSpeechSynthesisVoice *v in g_lcVoices)
            if ([v.identifier isEqualToString:voiceID]) { voice = v; break; }
        if (!voice) voice = (g_lcVoices.count ? g_lcVoices[0] : nil);
        if (!voice) { if (done) done(nil, [NSError errorWithDomain:@"local" code:2
            userInfo:@{NSLocalizedDescriptionKey:@"系统无可用语音"}]); return; }

        AVSpeechUtterance *u = [AVSpeechUtterance speechUtteranceWithString:text];
        u.voice = voice;
        u.rate = MIN(0.92f, MAX(0.12f, 0.5f * rate));   /* 语速滑杆 0.5~2.0 → 0.25~0.92 */
        u.pitchMultiplier = 1.0;
        u.postUtteranceDelay = 0; u.preUtteranceDelay = 0;

        AVSpeechSynthesizer *syn = [[AVSpeechSynthesizer alloc] init];
        NSMutableArray *chunks = [NSMutableArray array];       /* NSData(float32 ch0) */
        __block AVAudioFormat *fmt0 = nil;
        __block AVAudioFrameCount totalFrames = 0;
        __block BOOL finished = NO;

        void (^finish)(NSError *) = ^(NSError *err) {
            if (finished) return;
            finished = YES;
            if (err) {
                LocalLog(@"[local] 失败 %@", err.localizedDescription);
                if (done) done(nil, err);
                return;
            }
            /* 拼接 → 转 16k mono int16 → WAV */
            @try {
                AVAudioFormat *inf = fmt0;
                AVAudioFrameCount cap = totalFrames + 4096;
                AVAudioPCMBuffer *inBuf = [[AVAudioPCMBuffer alloc] initWithPCMFormat:inf frameCapacity:cap];
                float *dst0 = inBuf.floatChannelData[0];
                AVAudioFrameCount off = 0;
                for (NSData *c in chunks) {
                    AVAudioFrameCount nf = (AVAudioFrameCount)(c.length / sizeof(float));
                    memcpy(dst0 + off, c.bytes, c.length); off += nf;
                }
                inBuf.frameLength = totalFrames;

                AVAudioFormat *outFmt = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:16000 channels:1];
                AVAudioConverter *conv = [[AVAudioConverter alloc] initFromFormat:inf toFormat:outFmt];
                AVAudioPCMBuffer *outBuf = [[AVAudioPCMBuffer alloc] initWithPCMFormat:outFmt
                    frameCapacity:(AVAudioFrameCount)(totalFrames * 16000.0 / inf.sampleRate) + 8192];
                __block BOOL fed = NO;
                NSError *cerr = nil;
                [conv convertToBuffer:outBuf error:&cerr withInputFromBlock:
                 ^AVAudioBuffer *(AVAudioPacketCount pk, AVAudioConverterInputStatus *st) {
                     if (!fed) { fed = YES; *st = AVAudioConverterInputStatus_HaveData; return inBuf; }
                     *st = AVAudioConverterInputStatus_NoDataNow;
                     return nil;
                 }];
                if (cerr || !outBuf || outBuf.frameLength == 0) {
                    LocalLog(@"[local] 重采样失败 %@", cerr);
                    if (done) done(nil, [NSError errorWithDomain:@"local" code:4
                        userInfo:@{NSLocalizedDescriptionKey:@"本地合成重采样失败"}]);
                    return;
                }
                NSMutableData *pcm = [NSMutableData dataWithCapacity:outBuf.frameLength * 2];
                const float *src = outBuf.floatChannelData[0];
                for (AVAudioFrameCount i = 0; i < outBuf.frameLength; i++) {
                    float f = src[i]; if (f > 1) f = 1; if (f < -1) f = -1;
                    int16_t v = (int16_t)(f * 32767.0f);
                    [pcm appendBytes:&v length:2];
                }
                LocalLog(@"[local] 完成 %luB PCM（%lu 帧 @%uHz → 16k）",
                         (unsigned long)pcm.length, (unsigned long)outBuf.frameLength, (unsigned)inf.sampleRate);
                if (done) done(LocalMakeWav(pcm), nil);
            } @catch (NSException *e) {
                LocalLog(@"[local] 收尾异常 %@", e);
                if (done) done(nil, [NSError errorWithDomain:@"local" code:5
                    userInfo:@{NSLocalizedDescriptionKey:@"本地合成收尾异常"}]);
            }
        };

        LocalLog(@"[local] 合成 voice=%@ rate=%.2f 文本%lu字", voice.name, rate, (unsigned long)text.length);

        /* 结束信号：用 KVO 观察 isSpeaking 更可靠（write 模式 delegate 也会回调） */
        [syn writeUtterance:u toBufferCallback:^(AVAudioBuffer *buffer) {
            if (finished) return;
            if ([buffer isKindOfClass:[AVAudioPCMBuffer class]]) {
                AVAudioPCMBuffer *pb = (AVAudioPCMBuffer *)buffer;
                if (pb.frameLength == 0) return;
                if (!fmt0) fmt0 = pb.format;
                if (fmt0.sampleRate != pb.format.sampleRate) return;   /* 格式突变忽略 */
                NSData *c = [NSData dataWithBytes:pb.floatChannelData[0]
                                           length:pb.frameLength * sizeof(float)];
                [chunks addObject:c];
                totalFrames += pb.frameLength;
            }
        }];

        /* 结束判定：轮询 isSpeaking（避免 delegate 对象桥接复杂度） */
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                       dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            __block int idle = 0, waited = 0;
            void (^poll)(void) = ^{
                if (finished) return;
                if (!syn.isSpeaking && chunks.count > 0) {
                    idle++;
                    if (idle >= 3) { finish(nil); return; }   /* 连续 0.6s 不在说且已有数据 → 完成 */
                } else idle = 0;
                waited += 200;
                if (waited > 30000) { finish([NSError errorWithDomain:@"local" code:3
                    userInfo:@{NSLocalizedDescriptionKey:@"本地合成超时"}]); return; }
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                               dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), poll);
            };
            poll();
        });
    } else {
        if (done) done(nil, [NSError errorWithDomain:@"local" code:9
            userInfo:@{NSLocalizedDescriptionKey:@"本地合成需要 iOS 13+"}]);
    }
}
