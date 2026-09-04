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

    IMP newImp = imp_implementationWithBlock(^id(id self, id a, id b) {
        WPLog(@"---- %@ -%@ BEGIN ----", className, selectorName);
        LogArg(@"arg1", a);
        LogArg(@"arg2", b);

        id ret = ((id (*)(id, SEL, id, id))oldImp)(self, sel, a, b);

        LogArg(@"return", ret);
        WPLog(@"---- %@ -%@ END ----", className, selectorName);
        return ret;
    });

    method_setImplementation(m, newImp);
    WPLog(@"[HOOK OK] %@ -%@", className, selectorName);
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

    IMP newImp = imp_implementationWithBlock(^id(id self, id a, id b, id c) {
        WPLog(@"---- %@ -%@ BEGIN ----", className, selectorName);
        LogArg(@"arg1", a);
        LogArg(@"arg2", b);
        LogArg(@"arg3", c);

        id ret = ((id (*)(id, SEL, id, id, id))oldImp)(self, sel, a, b, c);

        LogArg(@"return", ret);
        WPLog(@"---- %@ -%@ END ----", className, selectorName);
        return ret;
    });

    method_setImplementation(m, newImp);
    WPLog(@"[HOOK OK] %@ -%@", className, selectorName);
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
