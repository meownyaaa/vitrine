// Player redesign: glass circles behind the header's close and more buttons.
//
// Glass is the control layer floating over the field, so it goes behind the round buttons only: the
// playlist name between them stays a label, and the row of playback controls stays bare glyphs
// (PlayerControls.x). Each circle is a subview of the button it sits behind (SGRGlassInside), below
// what the button draws and taking no touches, so the buttons stay Spotify's, with their actions, state
// and accessibility, and the circle follows the button wherever Spotify's row puts it. Circles placed
// from the unit's layout pass instead (a backing across the unit's view) were read before the row had
// laid the buttons out and sat 24pt up and to the side until a tap laid the unit out again
// (trees/continuous/1.txt, 2026-09-17: shapes at {-10, -22} and {320, -22}; the close button is at {12, 0}
// in the unit's view, so its circle belonged at {14, 2}).
//
// The add button keeps no circle: its glyph is a circle of its own, green and filled once the track is
// saved, and on glass it read as a disc on a disc (device test, 2026-09-17).
//
// Tree (trees/clean/player/01.txt): HeaderElementsUnit's view is a 402x48 row holding
// id=now-playing-minimize-button 48x48 (:103) and id=Context menu 48x48 (:122), the playlist name
// between them. The down arrow and the ⋯ are a pair, as the Music app's are: the same circle, size and glass.
// 9.1.78 also carries mobile-nowplaying-close-button (strings in the binary), so the down arrow is looked for
// under either name; which view each circle went into is logged once, so a phone where the arrow has none
// says why.
//
// The circle presses in itself (scale, the Kit's press spring), from the control that takes the touches: the
// arrow's own, and for the ⋯ the mod's button over it (ContextMenu.x). Spotify draws a button's pressed look
// under its subviews, where the circle covers it (phone, 2026-10-06: the arrow closed the player but showed
// no ripple), and the ⋯'s touches no longer reach Spotify's button at all.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Redesigned/ContextMenu/ContextMenu.h"
#import "Player.h"

static char kGlassKey, kDimKey, kCloseKey, kMoreKey, kPressKey;
static const CGFloat kPressScale = 0.92;

@interface SGRHeaderPress : NSObject
@end
@implementation SGRHeaderPress
// The circle of the control pressed, or of the button under it (the ⋯'s front).
static UIView *circleOf(UIControl *control) {
    return objc_getAssociatedObject(control, &kGlassKey) ?: objc_getAssociatedObject(control.superview, &kGlassKey);
}
- (void)down:(UIControl *)control {
    if (SGUseLegacyGlass()) return;    // the glass answers the press itself (SGGlassInteractiveVia)
    UIView *circle = circleOf(control);
    SGRAnimate(SGRMotionPress, ^{ circle.transform = CGAffineTransformMakeScale(kPressScale, kPressScale); }, nil);
}
- (void)up:(UIControl *)control {
    UIView *circle = circleOf(control);
    SGRAnimate(SGRMotionPress, ^{ circle.transform = CGAffineTransformIdentity; }, nil);
}
@end

// `throughMenu`: the mod's ⋯, whose touch UIKit cancels as the menu comes up on it; the press holds until the
// menu ends, which the button reports as a touch up outside (ContextMenu.x), so its cancel is not listened to.
static void pressFrom(UIControl *control, BOOL throughMenu) {
    if (![control isKindOfClass:UIControl.class] || objc_getAssociatedObject(control, &kPressKey)) return;
    objc_setAssociatedObject(control, &kPressKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    static SGRHeaderPress *press;
    if (!press) press = [SGRHeaderPress new];
    [control addTarget:press action:@selector(down:) forControlEvents:UIControlEventTouchDown | UIControlEventTouchDragEnter];
    UIControlEvents up = UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchDragExit;
    [control addTarget:press action:@selector(up:) forControlEvents:throughMenu ? up : up | UIControlEventTouchCancel];
}

// `identifiers` holds, for each button, the identifiers it may carry, the first found winning. `watchMenu` hands the ⋯
// to PlayerMenu.m, which opens the system menu from it: the ordinary player's, or the AI DJ's under a kind of its own.
static void glassInside(UIViewController *unit, NSArray<NSArray<NSString *> *> *identifiers, const void **findKeys, void (*watchMenu)(UIView *)) {
    UIView *host = unit.viewIfLoaded;
    if (!host) return;
    NSUInteger found = 0;
    for (NSUInteger i = 0; i < identifiers.count; i++) {
        UIView *button = nil;
        for (NSString *identifier in identifiers[i]) {
            if ((button = SGRFindByIdentifier(host, identifier, findKeys[i]))) break;
        }
        NSString *name = identifiers[i].firstObject;
        static NSMutableSet<NSString *> *said;
        if (!said) said = [NSMutableSet set];
        if (!button) {
            if (![said containsObject:name]) {
                [said addObject:name];
                SGLog(@"redesign player: %@ not found in %@, left as Spotify's", [identifiers[i] componentsJoinedByString:@" or "], NSStringFromClass(host.class));
            }
            continue;
        }
        UIView *circle = SGRGlassInside(button, &kGlassKey, SGRGlassCircleSize);
        // The down arrow and the ⋯ dimmed as the tab bar's glass is, below iOS 26.
        SGRDarkenGlass(circle, &kDimKey, SGRGlassCircleSize / 2, SGRBarDim);
        if (![said containsObject:name] && button.bounds.size.width > 0) {
            [said addObject:name];
            SGLog(@"redesign player: a %.0fpt glass circle in %@ (id %@, %.0fx%.0f, %@)", circle.bounds.size.width, NSStringFromClass(button.class),
                  button.accessibilityIdentifier, button.bounds.size.width, button.bounds.size.height,
                  button.hidden || button.alpha < 0.01 ? @"hidden" : @"shown");
        }
        if ([name isEqualToString:@"Context menu"]) {
            watchMenu(button);
        }
        UIControl *front = SGRSystemMenuFront(button);
        pressFrom(front ?: (UIControl *)button, front != nil);
        // The mod's button over the ⋯ takes its touches, so the press is watched there and moves the ⋯.
        if (front) SGGlassInteractiveVia(front, button, circle);
        found++;
    }

    static NSMutableSet<NSString *> *logged;
    if (!logged) logged = [NSMutableSet set];
    NSString *unitName = NSStringFromClass(unit.class);
    if (![logged containsObject:unitName]) {
        [logged addObject:unitName];
        SGLog(@"redesign player: glass inside %lu of %lu buttons in %@", (unsigned long)found, (unsigned long)identifiers.count, unitName);
    }
}

static void glassHeader(UIViewController *unit, void (*watchMenu)(UIView *)) {
    static const void *keys[] = {&kCloseKey, &kMoreKey};
    glassInside(unit, @[@[@"now-playing-minimize-button", @"mobile-nowplaying-close-button"], @[@"Context menu"]], keys, watchMenu);
}

%hook _TtC20NowPlaying_ModesImpl18HeaderElementsUnit
- (void)viewDidLayoutSubviews {
    %orig;
    glassHeader((UIViewController *)self, SGRPlayerMenuWatch);
}
%end

// The AI DJ's player has a header unit of its own with the same two buttons, which the circles never reached.
// Its ⋯ gets the glass but is not watched: the menu it opens (feedback, language, voice) is not the player's.
%group SGRDJHeaderHooks
%hook SGRDJHeaderUnit
- (void)viewDidLayoutSubviews {
    %orig;
    glassHeader((UIViewController *)self, SGRDJPlayerMenuWatch);
}
%end
%end

%ctor {
    if (!SGRedesignedUI()) return;
    %init;
    Class djHeader = SGRDJClass(@"DJMHeaderElementsUnitViewController");
    if (djHeader) { %init(SGRDJHeaderHooks, SGRDJHeaderUnit = djHeader); }
    SGRequireClasses(@[@"_TtC20NowPlaying_ModesImpl18HeaderElementsUnit"]);
}
