// The "Mirage" row in Spotify's side drawer (the profile drawer opened from the avatar), right
// below Vitrine's "Mod Settings" row and drawn the same way: a 56pt row, 24pt SF Symbol at x 16,
// title at x 52 in the drawer's own font, no chevron.
//
// How Vitrine does it (tweak/Sources/App/ModSettings.x): the drawer's list is a collection view whose
// class name contains "SideDrawerListCollectionView" (on 9.1.90:
// _TtC23SideDrawer_ListPageImplP33_1D8CA7A9CC41E8D184AF8B9AAE4E684E28SideDrawerListCollectionView),
// found from -[_TtC23SideDrawer_ListPageImpl18ListViewController viewDidLayoutSubviews]. Its row sits
// at y = -56 inside the list, above the first cell (the profile card), with contentInset.top raised
// by 56 so it shows.
//
// Mirage takes the y = -56 slot and moves Vitrine's row (class SGModSettingsRow, drawer == YES) up to
// -112, so the order is Mod Settings, Mirage, profile card. Its own 56pt goes into the inset through
// the list's contentInset setter and is taken back out in the getter, so Spotify's and Vitrine's own
// bookkeeping of the inset (Vitrine compares the inset with the one it applied) never sees it and
// neither keeps adding to it. Without Vitrine, the row is simply the first one.
#import "MRGPrefs.h"
#import "MRGSettings.h"
#import <objc/runtime.h>
#import <objc/message.h>

static const CGFloat kRowHeight = 56;
static char kRowKey;
// The drawer list's class, once seen: the inset hooks below run for every collection view in the app,
// so they compare a class pointer before they look anything up.
static Class sg_drawerClass;

// Every hook below touches nothing but the drawer list instances Mirage put its row into: the exact
// drawer class, and the row tag on that instance. Spotify's settings list, Vitrine's settings-list row
// and every other collection view go through untouched.
static inline BOOL hasRow(UIView *v) {
    return sg_drawerClass && object_getClass(v) == sg_drawerClass && objc_getAssociatedObject(v, &kRowKey) != nil;
}

@interface MRGDrawerRow : UIControl
@end

@implementation MRGDrawerRow {
    UIImageView *_icon;
    UILabel *_title;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    UIImage *img = [UIImage systemImageNamed:@"sparkles" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:20 weight:UIImageSymbolWeightRegular]];
    _icon = [[UIImageView alloc] initWithImage:img];
    _icon.tintColor = UIColor.whiteColor;
    _icon.contentMode = UIViewContentModeCenter;
    _title = [UILabel new];
    _title.text = @"Mirage";
    _title.textColor = UIColor.whiteColor;
    _title.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    [self addSubview:_icon];
    [self addSubview:_title];
    self.accessibilityLabel = @"Mirage";
    self.accessibilityTraits = UIAccessibilityTraitButton;
    self.isAccessibilityElement = YES;
    [self addTarget:self action:@selector(open) forControlEvents:UIControlEventTouchUpInside];
    return self;
}

// Same font as the drawer's own rows: Vitrine's row if it is there (it already read the drawer's
// font), otherwise the commonest 14-18pt label font in the list.
- (void)adoptFontFrom:(UIView *)list vitrineRow:(UIView *)vitrine {
    UIFont *font = nil;
    for (UIView *v in vitrine.subviews) if ([v isKindOfClass:UILabel.class]) font = ((UILabel *)v).font;
    if (!font) {
        NSCountedSet *fonts = [NSCountedSet set];
        NSMutableArray *stack = [NSMutableArray arrayWithArray:list.subviews];
        while (stack.count) {
            UIView *v = stack.lastObject; [stack removeLastObject];
            if (v == self) continue;
            if ([v isKindOfClass:UILabel.class]) {
                UILabel *l = (UILabel *)v;
                if (l.text.length >= 2 && l.font.pointSize >= 14 && l.font.pointSize <= 18) [fonts addObject:l.font];
            }
            [stack addObjectsFromArray:v.subviews];
        }
        NSUInteger best = 0;
        for (UIFont *f in fonts) if ([fonts countForObject:f] > best) { best = [fonts countForObject:f]; font = f; }
    }
    if (font && ![font isEqual:_title.font]) { _title.font = font; [self setNeedsLayout]; }
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.bounds.size.width, h = self.bounds.size.height;
    _icon.frame = CGRectMake(16, (h - 24) / 2, 24, 24);
    _title.frame = CGRectMake(52, 0, w - 68, h);
}

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    self.alpha = highlighted ? 0.5 : 1;
}

static UINavigationController *navigationIn(UIViewController *page) {
    if ([page isKindOfClass:UINavigationController.class]) return (UINavigationController *)page;
    for (UIViewController *child in page.childViewControllers) {
        UINavigationController *found = navigationIn(child);
        if (found) return found;
    }
    return nil;
}

// The drawer is presented over the app: close it, then push onto the stack it covered, the way
// the drawer's own rows (and Vitrine's) open their pages.
- (void)open {
    UIViewController *owner = nil;
    for (UIResponder *r = self; r && !owner; r = r.nextResponder)
        if ([r isKindOfClass:UIViewController.class]) owner = (UIViewController *)r;
    UIViewController *presenting = owner.presentingViewController;
    if (!presenting) { MRGShowSettings(owner); return; }
    [presenting dismissViewControllerAnimated:YES completion:^{
        MRGShowSettings(navigationIn(presenting).topViewController ?: presenting);
    }];
}

@end

#pragma mark - placement

static BOOL isDrawerList(UIView *v) {
    return [v isKindOfClass:UICollectionView.class] && [NSStringFromClass(v.class) containsString:@"SideDrawerListCollectionView"];
}

static UIView *vitrineRowIn(UIView *list) {
    static Class vitrineRow;
    if (!vitrineRow) vitrineRow = NSClassFromString(@"SGModSettingsRow");
    if (!vitrineRow) return nil;
    for (UIView *v in list.subviews) {
        if (![v isKindOfClass:vitrineRow]) continue;
        // Only the drawer's copy (Vitrine also puts one at the end of Spotify's settings list).
        if ([v respondsToSelector:@selector(drawer)] && !((BOOL (*)(id, SEL))objc_msgSend)(v, @selector(drawer))) continue;
        return v;
    }
    return nil;
}

static void placeRow(UICollectionView *list) {
    MRGDrawerRow *row = objc_getAssociatedObject(list, &kRowKey);
    if (!row) return;
    if (row.superview != list) [list addSubview:row];
    UIView *vitrine = vitrineRowIn(list);
    [row adoptFontFrom:list vitrineRow:vitrine];
    CGRect frame = CGRectMake(0, -kRowHeight, list.bounds.size.width, kRowHeight);
    if (!CGRectEqualToRect(row.frame, frame)) row.frame = frame;
    if (vitrine && vitrine.frame.origin.y > -2 * kRowHeight + 0.5) {
        CGRect f = vitrine.frame;
        f.origin.y = -2 * kRowHeight;
        vitrine.frame = f;   // runs our setFrame: hook below too, which keeps it there
    }
}

static void attachRow(UICollectionView *list) {
    MRGDrawerRow *row = objc_getAssociatedObject(list, &kRowKey);
    if (!row) {
        // The inset as Spotify (and Vitrine) set it, read before the row exists so the getter below
        // takes nothing off; written back once the row exists, so the setter adds Mirage's 56pt.
        UIEdgeInsets inset = list.contentInset;
        sg_drawerClass = object_getClass(list);
        row = [[MRGDrawerRow alloc] initWithFrame:CGRectZero];
        objc_setAssociatedObject(list, &kRowKey, row, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        list.contentInset = inset;
        CGPoint off = list.contentOffset;
        if (off.y <= 0) list.contentOffset = CGPointMake(off.x, -list.adjustedContentInset.top);
    }
    placeRow(list);
}

%hook _TtC23SideDrawer_ListPageImpl18ListViewController
- (void)viewDidLayoutSubviews {
    %orig;
    NSMutableArray *stack = [NSMutableArray arrayWithObject:((UIViewController *)self).view];
    while (stack.count) {
        UIView *v = stack.lastObject; [stack removeLastObject];
        if (isDrawerList(v)) { attachRow((UICollectionView *)v); continue; }
        [stack addObjectsFromArray:v.subviews];
    }
}
%end

%hook UICollectionView
- (void)layoutSubviews {
    %orig;
    if (hasRow(self)) placeRow(self);
}

- (void)setContentInset:(UIEdgeInsets)inset {
    if (hasRow(self)) inset.top += kRowHeight;
    %orig(inset);
}

- (UIEdgeInsets)contentInset {
    UIEdgeInsets inset = %orig;
    if (hasRow(self)) inset.top -= kRowHeight;
    return inset;
}
%end

// Vitrine re-places its row at y = -56 on every layout of the list; keep it one row higher.
%group MRGVitrineRow
%hook SGModSettingsRow
- (void)setFrame:(CGRect)frame {
    UIView *list = ((UIView *)self).superview;
    id me = (id)self;
    BOOL drawerRow = [me respondsToSelector:@selector(drawer)] && ((BOOL (*)(id, SEL))objc_msgSend)(me, @selector(drawer));
    if (drawerRow && list && hasRow(list) && frame.origin.y < 0 && frame.origin.y > -2 * kRowHeight + 0.5)
        frame.origin.y = -2 * kRowHeight;
    %orig(frame);
}
%end
%end

%ctor {
    @autoreleasepool {
        if (NSClassFromString(@"_TtC23SideDrawer_ListPageImpl18ListViewController")) %init;
        // Vitrine's dylib may load after Mirage's; look again once the app has finished launching.
        void (^hookVitrine)(void) = ^{
            static BOOL done;
            if (done || !NSClassFromString(@"SGModSettingsRow")) return;
            done = YES;
            %init(MRGVitrineRow);
        };
        hookVitrine();
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidFinishLaunchingNotification object:nil queue:nil usingBlock:^(NSNotification *n) {
            dispatch_async(dispatch_get_main_queue(), hookVitrine);
        }];
        MRGRegisterSettingsPage();
    }
}
