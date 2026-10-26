// The full screen lyrics page on glass ("Glass lyrics" on the Lyrics page): the card under the player
// reads as having grown to the screen (Native/Player/LyricsCard.x).
//
// Page (trees/lyrics.txt): a page of its own, presented over the player by a
// _UIOverFullscreenPresentationController, which is why the card's glass stops at the card's edge.
// Tome_PageTemplateImpl paints the template view #121212 and FullscreenView paints itself the
// album color on top, both opaque; clearing them lets the player's blurred artwork through.
//
// The album color is the stubborn one: it arrives per track, after the page has laid out, and it
// comes back through a path Native/Appearance/Repaint.x never sees, so a sweep at layout time loses the race.
// FullscreenView is asked not to keep it at all instead. The pane goes inside FullscreenView, in
// front of whatever that view still fills itself with, rather than behind the whole page.
//
// And under either kind of page, with glass or without, the footer's credit opens the pages it links to.
#import "Core/SGCore.h"
#import "Native/Player/NowPlaying.h"
#import "Native/Appearance/Repaint.h"
#import "Shared/LyricsSources/LyricsSources.h"
#import <objc/runtime.h>

static char kPageGlassKey;

// A class's name never changes, so its prefix test is answered once (main thread only, as the layout is).
static BOOL isTransitionClass(Class cls) {
    static NSMutableDictionary *answers;
    if (!answers) answers = [NSMutableDictionary dictionary];
    NSNumber *answer = answers[(id<NSCopying>)cls];
    if (!answer) answers[(id<NSCopying>)cls] = answer = @([NSStringFromClass(cls) hasPrefix:@"UITransition"]);
    return answer.boolValue;
}

// Up to the presentation: the template views in between paint themselves opaque once, at setup.
// Only the chain is cleared, not the subtree -- nothing else on the page is painted.
static UIView *clearAncestors(UIView *view) {
    UIView *top = view;
    for (UIView *v = view; v && ![v isKindOfClass:UIWindow.class] && !isTransitionClass(v.class); v = v.superview) {
        v.layer.backgroundColor = NULL;
        top = v;
    }
    return top;
}

%hook _TtC32Lyrics_FullscreenElementPageImpl14FullscreenView
// A color kept here is re-applied whenever UIKit feels like it, so it is refused outright.
- (void)setBackgroundColor:(UIColor *)color {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ SGLog(@"lyrics page paints itself %@ through UIView", color); });
    %orig(SGFlag(SGKeyLyricsCard, NO) ? nil : color);
}

- (void)layoutSubviews {
    %orig;
    if (!SGFlag(SGKeyLyricsCard, NO)) return;
    UIView *page = (UIView *)self;
    if (page.bounds.size.height < 200) return;

    page.layer.backgroundColor = NULL;
    sg_lyricsPageRoot = clearAncestors(page);

    UIVisualEffectView *glass = SGGlassFor(page, &kPageGlassKey);
    // Dark whatever the system is set to, as the player's header panes are (Native/Player/Player.x):
    // light glass under white lyrics otherwise, on a phone in light mode.
    if (glass.overrideUserInterfaceStyle != UIUserInterfaceStyleDark) glass.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    glass.frame = page.bounds;
    glass.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    // Full bleed, so the shape is spelled out: a fresh pane does not promise square corners.
    SGShapeGlass(glass, 0, NO);
}
%end

#pragma mark - the credit

// The footer under the page's lines ("Lyrics provided by ..."), which names the source of the page's text
// (Shared/LyricsSources/LyricsHook.x). A credit that links to the people who made the lines (SpicyLyrics.m)
// opens their pages from a tap on it; any other footer's tap never begins, and passes on to Spotify.
static NSString *footerText(UIView *view) {
    if ([view isKindOfClass:UILabel.class] && ((UILabel *)view).text.length) return ((UILabel *)view).text;
    for (UIView *child in view.subviews) {
        NSString *text = footerText(child);
        if (text) return text;
    }
    return nil;
}

@interface SGFooterCreditTap : UITapGestureRecognizer <UIGestureRecognizerDelegate>
@end

@implementation SGFooterCreditTap

- (instancetype)init {
    if (!(self = [super initWithTarget:nil action:NULL])) return nil;
    [self addTarget:self action:@selector(open)];
    self.delegate = self;
    return self;
}

- (NSArray<SGLyricsLink *> *)links {
    NSString *text = footerText(self.view) ?: self.view.accessibilityLabel;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ SGLog(@"lyrics page: its footer reads \"%@\"", text); });
    return SGLyricsCreditLinks(text);
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)recognizer {
    return [self links].count > 0;
}

- (void)open {
    SGLyricsOpenCreditLinks([self links], self.view);
}

@end

static char kCreditTapKey;

static void tapForCredit(UIView *footer) {
    if (!footer.window || objc_getAssociatedObject(footer, &kCreditTapKey)) return;
    SGFooterCreditTap *tap = [SGFooterCreditTap new];
    [footer addGestureRecognizer:tap];
    footer.userInteractionEnabled = YES;
    objc_setAssociatedObject(footer, &kCreditTapKey, tap, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// The footer as the lyrics page draws it, under the card's text, and under the sing-along page's.
%hook _TtC22Lyrics_TextElementImpl16LyricsFooterView
- (void)didMoveToWindow {
    %orig;
    tapForCredit((UIView *)self);
}
%end

%hook _TtC24Lyrics_TextComponentImpl16LyricsFooterView
- (void)didMoveToWindow {
    %orig;
    tapForCredit((UIView *)self);
}
%end

%hook _TtC31Lyrics_TextElementSingalongImpl16LyricsFooterView
- (void)didMoveToWindow {
    %orig;
    tapForCredit((UIView *)self);
}
%end

%ctor {
    if (!SGNativeUI()) return;
    %init;
    SGRequireClasses(@[@"_TtC32Lyrics_FullscreenElementPageImpl14FullscreenView", @"_TtC22Lyrics_TextElementImpl16LyricsFooterView",
                       @"_TtC24Lyrics_TextComponentImpl16LyricsFooterView"]);
}
