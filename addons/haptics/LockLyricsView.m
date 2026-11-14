#import "LockLyricsView.h"
#import "../../tweak/Sources/Shared/Lyrics/KaraokeLines.h"
#import "../../tweak/Sources/Shared/Haptics/SGHapticRelay.h"

// Two voices can sing at once, rarely more; past this many, the latest ones wait their turn.
enum { kMostSung = 6 };
// How many line views are made in one frame: the rest follow on the next, nearest the sung line first.
static const NSUInteger kLinesPerFrame = 4;
// Lines get views this far outside the view, in its heights, and keep them a little further out.
static const CGFloat kSightBehind = 0.5, kSightAhead = 0.5, kSightSlack = 0.25;
// One set of lines crossfading over the last.
static const NSTimeInterval kSwapFade = 0.35;
// A paused or held clock draws nothing new: once nothing has moved for this long, the link stops until something does.
static const CFTimeInterval kCalmAfter = 1.5;
// After scrolling by hand, how long until the lines follow the song again (the lyrics page's).
static const NSTimeInterval kBrowseHold = 3;

// When each line is sung, and a pause long enough for the dots with the line after it.
typedef struct {
    NSInteger start, end;
} SGVSpan;
typedef struct {
    NSInteger start, end, line;
} SGVBreak;

@interface SGVLockLyrics () <UIScrollViewDelegate>
@end

@implementation SGVLockLyrics {
    UIScrollView *_scroll;   // offset 0 while following the song; scrolled by hand while browsing
    UIView *_stack;
    BOOL _browsing;
    NSUInteger _browse;
    CGFloat _dragFrom;   // the offset a drag began at
    CAGradientLayer *_fade;
    NSArray<SGKaraokeLine *> *_lines;
    SGKaraokeStyle *_style;
    UIFont *_font;
    CGFloat _gap, _blurPerLine, _maxBlur;
    NSInteger _delay;
    BOOL _sweepsEstimates;
    uint16_t _tag;
    SGVSpan *_spans;
    SGVBreak *_breaks;
    NSUInteger _breakCount;
    NSArray<NSNumber *> *_tops;   // where each line starts in the stack, for _builtWidth
    CGFloat _builtWidth;
    NSUInteger _measure;
    NSMutableDictionary<NSNumber *, SGKaraokeLineView *> *_shown;
    NSInteger _sung[kMostSung];
    NSUInteger _sungCount;
    NSInteger _focus, _openBreak, _dotsLine;
    CGFloat _focusTop;
    SGKaraokeBreakView *_dots;
    NSInteger _clockMs;
    double _clockSpeed;
    BOOL _clockPlaying, _held, _suspended, _available;
    uint16_t _clockTag;
    CFTimeInterval _clockAt, _stirredAt;
    double _heldMs;
    CADisplayLink *_link;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.userInteractionEnabled = NO;
    _scroll = [[UIScrollView alloc] initWithFrame:self.bounds];
    _scroll.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    _scroll.showsVerticalScrollIndicator = _scroll.showsHorizontalScrollIndicator = NO;
    _scroll.alwaysBounceVertical = YES;
    _scroll.delegate = self;
    [self addSubview:_scroll];
    _stack = [[UIView alloc] initWithFrame:self.bounds];
    [_scroll addSubview:_stack];
    [self addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tapped:)]];
    // The lines fade out at the top and the bottom, as the lyrics page's do.
    _fade = [CAGradientLayer layer];
    _fade.colors = @[(id)UIColor.clearColor.CGColor, (id)UIColor.blackColor.CGColor, (id)UIColor.blackColor.CGColor, (id)UIColor.clearColor.CGColor];
    _fade.locations = @[@0, @(SGKaraokeEdgeFade), @(1 - SGKaraokeEdgeFade), @1];
    self.layer.mask = _fade;
    _shown = [NSMutableDictionary dictionary];
    _focus = _openBreak = _dotsLine = -1;
    _clockMs = -1;
    return self;
}

- (void)dealloc {
    free(_spans);
    free(_breaks);
}

#pragma mark - the lines


// A number of the file, or nil for anything else: it is read whole, and what it holds is checked before it is used.
static NSNumber *numberIn(id value) {
    return [value isKindOfClass:NSNumber.class] ? value : nil;
}

- (BOOL)takeFile:(NSString *)path {
    // Read through one handle and never past the cap SpringBoard copies to (kSGLockLyricsMostBytes): a larger file is
    // not read whole into MediaRemoteUI, whatever it was when it was looked at.
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:path];
    NSData *data = [handle readDataUpToLength:kSGLockLyricsMostBytes + 1 error:nil];
    [handle closeFile];
    if (data.length > kSGLockLyricsMostBytes) return NO;
    NSDictionary *content = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (![content isKindOfClass:NSDictionary.class]) return NO;
    NSArray<SGKaraokeLine *> *lines = SGKaraokeLinesFromPlist(content[@"lines"]);
    NSDictionary *look = [content[@"look"] isKindOfClass:NSDictionary.class] ? content[@"look"] : @{};
    NSNumber *tag = numberIn(content[@"tag"]);
    if (!lines.count || !tag) return NO;
    [self dropLinesFading:_lines != nil];
    _lines = lines;
    _tag = (uint16_t)tag.unsignedIntegerValue;
    [self takeLook:look];
    [self timeLines];
    _held = NO;
    [self measure];
    [self checkAvailable];
    return YES;
}

- (void)clear {
    if (!_lines) return;
    [self dropLinesFading:YES];
    _lines = nil;
    _tag = 0;
    [self checkAvailable];
}

// The lyrics page's look, as Spotify wrote it (SGLyricsLookPlist): the size, the room between lines, the blur, the glow
// and the wave, the texts shown and in what order, the Latin letters and the delay.
- (void)takeLook:(NSDictionary *)look {
    // Each held to the Lyrics page's ranges, copied here as the add-on has no settings of its own: LyricsLook.m's kLeast and
    // kMost for the look, LyricsSettings.m's Delay slider for the delay. A missing or strange one takes Apple Music's.
    double (^value)(NSString *, double, double, double) = ^double(NSString *key, double fallback, double least, double most) {
        NSNumber *number = numberIn(look[key]);
        double read = number ? number.doubleValue : fallback;
        return isfinite(read) ? MAX(least, MIN(most, read)) : fallback;
    };
    CGFloat size = value(@"size", 30, 22, 40), blur = value(@"blur", 1, 0, 2);
    _gap = value(@"spacing", 24, 12, 40);
    _blurPerLine = SGKaraokeBlurPerLine * blur;
    _maxBlur = SGKaraokeMaxBlur * blur;
    SGKaraokeSetGlowAndWave(value(@"glow", 1, 0, 2), value(@"wave", 1, 0, 2));
    _delay = (NSInteger)value(@"delay", 0, 0, 1000);
    _sweepsEstimates = numberIn(look[@"sweepsEstimates"]).boolValue;
    BOOL hasSpoken = NO, hasTranslation = NO;
    for (SGKaraokeLine *line in _lines) {
        hasSpoken = hasSpoken || line.pronunciation || line.backing.pronunciation;
        hasTranslation = hasTranslation || line.translation.length;
    }
    BOOL romanised = numberIn(look[@"romanised"]).boolValue, replace = romanised && numberIn(look[@"romanisedReplace"]).boolValue;
    // The three texts, each once, as SGKaraokeText values; anything else and the order is Apple Music's.
    NSArray *order = @[@(SGKaraokeTextLyrics), @(SGKaraokeTextPronunciation), @(SGKaraokeTextTranslation)];
    NSArray *given = [look[@"order"] isKindOfClass:NSArray.class] ? look[@"order"] : nil;
    if (given.count == 3 && [[NSSet setWithArray:given] isEqualToSet:[NSSet setWithArray:order]]) order = given;
    _style = [[SGKaraokeStyle alloc] initWithSize:size order:order pronunciation:!replace && hasSpoken && numberIn(look[@"pronunciation"]).boolValue
                                      translation:hasTranslation && numberIn(look[@"translation"]).boolValue romanised:romanised && !replace];
    _style.japanese = numberIn(look[@"japanese"]).boolValue;
    _style.romanisedReplace = replace;
    _font = [UIFont systemFontOfSize:size weight:UIFontWeightBold];
}

// When each line is sung and where the breaks are, as the lyrics page works them out.
- (void)timeLines {
    free(_spans);
    free(_breaks);
    NSUInteger count = _lines.count;
    _spans = calloc(count + 1, sizeof(SGVSpan));
    _breaks = calloc(count + 1, sizeof(SGVBreak));
    _breakCount = 0;
    NSInteger sungTo = 0;   // the top of the song counts as where the singing before the first line ends
    for (NSUInteger i = 0; i < count; i++) {
        SGKaraokeLine *line = _lines[i];
        _spans[i] = (SGVSpan){line.start, SGKaraokeSungEnd(line)};
        if (line.start - sungTo >= SGKaraokeBreakMinMs) _breaks[_breakCount++] = (SGVBreak){sungTo, line.start, (NSInteger)i};
        sungTo = MAX(sungTo, _spans[i].end);
    }
}

// The lines shown let go, faded out where they are when `fading`; a new set comes in over them.
- (void)dropLinesFading:(BOOL)fading {
    UIView *leaving = _stack;
    _stack = [[UIView alloc] initWithFrame:self.bounds];
    [_scroll insertSubview:_stack aboveSubview:leaving];
    _browsing = NO;
    _browse++;
    _scroll.contentOffset = CGPointZero;
    if (fading && leaving.subviews.count) {
        _stack.alpha = 0;
        [UIView animateWithDuration:kSwapFade animations:^{
            leaving.alpha = 0;
            self->_stack.alpha = 1;
        } completion:^(BOOL finished) { [leaving removeFromSuperview]; }];
    } else {
        [leaving removeFromSuperview];
    }
    [_shown removeAllObjects];
    _dots = nil;
    _tops = nil;
    _builtWidth = 0;
    _sungCount = 0;
    _focus = _openBreak = _dotsLine = -1;
    _measure++;
}

// The song measured for the width off the main thread, as the lyrics page measures it, then placed.
- (void)measure {
    CGFloat width = self.bounds.size.width - 2 * SGKaraokeMargin;
    if (!_lines || width <= 0) return;
    NSArray<SGKaraokeLine *> *lines = _lines;
    SGKaraokeStyle *style = _style;
    CGFloat gap = _gap, built = self.bounds.size.width;
    NSUInteger measure = ++_measure;
    __weak SGVLockLyrics *weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray<NSNumber *> *tops = SGKaraokeLineTops(lines, width, style, gap);
        dispatch_async(dispatch_get_main_queue(), ^{
            SGVLockLyrics *view = weakSelf;
            if (!view || view->_measure != measure) return;
            view->_tops = tops;
            view->_builtWidth = built;
            [view stir];
        });
    });
}

- (void)layoutSubviews {
    [super layoutSubviews];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _fade.frame = self.bounds;
    [CATransaction commit];
    _scroll.frame = self.bounds;
    _scroll.contentSize = self.bounds.size;
    // The stacks, the one shown and one fading out, are plain views; the scroll view's own are not touched.
    for (UIView *sub in _scroll.subviews) if (sub.class == UIView.class) sub.frame = self.bounds;
    if (_lines && self.bounds.size.width != _builtWidth && self.bounds.size.width > 0) {
        for (SGKaraokeLineView *view in _shown.allValues) [view removeFromSuperview];
        [_shown removeAllObjects];
        [_dots removeFromSuperview];
        _dots = nil;
        _dotsLine = -1;
        _sungCount = 0;
        _focus = _openBreak = -1;
        _builtWidth = self.bounds.size.width;
        [self measure];
    }
}

#pragma mark - the clock

// SGLockLyricsClock's fields: the position in ms, the speed in thousandths, playing, and the song's tag.
- (void)setClockState:(uint64_t)state {
    _clockMs = (NSInteger)(state & 0xFFFFFFFF);
    _clockSpeed = ((state >> 32) & 0xFFFF) / 1000.0 ?: 1;
    _clockPlaying = (state >> 48) & 1;
    _clockTag = (uint16_t)((state >> 49) & 0x7FFF);
    _clockAt = CACurrentMediaTime();
    // The next song's clock comes before its lines: the last song's stay held until they do.
    if (_clockTag == _tag) _held = NO;
    [self checkAvailable];
    [self stir];
}

- (void)hold {
    _heldMs = [self songMs];
    _held = YES;
    [self checkAvailable];
}

// Where the song is now, as the lines are timed against it: the clock run on since it was heard, less the delay. A
// clock of another song holds the lines where they were.
- (double)songMs {
    if (_clockMs < 0 && !_held) return -1;
    if (_held || _clockTag != _tag) return _heldMs;
    return _clockMs + (_clockPlaying ? (CACurrentMediaTime() - _clockAt) * 1000 * _clockSpeed : 0) - _delay;
}

- (BOOL)running {
    return _clockPlaying && !_held && _clockTag == _tag;
}

- (void)checkAvailable {
    // Held, the last song's lines stay up while the next one's come.
    BOOL available = _lines.count && _tag && (_clockTag == _tag || _held);
    if (available == _available) return;
    _available = available;
    if (self.availabilityChanged) self.availabilityChanged();
}

- (BOOL)available {
    return _available;
}

#pragma mark - the link

- (void)setSuspended:(BOOL)suspended {
    if (_suspended == suspended) return;
    _suspended = suspended;
    if (suspended) [self stopLink];
    else [self stir];
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (self.window) [self stir];
    else [self stopLink];
}

// Something moved: the link runs until it has been still for a while.
- (void)stir {
    _stirredAt = CACurrentMediaTime();
    if (_suspended || !self.window || !_lines) return;
    if (!_link) {
        _link = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick)];
        // Not capped at 60: a cap held the system's own 120 Hz animations down with it in Spotify.
        if (@available(iOS 15.0, *)) _link.preferredFrameRateRange = CAFrameRateRangeMake(30, 120, 60);
        [_link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    }
    _link.paused = NO;
}

- (void)stopLink {
    [_link invalidate];
    _link = nil;
}

- (void)tick {
    if (!_tops) return;
    double now = [self songMs];
    if (now < 0) return;
    if (!_held && _clockTag == _tag) _heldMs = now;   // where a hold, or another song's clock, will keep the lines
    [self arrangeAt:now];
    for (NSUInteger i = 0; i < _sungCount; i++) [_shown[@(_sung[i])] showTime:now];
    CFTimeInterval frame = _link ? _link.targetTimestamp : CACurrentMediaTime();
    if (_dots.superview) [_dots showTime:now running:[self running] at:frame];
    if (![self running] && CACurrentMediaTime() - _stirredAt > kCalmAfter) _link.paused = YES;
}

#pragma mark - placing

- (CGFloat)breakRoom {
    return ceil(_font.lineHeight) + _gap;
}

- (CGFloat)topOfLine:(NSInteger)index {
    CGFloat top = self.bounds.size.height * SGKaraokeAnchor + _tops[index].doubleValue - _focusTop;
    return _openBreak >= 0 && index >= _openBreak ? top + [self breakRoom] : top;
}

- (BOOL)isSung:(NSInteger)index {
    for (NSUInteger i = 0; i < _sungCount; i++) {
        if (_sung[i] == index) return YES;
    }
    return NO;
}

// How many lines away from what is sung a line is, which is what dims, shrinks and blurs it.
- (NSInteger)distanceOf:(NSInteger)index {
    if (_openBreak >= 0) return index >= _openBreak ? index - _openBreak + 1 : _openBreak - index;
    if (!_sungCount) return labs(index - _focus);
    NSInteger nearest = NSIntegerMax;
    for (NSUInteger i = 0; i < _sungCount; i++) nearest = MIN(nearest, labs(index - _sung[i]));
    return nearest;
}

// What is sung at `now`, as the lyrics page reads it: each line from its start until it is sung out, the last line
// begun on through the pause after it, and a break's dots in place of the lines until the moment before it ends.
- (NSUInteger)sungAt:(double)now into:(NSInteger *)sung focus:(NSInteger *)focus openBreak:(NSInteger *)openBreak {
    NSInteger count = (NSInteger)_lines.count, last = -1;
    while (last + 1 < count && _spans[last + 1].start <= now) last++;
    *openBreak = -1;
    NSInteger breakLine = -1;
    for (NSUInteger i = 0; i < _breakCount; i++) {
        SGVBreak pause = _breaks[i];
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

- (void)arrangeAt:(double)now {
    NSInteger sung[kMostSung], focus, openBreak;
    NSUInteger count = [self sungAt:now into:sung focus:&focus openBreak:&openBreak];
    if (focus == _focus && openBreak == _openBreak && count == _sungCount && !memcmp(sung, _sung, count * sizeof(NSInteger))) {
        [self showLinesInSight];
        return;
    }
    for (NSUInteger i = 0; i < _sungCount; i++) {
        BOOL still = NO;
        for (NSUInteger j = 0; j < count; j++) still = still || sung[j] == _sung[i];
        if (!still) _shown[@(_sung[i])].active = NO;
    }
    BOOL first = _focus < 0 && !_sungCount;
    for (NSUInteger j = 0; j < count; j++) {
        if (![self isSung:sung[j]]) [self viewForLine:sung[j]].active = YES;
    }
    BOOL jump = first || labs(focus - _focus) > 2;   // a seek or a new song, not the song moving on
    memcpy(_sung, sung, count * sizeof(NSInteger));
    _sungCount = count;
    _focus = focus;
    _openBreak = openBreak;
    [self stir];
    [self placeLinesAnimated:!jump];
}

- (void)placeLinesAnimated:(BOOL)animated {
    // Scrolled by hand, the stack stands still; the lines sung still light up, and it is placed again as it follows.
    if (_browsing || !_tops.count) return;
    _focusTop = _tops[(NSUInteger)MAX(_focus, 0)].doubleValue;
    [self showLinesInSight];
    for (NSNumber *key in _shown) [self placeLine:_shown[key] at:key.integerValue animated:animated];
    [self placeBreak];
    // Room to scroll until the first line or the last one reaches the anchor.
    CGFloat lastTop = _tops.lastObject.doubleValue + (_openBreak >= 0 ? [self breakRoom] : 0);
    _scroll.contentInset = UIEdgeInsetsMake(_focusTop, 0, MAX(0, lastTop - _focusTop), 0);
}

// One line's place: on the edge its text is aligned to, so it scales toward its own text, dimmed and blurred with its
// distance from what is sung; the lines below the anchor follow a beat later, the further down the later.
- (void)placeLine:(SGKaraokeLineView *)view at:(NSInteger)index animated:(BOOL)animated {
    CGFloat height = self.bounds.size.height, margin = SGKaraokeMargin;
    NSInteger distance = [self distanceOf:index], below = index - _focus;
    CGRect frame = CGRectMake(margin, [self topOfLine:index], view.bounds.size.width, view.bounds.size.height);
    CGPoint center = CGPointMake(view.right ? CGRectGetMaxX(frame) : margin, CGRectGetMidY(frame));
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
                        options:UIViewAnimationOptionBeginFromCurrentState
                     animations:^{
        view.center = center;
        view.transform = transform;
    } completion:nil];
}

- (SGKaraokeLineView *)viewForLine:(NSInteger)index {
    __block SGKaraokeLineView *view = _shown[@(index)];
    if (view || !_tops || index < 0 || index >= (NSInteger)_lines.count) return view;
    [UIView performWithoutAnimation:^{
        view = [[SGKaraokeLineView alloc] initWithLine:self->_lines[index] width:self->_builtWidth - 2 * SGKaraokeMargin style:self->_style
                                                 under:nil blurred:self->_maxBlur > 0 sweepsEstimates:self->_sweepsEstimates];
        [self->_stack addSubview:view];
        self->_shown[@(index)] = view;
        [self placeLine:view at:index animated:NO];
    }];
    return view;
}

// Views for the lines in the view and just outside it; the ones further off are let go, a few made a frame.
- (void)showLinesInSight {
    if (!_tops.count) return;
    CGFloat height = self.bounds.size.height, offset = _scroll.contentOffset.y;
    CGFloat from = offset - kSightBehind * height, to = offset + (1 + kSightAhead) * height, slack = kSightSlack * height;
    NSMutableArray<NSNumber *> *gone = [NSMutableArray array];
    for (NSNumber *key in _shown) {
        NSInteger index = key.integerValue;
        CGFloat top = [self topOfLine:index], bottom = top + _shown[key].bounds.size.height;
        if (![self isSung:index] && (bottom < from - slack || top > to + slack)) [gone addObject:key];
    }
    for (NSNumber *key in gone) {
        [_shown[key] removeFromSuperview];
        [_shown removeObjectForKey:key];
    }
    NSInteger count = (NSInteger)_lines.count;
    NSUInteger made = 0;
    // Outward from the line sung, so the lines nearest it come first.
    NSInteger focus = MAX(_focus, 0);
    for (NSInteger step = 0; step < count * 2 && made < kLinesPerFrame; step++) {
        NSInteger index = focus + (step % 2 ? (step + 1) / 2 : -(step / 2));
        if (index < 0 || index >= count || _shown[@(index)]) continue;
        CGFloat top = [self topOfLine:index];
        CGFloat bottom = index + 1 < count ? [self topOfLine:index + 1] - _gap : top + height;
        if (bottom < from || top > to) continue;
        [self viewForLine:index];
        made++;
    }
    if (made == kLinesPerFrame) [self stir];   // the rest on the next frames
}

// The dots, at the anchor for as long as a break is open, against the edge the line after it is on.
- (void)placeBreak {
    if (_openBreak < 0) {
        [_dots removeFromSuperview];
        return;
    }
    SGKaraokeLine *after = _lines[(NSUInteger)_openBreak];
    if (_style.romanisedReplace) after = SGLyricsRomanisedLine(after, _style.japanese) ?: after;
    if (!_dots) {
        _dots = [[SGKaraokeBreakView alloc] initWithFont:_font];
        _dotsLine = -1;
    }
    if (_dotsLine != _openBreak) {
        _dots.rightToLeft = SGKaraokeReadsRightToLeft(SGKaraokeLineText(after));
        for (NSUInteger i = 0; i < _breakCount; i++) {
            if (_breaks[i].line == _openBreak) [_dots playFrom:_breaks[i].start to:_breaks[i].end];
        }
        _dotsLine = _openBreak;
    }
    if (_dots.superview != _stack) [_stack addSubview:_dots];
    _dots.right = SGKaraokeAlignsRight(after);
    CGFloat top = [self topOfLine:_openBreak] - [self breakRoom];
    _dots.frame = CGRectMake(SGKaraokeMargin, top, _builtWidth - 2 * SGKaraokeMargin, _dots.bounds.size.height);
}

#pragma mark - by hand

- (void)scrollViewWillBeginDragging:(UIScrollView *)scrollView {
    _browsing = YES;
    _browse++;
    for (SGKaraokeLineView *view in _shown.allValues) view.blur = 0;
    [self stir];
}

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    if (_browsing) [self showLinesInSight];
}

- (void)scrollViewDidEndDragging:(UIScrollView *)scrollView willDecelerate:(BOOL)decelerate {
    if (!decelerate) [self holdBrowsing];
}

- (void)scrollViewDidEndDecelerating:(UIScrollView *)scrollView {
    [self holdBrowsing];
}

// The lines stay where the finger left them for kBrowseHold, then go back to the line sung.
- (void)holdBrowsing {
    NSUInteger browse = ++_browse;
    __weak SGVLockLyrics *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kBrowseHold * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        SGVLockLyrics *view = weakSelf;
        if (!view || view->_browse != browse || view->_scroll.isTracking || view->_scroll.isDecelerating) return;
        [view followAgain];
    });
}

- (void)followAgain {
    if (!_browsing) return;
    _browsing = NO;
    _browse++;
    [UIView animateWithDuration:0.7 delay:0 usingSpringWithDamping:0.86 initialSpringVelocity:0
                        options:UIViewAnimationOptionBeginFromCurrentState animations:^{
        self->_scroll.contentOffset = CGPointZero;
    } completion:nil];
    [self placeLinesAnimated:YES];
    [self stir];
}

// A drag handed in, as a finger on the scroll view would scroll it: past the first or last line, a third as far.
- (void)dragBegan {
    [self.layer removeAllAnimations];
    [_scroll.layer removeAllAnimations];
    [self scrollViewWillBeginDragging:_scroll];
    _dragFrom = _scroll.contentOffset.y;
}

- (CGFloat)clampedOffset:(CGFloat)offset rubber:(BOOL)rubber {
    CGFloat least = -_scroll.contentInset.top, most = _scroll.contentInset.bottom;
    if (offset < least) return rubber ? least - (least - offset) / 3 : least;
    if (offset > most) return rubber ? most + (offset - most) / 3 : most;
    return offset;
}

- (void)dragTo:(CGFloat)translation {
    if (!_browsing) [self dragBegan];
    _scroll.contentOffset = CGPointMake(0, [self clampedOffset:_dragFrom - translation rubber:YES]);
}

// Let go, the lines glide on with the finger's speed and settle inside the song, as a scroll view's deceleration does.
- (void)dragEndedWithVelocity:(CGFloat)velocity {
    if (!_browsing) return;
    CGFloat target = [self clampedOffset:_scroll.contentOffset.y - velocity * 0.35 rubber:NO];
    [UIView animateWithDuration:0.6 delay:0 options:UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionBeginFromCurrentState
                     animations:^{ self->_scroll.contentOffset = CGPointMake(0, target); }
                     completion:^(BOOL finished) {
        [self showLinesInSight];
        [self holdBrowsing];
    }];
}

- (void)tapped:(UITapGestureRecognizer *)tap {
    [self tapAt:[tap locationInView:self]];
}

// A tap on a line seeks the song to its start, as the lyrics page's does: the clock is set there at once, and Spotify
// told to follow.
- (void)tapAt:(CGPoint)tapped {
    CGPoint point = [self convertPoint:tapped toView:_stack];
    for (NSNumber *key in _shown) {
        SGKaraokeLineView *view = _shown[key];
        if (!CGRectContainsPoint(CGRectInset(view.frame, -SGKaraokeMargin, -_gap / 2), point)) continue;
        NSInteger position = view.line.start + _delay;
        _clockMs = position;
        _clockAt = CACurrentMediaTime();
        _held = NO;
        if (self.seek) self.seek(position);
        [self followAgain];
        [self stir];
        return;
    }
}

@end
