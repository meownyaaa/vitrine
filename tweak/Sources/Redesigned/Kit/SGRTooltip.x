// Redesign, iOS < 26: Spotify's tooltips ("You can ask people to join the Jam on your phone", "Listening on this
// iPhone") on glass.
//
// Tree: a Messaging_TooltipPresenterImpl.PassthroughView over the now playing bar, holding a
// TooltipContainerView {390 wide}. In it, the arrow first: a white UIView, a 9pt square turned 45 degrees (12.7pt across its
// frame), centred on the card's bottom edge at the x of the control it points to. Then the card: a UIView #FFFFFF r=8 clips,
// with a SwiftUI hosting view in it, whose _UIGraphicsView is white as well and whose text is drawn by CGDrawingViews
// (black), with the action ("Got it") drawn the same way and, on some, a Lottie play indicator.
//
// The card is dressed the way the toasts are (Kit/SGRSnackbar.x): its white goes, a glass pane and the faint white film
// stand behind the content, the corners are a capsule's (up to kMaxRadius), and the black text turns white (Kit/SGRDrawnText.h).
// The arrow is white and would stay a white diamond on a glass card, so it is cleared and a small glass tail of the same
// material is made in its place, on the card's edge at the arrow's x. The tail is a pane with a triangle for a mask, so
// the film and the glass are cut to the same shape and its top lies 1pt inside the card, which leaves no seam.
//
// Over the now playing bar the tooltip follows it: in the minimized tab bar the bar moves down into the row by a transform
// Spotify does not know (NowPlayingBar.x), and the tooltip, laid out for the bar's usual place, hung in the air above
// nothing. The whole container moves by the bar's shift, in the tab bar's animation, as the toasts' card does
// (Kit/SGRSnackbar.x). Only a tooltip that stands over the bar moves, so one pointing at something else stays where it is.
//
// Spotify's own sizes are kept: the card is the width SwiftUI laid it out for. The pass runs from the container's layout
// and again a moment later, in case SwiftUI draws the text or paints the white back after it.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Redesigned/NowPlayingBar/NowPlayingBar.h"

static const CGFloat kMaxRadius = 28;
// The tail: how wide it is at the card's edge and how far it stands out from it, and how far it lies under the card.
static const CGFloat kTailWidth = 18, kTailHeight = 8, kTailOverlap = 1;

// The tooltips on screen, for the tab bar's minimize to move.
static NSHashTable<UIView *> *sg_tooltips;

static char kGlassKey, kFilmKey, kTailKey, kTailGlassKey, kTailFilmKey, kTailMaskKey, kTailBelowKey;

// The card is the container's biggest subview and the arrow its small one; what the mod adds (the tail) is neither.
static void partsOf(UIView *container, UIView **card, UIView **arrow) {
    *card = nil;
    *arrow = nil;
    UIView *tail = objc_getAssociatedObject(container, &kTailKey);
    for (UIView *sub in container.subviews) {
        if (sub == tail) continue;
        CGSize size = sub.bounds.size;
        if (size.width < 1 || size.height < 1) continue;
        if (!*card || size.width * size.height > (*card).bounds.size.width * (*card).bounds.size.height) *card = sub;
    }
    for (UIView *sub in container.subviews) {
        CGSize size = sub.bounds.size;
        if (sub == tail || sub == *card || size.width < 1 || size.height < 1) continue;
        // The arrow's frame is the box of the turned square: 12.7pt, never more than a couple of dozen.
        if (size.width <= 24 && size.height <= 24) *arrow = sub;
    }
}

static void dressTail(UIView *container, UIView *card, UIView *arrow, CGFloat radius) {
    UIView *tail = SGLazyChild(container, &kTailKey, ^UIView *{
        UIView *view = [UIView new];
        view.userInteractionEnabled = NO;
        return view;
    });
    if (tail.superview != container) [container insertSubview:tail belowSubview:card];

    // The arrow's x, kept off the card's corners; on the side of the card it was on.
    BOOL below = CGRectGetMidY(arrow.frame) >= CGRectGetMidY(card.frame);
    CGFloat minX = CGRectGetMinX(card.frame) + radius + kTailWidth / 2;
    CGFloat maxX = CGRectGetMaxX(card.frame) - radius - kTailWidth / 2;
    CGFloat midX = maxX >= minX ? MAX(minX, MIN(maxX, CGRectGetMidX(arrow.frame))) : CGRectGetMidX(card.frame);
    CGFloat y = below ? CGRectGetMaxY(card.frame) - kTailOverlap : CGRectGetMinY(card.frame) - kTailHeight;
    CGRect frame = CGRectMake(round(midX - kTailWidth / 2), round(y), kTailWidth, kTailHeight + kTailOverlap);
    if (!CGRectEqualToRect(tail.frame, frame)) tail.frame = frame;

    UIView *glass = SGGlassFor(tail, &kTailGlassKey);
    if (glass.overrideUserInterfaceStyle != UIUserInterfaceStyleDark) glass.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    if (!CGRectEqualToRect(glass.frame, tail.bounds)) glass.frame = tail.bounds;
    SGShapeGlass(glass, 0, NO);
    SGRGlassFilm(tail, &kTailFilmKey, glass, 0);

    // The triangle's base is on the card's side, its tip away from it. Kept as the mask's own layer, so a pass sets the path
    // again only when the tail's size or side has changed.
    CAShapeLayer *mask = objc_getAssociatedObject(tail, &kTailMaskKey);
    if (!mask) {
        mask = [CAShapeLayer layer];
        mask.fillColor = UIColor.whiteColor.CGColor;
        tail.layer.mask = mask;
        objc_setAssociatedObject(tail, &kTailMaskKey, mask, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    NSNumber *shown = objc_getAssociatedObject(tail, &kTailBelowKey);
    if (!CGRectEqualToRect(mask.frame, tail.bounds) || !shown || shown.boolValue != below) {
        CGSize size = tail.bounds.size;
        UIBezierPath *path = [UIBezierPath bezierPath];
        [path moveToPoint:CGPointMake(0, below ? 0 : size.height)];
        [path addLineToPoint:CGPointMake(size.width, below ? 0 : size.height)];
        [path addLineToPoint:CGPointMake(size.width / 2, below ? size.height : 0)];
        [path closePath];
        mask.frame = tail.bounds;
        mask.path = path.CGPath;
        objc_setAssociatedObject(tail, &kTailBelowKey, @(below), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

// The card where it stands without the container's own transform, in the window: what decides if it is over the bar.
static CGRect untransformedCard(UIView *container, UIView *card) {
    if (!container.superview) return CGRectNull;
    CGPoint origin = CGPointMake(container.center.x - container.bounds.size.width / 2, container.center.y - container.bounds.size.height / 2);
    CGRect inParent = CGRectOffset(card.frame, origin.x - container.bounds.origin.x, origin.y - container.bounds.origin.y);
    return [container.superview convertRect:inParent toView:nil];
}

static void followNowPlayingBar(UIView *container) {
    UIView *card = nil, *arrow = nil;
    partsOf(container, &card, &arrow);
    if (!card) return;
    // Spotify's own move of the tooltip runs to its end: a transform written under it would cut it short.
    for (NSString *key in container.layer.animationKeys) {
        if ([key containsString:@"transform"]) return;
    }
    CGAffineTransform move = CGAffineTransformMakeTranslation(0, SGRNowPlayingBarShiftOver(untransformedCard(container, card), container.window));
    if (!CGAffineTransformEqualToTransform(container.transform, move)) container.transform = move;
}

void SGRTooltipFollowNowPlayingBar(void) {
    for (UIView *container in sg_tooltips.allObjects) {
        if (container.window) followNowPlayingBar(container);
    }
}

static void dressTooltip(UIView *container) {
    if (container.bounds.size.width < 1 || container.bounds.size.height < 1) return;
    UIView *card = nil, *arrow = nil;
    partsOf(container, &card, &arrow);
    if (!card) return;

    UIView *glass = SGRGlassFloatingCard(card, &kGlassKey, &kFilmKey, kMaxRadius);
    UIView *film = objc_getAssociatedObject(card, &kFilmKey);

    // What SwiftUI put in the card: its white goes, its text turns white. The glass and the film are the mod's.
    for (UIView *sub in card.subviews) {
        if (sub == glass || sub == film) continue;
        SGRClearHostedFill(sub);
        SGRLightenDrawnText(sub);
    }

    if (arrow) {
        // The white diamond is only a fill; clearing it leaves it in place for whatever Spotify does with its frame.
        if (arrow.layer.backgroundColor) arrow.layer.backgroundColor = NULL;
        dressTail(container, card, arrow, card.layer.cornerRadius);
    }

    if (!sg_tooltips) sg_tooltips = [NSHashTable weakObjectsHashTable];
    [sg_tooltips addObject:container];
    followNowPlayingBar(container);

    static dispatch_once_t once;
    dispatch_once(&once, ^{ SGLog(@"tooltip: glass over a card of %@", NSStringFromCGRect(card.bounds)); });
}

static void dressAfterSettling(UIView *container) {
    SGRRepeatViewPass(container, @[@0.0, @0.25], ^(UIView *v) { dressTooltip(v); });
}

%group SGRTooltipGlass
%hook SGRTooltipContainer
- (void)layoutSubviews {
    %orig;
    dressTooltip((UIView *)self);
}

- (void)didMoveToWindow {
    %orig;
    UIView *container = (UIView *)self;
    if (!container.window) return;
    dressTooltip(container);
    dressAfterSettling(container);
}
%end
%end

%ctor {
    if (!SGRedesignedUI()) return;
    if (!SGBelowiOS26()) return;
    Class container = SGRSwiftClass(@"Messaging_TooltipPresenterImpl", @"TooltipContainerView");
    if (container) {
        %init(SGRTooltipGlass, SGRTooltipContainer = container);
    } else {
        SGLog(@"class Messaging_TooltipPresenterImpl.TooltipContainerView not found, tooltips keep Spotify's white card");
    }
}
