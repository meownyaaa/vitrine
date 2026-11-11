// Mirage's page clearing (MRGBackgrounds.x), for the parts of a page found by other files (MRGProfile.x).
#import <UIKit/UIKit.h>

// Clears an opaque-ish near-black fill (alpha over 0.5, pure #000 included) and keeps it clear through
// Spotify's repaints; a later real color is kept and the view let go. Put back when the page's background goes.
void MRGClearDarkPersistently(UIView *view);
// A list nested in a page (a section's own table or collection view): its fill cleared, and its cells
// cleared as they come and go, like a page's main list.
void MRGAdoptList(UIScrollView *list);
