/*
 TTSProbe_TrollStore.m
 诊断型 dylib：适合通过 TrollStore/TrollFools 等方式注入目标 App。

 特点：
 1. 不 hook / 不 swizzle / 不发送消息 / 不修改目标对象。
 2. 启动后扫描 Objective-C Runtime：
    - Silk / Audio / PCM / Voice / Speech 相关类
    - CMessageWrap / CMessageMgr / MessageService 等消息相关类
    - 当前最上层 UIViewController
 3. 同时把日志写入：
       /var/mobile/Media/TTSProbe.log
 4. 也输出 NSLog，方便查看系统日志。

 注意：
 - 这是“定位器”，不是发送语音插件。
 - class_copyIvarList / class_copyMethodList 只列出当前 class 自己声明的成员；
   class_getInstanceMethod 可继续沿继承链查找方法。
*/

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <stdio.h>
#include <stdarg.h>
#include <string.h>
#include <stdlib.h>

static NSString *kLogPath = nil;

static void TP(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);

    char buf[8192];
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);

    NSString *line = [NSString stringWithFormat:@"[TTSProbe] %s\n", buf];

    // 1. stderr
    fprintf(stderr, "%s", line.UTF8String);
    fflush(stderr);

    // 2. NSLog
    NSLog(@"%s", line.UTF8String);

    // 3. 文件
    @autoreleasepool {
        NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:kLogPath];

        if (!fh) {
            [[NSFileManager defaultManager] createFileAtPath:kLogPath
                                                    contents:nil
                                                  attributes:nil];
            fh = [NSFileHandle fileHandleForWritingAtPath:kLogPath];
        }

        if (fh) {
            @try {
                [fh seekToEndOfFile];
                [fh writeData:data];
                [fh closeFile];
            } @catch (__unused NSException *e) {
            }
        }
    }
}

static BOOL StringContainsAny(const char *text, const char **keys, size_t count)
{
    if (!text) return NO;

    for (size_t i = 0; i < count; i++) {
        if (keys[i] && strcasestr(text, keys[i])) {
            return YES;
        }
    }
    return NO;
}

static void DumpIvars(Class cls)
{
    if (!cls) return;

    unsigned int count = 0;
    Ivar *ivars = class_copyIvarList(cls, &count);

    TP("  IVARS %s: %u", class_getName(cls), count);

    for (unsigned int i = 0; i < count; i++) {
        const char *name = ivar_getName(ivars[i]);
        const char *type = ivar_getTypeEncoding(ivars[i]);

        TP("    ivar=%s type=%s offset=%td",
           name ? name : "?",
           type ? type : "?",
           ivar_getOffset(ivars[i]));
    }

    if (ivars) free(ivars);
}

static void DumpMatchingMethods(Class cls,
                                const char **keys,
                                size_t keyCount)
{
    if (!cls) return;

    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);

    TP("  METHODS %s: %u", class_getName(cls), count);

    for (unsigned int i = 0; i < count; i++) {
        SEL sel = method_getName(methods[i]);
        const char *name = sel_getName(sel);

        if (StringContainsAny(name, keys, keyCount)) {
            const char *types = method_getTypeEncoding(methods[i]);
            TP("    method=%s types=%s imp=%p",
               name ? name : "?",
               types ? types : "?",
               method_getImplementation(methods[i]));
        }
    }

    if (methods) free(methods);
}

static void ProbeSelector(Class cls, const char *selectorName)
{
    if (!cls || !selectorName) return;

    SEL sel = sel_registerName(selectorName);
    Method method = class_getInstanceMethod(cls, sel);

    if (!method) {
        TP("    selector MISS: %s", selectorName);
        return;
    }

    TP("    selector HIT : %s", selectorName);
    TP("      types=%s",
       method_getTypeEncoding(method) ?: "?");
    TP("      imp=%p",
       method_getImplementation(method));
}

static void ProbeClass(const char *className,
                       const char **selectors,
                       size_t selectorCount)
{
    Class cls = objc_getClass(className);

    if (!cls) {
        TP("[CLASS MISS] %s", className);
        return;
    }

    Class superCls = class_getSuperclass(cls);

    TP("[CLASS] %s  superclass=%s",
       className,
       superCls ? class_getName(superCls) : "?");

    for (size_t i = 0; i < selectorCount; i++) {
        ProbeSelector(cls, selectors[i]);
    }

    DumpIvars(cls);

    const char *keys[] = {
        "Voice", "Audio", "PCM", "Silk", "Speech",
        "Msg", "Send", "Contact", "Chat", "User"
    };

    DumpMatchingMethods(cls,
                        keys,
                        sizeof(keys) / sizeof(keys[0]));
}

static void SearchClasses(void)
{
    const char *keys[] = {
        "Silk",
        "Speech",
        "Voice",
        "Audio",
        "PCM",
        "MsgWrap",
        "MessageMgr",
        "MessageService",
        "MsgService",
        "Chat",
        "Contact"
    };

    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);

    TP("===== CLASS SEARCH (%u classes) =====", count);

    if (!classes) {
        TP("objc_copyClassList returned NULL");
        return;
    }

    for (unsigned int i = 0; i < count; i++) {
        const char *name = class_getName(classes[i]);

        if (StringContainsAny(name,
                              keys,
                              sizeof(keys) / sizeof(keys[0]))) {
            TP("[CLASS MATCH] %s", name);
        }
    }

    free(classes);
}

static UIViewController *TopViewController(UIViewController *vc)
{
    if (!vc) return nil;

    UIViewController *presented = vc.presentedViewController;
    if (presented) {
        return TopViewController(presented);
    }

    if ([vc isKindOfClass:[UINavigationController class]]) {
        return TopViewController(
            ((UINavigationController *)vc).visibleViewController
        );
    }

    if ([vc isKindOfClass:[UITabBarController class]]) {
        return TopViewController(
            ((UITabBarController *)vc).selectedViewController
        );
    }

    if ([vc isKindOfClass:[UISplitViewController class]]) {
        UIViewController *last =
            ((UISplitViewController *)vc).viewControllers.lastObject;

        return last ? TopViewController(last) : vc;
    }

    return vc;
}

static void DumpVCHierarchy(UIViewController *vc, int depth)
{
    if (!vc || depth > 15) return;

    NSMutableString *indent = [NSMutableString string];

    for (int i = 0; i < depth; i++) {
        [indent appendString:@"  "];
    }

    TP("%sVC=%s",
       indent.UTF8String,
       NSStringFromClass(vc.class).UTF8String);

    for (UIViewController *child in vc.childViewControllers) {
        DumpVCHierarchy(child, depth + 1);
    }

    if (vc.presentedViewController) {
        DumpVCHierarchy(vc.presentedViewController, depth + 1);
    }
}

static void ProbeCurrentVC(void)
{
    @autoreleasepool {
        UIWindow *keyWindow = nil;
        UIWindow *fallbackWindow = nil;

        for (UIWindow *window in
             UIApplication.sharedApplication.windows) {

            if (window.hidden || !window.rootViewController)
                continue;

            if (!fallbackWindow) {
                fallbackWindow = window;
            }

            if (window.isKeyWindow) {
                keyWindow = window;
                break;
            }
        }

        UIWindow *window = keyWindow ?: fallbackWindow;

        if (!window) {
            TP("[VC] no usable UIWindow");
            return;
        }

        UIViewController *top =
            TopViewController(window.rootViewController);

        TP("===== CURRENT VC (sync) =====");
        TP("window=%s",
           NSStringFromClass(window.class).UTF8String);

        TP("topVC=%s",
           top ? NSStringFromClass(top.class).UTF8String : "(nil)");

        TP("----- VC HIERARCHY -----");
        DumpVCHierarchy(window.rootViewController, 0);

        if (top) {
            const char *keys[] = {
                "Msg",
                "Chat",
                "Contact",
                "User",
                "Voice",
                "Audio",
                "Send",
                "Text",
                "m_",
                "UI",
                "current"
            };

            TP("----- TOP VC ALL IVARS -----");
            DumpIvars(top.class);

            TP("----- TOP VC METHODS -----");
            DumpMatchingMethods(
                top.class,
                keys,
                sizeof(keys) / sizeof(keys[0])
            );
        }
    }
}

/* 延迟重测：等微信 UI 就绪、用户进入聊天页后，再抓一次 VC */
static void ProbeCurrentVCDeferred(int seconds)
{
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        TP("===== DEFERRED VC PROBE (%d s) =====", seconds);
        ProbeCurrentVC();
    });
}

static void ProbeKnownClasses(void)
{
    const char *silkSelectors[] = {
        "encodeToSilkFromPCMData:",
        "decodeFromSilkData:",
        "decodePCMData:",
        "decodePCMDataWithResponseData:",
        "encodePCMData:",
        "convertAudio:",
        "decodeAudio:",
        "decode:",
        "encode:"
    };

    const char *wrapSelectors[] = {
        "setM_uiMessageType:",
        "setM_nsVoiceData:",
        "setVoiceData:",
        "setM_dtVoice:",
        "setM_nsLocalXmlData:",
        "m_nsVoiceData",
        "voiceData",
        "audioData"
    };

    const char *mgrSelectors[] = {
        "AddMsg:MsgWrap:",
        "addMsg:MsgWrap:",
        "SendMsg:",
        "sendMsg:",
        "sendMessage:",
        "sendMessage:toUsr:",
        "SendMessage:",
        "sendMessage:toUsr:msgType:",
        "sendMessage:message:"
    };

    TP("===== AUDIO / SILK =====");
    ProbeClass("MJSilkCodec",
               silkSelectors,
               sizeof(silkSelectors) / sizeof(silkSelectors[0]));

    TP("===== MESSAGE WRAP =====");
    ProbeClass("CMessageWrap",
               wrapSelectors,
               sizeof(wrapSelectors) / sizeof(wrapSelectors[0]));

    TP("===== MESSAGE MANAGER =====");
    ProbeClass("CMessageMgr",
               mgrSelectors,
               sizeof(mgrSelectors) / sizeof(mgrSelectors[0]));

    TP("===== MESSAGE SERVICE =====");
    ProbeClass("MessageService",
               mgrSelectors,
               sizeof(mgrSelectors) / sizeof(mgrSelectors[0]));

    ProbeClass("CMessageService",
               mgrSelectors,
               sizeof(mgrSelectors) / sizeof(mgrSelectors[0]));
}

__attribute__((constructor))
static void TTSProbeEntry(void)
{
    @autoreleasepool {
        // 巨魔(无越狱)可写路径：微信沙盒 Documents，避免 /var/mobile/Media 无权限
        NSString *home = NSHomeDirectory();
        kLogPath = [home stringByAppendingPathComponent:@"Documents/TTSProbe.log"];

        TP("========================================");
        TP("TTSProbe loaded");
        TP("MODE: TrollStore diagnostic");
        TP("NO HOOK / NO SWIZZLE / NO SEND / NO MODIFY");
        TP("LOG FILE: %s", kLogPath.UTF8String);
        TP("========================================");

        SearchClasses();
        ProbeKnownClasses();
        ProbeCurrentVC();

        /* 延迟重测：等微信 UI 就绪、用户进入聊天页后再抓 VC（同步版已能抓，这里再补两次） */
        ProbeCurrentVCDeferred(3);
        ProbeCurrentVCDeferred(8);

        TP("===== PROBE INITIAL PASS COMPLETE =====");
        TP("Enter a chat page, wait ~8s, then check Documents/TTSProbe.log for DEFERRED VC PROBE.");
    }
}
