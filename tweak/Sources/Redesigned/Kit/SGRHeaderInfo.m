// The header's text and controls, the redesign's own. Laid out top down from where the content has to start
// for its bottom to sit SGRHeaderInfoBottom above the view's.
#import "Core/SGCore.h"
#import "SGRHeaderInfo.h"
#import "SGRActionRow.h"
#import "SGRRestyle.h"
#import "SGRTokens.h"

const CGFloat SGRHeaderInfoBottom = 14;
const CGFloat SGRHeaderInfoTitleRise = 56;

BOOL SGRFullBleedCovers(void) {
    static BOOL on;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ on = SGEnabled(SGRKeyFullBleedCovers); });
    return on;
}

// The text kSide in from the edges; Play at least kPlayWidth wide, the Music app's; the gaps between.
static const CGFloat kSide = 20, kPlayWidth = 148, kRowSpacing = 16, kRowAbove = 16, kAboutAbove = 14;

static UILabel *infoLabel(UIView *parent, UIFont *font, UIColor *color, NSInteger lines, NSTextAlignment alignment) {
    UILabel *label = [UILabel new];
    label.font = font;
    label.textColor = color;
    label.numberOfLines = lines;
    label.textAlignment = alignment;
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    label.hidden = YES;
    [parent addSubview:label];
    return label;
}

static BOOL setText(UILabel *label, NSString *text) {
    if ([label.text ?: @"" isEqualToString:text ?: @""]) return NO;
    label.text = text;
    label.hidden = text.length == 0;
    return YES;
}

// The most a title picture takes: a share of the text's width, and a height near three lines of the title.
static const CGFloat kLogoWidthShare = 0.8, kLogoMaxHeight = 64;
// Between the creator's picture and the name.
static const CGFloat kPictureGap = 8;

// A face is at least this wide, and square give or take a point.
static const CGFloat kMinFace = 16;

UIImageView *SGRCreatorPicture(UIView *root) {
    if (!root) return nil;
    // The faces of a facepile overlap, the leading one first to the eye.
    BOOL rtl = root.effectiveUserInterfaceLayoutDirection == UIUserInterfaceLayoutDirectionRightToLeft;
    __block UIImageView *found = nil;
    __block CGFloat edge = 0;
    SGForEachView(root, ^(UIView *v) {
        CGSize size = v.bounds.size;
        if (![v isKindOfClass:UIImageView.class] || size.width < kMinFace || fabs(size.width - size.height) > 1) return;
        CGFloat x = [v convertPoint:CGPointMake(rtl ? size.width : 0, 0) toView:root].x;
        if (!found || (rtl ? x > edge : x < edge)) found = (UIImageView *)v, edge = x;
    });
    return found;
}

@implementation SGRHeaderInfo {
    UILabel *_title, *_creator, *_length, *_about;
    UIImageView *_logo;
    UIImageView *_picture;   // the creator's, round, before the name
    __weak UIImageView *_pictureSource;
    UIImage *_titleImage;   // what the title's place is laid out for; the logo keeps its picture while it fades out
    SGRMirrorButton *_shuffle, *_trailing;
    SGRPlayCapsule *_play;
    __weak UIView *_creatorLink;
    // contentHeightForWidth:'s last answer, for _measuredWidth; a negative width is none. Cleared when the text or
    // the title picture changes, the only things it measures.
    CGFloat _measuredWidth, _measuredHeight;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    _measuredWidth = -1;
    _title = infoLabel(self, SGRFont(UIFontTextStyleTitle2, UIFontWeightBold, UIContentSizeCategoryExtraLarge),
                       SGRPrimary(), 2, NSTextAlignmentCenter);
    _title.accessibilityTraits = UIAccessibilityTraitHeader;
    _creator = infoLabel(self, SGRFont(UIFontTextStyleBody, UIFontWeightRegular, UIContentSizeCategoryExtraLarge),
                         SGRSecondary(), 1, NSTextAlignmentCenter);
    _length = infoLabel(self, SGRFont(UIFontTextStyleFootnote, UIFontWeightRegular, UIContentSizeCategoryExtraLarge),
                        SGRTertiary(), 1, NSTextAlignmentCenter);
    _about = infoLabel(self, SGRFont(UIFontTextStyleFootnote, UIFontWeightRegular, UIContentSizeCategoryExtraLarge),
                       SGRSecondary(), 2, NSTextAlignmentNatural);
    _picture = [UIImageView new];
    _picture.contentMode = UIViewContentModeScaleAspectFill;
    _picture.clipsToBounds = YES;
    _picture.hidden = YES;
    [self addSubview:_picture];

    _shuffle = [[SGRMirrorButton alloc] initWithFrame:CGRectZero];
    _shuffle.fallbackGlyph = [UIImage systemImageNamed:@"shuffle"];
    // White like the buttons beside it while off -- Spotify's off gray read as a disabled button next to the
    // white download (issue #65) -- and the accent while on, so its state still shows.
    _shuffle.glyphColor = SGRPrimary();
    _shuffle.onGlyphColor = SGRAccent();
    _play = [[SGRPlayCapsule alloc] initWithFrame:CGRectZero];
    _play.fillColor = UIColor.whiteColor;
    _trailing = [[SGRMirrorButton alloc] initWithFrame:CGRectZero];
    for (UIView *button in @[_shuffle, _play, _trailing]) {
        button.hidden = YES;
        [self addSubview:button];
    }
    return self;
}

// Touches only for the buttons and, where there is one, the creator line: the rest of the text lets a
// pull or a tap through to the page under it.
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    // The creator label is the width of the view, so the label itself answers a touch well away from the
    // name; both it and the view answer only where the name is drawn.
    if (hit == self || hit == _creator) return [self sgr_creatorHit:point];
    return hit;
}

// The picture often arrives from the network with the page already on screen. There the picture and the
// title cross over, and the block makes room for the picture in one move rather than in a frame, the picture
// growing out of the title's place; out of a window it all happens at once.
- (void)showTitleImage:(UIImage *)image {
    if (_titleImage == image) return;
    if (!_logo) {
        _logo = [UIImageView new];
        _logo.contentMode = UIViewContentModeScaleAspectFit;
        _logo.isAccessibilityElement = YES;
        _logo.accessibilityTraits = UIAccessibilityTraitHeader;
        _logo.alpha = 0;
        [self addSubview:_logo];
    }
    _titleImage = image;
    _measuredWidth = -1;
    _title.accessibilityElementsHidden = image != nil;
    if (image) {
        if (!_logo.image) [UIView performWithoutAnimation:^{ self->_logo.frame = self->_title.frame; }];
        _logo.image = image;
        _logo.hidden = NO;
    }
    [self setNeedsLayout];
    void (^fade)(void) = ^{
        self->_logo.alpha = image ? 1 : 0;
        self->_title.alpha = image ? 0 : 1;
    };
    void (^faded)(BOOL) = ^(BOOL finished) {
        if (self->_titleImage) return;
        self->_logo.image = nil;
        self->_logo.hidden = YES;
    };
    if (!self.window) {
        fade();
        faded(YES);
        return;
    }
    SGRAnimate(SGRMotionFade, fade, faded);
    SGRAnimateLayout(self, ^{ [self layoutIfNeeded]; }, nil);
}

// The space under a line: a picture needs more room under it than a line of text does.
- (CGFloat)sgr_gapAfter:(UILabel *)label {
    if (label == _title && _titleImage) return 8;
    return label == _creator ? 4 : 2;
}

// The title's line: the picture's fitted height where there is a picture, the label's otherwise.
- (CGSize)sgr_sizeOf:(UILabel *)label width:(CGFloat)text {
    if (label != _title || !_titleImage) return [label sizeThatFits:CGSizeMake(text, CGFLOAT_MAX)];
    CGSize image = _titleImage.size;
    if (image.width <= 0 || image.height <= 0) return CGSizeZero;
    CGFloat scale = MIN(text * kLogoWidthShare / image.width, kLogoMaxHeight / image.height);
    return CGSizeMake(round(image.width * scale), round(image.height * scale));
}

- (BOOL)showTitle:(NSString *)title creator:(NSString *)creator length:(NSString *)length about:(NSString *)about {
    BOOL changed = NO;
    changed |= setText(_title, title);
    changed |= setText(_creator, creator);
    changed |= setText(_length, length);
    changed |= setText(_about, about);
    if (changed) {
        _measuredWidth = -1;
        [self setNeedsLayout];
    }
    return changed;
}

// The creator line, tappable. The label is as wide as the view and centered, so the target is narrowed to
// the text itself -- a tap either side of a short name belongs to the page under it, which a pull down
// starts on. Spotify's own control stays concealed where it is and only fires.
- (void)showCreatorLink:(UIView *)control {
    _creatorLink = control;
    BOOL live = control != nil;
    if (_creator.userInteractionEnabled == live) return;
    _creator.userInteractionEnabled = live;
    _creator.accessibilityTraits = live ? UIAccessibilityTraitButton : UIAccessibilityTraitStaticText;
    if (!live || _creator.gestureRecognizers.count) return;
    [_creator addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(sgr_creatorTapped)]];
}

- (void)sgr_creatorTapped {
    SGRActivate(_creatorLink);
}

- (void)showCreatorPicture:(UIImageView *)source {
    if (source != _pictureSource) {
        _pictureSource = source;
        __weak SGRHeaderInfo *weakSelf = self;
        if (source) SGRObserveImage(source, ^(UIImageView *view) {
            SGRHeaderInfo *info = weakSelf;
            if (info && view == info->_pictureSource) [info sgr_takePicture:view.image];
        });
    }
    [self sgr_takePicture:source.image];
}

// The picture fades in where it lands with the page on screen; the name makes room for it in the same move.
- (void)sgr_takePicture:(UIImage *)image {
    if (image == _picture.image) return;
    BOOL appears = image && !_picture.image;
    _picture.image = image;
    _picture.hidden = image == nil;
    [self setNeedsLayout];
    if (!appears || !self.window) return;
    _picture.alpha = 0;
    SGRAnimate(SGRMotionFade, ^{ self->_picture.alpha = 1; }, nil);
    SGRAnimateLayout(self, ^{ [self layoutIfNeeded]; }, nil);
}

// The creator line takes a touch only where its text and its picture are; everything else of the view is the
// page's. The label is laid out at the text's own width (-layoutSubviews).
- (UIView *)sgr_creatorHit:(CGPoint)point {
    if (!_creator.userInteractionEnabled || _creator.hidden) return nil;
    CGRect line = _picture.hidden ? _creator.frame : CGRectUnion(_creator.frame, _picture.frame);
    return CGRectContainsPoint(CGRectInset(line, -8, -6), point) ? _creator : nil;
}

- (void)showShuffle:(UIView *)shuffle play:(UIView *)play trailing:(UIView *)trailing
   trailingFallback:(UIImage *)trailingFallback playColor:(UIColor *)playColor {
    _trailing.fallbackGlyph = trailingFallback;
    if (_trailing.readState != self.trailingState) {
        _trailing.readState = self.trailingState;
        _trailing.stateOffSymbol = self.trailingOffSymbol;
        _trailing.stateOnSymbol = self.trailingOnSymbol;
    }
    if (shuffle) [_shuffle feedFrom:shuffle];
    if (play) {
        if (playColor) _play.contentColor = playColor;
        [_play feedFrom:play];
    }
    // Another of Spotify's buttons in the trailing place (save becoming download once the playlist is saved) is
    // a crossfade, a change of what the button is rather than a move.
    if (trailing && _trailing.source && trailing != _trailing.source && !_trailing.hidden && self.window) {
        [UIView transitionWithView:_trailing duration:SGRCrossfade options:UIViewAnimationOptionTransitionCrossDissolve
                        animations:^{ [self->_trailing feedFrom:trailing]; } completion:nil];
    }
    else if (trailing) [_trailing feedFrom:trailing];

    BOOL changed = NO;
    NSArray<UIView *> *buttons = @[_shuffle, _play, _trailing];
    NSArray<NSNumber *> *shown = @[@(shuffle != nil), @(play != nil), @(trailing != nil)];
    for (NSUInteger i = 0; i < buttons.count; i++) {
        BOOL hide = !shown[i].boolValue;
        if (buttons[i].hidden != hide) {
            buttons[i].hidden = hide;
            changed = YES;
        }
    }
    if (changed) [self setNeedsLayout];
}

- (void)trailingStateChanged {
    if (_trailing.source) [_trailing feedFrom:_trailing.source];
}

- (CGFloat)contentHeightForWidth:(CGFloat)width {
    if (width == _measuredWidth) return _measuredHeight;
    CGFloat text = MAX(0, width - 2 * kSide), height = 0;
    UILabel *previous = nil;
    for (UILabel *label in @[_title, _creator, _length]) {
        if (label.hidden) continue;
        if (previous) height += [self sgr_gapAfter:previous];
        height += ceil([self sgr_sizeOf:label width:text].height);
        previous = label;
    }
    if (previous) height += kRowAbove;
    height += SGRActionHeight;
    if (!_about.hidden) height += kAboutAbove + ceil([_about sizeThatFits:CGSizeMake(text, CGFLOAT_MAX)].height);
    _measuredWidth = width;
    _measuredHeight = height;
    return height;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width = self.bounds.size.width, text = MAX(0, width - 2 * kSide);
    CGFloat content = [self contentHeightForWidth:width];
    CGFloat y = round(self.bounds.size.height - SGRHeaderInfoBottom - content);
    if (self.pinnedTop > 0 && self.pinnedTop + content <= self.bounds.size.height) y = round(self.pinnedTop);
    // No name, no picture: it belongs to the line.
    _picture.hidden = !_picture.image || _creator.hidden;

    UILabel *previous = nil;
    for (UILabel *label in @[_title, _creator, _length]) {
        if (label.hidden) continue;
        if (previous) y += [self sgr_gapAfter:previous];
        CGSize size = [self sgr_sizeOf:label width:text];
        CGFloat height = ceil(size.height);
        label.frame = CGRectMake(kSide, y, text, height);
        // The name at its own width, so a tap beside it is the page's (-sgr_creatorHit:), and before it the
        // picture, a line high so the line keeps its height, the two centered together. The picture leads, so it
        // is on the right in a right-to-left language.
        if (label == _creator) {
            CGFloat picture = _picture.hidden ? 0 : height + kPictureGap;
            CGFloat named = MIN(ceil(size.width), MAX(0, text - picture));
            CGFloat x = round((width - picture - named) / 2);
            BOOL rtl = self.effectiveUserInterfaceLayoutDirection == UIUserInterfaceLayoutDirectionRightToLeft;
            _picture.frame = CGRectMake(rtl ? x + named + kPictureGap : x, y, height, height);
            _picture.layer.cornerRadius = height / 2;
            label.frame = CGRectMake(rtl ? x : x + picture, y, named, height);
        }
        if (label == _title && _titleImage) {
            _logo.frame = CGRectMake(round((width - size.width) / 2), y, size.width, height);
            _logo.accessibilityLabel = _title.text;
        }
        y += height;
        previous = label;
    }
    if (previous) y += kRowAbove;

    // Play on the middle of the page, the other two hung off its sides, so it holds its place whether both
    // are there or not.
    CGFloat side = SGRActionHeight;
    // As wide as its word, short of pushing the other two off the page.
    CGFloat playWidth = MIN(MAX(kPlayWidth, [_play sgr_width]), width - 2 * (kSide + side + kRowSpacing));
    CGRect play = CGRectMake(round((width - playWidth) / 2), y, playWidth, side);
    _play.frame = play;
    _shuffle.frame = CGRectMake(CGRectGetMinX(play) - kRowSpacing - side, y, side, side);
    _trailing.frame = CGRectMake(CGRectGetMaxX(play) + kRowSpacing, y, side, side);
    y += side;

    if (!_about.hidden) {
        y += kAboutAbove;
        _about.frame = CGRectMake(kSide, y, text, ceil([_about sizeThatFits:CGSizeMake(text, CGFLOAT_MAX)].height));
    }
}

@end
