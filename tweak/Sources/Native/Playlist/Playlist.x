// Playlist: hides parts of a playlist page, one switch each in Mod Settings > Home & Library. Album and
// artist pages are built by another framework and are left alone.
//
// The header parts are hidden from the layout pass that places them, not from the view
// controller's: the elements arrive after the page does, and a controller whose own view is not
// dirty never hears about it, so anything hidden a level up flashes first.
//
// Tree (trees/test-playlist.txt): HeaderContentLayout holds the cover over a block of title,
// description, the creator row, the length and HeaderActionsRow, a stack of the video deck, add,
// download, share and more. The header names every one of them with an accessibility identifier,
// so the switches go by those; the description and the find bar have none and go by class.
//
// The header's height is not measured from what it shows: -[SPTFreeTierPlaylistEncoreHeaderViewController
// update] adds three numbers into a stored fullHeaderHeight and pins headerViewHeightConstraint to
// it, so a hidden cover leaves the room it was counted for. collapseCover() takes that room back.
#import "Core/SGCore.h"
#import "Playlist.h"

@interface NSObject (SGPlaylistHeader)
- (NSLayoutConstraint *)headerViewHeightConstraint;
- (NSLayoutConstraint *)layoutGuideHeightConstraint;
@end

static const struct { __unsafe_unretained NSString *ident, *key; } buttons[] = {
    {@"Components.UI.WatchFeedEntityExplorerButton", SGHidePlaylistVideo},
    {@"Components.UI.AddToButton", SGHidePlaylistAddTo},
    {@"DownloadButton.Granular", SGHidePlaylistDownload},
    {@"Components.UI.ShareButton", SGHidePlaylistShare},
    {@"Components.UI.ContextMenuButton", SGHidePlaylistMore},
};
enum { kButtons = sizeof(buttons) / sizeof(buttons[0]) };

// Each part's view, remembered on the view it was found under (Core/SGViewTree.h).
static char kCoverKey, kDescriptionKey, kFindKey, kArtworkKey, kPillsKey, kButtonKeys[kButtons];

static BOOL anyButtonSwitch(void) {
    for (size_t i = 0; i < kButtons; i++) {
        if (SGHidden(buttons[i].key)) return YES;
    }
    return NO;
}

// The header layout is Encore's own class, so the hook asks whose page it is before touching it.
static UIViewController *playlistHeaderOf(UIView *view) {
    for (UIResponder *r = view; r; r = r.nextResponder) {
        if (![r isKindOfClass:UIViewController.class]) continue;
        return SGClassNamed(r.class, @"FreeTierPlaylist") ? (UIViewController *)r : nil;
    }
    return nil;
}

// Each switch only ever hides, here and below. A switch turned off again shows after Spotify restarts, like
// every other one.

// Title, description, the creator row and the length share one column, and only the description
// names a class of its own, so the column is reached through it and its rows go by what they hold.
// The length is the last row rather than the second stack: a byline without faces is a stack too.
// A row already hidden is passed over.
static void applyColumn(UIView *header) {
    BOOL hideDescription = SGHidden(SGHidePlaylistDescription), hideCreator = SGHidden(SGHidePlaylistCreator);
    BOOL hideLength = SGHidden(SGHidePlaylistLength);
    if (!hideDescription && !hideCreator && !hideLength) return;
    UIView *column = nil;
    UIView *description = SGFindRemembered(header, &kDescriptionKey, ^BOOL(UIView *v) { return SGClassNamed(v.class, @"ExpandableTextView"); });
    for (UIView *v = description; v && v != header; v = v.superview) {
        if (!SGClassNamed(v.superview.class, @"AutoLayoutStackView")) continue;
        column = v;
        break;
    }
    for (UIView *row in column.subviews) {
        if (row.hidden) continue;
        BOOL last = row == column.subviews.lastObject && SGClassNamed(row.class, @"StackView");
        BOOL hide = NO;
        if (SGHasClass(row, @"ExpandableTextView")) hide = hideDescription;
        else if (SGHasClass(row, @"FacepileView")) hide = hideCreator;
        else if (last) hide = hideLength;
        if (hide) row.hidden = YES;
    }
}

// The identifier sits on the button, the stack arranges the action around it, so each switch hides
// the action rather than the button and the row closes up behind it.
// An action already hidden is passed over.
static void applyActions(UIView *row) {
    // The buttons with a switch on, looked for under each action in one walk.
    NSString *idents[kButtons];
    const void *keys[kButtons];
    NSUInteger count = 0;
    for (size_t i = 0; i < kButtons; i++) {
        if (!SGHidden(buttons[i].key)) continue;
        idents[count] = buttons[i].ident;
        keys[count++] = &kButtonKeys[i];
    }
    if (!count) return;
    for (UIView *action in row.subviews) {
        if (action.hidden) continue;
        UIView *found[count];
        SGFindIdentifiers(action, count, idents, keys, found);
        for (NSUInteger i = 0; i < count && !action.hidden; i++) {
            if (found[i]) action.hidden = YES;
        }
    }
}

// Find on page and Sort sit in a header view of their own, one that holds nothing else.
static void applyFindBar(UIView *header) {
    if (!SGHidden(SGHidePlaylistFind)) return;
    UIView *field = SGFindRemembered(header, &kFindKey, ^BOOL(UIView *v) { return SGClassNamed(v.class, @"EncoreTextField"); });
    for (UIView *v = field; v && v != header; v = v.superview) {
        if (!SGClassNamed(v.class, @"HeaderView")) continue;
        v.hidden = YES;
        return;
    }
}

// Takes back the room the hidden cover was measured into. The cover swells to fill whatever the
// header's height leaves over, so the block below it moves up to where the cover began and the
// height constraints come down by as much; the cover then has nothing left to swell into.
//
// Both numbers are read back from the frames Spotify has just set, so once the header has shrunk
// the next pass finds nothing to take and stops. The header constraint holds the content layout
// and the top accessory above it, so it is the taller of the two; if it ever is not, it is not the
// constraint sizing this layout and nothing is touched -- which is also the brake that stops this
// shrinking for ever should the header stop following.
static void collapseCover(UIViewController *headerVC, UIView *layout, UIView *cover) {
    NSLayoutConstraint *height = [headerVC respondsToSelector:@selector(headerViewHeightConstraint)] ? [headerVC headerViewHeightConstraint] : nil;
    NSLayoutConstraint *guide = [headerVC respondsToSelector:@selector(layoutGuideHeightConstraint)] ? [headerVC layoutGuideHeightConstraint] : nil;
    CGFloat full = CGRectGetHeight(layout.bounds), before = height.constant;
    if (before < full) {
        static dispatch_once_t once;
        dispatch_once(&once, ^{ SGLog(@"playlist header: %.0f layout, header constraint %.0f, guide %.0f", full, before, guide.constant); });
        return;
    }

    CGFloat top = CGFLOAT_MAX, bottom = 0;
    for (UIView *v in layout.subviews) {
        if (v == cover) continue;
        top = MIN(top, CGRectGetMinY(v.frame));
        bottom = MAX(bottom, CGRectGetMaxY(v.frame));
    }
    if (top == CGFLOAT_MAX) return;

    CGFloat coverTop = CGRectGetMinY(cover.frame);
    CGFloat shift = coverTop > 0 && coverTop < top ? top - coverTop : 0;
    for (UIView *v in layout.subviews) {
        if (v != cover && shift > 0) v.frame = CGRectOffset(v.frame, 0, -shift);
    }

    CGFloat target = bottom - shift + (before - full);
    if (target > before - 0.5) return;
    height.constant = target;
    if (guide.constant > before - target) guide.constant -= before - target;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ SGLog(@"playlist header: layout %.0f, header %.0f -> %.0f, guide %.0f", full, before, target, guide.constant); });
}

static char kBackdropKey, kSourceKey;

// The cover blurred behind the header in place of Spotify's color wash. The header's background
// (trees/test6.txt) is a HeaderView under _backgroundViewContainer holding the wash, then a black
// view that fades in as the page scrolls; the backdrop goes between them so the scroll still darkens
// it, and its scrim ends in the black of the rows below. No cover, no backdrop: the wash stays.
static void applyBackdrop(UIView *layout) {
    if (!SGFlag(SGKeyPlaylistBackdrop, NO)) return;
    UIImage *image = nil;
    for (UIView *v in SGFindIdentifier(layout, @"EditableHeaderArtworkElement.ImageView", &kArtworkKey).subviews) {
        if ([v isKindOfClass:UIImageView.class] && ((UIImageView *)v).image) image = ((UIImageView *)v).image;
    }
    if (!image) return;

    UIView *container = nil;
    for (UIView *v = layout.superview; v && !container; v = v.superview) {
        for (UIView *sub in v.subviews) {
            if ([sub.accessibilityIdentifier isEqualToString:@"_backgroundViewContainer"]) container = sub;
        }
    }
    UIView *header = container.subviews.firstObject;
    if (header.subviews.count < 2) return;

    UIView *backdrop = objc_getAssociatedObject(header, &kBackdropKey);
    if (!backdrop) {
        backdrop = SGBackdropMake(header.bounds, 1);
        objc_setAssociatedObject(header, &kBackdropKey, backdrop, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (backdrop.superview != header) [header insertSubview:backdrop atIndex:1];

    UIImageView *sample = SGBackdropImageView(backdrop);
    if (objc_getAssociatedObject(sample, &kSourceKey) == image) return;
    objc_setAssociatedObject(sample, &kSourceKey, image, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    sample.image = SGBackdropSample(image);
}

%hook _TtC28EncoreConsumerMobile_BaseKit19HeaderContentLayout
- (void)layoutSubviews {
    %orig;
    UIViewController *headerVC = playlistHeaderOf((UIView *)self);
    if (!headerVC) return;
    UIView *layout = (UIView *)self, *cover = SGFindIdentifier(layout, @"Components.Header.UI.ArtworkImage", &kCoverKey);
    if (SGHidden(SGHidePlaylistArtwork)) cover.hidden = YES;
    applyColumn(layout);
    applyBackdrop(layout);
    if (cover.hidden) collapseCover(headerVC, layout, cover);
}
%end

// The cover loads after the header is laid out, and a new image does not lay the header out again.
%hook UIImageView
- (void)setImage:(UIImage *)image {
    %orig;
    if (!image || ![self.superview.accessibilityIdentifier isEqualToString:@"EditableHeaderArtworkElement.ImageView"]
        || !SGFlag(SGKeyPlaylistBackdrop, NO)) return;
    for (UIView *v = self.superview; v; v = v.superview) {
        if (!SGClassNamed(v.class, @"HeaderContentLayout")) continue;
        if (playlistHeaderOf(v)) applyBackdrop(v);
        return;
    }
}
%end

// The buttons fill in after the header is laid out, and a row that keeps its size never makes the
// header lay out again, so they stay up until something else does -- the cover loading, a second on.
%hook UIStackView
- (void)layoutSubviews {
    %orig;
    if ([self.accessibilityIdentifier isEqualToString:@"HeaderActionsRow"] && anyButtonSwitch() && playlistHeaderOf(self)) applyActions(self);
}
%end

// The find bar is not in the header layout, and it fades in on its own rather than appearing, so
// the controller's pass is soon enough for it.
%hook SPTFreeTierPlaylistEncoreHeaderViewController
- (void)viewDidLayoutSubviews {
    %orig;
    UIView *header = ((UIViewController *)self).viewIfLoaded;
    if (header) applyFindBar(header);
}
%end

// The pills are a cell of the track list. ListUXPlatform_LayoutKit.ListLayout gives every item its
// height, so a cell can only close up where the layout asks it how tall it wants to be; if it
// never asks, the log stays quiet and the pills stay.
%hook _TtC35ListUXPlatform_FreeTierPlaylistImpl25ElementCollectionViewCell
- (UICollectionViewLayoutAttributes *)preferredLayoutAttributesFittingAttributes:(UICollectionViewLayoutAttributes *)attributes {
    UICollectionViewLayoutAttributes *result = %orig;
    if (!SGHidden(SGHidePlaylistPills)
        || !SGFindIdentifier((UIView *)self, @"PlaylistCuration.Row.CurationActionsToolbar", &kPillsKey)) return result;
    result.size = CGSizeMake(result.size.width, 0);
    ((UIView *)self).clipsToBounds = YES;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ SGLog(@"playlist pills: asked for a height, answered 0"); });
    return result;
}
%end

%ctor {
    if (!SGNativeUI()) return;
    %init;
    SGRequireClasses(@[
        @"_TtC28EncoreConsumerMobile_BaseKit19HeaderContentLayout",
        @"SPTFreeTierPlaylistEncoreHeaderViewController",
        @"_TtC35ListUXPlatform_FreeTierPlaylistImpl25ElementCollectionViewCell",
    ]);
}
