// Redesign: "Find on this page" (Liked Songs and any other playlist). It is the plain system UISearchBar
// (id=PL.SearchViewController.SearchBar), not one of Spotify's Encore fields, and its field is a flat
// _UISearchBarSearchFieldBackgroundView, bg=#767680@0.24 r=10. It becomes a glass
// capsule like the redesign's other search fields (Navbar/SearchField.x). The bar's own backing (_UISearchBarBackground,
// the grey or black strip behind the field) is drawn by nothing and Cancel, once the field is focused, is a glass
// capsule too, so the field and Cancel float over the page.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"

static char kBoxKey, kGlassKey, kCancelGlassKey;

// Room Cancel's capsule takes past its button on each side.
static const CGFloat kCancelPadding = 6;

// The search field's own background view: Apple's private class, found by name since its identifier is
// nothing and its class isn't exported to link against.
static UIView *searchFieldBoxIn(UIView *bar) {
    UIView *cached = objc_getAssociatedObject(bar, &kBoxKey);
    if (cached && cached.superview) return cached;
    __block UIView *found = nil;
    SGForEachView(bar, ^(UIView *v) {
        if (!found && [NSStringFromClass(v.class) containsString:@"SearchBarSearchFieldBackgroundView"]) found = v;
    });
    if (found) objc_setAssociatedObject(bar, &kBoxKey, found, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return found;
}

// Cancel: the bar's button outside the field (the clear and bookmark buttons are inside it). UIKit builds it when the field
// is focused, as a private UIButton subclass, so it is told by being a button the field does not hold.
static UIView *cancelIn(UIView *bar, UIView *box) {
    // The field is the box's parent (the text field holding the background, the magnifier and the clear button).
    UIView *field = box.superview != bar ? box.superview : box;
    __block UIView *found = nil;
    SGForEachView(bar, ^(UIView *v) {
        if (found || ![v isKindOfClass:UIButton.class] || v.bounds.size.width < 1 || v.bounds.size.width > 140) return;
        if (field && [v isDescendantOfView:field]) return;
        found = v;
    });
    return found;
}

// The strip UIKit draws behind a search bar: faded out rather than hidden, which UIKit sets back.
static void clearBackdrop(UIView *bar) {
    for (UIView *sub in bar.subviews) {
        if ([NSStringFromClass(sub.class) containsString:@"SearchBarBackground"] && sub.alpha != 0) sub.alpha = 0;
    }
}

%hook SPTSearchBar
- (void)layoutSubviews {
    %orig;
    UIView *bar = (UIView *)self;
    if (![bar.accessibilityIdentifier isEqualToString:@"PL.SearchViewController.SearchBar"]) return;
    UIView *box = searchFieldBoxIn(bar);
    SGRGlassFlatBox(box, &kGlassKey, NO);
    clearBackdrop(bar);
    UIView *cancel = cancelIn(bar, box);
    if (cancel && box) {
        SGRUnclipUpTo(cancel, ^BOOL(UIView *v) { return v.superview == bar.superview; });
        SGRGlassCapsuleInside(cancel, &kCancelGlassKey, CGSizeMake(cancel.bounds.size.width + 2 * kCancelPadding, box.bounds.size.height), NO);
    }
    static BOOL logged;
    if (!logged && bar.window) {
        logged = YES;
        SGLog(@"redesign playlist: find-on-page search bar %@ in glass", NSStringFromCGRect(bar.bounds));
    }
}
%end

%ctor {
    if (!SGRedesignedUI()) return;
    if (!SGBelowiOS26()) return;
    %init;
    SGRequireClasses(@[@"SPTSearchBar"]);
}
