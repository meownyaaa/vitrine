// Add artists and Add podcasts, the pickers the Library opens over itself (AllBoarding_AllBoardingPlatformImpl
// .ContentPickerViewController, presented in a navigation controller of its own): the cross on glass, and the search
// field on glass.
//
// Tree: ContentPickerView holds the grid (a UICollectionView on #000000 below the search field), the large header
// (LargeHeaderView on #000000: the title and the search bar, AllBoardingSearch.searchBar 374x52, a UISearchBar whose
// field, a 358x44 UISearchBarTextField, is drawn by a picture, a _UITextFieldImageBackgroundView, with its text and
// magnifier dark), Done on its gradient and, last, a plain 390x91 view on #000000 over the top. Over all of it, outside
// the page, the navigation controller's blur (a=0.00 here, it fades in as the list scrolls) and SPNavigationBar: a
// leading stack with one button (a cross or a chevron, 20x20), an empty trailing stack and the title control, whose label
// (Allboarding.customNavigationTitleLabel) shows only once the large title has scrolled away.
//
// So the bar is Pages/PageBar.m's, without a capsule for its title (the label comes and goes with the scroll, and a
// capsule behind it would stay): the blur is drawn by nothing and the cross is a glass circle pinned to the corner that
// fires Spotify's own button, which dismisses the picker where Back would pop nothing. The black plate at the top is left
// as it is: it is what hides the large title as it scrolls up under the bar. The field's picture goes, the field is glass
// the way the other search fields are (SGRGlassFlatBox, prominent: it floats over black, where plain glass reads as no plate),
// and its text, its placeholder and its magnifier go light.
// Threading: main thread only.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Pages.h"

static char kFieldGlassKey;

// The search bar's field: the picture Spotify draws it with is faded out (UIKit leaves a view's alpha alone), a glass
// capsule goes inside it and what it writes is made light. Cheap to call again on every pass.
static void dressField(UISearchBar *bar) {
    if (![bar isKindOfClass:UISearchBar.class]) return;
    UITextField *field = bar.searchTextField;
    if (!field || field.bounds.size.width < 1) return;
    for (UIView *sub in field.subviews) {
        if ([NSStringFromClass(sub.class) containsString:@"ImageBackgroundView"] && sub.alpha != 0) sub.alpha = 0;
    }
    SGRGlassFlatBox(field, &kFieldGlassKey, YES);

    UIColor *text = SGRPrimary(), *dim = SGRSecondary();
    if (![field.textColor isEqual:text]) field.textColor = text;
    NSString *placeholder = field.placeholder;
    if (placeholder.length) {
        UIColor *now = field.attributedPlaceholder.length ? [field.attributedPlaceholder attribute:NSForegroundColorAttributeName atIndex:0 effectiveRange:NULL] : nil;
        if (![now isEqual:dim]) {
            field.attributedPlaceholder = [[NSAttributedString alloc] initWithString:placeholder attributes:@{NSForegroundColorAttributeName: dim}];
        }
    }
    // The magnifier is a picture in Spotify's dark; as a template it takes the tint.
    if ([field.leftView isKindOfClass:UIImageView.class]) {
        UIImageView *icon = (UIImageView *)field.leftView;
        if (icon.image && icon.image.renderingMode != UIImageRenderingModeAlwaysTemplate) {
            icon.image = [icon.image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
        }
        if (![icon.tintColor isEqual:dim]) icon.tintColor = dim;
    }
    static BOOL logged;
    if (!logged && bar.window) {
        logged = YES;
        SGLog(@"redesign picker: search field %@ in glass", NSStringFromCGRect(field.frame));
    }
}

static void dress(UIViewController *page) {
    SGRDressBarPageTitleless(page);
    UIView *root = page.viewIfLoaded;
    if (!root.window || root.bounds.size.width < 1) return;
    static char kSearchKey;
    UIView *bar = SGRFindByIdentifier(root, @"AllBoardingSearch.searchBar", &kSearchKey);
    if (bar) dressField((UISearchBar *)bar);
}

%ctor {
    if (!SGRedesignedUI() || !SGBelowiOS26()) return;
    Class page = SGRSwiftClass(@"AllBoarding_AllBoardingPlatformImpl", @"ContentPickerViewController");
    if (!page) SGLog(@"class AllBoarding_AllBoardingPlatformImpl.ContentPickerViewController not found, the pickers keep Spotify's bar");
    // The bar's cross and the field's text are made after the first layout, and the picture comes back as the field is focused.
    SGRDressBarPagesWith(page, YES, ^(UIViewController *c) { dress(c); });
    // UIKit puts the field right again as it is focused or cleared: the bar's own pass sets it back at once.
    Class search = SGRSwiftClass(@"AllBoarding_AllBoardingPlatformImpl", @"AllBoardingSearchBar");
    if (!search) SGLog(@"class AllBoarding_AllBoardingPlatformImpl.AllBoardingSearchBar not found, the pickers keep Spotify's search field");
    SGRPassView(search, ^(UIView *v) { dressField((UISearchBar *)v); });
}
