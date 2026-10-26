// Host check for Redesigned/Kit/SGRTokens.m's SGRFont: the same inputs give the one kept font, each input is part
// of what tells fonts apart, and the kept font is the one the uncached computation gives.
#import <UIKit/UIKit.h>
#import "Redesigned/Kit/SGRTokens.h"

// SGRTokens.m's accent comes from SGRAccent.x, which this does not compile.
UIColor *SGRAccentColor(void) { return nil; }

#define CHECK(cond) do { if (!(cond)) { fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #cond); exit(1); } } while (0)

static UIFont *uncached(UIFontTextStyle style, UIFontWeight weight, UIContentSizeCategory largest) {
    UIContentSizeCategory current = UIApplication.sharedApplication.preferredContentSizeCategory;
    if (largest && UIContentSizeCategoryCompareToCategory(current, largest) == NSOrderedDescending) current = largest;
    UITraitCollection *traits = [UITraitCollection traitCollectionWithPreferredContentSizeCategory:current];
    return [UIFont systemFontOfSize:[UIFont preferredFontForTextStyle:style compatibleWithTraitCollection:traits].pointSize weight:weight];
}

int main(void) {
    @autoreleasepool {
        printf("current category: %s\n", UIApplication.sharedApplication.preferredContentSizeCategory.UTF8String ?: "(none)");
        UIFont *title = SGRFont(UIFontTextStyleTitle2, UIFontWeightBold, UIContentSizeCategoryLarge);
        CHECK(title == SGRFont(UIFontTextStyleTitle2, UIFontWeightBold, UIContentSizeCategoryLarge));
        CHECK([title isEqual:uncached(UIFontTextStyleTitle2, UIFontWeightBold, UIContentSizeCategoryLarge)]);

        // Mac Catalyst scales no text style by category, so only the style and the weight can be told apart here; the
        // cap and the live category are in the key by construction (SGRTokens.m).
        UIFont *body = SGRFont(UIFontTextStyleBody, UIFontWeightBold, UIContentSizeCategoryLarge);
        UIFont *regular = SGRFont(UIFontTextStyleTitle2, UIFontWeightRegular, UIContentSizeCategoryLarge);
        UIFont *capped = SGRFont(UIFontTextStyleTitle2, UIFontWeightBold, UIContentSizeCategoryExtraSmall);
        CHECK(![body isEqual:title] && ![regular isEqual:title]);
        CHECK(body == SGRFont(UIFontTextStyleBody, UIFontWeightBold, UIContentSizeCategoryLarge));
        CHECK([body isEqual:uncached(UIFontTextStyleBody, UIFontWeightBold, UIContentSizeCategoryLarge)]);
        CHECK([regular isEqual:uncached(UIFontTextStyleTitle2, UIFontWeightRegular, UIContentSizeCategoryLarge)]);
        CHECK([capped isEqual:uncached(UIFontTextStyleTitle2, UIFontWeightBold, UIContentSizeCategoryExtraSmall)]);
        printf("title %.1f, body %.1f, capped %.1f\n", title.pointSize, body.pointSize, capped.pointSize);
        puts("tokens: ok");
    }
    return 0;
}
