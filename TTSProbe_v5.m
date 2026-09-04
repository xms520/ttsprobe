//
// TTSProbe_v5.m
// 目的：只追踪微信语音正常发送链路，不修改原有行为。
// 重点：AudioSender -prepareSend: 以及其后几个已知语音相关方法。
//

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <UIKit/UIKit.h>

static NSString *WPClassName(id obj) {
    if (!obj) return @"<nil>";
    return NSStringFromClass([obj class]);
}

static NSString *WPObjectDesc(id obj) {
    if (!obj) return @"<nil>";
    @try {
        NSString *s = [obj description];
        if (s.length > 1000) s = [s substringToIndex:1000];
        return s ?: @"<null description>";
    } @catch (...) {
        return @"<description exception>";
    }
}

static void WPLog(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);

    NSLog(@"[WeChatHook][TTSProbe_v5] %@", s);
}

static void LogArg(NSString *name, id obj) {
    WPLog(@"%@ class=%@ ptr=%p desc=%@", name, WPClassName(obj), obj, WPObjectDesc(obj));
}

static void HookPrepareSend(void) {
    Class cls = NSClassFromString(@"AudioSender");
    if (!cls) {
        WPLog(@"[MISS] AudioSender");
        return;
    }

    SEL sel = NSSelectorFromString(@"prepareSend:");
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) {
        WPLog(@"[MISS] AudioSender -prepareSend:");
        return;
    }

    IMP oldImp = method_getImplementation(m);

    IMP newImp = imp_implementationWithBlock(^id(id self, id arg) {
        WPLog(@"========== prepareSend BEGIN ==========");
        LogArg(@"arg1", arg);

        id ret = ((id (*)(id, SEL, id))oldImp)(self, sel, arg);

        LogArg(@"return", ret);
        WPLog(@"========== prepareSend END ==========");

        return ret;
    });

    method_setImplementation(m, newImp);
    WPLog(@"[HOOK OK] AudioSender -prepareSend:");
}

static void HookStopRecord(void) {
    Class cls = NSClassFromString(@"AudioSender");
    if (!cls) return;

    SEL sel = NSSelectorFromString(@"StopRecord");
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) {
        WPLog(@"[MISS] AudioSender -StopRecord");
        return;
    }

    IMP oldImp = method_getImplementation(m);

    IMP newImp = imp_implementationWithBlock(^void(id self) {
        WPLog(@"========== AudioSender -StopRecord ==========");
        ((void (*)(id, SEL))oldImp)(self, sel);
        WPLog(@"========== AudioSender -StopRecord RETURN ==========");
    });

    method_setImplementation(m, newImp);
    WPLog(@"[HOOK OK] AudioSender -StopRecord");
}

static void HookOneArgMethod(NSString *className, NSString *selectorName) {
    Class cls = NSClassFromString(className);
    if (!cls) {
        WPLog(@"[MISS] %@ class", className);
        return;
    }

    SEL sel = NSSelectorFromString(selectorName);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) {
        WPLog(@"[MISS] %@ -%@", className, selectorName);
        return;
    }

    const char *types = method_getTypeEncoding(m);
    WPLog(@"[FOUND] %@ -%@ type=%s", className, selectorName, types);

    IMP oldImp = method_getImplementation(m);

    IMP newImp = imp_implementationWithBlock(^id(id self, id arg) {
        WPLog(@"---- %@ -%@ BEGIN ----", className, selectorName);
        LogArg(@"arg1", arg);

        // 不假设返回类型，先按常见 Objective-C 对象返回读取。
        id ret = ((id (*)(id, SEL, id))oldImp)(self, sel, arg);

        LogArg(@"return", ret);
        WPLog(@"---- %@ -%@ END ----", className, selectorName);
        return ret;
    });

    method_setImplementation(m, newImp);
    WPLog(@"[HOOK OK] %@ -%@", className, selectorName);
}

static void HookTwoArgMethod(NSString *className, NSString *selectorName) {
    Class cls = NSClassFromString(className);
    if (!cls) {
        WPLog(@"[MISS] %@ class", className);
        return;
    }

    SEL sel = NSSelectorFromString(selectorName);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) {
        WPLog(@"[MISS] %@ -%@", className, selectorName);
        return;
    }

    const char *types = method_getTypeEncoding(m);
    WPLog(@"[FOUND] %@ -%@ type=%s", className, selectorName, types);

    IMP oldImp = method_getImplementation(m);

    /* 关键修复：按真实返回类型分派，避免 BOOL/void 被误当 id 导致寄存器错位闪退。
     * types 第一个字符：'v'=void, 'B'=BOOL, '@'=对象, 其他按 void* 兼容处理 */
    char retType = types ? types[0] : '@';

    if (retType == 'v') {
        /* void 返回 */
        IMP newImp = imp_implementationWithBlock(^(id self, id a, id b) {
            WPLog(@"---- %@ -%@ BEGIN (void) ----", className, selectorName);
            LogArg(@"arg1", a); LogArg(@"arg2", b);
            ((void (*)(id, SEL, id, id))oldImp)(self, sel, a, b);
            WPLog(@"---- %@ -%@ END ----", className, selectorName);
        });
        method_setImplementation(m, newImp);
    } else if (retType == 'B') {
        /* BOOL 返回 */
        IMP newImp = imp_implementationWithBlock(^BOOL(id self, id a, id b) {
            WPLog(@"---- %@ -%@ BEGIN (BOOL) ----", className, selectorName);
            LogArg(@"arg1", a); LogArg(@"arg2", b);
            BOOL r = ((BOOL (*)(id, SEL, id, id))oldImp)(self, sel, a, b);
            WPLog(@"    return BOOL=%d", r);
            WPLog(@"---- %@ -%@ END ----", className, selectorName);
            return r;
        });
        method_setImplementation(m, newImp);
    } else {
        /* 对象/其他：按 void* 兼容 */
        IMP newImp = imp_implementationWithBlock(^id(id self, id a, id b) {
            WPLog(@"---- %@ -%@ BEGIN (@) ----", className, selectorName);
            LogArg(@"arg1", a); LogArg(@"arg2", b);
            id r = ((id (*)(id, SEL, id, id))oldImp)(self, sel, a, b);
            LogArg(@"return", r);
            WPLog(@"---- %@ -%@ END ----", className, selectorName);
            return r;
        });
        method_setImplementation(m, newImp);
    }
    WPLog(@"[HOOK OK] %@ -%@ (ret=%c)", className, selectorName, retType);
}

static void HookThreeArgMethod(NSString *className, NSString *selectorName) {
    Class cls = NSClassFromString(className);
    if (!cls) {
        WPLog(@"[MISS] %@ class", className);
        return;
    }

    SEL sel = NSSelectorFromString(selectorName);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) {
        WPLog(@"[MISS] %@ -%@", className, selectorName);
        return;
    }

    const char *types = method_getTypeEncoding(m);
    WPLog(@"[FOUND] %@ -%@ type=%s", className, selectorName, types);

    IMP oldImp = method_getImplementation(m);
    char retType = types ? types[0] : '@';

    if (retType == 'v') {
        IMP newImp = imp_implementationWithBlock(^(id self, id a, id b, id c) {
            WPLog(@"---- %@ -%@ BEGIN (void) ----", className, selectorName);
            LogArg(@"arg1", a); LogArg(@"arg2", b); LogArg(@"arg3", c);
            ((void (*)(id, SEL, id, id, id))oldImp)(self, sel, a, b, c);
            WPLog(@"---- %@ -%@ END ----", className, selectorName);
        });
        method_setImplementation(m, newImp);
    } else if (retType == 'B') {
        IMP newImp = imp_implementationWithBlock(^BOOL(id self, id a, id b, id c) {
            WPLog(@"---- %@ -%@ BEGIN (BOOL) ----", className, selectorName);
            LogArg(@"arg1", a); LogArg(@"arg2", b); LogArg(@"arg3", c);
            BOOL r = ((BOOL (*)(id, SEL, id, id, id))oldImp)(self, sel, a, b, c);
            WPLog(@"    return BOOL=%d", r);
            return r;
        });
        method_setImplementation(m, newImp);
    } else {
        IMP newImp = imp_implementationWithBlock(^id(id self, id a, id b, id c) {
            WPLog(@"---- %@ -%@ BEGIN (@) ----", className, selectorName);
            LogArg(@"arg1", a); LogArg(@"arg2", b); LogArg(@"arg3", c);
            id r = ((id (*)(id, SEL, id, id, id))oldImp)(self, sel, a, b, c);
            LogArg(@"return", r);
            return r;
        });
        method_setImplementation(m, newImp);
    }
    WPLog(@"[HOOK OK] %@ -%@ (ret=%c)", className, selectorName, retType);
}

__attribute__((constructor))
static void TTSProbeV5Init(void) {
    @autoreleasepool {
        WPLog(@"======================================");
        WPLog(@"TTSProbe_v5 loaded");
        WPLog(@"只记录，不主动发送，不修改参数");
        WPLog(@"======================================");

        // 给微信一点初始化时间，再安装 Hook。
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            HookPrepareSend();
            HookStopRecord();

            // 这些是之前已经确认存在/值得继续观察的语音相关方法。
            HookTwoArgMethod(@"CMessageMgr", @"SaveMesVoice:MsgWrap:");
            HookTwoArgMethod(@"CMessageMgr", @"UpdateVoiceMessage:MsgWrap:");
            HookThreeArgMethod(@"CMessageMgr", @"UpdateVoiceMessage:MsgWrap:fixTime:");
            HookTwoArgMethod(@"CMessageMgr", @"AddRecordMsg:MsgWrap:");
            HookOneArgMethod(@"RecordController", @"onVoiceMsgSent:");
        });
    }
}
