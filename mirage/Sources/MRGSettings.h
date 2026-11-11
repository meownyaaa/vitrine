#import <UIKit/UIKit.h>
// Mirage's own settings page: Backgrounds now; Addon Shop and AI DJ are placeholders.
void MRGRegisterSettingsPage(void);              // makes the page a Spotify page (SPTPageController) at launch
void MRGShowSettings(UIViewController *owner);   // push on Spotify's stack, or present

void MRGShowDJSettings(UIViewController *owner);   // the AI DJ settings page
