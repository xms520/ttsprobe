/*
 * wx_chain.m — 微信发送链（双宿主插件 QQFloat 的微信侧编译单元）
 * 来源: TTSFloat_v30.m 的微信链（fishhook AudioQueueNewInput C 层替换 +
 *       复刻微信自己的 StartRecordFrom / StopRecord → 微信自己编码、自己发送）
 *
 * 与 QQFloat_v5.m（QQ 链 + 共用 UI/引擎）一起编成同一个 dylib：
 *   微信宿主: 面板「合成语音」→ WXChainSendWithPcm() → 全自动录音/发送
 *   QQ 宿主  : 面板「合成语音」→ 注入待命 → 手动按住语音按钮发送
 *
 * 隔离: 本编译单元不定义任何 ObjC 类；所有符号加 WX 前缀，与主单元的 static 互不冲突。
 */
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <string.h>
#import <stdlib.h>
#include "fishhook.h"

/* ==================== 对外接口（主单元调用） ==================== */
BOOL WXChainIsWeChatBundle(void);
void WXChainSetLogPath(NSString *p);
void WXChainInstallHooks(void);
void WXChainSendWithPcm(NSData *pcm, void (^status)(NSString *text));
BOOL WXChainHasSession(void);
void WXChainArmInjectionWithPcm(NSData *pcm);

static NSString *g_wxLogPath = nil;
void WXChainSetLogPath(NSString *p) { g_wxLogPath = [p copy]; }

/* 与主单元同格式的日志（同一文件追加，行首 [WXCHAIN] 区分） */
static void WXLog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[WXCHAIN] %@", s);
    if (!g_wxLogPath) return;
    @autoreleasepool {
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:g_wxLogPath];
        if (!fh) {
            [[NSFileManager defaultManager] createFileAtPath:g_wxLogPath contents:nil attributes:nil];
            fh = [NSFileHandle fileHandleForWritingAtPath:g_wxLogPath];
        }
        if (fh) {
            [fh seekToEndOfFile];
            [fh writeData:[[NSString stringWithFormat:@"[WXCHAIN] %@\n", s] dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        }
    }
}

static NSInteger g_wxTargetSampleRate = 16000;   /* 微信链 PCM 采样率(与主单元一致) */
static void WXChainFinishRecord(int waitedMs, void (^status)(NSString *));
/* ===== WX-CHAIN A_obf ===== */
static NSString *WXXorHex(const char *hex, int key) {
    if (!hex) return nil;
    NSUInteger n = strlen(hex) / 2;
    NSMutableString *o = [NSMutableString stringWithCapacity:n];
    for (NSUInteger i = 0; i < n; i++) {
        /* hex→int（标准写法；此前 'a'-'0' 的偏移写错导致解码全乱 → 类名 MISS）*/
        int hi = hex[i*2];   if (hi >= 'a') hi -= 'a' - 10; else hi -= '0';
        int lo = hex[i*2+1]; if (lo >= 'a') lo -= 'a' - 10; else lo -= '0';
        int v = (hi << 4) | lo;
        v ^= key;
        if (v == 0) break;   /* 密文不含 0x00；遇到即截断 */
        [o appendFormat:@"%C", (unichar)v];
    }
    return o;
}

/* v26: XOR 密文表（k=0x5A 类名 / k=0x3C selector）——strings 搜不到明文 */
static NSArray *WXObfTable(void) {
    static NSArray *t = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ t = @[
        @"1b2f3e3335093f343e3f28"  /* cls */,
        @"17100933363119353e3f39"  /* cls */,
        @"4c4e594c5d4e596f59525806"  /* sel */,
        @"6f48534c6e595f534e58"  /* sel */,
        @"73526e595f534e58594e7952586e595f534e5855525b06"  /* sel */,
        @"73526e595f534e58594e7952586e595f534e5855525b06694f594e785d485d06"  /* sel */,
        @"73526e595f534e58594e7952586e595f534e5855525b06794e4e534e06"  /* sel */,
        @"73526e595f534e58594e6c5d4e4806735a5a4f594806705952067952587a505d5b067a534e5f597859505948590678494e5d4855535206"  /* sel */,
        @"73527349484c49486c5f517e495a5a594e06694f594e785d485d06"  /* sel */,
        @"7d495855536d4959495972594b75524c4948"  /* sel */,
        @"6f485d4e486e595f534e587a4e5351066853694f594e06694f594e75525a5306"  /* sel */,
        @"6f595258734e556a53555f59714f5b6b554854694f594e785d485d06"  /* sel */
,
        @"48594448"  /* text */,
        @"4a53555f59"  /* voice */,
        @"5d4c55575945"  /* apikey */        ]; });
    return t;
}
static NSString *WXCls(int i) { return WXXorHex([WXObfTable()[i] UTF8String], 0x5A); }
static NSString *WXSel(int i) { return WXXorHex([WXObfTable()[2 + i] UTF8String], 0x3C); }

/* ===== WX-CHAIN B_glob ===== */


static NSData *g_wxPendingPCM = nil;       /* TTS 合成的完整 PCM */
static NSUInteger g_wxPcmOffset = 0;       /* 已喂位置 */
static BOOL g_wxReplaceActive = NO;        /* 替换开关 */
static BOOL g_wxPcmFedDone = NO;           /* TTS 数据已全部喂进管线（StopRecord 时机依据） */

/* ===== WX-CHAIN C_chat ===== */
static NSString *WXStringify(id v) {
    if (!v) return nil;
    if ([v isKindOfClass:[NSString class]]) return v;
    if ([v isKindOfClass:[NSNumber class]]) return [(NSNumber *)v stringValue];
    return nil;
}
/* v28c: 值探测——不再猜 ivar 名，直接遍历全部 ivar，找值长得像会话 id 的字符串
 *（wxid_xxx / xxx@chatroom / gh_ 开头，长度 6-60）。同时 dump ivar 名清单（一次）辅助定位。 */
static BOOL WXLookLikeSessionId(NSString *s) {
    if (![s isKindOfClass:[NSString class]] || s.length < 6 || s.length > 60) return NO;
    if ([s hasPrefix:@"wxid_"]) return YES;
    if ([s hasSuffix:@"@chatroom"]) return YES;
    if ([s hasPrefix:@"gh_"] && s.length > 10) return YES;
    /* v29b: 企业微信/其他格式——无空格、无尖括号、非纯数字的 id 也接受
     *（覆盖 wxwork_/wm_/openim 等未知前缀，宁可多收不漏收，打日志确认） */
    if ([s rangeOfString:@" "].location == NSNotFound &&
        [s rangeOfString:@"<"].location == NSNotFound &&
        ![NSCharacterSet.decimalDigitCharacterSet isSupersetOfSet:
            [NSCharacterSet characterSetWithCharactersInString:s]]) return YES;
    return NO;
}
/* v28d: 崩溃修复——v28c 的 object_getIvar 全量裸扫 + 对象下钻会踩到
 * 微信 C++ 混合类的不安全字段（SIGSEGV，@try 拦不住信号）。
 * 改为 KVC valueForKey: 只读探测（KVC 内部有完整防护，异常能被 @catch）：
 *   ① class_copyIvarList 只拿【ivar 名清单】（不碰值）
 *   ② 每个名字走 [vc valueForKey:name] 读值（安全 API）
 *   ③ 只扫一层，不做对象下钻（崩溃面最大的部分）
 *   ④ 限制 200 个 ivar 以内 */
static NSString *WXPeerFromChatVC(id vc) {
    if (!vc) return nil;
    static BOOL dumpedIvars = NO;
    /* v28e: 本类 ivar 可能为空（混合类字段在父类）→ 沿父类链逐层扫（每层 KVC 安全读）。
     * 跳过系统层（UIViewController/UIViewController 以下不扫，没意义）。 */
    Class c = object_getClass(vc);
    int levels = 0;
    while (c && c != [NSObject class] && levels < 8) {
        unsigned int n = 0;
        Ivar *ivs = class_copyIvarList(c, &n);
        if (!ivs) { c = class_getSuperclass(c); levels++; continue; }
        for (unsigned int i = 0; i < n && i < 300; i++) {
            const char *nmC = ivar_getName(ivs[i]);
            if (!nmC) continue;
            NSString *key = [NSString stringWithUTF8String:nmC];
            if (!key.length) continue;
            if (!dumpedIvars) WXLog(@"[ivar] %@", key);   /* dump 不截断（定位用） */
            @try {
                id v = [vc valueForKey:key];   /* KVC：安全读，异常走 @catch */
                NSString *sv = WXStringify(v);
                if (sv.length && WXLookLikeSessionId(sv)) {
                    if (!dumpedIvars) {
                        WXLog(@"[chat] 命中 ivar=%@ 值=%@", key, sv);
                        dumpedIvars = YES;
                    }
                    free(ivs);
                    return sv;
                }
                /* v29b: 群聊/企业微信兜底——固定键 KVC 探测（聊天逻辑层常见字段） */
                if (v && ![v isKindOfClass:[NSString class]]) {
                    for (NSString *fixedKey in @[@"m_nsTalker", @"m_nsFromUsr", @"m_nsChatName",
                                                 @"talker", @"m_nsUserName", @"nsTalker"]) {
                        @try {
                            NSString *fv = WXStringify([v valueForKey:fixedKey]);
                            if (fv.length && WXLookLikeSessionId(fv)) {
                                WXLog(@"[chat] 命中固定键 %@.%@ 值=%@", key, fixedKey, fv);
                                free(ivs);
                                return fv;
                            }
                        } @catch (NSException *e) { }
                    }
                }
                /* v28f: KVC 安全下钻——值是对象（非 view/字符串/数据）→ 用 KVC 扫它的 ivar
                 * （v28c 崩在 object_getIvar 裸读；这里全部走 valueForKey，不裸读） */
                if (v && ![v isKindOfClass:[NSString class]] && ![v isKindOfClass:[NSNumber class]]
                    && ![v isKindOfClass:[NSData class]] && ![v isKindOfClass:[UIView class]]
                    && ![v isKindOfClass:[NSArray class]] && ![v isKindOfClass:[NSDictionary class]]
                    && [NSStringFromClass([v class]) length] > 0
                    && ![NSStringFromClass([v class]) hasPrefix:@"NS"]
                    && ![NSStringFromClass([v class]) hasPrefix:@"UI"]
                    && ![NSStringFromClass([v class]) hasPrefix:@"__"]) {
                    @try {
                        Class c2 = object_getClass(v);
                        int lv2 = 0;
                        while (c2 && c2 != [NSObject class] && lv2 < 6) {
                            unsigned int n2 = 0;
                            Ivar *ivs2 = class_copyIvarList(c2, &n2);
                            for (unsigned int k = 0; ivs2 && k < n2 && k < 150; k++) {
                                const char *nm2 = ivar_getName(ivs2[k]);
                                if (!nm2) continue;
                                NSString *key2 = [NSString stringWithUTF8String:nm2];
                                if (!key2.length) continue;
                                @try {
                                    NSString *sv2 = WXStringify([v valueForKey:key2]);
                                    if (sv2.length && WXLookLikeSessionId(sv2)) {
                                        WXLog(@"[chat] 命中下钻 %@.%@ 值=%@", key, key2, sv2);
                                        if (ivs2) free(ivs2);
                                        free(ivs);
                                        return sv2;
                                    }
                                } @catch (NSException *e2) { }
                            }
                            if (ivs2) free(ivs2);
                            c2 = class_getSuperclass(c2);
                            lv2++;
                        }
                    } @catch (NSException *e3) { }
                }
            } @catch (NSException *e) { }
        }
        free(ivs);
        if (!dumpedIvars) { WXLog(@"[ivar] ---- 以上为 %s 层 ----", class_getName(c)); dumpedIvars = YES; }
        c = class_getSuperclass(c);
        levels++;
    }
    return nil;
}

/* 遍历 VC 树，返回第一个"像聊天页"的 VC。
 * v28 首版类名匹配（MsgContentViewController/ChatRoomView/BaseMsgContent）实测没命中
 * → v28b 宽化：类名含 Message/Chat/Conversation 之一即算候选，再逐个试取用户名，
 *   取到 wxid/chatroom 才认定。找不到时 dump 整棵 VC 类名树（打一次日志，用于人工定位）。 */
static NSString *WXPeerFromChatVC(id vc);

static BOOL WXLooksLikeChatVC(NSString *cn) {
    if (!cn.length) return NO;
    /* v28c: 实测确认的真实类名（TTSFloat_7.log [vc-tree]）*/
    NSArray *keys = @[@"BaseMsgContentViewController", @"MsgContentViewController",
                      @"ChatRoomView", @"MessageViewController", @"ConversationView"];
    for (NSString *k in keys) {
        if ([cn rangeOfString:k].location != NSNotFound) return YES;
    }
    return NO;
}
static id WXFindChatVC(void) {
    static BOOL dumped = NO;
    id best = nil;
    id listPageVC = nil;   /* v28g: 会话列表页（兜底） */
    /* v28e: NewMainFrameViewController（聊天容器）也作为候选（会话 id 可能挂在容器上） */
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        UIViewController *root = w.rootViewController;
        if (!root) continue;
        NSMutableArray *stack = [NSMutableArray arrayWithObject:root];
        while (stack.count) {
            UIViewController *cur = stack.lastObject;
            [stack removeLastObject];
            NSString *cn = NSStringFromClass([cur class]);
            /* v28g: 分级候选——真聊天页一级；NewMainFrame（会话列表页）只做最后兜底，
             * 因为它里面的会话 id 是"上次阅读缓存"（m_readerReporter._usrName），不是当前打开的对话 */
            if (WXLooksLikeChatVC(cn)) {
                NSString *peer = WXPeerFromChatVC(cur);
                if (peer.length) { dumped = YES; return cur; }
                if (!best) best = cur;
            } else if ([cn isEqualToString:@"NewMainFrameViewController"]) {
                if (!listPageVC) listPageVC = cur;   /* 会话列表页，最后再试 */
            }
            if (!dumped) {
                /* 诊断：把整棵 VC 树类名打出来（只打一次；行首 [vc-tree]） */
                WXLog(@"[vc-tree] %@", cn);
            }
            if (cur.presentedViewController) [stack addObject:cur.presentedViewController];
            for (UIViewController *child in cur.childViewControllers) [stack addObject:child];
        }
        if (!dumped) dumped = YES;   /* 第一个窗口树 dump 完就不再打 */
    }
    /* v28g: 有真聊天页候选就用；没有才回落会话列表页（值可能是上次阅读的会话） */
    if (best) return best;
    if (listPageVC) {
        NSString *peer = WXPeerFromChatVC(listPageVC);
        if (peer.length) {
            WXLog(@"[chat] 聊天页未找到——回落会话列表页缓存（可能不是当前对话）: %@", peer);
            return listPageVC;
        }
    }
    return nil;
}
static NSString *WXCurrentChatPeer(void) {
    static NSString *lastHit = nil;
    id vc = WXFindChatVC();
    if (!vc) return lastHit;
    NSString *peer = WXPeerFromChatVC(vc);
    if (peer.length) {
        lastHit = peer;
        return peer;
    }
    return lastHit;   /* 探测失败回落上次成功的值 */
}

/* ===== WX-CHAIN D_sess ===== */
static NSString *const kSessionFromKey = @"TTSFloatFrom";
static NSString *const kSessionToKey   = @"TTSFloatTo";
static NSString *const kSessionInfoKey = @"TTSFloatInfo";

static void WXSaveSession(NSString *from, NSString *to, NSDictionary *info) {
    if (from.length) [NSUserDefaults.standardUserDefaults setObject:from forKey:kSessionFromKey];
    if (to.length)   [NSUserDefaults.standardUserDefaults setObject:to   forKey:kSessionToKey];
    if (info.count) {
        NSError *e = nil;
        NSData *jd = [NSJSONSerialization dataWithJSONObject:info options:0 error:&e];
        if (jd && !e) [NSUserDefaults.standardUserDefaults setObject:[jd base64EncodedStringWithOptions:0]
                                                            forKey:kSessionInfoKey];
    }
}
static NSDictionary *WXLoadSessionInfo(void) {
    NSString *b64 = [NSUserDefaults.standardUserDefaults stringForKey:kSessionInfoKey];
    if (!b64.length) return nil;
    NSData *jd = [[NSData alloc] initWithBase64EncodedString:b64 options:0];
    if (!jd) return nil;
    id o = [NSJSONSerialization JSONObjectWithData:jd options:0 error:nil];
    return [o isKindOfClass:[NSDictionary class]] ? o : nil;
}


/* ===== WX-CHAIN E_start ===== */
static id g_wxLastFrom = nil;
static id g_wxLastUserInfo = nil;

static void WXInstallStartRecordObserver(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class cls = NSClassFromString(WXCls(0));
        if (!cls) return;
        SEL sel = NSSelectorFromString(WXSel(8));
        Method m = class_getInstanceMethod(cls, sel);
        if (!m) { WXLog(@"[obs] start MISS"); return; }
        const char *types = method_getTypeEncoding(m);
        WXLog(@"[obs] start types=%s", types ? types : "?");
        IMP oldImp = method_getImplementation(m);
        IMP newImp = imp_implementationWithBlock(^BOOL(id self, id from, id toUser, id userInfo) {
            @autoreleasepool {
                WXLog(@"[obs] start: from=%@(%@) to=%@(%@) info=%@",
                      from ? NSStringFromClass([from class]) : @"nil",
                      from ? [from description] : @"-",
                      toUser ? NSStringFromClass([toUser class]) : @"nil",
                      toUser ? [toUser description] : @"-",
                      userInfo ? NSStringFromClass([userInfo class]) : @"nil");
                @synchronized([NSObject class]) {
                    g_wxLastFrom = from;
                    g_wxLastUserInfo = userInfo;
                }
                /* v27: 持久化（跨启动直接可用；换会话兜底） */
                WXSaveSession(from, toUser, [userInfo isKindOfClass:[NSDictionary class]] ? userInfo : nil);
            }
            return ((BOOL (*)(id, SEL, id, id, id))oldImp)(self, sel, from, toUser, userInfo);
        });
        method_setImplementation(m, newImp);
        WXLog(@"[obs] installed");
    });
}

/* ===== WX-CHAIN F_aq ===== */
/* ==================== AudioQueue C 层替换（数据真正的源头） ==================== */
static AudioQueueInputCallback g_wxOrigAQCb = NULL;  /* 微信的原始回调 */
static void *g_wxUserData = NULL;

/* trampoline：微信回调前替换 buffer 内容（官方 AudioToolbox 类型） */
/* v22: 实时节奏喂数
 * v21 每次把整个 buffer 塞满 TTS 字节 → 一次回调吃掉 6144B(=192ms@16k) 的 TTS 内容。
 * 若 buffer 实际只代表 64ms（微信录音器 48kHz），喂数速度 = 3× 实时
 * → 录音会话总时长被压成 1/3 → 微信只录到 TTS 开头几帧就被 StopRecord 截断（转圈/半截语音）。
 * v22 按【实测采集速率】喂：buffer/回调间隔 = 录音器真实字节速率，
 * 每次只消耗 (速率 × 距上次回调毫秒) 对应的 16kHz TTS 字节，buffer 其余补零。
 * 这样录音器看到的是时长与内容完全自洽的 16kHz 流（末尾静音），
 * OnRecorderPart 才会像真实录音那样正常提交分片。 */
/* v23 喂数策略：整块填满（v19 已验证音质干净的写法）
 * ⚠️ v22 的"按实测速率节奏喂"被日志判死：微信每次回调给的 buffer 大小不固定
 * （实测 6144 / 7018 / 8000 / 2570），rate×dt 恒小于 buffer →
 * TTS 字节流和 buffer 流对不齐，缺口被补零 → 语音里每隔 250ms 插一段静音 = 杂音。
 * 实测证据（v22 日志）：buffer 累计 142736B(=4.46s) 而 TTS 只有 107498B(=3.36s)。
 * v23：每次把整块 buffer 用连续 TTS 字节填满（块内零间隙），耗尽后整块补零。
 * 采样率铁证：buffer=8000B(4000 样本) 间隔 250ms → 16kHz 16bit mono → 32000B/s，
 * 真实录音 buffer=6144B 间隔 192ms 同样 32000B/s。 */
static uint64_t g_wxAqLastNs = 0;      /* 上次回调时间戳（仅诊断） */
static uint32_t g_wxAqRateBps = 0;     /* 实测采集速率 B/s（仅诊断） */
static NSUInteger g_wxAqCbSeq = 0;     /* 回调序号 */
static uint64_t g_wxAqStartNs = 0;
static BOOL g_wxAqFormatLogged = NO;   /* ASBD 只打一次 */

static void WXAQInputTrampoline(void *inUserData, AudioQueueRef inAQ,
                                  AudioQueueBuffer *inBuffer,
                                  const AudioTimeStamp *inStartTime,
                                  UInt32 inNumberPacketDescriptions,
                                  const AudioStreamPacketDescription *inPacketDescs) {
    if (g_wxReplaceActive && g_wxPendingPCM && inBuffer && inBuffer->mAudioData) {
        @synchronized([NSObject class]) {
            uint64_t now = clock_gettime_nsec_np(CLOCK_MONOTONIC);
            uint64_t dtNs = 0;
            if (g_wxAqLastNs && now > g_wxAqLastNs) dtNs = now - g_wxAqLastNs;
            uint32_t bufSz = inBuffer->mAudioDataByteSize;
            if (g_wxAqCbSeq == 0) { g_wxAqStartNs = now; dtNs = 0; }
            g_wxAqLastNs = now;
            g_wxAqCbSeq++;

            /* 诊断：实测采集速率（buffer/dt）——用来核对 PCM 采样率是否 16kHz */
            if (dtNs > 2 * 1000 * 1000 && dtNs < 2000LL * 1000 * 1000) {
                uint32_t r = (uint32_t)((uint64_t)bufSz * 1000000000ULL / dtNs);
                if (r >= 1000 && r <= 4000000 && (g_wxAqRateBps == 0 || g_wxAqCbSeq <= 6)) g_wxAqRateBps = r;
            }
            NSUInteger total = g_wxPendingPCM.length;
            if (g_wxPcmOffset < total) {
                /* 整块填满：块内不留间隙（杂音根因就是间隙） */
                NSUInteger take = MIN((NSUInteger)bufSz, total - g_wxPcmOffset);
                memcpy(inBuffer->mAudioData, (const char *)g_wxPendingPCM.bytes + g_wxPcmOffset, take);
                if (take < bufSz) memset((char *)inBuffer->mAudioData + take, 0, bufSz - take);
                g_wxPcmOffset += take;
            } else {
                memset(inBuffer->mAudioData, 0, bufSz);
                if (!g_wxPcmFedDone) {
                    g_wxPcmFedDone = YES;      /* 喂完标记（自动发送的 StopRecord 时机依据） */
                    g_wxReplaceActive = NO;    /* v5.1: 立刻关替换 → 再录音就是真实麦克风 */
                    WXLog(@"[wx-inject] PCM 全部喂完 — 已关闭替换（cb=%lu）", (unsigned long)g_wxAqCbSeq);
                }
            }
            /* 每次回调都记录（seq/size/dt/est-rate/fed/total） */
            WXLog(@"[aq-cb] #%lu size=%u dt=%llums rate=%uB/s fed=%lu/%lu",
                  (unsigned long)g_wxAqCbSeq, bufSz,
                  (unsigned long long)(dtNs / 1000000ULL), g_wxAqRateBps,
                  (unsigned long)g_wxPcmOffset, (unsigned long)total);
        }
    }
    /* 调微信原回调（微信以为是自己录的音，实际是 TTS 数据） */
    if (g_wxOrigAQCb) {
        g_wxOrigAQCb(inUserData, inAQ, inBuffer, inStartTime, inNumberPacketDescriptions, inPacketDescs);
    }
}

/* rebind AudioQueueNewInput */
static OSStatus (*wxOrig_AudioQueueNewInput)(const AudioStreamBasicDescription *inFormat,
                                           AudioQueueInputCallback inCallbackProc,
                                           void *inUserData, CFRunLoopRef inCFRunLoop,
                                           CFStringRef inCFRunLoopMode,
                                           UInt32 inFlags, AudioQueueRef *outAQ);

static OSStatus WXAudioQueueNewInput(const AudioStreamBasicDescription *inFormat,
                                       AudioQueueInputCallback inCallbackProc,
                                       void *inUserData, CFRunLoopRef inCFRunLoop,
                                       CFStringRef inCFRunLoopMode,
                                       UInt32 inFlags, AudioQueueRef *outAQ) {
    if (inCallbackProc && inUserData) {
        WXLog(@"[aq-hook] AudioQueueNewInput 拦截成功（录音回调将经过 trampoline）");
        if (inFormat && !g_wxAqFormatLogged) {
            g_wxAqFormatLogged = YES;
            char fcode[5] = { (char)((inFormat->mFormatID >> 24) & 0xFF),
                              (char)((inFormat->mFormatID >> 16) & 0xFF),
                              (char)((inFormat->mFormatID >> 8) & 0xFF),
                              (char)(inFormat->mFormatID & 0xFF), 0 };
            WXLog(@"[aq-fmt] 申请格式 sampleRate=%.0f channels=%u fmt=%s bits=%u bytes/pkt=%u",
                  inFormat->mSampleRate, (unsigned)inFormat->mChannelsPerFrame, fcode,
                  (unsigned)inFormat->mBitsPerChannel, (unsigned)inFormat->mBytesPerPacket);
        }
        g_wxOrigAQCb = inCallbackProc;
        g_wxUserData = inUserData;
        return wxOrig_AudioQueueNewInput(inFormat, WXAQInputTrampoline, inUserData,
                                       inCFRunLoop, inCFRunLoopMode, inFlags, outAQ);
    }
    return wxOrig_AudioQueueNewInput(inFormat, inCallbackProc, inUserData, inCFRunLoop, inCFRunLoopMode, inFlags, outAQ);
}

static void WXInstallAudioQueueHook(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        /* fishhook rebind（CoreAudio 动态库符号） */
        struct rebinding r;
        r.name = [WXSel(7) UTF8String];
        r.replacement = (void *)WXAudioQueueNewInput;
        r.replaced = (void **)&wxOrig_AudioQueueNewInput;
        struct rebinding rebinds[1];
        rebinds[0] = r;
        int err = rebind_symbols(rebinds, 1);
        WXLog(@"[aq-hook] fishhook installed err=%d", err);
    });
}

/* ===== WX-CHAIN G_prep ===== */
static int g_wxPrepareSendSeen = 0;      /* prepareSend: 触发次数（= 发送链是否启动） */
static NSString *g_wxLastToUsr = nil;
static id g_wxAudioSender = nil;
static id g_wxLastUserData = nil;

static void WXInstallPrepareSendCapture(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class cls = NSClassFromString(WXCls(0));
        if (!cls) { WXLog(@"[capture] cls MISS"); return; }
        SEL sel = NSSelectorFromString(WXSel(0));
        Method m = class_getInstanceMethod(cls, sel);
        if (!m) { WXLog(@"[capture] send-hook MISS"); return; }

        const char *types = method_getTypeEncoding(m);
        IMP oldImp = method_getImplementation(m);

        if (types && types[0] == 'B') {
            IMP newImp = imp_implementationWithBlock(^BOOL(id self, id arg) {
                @try {
                    @synchronized([NSObject class]) {
                        if (g_wxAudioSender != self) g_wxAudioSender = self;
                        if (arg && g_wxLastUserData != arg) g_wxLastUserData = arg;
                    }
                    g_wxPrepareSendSeen++;
                    WXLog(@"[capture] send-hook #%d", g_wxPrepareSendSeen);
                    if (arg) {
                        id to = [arg valueForKey:@"tousr"];
                        if ([to isKindOfClass:[NSString class]] && [(NSString *)to length] > 0) {
                            @synchronized([NSObject class]) { g_wxLastToUsr = [to copy]; }
                        }
                    }
                } @catch (NSException *e) { }
                return ((BOOL (*)(id, SEL, id))oldImp)(self, sel, arg);
            });
            method_setImplementation(m, newImp);
            WXLog(@"[capture] send-hook installed");
        }
    });
}

/* ==================== 核心：OnOutputPcmBuffer:UserData: Hook ====================
 * 真实录音时微信每帧 PCM 都经过这里（v8b 调用栈证实）。
 * 我们把 PCM 数据替换成 TTS PCM；返回值/其他参数原样传递。

/* ===== WX-CHAIN H_part ===== */
static void WXInstallRecorderPartObserver(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class cls = NSClassFromString(WXCls(0));
        if (!cls) { WXLog(@"[part-obs] cls MISS"); return; }
        SEL sel = NSSelectorFromString(WXSel(5));
        Method m = class_getInstanceMethod(cls, sel);
        if (!m) { WXLog(@"[part-obs] part MISS"); return; }

        const char *types = method_getTypeEncoding(m);
        IMP oldImp = method_getImplementation(m);
        WXLog(@"[part-obs] types=%s", types ? types : "?");
        char ret = types ? types[0] : 'v';
        if (ret != 'v') { WXLog(@"[part-obs] 返回 %c 非 void，不 hook", ret); return; }

        /* v17: 签名已确认 v44@0:8@16I24I28I32B36I40（对象+4u32+BOOL）
         * 按精确布局 hook：block 参数 (id, id, uint32, uint32, uint32, BOOL, uint32)
         * v11b 崩因是参数个数/类型猜错；这次每参按 types 对齐 */
        IMP newImp = imp_implementationWithBlock(^(id self, id part,
                                                   uint32_t offset, uint32_t len,
                                                   uint32_t endFlag, BOOL forceDelete,
                                                   uint32_t duration) {
            @autoreleasepool {
                NSUInteger plen = 0;
                if ([part isKindOfClass:[NSData class]]) plen = [part length];
                WXLog(@"[part] off=%u len=%u end=%u forceDel=%d dur=%u part=%luB",
                      offset, len, endFlag, forceDelete, duration, (unsigned long)plen);
            }
            ((void (*)(id, SEL, id, uint32_t, uint32_t, uint32_t, BOOL, uint32_t))oldImp)
                (self, sel, part, offset, len, endFlag, forceDelete, duration);
        });
        method_setImplementation(m, newImp);
        WXLog(@"[part-obs] hooked（按精确签名）");
    });
}


/* ===== WX-CHAIN I_end ===== */
static id g_wxRealEndUserData = nil;
static NSString *g_wxRealEndSelector = nil;
static int g_wxRecorderEndSeen = 0;
static NSTimeInterval g_wxRecorderEndTime = 0;   /* 最近一次真实结束回调时刻 */

static void WXInstallRecorderEndCapture(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class cls = NSClassFromString(WXCls(0));
        if (!cls) { WXLog(@"[end-obs] cls MISS"); return; }
        NSArray *cands = @[ WXSel(2),
                            WXSel(3),
                            WXSel(4) ];
        for (NSString *name in cands) {
            SEL sel = NSSelectorFromString(name);
            Method m = class_getInstanceMethod(cls, sel);
            if (!m) continue;
            const char *types = method_getTypeEncoding(m);
            if (!types || !strstr(types, "@0:8@16")) {   /* 只 hook 单对象参形态 */
                WXLog(@"[end-obs] %@ types=%s 非单对象参，跳过", name, types ? types : "?");
                continue;
            }
            IMP oldImp = method_getImplementation(m);
            IMP newImp = imp_implementationWithBlock(^id(id self, id arg) {
                @autoreleasepool {
                    g_wxRecorderEndSeen++;
                    g_wxRecorderEndTime = [NSDate date].timeIntervalSinceReferenceDate;
                    @synchronized([NSObject class]) {
                        if (g_wxAudioSender != self) g_wxAudioSender = self;
                        if (arg) g_wxRealEndUserData = arg;
                        g_wxRealEndSelector = name;
                    }
                    WXLog(@"[end-obs] %@ self=%p arg=%p(%@)", name, (__bridge void *)self,
                          (__bridge void *)arg, arg ? NSStringFromClass([arg class]) : @"nil");
                }
                return ((id (*)(id, SEL, id))oldImp)(self, sel, arg);
            });
            method_setImplementation(m, newImp);
            WXLog(@"[end-obs] hooked %@ types=%s", name, types);
        }
    });
}
/* ==================== 微信发送主流程 ====================
 * 合成好的 PCM → 装填 AQ 替换缓存 → 复刻微信自己的 StartRecordFrom:ToUser:UserInfo:
 * → AudioQueue trampoline 把 TTS PCM 当"麦克风数据"喂进微信录音管线
 * → PCM 喂完后主线程复刻 StopRecord → 微信自己的结束链(OnRecorderEndRecording →
 *   SendOriVoiceMsgWithUserData → prepareSend)把消息发到当前会话。全程不需用户操作。 */
void WXChainSendWithPcm(NSData *pcm, void (^status)(NSString *)) {
    void (^say)(NSString *) = ^(NSString *t) { if (status && t) status(t); };
    if (!pcm.length) { say(@"PCM 为空"); return; }

    id audioSender = nil; NSString *peer = nil; NSString *myWxid = nil; id userInfo = nil;
    @synchronized([NSObject class]) {
        peer = [g_wxLastToUsr copy];
        myWxid = g_wxLastFrom;
        userInfo = g_wxLastUserInfo;
        audioSender = g_wxAudioSender;
    }
    /* ① 当前聊天自动识别（换对话不用再捕捉） */
    NSString *autoPeer = WXCurrentChatPeer();
    if (autoPeer.length) {
        if (![autoPeer isEqualToString:(peer ?: @"")])
            WXLog(@"[chat] 自动识别当前聊天: %@（旧:%@）", autoPeer, peer ?: @"-");
        peer = autoPeer;
    }
    /* ② 内存没有 → 持久化恢复 */
    if (!peer.length)   peer   = [NSUserDefaults.standardUserDefaults stringForKey:kSessionToKey];
    if (!myWxid.length) myWxid = [NSUserDefaults.standardUserDefaults stringForKey:kSessionFromKey];
    if (!userInfo)      userInfo = WXLoadSessionInfo();
    if (userInfo && ![userInfo isKindOfClass:[NSDictionary class]]) userInfo = nil;
    if (!peer.length)   { say(@"先按住说话一次（捕获会话）"); return; }
    if (!myWxid.length) { say(@"先按住说话一次（捕获身份）"); return; }

    /* ③ AudioSender 懒创建（没录过音就没有实例） */
    if (!audioSender) {
        Class senderCls = NSClassFromString(WXCls(0));
        if (senderCls) {
            @try {
                id fresh = [[senderCls alloc] init];
                if (fresh) {
                    @synchronized([NSObject class]) { g_wxAudioSender = fresh; }
                    audioSender = fresh;
                    WXLog(@"[chat] AudioSender 现场创建 %p（免捕捉首次发送）", (__bridge void *)fresh);
                }
            } @catch (NSException *e) { WXLog(@"[chat] AudioSender 创建失败: %@", e); }
        }
    }
    if (!audioSender) { say(@"发送器未就绪"); return; }

    NSUInteger ms = pcm.length * 1000 / (NSUInteger)(g_wxTargetSampleRate * 2);

    /* ④ 装填 C 层替换缓存（trampoline 消费） */
    @synchronized([NSObject class]) {
        g_wxPendingPCM = pcm;
        g_wxPcmOffset = 0;
        g_wxReplaceActive = YES;
        g_wxPcmFedDone = NO;
        g_wxAqLastNs = 0; g_wxAqRateBps = 0; g_wxAqCbSeq = 0; g_wxAqStartNs = 0;
        g_wxAqFormatLogged = NO;
    }
    WXLog(@"[panel] PCM 装填 %lu bytes ≈ %lums — 启动录音会话", (unsigned long)pcm.length, (unsigned long)ms);
    say(@"自动录音发送中…");

    /* ⑤ 编程式启动录音（参数身份: 自己wxid / 对方wxid / userInfo 字典） */
    SEL startSel = NSSelectorFromString(WXSel(8));
    BOOL recording = NO;
    @try {
        BOOL (*fn)(id, SEL, id, id, id) = (BOOL (*)(id, SEL, id, id, id))objc_msgSend;
        recording = fn(audioSender, startSel, myWxid, peer, userInfo);
        WXLog(@"[panel] start ret=%d to=%@", recording, peer);
    } @catch (NSException *e) { WXLog(@"[panel] start EXC: %@", e); }

    if (!recording) {
        @synchronized([NSObject class]) { g_wxReplaceActive = NO; }
        say(@"录音会话启动失败（看日志）");
        return;
    }

    /* ⑥ 等 PCM 喂完（g_wxPcmFedDone）+ 0.3s 余量 → 主线程 StopRecord */
    int msInt = (int)ms;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        int waited = 0;
        int capMs = 15000 + 2 * msInt;
        while (waited < capMs) {
            [NSThread sleepForTimeInterval:0.1];
            waited += 100;
            BOOL fed = NO;
            @synchronized([NSObject class]) { fed = g_wxPcmFedDone; }
            if (fed) { [NSThread sleepForTimeInterval:0.3]; break; }
        }
        int waitedCopy = waited;
        dispatch_async(dispatch_get_main_queue(), ^{
            WXChainFinishRecord(waitedCopy, status);
        });
    });
}

/* ==================== 收尾：复刻 StopRecord（必须主线程） ====================
 * 铁律（v23 踩坑）：绝不把捕获来的 AudioRecorderUserData 跨会话回传微信（use-after-free 闪退）。
 * 真实结束链由 StopRecord 自己触发，成功判据看 OnRecorderEndRecording: 是否触发。 */
static void WXChainFinishRecord(int waitedMs, void (^status)(NSString *)) {
    id audioSender = nil;
    @synchronized([NSObject class]) { audioSender = g_wxAudioSender; }
    if (!audioSender) { WXLog(@"[stop] 无 AudioSender"); return; }

    int seenBefore = g_wxRecorderEndSeen;
    SEL stopSel = NSSelectorFromString(WXSel(1));
    @try {
        ((void (*)(id, SEL))objc_msgSend)(audioSender, stopSel);
        WXLog(@"[stop] StopRecord 已调用 (waited=%dms) end=%d", waitedMs, seenBefore);
    } @catch (NSException *e) { WXLog(@"[stop] StopRecord 异常: %@", e); }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        @synchronized([NSObject class]) {
            g_wxReplaceActive = NO;
            g_wxPcmFedDone = NO;
        }
        BOOL endFired = (g_wxRecorderEndSeen > seenBefore);
        WXLog(@"[stop] done end:%d→%d %@", seenBefore, g_wxRecorderEndSeen, endFired ? @"OK" : @"END-MISS");
        if (status) status(endFired ? @"✅ 已发送" : @"⚠️ 未触发结束链（看日志）");
    });
}

/* ==================== 安装 / 宿主判断 ==================== */
void WXChainInstallHooks(void) {
    WXInstallPrepareSendCapture();
    WXInstallStartRecordObserver();
    WXInstallAudioQueueHook();
    WXInstallRecorderEndCapture();
    WXInstallRecorderPartObserver();
    WXLog(@"[init] 微信链 hooks 安装完成");
}

BOOL WXChainIsWeChatBundle(void) {
    /* ① bundleId（最可靠） */
    NSString *bid = NSBundle.mainBundle.bundleIdentifier;
    if ([bid hasPrefix:@"com.tencent.xin"]) return YES;   /* 微信 */
    if ([bid hasPrefix:@"com.tencent.mqq"] ||
        [bid hasPrefix:@"com.tencent.qq"])  return NO;    /* QQ */
    /* ② bundleId 早期读不到时按类兜底（dylib 加载早期 NSBundle 可能还没就绪） */
    if (NSClassFromString(@"QQPttRecordBtn") || NSClassFromString(@"QQMsgService")) return NO;
    if (NSClassFromString(@"CMessageMgr") || NSClassFromString(@"MMServiceCenter") ||
        NSClassFromString(@"CMessageWrap")) return YES;
    return NO;
}

/* ==================== v5.1: 手动注入路（不依赖任何会话参数） ====================
 * 自动路要 StartRecordFrom 的 from/to/userInfo；没捕获到就发不出去。
 * 这一路只用已装好的 AudioQueue trampoline：
 *   装填 PCM → 用户自己在聊天里按住说话（微信真实录音 UI）→ buffer 被替换成 TTS
 *   → 松手 → 微信自己的完整发送链把语音条发到当前会话。
 * 全程不需要 from/to/userInfo，也不需要面板调任何微信内部方法。 */
void WXChainArmInjectionWithPcm(NSData *pcm) {
    if (!pcm.length) return;
    @synchronized([NSObject class]) {
        g_wxPendingPCM = pcm;
        g_wxPcmOffset = 0;
        g_wxReplaceActive = YES;
        g_wxPcmFedDone = NO;
        g_wxAqLastNs = 0; g_wxAqRateBps = 0; g_wxAqCbSeq = 0; g_wxAqStartNs = 0;
        g_wxAqFormatLogged = NO;
    }
    NSUInteger ms = pcm.length * 1000 / (NSUInteger)(g_wxTargetSampleRate * 2);
    WXLog(@"[wx-inject] 装填 %luB ≈ %lums — 等待用户按住说话（无需会话参数）",
          (unsigned long)pcm.length, (unsigned long)ms);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(60 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        NSUInteger off = 0;
        @synchronized([NSObject class]) { off = g_wxPcmOffset; }
        if (g_wxReplaceActive && off == 0) {
            @synchronized([NSObject class]) { g_wxReplaceActive = NO; g_wxPendingPCM = nil; }
            WXLog(@"[wx-inject] 60s 未使用 → 已自动撤销");
        }
    });
}

/* 会话参数是否齐（齐了才能走全自动 StartRecordFrom 路） */
BOOL WXChainHasSession(void) {
    NSString *peer = nil; id from = nil; id info = nil;
    @synchronized([NSObject class]) {
        peer = [g_wxLastToUsr copy];
        from = g_wxLastFrom;
        info = g_wxLastUserInfo;
    }
    if (!peer.length) peer = [NSUserDefaults.standardUserDefaults stringForKey:kSessionToKey];
    if (!from || ![from isKindOfClass:[NSString class]] || ![from length])
        from = [NSUserDefaults.standardUserDefaults stringForKey:kSessionFromKey];
    if (!info) info = WXLoadSessionInfo();
    if (!peer.length || !from || ![from length] || !info) return NO;
    return YES;
}
