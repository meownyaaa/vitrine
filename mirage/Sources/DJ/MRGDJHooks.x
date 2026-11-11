// Where Mirage DJ shows up in Spotify:
//  - Home: a DJ chip at the end of the filter chips (Home_PillUIKit.PillScrollView, inside its scroll view), or in the
//    header row when the chips are not shown (Vitrine's redesign title row, or the chips hidden), placed on Home's
//    page passes (Home_FunkisPageImpl.FunkisViewController). The redesign's glass pill (SGRHomePillButtons, Vitrine's)
//    rises and fades with the page by its transform and alpha; the header chip is re-placed beside it on every
//    center/bounds/transform/alpha change, and stays hidden until the pill is laid out below the safe area.
//  - Now Playing: a DJ button in the header row (NowPlaying_ModesImpl.HeaderElementsUnit) and the caption under it.
// The settings switches re-run the placement on the views last seen.
#import "MRGDJView.h"
#import "MRGPrefs.h"
#import "MRGHistory.h"

static NSHashTable *sPages, *sPills, *sUnits;

static void remember(NSHashTable *__strong *table, id obj) {
    if (!*table) *table = [NSHashTable weakObjectsHashTable];
    [*table addObject:obj];
}

%group MRGDJHome
%hook _TtC19Home_FunkisPageImpl20FunkisViewController
- (void)viewDidLayoutSubviews {
    %orig;
    UIView *v = ((UIViewController *)self).viewIfLoaded;
    if (!v) return;
    remember(&sPages, v);
    MRGDJPlaceHomeEntry(v);
}
%end
%end

%group MRGDJPills
%hook _TtC14Home_PillUIKit14PillScrollView
- (void)layoutSubviews {
    %orig;
    remember(&sPills, self);
    MRGDJPlaceChipInPills((UIView *)self);
}
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *chip = MRGDJChipHit((UIView *)self, point, event);
    return chip ?: %orig;
}
%end
%end

%group MRGDJRedesignPill
%hook SGRHomePillButtons
- (void)setTransform:(CGAffineTransform)t { %orig; MRGDJFollowHeaderButtons((UIView *)self); }
- (void)setAlpha:(CGFloat)a { %orig; MRGDJFollowHeaderButtons((UIView *)self); }
- (void)setCenter:(CGPoint)c { %orig; MRGDJFollowHeaderButtons((UIView *)self); }
- (void)setBounds:(CGRect)b { %orig; MRGDJFollowHeaderButtons((UIView *)self); }
- (void)setHidden:(BOOL)h { %orig; MRGDJFollowHeaderButtons((UIView *)self); }
%end
%end

%group MRGDJPlayer
%hook _TtC20NowPlaying_ModesImpl18HeaderElementsUnit
- (void)viewDidLayoutSubviews {
    %orig;
    remember(&sUnits, self);
    MRGDJPlacePlayerButton((UIViewController *)self);
}
%end
%end

%ctor {
    MRGHistoryStart();
    if (NSClassFromString(@"_TtC19Home_FunkisPageImpl20FunkisViewController")) %init(MRGDJHome);
    if (NSClassFromString(@"_TtC14Home_PillUIKit14PillScrollView")) %init(MRGDJPills);
    if (NSClassFromString(@"SGRHomePillButtons")) %init(MRGDJRedesignPill);
    if (NSClassFromString(@"_TtC20NowPlaying_ModesImpl18HeaderElementsUnit")) %init(MRGDJPlayer);
    [NSNotificationCenter.defaultCenter addObserverForName:MRGSettingsChangedNotification object:nil queue:NSOperationQueue.mainQueue
                                                usingBlock:^(NSNotification *n) {
        for (UIView *p in sPills.allObjects) MRGDJPlaceChipInPills(p);
        for (UIView *v in sPages.allObjects) MRGDJPlaceHomeEntry(v);
        for (UIViewController *u in sUnits.allObjects) MRGDJPlacePlayerButton(u);
    }];
}
