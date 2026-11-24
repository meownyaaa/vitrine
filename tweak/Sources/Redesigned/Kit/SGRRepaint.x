// Keeps the areas the redesign stripped transparent when Spotify repaints them, and learns which views
// could be the now playing bar's card from the album-color paint.
#import "Core/SGCore.h"
#import "SGRRepaint.h"
#import "SGRGlass.h"
#import "SGRChips.h"
#import "SGRRestyle.h"
#import "SGRPass.h"

__weak UIView *sgr_nowPlayingRoot = nil;
NSHashTable<UIView *> *sgr_nowPlayingPainted = nil;
__weak UIView *sgr_lyricsPageRoot = nil;
__weak UIView *sgr_playlistRoot = nil;
__weak UIView *sgr_albumRoot = nil;
__weak UIView *sgr_artistRoot = nil;
__weak UIView *sgr_sheetChromeRoot = nil;
__weak UIView *sgr_searchHeaderRoot = nil;
__weak UIView *sgr_addSongsSearchBar = nil;
__weak UIView *sgr_searchFieldFill = nil;
__weak UIView *sgr_showSearchField = nil;
__weak UIView *sgr_showSearchHeader = nil;

// Views whose fill is kept clear for good (SGRHoldClear): a dressed button's or a dressed disc's own paint, which Encore
// paints again as the control is pressed, let go or reused.
static NSHashTable<UIView *> *heldClear;

void SGRHoldClear(UIView *view) {
    if (!view) return;
    if (!heldClear) heldClear = [NSHashTable weakObjectsHashTable];
    [heldClear addObject:view];
}

// Classes are never unloaded, so plain pointers do; a handful at most.
static Class heldClearClasses[8];
static int heldClearClassCount;

void SGRHoldClearClass(Class cls) {
    if (!cls) return;
    for (int i = 0; i < heldClearClassCount; i++) if (heldClearClasses[i] == cls) return;
    if (heldClearClassCount >= 8) return;
    heldClearClasses[heldClearClassCount++] = cls;
    // At the view as well: UIView keeps the colour it is given and puts it on its layer again by ways of its own (a
    // change of traits), past the layer's setter, so a view left holding its black got it back on its layer after the
    // layer had been cleared (Home's header element, its view and its layer both #000000 with the hold in place). On
    // this class alone: its own -setBackgroundColor:, or one added over the one it inherits.
    SEL set = @selector(setBackgroundColor:);
    Method method = class_getInstanceMethod(cls, set);
    if (!method) return;
    IMP inherited = method_getImplementation(method);
    IMP cleared = imp_implementationWithBlock(^(UIView *view, UIColor *color) {
        ((void (*)(id, SEL, UIColor *))inherited)(view, set, nil);
    });
    if (!class_addMethod(cls, set, cleared, method_getTypeEncoding(method))) method_setImplementation(method, cleared);
}

static BOOL ofHeldClearClass(id owner) {
    if (!heldClearClassCount || !owner) return NO;
    Class cls = object_getClass(owner);
    for (int i = 0; i < heldClearClassCount; i++) if (heldClearClasses[i] == cls) return YES;
    return NO;
}

// The flat, translucent white Spotify tints an unselected filter chip with (#FFFFFF@0.10). A selected chip is painted a solid colour of its own, which is never this.
static BOOL isNeutralTint(CGColorRef color) {
    if (!color || CFGetTypeID(color) != CGColorGetTypeID()) return NO;
    CGFloat alpha = CGColorGetAlpha(color);
    if (alpha < 0.01 || alpha > 0.3) return NO;
    const CGFloat *c = CGColorGetComponents(color);
    size_t n = CGColorGetNumberOfComponents(color);
    for (size_t i = 0; i + 1 < n; i++) if (c[i] < 0.9) return NO;
    return n >= 2;
}

// The fill of a library filter chip: the plain view FilterChipView lays under its label. Spotify paints
// it again on its own passes (a chip pressed, selected or let go, a cell coming back from reuse), none
// of which lays the library page out, so clearing it once from the page's pass left the grey back under
// the glass every time. Told apart by the class of its parent, not by a root: the root library and a
// folder can both be alive, and each has chips. The cross that clears the filters has a fill of the same kind
// in its ClearChipView.
static BOOL isChipFill(UIView *view) {
    if (view.superview == nil || ![view isMemberOfClass:UIView.class]) return NO;
    NSString *parent = NSStringFromClass(view.superview.class);
    return [parent isEqualToString:@"EncoreConsumerMobile_BaseKit.FilterChipView"] || [parent hasSuffix:@"ClearChipView"];
}

// The opaque backing Spotify paints the library's pinned header with (#121212, black under the AMOLED hook).
// Library/LibraryHeader.x leaves the header with no backing at all, so the title row and the filter chips
// float over the page as glass; this keeps Spotify's own paint from covering them again on its passes. Size first, name second: this runs for every colour any layer is given.
static BOOL isLibraryHeader(UIView *view) {
    CGSize size = view.bounds.size;
    if (size.width < 300 || size.height < 100 || size.height > 260) return NO;
    NSString *name = NSStringFromClass(view.class);
    return [name hasSuffix:@"YourLibraryHeaderView"] || [name hasSuffix:@"FolderHeaderView"];
}

// One walk up from the view says which roots it is inside, the way SGIsInside would for each: not past a
// visual effect view. The roots are then taken in their order, not in the order the walk meets them.
enum { kInNowPlaying = 1, kInLyrics = 2, kInPage = 4 };

%hook CALayer
- (void)setBackgroundColor:(CGColorRef)color {
    if (!color) {
        %orig;
        return;
    }
    BOOL legacyLook = SGBelowiOS26();
    if (legacyLook && color && CGColorGetAlpha(color) > 0.5) {
        UIView *header = (UIView *)self.delegate;
        if ([header isKindOfClass:UIView.class] && header.layer == self && isLibraryHeader(header)) color = NULL;
    }
    // The search results header's backing and the grey in its field: the glass of the field stands in its place, the header has none.
    if (legacyLook && color && (sgr_searchHeaderRoot || sgr_searchFieldFill)) {
        id owner = self.delegate;
        if (owner == sgr_searchHeaderRoot && CGColorGetAlpha(color) > 0.5) color = NULL;
        else if (owner == sgr_searchFieldFill && (isNeutralTint(color) || CGColorGetAlpha(color) > 0.5)) color = NULL;
    }
    // The podcast search page's field: the grey goes, the glass (Pages/ShowSearch.x) stands in its place.
    if (legacyLook && color && sgr_showSearchField && self.delegate == sgr_showSearchField && (isNeutralTint(color) || CGColorGetAlpha(color) > 0.5)) color = NULL;
    // The podcast search page's header, Spotify's black behind the field row: it goes and the field and Cancel float.
    if (legacyLook && color && sgr_showSearchHeader && self.delegate == sgr_showSearchHeader && CGColorGetAlpha(color) > 0.5) color = NULL;
    // The Add songs sheet's search bar: its grey goes, the glass (Playlist/PlaylistAddSearch.x) stands in its place.
    if (legacyLook && color && sgr_addSongsSearchBar && self.delegate == sgr_addSongsSearchBar && CGColorGetAlpha(color) > 0.5) color = NULL;
    // A class the Kit holds clear (SGRHoldClearClass), whichever view of it is painted.
    if (legacyLook && color && heldClearClassCount && CGColorGetAlpha(color) > 0.05 && ofHeldClearClass(self.delegate)
        && ((UIView *)self.delegate).layer == self) color = NULL;
    // A fill the Kit holds clear (SGRHoldClear): the button or disc is on glass, and Spotify's paint goes whenever it is set.
    if (legacyLook && color && heldClear.count && CGColorGetAlpha(color) > 0.05 && NSThread.isMainThread) {
        UIView *held = (UIView *)self.delegate;
        if ([held isKindOfClass:UIView.class] && held.layer == self && [heldClear containsObject:held]) color = NULL;
    }
    // A chip's fill painted: the grey goes, and either way the chip's glass is told (below, once the paint is
    // in), because selecting and deselecting a chip repaints the fill and lays nothing out, so the glass kept
    // whatever state the last layout gave it (hidden under a selected colour that was gone again).
    UIView *paintedChip = nil;
    BOOL dressedChip = NO;
    if (legacyLook && color && (isNeutralTint(color) || CGColorGetAlpha(color) > 0.5)) {
        UIView *fill = (UIView *)self.delegate;
        if ([fill isKindOfClass:UIView.class] && fill.layer == self) {
            if (isChipFill(fill) && SGRIsGlassChip(fill.superview)) {
                paintedChip = fill.superview;
            } else if (SGRIsDressedChipPill(fill)) {
                // The pill of a chip dressed by the Kit (SGRChips.h): the genres over Liked Songs, Recents' chips.
                paintedChip = fill.superview;
                dressedChip = YES;
            }
            if (paintedChip && (isNeutralTint(color) || (dressedChip && SGRIsSheetSurface(color)))) color = NULL;
            // A selected chip's solid colour lands as a tint over the chip's glass (SGRChips.h).
            else if (paintedChip) color = SGRSelectedChipPaint(color);
        }
    }
    // A pill of the Add to playlist sheet (SGRSheetPills.x): its grey goes, and the pill's glass is told once the
    // paint is in, since selecting a pill repaints it and lays nothing out. The dressed mark is one lookup.
    UIView *paintedPill = nil;
    if (legacyLook && color && SGRSheetPillsLive()) {
        UIView *pill = (UIView *)self.delegate;
        if ([pill isKindOfClass:UIView.class] && pill.layer == self && SGRIsSheetPill(pill)) {
            paintedPill = pill;
            if (SGRIsPillGrey(color)) color = NULL;
            else color = SGRSelectedChipPaint(color);
        }
    }
    UIView *nowPlaying = sgr_nowPlayingRoot, *lyrics = sgr_lyricsPageRoot;
    UIView *playlist = sgr_playlistRoot, *album = sgr_albumRoot, *artist = sgr_artistRoot;
    UIView *sheet = sgr_sheetChromeRoot;
    // A page only ever loses the base surface, so another color asks after the player and the lyrics alone.
    if (color && (playlist || album || artist) && !SGIsBaseSurface(color)) playlist = album = artist = nil;
    if (color && (nowPlaying || lyrics || playlist || album || artist || sheet)) {
        UIView *view = (UIView *)self.delegate;
        if ([view isKindOfClass:UIView.class] && view.layer == self && !SGKeepsColor(view)) {
            NSUInteger inside = 0;
            for (UIView *v = view; v && !(inside & kInNowPlaying); v = v.superview) {
                if ([v isKindOfClass:UIVisualEffectView.class]) break;
                if (v == nowPlaying) inside |= kInNowPlaying;
                if (v == lyrics) inside |= kInLyrics;
                if (v == playlist || v == album || v == artist) inside |= kInPage;
            }
            if (inside & kInNowPlaying) {
                // Its size is judged when the bar picks its card: Spotify can paint a card before it sizes it.
                // The Jam strip's avatar keeps its colour, or only its initial is left.
                if (!SGRIsStripAvatar(view)) {
                    if (SGIsVisibleColor(color)) {
                        // The bar reads the table on main, and Spotify also paints layers off main.
                        void (^learn)(UIView *) = ^(UIView *painted) {
                            if (!painted || [sgr_nowPlayingPainted containsObject:painted]) return;
                            [sgr_nowPlayingPainted addObject:painted];
                            dispatch_async(dispatch_get_main_queue(), ^{ [nowPlaying.superview setNeedsLayout]; });
                        };
                        if (NSThread.isMainThread) {
                            learn(view);
                        } else {
                            __weak UIView *weakView = view;
                            dispatch_async(dispatch_get_main_queue(), ^{ learn(weakView); });
                        }
                    }
                    color = NULL;
                }
            } else if (inside & (kInLyrics | kInPage)) {
                color = NULL;
            } else if (sheet) {
                if (SGRIsSwiftUICard(view) && SGRIsSheetSurface(color) && SGIsInside(view, sheet)) {
                    // The device picker's cards: translucent rather than an opaque grey on the glass.
                    color = SGRSheetCardFill();
                } else if (SGIsVisibleColor(color) && SGRIsSheetChromeArea(view, sheet) && !SGRIsSheetCard(view)) {
                    color = NULL;
                } else if (SGRIsSheetSurface(color) && !SGRIsSheetCard(view) && SGIsInside(view, sheet)
                           && sheet.bounds.size.width > 1 && view.bounds.size.width >= sheet.bounds.size.width * SGRSheetBandShare) {
                    // A band in the sheet's own list (the queue's QueueCell and TrackRowQueue.Cell, #1F1F1F).
                    color = NULL;
                }
            }
        }
    }
    %orig(color);
    if (paintedPill) dispatch_async(dispatch_get_main_queue(), ^{ SGRSheetPillPainted(paintedPill); });
    if (paintedChip) dispatch_async(dispatch_get_main_queue(), ^{
        if (dressedChip) SGRDressedChipPainted(paintedChip);
        else SGRLibraryChipPainted(paintedChip);
    });
}
%end

#pragma mark - a glassed sheet, watched

// Paint that lands before the layer hook above can place it: a view given its grey while it has no parent yet, or
// before it has a size (SGKeepsColor spares a view of no size), is not seen as the sheet's when it is painted. It is
// cleared from the next layout of the sheet or of a list in it, which UIKit runs before the frame that would show it:
// the sheet and its lists are watched themselves, instance by instance, not every view of the app.
static BOOL isSheetPaint(UIView *view, CGColorRef color) {
    UIView *root = sgr_sheetChromeRoot;
    if (!root || root.bounds.size.width < 1 || !SGRIsSheetSurface(color)) return NO;
    if (SGKeepsColor(view) || SGRIsSheetCard(view) || !SGIsInside(view, root)) return NO;
    return SGRIsSheetChromeArea(view, root) || view.bounds.size.width >= root.bounds.size.width * SGRSheetBandShare;
}

static char kSheetWatchedKey, kCellSweptKey;
static void watchSheetView(UIView *view, void (^pass)(UIView *view));

// The grey of every view under `view` that is the sheet's, and of the rows of every list in it, cleared; a list met
// for the first time is watched from then on, so a row scrolled or reused into it is cleared as it lays out. A list lays
// out on every frame of a scroll, so a row is walked once, and again only when it holds another set of views: paint on a
// row already in the sheet goes through the layer hook above. A scroll costs one lookup per visible row.
static void sweepSheet(UIView *view, int depth) {
    UIView *root = sgr_sheetChromeRoot;
    if (!root || !view || depth > 16) return;
    if ([view isKindOfClass:UITableViewCell.class] || [view isKindOfClass:UICollectionViewCell.class]) {
        UIView *content = [view respondsToSelector:@selector(contentView)] ? [(id)view contentView] : view;
        NSNumber *held = @(view.subviews.count * 1000 + content.subviews.count);
        if ([objc_getAssociatedObject(view, &kCellSweptKey) isEqual:held]) return;
        objc_setAssociatedObject(view, &kCellSweptKey, held, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        CGColorRef paint = view.layer.backgroundColor;
        if (paint && isSheetPaint(view, paint)) view.backgroundColor = UIColor.clearColor;
        SGRClearSheetCellPaint(view, root);
        return;
    }
    CGColorRef paint = view.layer.backgroundColor;
    if (paint && isSheetPaint(view, paint)) view.backgroundColor = UIColor.clearColor;
    if ([view isKindOfClass:UIScrollView.class]) watchSheetView(view, ^(UIView *list) { sweepSheet(list, 0); });
    for (UIView *sub in view.subviews) sweepSheet(sub, depth + 1);
}

// `pass` after every layout of `view`: by a subclass of the instance, or, for one of Spotify's own Swift classes that
// cannot be subclassed, on that class (never on one of UIKit's, which every screen of the app is made of).
static void watchSheetView(UIView *view, void (^pass)(UIView *view)) {
    if (objc_getAssociatedObject(view, &kSheetWatchedKey)) return;
    objc_setAssociatedObject(view, &kSheetWatchedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    // A view another feature watches keeps its observer (SGRObserveLayout holds one block a view): this one goes on the class.
    if (!SGRObservesLayout(view) && SGRObserveLayout(view, pass)) return;
    Class cls = object_getClass(view);
    NSString *name = NSStringFromClass(cls);
    if ([name hasPrefix:@"UI"] || [name hasPrefix:@"_UI"]) return;
    static NSMutableSet<Class> *passed;
    if (!passed) passed = [NSMutableSet set];
    if ([passed containsObject:cls]) return;
    [passed addObject:cls];
    SGRPassView(cls, ^(UIView *v) { if (sgr_sheetChromeRoot && SGIsInside(v, sgr_sheetChromeRoot)) pass(v); });
}

void SGRWatchSheetPaint(UIView *root) {
    if (!root) return;
    watchSheetView(root, ^(UIView *sheet) { if (sheet == sgr_sheetChromeRoot) sweepSheet(sheet, 0); });
    sweepSheet(root, 0);
}

%ctor {
    if (!SGRedesignedUI()) return;
    %init;
}
