%config(generator=internal)
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

static const void *kTrackedLabelAssocKey    = &kTrackedLabelAssocKey;
static const void *kForceHiddenViewKey      = &kForceHiddenViewKey;
static const void *kCollapsedPathsKey       = &kCollapsedPathsKey;
static const void *kCollapsedSectionsKey    = &kCollapsedSectionsKey;
static const void *kCollapsePendingFlagKey  = &kCollapsePendingFlagKey;
static const void *kGestureAttachedKey      = &kGestureAttachedKey;
static const void *kOrigYogaYKey            = &kOrigYogaYKey;
static const void *kLastShiftedYKey         = &kLastShiftedYKey;
static const void *kOrigTabCenterXKey       = &kOrigTabCenterXKey;
static const void *kLastTabCenterXKey       = &kLastTabCenterXKey;
static const void *kIsNMTabBarKey            = &kIsNMTabBarKey;
static const void *kNMTabBarRebalancePendKey = &kNMTabBarRebalancePendKey;
static const void *kIsMyPageTabBarKey        = &kIsMyPageTabBarKey;
static const void *kMyPageTabBarPendKey      = &kMyPageTabBarPendKey;
static const void *kLockMyPageHorizScrollKey = &kLockMyPageHorizScrollKey;
static BOOL gInsideNMTabBarRebalance         = NO;
static BOOL gInsideMyPageBarRebalance        = NO;


// Fine-grained NSUserDefaults preference keys (all default to YES)
static NSString *const kPrefMasterEnabled    = @"UICleaner_MasterEnabled";
static NSString *const kPrefCleanTopBar      = @"UICleaner_CleanTopBar";
static NSString *const kPrefCleanBottomBar   = @"UICleaner_CleanBottomBar";
static NSString *const kPrefCleanMyPage      = @"UICleaner_CleanMyPage";
static NSString *const kPrefCleanSidebar     = @"UICleaner_CleanSidebar";
static NSString *const kPrefFeedPlaylist     = @"UICleaner_FeedPlaylist";
static NSString *const kPrefFeedRank         = @"UICleaner_FeedRank";
static NSString *const kPrefFeedAudioBook    = @"UICleaner_FeedAudioBook";
static NSString *const kPrefFeedCityHot      = @"UICleaner_FeedCityHot";
static NSString *const kPrefFeedArtistTry    = @"UICleaner_FeedArtistTry";
static NSString *const kPrefFeedLiveVideo    = @"UICleaner_FeedLiveVideo";
static NSString *const kPrefCustomRulesArray = @"UICleaner_CustomRules";

// Forward declarations
@class UICleanerSettingsController;
static void MarkForceHidden(UIView *v);
static void UnmarkForceHidden(UIView *v);
static void CollapseContainerHeightForHiddenModule(UIView *moduleView);
static void ScanAndRebalanceBottomBar(UIView *barView);
static void CollectTextsInSubtree(UIView *view, NSMutableArray<NSString *> *outTexts, int depth);
static NSString *CleanLabelText(NSString *raw);
static UIWindow *ActiveKeyWindow(void);
static void ShowInspectorOverlay(void);
static BOOL IsViewInsideCleanerUI(UIView *v);

static NSArray<NSDictionary *> *gCachedCustomRules = nil;

static void ReloadCustomRulesCache(void) {
    NSArray *saved = [[NSUserDefaults standardUserDefaults] arrayForKey:kPrefCustomRulesArray];
    gCachedCustomRules = [saved isKindOfClass:[NSArray class]] ? [saved copy] : @[];
}

static void RegisterDefaultPrefs(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        [[NSUserDefaults standardUserDefaults] registerDefaults:@{
            kPrefMasterEnabled:  @YES,
            kPrefCleanTopBar:    @YES,
            kPrefCleanBottomBar: @YES,
            kPrefCleanMyPage:    @YES,
            kPrefCleanSidebar:   @YES,
            kPrefFeedPlaylist:   @YES,
            kPrefFeedRank:       @YES,
            kPrefFeedAudioBook:  @YES,
            kPrefFeedCityHot:    @YES,
            kPrefFeedArtistTry:  @YES,
            kPrefFeedLiveVideo:  @YES
        }];
        ReloadCustomRulesCache();
    });
}

static BOOL IsPrefOn(NSString *key) {
    RegisterDefaultPrefs();
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    if (![ud boolForKey:kPrefMasterEnabled]) return NO;
    return [ud boolForKey:key];
}

static BOOL IsAnyFeedSubPrefOn(void) {
    return IsPrefOn(kPrefFeedPlaylist) || IsPrefOn(kPrefFeedRank) ||
           IsPrefOn(kPrefFeedAudioBook) || IsPrefOn(kPrefFeedCityHot) ||
           IsPrefOn(kPrefFeedArtistTry) || IsPrefOn(kPrefFeedLiveVideo);
}

static BOOL IsSystemFrameworkViewClass(NSString *clsName) {
    if (!clsName || clsName.length == 0) return YES;
    return [clsName hasPrefix:@"UI"] || [clsName hasPrefix:@"_UI"] ||
           [clsName hasPrefix:@"NS"] || [clsName hasPrefix:@"CA"] ||
           [clsName hasPrefix:@"WK"] || [clsName hasPrefix:@"AV"] ||
           [clsName hasPrefix:@"RCT"];
}

static NSString *ZoneForViewInWindow(UIView *v, CGSize screenSz) {
    if (!v || !v.window || screenSz.height <= 0) return @"body";
    CGRect r = [v convertRect:v.bounds toView:nil];
    if (r.origin.y <= 175.0 && r.size.height <= 120.0) return @"top";
    if (r.origin.y >= screenSz.height - 135.0 && r.size.height <= 120.0) return @"bottom";
    return @"body";
}

static void UnmarkAllForceHiddenInTree(UIView *root) {
    if (!root) return;
    UnmarkForceHidden(root);
    if ([root isKindOfClass:[UIScrollView class]]) {
        [objc_getAssociatedObject(root, kCollapsedPathsKey) removeAllObjects];
        [objc_getAssociatedObject(root, kCollapsedSectionsKey) removeAllObjects];
    }
    for (UIView *sub in root.subviews) {
        UnmarkAllForceHiddenInTree(sub);
    }
}

// =============================================================================
// Interactive "指哪打哪" Visual Targeter Overlay
// =============================================================================
@interface UICleanerInspectorOverlay : UIView
@property (nonatomic, weak) UIView *selectedTarget;
@property (nonatomic, strong) NSMutableArray<NSValue *> *childHistory;
@property (nonatomic, assign) BOOL passThroughScrollMode;
@property (nonatomic, strong) UIView *highlightBox;
@property (nonatomic, strong) UIVisualEffectView *hudCard;
@property (nonatomic, strong) UILabel *infoLabel;
@property (nonatomic, strong) UIButton *modeBtn;
@end

static __weak UICleanerInspectorOverlay *gActiveOverlay = nil;

@implementation UICleanerInspectorOverlay

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _childHistory = [NSMutableArray array];
        _passThroughScrollMode = NO;
        self.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.04];

        _highlightBox = [[UIView alloc] initWithFrame:CGRectZero];
        _highlightBox.backgroundColor = [UIColor colorWithRed:1.0 green:0.18 blue:0.18 alpha:0.18];
        _highlightBox.layer.borderColor = [UIColor systemRedColor].CGColor;
        _highlightBox.layer.borderWidth = 2.5;
        _highlightBox.layer.cornerRadius = 6.0;
        _highlightBox.userInteractionEnabled = NO;
        _highlightBox.hidden = YES;
        [self addSubview:_highlightBox];

        UIBlurEffect *blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterialDark];
        _hudCard = [[UIVisualEffectView alloc] initWithEffect:blur];
        CGFloat cardW = MIN(frame.size.width - 20.0, 400.0);
        _hudCard.frame = CGRectMake((frame.size.width - cardW) * 0.5, frame.size.height - 265.0, cardW, 154.0);
        _hudCard.layer.cornerRadius = 16.0;
        _hudCard.layer.masksToBounds = YES;
        _hudCard.layer.borderWidth = 0.5;
        _hudCard.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.25].CGColor;
        [self addSubview:_hudCard];

        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onDragHud:)];
        [_hudCard addGestureRecognizer:pan];

        _infoLabel = [[UILabel alloc] initWithFrame:CGRectMake(12, 8, cardW - 24, 42)];
        _infoLabel.text = @"🎯 瞄准模式（按住此黑框可上下拖动位置）\n直接点屏幕上不想看的板块即可红框锁定！";
        _infoLabel.textColor = [UIColor whiteColor];
        _infoLabel.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightMedium];
        _infoLabel.numberOfLines = 2;
        [_hudCard.contentView addSubview:_infoLabel];

        CGFloat btnGap = 6.0;
        CGFloat rowW = cardW - 24.0;
        CGFloat w3 = (rowW - btnGap * 2.0) / 3.0;

        UIButton *upBtn = [self makeHudButton:@"⬆️ 扩一层" bg:[UIColor colorWithWhite:1.0 alpha:0.18] action:@selector(onExpandParent)];
        upBtn.frame = CGRectMake(12.0, 56.0, w3, 38.0);

        UIButton *downBtn = [self makeHudButton:@"⬇️ 缩一层" bg:[UIColor colorWithWhite:1.0 alpha:0.18] action:@selector(onShrinkChild)];
        downBtn.frame = CGRectMake(12.0 + w3 + btnGap, 56.0, w3, 38.0);

        _modeBtn = [self makeHudButton:@"👆 切滑动页面" bg:[UIColor systemOrangeColor] action:@selector(onToggleScrollMode)];
        _modeBtn.frame = CGRectMake(12.0 + (w3 + btnGap) * 2.0, 56.0, w3, 38.0);

        UIButton *hideBtn = [self makeHudButton:@"🙈 隐藏此块" bg:[UIColor systemRedColor] action:@selector(onHideSelected)];
        hideBtn.frame = CGRectMake(12.0, 102.0, w3, 40.0);

        UIButton *copyBtn = [self makeHudButton:@"📋 复制发助手" bg:[UIColor systemBlueColor] action:@selector(onCopySelectedInfo)];
        copyBtn.frame = CGRectMake(12.0 + w3 + btnGap, 102.0, w3, 40.0);

        UIButton *exitBtn = [self makeHudButton:@"✕ 退出瞄准" bg:[UIColor colorWithWhite:0.35 alpha:0.9] action:@selector(onCloseOverlay)];
        exitBtn.frame = CGRectMake(12.0 + (w3 + btnGap) * 2.0, 102.0, w3, 40.0);

        [_hudCard.contentView addSubview:upBtn];
        [_hudCard.contentView addSubview:downBtn];
        [_hudCard.contentView addSubview:_modeBtn];
        [_hudCard.contentView addSubview:hideBtn];
        [_hudCard.contentView addSubview:copyBtn];
        [_hudCard.contentView addSubview:exitBtn];

        UITapGestureRecognizer *aimTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onAimTap:)];
        [self addGestureRecognizer:aimTap];
    }
    return self;
}

- (UIButton *)makeHudButton:(NSString *)title bg:(UIColor *)bg action:(SEL)sel {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont boldSystemFontOfSize:12.5];
    b.titleLabel.adjustsFontSizeToFitWidth = YES;
    b.backgroundColor = bg;
    b.layer.cornerRadius = 9.0;
    [b addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    if (CGRectContainsPoint(self.hudCard.frame, point)) return YES;
    return !self.passThroughScrollMode;
}

- (void)onDragHud:(UIPanGestureRecognizer *)pan {
    CGPoint trans = [pan translationInView:self];
    CGPoint c = self.hudCard.center;
    c.x = MIN(MAX(c.x + trans.x, self.hudCard.bounds.size.width * 0.5), self.bounds.size.width - self.hudCard.bounds.size.width * 0.5);
    c.y = MIN(MAX(c.y + trans.y, 110.0), self.bounds.size.height - 95.0);
    self.hudCard.center = c;
    [pan setTranslation:CGPointZero inView:self];
}

- (UIView *)deepestVisibleViewAtWindowPoint:(CGPoint)pt inRoot:(UIView *)root {
    if (!root || root == self || root.hidden || root.alpha < 0.02) return nil;
    CGPoint localPt = [root convertPoint:pt fromView:nil];
    if (![root pointInside:localPt withEvent:nil]) return nil;

    for (UIView *sub in [root.subviews reverseObjectEnumerator]) {
        UIView *hit = [self deepestVisibleViewAtWindowPoint:pt inRoot:sub];
        if (hit) return hit;
    }
    if (root.bounds.size.width >= 10.0 && root.bounds.size.height >= 10.0) {
        return root;
    }
    return nil;
}

- (void)onAimTap:(UITapGestureRecognizer *)tap {
    CGPoint pt = [tap locationInView:self];
    if (CGRectContainsPoint(self.hudCard.frame, pt)) return;

    UIWindow *win = self.window;
    if (!win) return;

    self.hidden = YES;
    UIView *hit = [win hitTest:pt withEvent:nil];
    if (!hit || hit == win || (hit.bounds.size.width >= win.bounds.size.width * 0.95 && hit.bounds.size.height >= win.bounds.size.height * 0.70)) {
        UIView *deep = [self deepestVisibleViewAtWindowPoint:pt inRoot:win];
        if (deep) hit = deep;
    }
    self.hidden = NO;

    if (hit && hit != win) {
        [self.childHistory removeAllObjects];
        [self updateSelection:hit];
        UIImpactFeedbackGenerator *gen = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
        [gen impactOccurred];
    }
}

- (void)updateSelection:(UIView *)target {
    self.selectedTarget = target;
    if (!target || !target.window) {
        self.highlightBox.hidden = YES;
        self.infoLabel.text = @"未选中有效控件，请点击页面上的目标板块";
        return;
    }
    CGRect r = [target convertRect:target.bounds toView:self];
    self.highlightBox.frame = r;
    self.highlightBox.hidden = NO;

    NSString *cls = NSStringFromClass([target class]);
    NSString *parentCls = target.superview ? NSStringFromClass([target.superview class]) : @"无";
    NSMutableArray<NSString *> *texts = [NSMutableArray array];
    CollectTextsInSubtree(target, texts, 0);
    NSString *sampleText = texts.firstObject ? (CleanLabelText(texts.firstObject) ?: texts.firstObject) : @"无文字";
    if (sampleText.length > 14) sampleText = [[sampleText substringToIndex:14] stringByAppendingString:@"…"];

    self.infoLabel.text = [NSString stringWithFormat:@"选中: %@ (%.0f×%.0f) [%@]\n外层: %@",
                           cls, r.size.width, r.size.height, sampleText, parentCls];
}

- (void)onExpandParent {
    UIView *cur = self.selectedTarget;
    if (!cur || !cur.superview || [cur.superview isKindOfClass:[UIWindow class]]) return;
    [self.childHistory addObject:[NSValue valueWithNonretainedObject:cur]];
    [self updateSelection:cur.superview];
}

- (void)onShrinkChild {
    while (self.childHistory.count > 0) {
        UIView *prev = [self.childHistory.lastObject nonretainedObjectValue];
        [self.childHistory removeLastObject];
        if (prev && prev.window) {
            [self updateSelection:prev];
            return;
        }
    }
}

- (void)onToggleScrollMode {
    self.passThroughScrollMode = !self.passThroughScrollMode;
    if (self.passThroughScrollMode) {
        self.backgroundColor = [UIColor clearColor];
        self.highlightBox.hidden = YES;
        [self.modeBtn setTitle:@"🎯 切回瞄准" forState:UIControlStateNormal];
        self.modeBtn.backgroundColor = [UIColor systemGreenColor];
        self.infoLabel.text = @"👆 当前为【自由滑动模式】：可上下滑动或切页\n找到目标后点右下方【🎯 切回瞄准】即可框选！";
    } else {
        self.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.04];
        [self.modeBtn setTitle:@"👆 切滑动页面" forState:UIControlStateNormal];
        self.modeBtn.backgroundColor = [UIColor systemOrangeColor];
        if (self.selectedTarget) {
            [self updateSelection:self.selectedTarget];
        } else {
            self.infoLabel.text = @"🎯 已切回【瞄准模式】：请直接点击你想删掉的板块";
        }
    }
}

- (void)onHideSelected {
    UIView *target = self.selectedTarget;
    if (!target || !target.window) {
        self.infoLabel.text = @"⚠️ 请先点击屏幕选中一个红框区域再点隐藏！";
        return;
    }
    CGSize screenSz = UIScreen.mainScreen.bounds.size;
    if (target.bounds.size.width >= screenSz.width * 0.95 && target.bounds.size.height >= screenSz.height * 0.65) {
        self.infoLabel.text = @"⚠️ 红框包住了整个页面！请点【⬇️ 缩一层】缩小范围";
        return;
    }

    NSString *clsName = NSStringFromClass([target class]);
    BOOL isSys = IsSystemFrameworkViewClass(clsName);
    NSString *parentCls = target.superview ? NSStringFromClass([target.superview class]) : @"";
    NSString *zone = ZoneForViewInWindow(target, screenSz);

    NSMutableArray<NSString *> *texts = [NSMutableArray array];
    CollectTextsInSubtree(target, texts, 0);
    NSString *anchorText = @"";
    for (NSString *s in texts) {
        NSString *c = CleanLabelText(s);
        if (c.length >= 2) { anchorText = c; break; }
    }

    NSDictionary *rule = @{
        @"className": clsName,
        @"isSystem": @(isSys),
        @"parentClass": parentCls,
        @"zone": zone,
        @"anchorText": anchorText,
        @"w": @(round(target.bounds.size.width)),
        @"h": @(round(target.bounds.size.height))
    };

    NSMutableArray *rules = [NSMutableArray arrayWithArray:gCachedCustomRules ?: @[]];
    [rules addObject:rule];
    [[NSUserDefaults standardUserDefaults] setObject:rules forKey:kPrefCustomRulesArray];
    [[NSUserDefaults standardUserDefaults] synchronize];
    ReloadCustomRulesCache();

    UIView *superBar = target.superview;
    MarkForceHidden(target);
    CollapseContainerHeightForHiddenModule(target);
    if ([zone isEqualToString:@"bottom"] && superBar) {
        ScanAndRebalanceBottomBar(superBar);
    }

    self.highlightBox.hidden = YES;
    self.selectedTarget = nil;
    UIImpactFeedbackGenerator *gen = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    [gen impactOccurred];
    self.infoLabel.text = [NSString stringWithFormat:@"✅ 已隐藏 %@ 并记住！（长按底栏可随时恢复）", clsName];
}

- (void)onCopySelectedInfo {
    UIView *target = self.selectedTarget;
    if (!target || !target.window) {
        self.infoLabel.text = @"⚠️ 请先点中一个目标出现红框后再点复制！";
        return;
    }
    CGRect rInWin = [target convertRect:target.bounds toView:nil];
    NSMutableArray<NSString *> *chain = [NSMutableArray array];
    UIView *cur = target;
    for (int i = 0; i < 8 && cur && ![cur isKindOfClass:[UIWindow class]]; i++) {
        [chain addObject:[NSString stringWithFormat:@"%@(%.0fx%.0f)", NSStringFromClass([cur class]), cur.bounds.size.width, cur.bounds.size.height]];
        cur = cur.superview;
    }

    NSMutableArray<NSString *> *texts = [NSMutableArray array];
    CollectTextsInSubtree(target, texts, 0);
    NSString *joinedTexts = texts.count > 0 ? [[texts subarrayWithRange:NSMakeRange(0, MIN((NSUInteger)6, texts.count))] componentsJoinedByString:@" | "] : @"无";

    NSString *report = [NSString stringWithFormat:
        @"【UI瞄准报告】\n选中类名: %@\n屏幕坐标: x=%.0f, y=%.0f, w=%.0f, h=%.0f\n内部文字: %@\n层级链: %@",
        NSStringFromClass([target class]),
        rInWin.origin.x, rInWin.origin.y, rInWin.size.width, rInWin.size.height,
        joinedTexts,
        [chain componentsJoinedByString:@" -> "]];

    [UIPasteboard generalPasteboard].string = report;
    UIImpactFeedbackGenerator *gen = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    [gen impactOccurred];
    self.infoLabel.text = @"📋 控件结构报告已复制！直接粘贴发给助手即可！";
}

- (void)onCloseOverlay {
    gActiveOverlay = nil;
    [self removeFromSuperview];
}

@end

// =============================================================================
// Fine-Grained Native iOS Settings Table (UITableViewStyleInsetGrouped)
// =============================================================================
@interface UICleanerSettingsController : UIViewController <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSArray<NSDictionary *> *sections;
@end

@implementation UICleanerSettingsController

- (void)viewDidLoad {
    [super viewDidLoad];
    RegisterDefaultPrefs();
    self.title = @"界面精简设置";
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];

    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"关闭"
                                                                             style:UIBarButtonItemStylePlain
                                                                            target:self
                                                                            action:@selector(onCloseOnly)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"重启生效"
                                                                              style:UIBarButtonItemStyleDone
                                                                             target:self
                                                                             action:@selector(onSaveAndRestart)];
    self.navigationItem.rightBarButtonItem.tintColor = [UIColor systemRedColor];

    _sections = @[
        @{
            @"header": @"可视化工具",
            @"rows": @[
                @{@"type": @"action_aim",   @"title": @"🎯 开启「指哪打哪」瞄准器"},
                @{@"type": @"action_reset", @"title": @"🔄 清空手动点选隐藏记录"}
            ]
        },
        @{
            @"header": @"总控开关",
            @"rows": @[
                @{@"type": @"switch", @"key": kPrefMasterEnabled, @"title": @"启用全局界面精简"}
            ]
        },
        @{
            @"header": @"导航栏与页面布局",
            @"rows": @[
                @{@"type": @"switch", @"key": kPrefCleanTopBar,    @"title": @"顶栏：只留「推荐」并左对齐"},
                @{@"type": @"switch", @"key": kPrefCleanBottomBar, @"title": @"底栏：抹除关注 / 漫游 / 发现"},
                @{@"type": @"switch", @"key": kPrefCleanMyPage,    @"title": @"我的页：只留「音乐」板块"},
                @{@"type": @"switch", @"key": kPrefCleanSidebar,   @"title": @"侧边栏：抹除云贝 / 商城等推广"}
            ]
        },
        @{
            @"header": @"「推荐」页卡片细项",
            @"footer": @"修改开关后点右上角「重启生效」即可立即刷新全部页面。",
            @"rows": @[
                @{@"type": @"switch", @"key": kPrefFeedPlaylist,  @"title": @"隐藏「推荐歌单」"},
                @{@"type": @"switch", @"key": kPrefFeedRank,      @"title": @"隐藏「排行榜」"},
                @{@"type": @"switch", @"key": kPrefFeedAudioBook, @"title": @"隐藏「有声书 / 播客节目」"},
                @{@"type": @"switch", @"key": kPrefFeedCityHot,   @"title": @"隐藏「城市热门歌曲」"},
                @{@"type": @"switch", @"key": kPrefFeedArtistTry, @"title": @"隐藏「艺人新歌 / 金曲 / 猜你喜欢」"},
                @{@"type": @"switch", @"key": kPrefFeedLiveVideo, @"title": @"隐藏「直播 / 视频 / 演出」"}
            ]
        }
    ];

    _tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    _tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _tableView.dataSource = self;
    _tableView.delegate = self;
    _tableView.rowHeight = 48.0;
    [self.view addSubview:_tableView];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return (NSInteger)self.sections.count;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    NSArray *rows = self.sections[(NSUInteger)section][@"rows"];
    return (NSInteger)rows.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return self.sections[(NSUInteger)section][@"header"];
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return self.sections[(NSUInteger)section][@"footer"];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *row = self.sections[(NSUInteger)indexPath.section][@"rows"][(NSUInteger)indexPath.row];
    NSString *type = row[@"type"];

    if ([type isEqualToString:@"switch"]) {
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"SwitchCell"];
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"SwitchCell"];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            cell.textLabel.font = [UIFont systemFontOfSize:15.5 weight:UIFontWeightRegular];
        }
        NSString *key = row[@"key"];
        cell.textLabel.text = row[@"title"];
        cell.textLabel.textColor = [UIColor labelColor];

        UISwitch *sw = [[UISwitch alloc] init];
        sw.on = [[NSUserDefaults standardUserDefaults] boolForKey:key];
        sw.accessibilityIdentifier = key;
        [sw addTarget:self action:@selector(onSwitchToggled:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = sw;
        return cell;
    } else {
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"ActionCell"];
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"ActionCell"];
            cell.textLabel.font = [UIFont systemFontOfSize:15.5 weight:UIFontWeightSemibold];
        }
        cell.accessoryView = nil;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        if ([type isEqualToString:@"action_aim"]) {
            cell.textLabel.text = row[@"title"];
            cell.textLabel.textColor = [UIColor systemBlueColor];
            cell.detailTextLabel.text = @"点选隐藏";
        } else {
            cell.textLabel.text = row[@"title"];
            cell.textLabel.textColor = [UIColor labelColor];
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%lu 项", (unsigned long)gCachedCustomRules.count];
        }
        return cell;
    }
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *row = self.sections[(NSUInteger)indexPath.section][@"rows"][(NSUInteger)indexPath.row];
    NSString *type = row[@"type"];

    if ([type isEqualToString:@"action_aim"]) {
        [self dismissViewControllerAnimated:YES completion:^{
            ShowInspectorOverlay();
        }];
    } else if ([type isEqualToString:@"action_reset"]) {
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:kPrefCustomRulesArray];
        [[NSUserDefaults standardUserDefaults] synchronize];
        ReloadCustomRulesCache();
        UIWindow *win = ActiveKeyWindow();
        if (win) UnmarkAllForceHiddenInTree(win);
        UIImpactFeedbackGenerator *gen = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
        [gen impactOccurred];
        [tableView reloadData];
    }
}

- (void)onSwitchToggled:(UISwitch *)sender {
    NSString *key = sender.accessibilityIdentifier;
    if (key.length > 0) {
        [[NSUserDefaults standardUserDefaults] setBool:sender.isOn forKey:key];
        [[NSUserDefaults standardUserDefaults] synchronize];
        if ([key isEqualToString:kPrefMasterEnabled]) {
            [self.tableView reloadData];
        }
    }
}

- (void)onSaveAndRestart {
    [[NSUserDefaults standardUserDefaults] synchronize];
    UIImpactFeedbackGenerator *gen = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    [gen impactOccurred];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        exit(0);
    });
}

- (void)onCloseOnly {
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end

// Protect our own Settings & Inspector views from ever being touched by cleaner hooks!
static BOOL IsViewInsideCleanerUI(UIView *v) {
    if (!v) return NO;
    if (gActiveOverlay && (v == gActiveOverlay || [v isDescendantOfView:gActiveOverlay])) return YES;
    UIResponder *resp = v;
    for (int i = 0; i < 12 && resp; i++) {
        if ([resp isKindOfClass:[UICleanerSettingsController class]]) return YES;
        resp = [resp nextResponder];
    }
    return NO;
}

static UIWindow *ActiveKeyWindow(void) {
    UIWindow *bestKeyWin = nil;
    UIWindow *fallbackWin = nil;
    CGFloat minW = UIScreen.mainScreen.bounds.size.width * 0.85;
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]] &&
            (scene.activationState == UISceneActivationStateForegroundActive ||
             scene.activationState == UISceneActivationStateForegroundInactive)) {
            for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                if (w.hidden || w.alpha < 0.05 || !w.rootViewController || w.bounds.size.width < minW) continue;
                if (w.isKeyWindow) { bestKeyWin = w; break; }
                if (!fallbackWin) fallbackWin = w;
            }
            if (bestKeyWin) break;
        }
    }
    if (bestKeyWin) return bestKeyWin;
    if (fallbackWin) return fallbackWin;
    id<UIApplicationDelegate> appDel = [UIApplication sharedApplication].delegate;
    if ([appDel respondsToSelector:@selector(window)]) {
        return appDel.window;
    }
    return nil;
}

static void ShowInspectorOverlay(void) {
    if (gActiveOverlay) return;
    UIWindow *win = ActiveKeyWindow();
    if (!win) return;
    UICleanerInspectorOverlay *ov = [[UICleanerInspectorOverlay alloc] initWithFrame:win.bounds];
    gActiveOverlay = ov;
    [win addSubview:ov];
}

static UIViewController *TopMostViewController(void) {
    UIWindow *targetWin = ActiveKeyWindow();
    UIViewController *vc = targetWin.rootViewController;
    while (vc.presentedViewController) {
        vc = vc.presentedViewController;
    }
    return vc;
}

static void PresentCleanerSettingsSheet(void) {
    if (gActiveOverlay) {
        [gActiveOverlay removeFromSuperview];
        gActiveOverlay = nil;
    }
    UIViewController *topVC = TopMostViewController();
    if (!topVC) return;
    if ([topVC isKindOfClass:[UINavigationController class]] &&
        [((UINavigationController *)topVC).topViewController isKindOfClass:[UICleanerSettingsController class]]) {
        return;
    }

    UIImpactFeedbackGenerator *gen = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    [gen impactOccurred];

    UICleanerSettingsController *vc = [[UICleanerSettingsController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    if (@available(iOS 15.0, *)) {
        UISheetPresentationController *sheet = nav.sheetPresentationController;
        if (sheet) {
            sheet.detents = @[
                [UISheetPresentationControllerDetent mediumDetent],
                [UISheetPresentationControllerDetent largeDetent]
            ];
            sheet.prefersGrabberVisible = YES;
            sheet.preferredCornerRadius = 20.0;
        }
    }
    [topVC presentViewController:nav animated:YES completion:nil];
}

@interface UICleanerGestureHandler : NSObject <UIGestureRecognizerDelegate>
+ (instancetype)shared;
- (void)handleBottomLongPress:(UILongPressGestureRecognizer *)gr;
- (void)handleThreeFingerTap:(UITapGestureRecognizer *)gr;
@end

@implementation UICleanerGestureHandler

+ (instancetype)shared {
    static UICleanerGestureHandler *inst;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ inst = [[UICleanerGestureHandler alloc] init]; });
    return inst;
}

- (void)handleBottomLongPress:(UILongPressGestureRecognizer *)gr {
    if (gr.state == UIGestureRecognizerStateBegan) {
        PresentCleanerSettingsSheet();
    }
}

- (void)handleThreeFingerTap:(UITapGestureRecognizer *)gr {
    if (gr.state == UIGestureRecognizerStateEnded) {
        PresentCleanerSettingsSheet();
    }
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    if (gActiveOverlay) return NO;
    UIViewController *topVC = TopMostViewController();
    if ([topVC isKindOfClass:[UINavigationController class]] &&
        [((UINavigationController *)topVC).topViewController isKindOfClass:[UICleanerSettingsController class]]) {
        return NO;
    }
    if ([gestureRecognizer isKindOfClass:[UILongPressGestureRecognizer class]]) {
        UIView *v = gestureRecognizer.view;
        if (!v) return NO;
        CGPoint pt = [gestureRecognizer locationInView:v];
        return (pt.y >= v.bounds.size.height - 95.0);
    }
    return YES;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    return YES;
}

@end

static void AttachSettingsGesturesToWindow(UIWindow *win) {
    if (!win || objc_getAssociatedObject(win, kGestureAttachedKey)) return;
    objc_setAssociatedObject(win, kGestureAttachedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:[UICleanerGestureHandler shared] action:@selector(handleBottomLongPress:)];
    lp.minimumPressDuration = 0.55;
    lp.cancelsTouchesInView = NO;
    lp.delegate = [UICleanerGestureHandler shared];
    [win addGestureRecognizer:lp];

    UITapGestureRecognizer *tap3 = [[UITapGestureRecognizer alloc] initWithTarget:[UICleanerGestureHandler shared] action:@selector(handleThreeFingerTap:)];
    tap3.numberOfTouchesRequired = 3;
    tap3.numberOfTapsRequired = 1;
    tap3.cancelsTouchesInView = NO;
    [win addGestureRecognizer:tap3];
}

// =============================================================================
// Force-Hidden Lock & Dynamic Delegate Height Collapser
// =============================================================================
static void MarkForceHidden(UIView *v) {
    if (!v || IsViewInsideCleanerUI(v)) return;
    objc_setAssociatedObject(v, kForceHiddenViewKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    v.clipsToBounds = YES;
    if (!v.hidden) v.hidden = YES;
    if (v.alpha > 0.01) v.alpha = 0.0;
    v.userInteractionEnabled = NO;
}

static void UnmarkForceHidden(UIView *v) {
    if (!v) return;
    if (objc_getAssociatedObject(v, kForceHiddenViewKey)) {
        objc_setAssociatedObject(v, kForceHiddenViewKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        v.hidden = NO;
        v.alpha = 1.0;
        v.userInteractionEnabled = YES;
    }
}

static NSMutableSet<NSIndexPath *> *CollapsedPathsForScroll(UIScrollView *sv, BOOL create) {
    NSMutableSet<NSIndexPath *> *set = objc_getAssociatedObject(sv, kCollapsedPathsKey);
    if (!set && create) {
        set = [NSMutableSet set];
        objc_setAssociatedObject(sv, kCollapsedPathsKey, set, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return set;
}

static NSMutableSet<NSNumber *> *CollapsedSectionsForScroll(UIScrollView *sv, BOOL create) {
    NSMutableSet<NSNumber *> *set = objc_getAssociatedObject(sv, kCollapsedSectionsKey);
    if (!set && create) {
        set = [NSMutableSet set];
        objc_setAssociatedObject(sv, kCollapsedSectionsKey, set, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return set;
}

static void ClearCollapsedStateForScroll(UIScrollView *sv) {
    [CollapsedPathsForScroll(sv, NO) removeAllObjects];
    [CollapsedSectionsForScroll(sv, NO) removeAllObjects];
}

static void SwizzleTableViewDelegateClass(Class cls) {
    if (!cls || cls == [UICleanerSettingsController class]) return;
    static NSMutableSet<NSString *> *swizzled;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ swizzled = [NSMutableSet set]; });

    NSString *clsName = NSStringFromClass(cls);
    if ([swizzled containsObject:clsName]) return;
    [swizzled addObject:clsName];

    SEL rowSel = @selector(tableView:heightForRowAtIndexPath:);
    Method rowM = class_getInstanceMethod(cls, rowSel);
    if (rowM) {
        typedef CGFloat (*OrigRowFn)(id, SEL, UITableView *, NSIndexPath *);
        OrigRowFn origImp = (OrigRowFn)method_getImplementation(rowM);
        IMP newImp = imp_implementationWithBlock(^CGFloat(id _self, UITableView *tv, NSIndexPath *ip) {
            if (IsPrefOn(kPrefMasterEnabled) && ip && !IsViewInsideCleanerUI(tv)) {
                NSMutableSet *set = CollapsedPathsForScroll(tv, NO);
                if (set && [set containsObject:ip]) return 0.01;
            }
            return origImp(_self, rowSel, tv, ip);
        });
        if (!class_addMethod(cls, rowSel, newImp, method_getTypeEncoding(rowM))) {
            method_setImplementation(rowM, newImp);
        }
    } else {
        IMP newImp = imp_implementationWithBlock(^CGFloat(id _self, UITableView *tv, NSIndexPath *ip) {
            if (IsPrefOn(kPrefMasterEnabled) && ip && !IsViewInsideCleanerUI(tv)) {
                NSMutableSet *set = CollapsedPathsForScroll(tv, NO);
                if (set && [set containsObject:ip]) return 0.01;
            }
            return tv.rowHeight;
        });
        class_addMethod(cls, rowSel, newImp, "d@:@@");
    }

    SEL hdrSel = @selector(tableView:heightForHeaderInSection:);
    Method hdrM = class_getInstanceMethod(cls, hdrSel);
    if (hdrM) {
        typedef CGFloat (*OrigSecFn)(id, SEL, UITableView *, NSInteger);
        OrigSecFn origImp = (OrigSecFn)method_getImplementation(hdrM);
        IMP newImp = imp_implementationWithBlock(^CGFloat(id _self, UITableView *tv, NSInteger sec) {
            if (IsPrefOn(kPrefMasterEnabled) && !IsViewInsideCleanerUI(tv)) {
                NSMutableSet *secSet = CollapsedSectionsForScroll(tv, NO);
                if (secSet && [secSet containsObject:@(sec)]) return 0.01;
            }
            return origImp(_self, hdrSel, tv, sec);
        });
        if (!class_addMethod(cls, hdrSel, newImp, method_getTypeEncoding(hdrM))) {
            method_setImplementation(hdrM, newImp);
        }
    }

    SEL ftrSel = @selector(tableView:heightForFooterInSection:);
    Method ftrM = class_getInstanceMethod(cls, ftrSel);
    if (ftrM) {
        typedef CGFloat (*OrigSecFn)(id, SEL, UITableView *, NSInteger);
        OrigSecFn origImp = (OrigSecFn)method_getImplementation(ftrM);
        IMP newImp = imp_implementationWithBlock(^CGFloat(id _self, UITableView *tv, NSInteger sec) {
            if (IsPrefOn(kPrefMasterEnabled) && !IsViewInsideCleanerUI(tv)) {
                NSMutableSet *secSet = CollapsedSectionsForScroll(tv, NO);
                if (secSet && [secSet containsObject:@(sec)]) return 0.01;
            }
            return origImp(_self, ftrSel, tv, sec);
        });
        if (!class_addMethod(cls, ftrSel, newImp, method_getTypeEncoding(ftrM))) {
            method_setImplementation(ftrM, newImp);
        }
    }
}

static void SwizzleCollectionViewDelegateClass(Class cls) {
    if (!cls) return;
    static NSMutableSet<NSString *> *swizzled;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ swizzled = [NSMutableSet set]; });

    NSString *clsName = NSStringFromClass(cls);
    if ([swizzled containsObject:clsName]) return;
    [swizzled addObject:clsName];

    SEL szSel = @selector(collectionView:layout:sizeForItemAtIndexPath:);
    Method szM = class_getInstanceMethod(cls, szSel);
    if (szM) {
        typedef CGSize (*OrigSzFn)(id, SEL, UICollectionView *, UICollectionViewLayout *, NSIndexPath *);
        OrigSzFn origImp = (OrigSzFn)method_getImplementation(szM);
        IMP newImp = imp_implementationWithBlock(^CGSize(id _self, UICollectionView *cv, UICollectionViewLayout *layout, NSIndexPath *ip) {
            CGSize orig = origImp(_self, szSel, cv, layout, ip);
            if (IsPrefOn(kPrefMasterEnabled) && ip) {
                NSMutableSet *set = CollapsedPathsForScroll(cv, NO);
                if (set && [set containsObject:ip]) {
                    return CGSizeMake(MAX(orig.width, 1.0), 0.01);
                }
            }
            return orig;
        });
        if (!class_addMethod(cls, szSel, newImp, method_getTypeEncoding(szM))) {
            method_setImplementation(szM, newImp);
        }
    }

    SEL insSel = @selector(collectionView:layout:insetForSectionAtIndex:);
    Method insM = class_getInstanceMethod(cls, insSel);
    if (insM) {
        typedef UIEdgeInsets (*OrigInsFn)(id, SEL, UICollectionView *, UICollectionViewLayout *, NSInteger);
        OrigInsFn origImp = (OrigInsFn)method_getImplementation(insM);
        IMP newImp = imp_implementationWithBlock(^UIEdgeInsets(id _self, UICollectionView *cv, UICollectionViewLayout *layout, NSInteger sec) {
            if (IsPrefOn(kPrefMasterEnabled)) {
                NSMutableSet *secSet = CollapsedSectionsForScroll(cv, NO);
                if (secSet && [secSet containsObject:@(sec)]) return UIEdgeInsetsZero;
            }
            return origImp(_self, insSel, cv, layout, sec);
        });
        if (!class_addMethod(cls, insSel, newImp, method_getTypeEncoding(insM))) {
            method_setImplementation(insM, newImp);
        }
    }

    SEL hdrSel = @selector(collectionView:layout:referenceSizeForHeaderInSection:);
    Method hdrM = class_getInstanceMethod(cls, hdrSel);
    if (hdrM) {
        typedef CGSize (*OrigHdrFn)(id, SEL, UICollectionView *, UICollectionViewLayout *, NSInteger);
        OrigHdrFn origImp = (OrigHdrFn)method_getImplementation(hdrM);
        IMP newImp = imp_implementationWithBlock(^CGSize(id _self, UICollectionView *cv, UICollectionViewLayout *layout, NSInteger sec) {
            if (IsPrefOn(kPrefMasterEnabled)) {
                NSMutableSet *secSet = CollapsedSectionsForScroll(cv, NO);
                if (secSet && [secSet containsObject:@(sec)]) return CGSizeZero;
            }
            return origImp(_self, hdrSel, cv, layout, sec);
        });
        if (!class_addMethod(cls, hdrSel, newImp, method_getTypeEncoding(hdrM))) {
            method_setImplementation(hdrM, newImp);
        }
    }
}

static void CollapseContainerHeightForHiddenModule(UIView *moduleView) {
    if (!moduleView || IsViewInsideCleanerUI(moduleView)) return;
    UIView *parent = moduleView.superview;
    UIView *enclosingCell = moduleView;
    while (parent && ![parent isKindOfClass:[UITableView class]] && ![parent isKindOfClass:[UICollectionView class]]) {
        if ([parent isKindOfClass:[UITableViewCell class]] || [parent isKindOfClass:[UICollectionViewCell class]]) {
            enclosingCell = parent;
        }
        parent = parent.superview;
    }

    if ([parent isKindOfClass:[UITableView class]] && [enclosingCell isKindOfClass:[UITableViewCell class]] && enclosingCell == moduleView) {
        UITableView *tv = (UITableView *)parent;
        if (IsViewInsideCleanerUI(tv)) return;
        if (tv.delegate) SwizzleTableViewDelegateClass([tv.delegate class]);
        NSIndexPath *ip = [tv indexPathForCell:(UITableViewCell *)moduleView];
        if (!ip) return;

        NSMutableSet<NSIndexPath *> *set = CollapsedPathsForScroll(tv, YES);
        if (![set containsObject:ip]) {
            [set addObject:ip];
            if ([tv numberOfRowsInSection:ip.section] == 1) {
                [CollapsedSectionsForScroll(tv, YES) addObject:@(ip.section)];
            }
            if (!objc_getAssociatedObject(tv, kCollapsePendingFlagKey)) {
                objc_setAssociatedObject(tv, kCollapsePendingFlagKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                __weak UITableView *weakTV = tv;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    UITableView *strongTV = weakTV;
                    if (!strongTV) return;
                    objc_setAssociatedObject(strongTV, kCollapsePendingFlagKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                    [UIView performWithoutAnimation:^{
                        [strongTV beginUpdates];
                        [strongTV endUpdates];
                    }];
                });
            }
        }
    } else if ([parent isKindOfClass:[UICollectionView class]] && [enclosingCell isKindOfClass:[UICollectionViewCell class]] && enclosingCell == moduleView) {
        UICollectionView *cv = (UICollectionView *)parent;
        if (cv.bounds.size.height < 200.0) return;
        if (cv.delegate) SwizzleCollectionViewDelegateClass([cv.delegate class]);
        NSIndexPath *ip = [cv indexPathForCell:(UICollectionViewCell *)moduleView];
        if (!ip) return;

        NSMutableSet<NSIndexPath *> *set = CollapsedPathsForScroll(cv, YES);
        if (![set containsObject:ip]) {
            [set addObject:ip];
            if ([cv numberOfItemsInSection:ip.section] == 1) {
                [CollapsedSectionsForScroll(cv, YES) addObject:@(ip.section)];
            }
            if (!objc_getAssociatedObject(cv, kCollapsePendingFlagKey)) {
                objc_setAssociatedObject(cv, kCollapsePendingFlagKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                __weak UICollectionView *weakCV = cv;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    UICollectionView *strongCV = weakCV;
                    if (!strongCV) return;
                    objc_setAssociatedObject(strongCV, kCollapsePendingFlagKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                    [UIView performWithoutAnimation:^{
                        [strongCV.collectionViewLayout invalidateLayout];
                        [strongCV layoutIfNeeded];
                    }];
                });
            }
        }
    }
}

// =============================================================================
// Precision Component Cleaners (NMHomeTabbarView, NMTabBar, Sidebar, Feed)
// =============================================================================
static NSString *CleanLabelText(NSString *raw) {
    if (!raw || raw.length < 2 || raw.length > 48) return nil;
    static NSCharacterSet *trimSet;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        trimSet = [NSCharacterSet characterSetWithCharactersInString:@" \t\r\n>＞›》·•\uFFFC\u200B"];
    });
    NSString *cleaned = [raw stringByTrimmingCharactersInSet:trimSet];
    return cleaned.length >= 2 ? cleaned : nil;
}

static BOOL IsBottomBarBlockedText(NSString *raw) {
    if (!IsPrefOn(kPrefCleanBottomBar)) return NO;
    NSString *t = CleanLabelText(raw);
    if (!t) return NO;
    static NSSet<NSString *> *exactSet;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        exactSet = [NSSet setWithArray:@[
            @"关注", @"漫游", @"发现", @"动态", @"搜索", @"笔记", @"播客", @"听书", @"免费听"
        ]];
    });
    return [exactSet containsObject:t];
}

static BOOL IsMyPageSubTabBlockedText(NSString *raw) {
    if (!IsPrefOn(kPrefCleanMyPage) || !raw || raw.length < 2 || raw.length > 32) return NO;
    static NSCharacterSet *noiseSet;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        noiseSet = [NSCharacterSet characterSetWithCharactersInString:@" \t\r\n0123456789+·•>＞›》\uFFFC\u200B"];
    });
    NSString *s = [[raw componentsSeparatedByCharactersInSet:noiseSet] componentsJoinedByString:@""];
    if (s.length < 2) return NO;
    if ([[s stringByReplacingOccurrencesOfString:@"播客" withString:@""] length] == 0) return YES;
    if ([[s stringByReplacingOccurrencesOfString:@"笔记" withString:@""] length] == 0) return YES;
    return NO;
}

static BOOL IsSidebarRowBlockedText(NSString *raw) {
    if (!IsPrefOn(kPrefCleanSidebar) || !raw || raw.length < 2) return NO;
    static NSArray<NSString *> *sidebarBlocked;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sidebarBlocked = @[
            @"我的云贝",
            @"装扮中心",
            @"创作者中心",
            @"商城",
            @"云村有票",
            @"云推歌"
        ];
    });
    for (NSString *kw in sidebarBlocked) {
        if ([raw containsString:kw]) return YES;
    }
    return NO;
}

static BOOL IsFeedSectionBlockedText(NSString *raw) {
    NSString *cleaned = CleanLabelText(raw);
    if (!cleaned) return NO;

    if (IsPrefOn(kPrefFeedPlaylist)) {
        if ([cleaned isEqualToString:@"推荐歌单"] || (cleaned.length <= 8 && [cleaned hasPrefix:@"推荐歌单"])) {
            return YES;
        }
    }
    if (IsPrefOn(kPrefFeedRank)) {
        if ([cleaned isEqualToString:@"排行榜"] || (cleaned.length <= 8 && [cleaned hasSuffix:@"排行榜"])) {
            return YES;
        }
    }
    if (IsPrefOn(kPrefFeedAudioBook)) {
        for (NSString *kw in @[@"精品有声书", @"有声书", @"为你严选", @"热门节目", @"播客", @"有声剧", @"广播剧", @"听书"]) {
            if ([cleaned containsString:kw]) return YES;
        }
    }
    if (IsPrefOn(kPrefFeedCityHot)) {
        if ([cleaned containsString:@"最近的热门歌曲"]) return YES;
    }
    if (IsPrefOn(kPrefFeedArtistTry)) {
        for (NSString *kw in @[@"艺人新歌", @"喜爱的艺人", @"试试这些", @"你可能感兴趣的", @"艺人热门金曲", @"热门金曲"]) {
            if ([cleaned containsString:kw]) return YES;
        }
    }
    if (IsPrefOn(kPrefFeedLiveVideo)) {
        for (NSString *kw in @[@"直播", @"语音房", @"歌房", @"热门笔记", @"精选视频", @"音乐演出"]) {
            if ([cleaned containsString:kw]) return YES;
        }
    }
    return NO;
}

static void CollectTextsInSubtree(UIView *view, NSMutableArray<NSString *> *outTexts, int depth) {
    if (!view || depth > 6) return;
    if (view.accessibilityLabel.length >= 2 && view.accessibilityLabel.length <= 64) {
        [outTexts addObject:view.accessibilityLabel];
    }
    if ([view isKindOfClass:[UILabel class]]) {
        UILabel *lbl = (UILabel *)view;
        NSString *s = lbl.text ?: lbl.attributedText.string;
        if (s.length >= 2 && s.length <= 64) [outTexts addObject:s];
    } else if ([view isKindOfClass:[UIButton class]]) {
        UIButton *btn = (UIButton *)view;
        NSString *s = btn.currentTitle ?: [btn titleForState:UIControlStateNormal] ?: btn.titleLabel.text ?: btn.currentAttributedTitle.string;
        if (s.length >= 2 && s.length <= 64) [outTexts addObject:s];
    } else if ([view respondsToSelector:@selector(text)]) {
        @try {
            id val = [view valueForKey:@"text"];
            if ([val isKindOfClass:[NSString class]] && ((NSString *)val).length >= 2 && ((NSString *)val).length <= 64) {
                [outTexts addObject:(NSString *)val];
            }
        } @catch (__unused NSException *e) {}
    } else if ([NSStringFromClass([view class]) hasPrefix:@"RCT"]) {
        @try {
            Ivar ivar = class_getInstanceVariable([view class], "_textStorage");
            if (ivar) {
                id ts = object_getIvar(view, ivar);
                if ([ts isKindOfClass:[NSAttributedString class]]) {
                    NSString *s = ((NSAttributedString *)ts).string;
                    if (s.length >= 2 && s.length <= 64) [outTexts addObject:s];
                }
            }
        } @catch (__unused NSException *e) {}
    }

    if ([view.layer isKindOfClass:[CATextLayer class]]) {
        id str = ((CATextLayer *)view.layer).string;
        if ([str isKindOfClass:[NSString class]]) [outTexts addObject:str];
        else if ([str isKindOfClass:[NSAttributedString class]]) [outTexts addObject:((NSAttributedString *)str).string];
    }
    for (CALayer *subLayer in view.layer.sublayers) {
        if ([subLayer isKindOfClass:[CATextLayer class]]) {
            id str = ((CATextLayer *)subLayer).string;
            if ([str isKindOfClass:[NSString class]]) [outTexts addObject:str];
            else if ([str isKindOfClass:[NSAttributedString class]]) [outTexts addObject:((NSAttributedString *)str).string];
        }
    }

    for (UIView *sub in view.subviews) {
        CollectTextsInSubtree(sub, outTexts, depth + 1);
    }
}

// 1. Precision Top Bar Cleaner: NMHomeTabbarView -> UIScrollView(290x44)
// Keeps ONLY "推荐", wipes out 心动/音乐/播客/听书/免费听, and aligns "推荐" flush-left!
static void CleanAndLeftAlignHomeTopScrollView(UIScrollView *sv) {
    if (!sv || !IsPrefOn(kPrefCleanTopBar)) return;

    UIView *recommendItem = nil;
    UIView *indicatorLine = nil;
    NSMutableArray<UIView *> *otherTabItems = [NSMutableArray array];

    for (UIView *sub in sv.subviews) {
        CGSize sz = sub.bounds.size;
        if (sz.width <= 1.0 || sz.height <= 1.0) continue;

        // Detect underline selection indicator bar (thin bar <= 6pt tall, no text)
        NSMutableArray<NSString *> *texts = [NSMutableArray array];
        CollectTextsInSubtree(sub, texts, 0);

        if (texts.count == 0 && sz.height <= 6.5 && sz.width <= 48.0) {
            indicatorLine = sub;
            continue;
        }

        BOOL isRecommend = NO;
        for (NSString *s in texts) {
            NSString *c = CleanLabelText(s);
            if ([c isEqualToString:@"推荐"]) {
                isRecommend = YES;
                break;
            }
        }

        if (isRecommend) {
            recommendItem = sub;
        } else if (sz.height >= 16.0 && sz.width <= 130.0) {
            // Wipe out all other top bar items (心动, 音乐, 播客, 听书, 免费听, icons/capsules!)
            [otherTabItems addObject:sub];
        }
    }

    if (recommendItem) {
        for (UIView *other in otherTabItems) {
            MarkForceHidden(other);
        }
        sv.scrollEnabled = NO;
        if (sv.contentOffset.x != 0) {
            sv.contentOffset = CGPointZero;
        }
        // Align "推荐" flush-left inside NMHomeTabbarView's UIScrollView!
        CGRect rf = recommendItem.frame;
        if (fabs(rf.origin.x - 4.0) > 0.5) {
            rf.origin.x = 4.0;
            recommendItem.frame = rf;
        }
        if (indicatorLine) {
            CGRect indF = indicatorLine.frame;
            CGFloat targetIndX = CGRectGetMidX(recommendItem.frame) - indF.size.width * 0.5;
            if (fabs(indF.origin.x - targetIndX) > 0.5) {
                indF.origin.x = targetIndX;
                indicatorLine.frame = indF;
            }
        }
    }
}

static void CleanHomeTabbarContainer(UIView *homeTabbar) {
    if (!homeTabbar || !IsPrefOn(kPrefCleanTopBar)) return;
    for (UIView *sub in homeTabbar.subviews) {
        if ([sub isKindOfClass:[UIScrollView class]]) {
            CleanAndLeftAlignHomeTopScrollView((UIScrollView *)sub);
        }
        for (UIView *sub2 in sub.subviews) {
            if ([sub2 isKindOfClass:[UIScrollView class]]) {
                CleanAndLeftAlignHomeTopScrollView((UIScrollView *)sub2);
            }
        }
    }
}

// Find enclosing NMTabBar if view is anywhere inside NMTabBar's subtree
static UIView *EnclosingNMTabBar(UIView *v) {
    UIView *cur = v;
    for (int i = 0; i < 8 && cur; i++) {
        if (objc_getAssociatedObject(cur, kIsNMTabBarKey) ||
            [NSStringFromClass([cur class]) isEqualToString:@"NMTabBar"]) {
            objc_setAssociatedObject(cur, kIsNMTabBarKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            return cur;
        }
        cur = cur.superview;
    }
    return nil;
}

// Walk up from any matched text/button inside NMTabBar to its outermost single-tab slot (width <= 62% of bar)
static UIView *OutermostTabSlotInBar(UIView *node, UIView *barView, CGFloat barW) {
    UIView *slot = nil;
    UIView *cur = node;
    while (cur && cur != barView) {
        CGSize sz = cur.bounds.size;
        if (sz.width >= 18.0 && sz.width <= barW * 0.62 && sz.height >= 14.0 && sz.height <= 92.0) {
            slot = cur;
        } else if (sz.width > barW * 0.70) {
            break;
        }
        cur = cur.superview;
    }
    return slot;
}

static void DeepScanNMTabBarSubtreeForBlockedItems(UIView *node, UIView *barView, CGFloat barW, int depth) {
    if (!node || depth > 6) return;
    if (node != barView) {
        NSString *ownStr = nil;
        if (node.accessibilityLabel.length >= 2 && node.accessibilityLabel.length <= 16) {
            ownStr = node.accessibilityLabel;
        }
        if (ownStr && IsBottomBarBlockedText(ownStr)) {
            UIView *slot = OutermostTabSlotInBar(node, barView, barW);
            if (slot) MarkForceHidden(slot);
        }
        if ([node isKindOfClass:[UILabel class]]) {
            UILabel *lbl = (UILabel *)node;
            NSString *s = lbl.text ?: lbl.attributedText.string;
            if (IsBottomBarBlockedText(s)) {
                UIView *slot = OutermostTabSlotInBar(node, barView, barW);
                if (slot) MarkForceHidden(slot);
            }
        } else if ([node isKindOfClass:[UIButton class]]) {
            UIButton *btn = (UIButton *)node;
            NSString *s = btn.currentTitle ?: [btn titleForState:UIControlStateNormal] ?: btn.titleLabel.text;
            if (IsBottomBarBlockedText(s)) {
                UIView *slot = OutermostTabSlotInBar(node, barView, barW);
                if (slot) MarkForceHidden(slot);
            }
        } else if ([node respondsToSelector:@selector(text)]) {
            @try {
                id val = [node valueForKey:@"text"];
                if ([val isKindOfClass:[NSString class]] && IsBottomBarBlockedText(val)) {
                    UIView *slot = OutermostTabSlotInBar(node, barView, barW);
                    if (slot) MarkForceHidden(slot);
                }
            } @catch (__unused NSException *e) {}
        }
    }
    for (UIView *sub in [node.subviews copy]) {
        DeepScanNMTabBarSubtreeForBlockedItems(sub, barView, barW, depth + 1);
    }
}

static void RebalanceTabContainerRow(UIView *container, CGFloat barW) {
    NSMutableArray<UIView *> *visibleSlots = [NSMutableArray array];
    BOOL anyHidden = NO;

    for (UIView *sub in container.subviews) {
        CGSize sz = sub.bounds.size;
        // Recurse into full-width wrapper views inside NMTabBar (e.g. 390x49 visual content layer!)
        if (sz.width >= barW * 0.75 && sz.height >= 28.0 && sz.height <= 92.0) {
            RebalanceTabContainerRow(sub, sz.width);
            continue;
        }
        if (sz.width >= 32.0 && sz.width <= barW * 0.62 && sz.height >= 24.0 && sz.height <= 90.0) {
            NSNumber *lastCX = objc_getAssociatedObject(sub, kLastTabCenterXKey);
            NSNumber *origCX = objc_getAssociatedObject(sub, kOrigTabCenterXKey);
            if (!origCX || (lastCX && fabs(sub.center.x - [lastCX doubleValue]) > 1.0)) {
                objc_setAssociatedObject(sub, kOrigTabCenterXKey, @(sub.center.x), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }

            if (sub.hidden || sub.alpha < 0.05 || objc_getAssociatedObject(sub, kForceHiddenViewKey)) {
                anyHidden = YES;
            } else {
                // Only rebalance actual tab items (UIControl or views containing tab text/icons)
                NSMutableArray<NSString *> *texts = [NSMutableArray array];
                CollectTextsInSubtree(sub, texts, 0);
                if ([sub isKindOfClass:[UIControl class]] || texts.count > 0) {
                    [visibleSlots addObject:sub];
                }
            }
        }
    }

    if (!anyHidden || visibleSlots.count == 0) return;

    // Sort by original X and cluster overlapping layers (e.g. UITabBarButton + overlay UIButton at same X!)
    [visibleSlots sortUsingComparator:^NSComparisonResult(UIView *a, UIView *b) {
        CGFloat xa = [objc_getAssociatedObject(a, kOrigTabCenterXKey) doubleValue];
        CGFloat xb = [objc_getAssociatedObject(b, kOrigTabCenterXKey) doubleValue];
        return xa < xb ? NSOrderedAscending : NSOrderedDescending;
    }];

    NSMutableArray<NSMutableArray<UIView *> *> *columns = [NSMutableArray array];
    for (UIView *v in visibleSlots) {
        CGFloat vx = [objc_getAssociatedObject(v, kOrigTabCenterXKey) doubleValue];
        NSMutableArray<UIView *> *matchedCol = nil;
        for (NSMutableArray<UIView *> *col in columns) {
            CGFloat colX = [objc_getAssociatedObject(col.firstObject, kOrigTabCenterXKey) doubleValue];
            if (fabs(vx - colX) < 42.0) {
                matchedCol = col;
                break;
            }
        }
        if (!matchedCol) {
            matchedCol = [NSMutableArray array];
            [columns addObject:matchedCol];
        }
        [matchedCol addObject:v];
    }

    CGFloat slotW = barW / (CGFloat)columns.count;
    for (NSUInteger i = 0; i < columns.count; i++) {
        CGFloat targetX = slotW * ((CGFloat)i + 0.5);
        for (UIView *v in columns[i]) {
            CGPoint c = v.center;
            if (fabs(c.x - targetX) > 0.5) {
                c.x = targetX;
                v.center = c;
            }
            objc_setAssociatedObject(v, kLastTabCenterXKey, @(targetX), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
}

// 2. Precision Bottom Bar Cleaner: NMTabBar(390x83) -> kills BOTH visual & touch layers of "关注"
static void ScanAndRebalanceBottomBar(UIView *barView) {
    if (!barView || !barView.window || !IsPrefOn(kPrefCleanBottomBar) || IsViewInsideCleanerUI(barView)) return;
    if (gInsideNMTabBarRebalance) return;

    CGFloat barW = barView.bounds.size.width;
    if (barW < 200.0) return;

    gInsideNMTabBarRebalance = YES;
    objc_setAssociatedObject(barView, kIsNMTabBarKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    DeepScanNMTabBarSubtreeForBlockedItems(barView, barView, barW, 0);
    RebalanceTabContainerRow(barView, barW);

    gInsideNMTabBarRebalance = NO;
}

static void ScheduleNMTabBarRebalance(UIView *barView) {
    if (!barView || gInsideNMTabBarRebalance || !IsPrefOn(kPrefCleanBottomBar)) return;
    objc_setAssociatedObject(barView, kIsNMTabBarKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (objc_getAssociatedObject(barView, kNMTabBarRebalancePendKey)) return;
    objc_setAssociatedObject(barView, kNMTabBarRebalancePendKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    __weak UIView *weakBar = barView;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIView *strongBar = weakBar;
        if (!strongBar) return;
        objc_setAssociatedObject(strongBar, kNMTabBarRebalancePendKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ScanAndRebalanceBottomBar(strongBar);
    });
}

// 3. Precision React Native Sidebar Cleaner & Gap Compactor:
// RCTScrollContentView(312x734) -> RCTView(312x48) rows (我的云贝, 装扮中心, 创作者中心, 商城, 云村有票, 云推歌)
static void CleanAndCompactSidebarScrollContent(UIView *scrollContent) {
    if (!scrollContent || !IsPrefOn(kPrefCleanSidebar)) return;
    NSArray<UIView *> *subs = [scrollContent.subviews copy];
    if (subs.count < 2) return;

    // Step 1: Capture original React Yoga Y coordinates & mark blocked 48pt rows hidden
    for (UIView *row in subs) {
        NSNumber *lastShifted = objc_getAssociatedObject(row, kLastShiftedYKey);
        NSNumber *origYNum = objc_getAssociatedObject(row, kOrigYogaYKey);
        if (!origYNum || (lastShifted && fabs(row.frame.origin.y - [lastShifted doubleValue]) > 0.5)) {
            objc_setAssociatedObject(row, kOrigYogaYKey, @(row.frame.origin.y), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }

        CGSize rsz = row.bounds.size;
        if (!objc_getAssociatedObject(row, kForceHiddenViewKey) &&
            rsz.width >= scrollContent.bounds.size.width * 0.85 &&
            rsz.height >= 34.0 && rsz.height <= 70.0) {
            NSMutableArray<NSString *> *texts = [NSMutableArray array];
            CollectTextsInSubtree(row, texts, 0);
            for (NSString *s in texts) {
                if (IsSidebarRowBlockedText(s)) {
                    MarkForceHidden(row);
                    break;
                }
            }
        }
    }

    // Step 2: Sort by original Yoga Y and slide remaining rows smoothly upward to close gaps!
    NSArray<UIView *> *sorted = [subs sortedArrayUsingComparator:^NSComparisonResult(UIView *a, UIView *b) {
        CGFloat ya = [objc_getAssociatedObject(a, kOrigYogaYKey) doubleValue];
        CGFloat yb = [objc_getAssociatedObject(b, kOrigYogaYKey) doubleValue];
        return ya < yb ? NSOrderedAscending : (ya > yb ? NSOrderedDescending : NSOrderedSame);
    }];

    CGFloat collapsedHeight = 0.0;
    CGFloat maxBottom = 0.0;
    for (UIView *row in sorted) {
        CGFloat origY = [objc_getAssociatedObject(row, kOrigYogaYKey) doubleValue];
        if (objc_getAssociatedObject(row, kForceHiddenViewKey)) {
            collapsedHeight += row.bounds.size.height;
        } else {
            CGFloat targetY = origY - collapsedHeight;
            CGRect f = row.frame;
            if (fabs(f.origin.y - targetY) > 0.5) {
                f.origin.y = targetY;
                row.frame = f;
            }
            objc_setAssociatedObject(row, kLastShiftedYKey, @(targetY), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            CGFloat bot = targetY + f.size.height;
            if (bot > maxBottom) maxBottom = bot;
        }
    }

    if (collapsedHeight > 0 && [scrollContent.superview isKindOfClass:[UIScrollView class]]) {
        UIScrollView *sv = (UIScrollView *)scrollContent.superview;
        CGSize cs = sv.contentSize;
        if (maxBottom > 100.0 && cs.height > maxBottom + 32.0) {
            sv.contentSize = CGSizeMake(cs.width, maxBottom + 24.0);
        }
    }
}

static BOOL IsInsideVerticalFeedScrollView(UIView *view) {
    UIView *cur = view.superview;
    while (cur) {
        if ([cur isKindOfClass:[UIScrollView class]]) {
            CGSize sz = cur.bounds.size;
            if (sz.height > 220.0) {
                UIScrollView *sv = (UIScrollView *)cur;
                if ([sv isKindOfClass:[UITableView class]]) return YES;
                if (!sv.pagingEnabled && (sv.contentSize.height > sz.height * 1.05 || sv.alwaysBounceVertical)) {
                    return YES;
                }
            }
        }
        cur = cur.superview;
    }
    return NO;
}

static void HideFeedModuleForAnchorView(UIView *anchorView, NSString *rawTitle, CGSize screenSz) {
    if (!IsAnyFeedSubPrefOn() || IsViewInsideCleanerUI(anchorView)) return;
    NSString *cleanedTitle = CleanLabelText(rawTitle);
    if (!cleanedTitle) return;

    if ([cleanedTitle isEqualToString:@"排行榜"] && IsPrefOn(kPrefFeedRank)) {
        UIView *cur = anchorView.superview;
        for (int depth = 0; depth < 5 && cur; depth++) {
            CGSize sz = cur.bounds.size;
            if (sz.width >= 36.0 && sz.width <= screenSz.width * 0.32 &&
                sz.height >= 40.0 && sz.height <= 115.0 &&
                ([cur isKindOfClass:[UICollectionViewCell class]] || [cur isKindOfClass:[UIControl class]])) {
                if (cur.superview && cur.superview.bounds.size.height <= 135.0) {
                    MarkForceHidden(cur);
                    return;
                }
            }
            cur = cur.superview;
        }
    }

    CGRect anchorInWin = [anchorView convertRect:anchorView.bounds toView:nil];
    if (anchorInWin.origin.x > screenSz.width * 0.45) return;

    UIView *moduleView = nil;
    UIView *cur = anchorView.superview;
    for (int depth = 0; depth < 12 && cur; depth++) {
        CGSize sz = cur.bounds.size;
        if ([cur isKindOfClass:[UIScrollView class]] && sz.height > screenSz.height * 0.55) {
            break;
        }
        if (sz.width >= screenSz.width * 0.84 && sz.height >= 26.0 && sz.height <= screenSz.height * 0.90) {
            if ([cur isKindOfClass:[UITableViewCell class]] ||
                [cur isKindOfClass:[UICollectionViewCell class]] ||
                [cur isKindOfClass:[UICollectionReusableView class]]) {
                moduleView = cur;
            } else if (!moduleView && sz.height >= 85.0 &&
                       ([cur.superview isKindOfClass:[UIScrollView class]] ||
                        [cur.superview isKindOfClass:[UIStackView class]])) {
                moduleView = cur;
            }
        }
        cur = cur.superview;
    }

    if (!moduleView) return;

    CGRect anchorInMod = [anchorView convertRect:anchorView.bounds toView:moduleView];
    if (anchorInMod.origin.y > 115.0) return;

    MarkForceHidden(moduleView);
    CollapseContainerHeightForHiddenModule(moduleView);

    if (moduleView.bounds.size.height < 90.0 && moduleView.superview) {
        CGFloat headerBottom = CGRectGetMaxY(moduleView.frame);
        for (UIView *sib in moduleView.superview.subviews) {
            if (sib == moduleView) continue;
            if (sib.bounds.size.width >= screenSz.width * 0.84 &&
                sib.bounds.size.height >= 80.0 && sib.bounds.size.height <= 720.0 &&
                sib.frame.origin.y >= headerBottom - 12.0 &&
                sib.frame.origin.y <= headerBottom + 40.0) {
                MarkForceHidden(sib);
                CollapseContainerHeightForHiddenModule(sib);
            }
        }
    }
}

static void ScanFeedCellHeaderIfNeeded(UIView *cell) {
    if (!IsAnyFeedSubPrefOn() || !cell || !cell.window || IsViewInsideCleanerUI(cell)) return;
    if (objc_getAssociatedObject(cell, kForceHiddenViewKey)) {
        CollapseContainerHeightForHiddenModule(cell);
        return;
    }
    CGSize screenSz = UIScreen.mainScreen.bounds.size;
    if (screenSz.width <= 0 || cell.bounds.size.width < screenSz.width * 0.84) return;
    if (!IsInsideVerticalFeedScrollView(cell)) return;

    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:cell];
    int visited = 0;
    while (queue.count > 0 && visited < 130) {
        UIView *v = queue.firstObject;
        [queue removeObjectAtIndex:0];
        visited++;

        if (v != cell) {
            CGRect r = [v convertRect:v.bounds toView:cell];
            if (r.origin.y > 115.0) continue;

            NSMutableArray<NSString *> *localStrs = [NSMutableArray array];
            if (v.accessibilityLabel.length >= 2 && v.accessibilityLabel.length <= 64) {
                [localStrs addObject:v.accessibilityLabel];
            }
            if ([v isKindOfClass:[UILabel class]]) {
                UILabel *lbl = (UILabel *)v;
                NSString *s = lbl.text ?: lbl.attributedText.string;
                if (s.length >= 2) [localStrs addObject:s];
            } else if ([v isKindOfClass:[UIButton class]]) {
                UIButton *btn = (UIButton *)v;
                NSString *s = btn.currentTitle ?: btn.titleLabel.text ?: btn.currentAttributedTitle.string;
                if (s.length >= 2) [localStrs addObject:s];
            } else if ([v respondsToSelector:@selector(text)]) {
                @try {
                    id val = [v valueForKey:@"text"];
                    if ([val isKindOfClass:[NSString class]] && ((NSString *)val).length >= 2) {
                        [localStrs addObject:val];
                    }
                } @catch (__unused NSException *e) {}
            }
            if ([v.layer isKindOfClass:[CATextLayer class]]) {
                id str = ((CATextLayer *)v.layer).string;
                if ([str isKindOfClass:[NSString class]]) [localStrs addObject:str];
                else if ([str isKindOfClass:[NSAttributedString class]]) [localStrs addObject:((NSAttributedString *)str).string];
            }
            for (CALayer *subL in v.layer.sublayers) {
                if ([subL isKindOfClass:[CATextLayer class]]) {
                    id str = ((CATextLayer *)subL).string;
                    if ([str isKindOfClass:[NSString class]]) [localStrs addObject:str];
                    else if ([str isKindOfClass:[NSAttributedString class]]) [localStrs addObject:((NSAttributedString *)str).string];
                }
            }

            for (NSString *candidateStr in localStrs) {
                if (IsFeedSectionBlockedText(candidateStr)) {
                    HideFeedModuleForAnchorView(v, candidateStr, screenSz);
                    return;
                }
            }
        }
        for (UIView *sub in v.subviews) {
            [queue addObject:sub];
        }
    }
}

// "我的" Page Helpers: Center "音乐" in RCTView(390x48) & kill all horizontal swiping into 播客/笔记!
static BOOL IsMyPageMusicTabString(NSString *raw) {
    if (!raw || raw.length < 2 || raw.length > 32) return NO;
    static NSCharacterSet *noiseSet;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        noiseSet = [NSCharacterSet characterSetWithCharactersInString:@" \t\r\n0123456789+·•>＞›》\uFFFC\u200B"];
    });
    NSString *s = [[raw componentsSeparatedByCharactersInSet:noiseSet] componentsJoinedByString:@""];
    if (s.length < 2) return NO;
    return [[s stringByReplacingOccurrencesOfString:@"音乐" withString:@""] length] == 0;
}

static BOOL IsInsideMyPageScrollContent(UIView *v, CGFloat screenW) {
    UIView *cur = v.superview;
    for (int i = 0; i < 12 && cur; i++) {
        if ([NSStringFromClass([cur class]) isEqualToString:@"RCTScrollContentView"] &&
            cur.bounds.size.width >= screenW * 0.94) {
            return YES;
        }
        cur = cur.superview;
    }
    return NO;
}

static void CleanAndCenterMyPageTabBar(UIView *tabBar) {
    if (!tabBar || !tabBar.window || !IsPrefOn(kPrefCleanMyPage) || gInsideMyPageBarRebalance) return;
    CGFloat barW = tabBar.bounds.size.width;
    if (barW < 240.0) return;

    UIView *musicTab = nil;
    UIView *indicator = nil;
    NSMutableArray<UIView *> *blockedTabs = [NSMutableArray array];

    for (UIView *sub in tabBar.subviews) {
        CGSize sz = sub.bounds.size;
        if (sz.width <= 1.0 || sz.height <= 1.0) continue;

        NSMutableArray<NSString *> *texts = [NSMutableArray array];
        CollectTextsInSubtree(sub, texts, 0);

        if (texts.count == 0 && sz.height <= 8.0 && sz.width >= 8.0 && sz.width <= 80.0) {
            indicator = sub;
            continue;
        }

        if (sz.width >= 45.0 && sz.width <= barW * 0.48 && sz.height >= 24.0 && sz.height <= 60.0) {
            BOOL hitBlocked = NO;
            BOOL hitMusic = NO;
            for (NSString *s in texts) {
                if (IsMyPageSubTabBlockedText(s)) { hitBlocked = YES; break; }
                if (IsMyPageMusicTabString(s)) { hitMusic = YES; }
            }
            if (hitBlocked) {
                [blockedTabs addObject:sub];
            } else if (hitMusic) {
                musicTab = sub;
            }
        }
    }

    if (!musicTab && blockedTabs.count == 0) return;

    gInsideMyPageBarRebalance = YES;
    objc_setAssociatedObject(tabBar, kIsMyPageTabBarKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    for (UIView *b in blockedTabs) {
        MarkForceHidden(b);
    }

    if (musicTab) {
        CGFloat targetCenterX = barW * 0.5;
        CGPoint mc = musicTab.center;
        if (fabs(mc.x - targetCenterX) > 0.5) {
            mc.x = targetCenterX;
            musicTab.center = mc;
        }
        if (indicator) {
            CGPoint ic = indicator.center;
            if (fabs(ic.x - targetCenterX) > 0.5) {
                ic.x = targetCenterX;
                indicator.center = ic;
            }
        }
    }

    gInsideMyPageBarRebalance = NO;
}

static void ScheduleMyPageTabBarCenter(UIView *tabBar) {
    if (!tabBar || gInsideMyPageBarRebalance || !IsPrefOn(kPrefCleanMyPage)) return;
    if (objc_getAssociatedObject(tabBar, kMyPageTabBarPendKey)) return;
    objc_setAssociatedObject(tabBar, kMyPageTabBarPendKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    __weak UIView *weakBar = tabBar;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIView *strongBar = weakBar;
        if (!strongBar) return;
        objc_setAssociatedObject(strongBar, kMyPageTabBarPendKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        CleanAndCenterMyPageTabBar(strongBar);
    });
}

static void ApplyCustomUserRulesIfNeeded(UIView *view) {
    if (!view || !view.window || !IsPrefOn(kPrefMasterEnabled)) return;
    if (gCachedCustomRules.count == 0 || objc_getAssociatedObject(view, kForceHiddenViewKey)) return;
    if (IsViewInsideCleanerUI(view)) return;

    CGSize screenSz = UIScreen.mainScreen.bounds.size;
    CGSize sz = view.bounds.size;
    if (sz.width < 12.0 || sz.height < 12.0) return;
    if (sz.width >= screenSz.width * 0.95 && sz.height >= screenSz.height * 0.65) return;

    NSString *clsName = NSStringFromClass([view class]);
    for (NSDictionary *rule in gCachedCustomRules) {
        if (![clsName isEqualToString:rule[@"className"]]) continue;

        NSString *ruleZone = rule[@"zone"];
        NSString *curZone = ZoneForViewInWindow(view, screenSz);
        if (ruleZone.length > 0 && ![ruleZone isEqualToString:curZone]) continue;

        BOOL isSys = [rule[@"isSystem"] boolValue];
        NSString *anchorText = rule[@"anchorText"];
        CGFloat rw = [rule[@"w"] doubleValue];
        CGFloat rh = [rule[@"h"] doubleValue];

        if (anchorText.length > 0) {
            NSMutableArray<NSString *> *texts = [NSMutableArray array];
            CollectTextsInSubtree(view, texts, 0);
            BOOL textHit = NO;
            for (NSString *s in texts) {
                NSString *c = CleanLabelText(s);
                if (c && ([c isEqualToString:anchorText] || [c containsString:anchorText])) {
                    textHit = YES;
                    break;
                }
            }
            if (!textHit) continue;
        } else {
            NSString *parentCls = view.superview ? NSStringFromClass([view.superview class]) : @"";
            NSString *ruleParent = rule[@"parentClass"];
            if (isSys && ruleParent.length > 0 && ![parentCls isEqualToString:ruleParent]) continue;
            if (rw > 0 && rh > 0) {
                if (fabs(sz.width - rw) > MAX(rw * 0.35, 24.0) || fabs(sz.height - rh) > MAX(rh * 0.35, 24.0)) {
                    continue;
                }
            }
        }

        UIView *superBar = view.superview;
        MarkForceHidden(view);
        CollapseContainerHeightForHiddenModule(view);
        if ([curZone isEqualToString:@"bottom"] && superBar) {
            ScanAndRebalanceBottomBar(superBar);
        }
        return;
    }
}

static NSArray<UIViewController *> *FilterTabViewControllers(NSArray<UIViewController *> *vcs) {
    if (!IsPrefOn(kPrefCleanBottomBar) || vcs.count <= 1) return vcs;
    NSMutableArray<UIViewController *> *kept = [NSMutableArray arrayWithCapacity:vcs.count];
    for (UIViewController *vc in vcs) {
        if (IsBottomBarBlockedText(vc.tabBarItem.title) || IsBottomBarBlockedText(vc.title)) {
            continue;
        }
        [kept addObject:vc];
    }
    return kept.count > 0 ? [kept copy] : vcs;
}

typedef void (^UICleanerBatchBlock)(void);
typedef void (^UICleanerCompletionBlock)(BOOL);

// =============================================================================
// Direct Hooks (Exact Host Classes + Standard UIKit)
// =============================================================================
%group UICleanerHooks

// Exact Hook #1: NMTabBar(390x83) -> kills UIButton "关注" AFTER NMTabBar's own layout finishes!
%hook NMTabBar

- (void)layoutSubviews {
    %orig;
    ScanAndRebalanceBottomBar((UIView *)self);
}

%end

// Exact Hook #2: NMHomeTabbarView(290x44) -> keeps ONLY "推荐" and aligns it flush-left!
%hook NMHomeTabbarView

- (void)layoutSubviews {
    %orig;
    CleanHomeTabbarContainer((UIView *)self);
}

%end

%hook UIWindow

- (void)makeKeyAndVisible {
    %orig;
    AttachSettingsGesturesToWindow(self);
}

- (void)didAddSubview:(UIView *)subview {
    %orig(subview);
    AttachSettingsGesturesToWindow(self);
}

%end

%hook UIView

- (void)setHidden:(BOOL)hidden {
    if (!hidden && objc_getAssociatedObject(self, kForceHiddenViewKey)) {
        %orig(YES);
        return;
    }
    %orig(hidden);
}

- (void)setAlpha:(CGFloat)alpha {
    if (alpha > 0.01 && objc_getAssociatedObject(self, kForceHiddenViewKey)) {
        %orig(0.0);
        return;
    }
    %orig(alpha);
}

- (void)setFrame:(CGRect)frame {
    if (IsPrefOn(kPrefCleanMyPage) && self.window &&
        self.bounds.size.width >= UIScreen.mainScreen.bounds.size.width * 1.8 &&
        self.bounds.size.height >= 190.0 &&
        [NSStringFromClass([self class]) hasPrefix:@"RCT"] &&
        IsInsideMyPageScrollContent(self, UIScreen.mainScreen.bounds.size.width)) {
        frame.origin.x = 0.0;
    }
    %orig(frame);
    if (self.window) {
        if (!gInsideNMTabBarRebalance) {
            UIView *nmBar = EnclosingNMTabBar(self.superview);
            if (nmBar) ScheduleNMTabBarRebalance(nmBar);
        }
        if (!gInsideMyPageBarRebalance && self.superview && objc_getAssociatedObject(self.superview, kIsMyPageTabBarKey)) {
            ScheduleMyPageTabBarCenter(self.superview);
        }
    }
}

- (void)setCenter:(CGPoint)center {
    %orig(center);
    if (self.window) {
        if (!gInsideNMTabBarRebalance) {
            UIView *nmBar = EnclosingNMTabBar(self.superview);
            if (nmBar) ScheduleNMTabBarRebalance(nmBar);
        }
        if (!gInsideMyPageBarRebalance && self.superview && objc_getAssociatedObject(self.superview, kIsMyPageTabBarKey)) {
            ScheduleMyPageTabBarCenter(self.superview);
        }
    }
}

- (void)setTransform:(CGAffineTransform)transform {
    if (IsPrefOn(kPrefCleanMyPage) && self.window &&
        self.bounds.size.width >= UIScreen.mainScreen.bounds.size.width * 1.8 &&
        self.bounds.size.height >= 190.0 &&
        [NSStringFromClass([self class]) hasPrefix:@"RCT"] &&
        IsInsideMyPageScrollContent(self, UIScreen.mainScreen.bounds.size.width)) {
        transform.tx = 0.0;
    }
    %orig(transform);
}

- (void)didMoveToWindow {
    %orig;
    if (!self.window || IsViewInsideCleanerUI(self)) return;
    UIView *nmBar = EnclosingNMTabBar(self);
    if (nmBar) {
        ScheduleNMTabBarRebalance(nmBar);
    } else if ([NSStringFromClass([self class]) isEqualToString:@"NMHomeTabbarView"]) {
        CleanHomeTabbarContainer(self);
    }
}

- (void)setAccessibilityLabel:(NSString *)accessibilityLabel {
    %orig(accessibilityLabel);
    UIView *nmBar = EnclosingNMTabBar(self.superview);
    if (nmBar) {
        ScheduleNMTabBarRebalance(nmBar);
    }
}

- (void)layoutSubviews {
    %orig;
    if (!self.window || IsViewInsideCleanerUI(self)) return;

    if (gCachedCustomRules.count > 0) {
        ApplyCustomUserRulesIfNeeded(self);
    }

    CGSize sz = self.bounds.size;
    CGSize screenSz = UIScreen.mainScreen.bounds.size;
    if (screenSz.width <= 0) return;

    NSString *clsName = NSStringFromClass([self class]);

    // Direct runtime match on NMTabBar AND any button inside NMTabBar (works regardless of framework load order or layout timing!)
    if ([clsName isEqualToString:@"NMTabBar"]) {
        ScanAndRebalanceBottomBar(self);
        ScheduleNMTabBarRebalance(self);
        return;
    }
    if (self.superview && (objc_getAssociatedObject(self.superview, kIsNMTabBarKey) ||
                           [NSStringFromClass([self.superview class]) isEqualToString:@"NMTabBar"])) {
        ScheduleNMTabBarRebalance(self.superview);
    }

    if ([clsName isEqualToString:@"NMHomeTabbarView"]) {
        CleanHomeTabbarContainer(self);
        return;
    }

    // Also enforce left-align inside NMHomeTabbarView's UIScrollView whenever the UIScrollView itself layouts!
    if ([self isKindOfClass:[UIScrollView class]] && sz.height >= 28.0 && sz.height <= 60.0) {
        NSString *p1 = self.superview ? NSStringFromClass([self.superview class]) : @"";
        NSString *p2 = (self.superview && self.superview.superview) ? NSStringFromClass([self.superview.superview class]) : @"";
        if ([p1 isEqualToString:@"NMHomeTabbarView"] || [p2 isEqualToString:@"NMHomeTabbarView"]) {
            CleanAndLeftAlignHomeTopScrollView((UIScrollView *)self);
            return;
        }
    }

    // Catch GaiaX (GXRootView) async renders inside NMMixedLayoutDSLCell on Home "推荐" feed!
    if ([clsName isEqualToString:@"GXRootView"] || [clsName isEqualToString:@"NMMixedLayoutDSLCell"]) {
        UIView *cur = self;
        for (int i = 0; i < 5 && cur; i++) {
            if ([cur isKindOfClass:[UICollectionViewCell class]] || [cur isKindOfClass:[UITableViewCell class]]) {
                ScanFeedCellHeaderIfNeeded(cur);
                break;
            }
            cur = cur.superview;
        }
    }

    // Lock _UIQueuingScrollView (UIPageViewController) if inside React Native "我的" page!
    if (IsPrefOn(kPrefCleanMyPage) && [clsName isEqualToString:@"_UIQueuingScrollView"] &&
        sz.width >= screenSz.width * 0.90 && sz.height >= 190.0 &&
        IsInsideMyPageScrollContent(self, screenSz.width)) {
        UIScrollView *qsv = (UIScrollView *)self;
        qsv.scrollEnabled = NO;
        qsv.panGestureRecognizer.enabled = NO;
        return;
    }

    if ([clsName hasPrefix:@"RCT"]) {
        // 1. Left Sidebar Drawer: RCTScrollContentView (312pt on 390pt 13Pro, ~312-380pt on 430pt 15PM)
        if ([clsName isEqualToString:@"RCTScrollContentView"] &&
            sz.width >= screenSz.width * 0.55 && sz.width <= screenSz.width * 0.93) {
            CleanAndCompactSidebarScrollContent(self);
            return;
        }

        // 2. "我的" Page Sub-tab bar RCTView(390x48) -> wipe 播客/笔记 and center "音乐"!
        if (IsPrefOn(kPrefCleanMyPage)) {
            if (sz.width >= screenSz.width * 0.85 && sz.height >= 34.0 && sz.height <= 68.0 &&
                IsInsideMyPageScrollContent(self, screenSz.width)) {
                CleanAndCenterMyPageTabBar(self);
            } else if (sz.width >= 45.0 && sz.width <= screenSz.width * 0.48 &&
                       sz.height >= 24.0 && sz.height <= 60.0 &&
                       self.superview &&
                       self.superview.bounds.size.width >= screenSz.width * 0.85 &&
                       self.superview.bounds.size.height >= 34.0 &&
                       self.superview.bounds.size.height <= 68.0 &&
                       IsInsideMyPageScrollContent(self, screenSz.width)) {
                CleanAndCenterMyPageTabBar(self.superview);
            }

            // 3A. Lock ANY horizontal scroll/pager view on "我的" page (even if pagingEnabled == NO!)
            if ([self isKindOfClass:[UIScrollView class]] &&
                sz.width >= screenSz.width * 0.90 && sz.height >= 190.0 &&
                IsInsideMyPageScrollContent(self, screenSz.width)) {
                UIScrollView *sv = (UIScrollView *)self;
                if (sv.contentSize.width > sz.width * 1.25 || sv.pagingEnabled || sv.alwaysBounceHorizontal) {
                    objc_setAssociatedObject(sv, kLockMyPageHorizScrollKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                    if (sv.contentOffset.x != 0) {
                        [sv setContentOffset:CGPointMake(0, sv.contentOffset.y) animated:NO];
                    }
                    sv.scrollEnabled = NO;
                    sv.panGestureRecognizer.enabled = NO;
                    // Also wipe out Page 1 (播客) & Page 2 (笔记) subviews inside horizontal content!
                    for (UIView *pageSub in sv.subviews) {
                        for (UIView *leaf in pageSub.subviews) {
                            if (leaf.frame.origin.x >= sz.width * 0.85 && leaf.bounds.size.width >= sz.width * 0.80) {
                                MarkForceHidden(leaf);
                            }
                        }
                        if (pageSub.frame.origin.x >= sz.width * 0.85 && pageSub.bounds.size.width >= sz.width * 0.80) {
                            MarkForceHidden(pageSub);
                        }
                    }
                }
            }

            // 3B. Also lock 3x-width Animated/Gesture horizontal track RCTView (e.g. 1170pt wide) on "我的" page!
            if (sz.width >= screenSz.width * 1.8 && sz.height >= 190.0 &&
                IsInsideMyPageScrollContent(self, screenSz.width)) {
                for (UIGestureRecognizer *gr in self.gestureRecognizers) {
                    if ([gr isKindOfClass:[UIPanGestureRecognizer class]]) gr.enabled = NO;
                }
                if (self.superview) {
                    for (UIGestureRecognizer *gr in self.superview.gestureRecognizers) {
                        if ([gr isKindOfClass:[UIPanGestureRecognizer class]]) gr.enabled = NO;
                    }
                }
                for (UIView *page in self.subviews) {
                    if (page.frame.origin.x >= screenSz.width * 0.85) {
                        MarkForceHidden(page);
                    }
                }
            }
        }
    }
}

%end

%hook UITabBarController

- (void)setViewControllers:(NSArray<UIViewController *> *)viewControllers animated:(BOOL)animated {
    %orig(FilterTabViewControllers(viewControllers), animated);
}

- (void)setViewControllers:(NSArray<UIViewController *> *)viewControllers {
    %orig(FilterTabViewControllers(viewControllers));
}

%end

%hook UITabBar

- (void)layoutSubviews {
    %orig;
    ScanAndRebalanceBottomBar(self);
}

%end

%hook UIScrollView

- (void)setContentOffset:(CGPoint)contentOffset {
    if (IsPrefOn(kPrefCleanMyPage) && objc_getAssociatedObject(self, kLockMyPageHorizScrollKey)) {
        contentOffset.x = 0.0;
    }
    %orig(contentOffset);
}

- (void)setContentOffset:(CGPoint)contentOffset animated:(BOOL)animated {
    if (IsPrefOn(kPrefCleanMyPage) && objc_getAssociatedObject(self, kLockMyPageHorizScrollKey)) {
        contentOffset.x = 0.0;
    }
    %orig(contentOffset, animated);
}

%end

%hook UITableView

- (void)setDelegate:(id<UITableViewDelegate>)delegate {
    if (delegate && !IsViewInsideCleanerUI(self)) {
        SwizzleTableViewDelegateClass([delegate class]);
    }
    %orig(delegate);
}

- (void)reloadData {
    if (!IsViewInsideCleanerUI(self)) ClearCollapsedStateForScroll(self);
    %orig;
}

- (void)reloadSections:(NSIndexSet *)sections withRowAnimation:(UITableViewRowAnimation)animation {
    if (!IsViewInsideCleanerUI(self)) ClearCollapsedStateForScroll(self);
    %orig(sections, animation);
}

%end

%hook UICollectionView

- (void)setDelegate:(id<UICollectionViewDelegate>)delegate {
    if (delegate) {
        SwizzleCollectionViewDelegateClass([delegate class]);
    }
    %orig(delegate);
}

- (void)reloadData {
    ClearCollapsedStateForScroll(self);
    %orig;
}

- (void)reloadSections:(NSIndexSet *)sections {
    ClearCollapsedStateForScroll(self);
    %orig(sections);
}

- (void)performBatchUpdates:(UICleanerBatchBlock)updates completion:(UICleanerCompletionBlock)completion {
    ClearCollapsedStateForScroll(self);
    %orig(updates, completion);
}

%end

%hook UICollectionReusableView

- (void)prepareForReuse {
    UnmarkForceHidden(self);
    %orig;
}

- (void)applyLayoutAttributes:(UICollectionViewLayoutAttributes *)layoutAttributes {
    %orig(layoutAttributes);
    if (objc_getAssociatedObject(self, kForceHiddenViewKey)) {
        self.hidden = YES;
        self.alpha = 0.0;
        self.userInteractionEnabled = NO;
    }
}

%end

%hook UICollectionViewCell

- (void)layoutSubviews {
    %orig;
    if (self.window && !IsViewInsideCleanerUI(self)) {
        CGSize sz = self.bounds.size;
        CGSize screenSz = UIScreen.mainScreen.bounds.size;
        if (sz.width >= screenSz.width * 0.84) {
            ScanFeedCellHeaderIfNeeded(self);
        }
    }
}

%end

%hook UITableViewCell

- (void)prepareForReuse {
    if (!IsViewInsideCleanerUI(self)) UnmarkForceHidden(self);
    %orig;
}

- (void)layoutSubviews {
    %orig;
    if (self.window && !IsViewInsideCleanerUI(self)) {
        ScanFeedCellHeaderIfNeeded(self);
    }
}

%end

%hook UILabel

- (void)setText:(NSString *)text {
    %orig(text);
    if (IsViewInsideCleanerUI(self)) return;
    UIView *nmBar = EnclosingNMTabBar(self);
    if (nmBar) {
        ScheduleNMTabBarRebalance(nmBar);
        return;
    }
    if (IsFeedSectionBlockedText(text)) {
        objc_setAssociatedObject(self, kTrackedLabelAssocKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        __weak UILabel *weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            UILabel *s = weakSelf;
            if (s && s.window && !IsViewInsideCleanerUI(s)) {
                HideFeedModuleForAnchorView(s, s.text ?: s.attributedText.string, UIScreen.mainScreen.bounds.size);
            }
        });
    } else {
        objc_setAssociatedObject(self, kTrackedLabelAssocKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

- (void)setAttributedText:(NSAttributedString *)attributedText {
    %orig(attributedText);
    NSString *str = attributedText.string;
    if (!IsViewInsideCleanerUI(self) && IsFeedSectionBlockedText(str)) {
        objc_setAssociatedObject(self, kTrackedLabelAssocKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        __weak UILabel *weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            UILabel *s = weakSelf;
            if (s && s.window && !IsViewInsideCleanerUI(s)) {
                HideFeedModuleForAnchorView(s, s.text ?: s.attributedText.string, UIScreen.mainScreen.bounds.size);
            }
        });
    } else {
        objc_setAssociatedObject(self, kTrackedLabelAssocKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

- (void)layoutSubviews {
    %orig;
    if (self.window && objc_getAssociatedObject(self, kTrackedLabelAssocKey) && !IsViewInsideCleanerUI(self)) {
        HideFeedModuleForAnchorView(self, self.text ?: self.attributedText.string, UIScreen.mainScreen.bounds.size);
    }
}

%end

%end // group UICleanerHooks

%ctor {
    @autoreleasepool {
        // Guard against running inside non-UI extension processes (Widgets / Siri / Notification Service on 15PM!)
        NSString *bundlePath = [[NSBundle mainBundle] bundlePath] ?: @"";
        if ([bundlePath hasSuffix:@".appex"]) {
            return;
        }
        RegisterDefaultPrefs();
        // Activate unconditionally inside the main app bundle (even if personal-cert signing tools altered CFBundleShortVersionString!)
        %init(UICleanerHooks);
    }
}
