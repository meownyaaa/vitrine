// Home declutter: sections of Home collapsed and the filter pills hidden, one switch each on the Home &
// Library page. A section is an Element_List cell; a hidden one reports zero height when the list sizes
// it, so the list closes up around it.
//
// Trees (trees/home*.txt): every section is a CollectionViewCell whose content view names the page
// (Home_EvoPageImpl) and whose subtree names the section.
#import "Core/SGCore.h"
#import "Home.h"

static const struct { __unsafe_unretained NSString *marker, *key; } sections[] = {
    {@"Home_AnchorsAndShortcutsKit", SGHideHomeShortcuts},
    {@"Discovery_PromoElement", SGHideHomePromo},
    {@"Discovery_PreviewElement", SGHideHomePreviews},
    {@"Discovery_DJElement", SGHideHomeDJ},
};

enum { kSections = sizeof(sections) / sizeof(sections[0]) };

static BOOL anySectionSwitch(void) {
    for (size_t i = 0; i < kSections; i++) {
        if (SGHidden(sections[i].key)) return YES;
    }
    return NO;
}

// Whether the cell is a section of Home: its first view names the page. Spotify's cell has held it as its own
// first subview (Redesigned/Home/HomeSections.x) and as its content view's (Native/Player/PlayerDeclutter.x).
static BOOL onHome(UICollectionViewCell *cell) {
    return SGClassNamed(cell.subviews.firstObject.class, @"Home_EvoPageImpl")
        || SGClassNamed(cell.contentView.subviews.firstObject.class, @"Home_EvoPageImpl");
}

// The first switched-on section a class in the cell names. Lists nested in the cell are laid out first so
// the cells that name the section (shortcut tiles) exist.
static NSString *switchedSectionIn(UIView *cell) {
    unsigned hidden = 0;   // a bit per switched-on section (a block cannot capture an array)
    for (size_t i = 0; i < kSections; i++) if (SGHidden(sections[i].key)) hidden |= 1u << i;
    __block size_t first = kSections;
    SGForEachView(cell, ^(UIView *v) {
        if (v != cell && [v isKindOfClass:UICollectionView.class]) [v layoutIfNeeded];
        for (size_t i = 0; i < first; i++) {
            if ((hidden & 1u << i) && SGClassNamed(v.class, sections[i].marker)) first = i;
        }
    });
    return first < kSections ? sections[first].key : nil;
}

static NSString *hiddenKeyFor(UICollectionViewCell *cell) {
    if (!anySectionSwitch() || !onHome(cell)) return nil;
    // A cell inside another section's list: the outer section decides.
    for (UIView *v = cell.superview; v; v = v.superview) {
        if ([v isKindOfClass:cell.class]) return nil;
    }
    return switchedSectionIn(cell);
}

%hook _TtC12Element_List18CollectionViewCell
- (UICollectionViewLayoutAttributes *)preferredLayoutAttributesFittingAttributes:(UICollectionViewLayoutAttributes *)attributes {
    UICollectionViewLayoutAttributes *result = %orig;
    NSString *key = hiddenKeyFor((UICollectionViewCell *)self);
    if (!key) return result;
    result.size = CGSizeMake(result.size.width, 0);
    ((UIView *)self).clipsToBounds = YES;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ SGLog(@"home: collapsed the first section, %@", key); });
    return result;
}
%end

%hook _TtC14Home_PillUIKit14PillScrollView
- (void)didMoveToWindow {
    %orig;
    if (SGHidden(SGHideHomePills)) ((UIView *)self).hidden = YES;
}
%end

%ctor {
    if (!SGNativeUI()) return;
    %init;
    SGRequireClasses(@[
        @"_TtC12Element_List18CollectionViewCell",
        @"_TtC14Home_PillUIKit14PillScrollView",
    ]);
}
