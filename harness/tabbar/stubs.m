// What the harness does not compile: the accent hook (SGRAccent.x), the repaint hook (SGRRepaint.x), the
// tab bar's composition (Navbar.x) and Mod Settings. Spotify's order of tabs stays as the mock has it.
#import <UIKit/UIKit.h>

UIColor *SGRAccentColor(void) { return nil; }
__weak UIView *sgr_nowPlayingRoot = nil;
NSHashTable<UIView *> *sgr_nowPlayingPainted = nil;
__weak UIView *sgr_lyricsPageRoot = nil;
__weak UIView *sgr_playlistRoot = nil;
__weak UIView *sgr_albumRoot = nil;
__weak UIView *sgr_artistRoot = nil;

void SGRComposeTabBar(UIView *tabBar) {}

// With `split` among the launch words, Search is a split tab, which TabBar.x stands on a bar of its own;
// with `split2`, Create is one too.
BOOL SGRTabIsApart(UIView *item) {
    NSArray<NSString *> *args = NSProcessInfo.processInfo.arguments;
    BOOL two = [args containsObject:@"split2"];
    if (![args containsObject:@"split"] && !two) return NO;
    for (UIView *sub in item.subviews) {
        if (![sub isKindOfClass:UILabel.class]) continue;
        NSString *text = ((UILabel *)sub).text;
        if ([text isEqualToString:@"Search"] || (two && [text isEqualToString:@"Create"])) return YES;
    }
    return NO;
}
void SGRLogTabBarRow(UIView *tabBar) {}
// The tab of the mod's own whose page is up (Navbar.x), which the `lit` launch word sets by hand.
__weak UIView *sgHarnessLitTab = nil;
UIView *SGRNavbarLitTab(void) { return sgHarnessLitTab; }
void SGRNavbarForgetTab(void) {
    if (sgHarnessLitTab) NSLog(@"[harness] the lit tab forgotten");
    sgHarnessLitTab = nil;
}
void SGOpenModSettings(UIView *source) {}
// Shared/Player/PlayerEvents.x, which TabBarMinimize.x listens to.
NSString *const SGPlayerTransitionNotification = @"spotifyglass.playerTransition";
NSString *const SGPlayerTransitionEndedNotification = @"spotifyglass.playerTransitionEnded";
// Navbar.x refreshes the bar once its settings change; the harness changes none.
void SGRRefreshTabBar(void) {}
// TabBarLegacy.x, the bar below iOS 26 with Legacy Liquid Glass: the harness drives the bar main has, so it is off.
BOOL SGRLegacyTabBarOn(void) { return NO; }
BOOL SGRLegacyTabBarMinimized(void) { return NO; }
void SGRLegacyApplyTabBarMinimized(BOOL minimized, BOOL animated) {}
CGRect SGRLegacyTabBarInlineSlot(UIView *host, CGFloat height) { return CGRectNull; }
// SGRRepaint.x, the layer hooks that keep a glassed sheet clear of Spotify's grey: the harness has no Spotify sheet.
__weak UIView *sgr_sheetChromeRoot = nil;
void SGRWatchSheetPaint(UIView *root) {}
// The toast and the tooltip (SGRSnackbar.x, SGRTooltip.x), which follow the now playing bar: the harness shows neither.
void SGRSnackbarFollowNowPlayingBar(void) {}
void SGRTooltipFollowNowPlayingBar(void) {}
// SGRRestyle.m's lookup, as it is there.
Class SGRSwiftClass(NSString *module, NSString *name) {
    NSString *mangled = [NSString stringWithFormat:@"_TtC%lu%@%lu%@", (unsigned long)module.length, module, (unsigned long)name.length, name];
    return NSClassFromString(mangled) ?: NSClassFromString([NSString stringWithFormat:@"%@.%@", module, name]);
}
