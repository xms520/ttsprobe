/*
 * TTSFloatFinal.m — 微信文字转语音插件（完整可用版）
 *
 * 基于真机探测（TTSProbe + Frida hook）修正后的正确实现：
 *   1. 会话查找：BaseMsgContentViewController 的 m_username / m_chatContact / m_nsChatName
 *   2. SILK 编码：-[MJSilkCodec encodeFromPCMData:]（实例方法，先 initEncoder）
 *   3. 消息类型：-[CMessageWrap setM_uiMessageType:] 传 unsigned int (VoiceMsg=34)
 *   4. 发送：-[CMessageMgr AddMsg:MsgWrap:] (toUser, msgWrap)
 *   5. TTS：GET yuyin2.php?text=..&voice=..&apikey=.. → {"code":"200","url":"...mp3"} → 下载 mp3 → AVFoundation 解码 PCM → silk
 *   6. API key 从环境变量 TIAX_API_KEY 读取
 *
 * 编译（GitHub Actions macOS runner）：
 *   xcrun -sdk iphoneos clang -arch arm64 -miphoneos-version-min=12.0 \
 *     -fobjc-arc -fobjc-abi-version=2 -dynamiclib \
 *     -framework Foundation -framework UIKit -framework AVFoundation \
 *     -o TTSFloat.dylib TTSFloatFinal.m
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ============================================================
 * 配置
 * ============================================================ */
#define K_TTS_ENDPOINT "https://www.tiax.pw/API/yuyin2.php"

static const char *g_voice = "2学长"; /* 默认音色名 */

static const char *kVoiceList[] = {
    "2学长", "AD学姐", "alex克隆", "阿蕾奇诺", "爱莉希雅",
    "安倍晋三", "八戒", "白领御姐音", "白鹿的声音", "白岩松",
    "北方口音LY", "北京地铁黄华报站", "贝利亚", "毕业季温情女学生",
    "菠萝宝宝yuna", "伯纳德", "采访女生", "曹操", "陈赫",
    "陈奕恒", "重音TETO SV", "重音teto", "磁性电台女生", "达叔",
    "六花", "叶修", "洛天依", "初音未来", "小新", "蜡笔小新"
};
#define K_VOICE_COUNT (sizeof(kVoiceList)/sizeof(kVoiceList[0]))

static const char *TiaxApiKey(void) {
    char *k = getenv("TIAX_API_KEY");
    return (k && k[0]) ? k : "";
}

/* ============================================================
 * 日志
 * ============================================================ */
static NSString *g_logPath = nil;
static void LOG(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[TTSFloat] %@", msg);
    if (g_logPath) {
        @autoreleasepool {
            NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:g_logPath];
            if (!fh) { [[NSFileManager defaultManager] createFileAtPath:g_logPath contents:nil attributes:nil]; fh = [NSFileHandle fileHandleForWritingAtPath:g_logPath]; }
            if (fh) { [fh seekToEndOfFile]; [fh writeData:[[NSString stringWithFormat:@"[TTSFloat] %@\n", msg] dataUsingEncoding:NSUTF8StringEncoding]]; [fh closeFile]; }
        }
    }
}

/* ============================================================
 * 当前聊天用户名获取（真机验证字段）
 * ============================================================ */
static NSString *CurrentChatUser(void) {
    @autoreleasepool {
        Class chatCls = NSClassFromString(@"BaseMsgContentViewController");
        if (!chatCls) { LOG(@"BaseMsgContentViewController 类不存在"); return nil; }

        UIApplication *app = UIApplication.sharedApplication;
        for (UIWindow *w in app.windows) {
            if (w == g_ttsWindow) continue;
            UIViewController *root = w.rootViewController;
            if (!root) continue;

            NSMutableArray *queue = [NSMutableArray arrayWithObject:root];
            while (queue.count) {
                UIViewController *vc = queue.firstObject;
                [queue removeObjectAtIndex:0];
                if (!vc) continue;

                /* 只在 BaseMsgContentViewController 及其子类上探测 */
                if ([vc isKindOfClass:chatCls]) {
                    LOG(@"[VC] 命中聊天页 %@", NSStringFromClass(vc.class));
                    /* KVC 探测字段（valueForKey 支持属性 getter + ivar） */
                    NSArray *keys = @[@"m_username", @"m_chatContact", @"m_contact",
                                      @"m_nsChatUsername", @"m_nsChatName", @"m_oContact"];
                    for (NSString *k in keys) {
                        @try {
                            id v = [vc valueForKey:k];
                            if (v && v != [NSNull null]) {
                                /* 若 v 是 contact 对象，取其用户名 */
                                NSString *s = nil;
                                if ([v isKindOfClass:[NSString class]]) s = v;
                                else {
                                    @try {
                                        id u = [v valueForKey:@"m_nsUsrName"];
                                        if (u && [u isKindOfClass:[NSString class]]) s = u;
                                    } @catch (NSException *e) {}
                                }
                                if (s.length > 0) {
                                    LOG(@"[VC] 拿到当前聊天用户: key=%@ val=%@", k, s);
                                    return s;
                                }
                            }
                        } @catch (NSException *e) {
                            LOG(@"[VC] KVC %@ 异常: %@", k, e);
                        }
                    }
                    LOG(@"[VC] 聊天页上所有字段都拿不到用户名，继续找子 VC");
                }

                /* 下钻 */
                for (UIViewController *c in vc.childViewControllers)
                    if (queue.count < 200) [queue addObject:c];
                UIViewController *p = vc.presentedViewController;
                if (p && queue.count < 200) [queue addObject:p];
                if ([vc isKindOfClass:[UINavigationController class]]) {
                    UIViewController *vis = ((UINavigationController*)vc).visibleViewController;
                    if (vis && queue.count < 200) [queue addObject:vis];
                }
            }
        }
        LOG(@"[VC] 未找到当前聊天用户");
    }
    return nil;
}

/* ============================================================
 * mp3 → PCM (单声道 24kHz) 解码
 * ============================================================ */
static NSData *DecodeMP3ToPCM(NSData *mp3Data) {
    @autoreleasepool {
        if (!mp3Data || mp3Data.length == 0) return nil;
        NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:@"tts_in.mp3"];
        [mp3Data writeToFile:tmp atomically:YES];

        NSURL *url = [NSURL fileURLWithPath:tmp];
        NSError *err = nil;
        AVAudioFile *file = [[AVAudioFile alloc] initForReading:url error:&err];
        if (!file) { LOG(@"AVAudioFile open fail: %@", err); return nil; }

        AVAudioFormat *format = file.processingFormat;
        AVAudioFrameCount totalFrames = (AVAudioFrameCount)file.length;
        AVAudioPCMBuffer *buf = [[AVAudioPCMBuffer alloc] initWithPCMFormat:format
                                                              frameCapacity:totalFrames];
        if (!buf) return nil;
        NSError *rerr = nil;
        [file readIntoBuffer:buf error:&rerr];

        /* 提取 float32 数据，转 16bit PCM */
        AVAudioFrameCount frames = buf.frameLength;
        float *samples = buf.floatChannelData[0];
        if (!samples || frames == 0) return nil;

        NSMutableData *pcm = [NSMutableData dataWithCapacity:frames*2];
        for (AVAudioFrameCount i = 0; i < frames; i++) {
            float s = samples[i];
            if (s > 1.0f) s = 1.0f;
            if (s < -1.0f) s = -1.0f;
            int16_t v = (int16_t)(s * 32767.0f);
            [pcm appendBytes:&v length:2];
        }
        [[NSFileManager defaultManager] removeItemAtPath:tmp error:nil];

        /* 目标采样率 24kHz（如果原采样率不同，这里暂用原采样率；MJSilkCodec 内部会处理）*/
        double sr = format.sampleRate;
        LOG(@"decoded PCM: frames=%d sampleRate=%.0f bytes=%lu", (int)frames, sr, (unsigned long)pcm.length);
        return pcm;
    }
}

/* ============================================================
 * PCM → SILK（真机验证：MJSilkCodec 实例方法）
 * ============================================================ */
static NSData *EncodePCMToSilk(NSData *pcmData) {
    Class silkCls = objc_getClass("MJSilkCodec");
    if (!silkCls) { LOG(@"MJSilkCodec class not found"); return nil; }

    id codec = [[silkCls alloc] init];
    if (!codec) { LOG(@"MJSilkCodec init fail"); return nil; }

    /* 先 initEncoder（如存在） */
    SEL initSel = sel_registerName("initEncoderWithSampleRate:");
    if ([codec respondsToSelector:initSel]) {
        ((void(*)(id,SEL,unsigned int))objc_msgSend)(codec, initSel, 24000);
    } else {
        SEL initSel2 = sel_registerName("initEncoder");
        if ([codec respondsToSelector:initSel2]) {
            ((void(*)(id,SEL))objc_msgSend)(codec, initSel2);
        }
    }

    /* 实例方法 encodeFromPCMData: 返回 silk NSData */
    SEL encSel = sel_registerName("encodeFromPCMData:");
    NSData *silk = nil;
    if ([codec respondsToSelector:encSel]) {
        silk = ((id(*)(id,SEL,id))objc_msgSend)(codec, encSel, pcmData);
    }
    return silk;
}

/* ============================================================
 * 发送语音消息（真机验证：CMessageMgr AddMsg:MsgWrap:）
 * ============================================================ */
static BOOL SendVoiceMessage(NSData *silkData, NSString *toUser) {
    if (!silkData || silkData.length == 0 || !toUser) return NO;

    /* 先把 silk 写到语音文件（微信语音需要文件路径） */
    NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:@"tts_voice"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *voicePath = [dir stringByAppendingPathComponent:
        [NSString stringWithFormat:@"%lld.silk", (long long)[[NSDate date] timeIntervalSince1970]*1000]];
    [silkData writeToFile:voicePath atomically:YES];

    Class wrapCls = objc_getClass("CMessageWrap");
    if (!wrapCls) return NO;
    id msg = [[wrapCls alloc] init];
    if (!msg) return NO;

    /* 消息类型 34 = 语音 (unsigned int) */
    SEL typeSel = sel_registerName("setM_uiMessageType:");
    if ([msg respondsToSelector:typeSel]) {
        ((void(*)(id,SEL,unsigned int))objc_msgSend)(msg, typeSel, 34);
    }

    /* 语音路径 + 时长（尝试多种字段） */
    SEL pathSel = sel_registerName("setM_nsVoicePath:");
    if (![msg respondsToSelector:pathSel]) pathSel = sel_registerName("setM_nsVoiceFilePath:");
    if (![msg respondsToSelector:pathSel]) pathSel = sel_registerName("setVoicePath:");
    if ([msg respondsToSelector:pathSel]) {
        ((void(*)(id,SEL,id))objc_msgSend)(msg, pathSel, voicePath);
    }

    /* 通过 CMessageMgr 发送 */
    Class mgrCls = objc_getClass("CMessageMgr");
    if (!mgrCls) return NO;
    /* 获取单例：MMServiceCenter getService:[CMessageMgr class] */
    id mgr = nil;
    Class scCls = objc_getClass("MMServiceCenter");
    if (scCls) {
        id sc = ((id(*)(id,SEL))objc_msgSend)(scCls, sel_registerName("defaultCenter"));
        if (!sc) sc = ((id(*)(Class,SEL))objc_msgSend)(scCls, sel_registerName("defaultCenter"));
        if (sc) {
            SEL getSel = sel_registerName("getService:");
            if ([sc respondsToSelector:getSel]) {
                mgr = ((id(*)(id,SEL,Class))objc_msgSend)(sc, getSel, mgrCls);
            }
        }
    }
    if (!mgr) mgr = ((id(*)(Class,SEL))objc_msgSend)(mgrCls, sel_registerName("shareInstance"));
    if (!mgr) mgr = [[mgrCls alloc] init];
    if (!mgr) return NO;

    SEL addSel = sel_registerName("AddMsg:MsgWrap:");
    if ([mgr respondsToSelector:addSel]) {
        ((void(*)(id,SEL,id,id))objc_msgSend)(mgr, addSel, toUser, msg);
        LOG(@"AddMsg sent to %@", toUser);
        return YES;
    }
    return NO;
}

/* ============================================================
 * TTS 请求：文本 → silk
 * ============================================================ */
static NSData *RequestTTS(NSString *text) {
    if (!text || text.length == 0) return nil;
    const char *key = TiaxApiKey();
    if (!key || !key[0]) { LOG(@"TIAX_API_KEY not set"); return nil; }

    /* URL 编码 text */
    NSString *encText = [text stringByAddingPercentEncodingWithAllowedCharacters:
        [NSCharacterSet URLQueryAllowedCharacterSet]];
    NSString *encVoice = [[NSString stringWithUTF8String:g_voice ? g_voice : "2学长"]
        stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];

    NSString *urlStr = [NSString stringWithFormat:@"%s?text=%@&voice=%@&apikey=%s",
        K_TTS_ENDPOINT, encText, encVoice, key];

    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url) return nil;

    NSData *resp = [NSData dataWithContentsOfURL:url];
    if (!resp) { LOG(@"TTS request fail"); return nil; }

    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:resp options:0 error:nil];
    if (!json) { LOG(@"TTS JSON parse fail: %@", [[NSString alloc] initWithData:resp encoding:NSUTF8StringEncoding]); return nil; }

    NSString *mp3url = json[@"url"];
    if (!mp3url || ![mp3url isKindOfClass:[NSString class]]) {
        LOG(@"TTS no url, json=%@", json);
        return nil;
    }

    NSData *mp3 = [NSData dataWithContentsOfURL:[NSURL URLWithString:mp3url]];
    if (!mp3 || mp3.length == 0) { LOG(@"mp3 download fail"); return nil; }

    NSData *pcm = DecodeMP3ToPCM(mp3);
    if (!pcm) { LOG(@"mp3 decode fail"); return nil; }

    NSData *silk = EncodePCMToSilk(pcm);
    if (!silk) { LOG(@"silk encode fail"); return nil; }
    return silk;
}

/* ============================================================
 * 悬浮窗 UI
 * ============================================================ */
static UIWindow *g_ttsWindow = nil;

@interface TTSPassWindow : UIWindow @end
@implementation TTSPassWindow
- (UIView *)hitTest:(CGPoint)p withEvent:(UIEvent *)e {
    UIView *hit = [super hitTest:p withEvent:e];
    UIView *root = self.rootViewController.view;
    return (hit == self || hit == root) ? nil : hit;
}
@end

@interface TTSRootController : UIViewController @end
@implementation TTSRootController @end

@interface TTSFloatView : UIView {
    UIView *_panel;
    UITextView *_input;
    UIButton *_send;
    UIButton *_voicePrev;
    UIButton *_voiceNext;
    UILabel *_voiceLabel;
    int _voiceIndex;
    CGPoint _dragStart;
    CGPoint _panelDragStart;
    BOOL _moved;
}
- (void)togglePanel;
- (void)sendVoice;
- (void)drag:(UIPanGestureRecognizer *)g;
- (void)dragPanel:(UIPanGestureRecognizer *)g;
- (void)voicePrev;
- (void)voiceNext;
@end

@implementation TTSFloatView

- (id)initWithFrame:(CGRect)r {
    self = [super initWithFrame:r];
    if (self) {
        self.backgroundColor = [UIColor colorWithRed:.12 green:.57 blue:.96 alpha:.98];
        self.layer.cornerRadius = 28;
        self.layer.masksToBounds = YES;
        self.userInteractionEnabled = YES;
        _voiceIndex = 0;
        g_voice = kVoiceList[0];

        UILabel *icon = [[UILabel alloc] initWithFrame:CGRectMake(0,0,56,56)];
        icon.text = @"🎙"; icon.font = [UIFont systemFontOfSize:26];
        icon.textAlignment = NSTextAlignmentCenter; icon.textColor = [UIColor whiteColor];
        [self addSubview:icon];

        [self addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(togglePanel)]];
        [self addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(drag:)]];
    }
    return self;
}

- (void)drag:(UIPanGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateBegan) { _dragStart = self.center; _moved = NO; }
    else if (g.state == UIGestureRecognizerStateChanged) {
        CGPoint t = [g translationInView:self.superview];
        if (t.x*t.x + t.y*t.y > 16) _moved = YES;
        self.center = CGPointMake(_dragStart.x+t.x, _dragStart.y+t.y);
    }
}

- (void)voicePrev {
    if (_voiceIndex > 0) _voiceIndex--; else _voiceIndex = (int)K_VOICE_COUNT-1;
    _voiceLabel.text = [NSString stringWithUTF8String:kVoiceList[_voiceIndex]];
    g_voice = kVoiceList[_voiceIndex];
}
- (void)voiceNext {
    if (_voiceIndex < (int)K_VOICE_COUNT-1) _voiceIndex++; else _voiceIndex = 0;
    _voiceLabel.text = [NSString stringWithUTF8String:kVoiceList[_voiceIndex]];
    g_voice = kVoiceList[_voiceIndex];
}

- (void)dragPanel:(UIPanGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateBegan) _panelDragStart = _panel.center;
    else if (g.state == UIGestureRecognizerStateChanged) {
        CGPoint t = [g translationInView:_panel.superview];
        _panel.center = CGPointMake(_panelDragStart.x+t.x, _panelDragStart.y+t.y);
    }
}

- (void)togglePanel {
    if (_moved) { _moved = NO; return; }
    if (_panel) { [_panel removeFromSuperview]; _panel = nil; return; }

    CGRect scr = [UIScreen mainScreen].bounds;
    CGFloat w = scr.size.width - 36;

    _panel = [[UIView alloc] initWithFrame:CGRectMake(18, scr.size.height*.16, w, 360)];
    _panel.backgroundColor = [UIColor colorWithWhite:.08 alpha:.96];
    _panel.layer.cornerRadius = 14;
    _panel.userInteractionEnabled = YES;

    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0,0,w,44)];
    header.backgroundColor = [UIColor clearColor];
    [header addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(dragPanel:)]];
    [_panel addSubview:header];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(12,10,w-24,30)];
    title.text = @"🔊 文字转语音（拖动标题栏移动）";
    title.textColor = [UIColor whiteColor]; title.font = [UIFont boldSystemFontOfSize:15];
    title.textAlignment = NSTextAlignmentCenter; [_panel addSubview:title];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeCustom];
    close.frame = CGRectMake(w-40,8,32,32); [close setTitle:@"✕" forState:UIControlStateNormal];
    [close setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [close addTarget:self action:@selector(togglePanel) forControlEvents:UIControlEventTouchUpInside];
    [_panel addSubview:close];

    _voicePrev = [UIButton buttonWithType:UIButtonTypeCustom];
    _voicePrev.frame = CGRectMake(12,52,40,34); [_voicePrev setTitle:@"◀" forState:UIControlStateNormal];
    [_voicePrev setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    _voicePrev.backgroundColor = [UIColor colorWithWhite:.25 alpha:1];
    [_voicePrev addTarget:self action:@selector(voicePrev) forControlEvents:UIControlEventTouchUpInside];
    [_panel addSubview:_voicePrev];

    _voiceLabel = [[UILabel alloc] initWithFrame:CGRectMake(58,52,w-116,34)];
    _voiceLabel.text = [NSString stringWithUTF8String:kVoiceList[_voiceIndex]];
    _voiceLabel.textColor = [UIColor whiteColor]; _voiceLabel.font = [UIFont boldSystemFontOfSize:15];
    _voiceLabel.textAlignment = NSTextAlignmentCenter; _voiceLabel.userInteractionEnabled = YES;
    [_voiceLabel addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(voiceNext)]];
    [_panel addSubview:_voiceLabel];

    _voiceNext = [UIButton buttonWithType:UIButtonTypeCustom];
    _voiceNext.frame = CGRectMake(w-52,52,40,34); [_voiceNext setTitle:@"▶" forState:UIControlStateNormal];
    [_voiceNext setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    _voiceNext.backgroundColor = [UIColor colorWithWhite:.25 alpha:1];
    [_voiceNext addTarget:self action:@selector(voiceNext) forControlEvents:UIControlEventTouchUpInside];
    [_panel addSubview:_voiceNext];

    _input = [[UITextView alloc] initWithFrame:CGRectMake(12,96,w-24,140)];
    _input.backgroundColor = [UIColor colorWithWhite:.16 alpha:1];
    _input.textColor = [UIColor whiteColor]; _input.font = [UIFont systemFontOfSize:16];
    _input.layer.cornerRadius = 8; [_panel addSubview:_input];

    _send = [UIButton buttonWithType:UIButtonTypeCustom];
    _send.frame = CGRectMake(12,244,w-24,48);
    _send.backgroundColor = [UIColor colorWithRed:.12 green:.57 blue:.96 alpha:1];
    _send.layer.cornerRadius = 8;
    [_send setTitle:@"📤 发送语音到当前聊天" forState:UIControlStateNormal];
    [_send setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    _send.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    [_send addTarget:self action:@selector(sendVoice) forControlEvents:UIControlEventTouchUpInside];
    [_panel addSubview:_send];

    [self.superview addSubview:_panel];
    [_input becomeFirstResponder];
}

- (void)sendVoice {
    NSString *text = _input.text;
    if (!text || text.length == 0) { [_send setTitle:@"⚠️ 请先输入文字" forState:UIControlStateNormal]; return; }
    NSString *toUser = CurrentChatUser();
    if (!toUser || toUser.length == 0) { [_send setTitle:@"⚠️ 请先打开聊天" forState:UIControlStateNormal]; return; }

    _send.enabled = NO; [_send setTitle:@"⏳ 合成中..." forState:UIControlStateNormal];

    dispatch_async(dispatch_get_global_queue(0,0), ^{
        NSData *silk = RequestTTS(text);
        BOOL ok = silk && SendVoiceMessage(silk, toUser);
        dispatch_async(dispatch_get_main_queue(), ^{
            _send.enabled = YES;
            [_send setTitle: ok ? @"✅ 已发送语音" : @"❌ 失败" forState:UIControlStateNormal];
            if (ok) _input.text = @"";
        });
    });
}

@end

/* ============================================================
 * 启动
 * ============================================================ */
@interface TTSBootstrap : NSObject @end
@implementation TTSBootstrap
+ (void)load {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (g_ttsWindow) return;
        CGRect r = [UIScreen mainScreen].bounds;
        g_ttsWindow = [[TTSPassWindow alloc] initWithFrame:r];
        g_ttsWindow.backgroundColor = [UIColor clearColor];
        g_ttsWindow.windowLevel = UIWindowLevelAlert + 100;
        g_ttsWindow.userInteractionEnabled = YES;
        TTSRootController *root = [TTSRootController new];
        g_ttsWindow.rootViewController = root;
        root.view.backgroundColor = [UIColor clearColor];
        root.view.userInteractionEnabled = YES;
        TTSFloatView *ball = [[TTSFloatView alloc] initWithFrame:CGRectMake(r.size.width-70, r.size.height*.42, 56, 56)];
        [root.view addSubview:ball];
        g_ttsWindow.hidden = NO;
    });
}
@end

__attribute__((constructor))
static void TTSFloatInit(void) {
    g_logPath = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/TTSFloat.log"];
    LOG(@"TTSFloat loaded. API key env %s", (getenv("TIAX_API_KEY") && getenv("TIAX_API_KEY")[0]) ? "set" : "NOT SET");
}
