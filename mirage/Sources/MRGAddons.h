// The Addon Shop: a list of addons from the repo (addons/index.json on GitHub, with a copy built in), each one a
// feature that ships inside Mirage and stays off until it's installed here. Nothing is downloaded and run (iOS apps
// can't safely load code); the shop only turns built-in features on, keeps their settings, and fetches preview
// images. Installed state lives in NSUserDefaults (mirage.addon.<id>), and changes post MRGSettingsChangedNotification.
#import <UIKit/UIKit.h>

BOOL MRGAddonInstalled(NSString *addonID);
void MRGAddonSetInstalled(NSString *addonID, BOOL on);
NSUInteger MRGAddonsInstalledCount(void);
BOOL MRGAddonBuiltIn(NSString *addonID);                // this Mirage carries the feature
NSArray<NSDictionary *> *MRGAddonIndex(void);           // last fetched index, else the built-in copy
void MRGAddonRefresh(void (^done)(NSArray<NSDictionary *> *addons, NSString *error));
UIViewController *MRGAddonShopPage(void);

// Vinyl (Now Playing): seconds per turn and which side the record peeks out on.
double MRGVinylSecondsPerTurn(void);
void MRGVinylSetSecondsPerTurn(double s);
BOOL MRGVinylOnLeft(void);
void MRGVinylSetOnLeft(BOOL left);
