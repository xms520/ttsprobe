//
// TTSProbe_v13.m — AddNewPart C-IMP 探针（不用 block，签名绝对对齐）
//
// 真机签名: v84@0:8@16I24q28I36I40I44I48I52I56I60I64@68@76
//  → void (id self, SEL _cmd, id@16, uint32_t I24, uint64_t q28,
//          uint32_t I36, uint32_t I40, uint32_t I44, uint32_t I48,
//          uint32_t I52, uint32_t I56, uint32_t I60, uint64_t I64?, id@68, id@76)
//  注意：偏移 I64 在 @68 之前——I64 是 4 字节但下一个参数 @68 从 68 开始，
//        说明 I64 后有 4 字节 padding。arm64 上按寄存器传参：
//        x2=@16, w3=I24, x4=q28, w5=I36, w6=I40, w7=I44,
//        栈上: I48,I52,I56,I60,I64(都在栈/寄存器，由 ABI 决定)
//  为绝对安全：只记录、立即转调原 IMP（C 函数转发，零签名风险）
//
// 同时 hook MMNewVoiceInputCacheLogic 的 processVoiceData:queueItem:（v9 验证安全）
// → 对照「真实录音」与「TTS 发送」在缓存层的调用差异
//

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <UIKit/UIKit.h>

static NSString *g_logPath = nil;

static void L13_log(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[v13] %@", s);
    if (!g_logPath) return;
    @autoreleasepool {
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:g_logPath];
        if (!fh) { [[NSFileManager defaultManager] createFileAtPath:g_logPath contents:nil attributes:nil]; fh = [NSFileHandle fileHandleForWritingAtPath:g_logPath]; }
        if (fh) { [fh seekToEndOfFile]; [fh writeData:[[NSString stringWithFormat:@"[v13] %@\n", s] dataUsingEncoding:NSUTF8StringEncoding]]; [fh closeFile]; }
    }
}

static NSString *D12(id obj) {
    if (!obj) return @"<nil>";
    if ([obj isKindOfClass:[NSString class]]) {
        NSString *s = obj;
        return s.length > 80 ? [s substringToIndex:80] : s;
    }
    if ([obj isKindOfClass:[NSData class]]) return [NSString stringWithFormat:@"NSData(%lu)", (unsigned long)[obj length]];
    if ([obj isKindOfClass:[NSNumber class]]) return [NSString stringWithFormat:@"%@", obj];
    return NSStringFromClass([obj class]);
}

/* ================= prepareSend: userData 全字段 dump ================= */
static void HookPrepareSendDump(void) {
    Class cls = NSClassFromString(@"AudioSender");
    if (!cls) { L13_log(@"[MISS] AudioSender"); return; }
    SEL sel = NSSelectorFromString(@"prepareSend:");
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) { L13_log(@"[MISS] prepareSend:"); return; }
    IMP oldImp = method_getImplementation(m);
    IMP newImp = imp_implementationWithBlock(^BOOL(id self, id arg) {
        @autoreleasepool {
            L13_log(@"==== prepareSend userData dump ====");
            if (arg) {
                unsigned int count = 0;
                objc_property_t *props = class_copyPropertyList([arg class], &count);
                L13_log(@"  class=%@ props=%u", NSStringFromClass([arg class]), count);
                if (props) {
                    for (unsigned int i = 0; i < count && i < 50; i++) {
                        const char *pn = property_getName(props[i]);
                        NSString *key = [NSString stringWithUTF8String:pn];
                        @try {
                            id v = [arg valueForKey:key];
                            if (v && ![v isKindOfClass:[NSNull class]]) {
                                NSString *vs = [NSString stringWithFormat:@"%@", v];
                                if (vs.length > 60) vs = [vs substringToIndex:60];
                                L13_log(@"  %@ = %@", key, vs);
                            } else {
                                L13_log(@"  %@ = <nil>", key);
                            }
                        } @catch (NSException *e) { }
                    }
                    free(props);
                }
            }
        }
        return ((BOOL (*)(id, SEL, id))oldImp)(self, sel, arg);
    });
    method_setImplementation(m, newImp);
    L13_log(@"[HOOK OK] prepareSend userData dumper");
}

/* ================= processVoiceData:queueItem: 观察（v9 验证安全的 block hook） ================= */
static void HookQueueItemObserver(void) {
    Class cls = NSClassFromString(@"MMNewVoiceInputCacheLogic");
    if (!cls) { L13_log(@"[MISS] MMNewVoiceInputCacheLogic"); return; }
    SEL sel = NSSelectorFromString(@"processVoiceData:queueItem:");
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) { L13_log(@"[MISS] processVoiceData:queueItem:"); return; }
    IMP oldImp = method_getImplementation(m);
    IMP newImp = imp_implementationWithBlock(^(id self, id data, id item) {
        /* 只记数据长度 + item 类名/指针——不碰 description（v12 崩点嫌疑） */
        @autoreleasepool {
            NSUInteger len = 0;
            if ([data isKindOfClass:[NSData class]]) len = [data length];
            const char *icn = item ? class_getName([item class]) : NULL;
            L13_log(@"[queue] self=%p dataLen=%lu item=%s:%p",
                self, (unsigned long)len, icn ? icn : "<nil>", item);
        }
        ((void (*)(id, SEL, id, id))oldImp)(self, sel, data, item);
    });
    method_setImplementation(m, newImp);
    L13_log(@"[HOOK OK] processVoiceData:queueItem: observer");
}

__attribute__((constructor))
static void V12Init(void) {
    @autoreleasepool {
        g_logPath = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/TTSProbe_v13.log"];
        L13_log(@"v13 loaded (C-IMP upload probe + queue observer)");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            /* AddNewPart C-IMP 转发会崩（14参栈布局对不齐）— 撤掉，只留 queue 观察器 */
            HookQueueItemObserver();
            L13_log(@"installed — queue observer ONLY（对照真实录音 vs TTS 的数据帧）");
        });
    }
}
