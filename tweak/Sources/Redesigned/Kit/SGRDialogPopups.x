// Redesign, iOS < 26: Spotify's own white pop-up dialogs, shown as the system's notification: a UIAlertController, which
// SGRAlertHook.x draws as the redesign's alert below iOS 26 (SGRAlertScreen.m: a glass card with 35pt corners, white
// text, a capsule button filled with the accent for the main action and one of 10% white for the rest) and the system
// draws as its own glass alert from iOS 26 on.
//
//   Get smoother transitions     id=PopUp.Dialog, white r=8
//   Discard changes?             id=PopUp.Dialog
//   Make this playlist private?  id=PopUp.Dialog
//   Update preferred location    id=PopUpConfirmationDialog, a grey r=16 card with
//                                the Cancel button under it, in a window of its own
//   Want this playlist to        id=PlaylistsProfileVisibility.MakePublicDialog, an
//   appear on your profile?      Encore Dialog, white r=8, with Encore.Button.Primary
//                                and Encore.Button.Tertiary instead of Components.UI's
//
// Each lives in a UIWindow of level 1000 over a 54% black dim, and is not a UIAlertController, so SGRAlertHook.x never
// sees it. Repainting Spotify's views would show the white dialog for a moment and then redraw it, because Spotify
// lays the dialog out and fills it in after it is attached. So nothing of Spotify's is repainted:
//
//  1. The moment a dialog's view comes into its window, the window is made invisible (alpha 0, and hidden from
//     VoiceOver), in the same turn of the run loop, before the first frame is drawn.
//  2. Its title, text and buttons are read once Spotify has filled them in: every 40 ms until two reads in a row
//     agree. The main button is Components.UI.PrimaryButton (Encore.Button.Primary in the Encore Dialog), the others Components.UI.TertiaryButton (Encore.Button.Tertiary).
//  3. A UIAlertController is built from them and presented over the app's own window. Each action fires Spotify's own
//     button (SGRActivate), so the handler Spotify attached to it runs exactly as for a tap, and Spotify takes its own
//     window down. A tap outside the alert is its Cancel, as for any alert.
//  4. If the alert cannot be shown (no window of the app to show it in, or the dialog never fills in), the window is
//     made visible again and the dialog is repainted as it was before (dressDialog): a dialog that cannot be
//     replaced is still a dialog.
//
// The window is made visible again a second after the dialog is gone, so a window Spotify keeps and uses for the next
// dialog is not left invisible. If Spotify takes the dialog down itself while the alert is up, the alert goes too.
//
// The dialog is found from its window, not from a hook on every view: a window above the app's (a plain UIWindow or one
// of Spotify's, never UIKit's own keyboard and text effect windows) is looked through as it is shown, laid out or given a
// view, and a moment after it is shown, as Spotify fills it in; its taking down is seen as the window is hidden or no
// longer holds the dialog. On iOS 26 none of this runs, and Spotify's dialogs are its own, as on main.
//
// Create cover art > Cancel > "Are you sure" is a web page, not a view of Spotify's: nothing to replace.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Settings/SGPageStyle.h"

static const CGFloat kDialogRadius = 35;

static char kGlassKey, kFillKey;

// The main button of a dialog: Components.UI's in the PopUp dialogs, Encore's in the Encore Dialog.
static BOOL isPrimary(UIView *view) {
    NSString *ident = view.accessibilityIdentifier;
    return [ident isEqualToString:@"Components.UI.PrimaryButton"] || [ident isEqualToString:@"Encore.Button.Primary"];
}

static BOOL isButton(UIView *view) {
    NSString *ident = view.accessibilityIdentifier;
    return isPrimary(view) || [ident isEqualToString:@"Components.UI.TertiaryButton"] || [ident isEqualToString:@"Encore.Button.Tertiary"];
}

static BOOL insideButton(UIView *view, UIView *root) {
    for (UIView *v = view; v && v != root; v = v.superview) {
        if (isButton(v)) return YES;
    }
    return NO;
}

static void dressButton(UIView *button) {
    CGSize size = button.bounds.size;
    if (size.width < 1 || size.height < 1) return;
    BOOL primary = isPrimary(button);
    UIView *fill = objc_getAssociatedObject(button, &kFillKey);
    if (!fill) {
        fill = [UIView new];
        fill.userInteractionEnabled = NO;
        fill.layer.cornerCurve = kCACornerCurveContinuous;
        objc_setAssociatedObject(button, &kFillKey, fill, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [button insertSubview:fill atIndex:0];
    }
    if (button.subviews.firstObject != fill) [button sendSubviewToBack:fill];
    fill.frame = button.bounds;
    fill.layer.cornerRadius = size.height / 2;
    UIColor *accent = SGRAccent();
    fill.backgroundColor = primary ? accent : [UIColor colorWithWhite:1 alpha:0.1];
    UIColor *text = primary ? SGRInkOnAccent(accent) : UIColor.whiteColor;
    SGForEachView(button, ^(UIView *view) {
        if ([view isKindOfClass:UILabel.class] && ((UILabel *)view).textColor != text) ((UILabel *)view).textColor = text;
    });
}

// Spotify's paint (the white card, the grey one, an image's placeholder) goes; the glass and the buttons' fills stay.
static void clearPaint(UIView *view, UIView *glass, int depth) {
    if (depth > 12 || view == glass || isButton(view)) return;
    CGColorRef paint = view.layer.backgroundColor;
    if (paint && CGColorGetAlpha(paint) > 0.05) view.backgroundColor = UIColor.clearColor;
    if (view.layer.cornerRadius > 0 && depth > 0) view.layer.cornerRadius = 0;
    for (UIView *sub in view.subviews) clearPaint(sub, glass, depth + 1);
}

// Update preferred location: the dialog's stack holds the card's content (the text and Confirm, 24pt of air under
// Confirm) and then Cancel after 16pt more, flush with the bottom edge of the dialog (Confirm ends at 258.7, Cancel
// runs 298.7 to 346.7 in a 346.7 card). Cancel moves up to kCancelGap under Confirm, and the room that frees goes
// under it as the stack's bottom margin, so the card keeps its height and Cancel keeps its air. The spacing and the
// margin are properties of the stack, so Spotify's own layout keeps them.
static const CGFloat kCancelGap = 12, kCancelBottom = 28;
static char kCancelUnderKey;

static void spaceCancel(UIView *host) {
    UIStackView *stack = nil;
    for (UIView *view in host.subviews) {
        if ([view isKindOfClass:UIStackView.class] && [view.accessibilityIdentifier isEqualToString:@"PopUpConfirmationDialog"]) stack = (UIStackView *)view;
    }
    if (!stack || stack.arrangedSubviews.count != 2) return;
    UIView *card = stack.arrangedSubviews.firstObject, *cancel = stack.arrangedSubviews.lastObject;
    if (![cancel.accessibilityIdentifier isEqualToString:@"Components.UI.TertiaryButton"]) return;
    // The air under Confirm in the card, read once: it is what the stack's spacing is measured against, and reading it
    // again after the spacing has changed the card's height would chase its own tail.
    NSNumber *under = objc_getAssociatedObject(stack, &kCancelUnderKey);
    if (!under) {
        UIView *confirm = nil;
        for (UIView *sub in card.subviews) {
            if ([sub.accessibilityIdentifier isEqualToString:@"Components.UI.PrimaryButton"]) confirm = sub;
        }
        if (!confirm || card.bounds.size.height < 1 || confirm.bounds.size.height < 1) return;
        under = @(MAX(0, card.bounds.size.height - CGRectGetMaxY(confirm.frame)));
        objc_setAssociatedObject(stack, &kCancelUnderKey, under, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    CGFloat custom = kCancelGap - under.doubleValue;
    if (fabs([stack customSpacingAfterView:card] - custom) > 0.5) [stack setCustomSpacing:custom afterView:card];
    // Written whole: a stack's margins are 8pt on every side by default, and they apply once the arrangement follows them.
    UIEdgeInsets margins = UIEdgeInsetsMake(0, 0, kCancelBottom, 0);
    if (stack.insetsLayoutMarginsFromSafeArea) stack.insetsLayoutMarginsFromSafeArea = NO;
    if (!UIEdgeInsetsEqualToEdgeInsets(stack.layoutMargins, margins)) stack.layoutMargins = margins;
    if (!stack.layoutMarginsRelativeArrangement) stack.layoutMarginsRelativeArrangement = YES;
}

static void dressDialog(UIView *host) {
    if (host.bounds.size.width < 1 || host.bounds.size.height < 1) return;
    UIView *glass = SGRGlassPaneIn(host, &kGlassKey, kDialogRadius);
    if (!SGRReduceTransparency()) SGRDimSheetGlass(glass, 0.45);

    clearPaint(host, glass, 0);
    spaceCancel(host);
    host.layer.cornerRadius = kDialogRadius;
    host.layer.cornerCurve = kCACornerCurveContinuous;
    BOOL clip = !SGUseLegacyGlass();
    if (host.layer.masksToBounds != clip) host.layer.masksToBounds = clip;

    SGForEachView(host, ^(UIView *view) {
        if (isButton(view)) {
            dressButton(view);
            return;
        }
        if (![view isKindOfClass:UILabel.class] || insideButton(view, host) || SGIsInside(view, glass)) return;
        UILabel *label = (UILabel *)view;
        UIColor *color = label.font.pointSize >= 17 ? UIColor.whiteColor : [UIColor colorWithWhite:1 alpha:0.7];
        label.textColor = color;
    });
}

#pragma mark - the notification

static char kTakeKey;

// How often a dialog that is not filled in yet is read again, how many times before it is given up and shown as
// Spotify's own (1 s), and how long after it is gone its window stays invisible before it is made visible again.
static const NSTimeInterval kPollInterval = 0.04, kRestoreDelay = 1.0;
static const NSUInteger kMaxPolls = 25;

// A dialog's window taken over: kept on the window itself, so one dialog is taken once however many of its views
// come into the window.
@interface SGRDialogTake : NSObject
@property (nonatomic, weak) UIWindow *window;
@property (nonatomic, weak) UIViewController *presenter;
@property (nonatomic, copy) NSString *signature;
@property (nonatomic) NSUInteger polls;
@property (nonatomic) BOOL presented, done;
@end

@implementation SGRDialogTake
@end

static BOOL visibleUnder(UIView *view, UIView *root) {
    for (UIView *v = view; v && v != root; v = v.superview) {
        if (v.hidden || v.alpha < 0.01) return NO;
    }
    return YES;
}

static NSString *trimmed(NSString *text) {
    return [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"";
}

static NSString *titleOfButton(UIView *button) {
    __block NSString *title = nil;
    SGForEachView(button, ^(UIView *v) {
        if (!title.length && [v isKindOfClass:UILabel.class]) title = trimmed(((UILabel *)v).text);
    });
    return title.length ? title : trimmed(button.accessibilityLabel);
}

static BOOL before(UIView *a, UIView *b, UIView *root) {
    CGPoint pa = [a convertPoint:CGPointZero toView:root], pb = [b convertPoint:CGPointZero toView:root];
    return fabs(pa.y - pb.y) > 1 ? pa.y < pb.y : pa.x < pb.x;
}

// What the dialog says, read off its views: @"title", @"message", @"buttons" (dictionaries of @"title" and @"view",
// in reading order) and @"signature", which is empty until the dialog is filled in: a title and at least one button,
// every button with its label.
static NSDictionary *readDialog(UIWindow *window) {
    NSMutableArray<UILabel *> *labels = [NSMutableArray array];
    NSMutableArray<UIView *> *buttons = [NSMutableArray array];
    SGForEachView(window, ^(UIView *v) {
        if (v == window || !visibleUnder(v, window)) return;
        if (isButton(v)) {
            if (!insideButton(v.superview, window)) [buttons addObject:v];
        } else if ([v isKindOfClass:UILabel.class] && trimmed(((UILabel *)v).text).length && !insideButton(v, window)) {
            [labels addObject:(UILabel *)v];
        }
    });
    [labels sortUsingComparator:^NSComparisonResult(UILabel *a, UILabel *b) {
        return before(a, b, window) ? NSOrderedAscending : NSOrderedDescending;
    }];
    [buttons sortUsingComparator:^NSComparisonResult(UIView *a, UIView *b) {
        return before(a, b, window) ? NSOrderedAscending : NSOrderedDescending;
    }];

    NSString *title = labels.count ? trimmed(labels.firstObject.text) : @"";
    NSMutableArray<NSString *> *rest = [NSMutableArray array];
    for (NSUInteger i = 1; i < labels.count; i++) [rest addObject:trimmed(labels[i].text)];
    NSString *message = [rest componentsJoinedByString:@"\n"];

    NSMutableArray<NSDictionary *> *found = [NSMutableArray array];
    BOOL filled = title.length && buttons.count;
    for (UIView *button in buttons) {
        NSString *name = titleOfButton(button);
        if (!name.length) filled = NO;
        else [found addObject:@{@"title": name, @"view": button}];
    }
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (NSDictionary *b in found) [names addObject:b[@"title"]];
    NSString *signature = filled ? [NSString stringWithFormat:@"%@|%@|%@", title, message, [names componentsJoinedByString:@"/"]] : @"";
    return @{@"title": title, @"message": message, @"buttons": found, @"signature": signature};
}

// The top controller of the app's own window: the notification is shown there, under the invisible window of Spotify's.
static UIViewController *appPresenter(UIWindow *except) {
    UIWindow *best = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window == except || window.hidden || window.windowLevel != UIWindowLevelNormal || !window.rootViewController) continue;
            if (!best || window.isKeyWindow) best = window;
        }
    }
    UIViewController *top = best.rootViewController;
    while (top.presentedViewController) top = top.presentedViewController;
    return top;
}

// The window shown again and let go.
static void showWindow(UIWindow *window) {
    window.alpha = 1;
    window.accessibilityElementsHidden = NO;
    objc_setAssociatedObject(window, &kTakeKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static UIView *dialogIn(UIWindow *window);

// How many times, kRestoreDelay apart, a window whose dialog is still in it is looked at again before it is let go.
static const NSUInteger kRestoreTries = 10;

// Makes the window visible again once Spotify has taken its dialog out, unless another dialog has taken it since. While
// the dialog is in, the window stays unseen (and, at alpha 0, takes no touches): shown again, Spotify's white dialog or
// its dim came back over the app when the button fired and Spotify left the dialog up.
static void restoreAfter(SGRDialogTake *take, NSUInteger tries) {
    __weak UIWindow *weak = take.window;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kRestoreDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIWindow *window = weak;
        if (!window || objc_getAssociatedObject(window, &kTakeKey) != take) return;
        if (window.hidden || !dialogIn(window)) {
            showWindow(window);
        } else if (tries + 1 < kRestoreTries) {
            restoreAfter(take, tries + 1);
        } else {
            SGLog(@"redesign dialogs: Spotify left its dialog up, its window kept unseen");
            objc_setAssociatedObject(window, &kTakeKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    });
}

static void restoreLater(SGRDialogTake *take) {
    if (take.done) return;
    take.done = YES;
    restoreAfter(take, 0);
}

static BOOL presentNotification(SGRDialogTake *take, NSDictionary *read) {
    UIViewController *presenter = appPresenter(take.window);
    if (!presenter || presenter.isBeingDismissed || presenter.isBeingPresented) return NO;

    NSString *message = read[@"message"];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:read[@"title"] message:message.length ? message : nil
                                                            preferredStyle:UIAlertControllerStyleAlert];
    alert.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    BOOL haveCancel = NO;
    UIAlertAction *main = nil;
    for (NSDictionary *entry in read[@"buttons"]) {
        UIView *button = entry[@"view"];
        BOOL primary = isPrimary(button);
        // One Cancel at most, and only among the quiet buttons: an alert refuses two.
        UIAlertActionStyle style = UIAlertActionStyleDefault;
        if (!primary && !haveCancel) {
            style = UIAlertActionStyleCancel;
            haveCancel = YES;
        }
        __weak UIView *weakButton = button;
        UIAlertAction *action = [UIAlertAction actionWithTitle:entry[@"title"] style:style handler:^(UIAlertAction *picked) {
            // Spotify's own button, so what Spotify attached to it runs and Spotify takes its own window down.
            UIView *spotify = weakButton;
            if (spotify.window) SGRActivate(spotify);
            restoreLater(take);
        }];
        if (primary && !main) main = action;
        [alert addAction:action];
    }
    if (main) alert.preferredAction = main;

    SGPresentDark(alert);
    [presenter presentViewController:alert animated:YES completion:nil];
    take.presenter = presenter;
    take.presented = YES;
    return YES;
}

static void dressWindow(UIWindow *window);

// The dialog could not be replaced: Spotify's own is shown, dressed the way it was before.
static void giveUp(SGRDialogTake *take) {
    UIWindow *window = take.window;
    take.done = YES;
    if (!window) return;
    showWindow(window);
    SGLog(@"redesign dialogs: a pop-up could not be shown as a notification, left as Spotify's");
    dressWindow(window);
}

static void poll(SGRDialogTake *take) {
    UIWindow *window = take.window;
    if (!window || take.done || take.presented) return;
    take.polls++;
    NSDictionary *read = readDialog(window);
    NSString *signature = read[@"signature"];
    // Two reads in a row that agree: Spotify fills a dialog in over a few passes, and a title read half way is not the title.
    BOOL steady = signature.length && [signature isEqualToString:take.signature];
    take.signature = signature;
    if (steady && presentNotification(take, read)) {
        static BOOL logged;
        if (!logged) {
            logged = YES;
            SGLog(@"redesign dialogs: \"%@\" shown as a notification after %lu reads", read[@"title"], (unsigned long)take.polls);
        }
        return;
    }
    if (take.polls >= kMaxPolls) {
        giveUp(take);
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kPollInterval * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ poll(take); });
}

// A dialog's view came into its window: the window goes dark before a frame is drawn and the dialog is read.
// NO for a dialog that is not in a window of its own: the app's main window is never made invisible, and such a
// dialog is dressed as Spotify's own instead.
static BOOL takeOver(UIWindow *window) {
    SGRDialogTake *current = objc_getAssociatedObject(window, &kTakeKey);
    if (current && !current.done) return YES;
    if (window.windowLevel <= UIWindowLevelNormal) return NO;
    SGRDialogTake *take = [SGRDialogTake new];
    take.window = window;
    objc_setAssociatedObject(window, &kTakeKey, take, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    window.alpha = 0;
    window.accessibilityElementsHidden = YES;
    dispatch_async(dispatch_get_main_queue(), ^{ poll(take); });
    return YES;
}

// Spotify took the dialog down: the notification, if it is still up, goes with it.
static void abandon(UIWindow *window) {
    SGRDialogTake *take = objc_getAssociatedObject(window, &kTakeKey);
    if (!take || take.done) return;
    UIViewController *shown = take.presenter.presentedViewController;
    if (take.presented && shown && SGIsAlertController(shown) && !shown.isBeingDismissed) [shown dismissViewControllerAnimated:YES completion:nil];
    restoreLater(take);
}

#pragma mark - the fallback: Spotify's own dialog, dressed

// The view that carries the card: the white ScrollView itself, or for the location dialog the element view that holds the card and Cancel.
static UIView *hostOf(UIView *view) {
    NSString *ident = view.accessibilityIdentifier;
    if ([ident isEqualToString:@"PopUp.Dialog"] || [ident isEqualToString:@"PlaylistsProfileVisibility.MakePublicDialog"]) return view;
    if ([ident isEqualToString:@"PopUpConfirmationDialog"]) {
        UIView *parent = view.superview;
        return parent && CGSizeEqualToSize(parent.bounds.size, view.bounds.size) ? parent : view;
    }
    return nil;
}

// The dialog dressed, now and as Spotify lays it out after it is attached.
static void dressLater(UIView *host) {
    SGRRepeatViewPass(host, @[@0.0, @0.1, @0.3], ^(UIView *v) { dressDialog(v); });
}

static void dressWindow(UIWindow *window) {
    NSMutableSet<UIView *> *hosts = [NSMutableSet set];
    SGForEachView(window, ^(UIView *view) {
        UIView *host = view.accessibilityIdentifier.length ? hostOf(view) : nil;
        if (host) [hosts addObject:host];
    });
    for (UIView *host in hosts) dressLater(host);
}

// A window a dialog of Spotify's can be in: above the app's, shown, and not one of UIKit's own (the keyboard's, text
// effects') or the mod's.
static BOOL dialogWindow(UIWindow *window) {
    if (window.hidden || window.windowLevel <= UIWindowLevelNormal) return NO;
    NSString *name = NSStringFromClass(window.class);
    if ([name isEqualToString:@"UIWindow"]) return YES;
    return ![name hasPrefix:@"UI"] && ![name hasPrefix:@"_UI"] && ![name hasPrefix:@"SG"];
}

static UIView *dialogIn(UIWindow *window) {
    __block UIView *host = nil;
    SGForEachView(window, ^(UIView *view) {
        if (!host && view.accessibilityIdentifier.length) host = hostOf(view);
    });
    return host;
}

// While a taken dialog is up: once its window is hidden or holds it no more, Spotify took it down.
static void watchGone(UIWindow *window) {
    __weak UIWindow *weak = window;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIWindow *still = weak;
        SGRDialogTake *take = still ? objc_getAssociatedObject(still, &kTakeKey) : nil;
        if (!take || take.done) return;
        if (still.hidden || !dialogIn(still)) abandon(still);
        else watchGone(still);
    });
}

static void lookForDialog(UIWindow *window) {
    if (!dialogWindow(window)) return;
    SGRDialogTake *current = objc_getAssociatedObject(window, &kTakeKey);
    if (current && !current.done) return;
    UIView *host = dialogIn(window);
    if (!host) return;
    if (takeOver(window)) watchGone(window);
    else dressLater(host);
}

// Shown: looked through now and as Spotify fills it in.
static void lookSoon(UIWindow *window) {
    lookForDialog(window);
    __weak UIWindow *weak = window;
    for (NSNumber *after in @[@0.02, @0.08, @0.2, @0.4]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(after.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            UIWindow *still = weak;
            if (still) lookForDialog(still);
        });
    }
}

%group SGRDialogs
%hook UIWindow
- (void)setHidden:(BOOL)hidden {
    %orig;
    UIWindow *window = (UIWindow *)self;
    if (!hidden) lookSoon(window);
    else if (objc_getAssociatedObject(window, &kTakeKey)) abandon(window);
}

- (void)makeKeyAndVisible {
    %orig;
    lookSoon((UIWindow *)self);
}

- (void)layoutSubviews {
    %orig;
    lookForDialog((UIWindow *)self);
}

- (void)didAddSubview:(UIView *)subview {
    %orig;
    lookForDialog((UIWindow *)self);
}
%end
%end

%ctor {
    if (!SGRedesignedUI() || !SGBelowiOS26()) return;
    %init(SGRDialogs);
}
