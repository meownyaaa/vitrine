// Mirage DJ's surfaces: the DJ sheet (artwork header, the line, "Switch it up", a request field, the set as rows),
// the DJ chip on Home and the DJ button and caption on Now Playing. Glass the way Vitrine's redesign draws it:
// UIGlassEffect on iOS 26, a dark material before.
#import <UIKit/UIKit.h>

void MRGShowDJ(UIViewController *from);

// Home. The DJ chip goes at the end of Spotify's filter chips (All, Music, Podcasts…), inside their scroll view,
// styled from Spotify's own chip; MRGDJPlaceChipInPills runs on the chip row's layout passes. When the chips are
// not shown (Vitrine's redesign replaces them with a title, or "hide the filter pills" is on) the chip sits in the
// header row instead: before the redesign's glass pill, or where the chips would start. Both follow the
// "DJ button on Home" setting. MRGDJPlaceHomeEntry runs on Home's page layout passes.
void MRGDJPlaceHomeEntry(UIView *homeView);
void MRGDJPlaceChipInPills(UIView *pillScrollView);
UIView *MRGDJChipHit(UIView *pillScrollView, CGPoint point, UIEvent *event);   // the chip under a touch, or nil
void MRGDJFollowHeaderButtons(UIView *buttons);   // re-places the header chip beside the redesign pill (layout, rise, fade)

// Now Playing: a DJ button in the header row, before the ⋯ (a spacer after the ⌄ keeps the title centered), and a
// glass caption under the header with the line while the DJ talks. Runs on the header unit's layout passes.
void MRGDJPlacePlayerButton(UIViewController *headerUnit);
