// The drawing of a timed line, KaraokeLines.h's: its words, how it is set, where its words go, the sweep that
// lights them, the line itself and the dots of a break. Moved here whole from the redesign's lyrics page, so the
// lock screen's lines (Vitrine Addon) are drawn by the same code.
//
// Only words the source timed are swept. A line timed by the line lights up whole as it starts, as
// Apple Music lights such a line, unless the column asks for its estimated words to be swept; lyrics
// with no timing at all are shown as plain text, every line lit, nothing following the clock.
#import "KaraokeLines.h"

static const CGFloat kRowTighten = 2;
static const CGFloat kDimAlpha = 0.3, kFillEdge = 22, kLift = 2.5;
// The (oh, aye) hanging under a line: smaller, a little dimmer, and just clear of it.
static const CGFloat kBackingScale = 0.62, kBackingAlpha = 0.8, kBackingGap = 4;
static const double kFloatMinMs = 700, kFloatLeadMs = 80;   // a short word still floats up this slowly
// A word held this long starts to glow, and one held kGlowFullMs glows fully. The glow grows over the
// word and fades over kGlowFadeMs after it.
static const double kGlowFromMs = 900, kGlowFullMs = 2400, kGlowFadeMs = 450;
static const CGFloat kGlowRadius = 9, kGlowOpacity = 0.85;
// The room the sweep's mask leaves around the lit part of a word for its glow: past the widest shadow's
// visible tail, so the glow is cut nowhere but at the sweep's feathered edge (issue #68).
static const CGFloat kGlowReach = kGlowRadius * 4;
// How strongly the glow and the wave below are drawn (SGKaraokeSetGlowAndWave), 1 being as here.
static CGFloat sg_glowScale = 1, sg_waveScale = 1;
// A word held long enough to glow lifts its letters one after another as the sweep reaches each, a wave
// running through it, as high as this share of the font for the word held longest: a letter starts up a
// little before the sweep's edge reaches its middle and is up over this share of the word's time. They come
// down with the glow once the word is sung, and the wave is left out under Reduce Motion.
static const CGFloat kWaveShare = 0.1;
static const double kWaveLead = 0.08, kWaveSpan = 0.3;
// A line lit whole: how long its words take to come up to full white, and to float up together.
static const NSTimeInterval kWholeFade = 0.35;
static const double kWholeRiseMs = 900;
static NSString *const kBlurPath = @"filters.gaussianBlur.inputRadius";
// The dots' size and the room between them, as shares of the font, which is Apple Music's proportion.
static const CGFloat kDotShare = 0.5, kDotGapShare = 0.27;
// Their timeline, Apple Music's as that player reads it off: in over 0.4 s, breathing between 85 % and
// 112 % of their size in eight second cycles, filling one after another, then swelling to 120 % and
// shrinking away in 0.35 s, which ends half a second before the next line starts so it has that long
// to move up into their place (SGKaraokeBreakCollapse). A cycle is timed to end small, so the swell starts
// from the bottom. They wait a quarter of a second before they come, for the line before them to move up out of
// the way.
static const double kBreakWait = 0.25, kBreakIn = 0.4, kBreakFadeIn = 0.16, kBreathHalf = 4, kBreathLow = 0.85, kBreathHigh = 1.12;
static const double kBreakOut = 0.35, kBreakSwell = 1.2, kBreakSwellShare = 0.35;
// The dots' clock is set again only once it is this far from the song's, or the song stops or starts.
static const double kBreakSlack = 0.03;

void SGKaraokeSetGlowAndWave(CGFloat glow, CGFloat wave) {
    sg_glowScale = glow;
    sg_waveScale = wave;
}

@interface CAFilter : NSObject
+ (instancetype)filterWithType:(NSString *)type;
@end

// Whether a line is written right to left, told by its first letter the way the Unicode bidi algorithm
// tells a paragraph's direction. Each line is asked on its own, since a song can mix scripts, and the
// phone's language has no say in it.
BOOL SGKaraokeReadsRightToLeft(NSString *text) {
    static NSCharacterSet *rightToLeft, *leftToRight;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableCharacterSet *scripts = [NSMutableCharacterSet new];
        [scripts addCharactersInRange:NSMakeRange(0x0590, 0x370)];    // Hebrew, Arabic, Syriac, Thaana, N'Ko and on
        [scripts addCharactersInRange:NSMakeRange(0xFB1D, 0x2E3)];    // Hebrew and Arabic presentation forms
        [scripts addCharactersInRange:NSMakeRange(0xFE70, 0x90)];     // Arabic presentation forms B
        [scripts addCharactersInRange:NSMakeRange(0x10800, 0x800)];   // the old scripts written right to left
        [scripts addCharactersInRange:NSMakeRange(0x1E800, 0x800)];   // Mende Kikakui and Adlam
        NSMutableCharacterSet *letters = [NSCharacterSet.letterCharacterSet mutableCopy];
        [letters formIntersectionWithCharacterSet:scripts.invertedSet];
        leftToRight = [letters copy];
        [scripts formIntersectionWithCharacterSet:NSCharacterSet.letterCharacterSet];
        rightToLeft = [scripts copy];
    });
    NSUInteger first = [text rangeOfCharacterFromSet:rightToLeft].location;
    return first != NSNotFound && first < [text rangeOfCharacterFromSet:leftToRight].location;
}

// Laid against the right edge: a line written right to left, or a second voice's written left to right.
BOOL SGKaraokeAlignsRight(SGKaraokeLine *line) {
    return (line.align == SGKaraokeAlignTrailing) != SGKaraokeReadsRightToLeft(SGKaraokeLineText(line));
}

static UILabel *wordLabel(NSString *text, UIFont *font, UIColor *color, CGRect frame, BOOL rightToLeft) {
    UILabel *label = [[UILabel alloc] initWithFrame:frame];
    label.text = text;
    label.font = font;
    label.textColor = color;
    if (!rightToLeft) return label;
    // A word of a line written right to left is set in the line's direction, so the punctuation at its
    // ends falls where the whole line would put it, a word of a left to right script among them too.
    NSMutableParagraphStyle *paragraph = [NSMutableParagraphStyle new];
    paragraph.baseWritingDirection = NSWritingDirectionRightToLeft;
    label.attributedText = [[NSAttributedString alloc] initWithString:text attributes:@{
        NSFontAttributeName: font, NSForegroundColorAttributeName: color, NSParagraphStyleAttributeName: paragraph}];
    return label;
}

#pragma mark - a word

// The word twice: dim underneath, white on top behind a mask whose feathered edge slides across it,
// from the edge its script starts at.
@interface SGKaraokeWordView : UIView
@property (nonatomic, readonly) SGKaraokeWord *word;
@property (nonatomic, readonly) UIView *lit;   // a label, or for a word that waves a view of its letters
@property (nonatomic) CGFloat offset;   // where the word starts along its line, rows laid end to end
// Lit with the rest of its line at once rather than swept, and floated up with it over riseStart to
// riseEnd, which are the word's own times until the sweep says otherwise.
@property (nonatomic) BOOL whole;
@property (nonatomic) double riseStart, riseEnd;
- (void)fillTo:(CGFloat)cursor;
- (void)floatAt:(double)ms;
- (void)settle;   // land and unglow at once
- (void)land;     // back down from its float
- (void)unglow;   // the glow off
@end

@implementation SGKaraokeWordView {
    CAGradientLayer *_fill;
    CGFloat _filled, _lift, _glow;
    BOOL _rightToLeft;
    // A word that waves: its letters, dim and lit, each letter's middle as a share of the word's width,
    // and how high each is lifted now.
    NSArray<UILabel *> *_dimLetters, *_litLetters;
    CGFloat *_letterAt, *_letterLift;
    CGFloat _waveHeight;
}

// The word set letter by letter, each where the whole word would put it, in a view the word's size.
static UIView *lettersOf(NSArray<NSString *> *letters, NSArray<NSNumber *> *xs, UIFont *font, UIColor *color, CGSize size,
                         NSMutableArray<UILabel *> *made) {
    UIView *run = [[UIView alloc] initWithFrame:(CGRect){CGPointZero, size}];
    for (NSUInteger i = 0; i < letters.count; i++) {
        CGFloat x = xs[i].doubleValue, next = i + 1 < xs.count ? xs[i + 1].doubleValue : size.width;
        UILabel *label = wordLabel(letters[i], font, color, CGRectMake(x, 0, ceil(next - x) + 2, size.height), NO);
        [run addSubview:label];
        [made addObject:label];
    }
    return run;
}

- (instancetype)initWithWord:(SGKaraokeWord *)word font:(UIFont *)font rightToLeft:(BOOL)rightToLeft {
    CGSize size = [word.text sizeWithAttributes:@{NSFontAttributeName: font}];
    self = [super initWithFrame:CGRectMake(0, 0, ceil(size.width), ceil(font.lineHeight))];
    if (!self) return nil;
    _word = word;
    _riseStart = word.start;
    _riseEnd = word.end;
    _rightToLeft = rightToLeft;
    // Only a word held long enough to glow waves, and only one written left to right: a script that joins
    // its letters, as Arabic does, cannot be set a letter at a time.
    NSMutableArray<NSString *> *letters = [NSMutableArray array];
    NSMutableArray<NSNumber *> *xs = [NSMutableArray array];
    if (word.end - word.start >= kGlowFromMs && !rightToLeft && !UIAccessibilityIsReduceMotionEnabled()) {
        NSDictionary *attributes = @{NSFontAttributeName: font};
        [word.text enumerateSubstringsInRange:NSMakeRange(0, word.text.length) options:NSStringEnumerationByComposedCharacterSequences
                                   usingBlock:^(NSString *letter, NSRange range, NSRange enclosing, BOOL *stop) {
            [letters addObject:letter];
            [xs addObject:@([[word.text substringToIndex:range.location] sizeWithAttributes:attributes].width)];
        }];
    }
    if (letters.count > 1) {
        NSMutableArray<UILabel *> *dim = [NSMutableArray array], *lit = [NSMutableArray array];
        [self addSubview:lettersOf(letters, xs, font, [UIColor colorWithWhite:1 alpha:kDimAlpha], self.bounds.size, dim)];
        _lit = lettersOf(letters, xs, font, UIColor.whiteColor, self.bounds.size, lit);
        _dimLetters = dim;
        _litLetters = lit;
        _letterAt = calloc(letters.count, sizeof(CGFloat));
        _letterLift = calloc(letters.count, sizeof(CGFloat));
        for (NSUInteger i = 0; i < letters.count; i++) {
            CGFloat next = i + 1 < xs.count ? xs[i + 1].doubleValue : size.width;
            _letterAt[i] = (xs[i].doubleValue + next) / 2 / MAX(size.width, 1);
        }
        _waveHeight = font.pointSize * kWaveShare;
    } else {
        [self addSubview:wordLabel(word.text, font, [UIColor colorWithWhite:1 alpha:kDimAlpha], self.bounds, rightToLeft)];
        _lit = wordLabel(word.text, font, UIColor.whiteColor, self.bounds, rightToLeft);
    }
    // Hidden until the line is sung: a masked layer is drawn offscreen every frame even when the
    // mask leaves nothing of it, and a song has hundreds of words waiting their turn.
    _lit.hidden = YES;
    [self addSubview:_lit];

    CGFloat width = self.bounds.size.width + 2 * kGlowReach + kFillEdge;
    _fill = [CAGradientLayer layer];
    _fill.colors = @[(id)UIColor.whiteColor.CGColor, (id)UIColor.whiteColor.CGColor, (id)UIColor.clearColor.CGColor];
    _fill.locations = @[@0, @((width - kFillEdge) / width), @1];
    _fill.startPoint = CGPointMake(rightToLeft ? 1 : 0, 0.5);
    _fill.endPoint = CGPointMake(rightToLeft ? 0 : 1, 0.5);
    _lit.layer.mask = _fill;
    _filled = NAN;
    [self fillTo:-CGFLOAT_MAX];
    return self;
}

- (void)dealloc {
    free(_letterAt);
    free(_letterLift);
}

// The cursor is in line units and the feathered edge is centered on it, so the edge runs on through
// the space into the next word instead of starting over at each one. Right to left, the mask is the
// same one turned around: white from the word's right edge, the feather `local` in from it. The white
// runs kGlowReach past the word on each side, and the edge follows the cursor that far past it, so a
// word's glow is cut only where the sweep has not reached yet.
- (void)fillTo:(CGFloat)cursor {
    CGFloat width = self.bounds.size.width, height = self.bounds.size.height;
    CGFloat local = MAX(-kFillEdge / 2, MIN(width + kGlowReach + kFillEdge / 2, cursor - _offset));
    if (local == _filled) return;
    _filled = local;
    CGFloat lit = width + 2 * kGlowReach;
    CGFloat left = _rightToLeft ? width - local - kFillEdge / 2 : local - kFillEdge / 2 - lit;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _fill.frame = CGRectMake(left, -kGlowReach, lit + kFillEdge, height + 2 * kGlowReach);
    [CATransaction commit];
}

// Rises like a critically damped spring let go as the word starts: no jolt, a long soft landing.
// x = 5 at the end of the word is 96 % of the way up.
- (void)floatAt:(double)ms {
    double x = MAX(0, ms - _riseStart + kFloatLeadMs) / MAX(_riseEnd - _riseStart, kFloatMinMs) * 5;
    CGFloat lift = kLift * (1 - (1 + x) * exp(-x));
    [self glowAt:ms];
    [self waveAt:ms];
    if (lift == _lift) return;
    _lift = lift;
    self.transform = CGAffineTransformMakeTranslation(0, -lift);
}

// How strongly a held word glows and waves: from a quarter for the shortest that does, to all of it.
static double heldStrength(double held) {
    return MIN(1, (held - kGlowFromMs) / (kGlowFullMs - kGlowFromMs) + 0.25);
}

// A held word glows, the more the longer it is held: white light around the lit part of it, since the
// sweep's mask cuts the shadow too, kGlowReach out from the lit part. Most words are too short to glow,
// and theirs is never drawn.
- (void)glowAt:(double)ms {
    double held = _word.end - _word.start;
    CGFloat glow = 0;
    if (held >= kGlowFromMs && !_whole && sg_glowScale > 0) {
        double strength = heldStrength(held);
        double envelope = ms < _word.start ? 0
                        : ms <= _word.end ? (ms - _word.start) / held
                        : MAX(0, 1 - (ms - _word.end) / kGlowFadeMs);
        glow = round(strength * envelope * 50) / 50;   // steps of 2 %, so most frames change nothing
    }
    if (glow == _glow) return;
    _glow = glow;
    CALayer *layer = _lit.layer;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    layer.shadowColor = UIColor.whiteColor.CGColor;
    layer.shadowOffset = CGSizeZero;
    layer.shadowRadius = kGlowRadius * (0.5 + glow / 2) * (0.75 + sg_glowScale / 4);
    layer.shadowOpacity = MIN(1, kGlowOpacity * glow * sg_glowScale);
    [CATransaction commit];
}

// Each letter comes up on a smoothstep as the sweep nears it and stays up while the word is held, so a
// crest runs through the word with the sweep; once it is sung they all come down as the glow fades.
- (void)waveAt:(double)ms {
    if (!_litLetters || _whole) return;
    double held = _word.end - _word.start, along = (ms - _word.start) / held;
    double fade = ms <= _word.end ? 1 : MAX(0, 1 - (ms - _word.end) / kGlowFadeMs);
    CGFloat height = _waveHeight * heldStrength(held) * fade * sg_waveScale;
    for (NSUInteger i = 0; i < _litLetters.count; i++) {
        double p = MAX(0, MIN(1, (along - _letterAt[i] + kWaveLead) / kWaveSpan));
        CGFloat lift = round(height * p * p * (3 - 2 * p) * 4) / 4;   // quarter points, so most frames change nothing
        if (lift == _letterLift[i]) continue;
        _letterLift[i] = lift;
        CGAffineTransform up = CGAffineTransformMakeTranslation(0, -lift);
        _litLetters[i].transform = up;
        _dimLetters[i].transform = up;
    }
}

- (void)settle {
    [self land];
    [self unglow];
}

- (void)land {
    _lift = 0;
    self.transform = CGAffineTransformIdentity;
    for (NSUInteger i = 0; i < _litLetters.count; i++) {
        _letterLift[i] = 0;
        _litLetters[i].transform = CGAffineTransformIdentity;
        _dimLetters[i].transform = CGAffineTransformIdentity;
    }
}

- (void)unglow {
    _glow = 0;
    _lit.layer.shadowOpacity = 0;
}

@end

#pragma mark - how a line is set

// The second and third place's sizes, as shares of the first: Apple Music's 20 and 16 under its 30.
static const CGFloat kSecondShare = 0.67, kThirdShare = 0.54;

@implementation SGKaraokeStyle

- (instancetype)initWithSize:(CGFloat)size order:(NSArray<NSNumber *> *)order pronunciation:(BOOL)pronunciation translation:(BOOL)translation
                   romanised:(BOOL)romanised {
    if (!(self = [super init])) return nil;
    CGFloat sizes[3] = {size, round(size * kSecondShare), round(size * kThirdShare)};
    NSUInteger spoken = [order indexOfObject:@(SGKaraokeTextPronunciation)];
    if (romanised) _romanised = [UIFont systemFontOfSize:spoken > 0 && spoken < 3 ? sizes[spoken] : sizes[1] weight:UIFontWeightSemibold];
    NSMutableArray<NSNumber *> *shown = [NSMutableArray array];
    for (NSUInteger place = 0; place < order.count && place < 3; place++) {
        SGKaraokeText text = order[place].integerValue;
        if ((text == SGKaraokeTextPronunciation && !pronunciation) || (text == SGKaraokeTextTranslation && !translation)) continue;
        CGFloat points = shown.count ? sizes[place] : size;
        UIFont *font = [UIFont systemFontOfSize:points weight:text == SGKaraokeTextTranslation ? UIFontWeightSemibold : UIFontWeightBold];
        if (text == SGKaraokeTextLyrics) _lyrics = font;
        else if (text == SGKaraokeTextPronunciation) _pronunciation = font;
        else _translation = font;
        [shown addObject:@(text)];
    }
    if (!_lyrics) {   // an order without the lyrics in it is not one to trust
        _lyrics = [UIFont systemFontOfSize:size weight:UIFontWeightBold];
        [shown insertObject:@(SGKaraokeTextLyrics) atIndex:0];
    }
    _order = shown;
    return self;
}

- (SGKaraokeStyle *)backing {
    SGKaraokeStyle *backing = [SGKaraokeStyle new];
    backing->_lyrics = [UIFont systemFontOfSize:round(_lyrics.pointSize * kBackingScale) weight:UIFontWeightBold];
    if (_pronunciation) backing->_pronunciation = [UIFont systemFontOfSize:round(_pronunciation.pointSize * kBackingScale) weight:UIFontWeightBold];
    NSMutableArray<NSNumber *> *order = [_order mutableCopy];
    [order removeObject:@(SGKaraokeTextTranslation)];
    backing->_order = order;
    backing.japanese = _japanese;
    backing.romanisedReplace = _romanisedReplace;
    return backing;
}

@end

#pragma mark - where a line's words go

// Between a row of words and the row spelling them out under it, between one such pair and the next,
// and between two texts of a line set apart.
static const CGFloat kPairTighten = 2, kPairGap = 4, kPartGap = 6;

// Where everything of a line goes, from its text alone: each word's frame and its place along the
// sweep, the translation's frame and the backing's top. The page lays every line of a song out with
// it off the main thread to stack them, and a line view lays itself out by it when it is made, so the
// two can never disagree about a height.
@interface SGKaraokeLayout : NSObject
@property (nonatomic) BOOL right;
@property (nonatomic) CGFloat height;
@property (nonatomic, copy) NSArray<NSValue *> *lyricFrames, *spokenFrames;
@property (nonatomic, copy) NSArray<NSNumber *> *lyricOffsets, *spokenOffsets;
@property (nonatomic) CGRect translation;   // CGRectNull without one
@property (nonatomic) CGRect romanised;     // likewise
@property (nonatomic, copy) NSString *romanisedText;
@property (nonatomic) CGFloat backingTop;   // 0 without a backing row
@end

@implementation SGKaraokeLayout
@end

// A run of words set in rows as wide as the page: where each goes along its row, which row, and where
// it sits along the sweep, the rows laid end to end. A joined word follows the one before it flush:
// the scripts that do not space their words would otherwise read with a gap between every syllable.
typedef struct {
    CGFloat x, width, offset;
    NSUInteger row;
} SGKaraokePlace;

static NSUInteger flow(NSArray<SGKaraokeWord *> *words, UIFont *font, CGFloat width, SGKaraokePlace *places) {
    NSDictionary *attributes = @{NSFontAttributeName: font};
    CGFloat space = ceil([@" " sizeWithAttributes:attributes].width), x = 0, offset = 0;
    NSUInteger row = 0;
    for (NSUInteger i = 0; i < words.count; i++) {
        CGFloat wide = ceil([words[i].text sizeWithAttributes:attributes].width);
        CGFloat lead = x > 0 && !words[i].joined ? space : 0;
        if (x > 0 && x + lead + wide > width) {
            x = lead = 0;
            row++;
        }
        x += lead;
        offset += lead;
        places[i] = (SGKaraokePlace){x, wide, offset, row};
        x += wide;
        offset += wide;
    }
    return words.count ? row + 1 : 0;
}

// Written right to left, rows are laid out left to right and turned around, so the first word is at
// the right edge and each row runs leftwards from it. Then each group of rows goes against the line's
// edge, a second voice's against the far one, as Apple Music sets the two sides of a duet apart; a
// group too wide to fit stays where its first word put it.
static void settle(CGRect *frames, NSUInteger *groups, NSUInteger count, NSUInteger groupCount, CGFloat width, BOOL rightToLeft, BOOL right) {
    if (rightToLeft) {
        for (NSUInteger i = 0; i < count; i++) frames[i].origin.x = width - CGRectGetMaxX(frames[i]);
    }
    for (NSUInteger g = 0; g < groupCount; g++) {
        CGRect extent = CGRectNull;
        for (NSUInteger i = 0; i < count; i++) {
            if (groups[i] == g) extent = CGRectUnion(extent, frames[i]);
        }
        if (CGRectIsNull(extent)) continue;
        CGFloat shift = right ? width - CGRectGetMaxX(extent) : -CGRectGetMinX(extent);
        if (right ? shift <= 0 : shift >= 0) continue;
        for (NSUInteger i = 0; i < count; i++) {
            if (groups[i] == g) frames[i].origin.x += shift;
        }
    }
}

static NSArray<NSValue *> *boxedFrames(CGRect *frames, NSUInteger count) {
    NSMutableArray<NSValue *> *boxed = [NSMutableArray arrayWithCapacity:count];
    for (NSUInteger i = 0; i < count; i++) [boxed addObject:[NSValue valueWithCGRect:frames[i]]];
    return boxed;
}

static NSArray<NSNumber *> *offsetsOf(SGKaraokePlace *places, NSUInteger count) {
    NSMutableArray<NSNumber *> *offsets = [NSMutableArray arrayWithCapacity:count];
    for (NSUInteger i = 0; i < count; i++) [offsets addObject:@(places[i].offset)];
    return offsets;
}

// A text of words on its own, from `top`; returns where it ends.
static CGFloat layRun(NSArray<SGKaraokeWord *> *words, UIFont *font, CGFloat width, BOOL right, CGFloat top,
                      NSArray<NSValue *> **frames, NSArray<NSNumber *> **offsets) {
    NSUInteger count = words.count;
    SGKaraokePlace *places = calloc(count + 1, sizeof(SGKaraokePlace));
    CGRect *rects = calloc(count + 1, sizeof(CGRect));
    NSUInteger *groups = calloc(count + 1, sizeof(NSUInteger));
    NSUInteger rows = flow(words, font, width, places);
    CGFloat row = ceil(font.lineHeight) - kRowTighten, high = ceil(font.lineHeight);
    for (NSUInteger i = 0; i < count; i++) {
        rects[i] = CGRectMake(places[i].x, top + places[i].row * row, places[i].width, high);
        groups[i] = places[i].row;
    }
    NSMutableString *text = [NSMutableString string];
    for (SGKaraokeWord *word in words) [text appendString:word.text];
    settle(rects, groups, count, rows, width, SGKaraokeReadsRightToLeft(text), right);
    *frames = boxedFrames(rects, count);
    *offsets = offsetsOf(places, count);
    free(places);
    free(rects);
    free(groups);
    return top + (rows ? rows - 1 : 0) * row + high;
}

// Two texts of words where the second spells out the first, or the first the second: each row of the
// leading one with the other's words under it, each under the word it starts with, as Apple Music sets
// its pronunciation, so a syllable reads under the syllable it sounds. Returns where the pair ends.
static CGFloat layPair(NSArray<SGKaraokeWord *> *lead, UIFont *leadFont, NSArray<SGKaraokeWord *> *under, UIFont *underFont,
                       CGFloat width, BOOL right, CGFloat top, NSArray<NSValue *> **leadFrames, NSArray<NSNumber *> **leadOffsets,
                       NSArray<NSValue *> **underFrames, NSArray<NSNumber *> **underOffsets) {
    NSUInteger leads = lead.count, unders = under.count, count = leads + unders;
    SGKaraokePlace *places = calloc(count + 1, sizeof(SGKaraokePlace));
    CGRect *rects = calloc(count + 1, sizeof(CGRect));
    NSUInteger *groups = calloc(count + 1, sizeof(NSUInteger));
    NSUInteger rows = flow(lead, leadFont, width, places);
    flow(under, underFont, width, places + leads);   // for their places along their own sweep
    // The leading word each one goes under: the last to start by the time it does.
    NSUInteger *matched = calloc(unders + 1, sizeof(NSUInteger));
    for (NSUInteger j = 0, i = 0; j < unders; j++) {
        while (i + 1 < leads && lead[i + 1].start <= under[j].start) i++;
        matched[j] = i;
    }
    CGFloat leadRow = ceil(leadFont.lineHeight) - kRowTighten, leadHigh = ceil(leadFont.lineHeight);
    CGFloat underRow = ceil(underFont.lineHeight) - kRowTighten, underHigh = ceil(underFont.lineHeight);
    CGFloat space = ceil([@" " sizeWithAttributes:@{NSFontAttributeName: underFont}].width);
    CGFloat y = top, bottom = top;
    NSUInteger j = 0;
    for (NSUInteger r = 0; r < rows; r++) {
        for (NSUInteger i = 0; i < leads; i++) {
            if (places[i].row != r) continue;
            rects[i] = CGRectMake(places[i].x, y, places[i].width, leadHigh);
            groups[i] = r;
        }
        bottom = y + leadHigh;
        // Under the row, each word at the start of its own, pushed along past the one before it, and the
        // pieces of one word flush together, the way the row above has them. A row spelled out wider than
        // it is written, as Korean is, cannot keep to its words and still fit: it is set as plain words
        // from the edge instead, in as many rows as it takes.
        NSUInteger from = j, until = j;
        while (until < unders && places[matched[until]].row == r) until++;
        CGFloat underTop = y + leadHigh - kPairTighten, reached = 0;
        BOOL fits = YES;
        for (NSUInteger k = from; k < until && fits; k++) {
            BOOL flush = k > from && under[k].joined;
            CGFloat x = flush ? reached : MAX(places[matched[k]].x, reached + (reached > 0 ? space : 0));
            rects[leads + k] = CGRectMake(x, underTop, places[leads + k].width, underHigh);
            reached = x + places[leads + k].width;
            fits = reached <= width;
        }
        NSUInteger subRow = 0;
        if (!fits) {
            reached = 0;
            for (NSUInteger k = from; k < until; k++) {
                CGFloat wide = places[leads + k].width, lead = reached > 0 && !under[k].joined ? space : 0;
                if (reached > 0 && reached + lead + wide > width) {
                    subRow++;
                    reached = lead = 0;
                }
                rects[leads + k] = CGRectMake(reached + lead, underTop + subRow * underRow, wide, underHigh);
                reached += lead + wide;
            }
        }
        for (NSUInteger k = from; k < until; k++) groups[leads + k] = r;
        j = until;
        BOOL any = until > from;
        if (any) bottom = underTop + subRow * underRow + underHigh;
        y = any ? bottom + kPairGap : y + leadRow;
    }
    NSMutableString *text = [NSMutableString string];
    for (SGKaraokeWord *word in lead) [text appendString:word.text];
    settle(rects, groups, count, rows, width, SGKaraokeReadsRightToLeft(text), right);
    *leadFrames = boxedFrames(rects, leads);
    *underFrames = boxedFrames(rects + leads, unders);
    *leadOffsets = offsetsOf(places, leads);
    *underOffsets = offsetsOf(places + leads, unders);
    free(places);
    free(rects);
    free(groups);
    free(matched);
    return bottom;
}

// A text set as a block, wrapping as a label does, from `top`.
static CGRect blockFrame(NSString *text, UIFont *font, CGFloat width, CGFloat top) {
    CGRect bounds = [text boundingRectWithSize:CGSizeMake(width, CGFLOAT_MAX) options:NSStringDrawingUsesLineFragmentOrigin
                                    attributes:@{NSFontAttributeName: font} context:nil];
    return CGRectMake(0, top, width, ceil(bounds.size.height));
}

// The texts a line has, in the style's order, the lyrics and their pronunciation set as a pair where
// the order has them side by side, the line in Latin letters right under the lyrics where it is not
// already spelled out by the pronunciation, and the backing row after that. `right` is the side a backing
// row keeps to, its line's; -1 for a line of its own, which takes its side from its voice and script.
static SGKaraokeLayout *layOut(SGKaraokeLine *line, CGFloat width, SGKaraokeStyle *style, NSInteger right) {
    SGKaraokeLayout *layout = [SGKaraokeLayout new];
    SGKaraokeLine *activeLine = line;
    if (style.romanisedReplace) {
        SGKaraokeLine *romanised = SGLyricsRomanisedLine(line, style.japanese);
        if (romanised) activeLine = romanised;
    }
    layout.right = right >= 0 ? right : SGKaraokeAlignsRight(activeLine);
    layout.translation = layout.romanised = CGRectNull;
    NSArray<SGKaraokeWord *> *spoken = (style.pronunciation && !style.romanisedReplace) ? line.pronunciation.words : nil;
    NSString *translation = style.translation ? activeLine.translation : nil;
    // A translator hands back a line already in the language as it was; the line says it once. It stays
    // translated, so it is not asked again.
    NSString *lineText = translation.length || (style.romanised && !style.romanisedReplace) ? SGKaraokeLineText(line) : nil;
    if (translation.length && [SGLyricsBareText(translation) isEqualToString:SGLyricsBareText(lineText)]) translation = nil;
    // A source's own pronunciation, hidden, still reads better than the transform's.
    if (style.romanised && !style.romanisedReplace && !spoken.count) {
        layout.romanisedText = line.pronunciation ? SGKaraokeLineText(line.pronunciation)
                                                  : SGLyricsRomanised(lineText, style.japanese);
    }
    NSMutableArray<NSNumber *> *parts = [NSMutableArray array];
    for (NSNumber *text in style.order) {
        if (text.integerValue == SGKaraokeTextPronunciation && (!spoken.count || style.romanisedReplace)) continue;
        if (text.integerValue == SGKaraokeTextTranslation && !translation.length) continue;
        [parts addObject:text];
    }
    NSArray<NSValue *> *frames;
    NSArray<NSNumber *> *offsets;
    CGFloat y = 0;
    for (NSUInteger p = 0; p < parts.count; p++) {
        SGKaraokeText text = parts[p].integerValue;
        if (p > 0) y += kPartGap;
        if (text == SGKaraokeTextTranslation) {
            layout.translation = blockFrame(translation, style.translation, width, y);
            y = CGRectGetMaxY(layout.translation);
            continue;
        }
        BOOL lyrics = text == SGKaraokeTextLyrics;
        BOOL paired = p + 1 < parts.count && parts[p + 1].integerValue != SGKaraokeTextTranslation;
        if (paired) {
            NSArray<NSValue *> *pairedFrames;
            NSArray<NSNumber *> *pairedOffsets;
            y = layPair(lyrics ? activeLine.words : spoken, lyrics ? style.lyrics : style.pronunciation,
                        lyrics ? spoken : activeLine.words, lyrics ? style.pronunciation : style.lyrics,
                        width, layout.right, y, &frames, &offsets, &pairedFrames, &pairedOffsets);
            layout.lyricFrames = lyrics ? frames : pairedFrames;
            layout.lyricOffsets = lyrics ? offsets : pairedOffsets;
            layout.spokenFrames = lyrics ? pairedFrames : frames;
            layout.spokenOffsets = lyrics ? pairedOffsets : offsets;
            p++;
            lyrics = YES;
        } else {
            y = layRun(lyrics ? activeLine.words : spoken, lyrics ? style.lyrics : style.pronunciation, width, layout.right, y, &frames, &offsets);
            if (lyrics) {
                layout.lyricFrames = frames;
                layout.lyricOffsets = offsets;
            } else {
                layout.spokenFrames = frames;
                layout.spokenOffsets = offsets;
            }
        }
        if (lyrics && layout.romanisedText.length) {
            layout.romanised = blockFrame(layout.romanisedText, style.romanised, width, y + kPartGap);
            y = CGRectGetMaxY(layout.romanised);
        }
        if (lyrics && right < 0 && activeLine.backing.words.count) {
            layout.backingTop = y + kBackingGap;
            y = layout.backingTop + layOut(activeLine.backing, width, style.backing, layout.right).height;
        }
    }
    layout.height = y;
    return layout;
}

// Where each line starts in the stack, from the heights alone. Measuring text is safe off the main
// thread, and a song's worth of it is kept off it: the first card of a track lays out while the
// player is opening, and a frame that measured every line then was a frame the animation lost.
// Where each line starts in the stack, and one more: where the stack ends, which the credit follows.
NSArray<NSNumber *> *SGKaraokeLineTops(NSArray<SGKaraokeLine *> *lines, CGFloat width, SGKaraokeStyle *style, CGFloat gap) {
    NSMutableArray<NSNumber *> *tops = [NSMutableArray arrayWithCapacity:lines.count + 1];
    CGFloat top = 0;
    for (SGKaraokeLine *line in lines) {
        [tops addObject:@(top)];
        top += layOut(line, width, style, -1).height + gap;
    }
    [tops addObject:@(top)];
    return tops;
}

#pragma mark - a sweep

typedef struct {
    double ms, x, slope;
} SGSweepKnot;

// One run of words lit by one sweep: a line's own, or its pronunciation's, each timed by its own words.
// A whole one lights every word of the run at once from `start`, for a run whose words are not timed.
@interface SGKaraokeSweep : NSObject
@property (nonatomic, readonly) NSArray<SGKaraokeWordView *> *words;
- (instancetype)initWithWords:(NSArray<SGKaraokeWordView *> *)words wholeFrom:(double)start;
- (void)showTime:(double)ms;
@end

@implementation SGKaraokeSweep {
    SGSweepKnot *_knots;
    NSUInteger _knotCount;
    BOOL _whole;
}

// start: NAN to sweep the words by their own times.
- (instancetype)initWithWords:(NSArray<SGKaraokeWordView *> *)words wholeFrom:(double)start {
    if (!(self = [super init])) return nil;
    _words = words;
    _whole = !isnan(start);
    if (_whole) {
        for (SGKaraokeWordView *word in words) {
            word.whole = YES;
            word.riseStart = start;
            word.riseEnd = start + kWholeRiseMs;
        }
        return self;
    }
    [self buildSweep];
    return self;
}

- (void)dealloc {
    free(_knots);
}

static double secant(SGSweepKnot *knots, NSUInteger i) {
    return (knots[i + 1].x - knots[i].x) / (knots[i + 1].ms - knots[i].ms);
}

// The fill cursor reaches each word's left edge as the word starts and clears the last word as it
// ends, on a monotone cubic through those points, so the pace changes between words without a kink.
- (void)buildSweep {
    _knots = calloc(_words.count + 1, sizeof(SGSweepKnot));
    if (!_words.count) return;
    for (NSUInteger i = 0; i <= _words.count; i++) {
        SGKaraokeWordView *word = _words[MIN(i, _words.count - 1)];
        double ms = i < _words.count ? word.word.start : word.word.end;
        double x = i == 0 ? -kFillEdge / 2 : i < _words.count ? word.offset : word.offset + word.bounds.size.width + kFillEdge / 2;
        if (_knotCount && ms <= _knots[_knotCount - 1].ms) {
            _knots[_knotCount - 1].x = x;
            continue;
        }
        _knots[_knotCount++] = (SGSweepKnot){ms, x, 0};
    }
    // Fritsch-Carlson slopes: capped so the cursor never runs backwards or overshoots a word.
    for (NSUInteger k = 0; k < _knotCount; k++) {
        BOOL first = k == 0, last = k + 1 == _knotCount;
        if (first && last) break;
        if (first || last) {
            _knots[k].slope = secant(_knots, first ? 0 : k - 1);
            continue;
        }
        double before = secant(_knots, k - 1), after = secant(_knots, k);
        double h0 = _knots[k].ms - _knots[k - 1].ms, h1 = _knots[k + 1].ms - _knots[k].ms;
        _knots[k].slope = MIN(MIN(2 * before, 2 * after), (before * h1 + after * h0) / (h0 + h1));
    }
}

- (CGFloat)cursorAt:(double)ms {
    if (!_knotCount) return -CGFLOAT_MAX;
    if (ms <= _knots[0].ms) return _knots[0].x;
    if (_knotCount == 1 || ms >= _knots[_knotCount - 1].ms) return _knots[_knotCount - 1].x;
    NSUInteger k = 0;
    while (ms >= _knots[k + 1].ms) k++;
    SGSweepKnot a = _knots[k], b = _knots[k + 1];
    double h = b.ms - a.ms, u = (ms - a.ms) / h, u2 = u * u, u3 = u2 * u;
    return (2 * u3 - 3 * u2 + 1) * a.x + (u3 - 2 * u2 + u) * h * a.slope
         + (3 * u2 - 2 * u3) * b.x + (u3 - u2) * h * b.slope;
}

- (void)showTime:(double)ms {
    // A whole run is only ever shown while its line is sung, so it is lit throughout.
    CGFloat cursor = _whole ? CGFLOAT_MAX : [self cursorAt:ms];
    for (SGKaraokeWordView *word in _words) {
        [word fillTo:cursor];
        [word floatAt:ms];
    }
}

@end

#pragma mark - a line

// The translation and the romanized line of a line being sung, brighter than a line waiting but never
// as bright as the words.
static const CGFloat kTranslationLit = 0.6;

@implementation SGKaraokeLineView {
    NSArray<SGKaraokeSweep *> *_sweeps;   // the line's words, then their pronunciation's where shown
    NSArray<SGKaraokeWordView *> *_words;   // every word of both
    UILabel *_translation, *_romanised;
    NSUInteger _generation;
    SGKaraokeLineView *_backing;
}

// A sweep's word views, each put where the layout has it and told where it sits along the sweep.
// start: NAN for words timed one by one, else when the run lights up whole.
- (SGKaraokeSweep *)sweepOf:(NSArray<SGKaraokeWord *> *)words font:(UIFont *)font frames:(NSArray<NSValue *> *)frames
                     offsets:(NSArray<NSNumber *> *)offsets wholeFrom:(double)start {
    if (!words.count || frames.count != words.count) return nil;
    BOOL rightToLeft = SGKaraokeReadsRightToLeft([[words valueForKey:@"text"] componentsJoinedByString:@""]);
    NSMutableArray<SGKaraokeWordView *> *views = [NSMutableArray arrayWithCapacity:words.count];
    for (NSUInteger i = 0; i < words.count; i++) {
        SGKaraokeWordView *view = [[SGKaraokeWordView alloc] initWithWord:words[i] font:font rightToLeft:rightToLeft];
        CGRect frame = frames[i].CGRectValue;
        view.center = CGPointMake(CGRectGetMidX(frame), CGRectGetMidY(frame));
        view.offset = offsets[i].doubleValue;
        [self addSubview:view];
        [views addObject:view];
    }
    return [[SGKaraokeSweep alloc] initWithWords:views wholeFrom:start];
}

// When a run of the line lights up whole, or NAN to sweep it: only words the source timed are swept,
// unless the estimate is asked for.
static double wholeFrom(SGKaraokeLine *run, BOOL sweepsEstimates) {
    if (run.timing == SGKaraokeTimingWords || (run.timing == SGKaraokeTimingLine && sweepsEstimates)) return NAN;
    return run.start;
}

- (instancetype)initWithLine:(SGKaraokeLine *)line width:(CGFloat)width style:(SGKaraokeStyle *)style under:(SGKaraokeLineView *)under
                     blurred:(BOOL)blurred sweepsEstimates:(BOOL)sweepsEstimates {
    self = [super initWithFrame:CGRectZero];
    if (!self) return nil;
    _line = line;
    BOOL backing = under != nil;
    SGKaraokeLine *activeLine = line;
    if (style.romanisedReplace) {
        SGKaraokeLine *romanised = SGLyricsRomanisedLine(line, style.japanese);
        if (romanised) activeLine = romanised;
    }
    self.isAccessibilityElement = under == nil;
    self.accessibilityLabel = SGKaraokeLineText(activeLine);
    self.accessibilityTraits = UIAccessibilityTraitButton;
    SGKaraokeLayout *layout = layOut(line, width, style, backing ? under.right : -1);
    _right = layout.right;
    NSMutableArray<SGKaraokeSweep *> *sweeps = [NSMutableArray array];
    SGKaraokeSweep *sung = [self sweepOf:activeLine.words font:style.lyrics frames:layout.lyricFrames offsets:layout.lyricOffsets
                                wholeFrom:wholeFrom(activeLine, sweepsEstimates)];
    SGKaraokeSweep *spoken = style.romanisedReplace ? nil : [self sweepOf:line.pronunciation.words font:style.pronunciation frames:layout.spokenFrames
                                    offsets:layout.spokenOffsets wholeFrom:wholeFrom(line.pronunciation, sweepsEstimates)];
    if (sung) [sweeps addObject:sung];
    if (spoken) [sweeps addObject:spoken];
    _sweeps = sweeps;
    _words = [sung.words ?: @[] arrayByAddingObjectsFromArray:spoken.words ?: @[]];
    _lyricWords = sung.words;

    if (!CGRectIsNull(layout.translation)) _translation = [self asideAt:layout.translation font:style.translation text:activeLine.translation];
    if (!CGRectIsNull(layout.romanised)) _romanised = [self asideAt:layout.romanised font:style.romanised text:layout.romanisedText];
    if (layout.backingTop > 0) {
        _backing = [[SGKaraokeLineView alloc] initWithLine:activeLine.backing ?: line.backing width:width style:style.backing under:self blurred:NO
                                            sweepsEstimates:sweepsEstimates];
        _backing.alpha = kBackingAlpha;
        _backing.frame = CGRectMake(0, layout.backingTop, width, _backing.bounds.size.height);
        [self addSubview:_backing];
    }
    NSMutableArray<NSString *> *asides = [NSMutableArray array];
    if (_translation.text.length) [asides addObject:_translation.text];
    if (_romanised.text.length) [asides addObject:_romanised.text];
    if (layout.spokenFrames.count && line.pronunciation && !style.romanisedReplace) [asides addObject:SGKaraokeLineText(line.pronunciation) ?: @""];
    if (activeLine.backing) [asides addObject:SGKaraokeLineText(activeLine.backing) ?: @""];
    self.accessibilityValue = [asides componentsJoinedByString:@". "];
    for (UIView *child in self.subviews) child.accessibilityElementsHidden = YES;
    self.frame = CGRectMake(0, 0, width, layout.height);

    // Scales toward the edge its text is aligned to, and a backing row rides its line's blur.
    if (backing) return self;
    self.layer.anchorPoint = CGPointMake(_right ? 1 : 0, 0.5);
    if (!blurred) return self;
    CAFilter *blur = [NSClassFromString(@"CAFilter") filterWithType:@"gaussianBlur"];
    if (blur) self.layer.filters = @[blur];
    return self;
}

- (BOOL)accessibilityActivate {
    return self.activate ? self.activate() : NO;
}

// A text of the line set apart from its words, dim until the line is sung.
- (UILabel *)asideAt:(CGRect)frame font:(UIFont *)font text:(NSString *)text {
    UILabel *label = [[UILabel alloc] initWithFrame:frame];
    label.numberOfLines = 0;
    label.font = font;
    label.textColor = UIColor.whiteColor;
    label.alpha = kDimAlpha;
    label.textAlignment = _right ? NSTextAlignmentRight : NSTextAlignmentLeft;
    label.text = text;
    [self addSubview:label];
    return label;
}

// Eases from wherever the blur is on screen, so a line coming into focus sharpens instead of snapping.
- (void)setBlur:(CGFloat)blur {
    if (blur == _blur) return;
    id shown = [self.layer.presentationLayer valueForKeyPath:kBlurPath];
    CGFloat from = [shown isKindOfClass:NSNumber.class] ? [shown doubleValue] : _blur;
    _blur = blur;
    if (!self.layer.filters) return;
    [self.layer setValue:@(blur) forKeyPath:kBlurPath];
    CABasicAnimation *ease = [CABasicAnimation animationWithKeyPath:kBlurPath];
    ease.fromValue = @(from);
    ease.toValue = @(blur);
    ease.duration = 0.6;
    ease.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    [self.layer addAnimation:ease forKey:@"blur"];
}

- (void)setActive:(BOOL)active {
    if (active == _active) return;
    _active = active;
    self.accessibilityTraits = (self.accessibilityTraits & ~UIAccessibilityTraitSelected) | (active ? UIAccessibilityTraitSelected : 0);
    _backing.active = active;
    NSUInteger generation = ++_generation;
    if (_translation || _romanised) {
        [UIView animateWithDuration:active ? 0.3 : 0.5 delay:0 options:UIViewAnimationOptionBeginFromCurrentState animations:^{
            self->_translation.alpha = self->_romanised.alpha = active ? kTranslationLit : kDimAlpha;
        } completion:nil];
    }
    if (active) {
        NSMutableArray<SGKaraokeWordView *> *whole = [NSMutableArray array];
        for (SGKaraokeWordView *word in _words) {
            [word.layer removeAllAnimations];
            [word.lit.layer removeAllAnimations];
            word.lit.alpha = 1;
            word.lit.hidden = NO;
            [word fillTo:word.whole ? CGFLOAT_MAX : -CGFLOAT_MAX];
            [word settle];
            if (word.whole) [whole addObject:word];
        }
        // A line lit whole comes up to white together rather than popping on, as Apple Music's do.
        if (!whole.count) return;
        for (SGKaraokeWordView *word in whole) word.lit.alpha = 0;
        [UIView animateWithDuration:kWholeFade delay:0 options:UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionAllowUserInteraction
                         animations:^{ for (SGKaraokeWordView *word in whole) word.lit.alpha = 1; } completion:nil];
        return;
    }
    // A sung line fades back to dim rather than dropping its fill at once, and its words sink back
    // on a spring slow enough to still be seen doing it. A held word's glow is left on: the spring would
    // drop it in the first frame, and the lit word fading out takes it out with it.
    [UIView animateWithDuration:0.9 delay:0 usingSpringWithDamping:1 initialSpringVelocity:0
                        options:UIViewAnimationOptionAllowUserInteraction
                     animations:^{
        for (SGKaraokeWordView *word in self->_words) [word land];
    } completion:nil];
    [UIView animateWithDuration:0.5 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
        for (SGKaraokeWordView *word in self->_words) word.lit.alpha = 0;
    } completion:^(BOOL finished) {
        if (generation != self->_generation) return;
        for (SGKaraokeWordView *word in self->_words) {
            [word fillTo:-CGFLOAT_MAX];
            [word unglow];
            word.lit.hidden = YES;
            word.lit.alpha = 1;
        }
    }];
}

- (void)showTime:(double)ms {
    for (SGKaraokeSweep *sweep in _sweeps) [sweep showTime:ms];
    [_backing showTime:ms];   // timed on its own, so it lags the line as it is sung
}

- (void)showPlain {
    self.accessibilityTraits = UIAccessibilityTraitStaticText;
    for (SGKaraokeWordView *word in _words) {
        word.lit.hidden = NO;
        word.lit.alpha = 1;
        [word fillTo:CGFLOAT_MAX];
    }
    _translation.alpha = _romanised.alpha = kTranslationLit;
    [_backing showPlain];
}

@end

#pragma mark - a break

// Apple Music's hop: as its turn begins each dot rises about 0.8 of its own width, holds at the top,
// drops back with a small undershoot and settles. One hop of the same length per dot, whatever the break's.
static const double kHopLift = 0.8;     // of a dot's width
static const double kHopUnder = 0.12;   // of a dot's width below rest, where the drop lands before it settles
static const CFTimeInterval kHopLength = 0.9;   // seconds; a break is 7 s or more, so it fits in a dot's third

// Local time on the dots' clock is this far into the break plus this, so no animation begins at 0,
// which Core Animation reads as "now".
static const CFTimeInterval kBreakEpoch = 1;

// The rate the page's display link asks for, asked for here too: an animation that settles for less
// could hold the player's own 120 Hz animations down, as a link asking for 60 once did.
static void atFullRate(CAAnimation *animation) {
    animation.preferredFrameRateRange = CAFrameRateRangeMake(80, 120, 120);
}

static double easeOutExpo(double p) {
    return p <= 0 ? 0 : p >= 1 ? 1 : 1 - pow(2, -10 * p);
}

static double smoothstep(double p) {
    p = MAX(0, MIN(1, p));
    return p * p * (3 - 2 * p);
}

@implementation SGKaraokeBreakView {
    CALayer *_clock, *_group;
    NSArray<CALayer *> *_dots;
    NSInteger _start;
    CGFloat _side, _gap;
}

- (instancetype)initWithFont:(UIFont *)font {
    self = [super initWithFrame:CGRectMake(0, 0, 0, ceil(font.lineHeight))];
    if (!self) return nil;
    self.userInteractionEnabled = NO;
    _side = round(font.pointSize * kDotShare);
    _gap = round(font.pointSize * kDotGapShare);
    _clock = [CALayer layer];
    _group = [CALayer layer];
    _group.bounds = CGRectMake(0, 0, 3 * _side + 2 * _gap, _side);
    NSMutableArray<CALayer *> *dots = [NSMutableArray array];
    for (NSUInteger i = 0; i < 3; i++) {
        CALayer *dot = [CALayer layer];
        dot.frame = CGRectMake(i * (_side + _gap), 0, _side, _side);
        dot.cornerRadius = _side / 2;
        dot.backgroundColor = UIColor.whiteColor.CGColor;
        dot.opacity = kDimAlpha;
        [_group addSublayer:dot];
        [dots addObject:dot];
    }
    _dots = dots;
    _group.opacity = 0;
    [_clock addSublayer:_group];
    [self.layer addSublayer:_clock];
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    CGSize size = self.bounds.size, group = _group.bounds.size;
    _clock.frame = self.bounds;
    _group.position = CGPointMake(_right ? size.width - group.width / 2 : group.width / 2, size.height / 2);
    [CATransaction commit];
}

- (void)setRight:(BOOL)right {
    if (right == _right) return;
    _right = right;
    [self setNeedsLayout];
}

// The break's whole run, sampled the way the numbers above describe it: densely where the dots come
// and go, every fifth of a second through the slow breath between.
- (void)playFrom:(NSInteger)start to:(NSInteger)end {
    _start = start;
    [_group removeAllAnimations];
    for (CALayer *dot in _dots) [dot removeAllAnimations];
    double length = (end - start) / 1000.0;
    double exitAt = MAX(kBreakWait + kBreakIn, length - SGKaraokeBreakCollapse - kBreakOut), over = exitAt + kBreakOut;
    BOOL still = UIAccessibilityIsReduceMotionEnabled();   // no breath and no swell, only the fades and the fill
    NSMutableArray<NSNumber *> *times = [NSMutableArray array], *scales = [NSMutableArray array], *alphas = [NSMutableArray array];
    void (^sample)(double) = ^(double t) {
        double cycle = 2 * kBreathHalf, phase = fmod(t + kBreathHalf - fmod(exitAt, cycle) + cycle, cycle);
        double low = (1 - cos(M_PI * phase / kBreathHalf)) / 2;
        double scale = (kBreathHigh + (kBreathLow - kBreathHigh) * low) * easeOutExpo((t - kBreakWait) / kBreakIn);
        double alpha = MAX(0, MIN(1, (t - kBreakWait) / kBreakFadeIn));
        if (t >= exitAt) {
            double p = (t - exitAt) / kBreakOut;
            BOOL swelling = p <= kBreakSwellShare;
            double eased = smoothstep(swelling ? p / kBreakSwellShare : (p - kBreakSwellShare) / (1 - kBreakSwellShare));
            scale = swelling ? kBreathLow + (kBreakSwell - kBreathLow) * eased : kBreakSwell * (1 - eased);
            alpha = swelling ? 1 : 1 - eased;
        }
        [times addObject:@(t / over)];
        [scales addObject:@(still ? 1 : MAX(scale, 0.001))];
        [alphas addObject:@(alpha)];
    };
    for (double t = 0; t < kBreakWait + kBreakIn; t += 0.025) sample(t);
    for (double t = kBreakWait + kBreakIn; t < exitAt; t += 0.2) sample(t);
    for (double t = exitAt; t < over; t += 0.02) sample(t);
    sample(over);

    CAKeyframeAnimation *scale = [CAKeyframeAnimation animationWithKeyPath:@"transform.scale"];
    CAKeyframeAnimation *alpha = [CAKeyframeAnimation animationWithKeyPath:@"opacity"];
    scale.values = scales;
    alpha.values = alphas;
    for (CAKeyframeAnimation *run in @[scale, alpha]) {
        run.keyTimes = times;
        run.duration = over;
        run.beginTime = kBreakEpoch;
        run.fillMode = kCAFillModeBoth;
        run.removedOnCompletion = NO;
        atFullRate(run);
        [_group addAnimation:run forKey:run.keyPath];
    }

    double slot = exitAt / 3;
    CAMediaTimingFunction *rise = [CAMediaTimingFunction functionWithControlPoints:0.3 :0 :0.2 :1];
    CAMediaTimingFunction *drop = [CAMediaTimingFunction functionWithControlPoints:0.4 :0 :1 :1];
    CAMediaTimingFunction *settle = [CAMediaTimingFunction functionWithControlPoints:0 :0 :0.3 :1];
    for (NSUInteger i = 0; i < _dots.count; i++) {
        CALayer *dot = _dots[i];
        NSUInteger turn = _rightToLeft ? _dots.count - 1 - i : i;
        CFTimeInterval begin = kBreakEpoch + turn * slot;

        // Each dot fills over its third of the time before they go, in the order the next line reads.
        CABasicAnimation *fill = [CABasicAnimation animationWithKeyPath:@"opacity"];
        fill.fromValue = @(kDimAlpha);
        fill.toValue = @1;
        fill.beginTime = begin;
        fill.duration = slot;
        fill.fillMode = kCAFillModeBoth;
        fill.removedOnCompletion = NO;
        atFullRate(fill);
        [dot addAnimation:fill forKey:@"fill"];

        if (still) continue;   // Reduce Motion keeps the fill and drops the hop

        CGFloat lift = -kHopLift * _side;   // y grows downward, so up is negative
        CAKeyframeAnimation *hop = [CAKeyframeAnimation animationWithKeyPath:@"transform.translation.y"];
        hop.values = @[@0, @(lift), @(lift), @(kHopUnder * _side), @0];
        hop.keyTimes = @[@0, @0.42, @0.54, @0.87, @1];
        hop.timingFunctions = @[rise, [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionLinear], drop, settle];
        hop.beginTime = begin + (turn == 0 ? kBreakWait + kBreakFadeIn : 0);   // the first hops once the dots are in
        hop.duration = kHopLength;
        hop.fillMode = kCAFillModeBoth;
        hop.removedOnCompletion = NO;
        atFullRate(hop);
        [dot addAnimation:hop forKey:@"hop"];
    }
}

- (void)showTime:(double)ms running:(BOOL)running at:(CFTimeInterval)shown {
    double local = kBreakEpoch + (ms - _start) / 1000.0;
    CFTimeInterval parent = [self.layer convertTime:shown fromLayer:nil];
    BOOL stopped = _clock.speed == 0;
    double now = stopped ? _clock.timeOffset : (parent - _clock.beginTime) * _clock.speed + _clock.timeOffset;
    if (stopped != running && fabs(now - local) < kBreakSlack) return;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    if (running) {
        _clock.speed = 1;
        _clock.timeOffset = 0;
        _clock.beginTime = parent - local;
    } else {
        _clock.speed = 0;
        _clock.beginTime = 0;
        _clock.timeOffset = local;
    }
    [CATransaction commit];
}

@end
