// Redesign, iOS < 26: Who's listening has no blur behind its bar.
//
// The page has no title in its bar, yet Spotify's blur stands over the top 91pt of it (the plain view of the
// navigation controller's that holds a UIVisualEffectView, #1C1C1C at 73%), a grey band over the heading. The page is
// registered with the bar pages (Pages.h), which keep that blur off while it is on top. The Add account circle is
// AccountPlus.x's. On iOS 26 the page stays as it is on main.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Redesigned/Pages/Pages.h"

%ctor {
    if (!SGRedesignedUI() || !SGBelowiOS26()) return;
    Class page = SGRSwiftClass(@"AccountSwitching_AccountPickerImpl", @"AccountPickerViewController");
    if (page) {
        SGRRegisterBarPages(^BOOL(UIViewController *top) { return SGRPageIsOrHolds(top, page); });
    } else {
        SGLog(@"class AccountSwitching_AccountPickerImpl.AccountPickerViewController not found, Who's listening keeps Spotify's blur behind its bar");
    }
}
