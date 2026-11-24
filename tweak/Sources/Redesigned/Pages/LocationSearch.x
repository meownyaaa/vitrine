// The Preferred Location page, reached from an artist's concerts by Change location
// (LiveEvents_LiveEventsImpl.LocationSearchViewController): the title on a glass capsule, Back a glass circle and the
// search field on glass, over a header that is no longer opaque.
//
// Tree: the page has no navigation bar (SPNavigationBar is not on screen, Spotify's blur is 390x0 and hidden). Its
// view, LocationSearchView, holds a plain UIView 390x143 painted #000000, the table (LocationSearchView.tableView,
// from y=143), and LocationSearchHeaderView (Components.UI.LocationHeaderSearch, 390x96 at y=47): a 48pt row with the
// title label "Preferred Location" and Back (an Encore Tertiary button, 32x32, a11y "Back"), then the field
// (Components.Header.UI.Toolbar.SearchField, a 358x32 text field, #FFFFFF@0.14 r=4).
//
// So the black plate is taken off, the title label gets the capsule the other pages' titles have (Pages/PageBar.m,
// the same padding and height, white), Back is pinned to the corner as on every redesigned page (the Encore button is
// concealed and fired by the glass circle), and the field is glass the way Liked Songs' find field is (SGRGlassFlatBox;
// SGRRepaint.x keeps Spotify's grey off it as it is focused, as it does for the podcast search field).
//
// Trees: the header and the field are on glass already. Three things were left:
//  - The plate behind the header (the 414x144 UIView, hidden) stays hidden with nothing in its place: the header as a whole
//    has no glass behind it, only the title capsule, the Back circle and the field have their own.
//  - The cross of a recent search (the Encore Tertiary button "Clear" in each LocationRowSearch row, 32x32) is on a glass circle.
//    Rows are reused as the list scrolls, so the table's own layout passes dress the buttons that are on screen.
//  - Search mode swaps the title for "Browse location" (and back). The label keeps its place and only its text changes, which lays
//    nothing out, so the capsule kept the old text's width: the label's text is watched and the capsule sized again.
// Threading: main thread only.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Redesigned/Kit/SGRRepaint.h"
#import "Pages.h"

static char kHeaderKey, kFieldKey, kFieldGlassKey, kTitleGlassKey, kClearGlassKey, kTableKey;

// The page on screen and the label its title is on, for the text watch below.
static __weak UIViewController *sg_locationPage;
static __weak UILabel *sg_titleLabel;
static void watchTitleText(UILabel *label);

// The room the two corner buttons leave the title: the same as every other page's (Pages/PageBar.m).
static const CGFloat kCorner = 16, kGap = 8;

static UIView *pageView(UIViewController *page) {
    UIView *view = page.viewIfLoaded;
    if (!view.window || view.bounds.size.width < 1) return nil;
    return view;
}

// The plain black view behind the header: a direct, childless UIView of the page that ends where the header does. It stays
// hidden and unpainted.
static void clearPlate(UIView *root, UIView *header) {
    CGFloat bottom = CGRectGetMaxY(header.frame);
    for (UIView *sub in root.subviews) {
        if (![sub isMemberOfClass:UIView.class] || sub.subviews.count) continue;
        if (sub.bounds.size.width < root.bounds.size.width * 0.9) continue;
        if (fabs(CGRectGetMaxY(sub.frame) - bottom) > 1.5) continue;
        if (!sub.hidden) sub.hidden = YES;
        if (sub.layer.backgroundColor) sub.layer.backgroundColor = NULL;
    }
}

// The cross of each recent search: an Encore Tertiary "Clear" button of a row, on a glass circle.
// The rows on screen only, and each row's cross found once: the table lays out on every frame of a scroll.
static char kCellClearKey;

static void dressClearButtons(UIView *table) {
    if (![table isKindOfClass:UITableView.class]) return;
    for (UITableViewCell *cell in ((UITableView *)table).visibleCells) {
        UIView *known = objc_getAssociatedObject(cell, &kCellClearKey);
        if (known && [known isDescendantOfView:cell]) continue;
        __block UIView *cross = nil;
        SGForEachView(cell, ^(UIView *v) {
            if (cross || ![v.accessibilityLabel isEqualToString:@"Clear"]) return;
            if (![NSStringFromClass(v.class) containsString:@"Tertiary"]) return;
            if (v.bounds.size.width < 1 || v.bounds.size.width > 48) return;
            cross = v;
        });
        if (!cross) continue;
        objc_setAssociatedObject(cell, &kCellClearKey, cross, OBJC_ASSOCIATION_ASSIGN);
        SGRGlassInside(cross, &kClearGlassKey, MIN(cross.bounds.size.width, cross.bounds.size.height));
    }
}

static UIView *backIn(UIView *header) {
    __block UIView *back = nil;
    SGForEachView(header, ^(UIView *v) {
        if (!back && [v.accessibilityLabel isEqualToString:@"Back"] && [NSStringFromClass(v.class) containsString:@"Button"]) back = v;
    });
    return back;
}

// The title: the wide label of the header's first row.
static UIView *titleIn(UIView *header) {
    __block UIView *title = nil;
    SGForEachView(header, ^(UIView *v) {
        if (title || ![NSStringFromClass(v.class) containsString:@"EncoreLabel"]) return;
        if (v.bounds.size.width > 100 && v.bounds.size.height >= 30) title = v;
    });
    return title;
}

static void glassTitle(UIView *root, UIView *title) {
    UILabel *label = nil;
    for (UIView *sub in title.subviews) {
        if (!label && [sub isKindOfClass:UILabel.class]) label = (UILabel *)sub;
    }
    if (!label.text.length) return;
    if (sg_titleLabel != label) sg_titleLabel = label;
    watchTitleText(label);
    UIColor *white = SGRPrimary();
    if (![label.textColor isEqual:white]) label.textColor = white;
    CGFloat room = root.bounds.size.width - 2 * (kCorner + SGRGlassCircleSize + kGap);
    // The label is as wide as the row gives it and the capsule is a subview that may reach past it.
    UIView *shape = SGRGlassTitleCapsule(title, &kTitleGlassKey, SGRTitleWidth(label), room, ^BOOL(UIView *v) { return v.superview == root; });
    // The row is 48pt high and the pinned Back is 44: the capsule is level with it, at the row's top.
    CGFloat width = shape.bounds.size.width;
    CGRect frame = CGRectMake(round((title.bounds.size.width - width) / 2), 0, width, SGRGlassCircleSize);
    if (shape && !CGRectEqualToRect(shape.frame, frame)) shape.frame = frame;
}

static void dress(UIViewController *page) {
    UIView *root = pageView(page);
    if (!root) return;
    if (sg_locationPage != page) sg_locationPage = page;
    UIView *header = SGRFindByIdentifier(root, @"Components.UI.LocationHeaderSearch", &kHeaderKey);
    if (!header || header.bounds.size.width < 1) return;
    UIView *headerHost = header;
    while (headerHost.superview && headerHost.superview != root) headerHost = headerHost.superview;
    clearPlate(root, headerHost);

    UIView *back = backIn(header);
    if (back) SGRPinnedBackOf(root, back);
    UIView *title = titleIn(header);
    if (title) glassTitle(root, title);

    UIView *table = SGRFindByIdentifier(root, @"LocationSearchView.tableView", &kTableKey);
    if (table) {
        dressClearButtons(table);
        // The table's own passes (it lays its rows out as they scroll in or are reused) dress the crosses on screen.
        SGRWatchLayout(table, ^(UIView *laidOut) { if (laidOut.window) dressClearButtons(laidOut); });
    }

    UIView *field = SGRFindByIdentifier(root, @"Components.Header.UI.Toolbar.SearchField", &kFieldKey);
    if (field) {
        if (sgr_showSearchField != field) sgr_showSearchField = field;
        SGRGlassFlatBox(field, &kFieldGlassKey, NO);
    }
    static BOOL logged;
    if (!logged && field) {
        logged = YES;
        SGLog(@"redesign location search: back %@, title %@, field %@", back ? @"pinned" : @"not found", title ? @"capsule" : @"not found", NSStringFromCGRect(field.frame));
    }
}

// Search mode changes the title's text (Location, Browse location) without a layout pass: size the capsule again.
static void titleTextChanged(UILabel *label) {
    if (label != sg_titleLabel) return;
    UIViewController *page = sg_locationPage;
    if (!page) return;
    __weak UIViewController *weak = page;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (weak) dress(weak);
    });
}

// The title label's text, watched on that one label (key-value observing), not by a hook on every label of the app.
@interface SGRLocationTitleWatch : NSObject
@end
@implementation SGRLocationTitleWatch
- (void)observeValueForKeyPath:(NSString *)path ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    titleTextChanged(object);
}
@end

static char kTitleWatchKey;

static void watchTitleText(UILabel *label) {
    if (!label || objc_getAssociatedObject(label, &kTitleWatchKey)) return;
    SGRLocationTitleWatch *watch = [SGRLocationTitleWatch new];
    // Held by the label, so it goes with it; observing ends as the label is freed.
    objc_setAssociatedObject(label, &kTitleWatchKey, watch, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [label addObserver:watch forKeyPath:@"text" options:0 context:NULL];
    [label addObserver:watch forKeyPath:@"attributedText" options:0 context:NULL];
}

%ctor {
    if (!SGRedesignedUI() || !SGBelowiOS26()) return;
    Class page = SGRSwiftClass(@"LiveEvents_LiveEventsImpl", @"LocationSearchViewController");
    if (!page) {
        SGLog(@"class LiveEvents_LiveEventsImpl.LocationSearchViewController not found, Preferred location keeps Spotify's header");
        return;
    }
    // The header's elements are made after the first layout, and the field's grey comes back as it is focused.
    SGRPassController(page, ^(UIViewController *c) { dress(c); });
}
