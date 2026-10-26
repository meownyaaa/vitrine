// The text and the controls of a redesigned page's header, under its full bleed picture, the way the Music
// app (iOS 26.4) sets a playlist or an album: the title, the creator and the length centered, one row of
// shuffle, a white Play capsule and one more round button, and the description under the row.
//
// A page conceals what Spotify draws in its header and puts this in its place, so nothing of Spotify's lays
// it out. It keeps no state of its own: the page hands it the text it read (from Spotify's model or from
// Spotify's concealed labels) and Spotify's own controls to draw from and fire, on every pass, and it lays
// itself out again only when something it shows changed.
//
// Its content sits on its bottom edge with SGRHeaderInfoBottom under it, whatever height the page gives it,
// so the buttons stay just above the first track; what does not fit rises over the picture. The page's
// picture reaches SGRHeaderInfoTitleRise below the content's top, so the title and the creator sit on the
// bottom of its dissolve. A page whose header changes height under it (the album's, a point or more as Play
// turns to Pause, more with a taller font) pins the content's top instead (pinnedTop).
//
// Ownership: the page that adds it; it keeps only weak references to Spotify's controls.
// Threading: main thread only.
#import <UIKit/UIKit.h>

extern const CGFloat SGRHeaderInfoBottom;     // 14, under the content
extern const CGFloat SGRHeaderInfoTitleRise;  // 56, of the content over the picture

// Full bleed covers (issue #98): the album's and the playlist's cover across the top of the page. Off, the cover
// is the square Spotify lays out above the title, and only an album's animated cover still runs full bleed. On
// until switched off (Appearance), read once, by the first album or playlist header.
#define SGRKeyFullBleedCovers @"spotifyglass.redesign.fullBleedCovers"
BOOL SGRFullBleedCovers(void);

@interface SGRHeaderInfo : UIView
// YES when anything shown changed. nil or empty hides that line.
- (BOOL)showTitle:(NSString *)title creator:(NSString *)creator length:(NSString *)length about:(NSString *)about;
// Spotify's own control behind the creator line -- the album's artist row, the playlist's collaborators
// button -- so a tap on the line opens whoever made it, and several of them open Spotify's own picker.
// The line keeps its color: it is the page's one piece of secondary text, not a link to be tinted. nil
// leaves it as text.
- (void)showCreatorLink:(UIView *)control;
// The picture of whoever made it -- the album's artist, the playlist's owner -- drawn round, a line high, before
// the creator's name, the two centered together, as Spotify's own facepile sat beside the name. `source` is the
// image view Spotify draws it in (SGRCreatorPicture), followed as Spotify fills it, so a picture that lands
// after the page has laid out still shows. With no picture in it, or nil, the name stands alone.
- (void)showCreatorPicture:(UIImageView *)source;
// For a trailing control that shows its state only as a word (the artist's Follow): SGRMirrorButton's
// readState and its two symbols. Set before the first -showShuffle:...; -trailingStateChanged redraws it.
@property (nonatomic, copy) BOOL (^trailingState)(BOOL *on);
@property (nonatomic, copy) NSString *trailingOffSymbol;
@property (nonatomic, copy) NSString *trailingOnSymbol;
- (void)trailingStateChanged;
// Spotify's controls, each drawn from and fired; nil hides that button. Play stays in the middle of the
// page whether the other two are there or not. `trailingFallback` is drawn when Spotify's trailing control
// has no image to copy. `playColor` is the color of the capsule's glyph and word.
- (void)showShuffle:(UIView *)shuffle play:(UIView *)play trailing:(UIView *)trailing
   trailingFallback:(UIImage *)trailingFallback playColor:(UIColor *)playColor;
// A picture drawn in the title's place, such as an artist's logo; the title stays its spoken name. nil
// draws the title again.
- (void)showTitleImage:(UIImage *)image;
// The height the content wants at `width`, from the top of the title to the bottom of the description.
- (CGFloat)contentHeightForWidth:(CGFloat)width;
// Where the content starts, from the top; 0 keeps it on the bottom edge. Content that would then run past the
// bottom goes back on the bottom edge.
@property (nonatomic) CGFloat pinnedTop;
// Kept for the page, which reads them back to tell whether a pass has anything new to hand over: the play color
// it last handed over, and whether it has found Spotify's buttons' row. The info itself never reads them.
@property (nonatomic, strong) UIColor *handedPlayColor;
@property (nonatomic) BOOL rowFound;
@end

// The image view of the leading face on Spotify's creator line `root` -- the playlist header's collaborators
// button, which carries a facepile, or the album header's artist row, which carries an Encore.ImageView: the
// square image view nearest the leading edge, so a badge after the name is not taken for it. nil when there is
// none yet.
UIImageView *SGRCreatorPicture(UIView *root);
