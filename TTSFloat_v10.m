/*
 * TTSFloat_v10.m — 微信文字转语音插件 最终版
 *
 * 完整闭环（全部基于真机验证链路 v8b/v9）：
 *   1. 悬浮球 + 面板（音色切换 ◀▶ + 文字输入）
 *   2. hook -[AudioSender prepareSend:] 读 AudioRecorderUserData.tousr（当前聊天对象）
 *   3. TTS: GET yuyin2.php?text=&voice=&apikey=（K_APIKEY_BUILTIN 宏，环境变量读不到）
 *   4. AVAudioConverter: mp3 → 16kHz mono Int16 PCM
 *   5. PCM 分片喂 [transcacheLogic processVoiceData:]（微信内部自动 PCM→silk 编码）
 *   6. endProcessVoiceData:(tousr) + queueItem:nil,endflag=1 → 微信真实上传发送
 *
 * 安全设计（血泪教训）：
 *   - 只 hook AudioSender prepareSend:（返回类型 B24 分派，v8b 验证不闪退）
 *   - 不 hook CMessageMgr（v5 证明会崩）
 *   - 不调 AddMsg（不需要，走微信真实上传链）
 *   - 不自己编码 silk（微信 processVoiceData 链内部做）
 *   - 日志写 Documents/TTSFloat.log
 *
 * 编译(GitHub Actions macOS):
 *   xcrun -sdk iphoneos clang -arch arm64 -miphoneos-version-min=12.0 \
 *     -fobjc-arc -dynamiclib \
 *     -framework Foundation -framework UIKit -framework AVFoundation -framework CoreGraphics \
 *     -o TTSFloat_v10.dylib TTSFloat_v10.m
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

/* ==================== 配置 ==================== */
#define K_TTS_ENDPOINT @"https://www.tiax.pw/API/yuyin2.php"
#define K_DEFAULT_VOICE @"2学长"

/* API key 在这里填（环境变量在 TrollStore 注入下读不到） */
#define K_APIKEY_BUILTIN @""

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

/* ==================== 当前聊天对象捕获（v8b 验证） ==================== */
static NSString *g_lastToUsr = nil;

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
            /* B24@0:8@16 — BOOL 返回（真机验证） */
            IMP newImp = imp_implementationWithBlock(^BOOL(id self, id arg) {
                @try {
                    if (arg) {
                        id to = [arg valueForKey:@"tousr"];
                        if ([to isKindOfClass:[NSString class]] && [(NSString *)to length] > 0) {
                            @synchronized([NSObject class]) {
                                g_lastToUsr = [to copy];
                            }
                            TTLog(@"[capture] tousr=%@", to);
                        }
                    }
                } @catch (NSException *e) { TTLog(@"[capture] kvc err %@", e); }
                return ((BOOL (*)(id, SEL, id))oldImp)(self, sel, arg);
            });
            method_setImplementation(m, newImp);
            TTLog(@"[capture] prepareSend: hooked (B) types=%s", types);
        } else {
            TTLog(@"[capture] unexpected types=%s — NOT hooked", types ? types : "?");
        }
    });
}

/* 兜底：从 VC KVC 找（弱于 capture） */
static NSString *CurrentChatUser(void) {
    InstallPrepareSendCapture();
    @synchronized([NSObject class]) {
        if (g_lastToUsr.length > 0) return [g_lastToUsr copy];
    }
    return nil;
}

/* ==================== 发送链（v9 验证） ==================== */
static NSString *TTSSendVoice(NSData *pcmData, NSString *toUsr) {
    if (!pcmData.length || !toUsr.length) return @"数据为空";

    /* 拿 AudioSender 单例（superclass=MMUserService → MMServiceCenter） */
    id audioSender = nil;
    Class scCls = NSClassFromString(@"MMServiceCenter");
    if (scCls) {
        id center = nil;
        SEL dc = NSSelectorFromString(@"defaultCenter");
        if ([scCls respondsToSelector:dc]) center = ((id (*)(id, SEL))objc_msgSend)(scCls, dc);
        if (!center) {
            SEL si = NSSelectorFromString(@"sharedInstance");
            if ([scCls respondsToSelector:si]) center = ((id (*)(id, SEL))objc_msgSend)(scCls, si);
        }
        if (center) {
            SEL gs = NSSelectorFromString(@"getService:");
            if ([center respondsToSelector:gs]) {
                audioSender = ((id (*)(id, SEL, Class))objc_msgSend)(center, gs, NSClassFromString(@"AudioSender"));
            }
        }
    }
    if (!audioSender) return @"拿不到 AudioSender";

    /* 拿 transcacheLogic（每次录音换新实例，从 audioSender 现取） */
    id logic = [audioSender valueForKey:@"transcacheLogic"];
    if (!logic) return @"拿不到 transcacheLogic";

    SEL pvd = NSSelectorFromString(@"processVoiceData:");
    SEL pvdq = NSSelectorFromString(@"processVoiceData:queueItem:");
    SEL epd = NSSelectorFromString(@"endProcessVoiceData:");

    if (![logic respondsToSelector:pvd] || ![logic respondsToSelector:epd]) {
        return @"transcacheLogic 缺方法";
    }

    void (*pvdImp)(id, SEL, id) = (void (*)(id, SEL, id))objc_msgSend;
    void (*epdImp)(id, SEL, id) = (void (*)(id, SEL, id))objc_msgSend;

    /* ① 分片喂 PCM（~8000 字节/片 ≈ 250ms，与微信录音节奏一致） */
    const NSUInteger CHUNK = 8000;
    const unsigned char *bytes = pcmData.bytes;
    NSUInteger total = pcmData.length;
    NSUInteger fed = 0, seq = 0;
    for (NSUInteger off = 0; off < total; off += CHUNK) {
        NSUInteger len = MIN(CHUNK, total - off);
        NSData *piece = [NSData dataWithBytes:bytes + off length:len];
        pvdImp(logic, pvd, piece);
        fed += len; seq++;
    }
    TTLog(@"[send] fed %lu bytes in %lu chunks", (unsigned long)fed, (unsigned long)seq);

    /* ② endProcessVoiceData:(tousr) */
    epdImp(logic, epd, toUsr);

    /* ③ 结束标记 queueItem:nil endflag=1 */
    if ([logic respondsToSelector:pvdq]) {
        Class itemCls = NSClassFromString(@"StreamInputQueueItem");
        if (itemCls) {
            id item = [[itemCls alloc] init];
            @try { [item setValue:@1 forKey:@"endflag"]; } @catch (NSException *e) { TTLog(@"[send] endflag kvc err"); }
            void (*pvdqImp)(id, SEL, id, id) = (void (*)(id, SEL, id, id))objc_msgSend;
            pvdqImp(logic, pvdq, nil, item);
            TTLog(@"[send] endflag=1 sent");
        } else {
            TTLog(@"[send] StreamInputQueueItem MISS — 尝试 nil 队列项");
            void (*pvdqImp)(id, SEL, id, id) = (void (*)(id, SEL, id, id))objc_msgSend;
            pvdqImp(logic, pvdq, nil, nil);
        }
    }

    return nil; /* 成功 */
}

/* ==================== TTS API ==================== */
static NSString *TiaxKey(void) {
    return K_APIKEY_BUILTIN;
}

static NSString *TTSEncode(NSString *s) {
    return [s stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
}

static void TTSDownloadAudio(NSString *audioURL, void (^done)(NSData *audio, NSError *error)) {
    NSURL *u = [NSURL URLWithString:audioURL];
    if (!u) {
        done(nil, [NSError errorWithDomain:@"TTS" code:3 userInfo:@{NSLocalizedDescriptionKey:@"音频URL无效"}]);
        return;
    }
    NSURLSessionDataTask *task = [NSURLSession.sharedSession dataTaskWithURL:u
        completionHandler:^(NSData *audio, NSURLResponse *r2, NSError *e2) {
            if (e2 != nil || audio.length == 0) {
                done(nil, e2);
            } else {
                TTLog(@"[tts] mp3 %lu bytes", (unsigned long)audio.length);
                done(audio, nil);
            }
        }];
    [task resume];
}

static void RequestTTS(NSString *text, NSString *voice, void (^done)(NSData *audio, NSError *error)) {
    NSString *v = voice ? voice : K_DEFAULT_VOICE;
    NSString *k = TiaxKey();
    if (k.length == 0) {
        done(nil, [NSError errorWithDomain:@"TTS" code:6 userInfo:@{NSLocalizedDescriptionKey:@"API key未配置(K_APIKEY_BUILTIN)"}]);
        return;
    }
    NSString *urlStr = [NSString stringWithFormat:@"%@?text=%@&voice=%@&apikey=%@",
                        K_TTS_ENDPOINT, TTSEncode(text), TTSEncode(v), TTSEncode(k)];
    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url) {
        done(nil, [NSError errorWithDomain:@"TTS" code:1 userInfo:@{NSLocalizedDescriptionKey:@"URL无效"}]);
        return;
    }
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.timeoutInterval = 30;
    NSURLSessionDataTask *task = [NSURLSession.sharedSession dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *r, NSError *e) {
            if (e != nil) { done(nil, e); return; }
            if (data.length == 0) {
                done(nil, [NSError errorWithDomain:@"TTS" code:2 userInfo:@{NSLocalizedDescriptionKey:@"API空返回"}]);
                return;
            }
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if ([json isKindOfClass:[NSDictionary class]]) {
                NSString *aurl = json[@"url"];
                if ([aurl isKindOfClass:[NSString class]] && aurl.length > 0) {
                    TTSDownloadAudio(aurl, done);
                    return;
                }
                done(nil, [NSError errorWithDomain:@"TTS" code:4 userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"API无url: %@", json]}]);
                return;
            }
            done(nil, [NSError errorWithDomain:@"TTS" code:5 userInfo:@{NSLocalizedDescriptionKey:@"非JSON返回"}]);
        }];
    [task resume];
}

/* ==================== mp3 → 16kHz mono Int16 PCM ==================== */
static NSData *DecodeToPCM(NSData *audioData) {
    if (!audioData.length) return nil;
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:
                      [NSString stringWithFormat:@"tts_%@.audio", NSUUID.UUID.UUIDString]];
    if (![audioData writeToFile:path options:NSDataWritingAtomic error:nil]) return nil;

    NSError *err = nil;
    AVAudioFile *file = [[AVAudioFile alloc] initForReading:[NSURL fileURLWithPath:path] error:&err];
    if (!file) { TTLog(@"[pcm] open fail %@", err); [[NSFileManager defaultManager] removeItemAtPath:path error:nil]; return nil; }

    AVAudioFormat *src = file.processingFormat;
    AVAudioFormat *dst = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:16000 channels:1];
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
            /* float32 → int16 */
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

/* ==================== UI（v4 结构） ==================== */
static UIWindow *g_ttsWindow = nil;
static NSString *g_voiceName = K_DEFAULT_VOICE;

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

- (void)togglePanel {
    if (self.panel) { [self.panel removeFromSuperview]; self.panel = nil; return; }

    CGFloat w = 300, h = 250;
    CGRect sc = UIScreen.mainScreen.bounds;
    UIView *panel = [[UIView alloc] initWithFrame:CGRectMake(MAX(10, CGRectGetMidX(sc) - w / 2),
                                                              MAX(50, CGRectGetMidY(sc) - h / 2), w, h)];
    panel.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.94];
    panel.layer.cornerRadius = 18;
    panel.layer.masksToBounds = YES;
    self.panel = panel;

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
    [self.send addTarget:self action:@selector(generate) forControlEvents:UIControlEventTouchUpInside];
    [panel addSubview:self.send];

    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(12, 222, 276, 20)];
    self.statusLabel.text = @"等待输入";
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

- (void)generate {
    NSString *text = self.input.text;
    if (!text.length) { self.statusLabel.text = @"请输入文字"; return; }

    NSString *peer = CurrentChatUser();
    if (!peer.length) {
        self.statusLabel.text = @"未捕获聊天对象（先在聊天里按住说话一次）";
        return;
    }

    self.send.enabled = NO;
    self.statusLabel.text = @"正在合成…";
    [self.spinner startAnimating];
    NSString *voice = g_voiceName ? g_voiceName : K_DEFAULT_VOICE;

    RequestTTS(text, voice, ^(NSData *audio, NSError *error) {
        if (error) { [self setStatusOnMain:[NSString stringWithFormat:@"TTS失败：%@", error.localizedDescription]]; return; }

        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSData *pcm = DecodeToPCM(audio);
            if (!pcm) { [self setStatusOnMain:@"PCM解码失败"]; return; }

            NSString *err = TTSSendVoice(pcm, peer);
            if (err) {
                TTLog(@"[final] send err: %@", err);
                [self setStatusOnMain:[NSString stringWithFormat:@"发送失败：%@", err]];
            } else {
                TTLog(@"[final] sent to %@", peer);
                [self setStatusOnMain:@"✅ 已发送语音"];
                dispatch_async(dispatch_get_main_queue(), ^{ self.input.text = @""; });
            }
        });
    });
}

@end

/* ==================== 启动 ==================== */
@interface TTSBootstrap : NSObject
@end

@implementation TTSBootstrap
+ (void)load {
    [[NSNotificationCenter defaultCenter] addObserver:[self new]
                                             selector:@selector(start:)
                                                 name:UIApplicationDidFinishLaunchingNotification
                                               object:nil];
}

- (void)start:(NSNotification *)n {
    [NSTimer scheduledTimerWithTimeInterval:2
                                     target:self
                                   selector:@selector(show:)
                                   userInfo:nil
                                    repeats:NO];
}

- (void)show:(NSTimer *)t {
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

    TTLog(@"===== TTSFloat_v10 loaded =====");
    TTLog(@"key: %@", TiaxKey().length ? @"已配置" : @"未配置(K_APIKEY_BUILTIN)");
    TTLog(@"MJSilkCodec encodeFromPCMData: %@",
          [NSClassFromString(@"MJSilkCodec") instancesRespondToSelector:NSSelectorFromString(@"encodeFromPCMData:")] ? @"YES" : @"NO");

    /* 提前装好捕获（用户第一次真实录音后 tousr 就有了） */
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ InstallPrepareSendCapture(); });
}
@end

__attribute__((constructor))
static void TTSFloatV10Init(void) {
    g_logPath = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/TTSFloat.log"];
    TTLog(@"v10 init (final)");
}
