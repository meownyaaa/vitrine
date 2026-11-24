#import "SGHapticRelay.h"
#import "Haptics.h"
#import "Core/SGCore.h"
#import <notify.h>
#import "Core/SGRebind.h"
#import "Settings/SGPageStyle.h"
#import "Shared/AnimatedArtwork/AnimatedArtwork.h"
#import <stdatomic.h>

NSNotificationName const SGHapticRelayAvailableNotification = @"SGHapticRelayAvailableNotification";

static BOOL sg_available;
// The rumble's level as last posted, so an unchanged one is not posted again; -1 before any.
static atomic_int sg_rumbleSent = -1;
// Locked with the lock screen switch off, the add-on would only drop what it is sent: nothing goes. Read on the audio
// thread, kept by the lock state's notification and the switch as they change.
static atomic_bool sg_quiet;
static BOOL sg_locked;
static atomic_uint_fast64_t sg_rumbleSentAt;

BOOL SGHapticRelayAvailable(void) {
    return sg_available;
}

static uint64_t sg_installedBuild;
static void offerUpdate(void);

NSURL *SGHapticAddonPackage(void) {
    return [NSBundle.mainBundle URLForResource:@"VitrineAddon" withExtension:@"deb"];
}

uint64_t SGHapticAddonInstalledBuild(void) {
    return sg_installedBuild;
}

BOOL SGHapticAddonOutdated(void) {
    return sg_available && sg_installedBuild > 0 && sg_installedBuild < kSGRelayAddonBuild && SGHapticAddonPackage();
}

BOOL SGHapticAddonShare(UIView *view) {
    NSURL *package = SGHapticAddonPackage();
    if (!package || !view.window) return NO;
    // Kept while its menu is up: the menu goes when its controller does.
    static UIDocumentInteractionController *share;
    share = [UIDocumentInteractionController interactionControllerWithURL:package];
    share.UTI = @"org.debian.deb-archive";
    share.name = @"Vitrine Addon";
    CGRect at = CGRectMake(CGRectGetMidX(view.bounds), CGRectGetMidY(view.bounds), 1, 1);
    BOOL shown = [share presentOptionsMenuFromRect:at inView:view animated:YES];
    SGLog(@"music haptics: the add-on's .deb handed to the system's Open In (%@)", shown ? @"shown" : @"nothing takes it");
    return shown;
}

BOOL SGHapticEverywhereOffered(void) {
    return sg_available || SGJailbroken();
}

static void watchLock(void);

void SGHapticRelayAsk(void) {
    static int token;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        watchLock();
        notify_register_dispatch(kSGRelayPong, &token, dispatch_get_main_queue(), ^(int t) {
            uint64_t build = 0;
            if (notify_get_state(t, &build) == NOTIFY_STATUS_OK) sg_installedBuild = build;
            SGHapticRelaySendLockScreen();
            SGHapticRelaySendLockArt();
            if (sg_available) return;
            sg_available = YES;
            offerUpdate();
            SGLog(@"music haptics: SpringBoard plays them everywhere (the add-on's build %llu, this one carries %d)",
                  (unsigned long long)sg_installedBuild, kSGRelayAddonBuild);
            [NSNotificationCenter.defaultCenter postNotificationName:SGHapticRelayAvailableNotification object:nil];
        });
    });
    notify_post(kSGRelayPing);
}

void SGHapticRelaySendLockArt(void) {
    notify_post(SGFlag(SGKeyLockCoverAddon, NO) ? kSGRelayLockArtOn : kSGRelayLockArtOff);
    notify_post(SGEnabled(SGKeyLockCoverLyrics) ? kSGRelayLockLyricsOn : kSGRelayLockLyricsOff);
}

void SGHapticAddonShareSoon(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        SGHapticAddonShare(SGTopController().view);
    });
}

// A new Vitrine carrying a newer add-on than the one SpringBoard runs: said once for each add-on build it carries, a
// moment after launch, with the same two taps to put it in place. Only the add-on's answer starts it, so only a
// jailbroken phone with the add-on installed ever sees it.
static NSString *const kUpdateOfferedKey = @"spotifyglass.addon.updateOffered";

static void offerUpdate(void) {
    if (!SGHapticAddonOutdated()) return;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if ([defaults integerForKey:kUpdateOfferedKey] >= kSGRelayAddonBuild) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIViewController *top = SGTopController();
        if (!top || !SGHapticAddonOutdated() || [top isKindOfClass:UIAlertController.class]) return;
        [defaults setInteger:kSGRelayAddonBuild forKey:kUpdateOfferedKey];
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Update Vitrine Addon"
            message:@"This Vitrine comes with a newer Vitrine Addon than the one installed. Tap Update, pick Sileo or Filza, install it, then respring."
            preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"Update" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) { SGHapticAddonShareSoon(); }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"Later" style:UIAlertActionStyleCancel handler:nil]];
        [top presentViewController:alert animated:YES completion:nil];
        SGLog(@"music haptics: the add-on's build %llu is older than this Vitrine's %d, its update offered", (unsigned long long)sg_installedBuild, kSGRelayAddonBuild);
    });
}

void SGHapticAddonExplain(NSString *feature) {
    BOOL carried = SGHapticAddonPackage() != nil;
    NSString *message = carried
        ? [NSString stringWithFormat:@"%@ is played by SpringBoard, through a small add-on that comes with Vitrine. Tap Install, pick Sileo or Filza, install it, then respring. The switch stays on and works once the add-on is there.", feature]
        : [NSString stringWithFormat:@"%@ is played by SpringBoard, through a small add-on that comes inside Vitrine's IPA. This install has no copy of it: install Vitrine from its IPA, then turn the switch on again to put the add-on in place.", feature];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Needs Vitrine Addon" message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    if (carried) {
        [alert addAction:[UIAlertAction actionWithTitle:@"Install" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) { SGHapticAddonShareSoon(); }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"Later" style:UIAlertActionStyleCancel handler:nil]];
    } else {
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    }
    [SGTopController() presentViewController:alert animated:YES completion:nil];
}

static void updateQuiet(void) {
    BOOL quiet = sg_locked && !SGFlag(SGKeyMusicHapticsLockScreen, NO);
    // Quiet first, so a rumble the audio thread sends meanwhile is dropped; then a rumble going on is stopped, as a level
    // of 0 still goes.
    BOOL was = atomic_exchange(&sg_quiet, quiet);
    if (quiet && !was) SGHapticRelayRumble(0);
    // Quiet, nothing is relayed, so the output is not analysed for it either (MusicHaptics.x's listening).
    if (quiet != was) SGMusicHapticsRelayQuietChanged();
}

BOOL SGHapticRelayQuiet(void) {
    return atomic_load(&sg_quiet);
}

void SGHapticRelaySendLockScreen(void) {
    notify_post(SGFlag(SGKeyMusicHapticsLockScreen, NO) ? kSGRelayLockOn : kSGRelayLockOff);
    updateQuiet();
}

// The phone's lock state, as SpringBoard's notification's state has it (1 locked), read now and as it changes.
static void watchLock(void) {
    static int token;
    notify_register_dispatch("com.apple.springboard.lockstate", &token, dispatch_get_main_queue(), ^(int t) {
        uint64_t state = 0;
        notify_get_state(t, &state);
        sg_locked = state != 0;
        updateQuiet();
    });
    uint64_t state = 0;
    if (notify_get_state(token, &state) == NOTIFY_STATUS_OK) sg_locked = state != 0;
    updateQuiet();
}

static int bucket(float value, int count) {
    int b = (int)lroundf(MAX(0, MIN(1, value)) * count);
    return MAX(0, MIN(count, b));
}

void SGHapticRelayTap(float intensity, float sharpness) {
    if (!sg_available || atomic_load(&sg_quiet)) return;
    int level = MAX(1, bucket(intensity, kSGRelayLevels));
    int sharp = MIN(kSGRelaySharpnesses - 1, (int)(MAX(0, MIN(1, sharpness)) * kSGRelaySharpnesses));
    char name[64];
    snprintf(name, sizeof name, kSGRelayPrefix "tap.%d.%d", level, sharp);
    notify_post(name);
}

void SGHapticRelayRumble(float level) {
    int b = bucket(level, kSGRelayLevels);
    if (!sg_available || (b > 0 && atomic_load(&sg_quiet))) return;
    uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    BOOL same = atomic_exchange(&sg_rumbleSent, b) == b;
    // Unchanged, it goes again now and then while it is on, the add-on's sign that Spotify still means it.
    if (same && (b == 0 || now - atomic_load(&sg_rumbleSentAt) < (uint64_t)(kSGRelayRumbleKeepalive * NSEC_PER_SEC))) return;
    atomic_store(&sg_rumbleSentAt, now);
    char name[64];
    snprintf(name, sizeof name, kSGRelayPrefix "rumble.%d", b);
    notify_post(name);
}
