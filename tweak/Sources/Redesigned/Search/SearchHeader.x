// Search redesign, iOS < 26: the header of the results page, the one that holds the field once something is typed
// and sent with return (and the recents under it). Spotify draws it as a flat #1F1F1F backing with a grey capsule
// for the field and grey capsules for the chips. Here the backing goes and nothing stands in its place: the field
// and Cancel are glass capsules floating over the page and the chips are glass the way the Library's are
// (Library/LibraryHeader.x takes them: it answers to this row's identifier too).
//
// Tree: Search_FeatureImpl.HeaderViewController's view is a plain UIView 390x143 bg=#1F1F1F,
// holding at {0, 47} a 96pt UIView with a vertical UIStackView of
//
//     a 32pt row   MultilineSearchBarContainer (id=SearchBarSearch) > UIView 358x32 > the field's fill, a plain
//                  UIView 304x32 bg=#FFFFFF@0.10 r=16 clips holding the text view and the clear button, and
//                  the Cancel button beside it
//     a 40pt row   id=Components.UI.FiltersView, a collection of FilterChipView (the chips' fills are plain
//                  UIViews bg=#FFFFFF@0.10 r=16, as in the Library)
//
// The page used to get a black plate behind the status bar and the field row. A plate is a view of ours that is
// sized on Spotify's layout passes, so when the header grew or shrank in an animation (the keyboard, the chips
// coming and going) it stood at the old size and cut the move off. There is none now: the header's own paint is
// held clear by SGRRepaint.x (sgr_searchHeaderRoot, sgr_searchFieldFill), which Spotify puts back on its passes,
// and the page behind it is black already.
//
// Spotify lays the field out and rebuilds its fill on passes that never reach the controller (the recents under it coming and
// going, the keyboard, a focus change), so the field is also dressed from the layout of its own container
// (MultilineSearchBarContainer), and the controller's passes are repeated a moment after the page appears. The glass
// carries a white film (SGRGlassFlatBox, prominent): the header has no backing, so the recents and the results scroll under
// the field, and plain glass over them read as no plate at all.
// Threading: main thread only.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Search.h"

static char kContainerKey, kFiltersKey, kFieldGlassKey, kCancelGlassKey;

// Room the Cancel capsule takes beside its label at most, on each side.
static const CGFloat kCancelPadding = 12;

// The field's own fill: a plain UIView with the text view in it, one level under the container's wrapper. Known
// again once it is ours (its corners stay, its paint is gone).
static UIView *fieldFill(UIView *container) {
    for (UIView *wrapper in container.subviews) {
        for (UIView *sub in wrapper.subviews) {
            if (![sub isMemberOfClass:UIView.class]) continue;
            if (sub.bounds.size.width < 100 || sub.bounds.size.height < 20) continue;
            if (sub == sgr_searchFieldFill || sub.layer.cornerRadius > 0) return sub;
        }
    }
    return nil;
}

// Cancel: the button beside the field, found by an identifier that says so, else as the one button in the container
// that is not the field and stands clear of it. It is wider than its label and the glass capsule is a little wider
// again, so it reaches past the button by what the gap to the field leaves it.
static UIView *cancelBeside(UIView *container, UIView *fill) {
    CGRect fieldFrame = [fill.superview convertRect:fill.frame toView:container];
    __block UIView *byName = nil, *byShape = nil;
    SGForEachView(container, ^(UIView *v) {
        if (v == container || v == fill || SGIsInside(v, fill) || v.bounds.size.width < 1) return;
        if ([v.accessibilityIdentifier containsString:@"Cancel"] && !byName) byName = v;
        if (byShape || ![NSStringFromClass(v.class) containsString:@"Button"]) return;
        CGRect frame = [v.superview convertRect:v.frame toView:container];
        if (v.bounds.size.height >= 20 && v.bounds.size.width <= 140 && !CGRectIntersectsRect(frame, fieldFrame)) byShape = v;
    });
    return byName ?: byShape;
}

static void glassCancel(UIView *container, UIView *fill) {
    UIView *cancel = cancelBeside(container, fill);
    if (!cancel) return;
    CGRect fieldFrame = [fill.superview convertRect:fill.frame toView:container];
    CGRect frame = [cancel.superview convertRect:cancel.frame toView:container];
    CGFloat gap = MIN(fabs(CGRectGetMinX(frame) - CGRectGetMaxX(fieldFrame)), fabs(CGRectGetMinX(fieldFrame) - CGRectGetMaxX(frame)));
    CGFloat pad = MIN(kCancelPadding, MAX(0, floor(gap / 2) - 1));
    SGRUnclipUpTo(cancel, ^BOOL(UIView *v) { return v.superview == container.superview; });
    SGRGlassCapsuleInside(cancel, &kCancelGlassKey, CGSizeMake(cancel.bounds.size.width + 2 * pad, fill.bounds.size.height), YES);
    SGForEachView(cancel, ^(UIView *v) {
        if ([v isKindOfClass:UILabel.class] && ((UILabel *)v).textColor != UIColor.whiteColor) ((UILabel *)v).textColor = UIColor.whiteColor;
    });
}

// The field and Cancel of the header the container is in: glass capsules, Spotify's grey gone. Cheap to call on every pass.
static UIView *dressField(UIView *container) {
    if (!container || container.bounds.size.width < 1) return nil;
    UIView *fill = fieldFill(container);
    if (!fill) return nil;
    if (sgr_searchFieldFill != fill) sgr_searchFieldFill = fill;
    SGRGlassFlatBox(fill, &kFieldGlassKey, YES);
    glassCancel(container, fill);
    return fill;
}

static void dress(UIView *root) {
    if (!root || root.bounds.size.width < 1) return;
    if (sgr_searchHeaderRoot != root) sgr_searchHeaderRoot = root;
    if (root.layer.backgroundColor) root.layer.backgroundColor = NULL;

    UIView *container = SGRFindByIdentifier(root, @"SearchBarSearch", &kContainerKey);
    UIView *fill = dressField(container);

    static BOOL logged;
    if (!logged && root.window && fill) {
        logged = YES;
        SGLog(@"redesign search: results header %@, field %@, chips %@", NSStringFromCGRect(root.frame),
              NSStringFromCGRect(fill.frame), SGRFindByIdentifier(root, SGRSearchFiltersIdentifier, &kFiltersKey) ? @"found" : @"not shown");
    }
}

// Whether the container is the search page's own: the same class holds the field wherever Spotify's search results header is used.
static BOOL inSearchPage(UIView *container) {
    for (UIResponder *r = container.nextResponder; r; r = r.nextResponder) {
        if ([r isKindOfClass:UIViewController.class]) return [NSStringFromClass(r.class) containsString:@"Search_FeatureImpl"];
    }
    return NO;
}

%ctor {
    if (!SGRedesignedUI() || !SGBelowiOS26()) return;
    // Spotify builds the field's content again once the page is up; the passes after it dress what it built.
    SGRPassControllersNamed(@[@"_TtC18Search_FeatureImpl20HeaderViewController"], ^(UIViewController *c) { dress(c.viewIfLoaded); });
    Class container = NSClassFromString(@"_TtC13Search_ECMKitP33_4AAD529A9116A2BD7185A1FC1B0C084527MultilineSearchBarContainer");
    if (!container) SGLog(@"class Search_ECMKit MultilineSearchBarContainer not found, the results header's field is dressed from the header's passes only");
    SGRPassView(container, ^(UIView *v) { if (v.window && inSearchPage(v)) dressField(v); });
}
