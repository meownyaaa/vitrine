// Mirage DJ's debug log: the last 200 lines of what the DJ did (Web API calls and their answers, which play path ran
// and what came of it, the player's state), kept on the phone (Library/Mirage/dj.log) so it survives a relaunch, for
// Settings → Mirage → AI DJ → DJ debug log, which shows and copies it. No keys, tokens or listening history.
#import <UIKit/UIKit.h>

void MRGDJLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
NSString *MRGDJLogText(void);
void MRGDJLogClear(void);
UIViewController *MRGDJLogPage(void);

// The accent everything DJ is drawn in: Vitrine's accent color for the look in use when one is set (the redesign's,
// #37F200 by default, or the native look's), Spotify's green otherwise. And the text color that reads on it.
UIColor *MRGAccent(void);
UIColor *MRGOnAccent(void);
