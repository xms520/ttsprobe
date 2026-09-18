/*
 * edge_tts.m — 微软 Edge 朗读接口（第三 TTS 后端：免费、无 key）
 * 协议（与 edge-tts-gui-rust v0.16.2 实测参数一致，已从 exe 静态扫描确认）:
 *   wss://speech.platform.bing.com/consumer/speech/synthesize/readaloud/edge/v1
 *       ?TrustedClientToken=6A5AA1D4EAFF4E9FB37E23D68491D6F4
 *       &Sec-MS-GEC=<SHA256>&Sec-MS-GEC-Version=1-130.0.2849.68&ConnectionId=<uuid32>
 *   文本帧1: X-Timestamp/Content-Type/Path:speech.config + JSON
 *   文本帧2: X-RequestId/Content-Type/Path:ssml + SSML（voice + prosody rate）
 *   二进制帧: [u16BE header长度][header][MP3 数据]（header 含 Path:audio）
 *   收到 Path:turn.end 结束 → 拼接全部 MP3 → 交主单元 DecodeToPCM 解码（24kHz MP3→16k PCM）
 * 需要 iOS 13+（URLSessionWebSocketTask），旧设备回落错误提示。
 */
#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonDigest.h>

NSUInteger EdgeVoiceCount(void);
NSString *EdgeVoiceDisplay(NSUInteger i);
NSString *EdgeVoiceID(NSUInteger i);
NSString *EdgeDisplayForID(NSString *vid);
void EdgeSetLogPath(NSString *p);
void RequestEdgeTTS(NSString *text, NSString *voiceID, float rate, void (^done)(NSData *audio, NSError *error));

/* ===== 音色表（显示名 / 微软 voice ID） ===== */
static NSString *const g_edgeVoiceTable[][2] = {
    {@"Edge·晓晓(女·通用)",  @"zh-CN-XiaoxiaoNeural"},
    {@"Edge·晓伊(女·温柔)",  @"zh-CN-XiaoyiNeural"},
    {@"Edge·云健(男·运动)",  @"zh-CN-YunjianNeural"},
    {@"Edge·云希(男·年轻)",  @"zh-CN-YunxiNeural"},
    {@"Edge·云夏(男·少年)",  @"zh-CN-YunxiaNeural"},
    {@"Edge·云扬(男·新闻)",  @"zh-CN-YunyangNeural"},
    {@"Edge·晓北(东北女)",   @"zh-CN-liaoning-XiaobeiNeural"},
    {@"Edge·晓妮(陕西女)",   @"zh-CN-shaanxi-XiaoniNeural"},
    {@"Edge·曉曼(粤语女)",   @"zh-HK-HiuMaanNeural"},
    {@"Edge·雲龍(粤语男)",   @"zh-HK-WanLungNeural"},
    {@"Edge·曉臻(台湾女)",   @"zh-TW-HsiaoChenNeural"},
    {@"Edge·Aria(英语女)",   @"en-US-AriaNeural"},
    {@"Edge·Guy(英语男)",    @"en-US-GuyNeural"},
    {@"Edge·七海(日语女)",   @"ja-JP-NanamiNeural"},
};
#define EDGE_VOICE_COUNT (sizeof(g_edgeVoiceTable) / sizeof(g_edgeVoiceTable[0]))

NSUInteger EdgeVoiceCount(void) { return EDGE_VOICE_COUNT; }
NSString *EdgeVoiceDisplay(NSUInteger i) {
    return (i < EDGE_VOICE_COUNT) ? g_edgeVoiceTable[i][0] : nil;
}
NSString *EdgeVoiceID(NSUInteger i) {
    return (i < EDGE_VOICE_COUNT) ? g_edgeVoiceTable[i][1] : nil;
}
NSString *EdgeDisplayForID(NSString *vid) {
    for (NSUInteger i = 0; i < EDGE_VOICE_COUNT; i++)
        if ([g_edgeVoiceTable[i][1] isEqualToString:vid]) return g_edgeVoiceTable[i][0];
    return vid;
}

/* ===== 日志（与主单元同一文件，行首 [EDGE] 区分） ===== */
static NSString *g_edgeLogPath = nil;
void EdgeSetLogPath(NSString *p) { g_edgeLogPath = [p copy]; }
static void EdgeLog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[EDGE] %@", s);
    if (!g_edgeLogPath) return;
    @autoreleasepool {
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:g_edgeLogPath];
        if (!fh) {
            [[NSFileManager defaultManager] createFileAtPath:g_edgeLogPath contents:nil attributes:nil];
            fh = [NSFileHandle fileHandleForWritingAtPath:g_edgeLogPath];
        }
        if (fh) {
            [fh seekToEndOfFile];
            [fh writeData:[[NSString stringWithFormat:@"[EDGE] %@\n", s] dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        }
    }
}

/* ===== Sec-MS-GEC：SHA256( filetime(5分钟粒度) + TrustedToken ) 大写 hex ===== */
static NSString *EdgeGECToken(void) {
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    unsigned long long ticks = (unsigned long long)((now + 11644473600.0) * 10000000.0);
    ticks -= ticks % 3000000000ULL;   /* 5 分钟粒度（微软 DRM 要求） */
    NSString *s = [NSString stringWithFormat:@"%llu6A5AA1D4EAFF4E9FB37E23D68491D6F4", ticks];
    const char *c = [s UTF8String];
    unsigned char md[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(c, (CC_LONG)strlen(c), md);
    NSMutableString *h = [NSMutableString stringWithCapacity:64];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [h appendFormat:@"%02X", md[i]];
    return h;
}

static NSString *EdgeTimestamp(void) {
    static NSDateFormatter *fmt = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fmt = [[NSDateFormatter alloc] init];
        fmt.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
        fmt.dateFormat = @"EEE MMM dd HH:mm:ss 'GMT'ZZZ yyyy";
        fmt.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
    });
    return [fmt stringFromDate:[NSDate date]];
}

static NSString *EdgeXMLEscape(NSString *t) {
    NSString *e = [t stringByReplacingOccurrencesOfString:@"&" withString:@"&amp;"];
    e = [e stringByReplacingOccurrencesOfString:@"<" withString:@"&lt;"];
    e = [e stringByReplacingOccurrencesOfString:@">" withString:@"&gt;"];
    e = [e stringByReplacingOccurrencesOfString:@"'" withString:@"&apos;"];
    return e;
}

/* ===== 主流程：WebSocket 合成，回调 MP3 ===== */
void RequestEdgeTTS(NSString *text, NSString *voiceID, float rate, void (^done)(NSData *audio, NSError *error)) {
    if (!text.length) { if (done) done(nil, [NSError errorWithDomain:@"edge" code:1
        userInfo:@{NSLocalizedDescriptionKey:@"文本为空"}]); return; }
    if (@available(iOS 13.0, *)) {
        NSString *cid  = [[[NSUUID UUID] UUIDString] stringByReplacingOccurrencesOfString:@"-" withString:@""];
        NSString *gec  = EdgeGECToken();
        NSString *url  = [NSString stringWithFormat:
            @"wss://speech.platform.bing.com/consumer/speech/synthesize/readaloud/edge/v1"
            @"?TrustedClientToken=6A5AA1D4EAFF4E9FB37E23D68491D6F4&Sec-MS-GEC=%@&Sec-MS-GEC-Version=1-130.0.2849.68&ConnectionId=%@",
            gec, cid];
        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
        [req setValue:@"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36 Edg/130.0.2849.68"
            forHTTPHeaderField:@"User-Agent"];
        [req setValue:@"chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold" forHTTPHeaderField:@"Origin"];

        NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        cfg.timeoutIntervalForRequest = 30;
        NSURLSession *sess = [NSURLSession sessionWithConfiguration:cfg];
        NSURLSessionWebSocketTask *ws = [sess webSocketTaskWithRequest:req];
        [ws resume];

        NSMutableData *mp3 = [NSMutableData data];
        __block BOOL finished = NO;
        __block NSUInteger audioFrames = 0;

        NSString *ts    = EdgeTimestamp();
        NSString *reqId = [[NSUUID UUID].UUIDString stringByReplacingOccurrencesOfString:@"-" withString:@""];
        NSString *cfgMsg = [NSString stringWithFormat:
            @"X-Timestamp:%@\r\nContent-Type:application/json; charset=utf-8\r\nPath:speech.config\r\n\r\n"
            @"{\"context\":{\"synthesis\":{\"audio\":{\"metadataoptions\":{"
            @"\"sentenceBoundaryEnabled\":\"false\",\"wordBoundaryEnabled\":\"false\"},"
            @"\"outputFormat\":\"audio-24khz-48kbitrate-mono-mp3\"}}}}", ts];
        int pct = (int)lroundf((rate - 1.0f) * 100.0f);
        NSString *rateStr = [NSString stringWithFormat:@"%@%d", pct >= 0 ? @"+" : @"", pct];
        NSString *ssml = [NSString stringWithFormat:
            @"X-RequestId:%@\r\nContent-Type:application/ssml+xml\r\nX-Timestamp:%@\r\nPath:ssml\r\n\r\n"
            @"<speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' xml:lang='zh-CN'>"
            @"<voice name='%@'><prosody rate='%@%%' volume='+0%%'>%@</prosody></voice></speak>",
            reqId, ts, voiceID, rateStr, EdgeXMLEscape(text)];

        void (^fail)(NSInteger, NSString *) = ^(NSInteger code, NSString *msg) {
            if (finished) return;
            finished = YES;
            EdgeLog(@"[edge] 失败 code=%ld %@", (long)code, msg);
            [ws cancelWithCloseCode:NSURLSessionWebSocketCloseCodeGoingAway reason:nil];
            [sess invalidateAndCancel];
            if (done) done(nil, [NSError errorWithDomain:@"edge" code:code
                userInfo:@{NSLocalizedDescriptionKey: msg ?: @"edge-tts 失败"}]);
        };
        void (^ok)(NSData *) = ^(NSData *a) {
            if (finished) return;
            finished = YES;
            EdgeLog(@"[edge] 完成 %luB (%lu 音频帧)", (unsigned long)a.length, (unsigned long)audioFrames);
            [ws cancelWithCloseCode:NSURLSessionWebSocketCloseCodeGoingAway reason:nil];
            [sess invalidateAndCancel];
            if (done) done(a, nil);
        };

        __block void (^recvBlock)(void) = NULL;
        recvBlock = ^{
            [ws receiveMessageWithCompletionHandler:^(NSURLSessionWebSocketMessage *msg, NSError *err) {
                if (finished) return;
                if (err) {
                    if (mp3.length > 0) { ok(mp3); }
                    else fail(err.code ?: 10, [NSString stringWithFormat:@"连接/接收: %@", err.localizedDescription]);
                    return;
                }
                if (msg.type == NSURLSessionWebSocketMessageTypeString) {
                    NSString *t = msg.string ?: @"";
                    if ([t containsString:@"Path:turn.end"]) {
                        if (mp3.length > 0) ok(mp3);
                        else fail(2, @"服务端正常结束但无音频数据（音色/网络被拒？）");
                        return;
                    }
                } else if (msg.type == NSURLSessionWebSocketMessageTypeData) {
                    NSData *d = msg.data;
                    if (d.length > 2) {
                        const unsigned char *bp = (const unsigned char *)d.bytes;
                        NSUInteger hl = ((NSUInteger)bp[0] << 8) | (NSUInteger)bp[1];
                        if (d.length > hl + 2) {
                            NSString *hs = [[NSString alloc] initWithData:[d subdataWithRange:NSMakeRange(2, hl)]
                                                                 encoding:NSUTF8StringEncoding] ?: @"";
                            NSData *payload = [d subdataWithRange:NSMakeRange(2 + hl, d.length - 2 - hl)];
                            if ([hs containsString:@"Path:audio"] && payload.length) {
                                [mp3 appendData:payload];
                                audioFrames++;
                                if (audioFrames == 1 || audioFrames % 20 == 0)
                                    EdgeLog(@"[edge] 音频帧 #%lu +%luB 累计%luB", (unsigned long)audioFrames,
                                            (unsigned long)payload.length, (unsigned long)mp3.length);
                            }
                        }
                    }
                }
                recvBlock();   /* 继续收下一帧 */
            }];
        };

        EdgeLog(@"[edge] 连接 voice=%@ rate=%@%% 文本%lu字", voiceID, rateStr, (unsigned long)text.length);
        [ws sendMessage:[[NSURLSessionWebSocketMessage alloc] initWithString:cfgMsg]
            completionHandler:^(NSError *e) { if (e) EdgeLog(@"[edge] config 发送失败: %@", e.localizedDescription); }];
        [ws sendMessage:[[NSURLSessionWebSocketMessage alloc] initWithString:ssml]
            completionHandler:^(NSError *e) { if (e) EdgeLog(@"[edge] ssml 发送失败: %@", e.localizedDescription); }];
        recvBlock();

        /* 超时保护：25s 未完成报错 */
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(25 * NSEC_PER_SEC)),
                       dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            if (!finished) fail(3, @"edge-tts 超时（25s）");
        });
    } else {
        if (done) done(nil, [NSError errorWithDomain:@"edge" code:9
            userInfo:@{NSLocalizedDescriptionKey:@"edge-tts 需要 iOS 13+（URLSessionWebSocketTask）"}]);
    }
}
