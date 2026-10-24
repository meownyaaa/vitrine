#import "Core/SGCore.h"
#import "Shared/AdBlock/AdBlock.h"
#import "AlbumQueue.h"

@interface SGAlbumQueuePage : NSObject
+ (NSString *)albumURI:(id)controller;
@end

static char kURIKey, kRowKey, kNativeKey, kSeenKey;
static NSString *sg_pending;
static CFTimeInterval sg_markedAt;
static NSString *const kPageClass = @"_TtC28CreativeWorkPlatform_PageKit24CreativeWorkTemplateView";

static NSString *SGAlbumQueueURIForView(UIView *view) {
    // The page model is the authority; a track's own ⋯ shares the page but has another identifier.
    static Class pageClass;
    if (!pageClass) pageClass = NSClassFromString(kPageClass);
    UIView *page = view;
    while (page && ![page isKindOfClass:pageClass]) page = page.superview;
    if (!page) return nil;
    NSString *uri;
    for (UIResponder *r = page.nextResponder; r; r = r.nextResponder) {
        if ([r isKindOfClass:UIViewController.class]) {
            uri = [SGAlbumQueuePage albumURI:r];
            if (uri) break;
        }
    }
    if (!SGAlbumQueueIsAlbumURI(uri)) return nil;
    NSString *identifier = [SGAlbumQueueButtonPrefix stringByAppendingString:[uri substringFromIndex:@"spotify:album:".length]];
    if (![view.accessibilityIdentifier isEqualToString:identifier]) return nil;
    for (UIView *v = view; v != page; v = v.superview) {
        if ([v.accessibilityIdentifier isEqualToString:@"CreativeWorkPlatform.Header"]) return uri;
    }
    // A pinned button lives outside the header. Find the original inside the header only.
    __block BOOL matches = NO;
    SGForEachView(page, ^(UIView *header) {
        if (![header.accessibilityIdentifier isEqualToString:@"CreativeWorkPlatform.Header"]) return;
        SGForEachView(header, ^(UIView *v) { if ([v.accessibilityIdentifier isEqualToString:identifier]) matches = YES; });
    });
    return matches ? uri : nil;
}

void SGAlbumQueueMarkSource(UIView *view) {
    sg_pending = SGAlbumQueueURIForView(view);
    sg_markedAt = CACurrentMediaTime();
}

static UITableView *tableIn(UIView *view, NSUInteger depth) {
    if ([view isKindOfClass:UITableView.class]) return (UITableView *)view;
    if (depth > 6) return nil;
    for (UIView *child in view.subviews) {
        UITableView *table = tableIn(child, depth + 1);
        if (table) return table;
    }
    return nil;
}

// Spotify's item number "11" first, so another language still matches, then the English title, as
// Redesigned/ContextMenu's quickItems() does for a sheet without the number.
static BOOL isNativeQueueView(UIView *view) {
    if ([view.accessibilityIdentifier isEqualToString:@"11"]) return YES;
    if (![view isKindOfClass:UILabel.class]) return NO;
    NSString *title = [((UILabel *)view).text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return [title.lowercaseString isEqualToString:@"add to queue"];
}

static BOOL hasNativeQueueRow(UITableView *table) {
    for (NSInteger section = 0; section < table.numberOfSections; section++) {
        for (NSInteger index = 0; index < [table numberOfRowsInSection:section]; index++) {
            NSIndexPath *path = [NSIndexPath indexPathForRow:index inSection:section];
            UITableViewCell *cell = [table cellForRowAtIndexPath:path];
            cell = cell ?: [table.dataSource tableView:table cellForRowAtIndexPath:path];
            __block BOOL found = NO;
            SGForEachView(cell, ^(UIView *v) { if (isNativeQueueView(v)) found = YES; });
            if (found) return YES;
        }
    }
    return NO;
}

// The outcome as a glass capsule under the Dynamic Island, the way the system confirms an action.
// It materializes on a critically damped spring, leaves the way it came, and a tap or an upward
// swipe sends it off early. VoiceOver hears the same words.
@interface SGAlbumQueueNotice : UIView
@end
@implementation SGAlbumQueueNotice {
    UIVisualEffectView *_glass;
    CGFloat _restY;
    BOOL _leaving;
}
static __weak SGAlbumQueueNotice *sg_notice;

+ (void)showIn:(UIWindow *)window title:(NSString *)title detail:(NSString *)detail symbol:(NSString *)symbol {
    if (!window) return;
    [sg_notice leave:0];
    SGAlbumQueueNotice *notice = [[self alloc] initWithFrame:CGRectZero];
    notice.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    [notice buildIn:window title:title detail:detail symbol:symbol];
    sg_notice = notice;
    UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, notice.accessibilityLabel);
    // Long enough to read: a confirmation is glanced at, a problem is read.
    NSTimeInterval stay = detail ? 2.5 : 4;
    __weak SGAlbumQueueNotice *weakNotice = notice;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(stay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [weakNotice leave:0]; });
}

- (void)buildIn:(UIWindow *)window title:(NSString *)title detail:(NSString *)detail symbol:(NSString *)symbol {
    UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:symbol]];
    icon.preferredSymbolConfiguration = [UIImageSymbolConfiguration configurationWithTextStyle:UIFontTextStyleBody scale:UIImageSymbolScaleMedium];
    icon.tintColor = UIColor.labelColor;
    icon.contentMode = UIViewContentModeCenter;
    UILabel *top = [UILabel new];
    top.text = title;
    UIFont *subheadline = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    top.font = [UIFont systemFontOfSize:subheadline.pointSize weight:UIFontWeightSemibold];
    top.textColor = UIColor.labelColor;
    top.numberOfLines = 0;
    top.textAlignment = detail ? NSTextAlignmentNatural : NSTextAlignmentCenter;
    UILabel *bottom = [UILabel new];
    bottom.text = detail;
    bottom.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    // secondaryLabelColor reads under 3:1 on the tinted glass; this reads about 5.7:1.
    bottom.textColor = [UIColor colorWithWhite:1 alpha:0.78];

    // Hugs its words, up to a width that keeps a line short enough to read at a glance.
    CGFloat maxWidth = MIN(window.bounds.size.width - 32, 380), iconSide = 28, pad = 18, gap = 10;
    CGFloat textMax = maxWidth - pad * 2 - iconSide - gap;
    CGSize topSize = [top sizeThatFits:CGSizeMake(textMax, CGFLOAT_MAX)];
    CGSize bottomSize = detail ? [bottom sizeThatFits:CGSizeMake(textMax, CGFLOAT_MAX)] : CGSizeZero;
    CGFloat textWidth = MIN(textMax, MAX(topSize.width, bottomSize.width));
    CGFloat textHeight = topSize.height + bottomSize.height;
    CGFloat height = MAX(50, textHeight + 24), width = pad * 2 + iconSide + gap + textWidth;
    _restY = window.safeAreaInsets.top + 6;
    self.frame = CGRectMake((window.bounds.size.width - width) / 2, _restY, width, height);
    self.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;

    _glass = [[UIVisualEffectView alloc] initWithEffect:nil];
    _glass.frame = self.bounds;
    _glass.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self addSubview:_glass];
    SGShapeGlass(_glass, 22, textHeight < 40);
    icon.frame = CGRectMake(pad, (height - iconSide) / 2, iconSide, iconSide);
    CGFloat y = (height - textHeight) / 2;
    top.frame = CGRectMake(pad + iconSide + gap, y, textWidth, topSize.height);
    bottom.frame = CGRectMake(pad + iconSide + gap, y + topSize.height, textWidth, bottomSize.height);
    for (UIView *v in @[icon, top, bottom]) [_glass.contentView addSubview:v];

    self.isAccessibilityElement = YES;
    self.accessibilityLabel = detail ? [NSString stringWithFormat:@"%@, %@", title, detail] : title;
    self.accessibilityHint = @"Double-tap to dismiss.";
    [self addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tapped)]];
    [self addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(dragged:)]];
    [window addSubview:self];

    // Reduce Motion keeps the fade and drops the travel.
    BOOL still = UIAccessibilityIsReduceMotionEnabled();
    self.alpha = 0;
    self.transform = still ? CGAffineTransformIdentity : CGAffineTransformScale(CGAffineTransformMakeTranslation(0, -height), 0.9, 0.9);
    // Glass turns light over a light cover; the tint keeps it dark enough for white words.
    UIVisualEffect *effect = SGGlassEffect();
    if ([effect respondsToSelector:@selector(setTintColor:)]) [(id)effect setTintColor:[UIColor colorWithWhite:0 alpha:0.55]];
    [UIView animateWithDuration:0.5 delay:0 usingSpringWithDamping:1 initialSpringVelocity:0 options:UIViewAnimationOptionAllowUserInteraction animations:^{
        self.alpha = 1;
        self.transform = CGAffineTransformIdentity;
        self->_glass.effect = effect;
    } completion:nil];
}

- (void)tapped {
    [self leave:0];
}

// Follows the finger up, resists going down, and leaves on a flick or a short lift.
- (void)dragged:(UIPanGestureRecognizer *)pan {
    CGFloat dy = [pan translationInView:self.superview].y;
    if (pan.state == UIGestureRecognizerStateChanged) {
        self.transform = CGAffineTransformMakeTranslation(0, dy < 0 ? dy : dy / (1 + dy / 30));
    } else if (pan.state == UIGestureRecognizerStateEnded || pan.state == UIGestureRecognizerStateCancelled) {
        CGFloat velocity = [pan velocityInView:self.superview].y;
        if (dy < -16 || velocity < -300) {
            [self leave:velocity];
        } else {
            [UIView animateWithDuration:0.4 delay:0 usingSpringWithDamping:1 initialSpringVelocity:0 options:UIViewAnimationOptionAllowUserInteraction animations:^{
                self.transform = CGAffineTransformIdentity;
            } completion:nil];
        }
    }
}

- (void)leave:(CGFloat)velocity {
    if (_leaving) return;
    _leaving = YES;
    BOOL still = UIAccessibilityIsReduceMotionEnabled();
    CGFloat distance = self.frame.origin.y + self.bounds.size.height;
    CGFloat spring = distance > 0 && velocity < 0 ? -velocity / distance : 0;
    [UIView animateWithDuration:0.35 delay:0 usingSpringWithDamping:1 initialSpringVelocity:spring options:UIViewAnimationOptionBeginFromCurrentState animations:^{
        self.alpha = 0;
        if (!still) self.transform = CGAffineTransformScale(CGAffineTransformMakeTranslation(0, -distance), 0.9, 0.9);
        self->_glass.effect = nil;
    } completion:^(BOOL finished) {
        [self removeFromSuperview];
    }];
}
@end

@interface SGAlbumQueueRow : UIControl
@property (nonatomic, copy) NSString *uri;
@property (nonatomic, weak) UIViewController *menu;
@end
@implementation SGAlbumQueueRow {
    UILabel *_title;
    UIImageView *_icon;
}
- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    _title = [UILabel new];
    _title.text = @"Add to Queue";
    _title.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    _title.adjustsFontForContentSizeCategory = YES;
    _title.textColor = UIColor.whiteColor;
    _icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"text.line.last.and.arrowtriangle.forward"]];
    _icon.tintColor = [UIColor colorWithWhite:1 alpha:0.65];
    _icon.contentMode = UIViewContentModeScaleAspectFit;
    for (UIView *v in @[_title, _icon]) { v.userInteractionEnabled = NO; [self addSubview:v]; }
    self.isAccessibilityElement = YES;
    self.accessibilityLabel = @"Add to Queue";
    self.accessibilityIdentifier = @"spotifyglass.albumQueue";
    self.accessibilityTraits = UIAccessibilityTraitButton;
    [self addTarget:self action:@selector(addAlbum) forControlEvents:UIControlEventTouchUpInside];
    return self;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat h = self.bounds.size.height, w = self.bounds.size.width;
    _icon.frame = CGRectMake(16, (h - 24) / 2, 24, 24);
    _title.frame = CGRectMake(56, 0, MAX(0, w - 72), h);
}
- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    self.backgroundColor = [UIColor colorWithWhite:1 alpha:highlighted ? 0.08 : 0];
}
- (void)addAlbum {
    self.enabled = NO;
    UIViewController *menu = self.menu;
    // The app's own window: the redesign presents the menu from a window of the mod's that drops under the app's
    // once the menu is gone, which would hide the notice.
    UIWindow *window;
    for (UIWindow *w in menu.viewIfLoaded.window.windowScene.windows) {
        if (!w.hidden && w.windowLevel == UIWindowLevelNormal) { window = w; break; }
    }
    NSString *uri = self.uri;
    [menu dismissViewControllerAnimated:YES completion:nil];
    SGAlbumQueueAdd(uri, ^(NSUInteger count, NSString *error) {
        if (error) {
            [SGAlbumQueueNotice showIn:window title:error detail:nil symbol:@"exclamationmark.circle"];
        } else {
            NSString *songs = count == 1 ? @"1 song" : [NSString stringWithFormat:@"%lu songs", (unsigned long)count];
            [SGAlbumQueueNotice showIn:window title:@"Added to Queue" detail:songs symbol:@"text.line.last.and.arrowtriangle.forward"];
        }
    });
}
@end

void SGAlbumQueueInstall(UIViewController *menu) {
    NSString *uri = objc_getAssociatedObject(menu, &kURIKey);
    if (!uri) return;
    UITableView *table = tableIn(menu.viewIfLoaded, 0);
    if (table.bounds.size.width <= 0) return;
    NSInteger rows = 0;
    for (NSInteger section = 0; section < table.numberOfSections; section++) rows += [table numberOfRowsInSection:section];
    // Wait for Spotify's rows, so its own queue row wins whenever it is present. Decided once per menu,
    // because the scan asks the data source for cells it never shows.
    if (!rows) return;
    NSNumber *native = objc_getAssociatedObject(menu, &kNativeKey);
    if (!native) {
        native = @(hasNativeQueueRow(table));
        objc_setAssociatedObject(menu, &kNativeKey, native, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (native.boolValue) return;
    SGAlbumQueueRow *row = objc_getAssociatedObject(menu, &kRowKey);
    if (table.tableFooterView && table.tableFooterView != row && table.tableFooterView.bounds.size.height > 0) return;
    if (!row) {
        row = [[SGAlbumQueueRow alloc] initWithFrame:CGRectZero];
        row.menu = menu;
        objc_setAssociatedObject(menu, &kRowKey, row, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        SGLog(@"album queue: row offered for %@", uri);
    }
    row.uri = uri;
    CGFloat height = MAX(56, [UIFont preferredFontForTextStyle:UIFontTextStyleBody].lineHeight + 24);
    CGSize size = CGSizeMake(table.bounds.size.width, height);
    // The table moves its footer to the end of the content, so only the size says whether it changed.
    if (table.tableFooterView != row || !CGSizeEqualToSize(row.bounds.size, size)) {
        // Outside the sheet's rise, or the row slides down over Spotify's rows from the table's top.
        [UIView performWithoutAnimation:^{
            row.frame = (CGRect){CGPointZero, size};
            table.tableFooterView = row;
            [table invalidateIntrinsicContentSize];
            [table layoutIfNeeded];
        }];
    }
}

%hook _TtC24ContextMenu_InternalImpl25ContextMenuViewController
- (void)viewWillAppear:(BOOL)animated {
    // Only the first appearance takes the marker; coming back from a page pushed in the sheet keeps the row.
    if (!objc_getAssociatedObject(self, &kSeenKey)) {
        objc_setAssociatedObject(self, &kSeenKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        NSString *uri = CACurrentMediaTime() - sg_markedAt <= 1.5 ? sg_pending : nil;
        sg_pending = nil;
        if (uri) {
            objc_setAssociatedObject(self, &kURIKey, uri, OBJC_ASSOCIATION_COPY_NONATOMIC);
            SGAlbumQueueInstall((UIViewController *)self);
        }
    }
    %orig;
}
- (void)viewDidLayoutSubviews {
    %orig;
    SGAlbumQueueInstall((UIViewController *)self);
}
%end
%ctor {
    if (!SGHidden(SGKeyFakePremium)) return;
    %init;
    SGRequireClasses(@[@"_TtC24ContextMenu_InternalImpl25ContextMenuViewController",
                       kPageClass,
                       @"SPTPlayerQueueWrapperImpl", @"SPTPlayerTrack"]);
}
