//
// TTSProbe_v12.m — AddNewPart C-IMP 探针（不用 block，签名绝对对齐）
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

static void L12(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[v12] %@", s);
    if (!g_logPath) return;
    @autoreleasepool {
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:g_logPath];
        if (!fh) { [[NSFileManager defaultManager] createFileAtPath:g_logPath contents:nil attributes:nil]; fh = [NSFileHandle fileHandleForWritingAtPath:g_logPath]; }
        if (fh) { [fh seekToEndOfFile]; [fh writeData:[[NSString stringWithFormat:@"[v12] %@\n", s] dataUsingEncoding:NSUTF8StringEncoding]]; [fh closeFile]; }
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

/* ================= AddNewPart: C-IMP trampoline（按 ABI 寄存器直接转发） =================
 * 签名: v84@0:8@16I24q28I36I40I44I48I52I56I60I64@68@76
 * ARM64 参数寄存器: x0=self x1=_cmd x2=@16 w3=I24 x4=q28
 *                   w5=I36 w6=I40 w7=I44 然后 w8..w11? —— 偏移 I48 起在栈上（84字节栈帧）
 * 最安全做法：C 函数参数列表完全按类型编码顺序写（编译器按 ABI 布局） */
typedef void (*AddNewPartIMP)(id, SEL, id, uint32_t, uint64_t,
                              uint32_t, uint32_t, uint32_t, uint32_t,
                              uint32_t, uint32_t, uint32_t, id, id);
static AddNewPartIMP g_origAddNewPart = NULL;

static void TTSNewAddNewPart(id self, SEL _cmd,
                             id a1, uint32_t a2, uint64_t a3,
                             uint32_t a4, uint32_t a5, uint32_t a6, uint32_t a7,
                             uint32_t a8, uint32_t a9, uint32_t a10,
                             id a11, id a12) {
    @autoreleasepool {
    L12(@"---- AddNewPart %@ ----", NSStringFromClass([self class]));
    L12(@"  a1=%@ a2=%u a3=%llu", D12(a1), a2, (unsigned long long)a3);
    L12(@"  a4=%u a5=%u a6=%u a7=%u", a4, a5, a6, a7);
    L12(@"  a8=%u a9=%u a10=%u", a8, a9, a10);
    L12(@"  a11=%@ a12=%@", D12(a11), D12(a12));
    if (g_origAddNewPart) {
        g_origAddNewPart(self, _cmd, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12);
    }
    L12(@"---- AddNewPart done ----");
    }

}

static void HookAddNewPartC(NSString *clsName) {
    Class cls = NSClassFromString(clsName);
    if (!cls) { L12(@"[MISS] %@", clsName); return; }
    SEL sel = NSSelectorFromString(@"AddNewPart:LocalID:n64SvrID:Offset:Len:VoiceTime:CreateTime:EndFlag:CancelFlag:VoiceFormat:ForwardFlag:msgSource:chatName:");
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) { L12(@"[MISS] %@ AddNewPart", clsName); return; }
    g_origAddNewPart = (AddNewPartIMP)method_getImplementation(m);
    method_setImplementation(m, (IMP)TTSNewAddNewPart);
    L12(@"[HOOK OK] %@ AddNewPart (C-IMP)", clsName);
}

/* ================= processVoiceData:queueItem: 观察（v9 验证安全的 block hook） ================= */
static void HookQueueItemObserver(void) {
    Class cls = NSClassFromString(@"MMNewVoiceInputCacheLogic");
    if (!cls) { L12(@"[MISS] MMNewVoiceInputCacheLogic"); return; }
    SEL sel = NSSelectorFromString(@"processVoiceData:queueItem:");
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) { L12(@"[MISS] processVoiceData:queueItem:"); return; }
    IMP oldImp = method_getImplementation(m);
    IMP newImp = imp_implementationWithBlock(^(id self, id data, id item) {
        /* 只记数据长度 + item 类名/指针——不碰 description（v12 崩点嫌疑） */
        @autoreleasepool {
            NSUInteger len = 0;
            if ([data isKindOfClass:[NSData class]]) len = [data length];
            const char *icn = item ? class_getName([item class]) : NULL;
            L12(@"[queue] self=%p dataLen=%lu item=%s:%p",
                self, (unsigned long)len, icn ? icn : "<nil>", item);
        }
        ((void (*)(id, SEL, id, id))oldImp)(self, sel, data, item);
    });
    method_setImplementation(m, newImp);
    L12(@"[HOOK OK] processVoiceData:queueItem: observer");
}

__attribute__((constructor))
static void V12Init(void) {
    @autoreleasepool {
        g_logPath = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/TTSProbe_v12.log"];
        L12(@"v12 loaded (C-IMP upload probe + queue observer)");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            HookAddNewPartC(@"UploadVoiceCDNMgr");
            HookQueueItemObserver();
            L12(@"installed — 1)真实录音发一条 2)TTS发一条，对照");
        });
    }
}
