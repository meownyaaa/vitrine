// Glass for UIKit's own context menus: the player's ⋯ menu (the row of Add to playlist / Share / Add to Queue
// over the list, Speed and the rest) and every other menu Spotify opens the same way. ContextMenu.x makes the
// menu; this is only its look.
//
// Tree: _UIContextMenuContainerView > _UIContextMenuPlatterTransitionView >
// _UIContextMenuView > _UIContextMenuListView, one for the menu and one more for a submenu, each holding a
// _UICutoutShadowView and a clipping UIView (the platter) with UIKit's own UIVisualEffectView and the menu's
// UICollectionView in it. The platter's blur is hidden and a glass pane, the heavy kind a sheet gets
// (SGRThickenSheetGlass), goes behind its content. The labels are drawn #000000@0.96, the light appearance the
// menu takes from a phone in light mode, so the list is made dark like the rest of the glass.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Redesigned/ContextMenu/ContextMenu.h"

// The corners UIKit cuts a menu with. Rounder ones, as iOS 26's menus have, were tried (24 pt): UIKit's own shape under
// the platter (its shadow and cut-out) kept its 14 pt corners, and the glass's rim light ran round the rounder ones over
// them, so the menu keeps UIKit's.
static const CGFloat kMenuRadius = 14;
static char kMenuGlassKey;

// The view holding UIKit's blur: the menu's own surface. Found by the blur rather than by how the platter is
// clipped, since a submenu (More) is another list that UIKit builds when it opens, and its platter is not
// guaranteed to be clipped or to hold the blur at the first level the top menu does. The mod's own pane is
// skipped, which is a UIVisualEffectView too when it is not the legacy glass.
static UIView *platterIn(UIView *view, int depth) {
    if (depth > 3) return nil;
    for (UIView *sub in view.subviews) {
        if ([sub isKindOfClass:UIVisualEffectView.class]) {
            if (objc_getAssociatedObject(view, &kMenuGlassKey) == sub) continue;
            if (object_getClass(view) == UIView.class) return view;
            continue;
        }
        if ([sub isKindOfClass:NSClassFromString(@"_UIContextMenuListView")]) continue;
        UIView *found = platterIn(sub, depth + 1);
        if (found) return found;
    }
    return nil;
}

// The menu's glass: a pane on `host` (a menu's platter, or the chrome of the player's sliders panel) with the
// body, rim and dim of a sheet's. One place, so what opens from the ⋯ looks like the menu it opens from.
// Nil while `host` has no size yet. Below iOS 26 only: the system draws its own on 26.
static UIView *menuGlass(UIView *host, const void *key, CGFloat dim, CGFloat radius) {
    if (host.bounds.size.width < 1 || host.bounds.size.height < 1) return nil;
    UIView *glass = SGRGlassPaneIn(host, key, radius);
    SGRDimSheetGlass(glass, dim);
    return glass;
}

UIView *SGRMenuGlass(UIView *host, const void *key, CGFloat dim) {
    return menuGlass(host, key, dim, kMenuRadius);
}

static void glassMenu(UIView *list) {
    UIView *platter = platterIn(list, 0);
    if (!platter || platter.bounds.size.width < 1 || platter.bounds.size.height < 1) return;
    if (list.overrideUserInterfaceStyle != UIUserInterfaceStyleDark) list.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;

    UIView *glass = menuGlass(platter, &kMenuGlassKey, SGRMenuDim, kMenuRadius);

    // UIKit's own blur goes; the pane above is the mod's, which is a UIVisualEffectView too when it is not
    // the legacy glass.
    for (UIView *sub in platter.subviews) {
        if (sub != glass && [sub isKindOfClass:UIVisualEffectView.class] && !sub.hidden) sub.hidden = YES;
    }

    static dispatch_once_t once;
    dispatch_once(&once, ^{ SGLog(@"context menu: glass over a platter of %@", NSStringFromCGRect(platter.bounds)); });
}

// Every list inside `root` glassed: a submenu's list is made when it opens, often after the menu's own passes,
// and UIKit may lay it out only inside the transition.
static void glassLists(UIView *root) {
    Class list = NSClassFromString(@"_UIContextMenuListView");
    SGForEachView(root, ^(UIView *view) {
        if ([view isKindOfClass:list]) glassMenu(view);
    });
}

// The menu's first list opens out of a drop of glass from the control it was opened from, as iOS 26's menus do
// (Kit/SGRGlassMotion.h); a submenu's list, made later in the same menu, comes in as UIKit has it.
static char kBubbledKey;

static void bubbleMenu(UIView *list) {
    UIView *menu = list.superview;
    while (menu && ![menu isKindOfClass:NSClassFromString(@"_UIContextMenuView")]) menu = menu.superview;
    if (!menu || objc_getAssociatedObject(menu, &kBubbledKey)) return;
    objc_setAssociatedObject(menu, &kBubbledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    SGRGlassBubbleOpen(list, kMenuRadius);
}

%hook _UIContextMenuListView
- (void)didMoveToWindow {
    %orig;
    if (((UIView *)self).window) {
        glassMenu((UIView *)self);
        bubbleMenu((UIView *)self);
        // Again once it has settled: the first pass can come before the platter has its blur or its size.
        SGRRepeatViewPass((UIView *)self, @[@0, @0.15, @0.45], ^(UIView *v) { glassMenu(v); });
    }
}

- (void)layoutSubviews {
    %orig;
    glassMenu((UIView *)self);
}
%end

// A long menu (a playlist's, some twenty rows) runs nearly the height of the screen, and still scrolls; it is held to a
// shorter list that scrolls, so it stays a menu by the button rather than a sheet over the page.
static const CGFloat kMenuMaxShare = 0.55;

// Never while a submenu is open: a list held to its height under a submenu UIKit lays out round the full one moves
// and cuts the two.
static void holdHeight(UIView *menuView) {
    CGFloat most = round(menuView.window.bounds.size.height * kMenuMaxShare);
    if (most < 100) return;
    Class list = NSClassFromString(@"_UIContextMenuListView");
    NSUInteger lists = 0;
    for (UIView *sub in menuView.subviews) if ([sub isKindOfClass:list]) lists++;
    if (lists > 1) return;
    for (UIView *sub in menuView.subviews) {
        if (![sub isKindOfClass:list] || sub.bounds.size.height <= most + 0.5) continue;
        CGRect frame = sub.frame;
        frame.size.height = most;
        sub.frame = frame;
        [sub layoutIfNeeded];
        // Its platter and its list of rows, laid out from its height, are held to it as well.
        SGForEachView(sub, ^(UIView *v) {
            if (v == sub || v.bounds.size.height <= most + 0.5) return;
            if (![v isKindOfClass:UICollectionView.class] && object_getClass(v) != UIView.class) return;
            CGRect f = v.frame;
            f.size.height = MAX(0, most - f.origin.y);
            v.frame = f;
        });
    }
}

// A submenu open (the player's More) stands alone, as on iOS 26: the menu under it, which UIKit below iOS 26 leaves slid
// down and dimmed behind it, fades out while it is up and back as it closes. The lists are laid one over the other, the
// submenu's last; only alpha is touched, on views of UIKit's own menu, which UIKit puts back as it lays them out again.
static const NSTimeInterval kSubmenuFade = 0.2;
// A submenu this much shorter than it was at its tallest is closing back into its row.
static const CGFloat kClosingShare = 0.8;
static char kUnderKey, kTallestKey;

static void fadeList(UIView *list, BOOL under) {
    BOOL was = [objc_getAssociatedObject(list, &kUnderKey) boolValue];
    if (under == was && (!under || list.alpha < 0.01)) return;
    objc_setAssociatedObject(list, &kUnderKey, @(under), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    // Back at once and quickly: the menu has to be there as the submenu shrinks into its row, not after.
    [UIView animateWithDuration:under ? kSubmenuFade : kSubmenuFade / 2 delay:0 options:UIViewAnimationOptionBeginFromCurrentState
                     animations:^{ list.alpha = under ? 0 : 1; } completion:nil];
}

static void hideUnder(UIView *menuView) {
    Class list = NSClassFromString(@"_UIContextMenuListView");
    NSMutableArray<UIView *> *lists = [NSMutableArray array];
    for (UIView *sub in menuView.subviews) if ([sub isKindOfClass:list]) [lists addObject:sub];
    UIView *top = lists.lastObject;
    // The submenu's tallest so far: UIKit sets a closing list's frame to its row's at once and animates the rest, so a
    // shorter one is a submenu on its way out, and the menu under it comes back as it starts to go rather than once it
    // has gone, which would leave More's row alone in the air a moment.
    BOOL closing = NO;
    if (lists.count > 1) {
        CGFloat height = top.bounds.size.height;
        CGFloat tallest = MAX(height, [objc_getAssociatedObject(top, &kTallestKey) doubleValue]);
        objc_setAssociatedObject(top, &kTallestKey, @(tallest), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        closing = height < tallest * kClosingShare;
    }
    for (UIView *each in lists) fadeList(each, each != top && !closing);
}

// The menu's own view lays out as a submenu comes in or goes out, which reaches the lists it holds.
%hook _UIContextMenuView
- (void)layoutSubviews {
    %orig;
    holdHeight((UIView *)self);
    glassLists((UIView *)self);
    hideUnder((UIView *)self);
}
%end

%ctor {
    if (!SGRedesignedUI()) return;
    // iOS 26 draws its own Liquid Glass on menus; the mod's pane would cover it.
    if (!SGBelowiOS26()) return;
    %init;
    SGRequireClasses(@[@"_UIContextMenuListView", @"_UIContextMenuView"]);
}
