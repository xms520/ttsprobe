//
//  PMGlass v6 —— 塔塔冒险队 功能版悬浮窗（v45 实测成功配方 + FloatGlass UI）
//  ────────────────────────────────────────────────────────────────────────
//  引擎 = PMLib v45 原版逐字保留（实测秒杀生效那版）：
//    pthread worker 探测 → CFRunLoopPerformBlock 投递主线程 install
//    → UpdateBeat 每帧回调 → hook ed.UnitComponent.TakeDamage/LoseHP
//    + BattleEngine.GetTimeScale → pm.flags 文件通道 → 30s ping 自愈
//  UI = FloatGlass 玻璃按钮/面板；开关按钮写 pm.flags（≤2s 生效）
//  注入：TrollFools / TrollStore 注入到 IGame-Mainland
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
#include <mach/mach.h>
#include <pthread.h>

typedef struct lua_State lua_State;
static lua_State* (*L_getstate)(void);
static lua_State* (*L_toluamain)(void);
static int (*L_loadstring)(lua_State*, const char*);
static int (*L_pcall)(lua_State*, int, int, int);
static int (*L_gettop)(lua_State*);
static int (*L_settop)(lua_State*, int);
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

static volatile int f_godmode = 0, f_onehit = 0, f_speed = 0, f_dump = 0;
static volatile int f_probe = 0;
static int g_dump_done = 0, g_probe_done = 0;  // 一次性动作防重入
static FILE* g_log = NULL;
#define LOG(...) do { if (g_log) { fprintf(g_log, __VA_ARGS__); fflush(g_log); } } while(0)

extern uint32_t _dyld_image_count(void);
extern const char* _dyld_get_image_name(uint32_t image_index);

// v3: 逐镜像 dlsym 扫描（TataDiag v4 已验证成功的方案）
// 注：镜像名后缀匹配不可靠（v2 因此失败），直接探测哪个镜像含 igame_getLuaState
static void find_uf(void) {
    if (g_uf) return;
    uint32_t n = _dyld_image_count();
    static int scanned = 0;
    int idx = 0;
    for (uint32_t i = 0; i < n; i++) {
        const char* nm = _dyld_get_image_name(i);
        if (!nm) continue;
        // 跳过系统库（igame/lua 不在系统路径），大幅减少 dlopen 次数
        if (strncmp(nm, "/usr/lib", 8) == 0 || strncmp(nm, "/System/", 8) == 0 ||
            strncmp(nm, "/Developer/", 11) == 0) continue;
        void* h = dlopen(nm, RTLD_LAZY | RTLD_NOLOAD);
        if (!h) continue;
        if (dlsym(h, "igame_getLuaState") || dlsym(h, "luaL_loadstring")) {
            g_uf = h;
            LOG("UF found at scan#%d (%s)\n", idx, nm);
            return;
        }
        idx++;
    }
    scanned++;
    if (scanned == 1) LOG("first scan done, %d non-system imgs, no UF yet\n", idx);
}

static void resolve_syms(void) {
    if (!g_uf) return;
    if (!L_getstate) {
    L_getstate  = (void*)dlsym(g_uf, "igame_getLuaState");
    L_toluamain = (void*)dlsym(g_uf, "tolua_getmainstate");
    L_loadstring= (void*)dlsym(g_uf, "luaL_loadstring");
    L_pcall     = (void*)dlsym(g_uf, "lua_pcall");
    L_gettop    = (void*)dlsym(g_uf, "lua_gettop");
    L_settop    = (void*)dlsym(g_uf, "lua_settop");
    L_tolstring = (void*)dlsym(g_uf, "lua_tolstring");
    I_domain_get      = (void*)dlsym(g_uf, "il2cpp_domain_get");
    I_domain_assemblies = (void*)dlsym(g_uf, "il2cpp_domain_get_assemblies");
    I_asm_get_image   = (void*)dlsym(g_uf, "il2cpp_assembly_get_image");
    I_image_get_name  = (void*)dlsym(g_uf, "il2cpp_image_get_name");
    I_class_from_name = (void*)dlsym(g_uf, "il2cpp_class_from_name");
    I_class_field     = (void*)dlsym(g_uf, "il2cpp_class_get_field_from_name");
    I_field_static_get= (void*)dlsym(g_uf, "il2cpp_field_static_get_value");
    I_thread_attach   = (void*)dlsym(g_uf, "il2cpp_thread_attach");
    }
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

static void sync_cfg(void) {
    // v11 前：开关仅记录状态（Lua 侧 hook 等全局表分析后再接）
    LOG("cfg sync: god=%d onehit=%d speed=%d (lua hooks pending v11)\n",
        f_godmode, f_onehit, f_speed?3:1);
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
    if (I_domain_get && I_domain_assemblies && I_asm_get_image && I_image_get_name &&
        I_class_from_name && I_class_field && I_field_static_get && L_loadstring && L_pcall) {
        Il2CppDomain* dom = I_domain_get();
        if (!dom) return;
        size_t n = 0;
        Il2CppAssembly** asms = I_domain_assemblies(dom, &n);
        for (size_t i = 0; i < n; i++) {
            const Il2CppImage* img = I_asm_get_image(asms[i]);
            if (!img) continue;
            const char* nm = I_image_get_name(img);
            if (!nm || strcmp(nm, "Assembly-CSharp.dll") != 0) continue;
            Il2CppClass* k = I_class_from_name(img, "LuaInterface", "LuaState");
            if (!k) break;
            FieldInfo* f = I_class_field(k, "mainState");
            if (!f) break;
            if (I_thread_attach) I_thread_attach(dom);
            void* val = NULL;
            I_field_static_get(f, &val);
            LOG("mainState field val=%p\n", val);
            if (val) {
                // val = LuaState 对象指针；LuaStatePtr 子布局 L @ obj+16
                lua_State* cand = *(lua_State**)((char*)val + 16);
                LOG("candidate L at +16 = %p\n", (void*)cand);
                if (cand) {
                    int top = L_gettop(cand);
                    if (L_loadstring(cand, "return 1") == 0 && L_pcall(cand, 0, 1, 0) == 0) {
                        g_L = cand; LOG("lua via il2cpp mainState=%p VERIFIED\n", cand);
                        L_settop(cand, top);
                        return;
                    }
                    if (L_settop) L_settop(cand, top);
                }
            }
            break;
        }
    }
}

// ---------------- v10: 无 UI 版 ----------------
// 开关方式：Documents/pm.flags 文件（每行一个 key=value，worker 每0.5s读取）
// 支持 key: god=1/0, onehit=1/0, speed=3/1, dump=1(一次性)
static void read_flags(void) {
    const char* home = getenv("HOME");
    char path[512];
    snprintf(path, sizeof(path), "%s/Documents/pm.flags", home ? home : "/var/mobile");
    FILE* f = fopen(path, "r");
    if (!f) return;
    char line[128];
    int newgod = f_godmode, newhit = f_onehit, newspd = f_speed, newdump = 0, newprobe = 0;
    while (fgets(line, sizeof(line), f)) {
        if (strncmp(line, "god=1", 5) == 0) newgod = 1;
        else if (strncmp(line, "god=0", 5) == 0) newgod = 0;
        else if (strncmp(line, "onehit=1", 8) == 0) newhit = 1;
        else if (strncmp(line, "onehit=0", 8) == 0) newhit = 0;
        else if (strncmp(line, "speed=3", 7) == 0) newspd = 1;
        else if (strncmp(line, "speed=1", 7) == 0) newspd = 0;
        else if (strncmp(line, "dump=1", 6) == 0) newdump = 1;
        else if (strncmp(line, "probe=1", 7) == 0) newprobe = 1;
    }
    fclose(f);
    if (newgod != f_godmode) { f_godmode = newgod; LOG("flag: god=%d\n", newgod); sync_cfg(); }
    if (newhit != f_onehit) { f_onehit = newhit; LOG("flag: onehit=%d\n", newhit); sync_cfg(); }
    if (newspd != f_speed)  { f_speed = newspd; LOG("flag: speed=%d\n", newspd); sync_cfg(); }
    if (newprobe && !g_probe_done) {
        g_probe_done = 1;
        f_probe = 1;
        LOG("flag: probe requested\n");
        char wpath2[512];
        snprintf(wpath2, sizeof(wpath2), "%s/Documents/pm.flags", home ? home : "/var/mobile");
        FILE* wf2 = fopen(wpath2, "w");
        if (wf2) { fprintf(wf2, "probe=0\n"); fclose(wf2); LOG("flags rewritten (probe=0)\n"); }
    }
    if (newdump && !g_dump_done) {
        g_dump_done = 1;
        f_dump = 1;
        LOG("flag: dump requested\n");
        // 自动把 flags 文件里的 dump=1 清掉，防止每次轮询重复触发（闪退根因）
        char wpath[512];
        snprintf(wpath, sizeof(wpath), "%s/Documents/pm.flags", home ? home : "/var/mobile");
        FILE* wf = fopen(wpath, "w");
        if (wf) {
            fprintf(wf, "dump=0\n");
            fclose(wf);
            LOG("flags rewritten (dump=0)\n");
        }
    }
}

// ---------------- runloop 桥（v45 实测配方）----------------
typedef void* CFLoopRef;
static CFLoopRef (*p_CFRunLoopGet0)(void*);
static void (*p_CFRunLoopPerformBlock)(CFLoopRef, const void*, void (^)(void));
static void (*p_CFRunLoopWakeUp)(CFLoopRef);
static const void* p_CommonModes;
static CFLoopRef g_main_runloop = NULL;

static mach_port_t g_main_thread_port = MACH_PORT_NULL;
static void* g_main_pthread = NULL;
static int find_named_main_thread(void) {
    mach_port_t *threads = NULL;
    mach_msg_type_number_t count = 0;
    kern_return_t kr = task_threads(mach_task_self(), &threads, &count);
    if (kr != 0 || !threads) {
        LOG("rl task_threads kr=%d count=%u\n", kr, count);
        return 0;
    }

    // v37: pthread_from_mach_thread_np + pthread_getname_np 读线程名
    int found = 0;
    // v39: 第一次找不到 MainThread 时，dump 全部线程名（诊断主线程真名）
    int dumped = 0;
    for (mach_msg_type_number_t i=0; i<count; i++) {
        void* pt = pthread_from_mach_thread_np(threads[i]);
        if (!pt) continue;
        char tname[64] = {0};
        pthread_getname_np(pt, tname, sizeof(tname));
        if (strcmp(tname, "MainThread") == 0) {
            g_main_thread_port = threads[i];
            g_main_pthread = pt;
            found = 1;
            LOG("rl MainThread port=%u name=%s\n", (unsigned)threads[i], tname);
            break;
        }
        // v39: 线程名 dump（每个线程名只记一次，最多 20 个）
        if (!dumped && tname[0] && i < 20) {
            LOG("rl thread[%u] name=%s\n", (unsigned)i, tname);
        }
    }
    // v39: 名字全空 → 主线程兜底 = task_threads 返回的第一个线程（Darwin 惯例）
    if (!found && count > 0) {
        void* pt = pthread_from_mach_thread_np(threads[0]);
        if (pt) {
            g_main_thread_port = threads[0];
            g_main_pthread = pt;
            found = 1;
            LOG("rl fallback first-thread as main (total=%u)\n", (unsigned)count);
        }
    }

    for (mach_msg_type_number_t i=0; i<count; i++) {
        if (!found || threads[i] != g_main_thread_port)
            mach_port_deallocate(mach_task_self(), threads[i]);
    }
    vm_deallocate(mach_task_self(), (vm_address_t)threads,
                  (vm_size_t)(count * sizeof(mach_port_t)));

    return found;
}

static int init_runloop_bridge(void) {
    if (p_CFRunLoopGet0 && p_CFRunLoopPerformBlock && p_CommonModes) return 1;

    void* cf = dlopen("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation", RTLD_LAZY);
    if (!cf) {
        LOG("rl-nocf\n");
        return 0;
    }

    p_CFRunLoopGet0 = (void*)dlsym(cf, "_CFRunLoopGet0");
    if (!p_CFRunLoopGet0)
        p_CFRunLoopGet0 = (void*)dlsym(cf, "CFRunLoopGet0");

    p_CFRunLoopPerformBlock = (void*)dlsym(cf, "CFRunLoopPerformBlock");
    if (!p_CFRunLoopPerformBlock)
        p_CFRunLoopPerformBlock = (void*)dlsym(cf, "_CFRunLoopPerformBlock");

    p_CFRunLoopWakeUp = (void*)dlsym(cf, "CFRunLoopWakeUp");
    if (!p_CFRunLoopWakeUp)
        p_CFRunLoopWakeUp = (void*)dlsym(cf, "_CFRunLoopWakeUp");

    const void** pcm = (const void**)dlsym(cf, "kCFRunLoopCommonModes");
    if (!pcm) pcm = (const void**)dlsym(cf, "_kCFRunLoopCommonModes");
    p_CommonModes = pcm ? *pcm : NULL;

    LOG("rl-syms g0=%p pb=%p wu=%p cm=%p\n",
        (void*)p_CFRunLoopGet0, (void*)p_CFRunLoopPerformBlock,
        (void*)p_CFRunLoopWakeUp, (void*)p_CommonModes);

    return p_CFRunLoopGet0 && p_CFRunLoopPerformBlock && p_CommonModes;
}

static int ensure_main_runloop(void) {
    if (!init_runloop_bridge()) return 0;
    if (g_main_runloop) return 1;

    if (!g_main_thread_port) {
        if (!find_named_main_thread()) {
            LOG("rl no MainThread yet\n");
            return 0;
        }
    }

    // v37: 直接用 find_named_main_thread 存好的 pthread（已验证名字="MainThread"）
    if (!g_main_pthread) return 0;
    g_main_runloop = p_CFRunLoopGet0(g_main_pthread);
    if (!g_main_runloop) {
        LOG("rl get0(main pthread) returned NULL\n");
        return 0;
    }

    LOG("main runloop=%p\n", (void*)g_main_runloop);
    return 1;
}

static int g_beat_ok = 0;   // v34: install 成功标志（失败则 30s 后重试）

// v38: 把一段 C 回调投递到游戏主线程 runloop 执行（光遇 ExecuteLuaAsync 同款）
// block 捕获：用 C 全局变量中转（block 捕获局部变量在 -fno-objc-arc 下复杂）
static char g_pending_job = 0;  // 0=无 1=verify+install 2=reinstall
static void install_beat(void);
static void run_pending_on_main(void) {
    if (g_pending_job == 0) return;
    int job = g_pending_job; g_pending_job = 0;
    if (!g_L) return;
    if (job == 1) {
        int r = lua_dostring("local x = 1 return x");
        LOG("channel verify rc=%d (0=OK) [main]\n", r);
        if (r != 0) return;
    }
    install_beat();
}
static void post_to_main(void (*unused)(void)) {
    (void)unused;
    if (!ensure_main_runloop()) { LOG("pm-post: no main runloop yet\n"); g_pending_job = 0; return; }
    p_CFRunLoopPerformBlock(g_main_runloop, p_CommonModes, ^{
        LOG("pm-block-enter\n");
        run_pending_on_main();
    });
    if (p_CFRunLoopWakeUp) p_CFRunLoopWakeUp(g_main_runloop);
    LOG("pm-posted\n");
}

static void install_beat_via_runloop(void) {
    g_pending_job = 1;
    post_to_main(NULL);
}

static void install_beat(void) {
    if (!g_L) return;
    const char* homeX = getenv("HOME");
    char rs[4096];
    snprintf(rs, sizeof(rs),
        // 主回调：状态轮询 + hook 安装，全部游戏主线程执行
        "rawset(_G, '__PM_S__', {god=false, onehit=false, speed=1})\n"
        "local home = '%s'\n"
        "local st = rawget(_G, '__PM_S__')\n"
        "local frame = 0\n"
        "local function tataOnFrame()\n"
        "  frame = frame + 1\n"
        "  -- 每30帧读一次开关文件\n"
        "  if frame %% 30 == 0 then\n"
        "    local ok, ff = pcall(io.open, home..'/Documents/pm.flags', 'r')\n"
        "    if ok and ff then\n"
        "      for line in ff:lines() do\n"
        "        if line:find('god=1', 1, true) then st.god = true\n"
        "        elseif line:find('god=0', 1, true) then st.god = false\n"
        "        elseif line:find('onehit=2', 1, true) then st.onehit = 2\n"
        "        elseif line:find('onehit=1', 1, true) then st.onehit = 1\n"
        "        elseif line:find('onehit=0', 1, true) then st.onehit = false\n"
        "        elseif line:find('speed=3', 1, true) then st.speed = 3\n"
        "        elseif line:find('speed=1', 1, true) then st.speed = 1\n"
        "        end\n"
        "      end\n"
        "      ff:close()\n"
        "    end\n"
        "  end\n"
        "  -- hook 安装（ed.UnitComponent 就绪时，一次）\n"
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
        "          if s and (s.god or s.onehit) then\n"
        "            local isZ = false\n"
        "            if self.IsZombie then isZ = self.IsZombie(self) end\n"
        "            if not isZ and self.IsFieldNpc then isZ = self.IsFieldNpc(self) end\n"
        "            if s.god and not isZ then return end\n"
        "            if s.onehit and isZ then\n"
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
        "      local okw = pcall(io.open, home..'/Documents/pm_hooked', 'w')\n"
        "      if okw then local hf2 = io.open(home..'/Documents/pm_hooked','w') hf2:write('1') hf2:close() end\n"
        "    end\n"
        "  end\n"
        "end\n"
        "rawset(_G, '__PM_F__', tataOnFrame)\n"
        "-- 挂进游戏每帧调度（UpdateBeat 是 tolua 全局表）\n"
        "local ub = rawget(_G, 'UpdateBeat')\n"
        "if ub and ub.Add then ub:Add(tataOnFrame) end\n"
        "local regok = (ub and ub.Add) and true or false\n"
        "rawset(_G, '__PM_R__', regok)\n"
        "local sf = io.open(home..'/Documents/pm.status','w')\n"
        "if sf then sf:write('reg='..(regok and 'OK' or 'FAIL')..'\\n') sf:close() end\n", homeX ? homeX : "/var/mobile");
    int rc = lua_dostring(rs);
    LOG("beat install rc=%d\n", rc);
    g_beat_ok = (rc == 0);
}

static void* worker(void* a) {
    (void)a;
    int hb = 0;
    for (int i = 0; i < 1440; i++) {
        if (!g_uf) find_uf();
        if (g_uf) resolve_syms();
        if (g_uf && !g_L && i > 4) try_get_lua();

        if (g_L && i > 60) break;  // Lua 就绪后停止观测（无 UI 版）

        if (i % 10 == 0) {
            LOG("hb%d imgs=%u uf=%p L=%p\n", hb++, _dyld_image_count(), g_uf, g_L);
        }
        usleep(500000);
    }

    if (g_L) {
        LOG("Lua VM=%p installing (via main runloop)...\n", g_L);
        // v38: verify + install 全部投递到主线程（worker 线程 pcall 长脚本与 60fps 主循环竞态 = v30/v37/v28 闪退根因）
        install_beat_via_runloop();
    } else {
        LOG("NO LUA after 12min\n");
    }

    int tick = 0;

    // UI 触发：pm_hooked 出现（进对局、战斗 hook 装好、游戏稳定运行）后建悬浮窗
    // 先删旧文件：防止上次运行残留导致 UI 在登录页就建（场景切换会吞掉面板）
    {
        const char* pd = getenv("HOME");
        char oldh[512];
        snprintf(oldh, sizeof(oldh), "%s/Documents/pm_hooked", pd?pd:"/var/mobile");
        remove(oldh);
        LOG("old pm_hooked removed\n");
    }
    int ui_tries = 0;
    time_t last_ping = time(NULL);
    time_t last_ui = 0;
    while (1) {
        // v36：UI 与 pm_hooked/Lua 解耦。
        // 注入成功后独立尝试；窗口尚未创建时等待 MainThread/UIScene 就绪。
        (void)ui_tries; (void)last_ui;
        // v29: Lua VM 自愈 —— 每 30s ping 一次（极轻量 return 1）；
        // 失败 = 引擎重启了 VM（Restart/DisposeOldLuaState）→ 重取 L + 重装回调
        if (time(NULL) - last_ping > 30) {
            last_ping = time(NULL);
            if (g_L) {
                int pr = lua_dostring("return 1");
                if (pr != 0) {
                    LOG("lua dead (rc=%d) -> re-acquiring\n", pr);
                    g_L = NULL;
                    if (L_getstate) { g_L = L_getstate(); LOG("new L=%p\n", (void*)g_L); }
                    if (g_L) { g_pending_job = 2; post_to_main(NULL); }
                } else if (!g_beat_ok) {
                    // v34: Lua 活着但 install 失败过（沙箱 __index 状态性错误）→ 静默重试
                    LOG("beat retry (alive but not installed)\n");
                    g_pending_job = 2; post_to_main(NULL);
                }
            } else {
                if (L_getstate) { g_L = L_getstate(); if (g_L) { LOG("L re-acquired %p\n",(void*)g_L); g_pending_job = 2; post_to_main(NULL); } }
            }
        }
        if ((tick++ % 3) == 0) read_flags();
        usleep(500000);
    }
    return NULL;
}


// ════════════════════════════════════════════════════════════════════════
// Part 2  FloatGlass UI（玻璃按钮 + 玻璃面板，面板内嵌功能开关）
// ════════════════════════════════════════════════════════════════════════

// UI → 引擎通道：pm.flags 文件（v45 实测成功通道；worker 每 1.5s 读、Lua 每 30 帧读）
static void pm_write_flags(void) {
    const char* p = getenv("HOME");
    char path[512];
    snprintf(path, sizeof(path), "%s/Documents/pm.flags", p ? p : "/var/mobile");
    FILE* f = fopen(path, "w");
    if (f) {
        fprintf(f, "god=%d\nonehit=%d\nspeed=%d\n",
                (int)f_godmode, (int)f_onehit, f_speed ? 3 : 1);
        fclose(f);
    }
}

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

static NSString *pm_godText(void)    { return f_godmode ? @"无敌 · 开" : @"无敌 · 关"; }
static NSString *pm_hitText(void)    { return f_onehit == 2 ? @"秒杀 · 暴力" : (f_onehit == 1 ? @"秒杀 · 温和" : @"秒杀 · 关"); }
static NSString *pm_spdText(void)    { return f_speed ? @"加速 · 3x" : @"加速 · 关"; }
static NSString *pm_engineText(void) {
    if (!g_uf)  return @"引擎 · 等待游戏加载";
    if (!g_L)   return @"引擎 · Lua 连接中";
    if (!g_beat_ok) return @"引擎 · 安装中";
    return @"引擎 · 就绪(进对局生效)";
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
    f_godmode = !f_godmode;
    pm_write_flags();
    [_godBtn setTitle:pm_godText() forState:UIControlStateNormal];
    LOG("ui: god=%d\n", (int)f_godmode);
}

- (void)pm_hitTap:(id)sender {
    (void)sender;
    f_onehit = (f_onehit + 1) % 3;   // 关 → 温和(×1000) → 暴力(9e15) → 关
    pm_write_flags();
    [_hitBtn setTitle:pm_hitText() forState:UIControlStateNormal];
    LOG("ui: onehit=%d\n", (int)f_onehit);
}

- (void)pm_spdTap:(id)sender {
    (void)sender;
    f_speed = !f_speed;
    pm_write_flags();
    [_spdBtn setTitle:pm_spdText() forState:UIControlStateNormal];
    LOG("ui: speed=%d\n", (int)f_speed);
}

- (void)pm_refresh {
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
        LOG("PMGlass v6 pid=%d\n", getpid());

        NSString *bid = NSBundle.mainBundle.bundleIdentifier;
        if (!bid) { LOG("no bundle id\n"); return; }
        if (fg_shouldSkip(bid)) {
            LOG("skip blacklist app: %s\n", bid.UTF8String);
            return;
        }
        LOG("loaded in %s\n", bid.UTF8String);

        // v6：v45 原版 worker（pthread：探测→runloop桥→install→ping 自愈→flags 读）
        pthread_t t;
        pthread_create(&t, NULL, worker, NULL);
        pthread_detach(t);

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
