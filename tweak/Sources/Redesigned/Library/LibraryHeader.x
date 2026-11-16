// Library redesign: the header of Your Library and of a folder inside it, the way Home and Search have theirs
// (Redesigned/Home/HomeHeader.x, Redesigned/Search/SearchPage.x). A large title at the leading edge, the avatar
// that opens the side drawer at the trailing edge, and the scrim Spotify lays behind the header gone, the soft
// scroll edge (Kit/SGREdgeEffect.x) being what keeps the header clear of the list scrolling under it.
//
// The filter chips under the row stay Spotify's own views and controls. They were taken out when the redesign was
// first built and the header closed up by the 49pt they left, and sorting a library turned out to be something the
// page cannot do without (issue #20); with them back the header keeps the height Spotify gives it and the list
// keeps Spotify's own inset, and there is nothing here to resize or to hold. Only the paint changes: an unselected
// chip's flat grey fill goes (SGRRepaint.x holds it clear when Spotify paints it back) and a glass capsule stands
// behind it, like the header's round buttons; a selected chip is that glass with its own colour over it as a tint
// (SGRSelectedChipPaint), and so is the cross that clears the filters, left of the chips. The header's own backing
// is gone and the list runs up under the chips (clearBacking, raiseList), so the glass has the rows to show; a
// folder's header gets the same, and its Back, ⋯ and + a glass circle each, like the root header's buttons.
//
// Tree (trees/clean/library/03.txt:1159-1247): YourLibraryView holds YourLibraryContentView, the size of the
// page, and after it -- so over it -- YourLibraryHeaderView 402x159.33: LiquidGlass.GradientView (the scrim), a
// 402x48 row at {0, 62} holding an AutoLayoutStackView {8, 0} 390x48 of
// ListeningActivity_ElementsKit.AdaptiveFaceContainer (the avatar, id=Components.UI.SideDrawerButton),
// id=YourLibraryHeader.title ("Your Library", 21pt), a spacer, a hidden id=YourLibraryHeader.recents,
// id=YourLibraryHeader.search and id=YourLibraryHeader.plus; and under the row
// YourLibraryHeaderContentFiltersView {0, 110} 402x49.33, the chips. Recents is hidden on the account the tree
// is of; the header's model shows it where it says isRecentsAvailable, a clock between the spacer and Search
// (issue #21), and it goes to the trailing edge with the others. A folder (trees/continuous/1.txt:325-344)
// is the same header under YourLibrary_FolderImpl, with id=YourLibraryFolderHeader.back at the leading edge,
// its title, then contextMenu, plus and play or pause, and the chips at {0, 118}.
//
// The header neither moves nor shrinks as the list scrolls -- 03.txt, 05.txt and 06.txt hold it at
// {0, 0} 402x159.33 at three scroll positions -- so there is nothing here to follow: the row is laid out once a
// pass and stays where it is put.
//
// Each control moves by a transform rather than by a frame. Spotify's stack lays them out from constraints of
// its own on every pass, and Auto Layout sets a view's center and bounds and leaves its transform alone, so the
// move outlives the pass that made it (Search moves the Browse cells the same way). Nothing leaves the stack:
// an arranged view of Spotify's that hides traps its stack in updateConstraints (Kit/SGRRestyle.h), so what
// goes is alpha, touches and accessibility, and the title Spotify draws goes that way while ours is a subview
// of the header the stack does not arrange.
//
// A move is worked out from where the stack put the control, so it holds only until the stack puts it somewhere
// else, and the stack does that on passes of its own that reach neither the header nor the page: the header's
// model arriving after the page first laid out shows or hides a button, the title gets its text, the avatar
// its size. A button just shown stands where it stood hidden, at the row's leading edge (Recents in 03.txt),
// until the stack's next pass places it. Moves worked out on the page's pass alone were then off by however
// far each control went since -- over the title, off the screen -- until the page laid out again on the way
// back from a playlist (issue #21). So the row the controls stand in is watched too, and every pass of its own
// places them again.

#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Library.h"
#import "Redesigned/Search/Search.h"

NSString *const SGRLibraryListIdentifier = @"YourLibraryContent.collectionView";

// Spotify's own inset for the header's controls: a 48pt button flush against the header's trailing edge has its
// 24pt glyph 20pt from the screen, and the 32pt avatar inside its own 48pt box 16pt from it, which is the
// margin Home gives the avatar.
static const CGFloat kRowInset = 8;
static char kTitleKey, kRowWatchedKey, kGroupGlassKey, kFolderGroupKey;
static char kRecentsKey, kSearchKey, kPlusKey, kHeaderTitleKey;
static char kRoundGlassKey;
static char kBackKey, kMenuKey, kFolderPlusKey, kPlayKey, kPauseKey, kFolderTitleKey;
static char kChipsKey, kChipGlassKey;
static char kContentKey, kListKey, kInsetKey;

static void vanish(UIView *view) {
    if (!view) return;
    if (view.alpha != 0) view.alpha = 0;
    if (view.userInteractionEnabled) view.userInteractionEnabled = NO;
    view.accessibilityElementsHidden = YES;
}

static UIView *childNamed(UIView *host, NSString *marker) {
    for (UIView *sub in host.subviews) {
        if ([NSStringFromClass(sub.class) containsString:marker]) return sub;
    }
    return nil;
}

void SGRLibraryClearScrim(UIView *header) {
    vanish(childNamed(header, @"GradientView"));
}

#pragma mark - the controls

// The header's controls, in the order they are to read from the leading edge, leaving out what this build does
// not have, what Spotify has hidden (a folder shows play or pause, never both) and what has not been laid out.
static NSMutableArray<UIView *> *controlsIn(UIView *header, NSArray<NSString *> *identifiers, const void *const keys[]) {
    UIView *controls[identifiers.count];
    SGRFindByIdentifiers(header, identifiers, keys, controls);
    NSMutableArray<UIView *> *found = [NSMutableArray array];
    for (NSUInteger i = 0; i < identifiers.count; i++) {
        UIView *control = controls[i];
        if (control && !control.hidden && control.alpha > 0.01 && control.bounds.size.width > 1) [found addObject:control];
    }
    return found;
}

// Puts the controls at the header's trailing edge, the last of them flush against it and each keeping the width
// it has, and answers where the leading edge of the first of them fell.
static CGFloat placeTrailing(UIView *header, NSArray<UIView *> *controls) {
    CGFloat right = header.bounds.size.width - kRowInset;
    for (UIView *control in controls.reverseObjectEnumerator) {
        CGFloat width = control.bounds.size.width;
        // The center is where Auto Layout put the control, whatever transform is on it; its frame is not.
        CGFloat natural = [control.superview convertPoint:CGPointZero toView:header].x + control.center.x - width / 2;
        CGAffineTransform move = CGAffineTransformMakeTranslation(right - width - natural, 0);
        if (!CGAffineTransformEqualToTransform(control.transform, move)) control.transform = move;
        right -= width;
    }
    return right;
}

// `place` again after every pass of the row the controls stand in (see the top of the file), for as long as it
// is in the header. The row is the stack's container, a plain UIView the Kit can watch; what `place` does not
// touch -- the header's height, the list under it -- stays the page's pass's.
static void watchRow(UIView *row, UIView *header, NSArray<UIView *> *(*place)(UIView *header)) {
    if (!row || objc_getAssociatedObject(row, &kRowWatchedKey)) return;
    objc_setAssociatedObject(row, &kRowWatchedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __weak UIView *weakHeader = header;
    SGRObserveLayout(row, ^(UIView *view) {
        UIView *owner = weakHeader;
        if (!owner || ![view isDescendantOfView:owner]) return;
        // Once, the first time the row's pass finds a control away from where the page's pass left it.
        static BOOL logged;
        NSMutableArray<NSNumber *> *before = logged ? nil : [NSMutableArray array];
        for (UIView *sub in before ? view.subviews : @[]) [before addObject:@(sub.transform.tx)];
        NSArray<UIView *> *placed = place(owner);
        if (!before || !owner.window) return;
        for (NSUInteger i = 0; i < before.count && i < view.subviews.count; i++) {
            if (fabs(view.subviews[i].transform.tx - before[i].doubleValue) < 0.5) continue;
            logged = YES;
            SGLog(@"redesign library: the header's row laid out on its own after the page, its %lu controls placed again",
                  (unsigned long)placed.count);
            break;
        }
    });
}

#pragma mark - the title

static NSString *textIn(UIView *label) {
    __block NSString *text = nil;
    SGForEachView(label, ^(UIView *view) {
        if (!text && [view isKindOfClass:UILabel.class] && ((UILabel *)view).text.length) text = ((UILabel *)view).text;
    });
    return text;
}

static UILabel *titleIn(UIView *header) {
    UILabel *title = objc_getAssociatedObject(header, &kTitleKey);
    if (!title) {
        title = [UILabel new];
        title.textColor = SGRPrimary();
        title.accessibilityTraits = UIAccessibilityTraitHeader;
        title.adjustsFontSizeToFitWidth = YES;
        title.minimumScaleFactor = 0.6;
        title.userInteractionEnabled = NO;
        objc_setAssociatedObject(header, &kTitleKey, title, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (title.superview != header) [header addSubview:title];
    return title;
}

// The title Spotify's own says, so it follows the app's language, in the Music app's size on the row's middle.
static void layoutTitle(UIView *header, UIView *spotifyTitle, CGFloat leading, CGFloat trailing, CGFloat middle) {
    UILabel *title = titleIn(header);
    NSString *text = textIn(spotifyTitle);
    if (text.length && ![title.text isEqualToString:text]) {
        title.text = text;
        title.accessibilityLabel = text;
    }
    UIFont *font = SGRFont(UIFontTextStyleLargeTitle, UIFontWeightBold, UIContentSizeCategoryLarge);
    if (![title.font isEqual:font]) title.font = font;

    CGFloat height = ceil(font.lineHeight);
    CGRect frame = CGRectMake(leading, round(middle - height / 2), MAX(0, trailing - SGRGrid - leading), height);
    if (!CGRectEqualToRect(title.frame, frame)) title.frame = frame;
}

#pragma mark - the two headers

static BOOL isFace(UIView *view) {
    return SGRIsAvatar(view);
}

// The root header's controls at its trailing edge, the avatar last, and the title before them. Answers what it
// placed in the order it reads, nothing while the header has no control laid out.
static NSArray<UIView *> *placeRoot(UIView *header) {
    UIView *spotifyTitle = SGRFindByIdentifier(header, @"YourLibraryHeader.title", &kHeaderTitleKey);
    vanish(spotifyTitle);
    static const void *keys[] = {&kRecentsKey, &kSearchKey, &kPlusKey};
    NSMutableArray<UIView *> *trailing = controlsIn(header, @[
        @"YourLibraryHeader.recents", @"YourLibraryHeader.search", @"YourLibraryHeader.plus",
    ], keys);
    __block UIView *face = nil;
    SGForEachView(header, ^(UIView *view) {
        if (!face && isFace(view) && view.bounds.size.width > 1) face = view;
    });
    if (face) [trailing addObject:face];
    if (!trailing.count) return trailing;

    CGFloat leading = placeTrailing(header, trailing);
    CGRect row = SGFrameIn(trailing.firstObject, header);
    layoutTitle(header, spotifyTitle, SGRSideMargin, leading, CGRectGetMidY(row));
    for (UIView *control in trailing) watchRow(control.superview, header, placeRoot);
    return trailing;
}

// The folder header's controls at its trailing edge and the title between them and the back button, which stays
// where Spotify has it. Answers what it placed in the order it reads, the back button first.
static NSArray<UIView *> *placeFolder(UIView *header) {
    UIView *spotifyTitle = SGRFindByIdentifier(header, @"YourLibraryFolderHeader.title", &kFolderTitleKey);
    vanish(spotifyTitle);
    UIView *back = SGRFindByIdentifier(header, @"YourLibraryFolderHeader.back", &kBackKey);
    static const void *keys[] = {&kMenuKey, &kFolderPlusKey, &kPlayKey, &kPauseKey};
    NSMutableArray<UIView *> *placed = controlsIn(header, @[
        @"YourLibraryFolderHeader.contextMenu", @"YourLibraryFolderHeader.plus",
        @"YourLibraryFolderHeader.play", @"YourLibraryFolderHeader.pause",
    ], keys);
    if (!placed.count && !back) return placed;

    CGFloat trailingEdge = placed.count ? placeTrailing(header, placed) : header.bounds.size.width - kRowInset;
    if (back) [placed insertObject:back atIndex:0];
    CGRect rowFrame = SGFrameIn(placed.firstObject, header);
    CGFloat leading = back ? CGRectGetMaxX(rowFrame) + SGRGrid : SGRSideMargin;
    layoutTitle(header, spotifyTitle, leading, trailingEdge, CGRectGetMidY(rowFrame));
    for (UIView *control in placed) watchRow(control.superview, header, placeFolder);
    return placed;
}

// The plain view FilterChipView draws its capsule fill with, under the label and the border: the first
// subview that is neither our glass nor one of Spotify's classes.
static UIView *chipFill(UIView *chip, UIView *glass) {
    for (UIView *sub in chip.subviews) {
        if (sub != glass && [sub isMemberOfClass:UIView.class]) return sub;
    }
    return nil;
}

// A selected chip is painted a solid colour of its own to say so (made a tint over the glass by SGRRepaint.x, so
// translucent but never the neutral white); an unselected one a translucent white that SGRRepaint.x now keeps from
// ever landing.
static BOOL chipIsSelected(UIView *fill) {
    CGColorRef color = fill.layer.backgroundColor;
    return color && CGColorGetAlpha(color) > 0.3;
}

// A chip grows and stretches under a finger below iOS 26 (SGGlassInteractive, with the legacy glass), and the
// views it stands in clip to their bounds: the cell, the stacks and the chips' collection, which is as tight as
// the chips themselves. They cut the grown capsule off at its edges. Every view from the chip up to the chips'
// row stops clipping; the row is as wide as the screen, so nothing shows that was not on screen already. The
// search results' chips (Search/SearchHeader.x) are the same views in a row of their own, and are taken the same way.
static BOOL inLibraryChips(UIView *view);
// The cross at the leading end of the chips while a filter is picked (Clear filters, a ClearChipView): a round chip
// of its own, a grey fill with the icon in it.
static BOOL isClearChip(UIView *view) {
    return [NSStringFromClass(view.class) hasSuffix:@"ClearChipView"];
}

static void unclipChip(UIView *chip) {
    if (!SGUseLegacyGlass() || !inLibraryChips(chip)) return;
    SGRUnclipUpTo(chip.superview, ^BOOL(UIView *v) {
        NSString *name = NSStringFromClass(v.class);
        return [name hasSuffix:@"YourLibraryHeaderContentFiltersView"] || [name containsString:@"AssistedCurationFiltersElement"]
            || [v.accessibilityIdentifier isEqualToString:SGRSearchFiltersIdentifier];
    });
}

// The glass goes in the chip itself, first among its subviews and under the fill, the way every round
// control of the header gets its own: a selected chip's solid colour then covers it by order, with no pass
// needed to take it away, and an unselected one's fill is clear, so what is seen through it is glass.
// (Glass inside the fill was above the fill's own paint, so the grey Spotify painted back showed through
// it, and a selected chip had the glass laid over its colour.)
static void glassChip(UIView *chip) {
    unclipChip(chip);
    UIView *fill = chipFill(chip, objc_getAssociatedObject(chip, &kChipGlassKey));
    SGRGlassChip(chip, fill, fill && !isClearChip(chip) && chipIsSelected(fill), &kChipGlassKey);
}

// Picking a filter makes the chips' collection lay them out again at new widths (the selected one grows, the
// others move or are reused), which reaches neither the header nor the page, so the glass kept the width it was
// given on the last page pass: a capsule too narrow or too wide for its chip, cut by the cell's clip, until the
// next tap laid the page out again. The chip is watched for its own layout and its glass is sized again on every
// pass of it (the legacy glass builds its mesh for a size, so autoresizing alone would not follow).
static void watchChip(UIView *chip) {
    SGRWatchLayout(chip, ^(UIView *view) { glassChip(view); });
}

// Playlists / Podcasts / Albums / Artists: each chip is Components.UI.FilterChips' own FilterChipView, a flat
// capsule unselected, unlike every other capsule the redesign gives a row of controls. Walked rather than
// hooked -- the class is a Swift one with no mangled name in the tree to hook by. The fill's repaint is
// held clear by SGRRepaint.x's hook, so this pass only has to make sure the glass is there.
static void glassChips(UIView *header) {
    UIView *chips = SGRFindByIdentifier(header, @"Components.UI.FilterChips", &kChipsKey);
    if (!chips) return;
    SGForEachView(chips, ^(UIView *v) {
        if (![NSStringFromClass(v.class) isEqualToString:@"EncoreConsumerMobile_BaseKit.FilterChipView"] && !isClearChip(v)) return;
        glassChip(v);
        watchChip(v);
    });
}

static BOOL isChipView(UIView *view) {
    return [NSStringFromClass(view.class) isEqualToString:@"EncoreConsumerMobile_BaseKit.FilterChipView"];
}

// Only the chips of a library header or a folder's, the search results' and the Find page's of the Add songs sheet
// (Songs / Artists / Albums: the same chips in an AssistedCurationFiltersElement), the rows of these chips
// that are glass: Home has chips of its own, with their own treatment.
static BOOL inLibraryChips(UIView *view) {
    for (UIView *v = view; v; v = v.superview) {
        if ([NSStringFromClass(v.class) hasSuffix:@"YourLibraryHeaderContentFiltersView"]) return YES;
        if ([v.accessibilityIdentifier isEqualToString:SGRSearchFiltersIdentifier]) return YES;
        if ([NSStringFromClass(v.class) containsString:@"AssistedCurationFiltersElement"]) return YES;
    }
    return NO;
}

// Asked on every paint of a chip's fill, so the answer is kept on the chip (a reused cell's chip stays in its row).
BOOL SGRIsGlassChip(UIView *chip) {
    static char kGlassChipKey;
    if (!chip) return NO;
    NSNumber *known = objc_getAssociatedObject(chip, &kGlassChipKey);
    if (known) return known.boolValue;
    if (!chip.window) return NO;
    BOOL glass = inLibraryChips(chip);
    objc_setAssociatedObject(chip, &kGlassChipKey, @(glass), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return glass;
}

// A chip's fill was painted (SGRRepaint.x): selecting a chip or letting it go repaints the fill and lays
// nothing out, so the glass stayed as the last layout left it. Deselected, the Playlists chip kept its glass
// hidden from the selected state and at the width of a chip that had been another one in the reused cell,
// and had no pill at all until the page happened to lay out.
void SGRLibraryChipPainted(UIView *chip) {
    if (!chip.window || !(isChipView(chip) || isClearChip(chip)) || !inLibraryChips(chip)) return;
    glassChip(chip);
    watchChip(chip);
}

// The chips' own collection lays out when a filter is picked or cleared: the cells are reloaded, a chip comes
// back in a cell that was another chip's or a new one, and the header's page, which glassChips walks from,
// is not laid out at all. Each pass of that collection takes every chip in it through the same two steps.
%group LegacyChips
%hook UICollectionView
- (void)layoutSubviews {
    %orig;
    UIView *collection = (UIView *)self;
    if (![collection.accessibilityIdentifier isEqualToString:@"Layout.CollectionView"] || !inLibraryChips(collection)) return;
    SGForEachView(collection, ^(UIView *v) {
        if (isChipView(v) || isClearChip(v)) { glassChip(v); watchChip(v); }
    });
}
%end
%end

#pragma mark - no backing

// Spotify backs the whole header, chips row included, with an opaque surface, and lays the list out below
// it, so the chips' glass had nothing but black behind it. The header's own paint goes (SGRRepaint.x holds it
// clear) and nothing stands in its place: the title row, the buttons and the chips float over the page. A plate
// of ours behind the title row stood at the size of the last layout pass and cut off any animation of the header,
// and the page behind it is black already. The list is stretched up under the chips row with an inset of the same
// height, so its first row still starts below the chips and the rest scroll under the glass. The chips row is
// YourLibraryHeaderContentFiltersView {0, 95} 390x52 of the 390x147 header.
static void clearBacking(UIView *header) {
    if (header.layer.backgroundColor) header.layer.backgroundColor = NULL;
}

// The list's page view moved up to the chips row and made taller by as much, and the list's top inset
// raised by the same: Spotify's own is read off the list and kept, and put back on whenever Spotify sets
// the inset again (told by the value not being the one written here). A list at its top stays at its top.
static void raiseList(UIView *page, UIView *header, UIView *filters) {
    CGFloat edge = CGRectGetMinY(filters.frame);
    CGFloat extra = header.bounds.size.height - edge;
    if (edge < 1 || extra < 1) return;
    UIView *content = SGRFindByIdentifier(page, @"YourLibraryContent.collectionView", &kContentKey).superview;
    if (!content || ![NSStringFromClass(content.class) hasSuffix:@"YourLibraryContentView"]) return;

    CGRect frame = CGRectMake(0, edge, page.bounds.size.width, page.bounds.size.height - edge);
    if (!CGRectEqualToRect(content.frame, frame)) content.frame = frame;

    UIView *found = SGRFindByIdentifier(content, SGRLibraryListIdentifier, &kListKey);
    if (![found isKindOfClass:UIScrollView.class]) return;
    UIScrollView *list = (UIScrollView *)found;
    NSNumber *written = objc_getAssociatedObject(list, &kInsetKey);
    UIEdgeInsets inset = list.contentInset;
    if (written && fabs(inset.top - written.doubleValue) < 0.5) return;

    BOOL atTop = list.contentOffset.y <= -list.adjustedContentInset.top + 1;
    inset.top += extra;
    // Noted before it is written, so that a pass inside the write reads the inset as ours.
    objc_setAssociatedObject(list, &kInsetKey, @(inset.top), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    list.contentInset = inset;
    UIEdgeInsets bar = list.verticalScrollIndicatorInsets;
    if (bar.top < extra) { bar.top += extra; list.verticalScrollIndicatorInsets = bar; }
    if (atTop) list.contentOffset = CGPointMake(list.contentOffset.x, -list.adjustedContentInset.top);
    SGLog(@"redesign library: list raised under the chips by %.0fpt, top inset %.1f", extra, inset.top);
}

// How far a group's capsule reaches past its first and last control: the 48pt buttons hold their glyphs well inside.
static const CGFloat kGroupPad = -2;

static void layoutRoot(UIView *page) {
    UIView *header = childNamed(page, @"YourLibraryHeaderView");
    if (!header) return;
    [header layoutIfNeeded];
    SGRLibraryClearScrim(header);
    if (SGBelowiOS26()) {
        glassChips(header);
        UIView *filters = childNamed(header, @"YourLibraryHeaderContentFiltersView");
        if (filters && header.bounds.size.height > 1) {
            clearBacking(header);
            raiseList(page, header, filters);
        }
    }

    NSArray<UIView *> *trailing = placeRoot(header);
    if (!trailing.count) return;

    // Search, + and the avatar, side by side, stand on one 44pt glass capsule, as iOS 26 groups a bar's buttons and as
    // Home's pill holds its own (a circle each read as three loose buttons).
    if (SGBelowiOS26()) {
        UIView *host = trailing.firstObject.superview;
        BOOL shared = YES;
        for (UIView *control in trailing) shared = shared && control.superview == host;
        // The two looks are exclusive: switching from one to the other hides the glass the earlier passes made.
        if (shared && trailing.count > 1) {
            SGRGlassGroupPill(host, trailing, &kGroupGlassKey, 44, kGroupPad);
            for (UIView *control in trailing) {
                UIView *round = objc_getAssociatedObject(control, &kRoundGlassKey);
                if (round && !round.hidden) round.hidden = YES;
            }
        } else {
            if (host) SGRGlassGroupPill(host, @[], &kGroupGlassKey, 44, kGroupPad);
            for (UIView *control in trailing) SGRGlassInside(control, &kRoundGlassKey, 44);
        }
    }

    // The first pass that laid the header out, not the first pass at all: a page appearing lays out before
    // its controls have a size, and a line off that pass would say the header was left as Spotify's.
    UIView *face = isFace(trailing.lastObject) ? trailing.lastObject : nil;
    static BOOL logged;
    if (!logged && header.window && face) {
        logged = YES;
        SGLog(@"redesign library: header %@, %lu controls at the trailing edge, avatar %@, chips %@",
              NSStringFromCGRect(header.frame), (unsigned long)trailing.count, face ? @"found" : @"not found",
              childNamed(header, @"YourLibraryHeaderContentFiltersView") ? @"Spotify's" : @"not found");
    }
}

static void layoutFolder(UIView *page) {
    UIView *header = childNamed(page, @"FolderHeaderView");
    if (!header) return;
    [header layoutIfNeeded];
    SGRLibraryClearScrim(header);
    if (SGBelowiOS26()) {
        glassChips(header);
        UIView *filters = childNamed(header, @"YourLibraryHeaderContentFiltersView");
        if (filters && header.bounds.size.height > 1) {
            clearBacking(header);
            raiseList(page, header, filters);
        }
    }

    NSArray<UIView *> *placed = placeFolder(header);
    if (!placed.count) return;

    // Back, ⋯ and Create playlist (+) are plain buttons with nothing behind them; Play is left as Spotify's.
    if (SGBelowiOS26()) {
        UIView *back = SGRFindByIdentifier(header, @"YourLibraryFolderHeader.back", &kBackKey);
        UIView *more = SGRFindByIdentifier(header, @"YourLibraryFolderHeader.contextMenu", &kMenuKey);
        UIView *plus = SGRFindByIdentifier(header, @"YourLibraryFolderHeader.plus", &kFolderPlusKey);
        // Back alone on a circle; ⋯ and + beside each other on one capsule, as on the root header.
        if (back.bounds.size.width >= 1) SGRGlassInside(back, &kRoundGlassKey, 44);
        NSMutableArray<UIView *> *pair = [NSMutableArray array];
        for (UIView *control in @[more ?: (id)NSNull.null, plus ?: (id)NSNull.null]) {
            if ([control isKindOfClass:UIView.class] && control.bounds.size.width >= 1) [pair addObject:control];
        }
        if (pair.count > 1 && pair.firstObject.superview == pair.lastObject.superview) {
            SGRGlassGroupPill(pair.firstObject.superview, pair, &kFolderGroupKey, 44, kGroupPad);
        } else {
            for (UIView *control in pair) SGRGlassInside(control, &kRoundGlassKey, 44);
        }
    }

    UIView *back = SGRFindByIdentifier(header, @"YourLibraryFolderHeader.back", &kBackKey);
    NSUInteger trailing = placed.count - (back ? 1 : 0);
    static BOOL logged;
    if (!logged && header.window && trailing) {
        logged = YES;
        SGLog(@"redesign library: folder header %@, back %@, %lu controls at the trailing edge, chips %@",
              NSStringFromCGRect(header.frame), back ? @"found" : @"not found", (unsigned long)trailing,
              childNamed(header, @"YourLibraryHeaderContentFiltersView") ? @"Spotify's" : @"not found");
    }
}

%hook _TtC28YourLibrary_YourLibraryXImpl15YourLibraryView
- (void)layoutSubviews {
    %orig;
    layoutRoot((UIView *)self);
}
%end

%hook _TtC22YourLibrary_FolderImpl10FolderView
- (void)layoutSubviews {
    %orig;
    layoutFolder((UIView *)self);
}
%end

%ctor {
    if (!SGRedesignedUI()) return;
    %init;
    if (SGBelowiOS26()) { %init(LegacyChips); }
    SGRequireClasses(@[
        @"_TtC28YourLibrary_YourLibraryXImpl15YourLibraryView",
        @"_TtC22YourLibrary_FolderImpl10FolderView",
        @"_TtC21YourLibrary_CommonKit35YourLibraryHeaderContentFiltersView",
        @"_TtC29ListeningActivity_ElementsKit21AdaptiveFaceContainer",
    ]);
}
