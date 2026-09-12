/*
 * QQFloat_v1.m — QQ 文字转语音插件（NT 内核直调方案）
 * 基于 TTSFloat_v30.1（千问双后端 + 440 原接口音色 + 情绪标签条 + 语速）
 *
 * QQ 9.3.60 发送链（逆向定案）：
 *   MsgSenderHandler(Swift OC桥) 
 *     → sendPttMsgWithAudioModel:placeholderMsgInfo:msgAttributeInfos:saveDataToKernelResultBlock:sendMsgResultBlock:
 *     → 内部: configPttElement 读 audioFilePath 生成MD5 → 写NT kernel → QQPttUploader 上传 → 消息发出
 *   NTAIOAudioModel: audioType / audioFilePath / placeholderMsgType / isAIVoice (KVC 写入)
 *   silk 编码: QQSilkCodec encode:withSamplesCount:callback:
 *   捕捉: hook sendTextMsgWithText: 拿 MsgSenderHandler 实例（用户发一条文字即就绪）
 *
 * 与微信版本质区别：不走录音管线替换，直接调发送方法传 silk 文件路径。
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include "tts_res_ball.h"   /* 悬浮球/面板头像（CI 由 pm_res_ball2.jpg 生成） */
#include "tts_res_tip.h"    /* 打赏二维码（CI 由 pm_res_tip2.jpg 生成） */


/* ==================== 配置 ==================== */
/* 端点拆三段，避免 strings 直出 */
#define K_EP_A @"https://"
#define K_EP_B_OBF @"2d2d2d742e333b22742a2d751b0a1375"
static NSString *TTSXorHex(const char *hex, int key);
#define K_EP_C_OBF @"232f23333468742a322a"
static NSString *TTSEndpoint(void) {
    static NSString *e = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ e = [K_EP_A stringByAppendingString:
        [TTSXorHex(K_EP_B_OBF.UTF8String, 0x5A) stringByAppendingString:TTSXorHex(K_EP_C_OBF.UTF8String, 0x5A)]]; });
    return e;
}
#define K_DEFAULT_VOICE @"TVB女"
#define K_KEY_A_HEX @"040a0f0c0a5e5d0d5f5a0458090c5e0e040a0a5f04"
#define K_KEY_B_HEX @"0f0a055d0d085e0f04085a590d5a5a050a050c0c5f"
#define K_KEY_C_HEX @"5d040e0e5805045e580f090e0b0859040b5e0c0a0f09"

/* ==================== v30: 千问后端配置 ====================
 * DashScope 原生端点 + qwen3-tts-instruct-flash。
 * 实测（2026-09-12）：POST JSON {"model","input":{"text"},"parameters":{"voice","format","speech_rate","instruction"}}
 * 返回 {"output":{"audio":{"url":OSS音频}}} —— OSS URL 是 http，iOS ATS 要 https，下载前替换前缀。
 * speech_rate/pitch 静默接受（不报错）；instruction 语气指令实测生效（河南话验证）。 */
#define QW_TTS_PATH @"/api/v1/services/aigc/multimodal-generation/generation"
#define QW_HOST_A @"a7a2b0abb0a0ac"        /* dashsco   XOR 0xC3 */
#define QW_HOST_B @"b3a6eda2afaaba"        /* pe.aliy   XOR 0xC3 */
#define QW_HOST_C @"b6ada0b0eda0acae"      /* uncs.com  XOR 0xC3 */
#define QW_KEY_A_HEX @"4f57114b4f1174126c7864706c6474120e457a70127179657f756d78524e4f71634a5772784644"
#define QW_KEY_B_HEX @"0b05634f6c5e6c0e70597a580a44744d5b556572046b5679580e0e704d0d0b6d75547d770c697a"
#define QW_KEY_C_HEX @"787f515209784554685f08576f567b6b68530e5d6a52490b78087a0d5e724c74704c515d71700b"
static NSString *const kQwenVoiceKey     = @"TTSFloatQwenVoice";      /* 千问音色ID持久化 */
static NSString *const kBackendKey       = @"TTSFloatBackend";        /* 0=原接口 1=千问 */
static NSString *const kQwenRateKey      = @"TTSFloatQwenRate";       /* 语速 0.5~2.0 */
static NSString *const kQwenInstrKey     = @"TTSFloatQwenInstr";      /* 语气指令自由文本 */
static NSInteger g_backend = 0;              /* 0=原接口(tiax) 1=千问直连 */
static NSString *g_qwenVoice = @"Cherry";    /* 千问音色 ID（英文标识） */
static float g_qwenRate = 1.0f;              /* 语速 */
static NSString *g_qwenInstr = nil;          /* 语气情绪显示名（可空，下发时转换指令） */

/* v30.1: 情绪预设表（显示名，索引对齐） */
static NSString *const g_qwEmoNames[] = {
    @"默认", @"生气", @"愤怒", @"快乐", @"开心", @"兴奋", @"悲伤",
    @"难过", @"恐惧", @"害怕", @"惊讶", @"温柔", @"严肃", @"沉稳",
    @"激动", @"委屈", @"撒娇", @"嘲讽", @"耳语", @"大喊",
};
#define QW_EMO_COUNT (sizeof(g_qwEmoNames) / sizeof(g_qwEmoNames[0]))

static NSInteger g_targetSampleRate = 16000;

/* v25: 当前音色（持久化到 NSUserDefaults，微信重启不丢） */
static NSString *g_voiceName = nil;
static NSString *const kTTSVoiceKey = @"TTSFloatVoiceName";

/* ==================== v25: 动态音色（全部来自 ys.php，删除旧硬编码列表） ====================
 * 音色接口：TTSVoiceEndpoint()（密文表内）
 * 合成接口：TTSEndpoint()（密文表内），参数 text/voice/apikey
 * voice 参数实测直接用中文名（返回 code=200 + mp3 url），列表去重保序。
 * ⚠️ ys.php 偶发抽风/慢：拉取失败时列表为空，面板顶部会显示"音色列表加载失败"，
 *    再点一次音色行会重新拉；合成时用当前选中名（默认 K_DEFAULT_VOICE）。 */

static NSArray *g_voices = nil;          /* 全量音色名（去重保序，仅显示/存储用） */
static NSArray *g_voiceIDs = nil;        /* 与 g_voices 同序的数字 ID（合成请求实际用） */
static NSArray *g_voiceFilter = nil;     /* 搜索过滤结果（nil = 不过滤） */
static NSInteger g_voiceFetchState = 0;  /* 0 未拉取 / 1 进行中 / 2 成功 / -1 失败 */
static BOOL g_voiceFetchInited = NO;

/* ==================== 日志 ==================== */
static NSString *g_logPath = nil;
static void TTLog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[TTSFloat] %@", s);
    if (!g_logPath) return;
    @autoreleasepool {
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:g_logPath];
        if (!fh) {
            [[NSFileManager defaultManager] createFileAtPath:g_logPath contents:nil attributes:nil];
            fh = [NSFileHandle fileHandleForWritingAtPath:g_logPath];
        }
        if (fh) {
            [fh seekToEndOfFile];
            [fh writeData:[[NSString stringWithFormat:@"[TTSFloat] %@\n", s] dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        }
    }
}


/* ==================== v26: 关键字符串运行时解码（反 strings 提取） ====================
 * strings/IDA 里搜不到 hook 类名 / selector / 域名——全部 XOR 解码或分段拼接。
 * 逆向者必须反汇编到 TTSXorDecode 才能还原目标。 */
/* v26: hex 密文 → XOR 解码。密文只含 [0-9a-f]，strings 里就是一段普通 hex，无语义 */
static NSString *TTSXorHex(const char *hex, int key) {
    if (!hex) return nil;
    NSUInteger n = strlen(hex) / 2;
    NSMutableString *o = [NSMutableString stringWithCapacity:n];
    for (NSUInteger i = 0; i < n; i++) {
        /* hex→int（标准写法；此前 'a'-'0' 的偏移写错导致解码全乱 → 类名 MISS）*/
        int hi = hex[i*2];   if (hi >= 'a') hi -= 'a' - 10; else hi -= '0';
        int lo = hex[i*2+1]; if (lo >= 'a') lo -= 'a' - 10; else lo -= '0';
        int v = (hi << 4) | lo;
        v ^= key;
        if (v == 0) break;   /* 密文不含 0x00；遇到即截断 */
        [o appendFormat:@"%C", (unichar)v];
    }
    return o;
}

/* v26: XOR 密文表（k=0x5A 类名 / k=0x3C selector）——strings 搜不到明文 */
static NSArray *TTSObfTable(void) {
    static NSArray *t = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ t = @[
        @"1b2f3e3335093f343e3f28"  /* cls */,
        @"17100933363119353e3f39"  /* cls */,
        @"4c4e594c5d4e596f59525806"  /* sel */,
        @"6f48534c6e595f534e58"  /* sel */,
        @"73526e595f534e58594e7952586e595f534e5855525b06"  /* sel */,
        @"73526e595f534e58594e7952586e595f534e5855525b06694f594e785d485d06"  /* sel */,
        @"73526e595f534e58594e7952586e595f534e5855525b06794e4e534e06"  /* sel */,
        @"73526e595f534e58594e6c5d4e4806735a5a4f594806705952067952587a505d5b067a534e5f597859505948590678494e5d4855535206"  /* sel */,
        @"73527349484c49486c5f517e495a5a594e06694f594e785d485d06"  /* sel */,
        @"7d495855536d4959495972594b75524c4948"  /* sel */,
        @"6f485d4e486e595f534e587a4e5351066853694f594e06694f594e75525a5306"  /* sel */,
        @"6f595258734e556a53555f59714f5b6b554854694f594e785d485d06"  /* sel */
,
        @"48594448"  /* text */,
        @"4a53555f59"  /* voice */,
        @"5d4c55575945"  /* apikey */        ]; });
    return t;
}
static NSString *TTSCls(int i) { return TTSXorHex([TTSObfTable()[i] UTF8String], 0x5A); }
static NSString *TTCSel(int i) { return TTSXorHex([TTSObfTable()[2 + i] UTF8String], 0x3C); }
/* ==================== 崩溃定位（v23 新增） ====================
 * 闪退后日志里会多出 [CRASH] 行；dylib 基址一并打印，
 * 崩溃帧地址 - 基址 = Hopper 里 MicroMessenger.dylib 的偏移（结合 .ips 报告定位）。 */
#include <string.h>
#include <signal.h>
#include <unistd.h>
#include <fcntl.h>
#include <dlfcn.h>
static int g_crashFd = -1;
static void TTSCrashLogException(NSException *e) {
    TTLog(@"[CRASH-EXC] %@ - %@\n%@", e.name, e.reason, e.callStackSymbols);
}
static void TTSCrashHandler(int sig, siginfo_t *info, void *uc) {
    /* v27: 信号处理器必须 async-signal-safe —— 只用 write()，
     * 不再调 backtrace/backtrace_symbols（内部走 malloc，SIGSEGV 里二次崩） */
    (void)uc;
    char buf[128];
    int n = snprintf(buf, sizeof(buf), "\n[CRASH] sig=%d addr=%p\n",
                     sig, info ? info->si_addr : NULL);
    if (g_crashFd >= 0) {
        ssize_t w = write(g_crashFd, buf, (size_t)n);
        (void)w;
    }
    _exit(128 + sig);
}
static void TTSInstallCrashGuards(void) {
    NSString *p = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/TTSCrash.log"];
    g_crashFd = open(p.fileSystemRepresentation, O_WRONLY | O_CREAT | O_APPEND, 0644);
    Dl_info di; void *self0 = (void *)&TTSInstallCrashGuards;
    if (dladdr(self0, &di)) {
        TTLog(@"[crash-guard] dylib=%s base=%p", di.dli_fname ? di.dli_fname : "?", di.dli_fbase);
    }
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = TTSCrashHandler;
    sa.sa_flags = SA_SIGINFO | SA_ONSTACK;
    sigaction(SIGSEGV, &sa, NULL);
    sigaction(SIGABRT, &sa, NULL);
    sigaction(SIGBUS, &sa, NULL);
    sigaction(SIGILL, &sa, NULL);
    NSSetUncaughtExceptionHandler(&TTSCrashLogException);
}

/* ---------- v25b: 宽松解析（兼容 "N. " / "N、" / "N)" / 纯换行无编号 / HTML 标签） ---------- */
static NSString *TTSTrim(NSString *s) {
    return [s stringByTrimmingCharactersInSet:
              [NSCharacterSet whitespaceAndNewlineCharacterSet]];
}
/* 名称里允许中文/字母数字/空格/常见符号；拒绝还带 HTML 标签的行 */
static BOOL TTSVoiceNameOK(NSString *n) {
    if (n.length < 1 || n.length > 24) return NO;
    if ([n rangeOfString:@"<"].location != NSNotFound) return NO;
    if ([n rangeOfString:@"http"].location != NSNotFound) return NO;
    return YES;
}
static void TTSAddVoice(NSMutableArray *out, NSMutableArray *ids, NSMutableSet *seen,
                        NSString *name, NSString *vid) {
    NSString *n = TTSTrim(name);
    if (!TTSVoiceNameOK(n)) return;
    NSString *key = [n lowercaseString];
    if ([seen containsObject:key]) return;
    [seen addObject:key];
    [out addObject:n];
    [ids addObject:vid.length ? vid : [NSString stringWithFormat:@"%lu", (unsigned long)out.count]];
}
static NSArray *g_lastParsedIDs = nil;   /* TTSParseVoiceList 的 ID 伴随输出 */
static NSArray *TTSParseVoiceList(NSString *raw0) {
    /* 万一是 HTML：去标签 + 实体还原（<br> 转换行），再按行解析 */
    NSString *text = raw0;
    if ([text rangeOfString:@"<"].location != NSNotFound) {
        text = [text stringByReplacingOccurrencesOfString:@"<br>" withString:@"\n" options:NSCaseInsensitiveSearch range:NSMakeRange(0, text.length)];
        text = [text stringByReplacingOccurrencesOfString:@"<br/>" withString:@"\n" options:NSCaseInsensitiveSearch range:NSMakeRange(0, text.length)];
        text = [text stringByReplacingOccurrencesOfString:@"<br />" withString:@"\n" options:NSCaseInsensitiveSearch range:NSMakeRange(0, text.length)];
        text = [text stringByReplacingOccurrencesOfString:@"<p>" withString:@"\n" options:NSCaseInsensitiveSearch range:NSMakeRange(0, text.length)];
        text = [text stringByReplacingOccurrencesOfString:@"</p>" withString:@"\n" options:NSCaseInsensitiveSearch range:NSMakeRange(0, text.length)];
        text = [text stringByReplacingOccurrencesOfString:@"&nbsp;" withString:@" "];
        text = [text stringByReplacingOccurrencesOfString:@"&quot;" withString:@"\""];
        text = [text stringByReplacingOccurrencesOfString:@"&amp;" withString:@"&"];
        text = [text stringByReplacingOccurrencesOfString:@"<[^>]+>" withString:@"\n" options:NSRegularExpressionSearch range:NSMakeRange(0, text.length)];
    }
    NSMutableArray *out = [NSMutableArray array];
    NSMutableArray *ids = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    NSArray<NSString *> *seps = @[ @".", @"、", @")", @"）", @":", @"：" ];
    NSArray *lines = [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet];
    for (NSString *raw in lines) {
        NSString *ln = TTSTrim(raw);
        if (ln.length < 2) continue;
        NSUInteger d = 0;
        unichar c0 = [ln characterAtIndex:0];
        if (c0 < '0' || c0 > '9') continue;
        while (d < ln.length && d < 6 &&
               [[NSCharacterSet decimalDigitCharacterSet] characterIsMember:[ln characterAtIndex:d]]) d++;
        if (d == 0 || d > 5) continue;
        NSString *vid = [ln substringToIndex:d];
        NSString *rest = [ln substringFromIndex:d];
        for (NSString *sep in seps) {
            if ([rest hasPrefix:sep]) { TTSAddVoice(out, ids, seen, [rest substringFromIndex:sep.length], vid); break; }
        }
    }
    /* 兜底：无编号（纯换行一行一个名字）——取前 800 行 */
    if (out.count < 5) {
        [out removeAllObjects]; [ids removeAllObjects]; [seen removeAllObjects];
        NSUInteger n = 0;
        for (NSString *raw in lines) {
            NSString *ln = TTSTrim(raw);
            if (ln.length == 0 || ln.length > 24) continue;
            if ([ln rangeOfString:@"<"].location != NSNotFound) continue;
            TTSAddVoice(out, ids, seen, ln, [NSString stringWithFormat:@"%lu", (unsigned long)(n + 1)]);
            if (++n >= 800) break;
        }
    }
    g_lastParsedIDs = ids;
    return out;
}
/* 失败时打印正文样本（转义换行），一次定位问题 */
static NSString *TTSTextSample(NSString *s, NSUInteger n) {
    if (s.length == 0) return @"(空)";
    NSString *t = [s substringToIndex:MIN(n, s.length)];
    t = [t stringByReplacingOccurrencesOfString:@"\n" withString:@"\\n"];
    t = [t stringByReplacingOccurrencesOfString:@"\r" withString:@"\\r"];
    return t;
}
/* 多编码兜底：UTF8 → GB18030 → ISO Latin → UTF16 */
static NSString *TTSDecodeBody(NSData *data) {
    if (!data.length) return nil;
    NSStringEncoding encs[] = { NSUTF8StringEncoding,
                                CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingGB_18030_2000),
                                NSISOLatin1StringEncoding,
                                NSUTF16StringEncoding };
    for (int i = 0; i < 4; i++) {
        NSString *s = [[NSString alloc] initWithData:data encoding:encs[i]];
        if (s.length) return s;
    }
    return nil;
}

/* v26: 音色接口地址（密文解码） */
static NSString *TTSVoiceEndpoint(void) {
    static NSString *e = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ e = [[K_EP_A stringByAppendingString:TTSXorHex(K_EP_B_OBF.UTF8String, 0x5A)]
        stringByAppendingString:TTSXorHex("2329742a322a", 0x5A)]; });
    return e;
}

/* ---------- v25b: 拉取（3 次重试 + Referer/UA + 完整诊断日志） ---------- */
static void TTSVoiceTry(NSInteger attempt, void (^done)(BOOL ok, NSUInteger n)) {
    NSMutableURLRequest *req = [NSMutableURLRequest
        requestWithURL:[NSURL URLWithString:TTSVoiceEndpoint()]
          cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:30];
    [req setValue:[K_EP_A stringByAppendingString:TTSXorHex(K_EP_B_OBF.UTF8String, 0x5A)] forHTTPHeaderField:@"Referer"];
    [req setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15"
          forHTTPHeaderField:@"User-Agent"];
    [req setValue:@"text/plain,text/html,*/*" forHTTPHeaderField:@"Accept"];
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block NSData *rData = nil; __block NSURLResponse *rResp = nil; __block NSError *rErr = nil;
    NSURLSessionDataTask *t = [NSURLSession.sharedSession
        dataTaskWithRequest:req
        completionHandler:^(NSData *d, NSURLResponse *resp, NSError *e) {
            rData = d; rResp = resp; rErr = e;
            dispatch_semaphore_signal(sem);
        }];
    [t resume];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(35 * NSEC_PER_SEC)));

    NSInteger status = [rResp isKindOfClass:[NSHTTPURLResponse class]] ? (NSInteger)((NSHTTPURLResponse *)rResp).statusCode : -1;
    NSString *text = TTSDecodeBody(rData);
    NSArray *list = text.length ? TTSParseVoiceList(text) : nil;

    if (list.count > 0) {
        g_voices = list;
        g_voiceIDs = g_lastParsedIDs;
        g_voiceFetchState = 2;
        @synchronized([NSObject class]) {
            if (g_voiceName.length == 0 || ![list containsObject:g_voiceName]) {
                g_voiceName = K_DEFAULT_VOICE;   /* 旧音色不在新表里 → 回落默认 */
            }
        }
        TTLog(@"[voice-api] ok n=%lu status=%ld bytes=%lu 首个=%@",
              (unsigned long)list.count, (long)status, (unsigned long)rData.length, list.firstObject);
        if (done) done(YES, list.count);
        return;
    }

    TTLog(@"[voice-api] fail try=%d err=%@ status=%ld bytes=%lu textLen=%lu sample=%@",
          (int)attempt, rErr.localizedDescription ?: @"nil", (long)status,
          (unsigned long)rData.length, (unsigned long)text.length, TTSTextSample(text, 300));
    if (attempt < 2) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                       dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            TTSVoiceTry(attempt + 1, done);
        });
        return;
    }
    g_voiceFetchState = -1;
    TTLog(@"[voice-api] 放弃：用内置音色表（点列表右上\"重新加载\"可再试）");
    if (done) done(NO, 0);
}

static void TTSFetchVoices(void (^done)(BOOL ok, NSUInteger n)) {
    g_voiceFetchState = 1;
    /* ⚠️ 重试内部用信号量等待，绝不能在主线程跑 */
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        TTSVoiceTry(0, done);
    });
}

static void TTSInitVoicesIfNeeded(void) {
    if (g_voiceFetchInited) return;
    g_voiceFetchInited = YES;
    TTSFetchVoices(nil);
}

/* 当前音色名（发送时用） */
static NSString *TTSCurVoice(void) {
    NSString *v = nil;
    @synchronized([NSObject class]) {
        v = g_voiceName;
        if (v.length == 0) {
            v = [NSUserDefaults.standardUserDefaults stringForKey:kTTSVoiceKey];
            if (v.length == 0) v = K_DEFAULT_VOICE;
            g_voiceName = v;
        }
    }
    return v;
}
static void TTSSetVoice(NSString *name) {
    @synchronized([NSObject class]) { g_voiceName = name; }
    [NSUserDefaults.standardUserDefaults setObject:name forKey:kTTSVoiceKey];
}
/* 名称 → 数字 ID（合成请求真正用的参数）。
 * 实测结论：yuyin2.php 的 voice 只认【序号 ID】，传中文名会被静默忽略、
 * 全部按 id=1（TVB女）合成 —— 这就是"换音色没反应、始终一个音色"的根因。 */
static NSString *TTSVoiceIDForName(NSString *name) {
    NSArray *vs = nil, *ids = nil;
    @synchronized([NSObject class]) { vs = g_voices; ids = g_voiceIDs; }
    if (!name.length) return @"1";
    if (vs.count && ids.count == vs.count) {
        NSUInteger i = [vs indexOfObject:name];
        if (i != NSNotFound && i < ids.count) return ids[i];
    }
    /* 兜底：名字数字开头就直接用 */
    if ([[name substringToIndex:1] isEqualToString:@""] == NO &&
        [[NSCharacterSet decimalDigitCharacterSet] characterIsMember:[name characterAtIndex:0]] &&
        name.intValue > 0) return name;
    return @"1";
}



/* ==================== v30: 千问后端（直连 DashScope） ====================
 * 音色表 48 个（官方 qwen3-tts-instruct-flash 全量）。
 * 显示用"ID·中文名"，请求时只传 ID。 */
static NSString *const g_qwenVoices[][2] = {
    {@"Cherry", @"芊悦·阳光亲切小姐姐"},
    {@"Serena", @"苏瑶·温柔小姐姐"},
    {@"Ethan", @"晨煦·温暖活力男声"},
    {@"Chelsie", @"千雪·二次元虚拟女友"},
    {@"Momo", @"茉兔·撒娇搞怪"},
    {@"Vivian", @"十三·拽拽小暴躁"},
    {@"Moon", @"月白·率性帅气男声"},
    {@"Maia", @"四月·知性温柔"},
    {@"Kai", @"凯·耳朵SPA男声"},
    {@"Nofish", @"不吃鱼·设计师"},
    {@"Bella", @"萌宝·小萝莉"},
    {@"Jennifer", @"詹妮弗·电影质感美语"},
    {@"Ryan", @"甜茶·戏感炸裂男声"},
    {@"Katerina", @"卡捷琳娜·御姐"},
    {@"Aiden", @"艾登·美语大男孩"},
    {@"Eldric Sage", @"沧明子·沉稳老者"},
    {@"Mia", @"乖小妹·温顺乖巧"},
    {@"Mochi", @"沙小弥·早慧小大人"},
    {@"Bellona", @"燕铮莺·千面人声江湖"},
    {@"Vincent", @"田叔·沙哑烟嗓"},
    {@"Bunny", @"萌小姬·萌属性萝莉"},
    {@"Neil", @"阿闻·专业新闻主持"},
    {@"Elias", @"墨讲师·知识讲师"},
    {@"Arthur", @"徐大爷·质朴讲故事"},
    {@"Nini", @"邻家妹妹·软黏甜嗓"},
    {@"Seren", @"小婉·助眠晚安"},
    {@"Pip", @"顽屁小孩·调皮小新"},
    {@"Stella", @"少女阿月·迷糊少女"},
    {@"Bodega", @"博德加·西班牙大叔"},
    {@"Sonrisa", @"索尼莎·拉美大姐"},
    {@"Alek", @"阿列克·战斗民族"},
    {@"Dolce", @"多尔切·慵懒意大利大叔"},
    {@"Sohee", @"素熙·韩国欧尼"},
    {@"Ono Anna", @"小野杏·青梅竹马"},
    {@"Lenn", @"莱恩·后朋克德国青年"},
    {@"Emilien", @"埃米尔安·浪漫法国哥哥"},
    {@"Andre", @"安德雷·磁性沉稳"},
    {@"Radio Gol", @"拉迪奥·足球诗人解说"},
    {@"Jada", @"上海阿珍·沪上阿姐(上海话)"},
    {@"Dylan", @"北京晓东·胡同少年(北京话)"},
    {@"Li", @"南京老李·瑜伽老师(南京话)"},
    {@"Marcus", @"陕西秦川·老陕味道(陕西话)"},
    {@"Roy", @"闽南阿杰·台湾哥仔(闽南语)"},
    {@"Peter", @"天津李彼得·专业捧哏(天津话)"},
    {@"Sunny", @"四川晴儿·甜川妹子(四川话)"},
    {@"Eric", @"四川程川·跳脱市井(四川话)"},
    {@"Rocky", @"粤语阿强·幽默陪聊(粤语)"},
    {@"Kiki", @"粤语阿清·甜美港妹(粤语)"},
};
#define QW_VOICE_COUNT (sizeof(g_qwenVoices) / sizeof(g_qwenVoices[0]))

/* 千问音色显示名 → 请求 ID */
static NSString *QwenVoiceIDFromDisplay(NSString *display) {
    for (NSUInteger i = 0; i < QW_VOICE_COUNT; i++) {
        if ([display isEqualToString:g_qwenVoices[i][1]] ||
            [display isEqualToString:g_qwenVoices[i][0]]) return g_qwenVoices[i][0];
    }
    /* 容错：显示名可能是 "Cherry·芊悦·xxx" 混合形态 → 前缀匹配 ID */
    for (NSUInteger i = 0; i < QW_VOICE_COUNT; i++) {
        if ([display hasPrefix:g_qwenVoices[i][0]]) return g_qwenVoices[i][0];
    }
    return @"Cherry";
}
/* 千问音色 ID → 显示名 */
static NSString *QwenDisplayFromID(NSString *vid) {
    for (NSUInteger i = 0; i < QW_VOICE_COUNT; i++) {
        if ([vid isEqualToString:g_qwenVoices[i][0]])
            return [NSString stringWithFormat:@"%@·%@", g_qwenVoices[i][0], g_qwenVoices[i][1]];
    }
    return @"Cherry·芊悦·阳光亲切小姐姐";
}

/* 后端状态读写（持久化） */
static void QwenLoadState(void) {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    NSInteger b = [d integerForKey:kBackendKey];
    g_backend = (b == 1) ? 1 : 0;
    NSString *v = [d stringForKey:kQwenVoiceKey];
    if (v.length) g_qwenVoice = v;
    double r = [d doubleForKey:kQwenRateKey];
    if (r >= 0.5 && r <= 2.0) g_qwenRate = (float)r;
    NSString *ins = [d stringForKey:kQwenInstrKey];
    if (ins.length) g_qwenInstr = ins;
}
static void QwenSaveBackend(NSInteger b) {
    g_backend = b;
    [NSUserDefaults.standardUserDefaults setInteger:b forKey:kBackendKey];
}
static void QwenSaveVoice(NSString *vid) {
    g_qwenVoice = vid;
    [NSUserDefaults.standardUserDefaults setObject:vid forKey:kQwenVoiceKey];
}
static void QwenSaveRate(float r) {
    g_qwenRate = r;
    [NSUserDefaults.standardUserDefaults setFloat:r forKey:kQwenRateKey];
}
static void QwenSaveInstr(NSString *s) {
    g_qwenInstr = s.length ? s : nil;
    if (s.length) [NSUserDefaults.standardUserDefaults setObject:s forKey:kQwenInstrKey];
    else [NSUserDefaults.standardUserDefaults removeObjectForKey:kQwenInstrKey];
}

/* DashScope key（三段 hex XOR 0x3C，同 TiaxKey 手法） */
static NSString *QwenKey(void) {
    static NSString *k = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        k = [TTSXorHex(QW_KEY_A_HEX.UTF8String, 0x3C) stringByAppendingString:
            [TTSXorHex(QW_KEY_B_HEX.UTF8String, 0x3C) stringByAppendingString:
              TTSXorHex(QW_KEY_C_HEX.UTF8String, 0x3C)]];
    });
    return k;
}
/* DashScope 域名（三段 hex XOR 0xC3 运行时拼） */
static NSString *QwenHost(void) {
    static NSString *h = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        h = [TTSXorHex(QW_HOST_A.UTF8String, 0xC3) stringByAppendingString:
            [TTSXorHex(QW_HOST_B.UTF8String, 0xC3) stringByAppendingString:
              TTSXorHex(QW_HOST_C.UTF8String, 0xC3)]];
    });
    return h;
}

/* 千问合成：POST JSON → {"output":{"audio":{"url":OSS}}} → https 化下载
 * text: 合成文本  voiceID: 音色  rate: 语速 0.5~2.0  instr: 语气指令(可nil) */
static void TTSDownloadAudio(NSString *audioURL, void (^done)(NSData *audio, NSError *error));   /* v30: 前置声明 */
static void RequestQwenTTS(NSString *text, NSString *voiceID, float rate, NSString *instr,
                           void (^done)(NSData *audio, NSError *error)) {
    NSString *key = QwenKey();
    if (![key hasPrefix:@"sk-"] || key.length < 20) {
        done(nil, [NSError errorWithDomain:@"QWEN" code:20 userInfo:@{NSLocalizedDescriptionKey:@"千问key未配置"}]);
        return;
    }
    NSMutableDictionary *params = [NSMutableDictionary dictionaryWithDictionary:@{
        @"voice": voiceID.length ? voiceID : @"Cherry",
        @"format": @"wav",
    }];
    if (rate >= 0.5f && rate <= 2.0f && rate != 1.0f) params[@"speech_rate"] = @(rate);
    if (instr.length) params[@"instruction"] = instr;
    NSDictionary *body = @{
        @"model": @"qwen3-tts-instruct-flash-2026-01-26",
        @"input": @{@"text": text ?: @""},
        @"parameters": params,
    };
    NSString *urlStr = [NSString stringWithFormat:@"https://%@%@", QwenHost(), QW_TTS_PATH];
    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url) { done(nil, [NSError errorWithDomain:@"QWEN" code:21 userInfo:@{NSLocalizedDescriptionKey:@"URL无效"}]); return; }
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    req.timeoutInterval = 40;
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    [req setValue:[NSString stringWithFormat:@"Bearer %@", key] forHTTPHeaderField:@"Authorization"];
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    TTLog(@"[qwen] POST voice=%@ rate=%.2f instr=%@ len=%lu",
          voiceID, rate, instr.length ? instr : @"-", (unsigned long)text.length);

    NSURLSessionDataTask *task = [NSURLSession.sharedSession dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *r, NSError *e) {
            if (e) { TTLog(@"[qwen] neterr %@", e.localizedDescription); done(nil, e); return; }
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if (![json isKindOfClass:[NSDictionary class]]) {
                NSString *raw = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                TTLog(@"[qwen] 非JSON: %@", [raw length] > 200 ? [raw substringToIndex:200] : raw);
                done(nil, [NSError errorWithDomain:@"QWEN" code:22 userInfo:@{NSLocalizedDescriptionKey:@"千问返回非JSON"}]);
                return;
            }
            NSString *code = json[@"code"], *msg = json[@"message"];
            if (code.length) {
                TTLog(@"[qwen] API错误 %@: %@", code, msg);
                done(nil, [NSError errorWithDomain:@"QWEN" code:23 userInfo:@{NSLocalizedDescriptionKey:
                    [NSString stringWithFormat:@"千问: %@ %@", code, msg ?: @""]}]);
                return;
            }
            NSString *aurl = json[@"output"][@"audio"][@"url"];
            if (![aurl isKindOfClass:[NSString class]] || !aurl.length) {
                TTLog(@"[qwen] 无url: %@", json);
                done(nil, [NSError errorWithDomain:@"QWEN" code:24 userInfo:@{NSLocalizedDescriptionKey:@"千问无音频url"}]);
                return;
            }
            /* OSS 返回 http:// → iOS ATS 要 https，实测同 URL https 可用 */
            if ([aurl hasPrefix:@"http:"]) aurl = [@"https" stringByAppendingString:[aurl substringFromIndex:4]];
            TTLog(@"[qwen] url ok (%lu chars)", (unsigned long)aurl.length);
            TTSDownloadAudio(aurl, done);
        }];
    [task resume];
}





/* ==================== v1 QQ 侧状态（发送链捕获） ====================
 * hook sendTextMsgWithText: 捕获 MsgSenderHandler 实例 + msgAttributeInfos(可空字典)。
 * 用户在 QQ 里发一条文字 → 全自动就绪。 */
static id g_qqSenderHandler = nil;      /* _TtC10MsgManager16MsgSenderHandler 实例 */
static NSDictionary *g_qqLastMsgAttrs = nil;

/* QQ silk 编码：QQSilkCodec encode:withSamplesCount:callback:（QQ 内置，v1 无需自实现）
 * pcm: 16bit mono PCM  rate: 采样率 */
static NSData *QQSilkEncode(NSData *pcm, uint32_t rate) {
    Class c = NSClassFromString(@"QQSilkCodec");
    if (!c) { TTLog(@"[silk] QQSilkCodec MISS"); return nil; }
    @try {
        id codec = [[c alloc] init];
        SEL pSel = NSSelectorFromString(@"setEncodeParam");
        if ([codec respondsToSelector:pSel]) ((void (*)(id, SEL))objc_msgSend)(codec, pSel);
        /* encode:withSamplesCount:callback: 返回 uint64 总长，帧数据经 callback 递给 */
        NSMutableData *out = [NSMutableData data];
        /* QQSilkRecorder 的做法: PCM→silk文件。这里直接用 encode 方法流式拉帧:
         * 先写 silk 文件头? silk v3 文件 = 0x02 0x00 0x00 0x00 前缀 + 950ms 帧 */
        [out appendBytes:"\\x02" length:0];  /* 占位, 下行真实写入 */
        SEL encSel = NSSelectorFromString(@"encode:withSamplesCount:callback:");
        if (![codec respondsToSelector:encSel]) { TTLog(@"[silk] encode sel MISS"); return nil; }
        const int16_t *samples = (const int16_t *)pcm.bytes;
        NSUInteger total = pcm.length / 2;
        NSUInteger frame = 20 * rate / 1000;   /* 20ms 一帧 */
        __block NSMutableData *acc = [NSMutableData data];
        for (NSUInteger off = 0; off + frame <= total; off += frame) {
            NSData *chunk = [NSData dataWithBytes:samples+off length:frame*2];
            ((uint64_t (*)(id, SEL, id, NSUInteger, void (^)(const void *, uint64_t)))objc_msgSend)
                (codec, encSel, chunk, frame, ^(const void *d, uint64_t n) {
                    if (d && n) [acc appendBytes:d length:(NSUInteger)n];
                });
        }
        if (acc.length == 0) { TTLog(@"[silk] 无帧输出"); return nil; }
        NSMutableData *file = [NSMutableData data];
        /* silk 文件头 (微信/QQ 通用 0x02 0x00 0x00 0x00) */
        unsigned char hdr[4] = {0x02, 0x00, 0x00, 0x00};
        [file appendBytes:hdr length:4];
        [file appendData:acc];
        return file;
    } @catch (NSException *e) { TTLog(@"[silk] 异常 %@", e); return nil; }
}


/* ==================== UI ==================== */
static UIWindow *g_ttsWindow = nil;

/* v24: 头像（悬浮球 + 面板左上角共用） */
static UIImage *TTSLoadBallImage(void) {
    static UIImage *img = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        img = [UIImage imageWithData:[NSData dataWithBytes:TTS_RES_BALL length:TTS_RES_BALL_LEN]];
        if (!img) TTLog(@"[ui] 头像解码失败 len=%u", TTS_RES_BALL_LEN);
    });
    return img;
}

@interface TTSPassWindow : UIWindow
@end
@implementation TTSPassWindow
- (UIView *)hitTest:(CGPoint)p withEvent:(UIEvent *)e {
    UIView *hit = [super hitTest:p withEvent:e];
    return (hit == self || hit == self.rootViewController.view) ? nil : hit;
}
@end

@interface TTSRootController : UIViewController
@end
@implementation TTSRootController
- (BOOL)prefersStatusBarHidden { return YES; }
@end

@interface TTSFloatView : UIView <UITableViewDataSource, UITableViewDelegate, UIGestureRecognizerDelegate, UISearchBarDelegate>
@property (nonatomic, strong) UIView *panel;
@property (nonatomic, strong) UITextView *input;
@property (nonatomic, strong) UIButton *send;
@property (nonatomic, strong) UILabel *voiceLabel;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) UIView *tipMask;
@property (nonatomic, strong) UISearchBar *searchField;
@property (nonatomic, strong) UITableView *voiceTable;
- (void)dragPanel:(UIPanGestureRecognizer *)g;
- (void)showVoiceList;
- (void)reloadVoices;
- (void)qwRateChanged:(UISlider *)s;      /* v30: 语速滑杆 */
- (void)qwEmoTapped:(UIButton *)b;        /* v30.1: 情绪标签点选 */
- (NSString *)qwEmoDisplayForIdx:(NSUInteger)idx;   /* v30.1: 索引→显示名 */
- (void)closeVoiceList;
- (void)maskTapped:(UITapGestureRecognizer *)g;
- (void)closePanel;
- (void)showTip;
- (void)closeTip;
- (void)tipMaskTapped:(UITapGestureRecognizer *)g;
- (void)kbWillShow:(NSNotification *)n;
- (void)kbWillHide:(NSNotification *)n;
- (void)sendDirect;
- (NSString *)sendVoiceToWeChat:(NSData *)pcm toUsr:(NSString *)toUsr { return nil; }
@end

@implementation TTSFloatView

+ (void)load {
    /* v1 QQ: 启动时序——等 QQ 自己的 window 就绪（v27 微信验证过的安全形态） */
    __block id obs = nil;
    obs = [[NSNotificationCenter defaultCenter]
        addObserverForName:UIApplicationDidFinishLaunchingNotification object:nil
        queue:[NSOperationQueue mainQueue]
        usingBlock:^(NSNotification *n) {
            [[NSNotificationCenter defaultCenter] removeObserver:obs];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                if (![UIApplication sharedApplication].keyWindow) return;
                /* 创建悬浮球 window（v24 形态：穿透 TTSPassWindow + 圆形头像） */
                static dispatch_once_t once;
                dispatch_once(&once, ^{
                    CGRect scr = UIScreen.mainScreen.bounds;
                    UIWindow *w = [[TTSPassWindow alloc] initWithFrame:scr];
                    w.rootViewController = [TTSRootController new];
                    w.windowLevel = UIWindowLevelAlert + 100;
                    TTSFloatView *ball = [[TTSFloatView alloc] initWithFrame:CGRectMake(scr.size.width-70, 180, 56, 56)];
                    ball.center = CGPointMake(scr.size.width-38, 200);
                    [w addSubview:ball];
                    g_ttsWindow = w;
                    [w makeKeyAndVisible];
                    [UIApplication.sharedApplication.keyWindow makeKeyWindow];  /* 关键键盘还给QQ */
                });
                TTSInitVoicesIfNeeded();
            });
        }];
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.backgroundColor = [UIColor colorWithWhite:0.98 alpha:0.98];
    self.layer.cornerRadius = 28;
    self.layer.masksToBounds = YES;
    self.userInteractionEnabled = YES;

    /* v24: 悬浮球用头像图片（圆形裁切） */
    UIImageView *icon = [[UIImageView alloc] initWithFrame:CGRectMake(0, 0, 56, 56)];
    UIImage *ballImg = TTSLoadBallImage();
    if (ballImg) {
        icon.image = ballImg;
        icon.contentMode = UIViewContentModeScaleAspectFill;
        icon.layer.cornerRadius = 28;
        icon.layer.masksToBounds = YES;
        icon.layer.borderWidth = 1.5;
        icon.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.9].CGColor;
    } else {
        TTLog(@"[ui] 悬浮球图片解码失败 len=%u", TTS_RES_BALL_LEN);
    }
    icon.userInteractionEnabled = NO;
    [self addSubview:icon];

    [self addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(togglePanel)]];
    [self addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(drag:)]];
    return self;
}

- (void)dragPanel:(UIPanGestureRecognizer *)g {
    static CGPoint start;
    if (g.state == UIGestureRecognizerStateBegan) start = self.panel.center;
    if (g.state == UIGestureRecognizerStateChanged) {
        CGPoint t = [g translationInView:self.panel.superview];
        self.panel.center = CGPointMake(start.x + t.x, start.y + t.y);
    }
}

- (void)drag:(UIPanGestureRecognizer *)g {
    static CGPoint start;
    if (g.state == UIGestureRecognizerStateBegan) start = self.center;
    if (g.state == UIGestureRecognizerStateChanged) {
        CGPoint t = [g translationInView:self.superview];
        self.center = CGPointMake(start.x + t.x, start.y + t.y);
    }
}

- (void)kbWillShow:(NSNotification *)n {
    CGRect kb = [n.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    CGRect f = self.panel.frame;
    CGFloat maxY = kb.origin.y - 8;
    if (CGRectGetMaxY(f) > maxY) { f.origin.y = MAX(40, maxY - f.size.height); self.panel.frame = f; }
}
- (void)kbWillHide:(NSNotification *)n {
    CGRect f = self.panel.frame;
    if (f.origin.y < 80) { f.origin.y = 80; self.panel.frame = f; }
}

- (void)togglePanel {
    if (self.panel) { [self.panel removeFromSuperview]; self.panel = nil; return; }

    CGFloat w = 300, h = 250;
    CGRect sc = UIScreen.mainScreen.bounds;
    UIView *panel = [[UIView alloc] initWithFrame:CGRectMake(MAX(10, CGRectGetMidX(sc) - w / 2), 80, w, h)];
    panel.backgroundColor = [UIColor colorWithWhite:0.98 alpha:0.99];
    panel.layer.cornerRadius = 18;
    panel.layer.masksToBounds = YES;
    self.panel = panel;

    /* 全屏拖动：面板任意位置可拖（输入框等子控件点击不受影响） */
    UIPanGestureRecognizer *ppan = [[UIPanGestureRecognizer alloc]
        initWithTarget:self action:@selector(dragPanel:)];
    [panel addGestureRecognizer:ppan];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(kbWillShow:) name:UIKeyboardWillShowNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(kbWillHide:) name:UIKeyboardWillHideNotification object:nil];

    /* v24: 左上角头像 */
    UIImageView *avatar = [[UIImageView alloc] initWithFrame:CGRectMake(12, 8, 34, 34)];
    UIImage *ballImg = TTSLoadBallImage();
    if (ballImg) {
        avatar.image = ballImg;
        avatar.contentMode = UIViewContentModeScaleAspectFill;
        avatar.layer.cornerRadius = 17;
        avatar.layer.masksToBounds = YES;
    }
    avatar.userInteractionEnabled = NO;
    [panel addSubview:avatar];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(52, 12, 140, 26)];
    title.text = @"文字转语音";
    title.textColor = UIColor.blackColor;
    title.font = [UIFont boldSystemFontOfSize:16];
    [panel addSubview:title];

    /* v24: 右上角 关闭（收起回悬浮球） + 打赏（弹二维码） */
    UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    closeBtn.frame = CGRectMake(262, 8, 30, 30);
    [closeBtn setTitle:@"✕" forState:UIControlStateNormal];
    [closeBtn setTitleColor:[UIColor colorWithWhite:0.35 alpha:1] forState:UIControlStateNormal];
    closeBtn.titleLabel.font = [UIFont boldSystemFontOfSize:19];
    closeBtn.layer.cornerRadius = 15;
    closeBtn.backgroundColor = [UIColor colorWithWhite:0.90 alpha:1];
    [closeBtn addTarget:self action:@selector(closePanel) forControlEvents:UIControlEventTouchUpInside];
    [panel addSubview:closeBtn];

    UIButton *tipBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    tipBtn.frame = CGRectMake(200, 8, 56, 30);
    [tipBtn setTitle:@"打赏" forState:UIControlStateNormal];
    [tipBtn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    tipBtn.titleLabel.font = [UIFont boldSystemFontOfSize:13];
    tipBtn.layer.cornerRadius = 15;
    tipBtn.backgroundColor = [UIColor colorWithRed:0.85 green:0.65 blue:0.13 alpha:1];
    [tipBtn addTarget:self action:@selector(showTip) forControlEvents:UIControlEventTouchUpInside];
    [panel addSubview:tipBtn];

    /* v25: 音色行（458 个音色，左右箭头已删 → 整行点开带搜索的列表） */
    UILabel *vt = [[UILabel alloc] initWithFrame:CGRectMake(16, 47, 40, 26)];
    vt.text = @"音色";
    vt.textColor = UIColor.blackColor;
    vt.font = [UIFont systemFontOfSize:15];
    [panel addSubview:vt];

    self.voiceLabel = [[UILabel alloc] initWithFrame:CGRectMake(58, 43, 200, 34)];
    self.voiceLabel.text = @"音色列表加载中…";
    self.voiceLabel.textColor = UIColor.blackColor;
    self.voiceLabel.textAlignment = NSTextAlignmentLeft;
    self.voiceLabel.font = [UIFont boldSystemFontOfSize:14];
    self.voiceLabel.userInteractionEnabled = YES;
    UITapGestureRecognizer *vTap = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(showVoiceList)];
    [self.voiceLabel addGestureRecognizer:vTap];
    [panel addSubview:self.voiceLabel];

    UILabel *vHint = [[UILabel alloc] initWithFrame:CGRectMake(258, 43, 30, 34)];
    vHint.text = @"▾";
    vHint.textColor = [UIColor colorWithWhite:0.45 alpha:1];
    vHint.textAlignment = NSTextAlignmentCenter;
    vHint.font = [UIFont systemFontOfSize:14];
    [panel addSubview:vHint];

    /* v1 QQ: 面板状态 = 捕捉就绪状态 */
    id h = nil;
    @synchronized([NSObject class]) { h = g_qqSenderHandler; }
    if (h) {
        self.statusLabel.text = @"就绪：输入文字点合成（发到当前会话）";
    } else {
        self.statusLabel.text = @"先在QQ发一条文字消息完成捕捉";
    }

    /* 音色异步加载完成后刷新标题（v30: 千问后端直接显示，不等原接口） */
    if (g_backend == 1) {
        self.voiceLabel.text = [NSString stringWithFormat:@"[千问] %@ %.2fx%@",
            g_qwenVoice, g_qwenRate, g_qwenInstr.length ? [NSString stringWithFormat:@" ·%@", g_qwenInstr] : @""];
    } else if (g_voices.count) {
        self.voiceLabel.text = TTSCurVoice();
    } else {
        self.voiceLabel.text = [NSString stringWithFormat:@"[千问备选] %@（原接口加载中…）", g_qwenVoice];
        __weak typeof(self) ws = self;
        TTSFetchVoices(^(BOOL ok, NSUInteger n) {
            dispatch_async(dispatch_get_main_queue(), ^{
                typeof(self) ss = ws; if (!ss) return;
                ss.voiceLabel.text = ok ? TTSCurVoice() : @"音色加载失败（点这里重试）";
            });
        });
    }

    self.input = [[UITextView alloc] initWithFrame:CGRectMake(12, 82, 276, 92)];
    self.input.backgroundColor = [UIColor colorWithWhite:0.92 alpha:1];
    self.input.textColor = UIColor.blackColor;
    self.input.font = [UIFont systemFontOfSize:15];
    self.input.layer.cornerRadius = 10;
    [panel addSubview:self.input];

    self.send = [UIButton buttonWithType:UIButtonTypeSystem];
    self.send.frame = CGRectMake(12, 181, 276, 40);
    self.send.backgroundColor = [UIColor colorWithRed:.12 green:.57 blue:.96 alpha:1];
    self.send.layer.cornerRadius = 9;
    [self.send setTitle:@"1️⃣ 合成语音" forState:UIControlStateNormal];
    [self.send setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    self.send.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    [self.send addTarget:self action:@selector(sendDirect) forControlEvents:UIControlEventTouchUpInside];
    [panel addSubview:self.send];

    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(12, 222, 276, 20)];
    self.statusLabel.text = @"输入文字后点合成";
    self.statusLabel.textColor = [UIColor colorWithWhite:0.25 alpha:1];
    self.statusLabel.font = [UIFont systemFontOfSize:11];
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    [panel addSubview:self.statusLabel];

    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.spinner.center = CGPointMake(282, 202);
    [panel addSubview:self.spinner];

    [self.superview addSubview:panel];
    [self.input becomeFirstResponder];
}

/* 音色列表弹层（点击音色名弹出，点击行选择） */
/* ==================== v24: 关闭 / 打赏 ==================== */
- (void)closePanel {
    [self.input resignFirstResponder];
    [self closeTip];
    if (self.panel) { [self.panel removeFromSuperview]; self.panel = nil; }
    TTLog(@"[ui] panel closed");
}

- (void)showTip {
    if (self.tipMask) return;
    CGRect sc = UIScreen.mainScreen.bounds;
    UIView *mask = [[UIView alloc] initWithFrame:sc];
    mask.tag = 9601;
    mask.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
    self.tipMask = mask;

    /* 赞赏码原图 1024×1036（自带"多谢老板打赏！"+ 底部金色署名条）→ 只做等比缩放，不裁切 */
    CGFloat cw = MIN(320, sc.size.width - 40);
    CGFloat iw = cw - 16;
    CGFloat ih = iw * 1036.0 / 1024.0;
    CGFloat ch = 8 + ih + 34;
    UIView *card = [[UIView alloc] initWithFrame:
        CGRectMake((sc.size.width - cw) / 2, (sc.size.height - ch) / 2, cw, ch)];
    card.tag = 9602;
    card.backgroundColor = UIColor.whiteColor;
    card.layer.cornerRadius = 16;
    card.layer.masksToBounds = YES;
    [mask addSubview:card];

    UIImageView *qr = [[UIImageView alloc] initWithFrame:CGRectMake(8, 8, iw, ih)];
    UIImage *qrImg = [UIImage imageWithData:[NSData dataWithBytes:TTS_RES_TIP length:TTS_RES_TIP_LEN]];
    if (qrImg) {
        qr.image = qrImg;
        qr.contentMode = UIViewContentModeScaleAspectFit;
    } else {
        TTLog(@"[ui] 二维码解码失败 len=%u", TTS_RES_TIP_LEN);
    }
    qr.userInteractionEnabled = NO;
    [card addSubview:qr];

    UILabel *sub = [[UILabel alloc] initWithFrame:CGRectMake(0, 8 + ih + 4, cw, 20)];
    sub.text = @"微信内长按识别 · 赞赏码";
    sub.textAlignment = NSTextAlignmentCenter;
    sub.textColor = [UIColor colorWithWhite:0.45 alpha:1];
    sub.font = [UIFont systemFontOfSize:12];
    [card addSubview:sub];

    UIButton *closeB = [UIButton buttonWithType:UIButtonTypeSystem];
    closeB.frame = CGRectMake(cw - 44, 4, 38, 32);
    [closeB setTitle:@"✕" forState:UIControlStateNormal];
    [closeB setTitleColor:[UIColor colorWithWhite:0.4 alpha:1] forState:UIControlStateNormal];
    closeB.titleLabel.font = [UIFont boldSystemFontOfSize:19];
    [closeB addTarget:self action:@selector(closeTip) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:closeB];

    /* 点卡片外任意处关闭（卡片内不关闭） */
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(tipMaskTapped:)];
    [mask addGestureRecognizer:tap];

    [self.superview addSubview:mask];
    TTLog(@"[ui] tip shown (%u bytes qr)", TTS_RES_TIP_LEN);
}

- (void)closeTip {
    if (self.tipMask) { [self.tipMask removeFromSuperview]; self.tipMask = nil; }
}

- (void)tipMaskTapped:(UITapGestureRecognizer *)g {
    UIView *card = [self.tipMask viewWithTag:9602];
    CGPoint loc = [g locationInView:card];
    if (card && !CGRectContainsPoint(card.bounds, loc)) [self closeTip];
}

/* ==================== v25: 音色选择列表（可搜索，458 个） ==================== */
- (void)showVoiceList {
    [self closeVoiceList];

    CGRect scr = UIScreen.mainScreen.bounds;
    UIView *mask = [[UIView alloc] initWithFrame:scr];
    mask.tag = 9527;
    mask.backgroundColor = [UIColor colorWithWhite:0 alpha:0.4];

    CGFloat lw = MIN(320, scr.size.width - 32);
    CGFloat lh = scr.size.height * 0.66;
    UIView *listPanel = [[UIView alloc] initWithFrame:CGRectMake((scr.size.width-lw)/2, (scr.size.height-lh)/2, lw, lh)];
    listPanel.backgroundColor = UIColor.whiteColor;
    listPanel.layer.cornerRadius = 14;
    listPanel.tag = 9528;
    [mask addSubview:listPanel];

    UILabel *lt = [[UILabel alloc] initWithFrame:CGRectMake(12, 8, lw-100, 28)];
    NSUInteger n = g_voices.count;
    NSString *title;
    if (g_backend == 1) {
        title = [NSString stringWithFormat:@"选择音色（千问48 + 原%lu）", (unsigned long)n];
    } else {
        title = n ? [NSString stringWithFormat:@"选择音色（千问48 + 原%lu）", (unsigned long)n]
                  : (g_voiceFetchState < 0 ? @"原接口加载失败，千问可用" : @"选择音色（千问48 + 原加载中…）");
    }
    lt.text = title;
    lt.tag = 9531;
    lt.textColor = UIColor.blackColor;
    lt.font = [UIFont boldSystemFontOfSize:15];
    [listPanel addSubview:lt];

    UIButton *reloadB = [UIButton buttonWithType:UIButtonTypeSystem];
    reloadB.frame = CGRectMake(lw-84, 6, 76, 30);
    [reloadB setTitle:@"重新加载" forState:UIControlStateNormal];
    [reloadB setTitleColor:[UIColor colorWithRed:.12 green:.57 blue:.96 alpha:1] forState:UIControlStateNormal];
    reloadB.titleLabel.font = [UIFont systemFontOfSize:13];
    [reloadB addTarget:self action:@selector(reloadVoices) forControlEvents:UIControlEventTouchUpInside];
    [listPanel addSubview:reloadB];

    /* 搜索框：千问+原接口合搜 */
    UISearchBar *sb = [[UISearchBar alloc] initWithFrame:CGRectMake(0, 38, lw, 44)];
    sb.placeholder = @"搜索音色（中文名/ID，如 Cherry、御姐）";
    sb.delegate = (id<UISearchBarDelegate>)self;
    sb.tag = 9530;
    [listPanel addSubview:sb];
    self.searchField = sb;

    /* ===== v30.1: 千问设置区（语速滑杆 + 情绪标签条——点选模式，自动下发指令） ===== */
    UIView *qwSet = [[UIView alloc] initWithFrame:CGRectMake(0, 84, lw, 88)];
    qwSet.tag = 9540;
    qwSet.backgroundColor = [UIColor colorWithRed:0.95 green:0.97 blue:1.0 alpha:1];
    [listPanel addSubview:qwSet];

    UILabel *rateL = [[UILabel alloc] initWithFrame:CGRectMake(12, 4, 32, 18)];
    rateL.text = @"语速";
    rateL.font = [UIFont boldSystemFontOfSize:12];
    rateL.textColor = [UIColor colorWithRed:0.1 green:0.3 blue:0.7 alpha:1];
    [qwSet addSubview:rateL];

    UILabel *rateV = [[UILabel alloc] initWithFrame:CGRectMake(lw-60, 4, 48, 18)];
    rateV.text = [NSString stringWithFormat:@"%.2fx", g_qwenRate];
    rateV.font = [UIFont boldSystemFontOfSize:12];
    rateV.textColor = [UIColor colorWithRed:0.1 green:0.3 blue:0.7 alpha:1];
    rateV.tag = 9541;
    [qwSet addSubview:rateV];

    UISlider *slider = [[UISlider alloc] initWithFrame:CGRectMake(44, 2, lw-110, 22)];
    slider.minimumValue = 0.5f;
    slider.maximumValue = 2.0f;
    slider.value = g_qwenRate;
    slider.tag = 9542;
    [slider addTarget:self action:@selector(qwRateChanged:) forControlEvents:UIControlEventValueChanged];
    [qwSet addSubview:slider];

    /* 语气：情绪标签条（点选循环 高亮），不再手输 */
    UILabel *instrL = [[UILabel alloc] initWithFrame:CGRectMake(12, 32, 32, 18)];
    instrL.text = @"语气";
    instrL.font = [UIFont boldSystemFontOfSize:12];
    instrL.textColor = [UIColor colorWithRed:0.1 green:0.3 blue:0.7 alpha:1];
    [qwSet addSubview:instrL];

    /* v30.1: 情绪标签条（数据源=全局 g_qwEmoNames，点选即下发指令） */
    UIScrollView *emoScroll = [[UIScrollView alloc] initWithFrame:CGRectMake(44, 28, lw-56, 30)];
    emoScroll.showsHorizontalScrollIndicator = NO;
    emoScroll.tag = 9545;
    CGFloat ex = 0;
    for (NSUInteger ei = 0; ei < QW_EMO_COUNT; ei++) {
        NSString *en = g_qwEmoNames[ei];
        UIButton *eb = [UIButton buttonWithType:UIButtonTypeSystem];
        eb.frame = CGRectMake(ex, 2, MAX(44, en.length * 16 + 20), 26);
        [eb setTitle:en forState:UIControlStateNormal];
        eb.titleLabel.font = [UIFont systemFontOfSize:12];
        eb.layer.cornerRadius = 13;
        eb.tag = 9600 + (int)ei;   /* 9600+idx → qwEmoTapped 逆映射 */
        [eb addTarget:self action:@selector(qwEmoTapped:) forControlEvents:UIControlEventTouchUpInside];
        /* 高亮当前选中（g_qwenInstr 显示名匹配） */
        BOOL cur = [g_qwenInstr isEqualToString:[self qwEmoDisplayForIdx:ei]];
        eb.backgroundColor = cur ? [UIColor colorWithRed:0.12 green:0.45 blue:0.95 alpha:1] : UIColor.whiteColor;
        [eb setTitleColor:cur ? UIColor.whiteColor : [UIColor colorWithWhite:0.25 alpha:1] forState:UIControlStateNormal];
        [emoScroll addSubview:eb];
        ex += MAX(44, en.length * 16 + 20) + 8;
    }
    emoScroll.contentSize = CGSizeMake(ex, 30);
    [qwSet addSubview:emoScroll];

    UILabel *hintL = [[UILabel alloc] initWithFrame:CGRectMake(12, 62, lw-24, 22)];
    hintL.text = @"语速/语气只对千问音色（第一段）生效";
    hintL.font = [UIFont systemFontOfSize:10];
    hintL.textColor = [UIColor colorWithWhite:0.5 alpha:1];
    [qwSet addSubview:hintL];

    UITableView *tv = [[UITableView alloc] initWithFrame:CGRectMake(0, 84 + 88, lw, lh-84-88)
                                                   style:UITableViewStylePlain];
    tv.tag = 9529;
    tv.dataSource = (id<UITableViewDataSource>)self;
    tv.delegate = (id<UITableViewDelegate>)self;
    tv.rowHeight = 42;
    [listPanel addSubview:tv];
    self.voiceTable = tv;

    g_voiceFilter = nil;   /* 每次打开重置过滤 */
    [tv reloadData];

    /* 遮罩只在点面板外时关闭；面板内触摸交给表格/搜索框 */
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(maskTapped:)];
    tap.delegate = (id<UIGestureRecognizerDelegate>)self;
    [mask addGestureRecognizer:tap];
    objc_setAssociatedObject(mask, "maskPanel", listPanel, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    if (!g_voices.count) TTSInitVoicesIfNeeded();

    UIWindow *w = nil;
    for (UIWindow *win in UIApplication.sharedApplication.windows) {
        if (win.isKeyWindow) { w = win; break; }
    }
    if (!w) w = UIApplication.sharedApplication.windows.firstObject;
    [w addSubview:mask];
    TTLog(@"[voice-list] shown (%lu voices)", (unsigned long)g_voices.count);
}

- (void)reloadVoices {
    TTLog(@"[voice-list] 手动重新加载音色");
    __weak typeof(self) ws = self;
    TTSFetchVoices(^(BOOL ok, NSUInteger n) {
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) ss = ws;
            UITableView *tv = ss.voiceTable;
            [tv reloadData];
            UIView *p = ss.searchField ? [ss.searchField superview] : nil;
            if (p) {
                UILabel *h = nil;
                for (UIView *v in p.subviews) {
                    if (v.tag == 9531 && [v isKindOfClass:[UILabel class]]) { h = (UILabel *)v; break; }
                }
                if (h) h.text = ok ? [NSString stringWithFormat:@"选择音色（千问48 + 原%lu）", (unsigned long)n]
                                   : @"原接口加载失败（千问可用）";
            }
            ss.voiceLabel.text = ok ? TTSCurVoice() : @"音色加载失败（点这里重试）";
        });
    });
}

/* ===== v30.1: 千问语速滑杆 + 情绪标签 ===== */
/* 显示名 → instruction 指令文本（千问 instruct 模型自然语言指令） */
static NSString *qwEmoInstruction(NSString *display) {
    if (display.length == 0 || [display isEqualToString:@"默认"]) return nil;
    NSDictionary *map = @{
        @"生气": @"用生气的语气说话，语调强硬，带着明显的不满",
        @"愤怒": @"用愤怒的语气大喊，情绪激烈，充满怒火",
        @"快乐": @"用快乐的语气说话，声音明亮上扬，充满感染力",
        @"开心": @"用开心的语气说话，轻快活泼，带着笑意",
        @"兴奋": @"用兴奋激动的语气说话，语速偏快，情绪高涨",
        @"悲伤": @"用悲伤低沉的语气说话，声音低落，充满哀伤",
        @"难过": @"用难过的语气说话，声音低沉，透着沮丧",
        @"恐惧": @"用恐惧颤抖的语气说话，声音发紧，充满害怕",
        @"害怕": @"用害怕的语气轻声说话，声音发抖，小心翼翼",
        @"惊讶": @"用惊讶的语气说话，声音突然拔高，充满震惊",
        @"温柔": @"用温柔的语气轻声说话，柔和缓慢，让人安心",
        @"严肃": @"用严肃的语气说话，字正腔圆，不苟言笑",
        @"沉稳": @"用沉稳的语气说话，声音厚实，镇定从容",
        @"激动": @"用激动澎湃的语气说话，情绪饱满，声音有力",
        @"委屈": @"用委屈的语气说话，声音发哽，带着哭腔",
        @"撒娇": @"用撒娇的语气说话，拖长音调，软糯可爱",
        @"嘲讽": @"用嘲讽轻蔑的语气说话，阴阳怪气，带着讥笑",
        @"耳语": @"用耳语的方式轻声说话，气声为主，仿佛在耳边低语",
        @"大喊": @"用大声呼喊的方式说话，音量全开，声嘶力竭",
    };
    return map[display];
}
- (NSString *)qwEmoDisplayForIdx:(NSUInteger)idx {
    return (idx < QW_EMO_COUNT) ? g_qwEmoNames[idx] : @"";
}
- (void)qwRateChanged:(UISlider *)s {
    float v = s.value;
    /* 步进 0.25 显示更稳定 */
    v = roundf(v * 4.0f) / 4.0f;
    s.value = v;
    QwenSaveRate(v);
    UIView *p = [s superview];
    if (p) {
        UILabel *rv = nil;
        for (UIView *v2 in p.subviews) {
            if (v2.tag == 9541 && [v2 isKindOfClass:[UILabel class]]) { rv = (UILabel *)v2; break; }
        }
        if (rv) rv.text = [NSString stringWithFormat:@"%.2fx", v];
    }
    TTLog(@"[qwen] rate=%.2f", v);
}
- (void)qwEmoTapped:(UIButton *)b {
    NSUInteger idx = (NSUInteger)(b.tag - 9600);
    if (idx >= QW_EMO_COUNT) return;
    NSString *display = g_qwEmoNames[idx];
    NSString *instr = qwEmoInstruction(display);
    QwenSaveInstr(instr ?: display);   /* 持久化存显示名（回显用），下发时转换 */
    /* 全标签刷新高亮 */
    UIView *p = [b superview];
    if (p) {
        for (UIView *v2 in p.subviews) {
            if (v2.tag >= 9600 && [v2 isKindOfClass:[UIButton class]]) {
                UIButton *eb = (UIButton *)v2;
                NSUInteger i = (NSUInteger)(eb.tag - 9600);
                BOOL cur = (i == idx);
                eb.backgroundColor = cur ? [UIColor colorWithRed:0.12 green:0.45 blue:0.95 alpha:1] : UIColor.whiteColor;
                [eb setTitleColor:cur ? UIColor.whiteColor : [UIColor colorWithWhite:0.25 alpha:1] forState:UIControlStateNormal];
            }
        }
    }
    TTLog(@"[qwen] emo=%@ instr=%@", display, instr ?: @"(默认)");
}

- (void)closeVoiceList {
    for (UIWindow *w in UIApplication.sharedApplication.windows) {
        for (UIView *sub in w.subviews) {
            if (sub.tag == 9527) [sub removeFromSuperview];
        }
    }
}

/* v21-fix: 只有关闭按钮/遮罩空白区才关列表；点列表面板内部不关 */
- (void)maskTapped:(UITapGestureRecognizer *)g {
    UIView *mask = g.view;
    UIView *listPanel = objc_getAssociatedObject(mask, "maskPanel");
    CGPoint loc = [g locationInView:listPanel];
    BOOL inside = CGRectContainsPoint(listPanel.bounds, loc);
    if (!inside) [self closeVoiceList];
}

/* v21-fix: 遮罩 tap 与表格行点击共存——触摸点在列表面板内时放弃识别 */
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gr shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    return YES;
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gr shouldBeRequireFailureOfGestureRecognizer:(UIGestureRecognizer *)other {
    return NO;
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gr shouldReceiveTouch:(UITouch *)touch {
    /* 触摸落在列表面板内 → 不接收，让表格自己处理 didSelectRowAtIndexPath */
    UIView *mask = gr.view;
    UIView *listPanel = objc_getAssociatedObject(mask, "maskPanel");
    if (!listPanel) return YES;
    CGPoint loc = [touch locationInView:listPanel];
    return !CGRectContainsPoint(listPanel.bounds, loc);
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return g_voiceFilter ? 1 : 2;   /* v30: 搜索时单段；平时 千问段 + 原接口段 */
}
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    if (g_voiceFilter) {
        if (s != 0) return 0;
        return (NSInteger)g_voiceFilter.count;
    }
    if (s == 0) return (NSInteger)QW_VOICE_COUNT;          /* 千问 48 */
    return (NSInteger)(g_voices ?: @[]).count;             /* 原接口（可能还在加载） */
}
- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    if (g_voiceFilter) return nil;
    if (s == 0) return @"千问（48 音色 · 支持语气/语速）";
    return [NSString stringWithFormat:@"原接口（%lu 音色）", (unsigned long)(g_voices ?: @[]).count];
}
/* v30: 显示名是否千问（"ID·中文名" 形态，按 ID 前缀判定） */
- (BOOL)qwIsQwenDisplay:(NSString *)name {
    if (!name.length) return NO;
    for (NSUInteger i = 0; i < QW_VOICE_COUNT; i++) {
        if ([name hasPrefix:g_qwenVoices[i][0]]) return YES;
    }
    return NO;
}
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *cid = @"VC";
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:cid];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:cid];
    NSString *name = nil;
    BOOL isQwen = NO;
    NSUInteger qwIdx = 0;
    if (g_voiceFilter) {
        if (ip.row >= (NSInteger)g_voiceFilter.count) { cell.textLabel.text = @""; return cell; }
        name = g_voiceFilter[ip.row];
        isQwen = [self qwIsQwenDisplay:name];
        if (isQwen) for (NSUInteger i = 0; i < QW_VOICE_COUNT; i++) if ([name hasPrefix:g_qwenVoices[i][0]]) { qwIdx = i; break; }
    } else if (ip.section == 0) {
        if (ip.row >= (NSInteger)QW_VOICE_COUNT) { cell.textLabel.text = @""; return cell; }
        qwIdx = (NSUInteger)ip.row;
        name = [NSString stringWithFormat:@"%@·%@", g_qwenVoices[qwIdx][0], g_qwenVoices[qwIdx][1]];
        isQwen = YES;
    } else {
        NSArray *l = g_voices ?: @[];
        if (ip.row >= (NSInteger)l.count) { cell.textLabel.text = @""; return cell; }
        name = l[ip.row];
        isQwen = NO;
    }
    cell.textLabel.text = name;
    cell.textLabel.font = [UIFont systemFontOfSize:14];
    cell.textLabel.textColor = UIColor.blackColor;
    BOOL selected;
    if (isQwen) selected = (g_backend == 1 && [g_qwenVoices[qwIdx][0] isEqualToString:g_qwenVoice]);
    else         selected = (g_backend == 0 && [name isEqualToString:TTSCurVoice()]);
    cell.accessoryType = selected ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    cell.backgroundColor = UIColor.whiteColor;
    return cell;
}
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    NSString *name = nil;
    BOOL isQwen = NO;
    NSUInteger qwIdx = 0;
    if (g_voiceFilter) {
        if (ip.row >= (NSInteger)g_voiceFilter.count) return;
        name = g_voiceFilter[ip.row];
        isQwen = [self qwIsQwenDisplay:name];
        if (isQwen) for (NSUInteger i = 0; i < QW_VOICE_COUNT; i++) if ([name hasPrefix:g_qwenVoices[i][0]]) { qwIdx = i; break; }
    } else if (ip.section == 0) {
        if (ip.row >= (NSInteger)QW_VOICE_COUNT) return;
        qwIdx = (NSUInteger)ip.row;
        name = [NSString stringWithFormat:@"%@·%@", g_qwenVoices[qwIdx][0], g_qwenVoices[qwIdx][1]];
        isQwen = YES;
    } else {
        NSArray *l = g_voices ?: @[];
        if (ip.row >= (NSInteger)l.count) return;
        name = l[ip.row];
        isQwen = NO;
    }
    if (isQwen) {
        QwenSaveBackend(1);
        QwenSaveVoice(g_qwenVoices[qwIdx][0]);
        TTSSetVoice(name);   /* 显示名同步，跨后端回切保持 */
        self.voiceLabel.text = name;
        [self closeVoiceList];
        [self setStatusOnMain:[NSString stringWithFormat:@"千问音色：%@（语速%.2f）", g_qwenVoices[qwIdx][0], g_qwenRate]];
        TTLog(@"[voice-list] qwen selected %@ rate=%.2f", g_qwenVoices[qwIdx][0], g_qwenRate);
    } else {
        QwenSaveBackend(0);
        TTSSetVoice(name);
        self.voiceLabel.text = name;
        [self closeVoiceList];
        [self setStatusOnMain:[NSString stringWithFormat:@"原接口音色：%@", name]];
        TTLog(@"[voice-list] legacy selected %@", name);
    }
}

/* v30: 搜索过滤（千问+原接口合搜） */
- (void)searchBar:(UISearchBar *)sb textDidChange:(NSString *)text {
    NSString *q = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (q.length == 0) {
        g_voiceFilter = nil;
    } else {
        NSMutableArray *r = [NSMutableArray array];
        for (NSUInteger i = 0; i < QW_VOICE_COUNT; i++) {
            NSString *dn = [NSString stringWithFormat:@"%@·%@", g_qwenVoices[i][0], g_qwenVoices[i][1]];
            if ([dn rangeOfString:q options:NSCaseInsensitiveSearch].location != NSNotFound) [r addObject:dn];
        }
        for (NSString *n in (g_voices ?: @[])) {
            if ([n rangeOfString:q options:NSCaseInsensitiveSearch].location != NSNotFound) [r addObject:n];
        }
        g_voiceFilter = r;
    }
    [self.voiceTable reloadData];
}
- (void)searchBarSearchButtonClicked:(UISearchBar *)sb { [sb resignFirstResponder]; }


- (void)setStatusOnMain:(NSString *)s {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.send.enabled = YES;
        [self.spinner stopAnimating];
        self.statusLabel.text = s;
    });
}

/* 面板直接发送（v15）：TTS → PCM → silk(自编码) → v13c 发送链 */
- (void)sendDirect {
    NSString *text = self.input.text;
    if (!text.length) { self.statusLabel.text = @"请输入文字"; return; }

    id handler = nil;
    NSDictionary *msgAttrs = nil;
    @synchronized([NSObject class]) {
        handler = g_qqSenderHandler;
        msgAttrs = g_qqLastMsgAttrs;
    }
    if (!handler) {
        /* v1 兜底: hook 未捕获(用户还没发过消息) → 主动创建 MsgSenderHandler 实例 */
        Class h = NSClassFromString(@"_TtC10MsgManager16MsgSenderHandler");
        if (h) {
            @try {
                id fresh = [[h alloc] init];
                if (fresh) { @synchronized([NSObject class]) { g_qqSenderHandler = fresh; } handler = fresh;
                    TTLog(@"[qq] MsgSenderHandler 现场创建 %p", (__bridge void *)fresh); }
            } @catch (NSException *e) { TTLog(@"[qq] handler 创建失败 %@", e); }
        }
    }
    if (!handler) { self.statusLabel.text = @"发送器未就绪(先发条文字消息捕捉)"; return; }

    [self.input resignFirstResponder];
    self.send.enabled = NO;
    self.statusLabel.text = @"合成中…";
    [self.spinner startAnimating];
    NSString *voice = TTSCurVoice();
    TTLog(@"[tts] backend=%ld v=%@ qq-chain", (long)g_backend, voice);

    void (^onAudio)(NSData *, NSError *) = ^(NSData *audio, NSError *error) {
        if (error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self.send.enabled = YES; [self.spinner stopAnimating];
                self.statusLabel.text = [NSString stringWithFormat:@"失败：%@", error.localizedDescription];
            });
            return;
        }
        /* ===== QQ 链: WAV(audio) → PCM 文件(silk编码) → NTAIOAudioModel → sendPttMsg ===== */
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSData *pcm = DecodeToPCM(audio);
            if (!pcm) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    self.send.enabled = YES; [self.spinner stopAnimating];
                    self.statusLabel.text = @"PCM解码失败";
                });
                return;
            }
            NSUInteger ms = pcm.length * 1000 / (NSUInteger)(g_targetSampleRate * 2);
            TTLog(@"[qq] PCM %luB ≈ %lums — silk编码", (unsigned long)pcm.length, (unsigned long)ms);

            /* silk 编码: QQSilkRecorder PCM→silk 文件（openPcmFile/openSilkFile 属主是实例ivars）
             * ⚠️ 若 openPcmFile: 不吃 NSData→需换 AVAudioFile 写 wav 再走 silk。v1 先试 QQSilkCodec 直接 encode */
            NSString *silkPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
                [NSString stringWithFormat:@"qq_tts_%@.slk", NSUUID.UUID.UUIDString]];
            NSData *silkData = QQSilkEncode(pcm, (uint32_t)g_targetSampleRate);
            if (!silkData) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    self.send.enabled = YES; [self.spinner stopAnimating];
                    self.statusLabel.text = @"silk编码失败";
                });
                return;
            }
            if (![silkData writeToFile:silkPath atomically:YES]) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    self.send.enabled = YES; [self.spinner stopAnimating];
                    self.statusLabel.text = @"silk文件写入失败";
                });
                return;
            }
            TTLog(@"[qq] silk %luB → %@", (unsigned long)silkData.length, silkPath.lastPathComponent);

            /* NTAIOAudioModel: audioType/audioFilePath (+placeholderMsgType/isAIVoice)
             * KVC 写入(Swift类ivar可KVC) */
            Class mCls = NSClassFromString(@"_TtC10MsgManager15NTAIOAudioModel");
            if (!mCls) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    self.send.enabled = YES; [self.spinner stopAnimating];
                    self.statusLabel.text = @"NTAIOAudioModel 类不存在";
                });
                return;
            }
            id audioModel = nil;
            @try {
                audioModel = [[mCls alloc] init];
                [audioModel setValue:silkPath forKey:@"audioFilePath"];
                [audioModel setValue:@(1) forKey:@"audioType"];   /* ⚠️ audioType 枚举值待真机dump修正 */
                [audioModel setValue:@(0) forKey:@"isAIVoice"];
                [audioModel setValue:@(ms) forKey:@"placeholderMsgType"];  /* ⚠️ 字段含义待验证 */
            } @catch (NSException *e) {
                TTLog(@"[qq] AudioModel 构造异常 %@", e);
                dispatch_async(dispatch_get_main_queue(), ^{
                    self.send.enabled = YES; [self.spinner stopAnimating];
                    self.statusLabel.text = @"AudioModel构造失败";
                });
                return;
            }
            if (!audioModel) { self.statusLabel.text = @"AudioModel空"; self.send.enabled = YES; return; }

            /* 发送: sendPttMsgWithAudioModel:placeholderMsgInfo:msgAttributeInfos:
             *       saveDataToKernelResultBlock:sendMsgResultBlock: (v56 五参) */
            SEL sendSel = NSSelectorFromString(@"sendPttMsgWithAudioModel:placeholderMsgInfo:msgAttributeInfos:saveDataToKernelResultBlock:sendMsgResultBlock:");
            if (![handler respondsToSelector:sendSel]) {
                TTLog(@"[qq] sendPttMsg sel MISS");
                dispatch_async(dispatch_get_main_queue(), ^{
                    self.send.enabled = YES; [self.spinner stopAnimating];
                    self.statusLabel.text = @"sendPttMsg 不存在";
                });
                return;
            }
            __weak typeof(self) ws = self;
            void (^saveBlk)(BOOL) = ^(BOOL ok) { TTLog(@"[qq] kernelSave=%d", ok); };
            void (^sendBlk)(int, NSString *) = ^(int code, NSString *err) {
                TTLog(@"[qq] sendResult code=%d err=%@", code, err);
                dispatch_async(dispatch_get_main_queue(), ^{
                    typeof(self) ss = ws;
                    if (!ss) return;
                    ss.send.enabled = YES; [ss.spinner stopAnimating];
                    if (code == 0) { ss.statusLabel.text = @"✅ 已发送"; ss.input.text = @""; }
                    else ss.statusLabel.text = [NSString stringWithFormat:@"发送失败 code=%d", code];
                });
            };
            @try {
                ((void (*)(id, SEL, id, id, id, void (^)(BOOL), void (^)(int, NSString *)))objc_msgSend)
                    (handler, sendSel, audioModel, nil, msgAttrs ?: @{}, saveBlk, sendBlk);
                TTLog(@"[qq] sendPttMsg 已调用");
            } @catch (NSException *e) {
                TTLog(@"[qq] sendPttMsg 异常 %@", e);
                dispatch_async(dispatch_get_main_queue(), ^{
                    self.send.enabled = YES; [self.spinner stopAnimating];
                    self.statusLabel.text = @"发送异常(看日志)";
                });
                return;
            }
        });
    };

    if (g_backend == 1) {
        RequestQwenTTS(text, g_qwenVoice, g_qwenRate, qwEmoInstruction(g_qwenInstr), onAudio);
    } else {
        RequestTTS(text, voice, onAudio);
    }
}


/* ==================== v1 QQ 捕捉 hook（sendTextMsgWithText:） ====================
 * 用户发一条文字消息 → 捕获 MsgSenderHandler 实例（self 即发送器）+ msgAttributeInfos。
 * method_exchangeImplementations 安全形态（无参签名变换）。 */
__attribute__((constructor))
static void QQFloatV1Init(void) {
    g_logPath = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/QQFloat.log"];
    QwenLoadState();
    TTLog(@"QQFloat v1 init (千问双后端 + sendPttMsg 链)");

    Class h = NSClassFromString(@"_TtC10MsgManager16MsgSenderHandler");
    if (!h) { TTLog(@"[qq-init] MsgSenderHandler 类 MISS（QQ版本不对？）"); return; }
    SEL s = NSSelectorFromString(@"sendTextMsgWithText:msgAttributeInfos:sendMsgResultBlock:");
    Method m = class_getInstanceMethod(h, s);
    if (!m) { TTLog(@"[qq-init] sendTextMsg sel MISS（QQ版本不对？）"); return; }
    const char *types = method_getTypeEncoding(m);
    TTLog(@"[qq-init] hook sendTextMsg types=%s", types ? types : "?");
    static IMP orig = NULL;
    IMP newImp = imp_implementationWithBlock(^(id self, NSString *text, NSDictionary *attrs, void (^cb)(int, NSString*)) {
        @synchronized([NSObject class]) {
            if (g_qqSenderHandler != self) {
                g_qqSenderHandler = self;
                TTLog(@"[qq-cap] 捕获 handler=%p text=%@", (__bridge void *)self, text.length ? @"(文本)" : @"?");
            }
            if (attrs && [attrs isKindOfClass:[NSDictionary class]]) g_qqLastMsgAttrs = attrs;
        }
        if (orig) ((void (*)(id, SEL, NSString*, NSDictionary*, void (^)(int, NSString*)))orig)(self, @selector(sendTextMsgWithText:msgAttributeInfos:sendMsgResultBlock:), text, attrs, cb);
    });
    orig = method_setImplementation(m, newImp);
    TTLog(@"[qq-init] hook installed");
}

@end
