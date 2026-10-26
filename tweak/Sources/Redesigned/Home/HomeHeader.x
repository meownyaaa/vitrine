// Home redesign: the header the way the Music app has it. The filter pills (All, Music, Podcasts) go and
// a large title takes their place at the leading edge; the avatar that opens the side drawer moves to the
// trailing edge; the scrim Spotify lays behind the header goes too, the soft scroll edge (Kit/SGREdgeEffect.x)
// being what keeps the page scrolling under it soft; the title itself scrolls away (followScroll), or stays
// with the feed's hard edge under it (keepTitle).
//
// Tree (trees/clean/home/10.txt:3018-3051): FunkisViewController's view holds a 402x112 UIView around
// Reprise_LiquidGlassKit LiquidGlass.GradientView (the scrim) and, at {0, 62}, an
// ElementView<HomeHeaderElement> 402x50 holding HomeHeaderView > UIStackView {0, 8} 402x34 of two arranged
// views: ListeningActivity_ElementsKit.AdaptiveFaceContainer {16, 0} 32x34 (the avatar, an EncoreButton in 9.1.90,
// id=Components.UI.SideDrawerButton) and LiquidGlass.LeadingFadeMaskView {48, 1} 354x32 around
// Home_PillUIKit.PillScrollView.
//
// The avatar moves by the stack's layout direction rather than by a frame of ours. Right to left, the stack
// lays its first view out at the trailing edge itself on every pass, whatever width the face container
// takes when friends listening show beside the avatar; its leading margin, 16pt, is the one Spotify gives
// the header in a right to left language. The pills stay in the stack with no alpha rather than hidden,
// the way the redesign takes any view out of a stack Spotify arranges (Kit/SGRRestyle.h).
//
// The title is Spotify's own name for the tab, read off its tab bar item (id=TabBar.Item.Home, 10.txt:3100),
// so it follows the app's language.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Home.h"

// Tries at finding the tab's name before settling for the English one: a miss walks the window.
static const NSUInteger kTitleTries = 8;

static char kTitleKey, kTabKey, kPillGlassKey, kGlassKey, kButtonsKey, kConnectKey, kTintKey, kWatchKey;
// The title row's pill: a glass capsule around the filter button and the avatar, 44pt tall, as the reference has
// it; the menu drives Spotify's own filter chips, hidden in the stack, and offers the device picker when Spotify
// has one (a now playing bar) and the large shelf's Show all while its heading is gone (HomeTopPicks.x).
static const CGFloat kPillHeight = 44, kPillButton = 44, kPillPad = 6;
// The page's color behind the title (SGRHomeSetPageTint), fading to black over this height.
static const CGFloat kTintHeight = 480;

// The pill's buttons sit above Spotify's stack, which would take every touch in the header otherwise; a touch
// outside a button goes through to the avatar under them.
@interface SGRHomePillButtons : UIView
@property (nonatomic, strong) UIButton *filter;
@end
@implementation SGRHomePillButtons
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    return hit == self ? nil : hit;
}
@end

@interface SGRHomeTintView : UIView
@end
@implementation SGRHomeTintView
+ (Class)layerClass {
    return CAGradientLayer.class;
}
@end
static NSString *sg_tabName;

static void vanish(UIView *view) {
    if (!view) return;
    if (view.alpha != 0) view.alpha = 0;
    view.userInteractionEnabled = NO;
    view.accessibilityElementsHidden = YES;
}

static UIView *childNamed(UIView *host, NSString *marker) {
    for (UIView *sub in host.subviews) {
        if ([NSStringFromClass(sub.class) containsString:marker]) return sub;
    }
    return nil;
}

static NSString *tabName(UIWindow *window) {
    if (sg_tabName || !window) return sg_tabName ?: @"Home";
    static NSUInteger tries;
    if (tries >= kTitleTries) return @"Home";
    tries++;
    UIView *item = SGRFindByIdentifier(window, @"TabBar.Item.Home", &kTabKey);
    __block NSString *name = nil;
    if (item) SGForEachView(item, ^(UIView *v) {
        if (!name && [v isKindOfClass:UILabel.class] && ((UILabel *)v).text.length) name = ((UILabel *)v).text;
    });
    if (!name) {
        if (tries == kTitleTries) SGLog(@"redesign home: the Home tab's name not found, the title stays English");
        return @"Home";
    }
    sg_tabName = [name copy];
    SGLog(@"redesign home: title \"%@\" from the tab bar", sg_tabName);
    return sg_tabName;
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

// The header's views, found once: the page lays out again as it appears, and the walk names classes.
static __weak UIView *sg_header;
static __weak UIStackView *sg_stack;
static __weak UIView *sg_scrim;
static UIControl *connectButton(UIView *window);

#pragma mark - the pill

// Spotify's filter chips (All, Music, Podcasts, Audiobooks), controls in the stack's hidden pill scroller, in
// their order there.
static NSArray<UIControl *> *chips(UIStackView *stack) {
    NSMutableArray<UIControl *> *found = [NSMutableArray array];
    SGForEachView(stack, ^(UIView *v) {
        if ([v.accessibilityIdentifier hasPrefix:@"home-feed-"] && [v isKindOfClass:UIControl.class]) [found addObject:(UIControl *)v];
    });
    return [found sortedArrayUsingComparator:^NSComparisonResult(UIView *a, UIView *b) {
        CGFloat xa = [a convertRect:a.bounds toView:stack].origin.x, xb = [b convertRect:b.bounds toView:stack].origin.x;
        return xa < xb ? NSOrderedAscending : xa > xb ? NSOrderedDescending : NSOrderedSame;
    }];
}

// The chip in effect: selected, or drawn solid with its glass hidden (home-feed-default, trees 2026-10-11).
static BOOL chosen(UIControl *chip) {
    if (chip.selected) return YES;
    __block BOOL solid = NO;
    SGForEachView(chip, ^(UIView *v) {
        if ([NSStringFromClass(v.class) containsString:@"ChipGlassView"] && v.hidden) solid = YES;
    });
    return solid;
}

static NSArray<UIMenuElement *> *menuElements(void) {
    NSMutableArray<UIMenuElement *> *elements = [NSMutableArray array];
    NSMutableArray<UIMenuElement *> *filters = [NSMutableArray array];
    for (UIControl *chip in chips(sg_stack)) {
        __weak UIControl *weakChip = chip;
        UIAction *action = [UIAction actionWithTitle:chip.accessibilityLabel ?: @"" image:nil identifier:nil handler:^(UIAction *a) {
            if (weakChip) SGRActivate(weakChip);
        }];
        action.state = chosen(chip) ? UIMenuElementStateOn : UIMenuElementStateOff;
        [filters addObject:action];
    }
    if (filters.count) [elements addObject:[UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:filters]];
    NSMutableArray<UIMenuElement *> *more = [NSMutableArray array];
    UIControl *connect = connectButton(sg_header.window);
    if (connect) {
        __weak UIControl *weakConnect = connect;
        [more addObject:[UIAction actionWithTitle:@"Devices" image:[UIImage systemImageNamed:@"hifispeaker"] identifier:nil handler:^(UIAction *a) {
            if (weakConnect) SGRActivate(weakConnect);
        }]];
    }
    NSString *title = nil;
    UIControl *showAll = SGRHomeTopPicksShowAll(&title);
    if (showAll) {
        __weak UIControl *weakShowAll = showAll;
        [more addObject:[UIAction actionWithTitle:title.length ? [NSString stringWithFormat:@"Show all · %@", title] : @"Show all"
                                            image:[UIImage systemImageNamed:@"rectangle.stack"] identifier:nil handler:^(UIAction *a) {
            if (weakShowAll) SGRActivate(weakShowAll);
        }]];
    }
    if (more.count) [elements addObject:[UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:more]];
    return elements;
}

// Spotify's device picker button, in the now playing bar (Components.ConnectButtonOutputSwitcher > UIButton,
// trees 2026-10-11); nil without a bar.
static UIControl *connectButton(UIView *window) {
    UIView *holder = window ? SGRFindByIdentifier(window, @"Components.ConnectButtonOutputSwitcher", &kConnectKey) : nil;
    __block UIControl *button = [holder isKindOfClass:UIControl.class] ? (UIControl *)holder : nil;
    if (!button) SGForEachView(holder, ^(UIView *v) {
        if (!button && [v isKindOfClass:UIControl.class]) button = (UIControl *)v;
    });
    return button;
}

static UIButton *pillButton(NSString *symbol, NSString *label) {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:17 weight:UIImageSymbolWeightMedium];
    [button setImage:[UIImage systemImageNamed:symbol withConfiguration:config] forState:UIControlStateNormal];
    button.tintColor = SGRPrimary();
    button.accessibilityLabel = label;
    // The menu takes the appearance of its button; outside Spotify's navigation stacks that is the system's.
    button.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    return button;
}

static SGRHomePillButtons *buttonsIn(UIView *header) {
    SGRHomePillButtons *buttons = objc_getAssociatedObject(header, &kButtonsKey);
    if (!buttons) {
        buttons = [SGRHomePillButtons new];
        buttons.filter = pillButton(@"line.3.horizontal.decrease", @"Filter Home");
        buttons.filter.menu = [UIMenu menuWithChildren:@[[UIDeferredMenuElement elementWithUncachedProvider:^(void (^completion)(NSArray<UIMenuElement *> *)) {
            completion(menuElements());
        }]]];
        buttons.filter.showsMenuAsPrimaryAction = YES;
        [buttons addSubview:buttons.filter];
        objc_setAssociatedObject(header, &kButtonsKey, buttons, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (buttons.superview != header) [header addSubview:buttons];
    else if (header.subviews.lastObject != buttons) [header bringSubviewToFront:buttons];
    return buttons;
}

static UIView *glassIn(UIView *header) {
    UIView *glass = objc_getAssociatedObject(header, &kGlassKey);
    if (!glass) {
        glass = [UIView new];
        glass.userInteractionEnabled = NO;
        objc_setAssociatedObject(header, &kGlassKey, glass, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (glass.superview != header) [header insertSubview:glass atIndex:0];
    else if (header.subviews.firstObject != glass) [header sendSubviewToBack:glass];
    return glass;
}

// Lays the pill out around the avatar, which stays Spotify's in its stack; the pill's leading edge.
// The stack's place in the header with no transform on it (its center and bounds, which a transform leaves
// alone): Spotify animates the stack in with a transform, and the one pass this ran in on a 440pt phone saw the
// stack's frame half a width to the left, with no pass after to put the pill right.
static CGRect untransformed(UIView *view) {
    CGSize size = view.bounds.size;
    return CGRectMake(view.center.x - size.width / 2, view.center.y - size.height / 2, size.width, size.height);
}

// The avatar's place, by its center and bounds too: it carries the scroll's transform (followScroll), unless kept.
static CGRect facePlace(UIStackView *stack, UIView *face) {
    CGRect place = untransformed(stack);
    return CGRectOffset(untransformed(face), place.origin.x - stack.bounds.origin.x, place.origin.y - stack.bounds.origin.y);
}

// A view placed by bounds and center, which the scroll's transform leaves alone.
static void place(UIView *view, CGRect frame) {
    CGRect bounds = (CGRect){CGPointZero, frame.size};
    CGPoint center = CGPointMake(CGRectGetMidX(frame), CGRectGetMidY(frame));
    if (!CGRectEqualToRect(view.bounds, bounds)) view.bounds = bounds;
    if (!CGPointEqualToPoint(view.center, center)) view.center = center;
}

static CGFloat layoutPill(UIView *header, UIStackView *stack, UIView *face) {
    SGRHomePillButtons *buttons = buttonsIn(header);
    UIView *glass = glassIn(header);
    CGRect faceFrame = face ? facePlace(stack, face) : CGRectZero;
    CGFloat width = kPillPad + kPillButton + (face ? faceFrame.size.width + kPillPad * 2 : kPillPad);
    CGFloat maxX = face ? CGRectGetMaxX(faceFrame) + kPillPad : header.bounds.size.width - SGRSideMargin;
    CGFloat midY = face ? CGRectGetMidY(faceFrame) : CGRectGetMidY(untransformed(stack));
    CGRect pill = CGRectMake(round(maxX - width), round(midY - kPillHeight / 2), width, kPillHeight);
    place(glass, pill);
    place(buttons, pill);
    CGRect filter = CGRectMake(kPillPad, 0, kPillButton, kPillHeight);
    if (!CGRectEqualToRect(buttons.filter.frame, filter)) buttons.filter.frame = filter;
    SGRGlassCapsuleInside(glass, &kPillGlassKey, pill.size, NO);
    return CGRectGetMinX(pill);
}

#pragma mark - the page's color

static UIColor *sg_pageTint;
static __weak SGRHomeTintView *sg_tintView;

static void paintTint(SGRHomeTintView *tint, BOOL animated) {
    CAGradientLayer *layer = (CAGradientLayer *)tint.layer;
    UIColor *top = sg_pageTint ?: UIColor.blackColor;
    NSArray *colors = @[(id)top.CGColor, (id)[top colorWithAlphaComponent:0].CGColor];
    if ([layer.colors isEqualToArray:colors]) return;
    if (animated && tint.window) {
        CABasicAnimation *fade = [CABasicAnimation animationWithKeyPath:@"colors"];
        fade.fromValue = layer.colors;
        fade.duration = SGRCrossfade;
        [layer addAnimation:fade forKey:@"colors"];
    }
    layer.colors = colors;
}

void SGRHomeSetPageTint(UIColor *color) {
    if (color == sg_pageTint || [color isEqual:sg_pageTint]) return;
    sg_pageTint = color;
    if (sg_tintView) paintTint(sg_tintView, YES);
}

// The gradient at the back of the page's view (HomePageView, which holds the feed), the feed's own black cleared so
// it shows through behind the title and the first shelf; the shelves clear theirs (HomeSections.x).
static void layoutTint(UIView *view) {
    __block UIView *page = sg_tintView.superview;
    if (!page) SGForEachView(view, ^(UIView *v) {
        if (!page && [v.accessibilityIdentifier hasPrefix:@"HomePageView"]) page = v;
    });
    if (!page) return;
    SGRHomeTintView *tint = objc_getAssociatedObject(page, &kTintKey);
    if (!tint) {
        tint = [SGRHomeTintView new];
        tint.userInteractionEnabled = NO;
        objc_setAssociatedObject(page, &kTintKey, tint, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        sg_tintView = tint;
        paintTint(tint, NO);
    }
    if (tint.superview != page) [page insertSubview:tint atIndex:0];
    CGRect frame = CGRectMake(0, 0, page.bounds.size.width, kTintHeight);
    if (!CGRectEqualToRect(tint.frame, frame)) tint.frame = frame;
    for (UIView *sub in page.subviews) {
        if ([sub isKindOfClass:UICollectionView.class] && ![sub.backgroundColor isEqual:UIColor.clearColor]) sub.backgroundColor = UIColor.clearColor;
    }
}

static BOOL findHeader(UIView *view) {
    if (sg_stack && [sg_stack isDescendantOfView:view]) return YES;
    for (UIView *wrapper in view.subviews) {
        UIView *scrim = childNamed(wrapper, @"GradientView");
        if (scrim) sg_scrim = scrim;
    }
    UIView *header = childNamed(childNamed(view, @"HomeHeaderElement"), @"HomeHeaderView");
    for (UIView *sub in header.subviews) {
        if ([sub isKindOfClass:UIStackView.class]) sg_stack = (UIStackView *)sub;
    }
    sg_header = header;
    if (sg_stack) return YES;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ SGLog(@"redesign home: header stack not found, header left as Spotify's"); });
    return NO;
}

// The title row scrolls away with the page, as the Music app's large title and avatar do: the title, the glass pill
// and Spotify's avatar rise with what is under them and fade over the title's height, so the page never passes
// under them. Kept in place instead (keepTitle), the page passes under them over a hard edge.
static __weak UIView *sg_face;
static void rise(UIView *part, CGAffineTransform transform, CGFloat alpha) {
    if (!CGAffineTransformEqualToTransform(part.transform, transform)) part.transform = transform;
    if (part.alpha != alpha) part.alpha = alpha;
}

// The pill's glass takes no alpha (SGRGlass.h): it rises with the row, and its material goes off once the row is
// half faded and comes back with it.
static const NSTimeInterval kGlassFade = 0.15;
static BOOL sg_glassShown = YES;
// When the material's last change ends: until then the glass keeps rising after the row has faded.
static CFTimeInterval sg_glassFadeEnds;
static void riseGlass(UIView *glass, CGAffineTransform transform, CGFloat alpha) {
    if (!glass) return;
    if (!CGAffineTransformEqualToTransform(glass.transform, transform)) glass.transform = transform;
    BOOL shown = alpha > 0.5;
    UIView *shape = objc_getAssociatedObject(glass, &kPillGlassKey);
    if (!shape || shown == sg_glassShown) return;
    sg_glassShown = shown;
    sg_glassFadeEnds = CACurrentMediaTime() + kGlassFade;
    [UIView animateWithDuration:kGlassFade animations:^{ SGRShowGlass(shape, shown); }];
}

static void followScroll(UIScrollView *scroll) {
    UILabel *title = sg_header ? objc_getAssociatedObject(sg_header, &kTitleKey) : nil;
    if (!title || !scroll) return;
    CGFloat scrolled = MAX(0, scroll.contentOffset.y + scroll.adjustedContentInset.top), faded = MAX(1, title.bounds.size.height);
    CGFloat alpha = 1 - MIN(1, scrolled / faded);
    // Past the title's height the row has faded out, so it stops rising there and nothing is written again until it
    // comes back; the glass keeps rising while its material is still going off.
    CGAffineTransform up = CGAffineTransformMakeTranslation(0, -MIN(scrolled, faded));
    BOOL glassFading = CACurrentMediaTime() < sg_glassFadeEnds || (alpha > 0.5) != sg_glassShown;
    rise(title, up, alpha);
    riseGlass(objc_getAssociatedObject(sg_header, &kGlassKey), glassFading ? CGAffineTransformMakeTranslation(0, -scrolled) : up, alpha);
    rise(objc_getAssociatedObject(sg_header, &kButtonsKey), up, alpha);
    if ([sg_face isDescendantOfView:sg_header]) rise(sg_face, up, alpha);
}

@interface SGRHomeTitleFollower : NSObject
@property (nonatomic, weak) UIScrollView *scroll;
@end

@implementation SGRHomeTitleFollower
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    followScroll(self.scroll);
}
@end

// The feed: the page's outermost scroll view taller than the pills, found once. Not the tallest: a shelf can grow taller
// than the page, and a shelf's offset never moves the title. Followed by an observer that lives as long as it does.
static char kFollowerKey, kEdgeKey;
static __weak UIScrollView *sg_feed;
static __weak UIView *sg_pageView;
// Kept in place (SGRKeyHomeKeepTitle), the row stays and no observer is added: the header instead shapes the feed's
// top edge effect, hard rather than the redesign's soft one (too faint under a large title, as Apple's guidelines
// say of text outside glass), which then darkens the page under the title and the pill as under a navigation bar.
static BOOL keepTitle(void) {
    static int state = -1;
    // Below iOS 26 there is no edge effect to put under it, and the scrim is gone: the title scrolls away there.
    if (state < 0) state = SGRedesignAvailable() && SGHidden(SGRKeyHomeKeepTitle) ? 1 : 0;
    return state == 1;
}

static void shapeEdge(UIScrollView *feed) {
    SGRHardTopEdge(feed);
    if (@available(iOS 26.0, *)) {
        UIView *header = sg_header;
        if (!header) return;
        UIScrollEdgeElementContainerInteraction *edge = objc_getAssociatedObject(header, &kEdgeKey);
        if (!edge) {
            edge = [UIScrollEdgeElementContainerInteraction new];
            edge.edge = UIRectEdgeTop;
            [header addInteraction:edge];
            objc_setAssociatedObject(header, &kEdgeKey, edge, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        if (edge.scrollView != feed) edge.scrollView = feed;
    }
}

static void followFeed(UIScrollView *feed) {
    sg_feed = feed;
    if (keepTitle()) {
        shapeEdge(feed);
        return;
    }
    if (!objc_getAssociatedObject(feed, &kFollowerKey)) {
        SGRHomeTitleFollower *follower = [SGRHomeTitleFollower new];
        follower.scroll = feed;
        [feed addObserver:follower forKeyPath:@"contentOffset" options:0 context:NULL];
        objc_setAssociatedObject(feed, &kFollowerKey, follower, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    followScroll(feed);
}

static void follow(UIView *view) {
    __block UIScrollView *feed = sg_feed;
    if (![feed isDescendantOfView:view]) feed = nil;
    if (!feed) SGForEachView(view, ^(UIView *v) {
        if (!feed && [v isKindOfClass:UIScrollView.class] && v.bounds.size.height > 300) feed = (UIScrollView *)v;
    });
    if (feed) followFeed(feed);
}

static void layoutHeader(UIViewController *page);

// The page's own pass can run before Spotify has sized its header at all (the header's view 0 by 0, its stack still
// a width to the left and centered on the origin: seen on a 440pt phone, with no pass of the page after, which
// left the pill beside the title). While the header has no size, this comes back a little later, for a few seconds
// at most, until it has one.
static const NSUInteger kHeaderWaits = 30;
static const NSTimeInterval kHeaderWait = 0.1;
static void layoutHeaderOnceSized(UIViewController *page, UIView *header) {
    // findHeader answers YES on the stack alone, so the header can be gone while the stack is not.
    if (!header) return;
    if (!CGRectIsEmpty(header.bounds)) {
        // Sized: a later spell without a size gets its waits again.
        if (objc_getAssociatedObject(header, &kWatchKey)) objc_setAssociatedObject(header, &kWatchKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }
    NSUInteger waits = [objc_getAssociatedObject(header, &kWatchKey) unsignedIntegerValue];
    if (waits >= kHeaderWaits) return;
    objc_setAssociatedObject(header, &kWatchKey, @(waits + 1), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __weak UIViewController *weakPage = page;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kHeaderWait * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIViewController *strongPage = weakPage;
        if (strongPage) layoutHeader(strongPage);
    });
}

static void layoutHeader(UIViewController *page) {
    UIView *view = page.viewIfLoaded;
    if (!view || !findHeader(view)) return;
    sg_pageView = view;
    UIView *header = sg_header;
    UIStackView *stack = sg_stack;
    vanish(sg_scrim);
    layoutHeaderOnceSized(page, header);

    UIView *face = nil;
    for (UIView *part in stack.arrangedSubviews) {
        if (SGRIsAvatar(part) && !face) face = part;
        else vanish(part);
    }
    // A face that stopped being the avatar drops the scroll's transform and fade.
    if (sg_face && sg_face != face) rise(sg_face, CGAffineTransformIdentity, 1);
    sg_face = face;
    // Brought back if an earlier pass took it for a pill (vanish). Its alpha is otherwise the scroll's (followScroll).
    if (!face.userInteractionEnabled && face.accessibilityElementsHidden) {
        face.alpha = 1;
        face.userInteractionEnabled = YES;
        face.accessibilityElementsHidden = NO;
    }
    if (stack.semanticContentAttribute != UISemanticContentAttributeForceRightToLeft) {
        stack.semanticContentAttribute = UISemanticContentAttributeForceRightToLeft;
        [stack setNeedsLayout];
    }
    [stack layoutIfNeeded];
    // With the Home look off, the avatar stands alone in the stack and the title ends before it; it rises and fades
    // with the title either way.
    CGFloat pillLeading = face ? CGRectGetMinX(facePlace(stack, face)) : header.bounds.size.width - SGRSideMargin + SGRGrid;
    if (SGRHomeLook()) {
        pillLeading = layoutPill(header, stack, face);
        layoutTint(view);
    }

    UILabel *title = titleIn(header);
    NSString *text = tabName(header.window);
    if (![title.text isEqualToString:text]) {
        title.text = text;
        title.accessibilityLabel = text;
    }
    UIFont *font = SGRFont(UIFontTextStyleLargeTitle, UIFontWeightBold, UIContentSizeCategoryLarge);
    if (![title.font isEqual:font]) title.font = font;

    CGFloat trailing = pillLeading - SGRGrid;
    CGFloat height = ceil(font.lineHeight);
    CGRect frame = CGRectMake(SGRSideMargin, round(CGRectGetMidY(untransformed(stack)) - height / 2), MAX(0, trailing - SGRSideMargin), height);
    place(title, frame);
    follow(view);

    static dispatch_once_t once;
    dispatch_once(&once, ^{
        SGLog(@"redesign home: header %@, avatar %@ in the stack %@, title %@, scrim %@", NSStringFromCGRect(header.frame),
              face ? NSStringFromCGRect(face.frame) : @"not found", NSStringFromCGRect(stack.frame), NSStringFromCGRect(frame),
              sg_scrim ? @"found" : @"not found");
    });
}

// The feed can come after the header's last pass (its page loads while the header is laid out, a few seconds on
// a slow account), and the page's view has no pass of its own after; a feed that replaces another (a filter) comes
// while the old one is still in the window. The feed's own controller hands it the follower on each of its passes.
%hook _TtC16Home_EvoPageImpl33EvoLoadableResourceViewController
- (void)viewDidLayoutSubviews {
    %orig;
    UIView *view = ((UIViewController *)self).viewIfLoaded;
    if (!sg_pageView || !view.window || ![view isDescendantOfView:sg_pageView]) return;
    for (UIView *sub in view.subviews) {
        if ([sub isKindOfClass:UICollectionView.class]) {
            if (sub != sg_feed) followFeed((UIScrollView *)sub);
            break;
        }
    }
}
%end

%hook _TtC19Home_FunkisPageImpl20FunkisViewController
- (void)viewDidLayoutSubviews {
    %orig;
    CFTimeInterval began = SGRHomeProbeBegin();
    layoutHeader((UIViewController *)self);
    SGRHomeProbeEnd(SGRHomeProbeHeader, began);
}

- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    %orig;
    [((UIViewController *)self).viewIfLoaded setNeedsLayout];
}
%end

%ctor {
    if (!SGRedesignedUI()) return;
    %init;
    SGRequireClasses(@[
        @"_TtC19Home_FunkisPageImpl20FunkisViewController",
        @"_TtC16Home_EvoPageImpl33EvoLoadableResourceViewController",
        @"_TtC29ListeningActivity_ElementsKit21AdaptiveFaceContainer",
    ]);
}
