// Recents, the listening history: the redesign's bar over the list (Pages/PageBar.m), its chips on glass, and the
// list run under the bars at the top and the bottom.
//
// Tree: the page is a plain view holding an Encore StackView of the chips (Podcasts, Music: the same Encore ChipView
// and PillView as Liked Songs', Kit/SGRChips.h) and the list, a UICollectionView on #000000, in that order. The
// stack starts at the bar's bottom and stopped where the tab bar and the now playing bar begin, so the last rows
// were cut off short of them, leaving a black margin where every other redesigned list runs on under glass.
//
// So the stack is made as tall as the page from where it starts, and what the bars below took of the stack goes to
// the list as its bottom inset: the last row clears them. The chips stay first in the stack, where Spotify put
// them. Bringing them to the front put them at the bottom of the page, since the stack arranges its views in
// order. The frames are set again after every pass of the view the stack stands in and of the stack, since
// Spotify's constraints and the stack's layout put them back.
//
// The list began where the chips end and clipped there, so rows scrolled up and were cut off in a straight line under
// the chips, leaving a black band over the top of the page (the list {0, 52} in a stack at y=91). Now the list is as
// tall as the whole page, from its top edge, with the bar and the chips as its top inset, so rows run on up under the
// glass chips and the title as they do in the library. The chips are drawn above the list by their layer's zPosition
// (their place in the stack is untouched), and the list gives up the touches that fall on the chips, which it would
// otherwise take, being over them.
//
// The chips of a filter that has just been picked (Clear filter, Saved, Played) are made by Spotify after the page's
// own layout, which never met them, so they stayed flat grey. The row they are made in is watched for its own layout,
// and every chip in it is dressed as it comes.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Pages.h"

static char kListKey, kHeaderKey;

// What shares the stack with the list: the row of chips.
static UIView *chipsBesides(UIView *list) {
    for (UIView *sub in list.superview.subviews) {
        if (sub != list) return sub;
    }
    return nil;
}

static void extendRecentsList(UIView *page, UICollectionView *list) {
    UIView *stack = list.superview;
    UIView *host = stack.superview;
    UIView *chips = chipsBesides(list);
    if (!host || !chips) return;
    CGFloat pageHeight = host.bounds.size.height;
    // The stack from where it starts to the foot of the page; the bars below become the list's bottom inset.
    SGRListRoom room = SGRListRoomOf(stack);
    SGRSetOwnFrame(stack, CGRectMake(stack.frame.origin.x, room.top, stack.frame.size.width, pageHeight - room.top));

    // The list from the top edge of the page to its bottom, over the chips; they are drawn above it.
    CGFloat under = CGRectGetMaxY(chips.frame);
    CGRect listFrame = CGRectMake(0, -room.top, stack.bounds.size.width, pageHeight);
    if (listFrame.size.height > 0 && !CGRectEqualToRect(list.frame, listFrame)) list.frame = listFrame;
    if (stack.clipsToBounds) stack.clipsToBounds = NO;
    if (chips.layer.zPosition != 1) chips.layer.zPosition = 1;
    // Where the list gives its touches up to the chips, in the stack's coordinates.
    NSNumber *zone = objc_getAssociatedObject(list, &kHeaderKey);
    if (!zone || fabs(zone.doubleValue - under) > 0.5) objc_setAssociatedObject(list, &kHeaderKey, @(under), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    // The bar and the chips are the list's top inset, the bars below its bottom inset.
    SGRSetListInsets(list, UIEdgeInsetsMake(room.top + under, 0, MAX(room.below, page.safeAreaInsets.bottom), 0));
}

// The row of chips scrolls inside the chips view: the chips of a filter just picked are put there after the page's
// own layout, so the scroll view is watched, and every chip in it is dressed (a chip already dressed is left be).
static UIScrollView *chipsScrollIn(UIView *chips) {
    __block UIScrollView *found = nil;
    SGForEachView(chips, ^(UIView *v) {
        if (!found && [v isKindOfClass:UIScrollView.class]) found = (UIScrollView *)v;
    });
    return found;
}

static void watchChips(UIView *chips) {
    SGRWatchLayout(chipsScrollIn(chips), ^(UIView *laidOut) { SGRGlassChipsIn(laidOut); });
}

static void dress(UIViewController *page) {
    SGRDressBarPage(page);
    UIView *view = page.viewIfLoaded;
    if (!view.window) return;
    UICollectionView *list = SGRPageListIn(view, &kListKey);
    if (!list) return;
    UIView *chips = chipsBesides(list);
    SGRGlassChipsIn(chips);
    watchChips(chips);
    extendRecentsList(view, list);
    // Spotify's constraints set the stack back after each pass of the view it is in, and the stack sets the list
    // back after each pass of its own.
    __weak UIViewController *weakPage = page;
    for (UIView *watched in @[list.superview.superview ?: view, list.superview]) {
        SGRWatchLayout(watched, ^(UIView *laidOut) {
            UIView *root = weakPage.viewIfLoaded;
            UICollectionView *found = root ? SGRPageListIn(root, &kListKey) : nil;
            if (found) extendRecentsList(root, found);
        });
    }
}

%group SGRRecents
// The list is over the chips, so the touches that fall on them are not its: it is not hit there. Only the list of
// this page carries kHeaderKey.
%hook UICollectionView
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    NSNumber *zone = objc_getAssociatedObject(self, &kHeaderKey);
    if (zone) {
        UIView *list = (UIView *)self;
        if (list.superview && [list convertPoint:point toView:list.superview].y < zone.doubleValue) return NO;
    }
    return %orig;
}
%end

%end

%ctor {
    if (!SGRedesignedUI() || !SGBelowiOS26()) return;
    Class page = SGRSwiftClass(@"Recents_RecentsPageImpl", @"RecentsViewController");
    if (!page) {
        SGLog(@"class Recents_RecentsPageImpl.RecentsViewController not found, Recents keeps Spotify's bar");
        return;
    }
    %init(SGRRecents);
    // The bar's buttons, the chips and the rows are made after the first layout.
    SGRDressBarPagesWith(page, NO, ^(UIViewController *c) { dress(c); });
}
