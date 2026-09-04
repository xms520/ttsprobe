//
// TTSProbe_v8.m
// 对照实验：只 hook AudioSender -prepareSend: 一个方法。
// v5 崩在"松手发送"时刻 → 用 v8 二分定位：
//   - v8 崩  → method_setImplementation 这条路彻底不可用
//   - v8 不崩 → 崩的是 CMessageMgr 那几个 hook
//
// 只记录参数，按真实返回类型分派，其他方法一概不碰。

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <UIKit/UIKit.h>

static void V8Log(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[TTSProbe_v8] %@", s);
}

static NSString *V8Desc(id obj) {
    if (!obj) return @"<nil>";
    @try {
        NSString *s = [obj description];
        if (s.length > 800) s = [s substringToIndex:800];
        return s;
    } @catch (...) { return @"<desc exception>"; }
}

static void V8LogArg(NSString *name, id obj) {
    V8Log(@"%@ class=%@ ptr=%p desc=%@", name,
          obj ? NSStringFromClass([obj class]) : @"<nil>", obj, V8Desc(obj));
}

__attribute__((constructor))
static void TTSProbeV8Init(void) {
    @autoreleasepool {
        V8Log(@"v8 loaded (prepareSend: ONLY, nothing else hooked)");

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{

            Class cls = NSClassFromString(@"AudioSender");
            if (!cls) { V8Log(@"[MISS] AudioSender class"); return; }

            SEL sel = NSSelectorFromString(@"prepareSend:");
            Method m = class_getInstanceMethod(cls, sel);
            if (!m) { V8Log(@"[MISS] prepareSend: method"); return; }

            const char *types = method_getTypeEncoding(m);
            V8Log(@"[FOUND] prepareSend: types=%s", types ? types : "?");

            IMP oldImp = method_getImplementation(m);
            char retType = types ? types[0] : '@';

            if (retType == 'v') {
                IMP newImp = imp_implementationWithBlock(^(id self, id arg) {
                    V8Log(@"---- prepareSend: BEGIN (void) ----");
                    V8LogArg(@"arg1", arg);
                    ((void (*)(id, SEL, id))oldImp)(self, sel, arg);
                    V8Log(@"---- prepareSend: END ----");
                });
                method_setImplementation(m, newImp);
            } else if (retType == 'B') {
                IMP newImp = imp_implementationWithBlock(^BOOL(id self, id arg) {
                    V8Log(@"---- prepareSend: BEGIN (BOOL) ----");
                    V8LogArg(@"arg1", arg);
                    BOOL r = ((BOOL (*)(id, SEL, id))oldImp)(self, sel, arg);
                    V8Log(@"    ret BOOL=%d", r);
                    V8Log(@"---- prepareSend: END ----");
                    return r;
                });
                method_setImplementation(m, newImp);
            } else {
                IMP newImp = imp_implementationWithBlock(^id(id self, id arg) {
                    V8Log(@"---- prepareSend: BEGIN (@) ----");
                    V8LogArg(@"arg1", arg);
                    id r = ((id (*)(id, SEL, id))oldImp)(self, sel, arg);
                    V8LogArg(@"ret", r);
                    V8Log(@"---- prepareSend: END ----");
                    return r;
                });
                method_setImplementation(m, newImp);
            }
            V8Log(@"[HOOK OK] prepareSend: (ret=%c) — send a real voice now", retType);
        });
    }
}
