//
// TTSProbe_v8b.m
// v8 的文件日志版：prepareSend: 的参数写进微信沙盒 Documents/TTSProbe_v8.log
// （NSLog 在无越狱环境不方便看，直接写文件用 Filza 取）
//
// 只 hook AudioSender -prepareSend:，按真实返回类型分派，其他不碰。

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <UIKit/UIKit.h>

static NSString *g_logPath = nil;

static void V8Log(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[TTSProbe_v8b] %@", s);

    if (!g_logPath) return;
    @autoreleasepool {
        NSString *line = [NSString stringWithFormat:@"[TTSProbe_v8b] %@\n", s];
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

static NSString *V8Desc(id obj) {
    if (!obj) return @"<nil>";
    @try {
        NSString *s = [obj description];
        if (s.length > 2000) s = [s substringToIndex:2000];
        return s;
    } @catch (...) { return @"<desc exception>"; }
}

static void V8LogArg(NSString *name, id obj) {
    V8Log(@"%@ class=%@ ptr=%p", name,
          obj ? NSStringFromClass([obj class]) : @"<nil>", obj);

    /* desc 单独写一行，并 dump 对象所有 KVC 可读字段（小对象才 dump，防大对象卡死） */
    if (obj && [obj isKindOfClass:[NSObject class]]) {
        V8Log(@"%@ desc=%@", name, V8Desc(obj));

        /* dump 所有属性（< 60 个的小对象） */
        @try {
            unsigned int count = 0;
            objc_property_t *props = class_copyPropertyList([obj class], &count);
            if (props && count > 0 && count < 60) {
                for (unsigned int i = 0; i < count; i++) {
                    const char *pname = property_getName(props[i]);
                    NSString *key = [NSString stringWithUTF8String:pname];
                    @try {
                        id v = [obj valueForKey:key];
                        if (v && ![v isKindOfClass:[NSNull class]]) {
                            NSString *vs = V8Desc(v);
                            if (vs.length > 300) vs = [vs substringToIndex:300];
                            V8Log(@"    %@.%@ = %@", name, key, vs);
                        }
                    } @catch (NSException *e) { /* skip */ }
                }
            }
            if (props) free(props);
        } @catch (...) { }
    }
}

__attribute__((constructor))
static void TTSProbeV8bInit(void) {
    @autoreleasepool {
        g_logPath = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/TTSProbe_v8.log"];

        V8Log(@"v8b loaded (file-log edition, prepareSend: ONLY)");
        V8Log(@"log file: %@", g_logPath);

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
                    V8Log(@"========== prepareSend: BEGIN (void) ==========");
                    V8LogArg(@"arg1", arg);
                    V8LogArg(@"self", self);
                    ((void (*)(id, SEL, id))oldImp)(self, sel, arg);
                    V8Log(@"========== prepareSend: END ==========");
                });
                method_setImplementation(m, newImp);
            } else if (retType == 'B') {
                IMP newImp = imp_implementationWithBlock(^BOOL(id self, id arg) {
                    V8Log(@"========== prepareSend: BEGIN (BOOL) ==========");
                    V8LogArg(@"arg1", arg);
                    V8LogArg(@"self", self);
                    BOOL r = ((BOOL (*)(id, SEL, id))oldImp)(self, sel, arg);
                    V8Log(@"    ret BOOL=%d", r);
                    V8Log(@"========== prepareSend: END ==========");
                    return r;
                });
                method_setImplementation(m, newImp);
            } else {
                IMP newImp = imp_implementationWithBlock(^id(id self, id arg) {
                    V8Log(@"========== prepareSend: BEGIN (@) ==========");
                    V8LogArg(@"arg1", arg);
                    V8LogArg(@"self", self);
                    id r = ((id (*)(id, SEL, id))oldImp)(self, sel, arg);
                    V8LogArg(@"ret", r);
                    V8Log(@"========== prepareSend: END ==========");
                    return r;
                });
                method_setImplementation(m, newImp);
            }
            V8Log(@"[HOOK OK] prepareSend: (ret=%c) — now send a real voice, then read Documents/TTSProbe_v8.log", retType);
        });
    }
}
