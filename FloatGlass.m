//
//  Tweak.xm — 悬浮玻璃按钮 (FloatGlass)
//  ────────────────────────────────────────────────────────────────────────
//  这是一个「普通 dylib」：用 TrollFools / TrollStore 注入到任意 App 即可，
//  构造函数(__attribute__((constructor))) 在 App 启动时自动运行，不依赖越狱
//  (ElleKit/Substrate/MobileSubstrate)，也不需要 Filter.plist。
//
//  行为：
//    · 圆形 · 半透明 · 液态玻璃 悬浮按钮（毛玻璃 + 顶部柔光 + 边缘高光 + 投影）
//    · 按钮较小，可拖动，松手吸附到最近的左右边缘
//    · 点按按钮 → 呼出/收起一个「空面板」小卡片（占位，可全屏任意拖动）
//    · 面板是独立的浮层小卡片，不全屏、不加遮罩，不拦截面板以外的点击
//    · 银行/带越狱检测的 App 在运行时黑名单中自动跳过
//    · 加载成功会在屏幕底部弹一条 2 秒淡出的提示，确认 dylib 已注入
//
//  没看见按钮时怎么排查：
//    1) 进 App 后 ~2 秒底部有没有出现 “FloatGlass 已加载” 提示？
//         · 没有 → dylib 没加载（TrollFools 没生效 / 装错 App / App 没重启）。
//         · 有   → dylib 加载了，按钮没显示，把现象告诉我。
//    2) 注入的是银行类 App → 在黑名单里被静默跳过（属正常）。
//  ────────────────────────────────────────────────────────────────────────
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#include <math.h>

@interface FloatGlassPanel : UIView
- (void)fg_close;
@end
static UIWindow *fg_keyWindow(void);
static FloatGlassPanel *g_panel = nil;

#pragma mark - 运行时黑名单（银行 / 带越狱检测的 App 不显示）

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
            @"com.alipay.iphoneclient",  // 支付宝（有检测，稳妥跳过）
            @"com.unionpay.iphone",      // 银联
        ];
    });
    for (NSString *b in blacklist) {
        if ([bid isEqualToString:b]) return YES;
    }
    return NO;
}

#pragma mark - 悬浮玻璃按钮

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
        _glassView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.14]; // 半透明基底
        _glassView.userInteractionEnabled = NO;
        [self addSubview:_glassView];

        // 毛玻璃（iOS 16 没有原生 UIGlassEffect，用 UIBlurEffect 模拟液态通透感）
        UIBlurEffect *blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterialLight];
        UIVisualEffectView *bv = [[UIVisualEffectView alloc] initWithEffect:blur];
        bv.frame = _glassView.bounds;
        bv.userInteractionEnabled = NO;
        [_glassView addSubview:bv];

        // 液态高光：顶部一道柔光，缓慢呼吸 → 像液面反光
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

        // 边缘高光（玻璃 rim light）
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
    [self fg_togglePanel];
}

- (void)fg_togglePanel {
    if (g_panel) { [self fg_closePanel]; return; }
    UIWindow *kw = fg_keyWindow();
    if (!kw) return;
    CGFloat pw = 280, ph = 340;   // 小卡片，不全屏
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

#pragma mark - 面板（可拖动小卡片：不全屏、不挡点击）

@implementation FloatGlassPanel

- (instancetype)initWithFrame:(CGRect)frame {
    if (self = [super initWithFrame:frame]) {
        // 投影（与按钮一致的玻璃质感）
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
        title.text = @"面板";
        title.textAlignment = NSTextAlignmentCenter;
        title.textColor = [UIColor whiteColor];
        title.font = [UIFont boldSystemFontOfSize:17];
        title.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        [self addSubview:title];

        // 关闭按钮
        UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
        [close setTitle:@"关闭" forState:UIControlStateNormal];
        close.tintColor = [UIColor whiteColor];
        close.frame = CGRectMake(CGRectGetWidth(self.bounds) - 72, 12, 60, 32);
        close.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleBottomMargin;
        [close addTarget:self action:@selector(fg_close) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:close];

        // 拖动：可全屏任意移动（只拦截卡片范围内的点击，不挡 App）
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(fg_drag:)];
        [self addGestureRecognizer:pan];

        // TODO: 在这里往卡片里加你的功能控件（只占位，面板外不挡 App 点击）
    }
    return self;
}

- (void)fg_close {
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

#pragma mark - 工具

static UIWindow *fg_keyWindow() {
    UIApplication *app = UIApplication.sharedApplication;
    if (!app) return nil;
    // iOS 13+：从 connectedScenes 里找前台激活的 windowScene 的 keyWindow
    for (UIScene *s in app.connectedScenes) {
        if ([s isKindOfClass:[UIWindowScene class]] &&
            ((UIWindowScene *)s).activationState == UISceneActivationStateForegroundActive) {
            UIWindowScene *ws = (UIWindowScene *)s;
            for (UIWindow *w in ws.windows) if (w.isKeyWindow) return w;
            for (UIWindow *w in ws.windows) if (w.rootViewController) return w;
            if (ws.windows.count) return ws.windows.firstObject;
        }
    }
    // 兜底
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
        g_floatBtn = [[FloatGlassButton alloc] initWithSize:46];   // 按钮缩小
        CGFloat W = UIScreen.mainScreen.bounds.size.width;
        CGFloat H = UIScreen.mainScreen.bounds.size.height;
        g_floatBtn.center = CGPointMake(W - 32, H / 2.0); // 默认右侧居中
    }
    UIWindow *kw = fg_keyWindow();
    if (kw) {
        if (g_floatBtn.superview != kw) [kw addSubview:g_floatBtn];
        [kw bringSubviewToFront:g_floatBtn];
    } else if (g_ensureTries < 12) {
        // keyWindow 还没就绪，1 秒后重试
        g_ensureTries++;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ fg_ensureButton(); });
    }
}

#pragma mark - 入口

__attribute__((constructor)) static void fg_ctor() {
    @autoreleasepool {
        NSString *bid = NSBundle.mainBundle.bundleIdentifier;
        if (!bid) return;
        if (fg_shouldSkip(bid)) {
            NSLog(@"[FloatGlass] 跳过黑名单 App: %@", bid);
            return;
        }
        NSLog(@"[FloatGlass] 已在 %@ 加载", bid);

        // App 启动后再挂 UI（构造函数早于 UIApplicationMain，需延迟）
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            fg_toast(@"FloatGlass 已加载");
            fg_ensureButton();
            [NSNotificationCenter.defaultCenter
                addObserverForName:UIApplicationDidBecomeActiveNotification
                            object:nil
                             queue:NSOperationQueue.mainQueue
                        usingBlock:^(NSNotification * _Nonnull n) {
                            // 回到前台时确保按钮仍在最上层
                            if (g_floatBtn.superview) [g_floatBtn.superview bringSubviewToFront:g_floatBtn];
                            else fg_ensureButton();
                        }];
        });
    }
}
