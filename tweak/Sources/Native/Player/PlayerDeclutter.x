// Player declutter: hides parts of the full screen player, one switch each on the Player page. Cards
// under the player are Element_List cells; a hidden one reports zero height when the list sizes it,
// so the list closes up around it (the 24pt gap between cards stays). Player buttons go invisible but
// keep their place, so their row stays centered. A hidden lyric preview gives its room to the cover.
//
// Trees (trees/now-playing*.txt): every card is a CollectionViewCell whose content view names the
// page (NowPlaying_ScrollAPI) and whose subtree names the card. Player rows are the UIStackView of each NowPlaying_ModesImpl unit: playback controls
// hold shuffle, previous, play, next, repeat; the footer holds connect, a hidden button, share
// and the queue; track info ends with the add-to button.
#import "Core/SGCore.h"
#import "Shared/AdBlock/AdBlock.h"
#import "NowPlaying.h"

#pragma mark - cards and sections

static const struct { __unsafe_unretained NSString *marker, *key; } cards[] = {
    {@"Lyrics_CardElementImpl", SGHideLyricsCard},
    {@"CreatorBiography", SGHideAboutArtist},
    {@"VideoRecommendations", SGHideRelatedVideos},
    {@"SongDNA_", SGHideSongDNA},
    {@"LiveEvents_", SGHideLiveEvents},
    {@"WatchFeed_", SGHideExploreArtist},
    {@"Creator_Credits", SGHideCredits},
    {@"Merch_", SGHideMerch},
    {@"RelatedContentRecommendations", SGHideRecommendations},
};

enum { kCards = sizeof(cards) / sizeof(cards[0]) };

static BOOL anyCardSwitch(void) {
    for (size_t i = 0; i < kCards; i++) {
        if (SGHidden(cards[i].key)) return YES;
    }
    return NO;
}

// Whether the cell is one of the player's cards: its own first subview or its content view's names the page.
// Spotify's cell has held the name in both places (Redesigned/Player/PlayerCards.x, and the trees above).
static BOOL onPlayer(UICollectionViewCell *cell) {
    return SGClassNamed(cell.subviews.firstObject.class, @"NowPlaying_ScrollAPI")
        || SGClassNamed(cell.contentView.subviews.firstObject.class, @"NowPlaying_ScrollAPI");
}

// The first switched-on card a class in the cell names. Lists nested in the cell are laid out first so the
// cells that name the card (video cards) exist.
static NSString *switchedCardIn(UIView *cell) {
    unsigned hidden = 0;   // a bit per switched-on card (a block cannot capture an array)
    for (size_t i = 0; i < kCards; i++) if (SGHidden(cards[i].key)) hidden |= 1u << i;
    __block size_t first = kCards;
    SGForEachView(cell, ^(UIView *v) {
        if (v != cell && [v isKindOfClass:UICollectionView.class]) [v layoutIfNeeded];
        for (size_t i = 0; i < first; i++) {
            if ((hidden & 1u << i) && SGClassNamed(v.class, cards[i].marker)) first = i;
        }
    });
    return first < kCards ? cards[first].key : nil;
}

// An ad among the cards (a sponsored playlist's "Advertisement" card, 9.1.78): built of Encore's own views, it is
// told apart only by its identifiers, Components.UI.Ads.FullbleedDisplayAd and the like. Hide ads drops it.
static BOOL holdsAd(UIView *cell) {
    __block BOOL found = NO;
    SGForEachView(cell, ^(UIView *v) {
        if (!found && [v.accessibilityIdentifier hasPrefix:@"Components.UI.Ads."]) found = YES;
    });
    return found;
}

static NSString *hiddenKeyFor(UICollectionViewCell *cell) {
    // Only the player's cards are looked into: they name the page, which every other list's cells do not.
    BOOL hideAds = SGHidden(SGKeyHideAds), anyCard = anyCardSwitch();
    if (!(hideAds || anyCard) || !onPlayer(cell)) return nil;
    // A cell inside another card's list: the outer card decides.
    for (UIView *v = cell.superview; v; v = v.superview) {
        if ([v isKindOfClass:cell.class]) return nil;
    }
    // The ad card has been seen only with the name on its content view, so only that shape is searched for ads.
    if (hideAds && SGClassNamed(cell.contentView.subviews.firstObject.class, @"NowPlaying_ScrollAPI") && holdsAd(cell)) return SGKeyHideAds;
    return anyCard ? switchedCardIn(cell) : nil;
}

%hook _TtC12Element_List18CollectionViewCell
- (UICollectionViewLayoutAttributes *)preferredLayoutAttributesFittingAttributes:(UICollectionViewLayoutAttributes *)attributes {
    UICollectionViewLayoutAttributes *result = %orig;
    NSString *key = hiddenKeyFor((UICollectionViewCell *)self);
    if (!key) return result;
    result.size = CGSizeMake(result.size.width, 0);
    ((UIView *)self).clipsToBounds = YES;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ SGLog(@"collapsed the first card, %@", key); });
    return result;
}
%end

#pragma mark - player buttons, lyrics under the artwork

static BOOL vanish(UIView *view) {
    if (!view || view.alpha == 0) return NO;
    view.alpha = 0;
    view.userInteractionEnabled = NO;
    return YES;
}

// Re-layout once something went invisible, so the glass panes of Player.x follow.
static void finish(UIViewController *unit, BOOL changed) {
    if (changed) [unit.viewIfLoaded setNeedsLayout];
}

%hook _TtC20NowPlaying_ModesImpl28PlaybackControlsElementsUnit
- (void)viewDidLayoutSubviews {
    %orig;
    BOOL hideShuffle = SGHidden(SGHideShuffle), hideRepeat = SGHidden(SGHideRepeat);
    if (!hideShuffle && !hideRepeat) return;
    NSArray<UIView *> *items = SGRowIn(((UIViewController *)self).viewIfLoaded).arrangedSubviews;
    if (items.count != 5 || !SGHasClass(items[2], @"PlayButton")) return;
    BOOL changed = NO;
    if (hideShuffle) changed |= vanish(items[0]);
    if (hideRepeat) changed |= vanish(items[4]);
    finish((UIViewController *)self, changed);
}
%end

%hook _TtC20NowPlaying_ModesImpl18FooterElementsUnit
- (void)viewDidLayoutSubviews {
    %orig;
    BOOL hideConnect = SGHidden(SGHideConnect), hideQueue = SGHidden(SGHideQueue), hideShare = SGHidden(SGHideShare);
    if (!hideConnect && !hideQueue && !hideShare) return;
    BOOL changed = NO;
    for (UIView *item in SGRowIn(((UIViewController *)self).viewIfLoaded).arrangedSubviews) {
        if (item.hidden || item.bounds.size.width < 20) continue;
        if (SGHasClass(item, @"Connect")) {
            if (hideConnect) changed |= vanish(item);
        } else if (SGHasClass(item, @"QueueButton")) {
            if (hideQueue) changed |= vanish(item);
        } else if (item.bounds.size.width <= 48 && SGHasClass(item, @"EncoreButton")) {
            if (hideShare) changed |= vanish(item);
        }
    }
    finish((UIViewController *)self, changed);
}
%end

%hook _TtC20NowPlaying_ModesImpl23InformationElementsUnit
- (void)viewDidLayoutSubviews {
    %orig;
    if (!SGHidden(SGHideAddTo)) return;
    BOOL changed = NO;
    for (UIView *item in SGRowIn(((UIViewController *)self).viewIfLoaded).arrangedSubviews) {
        if (SGHasClass(item, @"AddToButton")) changed |= vanish(item);
    }
    finish((UIViewController *)self, changed);
}
%end

// Hidden, the preview takes no room either, whatever size it is asked for or given: Spotify's cell kept
// room under the cover for it, so a track with lyrics had a smaller cover pushed up over a blank band
// (issue #77). With the switch off the preview shows and its room is its own.
%hook _TtC22Lyrics_NPVContainerKit19LyricsContainerView
- (void)setHidden:(BOOL)hidden {
    %orig(SGHidden(SGHideLyricsInline) ? YES : hidden);
}
- (void)didMoveToWindow {
    %orig;
    if (SGHidden(SGHideLyricsInline)) ((UIView *)self).hidden = YES;
}
- (CGSize)intrinsicContentSize {
    return SGHidden(SGHideLyricsInline) ? CGSizeZero : %orig;
}
- (CGSize)sizeThatFits:(CGSize)size {
    return SGHidden(SGHideLyricsInline) ? CGSizeZero : %orig;
}
- (void)setFrame:(CGRect)frame {
    if (SGHidden(SGHideLyricsInline)) frame.size = CGSizeZero;
    %orig(frame);
}
%end

#pragma mark - the cover in the preview's room

// The bar's cover has a tilt view of its own, 40pt; the player's is about 354.
static const CGFloat kCoverMinWidth = 200;

// The tilt view takes the largest square of the plain view it sits in with the preview, centered on whole
// points, the way the Music app's cover fills its square. Bounds and a center, not a frame, since the tilt
// view carries Spotify's tilt while the cover is inspected. A square under kCoverMinWidth is left alone.
static void fillRoom(UIView *tilt) {
    CGRect room = tilt.superview.bounds;
    CGFloat side = MIN(room.size.width, room.size.height);
    if (side < kCoverMinWidth) return;
    CGPoint middle = CGPointMake(round(CGRectGetMinX(room) + (room.size.width - side) / 2) + side / 2,
                                 round(CGRectGetMinY(room) + (room.size.height - side) / 2) + side / 2);
    CGRect bounds = (CGRect){tilt.bounds.origin, CGSizeMake(side, side)};
    if (CGRectEqualToRect(tilt.bounds, bounds) && CGPointEqualToPoint(tilt.center, middle)) return;
    tilt.bounds = bounds;
    tilt.center = middle;
    [tilt setNeedsLayout];
    static dispatch_once_t once;
    dispatch_once(&once, ^{ SGLog(@"native player: the cover fills its room, %.0fpt in %@", side, NSStringFromCGRect(room)); });
}

static Class tiltClass(void) {
    static Class tilt;
    if (!tilt) tilt = NSClassFromString(@"_TtC35CreativeWorkCommons_CoverArtTiltKit16CoverArtTiltView");
    return tilt;
}

// Only the player's own cover cell; the legacy and listening party cells are left as Spotify lays them out.
static BOOL inCoverCell(UIView *tilt) {
    static Class cell;
    if (!cell) cell = NSClassFromString(@"_TtC28NowPlaying_ContentLayersImpl16CoverArtCellImpl");
    for (UIView *v = tilt.superview; v; v = v.superview) {
        if ([v isKindOfClass:cell]) return YES;
    }
    return NO;
}

%hook _TtC28NowPlaying_ContentLayersImpl16CoverArtCellImpl
- (void)layoutSubviews {
    %orig;
    if (!SGHidden(SGHideLyricsInline)) return;
    SGForEachView((UIView *)self, ^(UIView *view) {
        if ([view isKindOfClass:tiltClass()]) fillRoom(view);
    });
}
%end

// Again before the tilt view lays out, for a pass of Spotify's that sizes it without the cell laying out.
// Before %orig, so the cover inside follows, and Player.x's corners and shadow and PlayerGestures.x's hold,
// which hook the same method and work after it, see the new size.
%hook _TtC35CreativeWorkCommons_CoverArtTiltKit16CoverArtTiltView
- (void)layoutSubviews {
    UIView *tilt = (UIView *)self;
    if (SGHidden(SGHideLyricsInline) && inCoverCell(tilt)) fillRoom(tilt);
    %orig;
}
%end

%ctor {
    if (!SGNativeUI()) return;
    %init;
    SGRequireClasses(@[
        @"_TtC12Element_List18CollectionViewCell",
        @"_TtC20NowPlaying_ModesImpl28PlaybackControlsElementsUnit",
        @"_TtC20NowPlaying_ModesImpl18FooterElementsUnit",
        @"_TtC20NowPlaying_ModesImpl23InformationElementsUnit",
        @"_TtC22Lyrics_NPVContainerKit19LyricsContainerView",
        @"_TtC28NowPlaying_ContentLayersImpl16CoverArtCellImpl",
        @"_TtC35CreativeWorkCommons_CoverArtTiltKit16CoverArtTiltView",
    ]);
}
