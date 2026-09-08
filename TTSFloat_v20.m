/*
 * TTSFloat_v14.m — 微信文字转语音插件（录音 Hook 方案）
 *
 * 核心思路（与之前所有版本的本质区别）：
 *   不再拼装微信内部调用，而是让微信的录音状态机完整真实运行，
 *   在 PCM 输出回调处把【麦克风数据】替换成【TTS 合成的 PCM】。
 *   松手后微信自己的 silk 编码 + CDN 上传 + 消息发送全部走真实流程。
 *
 * 流程：
 *   1. 悬浮球输入文字 → 点"发送" → TTS 合成 mp3 → 解码 16kHz mono PCM → 缓存待用
 *   2. 提示用户"按住说话"（面板状态文字指引）
 *   3. hook -[AudioSender(AudioRecorderDelegate) OnOutputPcmBuffer:UserData:]
 *      录音期间每帧回调时：用缓存 TTS PCM 的下一段替换麦克风 PCM（返回替换后的数据）
 *   4. 用户松手 → 微信真实流程完成发送（silk编码/上传/气泡全部真实）
 *
 * 安全设计：
 *   - hook 的是 delegate 回调（2对象参，v8b/v9 验证过的安全签名形态）
 *   - 按返回类型分派（types[0]）
 *   - 不调用任何未验证的微信内部方法
 *   - 全 try/catch 防崩
 *
 * 编译：
 *   xcrun -sdk iphoneos clang -arch arm64 -miphoneos-version-min=12.0 \
 *     -fobjc-arc -dynamiclib \
 *     -framework Foundation -framework UIKit -framework AVFoundation -framework CoreGraphics \
 *     -o TTSFloat_v14.dylib TTSFloat_v14.m
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include "fishhook.h"
#include "tts_res_ball.h"   /* 悬浮球/面板头像（CI 由 pm_res_ball2.jpg 生成） */
#include "tts_res_tip.h"    /* 打赏二维码（CI 由 pm_res_tip2.jpg 生成） */
#import <AudioToolbox/AudioToolbox.h>


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
#include <execinfo.h>
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
    (void)uc;
    char buf[256];
    int n = snprintf(buf, sizeof(buf), "\n[CRASH] sig=%d addr=%p\n",
                     sig, info ? info->si_addr : NULL);
    if (g_crashFd >= 0) write(g_crashFd, buf, (size_t)n);
    void *frames[48];
    int cnt = 0;
    @try { cnt = backtrace(frames, 48); } @catch(...) { cnt = 0; }
    if (g_crashFd >= 0) backtrace_symbols_fd(frames, cnt, g_crashFd);
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



/* ==================== TTS PCM 缓存（hook 替换数据源） ==================== */




static NSData *g_pendingPCM = nil;       /* TTS 合成的完整 PCM */
static NSUInteger g_pcmOffset = 0;       /* 已喂位置 */
static BOOL g_replaceActive = NO;        /* 替换开关 */
static BOOL g_pcmFedDone = NO;           /* TTS 数据已全部喂进管线（StopRecord 时机依据） */

/* ==================== v20: 录音启动参数捕获（面板直接发送的关键） ====================
 * StartRecordFrom:ToUser:UserInfo: 真实签名 B40@0:8@16@24@32（3个无类名对象参）。
 * 传 chatVC 崩（身份不对）。hook 它【只观察不修改】——用户按住说话一次，
 * 日志打出三个参数的真实类名+描述，就知道面板发送该传什么。单参观察 hook 安全。 */
static id g_lastFromParam = nil;
static id g_lastUserInfoParam = nil;

static void InstallStartRecordObserver(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class cls = NSClassFromString(TTSCls(0));
        if (!cls) return;
        SEL sel = NSSelectorFromString(TTCSel(8));
        Method m = class_getInstanceMethod(cls, sel);
        if (!m) { TTLog(@"[obs] start MISS"); return; }
        const char *types = method_getTypeEncoding(m);
        TTLog(@"[obs] start types=%s", types ? types : "?");
        IMP oldImp = method_getImplementation(m);
        IMP newImp = imp_implementationWithBlock(^BOOL(id self, id from, id toUser, id userInfo) {
            @autoreleasepool {
                TTLog(@"[obs] start: from=%@(%@) to=%@(%@) info=%@",
                      from ? NSStringFromClass([from class]) : @"nil",
                      from ? [from description] : @"-",
                      toUser ? NSStringFromClass([toUser class]) : @"nil",
                      toUser ? [toUser description] : @"-",
                      userInfo ? NSStringFromClass([userInfo class]) : @"nil");
                @synchronized([NSObject class]) {
                    g_lastFromParam = from;
                    g_lastUserInfoParam = userInfo;
                }
            }
            return ((BOOL (*)(id, SEL, id, id, id))oldImp)(self, sel, from, toUser, userInfo);
        });
        method_setImplementation(m, newImp);
        TTLog(@"[obs] installed");
    });
}

/* ==================== AudioQueue C 层替换（数据真正的源头） ==================== */

/* ==================== AudioQueue C 层替换（数据真正的源头） ==================== */
static AudioQueueInputCallback g_origAQNewInput_cb = NULL;  /* 微信的原始回调 */
static void *g_wechatUserData = NULL;

/* trampoline：微信回调前替换 buffer 内容（官方 AudioToolbox 类型） */
/* v22: 实时节奏喂数
 * v21 每次把整个 buffer 塞满 TTS 字节 → 一次回调吃掉 6144B(=192ms@16k) 的 TTS 内容。
 * 若 buffer 实际只代表 64ms（微信录音器 48kHz），喂数速度 = 3× 实时
 * → 录音会话总时长被压成 1/3 → 微信只录到 TTS 开头几帧就被 StopRecord 截断（转圈/半截语音）。
 * v22 按【实测采集速率】喂：buffer/回调间隔 = 录音器真实字节速率，
 * 每次只消耗 (速率 × 距上次回调毫秒) 对应的 16kHz TTS 字节，buffer 其余补零。
 * 这样录音器看到的是时长与内容完全自洽的 16kHz 流（末尾静音），
 * OnRecorderPart 才会像真实录音那样正常提交分片。 */
/* v23 喂数策略：整块填满（v19 已验证音质干净的写法）
 * ⚠️ v22 的"按实测速率节奏喂"被日志判死：微信每次回调给的 buffer 大小不固定
 * （实测 6144 / 7018 / 8000 / 2570），rate×dt 恒小于 buffer →
 * TTS 字节流和 buffer 流对不齐，缺口被补零 → 语音里每隔 250ms 插一段静音 = 杂音。
 * 实测证据（v22 日志）：buffer 累计 142736B(=4.46s) 而 TTS 只有 107498B(=3.36s)。
 * v23：每次把整块 buffer 用连续 TTS 字节填满（块内零间隙），耗尽后整块补零。
 * 采样率铁证：buffer=8000B(4000 样本) 间隔 250ms → 16kHz 16bit mono → 32000B/s，
 * 真实录音 buffer=6144B 间隔 192ms 同样 32000B/s。 */
static uint64_t g_aqLastNs = 0;      /* 上次回调时间戳（仅诊断） */
static uint32_t g_aqRateBps = 0;     /* 实测采集速率 B/s（仅诊断） */
static NSUInteger g_aqCbSeq = 0;     /* 回调序号 */
static uint64_t g_aqStartNs = 0;
static BOOL g_aqFormatLogged = NO;   /* ASBD 只打一次 */

static void TTS_AQInputTrampoline(void *inUserData, AudioQueueRef inAQ,
                                  AudioQueueBuffer *inBuffer,
                                  const AudioTimeStamp *inStartTime,
                                  UInt32 inNumberPacketDescriptions,
                                  const AudioStreamPacketDescription *inPacketDescs) {
    if (g_replaceActive && g_pendingPCM && inBuffer && inBuffer->mAudioData) {
        @synchronized([NSObject class]) {
            uint64_t now = clock_gettime_nsec_np(CLOCK_MONOTONIC);
            uint64_t dtNs = 0;
            if (g_aqLastNs && now > g_aqLastNs) dtNs = now - g_aqLastNs;
            uint32_t bufSz = inBuffer->mAudioDataByteSize;
            if (g_aqCbSeq == 0) { g_aqStartNs = now; dtNs = 0; }
            g_aqLastNs = now;
            g_aqCbSeq++;

            /* 诊断：实测采集速率（buffer/dt）——用来核对 PCM 采样率是否 16kHz */
            if (dtNs > 2 * 1000 * 1000 && dtNs < 2000LL * 1000 * 1000) {
                uint32_t r = (uint32_t)((uint64_t)bufSz * 1000000000ULL / dtNs);
                if (r >= 1000 && r <= 4000000 && (g_aqRateBps == 0 || g_aqCbSeq <= 6)) g_aqRateBps = r;
            }
            NSUInteger total = g_pendingPCM.length;
            if (g_pcmOffset < total) {
                /* 整块填满：块内不留间隙（杂音根因就是间隙） */
                NSUInteger take = MIN((NSUInteger)bufSz, total - g_pcmOffset);
                memcpy(inBuffer->mAudioData, (const char *)g_pendingPCM.bytes + g_pcmOffset, take);
                if (take < bufSz) memset((char *)inBuffer->mAudioData + take, 0, bufSz - take);
                g_pcmOffset += take;
            } else {
                memset(inBuffer->mAudioData, 0, bufSz);
                if (!g_pcmFedDone) {
                    g_pcmFedDone = YES;   /* 喂完标记（TTS 数据已全部进入管线） */
                    TTLog(@"[aq-replace] PCM 全部喂完 — 静音帧（cb=%lu）", (unsigned long)g_aqCbSeq);
                }
            }
            /* 每次回调都记录（seq/size/dt/est-rate/fed/total） */
            TTLog(@"[aq-cb] #%lu size=%u dt=%llums rate=%uB/s fed=%lu/%lu",
                  (unsigned long)g_aqCbSeq, bufSz,
                  (unsigned long long)(dtNs / 1000000ULL), g_aqRateBps,
                  (unsigned long)g_pcmOffset, (unsigned long)total);
        }
    }
    /* 调微信原回调（微信以为是自己录的音，实际是 TTS 数据） */
    if (g_origAQNewInput_cb) {
        g_origAQNewInput_cb(inUserData, inAQ, inBuffer, inStartTime, inNumberPacketDescriptions, inPacketDescs);
    }
}

/* rebind AudioQueueNewInput */
static OSStatus (*orig_AudioQueueNewInput)(const AudioStreamBasicDescription *inFormat,
                                           AudioQueueInputCallback inCallbackProc,
                                           void *inUserData, CFRunLoopRef inCFRunLoop,
                                           CFStringRef inCFRunLoopMode,
                                           UInt32 inFlags, AudioQueueRef *outAQ);

static OSStatus TTS_AudioQueueNewInput(const AudioStreamBasicDescription *inFormat,
                                       AudioQueueInputCallback inCallbackProc,
                                       void *inUserData, CFRunLoopRef inCFRunLoop,
                                       CFStringRef inCFRunLoopMode,
                                       UInt32 inFlags, AudioQueueRef *outAQ) {
    if (inCallbackProc && inUserData) {
        TTLog(@"[aq-hook] AudioQueueNewInput 拦截成功（录音回调将经过 trampoline）");
        if (inFormat && !g_aqFormatLogged) {
            g_aqFormatLogged = YES;
            char fcode[5] = { (char)((inFormat->mFormatID >> 24) & 0xFF),
                              (char)((inFormat->mFormatID >> 16) & 0xFF),
                              (char)((inFormat->mFormatID >> 8) & 0xFF),
                              (char)(inFormat->mFormatID & 0xFF), 0 };
            TTLog(@"[aq-fmt] 申请格式 sampleRate=%.0f channels=%u fmt=%s bits=%u bytes/pkt=%u",
                  inFormat->mSampleRate, (unsigned)inFormat->mChannelsPerFrame, fcode,
                  (unsigned)inFormat->mBitsPerChannel, (unsigned)inFormat->mBytesPerPacket);
        }
        g_origAQNewInput_cb = inCallbackProc;
        g_wechatUserData = inUserData;
        return orig_AudioQueueNewInput(inFormat, TTS_AQInputTrampoline, inUserData,
                                       inCFRunLoop, inCFRunLoopMode, inFlags, outAQ);
    }
    return orig_AudioQueueNewInput(inFormat, inCallbackProc, inUserData, inCFRunLoop, inCFRunLoopMode, inFlags, outAQ);
}

static void InstallAudioQueueHook(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        /* fishhook rebind（CoreAudio 动态库符号） */
        struct rebinding r;
        r.name = [TTCSel(7) UTF8String];
        r.replacement = (void *)TTS_AudioQueueNewInput;
        r.replaced = (void **)&orig_AudioQueueNewInput;
        struct rebinding rebinds[1];
        rebinds[0] = r;
        int err = rebind_symbols(rebinds, 1);
        TTLog(@"[aq-hook] fishhook installed err=%d", err);
    });
}

/* ==================== prepareSend 捕获（拿 tousr / AudioSender） ==================== */
static int g_prepareSendSeen = 0;      /* prepareSend: 触发次数（= 发送链是否启动） */
static NSString *g_lastToUsr = nil;
static id g_audioSender = nil;
static id g_lastUserData = nil;

static void InstallPrepareSendCapture(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class cls = NSClassFromString(TTSCls(0));
        if (!cls) { TTLog(@"[capture] cls MISS"); return; }
        SEL sel = NSSelectorFromString(TTCSel(0));
        Method m = class_getInstanceMethod(cls, sel);
        if (!m) { TTLog(@"[capture] send-hook MISS"); return; }

        const char *types = method_getTypeEncoding(m);
        IMP oldImp = method_getImplementation(m);

        if (types && types[0] == 'B') {
            IMP newImp = imp_implementationWithBlock(^BOOL(id self, id arg) {
                @try {
                    @synchronized([NSObject class]) {
                        if (g_audioSender != self) g_audioSender = self;
                        if (arg && g_lastUserData != arg) g_lastUserData = arg;
                    }
                    g_prepareSendSeen++;
                    TTLog(@"[capture] send-hook #%d", g_prepareSendSeen);
                    if (arg) {
                        id to = [arg valueForKey:@"tousr"];
                        if ([to isKindOfClass:[NSString class]] && [(NSString *)to length] > 0) {
                            @synchronized([NSObject class]) { g_lastToUsr = [to copy]; }
                        }
                    }
                } @catch (NSException *e) { }
                return ((BOOL (*)(id, SEL, id))oldImp)(self, sel, arg);
            });
            method_setImplementation(m, newImp);
            TTLog(@"[capture] send-hook installed");
        }
    });
}

/* ==================== 核心：OnOutputPcmBuffer:UserData: Hook ====================
 * 真实录音时微信每帧 PCM 都经过这里（v8b 调用栈证实）。
 * 我们把 PCM 数据替换成 TTS PCM；返回值/其他参数原样传递。
 * 签名推测: void/@(id, id, NSData*, AudioRecorderUserData*) — 按类型分派。
 */
static void InstallPcmReplaceHook(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class cls = NSClassFromString(TTSCls(0));
        if (!cls) { TTLog(@"[pcm-hook] cls MISS"); return; }
        SEL sel = NSSelectorFromString(TTCSel(6));
        Method m = class_getInstanceMethod(cls, sel);
        if (!m) { TTLog(@"[pcm-hook] OnOutputPcmBuffer: MISS"); return; }

        const char *types = method_getTypeEncoding(m);
        IMP oldImp = method_getImplementation(m);
        TTLog(@"[pcm-hook] OnOutputPcmBuffer: types=%s", types ? types : "?");

        char ret = types ? types[0] : 'v';
        if (ret == 'v' || ret == '@' || ret == 'B') {
            /* 常见形态: v32@0:8@16@24 (buffer, userData) — void 返回 2 对象参 */
            /* block 返回类型必须与方法一致——v14 先只支持 void(v) 返回形态
             * （@/B 形态日志会显示 types，下版再补） */
            if (ret != 'v') {
                TTLog(@"[pcm-hook] 返回类型 %c 非 void — v14 仅支持 v，暂不 hook", ret);
                return;
            }
            IMP newImp = imp_implementationWithBlock(^(id self, id buffer, id userData) {
                @autoreleasepool {
                    id passBuffer = buffer;   /* 传给原实现的参数（可能被替换成 TTS 分片） */
                    if (g_replaceActive && g_pendingPCM) {
                @synchronized([NSObject class]) {
                            NSUInteger total = g_pendingPCM.length;
                            if (g_pcmOffset < total) {
                                NSUInteger len = 8000;
                                if (g_pcmOffset + len > total) len = total - g_pcmOffset;
                                /* 不可变 NSData(_NSInlineData) 无法原地改 — 直接给原实现传我们的分片 */
                                NSData *seg = [g_pendingPCM subdataWithRange:NSMakeRange(g_pcmOffset, len)];
                                g_pcmOffset += len;
                                passBuffer = seg;
                                if (g_pcmOffset % 24000 < 8000) { /* 限频日志 */
                                    TTLog(@"[pcm-replace] 换参帧 %lu bytes (off=%lu/%lu) mic=%lu",
                                        (unsigned long)seg.length, (unsigned long)g_pcmOffset, (unsigned long)total,
                                        (unsigned long)[buffer length]);
                                }
                            }
                            /* PCM 用完后传静音帧（保持节奏，内容为 TTS 结尾后的静音） */
                        }
                    }
                    /* 调原实现（传替换后的 passBuffer）——必须在 autoreleasepool 作用域内 */
                    ((void (*)(id, SEL, id, id))oldImp)(self, sel, passBuffer, userData);
                }
            });
            method_setImplementation(m, newImp);
            TTLog(@"[pcm-hook] installed (void)");
        } else {
            TTLog(@"[pcm-hook] 未知返回类型 %c — 不 hook", ret);
        }
    });
}

/* ==================== v16: OnRecorderPart 观察器（真正进上传队列的入口） ====================
 * hook -[AudioSender(AudioRecorderDelegate) OnRecorderPart:Offset:Len:EndFlag:ForceDelete:Duration:]
 * 真实录音时观察：分片提交的参数序列（对照 TTS 发送时是否也走到这里） */
static void InstallRecorderPartObserver(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class cls = NSClassFromString(TTSCls(0));
        if (!cls) { TTLog(@"[part-obs] cls MISS"); return; }
        SEL sel = NSSelectorFromString(TTCSel(5));
        Method m = class_getInstanceMethod(cls, sel);
        if (!m) { TTLog(@"[part-obs] part MISS"); return; }

        const char *types = method_getTypeEncoding(m);
        IMP oldImp = method_getImplementation(m);
        TTLog(@"[part-obs] types=%s", types ? types : "?");
        char ret = types ? types[0] : 'v';
        if (ret != 'v') { TTLog(@"[part-obs] 返回 %c 非 void，不 hook", ret); return; }

        /* v17: 签名已确认 v44@0:8@16I24I28I32B36I40（对象+4u32+BOOL）
         * 按精确布局 hook：block 参数 (id, id, uint32, uint32, uint32, BOOL, uint32)
         * v11b 崩因是参数个数/类型猜错；这次每参按 types 对齐 */
        IMP newImp = imp_implementationWithBlock(^(id self, id part,
                                                   uint32_t offset, uint32_t len,
                                                   uint32_t endFlag, BOOL forceDelete,
                                                   uint32_t duration) {
            @autoreleasepool {
                NSUInteger plen = 0;
                if ([part isKindOfClass:[NSData class]]) plen = [part length];
                TTLog(@"[part] off=%u len=%u end=%u forceDel=%d dur=%u part=%luB",
                      offset, len, endFlag, forceDelete, duration, (unsigned long)plen);
            }
            ((void (*)(id, SEL, id, uint32_t, uint32_t, uint32_t, BOOL, uint32_t))oldImp)
                (self, sel, part, offset, len, endFlag, forceDelete, duration);
        });
        method_setImplementation(m, newImp);
        TTLog(@"[part-obs] hooked（按精确签名）");
    });
}

/* ==================== v22: 录音结束 → 真实发送入口 捕获 ====================
 * 真实链（二进制证实）：OnRecorderEndRecording: → SendOriVoiceMsgWithUserData: → prepareSend:
 * v21 面板里传的 userData 是【StartRecordFrom 的 UserInfo 入参】——它是录音会话的
 * 启动参数字典，不是录音结束时微信内部构造/填充的 AudioRecorderUserData。
 * SendOri 很可能因为 userData 状态不对（receiveEndFlag/duration/audioid 等未填齐）
 * 直接返回 NO，而日志里根本没出现 SendOri 行 → 说明该次还没跑到就结束测试。
 * v22：hook OnRecorderEndRecording: 抓取【微信自己结束时用的 userData】，
 * 面板 StopRecord 后在主线程复刻这一次调用。 */
static id g_realEndUserData = nil;
static NSString *g_realEndSelector = nil;
static int g_recorderEndSeen = 0;
static NSTimeInterval g_recorderEndTime = 0;   /* 最近一次真实结束回调时刻 */

static void InstallRecorderEndCapture(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class cls = NSClassFromString(TTSCls(0));
        if (!cls) { TTLog(@"[end-obs] cls MISS"); return; }
        NSArray *cands = @[ TTCSel(2),
                            TTCSel(3),
                            TTCSel(4) ];
        for (NSString *name in cands) {
            SEL sel = NSSelectorFromString(name);
            Method m = class_getInstanceMethod(cls, sel);
            if (!m) continue;
            const char *types = method_getTypeEncoding(m);
            if (!types || !strstr(types, "@0:8@16")) {   /* 只 hook 单对象参形态 */
                TTLog(@"[end-obs] %@ types=%s 非单对象参，跳过", name, types ? types : "?");
                continue;
            }
            IMP oldImp = method_getImplementation(m);
            IMP newImp = imp_implementationWithBlock(^id(id self, id arg) {
                @autoreleasepool {
                    g_recorderEndSeen++;
                    g_recorderEndTime = [NSDate date].timeIntervalSinceReferenceDate;
                    @synchronized([NSObject class]) {
                        if (g_audioSender != self) g_audioSender = self;
                        if (arg) g_realEndUserData = arg;
                        g_realEndSelector = name;
                    }
                    TTLog(@"[end-obs] %@ self=%p arg=%p(%@)", name, (__bridge void *)self,
                          (__bridge void *)arg, arg ? NSStringFromClass([arg class]) : @"nil");
                }
                return ((id (*)(id, SEL, id))oldImp)(self, sel, arg);
            });
            method_setImplementation(m, newImp);
            TTLog(@"[end-obs] hooked %@ types=%s", name, types);
        }
    });
}

/* ==================== v22: AudioSender 发送相关 selector 侦察（纯日志，零调用） ====================
 * 目的：把真实存在的发送/结束/上传 selector + 类型编码打出来，
 * 之后要补哪一步不用猜（只有类型编码确认是单对象参/无参的方法才会被 v22 调用）。 */
static void TTSDumpSendSelectors(void) {
    Class cls = NSClassFromString(TTSCls(0));
    if (!cls) { TTLog(@"[sel-dump] cls MISS"); return; }
    unsigned int n = 0;
    Method *ms = class_copyMethodList(cls, &n);
    NSMutableString *hit = [NSMutableString stringWithCapacity:2048];
    for (unsigned int i = 0; i < n; i++) {
        SEL s = method_getName(ms[i]);
        NSString *name = NSStringFromSelector(s);
        if ([name rangeOfString:@"Send"].location == NSNotFound &&
            [name rangeOfString:@"send"].location == NSNotFound &&
            [name rangeOfString:@"Record"].location == NSNotFound &&
            [name rangeOfString:@"record"].location == NSNotFound &&
            [name rangeOfString:@"Upload"].location == NSNotFound) continue;
        const char *t = method_getTypeEncoding(ms[i]);
        [hit appendFormat:@"\n    %@ : %s", name, t ? t : "?"];
    }
    free(ms);
    TTLog(@"[sel-dump] %u methods:%@", n, hit.length ? hit : @"(none)");
}

/* ==================== TTS API ==================== */
static NSString *TiaxKey(void) {   /* v26: key 三段 hex 密文运行时解码，strings 直搜无果 */
    static NSString *k = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        k = [TTSXorHex(K_KEY_A_HEX.UTF8String, 0x3C) stringByAppendingString:
            [TTSXorHex(K_KEY_B_HEX.UTF8String, 0x3C) stringByAppendingString:
              TTSXorHex(K_KEY_C_HEX.UTF8String, 0x3C)]];
    });
    return k;
}

static NSString *TTSEncode(NSString *s) {
    return [s stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
}

static BOOL TTSIsAudioData(NSData *d) {
    if (d.length < 4) return NO;
    const unsigned char *b = d.bytes;
    if (b[0] == 'I' && b[1] == 'D' && b[2] == '3') return YES;
    if (b[0] == 'R' && b[1] == 'I' && b[2] == 'F' && b[3] == 'F') return YES;
    if (b[0] == 0xFF && (b[1] & 0xF0) == 0xF0) return YES;
    if (b[0] == 'f' && b[1] == 't' && b[2] == 'y' && b[3] == 'p') return YES;
    if (b[0] == '{') return NO;
    return NO;
}

static void TTSDownloadAudio(NSString *audioURL, void (^done)(NSData *audio, NSError *error)) {
    NSURL *u = [NSURL URLWithString:audioURL];
    if (!u) { done(nil, [NSError errorWithDomain:@"TTS" code:3 userInfo:@{NSLocalizedDescriptionKey:@"音频URL无效"}]); return; }
    NSURLSessionDataTask *task = [NSURLSession.sharedSession dataTaskWithURL:u
        completionHandler:^(NSData *audio, NSURLResponse *r2, NSError *e2) {
            if (e2 != nil || audio.length == 0) {
                done(nil, e2);
            } else if (!TTSIsAudioData(audio)) {
                done(nil, [NSError errorWithDomain:@"TTS" code:7 userInfo:@{NSLocalizedDescriptionKey:@"CDN文件过期(NoSuchKey)"}]);
            } else {
                TTLog(@"[tts] audio %lu bytes", (unsigned long)audio.length);
                done(audio, nil);
            }
        }];
    [task resume];
}

static void RequestTTSOnce(NSString *text, NSString *voice, void (^done)(NSData *audio, NSError *error)) {
    NSString *v = TTSVoiceIDForName(voice);   /* ⚠️ 接口只认数字 ID，不认中文名 */
    NSString *k = TiaxKey();
    if (k.length == 0) { done(nil, [NSError errorWithDomain:@"TTS" code:6 userInfo:@{NSLocalizedDescriptionKey:@"key未配置"}]); return; }
    /* v26: 参数名拼装（binary 里搜不到 ?text=&voice=&apikey= 模板） */
    NSString *urlStr = [TTSEndpoint() stringByAppendingString:
        [NSString stringWithFormat:@"?%@=%@&%@=%@&%@=%@",
         TTCSel(10), TTSEncode(text), TTCSel(11), TTSEncode(v), TTCSel(12), TTSEncode(k)]];
    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url) { done(nil, [NSError errorWithDomain:@"TTS" code:1 userInfo:@{NSLocalizedDescriptionKey:@"URL无效"}]); return; }
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.timeoutInterval = 30;
    NSURLSessionDataTask *task = [NSURLSession.sharedSession dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *r, NSError *e) {
            if (e != nil) { done(nil, e); return; }
            if (data.length == 0) { done(nil, [NSError errorWithDomain:@"TTS" code:2 userInfo:@{NSLocalizedDescriptionKey:@"API空返回"}]); return; }
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if ([json isKindOfClass:[NSDictionary class]]) {
                NSString *aurl = json[@"url"];
                if ([aurl isKindOfClass:[NSString class]] && aurl.length > 0) { TTSDownloadAudio(aurl, done); return; }
                done(nil, [NSError errorWithDomain:@"TTS" code:4 userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"API无url: %@", json]}]);
                return;
            }
            done(nil, [NSError errorWithDomain:@"TTS" code:5 userInfo:@{NSLocalizedDescriptionKey:@"非JSON返回"}]);
        }];
    [task resume];
}

static void RequestTTS(NSString *text, NSString *voice, void (^done)(NSData *audio, NSError *error)) {
    __block NSInteger attempt = 0;
    __block void (^retry)(NSData *, NSError *) = nil;
    retry = ^(NSData *audio, NSError *error) {
        attempt++;
        if (audio != nil) { done(audio, nil); return; }
        if (error.code == 7 && attempt < 3) {
            TTLog(@"[tts] CDN过期重试 %ld", (long)attempt);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                           dispatch_get_global_queue(0, 0), ^{ RequestTTSOnce(text, voice, retry); });
            return;
        }
        done(nil, error);
    };
    RequestTTSOnce(text, voice, retry);
}

/* ==================== mp3 → PCM ==================== */
static NSData *DecodeToPCM(NSData *audioData) {
    if (!audioData.length) return nil;
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:
                      [NSString stringWithFormat:@"tts_%@.audio", NSUUID.UUID.UUIDString]];
    if (![audioData writeToFile:path options:NSDataWritingAtomic error:nil]) return nil;

    NSError *err = nil;
    AVAudioFile *file = [[AVAudioFile alloc] initForReading:[NSURL fileURLWithPath:path] error:&err];
    if (!file) { TTLog(@"[pcm] open fail %@", err); [[NSFileManager defaultManager] removeItemAtPath:path error:nil]; return nil; }

    AVAudioFormat *src = file.processingFormat;
    AVAudioFormat *dst = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:(double)g_targetSampleRate channels:1];
    AVAudioConverter *conv = [[AVAudioConverter alloc] initFromFormat:src toFormat:dst];
    if (!conv) { TTLog(@"[pcm] conv fail"); return nil; }

    NSMutableData *pcm = [NSMutableData data];
    while (file.framePosition < file.length) {
        AVAudioFrameCount remain = (AVAudioFrameCount)(file.length - file.framePosition);
        AVAudioFrameCount inFrames = MIN(remain, 4096);
        AVAudioPCMBuffer *inBuf = [[AVAudioPCMBuffer alloc] initWithPCMFormat:src frameCapacity:inFrames];
        if (![file readIntoBuffer:inBuf error:nil]) break;
        AVAudioPCMBuffer *outBuf = [[AVAudioPCMBuffer alloc] initWithPCMFormat:dst frameCapacity:8192];
        __block BOOL supplied = NO;
        [conv convertToBuffer:outBuf error:nil withInputFromBlock:^AVAudioBuffer *(AVAudioPacketCount pk, AVAudioConverterInputStatus *st) {
            if (supplied) { *st = AVAudioConverterInputStatus_NoDataNow; return nil; }
            supplied = YES; *st = AVAudioConverterInputStatus_HaveData; return inBuf;
        }];
        if (outBuf.frameLength && outBuf.floatChannelData) {
            float *samples = outBuf.floatChannelData[0];
            for (AVAudioFrameCount i = 0; i < outBuf.frameLength; i++) {
                float v = samples[i];
                if (v > 1.0f) v = 1.0f; if (v < -1.0f) v = -1.0f;
                int16_t s = (int16_t)(v * 32767.0f);
                [pcm appendBytes:&s length:2];
            }
        }
    }
    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    TTLog(@"[pcm] %lu bytes", (unsigned long)pcm.length);
    return pcm.length ? pcm : nil;
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
- (void)closeVoiceList;
- (void)maskTapped:(UITapGestureRecognizer *)g;
- (void)closePanel;
- (void)showTip;
- (void)closeTip;
- (void)tipMaskTapped:(UITapGestureRecognizer *)g;
- (void)kbWillShow:(NSNotification *)n;
- (void)kbWillHide:(NSNotification *)n;
- (void)sendDirect;
- (NSString *)sendVoiceToWeChat:(NSData *)pcm toUsr:(NSString *)toUsr;
- (void)v26_finishRecordAndWait:(int)waitedMs;
@end

@implementation TTSFloatView

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

    /* 音色异步加载完成后刷新标题 */
    if (g_voices.count) {
        self.voiceLabel.text = TTSCurVoice();
    } else {
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
    lt.text = n ? [NSString stringWithFormat:@"选择音色（%lu）", (unsigned long)n]
                : (g_voiceFetchState < 0 ? @"加载失败，点右上角重试" : @"加载中…");
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

    /* 搜索框：458 个音色必须能搜 */
    UISearchBar *sb = [[UISearchBar alloc] initWithFrame:CGRectMake(0, 38, lw, 44)];
    sb.placeholder = @"搜索音色（中文名，支持模糊）";
    sb.delegate = (id<UISearchBarDelegate>)self;
    sb.tag = 9530;
    [listPanel addSubview:sb];
    self.searchField = sb;

    UITableView *tv = [[UITableView alloc] initWithFrame:CGRectMake(0, 84, lw, lh-84)
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
                if (h) h.text = ok ? [NSString stringWithFormat:@"选择音色（%lu）", (unsigned long)n]
                                   : @"加载失败，点右上角重试";
            }
            ss.voiceLabel.text = ok ? TTSCurVoice() : @"音色加载失败（点这里重试）";
        });
    });
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

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 1; }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    NSArray *l = g_voiceFilter ?: g_voices;
    return (NSInteger)l.count;
}
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *cid = @"VC";
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:cid];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:cid];
    NSArray *l = g_voiceFilter ?: g_voices;
    if (ip.row >= (NSInteger)l.count) { cell.textLabel.text = @""; return cell; }
    NSString *name = l[ip.row];
    cell.textLabel.text = name;
    cell.textLabel.font = [UIFont systemFontOfSize:14];
    cell.textLabel.textColor = UIColor.blackColor;
    cell.accessoryType = [name isEqualToString:TTSCurVoice()] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    cell.backgroundColor = UIColor.whiteColor;
    return cell;
}
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    NSArray *l = g_voiceFilter ?: g_voices;
    if (ip.row >= (NSInteger)l.count) return;
    NSString *name = l[ip.row];
    TTSSetVoice(name);
    self.voiceLabel.text = name;
    [self closeVoiceList];
    [self setStatusOnMain:[NSString stringWithFormat:@"音色：%@", name]];
    TTLog(@"[voice-list] selected %@", name);
}

/* v25: 搜索过滤 */
- (void)searchBar:(UISearchBar *)sb textDidChange:(NSString *)text {
    NSString *q = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (q.length == 0 || !g_voices.count) {
        g_voiceFilter = nil;
    } else {
        NSMutableArray *r = [NSMutableArray array];
        for (NSString *n in g_voices) {
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

    NSString *peer = nil, *myWxid = nil;
    NSDictionary *userInfo = nil;
    id audioSender = nil;
    @synchronized([NSObject class]) {
        peer = [g_lastToUsr copy];
        myWxid = [g_lastFromParam copy];
        userInfo = g_lastUserInfoParam;
        audioSender = g_audioSender;
    }
    if (!peer.length) { self.statusLabel.text = @"先按住说话一次（捕获会话）"; return; }
    if (!myWxid.length) { self.statusLabel.text = @"先按住说话一次（捕获身份）"; return; }
    if (!audioSender) { self.statusLabel.text = @"发送器未就绪"; return; }

    [self.input resignFirstResponder];
    self.send.enabled = NO;
    self.statusLabel.text = @"合成中…";
    [self.spinner startAnimating];
    NSString *voice = TTSCurVoice();
    TTLog(@"[tts] v=%@ id=%@", voice, TTSVoiceIDForName(voice));

    RequestTTS(text, voice, ^(NSData *audio, NSError *error) {
        if (error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self.send.enabled = YES; [self.spinner stopAnimating];
                self.statusLabel.text = [NSString stringWithFormat:@"失败：%@", error.localizedDescription];
            });
            return;
        }
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

            /* 装填 C 层替换缓存（trampoline 消费） */
            @synchronized([NSObject class]) {
                g_pendingPCM = pcm;
                g_pcmOffset = 0;
                g_replaceActive = YES;
                g_pcmFedDone = NO;
                g_aqLastNs = 0; g_aqRateBps = 0; g_aqCbSeq = 0; g_aqStartNs = 0;
                g_aqFormatLogged = NO;   /* 本次会话重新打印录音器格式 */
            }
            TTLog(@"[panel] PCM 装填 %lu bytes ≈ %lums — 启动录音会话", (unsigned long)pcm.length, (unsigned long)ms);

            /* ① 编程式启动录音（参数身份 v20 已确认：自己wxid/对方wxid/字典） */
            SEL startSel = NSSelectorFromString(TTCSel(8));
            BOOL recording = NO;
            @try {
                BOOL (*fn)(id, SEL, id, id, id) = (BOOL (*)(id, SEL, id, id, id))objc_msgSend;
                recording = fn(audioSender, startSel, myWxid, peer, userInfo);
                TTLog(@"[panel] start ret=%d", recording);
            } @catch (NSException *e) {
                TTLog(@"[panel] start EXC: %@", e);
            }

            if (recording) {
                /* ② 轮询等待：PCM 喂完后（g_pcmFedDone）+ 800ms 余量再 Stop
                 *    （Stop 太早会截断数据 → 微信等完整数据 → 转圈） */
                __block int waited = 0;
                dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
                    /* v22: 实时节奏喂数 → 上限 = 15s + 2×语音时长（48kHz 采集时喂完需 3× 语音时长） */
                    int capMs = 15000 + 2 * (int)ms;
                    while (waited < capMs) {
                        [NSThread sleepForTimeInterval:0.1];
                        waited += 100;
                        BOOL fed = NO;
                        @synchronized([NSObject class]) { fed = g_pcmFedDone; }
                        if (fed) {
                            /* v23: 余量 1.2s→0.3s（只等最后一块 buffer 落地，少录静音） */
                            [NSThread sleepForTimeInterval:0.3];
                            break;
                        }
                    }
                    int waitedCopy = waited;
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [self v26_finishRecordAndWait:waitedCopy];
                    });
                });
            } else {
                @synchronized([NSObject class]) { g_replaceActive = NO; }
                dispatch_async(dispatch_get_main_queue(), ^{
                    self.send.enabled = YES; [self.spinner stopAnimating];
                    self.statusLabel.text = @"录音会话启动失败";
                });
            }
        });
    });
}

/* ==================== v23 收尾（全部主线程） ====================
 * ⚠️⚠️ 闪退根因（v22 日志 112~115 行铁证）：
 *   [v22] 真实结束链已跑 … 跳过复刻防重复发送
 *   [v22] SendOri(realUD) ret=0        ← 守卫说了"跳过"却仍然调了（守卫只置 sent=YES，没拦下面的分支）
 * `AudioRecorderUserData` 是录音会话私有对象，会话销毁后微信会释放它；
 * 把它跨会话喂给 SendOriVoiceMsgWithUserData: = 典型的 use-after-free → 闪退。
 * v23 铁律：**绝不再向微信回传任何捕获来的 userData 对象**，
 * 捕获对象只用于打指针/类名诊断。真实链（OnRecorderEndRecording: → SendOri → prepareSend）
 * 由 StopRecord 自己触发，v22 日志已证明它可以把消息发出去。
 * ⚠️ v21 在后台线程调 StopRecord 也是风险点 → StopRecord 保持主线程。 */
- (void)v26_finishRecordAndWait:(int)waitedMs {
    id audioSender = nil;
    @synchronized([NSObject class]) { audioSender = g_audioSender; }
    if (!audioSender) { TTLog(@"[v26] 无 AudioSender"); return; }

    int seenBefore = g_recorderEndSeen;
    int prepBefore = g_prepareSendSeen;

    SEL stopSel = NSSelectorFromString(TTCSel(1));
    @try {
        ((void (*)(id, SEL))objc_msgSend)(audioSender, stopSel);
        TTLog(@"[v26] stop done (waited=%dms) end=%d", waitedMs, seenBefore);
    } @catch (NSException *e) { TTLog(@"[v26] StopRecord 异常: %@", e); }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        @synchronized([NSObject class]) {
            g_replaceActive = NO;
            g_pcmFedDone = NO;
        }
        /* 只观测，不调用任何微信内部发送入口 */
        /* v23 日志修正认知：StopRecord 触发的结束链里**不会**走 prepareSend:，
         * 但 OnRecorderEndRecording: 一定会走，并且消息确实发出去了（实测）。
         * 所以成功判据用 end，不用 prepareSend（prepareSend 只在手动按住说话时计数）。 */
        BOOL endFired = (g_recorderEndSeen > seenBefore);
        BOOL prepFired = (g_prepareSendSeen > prepBefore);
        TTLog(@"[v26] done end:%d→%d %@",
              seenBefore, g_recorderEndSeen,
              endFired ? @"OK" : @"END-MISS");
        self.send.enabled = YES; [self.spinner stopAnimating];
        self.statusLabel.text = endFired ? @"✅ 已发送" : @"⚠️ 未触发结束链（看日志）";
        if (endFired) self.input.text = @"";
    });
}

/* ===== v13c 验证过的发送链（气泡+silk 已验证） ===== */
- (NSString *)sendVoiceToWeChat:(NSData *)pcm toUsr:(NSString *)toUsr {
    if (!pcm.length || !toUsr.length) return @"数据为空";

    id audioSender = nil;
    @synchronized([NSObject class]) { audioSender = g_audioSender; }
    if (!audioSender) return @"拿不到 AudioSender";

    /* silk 自编码（v13c 验证：initEncoder → encodeFromPCMData） */
    Class silkCls = NSClassFromString(TTSCls(1));
    NSData *silkData = nil;
    if (silkCls) {
        id codec = [[silkCls alloc] init];
        SEL initSel = NSSelectorFromString(@"initEncoderWithSampleRate:");
        if ([codec respondsToSelector:initSel]) {
            @try {
                ((void (*)(id, SEL, NSInteger))objc_msgSend)(codec, initSel, (NSInteger)g_targetSampleRate);
                TTLog(@"[silk] initEncoder done");
            } @catch (NSException *e) { }
        }
        SEL encSel = NSSelectorFromString(@"encodeFromPCMData:");
        if ([codec respondsToSelector:encSel]) {
            @try {
                id r = ((id (*)(id, SEL, id))objc_msgSend)(codec, encSel, pcm);
                if ([r isKindOfClass:[NSData class]] && [r length] > 0) {
                    silkData = r;
                    TTLog(@"[silk] encoded %lu -> %lu bytes", (unsigned long)pcm.length, (unsigned long)silkData.length);
                }
            } @catch (NSException *e) { TTLog(@"[silk] 异常"); }
        }
    }
    NSData *feed = (silkData.length > 0) ? silkData : pcm;

    /* v19: 数据在 C 层（AudioQueue buffer）被替换 —— 不再推分片/不调 prepareSend。
     * 用户按住说话 → trampoline 替换 buffer → 松手 → 微信完整真实管线发送。 */
    NSUInteger ms = pcm.length * 1000 / (NSUInteger)(g_targetSampleRate * 2);
    @synchronized([NSObject class]) {
        g_pendingPCM = pcm;
        g_pcmOffset = 0;
        g_replaceActive = YES;
    }
    TTLog(@"[v19] PCM 装填 %lu bytes ≈ %lums — 等待按住说话", (unsigned long)pcm.length, (unsigned long)ms);
    return nil;

    /* prepareSend:（v13c 验证：创建气泡+接收任务） */
    id userData = nil;
    @synchronized([NSObject class]) { userData = g_lastUserData; }
    if (!userData) return @"无 userData";

    @try { [userData setValue:toUsr forKey:@"tousr"]; } @catch (NSException *e) {}
    @try { [userData setValue:toUsr forKey:@"chatname"]; } @catch (NSException *e) {}

    BOOL ok = NO;
    @try {
        SEL ps = NSSelectorFromString(TTCSel(0));
        BOOL (*fn)(id, SEL, id) = (BOOL (*)(id, SEL, id))objc_msgSend;
        ok = fn(audioSender, ps, userData);
    } @catch (NSException *e) { return @"prepareSend 异常"; }
    TTLog(@"[send] prepareSend ret=%d", ok);
    if (!ok) return @"prepareSend 拒绝";

    /* bypUploader 启动尝试（v13f 未验证完的最后一环） */
    @try {
        id up = [audioSender valueForKey:@"bypUploader"];
        if (up) {
            SEL s1 = NSSelectorFromString(@"Start");
            SEL s2 = NSSelectorFromString(@"TimerCheckUpload");
            SEL s3 = NSSelectorFromString(@"startSend:");
            if ([up respondsToSelector:s1]) ((void (*)(id, SEL))objc_msgSend)(up, s1);
            if ([up respondsToSelector:s2]) ((void (*)(id, SEL))objc_msgSend)(up, s2);
            if ([up respondsToSelector:s3]) ((void (*)(id, SEL, id))objc_msgSend)(up, s3, nil);
            TTLog(@"[send] uploader Started+TimerCheck+startSend");
        }
    } @catch (NSException *e) { TTLog(@"[send] uploader 异常"); }

    return nil;
}

@end

/* ==================== 启动 ==================== */
static void TTSShowBall(void) {
    if (g_ttsWindow) return;
    CGRect r = UIScreen.mainScreen.bounds;
    g_ttsWindow = [[TTSPassWindow alloc] initWithFrame:r];
    g_ttsWindow.backgroundColor = UIColor.clearColor;
    g_ttsWindow.windowLevel = UIWindowLevelAlert + 100;
    g_ttsWindow.userInteractionEnabled = YES;
    TTSRootController *root = [TTSRootController new];
    g_ttsWindow.rootViewController = root;
    root.view.backgroundColor = UIColor.clearColor;
    TTSFloatView *ball = [[TTSFloatView alloc] initWithFrame:CGRectMake(r.size.width - 72, r.size.height * .42, 56, 56)];
    [root.view addSubview:ball];
    [g_ttsWindow makeKeyAndVisible];
    TTLog(@"===== v26 ball shown（整块填满 + 真实链自动发送，不再回传 userData） =====");
}

@interface TTSBootstrap : NSObject
@end
@implementation TTSBootstrap
+ (void)load {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        TTSShowBall();
        InstallPrepareSendCapture();
        InstallStartRecordObserver();
        InstallAudioQueueHook();
        TTSInitVoicesIfNeeded();          /* v25: 启动就拉 ys.php 音色表 */
        InstallRecorderEndCapture();      /* v22: 抓微信真实结束时的 userData */
        InstallRecorderPartObserver();    /* v22: 分片提交观察器（判断数据是否真进上传队列） */
        TTSDumpSendSelectors();           /* v22: 打印真实存在的发送/录音/上传 selector */
    });
}
@end

__attribute__((constructor))
static void TTSFloatV14Init(void) {
    g_logPath = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/TTSFloat.log"];
    TTLog(@"v26 init (音色改为 ys.php 动态加载 + 搜索列表)");
    TTSInstallCrashGuards();
}
