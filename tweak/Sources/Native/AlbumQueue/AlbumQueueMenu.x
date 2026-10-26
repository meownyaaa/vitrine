// Mark the native album header immediately before its menu action runs. Both UIKit dispatch
// paths are already used by Shared/Haptics/ControlHaptics.x: target/selector and UIAction.
#import "Core/SGCore.h"
#import "Shared/AdBlock/AdBlock.h"
#import "Shared/AlbumQueue/AlbumQueue.h"

static const UIControlEvents kActivationEvents = UIControlEventTouchUpInside | UIControlEventPrimaryActionTriggered;

static BOOL isMenuButton(UIControl *control) {
    return [control.accessibilityIdentifier hasPrefix:@"Components.UI.ContextMenuButton"];
}

%hook UIControl
- (void)sendAction:(SEL)selector to:(id)target forEvent:(UIEvent *)event {
    if (isMenuButton(self)) {
        __block BOOL activates = NO;
        [self enumerateEventHandlers:^(UIAction *action, id registeredTarget, SEL registeredSelector, UIControlEvents events, BOOL *stop) {
            if (!action && registeredSelector == selector && (!registeredTarget || registeredTarget == target) && (events & kActivationEvents)) activates = YES;
        }];
        if (activates) SGAlbumQueueMarkSource(self);
    }
    %orig;
}
- (void)sendAction:(UIAction *)action {
    if (isMenuButton(self)) {
        __block BOOL activates = NO;
        [self enumerateEventHandlers:^(UIAction *registered, id target, SEL selector, UIControlEvents events, BOOL *stop) {
            if (registered == action && (events & kActivationEvents)) activates = YES;
        }];
        if (activates) SGAlbumQueueMarkSource(self);
    }
    %orig;
}
%end

%ctor {
    if (!SGNativeUI()) return;
    %init;
}
