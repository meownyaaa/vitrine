// Spotify's Equalizer (Settings > Playback > Equalizer, SPTEqualizerViewController): the redesign's bar over the page
// (Pages/PageBar.m), the curve right under it and the presets running down under the bars.
//
// Tree (trees/continuous/4.txt, 2026-10-26): the page, hosted by Spotify's page template, is a UIView 390x792 holding an
// SPTEqualizerView {0, 135} 390x518: an SPTEqualizerColumnView 390x255 (the knobs and the bands' names) over an SPTTableView
// {0, 255} 390x263 #000000 clipped, the Equalizer switch and the presets in it. Over the page the navigation controller's
// blur (390x91, #1C1C1C@0.73) and SPNavigationBar with Back and the title. So the curve stood 44pt under the bar with
// nothing above it, and the list stopped at 653 with the presets past it cut off and the page's black under the now
// playing bar and the tab bar. The blur goes and Back and the title are glass, as on the other pages; the view starts
// where the bar ends and reaches the page's bottom, and the list fills the rest with an inset that lets its last preset
// scroll clear of the bars.
// Threading: main thread only.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Pages.h"

// How far the now playing bar and the tab bar reach up over `view`, in its own space: they float over the page.
static CGFloat barsOver(UIView *view) {
    UIWindow *window = view.window;
    if (!window) return 0;
    __block CGFloat top = CGFLOAT_MAX;
    SGForEachView(window, ^(UIView *v) {
        NSString *name = NSStringFromClass(v.class);
        BOOL bar = [name containsString:@"NowPlaying_BarPageImpl"] || [name isEqualToString:@"_TtC23NavigationUI_TabBarImpl10TabBarView"];
        if (!bar || v.hidden || v.alpha < 0.01 || v.bounds.size.height < 1) return;
        top = MIN(top, [v convertRect:v.bounds toView:window].origin.y);
    });
    if (top == CGFLOAT_MAX) return 0;
    CGFloat bottom = CGRectGetMaxY([view convertRect:view.bounds toView:window]);
    return MAX(0, bottom - top);
}

static UIView *childOf(UIView *view, NSString *name) {
    for (UIView *sub in view.subviews) {
        if ([NSStringFromClass(sub.class) isEqualToString:name]) return sub;
    }
    return nil;
}

static char kMeasuredKey;

// The list under the column, to the view's bottom. From the view's own passes, which lay the list out again.
static void fitList(UIView *equalizer) {
    UIView *column = childOf(equalizer, @"SPTEqualizerColumnView");
    UIView *found = childOf(equalizer, @"SPTTableView");
    if (!column || ![found isKindOfClass:UITableView.class]) return;
    UITableView *list = (UITableView *)found;
    CGFloat top = CGRectGetMaxY(column.frame);
    CGRect frame = CGRectMake(0, top, equalizer.bounds.size.width, MAX(0, equalizer.bounds.size.height - top));
    if (!CGRectEqualToRect(list.frame, frame)) list.frame = frame;
    // The bars are looked for over the whole window, so only when the list stands somewhere new: the view lays out on
    // every frame of the Equalizer switch's animation, which a walk of the window each time made stutter.
    CGRect inWindow = [list convertRect:list.bounds toView:nil];
    NSValue *measured = objc_getAssociatedObject(list, &kMeasuredKey);
    if (!list.window || (measured && CGRectEqualToRect(measured.CGRectValue, inWindow))) return;
    objc_setAssociatedObject(list, &kMeasuredKey, [NSValue valueWithCGRect:inWindow], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    CGFloat bottom = barsOver(list);
    if (fabs(list.contentInset.bottom - bottom) < 0.5) return;
    UIEdgeInsets inset = list.contentInset;
    inset.bottom = bottom;
    list.contentInset = inset;
    list.verticalScrollIndicatorInsets = inset;
}

// The view from the bar's bottom (the page's top safe area) to the page's bottom.
static void fitPage(UIViewController *page) {
    UIView *root = page.viewIfLoaded;
    UIView *equalizer = root ? childOf(root, @"SPTEqualizerView") : nil;
    if (!equalizer) return;
    CGFloat top = root.safeAreaInsets.top;
    CGRect frame = CGRectMake(0, top, root.bounds.size.width, MAX(0, root.bounds.size.height - top));
    if (!CGRectEqualToRect(equalizer.frame, frame)) equalizer.frame = frame;
    fitList(equalizer);
    static dispatch_once_t once;
    dispatch_once(&once, ^{ SGLog(@"redesign equalizer: view at %@, list under the bars", NSStringFromCGRect(frame)); });
}

%hook SPTEqualizerView
- (void)layoutSubviews {
    %orig;
    fitList((UIView *)self);
}
%end

%ctor {
    if (!SGRedesignedUI() || !SGBelowiOS26()) return;
    Class page = NSClassFromString(@"SPTEqualizerViewController");
    if (!page) {
        SGLog(@"class SPTEqualizerViewController not found, the Equalizer keeps Spotify's bar");
        return;
    }
    %init;
    SGRDressBarPagesWith(page, YES, ^(UIViewController *c) {
        SGRDressBarPageBackOnly(c);
        fitPage(c);
    });
}
