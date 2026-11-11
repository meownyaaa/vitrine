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

static char kBackgroundKey, kClearedKey, kOriginalColorKey, kDarkOnlyKey;

static BOOL isCleared(UIView *v) { return objc_getAssociatedObject(v, &kClearedKey) != nil; }

static BOOL isVisibleColor(UIColor *c) { return c && CGColorGetAlpha(c.CGColor) > 0.01; }

// Called on every layout pass of the host, so a color Spotify (or Vitrine) sets again later is taken
// off at the next pass and remembered as the one to put back. No UIView-wide setBackgroundColor: hook.
static BOOL sg_anyCleared;
static void clearView(UIView *v) {
    sg_anyCleared = YES;
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
    sg_anyCleared = YES;
    if (!isCleared(v)) {
        objc_setAssociatedObject(v, &kClearedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(v, &kDarkOnlyKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
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
    // Three levels: Library's cells are swipeable containers with the row or card a level further in.
    for (UIView *a in content.subviews) {
        if (a.bounds.size.width < size.width * 0.9 || a.bounds.size.height < size.height * 0.8) continue;
        clearDarkFill(a);
        for (UIView *b in a.subviews) {
            if (b.bounds.size.width < size.width * 0.9 || b.bounds.size.height < size.height * 0.8) continue;
            clearDarkFill(b);
            for (UIView *c in b.subviews)
                if (c.bounds.size.width >= size.width * 0.9 && c.bounds.size.height >= size.height * 0.8) clearDarkFill(c);
        }
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
    objc_setAssociatedObject(v, &kDarkOnlyKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
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

// Hosts that are never given a background, nor have their fills cleared:
//  - the side drawer: a sheet over the app whose list carries Vitrine's and Mirage's own rows;
//  - the now playing bar's page (NowPlaying_BarPageImpl, a TouchPassthroughView as wide as the screen)
//    and anything holding the bar or the tab bar. In the minimized tab bar Vitrine moves the bar's
//    container into the row by a transform (Redesigned/NowPlayingBar/NowPlayingBar.x placeInline) while
//    the page around it keeps the old full-width frame, so a background there was a full-width slab of
//    the picture left behind and sliding around with the pill;
//  - the full player's own pages (it has its own background, onTop).
// A host is also too small to be a page if it is not most of the window (a bar, a card, a sheet's grabber).
static char kExcludedKey;
static NSArray<NSString *> *excludedMarkers(void) {
    static NSArray *markers;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ markers = @[@"SideDrawer", @"NowPlaying_Bar", @"NowPlaying_View", @"MainUI_TabBar"]; });
    return markers;
}

static BOOL isExcludedClass(Class cls) {
    if ([cls isSubclassOfClass:UITabBar.class]) return YES;
    NSString *name = NSStringFromClass(cls);
    for (NSString *m in excludedMarkers()) if ([name containsString:m]) return YES;
    return NO;
}

static BOOL isExcludedHost(UIView *host) {
    if (!host.subviews.count) return NO;   // not built yet: ask again next pass
    // A yes stays yes; a no is checked again now and then, since the bar's page can be added later.
    NSArray *known = objc_getAssociatedObject(host, &kExcludedKey);
    CFTimeInterval now = CACurrentMediaTime();
    if (known && ([known[0] boolValue] || now - [known[1] doubleValue] < 2)) return [known[0] boolValue];
    BOOL excluded = NO;
    // Above the host only the bar's and the drawer's own containers count: every page sits under the tab
    // bar controller's views, whose names can hold "TabBar" too.
    for (UIView *v = host.superview; v && !excluded; v = v.superview) {
        NSString *name = NSStringFromClass(v.class);
        excluded = [name containsString:@"NowPlaying_Bar"] || [name containsString:@"SideDrawer"];
    }
    for (UIResponder *r = host.nextResponder; r && !excluded && ![r isKindOfClass:UIView.class]; r = r.nextResponder)
        excluded = isExcludedClass(r.class);
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithArray:host.subviews];
    NSUInteger seen = 0;
    while (stack.count && seen++ < 2500 && !excluded) {
        UIView *v = stack.lastObject; [stack removeLastObject];
        if ([v isKindOfClass:UICollectionViewCell.class] || [v isKindOfClass:UITableViewCell.class] ||
            [v isKindOfClass:MRGBackgroundView.class]) continue;
        if (isExcludedClass(v.class)) excluded = YES;
        [stack addObjectsFromArray:v.subviews];
    }
    objc_setAssociatedObject(host, &kExcludedKey, @[@(excluded), @(now)], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return excluded;
}

static BOOL isPageSized(UIView *host) {
    UIWindow *w = host.window;
    if (!w) return YES;   // laid out before it is on screen: judged again once it is
    CGSize page = host.bounds.size, screen = w.bounds.size;
    return page.width >= screen.width * 0.85 && page.height >= screen.height * 0.5;
}

static void attach(UIView *host, MRGScreen screen, BOOL onTop) {
    if (!host) return;
    if (!onTop && (!isPageSized(host) || isExcludedHost(host))) { detach(host); return; }
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

// Switching Library between grid and list (setCollectionViewLayout:animated:), a reload or batch updates
// hand the list new or re-configured cells after its layout pass, and Spotify may paint the list again; with
// no scroll nothing laid the list out again, so it stayed black until a touch. Each of these, and every
// layout pass, schedules one more clear on the next turn of the run loop (coalesced per list) and one after
// the layout animation. A list that replaced the old one (not tagged yet) gets its page walked again.
static char kPendingKey;

static UIView *backgroundHostOf(UIView *view) {
    for (UIView *v = view.superview; v; v = v.superview) {
        MRGBackgroundView *bg = objc_getAssociatedObject(v, &kBackgroundKey);
        if (bg && bg.superview == v && !bg.hidden) return v;
    }
    return nil;
}

static void clearListNow(UIScrollView *list) {
    if (isTaggedList(list)) {
        if (isCleared(list)) clearView(list);
        clearCells(list);
    } else if (MRGClearPages() && list.window) {
        // Only a list the page's size can be the page's main list; shelves and carousels are not walked for.
        UIView *host = backgroundHostOf(list);
        if (host && list.bounds.size.width >= host.bounds.size.width * 0.9 &&
            list.bounds.size.height >= host.bounds.size.height * 0.4) tagPageLists(host);
    }
}

static void scheduleListClear(UIScrollView *list, BOOL afterAnimation) {
    if (!sg_taggedLists) return;
    if (!objc_getAssociatedObject(list, &kPendingKey)) {
        objc_setAssociatedObject(list, &kPendingKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        __weak UIScrollView *weakList = list;
        dispatch_async(dispatch_get_main_queue(), ^{
            UIScrollView *l = weakList;
            if (!l) return;
            objc_setAssociatedObject(l, &kPendingKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            clearListNow(l);
        });
    }
    if (afterAnimation) {
        __weak UIScrollView *weakList = list;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            UIScrollView *l = weakList;
            if (l) clearListNow(l);
        });
    }
}

// A page-sized list that is not tagged yet (the grid and the list can be separate collection views, and the
// new one comes in after the page's last walk) is adopted on its own layout pass, once per size.
static char kCheckedSizeKey;
static void adoptListIfPage(UIScrollView *list) {
    if (!sg_taggedLists || isTaggedList(list) || !list.window || !MRGClearPages()) return;
    NSValue *checked = objc_getAssociatedObject(list, &kCheckedSizeKey);
    if (checked && CGSizeEqualToSize(checked.CGSizeValue, list.bounds.size)) return;
    objc_setAssociatedObject(list, &kCheckedSizeKey, [NSValue valueWithCGSize:list.bounds.size], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    UIView *host = backgroundHostOf(list);
    if (!host || list.bounds.size.width < host.bounds.size.width * 0.9 || list.bounds.size.height < host.bounds.size.height * 0.4) return;
    clearView(list);
    tagList(list);
    clearCells(list);
}

// The cell a view belongs to, if that cell sits in a tagged list (cells are the list's direct subviews).
static UIView *cellInTaggedList(UIView *view) {
    UIView *v = view;
    for (int i = 0; v && i < 8; i++, v = v.superview) {
        UIView *list = v.superview;
        if (([list isKindOfClass:UICollectionView.class] || [list isKindOfClass:UITableView.class]) &&
            ([v isKindOfClass:UICollectionReusableView.class] || [v isKindOfClass:UITableViewCell.class] ||
             [v isKindOfClass:UITableViewHeaderFooterView.class]))
            return isTaggedList(list) ? v : nil;
    }
    return nil;
}

static BOOL isDarkCG(CGColorRef color) {
    if (!color || CGColorGetAlpha(color) <= 0.9) return NO;
    size_t n = CGColorGetNumberOfComponents(color);
    const CGFloat *c = CGColorGetComponents(color);
    if (!c || n < 2) return NO;
    CGFloat hi = 0;
    for (size_t i = 0; i + 1 < n; i++) hi = MAX(hi, c[i]);
    return hi < 0.22;
}

static char kCellPendingKey;
static void scheduleCellClear(UIView *cell) {
    if (objc_getAssociatedObject(cell, &kCellPendingKey)) return;
    objc_setAssociatedObject(cell, &kCellPendingKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __weak UIView *weakCell = cell;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIView *c = weakCell;
        if (!c) return;
        objc_setAssociatedObject(c, &kCellPendingKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (cellInTaggedList(c) == c) clearCell(c);
    });
}

// The paint itself. Grid/list switches, reuse and Spotify's cell configuration paint cells after any pass of
// ours, which is why the list stayed black until a scroll. So while any list is tagged:
//  - a view Mirage cleared keeps its paint off: a new color is remembered as the one to put back;
//  - an opaque near-black paint inside a tagged list's cell is dropped if it is the cell, its content or
//    background view, or a view about the cell's size; a view not sized yet gets its cell cleared right after.
// Anything else is painted as asked, so artwork placeholders, badges and every other screen are untouched.

static BOOL dropsPaint(CALayer *layer, CGColorRef color) {
    if (!color || !sg_anyCleared) return NO;
    UIView *view = (UIView *)layer.delegate;
    if (![view isKindOfClass:UIView.class] || view.layer != layer) return NO;
    if (isCleared(view) && CGColorGetAlpha(color) > 0.01) {
        // A cell's fill was cleared for being near-black; a reused cell painted a real color keeps it.
        if (objc_getAssociatedObject(view, &kDarkOnlyKey) && !isDarkCG(color)) {
            objc_setAssociatedObject(view, &kClearedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(view, &kDarkOnlyKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            return NO;
        }
        objc_setAssociatedObject(view, &kOriginalColorKey, [UIColor colorWithCGColor:color], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return YES;
    }
    if (!sg_taggedLists || !isDarkCG(color)) return NO;
    if ([view isKindOfClass:UIImageView.class] || [view isKindOfClass:UIVisualEffectView.class]) return NO;
    UIView *cell = cellInTaggedList(view);
    if (!cell) return NO;
    CGSize cs = cell.bounds.size, vs = view.bounds.size;
    BOOL sized = cs.width > 0 && vs.width > 0;
    BOOL cellish = view == cell || view.superview == cell ||
                   (sized && vs.width >= cs.width * 0.9 && vs.height >= cs.height * 0.8);
    if (!cellish) {
        if (!sized) {
            if (NSThread.isMainThread) scheduleCellClear(cell);
            else { __weak UIView *weakCell = cell; dispatch_async(dispatch_get_main_queue(), ^{ if (weakCell) scheduleCellClear(weakCell); }); }
        }
        return NO;
    }
    objc_setAssociatedObject(view, &kClearedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(view, &kDarkOnlyKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(view, &kOriginalColorKey, [UIColor colorWithCGColor:color], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return YES;
}

%group MRGLists
%hook CALayer
- (void)setBackgroundColor:(CGColorRef)color {
    if (dropsPaint(self, color)) color = UIColor.clearColor.CGColor;
    %orig(color);
}
%end

// A cell clears itself as it comes on screen or takes its place in a new layout, scroll or not.
%hook UICollectionReusableView
- (void)didMoveToWindow { %orig; if (self.window && sg_taggedLists && cellInTaggedList(self) == self) clearCell(self); }
- (void)applyLayoutAttributes:(UICollectionViewLayoutAttributes *)attributes {
    %orig;
    if (sg_taggedLists && cellInTaggedList(self) == self) clearCell(self);
}
%end
%hook UITableViewCell
- (void)didMoveToWindow { %orig; if (self.window && sg_taggedLists && cellInTaggedList(self) == self) clearCell(self); }
%end

%hook UICollectionView
- (void)layoutSubviews {
    %orig;
    if (isTaggedList(self)) { clearCells(self); scheduleListClear(self, NO); }
    else adoptListIfPage(self);
}
- (void)reloadData { %orig; scheduleListClear(self, NO); }
- (void)setCollectionViewLayout:(UICollectionViewLayout *)layout animated:(BOOL)animated {
    %orig;
    scheduleListClear(self, YES);
}
- (void)setCollectionViewLayout:(UICollectionViewLayout *)layout animated:(BOOL)animated completion:(void (^)(BOOL))completion {
    __weak UICollectionView *weakSelf = self;
    %orig(layout, animated, ^(BOOL finished) {
        if (completion) completion(finished);
        UICollectionView *list = weakSelf;
        if (list) clearListNow(list);
    });
    scheduleListClear(self, YES);
}
- (void)performBatchUpdates:(void (^)(void))updates completion:(void (^)(BOOL))completion {
    if (!sg_taggedLists) { %orig; return; }
    __weak UICollectionView *weakSelf = self;
    %orig(updates, ^(BOOL finished) {
        if (completion) completion(finished);
        UICollectionView *list = weakSelf;
        if (list) clearListNow(list);
    });
}
%end
%hook UITableView
- (void)layoutSubviews {
    %orig;
    if (isTaggedList(self)) { clearCells(self); scheduleListClear(self, NO); }
    else adoptListIfPage(self);
}
- (void)reloadData { %orig; scheduleListClear(self, NO); }
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
