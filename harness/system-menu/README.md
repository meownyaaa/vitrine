# System menu harness

`Redesigned/ContextMenu/ContextMenu.x` and `Redesigned/Player/PlayerMenu.m` run for real against a mock of
Spotify's player ⋯ and its context menu sheet (`ContextMenu_InternalImpl.ContextMenuViewController` under its
class name, inside a navigation controller): 15 rows, each an Encore-style ListRow control whose identifier is
Spotify's item number and which acts on touch up inside, no `didSelect`, Sleep timer last and below the sheet's
fold, as on the phone. On the iOS 16 simulator the redesign runs as untested (`spotifyglass.redesign.untested`). Speed, pitch, reverb and Animated artwork are stubs that log.

    THEOS=$HOME/theos ./build.sh
    xcrun simctl install <udid> build/SystemMenuHarness.app
    xcrun simctl launch --console-pty <udid> com.vitrine.systemmenuharness <scenario>

The header row is shaped like Spotify's (`trees/clean/player/01.txt`: a 402x48 row, the down arrow 48x48 at x 12
and the ⋯ 48x48 at the trailing edge), each button with a 44pt glass circle first among its subviews taking no
touches, as `PlayerHeader.x` leaves them. The player's ⋯ is the mod's own pull-down button over Spotify's ⋯, and
a tap on it is a finger's touch (`../tabbar/touch.m`), down and up at its middle: UIKit opens the button's menu
on the touch down. (Until 2026-10-06 the harness tapped with `-performPrimaryAction`, which opens a button's menu
whether or not the button holds one yet, and so missed that a finger's touch on the mod's button, holding none
until asked, was taken and opened nothing: the phone's ⋯ did nothing.) Each run taps at 1 s and prints `PASS`
or `FAIL` lines, then `done`. A pick, or opening a submenu, goes through the menu view's own
selection (`_UIContextMenuView`'s `_handleSelectionForElement:`), the harness's only private call; the mod's own
lines (`SGLog`) go to the unified log.

Every scenario but `timing` first checks the top level: the menu is on screen (within 1 s, the simulator's
first menu of a launch being slow), the mod's ⋯ takes touches, the quick row (Share, Add to Playlist, Add to
Queue), Speed, Pitch & Reverb, Show Animated Artwork and More are in it and none of Spotify's other rows are;
then that Spotify's ⋯ action ran once, from code, after the menu was up, that Speed and pitch was told the
sheet is the player's, and that the sheet is in the mod's window under the app's, unseen, with the menu still up.

- `arrow`: the mod's ⋯ sits exactly over Spotify's in the window, above its glass circle and glyph, with the ⋯'s
  label for VoiceOver; a finger on the down arrow runs Spotify's arrow action, reaches nothing of the mod's and
  opens no menu; a finger on the ⋯ then sends the mod's button its touch down and opens the menu, and the press
  (what `PlayerHeader.x`'s circle listens to) holds while the menu is up and is let go as it ends.
- `timing`: ten taps, each closed again; logs the time from the touch down to the menu view in the hierarchy
  (UIKit presents it inside the touch's delivery, so 2 to 4 ms warm), and the median, best and worst of the last
  nine (the first pays for UIKit's menu classes loading).
- `rows`: More holds Go to album, the grayed-out Lyrics and Sleep timer (below the sheet's fold), not the rows
  the quick row has; picking Go to album taps Spotify's row and the sheet goes.
- `loading`: the first menu ever, its rows 1.5 s late: More shows the system's loading row, then the rows come
  into the open More, and Go to album fires.
- `stored`: a first menu reads and stores the rows and is closed with no pick (its sheet goes); a second menu's
  sheet holds its rows back: More shows the stored rows at once, a pick on them waits, and fires once the live
  rows come.
- `quick`: Add to Queue is picked at once; the rows come 1.2 s after the sheet, and the pick waits for them.
- `quicklate`: Add to Playlist is picked and the rows never come: after 4 s Spotify's sheet is shown.
- `podcast`: a sheet with no Add to playlist row: once its rows are in, the quick row drops Add to Playlist while
  the menu is up, and More holds Go to show.
- `close`: closing the menu with no pick takes the hidden sheet away within 1 s, and a second tap opens again.
- `subpage`: the quick Share taps Spotify's Share, which pushes a page inside the sheet: the sheet is shown over
  the player, on that page; closed, the mod's window goes back under the app's.
- `sleep`: More's Sleep timer (item 51) is picked: the menu goes, Spotify's row is tapped on the hidden sheet, which
  pushes its options page (Encore list rows, no table) 0.3 s later, and the page's rows open as a menu of their own
  from the ⋯, under its heading, with Back; the sheet stays hidden, and picking 5 minutes taps it on the page, after
  which the page and the sheet go, unseen.
- `sleeppresent`: the same with Sleep timer presenting a context menu sheet of its own from the player, as on the
  phone: it goes up from the hidden sheet instead, hidden and taking no touches, and its table rows fill the menu.
- `sleepwrapped`: the same, with the sleep timer's sheet inside a container that puts it in only as it appears
  (NavigationUI_SheetImpl.ContainerViewController on the phone), and Spotify's card taken down before it, as on
  the phone: it is still kept hidden and fills the menu, which opens though the card is gone.
- `sleepback`: as `sleepwrapped`, then Back 4.5 s after the times came (past `kPageWait`, when nothing of the pick holds
  the menu's session): the menu opens again though Spotify's card is gone, from a fresh session that asks for a card of
  its own, and the timer's sheet goes.
- `pagepopup`: Voice language (item 0), a row the mod does not know, pushes a page: its rows open as a menu of their
  own, under its heading, with Back and the picked row checked, and the row is kept as one that opens a page; Back pops
  the page and opens the menu again; Voice language is then a submenu of the page's stored rows, opened at once, and
  German picked from it fires Voice language on the hidden sheet and German on the page it opens.
- `sort`: a row of the mod's own in the sheet's header (as the playlist's Sort) is in More and fires.
- `animated`: Show Animated Artwork switches it on and the sheet goes.
- `wrapped`: Spotify presents a controller of its own that puts the sheet in only as it appears
  (NavigationUI_SheetImpl.ContainerViewController on the phone); More and a pick work the same.
