// Made For You (SPTMadeForYouHubViewController, a Hub page opened from Home): the covers of its cards cut at the radius
// Home's are.
//
// Tree (trees/continuous/27.txt): a card is a GLUEEntityCardView 162x224 (:29): a plain view 162x162 that clips and holds
// the cover, a GLUEImageView that clips too (:30-31), and the text under it. Both have no radius of their own, so the
// cover is square; Home's covers are cut at SGRRadiusCover, continuous (HomeCards.x), and these are now. Only the cards
// of this page are: the card's view controller says which page it is on.
// Threading: main thread only.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"

// Below this a card's picture is a glyph or a placeholder, not a cover (HomeCards.x).
static const CGFloat kCoverMinWidth = 80;

@interface GLUEEntityCardView : UIView
- (UIView *)imageContainerView;
@end

static Class sg_madeForYou;

static void roundCorners(UIView *view, CGFloat radius) {
    CALayer *layer = view.layer;
    if (layer.cornerRadius != radius) layer.cornerRadius = radius;
    if (layer.cornerCurve != kCACornerCurveContinuous) layer.cornerCurve = kCACornerCurveContinuous;
    if (!layer.masksToBounds) layer.masksToBounds = YES;
}

// Whether the card is on the Made For You page: the first view controller up its responder chain.
static BOOL onPage(UIView *card) {
    for (UIResponder *r = card.nextResponder; r; r = r.nextResponder) {
        if ([r isKindOfClass:UIViewController.class]) return [r isKindOfClass:sg_madeForYou];
    }
    return NO;
}

// The cover's holder clips (setupImageContainerView), so its corners cut the cover's too.
static void roundCover(GLUEEntityCardView *card) {
    UIView *holder = card.imageContainerView;
    if (holder.bounds.size.width < kCoverMinWidth || !onPage(card)) return;
    roundCorners(holder, SGRRadiusCover);
}

%hook GLUEEntityCardView
- (void)layoutSubviews {
    %orig;
    roundCover(self);
}
%end

%ctor {
    if (!SGRedesignedUI()) return;
    Class card = NSClassFromString(@"GLUEEntityCardView");
    sg_madeForYou = NSClassFromString(@"SPTMadeForYouHubViewController");
    if (!card || !sg_madeForYou) {
        SGRequireClasses(@[@"GLUEEntityCardView", @"SPTMadeForYouHubViewController"]);
        return;
    }
    if (![card instancesRespondToSelector:@selector(imageContainerView)]) {
        SGLog(@"-[GLUEEntityCardView imageContainerView] not found, the covers on Made For You stay square");
        return;
    }
    %init;
}
