// A legacy glass pane that answers a press, the stand-in for what UIGlassEffect.isInteractive does on iOS 26.
//
// Only below iOS 26, and only with the legacy glass in use (SGUseLegacyGlass): on iOS 26 and later, and on a
// plain blur pane, the call does nothing. On the host the glass grows by 15pt (at most 8%) on press, stretches toward the
// finger as it moves and springs back on release, and a soft radial light follows the touch. The spring values
// and the stretch geometry are Telegram-iOS's (GPLv2), as in SGLegacyGlass.h; the code is the mod's own.
// Reduce Motion keeps the light and drops the movement.
//
// Only for a pane on something that is pressed: a button, a round control. A sheet or a bar is not.
#import <UIKit/UIKit.h>

// The press's springs (Telegram's): quick and firm as the glass lifts, loose as it comes down. The tab bar's lens
// lifts on the same.
typedef struct { CGFloat mass, stiffness, damping; } SGSpring;
extern const SGSpring SGGlassLiftOn, SGGlassLiftOff;

// `host` is the control that owns `pane` (SGGlassFor / SGGlassAt). Idempotent, so a layout pass may call it
// every time.
void SGGlassInteractive(UIView *host, UIView *pane);

// The same where the touches land on `touched` (a button laid over the control) while `host` is what moves.
void SGGlassInteractiveVia(UIView *touched, UIView *host, UIView *pane);
