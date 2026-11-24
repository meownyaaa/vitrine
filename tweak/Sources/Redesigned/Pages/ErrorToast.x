// Redesign, iOS < 26: the page loader's error toast, "Something went wrong / Have another go?" with its Reload button,
// on glass like Spotify's other toasts (Kit/SGRSnackbar.x), Reload itself as Spotify made it.
//
// Tree: not an SPTSnackbarView. Tome_MusicClientPageLoaderViewKit.DefaultErrorToastView, id=default-error-toast-view,
// 358x128 at the foot of a page that failed to load, #FFFFFF r=8 clips, holding two Encore labels in black 16pt and 13pt
// and an Encore.Button.Primary "Reload" (74x32, its word 13pt black). The snackbar's hooks never met it, so it stayed a
// flat white card in the middle of the glass look.
//
// It is dressed the way the snackbar's card is: the white goes, a glass pane and the faint film that keeps a floating card
// from sinking into the page stand behind the content, the corners are rounder (kRadius), and the black text turns white.
// Reload is left as Spotify draws it, its green and its black word: a glass capsule round it showed as a white rim either
// side of the green, so the button takes none and nothing of its own is touched. The cross at the top-left of
// the page (a Tertiary button beside the toast, 24x48) gets the round glass every top bar button has (Kit/SGRGlass.h), the
// way the cover art page's does.
// Threading: main thread only.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"

static char kGlassKey, kFilmKey, kCloseGlassKey;

static const CGFloat kRadius = 24;

// The Reload button: Spotify's Primary button, found by its identifier. Only found, to keep its word as it is.
static UIView *reloadIn(UIView *toast) {
    __block UIView *found = nil;
    SGForEachView(toast, ^(UIView *view) {
        if (!found && [view.accessibilityIdentifier isEqualToString:@"Encore.Button.Primary"]) found = view;
    });
    return found;
}

// The cross: the Tertiary button at the top-left of the page the toast stands on, as on the cover art page.
static void glassClose(UIView *page) {
    for (UIView *sub in page.subviews) {
        if (![NSStringFromClass(sub.class) hasSuffix:@"Button8Tertiary"]) continue;
        if (CGRectGetMinY(sub.frame) > 120 || CGRectGetMinX(sub.frame) > 120 || sub.bounds.size.width > 80) continue;
        SGRGlassInside(sub, &kCloseGlassKey, SGRGlassCircleSize);
        if (sub.clipsToBounds) sub.clipsToBounds = NO;
    }
}

static void dressToast(UIView *toast) {
    CGSize size = toast.bounds.size;
    if (!toast.window || size.width < 1 || size.height < 1) return;

    SGRGlassFloatingCard(toast, &kGlassKey, &kFilmKey, kRadius);

    SGRLightenLabels(toast, reloadIn(toast));
    if (toast.superview) glassClose(toast.superview);

    static dispatch_once_t once;
    dispatch_once(&once, ^{ SGLog(@"error toast: glass over a card of %@", NSStringFromCGRect(toast.bounds)); });
}

%group SGRErrorToast
%hook SGRErrorToastView
- (void)layoutSubviews {
    %orig;
    dressToast((UIView *)self);
}

- (void)didMoveToWindow {
    %orig;
    UIView *toast = (UIView *)self;
    if (!toast.window) return;
    dressToast(toast);
    // Spotify paints the white and the button back as the toast's content is set.
    SGRRepeatViewPass(toast, @[@0.0, @0.25], ^(UIView *v) { dressToast(v); });
}
%end
%end

%ctor {
    if (!SGRedesignedUI()) return;
    if (!SGBelowiOS26()) return;
    Class toast = SGRSwiftClass(@"Tome_MusicClientPageLoaderViewKit", @"DefaultErrorToastView");
    if (toast) {
        %init(SGRErrorToast, SGRErrorToastView = toast);
    } else {
        SGLog(@"class Tome_MusicClientPageLoaderViewKit.DefaultErrorToastView not found, the page loader's error toast keeps Spotify's card");
    }
}
