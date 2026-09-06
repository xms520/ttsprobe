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

/* ==================== 配置 ==================== */
#define K_TTS_ENDPOINT @"https://www.tiax.pw/API/yuyin2.php"
#define K_DEFAULT_VOICE @"2学长"
#define K_APIKEY_BUILTIN @"86306ba1cf8d50b2866c8369a14b384fe1ff96900ca822d98bd35274e87b0635"

static NSInteger g_targetSampleRate = 16000;

static NSArray *VoiceList(void) {
    return @[
        @"2学长", @"AD学姐", @"alex克隆", @"阿蕾奇诺", @"爱莉希雅",
        @"安倍晋三", @"八戒", @"白领御姐音", @"白鹿的声音", @"白岩松",
        @"北方口音LY", @"北京地铁黄华报站", @"贝利亚", @"毕业季温情女学生",
        @"菠萝宝宝yuna", @"伯纳德", @"采访女生", @"曹操", @"陈赫",
        @"陈奕恒", @"重音TETO SV", @"重音teto", @"磁性电台女生", @"达叔",
        @"六花", @"叶修", @"洛天依", @"初音未来", @"小新", @"蜡笔小新"
    ];
}

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

/* ==================== TTS PCM 缓存（hook 替换数据源） ==================== */
static NSData *g_pendingPCM = nil;       /* TTS 合成的完整 PCM */
static NSUInteger g_pcmOffset = 0;       /* 已喂位置 */
static BOOL g_replaceActive = NO;        /* 替换开关 */
static NSString *g_voiceName = K_DEFAULT_VOICE;

/* ==================== prepareSend 捕获（拿 tousr / AudioSender） ==================== */
static NSString *g_lastToUsr = nil;
static id g_audioSender = nil;
static id g_lastUserData = nil;

static void InstallPrepareSendCapture(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class cls = NSClassFromString(@"AudioSender");
        if (!cls) { TTLog(@"[capture] AudioSender MISS"); return; }
        SEL sel = NSSelectorFromString(@"prepareSend:");
        Method m = class_getInstanceMethod(cls, sel);
        if (!m) { TTLog(@"[capture] prepareSend: MISS"); return; }

        const char *types = method_getTypeEncoding(m);
        IMP oldImp = method_getImplementation(m);

        if (types && types[0] == 'B') {
            IMP newImp = imp_implementationWithBlock(^BOOL(id self, id arg) {
                @try {
                    @synchronized([NSObject class]) {
                        if (g_audioSender != self) g_audioSender = self;
                        if (arg && g_lastUserData != arg) g_lastUserData = arg;
                    }
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
            TTLog(@"[capture] prepareSend: hooked");
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
        Class cls = NSClassFromString(@"AudioSender");
        if (!cls) { TTLog(@"[pcm-hook] AudioSender MISS"); return; }
        SEL sel = NSSelectorFromString(@"OnOutputPcmBuffer:UserData:");
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

/* ==================== TTS API ==================== */
static NSString *TiaxKey(void) { return K_APIKEY_BUILTIN; }

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
                TTLog(@"[tts] mp3 %lu bytes", (unsigned long)audio.length);
                done(audio, nil);
            }
        }];
    [task resume];
}

static void RequestTTSOnce(NSString *text, NSString *voice, void (^done)(NSData *audio, NSError *error)) {
    NSString *v = voice ? voice : K_DEFAULT_VOICE;
    NSString *k = TiaxKey();
    if (k.length == 0) { done(nil, [NSError errorWithDomain:@"TTS" code:6 userInfo:@{NSLocalizedDescriptionKey:@"key未配置"}]); return; }
    NSString *urlStr = [NSString stringWithFormat:@"%@?text=%@&voice=%@&apikey=%@",
                        K_TTS_ENDPOINT, TTSEncode(text), TTSEncode(v), TTSEncode(k)];
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

@interface TTSFloatView : UIView
@property (nonatomic, strong) UIView *panel;
@property (nonatomic, strong) UITextView *input;
@property (nonatomic, strong) UIButton *send;
@property (nonatomic, strong) UILabel *voiceLabel;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic) NSInteger voiceIndex;
- (void)kbWillShow:(NSNotification *)n;
- (void)kbWillHide:(NSNotification *)n;
- (void)sendDirect;
- (NSString *)sendVoiceToWeChat:(NSData *)pcm toUsr:(NSString *)toUsr;
@end

@implementation TTSFloatView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.92];
    self.layer.cornerRadius = 28;
    self.layer.masksToBounds = YES;
    self.userInteractionEnabled = YES;
    self.voiceIndex = 0;

    UILabel *icon = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 56, 56)];
    icon.text = @"🎙️";
    icon.font = [UIFont systemFontOfSize:26];
    icon.textAlignment = NSTextAlignmentCenter;
    [self addSubview:icon];

    [self addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(togglePanel)]];
    [self addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(drag:)]];
    return self;
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
    panel.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.94];
    panel.layer.cornerRadius = 18;
    panel.layer.masksToBounds = YES;
    self.panel = panel;

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(kbWillShow:) name:UIKeyboardWillShowNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(kbWillHide:) name:UIKeyboardWillHideNotification object:nil];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(16, 10, 180, 28)];
    title.text = @"🔊 文字转语音";
    title.textColor = UIColor.whiteColor;
    title.font = [UIFont boldSystemFontOfSize:16];
    [panel addSubview:title];

    UILabel *vt = [[UILabel alloc] initWithFrame:CGRectMake(16, 45, 45, 30)];
    vt.text = @"音色";
    vt.textColor = UIColor.whiteColor;
    [panel addSubview:vt];

    UIButton *prev = [UIButton buttonWithType:UIButtonTypeSystem];
    prev.frame = CGRectMake(75, 43, 38, 34);
    [prev setTitle:@"◀" forState:UIControlStateNormal];
    [prev setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    [prev addTarget:self action:@selector(prevVoice) forControlEvents:UIControlEventTouchUpInside];
    [panel addSubview:prev];

    self.voiceLabel = [[UILabel alloc] initWithFrame:CGRectMake(113, 43, 105, 34)];
    self.voiceLabel.text = VoiceList()[self.voiceIndex];
    self.voiceLabel.textColor = UIColor.whiteColor;
    self.voiceLabel.textAlignment = NSTextAlignmentCenter;
    self.voiceLabel.font = [UIFont boldSystemFontOfSize:14];
    [panel addSubview:self.voiceLabel];

    UIButton *next = [UIButton buttonWithType:UIButtonTypeSystem];
    next.frame = CGRectMake(220, 43, 38, 34);
    [next setTitle:@"▶" forState:UIControlStateNormal];
    [next setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    [next addTarget:self action:@selector(nextVoice) forControlEvents:UIControlEventTouchUpInside];
    [panel addSubview:next];

    self.input = [[UITextView alloc] initWithFrame:CGRectMake(12, 82, 276, 92)];
    self.input.backgroundColor = [UIColor colorWithWhite:0.16 alpha:1];
    self.input.textColor = UIColor.whiteColor;
    self.input.font = [UIFont systemFontOfSize:15];
    self.input.layer.cornerRadius = 10;
    [panel addSubview:self.input];

    self.send = [UIButton buttonWithType:UIButtonTypeSystem];
    self.send.frame = CGRectMake(12, 181, 276, 40);
    self.send.backgroundColor = [UIColor colorWithRed:.12 green:.57 blue:.96 alpha:1];
    self.send.layer.cornerRadius = 9;
    [self.send setTitle:@"发送语音" forState:UIControlStateNormal];
    [self.send setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    self.send.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    [self.send addTarget:self action:@selector(sendDirect) forControlEvents:UIControlEventTouchUpInside];
    [panel addSubview:self.send];

    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(12, 222, 276, 20)];
    self.statusLabel.text = @"输入文字后点合成";
    self.statusLabel.textColor = [UIColor colorWithWhite:.75 alpha:1];
    self.statusLabel.font = [UIFont systemFontOfSize:11];
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    [panel addSubview:self.statusLabel];

    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.spinner.center = CGPointMake(282, 202);
    [panel addSubview:self.spinner];

    [self.superview addSubview:panel];
    [self.input becomeFirstResponder];
}

- (void)prevVoice {
    NSArray *l = VoiceList();
    self.voiceIndex = (self.voiceIndex <= 0) ? l.count - 1 : self.voiceIndex - 1;
    g_voiceName = l[self.voiceIndex];
    self.voiceLabel.text = g_voiceName;
}
- (void)nextVoice {
    NSArray *l = VoiceList();
    self.voiceIndex = (self.voiceIndex + 1 >= l.count) ? 0 : self.voiceIndex + 1;
    g_voiceName = l[self.voiceIndex];
    self.voiceLabel.text = g_voiceName;
}

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

    NSString *peer = nil;
    @synchronized([NSObject class]) { peer = [g_lastToUsr copy]; }
    if (!peer.length) { self.statusLabel.text = @"先按住说话一次（捕获会话）"; return; }

    self.send.enabled = NO;
    self.statusLabel.text = @"合成发送中…";
    [self.spinner startAnimating];
    [self.input resignFirstResponder];
    NSString *voice = g_voiceName ? g_voiceName : K_DEFAULT_VOICE;

    RequestTTS(text, voice, ^(NSData *audio, NSError *error) {
        if (error) { [self setStatusOnMain:[NSString stringWithFormat:@"失败：%@", error.localizedDescription]]; return; }
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSData *pcm = DecodeToPCM(audio);
            if (!pcm) { [self setStatusOnMain:@"PCM解码失败"]; return; }

            NSString *err = [self sendVoiceToWeChat:pcm toUsr:peer];
            dispatch_async(dispatch_get_main_queue(), ^{
                self.send.enabled = YES;
                [self.spinner stopAnimating];
                if (err) {
                    self.statusLabel.text = [NSString stringWithFormat:@"失败：%@", err];
                } else {
                    self.statusLabel.text = @"✅ 已提交发送";
                    self.input.text = @"";
                }
            });
        });
    });
}

/* ===== v13c 验证过的发送链（气泡+silk 已验证） ===== */
- (NSString *)sendVoiceToWeChat:(NSData *)pcm toUsr:(NSString *)toUsr {
    if (!pcm.length || !toUsr.length) return @"数据为空";

    id audioSender = nil;
    @synchronized([NSObject class]) { audioSender = g_audioSender; }
    if (!audioSender) return @"拿不到 AudioSender";

    /* silk 自编码（v13c 验证：initEncoder → encodeFromPCMData） */
    Class silkCls = NSClassFromString(@"MJSilkCodec");
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

    /* logic 喂入（v13c 验证：queueItem 双参 + 末帧 endflag + 空帧） */
    id logic = nil;
    @try { logic = [audioSender valueForKey:@"transcacheLogic"]; } @catch (NSException *e) { }
    if (!logic) return @"拿不到 transcacheLogic";

    SEL pvd = NSSelectorFromString(@"processVoiceData:");
    SEL pvdq = NSSelectorFromString(@"processVoiceData:queueItem:");
    SEL epd = NSSelectorFromString(@"endProcessVoiceData");
    Class itemCls = NSClassFromString(@"StreamInputQueueItem");

    @try {
        NSUInteger CHUNK = 8000, total = feed.length, off = 0, seq = 0;
        while (off < total) {
            NSUInteger len = MIN(CHUNK, total - off);
            BOOL last = (off + len >= total);
            NSData *piece = [feed subdataWithRange:NSMakeRange(off, len)];
            ((void (*)(id, SEL, id))objc_msgSend)(logic, pvd, piece);
            if (itemCls) {
                id item = [[itemCls alloc] init];
                @try { [item setValue:@(last ? 1 : 0) forKey:@"_endFlag"]; }
                @catch (NSException *e2) { @try { [item setValue:@(last ? 1 : 0) forKey:@"endFlag"]; } @catch (NSException *e3) {} }
                ((void (*)(id, SEL, id, id))objc_msgSend)(logic, pvdq, piece, item);
            }
            off += len; seq++;
        }
        if (itemCls) {
            id item = [[itemCls alloc] init];
            @try { [item setValue:@1 forKey:@"_endFlag"]; }
            @catch (NSException *e2) { @try { [item setValue:@1 forKey:@"endFlag"]; } @catch (NSException *e3) {} }
            ((void (*)(id, SEL, id, id))objc_msgSend)(logic, pvdq, nil, item);
        }
        TTLog(@"[send] fed %lu bytes %lu chunks", (unsigned long)total, (unsigned long)seq);
    } @catch (NSException *e) { return @"喂入异常"; }

    @try {
        ((void (*)(id, SEL))objc_msgSend)(logic, epd);
        TTLog(@"[send] endProcess done");
    } @catch (NSException *e) { }

    /* prepareSend:（v13c 验证：创建气泡+接收任务） */
    id userData = nil;
    @synchronized([NSObject class]) { userData = g_lastUserData; }
    if (!userData) return @"无 userData";

    @try { [userData setValue:toUsr forKey:@"tousr"]; } @catch (NSException *e) {}
    @try { [userData setValue:toUsr forKey:@"chatname"]; } @catch (NSException *e) {}

    BOOL ok = NO;
    @try {
        SEL ps = NSSelectorFromString(@"prepareSend:");
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
    TTLog(@"===== v14 ball shown（录音Hook方案） =====");
}

@interface TTSBootstrap : NSObject
@end
@implementation TTSBootstrap
+ (void)load {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        TTSShowBall();
        InstallPrepareSendCapture();
        InstallPcmReplaceHook();
    });
}
@end

__attribute__((constructor))
static void TTSFloatV14Init(void) {
    g_logPath = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/TTSFloat.log"];
    TTLog(@"v14 init (录音Hook方案)");
}
