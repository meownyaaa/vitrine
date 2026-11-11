// Mirage DJ's sheet (what it said last, what is playing, what is coming, "Switch it up", a request field)
// and the floating DJ pill on Home. Glass the way Vitrine's redesign draws it: UIGlassEffect on iOS 26,
// a dark material before.
#import <UIKit/UIKit.h>

void MRGShowDJ(UIViewController *from);
// Puts the pill on (or takes it off) Home's page view, by the setting; called on Home's layout passes.
void MRGPlaceDJPill(UIView *homeView);
