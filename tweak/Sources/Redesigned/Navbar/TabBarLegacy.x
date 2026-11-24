// Tab bar below iOS 26: Spotify's own bar stays in place but invisible, and a system UITabBar floats over it as a
// capsule with a selection pill, drag-to-switch and Create's menu. The capsule sits on SGGlassFor's pane, so it is
// legacy glass or the plain dark blur depending on the Legacy Liquid Glass switch (read once at launch).
//
// TabBar.x is the iOS 26 bar. The hooks here run only where SGRLegacyTabBarOn() says so and TabBar.x's do not,
// so exactly one of the two is ever in place. Reads of Spotify's own items are shared (Shared/Navigation/TabItems.h).
//
// The selection pill is SGRLegacyLens (TabBarLens.m): a finger on the bar lifts it into a glass bubble that follows the
// finger on springs, stretches with the move and settles on the tab it is let go over, as the system bar of iOS 26 does.
//
// A page scrolled down minimizes the bar to a circle with the open tab, a circle for the set-apart tab, and the
// now playing card between them. The last set-apart tab never sits on the capsule: it has its own round button
// at the trailing end. A tab picked here is passed on as a tap on the hidden Spotify item it mirrors, and
// Navbar.x composes that hidden row, so order, hidden tabs and the mod's own tabs carry over.
//
// View tree: NavigationUI_TabBarImpl.TabBarView > TabBarCompactView > UIStackView of
// ElementContentView<TabBarItemElement>, each with an SPTEncoreIconView and an SPTEncoreLabel.
#import "Core/SGCore.h"
#import "Navbar.h"
#import "TabBarLens.h"
#import "Redesigned/Kit/SGRGlass.h"
#import "Redesigned/Kit/SGRTokens.h"
#import "Redesigned/Kit/SGRAccent.h"
#import "Redesigned/NowPlayingBar/NowPlayingBar.h"
#import "Settings/SGPage.h"
#import "Shared/Navigation/TabItems.h"
#import "Headers/SPTEncoreIconView.h"
#import <objc/message.h>

static char kBarKey, kHostKey, kNavGlassKey, kNavTintKey, kSelPillKey, kRetriesKey, kGlyphOverlayKey, kOutlineLiveKey, kFilledLiveKey, kCreateDiscKey, kGlyphsTakenKey;
static char kCirclePaneKey, kCircleFilmKey, kLeadKey, kTrailKey, kTabColorKey, kTemplateKey;
// The bar is a floating capsule, not a full-width slab.
static const CGFloat kNavGlassMargin = 16;        // gap at each side
static const CGFloat kNavGlassBottomMargin = 8;   // gap under it, and over it to the now playing card
// The capsule itself, never the safe-area room under it: SGRTabBarGlassHeight() can be 83pt on a Face ID phone
// (harness/tabbar/README.md) because it includes the home-indicator strip. 64pt is Telegram's pill (a 56pt
// item row with 4pt inside, TabBarComponent.swift). Without labels it is shorter, and UIKit still lays the
// icon out as if one sat below it, so the icon is nudged down by kNavIconOnlyImageShift (the two are tuned
// together).
static const CGFloat kNavPlatterHeight = 64;
static const CGFloat kNavPlatterHeightIconOnly = 52;
static const CGFloat kNavIconOnlyImageShift = 6;
static const CGFloat kNavItemSpacing = 4;
static const CGFloat kNavCircleSide = 48;   // the compact bar's circles before the now playing card has a radius to follow
static const CGFloat kNavItemWidth = 90;    // fixed, so the capsule hugs its items instead of stretching them
static const CGFloat kSelPillInset = 3;     // gap between the selection pill and the capsule's edge
static const CGFloat kLensOverhang = 3;     // how far the held bubble stands out of the capsule's rim, above and below
static __weak UIView *sg_stockBar;
// See "compact". The circles' frames in the host's coordinates, the trailing one empty when no tab is set apart.
static BOOL sg_minimized;
static CGRect sg_leadFrame, sg_trailFrame;

// Telegram's TabSelectionRecognizer: Began the instant a finger lands (no distance or duration threshold), Changed on
// every move after, so the bubble follows the finger from the first frame.
@interface SGRLegacyTabDragRecognizer : UIGestureRecognizer
@property (nonatomic) CGPoint currentLocation;
@property (nonatomic) BOOL moved;
@end

@implementation SGRLegacyTabDragRecognizer

- (instancetype)initWithTarget:(id)target action:(SEL)action {
    self = [super initWithTarget:target action:action];
    if (self) {
        self.delaysTouchesBegan = NO;
        self.delaysTouchesEnded = NO;
        // UITabBar's own tap handling must not race this recognizer for the same touch.
        self.cancelsTouchesInView = YES;
    }
    return self;
}

- (void)reset {
    [super reset];
    self.moved = NO;
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesBegan:touches withEvent:event];
    self.currentLocation = [touches.anyObject locationInView:self.view];
    self.state = UIGestureRecognizerStateBegan;
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesMoved:touches withEvent:event];
    self.currentLocation = [touches.anyObject locationInView:self.view];
    self.moved = YES;
    self.state = UIGestureRecognizerStateChanged;
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesEnded:touches withEvent:event];
    self.currentLocation = [touches.anyObject locationInView:self.view];
    self.state = UIGestureRecognizerStateEnded;
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesCancelled:touches withEvent:event];
    self.state = UIGestureRecognizerStateCancelled;
}

@end

@interface SGRLegacyTabBar : UITabBar <UITabBarDelegate, UIGestureRecognizerDelegate>
@property (nonatomic, weak) UIView *stockBar;
@property (nonatomic, copy) NSArray<UIView *> *sources;
// The tab set apart (Split tabs), on its own round button and not on the capsule: Spotify's view of it and the
// item that stands for it (never one of `items`), and whether its page is the open one, in which case the
// capsule has no selection.
@property (nonatomic, weak) UIView *apartSource;
@property (nonatomic, strong) UITabBarItem *apartItem;
@property (nonatomic) BOOL apartSelected;
// A short bar (SGRLegacyFoldLimit tabs or fewer) holds the split tab in the capsule while it is expanded, and the
// round button shows only when it is minimized. `apartItem` is then the capsule's own item for it (one of `items`),
// the capsule's selection says whether its page is open (apartSelected stays NO), and lastLeadItem is the tab the
// leading circle falls back to while that item is the open one.
@property (nonatomic) BOOL folded;
@property (nonatomic, weak) UITabBarItem *lastLeadItem;
@property (nonatomic, weak) UILongPressGestureRecognizer *hold;
@property (nonatomic, weak) UIGestureRecognizer *drag;
@property (nonatomic) BOOL holding;
// The last tab actually navigated to. Never Create, which opens a menu and no page, so the selection can
// always go back to this.
@property (nonatomic, weak) UITabBarItem *lastRealItem;
// The tab selected when the touch began: a release on it is a tap (or a there-and-back drag) and bumps the icon
// instead of moving the pill.
@property (nonatomic, weak) UITabBarItem *gestureStartItem;
// The Spotify tab open when Create was tapped, compared with the open one once the menu closes to tell whether the
// menu navigated. Also kept by name: Spotify rebuilds its items while the menu is up.
@property (nonatomic, weak) UIView *sourceBeforeCreate;
@property (nonatomic, copy) NSString *labelBeforeCreate;
@property (nonatomic) BOOL awaitingCreateClose;
@end

static void syncBar(UIView *stockBar);
// For a change of Spotify's selected controller from outside our bar (a link, the side drawer). Every other caller
// uses syncBar, which trusts lastRealItem: Spotify's label colors never clear for a tab the mod added, so
// rescanning them would snap the selection back to the old tab.
static void syncBarExternalChange(UIView *stockBar);
static void syncBarCore(UIView *stockBar, BOOL rescanSelection);
static void followCreateClose(UIView *stockBar);

#pragma mark - the compact bar's circles

static UIColor *openTabColor(void);
static BOOL tintedTabs(void);

// The disc's mask with the plus cut out of it, turned as the open plus is: the disc in the accent shows the glass
// through the plus, the way it looked before Tabs in the accent, rather than a plus of its own on top.
static CALayer *discHole(UIImage *glyph, CGFloat size) {
    if (!glyph || size < 1) return nil;
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.opaque = NO;
    UIImage *mask = [[[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(size, size) format:format] imageWithActions:^(UIGraphicsImageRendererContext *context) {
        CGContextRef c = context.CGContext;
        [UIColor.whiteColor setFill];
        CGContextFillEllipseInRect(c, CGRectMake(0, 0, size, size));
        CGContextTranslateCTM(c, size / 2, size / 2);
        CGContextRotateCTM(c, M_PI_4);
        CGSize g = glyph.size;
        [glyph drawInRect:CGRectMake(-g.width / 2, -g.height / 2, g.width, g.height) blendMode:kCGBlendModeDestinationOut alpha:1];
    }];
    CALayer *layer = [CALayer layer];
    layer.frame = CGRectMake(0, 0, size, size);
    layer.contents = (__bridge id)mask.CGImage;
    return layer;
}

// Create's menu open: its plus turns 45 degrees, black, onto a white disc that grows in behind it; closed, back again.
// With Tabs in the accent the disc is the accent's and the plus is cut out of it.
static void turnCreate(UIView *disc, UIView *glyph, BOOL open) {
    UIColor *accent = openTabColor();
    BOOL tinted = tintedTabs();
    disc.backgroundColor = tinted ? accent : UIColor.whiteColor;
    UIImage *image = [glyph isKindOfClass:UIImageView.class] ? ((UIImageView *)glyph).image : nil;
    disc.layer.mask = tinted ? discHole(image, disc.bounds.size.width) : nil;
    [UIView animateWithDuration:0.32 delay:0 usingSpringWithDamping:0.8 initialSpringVelocity:0
        options:UIViewAnimationOptionBeginFromCurrentState animations:^{
        disc.alpha = open ? 1 : 0;
        disc.transform = open ? CGAffineTransformIdentity : CGAffineTransformMakeScale(0.4, 0.4);
        glyph.transform = open ? CGAffineTransformMakeRotation(M_PI_4) : CGAffineTransformIdentity;
        glyph.tintColor = open ? UIColor.blackColor : accent;
        glyph.alpha = open && tinted ? 0 : 1;
    } completion:nil];
}

// Create's menu dims the page behind the bar, and the bar reads best then: the glass carries that dimming itself,
// always (SGRDarkenGlass).
static char kNavDimKey, kCircleDimKey;

// A round control of the compact bar: a glass circle with one tab's glyph on it. The glass is SGGlassFor's, so
// it is a legacy glass pane with Legacy Liquid Glass on and a plain blur without it, and comes and goes by its
// effect (SGRShowGlass), never by an alpha on the control, which UIKit draws a blur wrongly under. The control
// is scaled while it is away, so it grows in as the bar minimizes; its size and place are set by bounds and
// center, since a frame is undefined under a transform.
@interface SGRLegacyCircle : UIControl
@property (nonatomic, strong, readonly) UIImageView *glyph;
@property (nonatomic, copy) void (^onTap)(void);
// The tab the circle stands for, and whether that is Create.
@property (nonatomic, weak) UITabBarItem *item;
@property (nonatomic) BOOL holdsCreate;
// Shows or hides the circle; asked for inside an animation it moves in that animation.
- (void)setShown:(BOOL)shown;
// The circle while the capsule's own glass stands in its place, rolling out of it or back into it (placeCompact): no glass
// of its own, full size, its glyph at `alpha`. Counts as hidden, so a setShown:YES after it brings the glass back.
- (void)holdGlyphOnly:(CGFloat)alpha;
// Create's menu open: the plus turns 45 degrees onto a white disc, as on the capsule's own Create button.
- (void)setCreateOpen:(BOOL)open;
@end

@implementation SGRLegacyCircle {
    UIView *_pane;
    UIView *_film;
    UIView *_disc;
    BOOL _shown, _configured, _open;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    _pane = SGGlassFor(self, &kCirclePaneKey);
    _pane.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    SGGlassInteractive(self, _pane);
    _film = SGRGlassFilm(self, &kCircleFilmKey, _pane, 0);
    _glyph = [UIImageView new];
    _glyph.userInteractionEnabled = NO;
    _glyph.contentMode = UIViewContentModeCenter;
    _glyph.tintColor = UIColor.whiteColor;
    [self addSubview:_glyph];
    self.isAccessibilityElement = YES;
    self.accessibilityTraits = UIAccessibilityTraitButton;
    [self addTarget:self action:@selector(tapped) forControlEvents:UIControlEventTouchUpInside];
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect bounds = self.bounds;
    // A true circle: the circular corner curve, not the continuous one the capsule's ends and the now playing
    // card have, which on a square draws a squircle.
    CGFloat radius = MIN(bounds.size.width, bounds.size.height) / 2;
    if (!CGRectEqualToRect(_pane.frame, bounds)) _pane.frame = bounds;
    SGShapeGlass(_pane, radius, YES);
    _pane.layer.cornerCurve = kCACornerCurveCircular;
    SGRDarkenGlass(_pane, &kCircleDimKey, radius, SGRBarDim);
    SGRGlassFilm(self, &kCircleFilmKey, _pane, radius).layer.cornerCurve = kCACornerCurveCircular;
    // bounds and center, not frame: the glyph is turned while Create's menu is up.
    _glyph.bounds = (CGRect){CGPointZero, bounds.size};
    _glyph.center = CGPointMake(CGRectGetMidX(bounds), CGRectGetMidY(bounds));
    if (_disc) {
        CGFloat size = MIN(round(_glyph.image.size.height * 4.0 / 3.0), bounds.size.height - 8);
        _disc.bounds = CGRectMake(0, 0, size, size);
        _disc.layer.cornerRadius = size / 2;
        _disc.center = _glyph.center;
    }
}

- (void)setShown:(BOOL)shown {
    if (_configured && _shown == shown) return;
    _configured = YES;
    _shown = shown;
    SGRShowGlass(_pane, shown);
    _film.alpha = shown ? 1 : 0;
    _glyph.alpha = shown ? 1 : 0;
    self.transform = shown ? CGAffineTransformIdentity : CGAffineTransformMakeScale(0.6, 0.6);
    self.userInteractionEnabled = shown;
    if (!shown) [self setCreateOpen:NO];
}

- (void)holdGlyphOnly:(CGFloat)alpha {
    _configured = YES;
    _shown = NO;
    SGRShowGlass(_pane, NO);
    _film.alpha = 0;
    _glyph.alpha = alpha;
    self.transform = CGAffineTransformIdentity;
    self.userInteractionEnabled = NO;
}

- (void)setCreateOpen:(BOOL)open {
    if (_open == open || (open && !_shown)) return;
    _open = open;
    if (!_disc) {
        _disc = [[UIView alloc] initWithFrame:CGRectZero];
        _disc.userInteractionEnabled = NO;
        _disc.backgroundColor = UIColor.whiteColor;
        _disc.alpha = 0;
        _disc.transform = CGAffineTransformMakeScale(0.4, 0.4);
        [self insertSubview:_disc belowSubview:_glyph];
    }
    [self setNeedsLayout];
    [self layoutIfNeeded];
    turnCreate(_disc, _glyph, open);
}

- (void)tapped {
    if (self.onTap) self.onTap();
}

@end

#pragma mark - reading Spotify's items

// The tab that stands on the round button of its own: the last one set apart. With nothing but split tabs the
// bar has one group and no tab is apart (Navbar.x), so then there is none.
static UIView *trailingSource(NSArray<UIView *> *items) {
    UIView *trail = nil;
    NSUInteger apartCount = 0;
    for (UIView *item in items) {
        if (!SGRTabIsApart(item)) continue;
        trail = item;
        apartCount++;
    }
    return apartCount >= items.count ? nil : trail;
}

// Create pushes no screen, it only pops a menu open, so it is never the bar's real selected tab. The row's items are
// ElementContentView wrappers with CreateMenuTabBarItemView two levels down, so the subtree is searched.
static BOOL isCreateSource(UIView *source) {
    if (!source) return NO;
    __block BOOL found = NO;
    SGForEachView(source, ^(UIView *v) {
        if (found) return;
        found = [NSStringFromClass(v.class) containsString:@"CreateMenuTabBarItemView"] || [v.accessibilityIdentifier isEqualToString:@"TabBar.Item.Create"];
    });
    return found;
}

// The Spotify tab whose page is open (its label is white), never Create. Nil when that tab is hidden from the bar.
static UIView *activeStockSource(UIView *stockBar) {
    for (UIView *item in tabItems(stockBar)) {
        if (!isCreateSource(item) && isActive(item)) return item;
    }
    return nil;
}

// The outline and filled pictures of a tab, from Spotify's icon view, which draws only one. isActive is flipped,
// the other state drawn and isActive put back inside one runloop turn, so nothing reaches the screen.
static void captureGlyphs(UIView *live, UITabBarItem *item) {
    if (![live respondsToSelector:@selector(isActive)] || ![live respondsToSelector:@selector(setIsActive:)]) return;
    SPTEncoreIconView *view = (SPTEncoreIconView *)live;
    CGSize size = live.bounds.size;
    BOOL was = [view isActive];
    UIImage *now = renderLayer(live.layer, size);
    [view setIsActive:!was];
    [view layoutIfNeeded];
    [live.layer displayIfNeeded];
    UIImage *other = renderLayer(live.layer, size);
    [view setIsActive:was];
    [view layoutIfNeeded];
    if (!now || !other || [UIImagePNGRepresentation(now) isEqualToData:UIImagePNGRepresentation(other)]) return;
    item.image = was ? other : now;
    item.selectedImage = was ? now : other;
    objc_setAssociatedObject(item, &kFilledLiveKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(item, &kOutlineLiveKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// Both pictures of a tab. Create has no filled variant, so it takes each state's picture from the live view the
// first time it is seen in that state.
static void learnGlyphs(UIView *source, UITabBarItem *item) {
    UIView *live = iconIn(source);
    if (!live || live.bounds.size.width < 2) return;
    CGSize size = live.bounds.size;
    if (!item.image) item.image = renderLayer(live.layer, size);
    if (!item.selectedImage) item.selectedImage = renderLayer(live.layer, size);
    if (!objc_getAssociatedObject(item, &kGlyphsTakenKey)) {
        objc_setAssociatedObject(item, &kGlyphsTakenKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        captureGlyphs(live, item);
    }
    BOOL active = [live respondsToSelector:@selector(isActive)] ? [(SPTEncoreIconView *)live isActive] : isActive(source);
    const void *key = active ? &kFilledLiveKey : &kOutlineLiveKey;
    if (objc_getAssociatedObject(item, key)) return;
    UIImage *seen = renderLayer(live.layer, size);
    if (!seen) return;
    objc_setAssociatedObject(item, key, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (active) item.selectedImage = seen; else item.image = seen;
}

#pragma mark - taps

// A tap that ends on the tab already open moves no pill, so the icon pulses instead.
static void bumpIcon(UITabBar *bar, UITabBarItem *item) {
    if (!item) return;
    __block UIView *iconView = nil;
    SGForEachView(bar, ^(UIView *v) {
        if (iconView || v.hidden || ![v isKindOfClass:UIImageView.class]) return;
        UIImage *image = ((UIImageView *)v).image;
        if (image && (image == item.image || image == item.selectedImage)) iconView = v;
    });
    if (!iconView) return;
    // One keyframe timeline: two chained animations differ in velocity where they hand off and read as a jerk.
    [UIView animateKeyframesWithDuration:0.26 delay:0 options:UIViewKeyframeAnimationOptionCalculationModeCubic animations:^{
        [UIView addKeyframeWithRelativeStartTime:0 relativeDuration:0.4 animations:^{
            iconView.transform = CGAffineTransformMakeScale(1.12, 1.12);
        }];
        [UIView addKeyframeWithRelativeStartTime:0.4 relativeDuration:0.6 animations:^{
            iconView.transform = CGAffineTransformIdentity;
        }];
    } completion:nil];
}

// The bar's UITabBarButtons, left to right, which is the order of its items.
static NSArray<UIView *> *tabButtons(UITabBar *bar) {
    NSMutableArray<UIView *> *buttons = [NSMutableArray array];
    for (UIView *v in bar.subviews) {
        if ([NSStringFromClass(v.class) isEqualToString:@"UITabBarButton"]) [buttons addObject:v];
    }
    [buttons sortUsingComparator:^NSComparisonResult(UIView *a, UIView *b) {
        return [@(a.frame.origin.x) compare:@(b.frame.origin.x)];
    }];
    return buttons;
}

// setItems: can leave a button behind for an item that is gone (a second, unplaced "Your Library" after the tab
// list was rebuilt twice during launch). Every live item owns one button, its "view", so any other is a leftover.
// Only acts once every item has its button, so a bar still being built is never stripped.
static void pruneStrayButtons(UITabBar *bar) {
    NSMutableSet<UIView *> *owned = [NSMutableSet set];
    for (UITabBarItem *item in bar.items) {
        id view = nil;
        @try {
            view = [item valueForKey:@"view"];
        } @catch (NSException *e) {
            return;
        }
        if ([view isKindOfClass:UIView.class]) [owned addObject:view];
    }
    if (!bar.items.count || owned.count != bar.items.count) return;
    for (UIView *v in tabButtons(bar)) {
        if (![owned containsObject:v]) [v removeFromSuperview];
    }
}

// The tabs' color: the accent with Tabs in the accent on (SGRKeyTabAccent), else white. Every tab takes it; the open
// one stands out by its filled glyph, as it does in white.
static BOOL tintedTabs(void) {
    return SGFlag(SGRKeyTabAccent, NO);
}

static UIColor *openTabColor(void) {
    return tintedTabs() ? SGRAccent() : UIColor.whiteColor;
}

// The bar's appearance, every tab in openTabColor, set again only when that changes: with an appearance set, tintColor
// alone does not decide the colors.
static void applyTabColors(UITabBar *bar) {
    UIColor *open = openTabColor();
    if ([objc_getAssociatedObject(bar, &kTabColorKey) isEqual:open]) return;
    objc_setAssociatedObject(bar, &kTabColorKey, open, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    UITabBarAppearance *appearance = [UITabBarAppearance new];
    [appearance configureWithTransparentBackground];
    for (UITabBarItemAppearance *layout in @[appearance.stackedLayoutAppearance, appearance.inlineLayoutAppearance, appearance.compactInlineLayoutAppearance]) {
        layout.normal.iconColor = open;
        layout.normal.titleTextAttributes = @{NSForegroundColorAttributeName: open};
        layout.selected.iconColor = open;
        layout.selected.titleTextAttributes = @{NSForegroundColorAttributeName: open};
    }
    bar.standardAppearance = appearance;
    bar.scrollEdgeAppearance = appearance;
}

// `image` as a template, made once per image, for an overlay that takes the open tab's color: Spotify's glyphs are
// bitmaps rendered white (renderLayer), whose alpha is the glyph.
static UIImage *templateOf(UIImage *image) {
    UIImage *made = objc_getAssociatedObject(image, &kTemplateKey);
    if (!made) {
        made = [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
        objc_setAssociatedObject(image, &kTemplateKey, made, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return made;
}

// UITabBar does not repaint an icon between its outline and filled bitmaps when the selection changes on this bar,
// so each item's glyph is drawn by an image view of ours laid over UIKit's in the item's button (selectedImage on
// the selected item, image on the rest) and UIKit's is hidden. Run from layout and the selection setter.
static void paintGlyphs(UITabBar *bar) {
    NSArray<UITabBarItem *> *items = bar.items;
    NSArray<UIView *> *buttons = tabButtons(bar);
    if (!items.count || buttons.count != items.count) return;
    applyTabColors(bar);
    UIColor *open = openTabColor();
    BOOL tinted = tintedTabs();
    for (NSUInteger i = 0; i < items.count; i++) {
        UITabBarItem *item = items[i];
        UIView *button = buttons[i];
        UIImageView *overlay = objc_getAssociatedObject(button, &kGlyphOverlayKey);
        UIImageView *native = nil;
        for (UIView *v in button.subviews) {
            if (v != overlay && [v isKindOfClass:UIImageView.class] && v.bounds.size.width >= 2) { native = (UIImageView *)v; break; }
        }
        BOOL selected = item == bar.selectedItem;
        UIImage *want = (selected && item.selectedImage) ? item.selectedImage : item.image;
        // Create is selected while its menu is up, but is no tab to open: turnCreate draws it then.
        BOOL create = [bar isKindOfClass:SGRLegacyTabBar.class] && i < ((SGRLegacyTabBar *)bar).sources.count
            && isCreateSource(((SGRLegacyTabBar *)bar).sources[i]);
        if (want && tinted) want = templateOf(want);
        if (!native || !want) {
            overlay.hidden = YES;
            continue;
        }
        if (!overlay) {
            overlay = [UIImageView new];
            overlay.userInteractionEnabled = NO;
            overlay.contentMode = UIViewContentModeCenter;
            overlay.tintColor = UIColor.whiteColor;
            objc_setAssociatedObject(button, &kGlyphOverlayKey, overlay, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        if (overlay.superview != button) [button addSubview:overlay];
        // bounds + center, not frame: the overlay of Create is rotated while its menu is up, and assigning
        // a frame to a transformed view scrambles it.
        CGRect nativeFrame = native.frame;
        CGPoint nativeCenter = CGPointMake(CGRectGetMidX(nativeFrame), CGRectGetMidY(nativeFrame));
        if (!CGSizeEqualToSize(overlay.bounds.size, nativeFrame.size)) overlay.bounds = (CGRect){CGPointZero, nativeFrame.size};
        if (!CGPointEqualToPoint(overlay.center, nativeCenter)) overlay.center = nativeCenter;
        if (overlay.image != want) overlay.image = want;
        // Every pass, every tab, so a switch of the setting reaches them all. Create's plus while its menu is up (turned
        // on its disc) is turnCreate's.
        UIColor *tint = open;
        BOOL createOpen = create && !CGAffineTransformIsIdentity(overlay.transform);
        if (!createOpen && ![overlay.tintColor isEqual:tint]) overlay.tintColor = tint;
        overlay.hidden = NO;
        // The name under it too: UIKit does not repaint it from the appearance as the selection changes on this bar,
        // any more than it does the icon, so it stayed white under an accent icon.
        for (UIView *v in button.subviews) {
            if (![v isKindOfClass:UILabel.class]) continue;
            UILabel *name = (UILabel *)v;
            if (![name.textColor isEqual:tint]) name.textColor = tint;
        }
        native.hidden = YES;
    }
}

// Spotify's own Create item turns its plus onto a white disc while the menu is open (turnCreate). That runs on the
// hidden stock view, so the glass bar does the same on its own Create button.
static void setCreateOpen(SGRLegacyTabBar *bar, BOOL open) {
    // Create on the apart tab's own button: that button does it, and the capsule has no Create.
    if (bar.apartSource && isCreateSource(bar.apartSource) && (!bar.folded || sg_minimized)) {
        UIView *stock = bar.stockBar;
        UIView *barHost = stock ? objc_getAssociatedObject(stock, &kHostKey) : nil;
        SGRLegacyCircle *trail = barHost ? objc_getAssociatedObject(barHost, &kTrailKey) : nil;
        [trail setCreateOpen:open];
        return;
    }
    NSUInteger index = NSNotFound;
    for (NSUInteger i = 0; i < bar.sources.count; i++) {
        if (isCreateSource(bar.sources[i])) { index = i; break; }
    }
    if (index == NSNotFound || index >= bar.items.count) return;
    NSArray<UIView *> *buttons = tabButtons(bar);
    if (buttons.count != bar.items.count) return;
    UIView *button = buttons[index];
    UIImageView *overlay = objc_getAssociatedObject(button, &kGlyphOverlayKey);
    if (!overlay) return;
    UIView *disc = objc_getAssociatedObject(button, &kCreateDiscKey);
    if (!disc) {
        disc = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 40, 40)];
        disc.userInteractionEnabled = NO;
        disc.backgroundColor = UIColor.whiteColor;
        disc.layer.cornerRadius = 20;
        disc.alpha = 0;
        objc_setAssociatedObject(button, &kCreateDiscKey, disc, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (disc.superview != button) [button insertSubview:disc belowSubview:overlay];
    // Sized from the icon it sits behind (a third bigger), so it stays inside the pill with or without labels.
    CGFloat discSize = round(overlay.bounds.size.height * 4.0 / 3.0);
    if (fabs(disc.bounds.size.width - discSize) > 0.5) {
        disc.bounds = CGRectMake(0, 0, discSize, discSize);
        disc.layer.cornerRadius = discSize / 2;
    }
    disc.center = overlay.center;
    if ((disc.alpha > 0.5) == open && (open || CGAffineTransformIsIdentity(overlay.transform))) return;
    if (open) disc.transform = CGAffineTransformMakeScale(0.4, 0.4);
    turnCreate(disc, overlay, open);
}

#pragma mark - the system bar

@implementation SGRLegacyTabBar

- (void)layoutSubviews {
    [super layoutSubviews];
    pruneStrayButtons(self);
    paintGlyphs(self);
    // The pill can be placed before UIKit has put the buttons where they end up, so every pass re-checks it.
    SGRLegacyLens *pill = [self lens];
    CGFloat centerX = pill && !pill.hidden ? [self renderedCenterXForItem:self.selectedItem] : NAN;
    CGRect rest = pill.restFrame;
    if (!isnan(centerX) && rest.size.width > 0) {
        CGFloat wantX = self.frame.origin.x + centerX - rest.size.width / 2;
        if (fabs(rest.origin.x - wantX) > 0.5) {
            rest.origin.x = wantX;
            [pill setRestFrame:rest animated:YES];
        }
    }
}

// The centers of the first and the last tab in the host's coordinates: how far the bubble may run under a finger.
- (void)trackBoundsMin:(CGFloat *)minCenter max:(CGFloat *)maxCenter {
    CGFloat a = [self renderedCenterXForItem:self.items.firstObject];
    CGFloat b = [self renderedCenterXForItem:self.items.lastObject];
    CGFloat x = self.frame.origin.x;
    *minCenter = isnan(a) ? -CGFLOAT_MAX : x + a;
    *maxCenter = isnan(b) ? CGFLOAT_MAX : x + b;
}

- (SGRLegacyLens *)lens {
    UIView *stock = self.stockBar;
    UIView *host = stock ? objc_getAssociatedObject(stock, &kHostKey) : nil;
    return host ? objc_getAssociatedObject(host, &kSelPillKey) : nil;
}

- (void)setSelectedItem:(UITabBarItem *)item {
    if (item) self.apartSelected = NO;
    [super setSelectedItem:item];
    paintGlyphs(self);
}

- (void)rememberOpenTab {
    UIView *stockBar = self.stockBar;
    self.sourceBeforeCreate = stockBar ? activeStockSource(stockBar) : nil;
    self.labelBeforeCreate = labelIn(self.sourceBeforeCreate).text;
}

- (void)tabBar:(UITabBar *)tabBar didSelectItem:(UITabBarItem *)item {
    NSUInteger index = [self.items indexOfObject:item];
    if (index == NSNotFound || index >= self.sources.count) return;
    UIView *source = self.sources[index];
    if (isCreateSource(source)) {
        // The pill sits on Create while the menu is up and goes back to lastRealItem once it is gone.
        UIView *stockBar = self.stockBar;
        [self rememberOpenTab];
        forwardTap(source);
        // The apart tab stays the open one while Create's menu is up over it.
        BOOL apartSelected = self.apartSelected;
        self.selectedItem = item;
        self.apartSelected = apartSelected;
        setCreateOpen(self, YES);
        if (stockBar) {
            followCreateClose(stockBar);
            syncBar(stockBar);
        }
        // UIKit can still snap selectedItem back on the next runloop turn, so assert it once more.
        __weak typeof(self) weakSelf = self;
        __weak UIView *weakStock = stockBar;
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            UIView *stock = weakStock;
            if (!strongSelf || !stock) return;
            if (strongSelf.selectedItem != item) {
                strongSelf.selectedItem = item;
                syncBar(stock);
            }
        });
        return;
    }
    self.lastRealItem = item;
    // Home tapped while on Home pops Spotify's stack, which would take Mod Settings straight off it.
    if (!self.holding) forwardTap(source);
    // Spotify repaints its labels a moment later; a tap it did not take snaps the selection back.
    UIView *stockBar = self.stockBar;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (stockBar) syncBar(stockBar);
    });
}

// The apart tab's round button tapped, as the capsule's own tap would be: Create pops its menu, any other tab is
// opened and the capsule gives up its selection.
- (void)tapApart {
    UIView *source = self.apartSource;
    UIView *stockBar = self.stockBar;
    if (!source) return;
    if (isCreateSource(source)) {
        [self rememberOpenTab];
        forwardTap(source);
        setCreateOpen(self, YES);
        if (stockBar) followCreateClose(stockBar);
        return;
    }
    self.apartSelected = YES;
    self.selectedItem = nil;
    forwardTap(source);
    if (!stockBar) return;
    syncBar(stockBar);
    // Spotify repaints its labels a moment later.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        syncBar(stockBar);
    });
}

// UIKit's item views are private: the item under a touch is the one whose title label or glyph is nearest.
- (UITabBarItem *)itemAt:(CGPoint)point {
    __block UITabBarItem *nearest = nil;
    __block CGFloat best = CGFLOAT_MAX;
    SGForEachView(self, ^(UIView *v) {
        BOOL label = [v isKindOfClass:UILabel.class], glyph = [v isKindOfClass:UIImageView.class];
        if ((!label && !glyph) || v.bounds.size.width < 1) return;
        CGFloat distance = fabs([v convertPoint:CGPointMake(CGRectGetMidX(v.bounds), 0) toView:self].x - point.x);
        if (distance >= best) return;
        for (UITabBarItem *item in self.items) {
            UIImage *image = glyph ? ((UIImageView *)v).image : nil;
            if (label ? ![((UILabel *)v).text isEqualToString:item.title] : !image || (image != item.image && image != item.selectedImage)) continue;
            best = distance;
            nearest = item;
            break;
        }
    });
    return nearest;
}

// The item's on-screen x-center, read from its rendered button (or icon and label), since UIKit's layout does not
// match a width/spacing formula. NAN when the item's views are not in the hierarchy yet.
- (CGFloat)renderedCenterXForItem:(UITabBarItem *)item {
    if (!item) return NAN;
    NSUInteger index = [self.items indexOfObject:item];
    NSArray<UIView *> *buttons = tabButtons(self);
    if (index != NSNotFound && buttons.count == self.items.count && buttons.count) {
        if (buttons[index].bounds.size.width > 1) return CGRectGetMidX(buttons[index].frame);
    }
    __block CGRect unionFrame = CGRectNull;
    SGForEachView(self, ^(UIView *v) {
        BOOL label = [v isKindOfClass:UILabel.class], glyph = [v isKindOfClass:UIImageView.class];
        if ((!label && !glyph) || v.bounds.size.width < 1) return;
        if (glyph) {
            UIImage *image = ((UIImageView *)v).image;
            if (!image || (image != item.image && image != item.selectedImage)) return;
        } else if (!item.title.length || ![((UILabel *)v).text isEqualToString:item.title]) {
            return;
        }
        CGRect frame = [v convertRect:v.bounds toView:self];
        unionFrame = CGRectIsNull(unionFrame) ? frame : CGRectUnion(unionFrame, frame);
    });
    return CGRectIsNull(unionFrame) ? NAN : CGRectGetMidX(unionFrame);
}

// UIView asks itself this for its own recognizers too, so only the hold is answered here.
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)recognizer {
    if (recognizer != self.hold) return [super gestureRecognizerShouldBegin:recognizer];
    NSUInteger index = [self.items indexOfObject:[self itemAt:[recognizer locationInView:self]]];
    return index < self.sources.count && isHome(self.sources[index], self.stockBar);
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)recognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    return YES;
}

- (void)held:(UILongPressGestureRecognizer *)hold {
    if (hold.state == UIGestureRecognizerStateBegan) {
        self.holding = YES;
        SGOpenModSettings(self);
    } else if (hold.state != UIGestureRecognizerStateChanged) {
        // The bar may still pick Home as the finger lifts, after this.
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            weakSelf.holding = NO;
        });
    }
}

// The selection is the nearest tab at every touch update; release switches Spotify's content like a plain tap.
- (void)dragged:(SGRLegacyTabDragRecognizer *)g {
    UIView *stockBar = self.stockBar;
    UITabBarItem *item = [self itemAt:g.currentLocation];
    NSUInteger itemIndex = item ? [self.items indexOfObject:item] : NSNotFound;
    BOOL itemIsCreate = itemIndex != NSNotFound && itemIndex < self.sources.count && isCreateSource(self.sources[itemIndex]);

    if (g.state == UIGestureRecognizerStateBegan) {
        self.gestureStartItem = self.selectedItem;
    }

    if (g.state == UIGestureRecognizerStateBegan || g.state == UIGestureRecognizerStateChanged) {
        // syncBar here, or the pill only moves on some later Spotify event.
        if (item && !itemIsCreate && item != self.selectedItem) {
            self.selectedItem = item;
            if (stockBar) syncBar(stockBar);
        }
        // The bubble follows the finger from the first frame, over whatever tab it is on.
        SGRLegacyLens *lens = [self lens];
        CGFloat hostX = self.frame.origin.x + g.currentLocation.x;
        if (g.state == UIGestureRecognizerStateBegan) {
            CGFloat lo, hi;
            [self trackBoundsMin:&lo max:&hi];
            [lens beginTouchAtX:hostX minCenter:lo maxCenter:hi];
        } else {
            [lens moveTouchToX:hostX];
        }
    } else if (g.state == UIGestureRecognizerStateEnded) {
        // Create is selected before the bubble is let go, so it settles on Create and not back on the open tab.
        if (itemIsCreate && !self.apartSelected) {
            self.selectedItem = item;
            if (stockBar) syncBar(stockBar);
        }
        // Let go first, so the bubble's run is on screen before the tab starts loading.
        [[self lens] endTouch];
        [[self lens] flush];
        if (item) {
            if (!itemIsCreate && item != self.selectedItem) {
                self.selectedItem = item;
                if (stockBar) syncBar(stockBar);
            }
            [self tabBar:self didSelectItem:item];
            if (item == self.gestureStartItem) bumpIcon(self, item);
        } else if (stockBar) {
            syncBar(stockBar);
        }
        self.gestureStartItem = nil;
    } else if (g.state == UIGestureRecognizerStateCancelled) {
        [[self lens] endTouch];
        if (stockBar) syncBar(stockBar);
        self.gestureStartItem = nil;
    }
}

@end

// The system bar's view in Spotify's bar. UIKit sizes the bar by the safe area of the view it stands in, and the
// room made under Spotify's bar is not the phone's, so this hands the bar the safe area without the room.
@interface SGRLegacyTabBarHost : UIView
@end

@implementation SGRLegacyTabBarHost
- (UIEdgeInsets)safeAreaInsets {
    UIEdgeInsets insets = [super safeAreaInsets];
    // The host stands kNavGlassBottomMargin above the real safe area, which UITabBar would read as extra
    // home-indicator padding and push the icons off-centre, so it is cancelled out.
    insets.bottom = MAX(0, insets.bottom - SGRTabBarRoom() - kNavGlassBottomMargin);
    return insets;
}

// Minimized, the host still spans the screen, and its bare part between the circles is where the now playing
// card stands: a touch there goes on to the card instead of stopping here.
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    return sg_minimized && hit == self ? nil : hit;
}
@end

#pragma mark - room for the glass bar

// The room itself is TabBarRoom.m's, shared with TabBar.x.
static void makeRoom(UIViewController *container) {
    UIView *stockBar = sg_stockBar;
    SGRMakeTabBarRoom(container, stockBar, stockBar ? objc_getAssociatedObject(stockBar, &kBarKey) : nil);
}

// Create's menu closing is not announced (it pushes nothing), so it is polled for: the menu itself, or anything
// presented over the container, so one changed id does not stop it from ever firing. The presentation is asked first,
// as it costs nothing.
static BOOL createMenuIsUp(UIView *stockBar) {
    return containerOf(stockBar).presentedViewController != nil || SGRCreateMenuUp(stockBar);
}

// Once the menu is gone the selection follows Spotify if the menu took it to another tab, and otherwise goes back to
// the tab the user was on (which may be one of the mod's own). Looked at twice, since Spotify repaints its labels late.
static void settleAfterCreate(UIView *stockBar) {
    SGRLegacyTabBar *bar = objc_getAssociatedObject(stockBar, &kBarKey);
    if (!bar) return;
    setCreateOpen(bar, NO);
    UIView *open = activeStockSource(stockBar);
    // The same tab is the same by its view or by its name; only another one means the menu navigated.
    BOOL sameTab = open == bar.sourceBeforeCreate || (open && bar.labelBeforeCreate.length && [labelIn(open).text isEqualToString:bar.labelBeforeCreate]);
    if (open && !sameTab) {
        // The menu took Spotify to another tab: that brings the full bar back, as any other tab does.
        SGRSetTabBarMinimized(NO, YES);
        syncBarExternalChange(stockBar);
        return;
    }
    UITabBarItem *back = bar.apartSelected ? nil : bar.lastRealItem;
    if ((back || bar.apartSelected) && bar.selectedItem != back) bar.selectedItem = back;
    syncBar(stockBar);
    // Spotify shows the now playing bar again as the menu goes, in its place above the tab bar: the minimized
    // bar stays minimized, so the card goes back between the circles at once.
    if (sg_minimized) {
        UIView *host = objc_getAssociatedObject(stockBar, &kHostKey);
        [UIView performWithoutAnimation:^{
            [host layoutIfNeeded];
            SGRNowPlayingBarFollowTabBar();
        }];
    }
}

// Polled every 0.08 s. `seen`: the menu has been up at least once; before that it is given 10 looks to appear, and
// once seen it is watched for 560 (~45 s) at most.
static void pollCreateClose(UIView *stockBar, NSUInteger attempt, BOOL seen) {
    __weak UIView *weakStock = stockBar;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.08 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIView *stock = weakStock;
        SGRLegacyTabBar *bar = stock ? objc_getAssociatedObject(stock, &kBarKey) : nil;
        if (!bar || !bar.awaitingCreateClose) return;
        BOOL up = createMenuIsUp(stock);
        if (up ? attempt < 560 : (!seen && attempt < 10)) {
            pollCreateClose(stock, attempt + 1, seen || up);
            return;
        }
        bar.awaitingCreateClose = NO;
        settleAfterCreate(stock);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            UIView *again = weakStock;
            if (again) settleAfterCreate(again);
        });
    });
}

static void followCreateClose(UIView *stockBar) {
    SGRLegacyTabBar *bar = objc_getAssociatedObject(stockBar, &kBarKey);
    if (!bar || bar.awaitingCreateClose) return;
    bar.awaitingCreateClose = YES;
    pollCreateClose(stockBar, 0, NO);
}

#pragma mark - compact

// A page scrolled down minimizes the bar (TabBarMinimize.x), the way the Music app's does and the way TabBar.x's
// does on iOS 26: the capsule gives way to a circle at the leading end holding the tab that is open, which
// brings the whole bar back, and to a circle at the trailing end holding the last tab set apart (Split tabs),
// when there is one, and the now playing card takes the room between them (NowPlayingBar.x asks
// SGRLegacyTabBarInlineSlot for it). Without a split tab the card runs on to the margin.
//
// The system bar underneath is not rebuilt: it keeps its items, goes clear and takes no touches, so the full
// bar is back as it was, selection and all. The circles are controls of the host with a glass pane of their
// own (SGRLegacyCircle), the capsule's glass goes by its effect, and all of it moves in the one SGRMotionBar
// spring that moves the card. The panes come from SGGlassFor, so this is the same for a plain blur and for
// legacy glass.

// Whether `item` can stand on the leading circle: a real tab of the capsule, not Create.
static BOOL leadsCompact(SGRLegacyTabBar *bar, UITabBarItem *item) {
    NSUInteger index = item ? [bar.items indexOfObject:item] : NSNotFound;
    // The folded split tab has the trailing circle.
    if (bar.folded && item == bar.apartItem) return NO;
    return index < bar.sources.count && !isCreateSource(bar.sources[index]);
}

// A circle's tab, tapped the way the bar's own tap would: Create pops its menu, the rest are picked and passed
// on to Spotify. A tab that was already open just gets the tap (Home scrolls to its top); another one brings the
// full bar back (the hook on setSelectedViewController). The leading circle never brings it back by itself:
// only a scroll up does.
static void tapItem(UIView *stockBar, UITabBarItem *item) {
    SGRLegacyTabBar *bar = stockBar ? objc_getAssociatedObject(stockBar, &kBarKey) : nil;
    NSUInteger index = item ? [bar.items indexOfObject:item] : NSNotFound;
    if (index >= bar.sources.count) return;
    if (!isCreateSource(bar.sources[index])) bar.selectedItem = item;
    [bar tabBar:bar didSelectItem:item];
}

static SGRLegacyCircle *makeCircle(UIView *host, const void *key) {
    SGRLegacyCircle *circle = (SGRLegacyCircle *)SGLazyChild(host, key, ^UIView *{ return [SGRLegacyCircle new]; });
    // Made away, so it comes in with the bar's motion rather than being there at once.
    [UIView performWithoutAnimation:^{
        [host addSubview:circle];
        [circle setShown:NO];
    }];
    return circle;
}

static void placeCircle(SGRLegacyCircle *circle, CGRect frame, UIView *host) {
    if (!circle || CGRectIsEmpty(frame)) return;
    if (circle.superview != host) [host addSubview:circle];
    CGPoint center = CGPointMake(CGRectGetMidX(frame), CGRectGetMidY(frame));
    if (!CGSizeEqualToSize(circle.bounds.size, frame.size)) circle.bounds = (CGRect){CGPointZero, frame.size};
    if (!CGPointEqualToPoint(circle.center, center)) circle.center = center;
    [circle layoutIfNeeded];
}

static char kGlassMaskKey, kTintMaskKey;

// The roll's masks kept capsules on every frame. Their frames go on the bar's spring, but a corner radius set in the same
// animation goes on a curve of its own, done well before the spring: near the end of a minimize the mask was still taller
// than the circle with the circle's radius, its ends nearly square, and the circle took its round shape only once the
// mask was gone. So for the length of the roll a display link sets each radius to half of the height the mask is drawn at.
@interface SGRRollRadius : NSObject
+ (void)follow:(NSArray<UIView *> *)masks for:(NSTimeInterval)duration;
@end

@implementation SGRRollRadius {
    CADisplayLink *_link;
    NSArray<UIView *> *_masks;
    CFTimeInterval _end;
}

static SGRRollRadius *sg_rollRadius;

+ (void)follow:(NSArray<UIView *> *)masks for:(NSTimeInterval)duration {
    [sg_rollRadius stop];
    SGRRollRadius *follower = [SGRRollRadius new];
    follower->_masks = masks;
    // A little past the spring's duration: it is still settling by a fraction of a point then.
    follower->_end = CACurrentMediaTime() + duration + 0.1;
    for (UIView *mask in masks) [mask.layer removeAnimationForKey:@"cornerRadius"];
    follower->_link = [CADisplayLink displayLinkWithTarget:follower selector:@selector(tick)];
    // Not capped at 60: the bar and the card move at 120 Hz with it.
    if (@available(iOS 15.0, *)) follower->_link.preferredFrameRateRange = CAFrameRateRangeMake(60, 120, 120);
    [follower->_link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    sg_rollRadius = follower;
    [follower tick];
}

- (void)tick {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (UIView *mask in _masks) {
        CALayer *drawn = mask.layer.presentationLayer ?: mask.layer;
        CGSize size = drawn.bounds.size;
        CGFloat radius = MIN(size.width, size.height) / 2;
        if (mask.layer.cornerRadius != radius) mask.layer.cornerRadius = radius;
    }
    [CATransaction commit];
    if (CACurrentMediaTime() > _end) [self stop];
}

- (void)stop {
    // The link holds the follower: invalidated, it may let go of the last reference while this still runs.
    __attribute__((objc_precise_lifetime)) SGRRollRadius *keep = self;
    (void)keep;
    [_link invalidate];
    _link = nil;
    for (UIView *mask in _masks) mask.layer.cornerRadius = MIN(mask.bounds.size.width, mask.bounds.size.height) / 2;
    if (sg_rollRadius == self) sg_rollRadius = nil;
}
@end

// The mask a view of the capsule rolls out of the circle under (placeCompact), made once.
static UIView *rollMask(UIView *view, const void *key) {
    UIView *mask = objc_getAssociatedObject(view, key);
    if (!mask) {
        mask = [UIView new];
        mask.backgroundColor = UIColor.blackColor;
        // Circular, so the dot is a circle and not a squircle; on the capsule it lies just outside the glass's own ends.
        mask.layer.cornerCurve = kCACornerCurveCircular;
        objc_setAssociatedObject(view, key, mask, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (view.maskView != mask) view.maskView = mask;
    return mask;
}

// Lays the bar out for the state it is in, called from every pass of syncBarCore with the capsule's frame and
// the frame the apart tab's round button has beside it: the capsule, its film, the selection pill and the system
// bar for the full bar, the leading circle for the compact one. The apart tab's button is there in both, and
// moves between the two places. Inside an animation the change moves in it.
static void placeCompact(UIView *stockBar, SGRLegacyTabBar *bar, UIView *host, NSArray<UIView *> *sources, CGRect platter, CGRect apartFrame,
                         UIView *navGlass, UIView *navTint, UIView *selPill) {
    UIView *trailSource = bar.apartSource;
    UITabBarItem *trailItem = bar.apartItem;
    BOOL folded = bar.folded && trailSource;
    // One tab has nothing to shrink to: the capsule's tabs and the apart one make two at least (a folded one is
    // among the capsule's).
    BOOL compact = sg_minimized && sources.count + (trailSource && !folded ? 1 : 0) >= 2;
    // Minimized with nothing to shrink to draws the full bar, and the state has to say so: left minimized, every
    // scroll down after it asked for what it already was and the full bar stayed until a scroll back to the top.
    if (sg_minimized && !compact) {
        sg_minimized = NO;
        SGLog(@"tab bar: minimized with %lu tabs to show, expanded again", (unsigned long)sources.count);
    }

    // As tall as the now playing card beside them, round, and centered on the capsule's row.
    CGRect card = SGRNowPlayingCardFrameIn(host, NULL);
    CGFloat side = MIN(CGRectIsNull(card) ? kNavCircleSide : card.size.height, platter.size.height);
    CGFloat circleY = platter.origin.y + (platter.size.height - side) / 2;
    sg_leadFrame = CGRectMake(kNavGlassMargin, circleY, side, side);
    if (!trailSource) sg_trailFrame = CGRectZero;
    else if (compact) sg_trailFrame = CGRectMake(CGRectGetWidth(host.bounds) - kNavGlassMargin - side, circleY, side, side);
    else sg_trailFrame = apartFrame;

    UITabBarItem *leadItem = leadsCompact(bar, bar.selectedItem) ? bar.selectedItem : nil;
    if (!leadItem && leadsCompact(bar, bar.lastRealItem)) leadItem = bar.lastRealItem;
    if (!leadItem && leadsCompact(bar, bar.lastLeadItem)) leadItem = bar.lastLeadItem;
    if (!leadItem) {
        for (UITabBarItem *item in bar.items) {
            if (leadsCompact(bar, item)) {
                leadItem = item;
                break;
            }
        }
    }
    bar.lastLeadItem = leadItem;
    // Filled where the tab is open; on the apart button when that tab is, and then not on the leading one.
    BOOL trailSelected = trailSource && (folded ? bar.selectedItem == trailItem : bar.apartSelected) && !isCreateSource(trailSource);
    UIImage *leadImage = leadItem ? (!trailSelected && leadItem.selectedImage ? leadItem.selectedImage : leadItem.image) : nil;
    UIImage *trailImage = trailItem ? (trailSelected && trailItem.selectedImage ? trailItem.selectedImage : trailItem.image) : nil;

    SGRLegacyCircle *lead = objc_getAssociatedObject(host, &kLeadKey);
    SGRLegacyCircle *trail = objc_getAssociatedObject(host, &kTrailKey);
    if (compact && !lead) lead = makeCircle(host, &kLeadKey);
    if (trailSource && (!folded || compact) && !trail) trail = makeCircle(host, &kTrailKey);
    [UIView performWithoutAnimation:^{
        placeCircle(lead, sg_leadFrame, host);
    }];
    // The apart button is on screen in both states, so on its first pass it is put in place without a
    // motion, and after that it moves.
    if (trail && trail.bounds.size.width < 1) {
        [UIView performWithoutAnimation:^{ placeCircle(trail, sg_trailFrame, host); }];
    } else {
        placeCircle(trail, sg_trailFrame, host);
    }
    NSUInteger leadIndex = leadItem ? [bar.items indexOfObject:leadItem] : NSNotFound;
    __weak UIView *weakStock = stockBar;
    if (lead) {
        if (tintedTabs() && leadImage) leadImage = templateOf(leadImage);
        if (lead.glyph.image != leadImage) lead.glyph.image = leadImage;
        if (![lead.glyph.tintColor isEqual:openTabColor()]) lead.glyph.tintColor = openTabColor();
        lead.item = leadItem;
        lead.accessibilityLabel = leadIndex < sources.count ? labelIn(sources[leadIndex]).text : nil;
        if (!lead.onTap) {
            __weak SGRLegacyCircle *weakLead = lead;
            // As the Music app's circle and TabBar.x's do: a tap on the minimized bar's tab brings the whole bar back and
            // opens nothing (passed on, the tap would take Spotify's stack to its root).
            lead.onTap = ^{
                if (sg_minimized) {
                    SGRSetTabBarMinimized(NO, YES);
                    return;
                }
                tapItem(weakStock, weakLead.item);
            };
        }
    }
    if (trail) {
        if (tintedTabs() && trailImage) trailImage = templateOf(trailImage);
        if (trail.glyph.image != trailImage) trail.glyph.image = trailImage;
        if (CGAffineTransformIsIdentity(trail.glyph.transform) && ![trail.glyph.tintColor isEqual:openTabColor()]) trail.glyph.tintColor = openTabColor();
        trail.item = trailItem;
        trail.holdsCreate = trailSource && isCreateSource(trailSource);
        if (!trail.holdsCreate) [trail setCreateOpen:NO];
        trail.accessibilityLabel = trailSource ? labelIn(trailSource).text : nil;
        if (!trail.onTap) {
            trail.onTap = ^{
                UIView *stock = weakStock;
                SGRLegacyTabBar *legacy = stock ? objc_getAssociatedObject(stock, &kBarKey) : nil;
                // Folded, the tab is one of the capsule's: tapped as the capsule's own would be.
                if (legacy.folded) tapItem(stock, legacy.apartItem);
                else [legacy tapApart];
            };
        }
    }

    // The apart tab's button is there in both states, but a folded one only while minimized: expanded, it is in the capsule.
    [trail setShown:trailSource != nil && (!folded || compact)];

    // The full bar rolls out of the leading circle and back into it: the capsule's glass and film show the whole way, cut by a
    // mask from the circle's place and size to the capsule's on the one spring the change moves on (the mask is a view, so it
    // takes that spring as it is), and the circle is only its glyph meanwhile, its own glass back once the capsule has become
    // it. A transform squeezed the capsule into an oval on the way, so it faded out under the circle's size while the circle
    // faded in and out beside it.
    // The capsule hugs its tabs and stands in the middle, so the circle at the screen's edge lies partly outside its
    // glass, which draws nothing past its own bounds: the shape stopped at the capsule's edge and the circle came in
    // further out once the roll ended. So the glass slides along on the same spring, minimizing, until its leading edge
    // is the circle's, and back as the bar expands; a pass in the middle of a roll keeps the slide its end wants.
    CGFloat slide = MIN(0, sg_leadFrame.origin.x - platter.origin.x);
    CGAffineTransform slid = CGAffineTransformMakeTranslation(slide, 0);
    CGAffineTransform rest = compact && navGlass.maskView ? slid : CGAffineTransformIdentity;
    if (!CGAffineTransformEqualToTransform(navGlass.transform, rest)) navGlass.transform = rest;
    if (!CGAffineTransformEqualToTransform(navTint.transform, rest)) navTint.transform = rest;
    static BOOL sg_compactApplied;
    static NSUInteger sg_rollGeneration;
    BOOL changed = compact != sg_compactApplied;
    sg_compactApplied = compact;
    NSTimeInterval duration = UIView.inheritedAnimationDuration;
    BOOL roll = changed && duration > 0 && !SGRReduceMotion() && lead && !CGRectIsEmpty(platter) && !CGRectIsEmpty(sg_leadFrame);
    UIViewAnimationOptions options = UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionCurveEaseOut;
    void (^tabsFade)(void) = ^{ bar.alpha = compact ? 0 : 1; };
    if (roll) {
        NSUInteger generation = ++sg_rollGeneration;
        CGRect full = (CGRect){CGPointZero, platter.size};
        // The circle in the glass's own coordinates, with the glass slid to it.
        CGRect dot = CGRectOffset(sg_leadFrame, -platter.origin.x - slide, -platter.origin.y);
        UIView *glassMask = rollMask(navGlass, &kGlassMaskKey), *tintMask = rollMask(navTint, &kTintMaskKey);
        [UIView performWithoutAnimation:^{
            SGRShowGlass(navGlass, YES);
            navTint.alpha = 1;
            navGlass.transform = navTint.transform = compact ? CGAffineTransformIdentity : slid;
            for (UIView *mask in @[glassMask, tintMask]) {
                mask.frame = compact ? full : dot;
                mask.layer.cornerRadius = (compact ? full : dot).size.height / 2;
            }
            [lead holdGlyphOnly:compact ? 0 : 1];
        }];
        for (UIView *mask in @[glassMask, tintMask]) mask.frame = compact ? dot : full;
        navGlass.transform = navTint.transform = compact ? slid : CGAffineTransformIdentity;
        [SGRRollRadius follow:@[glassMask, tintMask] for:duration];
        [UIView animateWithDuration:compact ? 0.16 : 0.12 delay:compact ? MAX(0, duration * 0.5) : 0 options:options
                         animations:^{ lead.glyph.alpha = compact ? 1 : 0; } completion:nil];
        [UIView animateWithDuration:0.16 delay:0 options:options animations:^{ selPill.alpha = compact ? 0 : 1; } completion:nil];
        [UIView animateWithDuration:compact ? 0.1 : 0.22 delay:compact ? 0 : 0.1 options:options animations:tabsFade completion:nil];
        // Once the spring has carried the mask home: the masks off, and, minimized, the circle's own glass in the capsule's place.
        __weak SGRLegacyCircle *weakLead = lead;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(duration * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (generation != sg_rollGeneration) return;
            [UIView performWithoutAnimation:^{
                navGlass.maskView = nil;
                navTint.maskView = nil;
                navGlass.transform = navTint.transform = CGAffineTransformIdentity;
                if (compact) {
                    [weakLead setShown:YES];
                    SGRShowGlass(navGlass, NO);
                    navTint.alpha = 0;
                } else {
                    [weakLead setShown:NO];
                }
            }];
        });
    } else if (changed || !navGlass.maskView) {
        // A pass in the middle of a roll leaves it alone: the circle and the glass are the roll's until it ends.
        if (changed) {
            ++sg_rollGeneration;
            [sg_rollRadius stop];
            navGlass.maskView = nil;
            navTint.maskView = nil;
            navGlass.transform = navTint.transform = CGAffineTransformIdentity;
        }
        [lead setShown:compact];
        // Outside a roll the glass and the tabs fade, the tabs a beat after the glass coming in and first going away.
        void (^glassFade)(void) = ^{
            SGRShowGlass(navGlass, !compact);
            navTint.alpha = compact ? 0 : 1;
            selPill.alpha = compact ? 0 : 1;
        };
        if (changed && duration > 0 && !SGRReduceMotion()) {
            [UIView animateWithDuration:compact ? 0.16 : 0.2 delay:compact ? 0.04 : 0 options:options animations:glassFade completion:nil];
            [UIView animateWithDuration:compact ? 0.1 : 0.22 delay:compact ? 0 : 0.1 options:options animations:tabsFade completion:nil];
        } else {
            glassFade();
            tabsFade();
        }
    }
    bar.userInteractionEnabled = !compact;
}

static void setMinimized(BOOL minimized, BOOL animated) {
    UIView *stockBar = sg_stockBar;
    if (minimized == sg_minimized) return;
    // Spotify's regular width bar is not this bar's row of tabs; it stays as it is. One tab has nothing to
    // shrink to.
    if (minimized && (!stockBar.window || stockBar.traitCollection.horizontalSizeClass != UIUserInterfaceSizeClassCompact || tabItems(stockBar).count < 2)) return;
    sg_minimized = minimized;
    if (!stockBar) return;
    UIView *host = objc_getAssociatedObject(stockBar, &kHostKey);
    animated &= host.window != nil;
    void (^apply)(void) = ^{
        syncBar(stockBar);
        [host layoutIfNeeded];
        SGRNowPlayingBarFollowTabBar();
    };
    if (!animated) {
        [UIView performWithoutAnimation:apply];
        return;
    }
    // Minimizing is SGRMotionBar's spring with no overshoot. The full bar coming back has a little: the capsule
    // grows out of the circle and settles, the card goes back above it on the same spring.
    if (minimized || SGRReduceMotion()) {
        SGRAnimate(SGRMotionBar, apply, nil);
        return;
    }
    [UIView animateWithDuration:0.5 delay:0 usingSpringWithDamping:0.8 initialSpringVelocity:0
        options:UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionBeginFromCurrentState
        animations:apply completion:nil];
}

BOOL SGRLegacyTabBarMinimized(void) {
    return sg_minimized;
}

// When the change is made, inside an animation of Spotify's or not, is SGRSetTabBarMinimized's (TabBar.x).
void SGRLegacyApplyTabBarMinimized(BOOL minimized, BOOL animated) {
    setMinimized(minimized, animated);
}

CGRect SGRLegacyTabBarInlineSlot(UIView *host, CGFloat height) {
    UIView *stockBar = sg_stockBar;
    UIView *barHost = stockBar ? objc_getAssociatedObject(stockBar, &kHostKey) : nil;
    UIView *bar = stockBar ? objc_getAssociatedObject(stockBar, &kBarKey) : nil;
    if (!sg_minimized || !host || !barHost || !bar.window || stockBar.hidden || stockBar.alpha < 0.01 || CGRectIsEmpty(sg_leadFrame)) return CGRectNull;
    // The circles' places, not what is on screen mid-spring.
    CGRect lead = [barHost convertRect:sg_leadFrame toView:host];
    CGFloat left = CGRectGetMaxX(lead) + SGRGrid;
    CGFloat right;
    if (!CGRectIsEmpty(sg_trailFrame)) {
        right = CGRectGetMinX([barHost convertRect:sg_trailFrame toView:host]) - SGRGrid;
    } else {
        CGRect whole = [stockBar convertRect:stockBar.bounds toView:host];
        right = CGRectGetMaxX(whole) - kNavGlassMargin;
    }
    CGRect slot = CGRectMake(left, CGRectGetMidY(lead) - height / 2, right - left, height);
    // A bar Spotify has slid away for a page takes the slot off the screen with it.
    CGRect inWindow = [host convertRect:slot toView:nil];
    if (slot.size.width < 100 || CGRectGetMaxY(inWindow) > CGRectGetMaxY(bar.window.bounds)) return CGRectNull;
    return slot;
}

// What the bar's layout is made of that moves it when it changes: how many tabs, which one is set apart, whether the
// labels are shown, whether it is minimized. A change of it that nothing else animates (the settings rebuilding the
// bar, Spotify adding or dropping the split tab) is laid out on the bar's own spring rather than cut in.
static char kLayoutSigKey;

static void syncBar(UIView *stockBar) {
    NSArray<UIView *> *all = tabItems(stockBar);
    UIView *host = objc_getAssociatedObject(stockBar, &kHostKey);
    if (!all.count || !host) {
        syncBarCore(stockBar, NO);
        return;
    }
    NSString *sig = [NSString stringWithFormat:@"%lu|%p|%d|%d", (unsigned long)all.count, trailingSource(all),
                     SGHidden(SGRKeyNavbarHideLabels) ? 1 : 0, sg_minimized ? 1 : 0];
    NSString *prev = objc_getAssociatedObject(stockBar, &kLayoutSigKey);
    if (![sig isEqualToString:prev]) objc_setAssociatedObject(stockBar, &kLayoutSigKey, sig, OBJC_ASSOCIATION_COPY_NONATOMIC);
    BOOL moves = prev && ![sig isEqualToString:prev] && host.window && !SGRReduceMotion()
        && UIView.areAnimationsEnabled && UIView.inheritedAnimationDuration <= 0;
    if (!moves) {
        syncBarCore(stockBar, NO);
        return;
    }
    SGRAnimate(SGRMotionBar, ^{
        syncBarCore(stockBar, NO);
        [host layoutIfNeeded];
    }, nil);
}

static void syncBarExternalChange(UIView *stockBar) {
    syncBarCore(stockBar, YES);
}

static void syncBarCore(UIView *stockBar, BOOL rescanSelection) {
    sg_stockBar = stockBar;

    SGRLegacyTabBar *bar = objc_getAssociatedObject(stockBar, &kBarKey);
    if (!bar) {
        bar = [[SGRLegacyTabBar alloc] initWithFrame:stockBar.bounds];
        // Outside the navigation stacks Spotify makes dark itself, so the glass would follow a light system.
        bar.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
        // The glass (navGlass) is the bar's only background.
        bar.backgroundColor = UIColor.clearColor;
        // White in every state but the open tab's, which Tabs in the accent may tint.
        applyTabColors(bar);
        bar.delegate = bar;
        bar.stockBar = stockBar;
        UILongPressGestureRecognizer *hold = [[UILongPressGestureRecognizer alloc] initWithTarget:bar action:@selector(held:)];
        hold.delegate = bar;
        [bar addGestureRecognizer:hold];
        bar.hold = hold;
        SGRLegacyTabDragRecognizer *drag = [[SGRLegacyTabDragRecognizer alloc] initWithTarget:bar action:@selector(dragged:)];
        drag.delegate = bar;
        [bar addGestureRecognizer:drag];
        bar.drag = drag;
        objc_setAssociatedObject(stockBar, &kBarKey, bar, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        SGRLegacyTabBarHost *host = [SGRLegacyTabBarHost new];
        [host addSubview:bar];
        objc_setAssociatedObject(stockBar, &kHostKey, host, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    // The active tab shows by its filled glyph and the pill. renderLayer makes every icon a template image, so the
    // tint decides its color.
    bar.tintColor = UIColor.whiteColor;
    bar.unselectedItemTintColor = UIColor.whiteColor;
    // Centered at a fixed itemWidth (set below), so the capsule hugs its items instead of the group filling the frame.
    bar.itemPositioning = UITabBarItemPositioningCentered;
    bar.itemSpacing = kNavItemSpacing;
    UIView *host = objc_getAssociatedObject(stockBar, &kHostKey);

    for (UIView *sub in stockBar.subviews) {
        if (sub == host) continue;
        sub.alpha = 0;
        sub.userInteractionEnabled = NO;
    }
    stockBar.superview.layer.backgroundColor = NULL;

    NSArray<UIView *> *allSources = tabItems(stockBar);
    if (!allSources.count) return;
    // The apart tab is on a button of its own, so the capsule holds the others.
    UIView *apartSource = trailingSource(allSources);
    // With few tabs the apart one is not set apart while the bar is expanded: it is the capsule's last tab, and
    // only the minimized bar gives it its round button (placeCompact).
    BOOL fold = apartSource && allSources.count <= SGRLegacyFoldLimit;
    NSMutableArray<UIView *> *capsuleSources = [allSources mutableCopy];
    if (apartSource && !fold) [capsuleSources removeObject:apartSource];
    NSArray<UIView *> *sources = capsuleSources;
    if (apartSource != bar.apartSource || (apartSource && !fold && !bar.apartItem) || fold != bar.folded) {
        bar.apartSource = apartSource;
        // Folded, the item is the capsule's own, taken below once the capsule has its items.
        bar.apartItem = apartSource && !fold ? [[UITabBarItem alloc] initWithTitle:labelIn(apartSource).text image:nil tag:-1] : nil;
        if (!apartSource) bar.apartSelected = NO;
    }
    BOOL wasFolded = bar.folded;
    // An item with no title is drawn by UIKit as its glyph alone, centred, on a bar of the same height.
    BOOL hideLabels = SGHidden(SGRKeyNavbarHideLabels);

    BOOL itemsRebuilt = NO;
    if (![sources isEqualToArray:bar.sources]) {
        itemsRebuilt = YES;
        // The selection is carried over by source view, as indexes shift when a tab is removed.
        NSUInteger oldSelIndex = [bar.items indexOfObject:bar.selectedItem];
        UIView *oldSelSource = (oldSelIndex != NSNotFound && oldSelIndex < bar.sources.count) ? bar.sources[oldSelIndex] : nil;
        NSUInteger oldLastIndex = [bar.items indexOfObject:bar.lastRealItem];
        UIView *oldLastSource = (oldLastIndex != NSNotFound && oldLastIndex < bar.sources.count) ? bar.sources[oldLastIndex] : nil;
        NSMutableArray<UITabBarItem *> *items = [NSMutableArray array];
        for (UIView *source in sources) [items addObject:[[UITabBarItem alloc] initWithTitle:hideLabels ? nil : labelIn(source).text image:nil tag:items.count]];
        bar.sources = sources;
        [bar setItems:items animated:NO];
        // setItems: rebuilds every item view; finish it now so renderedCenterXForItem does not read stale ones.
        [bar layoutIfNeeded];
        if (oldSelSource) {
            NSUInteger newSelIndex = [sources indexOfObject:oldSelSource];
            if (newSelIndex != NSNotFound) bar.selectedItem = items[newSelIndex];
        }
        if (oldLastSource) {
            NSUInteger newLastIndex = [sources indexOfObject:oldLastSource];
            if (newLastIndex != NSNotFound) bar.lastRealItem = items[newLastIndex];
        }
        // The split tab changing between the capsule and its own button keeps its page open.
        if (wasFolded && !fold && oldSelSource && oldSelSource == apartSource) bar.apartSelected = YES;
        if (!wasFolded && fold && bar.apartSelected && items.count) {
            bar.apartSelected = NO;
            // The split tab is the capsule's own at whatever place the settings gave it.
            NSUInteger at = [sources indexOfObject:apartSource];
            UITabBarItem *own = at < items.count ? items[at] : items.lastObject;
            bar.selectedItem = own;
            bar.lastRealItem = own;
        }
    }
    if (fold) {
        NSUInteger apartIndex = [sources indexOfObject:apartSource];
        bar.apartItem = apartIndex < bar.items.count ? bar.items[apartIndex] : nil;
    }
    bar.folded = fold;

    UITabBarItem *selected = nil;
    BOOL missing = NO;
    for (NSUInteger i = 0; i < sources.count; i++) {
        UITabBarItem *item = bar.items[i];
        learnGlyphs(sources[i], item);
        missing |= !item.image || !item.selectedImage;
        NSString *title = hideLabels ? nil : labelIn(sources[i]).text;
        if (hideLabels ? item.title != nil : title.length && ![title isEqualToString:item.title]) item.title = title;
        // UIKit lays the icon out as if a label sat under it, so without labels it is nudged down to centre.
        UIEdgeInsets wantInsets = hideLabels ? UIEdgeInsetsMake(kNavIconOnlyImageShift, 0, -kNavIconOnlyImageShift, 0) : UIEdgeInsetsZero;
        if (!UIEdgeInsetsEqualToEdgeInsets(item.imageInsets, wantInsets)) item.imageInsets = wantInsets;
        if (!selected && isActive(sources[i]) && !isCreateSource(sources[i])) selected = item;
    }
    if (apartSource && !fold) {
        learnGlyphs(apartSource, bar.apartItem);
        missing |= !bar.apartItem.image || !bar.apartItem.selectedImage;
    }
    // Only an external change (rescanSelection) trusts the isActive scan over lastRealItem. While Create's menu is
    // up the pill stays on Create; settleAfterCreate decides where it goes after.
    if ((rescanSelection && !bar.awaitingCreateClose) || !bar.lastRealItem) {
        if (selected && bar.selectedItem != selected) bar.selectedItem = selected;
        if (selected) bar.lastRealItem = selected;
    }
    // The apart tab opened by a link or the drawer is read from Spotify's labels; one of the mod's own, from its tap.
    if (rescanSelection && !bar.awaitingCreateClose && !selected && apartSource && !fold && !isCreateSource(apartSource) && isActive(apartSource)) bar.apartSelected = YES;
    // With the apart tab open the capsule has no tab selected (no pill).
    if (bar.apartSelected && !bar.awaitingCreateClose && bar.selectedItem) bar.selectedItem = nil;
    // Glyphs of the selected and the other items are painted by paintGlyphs, from the bar's own layout.
    paintGlyphs(bar);
    // An icon view Spotify has not built yet is retried (40 times at most), counted per stock bar.
    NSNumber *retriesBox = objc_getAssociatedObject(stockBar, &kRetriesKey);
    NSUInteger retries = retriesBox.unsignedIntegerValue;
    if (missing) {
        if (retries < 40) {
            objc_setAssociatedObject(stockBar, &kRetriesKey, @(retries + 1), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                syncBar(stockBar);
            });
        }
    } else if (retriesBox) {
        objc_setAssociatedObject(stockBar, &kRetriesKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    CGRect bounds = stockBar.bounds;
    CGFloat width = bounds.size.width;
    // The host is as tall as the room (the bar asks for up to 83 pt, mostly home-indicator strip); only the bar and
    // its glass are pinned to the platter's height. It floats kNavGlassBottomMargin off the bottom edge.
    CGFloat height = MAX(bounds.size.height, SGRTabBarGlassHeight(bar, stockBar));
    CGRect frame = CGRectMake(0, CGRectGetMaxY(bounds) - height - kNavGlassBottomMargin, width, height);
    if (!CGRectEqualToRect(host.frame, frame)) host.frame = frame;

    // The capsule is as wide as its tabs; past the width that fits, each slot narrows to fit.
    CGFloat platterHeight = MIN(hideLabels ? kNavPlatterHeightIconOnly : kNavPlatterHeight, height);
    // The apart tab's button stands beside the capsule, as high as it is, and the two are centered together.
    BOOL separate = apartSource && !fold;
    CGFloat apartRoom = separate ? platterHeight + SGRGrid : 0;
    CGFloat availableWidth = width - kNavGlassMargin * 2 - apartRoom;
    CGFloat naturalWidth = kNavItemWidth * sources.count + kNavItemSpacing * (sources.count - 1);
    CGFloat itemWidth = naturalWidth > availableWidth
        ? MAX(1, (availableWidth - kNavItemSpacing * (sources.count - 1)) / sources.count)
        : kNavItemWidth;
    if (bar.itemWidth != itemWidth) bar.itemWidth = itemWidth;
    CGFloat contentWidth = MIN(availableWidth, naturalWidth);
    // A gap under the now playing card, which ends at the host's top edge.
    CGFloat platterY = MIN(kNavGlassBottomMargin, MAX(0, height - platterHeight));
    CGFloat groupX = floor((width - contentWidth - apartRoom) / 2);
    CGRect platterFrame = CGRectMake(groupX, platterY, contentWidth, platterHeight);
    CGRect apartFrame = separate ? CGRectMake(groupX + contentWidth + SGRGrid, platterY, platterHeight, platterHeight) : CGRectZero;
    BOOL frameChanged = !CGRectEqualToRect(bar.frame, platterFrame);
    if (frameChanged) bar.frame = platterFrame;
    // UIKit lays the item buttons out lazily; a resize or a reorder is laid out now, or the pill reads stale positions.
    if (frameChanged || itemsRebuilt) [bar layoutIfNeeded];

    // A glass capsule behind the bar, as NowPlayingBar.x backs the mini player; radius half its height.
    UIView *navGlass = SGGlassFor(host, &kNavGlassKey);
    navGlass.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    CGRect glassFrame = platterFrame;
    // By bounds and center: placeCompact rolls the capsule out of the circle under a mask, and these passes come during it.
    CGPoint glassCenter = CGPointMake(CGRectGetMidX(glassFrame), CGRectGetMidY(glassFrame));
    if (!CGSizeEqualToSize(navGlass.bounds.size, glassFrame.size)) navGlass.bounds = (CGRect){CGPointZero, glassFrame.size};
    if (!CGPointEqualToPoint(navGlass.center, glassCenter)) navGlass.center = glassCenter;
    SGShapeGlass(navGlass, glassFrame.size.height / 2, NO);
    SGRDarkenGlass(navGlass, &kNavDimKey, glassFrame.size.height / 2, SGRBarDim);

    UIView *navTint = SGRGlassFilm(host, &kNavTintKey, navGlass, glassFrame.size.height / 2);
    // SGRGlassFilm sets the film's frame from the pane's; the film is given the pane's bounds and center as well.
    if (!CGSizeEqualToSize(navTint.bounds.size, glassFrame.size)) navTint.bounds = (CGRect){CGPointZero, glassFrame.size};
    if (!CGPointEqualToPoint(navTint.center, glassCenter)) navTint.center = glassCenter;

    // The selection bubble, above the tint and below the transparent bar so the icon draws on top; while a finger holds
    // it, it stands over the bar so its glass bends and magnifies the icons (TabBarLens.m).
    SGRLegacyLens *selPill = (SGRLegacyLens *)SGLazyChild(host, &kSelPillKey, ^UIView *{ return [SGRLegacyLens new]; });
    if (selPill.superview != host) [host insertSubview:selPill aboveSubview:navTint];
    selPill.heldOutset = kSelPillInset + kLensOverhang;
    // The pill follows bar.selectedItem, not Spotify's labels, which repaint late. syncBar is its only writer.
    NSUInteger selIndex = [bar.items indexOfObject:bar.selectedItem];
    if (selIndex != NSNotFound && selIndex < sources.count) {
        CGFloat pillWidth = itemWidth - kSelPillInset * 2;
        CGFloat centerX = [bar renderedCenterXForItem:bar.selectedItem];
        CGFloat slotX = isnan(centerX)
            ? bar.frame.origin.x + selIndex * (itemWidth + kNavItemSpacing) + kSelPillInset
            : bar.frame.origin.x + centerX - pillWidth / 2;
        CGRect pillFrame = CGRectMake(slotX, bar.frame.origin.y + kSelPillInset, pillWidth, bar.frame.size.height - kSelPillInset * 2);
        BOOL wasVisible = !selPill.hidden;
        selPill.hidden = NO;
        // The lens moves the pill: a tap, a tab picked on release and a layout pass slide it to the new slot on the
        // bubble's springs, and a pill that was hidden appears where it belongs. While a finger has the bubble, the
        // slot is only remembered.
        if (!CGRectEqualToRect(selPill.restFrame, pillFrame)) [selPill setRestFrame:pillFrame animated:wasVisible];
    } else {
        selPill.hidden = YES;
    }
    placeCompact(stockBar, bar, host, sources, platterFrame, apartFrame, navGlass, navTint, selPill);
    // The now playing card fills what the circles leave of the row, and follows them when they move.
    static CGRect lastLead, lastTrail;
    static BOOL following;
    BOOL circlesMoved = !CGRectEqualToRect(lastLead, sg_leadFrame) || !CGRectEqualToRect(lastTrail, sg_trailFrame);
    lastLead = sg_leadFrame;
    lastTrail = sg_trailFrame;
    if (circlesMoved && sg_minimized && !following) {
        following = YES;
        SGRNowPlayingBarFollowTabBar();
        following = NO;
    }

    if (host.superview != stockBar) [stockBar addSubview:host];
    else if (stockBar.subviews.lastObject != host) [stockBar bringSubviewToFront:host];
    makeRoom(containerOf(stockBar));
}

#pragma mark - hooks

// The bar's own pass runs before Spotify has filled the row; the items lay out as they arrive.
static void itemDidLayOut(UIView *item) {
    UIView *bar = tabBarOf(item);
    if (!bar) return;
    SGRComposeTabBar(bar);
    SGRHoldHomeForModSettings(bar);
    syncBar(bar);
}

%group LegacyTabBar

%hook _TtC23NavigationUI_TabBarImpl10TabBarView
- (void)layoutSubviews {
    %orig;
    SGRComposeTabBar((UIView *)self);
    for (UIView *sub in ((UIView *)self).subviews) {
        if (![sub isKindOfClass:SGRLegacyTabBarHost.class]) [sub layoutIfNeeded];
    }
    SGRHoldHomeForModSettings((UIView *)self);
    syncBar((UIView *)self);
}
%end

%hook _TtC23NavigationUI_TabBarImpl21TabBarItemElementView
- (void)layoutSubviews {
    %orig;
    itemDidLayOut((UIView *)self);
}
%end

%hook _TtC25CreateMenu_TabBarItemImpl24CreateMenuTabBarItemView
- (void)layoutSubviews {
    %orig;
    itemDidLayOut((UIView *)self);
}
%end

// A tab changed from elsewhere (a link, the side drawer) repaints the labels without a layout pass.
%hook _TtC23NavigationUI_TabBarImpl19TabBarContainerImpl
- (void)setSelectedViewController:(UIViewController *)controller {
    %orig;
    // Spotify repaints its labels a moment later, so the second look is the one that sees the new tab.
    dispatch_async(dispatch_get_main_queue(), ^{
        // Another tab brings the minimized bar back (HIG, Tab bars). Create's menu stands under the compact bar
        // and hides nothing of it, so the bar stays while the menu is up (settleAfterCreate looks again after).
        UIView *bar = sg_stockBar;
        SGRLegacyTabBar *legacy = bar ? objc_getAssociatedObject(bar, &kBarKey) : nil;
        if (!(sg_minimized && bar && (legacy.awaitingCreateClose || createMenuIsUp(bar)))) SGRSetTabBarMinimized(NO, YES);
        if (bar) syncBarExternalChange(bar);
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIView *bar = sg_stockBar;
        if (bar) syncBarExternalChange(bar);
    });
}
// The message bar coming or going changes the view's safe area before Spotify lays the bar out for it,
// so the room follows in that same pass, and inside the message bar's animation.
- (void)viewSafeAreaInsetsDidChange {
    %orig;
    makeRoom((UIViewController *)self);
}
%end

%end

BOOL SGRLegacyTabBarOn(void) {
    static BOOL on;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // Below 26 the system draws no glass of its own, so the redesign's bar is this one whatever it is made
        // of; SGGlassFor makes the pane, a plain blur or legacy glass by the switch.
        if (@available(iOS 26.0, *)) return;
        on = SGRedesignedUI();
    });
    return on;
}

%ctor {
    if (!SGRLegacyTabBarOn()) return;
    %init(LegacyTabBar);
    SGRequireClasses(@[
        @"_TtC23NavigationUI_TabBarImpl10TabBarView",
        @"_TtC23NavigationUI_TabBarImpl21TabBarItemElementView",
        @"_TtC25CreateMenu_TabBarItemImpl24CreateMenuTabBarItemView",
        @"_TtC23NavigationUI_TabBarImpl19TabBarContainerImpl",
    ]);
}
