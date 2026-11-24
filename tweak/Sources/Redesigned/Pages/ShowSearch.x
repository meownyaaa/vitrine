// A podcast's "Find in this show" page, the one the search row at the top of See all episodes opens
// (ShowPage_ShowSearchPageImpl.ShowSearchViewController): the redesign's bar over it, its field and Cancel on glass.
//
// Tree: under SPNavigationBar (Back only, no title) and Spotify's blur (#1C1C1C@0.73) the page is a plain black view
// holding a SearchHeader ContainerView 390x50 painted #000000, a stack with the field
// (Components.SearchHeader.Private.SearchField, a 302x30 EncoreTextField, #FFFFFF@0.14 r=4) and, in a plain 72x30 view,
// Cancel (Components.SearchHeader.Private.CancelButton, 40x30).
//
// So the bar is Pages/PageBar.m's (the blur drawn by nothing, Back a glass circle pinned to the corner), the container's
// black goes (SGRRepaint.x keeps it off as Spotify paints it again, sgr_showSearchHeader) and the field and Cancel are
// glass the way every other search field of the redesign is (SGRGlassFlatBox). Spotify paints the field's grey again
// as it is focused, so SGRRepaint.x keeps it clear too (sgr_showSearchField). Cancel's capsule is wider than its label, as the title's is, and reaches past the button.
// Threading: main thread only.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Redesigned/Kit/SGRRepaint.h"
#import "Pages.h"

static char kFieldKey, kCancelKey, kFieldGlassKey, kCancelGlassKey;

// Room a Cancel capsule takes beside its label on each side.
static const CGFloat kCancelPadding = 12, kCancelHeight = 30;

static void dress(UIViewController *page) {
    SGRDressBarPage(page);
    UIView *root = page.viewIfLoaded;
    if (!root.window || root.bounds.size.width < 1) return;

    UIView *field = SGRFindByIdentifier(root, @"Components.SearchHeader.Private.SearchField", &kFieldKey);
    UIView *cancel = SGRFindByIdentifier(root, @"Components.SearchHeader.Private.CancelButton", &kCancelKey);
    if (field) {
        if (sgr_showSearchField != field) sgr_showSearchField = field;
        // The black behind the field row: the first view above the field that is named for the search header. It
        // is kept clear (SGRRepaint.x), so the field and Cancel float over the page with no header behind them.
        for (UIView *v = field.superview; v && v != root; v = v.superview) {
            if (![NSStringFromClass(v.class) containsString:@"SearchHeader"]) continue;
            if (sgr_showSearchHeader != v) sgr_showSearchHeader = v;
            if (v.layer.backgroundColor) v.layer.backgroundColor = NULL;
            break;
        }
        SGRGlassFlatBox(field, &kFieldGlassKey, NO);
    }
    if (cancel && cancel.bounds.size.width > 1) {
        SGRUnclipUpTo(cancel, ^BOOL(UIView *v) { return v.superview == root || v.superview == field.superview; });
        SGRGlassCapsuleInside(cancel, &kCancelGlassKey, CGSizeMake(cancel.bounds.size.width + 2 * kCancelPadding, kCancelHeight), NO);
    }

    static BOOL logged;
    if (!logged && field) {
        logged = YES;
        SGLog(@"redesign show search: field %@, cancel %@ in glass", NSStringFromCGRect(field.frame), cancel ? @"found" : @"not shown");
    }
}

%ctor {
    if (!SGRedesignedUI() || !SGBelowiOS26()) return;
    Class page = SGRSwiftClass(@"ShowPage_ShowSearchPageImpl", @"ShowSearchViewController");
    if (!page) SGLog(@"class ShowPage_ShowSearchPageImpl.ShowSearchViewController not found, the podcast search keeps Spotify's bar and field");
    // Hosted by a controller of Spotify's page template. The field and Cancel are made after the first layout, and the
    // grey comes back as the field is focused.
    SGRDressBarPagesWith(page, YES, ^(UIViewController *c) { dress(c); });
}
