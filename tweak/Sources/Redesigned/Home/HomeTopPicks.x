// Home redesign: Top picks, the first shelf of cards drawn large the way the Music app draws its top shelf:
// each card the cover edge to edge over a footer in the cover's color, 60% of the page wide so the next one
// shows at the trailing edge.
//
// A shelf is a Home_CarouselKit.TouchCancellingCollectionView in a cell of the page's list (HomeSections.x), a
// compositional layout of its own with cards under a 40pt heading (9.1.78: cards 149 by 195, a square picture
// over 46pt of text; 9.1.90's Recents: 98 by 144, the picture 94 at 2pt in, over 38pt of text). Its sizes are
// Spotify's, made by the layout's section provider each time the layout is asked for one. So every
// compositional layout's provider is wrapped, and while the large shelf's provider runs, a size kSmallest or
// more wide is made as many times wider as the card needs to reach kCardShare of the page, and taller by what
// the card grows: the card to its new width plus kFooter, the row that holds the cards by the same amount.
// The page's cell is made taller by the same amount.
//
// The shelf drawn large is the one nearest the top of the page: the lowest index any shelf has been measured at. One
// Cards from names is taken from the feed's model (HomeFeed.swift) as soon as any section is measured, since its own
// cell is built only once it nears the screen; the heading on screen still decides when the model can't be read.
// Cells are reused across shelves, so each measuring sets or clears the mark on the layout it holds.
//
// A large card (SGRHomeStyleLargeCard, from HomeCards.x on every layout of the card) keeps Spotify's button, cover
// and touch. A surface in the cover's color (SGRHomeTintForCover) goes behind everything, the cover's top corners
// take the card's radius, and two labels of the Kit's own stand in the footer over Spotify's, which go
// transparent: the leading one bold with what Spotify says under the title ("Album • Artist", or the makers of a
// mix), the other the title in the secondary color, which is how the reference lays its footer out. A card with
// no second line leads with its title.
#import <objc/runtime.h>
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Home.h"

static const CGFloat kCardShare = 0.6, kFooter = 76, kSmallest = 80, kHeading = 40;
// A card this wide or wider is one drawn large: Spotify's widest is 153.
static const CGFloat kLargeCard = 200;
static const CGFloat kFooterTop = 12, kFooterGap = 2;
// How far under the page's title the large shelf's cards sit, once its heading has gone.
// The reference's cards start 2pt above the feed's top (110pt on a 393pt phone against the feed's 112).
static const CGFloat kBandAbove = -2;
// The footer's text, in from the card's edges (the reference's first glyph sits 13.7pt in; a glyph's side bearing
// is about 1.5).
static const CGFloat kFooterInset = 12;
static char kLargeKey, kNaturalKey, kWrappedKey, kGrowKey, kAskedKey, kListKey, kOffsetKey, kHeldKey, kShowAllKey, kHeadingKey, kServedKey;
static __weak UICollectionView *sg_largeShelf;
static _Thread_local BOOL sg_enlarging;
// The list section the shortcuts grid is in, from its measuring; NSNotFound until one is.
static NSInteger sg_gridSection = NSNotFound;
static _Thread_local CGFloat sg_containerWidth;
// Spotify's card in the running provider: the narrowest size kSmallest or more wide, and how much taller the
// large one is than it. 0 until a card is made.
static _Thread_local CGFloat sg_cardWidth, sg_cardGrow;
static NSInteger sg_topIndex = NSIntegerMax;
// SGRKeyHomeTopPicksHeading, read at launch.
static BOOL sg_showHeading;

// The layout a wrapped provider belongs to, set once the layout is made.
@interface SGRLayoutBox : NSObject
@property (nonatomic, weak) UICollectionViewCompositionalLayout *layout;
@end
@implementation SGRLayoutBox
@end

static CGFloat targetWidth(void) {
    return round(sg_containerWidth * kCardShare);
}

// The large shelf's heading goes, and the band it took with it, unless Show Top picks heading keeps both. Its
// section's header is a boundary item (kind UICollectionElementKindSectionHeader, 39pt tall over the cards on
// 9.1.90, extending the section); it is made again not extending the section, so it takes no room and lies over the
// cards' top instead, where it stays in the shelf's visible rect, and so alive with the Show all the header's menu
// offers, transparent and without touches (the shelf's layout pass). The section's top inset goes the same way. What
// they took together is the band the shelf's cell loses (kOffsetKey, read as the cell is measured).
static void headingAside(NSCollectionLayoutSection *made, UICollectionViewLayout *layout) {
    NSMutableArray<NSCollectionLayoutBoundarySupplementaryItem *> *items = [NSMutableArray array];
    CGFloat band = made.contentInsets.top;
    for (NSCollectionLayoutBoundarySupplementaryItem *item in made.boundarySupplementaryItems) {
        if (![item.elementKind isEqualToString:UICollectionElementKindSectionHeader] || !item.extendsBoundary) {
            [items addObject:item];
            continue;
        }
        NSCollectionLayoutBoundarySupplementaryItem *aside = [NSCollectionLayoutBoundarySupplementaryItem boundarySupplementaryItemWithLayoutSize:item.layoutSize
                                                                                                                                      elementKind:item.elementKind
                                                                                                                                        alignment:item.alignment];
        aside.extendsBoundary = NO;
        aside.pinToVisibleBounds = item.pinToVisibleBounds;
        aside.zIndex = item.zIndex;
        [items addObject:aside];
        if (item.layoutSize.heightDimension.isAbsolute || item.layoutSize.heightDimension.isEstimated) band += item.layoutSize.heightDimension.dimension;
    }
    made.boundarySupplementaryItems = items;
    NSDirectionalEdgeInsets insets = made.contentInsets;
    insets.top = 0;
    made.contentInsets = insets;
    if (layout) objc_setAssociatedObject(layout, &kOffsetKey, band > 0 ? @(band) : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static UICollectionViewCompositionalLayoutSectionProvider wrapped(UICollectionViewCompositionalLayoutSectionProvider provider, SGRLayoutBox *box) {
    return ^NSCollectionLayoutSection *(NSInteger section, id<NSCollectionLayoutEnvironment> environment) {
        UICollectionViewCompositionalLayout *layout = box.layout;
        BOOL was = sg_enlarging;
        CGFloat wasWidth = sg_cardWidth, wasGrow = sg_cardGrow, wasContainer = sg_containerWidth;
        sg_enlarging = layout && objc_getAssociatedObject(layout, &kLargeKey) != nil;
        sg_containerWidth = environment.container.effectiveContentSize.width;
        sg_cardWidth = sg_cardGrow = 0;
        NSCollectionLayoutSection *made = provider(section, environment);
        if (sg_enlarging && made && !sg_showHeading) headingAside(made, layout);
        if (layout && sg_cardGrow > 0) objc_setAssociatedObject(layout, &kGrowKey, @(sg_cardGrow), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        sg_enlarging = was;
        sg_cardWidth = wasWidth;
        sg_cardGrow = wasGrow;
        sg_containerWidth = wasContainer;
        return made;
    };
}

static UICollectionViewCompositionalLayout *boxed(UICollectionViewCompositionalLayout *made, SGRLayoutBox *box) {
    box.layout = made;
    if (made) objc_setAssociatedObject(made, &kWrappedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return made;
}

#pragma mark - the shelf above the grid

// Spotify's feed puts the shortcuts grid first and the shelves after it; the reference puts the large shelf first,
// right under the title, and the grid under it. The list's layout is Spotify's, one cell per section, so its
// attributes are moved as the list asks for them: the shelf's block takes the grid's place and the grid's moves
// down by the shelf's height, the gap between them kept. The sections between (dropped, 0 tall) stay where they
// are. Nothing else about the layout changes: its content size and every other section's place are its own.
static _Thread_local BOOL sg_unmoved;   // reading the layout's own frames, not the moved ones

// The grid's and the shelf's frames as the layout has them, and where the sections before the shelf end (the
// grid's bottom, or a kept shelf's when Cards from names a later one), worked out once per layout pass (the
// cache goes as the layout prepares again); NO while there is no swap to make. The sections and items asked for
// are checked against what the list has now: the feed can have changed under the indexes the measuring left.
static void topLost(UICollectionView *list);
static __weak UICollectionViewLayout *sg_blocksLayout;
static BOOL sg_blocksKnown, sg_blocksSwap;
static CGRect sg_blocksGrid, sg_blocksShelf;
static CGFloat sg_blocksBefore;
// The sections the cached frames belong to: move() reads these, not the globals, which the measuring can change
// between two queries of one pass.
static NSInteger sg_blocksGridSection, sg_blocksShelfSection;

static BOOL blocks(UICollectionViewLayout *layout, CGRect *grid, CGRect *shelf, CGFloat *before) {
    if (!objc_getAssociatedObject(layout, &kListKey)) return NO;
    if (sg_blocksKnown && sg_blocksLayout == layout) {
        *grid = sg_blocksGrid;
        *shelf = sg_blocksShelf;
        *before = sg_blocksBefore;
        return sg_blocksSwap;
    }
    sg_blocksLayout = layout;
    sg_blocksKnown = YES;
    sg_blocksSwap = NO;
    NSInteger shelfSection = sg_topIndex == NSIntegerMax ? NSNotFound : sg_topIndex / 10000, shelfItem = sg_topIndex % 10000;
    sg_blocksGridSection = sg_gridSection;
    sg_blocksShelfSection = shelfSection;
    if (sg_gridSection == NSNotFound || shelfSection == NSNotFound || sg_gridSection >= shelfSection) return NO;
    UICollectionView *list = layout.collectionView;
    NSInteger sections = list.numberOfSections;
    if (sg_gridSection >= sections || [list numberOfItemsInSection:sg_gridSection] < 1) {
        sg_gridSection = NSNotFound;
        return NO;
    }
    if (shelfSection >= sections || shelfItem >= [list numberOfItemsInSection:shelfSection]) {
        // The feed changed under the index (a filter, a reload): the shelves on screen are measured again for a new top.
        topLost(list);
        return NO;
    }
    sg_unmoved = YES;
    UICollectionViewLayoutAttributes *a = [layout layoutAttributesForItemAtIndexPath:[NSIndexPath indexPathForItem:0 inSection:sg_gridSection]];
    UICollectionViewLayoutAttributes *b = [layout layoutAttributesForItemAtIndexPath:[NSIndexPath indexPathForItem:shelfItem inSection:shelfSection]];
    CGFloat last = CGRectGetMaxY(a.frame);
    if (a && b) {
        for (UICollectionViewLayoutAttributes *between in [layout layoutAttributesForElementsInRect:CGRectUnion(a.frame, b.frame)]) {
            NSInteger section = between.indexPath.section;
            if (section >= sg_gridSection && section < shelfSection) last = MAX(last, CGRectGetMaxY(between.frame));
        }
    }
    sg_unmoved = NO;
    if (!a || !b || last > CGRectGetMinY(b.frame)) return NO;
    *grid = sg_blocksGrid = a.frame;
    *shelf = sg_blocksShelf = b.frame;
    *before = sg_blocksBefore = last;
    sg_blocksSwap = YES;
    return YES;
}

// The shelf's block takes the grid's place, kBandAbove higher (the reference's cards start 2pt above the feed's
// top); the grid and everything between it and the shelf move down by the shelf's block, the gap above the shelf
// (its section inset) kept between the two.
static void move(UICollectionViewLayoutAttributes *attributes, CGRect grid, CGRect shelf, CGFloat before) {
    NSInteger section = attributes.indexPath.section, gridSection = sg_blocksGridSection, shelfSection = sg_blocksShelfSection;
    CGRect frame = attributes.frame;
    if (section >= gridSection && section < shelfSection) frame.origin.y += CGRectGetMaxY(shelf) - before + kBandAbove;
    else if (section == shelfSection) frame.origin.y += CGRectGetMinY(grid) - CGRectGetMinY(shelf) + kBandAbove;
    else return;
    attributes.frame = frame;
}

%hook UICollectionViewCompositionalLayout
- (instancetype)initWithSectionProvider:(UICollectionViewCompositionalLayoutSectionProvider)provider
                          configuration:(UICollectionViewCompositionalLayoutConfiguration *)configuration {
    if (!provider) return %orig;
    SGRLayoutBox *box = [SGRLayoutBox new];
    return boxed(%orig(wrapped(provider, box), configuration), box);
}
- (instancetype)initWithSectionProvider:(UICollectionViewCompositionalLayoutSectionProvider)provider {
    if (!provider) return %orig;
    SGRLayoutBox *box = [SGRLayoutBox new];
    return boxed(%orig(wrapped(provider, box)), box);
}
- (void)prepareLayout {
    %orig;
    if (sg_blocksLayout == (UICollectionViewLayout *)self) sg_blocksKnown = NO;
}

- (NSArray<UICollectionViewLayoutAttributes *> *)layoutAttributesForElementsInRect:(CGRect)rect {
    if (sg_unmoved) return %orig;
    CFTimeInterval began = SGRHomeProbeBegin();
    CGRect grid, shelf;
    CGFloat before;
    BOOL swap = blocks((UICollectionViewLayout *)self, &grid, &shelf, &before);
    // Everything between the two blocks moves within their band, so the band is asked for whole. The moved blocks reach
    // kBandAbove past the layout's own: a rect that touches only that strip (the prefetch rect above the feed's top,
    // as Home is pulled to refresh) gets the shelf too, or the list takes its cell for gone and keeps it hidden.
    CGRect own = CGRectUnion(grid, shelf);
    CGRect band = swap ? CGRectUnion(own, CGRectOffset(own, 0, kBandAbove)) : CGRectZero;
    if (!swap || !CGRectIntersectsRect(rect, band)) {
        SGRHomeProbeEnd(SGRHomeProbeListAttrs, began);
        return %orig;
    }
    NSMutableArray<UICollectionViewLayoutAttributes *> *moved = [NSMutableArray array];
    CGRect whole = CGRectUnion(rect, band);
    NSArray<UICollectionViewLayoutAttributes *> *all = %orig(whole);
    for (UICollectionViewLayoutAttributes *attributes in all) {
        UICollectionViewLayoutAttributes *copy = [attributes copy];
        move(copy, grid, shelf, before);
        if (CGRectIntersectsRect(copy.frame, rect)) [moved addObject:copy];
    }
    SGRHomeProbeEnd(SGRHomeProbeListAttrs, began);
    return moved;
}

- (UICollectionViewLayoutAttributes *)layoutAttributesForItemAtIndexPath:(NSIndexPath *)indexPath {
    UICollectionViewLayoutAttributes *attributes = %orig;
    if (sg_unmoved || !attributes) return attributes;
    CFTimeInterval began = SGRHomeProbeBegin();
    CGRect grid, shelf;
    CGFloat before;
    if (blocks((UICollectionViewLayout *)self, &grid, &shelf, &before)) {
        attributes = [attributes copy];
        move(attributes, grid, shelf, before);
    }
    SGRHomeProbeEnd(SGRHomeProbeListAttrs, began);
    return attributes;
}
%end

%hook NSCollectionLayoutSize
+ (instancetype)sizeWithWidthDimension:(NSCollectionLayoutDimension *)width heightDimension:(NSCollectionLayoutDimension *)height {
    if (!width.isAbsolute || width.dimension < kSmallest || sg_containerWidth <= 0) return %orig;
    BOOL sized = height.isAbsolute || height.isEstimated;
    // The cards come first, then the row that holds them all (1634 by 195 on the phone): the row is as many cards
    // wide, so it widens as much, but grows in height only as much as a card does.
    if (sg_cardWidth == 0 || width.dimension < sg_cardWidth) {
        sg_cardWidth = width.dimension;
        if (sized) sg_cardGrow = MAX(0, targetWidth() + kFooter - height.dimension);
    }
    if (!sg_enlarging || !sized || sg_cardGrow <= 0) return %orig;
    CGFloat scale = targetWidth() / sg_cardWidth;
    NSCollectionLayoutDimension *wider = [NSCollectionLayoutDimension absoluteDimension:round(width.dimension * scale)];
    NSCollectionLayoutDimension *taller = height.isAbsolute ? [NSCollectionLayoutDimension absoluteDimension:height.dimension + sg_cardGrow]
                                                            : [NSCollectionLayoutDimension estimatedDimension:height.dimension + sg_cardGrow];
    return %orig(wider, taller);
}
%end

#pragma mark - the shelf Cards from names, from the feed

// HomeFeed.swift.
@interface SGRHomeFeed : NSObject
+ (NSArray *)headingsOf:(id)page;
@end

// The model's identities as last read (NSNull for a section with no heading) and the list's section count then.
// Spotify's feed comes again with a new count nearly always (30 to 31 at launch, 18, 20, 21 through a refresh on
// 9.1.90); one that keeps the count is caught by the first heading read off a cell that disagrees with it.
static NSArray *sg_feed;
static NSInteger sg_feedSections = -1;
// The model the top was taken from, while no heading has borne it out; and the model a heading read off the top's
// own cell contradicted, with the Cards from it was for: that answer is not taken again, or the top would be lost
// and found on every pass.
static NSArray *sg_topFeed, *sg_overruled;
static NSString *sg_overruledFrom;

// One identity per section of the list from the model, nil when the model can't be read or does not match the
// list's sections (a snapshot the list has not taken yet).
static NSArray *feed(UICollectionView *list) {
    NSInteger sections = list.numberOfSections;
    if (sg_feed && sg_feedSections == sections) return sg_feed;
    CFTimeInterval began = SGRHomeProbeBegin();
    NSArray *headings = [SGRHomeFeed headingsOf:list.delegate];
    NSMutableArray *identities = [NSMutableArray arrayWithCapacity:headings.count];
    for (id heading in headings) {
        [identities addObject:[heading isKindOfClass:NSArray.class] ? SGRHomeShelfIdentityFrom(heading[0], heading[1]) : NSNull.null];
    }
    SGRHomeProbeEnd(SGRHomeProbeFeed, began);
    sg_feed = headings && (NSInteger)headings.count == sections ? identities : nil;
    sg_feedSections = sections;
    return sg_feed;
}

// The section's identity in the model, nil for none or when the model can't be read.
static NSString *feedIdentity(UICollectionView *list, NSInteger section) {
    NSArray *identities = feed(list);
    id identity = section < (NSInteger)identities.count ? identities[section] : nil;
    return [identity isKindOfClass:NSString.class] ? identity : nil;
}

// A heading read off a shelf's cell that is not what the model last said of its section: the model moved on under
// the same section count, and is read again.
static void feedRead(UICollectionView *list, NSInteger section, NSString *onScreen) {
    if (!sg_feed || sg_feedSections != list.numberOfSections || section >= (NSInteger)sg_feed.count) return;
    id entry = sg_feed[section];
    if ([entry isKindOfClass:NSString.class] && [entry isEqualToString:onScreen]) return;
    SGLog(@"redesign home: the feed's model moved on under section %ld (\"%@\" on screen, %@ in the model)", (long)section, onScreen, entry);
    sg_feed = nil;
}

// With no top yet and Cards from naming a shelf, the top is that shelf's section in the model, measured or not: the
// swap brings its cell on screen, and its measuring draws it large.
static void topFromFeed(UICollectionView *list) {
    NSString *from = SGRHomeTopPicksFrom();
    if (sg_topIndex != NSIntegerMax || !from || SGRHomeShelfHidden(from)) return;
    NSArray *identities = feed(list);
    NSUInteger section = [identities indexOfObject:from];
    if (section == NSNotFound || ([identities isEqualToArray:sg_overruled] && [from isEqualToString:sg_overruledFrom])) return;
    sg_topIndex = (NSInteger)section * 10000;
    sg_topFeed = identities;
    sg_blocksKnown = NO;
    // Mid-measure here: the list lays out again once this pass is over, so the swap shows now and not on a scroll.
    __weak UICollectionView *weakList = list;
    dispatch_async(dispatch_get_main_queue(), ^{ [weakList.collectionViewLayout invalidateLayout]; });
}

// The top shelf is no longer one (hidden, not the one Cards from names, or gone with the feed): the page's color goes,
// and every shelf on screen is measured again, so the next one takes the place now rather than on the next scroll.
static void topLost(UICollectionView *list) {
    sg_topIndex = NSIntegerMax;
    sg_topFeed = nil;
    sg_blocksKnown = NO;
    sg_largeShelf = nil;
    SGRHomeSetPageTint(nil);
    static Class shelf;
    if (!shelf) shelf = NSClassFromString(@"_TtC16Home_CarouselKit29TouchCancellingCollectionView");
    for (UICollectionViewCell *cell in list.visibleCells) {
        UIView *root = cell.contentView.subviews.firstObject.subviews.firstObject;
        if (shelf && [root isKindOfClass:shelf]) SGRHomeMeasureAgain(root);
    }
}

// A shelf stops being large: its mark goes, and what read the mark as "the top" (the Show all control, the page's
// color) with it. Its cells are made again from Spotify's layout: a cell the new layout puts off screen kept its old
// frame on screen.
static void dropLarge(UICollectionView *shelf) {
    objc_setAssociatedObject(shelf.collectionViewLayout, &kLargeKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (sg_largeShelf == shelf) sg_largeShelf = nil;
    SGRHomeSetPageTint(nil);
    [shelf.collectionViewLayout invalidateLayout];
    __weak UICollectionView *weakShelf = shelf;
    dispatch_async(dispatch_get_main_queue(), ^{ [weakShelf reloadData]; });
}

%hook _TtC12Element_List18CollectionViewCell
- (UICollectionViewLayoutAttributes *)preferredLayoutAttributesFittingAttributes:(UICollectionViewLayoutAttributes *)attributes {
    static Class shelf;
    if (!shelf) shelf = NSClassFromString(@"_TtC16Home_CarouselKit29TouchCancellingCollectionView");
    UIView *content = ((UICollectionViewCell *)self).contentView.subviews.firstObject;
    // Home's sections only, as HomeSections.x tells them: a shelf on another page is not Home's top.
    if (![NSStringFromClass(object_getClass(content)) containsString:@"Home_EvoPageImpl13HomeStructure"]) return %orig;
    UIView *root = content.subviews.firstObject;
    NSInteger index = attributes.indexPath.section * 10000 + attributes.indexPath.item;
    UIView *list = ((UIView *)self).superview;
    while (list && ![list isKindOfClass:UICollectionView.class]) list = list.superview;
    if (list) objc_setAssociatedObject(((UICollectionView *)list).collectionViewLayout, &kListKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    // The heading on screen, read before the measuring sizes the cell; nil while the shelf has none to read, when
    // the model's heading for the section stands in.
    NSString *onScreen = nil;
    // Spotify reuses a shelf's view for another section as the feed scrolls (and for another shelf at the same index
    // when the feed comes again), and its layout, which carries the mark and the sizes read from it, comes along. A
    // view serving a new shelf drops both before Spotify lays it out for this measuring: the other shelf's cards are
    // never drawn large for a pass, and a view back on the top is measured at Spotify's size first, then made large.
    if (shelf && [root isKindOfClass:shelf]) {
        UICollectionViewLayout *layout = ((UICollectionView *)root).collectionViewLayout;
        BOOL marked = objc_getAssociatedObject(layout, &kLargeKey) != nil;
        if (marked && index != sg_topIndex) dropLarge((UICollectionView *)root);
        onScreen = SGRHomeShelfIdentity(root);
        if (list && onScreen) feedRead((UICollectionView *)list, attributes.indexPath.section, onScreen);
        // The same name before and after the heading comes in, so the sizes and the mark stay with the shelf.
        NSString *served = onScreen ?: (list ? feedIdentity((UICollectionView *)list, attributes.indexPath.section) : nil) ?: [@(index) stringValue];
        if (![served isEqualToString:objc_getAssociatedObject(layout, &kServedKey)]) {
            objc_setAssociatedObject(layout, &kServedKey, served, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            char *keys[] = {&kNaturalKey, &kGrowKey, &kOffsetKey, &kAskedKey};
            for (size_t i = 0; i < sizeof(keys) / sizeof(keys[0]); i++) objc_setAssociatedObject(layout, keys[i], nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            if (objc_getAssociatedObject(layout, &kLargeKey)) dropLarge((UICollectionView *)root);
        }
    }
    UICollectionViewLayoutAttributes *result = %orig;
    if (list) topFromFeed((UICollectionView *)list);
    if (!shelf || ![root isKindOfClass:shelf] || result.size.height <= kHeading) {
        // The top's place holds something else now (the feed came again): the next shelf measured takes it.
        if (index == sg_topIndex) topLost((UICollectionView *)list);
        // The shortcuts grid is the one bare list Home has (HomeSections.x); a section of anything else in its place
        // (no shortcuts) leaves the order alone.
        BOOL grid = [root isKindOfClass:UICollectionView.class] && !(shelf && [root isKindOfClass:shelf]) && !root.accessibilityIdentifier.length
                    && result.size.height > 0;
        if (grid) sg_gridSection = attributes.indexPath.section;
        else if (attributes.indexPath.section == sg_gridSection) sg_gridSection = NSNotFound;
        sg_blocksKnown = NO;
        return result;
    }
    UICollectionViewLayout *layout = ((UICollectionView *)root).collectionViewLayout;
    // The shelf drawn large: the one Cards from names, else the one nearest the top; never one switched off.
    NSString *identity = onScreen ?: feedIdentity((UICollectionView *)list, attributes.indexPath.section), *from = SGRHomeTopPicksFrom();
    BOOL candidate = !SGRHomeShelfHidden(identity) && (!from || [identity isEqualToString:from]);
    // The heading bears the model's top out, or reads otherwise: then that model's answer is not taken again.
    if (onScreen && index == sg_topIndex && sg_topFeed) {
        if (!candidate) {
            sg_overruled = sg_topFeed;
            sg_overruledFrom = from;
            SGLog(@"redesign home: top picks from the model read \"%@\" on screen, not \"%@\": going by headings until the feed changes", onScreen, from);
        }
        sg_topFeed = nil;
    }
    if (candidate && index < sg_topIndex) sg_topIndex = index;
    else if (!candidate && index == sg_topIndex) topLost((UICollectionView *)list);
    BOOL large = index == sg_topIndex, was = objc_getAssociatedObject(layout, &kLargeKey) != nil;
    if (large) sg_largeShelf = (UICollectionView *)root;
    // The shelf's height as Spotify sizes it, from a measuring before it was large.
    if (!was) objc_setAssociatedObject(layout, &kNaturalKey, @(result.size.height), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (was && !large) dropLarge((UICollectionView *)root);
    if (large && !was) {
        objc_setAssociatedObject(layout, &kLargeKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [layout invalidateLayout];
        // Laid out large now, so the band its heading took (kOffsetKey) and the cards' height are known to the size
        // below on this pass, not on a later one, which would set the cell to a wrong height in between.
        [root layoutIfNeeded];
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            SGLog(@"redesign home: top picks at %ld, its layout %@ (%@)", (long)index, NSStringFromClass(layout.class),
                  objc_getAssociatedObject(layout, &kWrappedKey) ? @"sized by a provider" : @"not made by a provider: left as it is");
        });
    }
    NSNumber *natural = objc_getAssociatedObject(layout, &kNaturalKey);
    // Spotify's height for the shelf: its first measuring can be an estimate (244 for 235), so a lower one replaces
    // it. Measured with its cards drawn large it comes out taller, and is not taken: grown again, it would grow on
    // every pass.
    if (large && natural && result.size.height < natural.doubleValue) {
        natural = @(result.size.height);
        objc_setAssociatedObject(layout, &kNaturalKey, natural, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    NSNumber *grow = objc_getAssociatedObject(layout, &kGrowKey);
    // The band the heading and the section's top inset took, which the large shelf no longer has (headingAside): its
    // cell is that much shorter.
    CGFloat offset = large ? [objc_getAssociatedObject(layout, &kOffsetKey) doubleValue] : 0;
    // Never shorter than what the shelf lays out: Spotify's height can be taken before its tallest card sized
    // itself (a title on 4 lines), and the shelf then scrolls inside its cell. The shelf's height comes from its
    // cards, not from the cell, so taking it does not feed back.
    if (natural && large && grow) result.size = CGSizeMake(result.size.width, MAX(natural.doubleValue + grow.doubleValue - offset,
                                                                              ceil(layout.collectionViewContentSize.height)));
    else if (natural && was) result.size = CGSizeMake(result.size.width, natural.doubleValue);
    return result;
}
%end

%hook _TtC16Home_CarouselKit29TouchCancellingCollectionView
// The large shelf's cards sized themselves after its cell was measured and no longer fit: measure the cell again.
- (void)setContentSize:(CGSize)size {
    %orig;
    UICollectionView *shelf = (UICollectionView *)self;
    UICollectionViewLayout *layout = shelf.collectionViewLayout;
    if (!objc_getAssociatedObject(layout, &kLargeKey) || size.height <= shelf.bounds.size.height + 0.5) return;
    NSNumber *asked = objc_getAssociatedObject(layout, &kAskedKey);
    if (asked && asked.doubleValue == size.height) return;
    objc_setAssociatedObject(layout, &kAskedKey, @(size.height), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    SGRHomeMeasureAgain(shelf);
}

// VoiceOver reads a list's cells in their index order, which the swap no longer draws: while the swap is in
// effect, the page's list reads the cells on screen in the order they are on screen (the list's own answer is its
// cells on screen too; reaching the rest is UIScrollView's accessibilityScroll:, which this leaves alone).
- (NSArray *)accessibilityElements {
    UICollectionView *list = (UICollectionView *)self;
    CGRect grid, shelf;
    CGFloat before;
    if (!blocks(list.collectionViewLayout, &grid, &shelf, &before)) return %orig;
    NSArray<UICollectionViewCell *> *cells = [list.visibleCells sortedArrayUsingComparator:^NSComparisonResult(UIView *a, UIView *b) {
        return a.frame.origin.y < b.frame.origin.y ? NSOrderedAscending : a.frame.origin.y > b.frame.origin.y ? NSOrderedDescending : NSOrderedSame;
    }];
    NSMutableArray *elements = [NSMutableArray array];
    for (UICollectionViewCell *cell in cells) {
        if (!cell.accessibilityElementsHidden && cell.bounds.size.height > 0) [elements addObject:cell];
    }
    return elements;
}
%end

// Installed only while the heading is hidden.
%group SGRTopPicksHeadingAside
%hook _TtC16Home_CarouselKit29TouchCancellingCollectionView
// The large shelf's heading lies over its cards' top (headingAside), transparent and without touches; a shelf no
// longer large gets it back. Set here, on the shelf's own pass, since the heading's button lays out before the
// shelf is marked and not after.
- (void)layoutSubviews {
    %orig;
    CFTimeInterval began = SGRHomeProbeBegin();
    UICollectionView *shelf = (UICollectionView *)self;
    BOOL large = objc_getAssociatedObject(shelf.collectionViewLayout, &kLargeKey) != nil;
    BOOL held = objc_getAssociatedObject(shelf, &kHeldKey) != nil;
    // Every shelf and the page's list are this class: only the large one, or one that was, has work here.
    if (large || held) {
        UIView *heading = SGRFindByIdentifier(shelf, @"Components.UI.SectionHeadingHome", &kHeadingKey);
        if (heading && heading.alpha != (large ? 0 : 1)) {
            heading.alpha = large ? 0 : 1;
            heading.userInteractionEnabled = !large;
            heading.accessibilityElementsHidden = large;
        }
        if (held != large) objc_setAssociatedObject(shelf, &kHeldKey, large ? @YES : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    SGRHomeProbeEnd(SGRHomeProbeShelfLayout, began);
}
%end
%end

UIControl *SGRHomeTopPicksShowAll(NSString **title) {
    UICollectionView *shelf = sg_largeShelf;
    // A heading kept on screen offers its own.
    if (sg_showHeading || !shelf.window) return nil;
    UIView *showAll = SGRFindByIdentifier(shelf, @"Components.UI.NavigationButtonHome", &kShowAllKey);
    __block UIControl *control = [showAll isKindOfClass:UIControl.class] ? (UIControl *)showAll : nil;
    if (!control) SGForEachView(showAll, ^(UIView *v) {
        if (!control && [v isKindOfClass:UIControl.class]) control = (UIControl *)v;
    });
    if (!control || showAll.bounds.size.width < 1 || !SGShownUnder(showAll, shelf)) return nil;
    if (title) *title = SGRHomeShelfTitle(shelf);
    return control;
}

#pragma mark - the large card

static char kPartsKey, kCoverKey, kShownKey;

@interface SGRLargeCardParts : NSObject
@property (nonatomic, strong) UIView *surface;
@property (nonatomic, strong) UIImageView *cover;   // the Kit's, edge to edge at the card's top
@property (nonatomic, strong) UILabel *lead, *second;
@property (nonatomic, copy) NSArray<UILabel *> *theirs;   // Spotify's labels made transparent, to bring back
@end
@implementation SGRLargeCardParts
@end

static UILabel *footerLabel(UIFont *font, UIColor *color) {
    UILabel *label = [UILabel new];
    label.font = font;
    label.textColor = color;
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    label.userInteractionEnabled = NO;
    label.accessibilityElementsHidden = YES;   // the button reads the whole card out already
    return label;
}

// Spotify's labels with text, top to bottom: its first line, then its second (the kind over the name on a
// "More like" card, the name over "Album • Artist" in Recents), then the sponsored line when there is one.
static NSArray<UILabel *> *spotifyLabels(UIView *card, SGRLargeCardParts *parts) {
    NSMutableArray<UILabel *> *labels = [NSMutableArray array];
    SGForEachView(card, ^(UIView *v) {
        if (![v isKindOfClass:UILabel.class] || v == parts.lead || v == parts.second) return;
        if (((UILabel *)v).text.length && SGShownUnder(v, card)) [labels addObject:(UILabel *)v];
    });
    return [labels sortedArrayUsingComparator:^NSComparisonResult(UILabel *a, UILabel *b) {
        CGFloat ya = [a convertRect:a.bounds toView:card].origin.y, yb = [b convertRect:b.bounds toView:card].origin.y;
        return ya < yb ? NSOrderedAscending : ya > yb ? NSOrderedDescending : NSOrderedSame;
    }];
}

static void restore(UIView *card, SGRLargeCardParts *parts) {
    UIView *holder = SGRFindByIdentifier(card, @"Encore.ImageView", &kCoverKey);
    if (holder.alpha == 0) holder.alpha = 1;
    card.layer.cornerRadius = 0;
    card.layer.masksToBounds = NO;
    [parts.cover removeFromSuperview];
    [parts.surface removeFromSuperview];
    [parts.lead removeFromSuperview];
    [parts.second removeFromSuperview];
    for (UILabel *label in parts.theirs) label.alpha = 1;
    objc_setAssociatedObject(card, &kPartsKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(card, &kShownKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void setColor(SGRLargeCardParts *parts, UIColor *color, BOOL animated) {
    color = color ?: SGRElevated(UIColor.blackColor);
    if ([parts.surface.backgroundColor isEqual:color]) return;
    if (!animated || !parts.surface.window) {
        parts.surface.backgroundColor = color;
        return;
    }
    SGRAnimate(SGRMotionFade, ^{ parts.surface.backgroundColor = color; }, nil);
}

// The first card of the large shelf: the page takes its color.
static BOOL isFirstCard(UIView *card) {
    UIView *cell = card;
    while (cell && ![cell isKindOfClass:UICollectionViewCell.class]) cell = cell.superview;
    UICollectionView *shelf = sg_largeShelf;
    if (!cell || !shelf || ![cell isDescendantOfView:shelf]) return NO;
    NSIndexPath *path = [shelf indexPathForCell:(UICollectionViewCell *)cell];
    return path && path.item == 0;
}

static void tintCard(UIView *card, UIImageView *cover) {
    SGRLargeCardParts *parts = objc_getAssociatedObject(card, &kPartsKey);
    UIImage *image = cover.image;
    if (!parts) return;
    if (!SGEnabled(SGRKeyHomeTopPicksColour)) {
        objc_setAssociatedObject(card, &kShownKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        setColor(parts, nil, NO);
        if (isFirstCard(card)) SGRHomeSetPageTint(nil);
        return;
    }
    // A cover Spotify is loading again (back on Home) has no image for a moment: the colors stay until it comes,
    // rather than the card and the page going black between.
    if (!image) return;
    if (objc_getAssociatedObject(card, &kShownKey) == image) return;
    objc_setAssociatedObject(card, &kShownKey, image, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __weak UIView *weakCard = card;
    SGRHomeTintForCover(image, ^(UIColor *color) {
        UIView *strongCard = weakCard;
        // A card reused for another cover in the meantime has asked for that one.
        if (!strongCard || objc_getAssociatedObject(strongCard, &kShownKey) != image) return;
        SGRLargeCardParts *now = objc_getAssociatedObject(strongCard, &kPartsKey);
        if (now) setColor(now, color, YES);
        if (isFirstCard(strongCard)) SGRHomeSetPageTint(color);
    });
}

static BOOL styleLargeCard(UIView *card);
BOOL SGRHomeStyleLargeCard(UIView *card) {
    CFTimeInterval began = SGRHomeProbeBegin();
    BOOL styled = styleLargeCard(card);
    SGRHomeProbeEnd(SGRHomeProbeLargeCard, began);
    return styled;
}
static BOOL styleLargeCard(UIView *card) {
    SGRLargeCardParts *parts = objc_getAssociatedObject(card, &kPartsKey);
    UIView *holder = SGRFindByIdentifier(card, @"Encore.ImageView", &kCoverKey);
    UIImageView *cover = nil;
    for (UIView *sub in holder.subviews) {
        if ([sub isKindOfClass:UIImageView.class]) cover = (UIImageView *)sub;
    }
    // In the large shelf, not just wide: a shortcut tile is 200pt on a 440pt phone.
    if (!SGRHomeInTopPicks(card) || card.bounds.size.width < kLargeCard || !cover) {
        if (parts) restore(card, parts);
        return NO;
    }
    if (!parts) {
        parts = [SGRLargeCardParts new];
        parts.surface = [UIView new];
        parts.surface.userInteractionEnabled = NO;
        parts.surface.backgroundColor = SGRElevated(UIColor.blackColor);
        parts.lead = footerLabel(SGRFont(UIFontTextStyleBody, UIFontWeightSemibold, UIContentSizeCategoryLarge), SGRPrimary());
        parts.second = footerLabel(SGRFont(UIFontTextStyleFootnote, UIFontWeightRegular, UIContentSizeCategoryLarge), SGRSecondary());
        // The cover drawn by the Kit, edge to edge at the card's top: Spotify keeps its own 2pt in on every side (9.1.90),
        // and a transform scaling its holder out to the edges was reset by the stack's later pass. Spotify's image view
        // goes transparent and keeps everything else (the button's touches, its accessibility label, the image the tint
        // and this view read).
        parts.cover = [UIImageView new];
        parts.cover.contentMode = UIViewContentModeScaleAspectFill;
        // Spotify's card covers come with rounded corners in the bitmap (about 3pt of 237, transparent); the outer
        // 1.5% of each side is left out so the cover's bottom meets the footer square.
        parts.cover.layer.contentsRect = CGRectInset(CGRectMake(0, 0, 1, 1), 0.015, 0.015);
        parts.cover.clipsToBounds = YES;
        parts.cover.userInteractionEnabled = NO;
        parts.cover.accessibilityElementsHidden = YES;
        objc_setAssociatedObject(card, &kPartsKey, parts, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        static dispatch_once_t once;
        dispatch_once(&once, ^{ SGLog(@"redesign home: top picks card %@ styled", NSStringFromCGRect(card.bounds)); });
    }
    // On every pass: the block is replaced, so a cover taken into another card tells the card it is in now, and a
    // card given a new image view is followed from this pass on.
    __weak UIView *weakCard = card;
    SGRObserveImage(cover, ^(UIImageView *view) {
        UIView *strongCard = weakCard;
        if (!strongCard || ![view isDescendantOfView:strongCard]) return;
        SGRLargeCardParts *now = objc_getAssociatedObject(strongCard, &kPartsKey);
        if (now.cover.image != view.image) now.cover.image = view.image;
        tintCard(strongCard, view);
    });
    CALayer *layer = card.layer;
    if (layer.cornerRadius != SGRRadiusCard) layer.cornerRadius = SGRRadiusCard;
    if (layer.cornerCurve != kCACornerCurveContinuous) layer.cornerCurve = kCACornerCurveContinuous;
    if (!layer.masksToBounds) layer.masksToBounds = YES;
    // The card's own corners round the cover's top; its bottom meets the footer square. Spotify's holder goes
    // transparent as a whole: its image view's alpha is Spotify's to fade in as the image loads.
    if (parts.cover.layer.cornerRadius != 0) parts.cover.layer.cornerRadius = 0;
    if (holder.alpha != 0) holder.alpha = 0;
    if (parts.cover.image != cover.image) parts.cover.image = cover.image;

    if (parts.surface.superview != card) [card insertSubview:parts.surface atIndex:0];
    if (!CGRectEqualToRect(parts.surface.frame, card.bounds)) parts.surface.frame = card.bounds;
    // Above the surface and under Spotify's views, which draw nothing over it but keep their place for touches.
    if (parts.cover.superview != card) [card insertSubview:parts.cover aboveSubview:parts.surface];
    CGRect square = CGRectMake(0, 0, card.bounds.size.width, card.bounds.size.width);
    if (!CGRectEqualToRect(parts.cover.frame, square)) parts.cover.frame = square;

    NSArray<UILabel *> *theirs = spotifyLabels(card, parts);
    for (UILabel *label in theirs) {
        if (label.alpha != 0) label.alpha = 0;
    }
    if (![parts.theirs isEqualToArray:theirs]) {
        for (UILabel *label in parts.theirs) {
            if (![theirs containsObject:label]) label.alpha = 1;
        }
        parts.theirs = theirs;
    }
    // Spotify's lines in Spotify's order, the first bold and the rest on one line ("Album" over "Name – Artist"
    // for a card of three). A sponsored card's "Limited ads" is an ad's line and stays out.
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    for (UILabel *label in theirs) {
        if (![label.accessibilityIdentifier containsString:@"SponsoredLabel"]) [lines addObject:label.text];
    }
    NSString *lead = lines.firstObject;
    NSString *second = lines.count > 1 ? [[lines subarrayWithRange:NSMakeRange(1, lines.count - 1)] componentsJoinedByString:@" – "] : nil;
    // An album's "Album • Kendrick Lamar" under "DAMN." leads with the kind, "DAMN. – Kendrick Lamar" under it.
    NSRange dot = lines.count > 1 ? [lines[1] rangeOfString:@" • "] : NSMakeRange(NSNotFound, 0);
    if (dot.location != NSNotFound && dot.location > 0) {
        lead = [lines[1] substringToIndex:dot.location];
        second = [NSString stringWithFormat:@"%@ – %@", lines[0], [lines[1] substringFromIndex:NSMaxRange(dot)]];
    }
    if (![parts.lead.text isEqualToString:lead]) parts.lead.text = lead;
    if (second ? ![parts.second.text isEqualToString:second] : parts.second.text != nil) parts.second.text = second;
    if (parts.lead.superview != card) [card addSubview:parts.lead];
    if (parts.second.superview != card) [card addSubview:parts.second];

    // The footer is the card's bottom kFooter: the card is that much taller than its cover is wide. Spotify's stack
    // lays the cover out after this pass, so its frame is not the one to go by.
    CGFloat footerTop = card.bounds.size.height - kFooter;
    CGFloat x = kFooterInset, width = MAX(0, card.bounds.size.width - x * 2);
    CGFloat leadHeight = ceil(parts.lead.font.lineHeight), secondHeight = ceil(parts.second.font.lineHeight);
    CGRect leadFrame = CGRectMake(x, footerTop + kFooterTop, width, leadHeight);
    CGRect secondFrame = CGRectMake(x, CGRectGetMaxY(leadFrame) + kFooterGap, width, secondHeight);
    if (!CGRectEqualToRect(parts.lead.frame, leadFrame)) parts.lead.frame = leadFrame;
    if (!CGRectEqualToRect(parts.second.frame, secondFrame)) parts.second.frame = secondFrame;
    tintCard(card, cover);
    return YES;
}

BOOL SGRHomeInTopPicks(UIView *view) {
    static Class shelf;
    if (!shelf) shelf = NSClassFromString(@"_TtC16Home_CarouselKit29TouchCancellingCollectionView");
    for (UIView *v = view; v; v = v.superview) {
        if (shelf && [v isKindOfClass:shelf]) return objc_getAssociatedObject(((UICollectionView *)v).collectionViewLayout, &kLargeKey) != nil;
    }
    return NO;
}

SGModRow *SGRHomeTopPicksRow(void) {
    return SGWithSymbol(SGSwitchRow(@"Top picks", @"Home's first shelf above the shortcuts, as large cards in their covers' colors", SGRKeyHomeTopPicks), @"rectangle.stack");
}

%ctor {
    if (!SGRedesignedUI() || !SGRHomeLook() || !SGEnabled(SGRKeyHomeTopPicks)) return;
    sg_showHeading = SGHidden(SGRKeyHomeTopPicksHeading);
    %init;
    if (!sg_showHeading) %init(SGRTopPicksHeadingAside);
}
