// The redesign of the pages Spotify draws under a plain UINavigationBar (SPNavigationBar) rather than under a header
// of its own: the glass the Playlist, Album and Artist pages have at the top, on the pages that had none.
//
//     PageBar.m       the bar: its blur taken off, the page's title on a glass capsule, the back button and the
//                     page's ⋯ pinned to the corners as glass circles (Kit/SGRActionRow.h)
//     Recents.x       the listening history (Recents_RecentsPageImpl): the bar, its chips on glass, and the list
//                     run under the bars instead of stopping short of them
//     YourUpdates.x   the left menu's Your Updates (YourUpdates_CommonImpl): the bar
//     SongDNABlend.x  Song DNA's "songs together" page (SongDNA_ArtistsDNAPageImpl): the bar, Back, Share and Close on glass
//     ArtistConcerts.x an artist's concerts page (LiveEvents_ArtistLiveEventsPageImpl): the bar
//     LocationSearch.x the Preferred location page (LiveEvents_LiveEventsImpl), whose header is the page's own: title, Back and field on glass
//     ShowSearch.x    a podcast's "Find in this show" page (ShowPage_ShowSearchPageImpl): the bar, the field and Cancel on glass
//     ErrorToast.x    the page loader's "Something went wrong" toast (Tome_MusicClientPageLoaderViewKit): glass card with Reload as Spotify
//                     draws it, and the cross at the top-left of the page on a glass circle
//     AccountPlus.x   the plus of Add account on glass, in the left menu's facepile and list of accounts and on "Who's listening?"
//     AccountPickerGlass.x  "Who's listening?": the Add account circle on glass, and Spotify's blur behind its bar off
//     AIPlaylistGlass.x the AI playlist's chat (AIPlaylist_PlaylistCreationPageImpl): the header's cross, Cancel and ⋯ on glass
//     AIPlaylistChat.x  the same chat's last response, the Try asking cards and the Refine field on glass, the black behind them gone
//     AIPlaylistMore.x  the popup of its ⋯ (Report a problem, Clear conversation) as the queue's glass
//     ImportMusic.x   Import your music (TheStage_VtecImpl.VtecContainerController): the bar, Back on glass
//     BlendInvite.x   Create a Blend (Blend_BlendInvitationImpl.BIViewController): the bar, Back on glass
//     MadeForYou.x    Made For You (SPTMadeForYouHubViewController): the bar, the title on glass, the covers at Home's radius
//     NewEpisodes.x   the Library's New Episodes (SPTYourLibraryPodcastNewEpisodesViewController): the bar, the title and Back on glass
//     ContentPicker.x Add artists and Add podcasts (AllBoarding_AllBoardingPlatformImpl): the cross and the search field on glass
//     WebBrowser.x    Spotify's in-app browser (SPTWebViewControllerImplementation, Settings > About): close, Back and Forward on glass
//     LiveEvents.x    Live Events (LiveEvents_LiveEventsPageImpl): the title, Back, Saved and Notifications on glass, the list under the bars;
//                     the pages it opens (LiveEvents_GalleryPageImpl): Back and the title on glass, no gradients, the list under the bars
//     Equalizer.x     Spotify's Equalizer (SPTEqualizerViewController): the bar, the curve under it, the presets under the bars
//     ModPageBar.x    the mod's own pages (Mod Settings and every SGModPage on Spotify's stack): the bar, Back on glass
//
// The hosted pages that are dressed by what they hold -- Messages, Settings and its sections, Listening stats, Your Premium
// and the rest -- are listed in Kit/SGRPlainBar.x.
//

// Every hook installs only while Redesigned UI is on and below iOS 26, where the bars are the system's.
// Threading: main thread only.
#import <UIKit/UIKit.h>
#import "Redesigned/Kit/SGRPass.h"

// Whether `top` is a view controller of class `page` or holds one among its children (pages are hosted by Spotify's
// page template, so the top of the stack is the host).
BOOL SGRPageIsOrHolds(UIViewController *top, Class page);

// The Live Events gallery page (LiveEvents_GalleryPageImpl.GalleryPageViewController: Popular events, Venues, All events...)
// `view` is on, as its root view, or nil: Playlist/PlaylistBar.x refuses the gradients of such a page.
UIView *SGRGalleryPageOf(UIView *view);

// Dresses the bar of the navigation controller `page` is in, while `page` is the one on screen: from its layout
// passes and as it appears. Cheap to call again.
void SGRDressBarPage(UIViewController *page);
// The same for a page whose bar has no title (the profile's Add playlist page: an empty SwiftUI item in the title control):
// Back is pinned and the blur is gone as above, and the title carries no capsule, however the control is laid out.
// Given back with the rest, by SGRUndressBarPage.
void SGRDressBarPageTitleless(UIViewController *page);
// The same for a page with no ⋯ of its own (Settings and its sections, the mod's pages): Back and the title are dressed,
// and the controls at the trailing edge are left as Spotify has them. Given back with the rest, by SGRUndressBarPage.
void SGRDressBarPageBackOnly(UIViewController *page);
// Gives the bar back the way Spotify made it, for the next page: as `page` goes.
void SGRUndressBarPage(UIViewController *page);

// Registers a page the redesign dresses: `wants` says whether the page on top of a navigation controller is one. While one is,
// Spotify's blur behind the bar is kept off from the moment the page is pushed, instead of from the first pass of the page
// that finds the bar, and again whenever Spotify brings it back (the app left and entered again).
typedef BOOL (^SGRBarPageTest)(UIViewController *top);
void SGRRegisterBarPages(SGRBarPageTest wants);
// Puts the blur of `navigation` where its top page wants it: drawn by nothing for a dressed page, Spotify's again for any other.
// Cheap to call again.
void SGRSyncBarBlur(UINavigationController *navigation);
// Spotify's blur behind the bar of `navigation`: the plain view of its own that holds a UIVisualEffectView. Nil when none.
UIView *SGRBarBlurOf(UINavigationController *navigation);
// The first control with a size in the bar's stack of items on the leading or the trailing half of its content view
// (`content`, the bar's _UINavigationBarContentView). Nil when that half has none.
UIView *SGRBarStackButton(UIView *content, BOOL leading);

// `pass` on every layout of an SPNavigationBar and of its content view, where UIKit builds the bar's Back and title again
// after the bar's own pass (PageAppearance.x hooks the two once for every page that is dressed from its bar).
void SGRObserveBarPasses(void (^pass)(UIView *bar));

// How a page's bar is dressed: SGRDressBarPage, SGRDressBarPageTitleless or SGRDressBarPageBackOnly.
typedef NS_ENUM(NSInteger, SGRBarStyle) { SGRBarStyleFull, SGRBarStyleTitleless, SGRBarStyleBackOnly };

// The pages of class `page`: their bar dressed on their own passes and given back as they go, Spotify's blur off from the
// push (SGRRegisterBarPages). `hosted`: the page is a child of Spotify's page template, which is the top of the stack.
// Nothing when `page` is nil.
void SGRDressBarPagesOf(Class page, BOOL hosted);
// The same with a pass of the page's own, which dresses the bar itself (SGRDressBarPage) along with whatever else the
// page needs; the bar is given back as the page goes.
void SGRDressBarPagesWith(Class page, BOOL hosted, SGRControllerPass dress);

// The pages told by what they hold rather than by a class: `find` picks the page to dress from a navigation controller
// (nil when none of these is on top), and the bar is dressed from its own passes while that page is on screen and given
// back once it is not. Spotify's blur is off from the push for them too.
typedef UIViewController *(^SGRBarPageFind)(UINavigationController *navigation);
void SGRDressBarPagesFound(SGRBarPageFind find, SGRBarStyle style);

// The AI playlist chat's body on glass, from the page's own passes (Pages/AIPlaylistChat.x): the opaque black and the fades
// behind the last response and the footer go, and any card, bubble or field the views' own passes have not met yet is dressed.
// Cheap to call again; below iOS 26 only.
void SGRAIPlaylistDressChat(UIView *page);
