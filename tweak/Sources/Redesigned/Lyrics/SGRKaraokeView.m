// The redesign's Apple Music style lyrics, always on: the line being sung lights up word by word, the
// rest dim and blur with distance. Lines two voices sing at once are lit together, an instrumental
// break holds three dots, and a line can show its pronunciation and its translation under it. The
// lines and the clock are Shared/Lyrics/Lyrics.h's.
//
// Only words the source timed are swept. A line timed by the line lights up whole as it starts, as
// Apple Music lights such a line, unless the Lyrics page's "Simulate word-by-word timing" asks for
// its estimated words to be swept; lyrics with no timing at all are shown as plain text, every line
// lit, nothing following the clock.
#import <NaturalLanguage/NaturalLanguage.h>
#import "Core/SGCore.h"
#import "SGRKaraokeView.h"
#import "LyricsText.h"
#import "LyricsLook.h"
#import "MeaningSheet.h"
#import "SGRSingButton.h"
#import "Shared/Sing/Sing.h"
#import "Shared/LyricsSources/LyricsSources.h"
#import "Shared/LyricsTranslation/LyricsTranslation.h"
#import "Settings/SGPageStyle.h"
#import "Shared/Player/PlayerEvents.h"
#import "Shared/Player/PlayerState.h"
#import "Shared/Haptics/Haptics.h"
#import "Redesigned/Kit/SGRGlass.h"
#import "Redesigned/Kit/SGRTokens.h"
#import "Shared/Lyrics/KaraokeLines.h"

// The size of the words and the room between lines are the Lyrics page's (LyricsLook.h); the column's margins, anchor,
// fade and blur are Shared/Lyrics/KaraokeLines.h's, which draws the lines.
// The mark of a line Genius explains: a bubble after it for the artist's own word, a dotted underline
// for anyone else's.
static const CGFloat kBubbleSide = 22, kBubbleGap = 8, kBubbleGlyph = 11, kBubbleAlpha = 0.75, kBubbleReach = 14;
static const CGFloat kUnderlineDrop = 1, kUnderlineWidth = 2, kUnderlineAlpha = 0.35;
// The line naming the source, under the lyrics, which fade out above it and the buttons beside it. It
// wraps onto a second line rather than run under the buttons beside it, and a tap this far around it
// opens the pages it links to.
static const CGFloat kCreditSize = 12, kCreditGap = 12, kCreditSlop = 8;
// The button for the pronunciation and the translation, in the bottom leading corner as Apple Music
// has it, and the gap between it and the credit beside it. The translate glyph is half again as wide as the
// mic's across from it, so it is drawn smaller to weigh the same: 14 pt is about the mic's 17 pt in area.
static const CGFloat kExtrasSide = 44, kExtrasBottom = 12, kExtrasGlyph = 14;
static char kExtrasGlassKey;
static const NSTimeInterval kRestyleFade = 0.3;   // the lines crossfading to a new style
static const NSTimeInterval kBrowseHold = 3;   // after scrolling by hand, how long until it follows the song again
static const double kClockSnapMs = 250, kClockPull = 0.08;
// After a tap seeks to a line, the clock holds at it until the player reports a position this near it,
// or for this long at the most: the player takes a few frames to report a seek.
static const double kSeekNearMs = 500;
static const CFTimeInterval kSeekWait = 1.5;
// Lines get views this far outside the visible part, in screen heights: half a screen above it
// and below, and a quarter more before a view is let go. Every view held is one more for the window
// to take in and let go when the lyrics come up; a line comes into view about once in three seconds,
// and a page flung by hand fills in at a few lines a frame.
static const CGFloat kSightBehind = 0.5, kSightAhead = 0.5, kSightSlack = 0.25;
static const NSTimeInterval kTransitionSlack = 0.05;   // after the player's animation, before the link is back
// Two voices can sing at once, rarely more; past this many, the latest ones wait their turn.
enum { kMostSung = 6 };
// A position that has not moved for this long is a paused player, not two frames between readings.
static const CFTimeInterval kStillFor = 0.1;
// How long after the last thing set moving the page's link drops its rate: past the longest placement
// (0.3 s of delay and a 0.7 s spring) and a sung line's 0.9 s sink.
static const CFTimeInterval kCalmAfter = 1.5;

// How many line views are made in one frame: the rest follow on the next, nearest the sung line first.
static const NSUInteger kLinesPerFrame = 4;

#pragma mark - a line's meaning

// The mark of a line Genius explains on the line's view (Shared/Lyrics/KaraokeLines.h), which knows nothing of
// Genius: a bubble after it, or a dotted underline, kept on the view.
@interface SGKaraokeLineView (SGRMeaning)
- (void)markMeaning:(NSArray<SGLyricsMeaning *> *)meanings;
// Where the bubble can be tapped, in the line's own space; CGRectNull without one.
@property (nonatomic, readonly) CGRect bubbleTarget;
@end

static char kBubbleKey, kUnderlineKey;

@implementation SGKaraokeLineView (SGRMeaning)

- (CGRect)bubbleTarget {
    UIView *bubble = objc_getAssociatedObject(self, &kBubbleKey);
    return bubble ? CGRectInset(bubble.frame, -kBubbleReach, -kBubbleReach) : CGRectNull;
}

- (void)markMeaning:(NSArray<SGLyricsMeaning *> *)meanings {
    NSString *text = SGKaraokeLineText(self.line);
    self.accessibilityCustomActions = meanings.count ? @[[[UIAccessibilityCustomAction alloc]
        initWithName:@"Show Meaning" actionHandler:^BOOL(UIAccessibilityCustomAction *action) {
            SGRShowMeanings(text, meanings);
            return YES;
        }]] : nil;
    [(UIView *)objc_getAssociatedObject(self, &kBubbleKey) removeFromSuperview];
    [(CALayer *)objc_getAssociatedObject(self, &kUnderlineKey) removeFromSuperlayer];
    objc_setAssociatedObject(self, &kBubbleKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, &kUnderlineKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSArray<UIView *> *lyricWords = self.lyricWords;
    if (!meanings.count || !lyricWords.count) return;
    if (meanings.firstObject.author == SGLyricsMeaningByArtist) {
        // Beside the line's last row, on the side that faces into the page: after it for a line against the left
        // edge, before it, the quote mirrored, for one against the right (a second voice, or right to left), whose
        // far end is the screen's edge.
        UIView *last = lyricWords.lastObject;
        CGFloat rowLeft = CGFLOAT_MAX, rowRight = -CGFLOAT_MAX;
        for (UIView *word in lyricWords) {
            if (fabs(word.center.y - last.center.y) > 1) continue;
            rowLeft = MIN(rowLeft, word.center.x - word.bounds.size.width / 2);
            rowRight = MAX(rowRight, word.center.x + word.bounds.size.width / 2);
        }
        BOOL before = SGKaraokeAlignsRight(self.line);
        CGFloat x = before ? rowLeft - kBubbleGap - kBubbleSide : rowRight + kBubbleGap;
        UIImage *glyph = [UIImage systemImageNamed:@"quote.opening" withConfiguration:
                          [UIImageSymbolConfiguration configurationWithPointSize:kBubbleGlyph weight:UIImageSymbolWeightBold]];
        if (before) glyph = glyph.imageWithHorizontallyFlippedOrientation;
        UIImageView *bubble = [[UIImageView alloc] initWithImage:glyph];
        bubble.contentMode = UIViewContentModeCenter;
        bubble.tintColor = UIColor.blackColor;
        bubble.backgroundColor = UIColor.whiteColor;
        bubble.layer.cornerRadius = kBubbleSide / 2;
        bubble.alpha = kBubbleAlpha;
        bubble.frame = CGRectMake(x, last.center.y - kBubbleSide / 2, kBubbleSide, kBubbleSide);
        bubble.isAccessibilityElement = YES;
        bubble.accessibilityLabel = @"Meaning from the artist";
        [self addSubview:bubble];
        objc_setAssociatedObject(self, &kBubbleKey, bubble, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }
    // One dotted stroke under each row the line's words wrap onto.
    UIBezierPath *path = [UIBezierPath bezierPath];
    CGFloat rowY = NAN, from = 0, to = 0;
    for (UIView *word in lyricWords) {
        CGFloat bottom = word.center.y + word.bounds.size.height / 2 + kUnderlineDrop;
        CGFloat left = word.center.x - word.bounds.size.width / 2, right = left + word.bounds.size.width;
        if (bottom != rowY) {
            if (!isnan(rowY)) {
                [path moveToPoint:CGPointMake(from, rowY)];
                [path addLineToPoint:CGPointMake(to, rowY)];
            }
            rowY = bottom;
            from = left;
            to = right;
            continue;
        }
        from = MIN(from, left);
        to = MAX(to, right);
    }
    [path moveToPoint:CGPointMake(from, rowY)];
    [path addLineToPoint:CGPointMake(to, rowY)];
    CAShapeLayer *underline = [CAShapeLayer layer];
    underline.path = path.CGPath;
    underline.strokeColor = [UIColor colorWithWhite:1 alpha:kUnderlineAlpha].CGColor;
    underline.lineWidth = kUnderlineWidth;
    underline.lineCap = kCALineCapRound;
    underline.lineDashPattern = @[@0, @5];
    [self.layer insertSublayer:underline atIndex:0];
    objc_setAssociatedObject(self, &kUnderlineKey, underline, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

@end


#pragma mark - the page

// When each line is sung, kept apart from the lines so the page can ask on every frame.
typedef struct {
    NSInteger start, end;   // its start, and when it is sung out (SGKaraokeSungEnd)
} SGRKaraokeSpan;

// A pause long enough for the dots, and the line after it.
typedef struct {
    NSInteger start, end, line;
} SGRKaraokeBreak;

@interface SGRCreditLabel : UILabel
@property (nonatomic, copy) BOOL (^activate)(void);
@end
@implementation SGRCreditLabel
- (BOOL)accessibilityActivate { return self.activate ? self.activate() : NO; }
@end

@interface SGRKaraokeView () <UIScrollViewDelegate, SGPlayerStateObserver>
@end

@implementation SGRKaraokeView {
    UIScrollView *_scroll;
    BOOL _browsing;
    // The anchor and the open break as they were when the page was taken by hand, which the stack keeps to
    // until it follows the song again (topOfLine:).
    CGFloat _browseAnchor;
    NSInteger _browseBreak;
    CADisplayLink *_link;
    NSTimer *_poll;              // looking a few times a second while the link is paused, nothing on the page moving
    CFTimeInterval _stirredAt;   // when something last set the page moving
    NSString *_track;
    NSArray<SGKaraokeLine *> *_lines;
    // The song is placed from its lines' heights alone; views exist for the lines in and near sight.
    NSArray<NSNumber *> *_tops;   // where each line starts in the stack
    CGFloat _stackEnd;            // where the last line's gap ends: the credit's place
    NSMutableDictionary<NSNumber *, SGKaraokeLineView *> *_shown;   // the views there are, by line
    CGFloat _focusTop;            // the top of the line the stack is arranged around
    CGFloat _sightOffset, _sightFocus;   // what the views in sight were last chosen for
    NSUInteger _sightArrangement;
    NSUInteger _build;   // counts the songs and widths measured, so a measurement that is late is dropped
    UIFont *_font;
    // What is sung now. Most of the time one line, the one at the anchor; where voices overlap, every
    // line being sung, the stack arranged around the one that began first; through a break, none,
    // and the dots at the anchor with the line after them just below.
    SGRKaraokeSpan *_spans;
    SGRKaraokeBreak *_breaks;
    NSUInteger _breakCount;
    NSInteger _sung[kMostSung];
    NSUInteger _sungCount;
    NSInteger _focus;       // the line the stack is arranged around, -1 before the first
    NSInteger _openBreak;   // the line the open break comes before, -1 while no break is open
    NSUInteger _arrangement;   // counts the changes to the three above, for the views in sight
    SGKaraokeBreakView *_dots;
    NSInteger _dotsLine;   // the line the break the dots are timed for comes before
    CFTimeInterval _stillSince;   // when the position stopped moving, 0 while it moves
    SGKaraokeStyle *_style;   // how the lines were laid out
    BOOL _hasSpoken, _hasTranslation;   // whether the song has any line with either
    BOOL _untranslated;   // whether a line with words has no translation, which a translator can fill in
    SGTranslationSource *_saved;   // who made the song's saved translation and when, nil with none saved
    NSString *_savedLanguage;      // the language of that saved file: the setting can change while the lyrics are open
    BOOL _foreign;        // whether the song is in a language other than the one translations are asked in
    NSArray<SGKaraokeLine *> *_passedOver;   // lines kept for the song that changed nothing here, not looked at again
    UIView *_extrasBox;   // the Kit's glass and _extras over it, which holds none, so its alpha can fade
    UIButton *_extras;
    NSArray<SGKaraokeLine *> *_translating;   // the lines a translator is translating, nil while it is not
    SGRSingButton *_sing;   // across from _extras
    CGFloat _builtWidth, _placedHeight;
    BOOL _showing;
    CAGradientLayer *_fade;
    SGRCreditLabel *_credit;
    NSString *_creditSource;   // the source the credit was settled on, nil until the lyrics name one
    NSArray<SGLyricsLink *> *_creditLinks;
    CGFloat _fontSize, _margin, _lineGap, _blurPerLine, _maxBlur;
    BOOL _crediting;   // Show source, read once: the page asks for the source on every frame until it has one
    double _clock;
    NSInteger _reported;
    CFTimeInterval _clockTime;
    NSInteger _seekTo;      // the line a tap seeked to, held by the clock until the player reports it
    CFTimeInterval _seekAt;   // when, 0 while no seek is waiting
    BOOL _sweepsEstimates;   // the Lyrics page's "Simulate word-by-word timing", read once like the credit
    BOOL _plain;             // the song has no timing at all: every line lit, nothing follows the clock
    NSArray<SGKaraokeLine *> *_sample;   // the preview's lines, nil for the player's
    NSInteger _sampleLength;
    CFTimeInterval _sampleEpoch;
    NSDictionary<NSNumber *, NSArray<SGLyricsMeaning *> *> *_meanings;   // Genius's, by line
    NSUInteger _meaningsAsked;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.hidden = YES;
    _focus = _openBreak = -1;
    _margin = SGKaraokeMargin;
    [self takeLook];
    _shown = [NSMutableDictionary dictionary];
    _sightArrangement = NSUIntegerMax;
    SGAddPlayerStateObserver(self);
    _fade = [CAGradientLayer layer];
    _fade.colors = @[(id)UIColor.clearColor.CGColor, (id)UIColor.whiteColor.CGColor,
                     (id)UIColor.whiteColor.CGColor, (id)UIColor.clearColor.CGColor, (id)UIColor.clearColor.CGColor];
    _fade.locations = @[@0, @(SGKaraokeEdgeFade), @(1 - SGKaraokeEdgeFade), @1, @1];
    _scroll = [[UIScrollView alloc] initWithFrame:self.bounds];
    _scroll.layer.mask = _fade;
    _scroll.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _scroll.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    _scroll.showsVerticalScrollIndicator = NO;
    _scroll.alwaysBounceVertical = YES;
    _scroll.scrollsToTop = NO;
    _scroll.delegate = self;
    [self addSubview:_scroll];
    _credit = [[SGRCreditLabel alloc] initWithFrame:CGRectZero];
    [self refreshCreditStyle];
    _credit.adjustsFontForContentSizeCategory = YES;
    _credit.hidden = YES;
    _credit.numberOfLines = 2;
    _crediting = SGFlag(SGKeyLyricsCredit, NO);
    _sweepsEstimates = SGFlag(SGKeyLyricsSimulateWords, NO);
    [_scroll addSubview:_credit];
    __weak SGRKaraokeView *weakSelf = self;
    _credit.activate = ^BOOL {
        SGRKaraokeView *page = weakSelf;
        if (!page || !page->_creditLinks.count) return NO;
        SGLyricsOpenCreditLinks(page->_creditLinks, page->_credit);
        return YES;
    };
    for (NSNotificationName name in @[UIContentSizeCategoryDidChangeNotification, UIAccessibilityDarkerSystemColorsStatusDidChangeNotification])
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(creditStyleChanged) name:name object:nil];
    _sing = [SGRSingButton new];
    _sing.hidden = !SGSingButtonShown();
    [self addSubview:_sing];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(singButtonChanged) name:SGSingButtonDidChangeNotification object:nil];
    [self addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tapped:)]];
    [self addGestureRecognizer:[[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(held:)]];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(playerTransitionChanged:) name:SGPlayerTransitionNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(playerTransitionChanged:) name:SGPlayerTransitionEndedNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(restyle) name:SGRLyricsTextDidChangeNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(restyle) name:SGLyricsRomanisedDidChangeNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(translationsChanged) name:SGLyricsTranslationsDidChangeNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(sourceChosen:) name:SGLyricsSourceChosenNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(lookChanged) name:SGRLyricsLookDidChangeNotification object:nil];
    // A locked phone leaves the card in its window, so the link has to be put down by the app going
    // away rather than by the view going: see scheduleLink.
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(scheduleLink) name:UIApplicationDidBecomeActiveNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(scheduleLink) name:UIApplicationWillResignActiveNotification object:nil];
    return self;
}

// Karaoke's settings switched the mic off or on: hidden at once, Karaoke itself as it was.
- (void)singButtonChanged {
    _sing.hidden = !SGSingButtonShown();
}

- (void)refreshCreditStyle {
    _credit.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleCaption1]
        scaledFontForFont:[UIFont systemFontOfSize:kCreditSize weight:UIFontWeightSemibold] maximumPointSize:17];
    _credit.textColor = SGRSecondary();
}

- (void)creditStyleChanged {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self refreshCreditStyle];
        [self setNeedsLayout];
    });
}

- (instancetype)initWithSampleLines:(NSArray<SGKaraokeLine *> *)lines length:(NSInteger)length {
    if (!(self = [self initWithFrame:CGRectZero])) return nil;
    _sample = lines;
    _sampleLength = MAX(length, 1);
    _sampleEpoch = CACurrentMediaTime();
    _crediting = NO;
    [_sing removeFromSuperview];
    _sing = nil;
    self.userInteractionEnabled = NO;
    self.accessibilityElementsHidden = YES;   // a picture of the setting, with nothing to read or do
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    free(_spans);
    free(_breaks);
}

// The Lyrics page's look: the size and the room are the lines' layout, the blur their placing, the glow
// and the wave every held word's, so a change is the song measured again in it and crossfaded over.
- (void)takeLook {
    SGRLyricsLook look = SGRLyricsLookNow();
    _fontSize = look.size;
    _lineGap = look.spacing;
    _blurPerLine = SGKaraokeBlurPerLine * look.blur;
    _maxBlur = SGKaraokeMaxBlur * look.blur;
    SGKaraokeSetGlowAndWave(look.glow, look.wave);
}

- (void)lookChanged {
    [self takeLook];
    _font = [UIFont systemFontOfSize:_fontSize weight:UIFontWeightBold];
    [_dots removeFromSuperview];   // made again in the new font, at the next frame with a break open
    _dots = nil;
    [self restyle];
}

// The preview's lines on its own clock, round and round; everything else the player's, less the
// Lyrics page's Delay (below 0 for the first moments of a song with one).
- (NSInteger)positionMs {
    if (!_sample) {
        NSInteger ms = SGKaraokePositionMs();
        return ms < 0 ? ms : ms - SGKaraokeDelayMs();
    }
    return (NSInteger)fmod((CACurrentMediaTime() - _sampleEpoch) * 1000, _sampleLength);
}

- (NSArray<SGKaraokeLine *> *)linesFor:(NSString *)track {
    return _sample ?: SGKaraokeLinesForTrack(track);
}

// What a tap at point (in the view) lands on: the credit, a line's explain bubble (*explains), a line to seek
// to, or nothing.
- (UIView *)tapTargetAt:(CGPoint)point explains:(BOOL *)explains {
    *explains = NO;
    if (_extrasBox && !_extrasBox.hidden && CGRectContainsPoint(_extrasBox.frame, point)) return nil;
    if (_sing.userInteractionEnabled && [_sing pointInside:[self convertPoint:point toView:_sing] withEvent:nil]) return nil;
    CGPoint inScroll = [self convertPoint:point toView:_scroll];
    if (_creditLinks.count && !_credit.hidden
        && CGRectContainsPoint(CGRectInset(_credit.frame, -kCreditSlop, -MAX(kCreditSlop, (44 - _credit.frame.size.height) / 2)), inScroll)) {
        return _credit;
    }
    for (SGKaraokeLineView *view in _shown.allValues) {
        CGRect target = view.bubbleTarget;
        if (CGRectIsNull(target) || !CGRectContainsPoint(target, [_scroll convertPoint:inScroll toView:view])) continue;
        *explains = YES;
        return view;
    }
    if (_plain) return nil;   // a line with no time has nowhere to seek to
    if (_seeksAbove > 0 && (point.y > _seeksAbove || point.y < _seeksBelow)) return nil;   // the host's, where its controls were
    for (SGKaraokeLineView *view in _shown.allValues) {
        if (CGRectContainsPoint(CGRectInset(view.frame, -_margin, -_lineGap / 2), inScroll)) return view;
    }
    return nil;
}

- (BOOL)tapSeeksAt:(CGPoint)point {
    BOOL explains;
    UIView *target = [self tapTargetAt:point explains:&explains];
    return target && target != _credit && !explains;
}

- (void)tapped:(UITapGestureRecognizer *)tap {
    [self stir];
    BOOL explains;
    UIView *target = [self tapTargetAt:[tap locationInView:self] explains:&explains];
    if (target == _credit) SGLyricsOpenCreditLinks(_creditLinks, _credit);
    else if (explains) [self explainLine:(SGKaraokeLineView *)target];
    else if (target) [self seekToLine:((SGKaraokeLineView *)target).line];
}

// A tap on a line, or VoiceOver activating it.
- (void)seekToLine:(SGKaraokeLine *)line {
    // The line shows Delay later than the song, so its sound is that much past its start.
    NSInteger delay = SGKaraokeDelayMs();
    SGLog(@"lyrics: tapped the line at %ld-%ld ms, the clock at %.0f ms, %ld ms of delay", (long)line.start, (long)line.end, _clock, (long)delay);
    SGKaraokeSeek(line.start + delay);
    SGPlayFeedback(SGFeedbackSkip);
    [self glideTo:line.start];
}

- (void)held:(UILongPressGestureRecognizer *)hold {
    [self stir];
    if (hold.state != UIGestureRecognizerStateBegan || !_meanings.count) return;
    if (_sing.userInteractionEnabled && [_sing pointInside:[hold locationInView:_sing] withEvent:nil]) return;
    CGPoint point = [hold locationInView:_scroll];
    for (SGKaraokeLineView *view in _shown.allValues) {
        if (!CGRectContainsPoint(CGRectInset(view.frame, -_margin, -_lineGap / 2), point)) continue;
        [self explainLine:view];
        return;
    }
}

- (void)explainLine:(SGKaraokeLineView *)view {
    NSNumber *index = [_shown allKeysForObject:view].firstObject;
    NSArray<SGLyricsMeaning *> *meanings = index ? _meanings[index] : nil;
    if (!meanings.count) return;
    SGPlayFeedback(SGFeedbackSkip);
    SGRShowMeanings(SGKaraokeLineText(view.line), meanings);
}

// Genius is asked once the song's lines are in; lines that change under it are matched again.
- (void)askMeanings {
    _meanings = nil;
    if (_sample) return;
    NSUInteger asked = ++_meaningsAsked;
    NSArray<SGKaraokeLine *> *lines = _lines;
    __weak SGRKaraokeView *weakSelf = self;
    SGLyricsMeaningsFor(_track, lines, ^(NSDictionary<NSNumber *, NSArray<SGLyricsMeaning *> *> *byLine) {
        SGRKaraokeView *page = weakSelf;
        if (!page || asked != page->_meaningsAsked || lines != page->_lines) return;
        page->_meanings = byLine;
        for (NSNumber *key in page->_shown) [page->_shown[key] markMeaning:byLine[key]];
    });
}

#pragma mark - scrolling by hand

// Lines are placed for a content offset of 0, so following the song means scrolling back to 0.
// While the user browses, placement stands still and every line is sharp.
- (void)scrollViewWillBeginDragging:(UIScrollView *)scrollView {
    [self stir];
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(followSong) object:nil];
    if (!_browsing) {
        _browseAnchor = self.bounds.size.height * SGKaraokeAnchor;
        _browseBreak = _openBreak;
    }
    _browsing = YES;
    if (self.browsingBegan) self.browsingBegan([scrollView.panGestureRecognizer translationInView:scrollView].y < 0);
    for (SGKaraokeLineView *view in _shown.allValues) view.blur = 0;
}

// In the caller's animation: the glass dematerializes by its effect and the glyph fades by its alpha, the
// one view of the two with no glass in it.
- (void)setExtrasHidden:(BOOL)hidden {
    [self stir];
    _extrasHidden = hidden;
    if (_extrasBox) {
        UIView *extrasGlass = SGRGlassInside(_extrasBox, &kExtrasGlassKey, kExtrasSide);
        SGRShowGlass(extrasGlass, !hidden);
        _extras.alpha = hidden ? 0 : 1;
        _extrasBox.userInteractionEnabled = !hidden;
    }
    _sing.tucked = hidden && !_keepsSing;
}

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    [self showLinesInSight];
}

// Plain text has no song to follow back to: it stays where it was scrolled to, as a page of text does.
- (void)scrollViewDidEndDragging:(UIScrollView *)scrollView willDecelerate:(BOOL)decelerate {
    if (!decelerate && !_plain) [self performSelector:@selector(followSong) withObject:nil afterDelay:kBrowseHold];
}

- (void)scrollViewDidEndDecelerating:(UIScrollView *)scrollView {
    if (!_plain) [self performSelector:@selector(followSong) withObject:nil afterDelay:kBrowseHold];
}

- (void)followSong {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(followSong) object:nil];
    if (!_browsing) return;
    _browsing = NO;
    [UIView animateWithDuration:0.7 delay:0 usingSpringWithDamping:0.9 initialSpringVelocity:0
                        options:UIViewAnimationOptionAllowUserInteraction
                     animations:^{ self->_scroll.contentOffset = CGPointZero; } completion:nil];
    [self placeLinesAnimated:YES];
}

// A tapped line glides to the anchor at once, and the stack with it: the clock is held at the line until
// the player reports the seek, which takes a few frames. Read before then, the position still on the line
// being sung put the stack back on it, and the seek's arrival then jumped it over to the tapped one.
- (void)glideTo:(NSInteger)ms {
    [self stir];
    _seekTo = ms;
    _seekAt = CACurrentMediaTime();
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(followSong) object:nil];
    if (_browsing) {
        _browsing = NO;
        [UIView animateWithDuration:0.7 delay:0 usingSpringWithDamping:0.9 initialSpringVelocity:0
                            options:UIViewAnimationOptionAllowUserInteraction
                         animations:^{ self->_scroll.contentOffset = CGPointZero; } completion:nil];
    }
    if (!_tops) return;
    NSUInteger arrangement = _arrangement;
    [self arrangeAt:[self clockMs] glide:YES];
    // The line sung tapped again, off a page scrolled by hand: nothing moved on, so the stack is put back.
    if (_arrangement == arrangement) [self placeLinesAnimated:YES];
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (!self.window) {
        // The scroll goes back with the browsing: lines are placed for an offset of 0, and one left from a page
        // scrolled and closed before followSong drew every line off the anchor, none of them lit.
        [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(followSong) object:nil];
        _browsing = NO;
        _scroll.contentOffset = CGPointZero;
    }
    [self scheduleLink];
}

// The player opens and closes in animations that run at 120 Hz, and while a display link asked
// for 30 to 60, the range Apple's ProMotion guide says Core Animation gives priority to, those
// animations ran rough; the player and the lyrics themselves were smooth throughout. The card's
// link now asks for 60 but takes 120, and is put down for as long as the player animates, which
// NowPlayingBar.x announces as each animation starts and again as it ends. The timer is for an end
// that is never announced.
//
// The link is also put down whenever the app is not in front. Spotify keeps playing there, and a
// phone locked on the player kept the card ticking at 120 Hz against a screen that was off: 117 of
// the 137 wake ups a second the mod cost over stock Spotify were this one link, measured with
// scripts/battery-probe.sh. Nothing of the card is seen from the background, so nothing is drawn.
- (void)scheduleLink {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(startLink) object:nil];
    [_poll invalidate];
    _poll = nil;
    [_link invalidate];
    _link = nil;
    if (!self.window) return;
    NSTimeInterval wait = SGPlayerTransitionEnds() - CACurrentMediaTime();
    if (wait <= 0) [self startLink];
    else [self performSelector:@selector(startLink) withObject:nil afterDelay:wait + kTransitionSlack inModes:@[NSRunLoopCommonModes]];
}

- (void)startLink {
    if (!self.window || _link) return;
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
    _link = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick)];
    _link.preferredFrameRateRange = CAFrameRateRangeMake(80, 120, 120);
    _stirredAt = CACurrentMediaTime();
    [_link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
}

// The frame being drawn, or now while the link is paused.
- (CFTimeInterval)frameTime {
    return _link && !_link.paused ? _link.targetTimestamp : CACurrentMediaTime();
}

// Nothing on the page moves: the link is paused rather than slowed, because a link asking for a low rate,
// even uncapped, holds the player's 120 Hz animations back (see scheduleLink). A timer, which asks the display
// for nothing, still watches the track, its lines and the clock a few times a second.
- (void)calmDown {
    _link.paused = YES;
    __weak typeof(self) weakSelf = self;
    _poll = [NSTimer timerWithTimeInterval:0.2 repeats:YES block:^(NSTimer *timer) { [weakSelf tick]; }];
    [NSRunLoop.mainRunLoop addTimer:_poll forMode:NSRunLoopCommonModes];
}

// Something is about to move: the link back at the display's rate before its next frame.
- (void)stir {
    _stirredAt = CACurrentMediaTime();
    if (!_link.paused) return;
    [_poll invalidate];
    _poll = nil;
    _link.paused = NO;
}

// Play, pause, a new track: the clock is about to move, or the page to change.
- (void)playerStateDidChange:(SPTPlayerState *)state {
    [self stir];
}

// A seek while paused, from Spotify's own scrubber: a report that moves the position. A report that
// leaves it where it was lets the link stay calm.
- (void)playerStateDidReport:(SPTPlayerState *)state {
    if (_plain) return;
    // The player's position less the Delay, as positionMs reads it, from the state reported.
    NSInteger ms = _sample ? [self positionMs]
                           : (NSInteger)((state.isPaused ? state.positionAsOfTimestamp : state.position) * 1000) - SGKaraokeDelayMs();
    if (ms != _reported) [self stir];
}

- (void)playerTransitionChanged:(NSNotification *)note {
    [self scheduleLink];
}

// The mask sits in the scroll view's own coordinates, which move with the content as it scrolls, so
// it is put back over the visible part on every frame, where the presentation layer says the
// content is: that holds through a drag and through the animated scroll home alike. Left where
// layout put it, it covered the first screenful of lines only, and a scroll past them showed nothing.
- (void)alignFade {
    CALayer *shown = (CALayer *)_scroll.layer.presentationLayer ?: _scroll.layer;
    CGRect frame = CGRectMake(0, shown.bounds.origin.y, self.bounds.size.width, self.bounds.size.height);
    if (CGRectEqualToRect(frame, _fade.frame)) return;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _fade.frame = frame;
    [CATransaction commit];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    [self alignFade];
    _scroll.contentSize = self.bounds.size;
    _sing.frame = CGRectMake(self.bounds.size.width - _margin - kExtrasSide, self.bounds.size.height - kExtrasSide - kExtrasBottom, kExtrasSide, kExtrasSide);
    if (_extrasBox && !_extrasBox.hidden) {
        _extrasBox.frame = CGRectMake(_margin, self.bounds.size.height - kExtrasSide - kExtrasBottom, kExtrasSide, kExtrasSide);
        SGRShowGlass(SGRGlassInside(_extrasBox, &kExtrasGlassKey, kExtrasSide), !_extrasHidden);
    }
    [self clearBottomRow];
    if (_lines && self.bounds.size.width != _builtWidth) {
        [self rebuild];
    } else if (_tops && self.bounds.size.height != _placedHeight) {
        // A new height moves the anchor (the player's lines going alone and back): the stack is placed for it
        // here, inside whatever animation resized the page, so the sung line rides along with it rather than
        // springing to the new anchor at the next line, and the band the height opens is filled in.
        _sightOffset = -CGFLOAT_MAX;
        [self placeLinesAnimated:NO];
    }
    _placedHeight = self.bounds.size.height;
}

// The lines fade out above the bottom row (the mic and the extras button) and stay clear under
// it, so none is read through the credit; with nothing there they fade out at the bottom edge.
- (void)clearBottomRow {
    CGFloat height = self.bounds.size.height;
    if (height <= 0) return;
    CGFloat floor = height;
    for (UIView *view in @[_sing ?: NSNull.null, _extrasBox ?: NSNull.null]) {
        if ([view isKindOfClass:UIView.class] && !view.hidden && view.superview) floor = MIN(floor, CGRectGetMinY(view.frame) - 8);
    }
    CGFloat clear = MAX(0, MIN(1, (height - floor) / height));
    NSArray *locations = @[@0, @(SGKaraokeEdgeFade), @(MAX(SGKaraokeEdgeFade, 1 - clear - SGKaraokeEdgeFade)), @(1 - clear), @1];
    if ([_fade.locations isEqualToArray:locations]) return;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _fade.locations = locations;
    [CATransaction commit];
}

- (void)dropLineViews {
    for (UIView *view in _shown.allValues) [view removeFromSuperview];
    [_shown removeAllObjects];
    _tops = nil;
    _sightArrangement = NSUIntegerMax;
    _build++;
    [self forgetSung];
}

// Nothing sung, no break open: the state a song starts from, before the clock places it. The dots
// are made again for the next, in case it is laid out in another font.
- (void)forgetSung {
    _sungCount = 0;
    _focus = _openBreak = -1;
    _arrangement++;
    [_dots removeFromSuperview];
    _dots = nil;
}

// A line with words to translate: not an empty one, nor a ♪ holding a break.
static BOOL hasWords(SGKaraokeLine *line) {
    for (SGKaraokeWord *word in line.words) {
        if ([word.text rangeOfCharacterFromSet:NSCharacterSet.letterCharacterSet].location != NSNotFound) return YES;
    }
    return NO;
}

// A way to translate a song: the lines, the track and the language in, one translation per line out, or a
// message to show. Main queue.
typedef void (^SGRTranslated)(NSArray<NSString *> *translations, NSString *error);
// `progress` may be called with the lines so far before `done`.
typedef void (^SGRTranslator)(NSArray<SGKaraokeLine *> *lines, NSString *track, NSString *language, SGRTranslated progress, SGRTranslated done);

// The lines' text for a translator, "" for a line with no words or a translation already.
static NSArray<NSString *> *textsOf(NSArray<SGKaraokeLine *> *lines) {
    NSMutableArray<NSString *> *texts = [NSMutableArray arrayWithCapacity:lines.count];
    for (SGKaraokeLine *line in lines) [texts addObject:hasWords(line) && !line.translation.length ? SGKaraokeLineText(line) ?: @"" : @""];
    return texts;
}

// Whether a line with words is still without a translation.
static BOOL anyUntranslated(NSArray<SGKaraokeLine *> *lines) {
    for (SGKaraokeLine *line in lines) if (!line.translation.length && hasWords(line)) return YES;
    return NO;
}

// When each line is sung and where the breaks are, worked out once per song for the frames to read.
- (void)timeLines {
    free(_spans);
    free(_breaks);
    NSUInteger count = _lines.count;
    _spans = calloc(count + 1, sizeof(SGRKaraokeSpan));
    _breaks = calloc(count + 1, sizeof(SGRKaraokeBreak));
    _breakCount = 0;
    _hasSpoken = _hasTranslation = _untranslated = NO;
    _plain = SGKaraokeLinesTiming(_lines) == SGKaraokeTimingNone;
    _savedLanguage = SGLyricsTranslationTarget();
    _saved = _sample ? nil : SGLyricsSyncSavedTranslation(_track, _savedLanguage, _lines);
    _foreign = SGKaraokeInAnotherLanguage(_lines, _savedLanguage);
    NSInteger sungTo = 0;   // the top of the song counts as where the singing before the first line ends
    for (NSUInteger i = 0; i < count; i++) {
        SGKaraokeLine *line = _lines[i];
        _spans[i] = (SGRKaraokeSpan){line.start, SGKaraokeSungEnd(line)};
        if (!_plain && line.start - sungTo >= SGKaraokeBreakMinMs) _breaks[_breakCount++] = (SGRKaraokeBreak){sungTo, line.start, (NSInteger)i};
        sungTo = MAX(sungTo, _spans[i].end);
        _hasSpoken = _hasSpoken || line.pronunciation || line.backing.pronunciation;
        _hasTranslation = _hasTranslation || line.translation.length;
        _untranslated = _untranslated || (!line.translation.length && hasWords(line));
    }
    [self offerExtras];
    [self askMeanings];
}

// Measures the song for the width and, once that is in, places it; Spotify's own lines stay in view
// until then, since the page shows nothing of its own before it has lines to show.
- (void)rebuild {
    [self dropLineViews];
    _browsing = NO;
    _scroll.contentOffset = CGPointZero;
    _builtWidth = self.bounds.size.width;
    CGFloat width = _builtWidth - 2 * _margin;
    if (width <= 0) return;
    _font = [UIFont systemFontOfSize:_fontSize weight:UIFontWeightBold];
    SGKaraokeStyle *style = _style = [self styleNow];
    NSArray<SGKaraokeLine *> *lines = _lines;
    CGFloat gap = _lineGap;
    NSUInteger build = _build;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
        NSArray<NSNumber *> *tops = SGKaraokeLineTops(lines, width, style, gap);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (build != self->_build) return;   // the song or the width moved on meanwhile
            [self takeTops:tops];
            [self placeLinesAnimated:NO];
        });
    });
}

#pragma mark - the pronunciation and the translation

// What a line shows besides its words: what the song has, of what the lyrics menu has switched on.
- (SGKaraokeStyle *)styleNow {
    BOOL romanised = SGFlag(SGKeyLyricsRomanised, NO);
    BOOL replace = romanised && SGFlag(SGKeyLyricsRomanisedReplace, NO);
    SGKaraokeStyle *style = [[SGKaraokeStyle alloc] initWithSize:_fontSize order:SGRLyricsTextOrder()
                                                     pronunciation:!replace && _hasSpoken && SGFlag(SGRKeyLyricsPronunciation, NO)
                                                       translation:_hasTranslation && SGFlag(SGRKeyLyricsTranslation, NO)
                                                         romanised:romanised && !replace];
    style.japanese = romanised && SGLyricsLooksJapanese(_lines);
    style.romanisedReplace = replace;
    return style;
}

// A switch of the menu or the Lyrics page's order: the song is measured again in the new style off
// the main thread, as for a new width, but the lines on the page stay until it is in, and then the
// new ones crossfade over them where they were, so nothing blinks and nothing is lost of the place.
- (void)restyle {
    [self offerExtras];
    if (!_lines || !_tops || _builtWidth <= 0) return;   // the next build picks the style up
    SGKaraokeStyle *style = [self styleNow];
    NSArray<SGKaraokeLine *> *lines = _lines;
    CGFloat width = _builtWidth - 2 * _margin, gap = _lineGap;
    NSUInteger build = ++_build;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
        NSArray<NSNumber *> *tops = SGKaraokeLineTops(lines, width, style, gap);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (build != self->_build) return;
            [self showStyle:style tops:tops];
        });
    });
}

// SGKaraokeLineTops' answer: the lines' tops, and the stack's end apart from them.
- (void)takeTops:(NSArray<NSNumber *> *)tops {
    _stackEnd = tops.lastObject.doubleValue;
    _tops = tops.count ? [tops subarrayWithRange:NSMakeRange(0, tops.count - 1)] : tops;
}

- (void)showStyle:(SGKaraokeStyle *)style tops:(NSArray<NSNumber *> *)tops {
    CATransition *fade = [CATransition animation];
    fade.type = kCATransitionFade;
    fade.duration = kRestyleFade;
    [_scroll.layer addAnimation:fade forKey:@"restyle"];
    for (UIView *view in _shown.allValues) [view removeFromSuperview];
    [_shown removeAllObjects];
    _style = style;
    [self takeTops:tops];
    _sightArrangement = NSUIntegerMax;
    [self placeLinesAnimated:NO];
    [self showLinesInSight];   // placing stands still while the page is scrolled by hand; the views do not
    // The new views come in as the old ones were: the lines being sung lit, and every blur where it
    // was rather than easing in from sharp, which a view made out of sight does unseen.
    for (NSUInteger i = 0; i < _sungCount; i++) [self viewForLine:_sung[i]].active = YES;
    for (SGKaraokeLineView *view in _shown.allValues) [view.layer removeAnimationForKey:@"blur"];
}

// The button shows only for a song with a pronunciation or a translation to show, and its menu only
// what the song has: a switch for each, reading what tapping it will do.
- (void)offerExtras {
    NSString *language = SGLyricsTranslationTarget();
    // A translator is offered only for a song in another language than the one it would translate into,
    // and the translators are asked after (an AI translator's key is a Keychain read).
    BOOL wanted = _lines && !_sample && (_foreign || SGHidden(SGKeyLyricsTranslateEverySong)) && _untranslated;
    BOOL onDevice = wanted && SGFlag(SGKeyLyricsTranslateOnDevice, YES) && SGOnDeviceTranslation.translationAvailable;
    BOOL intelligence = wanted && SGFlag(SGKeyLyricsAppleIntelligence, YES) && [SGOnDeviceTranslation appleIntelligenceAvailable:language];
    BOOL ai = wanted && SGAITranslatorReady();
    BOOL translatable = ai || onDevice || intelligence;
    BOOL offered = _lines && !_sample && (_hasSpoken || _hasTranslation || translatable);
    if (!offered) {
        _extrasBox.hidden = YES;
        [self setNeedsLayout];
        return;
    }
    if (!_extras) {
        // The Kit's glass, as the mic across from it has (setExtrasHidden:), which turns solid under Reduce
        // Transparency, with a plain button over it.
        _extrasBox = [[UIView alloc] initWithFrame:CGRectMake(0, 0, kExtrasSide, kExtrasSide)];
        _extrasBox.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
        UIButtonConfiguration *config = [UIButtonConfiguration plainButtonConfiguration];
        config.image = [UIImage systemImageNamed:@"translate"];
        config.preferredSymbolConfigurationForImage = [UIImageSymbolConfiguration configurationWithPointSize:kExtrasGlyph weight:UIImageSymbolWeightSemibold];
        config.baseForegroundColor = UIColor.whiteColor;
        _extras = [UIButton buttonWithConfiguration:config primaryAction:nil];
        _extras.frame = _extrasBox.bounds;
        _extras.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _extras.showsMenuAsPrimaryAction = YES;
        _extras.preferredMenuElementOrder = UIContextMenuConfigurationElementOrderFixed;
        _extras.accessibilityLabel = @"Pronunciation and translation";
        [_extrasBox addSubview:_extras];
        [self addSubview:_extrasBox];
        self.extrasHidden = _extrasHidden;
    }
    // While a translation is worked out the glyph turns into a spinner, and the menu has nothing to ask a second time.
    BOOL translating = _translating && _translating == _lines;
    UIButtonConfiguration *config = _extras.configuration;
    if (config.showsActivityIndicator != translating) {
        config.showsActivityIndicator = translating;
        _extras.configuration = config;
        _extras.accessibilityValue = translating ? @"Translating" : nil;
    }
    NSMutableArray<UIMenuElement *> *items = [NSMutableArray array];
    if (_hasSpoken) {
        BOOL on = SGFlag(SGRKeyLyricsPronunciation, NO);
        [items addObject:[UIAction actionWithTitle:on ? @"Hide Pronunciation" : @"Show Pronunciation"
                                             image:[UIImage systemImageNamed:@"character.phonetic"] identifier:nil
                                           handler:^(UIAction *action) { SGRSetLyricsTextShown(SGRLyricsTextPronunciation, !on); }]];
    }
    if (_hasTranslation) {
        BOOL on = SGFlag(SGRKeyLyricsTranslation, NO);
        [items addObject:[UIAction actionWithTitle:on ? @"Hide Translation" : @"Show Translation"
                                             image:[UIImage systemImageNamed:@"character.bubble"] identifier:nil
                                           handler:^(UIAction *action) { SGRSetLyricsTextShown(SGRLyricsTextTranslation, !on); }]];
    }
    // Who made the saved translation and when, and for one an AI made (or no one known) a way to have it asked again.
    if (_saved && _hasTranslation) {
        UIAction *source = [UIAction actionWithTitle:_saved.name image:[UIImage systemImageNamed:@"info.circle"] identifier:nil handler:^(UIAction *action) {}];
        source.subtitle = _saved.made ? [NSDateFormatter localizedStringFromDate:_saved.made dateStyle:NSDateFormatterMediumStyle timeStyle:NSDateFormatterShortStyle]
                                      : @"Date unknown";
        source.attributes = UIMenuElementAttributesDisabled;
        NSMutableArray<UIMenuElement *> *about = [NSMutableArray arrayWithObject:source];
        // Not while a translator works: its next batch would save the file again.
        if (_saved.deletable && !translating) {
            NSString *track = _track, *language = _savedLanguage;
            UIAction *delete = [UIAction actionWithTitle:@"Delete This Translation" image:[UIImage systemImageNamed:@"trash"] identifier:nil
                                                 handler:^(UIAction *action) { SGLyricsDeleteSavedTranslation(track, language); }];
            delete.attributes = UIMenuElementAttributesDestructive;
            [about addObject:delete];
        }
        [items addObject:[UIMenu menuWithTitle:@"Translated by" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:about]];
    }
    // Also for a song a source translated in part, as Musixmatch's community often has: the rest is filled in.
    // Said in each item: whether the song's words stay on the phone.
    if (translatable && !translating) {
        __weak SGRKaraokeView *weakSelf = self;
        void (^offer)(NSString *, NSString *, NSString *, SGTranslationSource *(^)(void), SGRTranslator) =
            ^(NSString *title, NSString *glyph, NSString *subtitle, SGTranslationSource *(^source)(void), SGRTranslator translator) {
            UIAction *action = [UIAction actionWithTitle:title image:[UIImage systemImageNamed:glyph] identifier:nil
                                                 handler:^(UIAction *action) { [weakSelf translateWith:translator source:source()]; }];
            action.subtitle = subtitle;
            [items addObject:action];
        };
        if (onDevice) {
            offer(@"Translate on iPhone", @"translate", @"Apple's Translate, on this iPhone",
                  ^{ return [SGTranslationSource by:SGTranslatedOnDevice model:nil made:nil]; },
                  ^(NSArray<SGKaraokeLine *> *lines, NSString *track, NSString *to, SGRTranslated progress, SGRTranslated done) {
                [SGOnDeviceTranslation translate:textsOf(lines) to:to from:weakSelf done:done];
            });
        }
        if (intelligence) {
            offer(@"Translate with Apple Intelligence", @"apple.intelligence", @"On this iPhone",
                  ^{ return [SGTranslationSource by:SGTranslatedByAppleIntelligence model:nil made:nil]; },
                  ^(NSArray<SGKaraokeLine *> *lines, NSString *track, NSString *to, SGRTranslated progress, SGRTranslated done) {
                [SGOnDeviceTranslation translateWithAppleIntelligence:textsOf(lines) to:to song:SGLyricsSongName(track) progress:^(NSArray<NSString *> *soFar) { progress(soFar, nil); } done:done];
            });
        }
        // The provider and model are read as the item is tapped, which is when the request is made.
        if (ai) offer([@"Translate with " stringByAppendingString:SGAITranslatorName()], @"sparkles",
                      [@"Sends the lyrics to " stringByAppendingString:SGAITranslatorRecipient()], ^{ return SGAITranslatorSource(); },
                      ^(NSArray<SGKaraokeLine *> *lines, NSString *track, NSString *to, SGRTranslated progress, SGRTranslated done) {
            SGLyricsTranslateWithAI(track, lines, to, done);
        });
    }
    _extras.menu = [UIMenu menuWithChildren:items];
    _extrasBox.hidden = NO;
    [self setNeedsLayout];
}

// The song's lines into the Lyrics page's language, or the phone's: each line without a translation takes
// the translator's, and translations are switched on so the answer shows. The whole song goes, for the sense.
- (void)translateWith:(SGRTranslator)translator source:(SGTranslationSource *)source {
    NSArray<SGKaraokeLine *> *lines = _lines;
    NSString *track = _track;
    if (!lines.count || _translating == lines) return;
    _translating = lines;
    [self offerExtras];
    NSString *language = SGLyricsTranslationTarget();
    // Kept a batch at a time too, so a translation cut off by Spotify closing keeps what was done.
    translator(lines, track, language, ^(NSArray<NSString *> *soFar, NSString *error) {
        [self takeTranslations:soFar into:lines];
        [self saved:SGLyricsSaveTranslation(track, language, lines, source) for:lines in:language];
    }, ^(NSArray<NSString *> *translations, NSString *error) {
        if (self->_translating == lines) self->_translating = nil;
        // Translations can come with a note, which names the lines left out. Those lines stay untranslated, and
        // asking again sends only them.
        if (translations) {
            [self takeTranslations:translations into:lines];
            [self saved:SGLyricsSaveTranslation(track, language, lines, source) for:lines in:language];
            if (lines == self->_lines) self->_untranslated = anyUntranslated(lines);
        }
        [self offerExtras];
        if (error) {
            BOOL needsDownload = [source.by isEqualToString:SGTranslatedOnDevice] && [error hasPrefix:@"Download "];
            NSString *title = needsDownload ? @"Language not downloaded" : (translations ? @"Partly translated" : @"No translation");
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                           message:error preferredStyle:UIAlertControllerStyleAlert];
            // Over the player, which is dark whatever the system's appearance.
            alert.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
            if (needsDownload) {
                [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
                UIAlertAction *open = [UIAlertAction actionWithTitle:@"Open Settings" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
                    [SGOnDeviceTranslation openTranslateSettings];
                }];
                [alert addAction:open];
                alert.preferredAction = open;
            } else {
                [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
            }
            [SGTopController() presentViewController:alert animated:YES completion:nil];
        }
    });
}

// A source picked from the player's ⋯ replaces the lines of the song playing, which the page otherwise keeps
// through any later answer: they are dropped as on a change of track, and the next tick takes the new ones.
- (void)sourceChosen:(NSNotification *)note {
    if (_sample || ![note.object isEqual:_track]) return;
    [self dropLines];
}

- (void)dropLines {
    _lines = nil;
    _passedOver = nil;
    _builtWidth = 0;
    [self creditTo:nil];
    [self dropLineViews];
    [self offerExtras];
}

// The menu names who made the song's translation as soon as it is saved, if the song is still the one shown.
- (void)saved:(SGTranslationSource *)source for:(NSArray<SGKaraokeLine *> *)lines in:(NSString *)language {
    if (!source || lines != _lines) return;
    _saved = source;
    _savedLanguage = language;
    [self offerExtras];
}

// The saved translations deleted, or Translate any song switched: the song is synced again and redrawn.
- (void)translationsChanged {
    if (!_lines) return;
    [self timeLines];
    [self restyle];
}

// Each line still without a translation takes the one given for it, and translations are switched on so
// they show. The lines may be another song's by now: they keep the translation, the page is left alone.
- (void)takeTranslations:(NSArray<NSString *> *)translations into:(NSArray<SGKaraokeLine *> *)lines {
    __block BOOL took = NO;
    [lines enumerateObjectsUsingBlock:^(SGKaraokeLine *line, NSUInteger i, BOOL *stop) {
        if (i < translations.count && translations[i].length && !line.translation.length) {
            line.translation = translations[i];
            line.translationMade = YES;
            took = YES;
        }
    }];
    if (!took || lines != _lines) return;
    _hasTranslation = YES;
    [self offerExtras];
    if (SGFlag(SGRKeyLyricsTranslation, NO)) [self restyle];
    else SGRSetLyricsTextShown(SGRLyricsTextTranslation, YES);
}

// Where a line starts on the page, for the stack as it is arranged now: an open break holds the room
// of one row at the anchor, and the lines from the one after it on are moved down by it.
//
// While the page is scrolled by hand the stack stands still, and so does what places it: the room can
// change meanwhile (the player's controls go as a scroll starts, and the anchor moves with the height)
// and a break can open or close, and a line made for the view then went by the new anchor while the
// lines beside it kept the old one, the two running into each other.
- (CGFloat)topOfLine:(NSInteger)index {
    CGFloat anchor = _browsing ? _browseAnchor : self.bounds.size.height * SGKaraokeAnchor;
    NSInteger openBreak = _browsing ? _browseBreak : _openBreak;
    CGFloat top = anchor + _tops[index].doubleValue - _focusTop;
    return openBreak >= 0 && index >= openBreak ? top + [self breakRoom] : top;
}

- (CGFloat)breakRoom {
    return ceil(_font.lineHeight) + _lineGap;
}

- (BOOL)isSung:(NSInteger)index {
    for (NSUInteger i = 0; i < _sungCount; i++) {
        if (_sung[i] == index) return YES;
    }
    return NO;
}

// How many lines away from what is sung a line is, which is what dims, shrinks and blurs it: from the
// nearest line being sung, from an open break as if it were a line of its own, and before the first
// line from the line before it, as ever.
- (NSInteger)distanceOf:(NSInteger)index {
    if (_plain) return 0;   // nothing is sung, so every line reads as clearly as the rest
    if (_openBreak >= 0) return index >= _openBreak ? index - _openBreak + 1 : _openBreak - index;
    if (!_sungCount) return labs(index - _focus);
    NSInteger nearest = NSIntegerMax;
    for (NSUInteger i = 0; i < _sungCount; i++) nearest = MIN(nearest, labs(index - _sung[i]));
    return nearest;
}

// The view of a line, made the first time it is asked for and placed where the stack has it.
- (SGKaraokeLineView *)viewForLine:(NSInteger)index {
    __block SGKaraokeLineView *view = _shown[@(index)];
    if (view || !_tops || index < 0 || index >= (NSInteger)_tops.count) return view;
    // Made where it belongs even inside an animation of the page's (a new height), not flown in from the corner.
    [UIView performWithoutAnimation:^{
        view = [[SGKaraokeLineView alloc] initWithLine:self->_lines[index] width:self->_builtWidth - 2 * self->_margin style:self->_style under:nil
                                                blurred:self->_maxBlur > 0 && !self->_plain sweepsEstimates:self->_sweepsEstimates];
        __weak SGRKaraokeView *page = self;
        SGKaraokeLine *line = view.line;
        view.activate = ^BOOL {
            SGRKaraokeView *owner = page;
            if (!owner || owner->_plain || ![owner->_lines containsObject:line]) return NO;
            [owner seekToLine:line];
            return YES;
        };
        if (self->_plain) [view showPlain];
        [view markMeaning:self->_meanings[@(index)]];
        [self->_scroll addSubview:view];
        self->_shown[@(index)] = view;
        [self placeLine:view at:index animated:NO];
    }];
    return view;
}

// Views for the lines just outside the visible part as well as in it, wherever that is: around the
// sung line while following the song, around wherever the page has been scrolled to while browsing.
// The ones further off are let go, so a long song costs a couple of dozen line views rather than
// one for every line, and the lines in sight are the only ones the compositor has to draw.
- (void)showLinesInSight {
    if (!_tops.count) return;
    CGFloat offset = ((CALayer *)_scroll.layer.presentationLayer ?: _scroll.layer).bounds.origin.y;
    if (offset == _sightOffset && _focusTop == _sightFocus && _arrangement == _sightArrangement) return;
    _sightOffset = offset;
    _sightFocus = _focusTop;
    _sightArrangement = _arrangement;
    CGFloat height = self.bounds.size.height;
    CGFloat from = offset - kSightBehind * height, to = offset + (1 + kSightAhead) * height, slack = kSightSlack * height;
    NSMutableArray<NSNumber *> *gone = [NSMutableArray array];
    id focusedElement = UIAccessibilityIsVoiceOverRunning() ? UIAccessibilityFocusedElement(UIAccessibilityNotificationVoiceOverIdentifier) : nil;
    for (NSNumber *key in _shown) {
        NSInteger index = key.integerValue;
        CGFloat top = [self topOfLine:index], bottom = top + _shown[key].bounds.size.height;
        // Keep the element VoiceOver is reading even when playback moves it out of sight.
        BOOL focused = focusedElement == _shown[key];
        if (!focused && ![self isSung:index] && (bottom < from - slack || top > to + slack)) [gone addObject:key];
    }
    for (NSNumber *key in gone) {
        [_shown[key] removeFromSuperview];
        [_shown removeObjectForKey:key];
    }
    NSInteger count = (NSInteger)_tops.count;
    NSMutableArray<NSNumber *> *wanted = [NSMutableArray array];
    for (NSInteger index = 0; index < count; index++) {
        if (_shown[@(index)]) continue;
        CGFloat top = [self topOfLine:index];
        CGFloat bottom = index + 1 < count ? [self topOfLine:index + 1] - _lineGap : top + height;
        if (bottom < from || top > to) continue;
        [wanted addObject:@(index)];
    }
    // A few a frame, the nearest the middle of the visible part first, so a page scrolled by hand
    // fills in what is in view before what is not; the next frame picks up where this one left off.
    CGFloat middle = offset + height / 2;
    [wanted sortUsingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b) {
        CGFloat da = fabs([self topOfLine:a.integerValue] - middle), db = fabs([self topOfLine:b.integerValue] - middle);
        return da < db ? NSOrderedAscending : da > db ? NSOrderedDescending : NSOrderedSame;
    }];
    NSUInteger made = 0;
    for (NSNumber *index in wanted) {
        if (made++ == kLinesPerFrame) {
            _sightOffset = -CGFLOAT_MAX;
            break;
        }
        [self viewForLine:index.integerValue];
    }
}

// One line's place in the stack: the anchor sits on the edge its text is aligned to, so it scales
// toward its own text, and it dims and blurs with its distance from what is sung.
- (void)placeLine:(SGKaraokeLineView *)view at:(NSInteger)index animated:(BOOL)animated {
    CGFloat height = self.bounds.size.height;
    NSInteger distance = [self distanceOf:index], below = index - _focus;
    CGRect frame = CGRectMake(_margin, [self topOfLine:index], view.bounds.size.width, view.bounds.size.height);
    CGPoint center = CGPointMake(view.right ? CGRectGetMaxX(frame) : _margin, CGRectGetMidY(frame));
    CGFloat scale = distance == 0 ? 1 : SGKaraokeDimScale;
    CGAffineTransform transform = CGAffineTransformMakeScale(scale, scale);
    view.blur = distance == 0 || _browsing ? 0 : MIN(_maxBlur, distance * _blurPerLine);
    BOOL near = CGRectIntersectsRect(CGRectInset(self.bounds, 0, -height / 2), frame)
             || CGRectIntersectsRect(CGRectInset(self.bounds, 0, -height / 2), view.frame);
    if (!animated || !near) {
        view.center = center;
        view.transform = transform;
        return;
    }
    NSTimeInterval delay = below > 0 ? MIN(0.3, below * 0.04) : 0;
    [UIView animateWithDuration:0.7 delay:delay usingSpringWithDamping:0.86 initialSpringVelocity:0
                        options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                     animations:^{
        view.center = center;
        view.transform = transform;
    } completion:nil];
}

// The sung line rests at the anchor and the rest stack around it; lines below it follow a beat
// later, the further down the later, as Apple Music's do. A line sung over it stays where it is
// below, lit; the stack moves on to it once the line at the anchor is sung out.
- (void)placeLinesAnimated:(BOOL)animated {
    [self stir];
    if (_browsing || !_tops.count) return;
    _focusTop = _tops[(NSUInteger)MAX(_focus, 0)].doubleValue;
    [self showLinesInSight];
    for (NSNumber *key in _shown) [self placeLine:_shown[key] at:key.integerValue animated:animated];
    [self placeBreak];
    [self placeCreditAnimated:animated];
    // Room to scroll until the first line or the last one reaches the anchor.
    CGFloat lastTop = _tops.lastObject.doubleValue + (_openBreak >= 0 ? [self breakRoom] : 0);
    _scroll.contentInset = UIEdgeInsetsMake(_focusTop, 0, MAX(0, lastTop - _focusTop), 0);
}

// The credit, under the last line as Spotify's and Apple Music's are: it moves with the stack, so it is seen at the
// song's end or scrolled to, rather than over every line.
- (void)placeCreditAnimated:(BOOL)animated {
    if (!_tops.count || !_credit.text.length) return;
    CGFloat anchor = _browsing ? _browseAnchor : self.bounds.size.height * SGKaraokeAnchor;
    NSInteger openBreak = _browsing ? _browseBreak : _openBreak;
    CGFloat width = MAX(self.bounds.size.width - 2 * _margin, 0);
    CGSize size = [_credit sizeThatFits:CGSizeMake(width, CGFLOAT_MAX)];
    CGFloat top = anchor + _stackEnd - _focusTop + (openBreak >= 0 ? [self breakRoom] : 0) + kCreditGap;
    CGRect frame = CGRectMake(_margin, top, MIN(ceil(size.width), width), ceil(size.height));
    if (CGRectEqualToRect(_credit.frame, frame)) return;
    if (!animated || _credit.hidden) {
        _credit.frame = frame;
        return;
    }
    [UIView animateWithDuration:0.7 delay:0.3 usingSpringWithDamping:0.86 initialSpringVelocity:0
                        options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                     animations:^{ self->_credit.frame = frame; } completion:nil];
}

// The dots, at the anchor for as long as a break is open, against the edge the line after it is on.
// They are only ever where they belong: they come and go by their own timeline, not by moving.
- (void)placeBreak {
    if (_openBreak < 0) {
        [_dots removeFromSuperview];
        return;
    }
    if (!_dots) {
        _dots = [[SGKaraokeBreakView alloc] initWithFont:_font];
        _dotsLine = -1;
    }
    if (_dotsLine != _openBreak) {
        SGKaraokeLine *breakLine = _lines[(NSUInteger)_openBreak];
        if (_style.romanisedReplace) {
            SGKaraokeLine *rom = SGLyricsRomanisedLine(breakLine, _style.japanese);
            if (rom) breakLine = rom;
        }
        _dots.rightToLeft = SGKaraokeReadsRightToLeft(SGKaraokeLineText(breakLine));
        for (NSUInteger i = 0; i < _breakCount; i++) {
            if (_breaks[i].line == _openBreak) [_dots playFrom:_breaks[i].start to:_breaks[i].end];
        }
        _dotsLine = _openBreak;
    }
    if (_dots.superview != _scroll) [_scroll addSubview:_dots];
    SGKaraokeLine *dotLine = _lines[(NSUInteger)_openBreak];
    if (_style.romanisedReplace) {
        SGKaraokeLine *rom = SGLyricsRomanisedLine(dotLine, _style.japanese);
        if (rom) dotLine = rom;
    }
    _dots.right = SGKaraokeAlignsRight(dotLine);
    CGFloat top = [self topOfLine:_openBreak] - [self breakRoom];
    _dots.frame = CGRectMake(_margin, top, _builtWidth - 2 * _margin, _dots.bounds.size.height);
}

// A credit the source's terms require shows whatever Show source says (Shared/LyricsSources/SpicyLyrics.m).
- (void)creditTo:(NSString *)source {
    _creditSource = source;
    BOOL shown = source.length && (_crediting || SGLyricsCreditRequired(source));
    NSString *text = shown ? [NSString stringWithFormat:@"Lyrics from %@", source] : nil;
    _creditLinks = shown ? SGLyricsCreditLinks(source) : nil;
    _credit.accessibilityTraits = _creditLinks.count ? UIAccessibilityTraitLink : UIAccessibilityTraitStaticText;
    if (text == _credit.text || [text isEqualToString:_credit.text]) return;
    _credit.text = text;
    _credit.hidden = !_showing || !text.length;
    [self placeCreditAnimated:NO];
}

- (NSArray *)accessibilityElements {
    NSMutableArray *elements = [NSMutableArray array];
    for (NSNumber *key in [[_shown allKeys] sortedArrayUsingSelector:@selector(compare:)]) [elements addObject:_shown[key]];
    if (_extrasBox && !_extrasBox.hidden) [elements addObject:_extrasBox];
    if (!_credit.hidden) [elements addObject:_credit];
    if (_sing && !_sing.hidden) [elements addObject:_sing];
    return elements;
}

- (void)syncSiblings {
    for (UIView *sibling in self.superview.subviews) {
        if (sibling != self && _showing) sibling.alpha = 0;
    }
}

- (void)setShowing:(BOOL)showing {
    if (showing == _showing) return;
    _showing = showing;
    self.hidden = !showing;
    if (showing && !_browsing) _scroll.contentOffset = CGPointZero;
    _credit.hidden = !showing || !_credit.text.length;
    for (UIView *sibling in self.superview.subviews) {
        if (sibling != self) sibling.alpha = showing ? 0 : 1;
    }
}

// The player's position run on by the frame times the display will show and eased toward each new
// reading, so the sweep follows neither the callback's jitter nor the small jumps of the core's
// corrections. A seek or a new track is too far off to ease and is taken at once.
- (double)clockMs {
    NSInteger raw = [self positionMs];
    CFTimeInterval shown = [self frameTime];
    if (_seekAt) {
        // A paused player never moves, so the hold ends by the position or the time, not by motion.
        BOOL reported = raw >= 0 && labs(raw - _seekTo) <= kSeekNearMs;
        if (!reported && CACurrentMediaTime() - _seekAt < kSeekWait) {
            _clock = _seekTo;
            _reported = raw;
            _clockTime = shown;
            return _clock;
        }
        _seekAt = 0;
    }
    BOOL running = raw != _reported;   // a paused player reports the same position every frame
    if (running) {
        _stillSince = 0;
        [self stir];
    }
    else if (!_stillSince) _stillSince = shown;
    double reported = raw + (running ? (shown - CACurrentMediaTime()) * 1000 : 0);
    double predicted = _clock + (running ? (shown - _clockTime) * 1000 : 0);
    double error = reported - predicted;
    _clock = raw < 0 || fabs(error) > kClockSnapMs ? reported : predicted + error * kClockPull;
    _reported = raw;
    _clockTime = shown;
    return _clock;
}

- (void)tick {
    // A paused clock and a page at rest draw nothing new: once what was last set moving has finished, a few
    // frames a second still watch the track, its lines and the clock, and whatever moves stirs it back.
    if (_seekAt || _scroll.isTracking || _scroll.isDecelerating) [self stir];
    else if (_link && !_link.paused && [self frameTime] - _stirredAt > kCalmAfter) [self calmDown];
    NSString *track = _sample ? @"sample" : SGKaraokePlayingTrack();
    if (!(track == _track || [track isEqualToString:_track])) {
        SGLog(@"karaoke: page shows track %@, lyrics %@", track, [self linesFor:track] ? @"captured" : @"not captured yet");
        _track = track;
        [self dropLines];
    }
    NSArray<SGKaraokeLine *> *kept = _lines && track ? [self linesFor:track] : nil;
    if (kept && kept != _lines && kept != _passedOver) {
        if (!_hasTranslation && kept.count == _lines.count && SGKaraokeLinesTiming(kept) == SGKaraokeLinesTiming(_lines)
            && SGKaraokeHasTranslations(kept)) {
            // Musixmatch's translations come in a moment after the lines, as copies of them: the song is
            // restyled with them where it stands.
            SGLog(@"karaoke: translations of %@ came in", track);
            if (_tops) {
                _lines = kept;
                [self timeLines];
                [self restyle];
            } else {
                // Nothing placed yet, and a measure may be in flight in the old style: it is dropped, and
                // the translated lines are built below as new ones.
                _lines = nil;
                _builtWidth = 0;
                [self dropLineViews];
            }
        } else if (_plain) {
            // Plain text is shown while Spotify is asked whether it has the song timed; its answer replaces it.
            SGLog(@"karaoke: timed lines of %@ came in over the plain text", track);
            _lines = nil;
            _builtWidth = 0;
            [self creditTo:nil];
            [self dropLineViews];
        } else {
            _passedOver = kept;
        }
    }
    if (!_lines && track && (_lines = [self linesFor:track])) {
        SGLog(@"karaoke: showing %lu lines of %@", (unsigned long)_lines.count, track);
        [self timeLines];
        [self setNeedsLayout];
    }
    [self setShowing:_tops != nil];
    // The source is settled a moment after the lines are, so it is asked for until it answers.
    if (!_sample && _lines && !_creditSource) [self creditTo:SGLyricsCreditFor(track)];
    if (!_tops) return;
    [self alignFade];
    if (_plain) {
        [self showLinesInSight];   // it moves only when scrolled by hand
        return;
    }

    double now = [self clockMs];
    [self arrangeAt:now glide:_sample != nil];   // the preview coming round glides back to its first line
    for (NSUInteger i = 0; i < _sungCount; i++) [_shown[@(_sung[i])] showTime:now];
    CFTimeInterval frame = [self frameTime];
    if (_dots.superview) [_dots showTime:now running:!_stillSince || frame - _stillSince < kStillFor at:frame];
}

// What is sung at `now` lit and the stack arranged around it; a jump of more than a couple of lines is
// placed at once, unless it is a tapped line gliding over.
- (void)arrangeAt:(double)now glide:(BOOL)glide {
    NSInteger sung[kMostSung], focus, openBreak;
    NSUInteger count = [self sungAt:now into:sung focus:&focus openBreak:&openBreak];
    if (focus != _focus || openBreak != _openBreak || count != _sungCount || memcmp(sung, _sung, count * sizeof(NSInteger))) {
        // Lines sung out go back to dim, lines coming in light up, the ones sung throughout carry on.
        for (NSUInteger i = 0; i < _sungCount; i++) {
            BOOL still = NO;
            for (NSUInteger j = 0; j < count; j++) still = still || sung[j] == _sung[i];
            if (!still) _shown[@(_sung[i])].active = NO;
        }
        for (NSUInteger j = 0; j < count; j++) {
            if (![self isSung:sung[j]]) [self viewForLine:sung[j]].active = YES;
        }
        BOOL jump = labs(focus - _focus) > 2;   // a seek, not the song moving on
        memcpy(_sung, sung, count * sizeof(NSInteger));
        _sungCount = count;
        _focus = focus;
        _openBreak = openBreak;
        _arrangement++;
        if (openBreak < 0) [_dots removeFromSuperview];
        [self placeLinesAnimated:glide || !jump];
    } else {
        [self showLinesInSight];   // the page may be scrolling by hand, or springing back
    }
}

// What is sung at `now`: each line from its start until it is sung out, so two voices over each
// other are both lit, and the last line begun on through the pause after it, as Apple Music keeps a
// line lit until the next one comes. A pause that is a break is the dots' instead, until the moment
// before its end when the line after it moves up to the anchor, sharp but not yet lit.
- (NSUInteger)sungAt:(double)now into:(NSInteger *)sung focus:(NSInteger *)focus openBreak:(NSInteger *)openBreak {
    NSInteger count = (NSInteger)_lines.count, last = -1;
    while (last + 1 < count && _spans[last + 1].start <= now) last++;
    *openBreak = -1;
    NSInteger breakLine = -1;
    for (NSUInteger i = 0; i < _breakCount; i++) {
        SGRKaraokeBreak pause = _breaks[i];
        if (now < pause.start || now >= pause.end) continue;
        breakLine = pause.line;
        if (now < pause.end - SGKaraokeBreakCollapse * 1000) *openBreak = pause.line;
    }
    NSUInteger found = 0;
    for (NSInteger i = 0; i <= last && found < kMostSung; i++) {
        if (_spans[i].end > now || (i == last && breakLine < 0)) sung[found++] = i;
    }
    *focus = breakLine >= 0 ? breakLine : found ? sung[0] : last;
    return found;
}

@end
