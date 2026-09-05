//
//  PMGlass.m —— 塔塔冒险队 功能版悬浮窗
//  ────────────────────────────────────────────────────────────────────────
//  FloatGlass 液态玻璃 UI（Xcode 正规编译版） + PMLib v47 功能引擎（方式④）
//
//  架构：
//    · 功能引擎：Lua hook（无敌/秒杀三态/加速3x），状态源 = C 全局变量
//      （pm_god / pm_hit / pm_spd），游戏 Lua 每帧经 __PM_state__ 拉取——即时生效
//    · UI：面板三个开关按钮，主线程回调直接改 C 全局（按钮回调 = 主线程，
//      UpdateBeat 回调 = 游戏主线程 → 天然串行，零竞态、零文件通道）
//    · 编译：真实 iPhoneOS SDK（GitHub Actions macOS runner），
//      dispatch / CFRunLoop / UIKit 全部静态链接 —— -nostdlib 时代的符号坑全部消失
//
//  注入：TrollFools / TrollStore 注入到 IGame-Mainland（塔塔冒险队）。
//  银行类 App 在黑名单中自动跳过（同 FloatGlass）。
//
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <dlfcn.h>
#include <pthread.h>
#include <unistd.h>
#include <time.h>
#include <sys/stat.h>
#include <math.h>
#include <dispatch/dispatch.h>

// ════════════════════════════════════════════════════════════════════════
// Part 1  功能引擎（PMLib v47 同款，去掉文件开关通道与 mach/runloop 桥）
// ════════════════════════════════════════════════════════════════════════

typedef struct lua_State lua_State;
static lua_State* (*L_getstate)(void);
static lua_State* (*L_toluamain)(void);
static int (*L_loadstring)(lua_State*, const char*);
static int (*L_pcall)(lua_State*, int, int, int);
static void (*L_pushcclosure)(lua_State*, void*, int);
static void (*L_setglobal)(lua_State*, const char*);
static void (*L_pushstring)(lua_State*, const char*);
static void (*L_pushnumber)(lua_State*, double);
static int (*L_gettop)(lua_State*);
static void (*L_settop)(lua_State*, int);
static const char* (*L_tolstring)(lua_State*, int, size_t*);

typedef void Il2CppDomain; typedef void Il2CppImage; typedef void Il2CppClass;
typedef void Il2CppAssembly; typedef void FieldInfo;
static Il2CppDomain* (*I_domain_get)(void);
static Il2CppAssembly** (*I_domain_assemblies)(const Il2CppDomain*, size_t*);
static const Il2CppImage* (*I_asm_get_image)(Il2CppAssembly*);
static const char* (*I_image_get_name)(const Il2CppImage*);
static Il2CppClass* (*I_class_from_name)(const Il2CppImage*, const char*, const char*);
static FieldInfo* (*I_class_field)(Il2CppClass*, const char*);
static void (*I_field_static_get)(FieldInfo*, void*);
static void* (*I_thread_attach)(Il2CppDomain*);

static void* g_uf = NULL;
static lua_State* g_L = NULL;

// ── 状态源（UI 与 Lua 共享；主线程串行访问，volatile 保证可见性）──
// pm_god:  0关 / 1开（无敌）
// pm_hit:  0关 / 1温和(伤害×1000) / 2暴力(9e15)
// pm_spd:  0关 / 1开（加速3x）
static volatile int pm_god = 0, pm_hit = 0, pm_spd = 0;
static volatile int g_state_pulls = 0;   // tataOnFrame 拉状态计数（引擎活着）
static volatile int g_beat_ok = 0;      // install 成功
static volatile int g_hook_flag = 0;    // pm_hooked 文件存在（战斗 hook 就绪）
static FILE* g_log = NULL;
#define LOG(...) do { if (g_log) { fprintf(g_log, __VA_ARGS__); fflush(g_log); } } while(0)

extern uint32_t _dyld_image_count(void);
extern const char* _dyld_get_image_name(uint32_t image_index);

// 扫描非系统镜像找 UnityFramework（按符号探测，名字匹配不可靠）
static void find_uf(void) {
    if (g_uf) return;
    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) {
        const char* nm = _dyld_get_image_name(i);
        if (!nm) continue;
        if (strncmp(nm, "/usr/lib", 8) == 0 || strncmp(nm, "/System/", 8) == 0 ||
            strncmp(nm, "/Developer/", 11) == 0) continue;
        void* h = dlopen(nm, RTLD_LAZY | RTLD_NOLOAD);
        if (!h) continue;
        if (dlsym(h, "igame_getLuaState") || dlsym(h, "luaL_loadstring")) {
            g_uf = h;
            LOG("UF found (%s)\n", nm);
            return;
        }
    }
}

static void resolve_syms(void) {
    if (!g_uf || L_getstate) return;
    L_getstate  = (void*)dlsym(g_uf, "igame_getLuaState");
    L_toluamain = (void*)dlsym(g_uf, "tolua_getmainstate");
    L_loadstring= (void*)dlsym(g_uf, "luaL_loadstring");
    L_pushcclosure = (void*)dlsym(g_uf, "lua_pushcclosure");
    L_setglobal    = (void*)dlsym(g_uf, "lua_setglobal");
    L_pushstring   = (void*)dlsym(g_uf, "lua_pushstring");
    L_pushnumber   = (void*)dlsym(g_uf, "lua_pushnumber");
    L_pcall     = (void*)dlsym(g_uf, "lua_pcall");
    L_gettop    = (void*)dlsym(g_uf, "lua_gettop");
    L_settop    = (void*)dlsym(g_uf, "lua_settop");
    L_tolstring = (void*)dlsym(g_uf, "lua_tolstring");
}

// ── Lua 可调用的 C 函数（谁调它谁提供线程安全；游戏内也能切开关）──
static int pm_toggle_cfunc(lua_State* L) {
    const char* key = L_tolstring ? L_tolstring(L, 1, NULL) : NULL;
    if (!key) return 0;
    if (strcmp(key, "god") == 0) {
        pm_god = !pm_god;
        if (L_pushnumber) L_pushnumber(L, pm_god);
        return 1;
    } else if (strcmp(key, "onehit") == 0) {
        pm_hit = (pm_hit + 1) % 3;   // 三态循环：关→温和→暴力→关
        if (L_pushnumber) L_pushnumber(L, pm_hit);
        return 1;
    } else if (strcmp(key, "speed") == 0) {
        pm_spd = !pm_spd;
        if (L_pushnumber) L_pushnumber(L, pm_spd);
        return 1;
    }
    return 0;
}

// 查询当前状态（数字）：__PM_state__('god'|'onehit'|'speed')
static int pm_state_cfunc(lua_State* L) {
    const char* key = L_tolstring ? L_tolstring(L, 1, NULL) : NULL;
    double v = 0;
    if (key) {
        if (strcmp(key, "god") == 0) v = pm_god;
        else if (strcmp(key, "onehit") == 0) v = pm_hit;
        else if (strcmp(key, "speed") == 0) v = pm_spd;
    }
    g_state_pulls++;   // 引擎活着的证据（UI 显示用）
    if (L_pushnumber) L_pushnumber(L, v);
    return 1;
}

static int lua_dostring(const char* code) {
    if (!g_L || !L_loadstring || !L_pcall) return -100;
    int top = L_gettop(g_L);
    if (L_loadstring(g_L, code) != 0) {
        const char* e = L_tolstring ? L_tolstring(g_L, -1, NULL) : NULL;
        LOG("lua load err: %s\n", e ? e : "?");
        if (L_settop) L_settop(g_L, top);
        return -101;
    }
    if (L_pcall(g_L, 0, 0, 0) != 0) {
        const char* e = L_tolstring ? L_tolstring(g_L, -1, NULL) : NULL;
        LOG("lua pcall err: %s\n", e ? e : "?");
        if (L_settop) L_settop(g_L, top);
        return -102;
    }
    if (L_settop) L_settop(g_L, top);
    return 0;
}

static void try_get_lua(void) {
    if (L_getstate) {
        lua_State* s = L_getstate();
        if (s) { g_L = s; LOG("lua via igame_getLuaState=%p\n", s); return; }
    }
    if (L_toluamain) {
        lua_State* s = L_toluamain();
        if (s) { g_L = s; LOG("lua via tolua_getmainstate=%p\n", s); return; }
    }
}

// ── install_beat：注册 C 函数 + 挂 UpdateBeat 每帧回调（必须在游戏主线程执行！）──
static void install_beat(void) {
    if (!g_L) return;
    const char* homeX = getenv("HOME");
    const char* home = homeX ? homeX : "/var/mobile";
    char rs[4096];
    int n = snprintf(rs, sizeof(rs),
        "rawset(_G, '__PM_S__', {god=false, onehit=0, speed=1})\n"
        "local st = rawget(_G, '__PM_S__')\n"
        "local frame = 0\n"
        "local function pmOnFrame()\n"
        "  frame = frame + 1\n"
        "  local stt = rawget(_G, '__PM_state__')\n"
        "  if stt then\n"
        "    local g = stt('god'); local oh = stt('onehit'); local sp = stt('speed')\n"
        "    st.god = (g == 1)\n"
        "    st.onehit = oh\n"                      // 0关 1温和 2暴力
        "    st.speed = (sp == 1) and 3 or 1\n"
        "  end\n"
        "  if not rawget(_G, '__PM_H__') then\n"
        "    local ed = rawget(_G, 'ed')\n"
        "    local UC = ed and ed.UnitComponent\n"
        "    if UC then\n"
        "      rawset(_G, '__PM_H__', true)\n"
        "      local BE = ed.BattleEngine\n"
        "      if BE and not rawget(_G, '__PM_SP__') and BE.GetTimeScale then\n"
        "        rawset(_G, '__PM_SP__', true)\n"
        "        local oldGTS = BE.GetTimeScale\n"
        "        BE.GetTimeScale = function(self)\n"
        "          local ts = oldGTS(self)\n"
        "          local s2 = rawget(_G, '__PM_S__')\n"
        "          if s2 and s2.speed and s2.speed > 1 then return ts * s2.speed end\n"
        "          return ts\n"
        "        end\n"
        "      end\n"
        "      local oldTD = UC.TakeDamage\n"
        "      if oldTD then\n"
        "        UC.TakeDamage = function(self, dmg, ...)\n"
        "          local s = rawget(_G, '__PM_S__')\n"
        "          if s and (s.god or (s.onehit and s.onehit > 0)) then\n"
        "            local isZ = false\n"
        "            if self.IsZombie then isZ = self.IsZombie(self) end\n"
        "            if not isZ and self.IsFieldNpc then isZ = self.IsFieldNpc(self) end\n"
        "            if s.god and not isZ then return end\n"
        "            if s.onehit and s.onehit > 0 and isZ then\n"
        "              if s.onehit == 1 then dmg = dmg * 1000\n"
        "              else dmg = 9e15 end\n"
        "            end\n"
        "          end\n"
        "          return oldTD(self, dmg, ...)\n"
        "        end\n"
        "      end\n"
        "      local oldLose = UC.LoseHP\n"
        "      if oldLose then\n"
        "        UC.LoseHP = function(self, hp, ...)\n"
        "          local s = rawget(_G, '__PM_S__')\n"
        "          if s and s.god then\n"
        "            local isZ = false\n"
        "            if self.IsZombie then isZ = self.IsZombie(self) end\n"
        "            if not isZ and self.IsFieldNpc then isZ = self.IsFieldNpc(self) end\n"
        "            if not isZ then return end\n"
        "          end\n"
        "          return oldLose(self, hp, ...)\n"
        "        end\n"
        "      end\n"
        "      local okw = pcall(io.open, '%s/Documents/pm_hooked', 'w')\n"
        "      if okw then local hf2 = io.open('%s/Documents/pm_hooked','w') hf2:write('1') hf2:close() end\n"
        "    end\n"
        "  end\n"
        "end\n"
        "rawset(_G, '__PM_F__', pmOnFrame)\n"
        "local ub = rawget(_G, 'UpdateBeat')\n"
        "if ub and ub.Add then\n"
        "  -- v3: pcall 包装——pmOnFrame 错误直接抛给 UpdateBeat 会 luaD_throw→abort\n"
        "  ub:Add(function()\n"
        "    local ok, err = pcall(pmOnFrame)\n"
        "    if not ok then rawset(_G, '__PM_ERR__', tostring(err)) end\n"
        "  end)\n"
        "end\n"
        "local regok = (ub and ub.Add) and true or false\n"
        "rawset(_G, '__PM_R__', regok)\n"
        "local sf = io.open('%s/Documents/pm.status','w')\n"
        "if sf then sf:write('reg='..(regok and 'OK' or 'FAIL')..'\\n') sf:close() end\n",
        home, home, home);
    if (n >= (int)sizeof(rs) - 8) { LOG("script too long: %d\n", n); return; }
    // 注册 C 函数（pushcclosure 一步）
    if (L_pushcclosure && L_setglobal) {
        int top = L_gettop(g_L);
        L_pushcclosure(g_L, (void*)pm_toggle_cfunc, 0);
        L_setglobal(g_L, "__PM_toggle");
        L_pushcclosure(g_L, (void*)pm_state_cfunc, 0);
        L_setglobal(g_L, "__PM_state__");
        L_settop(g_L, top);
        LOG("C funcs registered\n");
    }
    int rc = lua_dostring(rs);
    LOG("beat install rc=%d\n", rc);
    if (rc != 0) { g_beat_ok = 0; return; }

    // v5 关键修复：rc=0 ≠ 成功！
    // 脚本在 Lua 刚出现（启动后 ~2s）就跑，那时 UpdateBeat 全局还不存在，
    // "if ub and ub.Add" 静默跳过 → 无回调无自愈（v4 实测 pulls=0）。
    // 成功标准 = 脚本写回的 pm.status 里 reg=OK（真挂上了 UpdateBeat）
    const char* homeC2 = getenv("HOME");
    char spath[512];
    snprintf(spath, sizeof(spath), "%s/Documents/pm.status", homeC2 ? homeC2 : "/var/mobile");
    FILE* sf = fopen(spath, "r");
    if (sf) {
        char buf[64] = {0};
        size_t n = fread(buf, 1, sizeof(buf) - 1, sf);
        fclose(sf);
        buf[n] = 0;
        g_beat_ok = (strncmp(buf, "reg=OK", 6) == 0) ? 1 : 0;
    } else {
        g_beat_ok = 0;
    }
    LOG("beat verified=%d (status: %s)\n", (int)g_beat_ok,
        (sf || 1) ? (g_beat_ok ? "reg=OK" : "reg missing/FAIL") : "?");
}

// ── v2 引擎装载（全部主线程：dispatch_after 链式重试，零 worker 线程）──
// 34 个版本教训：任何非主线程的 Lua pcall 都与 60fps 主循环竞态崩。
// v1 的 worker 虽把 install 投递主线程，但 30s ping 的 lua_dostring("return 1")
// 仍在 worker 线程执行 → 启动约 30s 后闪退（用户实测"安装引擎闪退"根因）。
// v2：探测/安装/自愈全部主线程；ping 并入 UI 的 pm_refresh timer。

static void pm_engine_tick(void) {
    static int ticks = 0;
    ticks++;
    // 每 tick（0.5s）检查：引擎就绪了吗？
    if (!g_L || !g_beat_ok) {
        // 还没装好：探测（主线程安全）+ 安装（主线程安全）
        // v5：install 失败/未验证（UpdateBeat 未出现 → reg=FAIL）时每 4 tick 重试
        if (!g_uf) find_uf();
        if (g_uf) resolve_syms();
        if (g_uf && !g_L) try_get_lua();
        static int inst_ctr = 0;
        if (g_L && ++inst_ctr >= 4) {   // 每 2s 一次（幂等，重装无副作用）
            inst_ctr = 0;
            install_beat();
        }
        if (ticks % 40 == 0) LOG("probe t=%d uf=%s L=%s beat=%d\n", ticks, g_uf?"ok":"-", g_L?"ok":"-", (int)g_beat_ok);
    } else {
        // v5 看门狗：装上 90s 仍无帧回调（pulls=0，VM 真死了）→ 重装
        // （vm 死但 "return 1" 还能过的极端情况：UpdateBeat 已死/重建）
        static time_t installed_at = 0;
        static time_t last_pull = 0;
        if (installed_at == 0) installed_at = time(NULL);
        if (g_state_pulls > 0 && g_state_pulls != (int)last_pull) {
            last_pull = g_state_pulls;
            installed_at = time(NULL);
        }
        if (time(NULL) - installed_at > 90) {
            LOG("watchdog: pulls stale (%d) -> reinstall\n", (int)g_state_pulls);
            g_beat_ok = 0; installed_at = 0; last_pull = 0;
            install_beat();
        }
        // 已装好：每 60 tick（30s）ping 自愈（主线程 pcall = 与游戏串行 = 安全）
        static int ping_ctr = 0;
        if (++ping_ctr >= 60) {
            ping_ctr = 0;
            int pr = lua_dostring("return 1");
            if (pr != 0) {
                LOG("lua dead (rc=%d) -> re-attach\n", pr);
                g_L = NULL; g_beat_ok = 0;
                if (L_getstate) g_L = L_getstate();
                if (g_L) install_beat();
            }
        }
    }
    // hook 状态检查（文件存在性，安全）
    {
        static int chk = 0;
        if (++chk >= 4) {
            chk = 0;
            const char* home = getenv("HOME");
            char hp[512];
            snprintf(hp, sizeof(hp), "%s/Documents/pm_hooked", home ? home : "/var/mobile");
            struct stat st;
            g_hook_flag = (stat(hp, &st) == 0);
        }
    }
    if (ticks % 120 == 60) LOG("alive god=%d hit=%d spd=%d pulls=%d beat=%d hook=%d\n",
        (int)pm_god, (int)pm_hit, (int)pm_spd, (int)g_state_pulls, (int)g_beat_ok, (int)g_hook_flag);
}


// ════════════════════════════════════════════════════════════════════════
// Part 2  FloatGlass UI（玻璃按钮 + 玻璃面板，面板内嵌功能开关）
// ════════════════════════════════════════════════════════════════════════

@interface FloatGlassPanel : UIView
- (void)fg_close;
@end
static UIWindow *fg_keyWindow(void);
static FloatGlassPanel *g_panel = nil;

#pragma mark - 运行时黑名单（银行 / 带检测的 App 不显示）

static BOOL fg_shouldSkip(NSString *bid) {
    static NSArray<NSString *> *blacklist = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        blacklist = @[
            @"com.icbc.iphone",          // 工行
            @"com.ccb.iphone",           // 建行
            @"com.boc.bocmobilebank",    // 中行
            @"com.cmbchina.ccd",         // 招行
            @"com.abchina.mobilebank",   // 农行
            @"com.spdb.pmobile",         // 浦发
            @"com.citicbank.mobilebank", // 中信
            @"com.cmbc.pocketbank",      // 民生
            @"com.cgbchina.mobilebank",  // 广发
            @"com.bankcomm.mobilebank",  // 交行
            @"com.alipay.iphoneclient",  // 支付宝
            @"com.unionpay.iphone",      // 银联
        ];
    });
    for (NSString *b in blacklist) {
        if ([bid isEqualToString:b]) return YES;
    }
    return NO;
}

#pragma mark - 状态渲染（C 状态 → 面板控件）

static NSString *pm_godText(void)    { return pm_god ? @"无敌 · 开" : @"无敌 · 关"; }
static NSString *pm_hitText(void)    { return pm_hit == 2 ? @"秒杀 · 暴力" : (pm_hit == 1 ? @"秒杀 · 温和" : @"秒杀 · 关"); }
static NSString *pm_spdText(void)    { return pm_spd ? @"加速 · 3x" : @"加速 · 关"; }
static NSString *pm_engineText(void) {
    if (!g_uf)  return @"引擎 · 等待游戏加载";
    if (!g_L)   return @"引擎 · Lua 连接中";
    if (!g_beat_ok) return @"引擎 · 安装中";
    if (!g_hook_flag) return @"引擎 · 就绪(进对局生效)";
    return @"引擎 · 战斗Hook已就绪";
}

@interface FloatGlassButton : UIControl
@property (nonatomic, strong) UIView *glassView;
@end

@implementation FloatGlassButton

- (instancetype)initWithSize:(CGFloat)size {
    if (self = [super initWithFrame:CGRectMake(0, 0, size, size)]) {
        self.backgroundColor = [UIColor clearColor];

        // 外层阴影（不能 clipsToBounds，否则阴影被裁掉）
        self.layer.shadowColor   = [UIColor blackColor].CGColor;
        self.layer.shadowOpacity = 0.40;
        self.layer.shadowRadius  = 14;
        self.layer.shadowOffset  = CGSizeMake(0, 5);

        // 内层玻璃体（圆形 + 裁剪）
        _glassView = [[UIView alloc] initWithFrame:self.bounds];
        _glassView.layer.cornerRadius = size / 2.0;
        _glassView.clipsToBounds = YES;
        _glassView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.14];
        _glassView.userInteractionEnabled = NO;
        [self addSubview:_glassView];

        // 毛玻璃
        UIBlurEffect *blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterialLight];
        UIVisualEffectView *bv = [[UIVisualEffectView alloc] initWithEffect:blur];
        bv.frame = _glassView.bounds;
        bv.userInteractionEnabled = NO;
        [_glassView addSubview:bv];

        // 液态高光：顶部柔光呼吸
        CAGradientLayer *sheen = [CAGradientLayer layer];
        sheen.frame = _glassView.bounds;
        sheen.colors = @[(__bridge id)[UIColor colorWithWhite:1.0 alpha:0.60].CGColor,
                         (__bridge id)[UIColor colorWithWhite:1.0 alpha:0.0].CGColor];
        sheen.startPoint = CGPointMake(0.5, 0.0);
        sheen.endPoint   = CGPointMake(0.5, 0.65);
        [_glassView.layer addSublayer:sheen];

        CABasicAnimation *breathe = [CABasicAnimation animationWithKeyPath:@"opacity"];
        breathe.fromValue = @0.6;
        breathe.toValue   = @0.95;
        breathe.duration  = 2.6;
        breathe.autoreverses = YES;
        breathe.repeatCount = HUGE_VALF;
        [sheen addAnimation:breathe forKey:@"fg_breathe"];

        // 边缘高光
        CGFloat px = 1.0 / [UIScreen mainScreen].scale;
        _glassView.layer.borderWidth = px;
        _glassView.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.55].CGColor;

        // 手势：拖动 + 点按（点按需等拖动失败才触发）
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(fg_pan:)];
        [self addGestureRecognizer:pan];
        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(fg_tap:)];
        [tap requireGestureRecognizerToFail:pan];
        [self addGestureRecognizer:tap];
    }
    return self;
}

#pragma mark 拖动

- (void)fg_pan:(UIPanGestureRecognizer *)g {
    UIView *sv = self.superview;
    if (!sv) return;

    if (g.state == UIGestureRecognizerStateChanged) {
        CGPoint t = [g translationInView:sv];
        CGPoint c = self.center;
        c.x += t.x;
        c.y += t.y;
        CGFloat halfW = self.frame.size.width  / 2.0;
        CGFloat halfH = self.frame.size.height / 2.0;
        c.x = MAX(halfW, MIN(c.x, sv.bounds.size.width  - halfW));
        c.y = MAX(halfH, MIN(c.y, sv.bounds.size.height - halfH));
        self.center = c;
        [g setTranslation:CGPointZero inView:sv];
    } else if (g.state == UIGestureRecognizerStateEnded) {
        // 吸附到最近的左右边缘
        CGFloat W = sv.bounds.size.width;
        CGPoint c = self.center;
        CGFloat margin = self.frame.size.width / 2.0 + 8.0;
        c.x = (c.x < W / 2.0) ? margin : (W - margin);
        [UIView animateWithDuration:0.25 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
            self.center = c;
        } completion:nil];
    }
}

#pragma mark 点按 → 呼出 / 收起面板

- (void)fg_tap:(UITapGestureRecognizer *)g {
    (void)g;
    [self fg_togglePanel];
}

- (void)fg_togglePanel {
    if (g_panel) { [self fg_closePanel]; return; }
    UIWindow *kw = fg_keyWindow();
    if (!kw) return;
    CGFloat pw = 280, ph = 360;
    FloatGlassPanel *p = [[FloatGlassPanel alloc] initWithFrame:
        CGRectMake((kw.bounds.size.width  - pw) / 2.0,
                   (kw.bounds.size.height - ph) / 2.0, pw, ph)];
    g_panel = p;
    [kw addSubview:p];
    [kw bringSubviewToFront:p];
}

- (void)fg_closePanel {
    if (g_panel) { [g_panel removeFromSuperview]; g_panel = nil; }
}

@end

#pragma mark - 功能面板（玻璃小卡片：三个开关 + 引擎状态 + 关闭）

@implementation FloatGlassPanel {
    UIButton *_godBtn;
    UIButton *_hitBtn;
    UIButton *_spdBtn;
    UILabel  *_engLabel;
    NSTimer  *_refreshTimer;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (self = [super initWithFrame:frame]) {
        // 玻璃质感（与按钮一致）
        self.layer.shadowColor   = [UIColor blackColor].CGColor;
        self.layer.shadowOpacity = 0.42;
        self.layer.shadowRadius  = 22;
        self.layer.shadowOffset  = CGSizeMake(0, 8);
        self.layer.cornerRadius  = 26;
        self.clipsToBounds       = YES;
        self.backgroundColor     = [UIColor colorWithWhite:1.0 alpha:0.14];

        // 毛玻璃底
        UIBlurEffect *blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterialLight];
        UIVisualEffectView *bv = [[UIVisualEffectView alloc] initWithEffect:blur];
        bv.frame = self.bounds;
        bv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        bv.userInteractionEnabled = NO;
        [self addSubview:bv];

        // 顶部柔光
        CAGradientLayer *sheen = [CAGradientLayer layer];
        sheen.frame = self.bounds;
        sheen.colors = @[(__bridge id)[UIColor colorWithWhite:1.0 alpha:0.55].CGColor,
                         (__bridge id)[UIColor colorWithWhite:1.0 alpha:0.0].CGColor];
        sheen.startPoint = CGPointMake(0.5, 0.0);
        sheen.endPoint   = CGPointMake(0.5, 0.60);
        [self.layer addSublayer:sheen];

        CGFloat px = 1.0 / [UIScreen mainScreen].scale;
        self.layer.borderWidth = px;
        self.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.5].CGColor;

        // 标题
        UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(0, 16, CGRectGetWidth(self.bounds), 24)];
        title.text = @"塔塔功能面板";
        title.textAlignment = NSTextAlignmentCenter;
        title.textColor = [UIColor whiteColor];
        title.font = [UIFont boldSystemFontOfSize:17];
        title.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        [self addSubview:title];

        // ── 三个功能开关（状态即时反映在标题上）──
        _godBtn = [self pm_mkSwitch:CGRectMake(16, 56, 248, 46) title:pm_godText() action:@selector(pm_godTap:)];
        _hitBtn = [self pm_mkSwitch:CGRectMake(16, 110, 248, 46) title:pm_hitText() action:@selector(pm_hitTap:)];
        _spdBtn = [self pm_mkSwitch:CGRectMake(16, 164, 248, 46) title:pm_spdText() action:@selector(pm_spdTap:)];

        // 引擎状态行
        _engLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 222, 248, 34)];
        _engLabel.text = pm_engineText();
        _engLabel.textAlignment = NSTextAlignmentCenter;
        _engLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.85];
        _engLabel.font = [UIFont systemFontOfSize:12];
        _engLabel.numberOfLines = 2;
        _engLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        [self addSubview:_engLabel];

        // 关闭按钮
        UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
        [close setTitle:@"关闭" forState:UIControlStateNormal];
        close.tintColor = [UIColor whiteColor];
        close.frame = CGRectMake(CGRectGetWidth(self.bounds) - 72, 12, 60, 32);
        close.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleBottomMargin;
        [close addTarget:self action:@selector(fg_close) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:close];

        // 拖动：可全屏任意移动
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(fg_drag:)];
        [self addGestureRecognizer:pan];

        // 状态自刷新（0.5s；UI 线程安全；VM 自愈后自动追上）
        _refreshTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 target:self
                                                       selector:@selector(pm_refresh) userInfo:nil repeats:YES];
        [[NSRunLoop mainRunLoop] addTimer:_refreshTimer forMode:NSDefaultRunLoopMode];
    }
    return self;
}

// 玻璃风格开关按钮
- (UIButton *)pm_mkSwitch:(CGRect)frame title:(NSString *)t action:(SEL)a {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.frame = frame;
    b.layer.cornerRadius = 14;
    b.layer.borderWidth  = 1.0 / [UIScreen mainScreen].scale;
    b.layer.borderColor  = [UIColor colorWithWhite:1.0 alpha:0.35].CGColor;
    b.backgroundColor    = [UIColor colorWithWhite:1.0 alpha:0.16];
    b.tintColor = [UIColor whiteColor];
    b.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    [b setTitle:t forState:UIControlStateNormal];
    [b addTarget:self action:a forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:b];
    return b;
}

#pragma mark 开关回调（主线程 → 直改 C 全局 → UpdateBeat 每帧拉取，零竞态）

- (void)pm_godTap:(id)sender {
    (void)sender;
    pm_god = !pm_god;
    [_godBtn setTitle:pm_godText() forState:UIControlStateNormal];
    LOG("ui: god=%d\n", (int)pm_god);
}

- (void)pm_hitTap:(id)sender {
    (void)sender;
    pm_hit = (pm_hit + 1) % 3;   // 关 → 温和(×1000) → 暴力(9e15) → 关
    [_hitBtn setTitle:pm_hitText() forState:UIControlStateNormal];
    LOG("ui: onehit=%d\n", (int)pm_hit);
}

- (void)pm_spdTap:(id)sender {
    (void)sender;
    pm_spd = !pm_spd;
    [_spdBtn setTitle:pm_spdText() forState:UIControlStateNormal];
    LOG("ui: speed=%d\n", (int)pm_spd);
}

- (void)pm_refresh {
    pm_engine_tick();   // v2：UI timer 顺带驱动引擎（主线程，含 30s ping 自愈）
    _engLabel.text = pm_engineText();
    [_godBtn setTitle:pm_godText() forState:UIControlStateNormal];
    [_hitBtn setTitle:pm_hitText() forState:UIControlStateNormal];
    [_spdBtn setTitle:pm_spdText() forState:UIControlStateNormal];
}

- (void)fg_close {
    [_refreshTimer invalidate];
    _refreshTimer = nil;
    [self removeFromSuperview];
    if (g_panel == self) g_panel = nil;
}

- (void)fg_drag:(UIPanGestureRecognizer *)g {
    UIView *sv = self.superview;
    if (!sv) return;
    if (g.state == UIGestureRecognizerStateChanged) {
        CGPoint t = [g translationInView:sv];
        CGPoint c = self.center;
        c.x += t.x;
        c.y += t.y;
        CGFloat hw = self.frame.size.width  / 2.0;
        CGFloat hh = self.frame.size.height / 2.0;
        c.x = MAX(hw, MIN(c.x, sv.bounds.size.width  - hw));
        c.y = MAX(hh, MIN(c.y, sv.bounds.size.height - hh));
        self.center = c;
        [g setTranslation:CGPointZero inView:sv];
    }
}

@end

#pragma mark - 工具（FloatGlass 原版）

static UIWindow *fg_keyWindow() {
    UIApplication *app = UIApplication.sharedApplication;
    if (!app) return nil;
    for (UIScene *s in app.connectedScenes) {
        if ([s isKindOfClass:[UIWindowScene class]] &&
            ((UIWindowScene *)s).activationState == UISceneActivationStateForegroundActive) {
            UIWindowScene *ws = (UIWindowScene *)s;
            for (UIWindow *w in ws.windows) if (w.isKeyWindow) return w;
            for (UIWindow *w in ws.windows) if (w.rootViewController) return w;
            if (ws.windows.count) return ws.windows.firstObject;
        }
    }
    for (UIWindow *w in app.windows) if (w.isKeyWindow) return w;
    return app.keyWindow;
}

static void fg_toast(NSString *msg) {
    UIWindow *kw = fg_keyWindow();
    if (!kw) return;
    UILabel *lab = [[UILabel alloc] init];
    lab.text = msg;
    lab.textColor = [UIColor whiteColor];
    lab.font = [UIFont systemFontOfSize:13];
    lab.textAlignment = NSTextAlignmentCenter;
    lab.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.72];
    lab.layer.cornerRadius = 10;
    lab.clipsToBounds = YES;
    lab.numberOfLines = 0;
    [lab sizeToFit];
    CGFloat w = MIN(lab.frame.size.width + 28, kw.bounds.size.width - 40);
    CGFloat h = lab.frame.size.height + 16;
    lab.frame = CGRectMake((kw.bounds.size.width - w) / 2.0,
                           kw.bounds.size.height - 110, w, h);
    lab.autoresizingMask = UIViewAutoresizingFlexibleTopMargin
                         | UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
    [kw addSubview:lab];
    [kw bringSubviewToFront:lab];
    [UIView animateWithDuration:0.35 delay:2.0 options:0
                     animations:^{ lab.alpha = 0; }
                     completion:^(BOOL f) { [lab removeFromSuperview]; }];
}

static FloatGlassButton *g_floatBtn = nil;
static int g_ensureTries = 0;

static void fg_ensureButton() {
    if (!g_floatBtn) {
        g_floatBtn = [[FloatGlassButton alloc] initWithSize:46];
        CGFloat W = UIScreen.mainScreen.bounds.size.width;
        CGFloat H = UIScreen.mainScreen.bounds.size.height;
        g_floatBtn.center = CGPointMake(W - 32, H / 2.0);
    }
    UIWindow *kw = fg_keyWindow();
    if (kw) {
        if (g_floatBtn.superview != kw) [kw addSubview:g_floatBtn];
        [kw bringSubviewToFront:g_floatBtn];
    } else if (g_ensureTries < 12) {
        g_ensureTries++;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ fg_ensureButton(); });
    }
}

#pragma mark - 入口

__attribute__((constructor)) static void fg_ctor() {
    @autoreleasepool {
        const char* homeC = getenv("HOME");
        char lp[512];
        snprintf(lp, sizeof(lp), "%s/Documents/pmglass.log", homeC ? homeC : "/var/mobile");
        g_log = fopen(lp, "w");
        LOG("PMGlass v5 pid=%d\n", getpid());

        NSString *bid = NSBundle.mainBundle.bundleIdentifier;
        if (!bid) { LOG("no bundle id\n"); return; }
        if (fg_shouldSkip(bid)) {
            LOG("skip blacklist app: %s\n", bid.UTF8String);
            return;
        }
        LOG("loaded in %s\n", bid.UTF8String);

        // v3：常驻主队列 timer（0.5s）驱动引擎探测/安装/30s 自愈——
        // v2 只在面板打开时才驱动（NSTimer 挂 panel），面板关着引擎就停摆；
        // Lua VM 通常在启动后几秒才出现，一次性 dispatch_after 探不到。
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            static dispatch_source_t t = nil;
            if (t) return;
            t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
            if (!t) { LOG("engine timer fail\n"); return; }
            dispatch_source_set_timer(t, DISPATCH_TIME_NOW,
                                      (uint64_t)(0.5 * NSEC_PER_SEC), (uint64_t)(0.1 * NSEC_PER_SEC));
            dispatch_source_set_event_handler(t, ^{ pm_engine_tick(); });
            dispatch_resume(t);
            LOG("engine timer on\n");
        });

        // App 启动后再挂 UI（构造函数早于 UIApplicationMain，需延迟）
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            fg_toast(@"PMGlass 已加载");
            fg_ensureButton();
            [NSNotificationCenter.defaultCenter
                addObserverForName:UIApplicationDidBecomeActiveNotification
                            object:nil
                             queue:NSOperationQueue.mainQueue
                        usingBlock:^(NSNotification * _Nonnull n) {
                            (void)n;
                            if (g_floatBtn.superview) [g_floatBtn.superview bringSubviewToFront:g_floatBtn];
                            else fg_ensureButton();
                        }];
        });
    }
}
