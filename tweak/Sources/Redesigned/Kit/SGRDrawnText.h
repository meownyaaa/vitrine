// Text and fills of a SwiftUI card the redesign puts on glass (the toast "You're now logged in as ..." of
// SGRSnackbar.x, the tooltips of SGRTooltip.x). SwiftUI draws its text into a CGDrawingView, so there is no UILabel
// to recolor, and it paints the card's white as the layer color of its own views.
// Threading: main thread only.
#import <UIKit/UIKit.h>

// Turns the black text under `root` white. Each drawing view is looked at once, by the color its pixels are
// (rendered into a small bitmap): dark neutral ink gets a color-invert filter on its layer, which leaves the
// alpha of the glyphs alone, and ink of any other color (an action's green) is left as Spotify drew it. A view
// that has drawn nothing yet is looked at again on the next call, so it is safe to call on every layout pass.
void SGRLightenDrawnText(UIView *root);

// Turns the dark neutral text of the UILabels under `root` white (black on a toast's white is lost on glass), outside
// `except` (a button's word on its green). A colour Spotify chose on purpose stays.
void SGRLightenLabels(UIView *root, UIView *except);

// Clears the white SwiftUI paints under `root` (layer colors of its views, white and opaque only, so a fill
// Spotify chose on purpose stays) so the glass behind the card shows. Safe to call on every pass.
void SGRClearHostedFill(UIView *root);
