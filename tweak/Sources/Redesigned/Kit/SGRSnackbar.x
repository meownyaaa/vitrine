// Redesign, iOS < 26: Spotify's toasts (Added to Queue, Saved in Liked Songs and the rest) on glass.
//
// Tree: SPTSnackbarView id=SPTSnackbarView {8, 639} 374x50, in the main content view above the
// now playing bar, holding a UIView #FFFFFF r=6 clips (the card), which holds an SPTSnackbarWithActionView
// #FFFFFF around the label (13pt #000000) and, when the toast has an action, an SPTSnackbarTextActionButton
// (id=SPTSnackbarTextButton, "Open" 13pt #19B551).
//
// The card is dressed the way the now playing bar is (Redesigned/NowPlayingBar): its white goes, a glass pane and
// the faint white film that keeps a floating card from sinking into the page stand behind the content, and the
// corners are a capsule's (half the height, up to kMaxRadius for a toast of several lines) instead of Spotify's 6.
// The black text turns white. The action button gets a glass capsule of its own, bigger than the word so it has
// room, and a hit area to match.
//
// 374pt wide the toast ran over the controls at either edge of the page (the buttons of a header, the rows' trailing
// buttons) and left a gap of nothing beside a short label, so the card is as wide as what it holds (the label, the
// action and an even padding), centred in the view and never wider than kSideInset short of either edge. Spotify
// lays the label and the button out for the 374, so the mod places both itself, also when the content lays out again
// (the button's glass ran 26pt past a 342pt card). The strips of the view that are left bare do not take
// touches.
//
// Spotify lays the content out for the 374 again whenever it lays out, whatever size the mod gave it (the content
// 374pt wide in a card of 193, the Open button at x=330 past the card's edge, so it was never seen, and the card first drawn
// for the label alone). So the content is held to the card's size from its own layout, and the action is measured by its
// word, not by a frame Spotify has not given it yet. A frame Spotify sets on the content is held to the card's as well
// (setFrame), so no pass of its own can put the button past the card's edge.
//
// A toast without an action (Removed from Liked Songs) holds an SPTSimpleSnackbarContentView with only
// the label, and is dressed the same way: the card is as wide as the label.
//
// Spotify puts the toast above the now playing bar where the bar stands with the tab bar expanded. In the minimized
// tab bar the bar moves down into the row (NowPlayingBar.x, by a transform Spotify does not know), and the toast
// kept its height in the air above nothing. The card follows the bar by the same shift, in the animation of the tab bar.
//
// A multi-line label ran out of the card's right edge (the card 321pt wide, the SPTEncoreLabel in it 281pt,
// the UILabel inside it still the 342pt Spotify laid it out for, so the text wrapped for 342 and ran 61pt past the
// card). Spotify does not size the inner label to the Encore label's frame, so the mod does, and the label clips to its
// own bounds as a last line.
//
// Some toasts are SwiftUI, in an SPTSnackbarViewFactoryView instead of an SPTSnackbarView ("You're now logged in as
// ..."): the same 374x50 view and plain card, but its content is a hosting view whose text is drawn, not a label,
// and which paints the white itself. That card is dressed the same, its text is turned white as Kit/SGRDrawnText.h says,
// and it is as wide as what the hosting view drew plus an even padding.
//
// The shift into the minimized tab bar's row is the card's only where the toast stands over the bar. A toast raised from a
// popup is laid out by Spotify at the bottom of the screen, with no bar under it (the toast at y=752 to 802, the bar
// at 697); the 68pt shift put the card at 820, below the screen's edge, where it was not seen.
//
// The toast is laid out as it comes up, so the pass runs from its layout; it runs again a moment later in case
// Spotify paints the white back with the content.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Redesigned/NowPlayingBar/NowPlayingBar.h"
#import "Shared/Player/PlayerEvents.h"

static const CGFloat kSideInset = 16;
static const CGFloat kMaxRadius = 28;
// The glass capsule round the action's word: its padding on each side and its height.
static const CGFloat kActionPadX = 10;
static const CGFloat kActionHeight = 32;
// How far past the button the touch still counts, so the capsule is all button.
static const CGFloat kActionHitX = 10, kActionHitY = 8;
// The card's padding left of the label, and right of the label when the toast has no action.
static const CGFloat kPadLeft = 20, kPadRight = 20;
// The glass round the action stands this far inside the card's edge: (50 - kActionHeight) / 2, so the two capsules
// are concentric and the glass never reaches the card's rim (the glass ended on the card's edge,
// and its corners stood out of the card's).
static const CGFloat kActionInset = 9;
// The space between the label and the glass round the action.
static const CGFloat kLabelGap = 16;

static char kGlassKey, kFilmKey, kDimKey, kActionGlassKey, kDressedKey;
// The toast on screen, for the tab bar's minimize to move.
static __weak UIView *sg_snackbar;

// The card: the plain UIView the toast holds its content in.
static UIView *cardOf(UIView *snackbar) {
    for (UIView *sub in snackbar.subviews) {
        if ([sub isMemberOfClass:UIView.class]) return sub;
    }
    return nil;
}

// The content of a SwiftUI toast: the hosting view its text and action are drawn in.
static BOOL isHostingView(UIView *view) {
    return [NSStringFromClass(view.class) containsString:@"_UIHostingView"];
}

static BOOL isActionButton(UIView *view) {
    return [NSStringFromClass(view.class) containsString:@"SPTSnackbarTextActionButton"];
}

// The label and the action of the toast's content (SPTSnackbarWithActionView), found among its direct subviews.
static void contentParts(UIView *content, UIView **label, UIView **action) {
    *label = nil;
    *action = nil;
    for (UIView *sub in content.subviews) {
        if (isActionButton(sub)) *action = sub;
        else if (!*label && [NSStringFromClass(sub.class) containsString:@"Label"]) *label = sub;
    }
}

static UILabel *innerLabel(UIView *label) {
    __block UILabel *found = nil;
    SGForEachView(label, ^(UIView *view) {
        if (!found && [view isKindOfClass:UILabel.class]) found = (UILabel *)view;
    });
    return found;
}

// The action's size: its frame once Spotify has laid it out, its word's until then.
static CGSize actionSize(UIView *action) {
    UILabel *text = innerLabel(action);
    CGSize fit = text ? [text sizeThatFits:CGSizeMake(CGFLOAT_MAX, CGFLOAT_MAX)] : CGSizeZero;
    return CGSizeMake(MAX(action.bounds.size.width, ceil(fit.width)), MAX(action.bounds.size.height, MAX(ceil(fit.height), 30)));
}

// How wide the label wants to be within maxWidth (a long one takes all of it and wraps).
static CGSize labelSize(UIView *label, CGFloat maxWidth) {
    UILabel *text = innerLabel(label);
    CGSize size = text ? [text sizeThatFits:CGSizeMake(maxWidth, CGFLOAT_MAX)] : label.bounds.size;
    return CGSizeMake(MIN(ceil(size.width), maxWidth), ceil(size.height));
}

// What the card holds to the right of the label: the action's word is this far from the card's edge (its glass's
// padding and the inset the glass keeps from the rim), the label's end when there is no action.
static CGFloat trailingPad(UIView *action) {
    return action ? kActionInset + kActionPadX : kPadRight;
}

// The card's width for its content: padding, label, and the action's glass when there is one.
static CGFloat cardWidth(UIView *content, CGFloat maxWidth) {
    UIView *label = nil, *action = nil;
    contentParts(content, &label, &action);
    CGFloat actionWidth = action ? actionSize(action).width + kActionPadX + kLabelGap : 0;
    CGFloat padRight = trailingPad(action);
    CGFloat room = maxWidth - kPadLeft - padRight - actionWidth;
    CGFloat labelWidth = label ? labelSize(label, MAX(room, 1)).width : 0;
    return MIN(kPadLeft + labelWidth + actionWidth + padRight, maxWidth);
}

// The label and the action inside the card, centred on its height: the label from the left padding, the action
// against the right one.
static void layoutContent(UIView *content) {
    // Spotify sizes the content for its 374; it is the card's size, and the parts are placed in that.
    UIView *card = content.superview;
    if (card && !CGRectEqualToRect(content.frame, card.bounds)) content.frame = card.bounds;
    CGSize size = content.bounds.size;
    if (size.width < 1 || size.height < 1) return;
    UIView *label = nil, *action = nil;
    contentParts(content, &label, &action);
    CGFloat padRight = trailingPad(action);
    CGSize actionFit = action ? actionSize(action) : CGSizeZero;
    CGFloat actionWidth = actionFit.width;
    if (action) {
        CGRect frame = CGRectMake(size.width - padRight - actionWidth, round((size.height - actionFit.height) / 2), actionWidth, actionFit.height);
        if (!CGRectEqualToRect(action.frame, frame)) action.frame = frame;
    }
    if (label) {
        CGFloat room = size.width - kPadLeft - padRight - (action ? actionWidth + kActionPadX + kLabelGap : 0);
        CGSize fit = labelSize(label, MAX(room, 1));
        CGRect frame = CGRectMake(kPadLeft, round((size.height - fit.height) / 2), fit.width, fit.height);
        if (!CGRectEqualToRect(label.frame, frame)) label.frame = frame;
        // Spotify's Encore label keeps its UILabel at the width it was laid out for (342 of a 374pt toast), whatever
        // frame it is given, so the text is wrapped for that width and runs out of a narrower card.
        UILabel *text = innerLabel(label);
        CGRect inner = CGRectMake(0, 0, fit.width, fit.height);
        if (text && !CGRectEqualToRect(text.frame, inner)) text.frame = inner;
        if (!label.clipsToBounds) label.clipsToBounds = YES;
    }
}

static void dressAction(UIView *button) {
    CGSize size = button.bounds.size;
    if (size.width < 1 || size.height < 1) return;
    SGRGlassCapsuleInside(button, &kActionGlassKey, CGSizeMake(size.width + kActionPadX * 2, kActionHeight), NO);
}

// Where the now playing bar stands is where the toast stands over it. Called inside the tab bar's animation as well, so
// the two move together.
static void followNowPlayingBar(UIView *snackbar) {
    UIView *card = cardOf(snackbar);
    if (!card) return;
    CGAffineTransform shift = CGAffineTransformMakeTranslation(0, SGRNowPlayingBarShiftOver([snackbar convertRect:snackbar.bounds toView:nil], snackbar.window));
    if (!CGAffineTransformEqualToTransform(card.transform, shift)) card.transform = shift;
}

void SGRSnackbarFollowNowPlayingBar(void) {
    UIView *snackbar = sg_snackbar;
    if (snackbar.window) followNowPlayingBar(snackbar);
}

// The width a SwiftUI toast needs: what its hosting view drew (the text, an action's own view), from the first one's
// left edge to the last one's right, with the same padding on the right as SwiftUI gave on the left. A toast whose
// content SwiftUI spreads to the full width (an action at the far end) gets the full width, as it had.
static CGFloat hostedCardWidth(UIView *content, CGFloat maxWidth) {
    __block CGFloat left = CGFLOAT_MAX, right = 0;
    SGForEachView(content, ^(UIView *view) {
        NSString *name = NSStringFromClass(view.class);
        if (![name hasSuffix:@"CGDrawingView"] && ![name containsString:@"PlatformViewHost"]) return;
        CGRect frame = [view convertRect:view.bounds toView:content];
        if (frame.size.width < 1) return;
        left = MIN(left, CGRectGetMinX(frame));
        right = MAX(right, CGRectGetMaxX(frame));
    });
    if (right <= 0 || left == CGFLOAT_MAX) return maxWidth;
    return MIN(ceil(right + MAX(left, kSideInset)), maxWidth);
}

static void dressSnackbar(UIView *snackbar) {
    UIView *card = cardOf(snackbar);
    if (!card || snackbar.bounds.size.width < 1 || snackbar.bounds.size.height < 1) return;
    // Dressed: from here the bare strips beside the card do not take touches (pointInside below).
    if (!objc_getAssociatedObject(snackbar, &kDressedKey)) objc_setAssociatedObject(snackbar, &kDressedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    // The content is the card's one view that is not the mod's glass or film (it is what Spotify added): the
    // toast with an action holds an SPTSnackbarWithActionView, the one without a SPTSimpleSnackbarContentView.
    UIView *content = nil;
    for (UIView *sub in card.subviews) {
        if ([NSStringFromClass(sub.class) containsString:@"SnackbarWithActionView"] || [NSStringFromClass(sub.class) containsString:@"SnackbarContentView"] || isHostingView(sub)) content = sub;
    }
    sg_snackbar = snackbar;
    CGFloat maxWidth = snackbar.bounds.size.width - kSideInset * 2;
    BOOL hosted = content && isHostingView(content);
    CGFloat width = !content ? maxWidth : hosted ? hostedCardWidth(content, maxWidth) : cardWidth(content, maxWidth);
    // By bounds and centre: the card carries a transform below (the minimized tab bar), and a frame set under one is undefined.
    CGRect bounds = CGRectMake(0, 0, width, snackbar.bounds.size.height);
    CGPoint center = CGPointMake(round((snackbar.bounds.size.width - width) / 2) + width / 2, snackbar.bounds.size.height / 2);
    if (!CGRectEqualToRect(card.bounds, bounds)) card.bounds = bounds;
    if (!CGPointEqualToPoint(card.center, center)) card.center = center;
    followNowPlayingBar(snackbar);
    UIView *glass = SGRGlassFloatingCard(card, &kGlassKey, &kFilmKey, kMaxRadius);
    // Dimmed as the tab bar's glass is, so its text stands out over a bright page.
    SGRDarkenGlass(glass, &kDimKey, MIN(kMaxRadius, bounds.size.height / 2), SGRBarDim);

    // What the card holds follows it, and the label and the button are placed for its width.
    for (UIView *sub in card.subviews) {
        if (sub == glass || sub == objc_getAssociatedObject(card, &kFilmKey)) continue;
        if (!CGRectEqualToRect(sub.frame, card.bounds)) sub.frame = card.bounds;
        if (sub.layer.backgroundColor) sub.layer.backgroundColor = NULL;
    }
    if (hosted) {
        // SwiftUI paints its own white and draws its text, which is black: the fill goes and the ink turns white.
        SGRClearHostedFill(content);
        SGRLightenDrawnText(content);
    } else if (content) {
        layoutContent(content);
    }
    SGRLightenLabels(card, nil);
    SGForEachView(card, ^(UIView *view) {
        if (isActionButton(view)) dressAction(view);
    });

    static dispatch_once_t once;
    dispatch_once(&once, ^{ SGLog(@"toast: glass over a card of %@", NSStringFromCGRect(card.bounds)); });
}

static void dressAfterSettling(UIView *snackbar) {
    SGRRepeatViewPass(snackbar, @[@0.0, @0.25], ^(UIView *v) { dressSnackbar(v); });
}

// A toast standing over the bar as the player comes up would stand over the player's controls (Added to queue, the
// player opened right after): its card fades out as the player opens, and back if the player goes again while the
// toast is still up. A toast raised once the player is open (a song saved from it) is shown. The card's alpha, not the
// toast's own, which Spotify animates.
static __weak UIView *sg_leftBehind;

static void playerMoves(void) {
    UIView *snackbar = sg_snackbar;
    UIView *card = snackbar.window ? cardOf(snackbar) : nil;
    if (!card || !SGPlayerIsOpen() || card.alpha < 0.01) return;
    sg_leftBehind = snackbar;
    [UIView animateWithDuration:0.15 animations:^{ card.alpha = 0; }];
}

static void playerSettled(void) {
    UIView *snackbar = sg_leftBehind;
    if (!snackbar || SGPlayerIsOpen()) return;
    sg_leftBehind = nil;
    UIView *card = cardOf(snackbar);
    [UIView animateWithDuration:0.2 animations:^{ card.alpha = 1; }];
}

// A toast Spotify shows again in the view it hid.
static void shownAgain(UIView *snackbar) {
    if (sg_leftBehind != snackbar) return;
    sg_leftBehind = nil;
    cardOf(snackbar).alpha = 1;
}

%hook SPTSnackbarView
- (void)layoutSubviews {
    %orig;
    dressSnackbar((UIView *)self);
}

- (void)didMoveToWindow {
    %orig;
    UIView *snackbar = (UIView *)self;
    if (!snackbar.window) return;
    shownAgain(snackbar);
    dressSnackbar(snackbar);
    dressAfterSettling(snackbar);
}

// The bare strips either side of the card are not the toast's: a touch there reaches the controls under them. Both the
// test and the hit are held to the card, so a hit test of Spotify's own that answers for the whole 374 does not take
// the strips either.
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *snackbar = (UIView *)self;
    UIView *card = objc_getAssociatedObject(snackbar, &kDressedKey) ? cardOf(snackbar) : nil;
    if (card && !CGRectContainsPoint(card.frame, point)) return nil;
    return %orig;
}

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *snackbar = (UIView *)self;
    UIView *card = objc_getAssociatedObject(snackbar, &kDressedKey) ? cardOf(snackbar) : nil;
    if (card) return CGRectContainsPoint(card.frame, point);
    return %orig;
}
%end

// The SwiftUI toast: the same view and the same card, dressed by the same pass.
%hook SPTSnackbarViewFactoryView
- (void)layoutSubviews {
    %orig;
    dressSnackbar((UIView *)self);
}

- (void)didMoveToWindow {
    %orig;
    UIView *snackbar = (UIView *)self;
    if (!snackbar.window) return;
    shownAgain(snackbar);
    dressSnackbar(snackbar);
    dressAfterSettling(snackbar);
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *snackbar = (UIView *)self;
    UIView *card = objc_getAssociatedObject(snackbar, &kDressedKey) ? cardOf(snackbar) : nil;
    if (card && !CGRectContainsPoint(card.frame, point)) return nil;
    return %orig;
}

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *snackbar = (UIView *)self;
    UIView *card = objc_getAssociatedObject(snackbar, &kDressedKey) ? cardOf(snackbar) : nil;
    if (card) return CGRectContainsPoint(card.frame, point);
    return %orig;
}
%end

// Spotify lays the label and the action out again for its own width whenever the content lays out.
static void relayoutContent(UIView *content) {
    UIView *snackbar = content.superview.superview;
    if (snackbar && objc_getAssociatedObject(snackbar, &kDressedKey)) layoutContent(content);
}

// A frame Spotify gives the content (its 374) is the card's instead, so the Open button is never placed past the card's edge.
static CGRect heldToCard(UIView *content, CGRect frame) {
    UIView *card = content.superview;
    UIView *snackbar = card.superview;
    if (card && snackbar && objc_getAssociatedObject(snackbar, &kDressedKey) && card.bounds.size.width >= 1) return card.bounds;
    return frame;
}

%hook SPTSnackbarWithActionView
- (void)setFrame:(CGRect)frame {
    %orig(heldToCard((UIView *)self, frame));
}

- (void)layoutSubviews {
    %orig;
    relayoutContent((UIView *)self);
}
%end

%hook SPTSimpleSnackbarContentView
- (void)setFrame:(CGRect)frame {
    %orig(heldToCard((UIView *)self, frame));
}

- (void)layoutSubviews {
    %orig;
    relayoutContent((UIView *)self);
}
%end

%hook SPTSnackbarTextActionButton
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    return CGRectContainsPoint(CGRectInset(((UIView *)self).bounds, -kActionHitX, -kActionHitY), point);
}
%end

%ctor {
    if (!SGRedesignedUI()) return;
    if (!SGBelowiOS26()) return;
    %init;
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center addObserverForName:SGPlayerTransitionNotification object:nil queue:nil usingBlock:^(NSNotification *note) { playerMoves(); }];
    [center addObserverForName:SGPlayerTransitionEndedNotification object:nil queue:nil usingBlock:^(NSNotification *note) { playerSettled(); }];
    SGRequireClasses(@[@"SPTSnackbarView", @"SPTSnackbarViewFactoryView", @"SPTSnackbarWithActionView", @"SPTSnackbarTextActionButton"]);
}
