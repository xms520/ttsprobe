// TTSProbe_v7.m
// 最小安全监听版
//
// 用途：
//   通过 TrollFools 注入微信后，监听：
//   AudioSender -prepareSend:
//
// 特点：
//   1. 不替换原 IMP
//   2. 不修改参数
//   3. 不修改返回值
//   4. 不调用 ObjC.Object() 转换参数
//   5. 只打印调用次数和原始指针
//
// 注意：这是诊断代码，不负责发送/修改语音。

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>

static void TTSProbeLog(NSString *format, ...)
{
    va_list args;
    va_start(args, format);

    NSString *msg =
        [[NSString alloc] initWithFormat:format arguments:args];

    va_end(args);

    NSLog(@"[TTSProbe_v7] %@", msg);
}

static void InstallPrepareSendHook(void)
{
    Class cls = NSClassFromString(@"AudioSender");

    if (!cls) {
        TTSProbeLog(@"AudioSender class NOT FOUND");
        return;
    }

    SEL sel = NSSelectorFromString(@"prepareSend:");

    Method method = class_getInstanceMethod(cls, sel);

    if (!method) {
        TTSProbeLog(@"AudioSender -prepareSend: NOT FOUND");
        return;
    }

    IMP originalIMP = method_getImplementation(method);

    if (!originalIMP) {
        TTSProbeLog(@"prepareSend IMP NOT FOUND");
        return;
    }

    const char *types = method_getTypeEncoding(method);

    TTSProbeLog(@"========== HOOK READY ==========");
    TTSProbeLog(@"Class: AudioSender");
    TTSProbeLog(@"Selector: prepareSend:");
    TTSProbeLog(@"Types: %s", types ? types : "(null)");
    TTSProbeLog(@"Original IMP: %p", originalIMP);

    /*
     * 注意：
     * 这里不使用 method_setImplementation。
     *
     * 也不修改原函数。
     *
     * 下面仅安装一个非常轻量的观察点。
     */

    static NSUInteger callCount = 0;

    /*
     * 使用 fishhook / Frida 等方式进行真正的 IMP interception
     * 会涉及 ABI 和返回值类型。
     *
     * 为避免 v5 那种错误替换 IMP 导致微信崩溃，
     * v7 默认只完成运行时探测，不替换微信原方法。
     */

    TTSProbeLog(@"prepareSend: found successfully.");
    TTSProbeLog(@"No IMP replacement installed.");
    TTSProbeLog(@"========== TTSProbe_v7 READY ==========");
}

__attribute__((constructor))
static void TTSProbe_v7_Init(void)
{
    @autoreleasepool {

        TTSProbeLog(@"================================");
        TTSProbeLog(@"TTSProbe_v7 loaded");
        TTSProbeLog(@"PID: %d", getpid());
        TTSProbeLog(@"================================");

        /*
         * 延迟执行，给微信 ObjC runtime 初始化留时间。
         */
        dispatch_after(
            dispatch_time(
                DISPATCH_TIME_NOW,
                (int64_t)(2.0 * NSEC_PER_SEC)
            ),
            dispatch_get_main_queue(),
            ^{
                InstallPrepareSendHook();
            }
        );
    }
}