//
// TTSProbe_v9.m
// 探针：MMNewVoiceInputCacheLogic 的 processVoiceData: / processVoiceData:queueItem:
// 目的：找 silk/PCM 数据进微信录音缓存的喂入口（参数里应有数据长度/来源）
//
// 沿用 v8b 验证过的安全模式：
//   - 单点 hook（只 hook MMNewVoiceInputCacheLogic）
//   - method_getTypeEncoding 按真实返回类型分派（v=void / B=BOOL / @=对象）
//   - 日志写文件（微信沙盒 Documents/TTSProbe_v9.log）
//   - AudioSender/CMessageMgr 不碰（v5 证明 CMessageMgr hook 会崩）
//
// 注意：processVoiceData: 参数可能是 NSData(音频数据)。只记录 class/length，
// 不 dump 数据内容（防止把几百 KB 音频写进日志卡死）。

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <UIKit/UIKit.h>

static NSString *g_logPath = nil;

static void V9Log(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[TTSProbe_v9] %@", s);

    if (!g_logPath) return;
    @autoreleasepool {
        NSString *line = [NSString stringWithFormat:@"[TTSProbe_v9] %@\n", s];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:g_logPath];
        if (!fh) {
            [[NSFileManager defaultManager] createFileAtPath:g_logPath contents:nil attributes:nil];
            fh = [NSFileHandle fileHandleForWritingAtPath:g_logPath];
        }
        if (fh) {
            [fh seekToEndOfFile];
            [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        }
    }
}

/* 参数描述：NSData 只记 length，不 dump 内容 */
static NSString *V9ArgDesc(id obj) {
    if (!obj) return @"<nil>";
    @try {
        if ([obj isKindOfClass:[NSData class]]) {
            return [NSString stringWithFormat:@"NSData len=%lu", (unsigned long)[obj length]];
        }
        if ([obj isKindOfClass:[NSString class]]) {
            NSString *s = obj;
            if (s.length > 200) s = [s substringToIndex:200];
            return [NSString stringWithFormat:@"NSString '%@'", s];
        }
        if ([obj isKindOfClass:[NSNumber class]]) {
            return [NSString stringWithFormat:@"NSNumber %@", obj];
        }
        NSString *d = [obj description];
        if (d.length > 300) d = [d substringToIndex:300];
        return [NSString stringWithFormat:@"%@ %@", NSStringFromClass([obj class]), d];
    } @catch (...) {
        return @"<desc exception>";
    }
}

static void V9LogArg(NSString *name, id obj) {
    V9Log(@"%@ -> %@", name, V9ArgDesc(obj));
}

/* ---- 通用安全 hook：按返回类型分派（1 参数版） ---- */
static void HookMethodWithTypeDispatch(Class cls, SEL sel, NSString *label) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) { V9Log(@"[MISS] %@", label); return; }

    const char *types = method_getTypeEncoding(m);
    V9Log(@"[FOUND] %@ types=%s", label, types ? types : "?");

    IMP oldImp = method_getImplementation(m);
    char retType = types ? types[0] : '@';

    if (retType == 'v') {
        IMP newImp = imp_implementationWithBlock(^(id self, id a) {
            V9Log(@"---- %@ BEGIN (void) ----", label);
            V9LogArg(@"arg1", a);
            ((void (*)(id, SEL, id))oldImp)(self, sel, a);
            V9Log(@"---- %@ END ----", label);
        });
        method_setImplementation(m, newImp);
    } else if (retType == 'B') {
        IMP newImp = imp_implementationWithBlock(^BOOL(id self, id a) {
            V9Log(@"---- %@ BEGIN (BOOL) ----", label);
            V9LogArg(@"arg1", a);
            BOOL r = ((BOOL (*)(id, SEL, id))oldImp)(self, sel, a);
            V9Log(@"    ret BOOL=%d", r);
            V9Log(@"---- %@ END ----", label);
            return r;
        });
        method_setImplementation(m, newImp);
    } else {
        IMP newImp = imp_implementationWithBlock(^id(id self, id a) {
            V9Log(@"---- %@ BEGIN (@) ----", label);
            V9LogArg(@"arg1", a);
            id r = ((id (*)(id, SEL, id))oldImp)(self, sel, a);
            V9LogArg(@"ret", r);
            V9Log(@"---- %@ END ----", label);
            return r;
        });
        method_setImplementation(m, newImp);
    }
    V9Log(@"[HOOK OK] %@ (ret=%c)", label, retType);
}

/* ---- 两参数版（processVoiceData:queueItem:） ---- */
static void HookTwoArgMethod(Class cls, SEL sel, NSString *label) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) { V9Log(@"[MISS] %@", label); return; }

    const char *types = method_getTypeEncoding(m);
    V9Log(@"[FOUND] %@ types=%s", label, types ? types : "?");

    IMP oldImp = method_getImplementation(m);
    char retType = types ? types[0] : '@';

    if (retType == 'v') {
        IMP newImp = imp_implementationWithBlock(^(id self, id a, id b) {
            V9Log(@"---- %@ BEGIN (void, 2 args) ----", label);
            V9LogArg(@"arg1", a);
            V9LogArg(@"arg2", b);
            ((void (*)(id, SEL, id, id))oldImp)(self, sel, a, b);
            V9Log(@"---- %@ END ----", label);
        });
        method_setImplementation(m, newImp);
    } else if (retType == 'B') {
        IMP newImp = imp_implementationWithBlock(^BOOL(id self, id a, id b) {
            V9Log(@"---- %@ BEGIN (BOOL, 2 args) ----", label);
            V9LogArg(@"arg1", a);
            V9LogArg(@"arg2", b);
            BOOL r = ((BOOL (*)(id, SEL, id, id))oldImp)(self, sel, a, b);
            V9Log(@"    ret BOOL=%d", r);
            V9Log(@"---- %@ END ----", label);
            return r;
        });
        method_setImplementation(m, newImp);
    } else {
        IMP newImp = imp_implementationWithBlock(^id(id self, id a, id b) {
            V9Log(@"---- %@ BEGIN (@, 2 args) ----", label);
            V9LogArg(@"arg1", a);
            V9LogArg(@"arg2", b);
            id r = ((id (*)(id, SEL, id, id))oldImp)(self, sel, a, b);
            V9LogArg(@"ret", r);
            V9Log(@"---- %@ END ----", label);
            return r;
        });
        method_setImplementation(m, newImp);
    }
    V9Log(@"[HOOK OK] %@ (ret=%c)", label, retType);
}

__attribute__((constructor))
static void TTSProbeV9Init(void) {
    @autoreleasepool {
        g_logPath = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/TTSProbe_v9.log"];
        V9Log(@"v9 loaded (processVoiceData probe, file-log)");
        V9Log(@"log: %@", g_logPath);

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{

            Class cls = NSClassFromString(@"MMNewVoiceInputCacheLogic");
            if (!cls) { V9Log(@"[MISS] MMNewVoiceInputCacheLogic class"); return; }

            /* 核心：录音数据进缓存的两个入口（两参数的那个用两参数 hook） */
            HookMethodWithTypeDispatch(cls, NSSelectorFromString(@"processVoiceData:"), @"processVoiceData:");
            HookTwoArgMethod(cls, NSSelectorFromString(@"processVoiceData:queueItem:"), @"processVoiceData:queueItem:");

            /* 辅助：结束/上传流程 */
            HookMethodWithTypeDispatch(cls, NSSelectorFromString(@"endProcessVoiceData"), @"endProcessVoiceData");
            HookMethodWithTypeDispatch(cls, NSSelectorFromString(@"notifyRecordStop"), @"notifyRecordStop");

            V9Log(@"all hooks installed — send a real voice now, then read Documents/TTSProbe_v9.log");
        });
    }
}
