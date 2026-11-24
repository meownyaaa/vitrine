// The redesign draws Spotify's settings switches as the mod's own pages draw theirs, below iOS 26 with the legacy glass
// (Settings/SGGlassSwitch.x): a row's (id=PreferenceRowSwitch.Switch, in Settings_PlatformImpl's StandardSwitchElement,
// trees/continuous/5.txt) and the Equalizer's (in SPTEqualizerSwitchTableViewCell, 4.txt).
#import "Core/SGCore.h"
#import "Settings/SGGlassSwitch.h"

static Class sg_equalizerCell;

static BOOL takesSpotify(UISwitch *toggle) {
    if ([toggle.accessibilityIdentifier isEqualToString:@"PreferenceRowSwitch.Switch"]) return YES;
    for (UIView *view = toggle.superview; view && sg_equalizerCell; view = view.superview) {
        if ([view isKindOfClass:sg_equalizerCell]) return YES;
        if ([view isKindOfClass:UITableView.class]) break;
    }
    return NO;
}

%ctor {
    if (!SGRedesignedUI()) return;
    if (!SGUseLegacyGlass()) return;
    sg_equalizerCell = NSClassFromString(@"SPTEqualizerSwitchTableViewCell");
    SGGlassSwitchTakesSpotify = takesSpotify;
}
