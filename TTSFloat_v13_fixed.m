/*
 * TTSFloat_v11_fixed.m — 微信文字转语音插件 最终版
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
 *     -o TTSFloat_v10.dylib TTSFloat_v11_fixed.m
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
#define K_APIKEY_BUILTIN @"86306ba1cf8d50b2866c8369a14b384fe1ff96900ca822d98bd35274e87b0635"

/* PCM 目标采样率（运行时按微信 silk 配置更新） */
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

/* ==================== 当前聊天对象捕获（v8b 验证） ==================== */
static NSString *g_lastToUsr = nil;
static id g_audioSender = nil;   /* prepareSend 的 self 就是 AudioSender 实例，直接存 */
static id g_lastUserData = nil;  /* prepareSend 的 arg：AudioRecorderUserData（完整对象） */

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
                    /* self 就是 AudioSender 实例；arg 是 AudioRecorderUserData — 全存 */
                    @synchronized([NSObject class]) {
                        if (g_audioSender != self) g_audioSender = self;
                        if (arg && g_lastUserData != arg) g_lastUserData = arg;
                    }
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

/* 兜底：从 VC KVC 找（若 prepareSend 捕获还没触发，实时抓一次） */
static NSString *CurrentChatUser(void) {
    InstallPrepareSendCapture();
    @synchronized([NSObject class]) {
        if (g_lastToUsr.length > 0) return [g_lastToUsr copy];
    }

    /* 兜底：遍历 VC 树，BaseMsgContentViewController 上 KVC 探测 */
    Class chatCls = NSClassFromString(@"BaseMsgContentViewController");
    if (!chatCls) return nil;
    for (UIWindow *w in UIApplication.sharedApplication.windows) {
        UIViewController *root = w.rootViewController;
        if (!root) continue;
        NSMutableArray *stack = [NSMutableArray arrayWithObject:root];
        while (stack.count) {
            UIViewController *vc = stack.lastObject;
            [stack removeLastObject];
            if (!vc) continue;
            if ([vc isKindOfClass:chatCls]) {
                for (NSString *key in @[@"m_nsChatUsername", @"m_username", @"m_nsChatName", @"username"]) {
                    @try {
                        id v = [vc valueForKey:key];
                        if ([v isKindOfClass:[NSString class]] && [(NSString *)v length] > 0
                            && ![(NSString *)v containsString:@"<"]) {
                            TTLog(@"[fallback] VC %@ %@=%@", NSStringFromClass(vc.class), key, v);
                            return (NSString *)v;
                        }
                    } @catch (NSException *e) { }
                }
            }
            for (UIViewController *c in vc.childViewControllers) [stack addObject:c];
            if (vc.presentedViewController) [stack addObject:vc.presentedViewController];
            if ([vc isKindOfClass:[UINavigationController class]]) {
                UIViewController *vis = ((UINavigationController *)vc).visibleViewController;
                if (vis) [stack addObject:vis];
            }
        }
    }
    return nil;
}

/* ==================== 发送链（v9 验证） ==================== */

static void TTSProbeObjectMethods(id obj, NSString *tag) {
    if (!obj) {
        TTLog(@"[probe] %@ = nil", tag);
        return;
    }

    TTLog(@"[probe] %@ class=%@", tag, NSStringFromClass([obj class]));

    unsigned int count = 0;
    Method *methods = class_copyMethodList(object_getClass([obj class]), &count);
    for (unsigned int i = 0; i < count; i++) {
        SEL s = method_getName(methods[i]);
        NSString *name = NSStringFromSelector(s);
        if ([name containsString:@"encode"] ||
            [name containsString:@"silk"] ||
            [name containsString:@"Voice"] ||
            [name containsString:@"voice"] ||
            [name containsString:@"upload"] ||
            [name containsString:@"Upload"] ||
            [name containsString:@"send"] ||
            [name containsString:@"Send"] ||
            [name containsString:@"finish"] ||
            [name containsString:@"Finish"] ||
            [name containsString:@"complete"] ||
            [name containsString:@"Complete"]) {
            TTLog(@"[probe] %@ -> %@", tag, name);
        }
    }
    free(methods);
}

static void TTSProbeClassMethods(NSString *className) {
    Class cls = NSClassFromString(className);
    if (!cls) {
        TTLog(@"[probe] class %@ NOT FOUND", className);
        return;
    }

    TTLog(@"[probe] class %@ FOUND", className);

    unsigned int count = 0;
    Method *methods = class_copyMethodList(object_getClass(cls), &count);
    for (unsigned int i = 0; i < count; i++) {
        SEL s = method_getName(methods[i]);
        NSString *name = NSStringFromSelector(s);
        if ([name containsString:@"encode"] ||
            [name containsString:@"silk"] ||
            [name containsString:@"Voice"] ||
            [name containsString:@"voice"] ||
            [name containsString:@"upload"] ||
            [name containsString:@"Upload"] ||
            [name containsString:@"send"] ||
            [name containsString:@"Send"] ||
            [name containsString:@"finish"] ||
            [name containsString:@"Finish"] ||
            [name containsString:@"complete"] ||
            [name containsString:@"Complete"]) {
            TTLog(@"[probe] %@ -> %@", className, name);
        }
    }
    free(methods);
}


static void TTSProbeMethodSignature(Class cls, NSString *className, SEL sel) {
    if (!cls || !sel || ![cls instancesRespondToSelector:sel]) {
        TTLog(@"[silk-probe] %@ %@ NOT FOUND", className, NSStringFromSelector(sel));
        return;
    }
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    TTLog(@"[silk-probe] %@ %@ type=%s args=%lu return=%s",
          className,
          NSStringFromSelector(sel),
          method_getTypeEncoding(m),
          (unsigned long)method_getNumberOfArguments(m),
          method_copyReturnType(m));
}

static void TTSProbeSilkAPI(void) {
    Class cls = NSClassFromString(@"MJSilkCodec");
    if (!cls) {
        TTLog(@"[silk-probe] MJSilkCodec NOT FOUND");
        return;
    }
    TTSProbeMethodSignature(cls, @"MJSilkCodec",
                            NSSelectorFromString(@"encodeToSilkFromPCMData:"));
    TTSProbeMethodSignature(cls, @"MJSilkCodec",
                            NSSelectorFromString(@"encodeFromPCMData:"));
    TTSProbeMethodSignature(cls, @"MJSilkCodec",
                            NSSelectorFromString(@"encodeToSilkFromPCMData:sampleRate:"));
    TTSProbeMethodSignature(cls, @"MJSilkCodec",
                            NSSelectorFromString(@"encodeToSilkFromPCMData:sampleRate:channels:"));
}

static NSString *TTSSendVoice(NSData *pcmData, NSString *toUsr) {
    if (!pcmData.length || !toUsr.length) return @"数据为空";

    TTSProbeSilkAPI();

    /*
     * v13:
     * 先读取真实 ABI。只有在 encodeToSilkFromPCMData: 明确是
     * “self + _cmd + object” 且返回 Objective-C object 时才调用。
     * 不猜 sampleRate/channels 等额外参数，避免 ABI 崩溃。
     */
    Class silkCls = NSClassFromString(@"MJSilkCodec");
    SEL silkSel = NSSelectorFromString(@"encodeToSilkFromPCMData:");
    NSData *silkData = nil;

    if (silkCls && [silkCls instancesRespondToSelector:silkSel]) {
        Method sm = class_getInstanceMethod(silkCls, silkSel);
        const char *enc = sm ? method_getTypeEncoding(sm) : NULL;
        NSUInteger nargs = sm ? method_getNumberOfArguments(sm) : 0;

        TTLog(@"[silk] candidate encodeToSilkFromPCMData: type=%s args=%lu",
              enc ? enc : "(null)", (unsigned long)nargs);

        /*
         * 常见 ObjC 编码：
         * @24 表示返回 id、self/_cmd + 1 个对象参数。
         */
        BOOL safeOneObjectArg =
            enc &&
            nargs == 3 &&
            enc[0] == '@' &&
            (strstr(enc, "@24") != NULL || strstr(enc, "@16") != NULL);

        if (safeOneObjectArg) {
            id codec = nil;
            @try {
                codec = [[silkCls alloc] init];
            } @catch (__unused NSException *e) {}

            if (codec) {
                @try {
                    id result = ((id (*)(id, SEL, id))objc_msgSend)(codec, silkSel, pcmData);
                    if ([result isKindOfClass:[NSData class]] && [result length] > 0) {
                        silkData = result;
                        TTLog(@"[silk] encoded PCM=%lu -> Silk=%lu bytes",
                              (unsigned long)pcmData.length,
                              (unsigned long)silkData.length);
                    } else {
                        TTLog(@"[silk] encoder returned %@; no NSData output",
                              result ? NSStringFromClass([result class]) : @"nil");
                    }
                } @catch (NSException *e) {
                    TTLog(@"[silk] encoder exception: %@", e);
                }
            }
        } else {
            TTLog(@"[silk] signature is not the safe one-object form; NOT calling it");
        }
    }

    /* v12: 只做运行时探针，不猜测 MJSilkCodec 的签名，也不直接调用未知 ABI。 */
    TTSProbeClassMethods(@"MJSilkCodec");
    TTSProbeClassMethods(@"AudioSender");
    TTSProbeClassMethods(@"MMNewVoiceInputCacheLogic");

    id audioSender = nil;
    @synchronized([NSObject class]) {
        audioSender = g_audioSender;
    }

    if (!audioSender) {
        Class scCls = NSClassFromString(@"MMServiceCenter");
        if (scCls) {
            id center = nil;
            SEL dc = NSSelectorFromString(@"defaultCenter");
            if ([scCls respondsToSelector:dc])
                center = ((id (*)(id, SEL))objc_msgSend)(scCls, dc);
            if (!center) {
                SEL si = NSSelectorFromString(@"sharedInstance");
                if ([scCls respondsToSelector:si])
                    center = ((id (*)(id, SEL))objc_msgSend)(scCls, si);
            }
            if (center) {
                SEL gs = NSSelectorFromString(@"getService:");
                if ([center respondsToSelector:gs]) {
                    Class asCls = NSClassFromString(@"AudioSender");
                    if (asCls)
                        audioSender = ((id (*)(id, SEL, Class))objc_msgSend)(center, gs, asCls);
                }
            }
        }
    }
    if (!audioSender) return @"拿不到 AudioSender（先在聊天里按住说话一次）";

    id logic = nil;
    @try { logic = [audioSender valueForKey:@"transcacheLogic"]; } @catch (__unused NSException *e) {}
    if (!logic) return @"拿不到 transcacheLogic";

    TTLog(@"[send] sender=%@ logic=%@ class=%@", audioSender, logic, NSStringFromClass([logic class]));

    /* 采样率 */
    NSInteger silkSR = 0;
    @try {
        id v = [logic valueForKey:@"sampleRateForSilk"];
        if ([v isKindOfClass:[NSNumber class]]) silkSR = [v integerValue];
    } @catch (__unused NSException *e) {}
    if (!silkSR) {
        @try {
            id v = [audioSender valueForKey:@"sampleRateForSilk"];
            if ([v isKindOfClass:[NSNumber class]]) silkSR = [v integerValue];
        } @catch (__unused NSException *e) {}
    }
    if (!silkSR) silkSR = 16000;
    g_targetSampleRate = silkSR;

    /*
     * v10 的关键错误：
     * 1) endProcessVoiceData 是无参 selector，却按“带参数”调用，属于未定义行为；
     * 2) 同一 PCM 同时调用 processVoiceData: 和 processVoiceData:queueItem:，导致同一帧进入两次；
     * 3) 在真正喂 PCM 前就 endProcessVoiceData，生命周期顺序反了；
     * 4) 把 prepareSend: 返回 YES 当成“上传完成”。
     *
     * v11 只走一个 PCM 输入入口，并根据运行时真实存在的 selector
     * 选择 endProcessVoiceData: 或 endProcessVoiceData，绝不伪造参数。
     */

    SEL pvd = NSSelectorFromString(@"processVoiceData:");
    SEL pvdq = NSSelectorFromString(@"processVoiceData:queueItem:");
    SEL epd1 = NSSelectorFromString(@"endProcessVoiceData:");
    SEL epd0 = NSSelectorFromString(@"endProcessVoiceData");

    BOOL hasPVD  = [logic respondsToSelector:pvd];
    BOOL hasPVDQ = [logic respondsToSelector:pvdq];

    if (hasPVD) {
        Method m = class_getInstanceMethod([logic class], pvd);
        if (m) TTLog(@"[probe] processVoiceData: type=%s args=%lu",
                     method_getTypeEncoding(m), (unsigned long)method_getNumberOfArguments(m));
    }
    if (hasPVDQ) {
        Method m = class_getInstanceMethod([logic class], pvdq);
        if (m) TTLog(@"[probe] processVoiceData:queueItem: type=%s args=%lu",
                     method_getTypeEncoding(m), (unsigned long)method_getNumberOfArguments(m));
    }
    if ([logic respondsToSelector:epd0]) {
        Method m = class_getInstanceMethod([logic class], epd0);
        if (m) TTLog(@"[probe] endProcessVoiceData type=%s args=%lu",
                     method_getTypeEncoding(m), (unsigned long)method_getNumberOfArguments(m));
    }

    TTLog(@"[send] selectors pvd=%d pvdq=%d epd1=%d epd0=%d",
          hasPVD, hasPVDQ, [logic respondsToSelector:epd1], [logic respondsToSelector:epd0]);

    if (!hasPVD && !hasPVDQ)
        return @"transcacheLogic 没有可用的 PCM 输入接口";

    const NSUInteger CHUNK = 8000; /* 保持 v10 已验证的块大小 */
    const unsigned char *bytes = pcmData.bytes;
    NSUInteger total = pcmData.length;
    NSUInteger fed = 0;
    NSUInteger seq = 0;

    /*
     * 只选择一个入口。
     * 优先 queueItem 版本，因为它可以携带结束标志；
     * 如果运行时没有该接口，再退回单参数版本。
     */
    BOOL useQueueItem = hasPVDQ;
    Class itemCls = NSClassFromString(@"StreamInputQueueItem");

    @try {
        for (NSUInteger off = 0; off < total; off += CHUNK) {
            NSUInteger len = MIN(CHUNK, total - off);
            NSData *piece = [NSData dataWithBytes:bytes + off length:len];

            if (useQueueItem) {
                id item = nil;
                if (itemCls) {
                    item = [[itemCls alloc] init];
                    BOOL last = (off + len >= total);
                    @try { [item setValue:@(last ? 1 : 0) forKey:@"_endFlag"]; }
                    @catch (__unused NSException *e1) {
                        @try { [item setValue:@(last ? 1 : 0) forKey:@"endFlag"]; }
                        @catch (__unused NSException *e2) {}
                    }
                }

                /*
                 * 如果 queueItem 类存在，传 item。
                 * 如果类不存在，不再冒险把同一块 PCM 再调用 pvd:
                 * 直接退回单参数入口。
                 */
                if (item) {
                    void (*fn)(id, SEL, id, id) =
                        (void (*)(id, SEL, id, id))objc_msgSend;
                    fn(logic, pvdq, piece, item);
                } else if (hasPVD) {
                    void (*fn)(id, SEL, id) =
                        (void (*)(id, SEL, id))objc_msgSend;
                    fn(logic, pvd, piece);
                } else {
                    return @"queueItem 接口存在但 StreamInputQueueItem 不可用";
                }
            } else {
                void (*fn)(id, SEL, id) =
                    (void (*)(id, SEL, id))objc_msgSend;
                fn(logic, pvd, piece);
            }

            fed += len;
            seq++;
        }
    } @catch (NSException *e) {
        TTLog(@"[send] PCM输入异常: %@", e);
        return @"PCM输入异常";
    }

    TTLog(@"[send] PCM fed=%lu bytes chunks=%lu; silk=%lu bytes (encoder probe only)", (unsigned long)fed, (unsigned long)seq, (unsigned long)silkData.length);

    /*
     * 正确处理结束接口：
     * - endProcessVoiceData: 如果微信提供带 tousr 的版本，就传 tousr；
     * - 否则只调用无参版本。
     *
     * 绝不再出现“无参 selector + 多一个参数”的 v10 错误。
     */
    BOOL ended = NO;
    @try {
        if ([logic respondsToSelector:epd1]) {
            void (*fn)(id, SEL, id) =
                (void (*)(id, SEL, id))objc_msgSend;
            fn(logic, epd1, toUsr);
            ended = YES;
            TTLog(@"[send] endProcessVoiceData: done tousr=%@", toUsr);
        } else if ([logic respondsToSelector:epd0]) {
            void (*fn)(id, SEL) =
                (void (*)(id, SEL))objc_msgSend;
            fn(logic, epd0);
            ended = YES;
            TTLog(@"[send] endProcessVoiceData done");
        }
    } @catch (NSException *e) {
        TTLog(@"[send] endProcessVoiceData 异常: %@", e);
        return @"语音结束处理异常";
    }

    if (!ended)
        TTLog(@"[send] 未找到 endProcessVoiceData，继续检查 prepareSend");

    /*
     * prepareSend 只负责启动微信自己的发送流程。
     * 不再手工修改 receiveDataLength / lastLen / audioid 等内部状态，
     * 因为这些值必须和微信实际生成的音频缓存保持一致；v10 手工伪造
     * 这些字段正是“消息创建成功但一直转圈”的高风险来源。
     */
    id userData = nil;
    @synchronized([NSObject class]) {
        userData = g_lastUserData;
    }

    if (!userData)
        return @"没有捕获到 AudioRecorderUserData（先按住说话一次）";

    @try { [userData setValue:toUsr forKey:@"tousr"]; }
    @catch (__unused NSException *e) {}
    @try { [userData setValue:toUsr forKey:@"chatname"]; }
    @catch (__unused NSException *e) {}

    @try { TTLog(@"[probe] userData class=%@", NSStringFromClass([userData class])); } @catch (__unused NSException *e) {}
    for (NSString *key in @[@"audioid", @"lastLen", @"receiveDataLength", @"duration",
                            @"sampleRate", @"sampleRateForSilk", @"tousr", @"chatname"]) {
        @try {
            id v = [userData valueForKey:key];
            if (v) TTLog(@"[probe] userData.%@=%@", key, v);
        } @catch (__unused NSException *e) {}
    }

    SEL ps = NSSelectorFromString(@"prepareSend:");
    if (![audioSender respondsToSelector:ps])
        return @"AudioSender 没有 prepareSend:";

    Method psMethod = class_getInstanceMethod([audioSender class], ps);
    if (psMethod) {
        TTLog(@"[probe] prepareSend: type=%s args=%lu",
              method_getTypeEncoding(psMethod),
              (unsigned long)method_getNumberOfArguments(psMethod));
    }

    BOOL ok = NO;
    @try {
        BOOL (*fn)(id, SEL, id) = (BOOL (*)(id, SEL, id))objc_msgSend;
        ok = fn(audioSender, ps, userData);
    } @catch (NSException *e) {
        TTLog(@"[send] prepareSend 异常: %@", e);
        return @"prepareSend 调用异常";
    }

    TTLog(@"[send] prepareSend ret=%d", ok);

    if (!ok)
        return @"prepareSend 返回失败";

    /*
     * 这里不能宣称“服务器上传完成”。
     * prepareSend 返回成功只代表微信接受了发送任务。
     * v11 通过日志明确区分两者，避免 UI 假报成功。
     */
    TTLog(@"[send] prepareSend accepted; upload completion must be confirmed by WeChat callback/logs.");
    return nil;
}

/* ==================== TTS API ==================== */
static NSString *TiaxKey(void) {
    return K_APIKEY_BUILTIN;
}

static NSString *TTSEncode(NSString *s) {
    return [s stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
}

/* 检测数据是否是音频（mp3/wav 头），排除 CDN 404 返回的 JSON 错误文本 */
static BOOL TTSIsAudioData(NSData *d) {
    if (d.length < 4) return NO;
    const unsigned char *b = d.bytes;
    /* ID3 (mp3 tag) / RIFF (wav) / 0xFF 0xFx (mp3 frame) / ftyp (m4a) */
    if (b[0] == 'I' && b[1] == 'D' && b[2] == '3') return YES;
    if (b[0] == 'R' && b[1] == 'I' && b[2] == 'F' && b[3] == 'F') return YES;
    if (b[0] == 0xFF && (b[1] & 0xF0) == 0xF0) return YES;
    if (b[0] == 'f' && b[1] == 't' && b[2] == 'y' && b[3] == 'p') return YES;
    if (b[0] == '{') return NO; /* JSON 错误文本 */
    return NO;
}

static void TTSDownloadAudio(NSString *audioURL, void (^done)(NSData *audio, NSError *error)) {
    NSURL *u = [NSURL URLWithString:audioURL];
    if (!u) {
        done(nil, [NSError errorWithDomain:@"TTS" code:3 userInfo:@{NSLocalizedDescriptionKey:@"音频URL无效"}]);
        return;
    }
    NSURLSessionDataTask *task = [NSURLSession.sharedSession dataTaskWithURL:u
        completionHandler:^(NSData *audio, NSURLResponse *r2, NSError *e2) {
            if (e2 != nil) {
                done(nil, e2);
            } else if (audio.length == 0) {
                done(nil, [NSError errorWithDomain:@"TTS" code:3 userInfo:@{NSLocalizedDescriptionKey:@"音频下载为空"}]);
            } else if (!TTSIsAudioData(audio)) {
                /* CDN 404 会返回 JSON 错误文本（NoSuchKey）——视为下载失败 */
                NSString *body = [[NSString alloc] initWithData:[audio subdataWithRange:NSMakeRange(0, MIN(80, audio.length))]
                                                        encoding:NSUTF8StringEncoding];
                TTLog(@"[tts] CDN 无音频: %@", body);
                done(nil, [NSError errorWithDomain:@"TTS" code:7 userInfo:@{NSLocalizedDescriptionKey:@"CDN文件已过期(NoSuchKey)"}]);
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

/* 带重试的 TTS 请求：CDN 文件过期(NoSuchKey)时重试——第一次请求触发后端重新合成 */
static void RequestTTS(NSString *text, NSString *voice, void (^done)(NSData *audio, NSError *error)) {
    __block NSInteger attempt = 0;
    __block void (^retry)(NSData *, NSError *) = nil;
    retry = ^(NSData *audio, NSError *error) {
        attempt++;
        if (audio != nil) { done(audio, nil); return; }
        BOOL isCDNExpired = (error.code == 7);
        if (isCDNExpired && attempt < 3) {
            TTLog(@"[tts] 第%ld次失败(CDN过期)，重试…", (long)attempt);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                           dispatch_get_global_queue(0, 0), ^{
                RequestTTSOnce(text, voice, retry);
            });
            return;
        }
        done(nil, error);
    };
    RequestTTSOnce(text, voice, retry);
}

/* ==================== mp3 → PCM（目标采样率由微信 silk 配置决定） ==================== */
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
- (void)kbWillShow:(NSNotification *)n;
- (void)kbWillHide:(NSNotification *)n;
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

/* 键盘跟随：面板推到键盘上方，绝不挡发送按钮 */
- (void)kbWillShow:(NSNotification *)n {
    CGRect kb = [n.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    CGRect f = self.panel.frame;
    CGFloat maxY = kb.origin.y - 8;
    if (CGRectGetMaxY(f) > maxY) {
        f.origin.y = MAX(40, maxY - f.size.height);
        self.panel.frame = f;
    }
}

- (void)kbWillHide:(NSNotification *)n {
    CGRect f = self.panel.frame;
    if (f.origin.y < 80) {
        f.origin.y = 80;
        self.panel.frame = f;
    }
}

- (void)togglePanel {
    if (self.panel) { [self.panel removeFromSuperview]; self.panel = nil; return; }

    CGFloat w = 300, h = 250;
    CGRect sc = UIScreen.mainScreen.bounds;
    /* 面板放屏幕上部（键盘弹出也不会挡住发送按钮） */
    UIView *panel = [[UIView alloc] initWithFrame:CGRectMake(MAX(10, CGRectGetMidX(sc) - w / 2),
                                                              80, w, h)];
    panel.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.94];
    panel.layer.cornerRadius = 18;
    panel.layer.masksToBounds = YES;
    self.panel = panel;

    /* 键盘弹出时再往上让一点（保险） */
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(kbWillShow:)
                                                 name:UIKeyboardWillShowNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(kbWillHide:)
                                                 name:UIKeyboardWillHideNotification
                                               object:nil];

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
                TTLog(@"[final] prepareSend accepted for %@", peer);
                [self setStatusOnMain:@"✅ 已提交发送（等待微信上传）"];
                dispatch_async(dispatch_get_main_queue(), ^{ self.input.text = @""; });
            }
        });
    });
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

    TTLog(@"===== ball shown =====");
    TTLog(@"key: %@", TiaxKey().length ? @"已配置" : @"未配置");
    TTLog(@"MJSilkCodec encodeFromPCMData: %@",
          [NSClassFromString(@"MJSilkCodec") instancesRespondToSelector:NSSelectorFromString(@"encodeFromPCMData:")] ? @"YES" : @"NO");
}

@interface TTSBootstrap : NSObject
@end

@implementation TTSBootstrap
+ (void)load {
    /* 不依赖任何通知——直接延迟到主线程创建（constructor 时主队列还没跑起来） */
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        TTSShowBall();
        InstallPrepareSendCapture();
    });
}
@end

__attribute__((constructor))
static void TTSFloatV10Init(void) {
    g_logPath = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/TTSFloat.log"];
    TTLog(@"v11 fixed init");
}
