// A slider's thumb as iOS 26 draws it, below iOS 26 with the legacy glass: a solid white capsule at rest that
// swells into clear glass while a finger holds it, pulled out past the ends of the track on a rubber band, with a
// tap of the Taptic Engine as it meets an end. The slider stays the caller's: UIKit's (Speed and Pitch), the system
// volume's, Spotify's progress. Only its thumb is drawn here.
//
// The thumb image is swapped for a clear one of `size` (so UIKit places the thumb by it) and the capsule goes into the
// view UIKit draws the thumb with, so it moves with the thumb and needs no pass of its own. A thumb image set again by
// the slider's owner is swapped back on the next call.
//
// Threading: main thread only.
#import <UIKit/UIKit.h>

// Gives `slider` the glass thumb, a capsule of `size` at rest. Nothing when the legacy glass is not in use (iOS 26
// draws its own; a plain blur has nothing to swell into). Idempotent: call it from the owner's layout passes.
void SGGlassThumbAttach(UISlider *slider, CGSize size);

// iOS 26's switch below iOS 26, drawn inside `toggle` in place of UIKit's: a wider capsule track, and a flat white thumb
// that grows into a clear glass lens while a finger holds it, follows a drag and settles where the switch does. The switch
// stays UIKit's control. Nothing when the legacy glass is not in use. Idempotent.
void SGGlassSwitchAttach(UISwitch *toggle);
// Brings the drawing of an attached switch up to date with it (its value set from code, a layout, enabled changed).
void SGGlassSwitchSync(UISwitch *toggle, BOOL animated);
// Whether `point` (in the switch) is on the drawing of an attached switch: its track is wider than UIKit's and reaches
// past the switch's leading edge, and that strip takes the touch too. NO for a switch with no drawing.
BOOL SGGlassSwitchContains(UISwitch *toggle, CGPoint point);
