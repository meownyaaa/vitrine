// Now playing redesign: glass for the Connect device picker. Its sheet is the same Navigation sheet the queue
// and the ⋯ menu are, but nothing gave it a pane: the pane stayed
// the opaque #1F1F1F Spotify paints it, so the picker was the one sheet with no glass at all. Content is
// SwiftUI (Connect_DevicePickerUIImpl.DevicePickerViewController hosts it), whose own cards -- the playing
// device's, the Connect button -- are left as they are (SGRIsSheetCard). The grey fade over the bottom of the
// list, above the Connect button, is switched off (clearFade).
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"

// The thin grey fade SwiftUI lays over the bottom of the device list, right above the Connect button
// (a full-width _UIShapeHitTestingView, 42 pt tall, ending at the button's top edge, with no fill of its own:
// a gradient is not a background colour). On the glass it reads as a grey band. SwiftUI's shape views paint their own fills (the grabber, the cards), so this one is told
// apart by size and parent: full width of the picker's hosting view, short, no colour. Its layer is switched
// off rather than its alpha, since alpha under 0.01 would also take it out of hit testing.
//
// SwiftUI makes the view after the picker's own layout pass, so clearing it from the controller's passes
// left it up for the half second the sheet takes to come in (the log: the fade seen in the dump of the
// sheet appearing, "cleared" 0.5 s later). It is hidden from the view's own layout, window and frame
// callbacks as well, which run before the first frame it could be drawn in.
static NSString *const kShapeViewSuffix = @"UIShapeHitTestingView";

static BOOL isPickerFade(UIView *view) {
    UIView *host = view.superview;
    if (!host) return NO;
    CGFloat width = host.bounds.size.width;
    CGSize size = view.frame.size;
    if (width < 1 || size.width < width * 0.9 || size.height < 8 || size.height > 80) return NO;
    if (view.subviews.count || SGIsVisibleColor(view.layer.backgroundColor)) return NO;
    return [NSStringFromClass(host.class) containsString:@"DevicePicker"];
}

static void hideFade(UIView *view) {
    if (view.layer.opacity == 0 || !isPickerFade(view)) return;
    view.layer.opacity = 0;
    SGLog(@"redesign connect: cleared the fade above the button, %@", NSStringFromCGRect(view.frame));
}

static void clearFade(UIView *sheet) {
    SGForEachView(sheet, ^(UIView *view) {
        if ([NSStringFromClass(view.class) hasSuffix:kShapeViewSuffix]) hideFade(view);
    });
}

static void chrome(UIViewController *controller) {
    UIView *root = controller.viewIfLoaded;
    if (!root) return;
    UIView *glass = SGRGlassSheetChrome(root);
    if (glass) clearFade(glass.superview);
}

%hook _TtC7SwiftUIP33_A34643117F00277B93DEBAB70EC0697122_UIShapeHitTestingView
- (void)layoutSubviews {
    %orig;
    hideFade((UIView *)self);
}

- (void)didMoveToWindow {
    %orig;
    hideFade((UIView *)self);
}

- (void)setFrame:(CGRect)frame {
    %orig;
    hideFade((UIView *)self);
}
%end

%ctor {
    if (!SGRedesignedUI() || !SGBelowiOS26()) return;
    %init;
    SGRPassControllersNamed(@[@"_TtC26Connect_DevicePickerUIImpl26DevicePickerViewController"], ^(UIViewController *c) { chrome(c); });
}
