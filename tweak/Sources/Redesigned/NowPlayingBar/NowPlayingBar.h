// The redesign's now playing bar: the glass card it becomes (NowPlayingBar.x), Spotify's device button
// on that card hidden on request (BarConnect.x), glass behind the bar's and the tab bar's stand-ins while
// the player opens and closes (BarTransition.x), and the bar's rows in Mod Settings
// (NowPlayingBarSettings.m). The redesign keeps its own copy of the hide switch and its own key; the
// native look's lives in Native/NowPlayingBar/.
#import <UIKit/UIKit.h>

@class SGModRow;

#define SGRHideBarConnect @"spotifyglass.redesign.hide.barConnect"   // the device button on the card
// The device button kept on the card in the minimized tab bar's row (NowPlayingBar.x), off unless set: by
// default the row has the cover, the title and play alone, as the Music app's. Read each time the card goes
// into the row, so a change shows the next time the bar minimizes.
#define SGRKeyBarInlineConnect @"spotifyglass.redesign.nowPlayingBar.inlineConnect"

// The bar's rows, the Mini player section of the Player page (Redesigned/Player/PlayerSettings.m): Apple
// Music style (the tab bar's Minimize on scroll, Redesigned/Navbar/Navbar.h), the device button in that
// row, and the device button hidden on the full card.
NSArray<SGModRow *> *SGRNowPlayingBarRows(void);

// The bar's glass card in `host`'s coordinates, with its corner radius; CGRectNull before the bar has
// been styled or while it is out of a window (NowPlayingBar.x). The bar keeps its geometry while
// Spotify hides it for the player's open and close.
CGRect SGRNowPlayingCardFrameIn(UIView *host, CGFloat *radius);
// The round artwork on that card in `host`'s coordinates; CGRectNull when none was found.
CGRect SGRNowPlayingArtworkFrameIn(UIView *host);
// Lays the bar out again at once, into the minimized tab bar's slot or back above the bar
// (Navbar.h's SGRTabBarInlineSlot); TabBar.x calls it inside its own animation.
void SGRNowPlayingBarFollowTabBar(void);
// TabBar.x brackets its animated minimize and expand with YES and NO. Meanwhile the bar's own relayout after the Jam
// strip moves waits for the end, so it cannot snap the bar mid-spring.
void SGRNowPlayingBarMoving(BOOL moving);
// The height of Spotify's Jam strip on the bar, 0 outside a Jam (NowPlayingBar.x): the fade under the bars
// (TabBar.x) reaches that much higher, so the strip's text has it behind it too. The tab bar is laid out
// again when it changes.
CGFloat SGRNowPlayingStripHeight(void);
// The Jam strip in `host`'s coordinates, through any transform between them (the minimized tab bar's row moves the
// bar by one); CGRectNull outside a Jam or when the strip is not inside `host`.
CGRect SGRNowPlayingStripFrameIn(UIView *host);
