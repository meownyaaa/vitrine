// Playlist redesign, iOS < 26: the chips over a playlist's first track (the genres of Liked Songs) on glass.
//
// Tree: a cell of the list holding CollectionSongs_PlaylistImpl's CSNestedChipsElement, whose
// NestedChipsView scrolls a row of Encore ChipViews. The glass is the Kit's (Kit/SGRChips.h), the same
// the chips of Recents have.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Playlist.h"

static BOOL isChipsCell(UIView *cell) {
    for (UIView *sub in cell.subviews) {
        if ([NSStringFromClass(sub.class) containsString:@"CSNestedChipsElement"]) return YES;
    }
    return NO;
}

%hook _TtC35ListUXPlatform_FreeTierPlaylistImpl25ElementCollectionViewCell
- (void)layoutSubviews {
    %orig;
    UIView *cell = (UIView *)self;
    if (isChipsCell(cell) && SGRPlaylistHeaderOf(cell)) SGRGlassChipsIn(cell);
}
%end

// The radio's chips (SessionControlImpl's SCFilterChipsElement) sit in a collection view of their own, whose items
// are made after the cell has been laid out, so the cell's pass above never meets them. Each chip is dressed as it
// comes into the window.
%hook _TtCE15Encore_ChipsKitO16EncoreFoundation6Encore8ChipView
- (void)didMoveToWindow {
    %orig;
    UIView *chip = (UIView *)self;
    if (chip.window && SGRPlaylistHeaderOf(chip)) SGRGlassChipsIn(chip);
}
%end

%ctor {
    if (!SGRedesignedUI()) return;
    if (!SGBelowiOS26()) return;
    %init;
    SGRequireClasses(@[@"_TtC35ListUXPlatform_FreeTierPlaylistImpl25ElementCollectionViewCell",
                       @"_TtCE15Encore_ChipsKitO16EncoreFoundation6Encore8ChipView"]);
}
