// Where the background goes. Classes are Spotify 9.1.90's, checked against a class dump of its binary
// (ipsw class-dump) and against the classes Vitrine already hooks on the same version:
//
//   Home         _TtC19Home_FunkisPageImpl20FunkisViewController, _TtC16Home_EvoPageImpl33EvoLoadableResourceViewController
//   Library      _TtC28YourLibrary_YourLibraryXImpl25YourLibraryViewController
//   Now playing  _TtC21NowPlaying_ScrollImpl27NPVBackgroundViewController (the album-colored plane behind the player)
//   Everywhere   _TtC33Navigation_PageAPIIntegrationImpl33MusicAppPageHostingViewController (wraps every page)
//
// A page gets a MRGBackgroundView at the very bottom of its view. Spotify paints its pages with an
// opaque fill (and Vitrine's redesign paints them black), so with "Clear page backgrounds" on, the
// full-screen containers of that page (views that cover most of it: the page view, its collection
// view and their full-size wrappers) are made clear, and cleared again on the next layout pass if Spotify or Vitrine sets
// a color again. Cells, cards, bars and Vitrine's glass are left alone, so the glass now samples
// the background instead of a flat fill.
#import "MRGPrefs.h"
#import "MRGBackgroundView.h"
#import <objc/runtime.h>

static char kBackgroundKey, kClearedKey, kOriginalColorKey;

static BOOL isCleared(UIView *v) { return objc_getAssociatedObject(v, &kClearedKey) != nil; }

static BOOL isVisibleColor(UIColor *c) { return c && CGColorGetAlpha(c.CGColor) > 0.01; }

// Called on every layout pass of the host, so a color Spotify (or Vitrine) sets again later is taken
// off at the next pass and remembered as the one to put back. No UIView-wide setBackgroundColor: hook.
static void clearView(UIView *v) {
    UIColor *c = v.backgroundColor;
    if (!isCleared(v)) {
        objc_setAssociatedObject(v, &kOriginalColorKey, c ?: (id)NSNull.null, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(v, &kClearedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else if (isVisibleColor(c)) {
        objc_setAssociatedObject(v, &kOriginalColorKey, c, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (isVisibleColor(c)) v.backgroundColor = UIColor.clearColor;
    UIView *bgView = [v isKindOfClass:UICollectionView.class] ? ((UICollectionView *)v).backgroundView
                   : [v isKindOfClass:UITableView.class] ? ((UITableView *)v).backgroundView : nil;
    if (bgView.alpha != 0) bgView.alpha = 0;
}

#pragma mark - list cells

// Lists inside a page that has a background (Library's rows and grid, mostly) whose cells Spotify fills
// opaque black. Tagged lists clear their visible cells' dark fills on each of their own layout passes,
// which run on scroll and after reuse, so recycled cells come out clear too.
static char kListKey;
static NSUInteger sg_taggedLists;

// Only opaque, near-black fills: artwork, colored badges, glass and Vitrine's tinted cards keep theirs.
static BOOL isDarkFill(UIColor *c) {
    if (!c) return NO;
    CGFloat r = 0, g = 0, b = 0, a = 0;
    if (![c getRed:&r green:&g blue:&b alpha:&a]) {
        CGFloat w = 0;
        if (![c getWhite:&w alpha:&a]) return NO;
        r = g = b = w;
    }
    return a > 0.9 && MAX(r, MAX(g, b)) < 0.22;
}

static void clearDarkFill(UIView *v) {
    if (!v || [v isKindOfClass:UIVisualEffectView.class] || [v isKindOfClass:UIImageView.class]) return;
    UIColor *c = v.backgroundColor;
    if (!isDarkFill(c)) return;
    if (!isCleared(v)) objc_setAssociatedObject(v, &kClearedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(v, &kOriginalColorKey, c, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    v.backgroundColor = UIColor.clearColor;
}

static void clearCell(UIView *cell) {
    clearDarkFill(cell);
    UIView *content = [cell isKindOfClass:UICollectionViewCell.class] ? ((UICollectionViewCell *)cell).contentView
                    : [cell isKindOfClass:UITableViewCell.class] ? ((UITableViewCell *)cell).contentView
                    : [cell isKindOfClass:UITableViewHeaderFooterView.class] ? ((UITableViewHeaderFooterView *)cell).contentView
                    : cell;   // a header or decoration view: its own subviews
    UIView *back = [cell isKindOfClass:UICollectionViewCell.class] ? ((UICollectionViewCell *)cell).backgroundView
                 : [cell isKindOfClass:UITableViewCell.class] ? ((UITableViewCell *)cell).backgroundView
                 : [cell isKindOfClass:UITableViewHeaderFooterView.class] ? ((UITableViewHeaderFooterView *)cell).backgroundView : nil;
    clearDarkFill(back);
    if (content != cell) clearDarkFill(content);
    // The cell-sized fills inside it (row containers, tile plates), two levels down.
    CGSize size = cell.bounds.size;
    for (UIView *a in content.subviews) {
        if (a.bounds.size.width < size.width * 0.9 || a.bounds.size.height < size.height * 0.9) continue;
        clearDarkFill(a);
        for (UIView *b in a.subviews)
            if (b.bounds.size.width >= size.width * 0.9 && b.bounds.size.height >= size.height * 0.9) clearDarkFill(b);
    }
}

// Cells, and the list's other reusable views: section headers (Library's "Recents" sort row), footers and
// decoration views (a section's backdrop), all direct subviews of the list.
static void clearCells(UIScrollView *list) {
    for (UIView *v in list.subviews) {
        if ([v isKindOfClass:UICollectionReusableView.class] || [v isKindOfClass:UITableViewCell.class] ||
            [v isKindOfClass:UITableViewHeaderFooterView.class]) clearCell(v);
    }
}

// Bars that run across the page outside its list (a sort row or a strip under the filter chips): as wide
// as the page, at most 120pt tall, filled opaque near-black. Only that fill goes, like a cell's.
static void clearPageBar(UIView *v, CGSize page) {
    CGSize s = v.bounds.size;
    if (s.width < page.width * 0.9 || s.height > 120 || s.height < 1) return;
    clearDarkFill(v);
}

static void tagList(UIScrollView *list) {
    if (objc_getAssociatedObject(list, &kListKey)) return;
    objc_setAssociatedObject(list, &kListKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    sg_taggedLists++;
}

static void untagList(UIView *list) {
    if (!objc_getAssociatedObject(list, &kListKey)) return;
    objc_setAssociatedObject(list, &kListKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (sg_taggedLists) sg_taggedLists--;
}

static inline BOOL isTaggedList(UIView *v) { return sg_taggedLists && objc_getAssociatedObject(v, &kListKey); }

static void restoreView(UIView *v) {
    if (!isCleared(v)) return;
    id original = objc_getAssociatedObject(v, &kOriginalColorKey);
    objc_setAssociatedObject(v, &kClearedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    v.backgroundColor = original == NSNull.null ? nil : original;
    if ([v isKindOfClass:UICollectionView.class]) ((UICollectionView *)v).backgroundView.alpha = 1;
    if ([v isKindOfClass:UITableView.class]) ((UITableView *)v).backgroundView.alpha = 1;
}

// Only views about the page's own size are walked into, so this stays a handful of views however
// long the page's list is: a cell is never full-screen.
static void forEachFullSizeView(UIView *root, CGSize page, int depth, void (^block)(UIView *)) {
    if (depth > 6) return;
    for (UIView *sub in root.subviews) {
        if ([sub isKindOfClass:MRGBackgroundView.class] || [sub isKindOfClass:UIVisualEffectView.class]) continue;
        if ([sub isKindOfClass:UICollectionViewCell.class] || [sub isKindOfClass:UITableViewCell.class]) continue;
        if ([sub.accessibilityIdentifier isEqualToString:@"mirage.settings"]) continue;
        CGSize s = sub.bounds.size;
        if (s.width < page.width * 0.9 || s.height < page.height * 0.6) continue;
        block(sub);
        forEachFullSizeView(sub, page, depth + 1, block);
    }
}

// The page's main lists, however deep they sit (Library nests its grid well below the page view):
// lists as wide as the page and at least 40% of its height. Cells are not walked into.
static void tagPageLists(UIView *host) {
    CGSize page = host.bounds.size;
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithArray:host.subviews];
    NSUInteger seen = 0;
    while (stack.count && seen++ < 3000) {
        UIView *v = stack.lastObject; [stack removeLastObject];
        if ([v isKindOfClass:MRGBackgroundView.class] || [v isKindOfClass:UICollectionViewCell.class] ||
            [v isKindOfClass:UITableViewCell.class] || [v isKindOfClass:UIVisualEffectView.class]) continue;
        if ([v.accessibilityIdentifier isEqualToString:@"mirage.settings"]) continue;   // draws its own
        clearPageBar(v, page);
        if (([v isKindOfClass:UICollectionView.class] || [v isKindOfClass:UITableView.class]) &&
            v.bounds.size.width >= page.width * 0.9 && v.bounds.size.height >= page.height * 0.4) {
            clearView(v);
            tagList((UIScrollView *)v);
            clearCells((UIScrollView *)v);
        }
        [stack addObjectsFromArray:v.subviews];
    }
}

#pragma mark - attaching

static void detach(UIView *host) {
    MRGBackgroundView *bg = objc_getAssociatedObject(host, &kBackgroundKey);
    if (!bg) return;
    [bg removeFromSuperview];
    objc_setAssociatedObject(host, &kBackgroundKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    // Everything Mirage cleared under this host: page fills, list fills and cell fills.
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:host];
    NSUInteger seen = 0;
    while (stack.count && seen++ < 5000) {
        UIView *v = stack.lastObject; [stack removeLastObject];
        restoreView(v);
        untagList(v);
        [stack addObjectsFromArray:v.subviews];
    }
}

// One background per stack of hosts: Home's Funkis page holds the Evo page, every page sits in a
// MusicAppPageHostingViewController, and page hosts can nest. The outermost host that wants one keeps
// it; an inner host whose ancestor already has one stands down, and a new outer one takes over from any
// inner ones. The now playing plane (onTop) is its own stack.
static BOOL ancestorHasBackground(UIView *host) {
    for (UIView *v = host.superview; v; v = v.superview) {
        MRGBackgroundView *bg = objc_getAssociatedObject(v, &kBackgroundKey);
        if (bg && bg.superview == v && !bg.hidden) return YES;
    }
    return NO;
}

static void detachDescendants(UIView *host) {
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithArray:host.subviews];
    NSUInteger seen = 0;
    while (stack.count && seen++ < 5000) {
        UIView *v = stack.lastObject; [stack removeLastObject];
        if ([v isKindOfClass:MRGBackgroundView.class]) continue;
        if (objc_getAssociatedObject(v, &kBackgroundKey)) detach(v);
        [stack addObjectsFromArray:v.subviews];
    }
}

// The side drawer is never given a background (nor has its fills cleared): it is a sheet over the app,
// and its list carries Vitrine's and Mirage's own rows. Looked up once per host.
static char kDrawerHostKey;
static BOOL isDrawerHost(UIView *host) {
    NSNumber *known = objc_getAssociatedObject(host, &kDrawerHostKey);
    if (known) return known.boolValue;
    if (!host.subviews.count) return NO;   // not built yet: ask again next pass
    BOOL drawer = NO;
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithArray:host.subviews];
    NSUInteger seen = 0;
    while (stack.count && seen++ < 2000 && !drawer) {
        UIView *v = stack.lastObject; [stack removeLastObject];
        if ([v isKindOfClass:UICollectionViewCell.class]) continue;
        if ([NSStringFromClass(v.class) containsString:@"SideDrawer"]) drawer = YES;
        [stack addObjectsFromArray:v.subviews];
    }
    objc_setAssociatedObject(host, &kDrawerHostKey, @(drawer), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return drawer;
}

static void attach(UIView *host, MRGScreen screen, BOOL onTop) {
    if (!host) return;
    if (screen == MRGScreenEverywhere && isDrawerHost(host)) { detach(host); return; }
    if (!MRGWantsScreen(screen) || (!onTop && ancestorHasBackground(host))) { detach(host); return; }
    MRGBackgroundView *bg = objc_getAssociatedObject(host, &kBackgroundKey);
    if (!bg) {
        bg = [[MRGBackgroundView alloc] initWithFrame:host.bounds];
        objc_setAssociatedObject(host, &kBackgroundKey, bg, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (!onTop) detachDescendants(host);
    }
    if (bg.hidden) bg.hidden = NO;
    if (bg.superview != host) [host insertSubview:bg atIndex:0];
    if (onTop) { if (host.subviews.lastObject != bg) [host bringSubviewToFront:bg]; }
    else if (host.subviews.firstObject != bg) [host sendSubviewToBack:bg];

    // The view fills the host's bounds; its canvas covers the window wherever the host is (pinCanvas),
    // so neither a short host (keyboard), an offset one (nav container, transition) nor the growing
    // now playing plane crops or shifts the picture. Re-pinned on every layout pass of the host.
    if (!CGRectEqualToRect(bg.frame, host.bounds)) {
        [UIView performWithoutAnimation:^{ bg.frame = host.bounds; }];
    }
    [bg pinCanvas];

    if (!onTop && MRGClearPages()) {
        clearView(host);
        forEachFullSizeView(host, host.bounds.size, 0, ^(UIView *v) { clearView(v); });
        tagPageLists(host);
    }
}

// Off screen but still in the window (a page covered by the one pushed over it): the same instance stays
// on the host, hidden, so the video engine stops counting it and nothing is re-added on the way back.
static void hostDisappeared(UIView *host) {
    MRGBackgroundView *bg = objc_getAssociatedObject(host, &kBackgroundKey);
    if (bg && !bg.hidden) bg.hidden = YES;
}

%group MRGLists
%hook UICollectionView
- (void)layoutSubviews { %orig; if (isTaggedList(self)) clearCells(self); }
%end
%hook UITableView
- (void)layoutSubviews { %orig; if (isTaggedList(self)) clearCells(self); }
%end
%end

#pragma mark - screens

%group MRGHome
%hook _TtC19Home_FunkisPageImpl20FunkisViewController
- (void)viewDidLayoutSubviews { %orig; attach(((UIViewController *)self).view, MRGScreenHome, NO); }
- (void)viewWillAppear:(BOOL)animated { %orig; attach(((UIViewController *)self).view, MRGScreenHome, NO); }
- (void)viewDidAppear:(BOOL)animated { %orig; attach(((UIViewController *)self).view, MRGScreenHome, NO); }
- (void)viewDidDisappear:(BOOL)animated { %orig; hostDisappeared(((UIViewController *)self).view); }
%end
%end

%group MRGHomeEvo
%hook _TtC16Home_EvoPageImpl33EvoLoadableResourceViewController
- (void)viewDidLayoutSubviews { %orig; attach(((UIViewController *)self).view, MRGScreenHome, NO); }
- (void)viewWillAppear:(BOOL)animated { %orig; attach(((UIViewController *)self).view, MRGScreenHome, NO); }
- (void)viewDidAppear:(BOOL)animated { %orig; attach(((UIViewController *)self).view, MRGScreenHome, NO); }
- (void)viewDidDisappear:(BOOL)animated { %orig; hostDisappeared(((UIViewController *)self).view); }
%end
%end

%group MRGLibrary
%hook _TtC28YourLibrary_YourLibraryXImpl25YourLibraryViewController
- (void)viewDidLayoutSubviews { %orig; attach(((UIViewController *)self).view, MRGScreenLibrary, NO); }
- (void)viewWillAppear:(BOOL)animated { %orig; attach(((UIViewController *)self).view, MRGScreenLibrary, NO); }
- (void)viewDidAppear:(BOOL)animated { %orig; attach(((UIViewController *)self).view, MRGScreenLibrary, NO); }
- (void)viewDidDisappear:(BOOL)animated { %orig; hostDisappeared(((UIViewController *)self).view); }
%end
%end

// The plane is laid out on every scroll frame (Vitrine, Redesigned/Player/PlayerField.x), so attach()
// only compares a frame on the way. The background goes over the plane's own gradients (and over
// Vitrine's artwork field, which sits there too) but stays under the player's cards and controls,
// which are not in this view.
%group MRGNowPlaying
%hook _TtC21NowPlaying_ScrollImpl27NPVBackgroundViewController
- (void)viewDidLayoutSubviews { %orig; attach(((UIViewController *)self).view, MRGScreenNowPlaying, YES); }
- (void)viewWillAppear:(BOOL)animated { %orig; attach(((UIViewController *)self).view, MRGScreenNowPlaying, YES); }
- (void)viewDidAppear:(BOOL)animated { %orig; attach(((UIViewController *)self).view, MRGScreenNowPlaying, YES); }
- (void)viewDidDisappear:(BOOL)animated { %orig; hostDisappeared(((UIViewController *)self).view); }
%end
%end

%group MRGEverywhere
%hook _TtC33Navigation_PageAPIIntegrationImpl33MusicAppPageHostingViewController
- (void)viewDidLayoutSubviews { %orig; attach(((UIViewController *)self).view, MRGScreenEverywhere, NO); }
- (void)viewWillAppear:(BOOL)animated { %orig; attach(((UIViewController *)self).view, MRGScreenEverywhere, NO); }
- (void)viewDidAppear:(BOOL)animated { %orig; attach(((UIViewController *)self).view, MRGScreenEverywhere, NO); }
- (void)viewDidDisappear:(BOOL)animated { %orig; hostDisappeared(((UIViewController *)self).view); }
%end
%end

#pragma mark - live updates


static void relayoutAll(void) {
    // Ask every page that has (or could want) a background to lay out again; attach/detach runs there.
    for (UIWindowScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *w in scene.windows) {
            NSMutableArray *stack = [NSMutableArray arrayWithObject:w];
            while (stack.count) {
                UIView *v = stack.lastObject; [stack removeLastObject];
                [v setNeedsLayout];
                if (objc_getAssociatedObject(v, &kBackgroundKey)) [(MRGBackgroundView *)objc_getAssociatedObject(v, &kBackgroundKey) refresh];
                if (stack.count < 4000) [stack addObjectsFromArray:v.subviews];
            }
        }
    }
}

%ctor {
    @autoreleasepool {
        %init(MRGLists);
        if (NSClassFromString(@"_TtC19Home_FunkisPageImpl20FunkisViewController")) %init(MRGHome);
        if (NSClassFromString(@"_TtC16Home_EvoPageImpl33EvoLoadableResourceViewController")) %init(MRGHomeEvo);
        if (NSClassFromString(@"_TtC28YourLibrary_YourLibraryXImpl25YourLibraryViewController")) %init(MRGLibrary);
        if (NSClassFromString(@"_TtC21NowPlaying_ScrollImpl27NPVBackgroundViewController")) %init(MRGNowPlaying);
        if (NSClassFromString(@"_TtC33Navigation_PageAPIIntegrationImpl33MusicAppPageHostingViewController")) %init(MRGEverywhere);
        [NSNotificationCenter.defaultCenter addObserverForName:MRGSettingsChangedNotification object:nil queue:nil usingBlock:^(NSNotification *n) {
            dispatch_async(dispatch_get_main_queue(), ^{ relayoutAll(); });
        }];
    }
}
