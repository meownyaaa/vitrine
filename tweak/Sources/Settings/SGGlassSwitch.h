// The legacy glass's switches and slider thumbs on the mod's own pages (SGGlassSwitch.x).
#import <UIKit/UIKit.h>

// Set by a higher layer that draws some of Spotify's own switches as the mod's pages do (the redesign's settings rows,
// Redesigned/Kit/SGRSettingsSwitches.x): YES for a switch of Spotify's that takes the mod's drawing. Nil, none do.
extern BOOL (*SGGlassSwitchTakesSpotify)(UISwitch *toggle);
