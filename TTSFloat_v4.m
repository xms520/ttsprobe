/*
 * TTSFloat_v3.m
 *
 * 微信 TTS 浮窗完整测试版
 *
 * 已整合：
 *   1. 300x250 左功能/右开关风格的简洁浮窗
 *   2. 30 个常用音色切换
 *   3. tiax TTS API -> JSON url -> 音频下载
 *   4. AVAudioFile / AVAudioConverter: MP3/WAV -> 16kHz mono Int16 PCM
 *   5. MJSilkCodec -encodeFromPCMData:
 *   6. BaseMsgContentViewController 当前聊天对象只读探测
 *
 * 注意：
 *   当前微信版本已经确认：
 *     MJSilkCodec -encodeFromPCMData:
 *     CMessageMgr -AddMsg:MsgWrap:
 *     CMessageMgr -SaveMesVoice:MsgWrap:
 *     CMessageMgr -UpdateVoiceMessage:MsgWrap:
 *     CMessageMgr -AddRecordMsg:MsgWrap:
 *
 *   但尚未确认“外发语音”的完整参数/字段组合。
 *   因此本版默认只生成 Silk，不调用未经验证的外发入口，
 *   避免把 AddMsg 当成真正的服务器发送。
 *
 *   编译时需要 iOS SDK 的 UIKit / AVFoundation / Foundation。
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/message.h>
#import <objc/runtime.h>

#define K_TTS_ENDPOINT @"https://www.tiax.pw/API/yuyin2.php"
#define K_DEFAULT_VOICE @"2学长"

/* 如果 API 需要 key，在这里填写；也可通过环境变量 TIAX_API_KEY 提供。 */
#define K_APIKEY_BUILTIN @""

static UIWindow *g_ttsWindow = nil;
static NSString *g_voiceName = K_DEFAULT_VOICE;

static void TLog(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[TTSFloat_v3] %@", s);
}

static id Msg0(id o, SEL s) {
    if (!o || ![o respondsToSelector:s]) return nil;
    return ((id(*)(id,SEL))objc_msgSend)(o,s);
}

static id Msg1(id o, SEL s, id a) {
    if (!o || ![o respondsToSelector:s]) return nil;
    return ((id(*)(id,SEL,id))objc_msgSend)(o,s,a);
}

static NSString *Stringify(id obj) {
    if (!obj || obj == [NSNull null]) return nil;
    @try {
        if ([obj isKindOfClass:[NSString class]]) return obj;
        return [obj description];
    } @catch (...) {
        return nil;
    }
}

/* -------------------- 音色 -------------------- */

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

/* -------------------- 当前聊天对象，只读 -------------------- */

static id FindIvar(id obj, const char *name) {
    if (!obj) return nil;
    Class c = object_getClass(obj);
    while (c) {
        Ivar iv = class_getInstanceVariable(c, name);
        if (iv) {
            @try { return object_getIvar(obj, iv); }
            @catch (...) { return nil; }
        }
        c = class_getSuperclass(c);
    }
    return nil;
}

static NSString *PeerFromVC(id vc) {
    if (!vc) return nil;

    const char *direct[] = {
        "m_nsChatUsername", "m_nsToUsr",
        "chatContactUsername", "contactUserName",
        "m_username", "username"
    };

    for (NSUInteger i=0; i<sizeof(direct)/sizeof(direct[0]); i++) {
        id v = FindIvar(vc, direct[i]);
        NSString *s = Stringify(v);
        if (s.length) return s;
    }

    const char *contacts[] = {
        "m_contact", "m_oContact", "m_chatContact",
        "contact", "_contact"
    };

    for (NSUInteger i=0; i<sizeof(contacts)/sizeof(contacts[0]); i++) {
        id c = FindIvar(vc, contacts[i]);
        if (!c) continue;

        const char *names[] = {
            "m_nsUsrName", "m_nsUserName", "nsUsrName",
            "m_nsChatUsername", "m_nsToUsr"
        };

        for (NSUInteger j=0; j<sizeof(names)/sizeof(names[0]); j++) {
            id v = FindIvar(c, names[j]);
            NSString *s = Stringify(v);
            if (s.length) return s;
        }
    }

    return nil;
}


// v4: 当前聊天对象改为从微信真实录音链获取。
// hook_wechat_voice.js 的实际链路显示：
// RecordController -StartRecordingFromUsr:ToUsr:UserInfo:
// 其中 ToUsr 就是当前聊天对象 username。
// 这里只被动捕获真实录音时传入的 ToUsr，不主动启动录音、不修改原录音逻辑。

static NSString *g_lastRecordToUser = nil;
static NSString *g_lastRecordFromUser = nil;

static NSString *TTSStringFromObject(id obj) {
    if (!obj || obj == (id)[NSNull null]) return nil;
    if ([obj isKindOfClass:[NSString class]]) return (NSString *)obj;
    NSString *s = [obj description];
    return (s.length > 0 && s.length < 512) ? s : nil;
}

static void TTSInstallRecordControllerCapture(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class cls = NSClassFromString(@"RecordController");
        SEL sel = NSSelectorFromString(@"StartRecordingFromUsr:ToUsr:UserInfo:");

        if (!cls || ![cls instancesRespondToSelector:sel]) {
            NSLog(@"[TTSFloat v4] RecordController selector not found");
            return;
        }

        Method method = class_getInstanceMethod(cls, sel);
        if (!method) return;

        IMP oldIMP = method_getImplementation(method);

        id block = ^(id selfObj, id fromUsr, id toUsr, id userInfo) {
            NSString *from = TTSStringFromObject(fromUsr);
            NSString *to   = TTSStringFromObject(toUsr);

            @synchronized ([NSObject class]) {
                g_lastRecordFromUser = [from copy];
                g_lastRecordToUser = [to copy];
            }

            NSLog(@"[TTSFloat v4] RecordController: FromUsr=%@ ToUsr=%@",
                  from ?: @"(nil)", to ?: @"(nil)");

            typedef void (*OrigIMP)(id, SEL, id, id, id);
            ((OrigIMP)oldIMP)(selfObj, sel, fromUsr, toUsr, userInfo);
        };

        method_setImplementation(method, imp_implementationWithBlock(block));
        NSLog(@"[TTSFloat v4] installed RecordController ToUsr capture");
    });
}

static NSString *CurrentChatUser(void) {
    TTSInstallRecordControllerCapture();

    @synchronized ([NSObject class]) {
        if (g_lastRecordToUser.length > 0) {
            return [g_lastRecordToUser copy];
        }
    }

    // 备用：只读取少量 KVC 键。
    Class vcClass = NSClassFromString(@"BaseMsgContentViewController");
    if (!vcClass) return nil;

    for (UIWindow *window in [UIApplication sharedApplication].windows) {
        UIViewController *root = window.rootViewController;
        if (!root) continue;

        NSMutableArray *stack = [NSMutableArray arrayWithObject:root];

        while (stack.count) {
            UIViewController *cur = stack.lastObject;
            [stack removeLastObject];

            if ([cur isKindOfClass:vcClass]) {
                for (NSString *key in @[
                    @"m_username",
                    @"username",
                    @"m_nsChatName",
                    @"nsChatName"
                ]) {
                    @try {
                        id value = [cur valueForKey:key];
                        NSString *s = TTSStringFromObject(value);
                        if (s.length > 0 && ![s containsString:@"<"]) {
                            return s;
                        }
                    } @catch (__unused NSException *e) {}
                }
            }

            if (cur.presentedViewController) {
                [stack addObject:cur.presentedViewController];
            }
            for (UIViewController *child in cur.childViewControllers) {
                [stack addObject:child];
            }
        }
    }

    return nil;
}

static NSString *TTSLastRecordFromUser(void) {
    @synchronized ([NSObject class]) {
        return [g_lastRecordFromUser copy];
    }
}


static void RequestTTS(NSString *text,
                       NSString *voice,
                       void (^done)(NSData *audioData, NSError *error)) {

    NSString *urlString =
        [NSString stringWithFormat:@"%@?text=%@&voice=%@&apikey=%@",
         K_TTS_ENDPOINT,
         URLEncode(text ?: @""),
         URLEncode(voice ?: K_DEFAULT_VOICE),
         URLEncode(TiaxKey() ?: @"")];

    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        NSError *e = [NSError errorWithDomain:@"TTSFloat_v3"
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey:@"TTS URL 无效"}];
        done(nil,e);
        return;
    }

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"GET";
    req.timeoutInterval = 30;

    NSURLSessionDataTask *task =
    [NSURLSession.sharedSession dataTaskWithRequest:req
                                  completionHandler:^(NSData *data,
                                                      NSURLResponse *response,
                                                      NSError *error) {
        if (error) {
            done(nil,error);
            return;
        }

        if (!data.length) {
            NSError *e = [NSError errorWithDomain:@"TTSFloat_v3"
                                             code:2
                                         userInfo:@{NSLocalizedDescriptionKey:@"TTS API 返回为空"}];
            done(nil,e);
            return;
        }

        NSError *jsonError = nil;
        id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];

        if ([json isKindOfClass:[NSDictionary class]]) {
            NSString *audioURL = Stringify(json[@"url"]);
            if (audioURL.length) {
                NSURL *audioURLObj = [NSURL URLWithString:audioURL];
                if (!audioURLObj) {
                    NSError *e = [NSError errorWithDomain:@"TTSFloat_v3"
                                                     code:3
                                                 userInfo:@{NSLocalizedDescriptionKey:@"API 返回的音频 URL 无效"}];
                    done(nil,e);
                    return;
                }

                NSURLSessionDataTask *download =
                [NSURLSession.sharedSession dataTaskWithURL:audioURLObj
                                          completionHandler:^(NSData *audio,
                                                              NSURLResponse *r,
                                                              NSError *err) {
                    if (err || !audio.length) {
                        NSError *e = err ?: [NSError errorWithDomain:@"TTSFloat_v3"
                                                                code:4
                                                            userInfo:@{NSLocalizedDescriptionKey:@"音频下载失败"}];
                        done(nil,e);
                    } else {
                        TLog(@"TTS 音频下载成功：%lu bytes",
                             (unsigned long)audio.length);
                        done(audio,nil);
                    }
                }];
                [download resume];
                return;
            }
        }

        /*
         * 兼容 API 直接返回 MP3/WAV 的情况。
         */
        if (!json && !jsonError) {
            done(data,nil);
            return;
        }

        /*
         * 如果不是 JSON，且看起来是音频，则直接交给解码器。
         */
        if (data.length >= 3) {
            const unsigned char *b = data.bytes;
            BOOL audioMagic =
                (b[0]=='I' && b[1]=='D' && b[2]=='3') ||
                (b[0]=='R' && b[1]=='I' && b[2]=='F' && b[3]=='F');

            if (audioMagic) {
                done(data,nil);
                return;
            }
        }

        NSError *e = [NSError errorWithDomain:@"TTSFloat_v3"
                                         code:5
                                     userInfo:@{NSLocalizedDescriptionKey:@"无法识别 TTS API 返回格式"}];
        done(nil,e);
    }];
    [task resume];
}

/* -------------------- MP3/WAV -> PCM -------------------- */

static NSData *DecodeToPCM(NSData *audioData, NSError **outError) {
    if (!audioData.length) return nil;

    NSString *path =
        [NSTemporaryDirectory()
         stringByAppendingPathComponent:
         [NSString stringWithFormat:@"tts_%@.audio",
          NSUUID.UUID.UUIDString]];

    if (![audioData writeToFile:path options:NSDataWritingAtomic error:outError])
        return nil;

    AVAudioFile *file =
        [[AVAudioFile alloc] initForReading:[NSURL fileURLWithPath:path]
                                      error:outError];

    if (!file) {
        [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
        return nil;
    }

    AVAudioFormat *src = file.processingFormat;

    /*
     * Silk 编码前统一成：
     *   16000 Hz
     *   mono
     *   Int16
     *   interleaved
     */
    AVAudioFormat *dst =
        [[AVAudioFormat alloc]
         initCommonFormat:AVAudioPCMFormatInt16
         sampleRate:16000
         channels:1
         interleaved:YES];

    AVAudioConverter *converter =
        [[AVAudioConverter alloc] initFromFormat:src toFormat:dst];

    if (!converter) {
        [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
        if (outError)
            *outError = [NSError errorWithDomain:@"TTSFloat_v3"
                                            code:10
                                        userInfo:@{NSLocalizedDescriptionKey:
                                                       @"AVAudioConverter 创建失败"}];
        return nil;
    }

    NSMutableData *pcm = [NSMutableData data];

    while (file.framePosition < file.length) {
        AVAudioFrameCount remain =
            (AVAudioFrameCount)(file.length - file.framePosition);
        AVAudioFrameCount inFrames = MIN(remain, 4096);

        AVAudioPCMBuffer *inBuffer =
            [[AVAudioPCMBuffer alloc]
             initWithPCMFormat:src
             frameCapacity:inFrames];

        if (![file readIntoBuffer:inBuffer error:outError])
            break;

        AVAudioPCMBuffer *outBuffer =
            [[AVAudioPCMBuffer alloc]
             initWithPCMFormat:dst
             frameCapacity:8192];

        __block BOOL supplied = NO;
        NSError *convertError = nil;

        AVAudioConverterOutputStatus status =
        [converter convertToBuffer:outBuffer
                             error:&convertError
                withInputFromBlock:^AVAudioBuffer *
                 (AVAudioPacketCount packets,
                  AVAudioConverterInputStatus *inputStatus) {

            if (supplied) {
                *inputStatus = AVAudioConverterInputStatus_NoDataNow;
                return nil;
            }

            supplied = YES;
            *inputStatus = AVAudioConverterInputStatus_HaveData;
            return inBuffer;
        }];

        if (status == AVAudioConverterOutputStatus_Error || convertError) {
            if (outError) *outError = convertError;
            [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
            return nil;
        }

        if (outBuffer.frameLength &&
            outBuffer.int16ChannelData) {

            NSUInteger bytes =
                outBuffer.frameLength *
                dst.streamDescription->mBytesPerFrame;

            [pcm appendBytes:outBuffer.int16ChannelData[0]
                      length:bytes];
        }
    }

    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];

    if (!pcm.length) {
        if (outError)
            *outError = [NSError errorWithDomain:@"TTSFloat_v3"
                                            code:11
                                        userInfo:@{NSLocalizedDescriptionKey:
                                                       @"PCM 解码结果为空"}];
        return nil;
    }

    TLog(@"PCM 解码成功：%lu bytes",
         (unsigned long)pcm.length);

    return pcm;
}

/* -------------------- PCM -> Silk -------------------- */

static NSData *EncodeSilk(NSData *pcm, NSError **outError) {
    Class cls = NSClassFromString(@"MJSilkCodec");
    if (!cls) {
        if (outError)
            *outError = [NSError errorWithDomain:@"TTSFloat_v3"
                                            code:20
                                        userInfo:@{NSLocalizedDescriptionKey:
                                                       @"找不到 MJSilkCodec"}];
        return nil;
    }

    id codec = [cls new];
    SEL sel = NSSelectorFromString(@"encodeFromPCMData:");

    if (![codec respondsToSelector:sel]) {
        if (outError)
            *outError = [NSError errorWithDomain:@"TTSFloat_v3"
                                            code:21
                                        userInfo:@{NSLocalizedDescriptionKey:
                                                       @"当前微信没有 encodeFromPCMData:"}];
        return nil;
    }

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    NSData *silk = [codec performSelector:sel withObject:pcm];
#pragma clang diagnostic pop

    if (![silk isKindOfClass:[NSData class]] || !silk.length) {
        if (outError)
            *outError = [NSError errorWithDomain:@"TTSFloat_v3"
                                            code:22
                                        userInfo:@{NSLocalizedDescriptionKey:
                                                       @"Silk 编码失败"}];
        return nil;
    }

    TLog(@"Silk 编码成功：%lu bytes",
         (unsigned long)silk.length);

    return silk;
}

/* -------------------- UI -------------------- */

@interface TTSPassWindow : UIWindow
@end

@implementation TTSPassWindow
- (UIView *)hitTest:(CGPoint)p withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:p withEvent:event];
    if (hit == self || hit == self.rootViewController.view)
        return nil;
    return hit;
}
@end

@interface TTSRootController : UIViewController
@end

@implementation TTSRootController
- (BOOL)prefersStatusBarHidden { return YES; }
@end

@interface TTSFloatView : UIView
@property(nonatomic,strong) UIView *panel;
@property(nonatomic,strong) UITextView *input;
@property(nonatomic,strong) UIButton *send;
@property(nonatomic,strong) UILabel *voiceLabel;
@property(nonatomic,strong) UILabel *statusLabel;
@property(nonatomic,strong) UISwitch *enableSwitch;
@property(nonatomic,strong) UIActivityIndicatorView *spinner;
@property(nonatomic) NSInteger voiceIndex;
@end

@implementation TTSFloatView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;

    self.backgroundColor =
        [UIColor colorWithWhite:0.08 alpha:0.92];

    self.layer.cornerRadius = 28;
    self.layer.masksToBounds = YES;
    self.userInteractionEnabled = YES;

    self.voiceIndex = 0;

    UILabel *icon =
        [[UILabel alloc] initWithFrame:CGRectMake(0,0,56,56)];
    icon.text = @"🎙️";
    icon.font = [UIFont systemFontOfSize:26];
    icon.textAlignment = NSTextAlignmentCenter;
    [self addSubview:icon];

    UITapGestureRecognizer *tap =
        [[UITapGestureRecognizer alloc]
         initWithTarget:self action:@selector(togglePanel)];
    [self addGestureRecognizer:tap];

    UIPanGestureRecognizer *pan =
        [[UIPanGestureRecognizer alloc]
         initWithTarget:self action:@selector(drag:)];
    [self addGestureRecognizer:pan];

    return self;
}

- (void)drag:(UIPanGestureRecognizer *)g {
    static CGPoint start;
    if (g.state == UIGestureRecognizerStateBegan)
        start = self.center;

    if (g.state == UIGestureRecognizerStateChanged) {
        CGPoint t = [g translationInView:self.superview];
        self.center =
            CGPointMake(start.x+t.x, start.y+t.y);
    }
}

- (void)togglePanel {
    if (self.panel) {
        [self.panel removeFromSuperview];
        self.panel = nil;
        return;
    }

    CGFloat w = 300;
    CGFloat h = 250;

    CGRect screen =
        UIScreen.mainScreen.bounds;

    UIView *panel =
        [[UIView alloc]
         initWithFrame:CGRectMake(
             MAX(10, CGRectGetMidX(screen)-w/2),
             MAX(50, CGRectGetMidY(screen)-h/2),
             w,h)];

    panel.backgroundColor =
        [UIColor colorWithWhite:0.08 alpha:0.94];

    panel.layer.cornerRadius = 18;
    panel.layer.masksToBounds = YES;
    self.panel = panel;

    UILabel *title =
        [[UILabel alloc] initWithFrame:CGRectMake(16,10,180,28)];
    title.text = @"🔊 文字转语音";
    title.textColor = UIColor.whiteColor;
    title.font = [UIFont boldSystemFontOfSize:16];
    [panel addSubview:title];

    self.enableSwitch =
        [[UISwitch alloc] initWithFrame:CGRectMake(245,8,45,30)];
    self.enableSwitch.on = YES;
    [panel addSubview:self.enableSwitch];

    UILabel *voiceTitle =
        [[UILabel alloc] initWithFrame:CGRectMake(16,45,70,30)];
    voiceTitle.text = @"音色";
    voiceTitle.textColor = UIColor.whiteColor;
    [panel addSubview:voiceTitle];

    UIButton *prev =
        [UIButton buttonWithType:UIButtonTypeSystem];
    prev.frame = CGRectMake(75,43,38,34);
    [prev setTitle:@"◀" forState:UIControlStateNormal];
    [prev setTitleColor:UIColor.whiteColor
              forState:UIControlStateNormal];
    [prev addTarget:self
             action:@selector(prevVoice)
   forControlEvents:UIControlEventTouchUpInside];
    [panel addSubview:prev];

    self.voiceLabel =
        [[UILabel alloc] initWithFrame:CGRectMake(113,43,105,34)];
    self.voiceLabel.text =
        VoiceList()[self.voiceIndex];
    self.voiceLabel.textColor = UIColor.whiteColor;
    self.voiceLabel.textAlignment = NSTextAlignmentCenter;
    self.voiceLabel.font =
        [UIFont boldSystemFontOfSize:14];
    [panel addSubview:self.voiceLabel];

    UIButton *next =
        [UIButton buttonWithType:UIButtonTypeSystem];
    next.frame = CGRectMake(220,43,38,34);
    [next setTitle:@"▶" forState:UIControlStateNormal];
    [next setTitleColor:UIColor.whiteColor
              forState:UIControlStateNormal];
    [next addTarget:self
             action:@selector(nextVoice)
   forControlEvents:UIControlEventTouchUpInside];
    [panel addSubview:next];

    self.input =
        [[UITextView alloc]
         initWithFrame:CGRectMake(12,82,276,92)];

    self.input.backgroundColor =
        [UIColor colorWithWhite:0.16 alpha:1];
    self.input.textColor = UIColor.whiteColor;
    self.input.font =
        [UIFont systemFontOfSize:15];
    self.input.layer.cornerRadius = 10;
    self.input.text = @"";
    [panel addSubview:self.input];

    self.send =
        [UIButton buttonWithType:UIButtonTypeSystem];
    self.send.frame =
        CGRectMake(12,181,276,40);
    self.send.backgroundColor =
        [UIColor colorWithRed:.12
                         green:.57
                          blue:.96
                         alpha:1];
    self.send.layer.cornerRadius = 9;
    [self.send setTitle:@"生成语音"
               forState:UIControlStateNormal];
    [self.send setTitleColor:UIColor.whiteColor
                    forState:UIControlStateNormal];
    self.send.titleLabel.font =
        [UIFont boldSystemFontOfSize:15];
    [self.send addTarget:self
                  action:@selector(generate)
        forControlEvents:UIControlEventTouchUpInside];
    [panel addSubview:self.send];

    self.statusLabel =
        [[UILabel alloc]
         initWithFrame:CGRectMake(12,222,276,20)];
    self.statusLabel.text =
        @"等待输入";
    self.statusLabel.textColor =
        [UIColor colorWithWhite:.75 alpha:1];
    self.statusLabel.font =
        [UIFont systemFontOfSize:11];
    self.statusLabel.textAlignment =
        NSTextAlignmentCenter;
    [panel addSubview:self.statusLabel];

    self.spinner =
        [[UIActivityIndicatorView alloc]
         initWithActivityIndicatorStyle:
         UIActivityIndicatorViewStyleMedium];
    self.spinner.center =
        CGPointMake(282,202);
    [panel addSubview:self.spinner];

    UIView *host = self.superview;
    if (host) [host addSubview:panel];

    [self.input becomeFirstResponder];
}

- (void)prevVoice {
    NSArray *list = VoiceList();
    self.voiceIndex =
        (self.voiceIndex <= 0)
        ? list.count-1
        : self.voiceIndex-1;

    g_voiceName = list[self.voiceIndex];
    self.voiceLabel.text = g_voiceName;
}

- (void)nextVoice {
    NSArray *list = VoiceList();
    self.voiceIndex =
        (self.voiceIndex+1 >= list.count)
        ? 0
        : self.voiceIndex+1;

    g_voiceName = list[self.voiceIndex];
    self.voiceLabel.text = g_voiceName;
}

- (void)generate {
    if (!self.enableSwitch.isOn) {
        self.statusLabel.text = @"功能开关已关闭";
        return;
    }

    NSString *text = self.input.text;
    if (!text.length) {
        self.statusLabel.text = @"请输入文字";
        return;
    }

    NSString *peer = CurrentChatUser();
    if (!peer.length) {
        self.statusLabel.text =
            @"未找到当前聊天";
        return;
    }

    self.send.enabled = NO;
    self.statusLabel.text = @"正在合成…";
    [self.spinner startAnimating];

    NSString *voice = g_voiceName ?: K_DEFAULT_VOICE;

    __weak typeof(self) weakSelf = self;

    RequestTTS(text, voice,
      ^(NSData *audio, NSError *error) {

        if (error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) self = weakSelf;
                if (!self) return;

                self.send.enabled = YES;
                [self.spinner stopAnimating];
                self.statusLabel.text =
                    [NSString stringWithFormat:@"TTS失败：%@",
                     error.localizedDescription];
            });
            return;
        }

        dispatch_async(
          dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{

            NSError *decodeError = nil;
            NSData *pcm =
                DecodeToPCM(audio,&decodeError);

            if (!pcm) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    __strong typeof(weakSelf) self = weakSelf;
                    if (!self) return;

                    self.send.enabled = YES;
                    [self.spinner stopAnimating];
                    self.statusLabel.text =
                        [NSString stringWithFormat:@"PCM失败：%@",
                         decodeError.localizedDescription];
                });
                return;
            }

            NSError *silkError = nil;
            NSData *silk =
                EncodeSilk(pcm,&silkError);

            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) self = weakSelf;
                if (!self) return;

                self.send.enabled = YES;
                [self.spinner stopAnimating];

                if (!silk) {
                    self.statusLabel.text =
                        [NSString stringWithFormat:@"Silk失败：%@",
                         silkError.localizedDescription];
                    return;
                }

                /*
                 * v3 安全模式：
                 * Silk 已生成，但这里不调用未经验证的 CMessageMgr
                 * 外发 selector。
                 *
                 * 这样可以先确认：
                 *   TTS -> MP3 -> PCM -> Silk
                 * 全链路正常。
                 */
                TLog(@"生成完成 peer=%@ silk=%lu bytes",
                     peer,(unsigned long)silk.length);

                self.statusLabel.text =
                    [NSString stringWithFormat:
                     @"✅ Silk生成成功 %lu B（未自动发送）",
                     (unsigned long)silk.length];

                [self.input resignFirstResponder];
            });
        });
    });
}

@end

/* -------------------- 启动 -------------------- */

@interface TTSBootstrap : NSObject
@end

@implementation TTSBootstrap

+ (void)load {
    [[NSNotificationCenter defaultCenter]
     addObserver:[self new]
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

- (void)show:(NSTimer *)timer {
    if (g_ttsWindow) return;

    CGRect r = UIScreen.mainScreen.bounds;

    g_ttsWindow =
        [[TTSPassWindow alloc] initWithFrame:r];

    g_ttsWindow.backgroundColor = UIColor.clearColor;
    g_ttsWindow.windowLevel =
        UIWindowLevelAlert + 100;
    g_ttsWindow.userInteractionEnabled = YES;

    TTSRootController *root =
        [TTSRootController new];

    g_ttsWindow.rootViewController = root;

    UIView *host = root.view;
    host.backgroundColor = UIColor.clearColor;

    TTSFloatView *ball =
        [[TTSFloatView alloc]
         initWithFrame:CGRectMake(
             r.size.width-72,
             r.size.height*.42,
             56,56)];

    [host addSubview:ball];

    [g_ttsWindow makeKeyAndVisible];
    g_ttsWindow.hidden = NO;

    TLog(@"===== TTSFloat_v3 loaded =====");
    TLog(@"MJSilkCodec=%@",
         NSClassFromString(@"MJSilkCodec") ? @"YES" : @"NO");
    TLog(@"encodeFromPCMData=%@",
         [NSClassFromString(@"MJSilkCodec")
          instancesRespondToSelector:
          NSSelectorFromString(@"encodeFromPCMData:")]
         ? @"YES" : @"NO");
}

@end
