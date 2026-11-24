// The Profile redesign, iOS < 26: the lists a person's profile opens (Followers, Following, the playlists they
// have), pages holding Profile_CommonImpl.ProfileListView under UIKit's own navigation bar.
//
//     ProfileHeader.x   a person's own page: the header's Back and ⋯ pinned as glass circles, the name in the bar on a
//                       glass capsule (Playlist/PlaylistBar.x)
//     ProfileListBar.x  the bar the way the playlist's has it (Pages/PageBar.m): the back button on a glass
//                       circle pinned to the corner, the title on a glass capsule, the dark blur Spotify lays
//                       behind the bar gone
//     ProfilePlaylists.x the page that adds playlists to the profile (PlaylistEditing_PlaylistsProfileVisibilityPageImpl): the
//                       same bar with no capsule, since the page has no title, and the black plate behind its Remove from
//                       profile button replaced by the queue's glass
//     ProfileEdit.x     the Edit profile sheet: the pane on the queue's glass, Cancel, Save and the title on glass capsules
//
// Every hook installs only while Redesigned UI is on (SGRedesignedUI), and below iOS 26: from 26 on UIKit's own
// bar is glass already.
// Threading: main thread only.
#import <UIKit/UIKit.h>

// The profile page (Profile_CommonImpl.ProfileView) `view` is on, or nil: Profile/ProfileHeader.x pins its Back and ⋯.
UIView *SGRProfilePageOf(UIView *view);
