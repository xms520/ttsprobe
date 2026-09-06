/*
 * TTSFloat_v13_fixed.m — 微信文字转语音插件（修复录音会话和元数据问题）
 *
 * 修复内容：
 *   1. StartRecordFrom 传入真实的 BaseMsgContentViewController（不再传 nil）
 *   2. 发送前动态更新 userData 的 audioid（置 nil）、duration、receiveDataLength 等
 *   3. StopRecord 仅在录音会话成功启动后才调用
 *   4. 新增 CurrentChatViewController 辅助函数
 *
 * 编译命令（参考）：
 *   xcrun -sdk iphoneos clang -arch arm64 -miphoneos-version-min=12.0 \
 *     -fobjc-arc -dynamiclib \
 *     -framework Foundation -framework UIKit -framework AVFoundation -framework CoreGraphics \
 *     -o TTSFloat.dylib TTSFloat_v13_fixed.m
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

/* ==================== 获取当前聊天界面的 ViewController（关键修复） ==================== */
static UIViewController *CurrentChatViewController(void) {
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
                return vc;
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

/* ==================== 发送链（v9 验证，已修复） ==================== */

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

/* ==================== 修复后的 TTSSendVoice ==================== */
static NSString *TTSSendVoice(NSData *pcmData, NSString *toUsr) {
    if (!pcmData.length || !toUsr.length) return @"数据为空";

    /* 1. 获取 AudioSender 实例 */
    id audioSender0 = nil;
    @synchronized([NSObject class]) { audioSender0 = g_audioSender; }
    if (!audioSender0) return @"拿不到 AudioSender（先按住说话一次）";

    /* 2. 获取当前聊天界面的 ViewController（关键修复） */
    UIViewController *chatVC = CurrentChatViewController();
    if (!chatVC) {
        TTLog(@"[rec] 未找到 BaseMsgContentViewController，请停留在聊天界面");
        return @"未找到聊天视图，请打开聊天窗口";
    }
    TTLog(@"[rec] chatVC = %@", NSStringFromClass([chatVC class]));

    /* 3. 启动录音会话（传入真实 chatVC） */
    SEL canSel = NSSelectorFromString(@"CanStartRecordFrom:ToUser:");
    SEL startSel = NSSelectorFromString(@"StartRecordFrom:ToUser:UserInfo:");
    BOOL can = NO;
    @try {
        BOOL (*canFn)(id, SEL, id, id) = (BOOL (*)(id, SEL, id, id))objc_msgSend;
        can = canFn(audioSender0, canSel, chatVC, toUsr);
        TTLog(@"[rec] CanStartRecord ret=%d", can);
    } @catch (NSException *e) { TTLog(@"[rec] CanStartRecord 异常: %@", e); }

    if (!can) {
        TTLog(@"[rec] CanStartRecord=NO，尝试先 StopRecord 清场再启动");
        SEL stopSel = NSSelectorFromString(@"StopRecord");
        if ([audioSender0 respondsToSelector:stopSel]) {
            @try { ((void (*)(id, SEL))objc_msgSend)(audioSender0, stopSel); } @catch (NSException *e2) { }
        }
        @try {
            BOOL (*canFn)(id, SEL, id, id) = (BOOL (*)(id, SEL, id, id))objc_msgSend;
            can = canFn(audioSender0, canSel, chatVC, toUsr);
            TTLog(@"[rec] 二次 CanStartRecord ret=%d", can);
        } @catch (NSException *e3) { TTLog(@"[rec] 二次 CanStartRecord 异常: %@", e3); }
    }

    BOOL recording = NO;
    if (can && [audioSender0 respondsToSelector:startSel]) {
        @try {
            BOOL (*startFn)(id, SEL, id, id, id) = (BOOL (*)(id, SEL, id, id, id))objc_msgSend;
            recording = startFn(audioSender0, startSel, chatVC, toUsr, nil);
            TTLog(@"[rec] StartRecordFrom ret=%d", recording);
        } @catch (NSException *e) {
            TTLog(@"[rec] StartRecordFrom 异常: %@", e);
        }
    }
    if (!recording) {
        TTLog(@"[rec] 录音会话未启动，继续走缓存喂入路径（但可能会转圈）");
        // 注意：即使 recording==NO，我们仍然可以尝试喂数据，但后续 StopRecord 不应调用
    }

    /* 4. SILK 编码（保持原样） */
    TTSProbeSilkAPI();
    Class silkCls = NSClassFromString(@"MJSilkCodec");
    NSData *silkData = nil;
    NSArray *candidates = @[@"encodeToSilkFromPCMData:", @"encodeFromPCMData:"];
    for (NSString *selName in candidates) {
        SEL silkSel = NSSelectorFromString(selName);
        if (!(silkCls && [silkCls instancesRespondToSelector:silkSel])) continue;
        Method sm = class_getInstanceMethod(silkCls, silkSel);
        const char *enc = sm ? method_getTypeEncoding(sm) : NULL;
        NSUInteger nargs = sm ? method_getNumberOfArguments(sm) : 0;
        TTLog(@"[silk] candidate %@ type=%s args=%lu", selName, enc ? enc : "(null)", (unsigned long)nargs);
        BOOL safeOneObjectArg = enc && nargs == 3 && enc[0] == '@' &&
            (strstr(enc, "@24") != NULL || strstr(enc, "@16") != NULL);
        if (!safeOneObjectArg) {
            TTLog(@"[silk] %@ 非 1对象参数签名，跳过", selName);
            continue;
        }
        id codec = nil;
        @try { codec = [[silkCls alloc] init]; } @catch (__unused NSException *e) {}
        if (!codec) continue;
        SEL initSel = NSSelectorFromString(@"initEncoderWithSampleRate:");
        if ([codec respondsToSelector:initSel]) {
            @try {
                ((void (*)(id, SEL, NSInteger))objc_msgSend)(codec, initSel, (NSInteger)g_targetSampleRate);
                TTLog(@"[silk] initEncoderWithSampleRate:%ld done", (long)g_targetSampleRate);
            } @catch (NSException *e0) {
                @try {
                    ((id (*)(id, SEL, NSInteger))objc_msgSend)(codec, initSel, (NSInteger)g_targetSampleRate);
                    TTLog(@"[silk] initEncoder(ret-obj) done");
                } @catch (NSException *e1) {
                    TTLog(@"[silk] initEncoder 异常: %@", e1);
                }
            }
        } else {
            SEL initSel2 = NSSelectorFromString(@"initEncoder");
            if ([codec respondsToSelector:initSel2]) {
                @try { ((void (*)(id, SEL))objc_msgSend)(codec, initSel2); TTLog(@"[silk] initEncoder done"); }
                @catch (NSException *e2) { TTLog(@"[silk] initEncoder2 异常: %@", e2); }
            } else {
                TTLog(@"[silk] 无 initEncoder 方法");
            }
        }
        @try {
            id result = ((id (*)(id, SEL, id))objc_msgSend)(codec, silkSel, pcmData);
            if ([result isKindOfClass:[NSData class]] && [result length] > 0) {
                silkData = result;
                TTLog(@"[silk] encoded via %@ PCM=%lu -> Silk=%lu bytes", selName, (unsigned long)pcmData.length, (unsigned long)silkData.length);
                break;
            } else {
                TTLog(@"[silk] %@ 返回 %@（非NSData/空），试下一个", selName, result ? NSStringFromClass([result class]) : @"nil");
            }
        } @catch (NSException *e) {
            TTLog(@"[silk] %@ 异常: %@", selName, e);
        }
    }

    /* 5. 获取 AudioSender 和 transcacheLogic（保持原样） */
    id audioSender = nil;
    @synchronized([NSObject class]) { audioSender = g_audioSender; }
    if (!audioSender) {
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
                    Class asCls = NSClassFromString(@"AudioSender");
                    if (asCls) audioSender = ((id (*)(id, SEL, Class))objc_msgSend)(center, gs, asCls);
                }
            }
        }
    }
    if (!audioSender) return @"拿不到 AudioSender（先在聊天里按住说话一次）";

    id logic = nil;
    @try { logic = [audioSender valueForKey:@"transcacheLogic"]; } @catch (__unused NSException *e) {}
    if (!logic) return @"拿不到 transcacheLogic";
    TTLog(@"[send] sender=%@ logic=%@ class=%@", audioSender, logic, NSStringFromClass([logic class]));

    /* 采样率（保持原样） */
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

    /* 6. 喂入数据（保持原样，使用自编码 silk 或回退 PCM） */
    SEL pvd = NSSelectorFromString(@"processVoiceData:");
    SEL pvdq = NSSelectorFromString(@"processVoiceData:queueItem:");
    SEL epd1 = NSSelectorFromString(@"endProcessVoiceData:");
    SEL epd0 = NSSelectorFromString(@"endProcessVoiceData");
    BOOL hasPVD  = [logic respondsToSelector:pvd];
    BOOL hasPVDQ = [logic respondsToSelector:pvdq];
    if (hasPVD) {
        Method m = class_getInstanceMethod([logic class], pvd);
        if (m) TTLog(@"[probe] processVoiceData: type=%s args=%lu", method_getTypeEncoding(m), (unsigned long)method_getNumberOfArguments(m));
    }
    if (hasPVDQ) {
        Method m = class_getInstanceMethod([logic class], pvdq);
        if (m) TTLog(@"[probe] processVoiceData:queueItem: type=%s args=%lu", method_getTypeEncoding(m), (unsigned long)method_getNumberOfArguments(m));
    }
    if ([logic respondsToSelector:epd0]) {
        Method m = class_getInstanceMethod([logic class], epd0);
        if (m) TTLog(@"[probe] endProcessVoiceData type=%s args=%lu", method_getTypeEncoding(m), (unsigned long)method_getNumberOfArguments(m));
    }
    TTLog(@"[send] selectors pvd=%d pvdq=%d epd1=%d epd0=%d", hasPVD, hasPVDQ, [logic respondsToSelector:epd1], [logic respondsToSelector:epd0]);
    if (!hasPVD && !hasPVDQ) return @"transcacheLogic 没有可用的 PCM 输入接口";

    const NSUInteger CHUNK = 8000;
    NSData *feedData = (silkData && silkData.length > 0) ? silkData : pcmData;
    const unsigned char *bytes = feedData.bytes;
    NSUInteger total = feedData.length;
    NSUInteger fed = 0;
    NSUInteger seq = 0;
    TTLog(@"[send] 喂入数据源: %@", (feedData == silkData) ? @"SILK(自编码)" : @"PCM(回退)");

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
                    @try { [item setValue:@(last ? 1 : 0) forKey:@"_endFlag"]; } @catch (__unused NSException *e1) {
                        @try { [item setValue:@(last ? 1 : 0) forKey:@"endFlag"]; } @catch (__unused NSException *e2) {}
                    }
                }
                if (item) {
                    void (*fn)(id, SEL, id, id) = (void (*)(id, SEL, id, id))objc_msgSend;
                    fn(logic, pvdq, piece, item);
                } else if (hasPVD) {
                    void (*fn)(id, SEL, id) = (void (*)(id, SEL, id))objc_msgSend;
                    fn(logic, pvd, piece);
                } else {
                    return @"queueItem 接口存在但 StreamInputQueueItem 不可用";
                }
            } else {
                void (*fn)(id, SEL, id) = (void (*)(id, SEL, id))objc_msgSend;
                fn(logic, pvd, piece);
            }
            fed += len;
            seq++;
        }
    } @catch (NSException *e) {
        TTLog(@"[send] PCM输入异常: %@", e);
        return @"PCM输入异常";
    }
    TTLog(@"[send] fed=%lu bytes chunks=%lu (silk=%lu, pcm=%lu)", (unsigned long)fed, (unsigned long)seq, (unsigned long)silkData.length, (unsigned long)pcmData.length);

    /* 结束处理 */
    BOOL ended = NO;
    @try {
        if ([logic respondsToSelector:epd1]) {
            void (*fn)(id, SEL, id) = (void (*)(id, SEL, id))objc_msgSend;
            fn(logic, epd1, toUsr);
            ended = YES;
            TTLog(@"[send] endProcessVoiceData: done tousr=%@", toUsr);
        } else if ([logic respondsToSelector:epd0]) {
            void (*fn)(id, SEL) = (void (*)(id, SEL))objc_msgSend;
            fn(logic, epd0);
            ended = YES;
            TTLog(@"[send] endProcessVoiceData done");
        }
    } @catch (NSException *e) {
        TTLog(@"[send] endProcessVoiceData 异常: %@", e);
        return @"语音结束处理异常";
    }
    if (!ended) TTLog(@"[send] 未找到 endProcessVoiceData，继续检查 prepareSend");

    /* 7. 获取 userData 并更新元数据（关键修复） */
    id userData = nil;
    @synchronized([NSObject class]) { userData = g_lastUserData; }
    if (!userData) return @"没有捕获到 AudioRecorderUserData（先按住说话一次）";

    // 更新 tousr 和 chatname
    @try { [userData setValue:toUsr forKey:@"tousr"]; } @catch (__unused NSException *e) {}
    @try { [userData setValue:toUsr forKey:@"chatname"]; } @catch (__unused NSException *e) {}

    // ★★★★★ 关键修复：根据实际音频数据更新元数据 ★★★★★
    NSInteger realDuration = (NSInteger)((double)pcmData.length / 2 / (g_targetSampleRate / 1000.0)); // 16bit=2字节, 毫秒
    // 清空旧的 audioid，让微信重新生成
    @try { [userData setValue:nil forKey:@"audioid"]; } @catch (__unused NSException *e) {}
    @try { [userData setValue:@(pcmData.length) forKey:@"receiveDataLength"]; } @catch (__unused NSException *e) {}
    @try { [userData setValue:@(realDuration) forKey:@"duration"]; } @catch (__unused NSException *e) {}
    @try { [userData setValue:@(g_targetSampleRate) forKey:@"sampleRate"]; } @catch (__unused NSException *e) {}
    TTLog(@"[fix] userData updated duration=%ld, pcmSize=%lu", (long)realDuration, (unsigned long)pcmData.length);

    // 打印调试
    @try { TTLog(@"[probe] userData class=%@", NSStringFromClass([userData class])); } @catch (__unused NSException *e) {}
    for (NSString *key in @[@"audioid", @"lastLen", @"receiveDataLength", @"duration", @"sampleRate", @"sampleRateForSilk", @"tousr", @"chatname"]) {
        @try {
            id v = [userData valueForKey:key];
            if (v) TTLog(@"[probe] userData.%@=%@", key, v);
        } @catch (__unused NSException *e) {}
    }

    /* 8. 结束录音会话（仅在 recording==YES 时调用） */
    if (recording) {
        SEL stopSel2 = NSSelectorFromString(@"StopRecord");
        if ([audioSender respondsToSelector:stopSel2]) {
            @try {
                ((void (*)(id, SEL))objc_msgSend)(audioSender, stopSel2);
                TTLog(@"[rec] StopRecord done（结束录音会话）");
            } @catch (NSException *e0) {
                TTLog(@"[rec] StopRecord 异常: %@", e0);
            }
        }
    } else {
        TTLog(@"[rec] 录音会话未启动，跳过 StopRecord");
    }

    /* 9. 发送：优先使用 SendOriVoiceMsgWithUserData: */
    SEL sendSel = NSSelectorFromString(@"SendOriVoiceMsgWithUserData:");
    BOOL usedOri = NO;
    if ([audioSender respondsToSelector:sendSel]) {
        Method sm = class_getInstanceMethod([audioSender class], sendSel);
        const char *enc = sm ? method_getTypeEncoding(sm) : NULL;
        TTLog(@"[send] SendOriVoiceMsgWithUserData: type=%s", enc ? enc : "?");
        @try {
            ((void (*)(id, SEL, id))objc_msgSend)(audioSender, sendSel, userData);
            usedOri = YES;
            TTLog(@"[send] SendOriVoiceMsgWithUserData: 已调用");
        } @catch (NSException *e) {
            TTLog(@"[send] SendOriVoiceMsgWithUserData: 异常: %@", e);
        }
    } else {
        TTLog(@"[send] SendOriVoiceMsgWithUserData: 不存在，回退 prepareSend:");
    }
    if (usedOri) {
        TTLog(@"[send] SendOri accepted; 上传由微信真实管线处理");
        return nil;
    }

    /* 回退到 prepareSend: */
    SEL ps = NSSelectorFromString(@"prepareSend:");
    if (![audioSender respondsToSelector:ps]) return @"AudioSender 没有 prepareSend:";
    Method psMethod = class_getInstanceMethod([audioSender class], ps);
    if (psMethod) {
        TTLog(@"[probe] prepareSend: type=%s args=%lu", method_getTypeEncoding(psMethod), (unsigned long)method_getNumberOfArguments(psMethod));
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
    if (!ok) return @"prepareSend 返回失败";
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
    TTLog(@"v13 fixed init (修复录音会话和元数据)");
}