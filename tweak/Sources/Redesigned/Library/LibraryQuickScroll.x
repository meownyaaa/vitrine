// Library redesign, iOS < 26: the quick scroll on glass, and the list down to the bottom of the page.
//
// Tree (trees/continuous/1.txt, 2026-10-26): over the list, in YourLibraryContentView, a QuickScroll_CommonImpl.QuickScrollView
// 390x697 holds the date badge, a QuickScrollIndicator 80x28 #262626 r=14 with an Encore label ("Oct 2026"), and the handle, a
// QuickScrollHandle 48x48 #262626 r=24 clipped, with its two arrows. Each is a glass capsule that fills it (SGRGlassFillBox),
// as the library's chips and the header's buttons are, in place of the flat grey; a grey Spotify sets again is kept off.
//
// In the same tree the list, YourLibraryCollectionView, is 697pt tall in a YourLibraryContentView of 749 (the content view
// raised under the chips by LibraryHeader.x's raiseList, the list left at the height Spotify gave it), so the last 52pt of
// the page, under the tab bar, were the page's black and no row ever scrolled there. The list is made to reach the content
// view's bottom and its bottom inset grows by as much, so its last row still stops where it stopped. The search results
// and a folder hold the same content view and list.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Library.h"

static char kQuickGlassKey, kBottomInsetKey;

static void glassQuick(UIView *view) {
    if (!view.window) return;
    SGRGlassFillBox(view, &kQuickGlassKey, NO);
}

%hook _TtC22QuickScroll_CommonImpl20QuickScrollIndicator
- (void)layoutSubviews {
    %orig;
    glassQuick((UIView *)self);
}

- (void)setBackgroundColor:(UIColor *)color {
    %orig(objc_getAssociatedObject(self, &kQuickGlassKey) ? UIColor.clearColor : color);
}
%end

%hook _TtC22QuickScroll_CommonImpl17QuickScrollHandle
- (void)layoutSubviews {
    %orig;
    glassQuick((UIView *)self);
}

- (void)setBackgroundColor:(UIColor *)color {
    %orig(objc_getAssociatedObject(self, &kQuickGlassKey) ? UIColor.clearColor : color);
}
%end

// The list stretched to the content view's bottom; the inset Spotify sets is read off the list and the stretch added to it,
// and put back whenever Spotify sets it again (told by the value not being the one written here).
static void reachBottom(UIView *content) {
    UIScrollView *list = nil;
    for (UIView *sub in content.subviews) {
        if ([sub isKindOfClass:UIScrollView.class] && [sub.accessibilityIdentifier isEqualToString:SGRLibraryListIdentifier]) list = (UIScrollView *)sub;
    }
    if (!list) return;
    CGFloat gap = content.bounds.size.height - CGRectGetMaxY(list.frame);
    NSNumber *written = objc_getAssociatedObject(list, &kBottomInsetKey);
    if (gap > 0.5 && gap < content.bounds.size.height / 2) {
        CGRect frame = list.frame;
        frame.size.height += gap;
        list.frame = frame;
        UIEdgeInsets inset = list.contentInset;
        // Ours already in it when the frame alone went back: only the frame is stretched again.
        if (!written || fabs(inset.bottom - written.doubleValue) >= 0.5) {
            inset.bottom += gap;
            list.contentInset = inset;
            UIEdgeInsets bar = list.verticalScrollIndicatorInsets;
            bar.bottom += gap;
            list.verticalScrollIndicatorInsets = bar;
            objc_setAssociatedObject(list, &kBottomInsetKey, @(inset.bottom), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            static dispatch_once_t once;
            dispatch_once(&once, ^{ SGLog(@"redesign library: list taken %.0fpt down to the page's bottom", gap); });
        }
    }
}

%hook _TtC21YourLibrary_CommonKit22YourLibraryContentView
- (void)layoutSubviews {
    %orig;
    reachBottom((UIView *)self);
}
%end

%ctor {
    if (!SGRedesignedUI() || !SGBelowiOS26()) return;
    %init;
    SGRequireClasses(@[
        @"_TtC22QuickScroll_CommonImpl20QuickScrollIndicator",
        @"_TtC22QuickScroll_CommonImpl17QuickScrollHandle",
        @"_TtC21YourLibrary_CommonKit22YourLibraryContentView",
    ]);
}
