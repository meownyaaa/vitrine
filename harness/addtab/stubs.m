// What the harness does not compile: Mod Settings' opener, which SGPage.h declares, and for the Tab bar page
// the glass bar's refresh, the Kit's accent, the titles' shrink as TabBar.x has it, and the glyphs TabBar.x
// reads off Spotify's bar, which are drawn here the way the stand-in Encore views draw them (main.m).
#import <UIKit/UIKit.h>
#import "Redesigned/Navbar/Navbar.h"
#import "Shared/Navigation/TabIcons.h"

void SGOpenModSettings(UIView *source) {}
void SGRRefreshTabBar(void) {}
void SGRShrinkTabTitles(UIView *bar) {
    for (UIView *sub in bar.subviews) {
        SGRShrinkTabTitles(sub);
        if (![sub isKindOfClass:UILabel.class]) continue;
        ((UILabel *)sub).adjustsFontSizeToFitWidth = YES;
        ((UILabel *)sub).minimumScaleFactor = 0.8;
    }
}
UIColor *SGRAccent(void) { return [UIColor colorWithRed:0x1E / 255.0 green:0xD7 / 255.0 blue:0x60 / 255.0 alpha:1]; }

// Spotify's own tabs by the English label under them; a tab of the mod's own by its icon, as on the bar.
UIImage *SGRNavbarGlyph(NSDictionary *entry, BOOL active) {
    if (!entry[SGRNavbarURI]) {
        NSDictionary *stock = @{@"Home": @"house", @"Search": @"magnifyingglass", @"Your Library": @"books.vertical", @"Create": @"plus"};
        NSString *name = stock[entry[SGRNavbarID]];
        if (!name) return nil;
        return [UIImage systemImageNamed:active && ![name isEqualToString:@"plus"] ? [name stringByAppendingString:@".fill"] : name];
    }
    UIView *icon = SGTabIconView(entry[SGRNavbarIcon], [entry[SGRNavbarIconSet] isEqual:SGTabIconSetSymbols], UIColor.whiteColor);
    return [icon isKindOfClass:UIImageView.class] ? ((UIImageView *)icon).image : nil;
}

// TabBarLegacy.x, the bar below iOS 26 with Legacy Liquid Glass: the editor the harness shows is the one main has.
BOOL SGRLegacyTabBarOn(void) { return NO; }
