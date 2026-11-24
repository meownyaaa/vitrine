// Redesign, iOS < 26: the body of the AI playlist's chat on glass
// (AIPlaylist_PlaylistCreationPageImpl.PlaylistCreationView). The header's buttons are AIPlaylistGlass.x, the ⋯'s popup
// AIPlaylistMore.x.
//
//   Responses       every message of Spotify AI is a glass plate, the one the chat pins above the footer and the ones in its list (the
//                   "Great, let me look through our catalog..." that stands in while a request is answered, and
//                   the replies): bubbles painted #2A2A2A, told from the user's own (#000000, 320 wide), which stay
//                   Spotify's. The plate carries the Kit's white film, since plain glass over the black page is a hole, not a plate, and
//                   no border of its own or Spotify's.
//   Last response   the message the chat pins above the footer ("Here's a playlist of your top played songs..."):
//                   Components.UI.ChatItemOverlayRow.Button, a plain view 390 x 76 that is the page's own child, holding a fade
//                   to black (two GradientViews and a 16pt black strip), the ChatBubble #2A2A2A and the
//                   button over it. The bubble is the view's full width, but what shows is its mask: the same 358pt plate
//                   16pt in from each side that the text's 32pt inset comes from. The mask goes (glass drawn under a layer mask
//                   is cut off or not drawn, as in the transcript's Report a problem popup, Kit/SGRSheetPopups.x) and the plate
//                   is a glass card of the mask's own bounds, with the Kit's card radius, in its place. Only the bubble of that
//                   row: the chat's own list keeps its bubbles.
//   Black behind    the page's own bottom plate (a plain UIView 390 x 190 at the foot: two fades and a 106pt black strip), the
//                   row's fade above, and the footer's own plates (the ChatFooter element's stack, #000000, and the 64pt view
//                   in it that holds Create and the field). Their paint is cleared and kept clear (SGRHoldClear), the fades
//                   are concealed the way the Rate show sheet's are (layer hidden, empty mask: Spotify brings its alpha
//                   back as the list scrolls, and a hidden Encore view can crash its stack). The page's own black stays
//                   behind: nothing but the page is opaque there now, and the glass shows the list scrolling under it.
//   Refine field    the white capsule (a stack #FFFFFF r=24, 227 x 48) is a glass capsule with the Kit's white film
//                   (SGRGlassFillBox), not a flat white. The glass is the box's own size by autoresizing, as Create narrows the box
//                   from 358 to 227pt (a pane sized from outside stayed 358 wide), and it answers no press: the grown,
//                   stretched glass of one lagged behind a finger on a field that is typed into. Its dark text goes light, as the
//                   placeholder (#5A5A5A) and the icon, which were drawn for white, and the 13pt GradientView along its top, a fade
//                   white to clear for text scrolling under it, is concealed: on glass it is a white band.
//   Try asking      Components.UI.PromptsCarouselRow.CardButton, 212 x 120: a view #FFFFFF@0.07 r=16 inside the button, which
//                   goes clear, and a glass card of the same size and radius behind it. The card's text stays Spotify's. The card
//                   fills its scroll view, and the scroll view and the cell clip to their bounds, so the press's grown
//                   glass was cut off at the card's own edge: they are let go of their clip, up to the collection view.
//
// The bubble, the cards and the field are dressed from their own layout passes (the collection lays its cells out
// without laying the page out, and typing lays out only the field), the plates from the page's (AIPlaylistGlass.x calls
// SGRAIPlaylistDressChat) and from the bubble's and the field's, since each is the first thing to know its plate is there.
// Threading: main thread only.
#import "Core/SGCore.h"
#import "Core/SGGlassTouch.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Redesigned/Pages/Pages.h"

static NSString *const kOverlayRow = @"Components.UI.ChatItemOverlayRow.Button";
static NSString *const kCardButton = @"Components.UI.PromptsCarouselRow.CardButton";
static NSString *const kInputText = @"Components.UI.ChatFooter.InputTextView";

static char kBubbleGlassKey, kPlateKey, kPlateSizeKey, kCardGlassKey, kFieldGlassKey;

// Where the plate of a bubble is when its mask tells nothing: 16pt in from each side of the full width view.
static const CGFloat kBubbleInset = 16;

// Whether the classes of the views with a pass of their own were found; when not, the page's pass looks for them.
static BOOL sBubbleHooked, sCardHooked;

#pragma mark - the black and the fades

static BOOL isGradient(UIView *view) {
    return [NSStringFromClass(view.class) hasSuffix:@"GradientView"];
}

// A fade: concealed by its layer, not by the view's alpha (Spotify animates that) nor its hidden flag.
static void concealFade(UIView *fade) {
    if (!fade.layer.hidden) fade.layer.hidden = YES;
    if (!fade.layer.mask) fade.layer.mask = [CALayer layer];
}

// A fill gone for good. An opaque view with no fill is drawn over black, whatever the glass behind it shows, so the flag goes too.
static void clearPaint(UIView *view) {
    if (view.backgroundColor && ![view.backgroundColor isEqual:UIColor.clearColor]) view.backgroundColor = UIColor.clearColor;
    if (view.layer.backgroundColor && CGColorGetAlpha(view.layer.backgroundColor) > 0.05) view.layer.backgroundColor = NULL;
    if (view.opaque) view.opaque = NO;
    if (view.layer.opaque) view.layer.opaque = NO;
    SGRHoldClear(view);
}

// The fades and the wide black views under `root`, a few levels down: the footer holds its black in a stack, in a view, in a view
// of 64pt, above everything the footer draws. The field, Create and the text view are deeper or not black.
static void clearPlates(UIView *root, int depth) {
    if (depth > 3) return;
    for (UIView *sub in root.subviews) {
        if (isGradient(sub)) {
            concealFade(sub);
            continue;
        }
        CGColorRef fill = sub.layer.backgroundColor;
        if (fill && SGIsBaseSurface(fill) && sub.bounds.size.width >= 300) clearPaint(sub);
        clearPlates(sub, depth + 1);
    }
}

static BOOL holdsFade(UIView *view) {
    for (UIView *sub in view.subviews) {
        if (isGradient(sub)) return YES;
    }
    return NO;
}

// The plate of the page and of the last response: a plain view with the fades and the black strip in it.
static void clearFadePlates(UIView *host) {
    for (UIView *sub in host.subviews) {
        if (object_getClass(sub) == UIView.class && holdsFade(sub)) clearPlates(sub, 0);
    }
}

static BOOL isFooter(UIView *view) {
    return [NSStringFromClass(view.class) containsString:@"ChatFooter"];
}

#pragma mark - the last response

// Keeps the bounds of the shape the bubble is masked to, when the mask is a shape of any sense.
static void rememberPlate(UIView *bubble, CALayer *mask) {
    if (![mask isKindOfClass:CAShapeLayer.class]) return;
    CGPathRef path = ((CAShapeLayer *)mask).path;
    if (!path) return;
    CGRect box = [bubble.layer convertRect:CGPathGetBoundingBox(path) fromLayer:mask];
    if (box.size.width < 100 || box.size.height < 20) return;
    if (!CGRectContainsRect(CGRectInset(bubble.bounds, -1, -1), box)) return;
    objc_setAssociatedObject(bubble, &kPlateKey, [NSValue valueWithCGRect:box], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(bubble, &kPlateSizeKey, [NSValue valueWithCGSize:bubble.bounds.size], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// A list's bubble is reused for another message and is resized with its text: a plate read for one size says nothing of the next.
static CGRect plateOf(UIView *bubble) {
    NSValue *stored = objc_getAssociatedObject(bubble, &kPlateKey);
    NSValue *size = objc_getAssociatedObject(bubble, &kPlateSizeKey);
    if (stored && size && CGSizeEqualToSize(size.CGSizeValue, bubble.bounds.size)) return stored.CGRectValue;
    return CGRectInset(bubble.bounds, kBubbleInset, 0);
}

// The grey of Spotify AI's bubbles (#2A2A2A), which the user's own (#000000) are not.
static BOOL isAIPaint(CGColorRef color) {
    if (!color || CGColorGetAlpha(color) < 0.9) return NO;
    const CGFloat *c = CGColorGetComponents(color);
    size_t n = CGColorGetNumberOfComponents(color);
    if (n < 2) return NO;
    for (size_t i = 0; i + 1 < n; i++) if (c[i] < 0.12 || c[i] > 0.22) return NO;
    return YES;
}

static void dressBubble(UIView *bubble) {
    CGSize size = bubble.bounds.size;
    if (!bubble.window || size.width < 1 || size.height < 1) return;
    UIView *row = bubble.superview;
    BOOL pinned = [row.accessibilityIdentifier isEqualToString:kOverlayRow];
    BOOL dressed = objc_getAssociatedObject(bubble, &kBubbleGlassKey) != nil;
    // The pinned one is always Spotify AI's. In the list, the grey paint tells AI's from the user's, and a bubble already on glass has
    // none left to tell by.
    if (!pinned && !dressed && !isAIPaint(bubble.layer.backgroundColor)) return;

    if (pinned) {
        // The row's fade and the page's plate under it: the black behind the message goes, and its page's below.
        clearFadePlates(row);
        if (row.superview) clearFadePlates(row.superview);
    }

    // The plate, from the mask Spotify cuts the bubble to: read while there is one, since the mask is gone from the next pass on.
    rememberPlate(bubble, bubble.layer.mask);
    CGRect plate = plateOf(bubble);
    if (bubble.layer.mask) bubble.layer.mask = nil;
    clearPaint(bubble);
    // No border of the bubble's own.
    if (bubble.layer.borderWidth > 0) bubble.layer.borderWidth = 0;

    UIView *glass = SGGlassFor(bubble, &kBubbleGlassKey);
    if (glass.overrideUserInterfaceStyle != UIUserInterfaceStyleDark) glass.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    glass.autoresizingMask = UIViewAutoresizingNone;
    if (!CGRectEqualToRect(glass.frame, plate)) glass.frame = plate;
    CGFloat radius = MIN(SGRRadiusCard, plate.size.height / 2);
    SGShapeGlass(glass, radius, NO);
    if (glass.layer.borderWidth > 0) glass.layer.borderWidth = 0;
    SGRGlassSetFilm(glass, YES, radius);
    if (bubble.subviews.firstObject != glass) [bubble insertSubview:glass atIndex:0];
}

#pragma mark - the Refine field

static BOOL isWhitePaint(CGColorRef color) {
    if (!color || CGColorGetAlpha(color) < 0.9) return NO;
    const CGFloat *c = CGColorGetComponents(color);
    size_t n = CGColorGetNumberOfComponents(color);
    for (size_t i = 0; i + 1 < n; i++) if (c[i] < 0.95) return NO;
    return n >= 2;
}

static BOOL isDarkText(UIColor *color) {
    CGColorRef cg = color.CGColor;
    if (!cg) return YES;
    const CGFloat *c = CGColorGetComponents(cg);
    return c && CGColorGetNumberOfComponents(cg) >= 2 && c[0] < 0.6;
}

// The field's box: the white capsule that holds the placeholder and the text view, a few levels up from the text view. Found by
// its paint the first time and by its glass afterwards.
static UIView *fieldBox(UIView *textView) {
    UIView *view = textView.superview;
    for (int i = 0; view && i < 5; i++, view = view.superview) {
        if (objc_getAssociatedObject(view, &kFieldGlassKey)) return view;
        if (view.bounds.size.height >= 40 && isWhitePaint(view.layer.backgroundColor)) return view;
    }
    return nil;
}

static void dressField(UITextView *text) {
    if (![text.accessibilityIdentifier isEqualToString:kInputText]) return;
    if (!text.window) return;
    UIView *box = fieldBox(text);
    if (!box || box.bounds.size.width < 1 || box.bounds.size.height < 1) return;

    SGRGlassFillBox(box, &kFieldGlassKey, YES);
    SGRHoldClear(box);
    // The fade along the top of the field, white to clear for a white field's text, is a white band over the glass.
    SGForEachView(box, ^(UIView *view) {
        if (isGradient(view)) concealFade(view);
    });
    // The footer's black under and around the field, from the first pass that meets the field.
    for (UIView *view = box; view; view = view.superview) {
        if (isFooter(view)) {
            clearPlates(view, 0);
            break;
        }
    }

    // What Spotify drew for a white field: dark text, a dark placeholder (#5A5A5A) and a dark icon.
    if (isDarkText(text.textColor)) text.textColor = UIColor.whiteColor;
    UIColor *soft = [UIColor colorWithWhite:1 alpha:0.6];
    SGForEachView(box, ^(UIView *view) {
        if ([view isKindOfClass:UILabel.class]) {
            UILabel *label = (UILabel *)view;
            if (isDarkText(label.textColor)) label.textColor = soft;
        } else if ([view isKindOfClass:UIImageView.class] && view.bounds.size.width <= 24 && !view.hidden) {
            UIImageView *icon = (UIImageView *)view;
            if (icon.image && icon.image.renderingMode != UIImageRenderingModeAlwaysTemplate) {
                icon.image = [icon.image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
            }
            if (![icon.tintColor isEqual:soft]) icon.tintColor = soft;
        }
    });
}

#pragma mark - the Try asking cards

static void dressCard(UIView *button) {
    if (![button.accessibilityIdentifier isEqualToString:kCardButton]) return;
    CGSize size = button.bounds.size;
    if (!button.window || size.width < 1 || size.height < 1) return;

    // The grey: the one plain rounded view in the button (#FFFFFF@0.07, r=16), which Spotify paints again as the card is pressed.
    CGFloat radius = SGRRadiusCard;
    for (UIView *sub in button.subviews) {
        if (object_getClass(sub) != UIView.class || sub.layer.cornerRadius < 1) continue;
        radius = sub.layer.cornerRadius;
        clearPaint(sub);
        break;
    }

    // The scroll view the cards stand in and the cell around it clip to their bounds, which the card fills: the press's grown glass would be
    // cut off at the card's own edge. Let go of them, up to the collection view, whose clip keeps the list under the header.
    SGRUnclipUpTo(button.superview, ^BOOL(UIView *v) {
        return [v.superview isKindOfClass:UICollectionView.class] || [v.superview isKindOfClass:UITableView.class];
    });

    UIView *glass = SGGlassFor(button, &kCardGlassKey);
    if (glass.overrideUserInterfaceStyle != UIUserInterfaceStyleDark) glass.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    glass.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    if (!CGRectEqualToRect(glass.frame, button.bounds)) glass.frame = button.bounds;
    SGShapeGlass(glass, MIN(radius, MIN(size.width, size.height) / 2), NO);
    if (button.subviews.firstObject != glass) [button insertSubview:glass atIndex:0];
    SGGlassInteractive(button, glass);
}

#pragma mark - the page's pass

void SGRAIPlaylistDressChat(UIView *page) {
    if (!SGBelowiOS26() || !page.window) return;
    for (UIView *sub in page.subviews) {
        if (isFooter(sub)) {
            clearPlates(sub, 0);
        } else if ([sub.accessibilityIdentifier isEqualToString:kOverlayRow]) {
            clearFadePlates(sub);
        }
    }
    clearFadePlates(page);
    // Views whose class has no pass of its own here are found by walking the page.
    if (sBubbleHooked && sCardHooked) return;
    SGForEachView(page, ^(UIView *view) {
        if (!sBubbleHooked && [view.superview.accessibilityIdentifier isEqualToString:kOverlayRow] && [NSStringFromClass(view.class) hasSuffix:@"ChatBubble"]) dressBubble(view);
        else if (!sCardHooked && [view.accessibilityIdentifier isEqualToString:kCardButton]) dressCard(view);
    });
}

%ctor {
    if (!SGRedesignedUI()) return;
    if (!SGBelowiOS26()) return;
    // The classes by the names the trees print: Swift's, nested or private to a file.
    Class bubble = NSClassFromString(@"_TtCOOE17AIPlaylist_ECMKitO19LegacyUI_ECMCoreKit10Components14ChatItemBubble2UI10ChatBubble");
    if (bubble) {
        sBubbleHooked = YES;
        SGRPassView(bubble, ^(UIView *v) { dressBubble(v); });
    } else {
        SGLog(@"class AIPlaylist ChatItemBubble.ChatBubble not found, the AI playlist's last response is dressed from the page's passes");
    }
    Class card = NSClassFromString(@"_TtC19LegacyUI_ECMCoreKitP33_7AC6ABDB5A3E514EA5239D6986C3C90912EncoreButton");
    if (card) {
        sCardHooked = YES;
        SGRPassView(card, ^(UIView *v) { dressCard(v); });
    } else {
        SGLog(@"class LegacyUI_ECMCoreKit EncoreButton not found, the AI playlist's Try asking cards are dressed from the page's passes");
    }
    // The Refine field's text view is UIKit's own: told by its identifier.
    SGRPassView(UITextView.class, ^(UIView *v) { dressField((UITextView *)v); });
}
