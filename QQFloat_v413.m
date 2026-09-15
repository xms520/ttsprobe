/*
 * QQFloat_v413.m — v4.13: v4.12 日志判决（QQFloat_5.log 38214B）→ 仍"编码失败":
 *   ❌ 铁证: encodeOneFrame 逐帧 nFrames=0 + encode:withSamplesCount:(字节数) nil — 非callback版全空
 *   → 非 callback 版依赖文件流上下文(openSilkFile), 独立调用必空
 *   ✅ 关键: callback 版 encode:withSamplesCount:callback: 是唯一有真实输出的入口
 *      (v4.8 用它有输出, 但当时只 6B 静音 = 因为没设 setSilkSampleRate/BitRate 码率参数!)
 *
 * v4.13 改动:
 *   1. 回到 callback 版 + 正确参数(setSilkSampleRate/BitRate/SamplesPerFrame 24000)
 *   2. 一次性喂全量 PCM, 末次 callback 快照(body=d[0..nMax]) = 完整累计输出
 *
 * v4.13 判决树:
 *   - [silk] callback 版: cbs=N nMax=X silk=XB, X ≈ 16kbps×秒数(如 5.4s≈10800B) → 终审✅
 *   - 输出头(非 29f752f6a121 静音) → 真实语音帧
 *   - ⚠️ 副作用不变: 真实录音文件被覆写
 *
 * ====================== v4.12 判决存档 ======================
 * QQFloat_v412.m — v4.12: 非callback版(encodeOneFrame/encode:withSamplesCount:) 全返回空
 *
 * ====================== v4.6 判决存档 ======================
 * QQFloat_v46.m — v4.6: v4.5 日志判决（QQFloat_2.log 32769B）→ "无论多少文字发出去只有1秒":
 *   ✅ 24kHz+真实头照抄生效: 真实录音 5728B/3s≈15kbps, 头 02 23 21 53 49 4c 4b 5f 56 33 = 0x02+"#!SILK_V3"
 *   ✅ 帧结构铁证: 真实头[11:13]=0f00 → [u16LE len][frame] 打包确认(帧0=15B, 帧1=43B)
 *   ✅ g_replaying 防自污染生效: replay 自触发跳过捕获, 模板保持
 *   ❌ 我们的 callback 数据 = 01 00|29 | 02 00|29 f7 | 03 00|29 f7 52 | ...
 *      n 前缀 1,2,3,4,5 递增 + payload 逐字节增长 = callback(d,n) 是流式进度通知!
 *      d=同一缓冲, n=当前累计长度 — v4.5 把每次进度快照当独立帧 append → 数据全错
 *   → QQ 播放器只认到第一个"帧"(len=1, 1B) → 无论多长都只播 ~1 帧时长!
 *
 * v4.6 三处改动:
 *   1. callback 全序列 dump: cbs/dChanges/nMax/nAvg + 前12次 (n@ptr=head6B) — 判 d/n 语义
 *      假设A: d 恒定+ n 递增 = 流式累计缓冲 → 输出 = 末次 d[0..n] 全量(不加前缀!)
 *      假设B: d 变化 = 每帧独立 → 输出 = [u16 n][frame] 打包
 *   2. 运行时 dump encode:withSamplesCount:callback: 方法签名(method_copyArgumentType)
 *      — block 真实参数型判决(静态反汇编到头: 0x109d8a2f8→0x101f60220 无 export symbol)
 *   3. 双候选日志(A/B 大小) + 自动选择: dChanges==0 且 lastFull==lastN → A; 否则 B
 *
 * v4.6 判决树:
 *   - "[silk] cbs=N dChanges=0 nMax=X" + 候选A==nMax → A 成立 → 播放正常=终审✅
 *   - dChanges>0 → 每帧独立 → B 路线([u16 n][frame]) → 播放正常=终审✅
 *   - encode 方法签名 "?"? 参数型 → 下版按签名改 block
 *   - 仍 1 秒 → 发日志: dump= 序列直接暴露真相
 *   ⚠️ 副作用不变: 真实录音文件被覆写
 *
 * ====================== v4.5 判决存档 ======================
 * QQFloat_v45.m — v4.5: v4.4 日志判决（QQFloat_1.log 31286B）→ 发送成功但播放失败, 修音频格式:
 *   ✅✅ v4.4 捕获重放全链闭环! kernelSave=1 + sendResult code=0 + 聊天出现语音条
 *      捕获链完美: 自指校验+兜底扫描双通过, 真实路径解码成功(.amr 扩展名!), 模板 model/phInfo/attrs 全保留
 *   ✅ storage dump 判决 Swift String 存储真实布局(修正 v4.4 假设):
 *      +0x00=isa(0x000021a1f6526f91) +0x08=refcount(0x000000030000078c)
 *      +0x10=count(0x90=144)+UTF-8第1字节! +0x11..=路径内容("/var/mo bile/Con...")
 *      → UTF-8 在 storage+0x11, 不是 +0x18! 兜底扫描(off=+0x11)正是这样找到的
 *   ❌ 发出的语音无法播放 — 三个嫌疑(v4.5 全修):
 *      1) 文件头: v4.4 写 0x02 00 00 00(v1 拍脑袋) — QQ silk 真头应为 "#!SILK_V3"(或 0x02 变体)
 *      2) 采样率: 16kHz 编码, QQ NT silk 解码 24kHz → 变调+时长错乱
 *      3) 比特率异常: 79405B/3983ms≈160kbps 远超 silk 语音(24kbps) — callback 输出结构未判决
 * v4.5 五处改动:
 *   1. g_targetSampleRate 16000→24000(QQ NT silk 共识, NapCat/LLOneBot 同款)
 *   2. QQSilkEncode: 文件头照抄真实模板 g_realHead(0x02开头→11B / '#'开头→10B), 无模板默认 #!SILK_V3
 *   3. QQSilkEncode: 帧格式自适应 — 首帧检测 *(u16LE*)d==n-2 → callback 已输出 [len][frame] 打包,
 *      否则裸帧自己补 [u16 len][frame] 前缀; 首帧 16B dump 日志判决
 *   4. H 钩子捕获时读真实录音文件头 32B + fileSize + 比特率 → 日志 dump
 *      判决: "#!SILK_V3"=silk / 0x02 变体 / "#!AMR\n"=AMR(则 silk 全案推翻→v4.6 换 AMR 编码)
 *   5. TTS: 模板检查前置(编码前) + 覆写前 dump 输出头 32B 对比
 *
 * v4.5 判决树:
 *   - [qq-real] 文件 NB dur=Nms 比特率≈N kbps 头32B=... magic=SILK/AMR/..
 *     → magic 定格式; 比特率≈24kbps → QQ silk 24kHz 共识成立(采样率修复正确)
 *     → 比特率≈12kbps → AMR! → v4.6 换 AMR 编码器(opencore-amr)
 *   - [silk] frames=N fmt=packed/raw 首帧NB头=...
 *     → packed: callback 已含长度前缀(160kbps 之谜=打包帧含开销? 或 codec 高音质)
 *     → raw: 我们补前缀后 79405B→约2倍大? 看输出
 *   - [qq] silk NB 覆写真实路径 ... 头32B=... → 与真实头对比: magic 一致=格式对齐
 *   - 播放成功 = 全案终审 ✅; 仍失败 → 发日志, 按 magic/比特率/帧头三证据链判决
 *   ⚠️ 副作用不变: 真实录音文件被覆写
 *
 * ====================== v4.4 判决存档 ======================
 * QQFloat_v44.m — v4.4: v4.3 日志判决（QQFloat.log 27522B）→ 捕获重放(capture & replay):
 *   ✅ H 钩子命中! 真实录音 sendPttMsg 全 dump 到手 — 决定性突破:
 *      [qq-real] sendPtt model=MsgManager.NTAIOAudioModel type=1 durBits=0x40000000
 *                 q0=0xc000000000000090 q1=0x4000000282c6a7e0
 *      → String 大字符串位型铁证:
 *        q0 = 0xC000_0000_0000_0000 | count  → flags=0xC000(ASCII|NFC), count=0x90(144B 路径)
 *        q1 = 0b01 << 62 | 堆指针            → native(owned) 形态, 指针=0x282c6a7e0
 *      → audioType=1 实锤(真实录音 silk 就是 1, 不再是推测)
 *      → duration float@+0x20 (真实值 2.0f = 2 秒录音)
 *      → phInfo size=24: isa@0 + String elementID@+8 = (0,0) 空串 — QQ 自己就用 (0,0)!
 *   ❌ 崩点: 日志停在 "qqbase slide=0x25ac000 → bridge=0x1121bc158" —
 *      内部桥 br(silkPath) 调用内直接崩(v4.2 同代码返回垃圾未崩, x1 遗留值运气差异)
 *      → 内部桥死路判决: 0x10fc10158 真身 ABI 不可静态判定, 永久弃用
 *
 * v4.4 方案 — 彻底绕开 String 构造(不再造模型/不再调桥):
 *   【捕获】H 钩子每次真实录音时:
 *     - CFRetain(ARC strong) 真实 audioModel / phInfo / attrs → 模板永生
 *     - 从 String 存储解码真实 silk 路径:
 *         ptr = q1 & 0x3FFF...(剥高2位); 校验 [ptr+8]==q1(自指) → UTF-8@ptr+0x18, len=count
 *         不命中 → [ptr-0x10, ptr+0x100] 扫描可打印 '/' 路径串(含 .slk//Documents/)
 *     - dump storage 前 0x30B — 布局日志判决
 *   【重放】TTS 发送时:
 *     1. TTS silk 字节直接覆写真实录音的 silk 文件(g_realPath) — QQ 链读该路径
 *        → MD5/上传/消息 全是 TTS 音频, String 对象 100% QQ 原生零手术
 *     2. 更新模板 duration@+0x20 = 本次 ms (float 4B 直写, 唯一改动字段)
 *     3. sendPttMsgWithAudioModel:(模板, 模板phInfo, 模板attrs, 自有blocks)
 *   【无模板】TTS 时提示"先在QQ里真实发一条语音" — 不构造任何对象, 零崩溃面
 *
 * v4.4 判决树:
 *   - [qq-real] storage@... hdr=... + "模板已捕获 path=..." → 捕获链成功
 *   - [qq] silk NB 覆写真实路径 ... + sendPttMsg 已调用 (replay) + sendResult code=0
 *     → 聊天语音条 = 全链闭环 ✅
 *   - storage 校验不命中(hdr1!=q1) → 看扫描结果; 扫描也 MISS → 看 storage dump 定布局
 *   - code!=0 → 按 err 修(路径覆写失败/attrs 过期 → v4.5 改传 nil attrs)
 *   - 崩在 sendPttMsg 内部 → blocks 嫌疑 → v4.5 回退 nil blocks
 *   ⚠️ 副作用: 真实录音文件被覆写 — 旧语音消息本地回放会变成 TTS 音频(服务器副本不变)
 *
 * ====================== 历史判决存档 ======================
 * QQFloat_v42.m — v4.2: DeepSeek 三条判决全部采纳（2026-09-14）:
 *   必崩根因1: v3.6~v4.1 的 memset(instanceSize) 把 audioModel [offset 0] 的 isa 清成 0!
 *     → 修复: 从 offset 8 开始清零, isa 保留 (placeholderInfo 同步修)
 *   必崩根因2: (0,0) 不是合法 Swift String — sendPtt 深层把 q1 当 object 解引用
 *     → 修复: 兜底位型改 q0=0xE000000000000000 (immortal small-empty), q1=0
 *   死路判决: bridgeSym=0x0 证明 dlsym 全路径死路(two-level 盲区)
 *     → 新路: QQ 主二进制内部单参桥 thunk 0x10fc10158!
 *       sendAiVoiceMsgWithGroupCode: (imp 0x1085a2df0) 反汇编实锤:
 *         0x1085a2e44: x0=NSString(timbreID); bl 0x10fc10158 → (x0,x1)=String 16B
 *         随后 x19(q1侧) 过 0x10fc0ebb4 release — 双值 String 证实
 *       调用: _dyld 枚举 "/QQ.app/QQ" → vmaddr_slide → bridge = 0x10fc10158+slide
 *       单参直调, 无需 String.Type/metadata — 比 dlsym 可靠
 *
 * v4.2 判决树:
 *   - "[qq] qqbase slide=0x... → bridge=0x..." + "[qq] 内部桥 q0=.. q1=.."
 *     位型: q0 高字节 0xE0 系(small) / q1 高 8 位 0xD0/0x90(堆对象) → String 真落地
 *     → AudioModel ok → sendPttMsg 已调用 → 聊天语音条 = 闭环
 *   - "内部桥位型可疑" → 桥地址对但 ABI 不对, 下版试四参 (meta,x2,w3)
 *   - "QQ 主 image 未找到" → strstr 匹配问题, 看日志路径名
 *   - 不再有任何崩溃路径: isa 保留 + 兜底位型合法 + 全 FAIL 跳过发送
 *
 * ====================== 历史判决存档 ======================
 * QQFloat_v40.m — v4.0: v3.9 日志判决（QQFloat.log 27098B, 2026-09-14 真机）:
 *   ✅ 启动扫描稳定（qq-scan done classes=120968, 无 5s 闪退 — v3.7 修复①持续生效）
 *   ✅ TTS→PCM(58346B/1823ms)→silk(16657B) 全链正常, handler 双路捕获正常
 *   ✅ bridgeSym=0x1855cddf8 + StringMetaAcc=0x185bb811c 两行均打出（非零!）
 *   ❌ 下一行 "[qq] String.Type=" 未打印 → 崩在 metaFn() 或紧随的 br2() 调用
 *      v3.9 判决树第 2 条命中: 双参 ABI 仍不对
 *
 * v4.0 三处判决性修复（本轮静态反汇编新实锤）:
 *   1.【桥真 ABI 定案】NTSendable setAudioFilePath: 段 (0x106e1fb40~0x106e1fb50):
 *      str x19,[sp+0x50](新 NSString 先落栈) → ldr x0,[x28,#0xc78](String.Type)
 *      → add x2,sp,#0x50(&NSString 栈槽) → mov w3,#1 → bl 0x107c22b20(桥)
 *      即桥调用形态 = (x0=String.Type, x1=不读, x2=NSString*, w3=1), 返回 (x0,x1)=String 16B
 *      v3.9 的 br2(strType, silkPath) 把 NSString 放 x1, x2 遗留垃圾 → 桥内消费 x2 垃圾 → SIGSEGV
 *      v4.0: 桥调用改为四参 (meta, _, argPtr, 1), C 函数指针 (BridgeRet(*)(id,id,id,int))
 *   2.【dlsym 符号前缀定案】Mach-O dlsym 符号名必须带前导下划线。
 *      v3.6~v3.9 tier-3 无下划线 "$sSS...FZ"/"$sSSMa" 命中的 0x1855cddf8/0x185bb811c
 *      是 flat-lookup 垃圾命中(与真符号无关) — v3.9 崩在这两个垃圾地址上。
 *      v4.0: 桥三级 + meta accessor 全部带 "_" 前缀; 第三级无下划线路径删除。
 *   3.【x28 Swift 上下文不可仿】QQ 内部桥调用的 x28 是编译器专用上下文寄存器
 *      (init 批次 0x106e1f94c 反复 [x27/x28+0xc78/0xc88] 取 metadata), 外部 dylib
 *      无法复现 — 外部唯一安全路径 = 系统符号 dlsym(带_)。NTSendable setter 依旧
 *      禁触(v3.8 realize 崩实锤)。P3 small-string / 空串兜底保留不变。
 *
 * v4.0 判决树（下次日志）:
 *   - bridgeSym=0x... 且首行 "[qq] StringMetaAcc=" 后紧跟 "[qq] String.Type=0x..." → 垃圾命中根除
 *   - "[qq] 四参桥 q0=.. q1=.." 位型: q1 高 8 位 0xD0/0x90(堆对象) 或 q0 高字节 0xE0(small) → 桥闭环
 *   - "String 已落地" → "sendPttMsg 已调用" → 聊天出语音条 = 全链闭环
 *   - bridgeSym=0x0(tier 全 MISS) → P3 small-string(路径 ≤15B 才成立, NSTemporary 大概率走不到)
 *     → 空串兜底: 不崩但发不出 → 让用户真实录一条语音, D 钩子 [qq-real] raw16 = 最终硬编码依据
 *   - ⚠️ audioType=1 仍为假设值, sendResult code!=0 时按错误码改
 *
 * ====================== 历史判决存档 ======================
 * QQFloat_v39.m — v3.9: v3.8 日志判决（QQFloat_1.log 30839B）:
 *   日志停在: [qq] sendCls=INTAIOChatProtocol.NTSendableAudioModel
 *   后续 lend/responds/P1 setter 全部没打 → 崩点 = class_createInstance(NTSendable)
 *   或 respondsToSelector 触发的 Swift 类 realize（metadata accessor 深初始化）
 *   【与 v3.7 ProtobufLite NoClass 同模式: 主动提前 realize 未就绪的桥类】
 *   静态佐证（本轮 Mach-O 解析实锤）: NTSendableAudioModel 的 ro @0x11cd25740
 *   flags=0x81(SWIFT), baseMethods=0, ivars=0 — 方法/ivar 全靠 Swift metadata 运行时挂,
 *   任何 objc runtime 主动触碰都会走 metadata accessor → 深初始化链 → 崩
 *   （NTAIOAudioModel 相反: qq-scan 12 万类扫过它都没事, 说明它 metadata 已就绪）
 * v3.9 修复:
 *   1) P1 整段删除（判决性移除, 不再触碰 NTSendable 类）
 *   2) P2 dlsym 双参桥升为唯一首选（v3.6 真机实锤三级链命中非零 0x1855cddf8）
 *   3) P3 small-string + 空串兜底保留; 落地正序 q0=count/flags@+0x10, q1=object@+0x18
 * 历史判决存档见下
 *
 * QQFloat_v38.m — v3.8: v3.7 真机日志判决（QQFloat.log 31830B）:
 *   ✅ 修复①生效: [qq-scan] done classes=121372 found=7, 两次启动 5s 后均不闪退
 *   ❌ 修复②反退化: bridgeSym=0x0 + StringMetaAcc 日志缺失 → v3.7 手术时误删第三级 dlsym
 *      (v3.6 源 bed526e 三级: 带下划线_$sSS...FZ → 无下划线_unconditionally... → 无下划线$sSS...FZ
 *       命中的正是第三级; v3.7 2210b46 只剩前两级 → 全 MISS → 桥块整体跳过)
 *   ❌ 兜底 borrowed 布局字段序写反 → 发送即崩:
 *      v3.7 写 q0=NSString ptr / q1=0x8..0 (q0 当 object、q1 当 count)
 *      实际 sendPtt 0x10862fa7c: mov x0,x28(=[model+0x18]); bl swift_bridgeObjectRetain
 *          → q1=[+0x18] 是 object 侧!
 *      .cxx_destruct 0x10862ee90 同样 release [self+0x18] → q1=object 实锤
 *      实际 Swift String 布局: q0=[+0x10]=count/flags, q1=[+0x18]=object
 * v3.8 定案修复:
 *   1) 桥调用彻底废弃手工猜 ABI —— 改借 QQ 自己的 setter 产真 String:
 *      _TtC18INTAIOChatProtocol20NTSendableAudioModel(静态实锤方法表有 setAudioFilePath:
 *      imp 0x106e1fb48, 内部 bl 桥函数把 NSString 转成 16B Swift String)
 *      → 创建 NTSendableAudioModel 实例 → 调官方 setAudioFilePath: → memcpy 16B 槽位到
 *      NTAIOAudioModel+0x10 (只借字段, 不把这个 model 传给 sendPtt)
 *   2) setter 路径 MISS 才走 small-string 手工布局:
 *      路径 ≤15B ASCII → q0=前8B LE + q1=0xE*0x100|count<<56|(第9-15B) 内联
 *      不成立 → 唯一安全兜底 q0=0(空串),q1=0 并 WARN (发不出但不崩, 看 [qq-real] 补位型)
 *   3) 保留 v3.7 的 dlsym 双参桥路径作为第三优先级尝试(补回第三级 dlsym 符号)
 * v3.7 历史判决存档见此注释下方
 *
 * v3.6: 静态铁证定案: _TtC10MsgManager15NTAIOAudioModel 方法表只有
 *   init + .cxx_destruct —— 根本没有 setAudioFilePath:/setAudioType:/setAudioDuration:!
 *   (v3.5 respondsToSelector MISS 实锤; 那批 setter @0x106e1f94c 属 NTSendableAudioModel)
 *   → v3.5 回退 object_setIvar 又是老坑:
 *     1) object_setIvar(@(1)) 到 audioType(size=1 uint8 槽) → 写 8B NSNumber 指针 → +8..+0xF 全污染
 *     2) object_setIvar(@(ms)) 到 audioDuration(size=4 float 槽) → 写 8B 指针 → float=指针位模式
 *     3) audioFilePath 16B Swift String 从未正确落地 (日志 q0=NSString指针 q1=0 半初始化)
 *   ivar 全布局(ro fileoff 0x1ec2e450 静态实锤, 与 v3.2 运行时 dump 一致):
 *     audioType@+8 size1 | audioFilePath@+0x10 size16(Swift String) | audioDuration@+0x20 size4(float)
 *     audioVolumePowerList@+0x28 size8 | audioRecordType@+0x30 size8 | voiceChangeType@+0x38 size8
 *     autoConvertible@+0x40 size1 | placeholderMsgType@+0x41 size1 | isAIVoice@+0x42 size1
 *   sendPtt 消费(0x10862f9c0 反汇编实锤): x25=[model+8]=type, ldp x26,x28,[model+0x10]=filePath 16B,
 *     ldr s8,[model+0x20]=duration float; filePath 无效走 " not exist" 内联串分支
 * v3.6 修复:
 *   1) 全部弃 object_setIvar → 按 ivar size memcpy 裸内存直写 (type 1B / duration float 4B)
 *   2) audioFilePath 16B Swift String: 调 QQ 内部桥函数 _unconditionallyBridgeFromObjectiveC
 *      (运行时 dlsym 拿符号) 拿 (q0,q1) 双寄存器 → memcpy 16B 落地
 *   3) class_createInstance 后先 memset 清零 instanceSize (空 String q0=0,q1=0 合法安全)
 *   4) 回读 16B + 各槽日志判决
 * 基于 TTSFloat_v30.1（千问双后端 + 440 原接口音色 + 情绪标签条 + 语速）
 *
 * v3 静态逆向定案（QQ 9.3.60, 623MB 主二进制实锤）：
 *   QQMsgService 类 @0x11ee0ee90:
 *     - 元类唯一方法 getInstance [静态实锤: dispatch_once 单例实现 @0x10e8643d8]
 *     - 实例方法 25 个，含 getMsgSenderHandlerWithcontact: [v24@0:8@16] @imp 0x10e865b34
 *       内部链: [contact convertToOCContact] → [XClass shared] → [x chatMsgHandlerEnumByChatInfo:ocContact]
 *     - sendMsgWithOCContact:msgElems:msgAttributeInfos:callBack: [v48] 也为实例方法
 *   MsgSenderHandler(Swift OC桥)
 *     → sendPttMsgWithAudioModel:placeholderMsgInfo:msgAttributeInfos:saveDataToKernelResultBlock:sendMsgResultBlock:
 *   NTAIOAudioModel: audioType / audioFilePath / placeholderMsgType / isAIVoice (KVC 写入)
 *   silk 编码: QQSilkCodec encode:withSamplesCount:callback:
 *
 * v3 主动链（sendDirect 无 handler 时）：
 *   id qms = [QQMsgService getInstance]                       ← 类方法，静态实锤
 *   id h  = [qms getMsgSenderHandlerWithcontact:g_qqLastPeer] ← 主动调用 + E 钩子双保险
 *   G 钩子: hook getMsgSenderHandlerWithcontact: 本体（QQ 内部任何调用都自动捕获 handler）
 *
 * 与微信版本质区别：不走录音管线替换，直接调发送方法传 silk 文件路径。
 */


#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <malloc/malloc.h>
#include <stdio.h>
#import <objc/message.h>
#include "tts_res_ball.h"   /* 悬浮球/面板头像（CI 由 pm_res_ball2.jpg 生成） */
#include "tts_res_tip.h"    /* 打赏二维码（CI 由 pm_res_tip2.jpg 生成） */


/* ==================== 配置 ==================== */
/* 端点拆三段，避免 strings 直出 */
#define K_EP_A @"https://"
#define K_EP_B_OBF @"2d2d2d742e333b22742a2d751b0a1375"
static NSString *TTSXorHex(const char *hex, int key);
#define K_EP_C_OBF @"232f23333468742a322a"
static NSString *TTSEndpoint(void) {
    static NSString *e = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ e = [K_EP_A stringByAppendingString:
        [TTSXorHex(K_EP_B_OBF.UTF8String, 0x5A) stringByAppendingString:TTSXorHex(K_EP_C_OBF.UTF8String, 0x5A)]]; });
    return e;
}
#define K_DEFAULT_VOICE @"TVB女"
#define K_KEY_A_HEX @"040a0f0c0a5e5d0d5f5a0458090c5e0e040a0a5f04"
#define K_KEY_B_HEX @"0f0a055d0d085e0f04085a590d5a5a050a050c0c5f"
#define K_KEY_C_HEX @"5d040e0e5805045e580f090e0b0859040b5e0c0a0f09"

/* ==================== v30: 千问后端配置 ====================
 * DashScope 原生端点 + qwen3-tts-instruct-flash。
 * 实测（2026-09-12）：POST JSON {"model","input":{"text"},"parameters":{"voice","format","speech_rate","instruction"}}
 * 返回 {"output":{"audio":{"url":OSS音频}}} —— OSS URL 是 http，iOS ATS 要 https，下载前替换前缀。
 * speech_rate/pitch 静默接受（不报错）；instruction 语气指令实测生效（河南话验证）。 */
#define QW_TTS_PATH @"/api/v1/services/aigc/multimodal-generation/generation"
#define QW_HOST_A @"a7a2b0abb0a0ac"        /* dashsco   XOR 0xC3 */
#define QW_HOST_B @"b3a6eda2afaaba"        /* pe.aliy   XOR 0xC3 */
#define QW_HOST_C @"b6ada0b0eda0acae"      /* uncs.com  XOR 0xC3 */
#define QW_KEY_A_HEX @"4f57114b4f1174126c7864706c6474120e457a70127179657f756d78524e4f71634a5772784644"
#define QW_KEY_B_HEX @"0b05634f6c5e6c0e70597a580a44744d5b556572046b5679580e0e704d0d0b6d75547d770c697a"
#define QW_KEY_C_HEX @"787f515209784554685f08576f567b6b68530e5d6a52490b78087a0d5e724c74704c515d71700b"
static NSString *const kQwenVoiceKey     = @"TTSFloatQwenVoice";      /* 千问音色ID持久化 */
static NSString *const kBackendKey       = @"TTSFloatBackend";        /* 0=原接口 1=千问 */
static NSString *const kQwenRateKey      = @"TTSFloatQwenRate";       /* 语速 0.5~2.0 */
static NSString *const kQwenInstrKey     = @"TTSFloatQwenInstr";      /* 语气指令自由文本 */
static NSInteger g_backend = 0;              /* 0=原接口(tiax) 1=千问直连 */
static NSString *g_qwenVoice = @"Cherry";    /* 千问音色 ID（英文标识） */
static float g_qwenRate = 1.0f;              /* 语速 */
static NSString *g_qwenInstr = nil;          /* 语气情绪显示名（可空，下发时转换指令） */

/* v30.1: 情绪预设表（显示名，索引对齐） */
static NSString *const g_qwEmoNames[] = {
    @"默认", @"生气", @"愤怒", @"快乐", @"开心", @"兴奋", @"悲伤",
    @"难过", @"恐惧", @"害怕", @"惊讶", @"温柔", @"严肃", @"沉稳",
    @"激动", @"委屈", @"撒娇", @"嘲讽", @"耳语", @"大喊",
};
#define QW_EMO_COUNT (sizeof(g_qwEmoNames) / sizeof(g_qwEmoNames[0]))

/* v4.7: 24000 → 16000 回退 — v4.6 日志实锤判决:
 * 24kHz PCM 编码后总输出仅 504B/3.36s ≈ 1.2kbps = CNG 静音帧率!
 * → QQSilkCodec.setEncodeParam() 无参调用 = 默认 16kHz 编码器
 * 24kHz 输入被 16kHz codec 解读 → 语音能量落高频被滤波 → 判静音 → CNG 极小帧
 * (若 16k 仍 CNG → 编码参数需带参设置, 看 [silk] nMax 码率判决) */
static NSInteger g_targetSampleRate = 16000;

/* v25: 当前音色（持久化到 NSUserDefaults，微信重启不丢） */
static NSString *g_voiceName = nil;
static NSString *const kTTSVoiceKey = @"TTSFloatVoiceName";

/* ==================== v25: 动态音色（全部来自 ys.php，删除旧硬编码列表） ====================
 * 音色接口：TTSVoiceEndpoint()（密文表内）
 * 合成接口：TTSEndpoint()（密文表内），参数 text/voice/apikey
 * voice 参数实测直接用中文名（返回 code=200 + mp3 url），列表去重保序。
 * ⚠️ ys.php 偶发抽风/慢：拉取失败时列表为空，面板顶部会显示"音色列表加载失败"，
 *    再点一次音色行会重新拉；合成时用当前选中名（默认 K_DEFAULT_VOICE）。 */

static NSArray *g_voices = nil;          /* 全量音色名（去重保序，仅显示/存储用） */
static NSArray *g_voiceIDs = nil;        /* 与 g_voices 同序的数字 ID（合成请求实际用） */
static NSArray *g_voiceFilter = nil;     /* 搜索过滤结果（nil = 不过滤） */
static NSInteger g_voiceFetchState = 0;  /* 0 未拉取 / 1 进行中 / 2 成功 / -1 失败 */
static BOOL g_voiceFetchInited = NO;

/* ==================== 日志 ==================== */
static NSString *g_logPath = nil;
static void TTLog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[TTSFloat] %@", s);
    if (!g_logPath) return;
    @autoreleasepool {
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:g_logPath];
        if (!fh) {
            [[NSFileManager defaultManager] createFileAtPath:g_logPath contents:nil attributes:nil];
            fh = [NSFileHandle fileHandleForWritingAtPath:g_logPath];
        }
        if (fh) {
            [fh seekToEndOfFile];
            [fh writeData:[[NSString stringWithFormat:@"[TTSFloat] %@\n", s] dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        }
    }
}


/* ==================== v26: 关键字符串运行时解码（反 strings 提取） ====================
 * strings/IDA 里搜不到 hook 类名 / selector / 域名——全部 XOR 解码或分段拼接。
 * 逆向者必须反汇编到 TTSXorDecode 才能还原目标。 */
/* v26: hex 密文 → XOR 解码。密文只含 [0-9a-f]，strings 里就是一段普通 hex，无语义 */
static NSString *TTSXorHex(const char *hex, int key) {
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
static NSArray *TTSObfTable(void) {
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
static NSString *TTSCls(int i) { return TTSXorHex([TTSObfTable()[i] UTF8String], 0x5A); }
static NSString *TTCSel(int i) { return TTSXorHex([TTSObfTable()[2 + i] UTF8String], 0x3C); }
/* ==================== 崩溃定位（v23 新增） ====================
 * 闪退后日志里会多出 [CRASH] 行；dylib 基址一并打印，
 * 崩溃帧地址 - 基址 = Hopper 里 MicroMessenger.dylib 的偏移（结合 .ips 报告定位）。 */
#include <string.h>
#include <signal.h>
#include <unistd.h>
#include <fcntl.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
static int g_crashFd = -1;
static void TTSCrashLogException(NSException *e) {
    TTLog(@"[CRASH-EXC] %@ - %@\n%@", e.name, e.reason, e.callStackSymbols);
}
static void TTSCrashHandler(int sig, siginfo_t *info, void *uc) {
    /* v27: 信号处理器必须 async-signal-safe —— 只用 write()，
     * 不再调 backtrace/backtrace_symbols（内部走 malloc，SIGSEGV 里二次崩） */
    (void)uc;
    char buf[128];
    int n = snprintf(buf, sizeof(buf), "\n[CRASH] sig=%d addr=%p\n",
                     sig, info ? info->si_addr : NULL);
    if (g_crashFd >= 0) {
        ssize_t w = write(g_crashFd, buf, (size_t)n);
        (void)w;
    }
    _exit(128 + sig);
}
static void TTSInstallCrashGuards(void) {
    NSString *p = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/QQFloatCrash.log"];
    g_crashFd = open(p.fileSystemRepresentation, O_WRONLY | O_CREAT | O_APPEND, 0644);
    Dl_info di; void *self0 = (void *)&TTSInstallCrashGuards;
    if (dladdr(self0, &di)) {
        TTLog(@"[crash-guard] dylib=%s base=%p", di.dli_fname ? di.dli_fname : "?", di.dli_fbase);
    }
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = TTSCrashHandler;
    sa.sa_flags = SA_SIGINFO | SA_ONSTACK;
    sigaction(SIGSEGV, &sa, NULL);
    sigaction(SIGABRT, &sa, NULL);
    sigaction(SIGBUS, &sa, NULL);
    sigaction(SIGILL, &sa, NULL);
    sigaction(SIGTRAP, &sa, NULL);   /* v3.4: Swift precondition/fatalError 走 brk #1 → SIGTRAP, 之前没装 */
    NSSetUncaughtExceptionHandler(&TTSCrashLogException);
}

/* ---------- v25b: 宽松解析（兼容 "N. " / "N、" / "N)" / 纯换行无编号 / HTML 标签） ---------- */
static NSString *TTSTrim(NSString *s) {
    return [s stringByTrimmingCharactersInSet:
              [NSCharacterSet whitespaceAndNewlineCharacterSet]];
}
/* 名称里允许中文/字母数字/空格/常见符号；拒绝还带 HTML 标签的行 */
static BOOL TTSVoiceNameOK(NSString *n) {
    if (n.length < 1 || n.length > 24) return NO;
    if ([n rangeOfString:@"<"].location != NSNotFound) return NO;
    if ([n rangeOfString:@"http"].location != NSNotFound) return NO;
    return YES;
}
static void TTSAddVoice(NSMutableArray *out, NSMutableArray *ids, NSMutableSet *seen,
                        NSString *name, NSString *vid) {
    NSString *n = TTSTrim(name);
    if (!TTSVoiceNameOK(n)) return;
    NSString *key = [n lowercaseString];
    if ([seen containsObject:key]) return;
    [seen addObject:key];
    [out addObject:n];
    [ids addObject:vid.length ? vid : [NSString stringWithFormat:@"%lu", (unsigned long)out.count]];
}
static NSArray *g_lastParsedIDs = nil;   /* TTSParseVoiceList 的 ID 伴随输出 */
static NSArray *TTSParseVoiceList(NSString *raw0) {
    /* 万一是 HTML：去标签 + 实体还原（<br> 转换行），再按行解析 */
    NSString *text = raw0;
    if ([text rangeOfString:@"<"].location != NSNotFound) {
        text = [text stringByReplacingOccurrencesOfString:@"<br>" withString:@"\n" options:NSCaseInsensitiveSearch range:NSMakeRange(0, text.length)];
        text = [text stringByReplacingOccurrencesOfString:@"<br/>" withString:@"\n" options:NSCaseInsensitiveSearch range:NSMakeRange(0, text.length)];
        text = [text stringByReplacingOccurrencesOfString:@"<br />" withString:@"\n" options:NSCaseInsensitiveSearch range:NSMakeRange(0, text.length)];
        text = [text stringByReplacingOccurrencesOfString:@"<p>" withString:@"\n" options:NSCaseInsensitiveSearch range:NSMakeRange(0, text.length)];
        text = [text stringByReplacingOccurrencesOfString:@"</p>" withString:@"\n" options:NSCaseInsensitiveSearch range:NSMakeRange(0, text.length)];
        text = [text stringByReplacingOccurrencesOfString:@"&nbsp;" withString:@" "];
        text = [text stringByReplacingOccurrencesOfString:@"&quot;" withString:@"\""];
        text = [text stringByReplacingOccurrencesOfString:@"&amp;" withString:@"&"];
        text = [text stringByReplacingOccurrencesOfString:@"<[^>]+>" withString:@"\n" options:NSRegularExpressionSearch range:NSMakeRange(0, text.length)];
    }
    NSMutableArray *out = [NSMutableArray array];
    NSMutableArray *ids = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    NSArray<NSString *> *seps = @[ @".", @"、", @")", @"）", @":", @"：" ];
    NSArray *lines = [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet];
    for (NSString *raw in lines) {
        NSString *ln = TTSTrim(raw);
        if (ln.length < 2) continue;
        NSUInteger d = 0;
        unichar c0 = [ln characterAtIndex:0];
        if (c0 < '0' || c0 > '9') continue;
        while (d < ln.length && d < 6 &&
               [[NSCharacterSet decimalDigitCharacterSet] characterIsMember:[ln characterAtIndex:d]]) d++;
        if (d == 0 || d > 5) continue;
        NSString *vid = [ln substringToIndex:d];
        NSString *rest = [ln substringFromIndex:d];
        for (NSString *sep in seps) {
            if ([rest hasPrefix:sep]) { TTSAddVoice(out, ids, seen, [rest substringFromIndex:sep.length], vid); break; }
        }
    }
    /* 兜底：无编号（纯换行一行一个名字）——取前 800 行 */
    if (out.count < 5) {
        [out removeAllObjects]; [ids removeAllObjects]; [seen removeAllObjects];
        NSUInteger n = 0;
        for (NSString *raw in lines) {
            NSString *ln = TTSTrim(raw);
            if (ln.length == 0 || ln.length > 24) continue;
            if ([ln rangeOfString:@"<"].location != NSNotFound) continue;
            TTSAddVoice(out, ids, seen, ln, [NSString stringWithFormat:@"%lu", (unsigned long)(n + 1)]);
            if (++n >= 800) break;
        }
    }
    g_lastParsedIDs = ids;
    return out;
}
/* 失败时打印正文样本（转义换行），一次定位问题 */
static NSString *TTSTextSample(NSString *s, NSUInteger n) {
    if (s.length == 0) return @"(空)";
    NSString *t = [s substringToIndex:MIN(n, s.length)];
    t = [t stringByReplacingOccurrencesOfString:@"\n" withString:@"\\n"];
    t = [t stringByReplacingOccurrencesOfString:@"\r" withString:@"\\r"];
    return t;
}
/* 多编码兜底：UTF8 → GB18030 → ISO Latin → UTF16 */
static NSString *TTSDecodeBody(NSData *data) {
    if (!data.length) return nil;
    NSStringEncoding encs[] = { NSUTF8StringEncoding,
                                CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingGB_18030_2000),
                                NSISOLatin1StringEncoding,
                                NSUTF16StringEncoding };
    for (int i = 0; i < 4; i++) {
        NSString *s = [[NSString alloc] initWithData:data encoding:encs[i]];
        if (s.length) return s;
    }
    return nil;
}

/* v26: 音色接口地址（密文解码） */
static NSString *TTSVoiceEndpoint(void) {
    static NSString *e = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ e = [[K_EP_A stringByAppendingString:TTSXorHex(K_EP_B_OBF.UTF8String, 0x5A)]
        stringByAppendingString:TTSXorHex("2329742a322a", 0x5A)]; });
    return e;
}

/* ---------- v25b: 拉取（3 次重试 + Referer/UA + 完整诊断日志） ---------- */
static void TTSVoiceTry(NSInteger attempt, void (^done)(BOOL ok, NSUInteger n)) {
    NSMutableURLRequest *req = [NSMutableURLRequest
        requestWithURL:[NSURL URLWithString:TTSVoiceEndpoint()]
          cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:30];
    [req setValue:[K_EP_A stringByAppendingString:TTSXorHex(K_EP_B_OBF.UTF8String, 0x5A)] forHTTPHeaderField:@"Referer"];
    [req setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15"
          forHTTPHeaderField:@"User-Agent"];
    [req setValue:@"text/plain,text/html,*/*" forHTTPHeaderField:@"Accept"];
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block NSData *rData = nil; __block NSURLResponse *rResp = nil; __block NSError *rErr = nil;
    NSURLSessionDataTask *t = [NSURLSession.sharedSession
        dataTaskWithRequest:req
        completionHandler:^(NSData *d, NSURLResponse *resp, NSError *e) {
            rData = d; rResp = resp; rErr = e;
            dispatch_semaphore_signal(sem);
        }];
    [t resume];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(35 * NSEC_PER_SEC)));

    NSInteger status = [rResp isKindOfClass:[NSHTTPURLResponse class]] ? (NSInteger)((NSHTTPURLResponse *)rResp).statusCode : -1;
    NSString *text = TTSDecodeBody(rData);
    NSArray *list = text.length ? TTSParseVoiceList(text) : nil;

    if (list.count > 0) {
        g_voices = list;
        g_voiceIDs = g_lastParsedIDs;
        g_voiceFetchState = 2;
        @synchronized([NSObject class]) {
            if (g_voiceName.length == 0 || ![list containsObject:g_voiceName]) {
                g_voiceName = K_DEFAULT_VOICE;   /* 旧音色不在新表里 → 回落默认 */
            }
        }
        TTLog(@"[voice-api] ok n=%lu status=%ld bytes=%lu 首个=%@",
              (unsigned long)list.count, (long)status, (unsigned long)rData.length, list.firstObject);
        if (done) done(YES, list.count);
        return;
    }

    TTLog(@"[voice-api] fail try=%d err=%@ status=%ld bytes=%lu textLen=%lu sample=%@",
          (int)attempt, rErr.localizedDescription ?: @"nil", (long)status,
          (unsigned long)rData.length, (unsigned long)text.length, TTSTextSample(text, 300));
    if (attempt < 2) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                       dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            TTSVoiceTry(attempt + 1, done);
        });
        return;
    }
    g_voiceFetchState = -1;
    TTLog(@"[voice-api] 放弃：用内置音色表（点列表右上\"重新加载\"可再试）");
    if (done) done(NO, 0);
}

static void TTSFetchVoices(void (^done)(BOOL ok, NSUInteger n)) {
    g_voiceFetchState = 1;
    /* ⚠️ 重试内部用信号量等待，绝不能在主线程跑 */
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        TTSVoiceTry(0, done);
    });
}

static void TTSInitVoicesIfNeeded(void) {
    if (g_voiceFetchInited) return;
    g_voiceFetchInited = YES;
    TTSFetchVoices(nil);
}

/* 当前音色名（发送时用） */
static NSString *TTSCurVoice(void) {
    NSString *v = nil;
    @synchronized([NSObject class]) {
        v = g_voiceName;
        if (v.length == 0) {
            v = [NSUserDefaults.standardUserDefaults stringForKey:kTTSVoiceKey];
            if (v.length == 0) v = K_DEFAULT_VOICE;
            g_voiceName = v;
        }
    }
    return v;
}
static void TTSSetVoice(NSString *name) {
    @synchronized([NSObject class]) { g_voiceName = name; }
    [NSUserDefaults.standardUserDefaults setObject:name forKey:kTTSVoiceKey];
}
/* 名称 → 数字 ID（合成请求真正用的参数）。
 * 实测结论：yuyin2.php 的 voice 只认【序号 ID】，传中文名会被静默忽略、
 * 全部按 id=1（TVB女）合成 —— 这就是"换音色没反应、始终一个音色"的根因。 */
static NSString *TTSVoiceIDForName(NSString *name) {
    NSArray *vs = nil, *ids = nil;
    @synchronized([NSObject class]) { vs = g_voices; ids = g_voiceIDs; }
    if (!name.length) return @"1";
    if (vs.count && ids.count == vs.count) {
        NSUInteger i = [vs indexOfObject:name];
        if (i != NSNotFound && i < ids.count) return ids[i];
    }
    /* 兜底：名字数字开头就直接用 */
    if ([[name substringToIndex:1] isEqualToString:@""] == NO &&
        [[NSCharacterSet decimalDigitCharacterSet] characterIsMember:[name characterAtIndex:0]] &&
        name.intValue > 0) return name;
    return @"1";
}



/* ==================== v30: 千问后端（直连 DashScope） ====================
 * 音色表 48 个（官方 qwen3-tts-instruct-flash 全量）。
 * 显示用"ID·中文名"，请求时只传 ID。 */
static NSString *const g_qwenVoices[][2] = {
    {@"Cherry", @"芊悦·阳光亲切小姐姐"},
    {@"Serena", @"苏瑶·温柔小姐姐"},
    {@"Ethan", @"晨煦·温暖活力男声"},
    {@"Chelsie", @"千雪·二次元虚拟女友"},
    {@"Momo", @"茉兔·撒娇搞怪"},
    {@"Vivian", @"十三·拽拽小暴躁"},
    {@"Moon", @"月白·率性帅气男声"},
    {@"Maia", @"四月·知性温柔"},
    {@"Kai", @"凯·耳朵SPA男声"},
    {@"Nofish", @"不吃鱼·设计师"},
    {@"Bella", @"萌宝·小萝莉"},
    {@"Jennifer", @"詹妮弗·电影质感美语"},
    {@"Ryan", @"甜茶·戏感炸裂男声"},
    {@"Katerina", @"卡捷琳娜·御姐"},
    {@"Aiden", @"艾登·美语大男孩"},
    {@"Eldric Sage", @"沧明子·沉稳老者"},
    {@"Mia", @"乖小妹·温顺乖巧"},
    {@"Mochi", @"沙小弥·早慧小大人"},
    {@"Bellona", @"燕铮莺·千面人声江湖"},
    {@"Vincent", @"田叔·沙哑烟嗓"},
    {@"Bunny", @"萌小姬·萌属性萝莉"},
    {@"Neil", @"阿闻·专业新闻主持"},
    {@"Elias", @"墨讲师·知识讲师"},
    {@"Arthur", @"徐大爷·质朴讲故事"},
    {@"Nini", @"邻家妹妹·软黏甜嗓"},
    {@"Seren", @"小婉·助眠晚安"},
    {@"Pip", @"顽屁小孩·调皮小新"},
    {@"Stella", @"少女阿月·迷糊少女"},
    {@"Bodega", @"博德加·西班牙大叔"},
    {@"Sonrisa", @"索尼莎·拉美大姐"},
    {@"Alek", @"阿列克·战斗民族"},
    {@"Dolce", @"多尔切·慵懒意大利大叔"},
    {@"Sohee", @"素熙·韩国欧尼"},
    {@"Ono Anna", @"小野杏·青梅竹马"},
    {@"Lenn", @"莱恩·后朋克德国青年"},
    {@"Emilien", @"埃米尔安·浪漫法国哥哥"},
    {@"Andre", @"安德雷·磁性沉稳"},
    {@"Radio Gol", @"拉迪奥·足球诗人解说"},
    {@"Jada", @"上海阿珍·沪上阿姐(上海话)"},
    {@"Dylan", @"北京晓东·胡同少年(北京话)"},
    {@"Li", @"南京老李·瑜伽老师(南京话)"},
    {@"Marcus", @"陕西秦川·老陕味道(陕西话)"},
    {@"Roy", @"闽南阿杰·台湾哥仔(闽南语)"},
    {@"Peter", @"天津李彼得·专业捧哏(天津话)"},
    {@"Sunny", @"四川晴儿·甜川妹子(四川话)"},
    {@"Eric", @"四川程川·跳脱市井(四川话)"},
    {@"Rocky", @"粤语阿强·幽默陪聊(粤语)"},
    {@"Kiki", @"粤语阿清·甜美港妹(粤语)"},
};
#define QW_VOICE_COUNT (sizeof(g_qwenVoices) / sizeof(g_qwenVoices[0]))

/* 千问音色显示名 → 请求 ID */
static NSString *QwenVoiceIDFromDisplay(NSString *display) {
    for (NSUInteger i = 0; i < QW_VOICE_COUNT; i++) {
        if ([display isEqualToString:g_qwenVoices[i][1]] ||
            [display isEqualToString:g_qwenVoices[i][0]]) return g_qwenVoices[i][0];
    }
    /* 容错：显示名可能是 "Cherry·芊悦·xxx" 混合形态 → 前缀匹配 ID */
    for (NSUInteger i = 0; i < QW_VOICE_COUNT; i++) {
        if ([display hasPrefix:g_qwenVoices[i][0]]) return g_qwenVoices[i][0];
    }
    return @"Cherry";
}
/* 千问音色 ID → 显示名 */
static NSString *QwenDisplayFromID(NSString *vid) {
    for (NSUInteger i = 0; i < QW_VOICE_COUNT; i++) {
        if ([vid isEqualToString:g_qwenVoices[i][0]])
            return [NSString stringWithFormat:@"%@·%@", g_qwenVoices[i][0], g_qwenVoices[i][1]];
    }
    return @"Cherry·芊悦·阳光亲切小姐姐";
}

/* 后端状态读写（持久化） */
static void QwenLoadState(void) {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    NSInteger b = [d integerForKey:kBackendKey];
    g_backend = (b == 1) ? 1 : 0;
    NSString *v = [d stringForKey:kQwenVoiceKey];
    if (v.length) g_qwenVoice = v;
    double r = [d doubleForKey:kQwenRateKey];
    if (r >= 0.5 && r <= 2.0) g_qwenRate = (float)r;
    NSString *ins = [d stringForKey:kQwenInstrKey];
    if (ins.length) g_qwenInstr = ins;
}
static void QwenSaveBackend(NSInteger b) {
    g_backend = b;
    [NSUserDefaults.standardUserDefaults setInteger:b forKey:kBackendKey];
}
static void QwenSaveVoice(NSString *vid) {
    g_qwenVoice = vid;
    [NSUserDefaults.standardUserDefaults setObject:vid forKey:kQwenVoiceKey];
}
static void QwenSaveRate(float r) {
    g_qwenRate = r;
    [NSUserDefaults.standardUserDefaults setFloat:r forKey:kQwenRateKey];
}
static void QwenSaveInstr(NSString *s) {
    g_qwenInstr = s.length ? s : nil;
    if (s.length) [NSUserDefaults.standardUserDefaults setObject:s forKey:kQwenInstrKey];
    else [NSUserDefaults.standardUserDefaults removeObjectForKey:kQwenInstrKey];
}

/* DashScope key（三段 hex XOR 0x3C，同 TiaxKey 手法） */
static NSString *QwenKey(void) {
    static NSString *k = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        k = [TTSXorHex(QW_KEY_A_HEX.UTF8String, 0x3C) stringByAppendingString:
            [TTSXorHex(QW_KEY_B_HEX.UTF8String, 0x3C) stringByAppendingString:
              TTSXorHex(QW_KEY_C_HEX.UTF8String, 0x3C)]];
    });
    return k;
}
/* DashScope 域名（三段 hex XOR 0xC3 运行时拼） */
static NSString *QwenHost(void) {
    static NSString *h = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        h = [TTSXorHex(QW_HOST_A.UTF8String, 0xC3) stringByAppendingString:
            [TTSXorHex(QW_HOST_B.UTF8String, 0xC3) stringByAppendingString:
              TTSXorHex(QW_HOST_C.UTF8String, 0xC3)]];
    });
    return h;
}

/* 千问合成：POST JSON → {"output":{"audio":{"url":OSS}}} → https 化下载
 * text: 合成文本  voiceID: 音色  rate: 语速 0.5~2.0  instr: 语气指令(可nil) */
static void TTSDownloadAudio(NSString *audioURL, void (^done)(NSData *audio, NSError *error));   /* v30: 前置声明 */

static BOOL TTSIsAudioData(NSData *d) {
    if (d.length < 4) return NO;
    const unsigned char *b = d.bytes;
    if (b[0] == 'I' && b[1] == 'D' && b[2] == '3') return YES;
    if (b[0] == 'R' && b[1] == 'I' && b[2] == 'F' && b[3] == 'F') return YES;
    if (b[0] == 0xFF && (b[1] & 0xF0) == 0xF0) return YES;
    if (b[0] == 'f' && b[1] == 't' && b[2] == 'y' && b[3] == 'p') return YES;
    if (b[0] == '{') return NO;
    return NO;
}

static void TTSDownloadAudio(NSString *audioURL, void (^done)(NSData *audio, NSError *error)) {
    NSURL *u = [NSURL URLWithString:audioURL];
    if (!u) { done(nil, [NSError errorWithDomain:@"TTS" code:3 userInfo:@{NSLocalizedDescriptionKey:@"音频URL无效"}]); return; }
    NSURLSessionDataTask *task = [NSURLSession.sharedSession dataTaskWithURL:u
        completionHandler:^(NSData *audio, NSURLResponse *r2, NSError *e2) {
            if (e2 != nil || audio.length == 0) {
                done(nil, e2);
            } else if (!TTSIsAudioData(audio)) {
                done(nil, [NSError errorWithDomain:@"TTS" code:7 userInfo:@{NSLocalizedDescriptionKey:@"CDN文件过期(NoSuchKey)"}]);
            } else {
                TTLog(@"[tts] audio %lu bytes", (unsigned long)audio.length);
                done(audio, nil);
            }
        }];
    [task resume];
}

static NSString *TiaxKey(void) {   /* v26: key 三段 hex 密文运行时解码，strings 直搜无果 */
    static NSString *k = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        k = [TTSXorHex(K_KEY_A_HEX.UTF8String, 0x3C) stringByAppendingString:
            [TTSXorHex(K_KEY_B_HEX.UTF8String, 0x3C) stringByAppendingString:
              TTSXorHex(K_KEY_C_HEX.UTF8String, 0x3C)]];
    });
    return k;
}

static NSString *TTSEncode(NSString *s) {
    return [s stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
}

static void RequestTTSOnce(NSString *text, NSString *voice, void (^done)(NSData *audio, NSError *error)) {
    NSString *v = TTSVoiceIDForName(voice);   /* ⚠️ 接口只认数字 ID，不认中文名 */
    NSString *k = TiaxKey();
    if (k.length == 0) { done(nil, [NSError errorWithDomain:@"TTS" code:6 userInfo:@{NSLocalizedDescriptionKey:@"key未配置"}]); return; }
    /* v26: 参数名拼装（binary 里搜不到 ?text=&voice=&apikey= 模板） */
    NSString *urlStr = [TTSEndpoint() stringByAppendingString:
        [NSString stringWithFormat:@"?%@=%@&%@=%@&%@=%@",
         TTCSel(10), TTSEncode(text), TTCSel(11), TTSEncode(v), TTCSel(12), TTSEncode(k)]];
    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url) { done(nil, [NSError errorWithDomain:@"TTS" code:1 userInfo:@{NSLocalizedDescriptionKey:@"URL无效"}]); return; }
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.timeoutInterval = 30;
    NSURLSessionDataTask *task = [NSURLSession.sharedSession dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *r, NSError *e) {
            if (e != nil) { done(nil, e); return; }
            if (data.length == 0) { done(nil, [NSError errorWithDomain:@"TTS" code:2 userInfo:@{NSLocalizedDescriptionKey:@"API空返回"}]); return; }
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if ([json isKindOfClass:[NSDictionary class]]) {
                NSString *aurl = json[@"url"];
                if ([aurl isKindOfClass:[NSString class]] && aurl.length > 0) { TTSDownloadAudio(aurl, done); return; }
                done(nil, [NSError errorWithDomain:@"TTS" code:4 userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"API无url: %@", json]}]);
                return;
            }
            done(nil, [NSError errorWithDomain:@"TTS" code:5 userInfo:@{NSLocalizedDescriptionKey:@"非JSON返回"}]);
        }];
    [task resume];
}

static void RequestTTS(NSString *text, NSString *voice, void (^done)(NSData *audio, NSError *error)) {
    __block NSInteger attempt = 0;
    __block void (^retry)(NSData *, NSError *) = nil;
    retry = ^(NSData *audio, NSError *error) {
        attempt++;
        if (audio != nil) { done(audio, nil); return; }
        if (error.code == 7 && attempt < 3) {
            TTLog(@"[tts] CDN过期重试 %ld", (long)attempt);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                           dispatch_get_global_queue(0, 0), ^{ RequestTTSOnce(text, voice, retry); });
            return;
        }
        done(nil, error);
    };
    RequestTTSOnce(text, voice, retry);
}

/* ==================== mp3 → PCM ==================== */
static NSData *DecodeToPCM(NSData *audioData) {
    if (!audioData.length) return nil;
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:
                      [NSString stringWithFormat:@"tts_%@.audio", NSUUID.UUID.UUIDString]];
    if (![audioData writeToFile:path options:NSDataWritingAtomic error:nil]) return nil;

    NSError *err = nil;
    AVAudioFile *file = [[AVAudioFile alloc] initForReading:[NSURL fileURLWithPath:path] error:&err];
    if (!file) { TTLog(@"[pcm] open fail %@", err); [[NSFileManager defaultManager] removeItemAtPath:path error:nil]; return nil; }

    AVAudioFormat *src = file.processingFormat;
    AVAudioFormat *dst = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:(double)g_targetSampleRate channels:1];
    AVAudioConverter *conv = [[AVAudioConverter alloc] initFromFormat:src toFormat:dst];
    if (!conv) { TTLog(@"[pcm] conv fail"); return nil; }

    NSMutableData *pcm = [NSMutableData data];
    while (file.framePosition < file.length) {
        AVAudioFrameCount remain = (AVAudioFrameCount)(file.length - file.framePosition);
        AVAudioFrameCount inFrames = MIN(remain, 4096);
        AVAudioPCMBuffer *inBuf = [[AVAudioPCMBuffer alloc] initWithPCMFormat:src frameCapacity:inFrames];
        if (![file readIntoBuffer:inBuf error:nil]) break;
        AVAudioPCMBuffer *outBuf = [[AVAudioPCMBuffer alloc] initWithPCMFormat:dst frameCapacity:8192];
        __block BOOL supplied = NO;
        [conv convertToBuffer:outBuf error:nil withInputFromBlock:^AVAudioBuffer *(AVAudioPacketCount pk, AVAudioConverterInputStatus *st) {
            if (supplied) { *st = AVAudioConverterInputStatus_NoDataNow; return nil; }
            supplied = YES; *st = AVAudioConverterInputStatus_HaveData; return inBuf;
        }];
        if (outBuf.frameLength && outBuf.floatChannelData) {
            float *samples = outBuf.floatChannelData[0];
            for (AVAudioFrameCount i = 0; i < outBuf.frameLength; i++) {
                float v = samples[i];
                if (v > 1.0f) v = 1.0f; if (v < -1.0f) v = -1.0f;
                int16_t s = (int16_t)(v * 32767.0f);
                [pcm appendBytes:&s length:2];
            }
        }
    }
    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    TTLog(@"[pcm] %lu bytes", (unsigned long)pcm.length);
    return pcm.length ? pcm : nil;
}


static void RequestQwenTTS(NSString *text, NSString *voiceID, float rate, NSString *instr,
                           void (^done)(NSData *audio, NSError *error)) {
    NSString *key = QwenKey();
    if (![key hasPrefix:@"sk-"] || key.length < 20) {
        done(nil, [NSError errorWithDomain:@"QWEN" code:20 userInfo:@{NSLocalizedDescriptionKey:@"千问key未配置"}]);
        return;
    }
    NSMutableDictionary *params = [NSMutableDictionary dictionaryWithDictionary:@{
        @"voice": voiceID.length ? voiceID : @"Cherry",
        @"format": @"wav",
    }];
    if (rate >= 0.5f && rate <= 2.0f && rate != 1.0f) params[@"speech_rate"] = @(rate);
    if (instr.length) params[@"instruction"] = instr;
    NSDictionary *body = @{
        @"model": @"qwen3-tts-instruct-flash-2026-01-26",
        @"input": @{@"text": text ?: @""},
        @"parameters": params,
    };
    NSString *urlStr = [NSString stringWithFormat:@"https://%@%@", QwenHost(), QW_TTS_PATH];
    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url) { done(nil, [NSError errorWithDomain:@"QWEN" code:21 userInfo:@{NSLocalizedDescriptionKey:@"URL无效"}]); return; }
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    req.timeoutInterval = 40;
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    [req setValue:[NSString stringWithFormat:@"Bearer %@", key] forHTTPHeaderField:@"Authorization"];
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    TTLog(@"[qwen] POST voice=%@ rate=%.2f instr=%@ len=%lu",
          voiceID, rate, instr.length ? instr : @"-", (unsigned long)text.length);

    NSURLSessionDataTask *task = [NSURLSession.sharedSession dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *r, NSError *e) {
            if (e) { TTLog(@"[qwen] neterr %@", e.localizedDescription); done(nil, e); return; }
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if (![json isKindOfClass:[NSDictionary class]]) {
                NSString *raw = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                TTLog(@"[qwen] 非JSON: %@", [raw length] > 200 ? [raw substringToIndex:200] : raw);
                done(nil, [NSError errorWithDomain:@"QWEN" code:22 userInfo:@{NSLocalizedDescriptionKey:@"千问返回非JSON"}]);
                return;
            }
            NSString *code = json[@"code"], *msg = json[@"message"];
            if (code.length) {
                TTLog(@"[qwen] API错误 %@: %@", code, msg);
                done(nil, [NSError errorWithDomain:@"QWEN" code:23 userInfo:@{NSLocalizedDescriptionKey:
                    [NSString stringWithFormat:@"千问: %@ %@", code, msg ?: @""]}]);
                return;
            }
            NSString *aurl = json[@"output"][@"audio"][@"url"];
            if (![aurl isKindOfClass:[NSString class]] || !aurl.length) {
                TTLog(@"[qwen] 无url: %@", json);
                done(nil, [NSError errorWithDomain:@"QWEN" code:24 userInfo:@{NSLocalizedDescriptionKey:@"千问无音频url"}]);
                return;
            }
            /* OSS 返回 http:// → iOS ATS 要 https，实测同 URL https 可用 */
            if ([aurl hasPrefix:@"http:"]) aurl = [@"https" stringByAppendingString:[aurl substringFromIndex:4]];
            TTLog(@"[qwen] url ok (%lu chars)", (unsigned long)aurl.length);
            TTSDownloadAudio(aurl, done);
        }];
    [task resume];
}





/* ==================== v1 QQ 侧状态（发送链捕获） ====================
 * hook sendTextMsgWithText: 捕获 MsgSenderHandler 实例 + msgAttributeInfos(可空字典)。
 * 用户在 QQ 里发一条文字 → 全自动就绪。 */
static id g_qqSenderHandler = nil;      /* _TtC10MsgManager16MsgSenderHandler 实例 */
static NSDictionary *g_qqLastMsgAttrs = nil;
static id g_qqMsgSvcInst = nil;         /* v3: QQMsgService 实例（G 钩子/getInstance 捕获） */

/* ===== v2: 多点捕捉 =====
 * 关键逆向结论（QQ 9.3.60 静态分析）：
 *  - AIO 文字发送不走 MsgSenderHandler.sendTextMsgWithText（Swift 静态分派，swizzle 钩不到）
 *  - 真实统一出口 = NTKernelAdapter.MessageService.sendMsgWithMsgId:peer:msgElems:msgAttributeInfos:cb:
 *    [v56@0:8q16@24@32@40@?48] —— C++ NT 层经 ObjC 桥调用，必走 objc_msgSend，可 hook
 *  - 发任何消息（文字/图/sticker/语音）都会过统一出口 → 捕获 MessageService + OCContact(peer)
 *  - 额外把 MsgSenderHandler 已知签名的 send* 方法全 hook，发图/语音时直接捕获 handler */
static id g_qqMsgService = nil;         /* _TtC15NTKernelAdapter14MessageService 实例 */
static id g_qqLastPeer = nil;           /* OCContact：当前聊天对端（v2 新捕获，最有价值） */

/* QQ silk 编码：QQSilkCodec encode:withSamplesCount:callback:（QQ 内置，v1 无需自实现）
 * pcm: 16bit mono PCM  rate: 采样率 */
/* v4.4 全链已闭环(sendResult code=0) — 但播放失败, v4.5 修音频格式:
 * v4.4 三宗罪:
 *   1) 文件头写 0x02 00 00 00(v1 拍脑袋) — QQ silk 文件真头是 "#!SILK_V3"(10B)
 *   2) 采样率 16k — QQ NT silk 解码 24k → 变调/时长错
 *   3) 比特率异常(79405B/3983ms≈160kbps) — callback 输出结构未判决(裸帧? 打包帧?)
 * v4.5: 头照抄真实模板(g_realHead) + 帧格式首帧自适应 + 全链 dump 取证 */
static unsigned char g_realHead[32];   /* 真实录音 silk 文件头 32B(H钩子读) */
static NSUInteger g_realHeadLen = 0;
static long long g_realFileSize = -1;  /* 真实录音文件大小(比特率判决用) */

static NSData *QQSilkEncode(NSData *pcm, uint32_t rate) {
    Class c = NSClassFromString(@"QQSilkCodec");
    if (!c) { TTLog(@"[silk] QQSilkCodec MISS"); return nil; }
    @try {
        id codec = [[c alloc] init];
        /* v4.13: 回到 callback 版 encode:withSamplesCount:callback: (唯一有真实输出的入口)
         * v4.12 铁证: encodeOneFrame 逐帧 nFrames=0 + encode:withSamplesCount: 传字节数 nil
         *   → 非 callback 版全依赖文件流上下文(openSilkFile), 独立调用返回空
         * v4.8 callback 版有输出但只有 6B 静音(因为当时没设码率/采样率参数!)
         * 现在 v4.13: callback 版 + 正确参数(setSilkSampleRate/BitRate) + 一次性喂全量
         * 关键: 完整输出 = 末次 callback 的 d[0..nMax](累计字节数) */
        SEL epSel  = NSSelectorFromString(@"setEncodeParam");
        SEL aebSel = NSSelectorFromString(@"allocEncodeBuffer");
        SEL iagcSel = NSSelectorFromString(@"initAgc");
        SEL insxSel = NSSelectorFromString(@"initNsx");
        SEL srSel  = NSSelectorFromString(@"setSilkSampleRate:");
        SEL brSel  = NSSelectorFromString(@"setSilkBitRate:");
        SEL spfSel = NSSelectorFromString(@"setSilkSamplesPerFrame:");
        if ([codec respondsToSelector:epSel])  ((void (*)(id, SEL))objc_msgSend)(codec, epSel);
        if ([codec respondsToSelector:srSel])  ((void (*)(id, SEL, uint64_t))objc_msgSend)(codec, srSel, (uint64_t)rate);
        if ([codec respondsToSelector:spfSel]) ((void (*)(id, SEL, uint64_t))objc_msgSend)(codec, spfSel, (uint64_t)(rate/50));
        if ([codec respondsToSelector:brSel])  ((void (*)(id, SEL, uint64_t))objc_msgSend)(codec, brSel, (uint64_t)24000);
        if ([codec respondsToSelector:aebSel]) ((BOOL (*)(id, SEL))objc_msgSend)(codec, aebSel);
        if ([codec respondsToSelector:iagcSel])((BOOL (*)(id, SEL))objc_msgSend)(codec, iagcSel);
        if ([codec respondsToSelector:insxSel])((BOOL (*)(id, SEL))objc_msgSend)(codec, insxSel);

        const int16_t *samples = (const int16_t *)pcm.bytes;
        NSUInteger total = pcm.length / 2;           /* 总样本数 */

        SEL cbSel = NSSelectorFromString(@"encode:withSamplesCount:callback:");
        if (![codec respondsToSelector:cbSel]) { TTLog(@"[silk] callback 版 sel MISS"); return nil; }

        __block NSMutableData *body = [NSMutableData data];   /* 末次快照 = 完整累计输出 */
        __block NSUInteger cbs = 0;
        __block uint64_t nMax = 0;
        __block const void *lastD = NULL;
        /* 一次性喂全量: data=完整 PCM NSData, count=总样本数 */
        NSData *allPcm = [NSData dataWithBytes:samples length:total*2];
        ((uint64_t (*)(id, SEL, id, NSUInteger, void (^)(const void *, uint64_t)))objc_msgSend)
            (codec, cbSel, allPcm, (NSUInteger)total, ^(const void *d, uint64_t n) {
                if (!d || !n) return;
                lastD = d;
                if (n > nMax) nMax = n;
                /* 末次快照 = 累计输出的完整数据 */
                [body setData:[NSData dataWithBytes:d length:(NSUInteger)n]];
                cbs++;
            });
        if (cbs == 0 || !lastD || body.length == 0) {
            TTLog(@"[silk] callback 版无输出 (cbs=%lu total=%lu)", (unsigned long)cbs, (unsigned long)total);
            return nil;
        }
        TTLog(@"[silk] callback 版: cbs=%lu nMax=%llu silk=%luB (%.1f kbps)",
              (unsigned long)cbs, (unsigned long long)nMax, (unsigned long)body.length,
              (double)body.length * 8 / ((double)total / rate));
        if (body.length < 16) {
            const unsigned char *fp = body.bytes;
            NSMutableString *hx = [NSMutableString string];
            for (NSUInteger k = 0; k < body.length; k++) [hx appendFormat:@"%02x", fp[k]];
            TTLog(@"[silk] 输出头=%@", hx);
        }
        NSMutableData *file = [NSMutableData data];
        if (g_realHeadLen >= 10) {
            NSUInteger hlen = (g_realHead[0] == 0x02) ? 11 : 10;
            [file appendBytes:g_realHead length:hlen];
            TTLog(@"[silk] 文件头=真实模板 %luB", (unsigned long)hlen);
        } else {
            [file appendBytes:"#!SILK_V3" length:10];
            TTLog(@"[silk] 文件头=默认 #!SILK_V3 (无真实模板头)");
        }
        [file appendData:body];
        return file;
    } @catch (NSException *e) { TTLog(@"[silk] 异常 %@", e); return nil; }
}


/* ==================== UI ==================== */
static UIWindow *g_ttsWindow = nil;

/* v24: 头像（悬浮球 + 面板左上角共用） */
static UIImage *TTSLoadBallImage(void) {
    static UIImage *img = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        img = [UIImage imageWithData:[NSData dataWithBytes:TTS_RES_BALL length:TTS_RES_BALL_LEN]];
        if (!img) TTLog(@"[ui] 头像解码失败 len=%u", TTS_RES_BALL_LEN);
    });
    return img;
}

@interface TTSPassWindow : UIWindow
@end
@implementation TTSPassWindow
- (UIView *)hitTest:(CGPoint)p withEvent:(UIEvent *)e {
    UIView *hit = [super hitTest:p withEvent:e];
    return (hit == self || hit == self.rootViewController.view) ? nil : hit;
}
@end

@interface TTSRootController : UIViewController
@end
@implementation TTSRootController
- (BOOL)prefersStatusBarHidden { return YES; }
@end

@interface TTSFloatView : UIView <UITableViewDataSource, UITableViewDelegate, UIGestureRecognizerDelegate, UISearchBarDelegate>
@property (nonatomic, strong) UIView *panel;
@property (nonatomic, strong) UITextView *input;
@property (nonatomic, strong) UIButton *send;
@property (nonatomic, strong) UILabel *voiceLabel;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) UIView *tipMask;
@property (nonatomic, strong) UISearchBar *searchField;
@property (nonatomic, strong) UITableView *voiceTable;
- (void)dragPanel:(UIPanGestureRecognizer *)g;
- (void)showVoiceList;
- (void)reloadVoices;
- (void)qwRateChanged:(UISlider *)s;      /* v30: 语速滑杆 */
- (void)qwEmoTapped:(UIButton *)b;        /* v30.1: 情绪标签点选 */
- (NSString *)qwEmoDisplayForIdx:(NSUInteger)idx;   /* v30.1: 索引→显示名 */
- (void)closeVoiceList;
- (void)maskTapped:(UITapGestureRecognizer *)g;
- (void)closePanel;
- (void)showTip;
- (void)closeTip;
- (void)tipMaskTapped:(UITapGestureRecognizer *)g;
- (void)kbWillShow:(NSNotification *)n;
- (void)kbWillHide:(NSNotification *)n;
- (void)sendDirect;
@end

@implementation TTSFloatView

+ (void)load {
    /* v1 QQ: 启动时序——等 QQ 自己的 window 就绪（v27 微信验证过的安全形态） */
    __block id obs = nil;
    obs = [[NSNotificationCenter defaultCenter]
        addObserverForName:UIApplicationDidFinishLaunchingNotification object:nil
        queue:[NSOperationQueue mainQueue]
        usingBlock:^(NSNotification *n) {
            [[NSNotificationCenter defaultCenter] removeObserver:obs];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                if (![UIApplication sharedApplication].keyWindow) return;
                /* 创建悬浮球 window（v24 形态：穿透 TTSPassWindow + 圆形头像）
                 * ⚠️ ball 必须加到 rootVC.view（透明），不能直接加 window——
                 * window 的 rootViewController 自带一个全屏 view，会把直接加到 window 的 ball 盖住 */
                static dispatch_once_t once;
                dispatch_once(&once, ^{
                    CGRect scr = UIScreen.mainScreen.bounds;
                    UIWindow *w = [[TTSPassWindow alloc] initWithFrame:scr];
                    w.backgroundColor = UIColor.clearColor;
                    TTSRootController *root = [TTSRootController new];
                    w.rootViewController = root;
                    root.view.backgroundColor = UIColor.clearColor;
                    w.windowLevel = UIWindowLevelAlert + 100;
                    TTSFloatView *ball = [[TTSFloatView alloc] initWithFrame:
                        CGRectMake(scr.size.width - 72, scr.size.height * 0.42, 56, 56)];
                    [root.view addSubview:ball];
                    g_ttsWindow = w;
                    [w makeKeyAndVisible];
                    TTLog(@"[ui] ball shown（rootVC.view 子视图，穿透窗口）");
                });
                TTSInitVoicesIfNeeded();
            });
        }];
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.backgroundColor = [UIColor colorWithWhite:0.98 alpha:0.98];
    self.layer.cornerRadius = 28;
    self.layer.masksToBounds = YES;
    self.userInteractionEnabled = YES;

    /* v24: 悬浮球用头像图片（圆形裁切） */
    UIImageView *icon = [[UIImageView alloc] initWithFrame:CGRectMake(0, 0, 56, 56)];
    UIImage *ballImg = TTSLoadBallImage();
    if (ballImg) {
        icon.image = ballImg;
        icon.contentMode = UIViewContentModeScaleAspectFill;
        icon.layer.cornerRadius = 28;
        icon.layer.masksToBounds = YES;
        icon.layer.borderWidth = 1.5;
        icon.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.9].CGColor;
    } else {
        TTLog(@"[ui] 悬浮球图片解码失败 len=%u", TTS_RES_BALL_LEN);
    }
    icon.userInteractionEnabled = NO;
    [self addSubview:icon];

    [self addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(togglePanel)]];
    [self addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(drag:)]];
    return self;
}

- (void)dragPanel:(UIPanGestureRecognizer *)g {
    static CGPoint start;
    if (g.state == UIGestureRecognizerStateBegan) start = self.panel.center;
    if (g.state == UIGestureRecognizerStateChanged) {
        CGPoint t = [g translationInView:self.panel.superview];
        self.panel.center = CGPointMake(start.x + t.x, start.y + t.y);
    }
}

- (void)drag:(UIPanGestureRecognizer *)g {
    static CGPoint start;
    if (g.state == UIGestureRecognizerStateBegan) start = self.center;
    if (g.state == UIGestureRecognizerStateChanged) {
        CGPoint t = [g translationInView:self.superview];
        self.center = CGPointMake(start.x + t.x, start.y + t.y);
    }
}

- (void)kbWillShow:(NSNotification *)n {
    CGRect kb = [n.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    CGRect f = self.panel.frame;
    CGFloat maxY = kb.origin.y - 8;
    if (CGRectGetMaxY(f) > maxY) { f.origin.y = MAX(40, maxY - f.size.height); self.panel.frame = f; }
}
- (void)kbWillHide:(NSNotification *)n {
    CGRect f = self.panel.frame;
    if (f.origin.y < 80) { f.origin.y = 80; self.panel.frame = f; }
}

- (void)togglePanel {
    if (self.panel) { [self.panel removeFromSuperview]; self.panel = nil; return; }

    CGFloat w = 300, h = 250;
    CGRect sc = UIScreen.mainScreen.bounds;
    UIView *panel = [[UIView alloc] initWithFrame:CGRectMake(MAX(10, CGRectGetMidX(sc) - w / 2), 80, w, h)];
    panel.backgroundColor = [UIColor colorWithWhite:0.98 alpha:0.99];
    panel.layer.cornerRadius = 18;
    panel.layer.masksToBounds = YES;
    self.panel = panel;

    /* 全屏拖动：面板任意位置可拖（输入框等子控件点击不受影响） */
    UIPanGestureRecognizer *ppan = [[UIPanGestureRecognizer alloc]
        initWithTarget:self action:@selector(dragPanel:)];
    [panel addGestureRecognizer:ppan];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(kbWillShow:) name:UIKeyboardWillShowNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(kbWillHide:) name:UIKeyboardWillHideNotification object:nil];

    /* v24: 左上角头像 */
    UIImageView *avatar = [[UIImageView alloc] initWithFrame:CGRectMake(12, 8, 34, 34)];
    UIImage *ballImg = TTSLoadBallImage();
    if (ballImg) {
        avatar.image = ballImg;
        avatar.contentMode = UIViewContentModeScaleAspectFill;
        avatar.layer.cornerRadius = 17;
        avatar.layer.masksToBounds = YES;
    }
    avatar.userInteractionEnabled = NO;
    [panel addSubview:avatar];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(52, 12, 140, 26)];
    title.text = @"文字转语音";
    title.textColor = UIColor.blackColor;
    title.font = [UIFont boldSystemFontOfSize:16];
    [panel addSubview:title];

    /* v24: 右上角 关闭（收起回悬浮球） + 打赏（弹二维码） */
    UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    closeBtn.frame = CGRectMake(262, 8, 30, 30);
    [closeBtn setTitle:@"✕" forState:UIControlStateNormal];
    [closeBtn setTitleColor:[UIColor colorWithWhite:0.35 alpha:1] forState:UIControlStateNormal];
    closeBtn.titleLabel.font = [UIFont boldSystemFontOfSize:19];
    closeBtn.layer.cornerRadius = 15;
    closeBtn.backgroundColor = [UIColor colorWithWhite:0.90 alpha:1];
    [closeBtn addTarget:self action:@selector(closePanel) forControlEvents:UIControlEventTouchUpInside];
    [panel addSubview:closeBtn];

    UIButton *tipBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    tipBtn.frame = CGRectMake(200, 8, 56, 30);
    [tipBtn setTitle:@"打赏" forState:UIControlStateNormal];
    [tipBtn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    tipBtn.titleLabel.font = [UIFont boldSystemFontOfSize:13];
    tipBtn.layer.cornerRadius = 15;
    tipBtn.backgroundColor = [UIColor colorWithRed:0.85 green:0.65 blue:0.13 alpha:1];
    [tipBtn addTarget:self action:@selector(showTip) forControlEvents:UIControlEventTouchUpInside];
    [panel addSubview:tipBtn];

    /* v25: 音色行（458 个音色，左右箭头已删 → 整行点开带搜索的列表） */
    UILabel *vt = [[UILabel alloc] initWithFrame:CGRectMake(16, 47, 40, 26)];
    vt.text = @"音色";
    vt.textColor = UIColor.blackColor;
    vt.font = [UIFont systemFontOfSize:15];
    [panel addSubview:vt];

    self.voiceLabel = [[UILabel alloc] initWithFrame:CGRectMake(58, 43, 200, 34)];
    self.voiceLabel.text = @"音色列表加载中…";
    self.voiceLabel.textColor = UIColor.blackColor;
    self.voiceLabel.textAlignment = NSTextAlignmentLeft;
    self.voiceLabel.font = [UIFont boldSystemFontOfSize:14];
    self.voiceLabel.userInteractionEnabled = YES;
    UITapGestureRecognizer *vTap = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(showVoiceList)];
    [self.voiceLabel addGestureRecognizer:vTap];
    [panel addSubview:self.voiceLabel];

    UILabel *vHint = [[UILabel alloc] initWithFrame:CGRectMake(258, 43, 30, 34)];
    vHint.text = @"▾";
    vHint.textColor = [UIColor colorWithWhite:0.45 alpha:1];
    vHint.textAlignment = NSTextAlignmentCenter;
    vHint.font = [UIFont systemFontOfSize:14];
    [panel addSubview:vHint];

    /* v1 QQ: 面板状态 = 捕捉就绪状态 */
    id readyObj = nil;
    @synchronized([NSObject class]) { readyObj = g_qqSenderHandler; }
    if (readyObj) {
        self.statusLabel.text = @"就绪：输入文字点合成（发到当前会话）";
    } else {
        self.statusLabel.text = @"先在QQ发任意消息(文字/图)完成捕捉";
    }

    /* 音色异步加载完成后刷新标题（v30: 千问后端直接显示，不等原接口） */
    if (g_backend == 1) {
        self.voiceLabel.text = [NSString stringWithFormat:@"[千问] %@ %.2fx%@",
            g_qwenVoice, g_qwenRate, g_qwenInstr.length ? [NSString stringWithFormat:@" ·%@", g_qwenInstr] : @""];
    } else if (g_voices.count) {
        self.voiceLabel.text = TTSCurVoice();
    } else {
        self.voiceLabel.text = [NSString stringWithFormat:@"[千问备选] %@（原接口加载中…）", g_qwenVoice];
        __weak typeof(self) ws = self;
        TTSFetchVoices(^(BOOL ok, NSUInteger n) {
            dispatch_async(dispatch_get_main_queue(), ^{
                typeof(self) ss = ws; if (!ss) return;
                ss.voiceLabel.text = ok ? TTSCurVoice() : @"音色加载失败（点这里重试）";
            });
        });
    }

    self.input = [[UITextView alloc] initWithFrame:CGRectMake(12, 82, 276, 92)];
    self.input.backgroundColor = [UIColor colorWithWhite:0.92 alpha:1];
    self.input.textColor = UIColor.blackColor;
    self.input.font = [UIFont systemFontOfSize:15];
    self.input.layer.cornerRadius = 10;
    [panel addSubview:self.input];

    self.send = [UIButton buttonWithType:UIButtonTypeSystem];
    self.send.frame = CGRectMake(12, 181, 276, 40);
    self.send.backgroundColor = [UIColor colorWithRed:.12 green:.57 blue:.96 alpha:1];
    self.send.layer.cornerRadius = 9;
    [self.send setTitle:@"1️⃣ 合成语音" forState:UIControlStateNormal];
    [self.send setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    self.send.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    [self.send addTarget:self action:@selector(sendDirect) forControlEvents:UIControlEventTouchUpInside];
    [panel addSubview:self.send];

    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(12, 222, 276, 20)];
    self.statusLabel.text = @"输入文字后点合成";
    self.statusLabel.textColor = [UIColor colorWithWhite:0.25 alpha:1];
    self.statusLabel.font = [UIFont systemFontOfSize:11];
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    [panel addSubview:self.statusLabel];

    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.spinner.center = CGPointMake(282, 202);
    [panel addSubview:self.spinner];

    [self.superview addSubview:panel];
    [self.input becomeFirstResponder];
}

/* 音色列表弹层（点击音色名弹出，点击行选择） */
/* ==================== v24: 关闭 / 打赏 ==================== */
- (void)closePanel {
    [self.input resignFirstResponder];
    [self closeTip];
    if (self.panel) { [self.panel removeFromSuperview]; self.panel = nil; }
    TTLog(@"[ui] panel closed");
}

- (void)showTip {
    if (self.tipMask) return;
    CGRect sc = UIScreen.mainScreen.bounds;
    UIView *mask = [[UIView alloc] initWithFrame:sc];
    mask.tag = 9601;
    mask.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
    self.tipMask = mask;

    /* 赞赏码原图 1024×1036（自带"多谢老板打赏！"+ 底部金色署名条）→ 只做等比缩放，不裁切 */
    CGFloat cw = MIN(320, sc.size.width - 40);
    CGFloat iw = cw - 16;
    CGFloat ih = iw * 1036.0 / 1024.0;
    CGFloat ch = 8 + ih + 34;
    UIView *card = [[UIView alloc] initWithFrame:
        CGRectMake((sc.size.width - cw) / 2, (sc.size.height - ch) / 2, cw, ch)];
    card.tag = 9602;
    card.backgroundColor = UIColor.whiteColor;
    card.layer.cornerRadius = 16;
    card.layer.masksToBounds = YES;
    [mask addSubview:card];

    UIImageView *qr = [[UIImageView alloc] initWithFrame:CGRectMake(8, 8, iw, ih)];
    UIImage *qrImg = [UIImage imageWithData:[NSData dataWithBytes:TTS_RES_TIP length:TTS_RES_TIP_LEN]];
    if (qrImg) {
        qr.image = qrImg;
        qr.contentMode = UIViewContentModeScaleAspectFit;
    } else {
        TTLog(@"[ui] 二维码解码失败 len=%u", TTS_RES_TIP_LEN);
    }
    qr.userInteractionEnabled = NO;
    [card addSubview:qr];

    UILabel *sub = [[UILabel alloc] initWithFrame:CGRectMake(0, 8 + ih + 4, cw, 20)];
    sub.text = @"微信内长按识别 · 赞赏码";
    sub.textAlignment = NSTextAlignmentCenter;
    sub.textColor = [UIColor colorWithWhite:0.45 alpha:1];
    sub.font = [UIFont systemFontOfSize:12];
    [card addSubview:sub];

    UIButton *closeB = [UIButton buttonWithType:UIButtonTypeSystem];
    closeB.frame = CGRectMake(cw - 44, 4, 38, 32);
    [closeB setTitle:@"✕" forState:UIControlStateNormal];
    [closeB setTitleColor:[UIColor colorWithWhite:0.4 alpha:1] forState:UIControlStateNormal];
    closeB.titleLabel.font = [UIFont boldSystemFontOfSize:19];
    [closeB addTarget:self action:@selector(closeTip) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:closeB];

    /* 点卡片外任意处关闭（卡片内不关闭） */
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(tipMaskTapped:)];
    [mask addGestureRecognizer:tap];

    [self.superview addSubview:mask];
    TTLog(@"[ui] tip shown (%u bytes qr)", TTS_RES_TIP_LEN);
}

- (void)closeTip {
    if (self.tipMask) { [self.tipMask removeFromSuperview]; self.tipMask = nil; }
}

- (void)tipMaskTapped:(UITapGestureRecognizer *)g {
    UIView *card = [self.tipMask viewWithTag:9602];
    CGPoint loc = [g locationInView:card];
    if (card && !CGRectContainsPoint(card.bounds, loc)) [self closeTip];
}

/* ==================== v25: 音色选择列表（可搜索，458 个） ==================== */
- (void)showVoiceList {
    [self closeVoiceList];

    CGRect scr = UIScreen.mainScreen.bounds;
    UIView *mask = [[UIView alloc] initWithFrame:scr];
    mask.tag = 9527;
    mask.backgroundColor = [UIColor colorWithWhite:0 alpha:0.4];

    CGFloat lw = MIN(320, scr.size.width - 32);
    CGFloat lh = scr.size.height * 0.66;
    UIView *listPanel = [[UIView alloc] initWithFrame:CGRectMake((scr.size.width-lw)/2, (scr.size.height-lh)/2, lw, lh)];
    listPanel.backgroundColor = UIColor.whiteColor;
    listPanel.layer.cornerRadius = 14;
    listPanel.tag = 9528;
    [mask addSubview:listPanel];

    UILabel *lt = [[UILabel alloc] initWithFrame:CGRectMake(12, 8, lw-100, 28)];
    NSUInteger n = g_voices.count;
    NSString *title;
    if (g_backend == 1) {
        title = [NSString stringWithFormat:@"选择音色（千问48 + 原%lu）", (unsigned long)n];
    } else {
        title = n ? [NSString stringWithFormat:@"选择音色（千问48 + 原%lu）", (unsigned long)n]
                  : (g_voiceFetchState < 0 ? @"原接口加载失败，千问可用" : @"选择音色（千问48 + 原加载中…）");
    }
    lt.text = title;
    lt.tag = 9531;
    lt.textColor = UIColor.blackColor;
    lt.font = [UIFont boldSystemFontOfSize:15];
    [listPanel addSubview:lt];

    UIButton *reloadB = [UIButton buttonWithType:UIButtonTypeSystem];
    reloadB.frame = CGRectMake(lw-84, 6, 76, 30);
    [reloadB setTitle:@"重新加载" forState:UIControlStateNormal];
    [reloadB setTitleColor:[UIColor colorWithRed:.12 green:.57 blue:.96 alpha:1] forState:UIControlStateNormal];
    reloadB.titleLabel.font = [UIFont systemFontOfSize:13];
    [reloadB addTarget:self action:@selector(reloadVoices) forControlEvents:UIControlEventTouchUpInside];
    [listPanel addSubview:reloadB];

    /* 搜索框：千问+原接口合搜 */
    UISearchBar *sb = [[UISearchBar alloc] initWithFrame:CGRectMake(0, 38, lw, 44)];
    sb.placeholder = @"搜索音色（中文名/ID，如 Cherry、御姐）";
    sb.delegate = (id<UISearchBarDelegate>)self;
    sb.tag = 9530;
    [listPanel addSubview:sb];
    self.searchField = sb;

    /* ===== v30.1: 千问设置区（语速滑杆 + 情绪标签条——点选模式，自动下发指令） ===== */
    UIView *qwSet = [[UIView alloc] initWithFrame:CGRectMake(0, 84, lw, 88)];
    qwSet.tag = 9540;
    qwSet.backgroundColor = [UIColor colorWithRed:0.95 green:0.97 blue:1.0 alpha:1];
    [listPanel addSubview:qwSet];

    UILabel *rateL = [[UILabel alloc] initWithFrame:CGRectMake(12, 4, 32, 18)];
    rateL.text = @"语速";
    rateL.font = [UIFont boldSystemFontOfSize:12];
    rateL.textColor = [UIColor colorWithRed:0.1 green:0.3 blue:0.7 alpha:1];
    [qwSet addSubview:rateL];

    UILabel *rateV = [[UILabel alloc] initWithFrame:CGRectMake(lw-60, 4, 48, 18)];
    rateV.text = [NSString stringWithFormat:@"%.2fx", g_qwenRate];
    rateV.font = [UIFont boldSystemFontOfSize:12];
    rateV.textColor = [UIColor colorWithRed:0.1 green:0.3 blue:0.7 alpha:1];
    rateV.tag = 9541;
    [qwSet addSubview:rateV];

    UISlider *slider = [[UISlider alloc] initWithFrame:CGRectMake(44, 2, lw-110, 22)];
    slider.minimumValue = 0.5f;
    slider.maximumValue = 2.0f;
    slider.value = g_qwenRate;
    slider.tag = 9542;
    [slider addTarget:self action:@selector(qwRateChanged:) forControlEvents:UIControlEventValueChanged];
    [qwSet addSubview:slider];

    /* 语气：情绪标签条（点选循环 高亮），不再手输 */
    UILabel *instrL = [[UILabel alloc] initWithFrame:CGRectMake(12, 32, 32, 18)];
    instrL.text = @"语气";
    instrL.font = [UIFont boldSystemFontOfSize:12];
    instrL.textColor = [UIColor colorWithRed:0.1 green:0.3 blue:0.7 alpha:1];
    [qwSet addSubview:instrL];

    /* v30.1: 情绪标签条（数据源=全局 g_qwEmoNames，点选即下发指令） */
    UIScrollView *emoScroll = [[UIScrollView alloc] initWithFrame:CGRectMake(44, 28, lw-56, 30)];
    emoScroll.showsHorizontalScrollIndicator = NO;
    emoScroll.tag = 9545;
    CGFloat ex = 0;
    for (NSUInteger ei = 0; ei < QW_EMO_COUNT; ei++) {
        NSString *en = g_qwEmoNames[ei];
        UIButton *eb = [UIButton buttonWithType:UIButtonTypeSystem];
        eb.frame = CGRectMake(ex, 2, MAX(44, en.length * 16 + 20), 26);
        [eb setTitle:en forState:UIControlStateNormal];
        eb.titleLabel.font = [UIFont systemFontOfSize:12];
        eb.layer.cornerRadius = 13;
        eb.tag = 9600 + (int)ei;   /* 9600+idx → qwEmoTapped 逆映射 */
        [eb addTarget:self action:@selector(qwEmoTapped:) forControlEvents:UIControlEventTouchUpInside];
        /* 高亮当前选中（g_qwenInstr 显示名匹配） */
        BOOL cur = [g_qwenInstr isEqualToString:[self qwEmoDisplayForIdx:ei]];
        eb.backgroundColor = cur ? [UIColor colorWithRed:0.12 green:0.45 blue:0.95 alpha:1] : UIColor.whiteColor;
        [eb setTitleColor:cur ? UIColor.whiteColor : [UIColor colorWithWhite:0.25 alpha:1] forState:UIControlStateNormal];
        [emoScroll addSubview:eb];
        ex += MAX(44, en.length * 16 + 20) + 8;
    }
    emoScroll.contentSize = CGSizeMake(ex, 30);
    [qwSet addSubview:emoScroll];

    UILabel *hintL = [[UILabel alloc] initWithFrame:CGRectMake(12, 62, lw-24, 22)];
    hintL.text = @"语速/语气只对千问音色（第一段）生效";
    hintL.font = [UIFont systemFontOfSize:10];
    hintL.textColor = [UIColor colorWithWhite:0.5 alpha:1];
    [qwSet addSubview:hintL];

    UITableView *tv = [[UITableView alloc] initWithFrame:CGRectMake(0, 84 + 88, lw, lh-84-88)
                                                   style:UITableViewStylePlain];
    tv.tag = 9529;
    tv.dataSource = (id<UITableViewDataSource>)self;
    tv.delegate = (id<UITableViewDelegate>)self;
    tv.rowHeight = 42;
    [listPanel addSubview:tv];
    self.voiceTable = tv;

    g_voiceFilter = nil;   /* 每次打开重置过滤 */
    [tv reloadData];

    /* 遮罩只在点面板外时关闭；面板内触摸交给表格/搜索框 */
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(maskTapped:)];
    tap.delegate = (id<UIGestureRecognizerDelegate>)self;
    [mask addGestureRecognizer:tap];
    objc_setAssociatedObject(mask, "maskPanel", listPanel, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    if (!g_voices.count) TTSInitVoicesIfNeeded();

    UIWindow *w = nil;
    for (UIWindow *win in UIApplication.sharedApplication.windows) {
        if (win.isKeyWindow) { w = win; break; }
    }
    if (!w) w = UIApplication.sharedApplication.windows.firstObject;
    [w addSubview:mask];
    TTLog(@"[voice-list] shown (%lu voices)", (unsigned long)g_voices.count);
}

- (void)reloadVoices {
    TTLog(@"[voice-list] 手动重新加载音色");
    __weak typeof(self) ws = self;
    TTSFetchVoices(^(BOOL ok, NSUInteger n) {
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) ss = ws;
            UITableView *tv = ss.voiceTable;
            [tv reloadData];
            UIView *p = ss.searchField ? [ss.searchField superview] : nil;
            if (p) {
                UILabel *h = nil;
                for (UIView *v in p.subviews) {
                    if (v.tag == 9531 && [v isKindOfClass:[UILabel class]]) { h = (UILabel *)v; break; }
                }
                if (h) h.text = ok ? [NSString stringWithFormat:@"选择音色（千问48 + 原%lu）", (unsigned long)n]
                                   : @"原接口加载失败（千问可用）";
            }
            ss.voiceLabel.text = ok ? TTSCurVoice() : @"音色加载失败（点这里重试）";
        });
    });
}

/* ===== v30.1: 千问语速滑杆 + 情绪标签 ===== */
/* 显示名 → instruction 指令文本（千问 instruct 模型自然语言指令） */
static NSString *qwEmoInstruction(NSString *display) {
    if (display.length == 0 || [display isEqualToString:@"默认"]) return nil;
    NSDictionary *map = @{
        @"生气": @"用生气的语气说话，语调强硬，带着明显的不满",
        @"愤怒": @"用愤怒的语气大喊，情绪激烈，充满怒火",
        @"快乐": @"用快乐的语气说话，声音明亮上扬，充满感染力",
        @"开心": @"用开心的语气说话，轻快活泼，带着笑意",
        @"兴奋": @"用兴奋激动的语气说话，语速偏快，情绪高涨",
        @"悲伤": @"用悲伤低沉的语气说话，声音低落，充满哀伤",
        @"难过": @"用难过的语气说话，声音低沉，透着沮丧",
        @"恐惧": @"用恐惧颤抖的语气说话，声音发紧，充满害怕",
        @"害怕": @"用害怕的语气轻声说话，声音发抖，小心翼翼",
        @"惊讶": @"用惊讶的语气说话，声音突然拔高，充满震惊",
        @"温柔": @"用温柔的语气轻声说话，柔和缓慢，让人安心",
        @"严肃": @"用严肃的语气说话，字正腔圆，不苟言笑",
        @"沉稳": @"用沉稳的语气说话，声音厚实，镇定从容",
        @"激动": @"用激动澎湃的语气说话，情绪饱满，声音有力",
        @"委屈": @"用委屈的语气说话，声音发哽，带着哭腔",
        @"撒娇": @"用撒娇的语气说话，拖长音调，软糯可爱",
        @"嘲讽": @"用嘲讽轻蔑的语气说话，阴阳怪气，带着讥笑",
        @"耳语": @"用耳语的方式轻声说话，气声为主，仿佛在耳边低语",
        @"大喊": @"用大声呼喊的方式说话，音量全开，声嘶力竭",
    };
    return map[display];
}
- (NSString *)qwEmoDisplayForIdx:(NSUInteger)idx {
    return (idx < QW_EMO_COUNT) ? g_qwEmoNames[idx] : @"";
}
- (void)qwRateChanged:(UISlider *)s {
    float v = s.value;
    /* 步进 0.25 显示更稳定 */
    v = roundf(v * 4.0f) / 4.0f;
    s.value = v;
    QwenSaveRate(v);
    UIView *p = [s superview];
    if (p) {
        UILabel *rv = nil;
        for (UIView *v2 in p.subviews) {
            if (v2.tag == 9541 && [v2 isKindOfClass:[UILabel class]]) { rv = (UILabel *)v2; break; }
        }
        if (rv) rv.text = [NSString stringWithFormat:@"%.2fx", v];
    }
    TTLog(@"[qwen] rate=%.2f", v);
}
- (void)qwEmoTapped:(UIButton *)b {
    NSUInteger idx = (NSUInteger)(b.tag - 9600);
    if (idx >= QW_EMO_COUNT) return;
    NSString *display = g_qwEmoNames[idx];
    NSString *instr = qwEmoInstruction(display);
    QwenSaveInstr(instr ?: display);   /* 持久化存显示名（回显用），下发时转换 */
    /* 全标签刷新高亮 */
    UIView *p = [b superview];
    if (p) {
        for (UIView *v2 in p.subviews) {
            if (v2.tag >= 9600 && [v2 isKindOfClass:[UIButton class]]) {
                UIButton *eb = (UIButton *)v2;
                NSUInteger i = (NSUInteger)(eb.tag - 9600);
                BOOL cur = (i == idx);
                eb.backgroundColor = cur ? [UIColor colorWithRed:0.12 green:0.45 blue:0.95 alpha:1] : UIColor.whiteColor;
                [eb setTitleColor:cur ? UIColor.whiteColor : [UIColor colorWithWhite:0.25 alpha:1] forState:UIControlStateNormal];
            }
        }
    }
    TTLog(@"[qwen] emo=%@ instr=%@", display, instr ?: @"(默认)");
}

- (void)closeVoiceList {
    for (UIWindow *w in UIApplication.sharedApplication.windows) {
        for (UIView *sub in w.subviews) {
            if (sub.tag == 9527) [sub removeFromSuperview];
        }
    }
}

/* v21-fix: 只有关闭按钮/遮罩空白区才关列表；点列表面板内部不关 */
- (void)maskTapped:(UITapGestureRecognizer *)g {
    UIView *mask = g.view;
    UIView *listPanel = objc_getAssociatedObject(mask, "maskPanel");
    CGPoint loc = [g locationInView:listPanel];
    BOOL inside = CGRectContainsPoint(listPanel.bounds, loc);
    if (!inside) [self closeVoiceList];
}

/* v21-fix: 遮罩 tap 与表格行点击共存——触摸点在列表面板内时放弃识别 */
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gr shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    return YES;
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gr shouldBeRequireFailureOfGestureRecognizer:(UIGestureRecognizer *)other {
    return NO;
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gr shouldReceiveTouch:(UITouch *)touch {
    /* 触摸落在列表面板内 → 不接收，让表格自己处理 didSelectRowAtIndexPath */
    UIView *mask = gr.view;
    UIView *listPanel = objc_getAssociatedObject(mask, "maskPanel");
    if (!listPanel) return YES;
    CGPoint loc = [touch locationInView:listPanel];
    return !CGRectContainsPoint(listPanel.bounds, loc);
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return g_voiceFilter ? 1 : 2;   /* v30: 搜索时单段；平时 千问段 + 原接口段 */
}
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    if (g_voiceFilter) {
        if (s != 0) return 0;
        return (NSInteger)g_voiceFilter.count;
    }
    if (s == 0) return (NSInteger)QW_VOICE_COUNT;          /* 千问 48 */
    return (NSInteger)(g_voices ?: @[]).count;             /* 原接口（可能还在加载） */
}
- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    if (g_voiceFilter) return nil;
    if (s == 0) return @"千问（48 音色 · 支持语气/语速）";
    return [NSString stringWithFormat:@"原接口（%lu 音色）", (unsigned long)(g_voices ?: @[]).count];
}
/* v30: 显示名是否千问（"ID·中文名" 形态，按 ID 前缀判定） */
- (BOOL)qwIsQwenDisplay:(NSString *)name {
    if (!name.length) return NO;
    for (NSUInteger i = 0; i < QW_VOICE_COUNT; i++) {
        if ([name hasPrefix:g_qwenVoices[i][0]]) return YES;
    }
    return NO;
}
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *cid = @"VC";
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:cid];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:cid];
    NSString *name = nil;
    BOOL isQwen = NO;
    NSUInteger qwIdx = 0;
    if (g_voiceFilter) {
        if (ip.row >= (NSInteger)g_voiceFilter.count) { cell.textLabel.text = @""; return cell; }
        name = g_voiceFilter[ip.row];
        isQwen = [self qwIsQwenDisplay:name];
        if (isQwen) for (NSUInteger i = 0; i < QW_VOICE_COUNT; i++) if ([name hasPrefix:g_qwenVoices[i][0]]) { qwIdx = i; break; }
    } else if (ip.section == 0) {
        if (ip.row >= (NSInteger)QW_VOICE_COUNT) { cell.textLabel.text = @""; return cell; }
        qwIdx = (NSUInteger)ip.row;
        name = [NSString stringWithFormat:@"%@·%@", g_qwenVoices[qwIdx][0], g_qwenVoices[qwIdx][1]];
        isQwen = YES;
    } else {
        NSArray *l = g_voices ?: @[];
        if (ip.row >= (NSInteger)l.count) { cell.textLabel.text = @""; return cell; }
        name = l[ip.row];
        isQwen = NO;
    }
    cell.textLabel.text = name;
    cell.textLabel.font = [UIFont systemFontOfSize:14];
    cell.textLabel.textColor = UIColor.blackColor;
    BOOL selected;
    if (isQwen) selected = (g_backend == 1 && [g_qwenVoices[qwIdx][0] isEqualToString:g_qwenVoice]);
    else         selected = (g_backend == 0 && [name isEqualToString:TTSCurVoice()]);
    cell.accessoryType = selected ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    cell.backgroundColor = UIColor.whiteColor;
    return cell;
}
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    NSString *name = nil;
    BOOL isQwen = NO;
    NSUInteger qwIdx = 0;
    if (g_voiceFilter) {
        if (ip.row >= (NSInteger)g_voiceFilter.count) return;
        name = g_voiceFilter[ip.row];
        isQwen = [self qwIsQwenDisplay:name];
        if (isQwen) for (NSUInteger i = 0; i < QW_VOICE_COUNT; i++) if ([name hasPrefix:g_qwenVoices[i][0]]) { qwIdx = i; break; }
    } else if (ip.section == 0) {
        if (ip.row >= (NSInteger)QW_VOICE_COUNT) return;
        qwIdx = (NSUInteger)ip.row;
        name = [NSString stringWithFormat:@"%@·%@", g_qwenVoices[qwIdx][0], g_qwenVoices[qwIdx][1]];
        isQwen = YES;
    } else {
        NSArray *l = g_voices ?: @[];
        if (ip.row >= (NSInteger)l.count) return;
        name = l[ip.row];
        isQwen = NO;
    }
    if (isQwen) {
        QwenSaveBackend(1);
        QwenSaveVoice(g_qwenVoices[qwIdx][0]);
        TTSSetVoice(name);   /* 显示名同步，跨后端回切保持 */
        self.voiceLabel.text = name;
        [self closeVoiceList];
        [self setStatusOnMain:[NSString stringWithFormat:@"千问音色：%@（语速%.2f）", g_qwenVoices[qwIdx][0], g_qwenRate]];
        TTLog(@"[voice-list] qwen selected %@ rate=%.2f", g_qwenVoices[qwIdx][0], g_qwenRate);
    } else {
        QwenSaveBackend(0);
        TTSSetVoice(name);
        self.voiceLabel.text = name;
        [self closeVoiceList];
        [self setStatusOnMain:[NSString stringWithFormat:@"原接口音色：%@", name]];
        TTLog(@"[voice-list] legacy selected %@", name);
    }
}

/* v30: 搜索过滤（千问+原接口合搜） */
- (void)searchBar:(UISearchBar *)sb textDidChange:(NSString *)text {
    NSString *q = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (q.length == 0) {
        g_voiceFilter = nil;
    } else {
        NSMutableArray *r = [NSMutableArray array];
        for (NSUInteger i = 0; i < QW_VOICE_COUNT; i++) {
            NSString *dn = [NSString stringWithFormat:@"%@·%@", g_qwenVoices[i][0], g_qwenVoices[i][1]];
            if ([dn rangeOfString:q options:NSCaseInsensitiveSearch].location != NSNotFound) [r addObject:dn];
        }
        for (NSString *n in (g_voices ?: @[])) {
            if ([n rangeOfString:q options:NSCaseInsensitiveSearch].location != NSNotFound) [r addObject:n];
        }
        g_voiceFilter = r;
    }
    [self.voiceTable reloadData];
}
- (void)searchBarSearchButtonClicked:(UISearchBar *)sb { [sb resignFirstResponder]; }


- (void)setStatusOnMain:(NSString *)s {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.send.enabled = YES;
        [self.spinner stopAnimating];
        self.statusLabel.text = s;
    });
}

/* 面板直接发送（v15）：TTS → PCM → silk(自编码) → v13c 发送链 */
- (void)sendDirect {
    NSString *text = self.input.text;
    if (!text.length) { self.statusLabel.text = @"请输入文字"; return; }

    id handler = nil;
    NSDictionary *msgAttrs = nil;
    @synchronized([NSObject class]) {
        handler = g_qqSenderHandler;
        msgAttrs = g_qqLastMsgAttrs;
    }
    /* ⚠️ 不再现场 [[h alloc] init]——MsgSenderHandler 是 Swift 类，
     * 无参 init 会命中 precondition/fatalError(SIGABRT)，@try 捕不住 → 闪退。
     * handler 必须来自真实 sendTextMsg 捕获。 */
    if (!handler) {
        /* v3 主动链（静态实锤）: [QQMsgService getInstance] 是元类唯一方法（dispatch_once 单例）
         * v2 教训: class_respondsToSelector 预判静默失败 → v3 不预判，直接 objc_msgSend 调用 + @try 兜底 */
        id qmsInst = nil;
        Class qmsCls = NSClassFromString(@"QQMsgService");
        if (qmsCls) {
            SEL getS = sel_registerName("getInstance");
            @try {
                qmsInst = ((id (*)(id, SEL))objc_msgSend)((id)qmsCls, getS);
                if (qmsInst)
                    TTLog(@"[qq] QQMsgService getInstance=%p (%s)", (__bridge void*)qmsInst,
                          class_getName(object_getClass(qmsInst)));
                else
                    TTLog(@"[qq] getInstance 返回 nil");
            } @catch (NSException *e) {
                TTLog(@"[qq] getInstance 异常 %@", e);
            }
        } else TTLog(@"[qq] QQMsgService 类 MISS");
        /* 备选单例名兜底（若未来版本 getInstance 改名） */
        if (!qmsInst && qmsCls) {
            SEL altSels[] = { sel_registerName("sharedInstance"), sel_registerName("shared"),
                              sel_registerName("defaultService"), sel_registerName("instance") };
            for (int i = 0; i < 4 && !qmsInst; i++) {
                @try {
                    qmsInst = ((id (*)(id, SEL))objc_msgSend)((id)qmsCls, altSels[i]);
                    if (qmsInst) TTLog(@"[qq] QQMsgService %s=%p", sel_getName(altSels[i]), (__bridge void*)qmsInst);
                } @catch (NSException *e) { }
            }
        }
        /* 保存 QQMsgService 实例（G 钩子未触发时备用） */
        if (qmsInst) {
            @synchronized([NSObject class]) { g_qqMsgSvcInst = qmsInst; }
        }
        id peer = g_qqLastPeer;
        if (qmsInst && peer) {
            /* v3.1: getMsgSenderHandlerWithcontact: 参数是 NTAIOContact(静态实锤:
             *   内部调 [参数 convertToOCContact]，OCContact 不响应该 sel → v3 崩异常)
             * NTAIOContact ivars(反汇编实锤): chatType@+8(NSNumber) uin@+0x10(NSString)
             *   groupCode@+0x18 guildID@+0x20，KVC 可写
             * 构造: alloc+init(NSObject init 安全) → KVC 从 OCContact(peer) 复制字段 */
            SEL getS2 = sel_registerName("getMsgSenderHandlerWithcontact:");
            id peerArg = peer;
            Class ntCls = NSClassFromString(@"NTAIOContact");
            if (ntCls) {
                @try {
                    id nt = [[ntCls alloc] init];
                    if (nt) {
                        id chatType = [peer valueForKey:@"chatType"];
                        id peerUid  = [peer valueForKey:@"peerUid"];
                        id guildId  = [peer valueForKey:@"guildId"];
                        if (chatType) [nt setValue:chatType forKey:@"chatType"];
                        if (peerUid)  [nt setValue:peerUid  forKey:@"uin"];
                        if (peerUid)  [nt setValue:peerUid  forKey:@"groupCode"];
                        if (guildId)  [nt setValue:guildId  forKey:@"guildID"];
                        peerArg = nt;
                        TTLog(@"[qq] NTAIOContact 构造 ok ct=%@ uid=%@ gid=%@",
                              chatType, peerUid, guildId);
                    }
                } @catch (NSException *e) {
                    TTLog(@"[qq] NTAIOContact 构造失败 %@ → 退回 OCContact", e);
                    peerArg = peer;
                }
            } else TTLog(@"[qq] NTAIOContact 类 MISS → 用 OCContact");
            @try {
                id fresh = ((id (*)(id, SEL, id))objc_msgSend)(qmsInst, getS2, peerArg);
                if (fresh) {
                    const char *cn = class_getName(object_getClass(fresh));
                    if (cn && strstr(cn, "MsgSenderHandler")) {
                        @synchronized([NSObject class]) { g_qqSenderHandler = fresh; }
                        handler = fresh;
                        TTLog(@"[qq-cap] handler via=主动调用getMsgSenderHandler %p (%s)",
                              (__bridge void*)fresh, cn);
                    } else TTLog(@"[qq] 主动调用返回非handler: %s", cn);
                } else TTLog(@"[qq] 主动调用返回 nil");
            } @catch (NSException *e) { TTLog(@"[qq] 主动调用异常 %@", e); }
        } else if (!peer) TTLog(@"[qq] peer 为空，先发一条消息");
    }
    if (!handler) {
        self.statusLabel.text = @"先在QQ发任意消息(文字/图)完成捕捉";
        TTLog(@"[qq] sendDirect 无 handler，msgService=%p peer=%p",
              (__bridge void*)g_qqMsgService, (__bridge void*)g_qqLastPeer);
        return;
    }

    [self.input resignFirstResponder];
    self.send.enabled = NO;
    self.statusLabel.text = @"合成中…";
    [self.spinner startAnimating];
    NSString *voice = TTSCurVoice();
    TTLog(@"[tts] backend=%ld v=%@ qq-chain", (long)g_backend, voice);

    void (^onAudio)(NSData *, NSError *) = ^(NSData *audio, NSError *error) {
        if (error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self.send.enabled = YES; [self.spinner stopAnimating];
                self.statusLabel.text = [NSString stringWithFormat:@"失败：%@", error.localizedDescription];
            });
            return;
        }
        /* ===== QQ 链: WAV(audio) → PCM 文件(silk编码) → NTAIOAudioModel → sendPttMsg ===== */
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSData *pcm = DecodeToPCM(audio);
            if (!pcm) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    self.send.enabled = YES; [self.spinner stopAnimating];
                    self.statusLabel.text = @"PCM解码失败";
                });
                return;
            }
            NSUInteger ms = pcm.length * 1000 / (NSUInteger)(g_targetSampleRate * 2);
            /* v4.7: PCM 振幅取证 — 判"静音输入"(codec CNG)还是正常语音
             * maxAbs<100 ≈ 全静音 → AVAudioConverter 链有问题(非 codec 采样率) */
            {
                const int16_t *pp = (const int16_t *)pcm.bytes;
                NSUInteger ns = pcm.length/2, maxAbs = 0;
                for (NSUInteger k = 0; k < ns; k++) {
                    int32_t v = pp[k]; if (v < 0) v = -v;
                    if ((NSUInteger)v > maxAbs) maxAbs = (NSUInteger)v;
                }
                char hh[33] = {0};
                for (NSUInteger k = 0; k < 16 && k < pcm.length; k++)
                    sprintf(hh + k*2, "%02x", ((const unsigned char *)pcm.bytes)[k]);
                TTLog(@"[qq] PCM %luB ≈ %lums maxAbs=%lu head32B=%s — silk编码(16k)",
                      (unsigned long)pcm.length, (unsigned long)ms,
                      (unsigned long)maxAbs, hh);
            }

            /* silk 编码: QQSilkRecorder PCM→silk 文件（openPcmFile/openSilkFile 属主是实例ivars）
             * ⚠️ 若 openPcmFile: 不吃 NSData→需换 AVAudioFile 写 wav 再走 silk。v1 先试 QQSilkCodec 直接 encode */
            /* v4.5: 模板检查前置 — 编码要用真实文件头(g_realHead), 且无模板不浪费编码 */
            id realModel = nil; NSString *realPath = nil; id realPh = nil; id realAttrs = nil;
            @synchronized([NSObject class]) {
                realModel = g_realModel; realPath = g_realPath;
                realPh = g_realPhInfo; realAttrs = g_realAttrs;
            }
            if (!realModel || realPath.length == 0) {
                TTLog(@"[qq] 无真实录音模板(model=%p path=%@) — 先在QQ里真实发一条语音",
                      (__bridge void *)realModel, realPath ?: @"(nil)");
                dispatch_async(dispatch_get_main_queue(), ^{
                    self.send.enabled = YES; [self.spinner stopAnimating];
                    self.statusLabel.text = @"先在QQ里真实发一条语音(捕获模板)";
                });
                return;
            }
            NSData *silkData = QQSilkEncode(pcm, (uint32_t)g_targetSampleRate);
            if (!silkData) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    self.send.enabled = YES; [self.spinner stopAnimating];
                    self.statusLabel.text = @"silk编码失败";
                });
                return;
            }
            TTLog(@"[qq] silk %luB 编码完成(v4.6 callback语义判决) — 进入覆写", (unsigned long)silkData.length);

            /* ===== v4.4 捕获重放(v4.5 修格式): silk 覆写真实路径 → 更新 duration → 重放 =====
             * 模板 = 真实录音 model/phInfo/attrs(String 对象 100% QQ 原生零手术) */
            /* 1) silk 覆写真实路径 — QQ 链(configPttElement→MD5→上传)读到的就是 TTS 音频 */
            if (![silkData writeToFile:realPath atomically:YES]) {
                TTLog(@"[qq] ⚠️ 覆写失败 path=%@", realPath);
                dispatch_async(dispatch_get_main_queue(), ^{
                    self.send.enabled = YES; [self.spinner stopAnimating];
                    self.statusLabel.text = @"silk覆写真实路径失败";
                });
                return;
            }
            /* v4.5: 覆写前 dump 输出头 32B — 与真实模板头对比判决 */
            {
                const unsigned char *hp = (const unsigned char *)silkData.bytes;
                NSUInteger hl = silkData.length < 32 ? silkData.length : 32;
                NSMutableString *hx = [NSMutableString string];
                for (NSUInteger k = 0; k < hl; k++) [hx appendFormat:@"%02x", hp[k]];
                TTLog(@"[qq] silk %luB 覆写真实路径 %@ 头32B=%@",
                      (unsigned long)silkData.length, realPath, hx);
            }
            /* 2) 更新模板 duration@+0x20 = 本次毫秒 (float 4B 直写 — 唯一改动字段,
             *    其余 audioType=1/音量列表/recordType 等全是真实录音原值) */
            {
                char *mp = (char *)(__bridge void *)realModel;
                float dms = (float)ms;
                memcpy(mp + 0x20, &dms, 4);
            }
            /* 3) 重放发送 */
            SEL sendSel = NSSelectorFromString(@"sendPttMsgWithAudioModel:placeholderMsgInfo:msgAttributeInfos:saveDataToKernelResultBlock:sendMsgResultBlock:");
            if (![handler respondsToSelector:sendSel]) {
                TTLog(@"[qq] sendPttMsg sel MISS");
                dispatch_async(dispatch_get_main_queue(), ^{
                    self.send.enabled = YES; [self.spinner stopAnimating];
                    self.statusLabel.text = @"sendPttMsg 不存在";
                });
                return;
            }
            __weak typeof(self) ws = self;
            void (^saveBlk)(BOOL) = ^(BOOL ok) {
                TTLog(@"[qq] kernelSave=%d", ok);
            };
            void (^sendBlk)(int, NSString *) = ^(int code, NSString *err) {
                TTLog(@"[qq] sendResult code=%d err=%@", code, err);
                dispatch_async(dispatch_get_main_queue(), ^{
                    typeof(self) ss = ws;
                    if (!ss) return;
                    ss.send.enabled = YES; [ss.spinner stopAnimating];
                    if (code == 0) { ss.statusLabel.text = @"✅ 已发送"; ss.input.text = @""; }
                    else ss.statusLabel.text = [NSString stringWithFormat:@"发送失败 code=%d", code];
                });
            };
            @try {
                TTLog(@"[qq] sendPttMsg 调用前 (replay model=%p ph=%p attrs=%p)",
                      (__bridge void *)realModel, (__bridge void *)realPh,
                      (__bridge void *)realAttrs);
                g_replaying = YES;   /* H 钩子将自触发 — 跳过捕获防自污染 */
                ((void (*)(id, SEL, id, id, id, void (^)(BOOL), void (^)(int, NSString *)))objc_msgSend)
                    (handler, sendSel, realModel, realPh, realAttrs, saveBlk, sendBlk);
                g_replaying = NO;    /* 同步调用返回 — 恢复捕获 */
                TTLog(@"[qq] sendPttMsg 已调用 (replay) — 等待 sendResult");
                dispatch_async(dispatch_get_main_queue(), ^{
                    self.statusLabel.text = @"已发送(重放)—等待结果…";
                });
                /* 20s 兜底: sendBlk 未回调则恢复按钮 */
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    typeof(self) ss = ws;
                    if (ss && !ss.send.enabled) {
                        ss.send.enabled = YES; [ss.spinner stopAnimating];
                        ss.statusLabel.text = @"发送超时—看消息是否已出现";
                    }
                });
            } @catch (NSException *e) {
                g_replaying = NO;   /* 异常路径也要复位, 否则捕获永久失效 */
                TTLog(@"[qq] sendPttMsg 异常 %@", e);
                dispatch_async(dispatch_get_main_queue(), ^{
                    self.send.enabled = YES; [self.spinner stopAnimating];
                    self.statusLabel.text = @"发送异常(看日志)";
                });
                return;
            }
        });
    };

    if (g_backend == 1) {
        RequestQwenTTS(text, g_qwenVoice, g_qwenRate, qwEmoInstruction(g_qwenInstr), onAudio);
    } else {
        RequestTTS(text, voice, onAudio);
    }
}


/* ==================== v2: 多点捕捉（统一出口 + MsgSenderHandler 已知签名全 hook） ====================
 * 逆向结论（QQ 9.3.60 静态）：
 *  - AIO 文字发送不走 MsgSenderHandler.sendTextMsgWithText（Swift 静态分派，swizzle 可能不触发）
 *  - 真实统一出口 = NTKernelAdapter.MessageService.sendMsgWithMsgId:peer:msgElems:msgAttributeInfos:cb:
 *    [v56@0:8q16@24@32@40@?48] —— 发任何消息都经过，捕获 MessageService + OCContact(peer)
 *  - 兜底：MsgSenderHandler 已知签名的 sendPic/sendArk/sendAudio/sendText 全 hook（发图/表情也能捕获）
 *  - 运行时扫描 getMsgSenderHandlerWithcontact: 的归属类（v3 主动取 handler 用） */

typedef void (^QQResultBlock)(int, NSString *);
static void *g_orig_sendText = NULL;
static void *g_orig_sendPic = NULL;
static void *g_orig_sendArk = NULL;
static void *g_orig_sendAudioPh = NULL;
static void *g_orig_sendMsgUnified = NULL;

/* 捕获 handler 实例（类名含 MsgSenderHandler 才存，避免误捕获） */
static void QQCapCls(id self, const char *via) {
    const char *cn = class_getName(object_getClass(self));
    if (!cn || !strstr(cn, "MsgSenderHandler")) return;
    @synchronized([NSObject class]) {
        if (g_qqSenderHandler != self) {
            g_qqSenderHandler = self;
            TTLog(@"[qq-cap] handler via=%s class=%s %p", via, cn, (__bridge void *)self);
        }
    }
}
static void QQSaveAttrs(NSDictionary *attrs) {
    if (attrs && [attrs isKindOfClass:[NSDictionary class]]) {
        @synchronized([NSObject class]) { g_qqLastMsgAttrs = attrs; }
    }
}

/* A: sendTextMsgWithText:msgAttributeInfos:sendMsgResultBlock:  v40@0:8@16@24@?32 */
static void QQHookSendText(id self, SEL cmd, NSString *text, NSDictionary *attrs, QQResultBlock cb) {
    QQCapCls(self, "sendText");
    QQSaveAttrs(attrs);
    if (g_orig_sendText)
        ((void(*)(id,SEL,NSString*,NSDictionary*,QQResultBlock))g_orig_sendText)(self,cmd,text,attrs,cb);
}
/* B: sendPicMsgWithPhotoResult:fileType:thumbSize:sendMsgResultBlock:  v40@0:8@16i24i28@?32 */
static void QQHookSendPic(id self, SEL cmd, id photo, int ftype, int tsize, QQResultBlock cb) {
    QQCapCls(self, "sendPic");
    QQSaveAttrs(nil);
    if (g_orig_sendPic)
        ((void(*)(id,SEL,id,int,int,QQResultBlock))g_orig_sendPic)(self,cmd,photo,ftype,tsize,cb);
}
/* C: sendArkMsgWithByteData:  v24@0:8@16 */
static void QQHookSendArk(id self, SEL cmd, NSData *byteData) {
    QQCapCls(self, "sendArk");
    if (g_orig_sendArk)
        ((void(*)(id,SEL,id))g_orig_sendArk)(self,cmd,byteData);
}
/* D: sendAudioPlacehodlerMsgWithMsgAttributeInfos:audioModel:  v32@0:8@16@24 */
static void QQHookSendAudioPh(id self, SEL cmd, id attrs, id audioModel) {
    QQCapCls(self, "sendAudioPh");
    QQSaveAttrs((NSDictionary*)attrs);
    /* v3.7: QQ 真实录音发送时 dump AudioModel 全槽位型 — String 16B 布局的唯一实锤来源
     * (音频链 TTS 构造的 model 若崩, 对比真实位型即可定案) */
    if (audioModel) {
        @try {
            const char *cn = class_getName(object_getClass(audioModel));
            const unsigned char *p = (const unsigned char *)(__bridge const void *)audioModel;
            uint64_t q0 = *(const uint64_t *)(p + 0x10);
            uint64_t q1 = *(const uint64_t *)(p + 0x18);
            uint8_t  ty = *(const uint8_t  *)(p + 8);
            uint32_t db = *(const uint32_t *)(p + 0x20);
            float    df = *(const float    *)(p + 0x20);
            TTLog(@"[qq-real] %@ type=%u durF=%.1f durBits=%#x path.q0=%#llx path.q1=%#llx",
                  @(cn ? cn : "?"), (unsigned)ty, df, db,
                  (unsigned long long)q0, (unsigned long long)q1);
            /* q0/q1 是 Swift String 位型 — small string 时 q0 低字节即前几个字符, 打出来判读 */
            unsigned char raw[16];
            memcpy(raw, p + 0x10, 16);
            TTLog(@"[qq-real] raw16=%02x%02x%02x%02x%02x%02x%02x%02x %02x%02x%02x%02x%02x%02x%02x%02x",
                  raw[0],raw[1],raw[2],raw[3],raw[4],raw[5],raw[6],raw[7],
                  raw[8],raw[9],raw[10],raw[11],raw[12],raw[13],raw[14],raw[15]);
        } @catch (NSException *e) {
            TTLog(@"[qq-real] dump 异常 %@", e);
        }
    }
    if (g_orig_sendAudioPh)
        ((void(*)(id,SEL,id,id))g_orig_sendAudioPh)(self,cmd,attrs,audioModel);
}
/* ===== v4.4: 捕获重放模板 — 真实录音的 model/phInfo/attrs + 解码出的 silk 路径 ===== */
static id g_realModel = nil;       /* NTAIOAudioModel 真实模板(ARC strong = CFRetain) */
static id g_realPhInfo = nil;      /* AudioPlaceholderMsgInfo 真实模板(size=24, elementID=(0,0)) */
static id g_realAttrs = nil;       /* 真实录音的 msgAttributeInfos(可能 nil) */
static NSString *g_realPath = nil; /* 从 String 存储解码的真实 silk 文件路径 */
static volatile BOOL g_replaying = NO; /* v4.5: replay 发送中 — H 钩子跳过捕获(防自污染) */

/* v4.4: 从 Swift String 大字符串(native 形态)解码内容
 * 位型铁证(v4.3 真机): q0=0xc000000000000090 q1=0x4000000282c6a7e0
 *   q1 高 2 位 0b01 = native; ptr = q1 & 0x3FFF_FFFF_FFFF_FFFF
 *   存储对象布局假设(自指校验判定): ptr+0x00=count/flags(==q0), ptr+0x08=baked(==q1 自指),
 *   ptr+0x10=capacity, ptr+0x18..=UTF-8 内容, 长度 = q0 & 0xFFFFFFFFFFFF
 * 自指校验不命中 → 兜底盲扫描 [ptr-0x10, ptr+0x100] 找 '/' 开头可打印串(含 .slk 或 /Documents/)
 * 返回 nil = 解码失败(调用方保留旧模板) */
static NSString *QQDecodeRealStringPath(uint64_t q0, uint64_t q1) {
    uint64_t ptr = q1 & 0x3FFFFFFFFFFFFFFFULL;   /* 剥高 2 位 native 标志 */
    if (ptr < 0x100000000ULL || ptr > 0x800000000000ULL) return nil;
    const unsigned char *p = (const unsigned char *)(uintptr_t)ptr;
    uint64_t cnt = q0 & 0xFFFFFFFFFFFFULL;       /* count 低 48 位 */
    /* 主路: 自指校验 — [ptr+8] == q1 (baked bits 指回自身) */
    if (cnt >= 8 && cnt <= 1024) {
        uint64_t h0 = *(const uint64_t *)(p + 0x00);
        uint64_t h1 = *(const uint64_t *)(p + 0x08);
        if (h1 == q1 && (h0 & 0xFFFFFFFFFFFFULL) == cnt) {
            NSString *s = [[NSString alloc] initWithBytes:(const void *)(p + 0x18)
                                                   length:(NSUInteger)cnt
                                                 encoding:NSUTF8StringEncoding];
            if (s.length == cnt) return s;   /* 全 ASCII → 长度一致 */
        }
    }
    /* 兜底: 盲扫描找路径样串 */
    const unsigned char *best = NULL; NSUInteger bestLen = 0;
    for (NSInteger off = -0x10; off < 0x100; off++) {
        const unsigned char *s = p + off;
        if (off > -0x10 && s[-1] >= 0x20 && s[-1] < 0x7F) continue;  /* 要串起点 */
        if (s[0] != '/') continue;
        NSUInteger len = 0;
        while (len < 512 && s[len] >= 0x20 && s[len] < 0x7F) len++;
        if (len < 16) continue;
        BOOL hit = NO;
        for (NSUInteger i = 0; i + 4 <= len && !hit; i++)
            if (s[i]=='.' && s[i+1]=='s' && s[i+2]=='l' && s[i+3]=='k') hit = YES;
        for (NSUInteger i = 0; i + 11 <= len && !hit; i++)
            if (!memcmp(s + i, "/Documents/", 11)) hit = YES;
        if (hit && len > bestLen) { best = s; bestLen = len; }
    }
    if (best) return [[NSString alloc] initWithBytes:(const void *)best
                                              length:bestLen
                                            encoding:NSUTF8StringEncoding];
    return nil;
}

/* H: sendPttMsgWithAudioModel:placeholderMsgInfo:msgAttributeInfos:... v56 五参 — v4.3 新增
 * QQ 真实录音发送走这里(不是 D)! dump model 全槽 + placeholderInfo 布局 —
 * String 16B 真实位型的唯一可靠来源 */
static void *g_orig_sendPtt = NULL;
static void QQHookSendPtt(id self, SEL cmd, id audioModel, id phInfo, id attrs,
                          void (^saveBlk)(BOOL), void (^sendBlk)(int, NSString *)) {
    QQCapCls(self, "sendPtt");
    if (audioModel) {
        @try {
            const char *cn = class_getName(object_getClass(audioModel));
            const unsigned char *p = (const unsigned char *)(__bridge const void *)audioModel;
            uint64_t q0 = *(const uint64_t *)(p + 0x10);
            uint64_t q1 = *(const uint64_t *)(p + 0x18);
            uint8_t  ty = *(const uint8_t  *)(p + 8);
            uint32_t db = *(const uint32_t *)(p + 0x20);
            unsigned char raw[16];
            memcpy(raw, p + 0x10, 16);
            TTLog(@"[qq-real] sendPtt model=%@ type=%u durBits=%#x q0=%#llx q1=%#llx",
                  @(cn ? cn : "?"), (unsigned)ty, db,
                  (unsigned long long)q0, (unsigned long long)q1);
            TTLog(@"[qq-real] raw16=%02x%02x%02x%02x%02x%02x%02x%02x %02x%02x%02x%02x%02x%02x%02x%02x",
                  raw[0],raw[1],raw[2],raw[3],raw[4],raw[5],raw[6],raw[7],
                  raw[8],raw[9],raw[10],raw[11],raw[12],raw[13],raw[14],raw[15]);
            /* model 完整 0x50 dump — ivar 布局核对 */
            unsigned char full[0x50]; memcpy(full, p, 0x50);
            TTLog(@"[qq-real] model[0x50]=%s",
                  [[NSString stringWithFormat:@"%02x%02x%02x%02x%02x%02x%02x%02x %02x%02x%02x%02x%02x%02x%02x%02x %02x%02x%02x%02x%02x%02x%02x%02x %02x%02x%02x%02x%02x%02x%02x%02x %02x%02x%02x%02x%02x%02x%02x%02x %02x%02x%02x%02x%02x%02x%02x%02x %02x%02x%02x%02x%02x%02x%02x%02x %02x%02x%02x%02x%02x%02x%02x%02x %02x%02x%02x%02x%02x%02x%02x%02x %02x%02x%02x%02x%02x%02x%02x%02x",
                  full[0],full[1],full[2],full[3],full[4],full[5],full[6],full[7],
                  full[8],full[9],full[10],full[11],full[12],full[13],full[14],full[15],
                  full[16],full[17],full[18],full[19],full[20],full[21],full[22],full[23],
                  full[24],full[25],full[26],full[27],full[28],full[29],full[30],full[31],
                  full[32],full[33],full[34],full[35],full[36],full[37],full[38],full[39],
                  full[40],full[41],full[42],full[43],full[44],full[45],full[46],full[47],
                  full[48],full[49],full[50],full[51],full[52],full[53],full[54],full[55],
                  full[56],full[57],full[58],full[59],full[60],full[61],full[62],full[63],
                  full[64],full[65],full[66],full[67],full[68],full[69],full[70],full[71],
                  full[72],full[73],full[74],full[75],full[76],full[77],full[78],full[79]] UTF8String]);
            if (phInfo) {
                const char *pcn = class_getName(object_getClass(phInfo));
                const unsigned char *pp = (const unsigned char *)(__bridge const void *)phInfo;
                unsigned char praw[0x30]; memcpy(praw, pp, 0x30);
                TTLog(@"[qq-real] phInfo=%@ raw30=%s size=%zu",
                      @(pcn ?: "?"),
                      [[NSString stringWithFormat:@"%02x%02x%02x%02x%02x%02x%02x%02x %02x%02x%02x%02x%02x%02x%02x%02x %02x%02x%02x%02x%02x%02x%02x%02x %02x%02x%02x%02x%02x%02x%02x%02x %02x%02x%02x%02x%02x%02x%02x%02x %02x%02x%02x%02x%02x%02x%02x%02x",
                        praw[0],praw[1],praw[2],praw[3],praw[4],praw[5],praw[6],praw[7],
                        praw[8],praw[9],praw[10],praw[11],praw[12],praw[13],praw[14],praw[15],
                        praw[16],praw[17],praw[18],praw[19],praw[20],praw[21],praw[22],praw[23],
                        praw[24],praw[25],praw[26],praw[27],praw[28],praw[29],praw[30],praw[31],
                        praw[32],praw[33],praw[34],praw[35],praw[36],praw[37],praw[38],praw[39],
                        praw[40],praw[41],praw[42],praw[43],praw[44],praw[45],praw[46],praw[47]] UTF8String],
                      class_getInstanceSize(object_getClass(phInfo)));
            } else TTLog(@"[qq-real] phInfo=nil");
        } @catch (NSException *e) {
            TTLog(@"[qq-real] sendPtt dump 异常 %@", e);
        }
        /* ===== v4.4: 捕获重放模板 =====
         * storage dump(布局判决) + 路径解码 + model/phInfo/attrs 全捕获(ARC strong)
         * 自指校验: [ptr+0x00]==q0 && [ptr+0x08]==q1 → UTF-8@ptr+0x18 len=count
         * v4.5: g_replaying 期间跳过 — 此时文件已被自己覆写, 读头=自污染(真实头丢失) */
        if (g_replaying) {
            TTLog(@"[qq-real] (replay 自触发 — 跳过捕获, 模板保持)");
        } else @try {
            uint64_t q0 = *(const uint64_t *)((const unsigned char *)(__bridge const void *)audioModel + 0x10);
            uint64_t q1 = *(const uint64_t *)((const unsigned char *)(__bridge const void *)audioModel + 0x18);
            if ((q1 >> 62) == 1ULL) {                      /* native 大字符串 */
                uint64_t sp = q1 & 0x3FFFFFFFFFFFFFFFULL;
                if (sp >= 0x100000000ULL && sp <= 0x800000000000ULL) {
                    const unsigned char *spx = (const unsigned char *)(uintptr_t)sp;
                    unsigned char sd[0x30]; memcpy(sd, spx, 0x30);
                    NSString *sdHex = [[NSString stringWithFormat:
                        @"%02x%02x%02x%02x%02x%02x%02x%02x %02x%02x%02x%02x%02x%02x%02x%02x %02x%02x%02x%02x%02x%02x%02x%02x %02x%02x%02x%02x%02x%02x%02x%02x %02x%02x%02x%02x%02x%02x%02x%02x %02x%02x%02x%02x%02x%02x%02x%02x",
                        sd[0],sd[1],sd[2],sd[3],sd[4],sd[5],sd[6],sd[7],
                        sd[8],sd[9],sd[10],sd[11],sd[12],sd[13],sd[14],sd[15],
                        sd[16],sd[17],sd[18],sd[19],sd[20],sd[21],sd[22],sd[23],
                        sd[24],sd[25],sd[26],sd[27],sd[28],sd[29],sd[30],sd[31],
                        sd[32],sd[33],sd[34],sd[35],sd[36],sd[37],sd[38],sd[39],
                        sd[40],sd[41],sd[42],sd[43],sd[44],sd[45],sd[46],sd[47]]
                        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                    NSString *hdr16 = [[NSString alloc] initWithBytes:(const void *)(spx + 0x18)
                                                              length:((q0 & 0xFFFFFFFFFFFFULL) < 48 ? (NSUInteger)(q0 & 0xFFFFFFFFFFFFULL) : 48)
                                                            encoding:NSUTF8StringEncoding];
                    TTLog(@"[qq-real] storage@%llx dump=%@ utf8@+0x18≈%@",
                          (unsigned long long)sp, sdHex, hdr16 ?: @"(nil)");
                }
            } else TTLog(@"[qq-real] String 非 native 形态 (q1>>62)=%llu — 只支持大字符串捕获",
                         (unsigned long long)(q1 >> 62));
            NSString *rpath = QQDecodeRealStringPath(q0, q1);
            if (rpath.length) {
                /* v4.5: 读真实录音文件头 32B + 大小 — 格式/采样率/帧结构取证
                 * 判决: "#!SILK_V3"=silk标准 / 0x02开头=QQ变体 / "#!AMR\n"=AMR(全案推翻)
                 * 比特率 = (fileSize-hdr)*8/duration → 24kbps≈24kHz silk 共识验证 */
                memset(g_realHead, 0, sizeof(g_realHead)); g_realHeadLen = 0; g_realFileSize = -1;
                NSData *fdat = [NSData dataWithContentsOfFile:rpath];
                if (fdat.length) {
                    g_realFileSize = (long long)fdat.length;
                    g_realHeadLen = fdat.length < 32 ? fdat.length : 32;
                    memcpy(g_realHead, fdat.bytes, g_realHeadLen);
                    uint32_t dms = 0; memcpy(&dms, (const unsigned char *)(__bridge const void *)audioModel + 0x20, 4);
                    float dur = *(const float *)&dms;
                    TTLog(@"[qq-real] 文件 %lldB dur=%.0fms 比特率≈%.0fkbps 头32B=%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x %02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x magic=%@",
                          g_realFileSize, dur,
                          g_realFileSize > 0 && dur > 0 ? (g_realFileSize - 11) * 8.0 / dur : 0,
                          g_realHead[0],g_realHead[1],g_realHead[2],g_realHead[3],
                          g_realHead[4],g_realHead[5],g_realHead[6],g_realHead[7],
                          g_realHead[8],g_realHead[9],g_realHead[10],g_realHead[11],
                          g_realHead[12],g_realHead[13],g_realHead[14],g_realHead[15],
                          g_realHead[16],g_realHead[17],g_realHead[18],g_realHead[19],
                          g_realHead[20],g_realHead[21],g_realHead[22],g_realHead[23],
                          g_realHead[24],g_realHead[25],g_realHead[26],g_realHead[27],
                          g_realHead[28],g_realHead[29],g_realHead[30],g_realHead[31],
                          [[NSString alloc] initWithBytes:g_realHead
                                                    length:(g_realHeadLen >= 10 ? 10 : g_realHeadLen)
                                                encoding:NSUTF8StringEncoding]);
                } else TTLog(@"[qq-real] ⚠️ 真实文件读取失败 %@ (发送后已删? 下次捕获再试)", rpath);
                @synchronized([NSObject class]) {
                    g_realModel  = audioModel;   /* ARC strong = 自动 retain */
                    g_realPhInfo = phInfo;       /* 可能为 nil — 与真实发送一致 */
                    g_realAttrs  = attrs;        /* 可能为 nil — 与真实发送一致 */
                    g_realPath   = [rpath copy];
                }
                TTLog(@"[qq-real] ✅ 模板已捕获 path=%@ (model=%p ph=%p attrs=%p)",
                      rpath, (__bridge void *)audioModel, (__bridge void *)phInfo,
                      (__bridge void *)attrs);
            } else {
                TTLog(@"[qq-real] ⚠️ 路径解码失败 — 模板未更新(保留旧模板) path=%@",
                      g_realPath ?: @"(无)");
            }
        } @catch (NSException *e) {
            TTLog(@"[qq-real] 模板捕获异常 %@", e);
        }
    }
    if (g_orig_sendPtt)
        ((void(*)(id,SEL,id,id,id,void(^)(BOOL),void(^)(int,NSString*)))g_orig_sendPtt)
            (self,cmd,audioModel,phInfo,attrs,saveBlk,sendBlk);
}
/* J: sendAiVoiceMsgWithGroupCode:voiceType:voiceTimbreID:text:msgAttributeInfos:sendMsgResultBlock:
 * v60@0:8Q16I24@28@36@44@?52 — QQ 自带 AI 语音发送(群聊)。用户用到时抓 groupCode/voiceType */
static void *g_orig_sendAiVoice = NULL;
static void QQHookSendAiVoice(id self, SEL cmd, uint64_t groupCode, uint32_t voiceType,
                              NSString *timbreID, NSString *text, id attrs,
                              void (^cb)(int, NSString *)) {
    QQCapCls(self, "sendAiVoice");
    TTLog(@"[qq-real] sendAiVoice groupCode=%llu voiceType=%u timbre=%@ textLen=%lu",
          (unsigned long long)groupCode, (unsigned)voiceType,
          timbreID ?: @"(nil)", (unsigned long)text.length);
    if (g_orig_sendAiVoice)
        ((void(*)(id,SEL,uint64_t,uint32_t,NSString*,NSString*,id,void(^)(int,NSString*)))g_orig_sendAiVoice)
            (self,cmd,groupCode,voiceType,timbreID,text,attrs,cb);
}
/* F: NTKernelAdapter.MessageService 统一出口  v56@0:8q16@24@32@40@?48
 * (self, int64 msgId, OCContact peer, NSArray elems, NSDictionary attrs, block cb) */
static void QQHookSendMsgUnified(id self, SEL cmd, int64_t msgId, id peer, id elems, id attrs, void *cb) {
    @synchronized([NSObject class]) {
        if (g_qqMsgService != self) {
            g_qqMsgService = self;
            TTLog(@"[qq-cap] MessageService %p (%s)", (__bridge void *)self, class_getName(object_getClass(self)));
        }
        if (peer && g_qqLastPeer != peer) {
            g_qqLastPeer = peer;
            TTLog(@"[qq-cap] peer=%p class=%s", (__bridge void *)peer, class_getName(object_getClass(peer)));
            /* v3.1: dump OCContact 字段值(chatType/peerUid/guildId) — NTAIOContact 映射用 */
            @try {
                TTLog(@"[qq-cap] OCContact dump ct=%@ uid=%@ gid=%@",
                      [peer valueForKey:@"chatType"], [peer valueForKey:@"peerUid"],
                      [peer valueForKey:@"guildId"]);
            } @catch (NSException *e) { }
        }
        if (attrs && [attrs isKindOfClass:[NSDictionary class]]) g_qqLastMsgAttrs = attrs;
    }
    if (g_orig_sendMsgUnified)
        ((void(*)(id,SEL,int64_t,id,id,id,void*))g_orig_sendMsgUnified)(self,cmd,msgId,peer,elems,attrs,cb);
}
/* E: QQMsgService.getMsgSenderHandlerWithcontact:  @24@0:8@16
 * (id self, SEL cmd, OCContact contact) → 返回 MsgSenderHandler 实例
 * ⚠️ QQMsgService 是 ObjC 类（非 Swift），调用必走 objc_msgSend → hook 必触发
 * 当 QQ 内部调它取 handler 时，捕获返回值 = MsgSenderHandler 实例
 * v3 增强: 同时捕获 self (QQMsgService 实例) + peer (contact) */
static void *g_orig_getHandler = NULL;
static id QQHookGetHandler(id self, SEL cmd, id contact) {
    id r = nil;
    /* 捕 QQMsgService 实例 + peer（主动链备用） */
    @synchronized([NSObject class]) {
        g_qqMsgSvcInst = self;
        if (contact) g_qqLastPeer = contact;
    }
    if (g_orig_getHandler)
        r = ((id(*)(id,SEL,id))g_orig_getHandler)(self, cmd, contact);
    if (r) {
        const char *cn = class_getName(object_getClass(r));
        if (cn && strstr(cn, "MsgSenderHandler")) {
            @synchronized([NSObject class]) {
                if (g_qqSenderHandler != r) {
                    g_qqSenderHandler = r;
                    TTLog(@"[qq-cap] handler via=getMsgSenderHandlerWithcontact: %p (%s)",
                          (__bridge void *)r, cn);
                }
            }
        } else {
            TTLog(@"[qq-cap] getMsgSenderHandler 返回非 handler: %s", cn ? cn : "?");
        }
    } else TTLog(@"[qq-cap] E钩子: getMsgSenderHandler 返回 nil (self=%p)", (__bridge void*)self);
    return r;
}
/* G1: QQMsgService.sendTextMsgByOCContact:richText:callBack: [v48@0:8@16@24@?32]
 * 捕 QQMsgService 实例 + peer(x2) —— QQMsgService 是 ObjC 类，任何发送路径都走 objc_msgSend */
static void *g_orig_qmsSendText = NULL;
static void QQHookQmsSendText(id self, SEL cmd, id contact, id richText, void *cb) {
    @synchronized([NSObject class]) {
        g_qqMsgSvcInst = self;
        if (contact) g_qqLastPeer = contact;
    }
    TTLog(@"[qq-cap] G1 sendTextMsgByOCContact self=%p peer=%p",
          (__bridge void*)self, (__bridge void*)contact);
    if (g_orig_qmsSendText)
        ((void(*)(id,SEL,id,id,void*))g_orig_qmsSendText)(self,cmd,contact,richText,cb);
}
/* G2: QQMsgService.sendMsgWithOCContact:msgElems:msgAttributeInfos:callBack: [v48@0:8@16@24@32@?40]
 * 通用 OC 发送出口 —— hook 上后发任何消息都能捕实例+peer+attrs */
static void *g_orig_qmsSendOC = NULL;
static void QQHookQmsSendOC(id self, SEL cmd, id contact, id elems, id attrs, void *cb) {
    @synchronized([NSObject class]) {
        g_qqMsgSvcInst = self;
        if (contact) g_qqLastPeer = contact;
        if (attrs && [attrs isKindOfClass:[NSDictionary class]]) g_qqLastMsgAttrs = attrs;
    }
    TTLog(@"[qq-cap] G2 sendMsgWithOCContact self=%p peer=%p", (__bridge void*)self, (__bridge void*)contact);
    if (g_orig_qmsSendOC)
        ((void(*)(id,SEL,id,id,id,void*))g_orig_qmsSendOC)(self,cmd,contact,elems,attrs,cb);
}

/* 安装单个 hook（类型编码不匹配则跳过，防 QQ 版本差异导致崩溃） */
static void QQInstallHook(Class cls, const char *selname, const char *expectTypes, IMP newImp, void **origSlot, const char *tag) {
    SEL s = sel_registerName(selname);
    Method m = class_getInstanceMethod(cls, s);
    if (!m) { TTLog(@"[qq-hook] %s sel MISS", tag); return; }
    const char *t = method_getTypeEncoding(m);
    if (expectTypes && t && strcmp(t, expectTypes) != 0) {
        TTLog(@"[qq-hook] %s types不符 expect=%s got=%s (跳过)", tag, expectTypes, t);
        return;
    }
    *origSlot = (void*)method_setImplementation(m, newImp);
    TTLog(@"[qq-hook] %s OK types=%s", tag, t ? t : "?");
}

__attribute__((constructor))
static void QQFloatV2Init(void) {
    g_logPath = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/QQFloat.log"];
    QwenLoadState();
    TTSInstallCrashGuards();   /* 崩了落 Documents/QQFloatCrash.log（信号+地址+dylib基址） */
    TTLog(@"QQFloat v4.13 init (callback版encode + 正确码率参数 + 一次性喂全量)");

    /* F: 统一出口（最高优先——发任何消息都触发） */
    Class ms = NSClassFromString(@"_TtC15NTKernelAdapter14MessageService");
    if (ms) {
        QQInstallHook(ms, "sendMsgWithMsgId:peer:msgElems:msgAttributeInfos:cb:",
                      "v56@0:8q16@24@32@40@?48", (IMP)QQHookSendMsgUnified, &g_orig_sendMsgUnified, "F-unified");
    } else TTLog(@"[qq-init] MessageService MISS");

    /* A-D: MsgSenderHandler 已知签名 */
    Class h = NSClassFromString(@"_TtC10MsgManager16MsgSenderHandler");
    if (h) {
        QQInstallHook(h, "sendTextMsgWithText:msgAttributeInfos:sendMsgResultBlock:",
                      "v40@0:8@16@24@?32", (IMP)QQHookSendText, &g_orig_sendText, "A-text");
        QQInstallHook(h, "sendPicMsgWithPhotoResult:fileType:thumbSize:sendMsgResultBlock:",
                      "v40@0:8@16i24i28@?32", (IMP)QQHookSendPic, &g_orig_sendPic, "B-pic");
        QQInstallHook(h, "sendArkMsgWithByteData:",
                      "v24@0:8@16", (IMP)QQHookSendArk, &g_orig_sendArk, "C-ark");
        QQInstallHook(h, "sendAudioPlacehodlerMsgWithMsgAttributeInfos:audioModel:",
                      "v32@0:8@16@24", (IMP)QQHookSendAudioPh, &g_orig_sendAudioPh, "D-audioPh");
        /* v4.3: H/J 新增 — QQ 真实录音走 sendPttMsg(不是 D); AI 语音抓 groupCode */
        QQInstallHook(h, "sendPttMsgWithAudioModel:placeholderMsgInfo:msgAttributeInfos:saveDataToKernelResultBlock:sendMsgResultBlock:",
                      "v56@0:8@16@24@32@?40@?48", (IMP)QQHookSendPtt, &g_orig_sendPtt, "H-sendPtt");
        QQInstallHook(h, "sendAiVoiceMsgWithGroupCode:voiceType:voiceTimbreID:text:msgAttributeInfos:sendMsgResultBlock:",
                      "v60@0:8Q16I24@28@36@44@?52", (IMP)QQHookSendAiVoice, &g_orig_sendAiVoice, "J-aiVoice");
    } else TTLog(@"[qq-init] MsgSenderHandler MISS");

    /* E: QQMsgService.getMsgSenderHandlerWithcontact: (ObjC类，hook必触发) */
    Class qms = NSClassFromString(@"QQMsgService");
    if (qms) {
        QQInstallHook(qms, "getMsgSenderHandlerWithcontact:", "@24@0:8@16",
                      (IMP)QQHookGetHandler, &g_orig_getHandler, "E-getHandler");
        /* G1/G2: QQMsgService OC 发送系（静态实锤的实例方法，25 方法表中的两个）
         * types 不匹配自动跳过（QQInstallHook 内置校验） */
        QQInstallHook(qms, "sendTextMsgByOCContact:richText:callBack:",
                      "v48@0:8@16@24@?32", (IMP)QQHookQmsSendText, &g_orig_qmsSendText, "G1-qmsText");
        QQInstallHook(qms, "sendMsgWithOCContact:msgElems:msgAttributeInfos:callBack:",
                      "v48@0:8@16@24@32@?40", (IMP)QQHookQmsSendOC, &g_orig_qmsSendOC, "G2-qmsOC");
        /* dump QQMsgService 类方法（找 sharedInstance/shared 主动取实例用） */
        unsigned mc = 0;
        Method *ml = class_copyMethodList(object_getClass(qms), &mc);
        if (ml) {
            for (unsigned j = 0; j < mc; j++)
                TTLog(@"[qq-dump] QQMsgService+ .%s [%s]",
                      sel_getName(method_getName(ml[j])),
                      method_getTypeEncoding(ml[j]) ? method_getTypeEncoding(ml[j]) : "?");
            free(ml);
        }
        /* v3: dump QQMsgService 实例方法表(全部 send/get 方法, 供 v4 定位) */
        unsigned mi = 0;
        Method *il = class_copyMethodList(qms, &mi);
        if (il) {
            for (unsigned j = 0; j < mi; j++)
                TTLog(@"[qq-dump] QQMsgService- .%s [%s]",
                      sel_getName(method_getName(il[j])),
                      method_getTypeEncoding(il[j]) ? method_getTypeEncoding(il[j]) : "?");
            free(il);
        }
    } else TTLog(@"[qq-init] QQMsgService MISS");

    /* 运行时扫描: getMsgSenderHandlerWithcontact: 归属类（v3 主动取 handler 用，后台 5s 后执行） */
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        int n = objc_getClassList(NULL, 0);
        if (n <= 0 || n > 300000) return;
        Class *list = (Class *)malloc((size_t)n * sizeof(Class));
        n = objc_getClassList(list, n);
        SEL s = sel_registerName("getMsgSenderHandlerWithcontact:");
        int found = 0;
        /* v3.6.1: class_respondsToSelector 会触发类 realize → 某些类 +initialize 抛异常
         * (真机实锤: ProtobufLite initializePBClassInfo 抛 "NoClass - Message Class not exist",
         *  竞态时序: QQ 的 Protobuf 注册表未就绪时被我们提前唤醒 → uncaught → 闪退)
         * → 每个类包 @try, 异常直接跳过该类继续扫描 */
        for (int i = 0; i < n; i++) {
            Class c = list[i];
            if (!c) continue;
            @try {
            /* 快速预判：绝大多数类不响应该 selector，先跳过（避免 7 万类逐个 copyMethodList） */
            if (!class_respondsToSelector(c, s)) continue;
            const char *cn = class_getName(c);
            if (!cn || !cn[0]) continue;
            /* 仅当方法"直接定义"在此类（非继承）才报 owner */
            unsigned cnt2 = 0;
            Method *ml2 = class_copyMethodList(c, &cnt2);
            if (!ml2) continue;
            for (unsigned j = 0; j < cnt2; j++) {
                if (method_getName(ml2[j]) == s) {
                    TTLog(@"[qq-scan] getMsgSenderHandlerWithcontact: owner=%s types=%s",
                          cn, method_getTypeEncoding(ml2[j]));
                    found++;
                    break;
                }
            }
            free(ml2);
            if (found >= 20) break;
            } @catch (NSException *e) {
                /* ProtobufLite/Lazy 类 realize 失败 — 跳过 */
                continue;
            }
        }
        free(list);
        TTLog(@"[qq-scan] done classes=%d found=%d", n, found);
        /* v2 诊断: 两关键类全量方法表(类自身方法, 含签名) —— 捕捉失败时 v3 直接照此表定 hook */
        Class dumpCls[] = { NSClassFromString(@"_TtC15NTKernelAdapter14MessageService"),
                            NSClassFromString(@"_TtC10MsgManager16MsgSenderHandler"),
                            NSClassFromString(@"QQSilkCodec"),
                            NSClassFromString(@"QQSilkRecorder"),
                            NSClassFromString(@"QQSilkEncodeDecode"),
                            NSClassFromString(@"AudioSilkCodec"),
                            NSClassFromString(@"SilkCodec"),
                            NSClassFromString(@"PcmEncoder") };
        int nDump = 8;
        for (int d = 0; d < nDump; d++) {
            Class c = dumpCls[d];
            if (!c) { TTLog(@"[qq-dump] class MISS"); continue; }
            @try {
            unsigned cnt = 0;
            Method *ml = class_copyMethodList(c, &cnt);
            if (!ml) continue;
            for (unsigned j = 0; j < cnt; j++) {
                TTLog(@"[qq-dump] %s .%s [%s]",
                      class_getName(c), sel_getName(method_getName(ml[j])),
                      method_getTypeEncoding(ml[j]) ? method_getTypeEncoding(ml[j]) : "?");
            }
            free(ml);
            } @catch (NSException *e) { /* v3.6.1: 同上防 realize 异常 */ }
        }
    });
    TTLog(@"[qq-init] v3.7 hooks installed");
}
@end
