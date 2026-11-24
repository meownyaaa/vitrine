#import "Core/SGCore.h"
#import "Settings/SGPageStyle.h"
#import "MeaningSheet.h"
#import "Redesigned/Kit/SGRTokens.h"
#import "Core/SGGlass.h"
#import "Redesigned/Kit/SGRGlass.h"

static const CGFloat kSide = 24, kTop = 28, kGap = 12;
// The footer's row is drawn 22pt tall; its buttons take touches over 44, centered on it.
static const CGFloat kRow = 22, kTouch = 44;
static char kMeaningGlassKey;

static NSString *authorName(SGLyricsMeaningAuthor author) {
    switch (author) {
        case SGLyricsMeaningByArtist: return @"From the artist";
        case SGLyricsMeaningByEditors: return @"Genius editors";
        case SGLyricsMeaningByCommunity: return @"Genius community";
    }
    return nil;
}

static NSString *authorSymbol(SGLyricsMeaningAuthor author) {
    return author == SGLyricsMeaningByArtist ? @"checkmark.seal.fill" : author == SGLyricsMeaningByEditors ? @"checkmark.circle" : @"person.2";
}

// The annotation's text with each web address in it made a link. Only http and https ones are, so an
// address-like bit of text never opens anything else.
static NSAttributedString *linkedBody(NSString *body) {
    NSDictionary *attributes = @{NSFontAttributeName: [UIFont preferredFontForTextStyle:UIFontTextStyleBody],
                                 NSForegroundColorAttributeName: SGRPrimary()};
    NSMutableAttributedString *out = [[NSMutableAttributedString alloc] initWithString:body ?: @"" attributes:attributes];
    static NSDataDetector *detector;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ detector = [NSDataDetector dataDetectorWithTypes:NSTextCheckingTypeLink error:nil]; });
    for (NSTextCheckingResult *match in [detector matchesInString:out.string options:0 range:NSMakeRange(0, out.length)]) {
        NSString *scheme = match.URL.scheme.lowercaseString;
        if ([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"])
            [out addAttribute:NSLinkAttributeName value:match.URL range:match.range];
    }
    return out;
}

@interface SGRMeaningSheet : UIViewController
@end

@implementation SGRMeaningSheet {
    NSString *_lineText;
    NSArray<SGLyricsMeaning *> *_meanings;
    NSUInteger _index;
    UIScrollView *_scroll;
    UILabel *_quote, *_count;
    UITextView *_body;
    UIButton *_author, *_next, *_open;
}

- (instancetype)initWithLine:(NSString *)lineText meanings:(NSArray<SGLyricsMeaning *> *)meanings {
    self = [super initWithNibName:nil bundle:nil];
    if (!self) return nil;
    _lineText = [lineText copy];
    _meanings = [meanings copy];
    self.modalPresentationStyle = UIModalPresentationPageSheet;
    SGPresentDark(self);
    UISheetPresentationController *sheet = self.sheetPresentationController;
    sheet.detents = @[UISheetPresentationControllerDetent.mediumDetent, UISheetPresentationControllerDetent.largeDetent];
    sheet.prefersGrabberVisible = YES;
    if (SGBelowiOS26()) sheet.preferredCornerRadius = SGRSheetCornerRadius();
    sheet.prefersScrollingExpandsWhenScrolledToEdge = YES;
    // On the landscape lyrics (compact height) the sheet would otherwise cover the whole screen with no
    // grabber and nothing to pull down; edge attached it is a card on the bottom edge, inside the safe area.
    sheet.prefersEdgeAttachedInCompactHeight = YES;
    return self;
}

- (UILabel *)labelWithFont:(UIFont *)font color:(UIColor *)color {
    UILabel *label = [UILabel new];
    label.numberOfLines = 0;
    label.font = font;
    label.textColor = color;
    label.adjustsFontForContentSizeCategory = YES;
    [_scroll addSubview:label];
    return label;
}

- (UIButton *)buttonWithTitle:(NSString *)title action:(SEL)action {
    UIButtonConfiguration *config = [UIButtonConfiguration plainButtonConfiguration];
    config.title = title;
    config.contentInsets = NSDirectionalEdgeInsetsZero;
    config.baseForegroundColor = SGRAccent();
    config.titleTextAttributesTransformer = ^NSDictionary *(NSDictionary *attributes) {
        NSMutableDictionary *out = [attributes mutableCopy];
        out[NSFontAttributeName] = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
        return out;
    };
    UIButton *button = [UIButton buttonWithConfiguration:config primaryAction:nil];
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [_scroll addSubview:button];
    return button;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    // From iOS 26 a sheet short of full height is Liquid Glass, which the system draws and turns opaque
    // itself at the large detent and under Reduce Transparency; a fill here would cover it. Below 26 the
    // sheet gets legacy glass.
    if (@available(iOS 26.0, *)) {
    } else {
        self.view.backgroundColor = UIColor.clearColor;
        UIView *glass = SGGlassFor(self.view, &kMeaningGlassKey);
        glass.frame = self.view.bounds;
        glass.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        SGShapeGlass(glass, SGRSheetCornerRadius(), NO);
        SGRThickenSheetGlass(glass, SGRSheetCornerRadius());
    }
    _scroll = [[UIScrollView alloc] initWithFrame:self.view.bounds];
    _scroll.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _scroll.alwaysBounceVertical = YES;
    [self.view addSubview:_scroll];

    _quote = [self labelWithFont:[UIFont systemFontOfSize:20 weight:UIFontWeightBold] color:SGRPrimary()];
    UIButtonConfiguration *badge = [UIButtonConfiguration filledButtonConfiguration];
    badge.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    badge.buttonSize = UIButtonConfigurationSizeMini;
    badge.imagePadding = 4;
    badge.contentInsets = NSDirectionalEdgeInsetsMake(4, 10, 4, 10);
    badge.baseBackgroundColor = [SGRAccent() colorWithAlphaComponent:0.2];
    badge.baseForegroundColor = SGRAccent();
    _author = [UIButton buttonWithConfiguration:badge primaryAction:nil];
    _author.userInteractionEnabled = NO;
    [_scroll addSubview:_author];
    // A text view rather than a label so the links in an annotation (Genius's text carries bare URLs) can be
    // tapped. It never scrolls or edits; the sheet's scroll view does the scrolling.
    _body = [UITextView new];
    _body.editable = NO;
    _body.selectable = YES;
    _body.scrollEnabled = NO;
    _body.backgroundColor = UIColor.clearColor;
    _body.textContainerInset = UIEdgeInsetsZero;
    _body.textContainer.lineFragmentPadding = 0;
    _body.adjustsFontForContentSizeCategory = YES;
    _body.linkTextAttributes = @{NSForegroundColorAttributeName: SGRAccent(),
                                 NSUnderlineStyleAttributeName: @(NSUnderlineStyleSingle)};
    [_scroll addSubview:_body];
    _count = [self labelWithFont:[UIFont systemFontOfSize:13 weight:UIFontWeightRegular] color:SGRTertiary()];
    _count.numberOfLines = 1;
    _next = [self buttonWithTitle:@"Next" action:@selector(showNext)];
    _open = [self buttonWithTitle:@"View on Genius" action:@selector(openGenius)];
    [self show];
}

- (void)show {
    SGLyricsMeaning *meaning = _meanings[_index];
    _quote.text = [NSString stringWithFormat:@"“%@”", _lineText];
    UIButtonConfiguration *badge = _author.configuration;
    badge.title = authorName(meaning.author);
    badge.image = [UIImage systemImageNamed:authorSymbol(meaning.author)
                          withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:11 weight:UIImageSymbolWeightSemibold]];
    _author.configuration = badge;
    _body.attributedText = linkedBody(meaning.body);
    _count.text = _meanings.count > 1 ? [NSString stringWithFormat:@"Genius · %lu of %lu", (unsigned long)_index + 1, (unsigned long)_meanings.count]
                                      : @"Genius";
    _next.hidden = _meanings.count < 2;
    _open.hidden = !meaning.url.length;
    [self.view setNeedsLayout];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    // A sheet as wide as a landscape screen reaches under the sensor housing, which the safe area keeps clear.
    UIEdgeInsets safe = self.view.safeAreaInsets;
    CGFloat left = kSide + safe.left, width = self.view.bounds.size.width - left - kSide - safe.right;
    CGFloat y = kTop;
    _quote.frame = CGRectMake(left, y, width, [_quote sizeThatFits:CGSizeMake(width, CGFLOAT_MAX)].height);
    y = CGRectGetMaxY(_quote.frame) + kGap;
    CGSize badge = [_author sizeThatFits:CGSizeMake(width, CGFLOAT_MAX)];
    _author.frame = CGRectMake(left, y, MIN(width, badge.width), badge.height);
    y = CGRectGetMaxY(_author.frame) + kGap + 4;
    _body.frame = CGRectMake(left, y, width, [_body sizeThatFits:CGSizeMake(width, CGFLOAT_MAX)].height);
    y = CGRectGetMaxY(_body.frame) + kGap * 2;
    _count.frame = CGRectMake(left, y, [_count sizeThatFits:CGSizeMake(width, kRow)].width, kRow);
    CGFloat right = left + width, touchTop = y - (kTouch - kRow) / 2;
    if (!_next.hidden) {
        CGFloat side = MAX(kTouch, [_next sizeThatFits:CGSizeZero].width);
        _next.frame = CGRectMake(right - side, touchTop, side, kTouch);
        right = CGRectGetMinX(_next.frame) - 20;
    }
    if (!_open.hidden) {
        CGFloat side = MAX(kTouch, [_open sizeThatFits:CGSizeZero].width);
        _open.frame = CGRectMake(right - side, touchTop, side, kTouch);
    }
    _scroll.contentSize = CGSizeMake(self.view.bounds.size.width, touchTop + kTouch + kTop + self.view.safeAreaInsets.bottom);
}

- (void)showNext {
    _index = (_index + 1) % _meanings.count;
    [UIView transitionWithView:_scroll duration:0.2 options:UIViewAnimationOptionTransitionCrossDissolve
                    animations:^{ [self show]; [self.view layoutIfNeeded]; } completion:nil];
    [_scroll setContentOffset:CGPointMake(0, -_scroll.adjustedContentInset.top) animated:NO];
}

- (void)openGenius {
    NSURL *url = [NSURL URLWithString:_meanings[_index].url];
    if (url) [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
}

@end

void SGRShowMeanings(NSString *lineText, NSArray<SGLyricsMeaning *> *meanings) {
    if (!meanings.count) return;
    UIViewController *top = SGTopController();
    if (!top || [top isKindOfClass:SGRMeaningSheet.class]) return;
    [top presentViewController:[[SGRMeaningSheet alloc] initWithLine:lineText meanings:meanings] animated:YES completion:nil];
}
