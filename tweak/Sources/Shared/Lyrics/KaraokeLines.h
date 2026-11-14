// A timed line drawn the Apple Music way, for every column of lyrics there is: the redesign's lyrics page
// (Redesigned/Lyrics/SGRKaraokeView.m) and the lock screen's large cover on a jailbroken phone below iOS 26
// (Vitrine Addon, addons/haptics), which builds this file into MediaRemoteUI. The line being sung lights up word
// by word, a held word glows and its letters wave, a backing row hangs under its line, a line can show its
// pronunciation, its Latin letters and its translation, and three dots hold the place of an instrumental break.
//
// A column stacks the lines (SGKaraokeLineTops), makes a view for each line near the one sung, tells it the
// time on every frame and which line is sung, and places them; how it scrolls and what else it does is its own.
// The numbers below are the column's that both columns share, so the two read alike.
//
// UIKit and the lines alone (Lyrics.h): nothing of the redesign's Kit, the player or the settings, which the
// add-on does not have. Main thread, but for SGKaraokeLineTops.
#import <UIKit/UIKit.h>
#import "Lyrics.h"

// A line's three texts, as the redesign's Lyrics page orders them (Redesigned/Lyrics/LyricsText.h's
// SGRLyricsText has the same values).
typedef NS_ENUM(NSInteger, SGKaraokeText) {
    SGKaraokeTextLyrics = 0,
    SGKaraokeTextPronunciation,
    SGKaraokeTextTranslation,
};

// The column: its side margins, where the sung line rests as a share of the height, the share at the top and
// the bottom the lines fade out over, how much a line blurs for each line it is from the sung one and at the most
// (Apple Music's, scaled by the look's blur), and how much smaller a line not sung is drawn.
static const CGFloat SGKaraokeMargin = 24;
static const CGFloat SGKaraokeAnchor = 0.28;
static const CGFloat SGKaraokeEdgeFade = 0.1;
static const CGFloat SGKaraokeBlurPerLine = 1.4, SGKaraokeMaxBlur = 6;
static const CGFloat SGKaraokeDimScale = 0.97;
// A pause in the singing this long is an instrumental break, and three dots hold its place: from the end of the
// last line sung before it to the start of the next, or from the top of the song to the first line. BiniLyrics'
// web player, which copies Apple Music's, draws them from seven seconds. The dots go this many seconds before the
// next line starts, so it has that long to move up into their place.
static const NSInteger SGKaraokeBreakMinMs = 7000;
static const double SGKaraokeBreakCollapse = 0.5;

// How strongly a held word glows and its letters wave, as shares of Apple Music's: 1 is theirs, 0 none. One for
// every line drawn in the process, 1 until set; lines already drawn take it on their next frame.
void SGKaraokeSetGlowAndWave(CGFloat glow, CGFloat wave);

// Whether a text is written right to left, told by its first letter the way the Unicode bidi algorithm tells a
// paragraph's direction; and whether a line is laid against the right edge: written right to left, or a second
// voice's written left to right.
BOOL SGKaraokeReadsRightToLeft(NSString *text);
BOOL SGKaraokeAlignsRight(SGKaraokeLine *line);

// Which of a line's texts are shown and how big, from the Lyrics page's order of the three and the
// lyrics menu's switches: the first shown is set at the lyrics' own size, and the next two keep the
// sizes of their places whatever is hidden above them, so a translation stays the smallest with the
// pronunciation off. A song is laid out and measured by one of these, so a change of it is a new one.
@interface SGKaraokeStyle : NSObject
@property (nonatomic, readonly) NSArray<NSNumber *> *order;   // SGKaraokeText, largest first, shown ones only
@property (nonatomic, readonly) UIFont *lyrics, *pronunciation, *translation;   // nil for a text not shown
@property (nonatomic, readonly) SGKaraokeStyle *backing;   // the backing row's: smaller, its translation read with the line's
// The line again in Latin letters (Shared/Lyrics' romanized lyrics), at the pronunciation's place in the
// order, since it is one (the second place's while that is the first); nil while the Lyrics page has
// it off. A backing row has none.
@property (nonatomic, readonly) UIFont *romanised;
@property (nonatomic) BOOL japanese;   // the song has kana, so its kanji are read the Japanese way
@property (nonatomic) BOOL romanisedReplace;   // show the Latin letters in place of the line's words
- (instancetype)initWithSize:(CGFloat)size order:(NSArray<NSNumber *> *)order pronunciation:(BOOL)pronunciation translation:(BOOL)translation
                   romanised:(BOOL)romanised;
@end

// Where each line starts in a stack of `lines` as wide as `width`, `gap` apart, and one more: where the stack
// ends. Measuring text is safe off the main thread, and a song's worth of it is best kept off it.
NSArray<NSNumber *> *SGKaraokeLineTops(NSArray<SGKaraokeLine *> *lines, CGFloat width, SGKaraokeStyle *style, CGFloat gap);

@interface SGKaraokeLineView : UIView
@property (nonatomic, readonly) SGKaraokeLine *line;
// Laid against the right edge: a line written right to left, or a second voice's written left to
// right. A backing row keeps to the edge of the line it hangs under, whatever script each is in.
@property (nonatomic, readonly) BOOL right;
// Being sung: its words light up as showTime: reaches them, and dim again once it is not.
@property (nonatomic) BOOL active;
// What VoiceOver's activation of the line does; nil does nothing.
@property (nonatomic, copy) BOOL (^activate)(void);
// The line's blur in points, eased from wherever it is on screen; only a line made `blurred` has one.
@property (nonatomic) CGFloat blur;
// The views of the line's own words, in order, each centered on the word: for a mark a column draws by them.
@property (nonatomic, readonly) NSArray<UIView *> *lyricWords;
// under: the line a backing row hangs under, nil for a line of its own. sweepsEstimates: the words of a
// line timed only by the line are swept on their estimated times, rather than lit whole.
- (instancetype)initWithLine:(SGKaraokeLine *)line width:(CGFloat)width style:(SGKaraokeStyle *)style under:(SGKaraokeLineView *)under
                     blurred:(BOOL)blurred sweepsEstimates:(BOOL)sweepsEstimates;
- (void)showTime:(double)ms;
// Every word lit and left so, for lyrics with no timing: nothing is sung, so nothing is dim.
- (void)showPlain;
@end

// Three dots in place of the lines through an instrumental break, the way Apple Music keeps a long
// pause from reading as lyrics gone missing: they come in as the break begins, breathe while it
// lasts, fill one after another over its length and swell and go as the next line comes up.
//
// All of it is one Core Animation timeline the length of the break, on a layer whose clock is laid
// against the song's: set once as the break opens and again only when the song jumps, stops or
// starts, so the frames in between cost the column nothing. The view itself is moved by the column like
// a line, so the clock is a layer inside it, where a stopped clock cannot stop that move too.
@interface SGKaraokeBreakView : UIView
@property (nonatomic) BOOL right;         // against the right edge, where the line after it is
@property (nonatomic) BOOL rightToLeft;   // filling from the right, the way the line after it reads
- (instancetype)initWithFont:(UIFont *)font;
// The break from `start` to `end`, in the song's ms.
- (void)playFrom:(NSInteger)start to:(NSInteger)end;
// The song at `ms`, running or not, as of `shown` (a frame's target timestamp, in media time).
- (void)showTime:(double)ms running:(BOOL)running at:(CFTimeInterval)shown;
@end
