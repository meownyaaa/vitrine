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
// view and their full-size wrappers) are made clear, and stay clear even if Spotify or Vitrine sets
// a color again later. Cells, cards, bars and Vitrine's glass are left alone, so the glass now samples
// the background instead of a flat fill.
#import "MRGPrefs.h"
#import "MRGBackgroundView.h"
#import <objc/runtime.h>

static char kBackgroundKey, kClearedKey, kOriginalColorKey;
// Views cleared so far; while none are, the setBackgroundColor: hook does nothing but compare this.
static NSUInteger sg_clearedCount;

#pragma mark - clearing a page's fills

static BOOL isCleared(UIView *v) { return sg_clearedCount && objc_getAssociatedObject(v, &kClearedKey) != nil; }

static void clearView(UIView *v) {
    if (isCleared(v)) return;
    UIColor *original = v.backgroundColor;
    objc_setAssociatedObject(v, &kOriginalColorKey, original ?: (id)NSNull.null, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(v, &kClearedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    sg_clearedCount++;
    v.backgroundColor = UIColor.clearColor;   // goes through the hook below, which lets clear through
    if ([v isKindOfClass:UICollectionView.class]) ((UICollectionView *)v).backgroundView.alpha = 0;
    if ([v isKindOfClass:UITableView.class]) ((UITableView *)v).backgroundView.alpha = 0;
}

static void restoreView(UIView *v) {
    if (!isCleared(v)) return;
    id original = objc_getAssociatedObject(v, &kOriginalColorKey);
    objc_setAssociatedObject(v, &kClearedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (sg_clearedCount) sg_clearedCount--;
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
        CGSize s = sub.bounds.size;
        if (s.width < page.width * 0.9 || s.height < page.height * 0.6) continue;
        block(sub);
        forEachFullSizeView(sub, page, depth + 1, block);
    }
}

#pragma mark - attaching

static void detach(UIView *host) {
    MRGBackgroundView *bg = objc_getAssociatedObject(host, &kBackgroundKey);
    if (!bg) return;
    [bg removeFromSuperview];
    objc_setAssociatedObject(host, &kBackgroundKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    restoreView(host);
    forEachFullSizeView(host, host.bounds.size, 0, ^(UIView *v) { restoreView(v); });
}

static void attach(UIView *host, MRGScreen screen, BOOL onTop) {
    if (!host) return;
    if (!MRGWantsScreen(screen)) { detach(host); return; }
    MRGBackgroundView *bg = objc_getAssociatedObject(host, &kBackgroundKey);
    if (!bg) {
        bg = [[MRGBackgroundView alloc] initWithFrame:host.bounds];
        objc_setAssociatedObject(host, &kBackgroundKey, bg, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
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
    }
}

#pragma mark - keeping cleared views clear

%hook UIView
- (void)setBackgroundColor:(UIColor *)color {
    if (isCleared(self) && color && CGColorGetAlpha(color.CGColor) > 0) {
        // Remember what Spotify (or Vitrine) wanted, for when the background is turned off.
        objc_setAssociatedObject(self, &kOriginalColorKey, color, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }
    %orig;
}
%end

#pragma mark - screens

%group MRGHome
%hook _TtC19Home_FunkisPageImpl20FunkisViewController
- (void)viewDidLayoutSubviews { %orig; attach(((UIViewController *)self).view, MRGScreenHome, NO); }
%end
%end

%group MRGHomeEvo
%hook _TtC16Home_EvoPageImpl33EvoLoadableResourceViewController
- (void)viewDidLayoutSubviews { %orig; attach(((UIViewController *)self).view, MRGScreenHome, NO); }
%end
%end

%group MRGLibrary
%hook _TtC28YourLibrary_YourLibraryXImpl25YourLibraryViewController
- (void)viewDidLayoutSubviews { %orig; attach(((UIViewController *)self).view, MRGScreenLibrary, NO); }
%end
%end

// The plane is laid out on every scroll frame (Vitrine, Redesigned/Player/PlayerField.x), so attach()
// only compares a frame on the way. The background goes over the plane's own gradients (and over
// Vitrine's artwork field, which sits there too) but stays under the player's cards and controls,
// which are not in this view.
%group MRGNowPlaying
%hook _TtC21NowPlaying_ScrollImpl27NPVBackgroundViewController
- (void)viewDidLayoutSubviews { %orig; attach(((UIViewController *)self).view, MRGScreenNowPlaying, YES); }
%end
%end

%group MRGEverywhere
%hook _TtC33Navigation_PageAPIIntegrationImpl33MusicAppPageHostingViewController
- (void)viewDidLayoutSubviews { %orig; attach(((UIViewController *)self).view, MRGScreenEverywhere, NO); }
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
        %init;   // UIView
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
