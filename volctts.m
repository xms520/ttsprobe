/*
 * volctts.m — 第四 TTS 后端：火山引擎豆包 TTS（openspeech.bytedance.com/api/v1/tts）
 * 鉴权: appid+token（编译时 XOR 0x3C 混淆内置，与 QIANWENTTS 同方式）
 * 协议: POST JSON → code==0 → data=base64(mp3) → 主单元 DecodeToPCM → 原发送链
 */
#import <Foundation/Foundation.h>

NSUInteger VolcVoiceCount(void);
NSString *VolcVoiceDisplay(NSUInteger i);
NSString *VolcVoiceID(NSUInteger i);
NSString *VolcDisplayForID(NSString *vid);
void VolcSetLogPath(NSString *p);
void RequestVolcTTS(NSString *text, NSString *voiceID, float rate, void (^done)(NSData *audio, NSError *error));

static NSString *const g_volcVoiceTable[][2] = {
    {@"豆包·灿灿(女·多情感)",  @"zh_female_cancan_mars_bigtts"},
    {@"豆包·湾湾小何(女)",     @"zh_female_wanwanxiaohe_mars_bigtts"},
    {@"豆包·魅力女友(女)",     @"zh_female_meilinvyou_mars_bigtts"},
    {@"豆包·爽快思思(女)",     @"zh_female_shuangkuai_mars_bigtts"},
    {@"豆包·邻家姐姐(女)",     @"zh_female_linjialimei_mars_bigtts"},
    {@"豆包·北京小爷(男)",     @"zh_male_beijingxiaoye_mars_bigtts"},
    {@"豆包·儒雅青年(男)",     @"zh_male_ruishiniandai_mars_bigtts"},
    {@"豆包·沉稳青年(男)",     @"zh_male_M392_conversation_wvae"},
    {@"豆包·元气小男孩",       @"zh_male_yuanqiyouxia_mars_bigtts"},
    {@"豆包·通用女声",         @"BV001_stream"},
    {@"豆包·通用男声",         @"BV002_stream"},
};
#define VOLC_VOICE_COUNT (sizeof(g_volcVoiceTable) / sizeof(g_volcVoiceTable[0]))

NSUInteger VolcVoiceCount(void) { return VOLC_VOICE_COUNT; }
NSString *VolcVoiceDisplay(NSUInteger i) { return (i < VOLC_VOICE_COUNT) ? g_volcVoiceTable[i][0] : nil; }
NSString *VolcVoiceID(NSUInteger i) { return (i < VOLC_VOICE_COUNT) ? g_volcVoiceTable[i][1] : nil; }
NSString *VolcDisplayForID(NSString *vid) {
    for (NSUInteger i = 0; i < VOLC_VOICE_COUNT; i++)
        if ([g_volcVoiceTable[i][1] isEqualToString:vid]) return g_volcVoiceTable[i][0];
    return vid;
}

static NSString *g_volcLogPath = nil;
void VolcSetLogPath(NSString *p) { g_volcLogPath = [p copy]; }
static void VolcLog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[VOLC] %@", s);
    if (!g_volcLogPath) return;
    @autoreleasepool {
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:g_volcLogPath];
        if (!fh) { [[NSFileManager defaultManager] createFileAtPath:g_volcLogPath contents:nil attributes:nil];
                   fh = [NSFileHandle fileHandleForWritingAtPath:g_volcLogPath]; }
        if (fh) { [fh seekToEndOfFile];
                  [fh writeData:[[NSString stringWithFormat:@"[VOLC] %@\n", s] dataUsingEncoding:NSUTF8StringEncoding]];
                  [fh closeFile]; }
    }
}

/* ===== 密钥（XOR 0x3C） ===== */
static NSString *VolcXor(NSString *hex) {
    if (hex.length < 2) return nil;
    NSMutableData *d = [NSMutableData data];
    for (NSUInteger i = 0; i + 1 < hex.length; i += 2) {
        unsigned b; sscanf([hex substringWithRange:NSMakeRange(i, 2)].UTF8String, "%2x", &b);
        char c = (char)(b ^ 0x3C); [d appendBytes:&c length:1];
    }
    return [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
}
static NSString *VolcToken(void)  { return VolcXor(@"5d4e57110c5f0b0f0c0b5f0511055e050811085f0858115e580d58110b0b0b5d04585d0b0a0a0c0b1109055e5f0f"); }
static NSString *VolcAppID(void)  { return VolcXor(@"6a73707f637d6c6c7578636c707d7f7974737078796e"); }

void RequestVolcTTS(NSString *text, NSString *voiceID, float rate, void (^done)(NSData *audio, NSError *error)) {
    if (!text.length) { if (done) done(nil, [NSError errorWithDomain:@"volc" code:1
        userInfo:@{NSLocalizedDescriptionKey:@"文本为空"}]); return; }
    NSString *appid = VolcAppID(), *token = VolcToken();
    if (appid.length < 4 || token.length < 8) {
        VolcLog(@"密钥未配置(appid_len=%lu token_len=%lu)", (unsigned long)appid.length, (unsigned long)token.length);
        if (done) done(nil, [NSError errorWithDomain:@"volc" code:5
            userInfo:@{NSLocalizedDescriptionKey:@"火山密钥未配置(appid/token)"}]);
        return;
    }
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:
        [NSURL URLWithString:@"https://openspeech.bytedance.com/api/v1/tts"]];
    req.HTTPMethod = @"POST";
    req.timeoutInterval = 30;
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:[NSString stringWithFormat:@"Bearer; %@", token] forHTTPHeaderField:@"Authorization"];
    double sr = MIN(2.0, MAX(0.5, (double)rate));
    NSDictionary *body = @{
        @"app":  @{@"appid": appid, @"token": token, @"cluster": @"volcano_tts"},
        @"user": @{@"uid": @"qqfloat"},
        @"audio":@{@"voice_type": voiceID ?: @"zh_female_cancan_mars_bigtts",
                   @"encoding": @"mp3",
                   @"speed_ratio": @(sr)},
        @"request":@{@"reqid": [[NSUUID UUID] UUIDString],
                     @"text": text, @"text_type": @"plain", @"operation": @"query"}
    };
    NSError *jerr = nil;
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:&jerr];
    VolcLog(@"POST voice=%@ rate=%.2f 文本%lu字", voiceID, rate, (unsigned long)text.length);
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
            if (err) { VolcLog(@"网络失败 %@", err.localizedDescription);
                if (done) done(nil, err); return; }
            NSDictionary *j = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] ?: @{};
            NSInteger code = [j[@"code"] integerValue];
            NSString *msg = j[@"message"] ?: @"";
            if (code != 0) {
                VolcLog(@"API code=%ld msg=%@", (long)code, msg);
                if (done) done(nil, [NSError errorWithDomain:@"volc" code:code
                    userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"火山 code=%ld %@", (long)code, msg]}]);
                return;
            }
            NSString *b64 = j[@"data"] ?: @"";
            NSData *mp3 = [[NSData alloc] initWithBase64EncodedString:b64 options:0];
            VolcLog(@"完成 %luB MP3", (unsigned long)mp3.length);
            if (done) done(mp3, nil);
        }];
    [task resume];
}
