// The bar of a page under SPNavigationBar. Spotify draws it as UIKit's bar with no background of its own over a
// blur of its own, a plain view in the navigation controller's view that holds a UIVisualEffectView and is painted
// #000000; the back button is a _UIButtonBarButton at the leading edge of the bar's content view, the title a
// _UINavigationBarTitleControl with a UILabel, and a page's ⋯ the Encore button in a _UIButtonBarStackView at the
// trailing edge.
//
// The playlist, album and artist pages have none of that: the page's field to the top of the screen, a glass
// circle for Back and for ⋯ at the corners, level with each other, and the name on a glass capsule between them.
// So here the blur is drawn by nothing, the bar takes no touches, Back and ⋯ are pinned to the page the way the
// other pages pin theirs (SGRPinnedMore, SGRPinnedBackOf), and the title control carries the capsule, as
// Playlist/PlaylistBar.x gives the playlist's name its own.
//
// The bar and its blur are the navigation controller's, shared by every page on its stack, so each is given back
// as the page goes (SGRUndressBarPage) -- unless another dressed page has come on top, which UIKit announces
// before it takes this one's leave: the bar is that page's then, and stays dressed.
//
// The bar is made dark while a page is dressed, and its title white: the system's appearance reached the bar, which
// drew the title in the label color, black in light mode, on a capsule of dark glass.
//
// What is concealed is Spotify's own controls, not replaced: the pinned ⋯ fires the page's own ⋯ -- the Encore
// button in this page's bar, or the Share of a Listening stats list, drawn as a share glyph -- and Back pops the
// navigation controller.
//
// A page dressed with SGRDressBarPageBackOnly gets Back and the title and nothing at the trailing edge: Settings and its
// sections and the mod's own pages have no ⋯, and what sits in their trailing stack is not one (a 22pt button the tree
// gives no name, and on the Settings root a hidden pair), so those controls are kept out of sight: the bar takes no touches,
// and one shown in it could not be tapped.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Pages.h"

static char kMoreKey, kExtraKey, kProxyKey, kTitleGlassKey, kBarStyleKey, kHeldKey, kConcealedKey, kBarBackgroundKey;

// The pages dressed now, weakly: the bar is given back only when none is left.
static NSHashTable<UIViewController *> *sg_dressed;
// The dressed pages whose bar has no title to carry (SGRDressBarPageTitleless), weakly too.
static NSHashTable<UIViewController *> *sg_titleless;
// The dressed pages whose trailing controls are left alone (SGRDressBarPageBackOnly), weakly too.
static NSHashTable<UIViewController *> *sg_backOnly;

// The room the two corner buttons leave the title.
static const CGFloat kCorner = 16, kGap = 8;

#pragma mark - the controls of the bar

// The bar's stacks of controls, told apart by the half of the bar they stand in: one at the trailing edge (the page's ⋯,
// a Share) and, when the page put an item of its own at the leading edge, one there (Add artists' cross). The system's
// back button is no such item: it is a direct subview of the content view.
static UIView *stackIn(UIView *content, BOOL leading) {
    CGFloat middle = content.bounds.size.width / 2;
    for (UIView *sub in content.subviews) {
        if (![NSStringFromClass(sub.class) isEqualToString:@"_UIButtonBarStackView"]) continue;
        if ((CGRectGetMidX(sub.frame) < middle) == leading) return sub;
    }
    return nil;
}

UIView *SGRBarStackButton(UIView *content, BOOL leading) {
    for (UIView *button in stackIn(content, leading).subviews) {
        if (button.bounds.size.width > 1 && button.bounds.size.height > 1) return button;
    }
    return nil;
}

// The button of such an item at the leading edge.
static UIView *leadingItemOf(UIView *content) {
    UIView *button = SGRChildNamed(stackIn(content, YES), @"_UIButtonBarButton");
    return button.bounds.size.width > 1 ? button : nil;
}

// The page's own ⋯: the first control of the bar's trailing stack, which holds nothing on a page without one.
// Looked for in this bar and nowhere else, so what the ⋯ fires can never be a ⋯ of the player's.
static UIView *moreOf(UIView *content) {
    UIView *stack = stackIn(content, NO);
    UIView *button = stack.subviews.firstObject;
    return button.bounds.size.width > 1 ? button : nil;
}

// Whether the page's trailing control is a Share (Listening stats' Top artists and Top songs) rather than a ⋯. A
// second control after the ⋯ in the trailing stack (SongDNA's bar: Share, then Close), the one nearest the corner.
// Pages with a single control have none.
static UIView *extraOf(UIView *content) {
    UIView *stack = stackIn(content, NO);
    BOOL first = YES;
    UIView *found = nil;
    for (UIView *sub in stack.subviews) {
        if (sub.bounds.size.width < 1 || sub.bounds.size.height < 1) continue;
        if (first) { first = NO; continue; }
        found = sub;
    }
    return found;
}

static BOOL isShare(UIView *control) {
    __block BOOL share = [NSStringFromClass(control.class) containsString:@"ShareButton"];
    SGForEachView(control, ^(UIView *v) {
        if ([v.accessibilityIdentifier hasSuffix:@"ShareButton"]) share = YES;
    });
    return share;
}

// SGRConceal, marked so that only what this file concealed is given back (restore).
static void conceal(UIView *view) {
    if (!view) return;
    objc_setAssociatedObject(view, &kConcealedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    SGRConceal(view);
}

static void reveal(UIView *view) {
    if (!view) return;
    objc_setAssociatedObject(view, &kConcealedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    view.layer.hidden = NO;
    view.layer.mask = nil;
    view.userInteractionEnabled = YES;
    view.accessibilityElementsHidden = NO;
}

// Spotify's blur: the plain view of the navigation controller's that holds a visual effect view.
UIView *SGRBarBlurOf(UINavigationController *navigation) {
    for (UIView *sub in navigation.view.subviews) {
        if (![sub isMemberOfClass:UIView.class]) continue;
        for (UIView *inner in sub.subviews) {
            if ([inner isKindOfClass:UIVisualEffectView.class]) return sub;
        }
    }
    return nil;
}

// The pages that want the blur off (SGRRegisterBarPages), and the blurs this file took off, to give back to a page that does not.
static NSMutableArray<SGRBarPageTest> *sg_wants;
static char kBlurOffKey;

void SGRRegisterBarPages(SGRBarPageTest wants) {
    if (!sg_wants) sg_wants = [NSMutableArray array];
    [sg_wants addObject:[wants copy]];
}

static BOOL isOnScreen(UIViewController *page, UINavigationController *navigation) {
    for (UIViewController *vc = page; vc; vc = vc.parentViewController) {
        if (vc == navigation.topViewController) return YES;
    }
    return NO;
}

// Whether a page dressed now (alive, and still in a stack) is in `navigation`: the bar of one navigation controller is
// given back when none of its own pages is dressed, whatever other stacks (a sheet's) hold.
static BOOL dressedIn(UINavigationController *navigation) {
    for (UIViewController *page in sg_dressed.allObjects) {
        if (navigation && page.navigationController == navigation) return YES;
    }
    return NO;
}

// Whether one of `pages` (sg_dressed, sg_titleless, sg_backOnly) is the one on top of `navigation`.
static BOOL topIsIn(NSHashTable<UIViewController *> *pages, UINavigationController *navigation) {
    for (UIViewController *page in pages.allObjects) {
        if (isOnScreen(page, navigation)) return YES;
    }
    return NO;
}

// Spotify's own Back, ⋯ and title are kept out of sight from the moment a page that wants the redesign's bar is
// pushed, not from the first pass that dresses it: UIKit builds them in the bar's content view, whose pass this
// runs after, and until the page's own controller exists nothing else hides them, so Spotify's bar showed for a
// moment and went. A dressed page conceals Back and ⋯ itself and its title is shown again here
// for its capsule; a page that turns out to be another gets all three back.
static void holdControls(UINavigationController *navigation, BOOL wanted) {
    UINavigationBar *bar = navigation.navigationBar;
    UIView *content = SGRChildNamed(bar, @"_UINavigationBarContentView");
    if (!content) return;
    UIView *title = SGRChildNamed(content, @"_UINavigationBarTitleControl");
    BOOL held = objc_getAssociatedObject(bar, &kHeldKey) != nil;
    if (wanted) {
        if (topIsIn(sg_dressed, navigation)) {
            if (held) reveal(title);
            return;
        }
        if (!held) objc_setAssociatedObject(bar, &kHeldKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        conceal(SGRChildNamed(content, @"_UIButtonBarButton"));
        conceal(leadingItemOf(content));
        conceal(moreOf(content));
        conceal(extraOf(content));
        conceal(title);
    } else if (held) {
        reveal(title);
        if (!dressedIn(navigation)) {
            reveal(SGRChildNamed(content, @"_UIButtonBarButton"));
            reveal(leadingItemOf(content));
            reveal(moreOf(content));
            reveal(extraOf(content));
            objc_setAssociatedObject(bar, &kHeldKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
}

void SGRSyncBarBlur(UINavigationController *navigation) {
    UIViewController *top = navigation.topViewController;
    BOOL wanted = NO;
    for (SGRBarPageTest test in sg_wants) {
        if (top && test(top)) { wanted = YES; break; }
    }
    UIView *blur = SGRBarBlurOf(navigation);
    if (blur) {
        if (wanted) {
            if (!blur.layer.mask) blur.layer.mask = [CALayer layer];
            if (blur.userInteractionEnabled) blur.userInteractionEnabled = NO;
            if (!objc_getAssociatedObject(blur, &kBlurOffKey)) objc_setAssociatedObject(blur, &kBlurOffKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        } else if (objc_getAssociatedObject(blur, &kBlurOffKey) && !dressedIn(navigation)) {
            blur.layer.mask = nil;
            blur.userInteractionEnabled = YES;
            objc_setAssociatedObject(blur, &kBlurOffKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
    if (SGBelowiOS26()) holdControls(navigation, wanted);
}

#pragma mark - Back

// What the pinned Back reads and fires: a control of the redesign's own that stands in for the bar's back button
// and pops the stack, which is all that button does.
@interface SGRBackProxy : UIControl
@property (nonatomic, weak) UINavigationController *navigation;
@end

@implementation SGRBackProxy
- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    [self addTarget:self action:@selector(sgr_back) forControlEvents:UIControlEventTouchUpInside];
    return self;
}

- (void)sgr_back {
    [self.navigation popViewControllerAnimated:YES];
}

- (BOOL)accessibilityActivate {
    [self sgr_back];
    return YES;
}
@end

BOOL SGRPageIsOrHolds(UIViewController *top, Class page) {
    if (!top || !page) return NO;
    NSMutableArray *queue = [NSMutableArray arrayWithObject:top];
    for (int depth = 0; depth < 7 && queue.count; depth++) {
        NSMutableArray *next = [NSMutableArray array];
        for (UIViewController *vc in queue) {
            if ([vc isKindOfClass:page]) return YES;
            [next addObjectsFromArray:vc.childViewControllers];
        }
        queue = next;
    }
    return NO;
}

#pragma mark - the title

static void dropTitleGlass(UIView *title) {
    [(UIView *)objc_getAssociatedObject(title, &kTitleGlassKey) removeFromSuperview];
}

static void glassTitle(UIView *title) {
    // A page with no title has an empty item in the title control (a SwiftUI bar item that draws nothing), which the
    // branch for a title that is a picture below would wrap in a capsule all the same. The title control is the bar's,
    // shared by the pages of the stack, and is watched for its layout, so this holds for every pass that reaches it.
    if (topIsIn(sg_titleless, SGRNavigationOf(title))) {
        dropTitleGlass(title);
        return;
    }
    UILabel *label = nil;
    for (UIView *sub in title.subviews) {
        for (UIView *inner in sub.subviews) {
            if (!label && [inner isKindOfClass:UILabel.class]) label = (UILabel *)inner;
        }
    }
    CGFloat content;
    if (label) {
        if (!label.text.length) return;
        // White, whatever the system appearance made of it: the capsule behind it is dark glass.
        UIColor *white = SGRPrimary();
        if (![label.textColor isEqual:white]) label.textColor = white;
        content = SGRTitleWidth(label);
    } else {
        // A title that is a picture (Song DNA's logo and its Beta tag): the capsule wraps the control.
        content = ceil(title.bounds.size.width);
        if (content < 1) return;
    }
    CGFloat screen = title.window ? title.window.bounds.size.width : 390;
    // Two glass circles at the trailing edge (Song DNA's Share and Close) take two places from the corner, and the
    // capsule is centred, so it leaves as much on the leading side: with one place it ran to 2pt from Share.
    BOOL backOnly = topIsIn(sg_backOnly, SGRNavigationOf(title));
    CGFloat places = !backOnly && extraOf(title.superview) ? 2 : 1;
    CGFloat room = screen - 2 * (kCorner + places * (SGRGlassCircleSize + kGap));
    // The control is as small as its label, and the capsule is a subview that reaches past it.
    SGRGlassTitleCapsule(title, &kTitleGlassKey, content, room, ^BOOL(UIView *v) { return [v.superview isKindOfClass:UINavigationBar.class]; });
}

// The title is laid out again as its text arrives, which reaches neither the page nor the bar's content view the
// page's pass works from: it is watched for its own layout.
static void watchTitle(UIView *title) {
    SGRWatchLayout(title, ^(UIView *view) { glassTitle(view); });
}

#pragma mark - the page

// The page's trailing controls, pinned: the ⋯ (or the Share, drawn as a share glyph) in the corner and, with a second
// control, the Share one place in from it and Close in the corner.
static void pinTrailing(UIView *view, UIView *more, UIView *extra) {
    static UIImage *shareGlyph, *moreGlyph, *closeGlyph;
    if (!shareGlyph) {
        shareGlyph = [UIImage systemImageNamed:@"square.and.arrow.up"];
        moreGlyph = [UIImage systemImageNamed:@"ellipsis"];
        closeGlyph = [UIImage systemImageNamed:@"xmark"];
    }
    BOOL share = more && isShare(more);
    conceal(more);
    if (extra) {
        // With a second control (SongDNA's Close) the first, Share, steps one place in from the corner and Close takes it.
        SGRPinnedTrailing(view, &kMoreKey, more, 1, share ? shareGlyph : moreGlyph);
        conceal(extra);
        SGRPinnedTrailing(view, &kExtraKey, extra, 0, closeGlyph);
        return;
    }
    SGRMirrorButton *pinned = SGRPinnedMore(view, &kMoreKey, more);
    if (share && pinned.fallbackGlyph != shareGlyph) {
        pinned.fallbackGlyph = shareGlyph;
        [pinned feedFrom:more];
    }
}

// The bar's own background, which UIKit fills with its blur once the list scrolls (its standard appearance in place of
// the scroll edge one), is above the page, so it covered the pinned Back: Settings scrolled showed a grey band with no
// Back in it. Taking the background off left the list's text under the status bar with nothing over it, so it keeps
// its blur with a hole the shape of Back cut in it, by a mask, which UIKit does not touch.
static void punchBack(UINavigationBar *bar, UIView *back) {
    UIView *background = SGRChildNamed(bar, @"_UIBarBackground");
    if (!background || !back.window) return;
    CAShapeLayer *mask = [background.layer.mask isKindOfClass:CAShapeLayer.class] ? (CAShapeLayer *)background.layer.mask : nil;
    if (background.layer.mask && !mask) return;
    if (!mask) {
        mask = [CAShapeLayer layer];
        mask.fillRule = kCAFillRuleEvenOdd;
        background.layer.mask = mask;
        objc_setAssociatedObject(bar, &kBarBackgroundKey, background, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    CGRect bounds = background.layer.bounds;
    UIBezierPath *path = [UIBezierPath bezierPathWithRect:CGRectInset(bounds, 0, -bounds.size.height)];
    [path appendPath:[UIBezierPath bezierPathWithOvalInRect:[back convertRect:back.bounds toView:background]]];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    mask.frame = bounds;
    mask.path = path.CGPath;
    [CATransaction commit];
}

void SGRDressBarPage(UIViewController *page) {
    UIView *view = page.viewIfLoaded;
    UINavigationController *navigation = page.navigationController;
    if (!view.window || !navigation || !isOnScreen(page, navigation)) return;
    UINavigationBar *bar = navigation.navigationBar;
    UIView *content = SGRChildNamed(bar, @"_UINavigationBarContentView");
    if (!content) return;

    if (!sg_dressed) sg_dressed = [NSHashTable weakObjectsHashTable];
    [sg_dressed addObject:page];
    if (bar.overrideUserInterfaceStyle != UIUserInterfaceStyleDark) {
        if (!objc_getAssociatedObject(bar, &kBarStyleKey)) {
            objc_setAssociatedObject(bar, &kBarStyleKey, @(bar.overrideUserInterfaceStyle), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        bar.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    }

    UIView *blur = SGRBarBlurOf(navigation);
    if (blur) {
        if (!blur.layer.mask) blur.layer.mask = [CALayer layer];
        if (blur.userInteractionEnabled) blur.userInteractionEnabled = NO;
    }
    // The bar is above the page and would take the touches meant for the buttons pinned to it.
    if (bar.userInteractionEnabled) bar.userInteractionEnabled = NO;

    UIView *back = SGRChildNamed(content, @"_UIButtonBarButton");
    UIView *item = back ? nil : leadingItemOf(content);
    conceal(back ?: item);
    if (item) {
        // An item the page set (a cross that dismisses it) does what the page made it do, which popping would not: the
        // glass circle mirrors and fires that button, as the pinned ⋯ does the page's own.
        punchBack(bar, SGRPinnedBackOf(view, item));
    } else {
        SGRBackProxy *proxy = objc_getAssociatedObject(view, &kProxyKey);
        if (!proxy) {
            proxy = [[SGRBackProxy alloc] initWithFrame:CGRectZero];
            objc_setAssociatedObject(view, &kProxyKey, proxy, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        proxy.navigation = navigation;
        punchBack(bar, SGRPinnedBackOf(view, proxy));
    }

    UIView *more = moreOf(content);
    UIView *extra = extraOf(content);
    if ([sg_backOnly containsObject:page]) {
        // Not given back: the bar takes no touches (it is over the pinned Back), so a control shown in it would do
        // nothing when tapped. What sits there is no ⋯ (see the top of the file), so nothing is pinned for it.
        conceal(more);
        conceal(extra);
    } else {
        pinTrailing(view, more, extra);
    }

    UIView *title = SGRChildNamed(content, @"_UINavigationBarTitleControl");
    if (title) {
        if (objc_getAssociatedObject(bar, &kHeldKey)) reveal(title);
        glassTitle(title);
        watchTitle(title);
    }
}

void SGRDressBarPageBackOnly(UIViewController *page) {
    if (!sg_backOnly) sg_backOnly = [NSHashTable weakObjectsHashTable];
    [sg_backOnly addObject:page];
    SGRDressBarPage(page);
}

void SGRDressBarPageTitleless(UIViewController *page) {
    if (!sg_titleless) sg_titleless = [NSHashTable weakObjectsHashTable];
    [sg_titleless addObject:page];
    SGRDressBarPage(page);
}

static void undressBar(UIViewController *page, UINavigationController *navigation) {
    [sg_dressed removeObject:page];
    [sg_titleless removeObject:page];
    [sg_backOnly removeObject:page];
    if (!navigation) return;
    // A page pushed over this one dressed the bar before this one went: it is that page's now.
    if (dressedIn(navigation)) return;
    UINavigationBar *bar = navigation.navigationBar;
    NSNumber *style = objc_getAssociatedObject(bar, &kBarStyleKey);
    if (style) {
        bar.overrideUserInterfaceStyle = (UIUserInterfaceStyle)style.integerValue;
        objc_setAssociatedObject(bar, &kBarStyleKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    UIView *background = objc_getAssociatedObject(bar, &kBarBackgroundKey);
    if (background) {
        background.layer.mask = nil;
        objc_setAssociatedObject(bar, &kBarBackgroundKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    UIView *content = SGRChildNamed(bar, @"_UINavigationBarContentView");
    reveal(SGRChildNamed(content, @"_UIButtonBarButton"));
    reveal(leadingItemOf(content));
    reveal(moreOf(content));
    reveal(extraOf(content));
    bar.userInteractionEnabled = YES;
    objc_setAssociatedObject(bar, &kHeldKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    UIView *title = SGRChildNamed(content, @"_UINavigationBarTitleControl");
    reveal(title);
    UIView *blur = SGRBarBlurOf(navigation);
    blur.layer.mask = nil;
    blur.userInteractionEnabled = YES;
    // The capsule is the title control's, which the next page's title may be too: it goes, and the next pass of
    // the page that wants one makes it again.
    dropTitleGlass(title);
}

// A swipe back says the page is going the moment the finger moves, and the page is still under it, following the
// finger, until it is let go. The bar is given back at the end of the swipe and not at its start: the title's capsule
// (Song DNA's logo) went with the first move while the page was still on screen. A swipe the finger takes back leaves
// the page dressed, and the pass its own appearing makes finds it so.
void SGRUndressBarPage(UIViewController *page) {
    UINavigationController *navigation = page.navigationController;
    id<UIViewControllerTransitionCoordinator> coordinator = page.transitionCoordinator;
    if (navigation && coordinator.isInteractive) {
        [coordinator animateAlongsideTransition:nil completion:^(id<UIViewControllerTransitionCoordinatorContext> context) {
            if (!context.isCancelled) undressBar(page, navigation);
        }];
        return;
    }
    undressBar(page, navigation);
}

#pragma mark - pages dressed by class, and pages dressed from the bar

static void dressStyled(UIViewController *page, SGRBarStyle style) {
    if (style == SGRBarStyleTitleless) SGRDressBarPageTitleless(page);
    else if (style == SGRBarStyleBackOnly) SGRDressBarPageBackOnly(page);
    else SGRDressBarPage(page);
}

void SGRDressBarPagesWith(Class page, BOOL hosted, SGRControllerPass dress) {
    if (!page) return;
    SGRRegisterBarPages(^BOOL(UIViewController *top) { return hosted ? SGRPageIsOrHolds(top, page) : [top isKindOfClass:page]; });
    // The bar's buttons and title are made after the first layout.
    SGRPassController(page, dress);
    SGRPassControllerGoing(page, ^(UIViewController *c) { SGRUndressBarPage(c); });
}

void SGRDressBarPagesOf(Class page, BOOL hosted) {
    SGRDressBarPagesWith(page, hosted, ^(UIViewController *c) { SGRDressBarPage(c); });
}

// One kind of page dressed from the bar, and the one of them dressed now.
@interface SGRBarPageWatch : NSObject
@property (nonatomic, copy) SGRBarPageFind find;
@property (nonatomic) SGRBarStyle style;
@property (nonatomic, weak) UIViewController *dressed;
@end

@implementation SGRBarPageWatch
@end

void SGRDressBarPagesFound(SGRBarPageFind find, SGRBarStyle style) {
    if (!find) return;
    SGRBarPageWatch *watch = [SGRBarPageWatch new];
    watch.find = find;
    watch.style = style;
    SGRRegisterBarPages(^BOOL(UIViewController *top) { return top.navigationController && find(top.navigationController) != nil; });
    SGRObserveBarPasses(^(UIView *bar) {
        UIViewController *page = watch.find(SGRNavigationOf(bar));
        if (page.viewIfLoaded.window) {
            watch.dressed = page;
            dressStyled(page, watch.style);
            return;
        }
        UIViewController *dressed = watch.dressed;
        if (!dressed) return;
        watch.dressed = nil;
        SGRUndressBarPage(dressed);
    });
}
