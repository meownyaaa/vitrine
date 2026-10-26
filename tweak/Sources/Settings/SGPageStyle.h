// The look of every page of the mod's, in the dark appearance: cards of #1C1C1E on black, 13pt titles over 11pt
// gray subtitles in Spotify's typeface, 11pt uppercase section headers and notes, a white symbol on a colored
// rounded square leading a row, white chevrons, switches in the look's accent color. The text follows Dynamic
// Type through the accessibility sizes, and the app font of Shared/Fonts.
#import <UIKit/UIKit.h>

UIColor *SGGrey(void);   // the secondary label's gray
UIColor *SGGreen(void);
UIColor *SGOnAccent(void); // black or white text on the accent
UIColor *SGAccentMark(void); // a visible accent mark on a dark card
UIColor *SGRed(void);
UIColor *SGPageBackground(void);
UIColor *SGCardBackground(void);
UIFont *SGTitleFont(void);      // a row's title and value, 13pt
UIFont *SGSubtitleFont(void);   // subtitles, section headers, footers and notes, 11pt
// Both grow through the accessibility sizes with no cap. A control beside a row's title, or text inside a
// drawing of fixed size, caps its copy so the title keeps its room.
UIFont *SGCappedFont(UIFont *font, CGFloat largest);
BOOL SGAccessibilityTextSize(void);   // an accessibility size, where a row's value goes under its title
// A slider row's text, laid out by hand: the title with its value at the trailing edge, or at the accessibility
// sizes the title wrapped across the row with the value under it, then the subtitle when it has one. The
// layout returns the y under the text; the height is the same text measured at the same width.
CGFloat SGSliderTextHeight(NSString *title, NSString *subtitle, CGFloat width);
CGFloat SGLayOutSliderText(UILabel *title, UILabel *value, UILabel *subtitle, CGFloat x, CGFloat y, CGFloat width);
// Takes the rows' title font off Spotify's own settings list or side drawer, once for each, for the Mod Settings row
// the mod adds to it (App/ModSettings.x), which reads as one of Spotify's rows; SGSpotifyListFont hands it out. YES
// on the call that found it.
BOOL SGAdoptFonts(UIView *list, UIView *exclude, BOOL drawer);
UIFont *SGSpotifyListFont(BOOL drawer);

UIImageView *SGSymbolView(NSString *name, CGFloat size, UIImageSymbolWeight weight, CGFloat box);
// A white symbol on a rounded square of `color`, the leading icon of a row; SGTileImage's square is gray.
UIImage *SGTileImageTinted(NSString *symbol, UIColor *color);
UIImage *SGTileImage(NSString *symbol);
// The chevron of a row that opens a page, in the tertiary label's gray.
UIImageView *SGChevronView(void);
// The separator inset of a row led by a tile, so the hairline starts under the title as in Settings.
extern const CGFloat SGTileRowInset;
// A gray note in a wrapper view, for a table header or footer; SGFitNote sizes it to its text.
UIView *SGNote(NSString *text);
void SGFitNote(UITableView *table, UIView *wrapper, CGFloat top, CGFloat bottom);
// The now playing bar and the tab bar float over the content, so a page insets itself under them.
void SGInsetForBars(UITableView *table);

CGFloat SGSectionHeaderHeight(void);   // grows with the header's text
extern const CGFloat SGSectionGap;   // above a section with no header, so its card does not touch the one before
void SGFillCell(UITableViewCell *cell, NSString *title, NSString *subtitle, UIColor *color, NSString *symbolName);
UIView *SGSectionHeader(UITableView *table, NSString *title);
UIView *SGSectionFooter(UITableView *table, NSString *text);
CGFloat SGSectionFooterHeight(UITableView *table, NSString *text);
UITableViewCell *SGDequeueCell(UITableView *table, NSString *identifier);

void SGOpenURL(NSString *url);
extern NSString *const SGRepoURL;
// The controller on top of the key window, through whatever is presented over it.
UIViewController *SGTopController(void);
// `panel` as a dark popover from `from`, at its preferredContentSize, a popover on iPhone too. Picked from a
// system menu, which is still going away, it waits for the menu.
void SGPresentPopover(UIViewController *panel, UIView *from);
