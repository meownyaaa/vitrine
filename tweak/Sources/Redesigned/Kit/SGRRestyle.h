// Keeping Spotify's views the way a redesigned screen set them: Spotify re-applies its own look on
// reuse, on state changes and on every layout pass, so each helper here either survives that or is
// cheap enough to run again on every pass. Nothing here uses `hidden` on a view Spotify arranges in a
// stack: OverflowStackView and some Encore stacks trap in updateConstraints when an arranged view
// hides, so a view goes away by alpha, touches and accessibility instead.
//
// Ownership: what a helper creates belongs to the view it was made for (associated objects), and a
// helper keeps only weak references to Spotify's views.
// Threading: main thread only.
#import <UIKit/UIKit.h>

#pragma mark - views

// Alpha 0, no touches, hidden from accessibility, and kept so: the instance becomes a runtime subclass
// of its own class (the way KVO does it, `class` still answers the original) whose setAlpha: and
// setUserInteractionEnabled: hold those values. For plain UIKit views (a UIImageView, a UILabel). One of
// Spotify's Swift classes, or an instance KVO observes, keeps its alpha (only its alpha: touches and
// accessibility are set again on each call) through an override on its class that holds only the instances
// suppressed; where neither takes, the values are set once instead, re-applied
// on the next call, and a log line says so once.
void SGRSuppress(UIView *view);

// Digits of one width in the label, kept through Spotify's own setText:, setAttributedText: and
// setFont: by a runtime subclass of the instance, like SGRSuppress. Idempotent.
void SGRMonospacedDigits(UILabel *label);

// `changed` after every setImage: on the image view, Spotify's included, for as long as the view lives: by a
// runtime subclass of the instance like SGRSuppress, or, for one of Spotify's own classes (Encore's image
// views, which no instance of can be subclassed), by an override on that class, which only ever reports the
// instances that asked. A second call replaces the block. NO when neither took, which a log line says once:
// the caller then only sees what its own passes read.
//
// This is how a picture that lands after a screen has been laid out reaches it: setting an image lays no
// ancestor out, so nothing else tells the screen it is there.
BOOL SGRObserveImage(UIImageView *view, void (^changed)(UIImageView *view));

// `laidOut` after every layoutSubviews of the view, Spotify's included, for as long as the view lives, by
// a runtime subclass of the instance like SGRSuppress, or, for one of Spotify's own Swift classes, by an
// override on that class that only ever reports the instances that asked (see SGRObserveImage). A second call
// replaces the block, and a pass started from inside the block is not reported again. NO when neither took
// (a KVO-observed instance): the caller then has only the passes it hooks itself to work from.
//
// For a screen that arranges Spotify's controls its own way: a parent lays its children out after the
// hook that placed them has returned, so frames set from an ancestor's pass are the ones overwritten.
BOOL SGRObserveLayout(UIView *view, void (^laidOut)(UIView *view));
// Whether `view` has a block from SGRObserveLayout: a caller that must not replace another's asks first.
BOOL SGRObservesLayout(UIView *view);

// SGRObserveLayout once per view: a view already watched keeps the block it has. For a pass that runs on every layout
// of the page and watches the same view each time.
BOOL SGRWatchLayout(UIView *view, void (^laidOut)(UIView *view));

// A list run on under the page's bars, as tall as the page instead of stopping short of them. What Spotify's
// constraints leave the view is read off its frame whenever it is not the frame last given by SGRSetOwnFrame, and kept
// while it is: that frame is the redesign's, and reading it would undo what was read. `top` is where the view starts,
// `below` how much of its superview is under it (the tab bar and the now playing bar).
typedef struct { CGFloat top, below; } SGRListRoom;
SGRListRoom SGRListRoomOf(UIView *view);
void SGRSetOwnFrame(UIView *view, CGRect frame);
// The list's insets set to `inset`, with no safe area of its own on top, its rows kept where they were: a list at its
// top stays there, and one a reload sent back to offset 0 (the first row under the bar) is put back under it.
void SGRSetListInsets(UIScrollView *list, UIEdgeInsets inset);
// The two together: `list` run on to the foot of its superview, from where it starts or, `fromTop`, from the superview's
// top, with `top` over its rows (and where it started, from the top) and the bars below as its bottom inset, at least
// `page`'s safe area.
void SGRRunListToFoot(UIScrollView *list, UIView *page, CGFloat top, BOOL fromTop);
// The page's list: the first collection view under `view` nearly as wide as it, kept on `view` under `key`.
UICollectionView *SGRPageListIn(UIView *view, const void *key);

// The first view under `root` (itself included) with the accessibility identifier, depth first. The
// answer is kept weakly on `root` under `cacheKey` and searched for again only when it is gone, has
// left `root` or changed its identifier. nil when there is none; a miss is not cached.
UIView *SGRFindByIdentifier(UIView *root, NSString *identifier, const void *cacheKey);
// SGRFindByIdentifier for every identifier at once, in one walk (Core's SGFindRememberedAll): `found[i]` is
// identifiers[i]'s view or nil. For lookups made back to back with nothing between them that changes the tree.
void SGRFindByIdentifiers(UIView *root, NSArray<NSString *> *identifiers, const void *const cacheKeys[], UIView *__strong found[]);

// The first subview of `host` (not deeper) whose class is named `name` exactly.
UIView *SGRChildNamed(UIView *host, NSString *name);

// The navigation controller `view` is shown in, by its responders; nil outside one.
UINavigationController *SGRNavigationOf(UIView *view);

// A Swift class by module and name, under the mangled spelling or the dotted one the trees print; nil when the
// app has neither.
Class SGRSwiftClass(NSString *module, NSString *name);

// A class of `module` whose mangled name carries a private discriminator (P33_...), found by the ending the trees
// print. Walks every class, so it is for a %ctor, once.
Class SGRPrivateSwiftClass(NSString *module, NSString *suffix);

// Invisible for good, whatever Spotify does to it. `hidden` on the layer costs nothing and, unlike -[UIView
// setHidden:], tells neither KVO nor the stack views, which is what makes it safe on Encore's layouts; an empty mask
// holds when Spotify shows the view again with -setHidden:NO. Out of touches and VoiceOver, still there to be read
// and fired.
void SGRConceal(UIView *view);

// Whether `view` is the profile avatar that opens the side drawer, in the Home, Search and Library headers. Known by
// its identifier, which every version gives it: 9.1.88 draws it in an AdaptiveFaceContainer, 9.1.90 in an Encore
// button around a listening-activity pulse, which a check by class alone took for something else.
BOOL SGRIsAvatar(UIView *view);

// A view that draws only a shadow, for a view whose own layer clips (rounded artwork): made once per
// host under `key`, inserted at the bottom of `host`. The caller gives it its frame and transform; its
// shadowPath follows its bounds and cornerRadius.
@interface SGRShadowPlate : UIView
@property (nonatomic) CGFloat cornerRadius;   // SGRRadiusArtwork unless set
@end
SGRShadowPlate *SGRShadowPlateIn(UIView *host, const void *key);

#pragma mark - Spotify's controls and pages

// The base surface a list cell paints over a page's field, cleared: the #121212 the redesign's AMOLED
// black has already turned black, on the cell and on everything under it nearly as wide as the cell, and
// the full-width fade a "see more" draws over its last row, which the black makes a dark band. The Kit's
// repaint hook misses all of it -- it only hears about a color when Spotify sets it, and a cell is painted
// before it is inside the page and brings its old paint with it when it is reused -- so this runs from the
// cell's own layout pass, and is cheap enough to.
//
// Only what is nearly as wide as the cell: a badge's black disc, a card's gray and an image's placeholder
// are their own. A cell nested inside the cell and narrower than that (a card in a carousel) is not walked
// into: its own row decides for it.
void SGRClearCellPaint(UIView *cell);

// Fires one of Spotify's own buttons the way a tap on it would: the first control under `source`, through
// SGRFire, and through -accessibilityActivate when that control answers its touches some other way. For a
// control the redesign conceals and draws itself (the action row's buttons, a header's creator line).
void SGRActivate(UIView *source);

// Fires a control's action the way a tap would: the actions registered for primary action triggered,
// else those for touch up inside. NO when the control has neither (an Encore control that reads its
// touches through a gesture recognizer); what was found is logged once per class.
BOOL SGRFire(UIControl *control);

// Gives a scroll view the hard top edge effect, a dark band, and keeps the soft one SGREdgeEffect.x sets on every
// other scroll view off it: for text that stays over a page scrolling under it (Home's kept title, HomeHeader.x).
// iOS 26 on; nothing before.
void SGRHardTopEdge(UIScrollView *scrollView);
