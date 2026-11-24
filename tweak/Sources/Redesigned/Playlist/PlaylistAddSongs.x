// Playlist redesign, iOS < 26: the Add songs row over a playlist's tracks (Liked Songs, a playlist of the user's
// own), its square on glass.
//
// Tree: a cell holding CurateContextPluginImpl's AddMoreSectionElement, a view
// id=PlaylistCuration.AddButton with an ImageViewHolder 48x48 that carries the plus on a plain view painted
// #1F1F1F, and the label beside it. The grey box is what a search field's grey box is elsewhere in the
// redesign, so it gets the same glass (SGRGlassFlatBox): cleared, round, glass inside it, the plus above.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Playlist.h"

static char kBoxGlassKey;

static BOOL isAddCell(UIView *cell) {
    for (UIView *sub in cell.subviews) {
        if ([NSStringFromClass(sub.class) containsString:@"AddMoreSectionElement"]) return YES;
    }
    return NO;
}

%hook _TtC35ListUXPlatform_FreeTierPlaylistImpl25ElementCollectionViewCell
- (void)layoutSubviews {
    %orig;
    UIView *cell = (UIView *)self;
    if (!isAddCell(cell) || !SGRPlaylistHeaderOf(cell)) return;
    __block UIView *box = nil;
    SGForEachView(cell, ^(UIView *v) {
        if (!box && [v isMemberOfClass:UIView.class] && [NSStringFromClass(v.superview.class) hasSuffix:@"ImageViewHolder"]) box = v;
    });
    SGRGlassFlatBox(box, &kBoxGlassKey, NO);
    // The legacy glass grows under a finger (SGGlassInteractive), and the 48pt ImageViewHolder around the square
    // clips to its bounds, which cut the capsule off at its edges while it was held.
    UIView *holder = box.superview;
    if (SGUseLegacyGlass() && holder.clipsToBounds) holder.clipsToBounds = NO;
}
%end

%ctor {
    if (!SGRedesignedUI()) return;
    if (!SGBelowiOS26()) return;
    %init;
    SGRequireClasses(@[@"_TtC35ListUXPlatform_FreeTierPlaylistImpl25ElementCollectionViewCell"]);
}
