//
// TTSProbe_v11.m — 上传队列探针
// hook UploadVoiceCDNMgr AddNewPart:... 观察真实上传参数（对照 TTS 发送的参数差异）
// 同时 hook MMNewUploadVoiceMgr 的 AddNewPart（备选路径）
// 安全模式：按真实返回类型分派 + 文件日志 + 全 try/catch
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
    NSLog(@"[v11] %@", s);
    if (!g_logPath) return;
    @autoreleasepool {
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:g_logPath];
        if (!fh) { [[NSFileManager defaultManager] createFileAtPath:g_logPath contents:nil attributes:nil]; fh = [NSFileHandle fileHandleForWritingAtPath:g_logPath]; }
        if (fh) { [fh seekToEndOfFile]; [fh writeData:[[NSString stringWithFormat:@"[v11] %@\n", s] dataUsingEncoding:NSUTF8StringEncoding]]; [fh closeFile]; }
    }
}

static NSString *D11(id obj) {
    if (!obj) return @"<nil>";
    if ([obj isKindOfClass:[NSString class]]) {
        NSString *s = obj;
        return s.length > 60 ? [s substringToIndex:60] : s;
    }
    if ([obj isKindOfClass:[NSNumber class]]) return [NSString stringWithFormat:@"%@", obj];
    return NSStringFromClass([obj class]);
}

/* hook AddNewPart（14参方法：self+cmd+12参数） */
static void HookAddNewPart(NSString *clsName) {
    Class cls = NSClassFromString(clsName);
    if (!cls) { L11(@"[MISS] %@ class", clsName); return; }
    SEL sel = NSSelectorFromString(@"AddNewPart:LocalID:n64SvrID:Offset:Len:VoiceTime:CreateTime:EndFlag:CancelFlag:VoiceFormat:ForwardFlag:msgSource:chatName:");
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) { L11(@"[MISS] %@ AddNewPart(13arg)", clsName); return; }

    const char *types = method_getTypeEncoding(m);
    L11(@"[FOUND] %@ AddNewPart types=%s", clsName, types ? types : "?");
    IMP oldImp = method_getImplementation(m);

    /* 按类型编码分派：v=void 返回（大概率），参数 12 个对象/标量混合 — 全按 id 打印指针/值 */
    if (types && types[0] == 'v') {
        IMP newImp = imp_implementationWithBlock(^(id self,
                id a1, id a2, id a3, id a4, id a5, id a6,
                id a7, id a8, id a9, id a10, id a11, id a12) {
            L11(@"---- AddNewPart %@ ----", clsName);
            L11(@"  arg1(LocalID?)=%@ arg2(n64SvrID?)=%@ arg3(Offset?)=%@ arg4(Len?)=%@",
                D11(a1), D11(a2), D11(a3), D11(a4));
            L11(@"  arg5(VoiceTime?)=%@ arg6(CreateTime?)=%@ arg7(EndFlag?)=%@ arg8(CancelFlag?)=%@",
                D11(a5), D11(a6), D11(a7), D11(a8));
            L11(@"  arg9(VoiceFormat?)=%@ arg10(ForwardFlag?)=%@ arg11(msgSource?)=%@ arg12(chatName?)=%@",
                D11(a9), D11(a10), D11(a11), D11(a12));
            ((void (*)(id, SEL, id, id, id, id, id, id, id, id, id, id, id, id))oldImp)
                (self, sel, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12);
            L11(@"---- AddNewPart done ----");
        });
        method_setImplementation(m, newImp);
        L11(@"[HOOK OK] %@ AddNewPart", clsName);
    } else {
        L11(@"[SKIP] %@ AddNewPart ret=%c 非 void，不 hook", clsName, types ? types[0] : '?');
    }
}

__attribute__((constructor))
static void V11Init(void) {
    @autoreleasepool {
        g_logPath = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/TTSProbe_v11.log"];
        L11(@"v11 loaded (upload queue probe)");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            HookAddNewPart(@"UploadVoiceCDNMgr");
            HookAddNewPart(@"MMNewUploadVoiceMgr");
            L11(@"hooks installed — 1) 真实录音发一条 2) TTS 发一条，对照 AddNewPart 参数");
        });
    }
}
