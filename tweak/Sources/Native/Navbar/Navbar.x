// Navbar: which tabs the bar shows, in what order, and tabs of the mod's own that open any
// spotify: URI. Spotify keeps its four items (Home, Search, Library, Create) as the arranged
// subviews of one stack view, but a tap on one of them is answered by counting the row off from
// the left, not by asking the item what it is: moved in the stack, an item takes the tap of
// whatever used to stand there. So the stack's own order is left exactly as Spotify built it.
//
// The row is split into equal slots instead, and each item is given the frame of its slot after
// the stack's own pass: hit testing goes by frame, so the touch follows the icon, while Spotify
// still counts its items off in the order it put them in. Items of the mod's own go on the end of
// the stack, past that count, and take a slot with the rest. A tap on one goes through Spotify's
// link dispatcher, the same route the app takes for a link it opens itself, so any URI works.
//
// Tree (trees/home.txt): NavigationUI_TabBarImpl.TabBarView > TabBarCompactView > UIStackView
//   402x49 of four ElementContentView<TabBarItemElement> 100x49, each an SPTEncoreIconView 24x24
//   at y 12.5 over an SPTEncoreLabel at y 35.
#import "Core/SGCore.h"
#import "Navbar.h"
#import "Shared/Navigation/Links.h"
#import "Shared/Navigation/TabIcons.h"
#import <objc/message.h>

static const CGFloat kIconSize = 24;
static const CGFloat kIconTop = 12.5;
static const CGFloat kLabelTop = 35;
static const CGFloat kLabelHeight = 14;
static char kCustomKey, kOrderKey;
// Between the main group and the split tabs (Split tabs), when both have something on the bar.
static const CGFloat kSplitGap = 10;

// Where Spotify's own items keep their icon and label, read off one of them every pass, so an item of
// the mod's own sits on the same line as its neighbors.
static CGRect sg_iconBox = {{0, kIconTop}, {kIconSize, kIconSize}};
static CGRect sg_labelBox = {{0, kLabelTop}, {0, kLabelHeight}};

static __weak UIView *sg_navbarRoot;
// The bar's row of items, given its frames by placeRow after each of its own passes.
static __weak UIStackView *sg_row;
static UIFont *sg_tabFont;
// Spotify's own tabs in Spotify's order, from the first layout pass of this launch, before
// anything below has moved them.
static NSMutableArray<NSString *> *sg_stockOrder;
// How many tabs at the end of the row are split off from the rest, 0 for one group.
static NSUInteger sg_apartCount;

static UIColor *itemColor(void) { return [UIColor colorWithWhite:0xB3 / 255.0 alpha:1]; }

#pragma mark - the mod's own items

// Drawn the way Spotify's own are, an Encore glyph or an SF Symbol at the glyphs' size
// (Shared/Navigation/TabIcons.h).
static UIView *iconView(NSDictionary *entry) {
    return SGTabIconView(entry[SGNavbarIcon], [entry[SGNavbarIconSet] isEqual:SGTabIconSetSymbols], itemColor());
}

@interface SGTabItemView : UIControl
@property (nonatomic, copy) NSString *uri;
- (instancetype)initWithEntry:(NSDictionary *)entry;
- (void)applyEntry:(NSDictionary *)entry;
@end

@implementation SGTabItemView {
    NSString *_iconName;
    UIView *_icon;
    UILabel *_title;
}

- (instancetype)initWithEntry:(NSDictionary *)entry {
    if (!(self = [super initWithFrame:CGRectZero])) return nil;
    _title = [UILabel new];
    _title.textAlignment = NSTextAlignmentCenter;
    _title.textColor = itemColor();
    [self addSubview:_title];
    [self applyEntry:entry];
    [self addTarget:self action:@selector(open) forControlEvents:UIControlEventTouchUpInside];
    return self;
}

- (void)applyEntry:(NSDictionary *)entry {
    self.uri = entry[SGNavbarURI];
    _title.text = entry[SGNavbarTitle];
    // The set is part of the name: "star" is a glyph in one and a symbol in the other.
    NSString *name = [NSString stringWithFormat:@"%@ %@", entry[SGNavbarIconSet] ?: @"encore", entry[SGNavbarIcon] ?: @"star"];
    if ([name isEqualToString:_iconName]) return;
    [_icon removeFromSuperview];
    _iconName = [name copy];
    _icon = iconView(entry);
    // Encore's views lay themselves out from constraints; this one is placed by frame.
    _icon.translatesAutoresizingMaskIntoConstraints = YES;
    [self addSubview:_icon];
}

// Both boxes come off a neighbor, so whatever Spotify does to the row's line-up is copied rather than
// guessed at; only the horizontal centering is the item's own.
- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width = self.bounds.size.width;
    _title.font = sg_tabFont ?: [UIFont systemFontOfSize:10];
    _title.frame = CGRectMake(0, CGRectGetMinY(sg_labelBox), width, CGRectGetHeight(sg_labelBox));
    _icon.frame = CGRectMake((width - CGRectGetWidth(sg_iconBox)) / 2, CGRectGetMinY(sg_iconBox),
                             CGRectGetWidth(sg_iconBox), CGRectGetHeight(sg_iconBox));
}

// A row that splits its width evenly ignores this, but one that sizes itself to its content would
// otherwise have nothing to go on for an item of ours.
- (CGSize)intrinsicContentSize {
    return CGSizeMake(kIconSize * 2, kLabelTop + kLabelHeight);
}

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    self.alpha = highlighted ? 0.5 : 1;
}

// Through the app's own link dispatcher (Shared/Navigation/Links.h).
- (void)open {
    NSURL *url = self.uri.length ? [NSURL URLWithString:self.uri] : nil;
    if (!SGOpenSpotifyURI(url)) SGLog(@"navbar: cannot open %@, dispatcher %@", self.uri, SGLinkDispatcher());
}

@end

#pragma mark - composition

// Spotify's items are told apart by the label under the icon: it survives the element views being
// rebuilt, and it is the name the Navbar page lists them under.
static NSString *stockID(UIView *item) {
    __block NSString *text = nil;
    SGForEachView(item, ^(UIView *v) {
        if (!text && [v isKindOfClass:UILabel.class] && ((UILabel *)v).text.length) text = ((UILabel *)v).text;
    });
    return text ?: NSStringFromClass(item.class);
}

static void measureItem(UIView *item) {
    __block UIView *icon = nil, *label = nil;
    SGForEachView(item, ^(UIView *v) {
        if (!icon && SGClassNamed(v.class, @"IconView") && v.bounds.size.width > 1) icon = v;
        if (!label && [v isKindOfClass:UILabel.class] && ((UILabel *)v).text.length) label = v;
    });
    if (icon) sg_iconBox = SGFrameIn(icon, item);
    if (!label) return;
    sg_labelBox = SGFrameIn(label, item);
    if (!sg_tabFont) sg_tabFont = ((UILabel *)label).font;
}

static NSMutableDictionary<NSString *, SGTabItemView *> *customItems(UIStackView *stack) {
    NSMutableDictionary *items = objc_getAssociatedObject(stack, &kCustomKey);
    if (!items) {
        items = [NSMutableDictionary dictionary];
        objc_setAssociatedObject(stack, &kCustomKey, items, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return items;
}

void SGComposeTabBar(UIView *tabBar) {
    UIStackView *stack = SGRowIn(tabBar);
    if (!stack) return;
    sg_navbarRoot = tabBar;

    NSMutableDictionary<NSString *, UIView *> *stockViews = [NSMutableDictionary dictionary];
    for (UIView *item in stack.arrangedSubviews) {
        if ([item isKindOfClass:SGTabItemView.class]) continue;
        NSString *ident = stockID(item);
        if (stockViews[ident]) continue;
        stockViews[ident] = item;
        measureItem(item);
        if (!sg_stockOrder) sg_stockOrder = [NSMutableArray array];
        if (![sg_stockOrder containsObject:ident]) [sg_stockOrder addObject:ident];
    }
    if (sg_stockOrder && ![sg_stockOrder isEqualToArray:SGNavbarStock()]) SGSetNavbarStock(sg_stockOrder);

    NSMutableDictionary<NSString *, SGTabItemView *> *custom = customItems(stack);
    NSMutableArray<UIView *> *wanted = [NSMutableArray array];
    NSMutableSet<NSString *> *placed = [NSMutableSet set];
    NSMutableSet<NSString *> *keep = [NSMutableSet set];
    NSSet<NSString *> *split = SGEnabled(SGKeyNavbar) ? [NSSet setWithArray:SGNavbarSplit()] : nil;
    NSMutableSet<UIView *> *apart = [NSMutableSet set];

    if (SGEnabled(SGKeyNavbar)) {
        for (NSDictionary *entry in SGNavbarLayout()) {
            NSString *ident = entry[SGNavbarID];
            if (![ident isKindOfClass:NSString.class] || [placed containsObject:ident]) continue;
            [placed addObject:ident];
            BOOL hidden = [entry[SGNavbarHidden] boolValue];
            if (entry[SGNavbarURI]) {
                if (hidden) continue;
                SGTabItemView *item = custom[ident];
                if (item) [item applyEntry:entry];
                else custom[ident] = item = [[SGTabItemView alloc] initWithEntry:entry];
                [keep addObject:ident];
                [wanted addObject:item];
                if ([split containsObject:ident]) [apart addObject:item];
            } else if (stockViews[ident]) {
                stockViews[ident].hidden = hidden;
                [wanted addObject:stockViews[ident]];
                if ([split containsObject:ident]) [apart addObject:stockViews[ident]];
            }
        }
    }
    // Tabs of Spotify's the list does not name — or named before Spotify had built them — keep
    // Spotify's own place, at the end, shown.
    for (NSString *ident in sg_stockOrder) {
        UIView *item = stockViews[ident];
        if (!item || [wanted containsObject:item]) continue;
        item.hidden = NO;
        [wanted addObject:item];
        if ([split containsObject:ident]) [apart addObject:item];
    }
    for (NSString *ident in custom.allKeys) {
        if ([keep containsObject:ident]) continue;
        [custom[ident] removeFromSuperview];
        [custom removeObjectForKey:ident];
    }

    // A bar with nothing on it would strand whoever emptied it, so the last word is Spotify's.
    BOOL empty = YES;
    for (UIView *item in wanted) if (!item.hidden) empty = NO;
    if (empty) for (UIView *item in wanted) item.hidden = NO;

    // Items of the mod's own join the stack at the end, where they are past whatever Spotify
    // counts, and Spotify's own keep the places it gave them.
    for (UIView *item in wanted) {
        if ([item isKindOfClass:SGTabItemView.class] && item.superview != stack) [stack addArrangedSubview:item];
    }
    // Split tabs go to the end, each group in the list's order. With nothing left in the main group they
    // are the bar's one group.
    NSMutableArray<UIView *> *order = [NSMutableArray array], *trailing = [NSMutableArray array];
    for (UIView *item in wanted) {
        if (item.hidden || item.superview != stack) continue;
        [([apart containsObject:item] ? trailing : order) addObject:item];
    }
    NSUInteger apartCount = order.count ? trailing.count : 0;
    [order addObjectsFromArray:trailing];
    sg_row = stack;
    if (![order isEqualToArray:objc_getAssociatedObject(stack, &kOrderKey)] || apartCount != sg_apartCount) {
        sg_apartCount = apartCount;
        objc_setAssociatedObject(stack, &kOrderKey, order, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [stack setNeedsLayout];
    }
}

// Spotify placed the icon and the label for the width it measured (trees/test5.txt: x 28 in a
// 134pt slot, the center of the 80pt it had with five tabs) and lays the item out no further
// once the slot changes. Assigning the centers back sends them through the hooks below.
static void centreContents(UIView *item) {
    SGForEachView(item, ^(UIView *v) {
        if ([v isKindOfClass:%c(SPTEncoreIconView)] || [v isKindOfClass:%c(SPTEncoreLabel)]) v.center = v.center;
    });
}

// Equal slots across the bar, in the order composed above, the split tabs' after a gap. The frames go on
// after the stack's own pass, so Spotify's own widths never decide whether a fifth item fits.
static void placeRow(UIStackView *stack) {
    NSArray<UIView *> *order = objc_getAssociatedObject(stack, &kOrderKey);
    UIView *bar = sg_navbarRoot;
    if (!order.count || !bar) return;
    CGFloat gap = sg_apartCount ? kSplitGap : 0;
    CGFloat width = (bar.bounds.size.width - gap) / order.count;
    CGFloat height = stack.bounds.size.height;
    NSUInteger firstApart = order.count - sg_apartCount;
    [order enumerateObjectsUsingBlock:^(UIView *item, NSUInteger i, BOOL *stop) {
        CGFloat left = i * width + (i >= firstApart ? gap : 0);
        CGFloat x = [bar convertPoint:CGPointMake(left, 0) toView:stack].x;
        CGRect frame = CGRectMake(x, 0, width, height);
        if (!CGAffineTransformIsIdentity(item.transform)) item.transform = CGAffineTransformIdentity;
        if (!CGRectEqualToRect(item.frame, frame)) item.frame = frame;
        centreContents(item);
    }];
}

%hook UIStackView
- (void)layoutSubviews {
    %orig;
    if ((UIStackView *)self == sg_row) placeRow((UIStackView *)self);
}
%end

// Spotify's element layout places the icon and the label from the width it measured, not from
// the slot above (trees/test5.txt: x 38 in a 134pt element in a 126pt slot), and a view placed by
// its parent gets no layout pass of its own. So the placement itself is bent: on the bar, whatever
// x Spotify sets, the view lands centered on its slot.
static CGFloat slotCentreX(UIView *view) {
    UIStackView *row = sg_row;
    if (!row) return NAN;
    UIView *slot = nil;
    for (UIView *v = view; v.superview; v = v.superview) if (v.superview == row) { slot = v; break; }
    if (!slot) return NAN;
    return [slot convertPoint:CGPointMake(CGRectGetMidX(slot.bounds), 0) toView:view.superview].x;
}

%hook SPTEncoreIconView
- (void)setFrame:(CGRect)frame {
    CGFloat centre = slotCentreX((UIView *)self);
    if (!isnan(centre)) frame.origin.x = centre - frame.size.width / 2;
    %orig(frame);
}
- (void)setCenter:(CGPoint)center {
    CGFloat centre = slotCentreX((UIView *)self);
    if (!isnan(centre)) center.x = centre;
    %orig(center);
}
%end

%hook SPTEncoreLabel
- (void)setFrame:(CGRect)frame {
    CGFloat centre = slotCentreX((UIView *)self);
    if (!isnan(centre)) frame.origin.x = centre - frame.size.width / 2;
    %orig(frame);
}
- (void)setCenter:(CGPoint)center {
    CGFloat centre = slotCentreX((UIView *)self);
    if (!isnan(centre)) center.x = centre;
    %orig(center);
}
%end

void SGRefreshTabBar(void) {
    [sg_navbarRoot setNeedsLayout];
}

// What the row settled on, logged whenever it changes: `make log` then says whether the items fit,
// what is holding their width, and in what order the bar ended up.
void SGLogTabBarRow(UIView *tabBar) {
    // The row SGComposeTabBar found in this bar on the same pass, just before.
    UIStackView *stack = sg_row;
    if (!stack) return;
    // Describing the constraints is the costly part, so the row is described again only once its geometry,
    // its stack settings or its items change. shortcut: items past the 16th are not compared, raise it if a bar
    // ever holds more.
    struct {
        CGRect bar, stack, icon, label;
        NSInteger axis, distribution, alignment;
        CGFloat spacing;
        NSUInteger count;
        struct { const void *item; CGRect frame; BOOL hidden; } items[16];
    } key;
    memset(&key, 0, sizeof key);   // padding too, for memcmp
    key.bar = tabBar.frame;
    key.stack = stack.frame;
    key.icon = sg_iconBox;
    key.label = sg_labelBox;
    key.axis = stack.axis;
    key.distribution = stack.distribution;
    key.alignment = stack.alignment;
    key.spacing = stack.spacing;
    for (UIView *item in stack.arrangedSubviews) {
        NSUInteger i = key.count++;
        if (i >= 16) continue;
        key.items[i].item = (__bridge const void *)item;
        key.items[i].frame = item.frame;
        key.items[i].hidden = item.hidden;
    }
    static typeof(key) lastKey;
    if (!memcmp(&key, &lastKey, sizeof key)) return;
    memcpy(&lastKey, &key, sizeof key);
    NSMutableString *out = [NSMutableString stringWithFormat:@"row in %@ %@, icon %@ label %@, stack %@ axis %ld dist %ld align %ld spacing %.1f autolayout %d",
                            NSStringFromClass(tabBar.class), NSStringFromCGRect(tabBar.frame),
                            NSStringFromCGRect(sg_iconBox), NSStringFromCGRect(sg_labelBox), NSStringFromCGRect(stack.frame),
                            (long)stack.axis, (long)stack.distribution, (long)stack.alignment, stack.spacing,
                            !stack.translatesAutoresizingMaskIntoConstraints];
    NSUInteger index = 0;
    for (UIView *item in stack.arrangedSubviews) {
        [out appendFormat:@"\n  %lu %@ %@%@ autolayout %d", (unsigned long)index++, NSStringFromClass(item.class),
             NSStringFromCGRect(item.frame), item.hidden ? @" hidden" : @"",
             !item.translatesAutoresizingMaskIntoConstraints];
        for (NSLayoutConstraint *c in item.constraints) {
            if (c.firstAttribute == NSLayoutAttributeWidth || c.secondAttribute == NSLayoutAttributeWidth) [out appendFormat:@"\n    %@", c];
        }
    }
    for (NSLayoutConstraint *c in stack.constraints) [out appendFormat:@"\n  own %@", c];
    for (NSLayoutConstraint *c in stack.superview.constraints) {
        if (c.firstItem == stack || c.secondItem == stack) [out appendFormat:@"\n  held %@", c];
    }
    static NSString *last;
    if ([out isEqualToString:last]) return;
    last = [out copy];
    SGLogLong(@"navbar", out);
}

// Whether Spotify reads its own item list through this ObjC bridge decides whether the bar can be
// composed at the model level, where the order, the taps and the widths would all follow by
// themselves, instead of by moving views about. Silence in the log says it cannot.
%hook _TtC28NavigationUI_TabBarItemsImpl29TabBarItemsNavigationListImpl
- (NSArray *)items {
    NSArray *items = %orig;
    static BOOL logged;
    if (logged) return items;
    logged = YES;
    NSMutableString *out = [NSMutableString stringWithFormat:@"list read, %lu items", (unsigned long)items.count];
    for (id item in items) [out appendFormat:@"\n  %@ · %@", [item valueForKey:@"title"], [item valueForKey:@"viewURI"]];
    SGLogLong(@"navbar", out);
    return items;
}
%end

%ctor {
    if (!SGNativeUI()) return;
    %init;
    SGRequireClasses(@[
        @"SPTEncoreIcon",
        @"SPTEncoreIconView",
        @"SPTEncoreLabel",
        @"_TtC28NavigationUI_TabBarItemsImpl29TabBarItemsNavigationListImpl",
    ]);
}
