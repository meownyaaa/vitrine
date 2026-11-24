// The switches on the mod's own pages (Mod Settings and every page under it) take iOS 26's switch below iOS 26 with the
// legacy glass: a wider track, and a white thumb that turns into glass under a finger (Core/SGGlassThumb.h). A switch counts
// when a controller of the mod's (SGPage, or any class of the SG prefix, the redesign's SGR ones too) holds it, and when the
// look in use says it is one of Spotify's it draws the same way (SGGlassSwitchTakesSpotify). Spotify's other switches are left
// as Spotify draws them. With the legacy glass off none of this runs, and every switch is UIKit's.
// Every slider under such a controller takes iOS 26's thumb the same way, the one Speed, Pitch & Reverb's have
// (SpeedPitchMenu.x): a white capsule that swells into glass under a finger. One look for every slider of the mod's, Sing's
// and the lyrics' included.
#import "Core/SGCore.h"
#import "SGPage.h"
#import "SGGlassSwitch.h"
#import <objc/runtime.h>

static BOOL onModPage(UIView *view) {
    for (UIResponder *r = view.nextResponder; r; r = r.nextResponder) {
        if (![r isKindOfClass:UIViewController.class]) continue;
        if ([r isKindOfClass:SGPage.class] || [NSStringFromClass(r.class) hasPrefix:@"SG"]) return YES;
    }
    return NO;
}

BOOL (*SGGlassSwitchTakesSpotify)(UISwitch *toggle);

// Asked from every layout of every switch in the app, so the answer is kept on the switch: @YES, it has its face; @NO, it
// was looked at and is not ours. Only a `fresh` ask (the switch came into a window or was named, which can make it ours)
// looks again at a switch found not ours; the layouts and value changes in between cost one associated object read.
static char kAttachedKey;

static void attachIfOurs(UISwitch *toggle, BOOL fresh) {
    if (!toggle.window) return;
    NSNumber *known = objc_getAssociatedObject(toggle, &kAttachedKey);
    if (known.boolValue || (known && !fresh)) return;
    BOOL ours = onModPage(toggle) || (SGGlassSwitchTakesSpotify && SGGlassSwitchTakesSpotify(toggle));
    if (ours) SGGlassSwitchAttach(toggle);
    objc_setAssociatedObject(toggle, &kAttachedKey, @(ours), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// Speed, Pitch & Reverb's thumb (SpeedPitchMenu.x).
static const CGSize kSliderThumb = {34, 22};
static char kModSliderKey;

%hook UISlider
- (void)didMoveToWindow {
    %orig;
    UISlider *slider = (UISlider *)self;
    if (!slider.window || objc_getAssociatedObject(slider, &kModSliderKey)) return;
    if (!onModPage(slider)) return;
    objc_setAssociatedObject(slider, &kModSliderKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    SGGlassThumbAttach(slider, kSliderThumb);
}

- (void)layoutSubviews {
    %orig;
    // Again on the owner's passes: a thumb image set again by the page is swapped back (SGGlassThumb.h).
    UISlider *slider = (UISlider *)self;
    if (objc_getAssociatedObject(slider, &kModSliderKey)) SGGlassThumbAttach(slider, kSliderThumb);
}
%end

// Spotify's settings rows name their switch (PreferenceRowSwitch.Switch) after it is in the window, and lay it out no more
// after that: asked only as it came in and on its layouts, a row's switch was never taken. So it is asked again as it is
// named, as it is set, and a turn after it comes in. A switch attached already returns at once.
%hook UISwitch
- (void)didMoveToWindow {
    %orig;
    UISwitch *toggle = (UISwitch *)self;
    attachIfOurs(toggle, YES);
    __weak UISwitch *weakToggle = toggle;
    dispatch_async(dispatch_get_main_queue(), ^{ attachIfOurs(weakToggle, YES); });
}

- (void)setAccessibilityIdentifier:(NSString *)identifier {
    %orig;
    attachIfOurs((UISwitch *)self, YES);
}

- (void)layoutSubviews {
    %orig;
    attachIfOurs((UISwitch *)self, NO);
    SGGlassSwitchSync((UISwitch *)self, NO);
}

- (void)setOn:(BOOL)on animated:(BOOL)animated {
    %orig;
    attachIfOurs((UISwitch *)self, NO);
    SGGlassSwitchSync((UISwitch *)self, animated);
}

// The drawing's track reaches past the switch's leading edge: that strip turns it too.
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    return %orig || SGGlassSwitchContains((UISwitch *)self, point);
}

- (void)setEnabled:(BOOL)enabled {
    %orig;
    SGGlassSwitchSync((UISwitch *)self, NO);
}
%end

%ctor {
    if (!SGUseLegacyGlass()) return;
    %init;
}
