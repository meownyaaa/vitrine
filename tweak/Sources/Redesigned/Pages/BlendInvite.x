// Create a Blend (Blend_BlendInvitationImpl.BIViewController): the redesign's bar over the page (Pages/PageBar.m),
// Spotify's header gone and Back a glass circle.
//
// Tree: BIView on #000000 holds a UIScrollView with the face pile, the heading, the text and the Invite button (at {48, 91});
// over it the navigation controller's blur (390x91, #1C1C1C@0.73) and SPNavigationBar with Back and no title. The
// page is a child of a MusicAppPageHostingViewController, the top of the stack, and the content already sits below the bar,
// so only the bar changes.
// Threading: main thread only.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Pages.h"

%ctor {
    if (!SGRedesignedUI() || !SGBelowiOS26()) return;
    Class page = SGRSwiftClass(@"Blend_BlendInvitationImpl", @"BIViewController");
    if (!page) SGLog(@"class Blend_BlendInvitationImpl.BIViewController not found, Create a Blend keeps Spotify's bar");
    SGRDressBarPagesOf(page, YES);
}
