// What the Logos files hold for the page: the accent colors as Accent.x and SGRAccent.x read them, and the
// font choice as Fonts.x reads it.
#import "Core/SGCore.h"
#import "Native/Appearance/Appearance.h"
#import "Redesigned/Kit/SGRAccent.h"
#import "Shared/Fonts/Fonts.h"

static NSInteger valid(NSInteger rgb) {
    return rgb >= 0 && rgb <= 0xFFFFFF ? rgb : -1;
}

UIColor *SGAccentColor(void) { return valid(SGInt(SGKeyAccent, -1)) < 0 ? nil : UIColor.redColor; }
NSInteger SGAccentRGB(void) { NSInteger rgb = valid(SGInt(SGKeyAccent, -1)); return rgb < 0 ? SGSpotifyGreen : rgb; }
UIColor *SGRAccentColor(void) { return valid(SGInt(SGRKeyAccent, SGRDefaultAccent)) < 0 ? nil : UIColor.redColor; }
NSInteger SGRAccentRGB(void) { NSInteger rgb = valid(SGInt(SGRKeyAccent, SGRDefaultAccent)); return rgb < 0 ? SGSpotifyGreen : rgb; }

SGAppFont SGAppFontChosen(void) {
    NSInteger font = SGInt(SGKeyAppFont, SGAppFontSpotify);
    return font >= SGAppFontSpotify && font <= SGAppFontFamily ? font : SGAppFontSpotify;
}

NSArray<NSString *> *SGAppFontNames(void) {
    return @[@"Default", @"San Francisco", @"SF Rounded", @"New York", @"SF Mono"];
}

NSArray<NSString *> *SGAppFontFamilies(void) {
    return @[@"Avenir Next", @"Georgia"];
}

// Redesigned/Pages/ModPageBar.x, the bar below iOS 26 over a page of the mod's on Spotify's stack: none here.
void SGDressPageBar(UIViewController *page) {}
void SGUndressPageBar(UIViewController *page) {}
void SGPlacePageBar(UIViewController *page) {}
