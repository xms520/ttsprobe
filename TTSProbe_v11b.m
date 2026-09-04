//
// TTSProbe_v11b.m — AddNewPart 上传队列探针（签名修正版）
//
// 真机实测签名: v84@0:8@16I24q28I36I40I44I48I52I56I60I64@68@76
//   返回 void (84字节栈)
//   @16  = arg1  LocalID      (对象)
//   I24  = arg2  n64SvrID低32? (uint32)
//   q28  = arg3  (uint64)
//   I36~I60 = 6×uint32 (Offset/Len/VoiceTime/CreateTime/EndFlag/CancelFlag/VoiceFormat/ForwardFlag 中的6个)
//   @68  = arg11 msgSource    (对象)
//   @76  = arg12 chatName     (对象)
// 标量参数与对象参数寄存器不同——block 签名必须逐参匹配，否则闪退。
//

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <UIKit/UIKit.h>

static NSString *g_logPath = nil;

static void L11(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[v11b] %@", s);
    if (!g_logPath) return;
    @autoreleasepool {
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:g_logPath];
        if (!fh) { [[NSFileManager defaultManager] createFileAtPath:g_logPath contents:nil attributes:nil]; fh = [NSFileHandle fileHandleForWritingAtPath:g_logPath]; }
        if (fh) { [fh seekToEndOfFile]; [fh writeData:[[NSString stringWithFormat:@"[v11b] %@\n", s] dataUsingEncoding:NSUTF8StringEncoding]]; [fh closeFile]; }
    }
}

static NSString *D11(id obj) {
    if (!obj) return @"<nil>";
    if ([obj isKindOfClass:[NSString class]]) {
        NSString *s = obj;
        return s.length > 80 ? [s substringToIndex:80] : s;
    }
    if ([obj isKindOfClass:[NSNumber class]]) return [NSString stringWithFormat:@"%@", obj];
    return NSStringFromClass([obj class]);
}

/* 按真实签名 hook：@16 I24 q28 I36 I40 I44 I48 I52 I56 I60 @68 @76 → void */
static void HookAddNewPartFixed(NSString *clsName) {
    Class cls = NSClassFromString(clsName);
    if (!cls) { L11(@"[MISS] %@ class", clsName); return; }
    SEL sel = NSSelectorFromString(@"AddNewPart:LocalID:n64SvrID:Offset:Len:VoiceTime:CreateTime:EndFlag:CancelFlag:VoiceFormat:ForwardFlag:msgSource:chatName:");
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) { L11(@"[MISS] %@ AddNewPart", clsName); return; }

    IMP oldImp = method_getImplementation(m);
    L11(@"[HOOK] %@ AddNewPart (签名修正版)", clsName);

    /* 参数布局（arm64）:
       x2=@LocalID  w3=I24? 不对——按 type encoding 偏移:
       @16(obj) I24(u32) q28(u64) I36 I40 I44 I48 I52 I56 I60 (6×u32) @68(obj) @76(obj)
       block 参数列表按此写：id, uint32_t, uint64_t, 6×uint32_t, id, id */
    IMP newImp = imp_implementationWithBlock(^(id self,
            id p1,                 /* @16  LocalID */
            uint32_t p2,           /* I24  */
            uint64_t p3,           /* q28  n64SvrID */
            uint32_t p4,           /* I36  Offset */
            uint32_t p5,           /* I40  Len */
            uint32_t p6,           /* I44  VoiceTime */
            uint32_t p7,           /* I48  CreateTime */
            uint32_t p8,           /* I52  EndFlag */
            uint32_t p9,           /* I56  CancelFlag */
            uint32_t p10,          /* I60  VoiceFormat/ForwardFlag */
            id p11,                /* @68  msgSource */
            id p12) {              /* @76  chatName */
        L11(@"---- AddNewPart %@ ----", clsName);
        L11(@"  LocalID=%@ n64SvrID=%llu Offset=%u Len=%u",
            D11(p1), (unsigned long long)p3, p4, p5);
        L11(@"  VoiceTime=%u CreateTime=%u EndFlag=%u CancelFlag=%u fmt=%u",
            p6, p7, p8, p9, p10);
        L11(@"  msgSource=%@ chatName=%@",
            D11(p11), D11(p12));
        ((void (*)(id, SEL, id, uint32_t, uint64_t, uint32_t, uint32_t, uint32_t,
                   uint32_t, uint32_t, uint32_t, uint32_t, id, id))oldImp)
            (self, sel, p1, p2, p3, p4, p5, p6, p7, p8, p9, p10, p11, p12);
        L11(@"---- AddNewPart done ----");
    });
    method_setImplementation(m, newImp);
}

__attribute__((constructor))
static void V11bInit(void) {
    @autoreleasepool {
        g_logPath = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/TTSProbe_v11.log"];
        L11(@"v11b loaded (fixed-signature upload probe)");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            HookAddNewPartFixed(@"UploadVoiceCDNMgr");
            HookAddNewPartFixed(@"MMNewUploadVoiceMgr");
            L11(@"installed — 1)真实录音发一条 2)TTS发一条");
        });
    }
}
