// The base of every page of the mod's, pushable onto Spotify's own navigation stack.
#import <UIKit/UIKit.h>

@interface SGPage : UITableViewController
@end

// Registers SGPage as one of Spotify's pages; called once, from the settings hook's %ctor.
void SGRegisterPages(void);
// Pushes the page if it can go on Spotify's stack, presents it otherwise.
void SGShowPage(UIViewController *owner, UIViewController *page);
// Mod Settings, pushed onto the selected tab's stack; `source` is any view on the tab bar.
void SGOpenModSettings(UIView *source);

// The redesign's bar over a page of the mod's that is on Spotify's own stack (Redesigned/Pages/ModPageBar.x): Spotify's blur
// behind the bar gone, Back on glass and the title on a glass capsule. Declared here and defined there, so Settings needs
// nothing of the redesign; both do nothing under the native look, on iOS 26 and for a page presented in a stack of its own.
// A page calls the first as it appears and lays out, and the second as it goes. Cheap to call again.
void SGDressPageBar(UIViewController *page);
void SGUndressPageBar(UIViewController *page);
// For a page that is its own table, as it scrolls: the pinned Back put back at the top of the screen, and nothing else of
// the bar made again.
void SGPlacePageBar(UIViewController *page);
