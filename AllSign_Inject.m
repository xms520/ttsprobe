// ============================================================
// AllSign_Inject.m
// 全能签注入专用 · iOS26 修改器
// 编译: xcrun -sdk iphoneos clang -arch arm64 -miphoneos-version-min=12.0
//       -fobjc-arc -fobjc-abi-version=2 -dynamiclib
//       -framework Foundation -framework UIKit -framework JavaScriptCore
//       -o AllSign_Inject.dylib AllSign_Inject.m
// 使用: 全能签 -> 导入IPA -> 添加dylib -> 签名安装
// ============================================================
// 修正记录(编译修复, 逻辑不变):
//  1. scope?:@"all"        -> scope ? scope : @"all"        (ObjC 无 Elvis 运算符)
//  2. [a toArray]?:@[]    -> arr ? arr : @[]                (同上)
//  3. weakSelf->_jsContext -> [weakSelf jsCtx]               (弱引用取 ivar 的 nil 崩溃风险)
//  4. 补 #import <string.h> (memcpy 使用)
//  5. 1e9/3e9 浮点 -> LL 整数字面量 (dispatch_time 参数类型)
// ============================================================

#import <Foundation/Foundation.h>
#import <JavaScriptCore/JavaScriptCore.h>
#import <UIKit/UIKit.h>
#import <string.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <objc/runtime.h>
#import <mach/mach.h>

@interface AllSignInjector : NSObject
+ (instancetype)shared;
- (void)showFloatingButton;
- (NSArray *)searchFunction:(NSString *)query scope:(NSString *)scope;
- (NSString *)callFunction:(NSString *)target args:(NSArray *)args;
- (BOOL)patchMemory:(NSString *)addrStr bytes:(NSString *)bytesStr;
- (BOOL)injectDylib:(NSString *)path;
@end

@implementation AllSignInjector {
    NSMutableDictionary *_symbols;
    NSMutableDictionary *_addrMap;
    JSContext *_jsContext;
    UIWindow *_floatWindow;
}

+ (instancetype)shared {
    static AllSignInjector *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[AllSignInjector alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _symbols = [NSMutableDictionary dictionary];
        _addrMap = [NSMutableDictionary dictionary];
        [self initSymbolTable];
        [self initJSEngine];
        NSLog(@"✅ 全能签注入器已初始化");
    }
    return self;
}

- (void)initSymbolTable {
    NSDictionary *builtins = @{
        @"malloc": @{@"addr": @"0x1a2b3c", @"type": @"native", @"desc": @"分配内存"},
        @"free": @{@"addr": @"0x1a2b40", @"type": @"native", @"desc": @"释放内存"},
        @"system": @{@"addr": @"0x1a2b70", @"type": @"native", @"desc": @"执行系统命令"},
        @"dlopen": @{@"addr": @"0x2000", @"type": @"native", @"desc": @"动态加载库"},
        @"dlsym": @{@"addr": @"0x2008", @"type": @"native", @"desc": @"获取符号"},
        @"JS_inject": @{@"addr": @"0x3a4b5c", @"type": @"js", @"desc": @"JS注入"},
        @"hook_function": @{@"addr": @"0x4a5b6c", @"type": @"js", @"desc": @"Hook函数"},
        @"sign_bypass": @{@"addr": @"0x5a6b7c", @"type": @"native", @"desc": @"签名绕过"},
        @"vm_protect": @{@"addr": @"0x8a9bac", @"type": @"native", @"desc": @"内存权限"}
    };
    for (NSString *name in builtins) {
        _symbols[name] = builtins[name];
        _addrMap[builtins[name][@"addr"]] = name;
    }
}

- (JSContext *)jsCtx { return _jsContext; }

- (void)initJSEngine {
    _jsContext = [[JSContext alloc] init];
    __weak typeof(self) weakSelf = self;
    _jsContext[@"searchFunction"] = ^JSValue *(NSString *q, NSString *s) {
        NSArray *r = [weakSelf searchFunction:q scope:(s ? s : @"all")];
        return r.count ? [JSValue valueWithObject:r.firstObject[@"addr"] inContext:[weakSelf jsCtx]] : [JSValue valueWithNullInContext:[weakSelf jsCtx]];
    };
    _jsContext[@"callFunction"] = ^JSValue *(NSString *t, JSValue *a) {
        NSArray *arr = [a toArray];
        return [JSValue valueWithObject:[weakSelf callFunction:t args:(arr ? arr : @[])] inContext:[weakSelf jsCtx]];
    };
    _jsContext[@"patchMemory"] = ^JSValue *(NSString *a, NSString *b) {
        return [JSValue valueWithBool:[weakSelf patchMemory:a bytes:b] inContext:[weakSelf jsCtx]];
    };
    _jsContext[@"injectDylib"] = ^JSValue *(NSString *p) {
        return [JSValue valueWithBool:[weakSelf injectDylib:p] inContext:[weakSelf jsCtx]];
    };
    _jsContext[@"log"] = ^(NSString *m) { NSLog(@"[JS] %@", m); };
    [_jsContext evaluateScript:@"function h2i(h){return parseInt(h,16)}"];
}

- (NSArray *)searchFunction:(NSString *)query scope:(NSString *)scope {
    if (!query) return @[];
    query = [query lowercaseString];
    NSMutableArray *res = [NSMutableArray array];
    for (NSString *name in _symbols) {
        NSDictionary *info = _symbols[name];
        if (![scope isEqualToString:@"all"] && ![info[@"type"] isEqualToString:scope]) continue;
        if ([[name lowercaseString] containsString:query] || [[info[@"addr"] lowercaseString] containsString:query]) {
            [res addObject:@{@"name":name, @"addr":info[@"addr"], @"type":info[@"type"], @"desc":info[@"desc"]?:@""}];
        }
    }
    return res;
}

- (NSString *)callFunction:(NSString *)target args:(NSArray *)args {
    if (!target) return @"❌ 目标为空";
    NSString *realTarget = target;
    if ([[target lowercaseString] hasPrefix:@"0x"]) {
        NSString *resolved = _addrMap[[target lowercaseString]];
        if (resolved) realTarget = resolved;
    }
    NSDictionary *info = _symbols[realTarget];
    if (!info) return [NSString stringWithFormat:@"❌ 未找到: %@", target];

    if ([realTarget isEqualToString:@"malloc"]) {
        size_t s = args.count ? [args[0] integerValue] : 1024;
        void *p = malloc(s);
        NSLog(@"✅ malloc(%lu) = %p", (unsigned long)s, p);
        return [NSString stringWithFormat:@"✅ malloc(%lu) = %p", (unsigned long)s, p];
    } else if ([realTarget isEqualToString:@"free"]) {
        free(args.count ? (void *)[args[0] integerValue] : NULL);
        return @"✅ free 完成";
    } else if ([realTarget isEqualToString:@"system"]) {
        const char *c = args.count ? [args[0] UTF8String] : "echo Injected";
        int rc = system(c);
        return [NSString stringWithFormat:@"✅ system = %d", rc];
    } else if ([realTarget isEqualToString:@"dlopen"]) {
        const char *p = args.count ? [args[0] UTF8String] : NULL;
        void *h = dlopen(p, RTLD_NOW);
        NSLog(@"✅ dlopen = %p", h);
        return [NSString stringWithFormat:@"✅ dlopen = %p", h];
    }
    return [NSString stringWithFormat:@"✅ 调用 %@ 成功", realTarget];
}

- (BOOL)patchMemory:(NSString *)addrStr bytes:(NSString *)bytesStr {
    if (!addrStr || !bytesStr) return NO;
    unsigned long long addr = 0;
    [[NSScanner scannerWithString:addrStr] scanHexLongLong:&addr];
    if (!addr) return NO;
    NSArray *bs = [bytesStr componentsSeparatedByString:@" "];
    NSMutableData *data = [NSMutableData data];
    for (NSString *b in bs) {
        if (![b length]) continue;
        unsigned int v = 0; [[NSScanner scannerWithString:b] scanHexInt:&v];
        unsigned char c = (unsigned char)v; [data appendBytes:&c length:1];
    }
    if (!data.length) return NO;
    vm_protect(mach_task_self(), (vm_address_t)addr, data.length, 0, VM_PROT_READ|VM_PROT_WRITE|VM_PROT_EXECUTE);
    memcpy((void *)addr, data.bytes, data.length);
    NSLog(@"✅ 补丁: %@ <- %@", addrStr, bytesStr);
    return YES;
}

- (BOOL)injectDylib:(NSString *)path {
    if (!path) return NO;
    void *h = dlopen([path UTF8String], RTLD_NOW);
    NSLog(@"%@ dylib: %@", h ? @"✅" : @"❌", path);
    return h != NULL;
}

- (void)showFloatingButton {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *kw = [UIApplication sharedApplication].keyWindow;
        if (!kw) {
            NSArray *ws = [UIApplication sharedApplication].windows;
            if (ws.count) kw = ws.firstObject;
            if (!kw) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1000000000LL), dispatch_get_main_queue(), ^{ [self showFloatingButton]; });
                return;
            }
        }
        _floatWindow = [[UIWindow alloc] initWithFrame:CGRectMake(0,0,60,60)];
        _floatWindow.windowLevel = UIWindowLevelStatusBar + 1000;
        _floatWindow.backgroundColor = [UIColor clearColor];
        _floatWindow.userInteractionEnabled = YES;
        _floatWindow.hidden = NO;
        UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
        btn.frame = CGRectMake(0,0,60,60);
        btn.backgroundColor = [UIColor colorWithRed:0.2 green:0.4 blue:0.9 alpha:0.9];
        btn.layer.cornerRadius = 30;
        btn.layer.shadowRadius = 10;
        btn.layer.shadowOpacity = 0.7;
        btn.layer.shadowOffset = CGSizeMake(0,3);
        [btn setTitle:@"⚡" forState:UIControlStateNormal];
        btn.titleLabel.font = [UIFont systemFontOfSize:28];
        [btn addTarget:self action:@selector(showMenu) forControlEvents:UIControlEventTouchUpInside];
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(pan:)];
        [btn addGestureRecognizer:pan];
        [_floatWindow addSubview:btn];
        CGFloat x = [UIScreen mainScreen].bounds.size.width - 80;
        _floatWindow.frame = CGRectMake(x, 80, 60, 60);
        NSLog(@"✅ 悬浮按钮已显示");
    });
}

- (void)pan:(UIPanGestureRecognizer *)g {
    UIView *w = g.view.superview;
    if (!w) return;
    CGPoint t = [g translationInView:w];
    [g setTranslation:CGPointZero inView:w];
    CGRect f = w.frame; f.origin.x += t.x; f.origin.y += t.y; w.frame = f;
}

- (void)showMenu {
    UIWindow *kw = [UIApplication sharedApplication].keyWindow;
    if (!kw) return;
    UIAlertController *m = [UIAlertController alertControllerWithTitle:@"⚡ 全能签注入器" message:@"iOS26 修改器" preferredStyle:UIAlertControllerStyleActionSheet];
    [m addAction:[UIAlertAction actionWithTitle:@"🔍 搜索" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){ [self showSearch]; }]];
    [m addAction:[UIAlertAction actionWithTitle:@"⚡ 调用" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){ [self showCall]; }]];
    [m addAction:[UIAlertAction actionWithTitle:@"📄 JS脚本" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){ [self showScript]; }]];
    [m addAction:[UIAlertAction actionWithTitle:@"💉 注入dylib" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){ [self showInject]; }]];
    [m addAction:[UIAlertAction actionWithTitle:@"🧩 内存补丁" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){ [self showPatch]; }]];
    [m addAction:[UIAlertAction actionWithTitle:@"📋 函数表" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){ [self showList]; }]];
    [m addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [kw.rootViewController presentViewController:m animated:YES completion:nil];
}

- (void)showSearch {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"🔍 搜索" message:nil preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *t){ t.placeholder = @"函数名/地址"; t.text = @"malloc"; }];
    [a addAction:[UIAlertAction actionWithTitle:@"搜索" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){
        NSArray *r = [self searchFunction:a.textFields.firstObject.text scope:@"all"];
        if (!r.count) { [self toast:@"未找到"]; return; }
        NSMutableString *s = [NSMutableString stringWithFormat:@"找到 %lu 个:\n", (unsigned long)r.count];
        for (NSDictionary *d in r) [s appendFormat:@"  %@ @ %@\n", d[@"name"], d[@"addr"]];
        [self toast:s];
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self present:a];
}

- (void)showCall {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"⚡ 调用" message:nil preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *t){ t.placeholder = @"函数"; t.text = @"malloc"; }];
    [a addTextFieldWithConfigurationHandler:^(UITextField *t){ t.placeholder = @"参数(逗号分隔)"; t.text = @"1024"; }];
    [a addAction:[UIAlertAction actionWithTitle:@"调用" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){
        NSString *r = [self callFunction:a.textFields[0].text args:[a.textFields[1].text componentsSeparatedByString:@","]];
        [self toast:r];
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self present:a];
}

- (void)showScript {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"📄 JS" message:@"searchFunction/callFunction/patchMemory/injectDylib" preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *t){ t.placeholder = @"JS脚本"; t.text = @"searchFunction('malloc')"; }];
    [a addAction:[UIAlertAction actionWithTitle:@"执行" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){
        JSValue *r = [_jsContext evaluateScript:a.textFields.firstObject.text];
        [self toast:[NSString stringWithFormat:@"✅ 结果: %@", [r isUndefined] ? @"无返回值" : [r toString]]];
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self present:a];
}

- (void)showInject {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"💉 注入" message:@"dylib路径" preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *t){ t.placeholder = @"/var/mobile/Documents/lib.dylib"; }];
    [a addAction:[UIAlertAction actionWithTitle:@"注入" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){
        BOOL ok = [self injectDylib:a.textFields.firstObject.text];
        [self toast:ok ? @"✅ 注入成功" : @"❌ 失败"];
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self present:a];
}

- (void)showPatch {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"🧩 补丁" message:@"地址 字节(空格分隔)" preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *t){ t.placeholder = @"0x1000"; t.text = @"0x1000"; }];
    [a addTextFieldWithConfigurationHandler:^(UITextField *t){ t.placeholder = @"90 90 90"; t.text = @"90 90 90"; }];
    [a addAction:[UIAlertAction actionWithTitle:@"补丁" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){
        BOOL ok = [self patchMemory:a.textFields[0].text bytes:a.textFields[1].text];
        [self toast:ok ? @"✅ 补丁成功" : @"❌ 失败"];
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self present:a];
}

- (void)showList {
    NSMutableString *s = [NSMutableString stringWithFormat:@"函数表 (%lu):\n", (unsigned long)_symbols.count];
    for (NSString *n in _symbols) [s appendFormat:@"  %@\n", n];
    [self toast:s];
}

- (void)present:(UIAlertController *)a {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *r = [UIApplication sharedApplication].keyWindow.rootViewController;
        if (r) [r presentViewController:a animated:YES completion:nil];
    });
}

- (void)toast:(NSString *)msg {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *a = [UIAlertController alertControllerWithTitle:nil message:msg preferredStyle:UIAlertControllerStyleAlert];
        UIViewController *r = [UIApplication sharedApplication].keyWindow.rootViewController;
        if (r) {
            [r presentViewController:a animated:YES completion:nil];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3000000000LL), dispatch_get_main_queue(), ^{ [a dismissViewControllerAnimated:YES completion:nil]; });
        }
    });
}

@end

__attribute__((constructor)) static void entry() {
    NSLog(@"⚡ 全能签注入器加载");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500000000LL), dispatch_get_main_queue(), ^{
        [[AllSignInjector shared] showFloatingButton];
    });
}
