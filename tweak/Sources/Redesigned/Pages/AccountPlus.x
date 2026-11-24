// Redesign, iOS < 26: the plus of "Add account" on glass: the one in the left menu's facepile and in both lists of accounts
// Spotify has.
//
// The facepile (AccountSwitching_AccountSwitchingUIImpl.FacepileEntryView at the right of the menu's profile
// row) ends with the plus, an Encore FacepileIconView 32x32 holding the SPTEncoreIconView that draws it. A glass circle
// goes inside it, behind the icon, the way a top bar button has one.
//
// Tree: the left menu's list of accounts (AccountSwitching_AccountSwitchingUIImpl.AddAccountCell, 72x79) holds a plain
// UIView 48x48 bg=#FFFFFF@0.07 r=24 and, after it, the SPTEncoreIconView that draws the plus. The page the app shows after
// signing out of an account, "Who's listening?" (AccountSwitching_AccountPickerImpl.AccountPickerAddAccountTableViewCell,
// a table row), has the same two views at 64x64 r=32 bg=#FFFFFF@0.07, beside the "Add account" label.
//
// The grey disc goes and a glass disc stands in it, with the faint white film the redesign's floating controls carry
// (the disc was a 7% white plate; plain glass over the list's black would read as nothing). The icon above it is
// Spotify's and is left alone. Spotify paints the disc again as the row is selected, highlighted or reused, so the fill is
// held clear (SGRHoldClear) and the row dresses it again from its own passes.
//
// The left menu's row is not laid out the way the picker's is: the disc sits in an Encore Box, 2 views below the cell, and is
// sized by that Box's pass or after it, so the cell's own layout and its move to the window met a disc of no size and the
// disc stayed grey. The Box's pass dresses the cell it is in, and a cell not dressed yet is tried again a moment later.
// Threading: main thread only.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Pages.h"

static char kDiscKey, kGlassKey, kFacepileGlassKey;

// The disc: the one square plain view in the row with nothing in it, 40 to 80pt across. Found once; once it holds the glass it has a
// subview, so it is known from the row afterwards, not by its look.
static UIView *plusDisc(UIView *row) {
    UIView *known = objc_getAssociatedObject(row, &kDiscKey);
    if (known && [known isDescendantOfView:row]) return known;
    __block UIView *found = nil;
    SGForEachView(row, ^(UIView *view) {
        if (found || view == row || ![view isMemberOfClass:UIView.class] || view.subviews.count) return;
        CGSize size = view.bounds.size;
        if (size.width < 40 || size.width > 80 || fabs(size.width - size.height) > 0.5) return;
        found = view;
    });
    if (found) objc_setAssociatedObject(row, &kDiscKey, found, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return found;
}

// Whether the row is dressed: it is in a window and its disc has a size.
static BOOL dressPlus(UIView *row) {
    if (!row.window) return NO;
    UIView *disc = plusDisc(row);
    if (!disc || disc.bounds.size.width < 1 || disc.bounds.size.height < 1) return NO;
    SGRHoldClear(disc);
    SGRGlassFlatBox(disc, &kGlassKey, YES);
    return YES;
}

// A row Spotify has not laid out yet is tried again once its pass has run, and after the menu's own animation.
static void dressPlusSoon(UIView *row) {
    if (dressPlus(row)) return;
    SGRRepeatViewPass(row, @[@0.0, @0.25], ^(UIView *v) { dressPlus(v); });
}

static Class sDrawerCell;

// The plus of the facepile: the FacepileIconView of the accounts' facepile only (other facepiles, the creators of a
// playlist, have none).
static BOOL inAccountFacepile(UIView *icon) {
    int depth = 0;
    for (UIView *v = icon.superview; v && depth < 8; v = v.superview, depth++) {
        if ([NSStringFromClass(v.class) containsString:@"AccountSwitching"]) return YES;
    }
    return NO;
}

static void dressFacepilePlus(UIView *icon) {
    CGSize size = icon.bounds.size;
    if (!icon.window || size.width < 1 || fabs(size.width - size.height) > 0.5 || !inAccountFacepile(icon)) return;
    SGRGlassCapsuleInside(icon, &kFacepileGlassKey, size, YES);
    // The press of the glass grows past the circle.
    if (icon.clipsToBounds) icon.clipsToBounds = NO;
}

%group SGRDrawerPlus
// The Box the disc is in: its pass is the one that sizes the disc.
%hook _TtCE16Encore_LayoutKitO16EncoreFoundation6Encore3Box
- (void)layoutSubviews {
    %orig;
    int depth = 0;
    for (UIView *v = ((UIView *)self).superview; v && depth < 3; v = v.superview, depth++) {
        if ([v isKindOfClass:sDrawerCell]) {
            dressPlusSoon(v);
            return;
        }
    }
}
%end
%end

%group SGRPickerPlus
%hook SGRPickerAddAccount
- (void)layoutSubviews {
    %orig;
    dressPlus((UIView *)self);
}

- (void)didMoveToWindow {
    %orig;
    dressPlus((UIView *)self);
}

// UIKit takes the fills of a row's views off as it is highlighted or selected and puts them back after.
- (void)setHighlighted:(BOOL)highlighted animated:(BOOL)animated {
    %orig;
    dressPlus((UIView *)self);
}

- (void)setSelected:(BOOL)selected animated:(BOOL)animated {
    %orig;
    dressPlus((UIView *)self);
}
%end
%end

%ctor {
    if (!SGRedesignedUI()) return;
    if (!SGBelowiOS26()) return;
    Class drawer = SGRSwiftClass(@"AccountSwitching_AccountSwitchingUIImpl", @"AddAccountCell");
    if (drawer) {
        sDrawerCell = drawer;
        SGRPassView(drawer, ^(UIView *v) { dressPlusSoon(v); });
        %init(SGRDrawerPlus);
    } else {
        SGLog(@"class AccountSwitching_AccountSwitchingUIImpl.AddAccountCell not found, the left menu's Add account keeps its grey plus");
    }
    Class picker = SGRSwiftClass(@"AccountSwitching_AccountPickerImpl", @"AccountPickerAddAccountTableViewCell");
    if (picker) {
        %init(SGRPickerPlus, SGRPickerAddAccount = picker);
    } else {
        SGLog(@"class AccountSwitching_AccountPickerImpl.AccountPickerAddAccountTableViewCell not found, Who's listening keeps its grey plus");
    }
    Class facepile = NSClassFromString(@"_TtCE14Encore_FaceKitO16EncoreFoundation6Encore16FacepileIconView");
    if (facepile) {
        SGRPassView(facepile, ^(UIView *v) { dressFacepilePlus(v); });
    } else {
        SGLog(@"class Encore_FaceKit FacepileIconView not found, the left menu's facepile keeps its plain plus");
    }
}
