// Music Haptics > Everywhere, with a jailbreak: the mod's own Music Haptics carried on while Spotify is not in front
// (the home screen, other apps, the lock screen), where iOS plays no haptics for an app in the background. Spotify
// keeps listening to its own sound and hands each tap and each level of the rumble to SpringBoard, which is always in
// front and plays them. The SpringBoard side is an add-on package of its own, Vitrine Addon (addons/haptics), installed
// once with a package manager on a jailbroken phone: Vitrine's IPA lives in Spotify's sandbox and has no way into
// SpringBoard. The IPA build lays the add-on's .deb inside Spotify.app (scripts/pipeline.sh), and the page hands that
// file to the package manager through the system's Open In (Sileo and Filza both take a .deb that way), so installing it
// is two taps, and the only way it is offered. An install of Vitrine's .deb alone has no copy inside Spotify: there the
// page says the IPA carries it. Everywhere is offered on a jailbroken phone; nothing plays behind Spotify
// until the add-on answers.
//
// The add-on answers with its build number (kSGRelayAddonBuild, raised whenever addons/haptics changes) as the state of
// its pong, so a copy inside Spotify newer than the one installed is offered as an update.
//
// The two talk by Darwin notifications, which a sandboxed app may post and which carry no payload: the value is in the
// name. A tap is one of kSGRelayLevels intensities times kSGRelaySharpnesses sharpnesses, the rumble one of
// kSGRelayLevels levels or 0 for quiet. Spotify posts each at the moment it is to be felt, so SpringBoard plays it at
// once. Spotify asks whether SpringBoard is there with a ping; SpringBoard answers with a pong, and posts one as it
// starts too, so whichever comes up second is heard.
//
// Threading: the posts are made from any thread; the answer is taken on the main queue.
#import <UIKit/UIKit.h>

#define kSGRelayPrefix "com.vitrine.haptics."
#define kSGRelayPing kSGRelayPrefix "ping"
#define kSGRelayPong kSGRelayPrefix "pong"
// kSGRelayPrefix "tap.<1...kSGRelayLevels>.<0...kSGRelaySharpnesses-1>" and kSGRelayPrefix "rumble.<0...kSGRelayLevels>".
enum { kSGRelayLevels = 10, kSGRelaySharpnesses = 3 };
// The add-on's build, set on its pong; raise it with every change to addons/haptics, so an older add-on is offered the copy
// inside Spotify.
enum { kSGRelayAddonBuild = 24 };
// Below iOS 26, the add-on also fills the lock screen with the now playing cover while Spotify's switch for it is on
// (AnimatedArtwork.h, SGKeyLockCoverAddon): told "lockart.1" and "lockart.0" as the switch is set and each time the
// add-on answers. It reads the cover from MediaRemote, as the lock screen's own player does.
#define kSGRelayLockArtOn kSGRelayPrefix "lockart.1"
#define kSGRelayLockArtOff kSGRelayPrefix "lockart.0"
// The track's moving artwork for the cover (Shared/AnimatedArtwork/LockScreenAddonClip.x): copied to kSGLockClipName in
// Spotify's caches, then "lockclip" posted; "lockclip.none" when the track has none, or while its clip is looked up.
#define kSGRelayLockClip kSGRelayPrefix "lockclip"
#define kSGRelayLockClipNone kSGRelayPrefix "lockclip.none"
#define kSGLockClipName "VitrineLockClip.mp4"
// Within the add-on: SpringBoard copies the clip where MediaRemoteUI, which draws the large cover, can read it
// (SGLockSharedClipPath) and posts "lockclip.shared"; MediaRemoteUI posts "lockclip.showing.1" while the clip is in the
// cover's place and "lockclip.showing.0" as it leaves, for SpringBoard to hide the widgets under the clock.
#define kSGRelayLockClipShared kSGRelayPrefix "lockclip.shared"
#define kSGRelayLockShowing kSGRelayPrefix "lockclip.showing.1"
#define kSGRelayLockNotShowing kSGRelayPrefix "lockclip.showing.0"
static inline NSString *SGLockSharedClipPath(void) {
    NSString *root = [NSFileManager.defaultManager fileExistsAtPath:@"/var/jb"] ? @"/var/jb/var/mobile" : @"/var/mobile";
    return [root stringByAppendingPathComponent:@"Library/Caches/com.vitrine.addon/lockclip.mp4"];
}
// The lyrics over the large cover's Canvas (AnimatedArtwork.h, SGKeyLockCoverLyrics), told the add-on with the cover's
// own switch: "locklyrics.1" and "locklyrics.0".
#define kSGRelayLockLyricsOn kSGRelayPrefix "locklyrics.1"
#define kSGRelayLockLyricsOff kSGRelayPrefix "locklyrics.0"
// The song's lines (Shared/AnimatedArtwork/LockScreenAddonLyrics.x): written to kSGLockLyricsName in Spotify's caches, then
// "locklyrics" posted; SpringBoard copies them where MediaRemoteUI can read them (SGLockSharedLyricsPath) and posts
// "locklyrics.shared". "locklyrics.none" for a song with no timed lines, "locklyrics.pending" as a song begins whose
// lines are still on their way: what is drawn holds until they come or kSGRelayLockLyricsWait has gone.
#define kSGRelayLockLyrics kSGRelayPrefix "locklyrics"
#define kSGRelayLockLyricsNone kSGRelayPrefix "locklyrics.none"
#define kSGRelayLockLyricsPending kSGRelayPrefix "locklyrics.pending"
#define kSGRelayLockLyricsShared kSGRelayPrefix "locklyrics.shared"
#define kSGLockLyricsName "VitrineLockLyrics.json"
// The most of it SpringBoard copies and MediaRemoteUI reads: a song's lines, with their words, translations and Latin
// letters, are a few hundred KB.
#define kSGLockLyricsMostBytes (4 * 1024 * 1024)
#define kSGRelayLockLyricsWait 2.0
static inline NSString *SGLockSharedLyricsPath(void) {
    NSString *root = [NSFileManager.defaultManager fileExistsAtPath:@"/var/jb"] ? @"/var/jb/var/mobile" : @"/var/mobile";
    return [root stringByAppendingPathComponent:@"Library/Caches/com.vitrine.addon/lyrics.json"];
}
// Where the song is, posted by Spotify as it starts, stops, seeks or changes speed and every few seconds while it plays,
// with the clock in the notification's state (SGLockLyricsClock): MediaRemoteUI runs it on from when it hears it.
#define kSGRelayLockLyricsClock kSGRelayPrefix "locklyrics.clock"
// The clock's state: the position in ms (32 bits), the speed in thousandths (16), playing (1) and the song's tag (15),
// so a clock of another song than the lines' is not run against them.
static inline uint64_t SGLockLyricsClock(NSInteger ms, double speed, BOOL playing, uint16_t tag) {
    uint64_t position = (uint64_t)MAX(0, MIN(ms, (NSInteger)UINT32_MAX));
    uint64_t thousandths = (uint64_t)MAX(0, MIN(speed * 1000, 65535.0));
    return position | thousandths << 32 | (uint64_t)(playing ? 1 : 0) << 48 | (uint64_t)(tag & 0x7FFF) << 49;
}
// A song's tag: its id folded to 15 bits (FNV-1a), never 0, which stands for none.
static inline uint16_t SGLockLyricsTag(NSString *track) {
    uint32_t hash = 2166136261u;
    for (const char *c = track.UTF8String; c && *c; c++) hash = (hash ^ (uint8_t)*c) * 16777619u;
    uint16_t tag = (uint16_t)((hash ^ (hash >> 15)) & 0x7FFF);
    return tag ? tag : 1;
}
// A tap on a line of the large cover's lyrics: the position to seek to, in ms, in the notification's state, posted by
// MediaRemoteUI for Spotify to seek to (LockScreenAddonLyrics.x).
#define kSGRelayLockLyricsSeek kSGRelayPrefix "locklyrics.seek"
// The large cover takes no touches: MediaRemoteUI draws it in a window behind SpringBoard's cover sheet, whose
// notification list gets every touch over it, scrolls the player with the finger and closes the cover on a tap. So
// SpringBoard lays a catcher over the list where the lyrics are (LockCover.x) while the cover is open, and hands its
// drags and taps to MediaRemoteUI: "lockgesture.area" from MediaRemoteUI says where the lyrics are and whether they show
// (SGLockGestureArea); "lockgesture.pan" and "lockgesture.tap" carry a drag
// (SGLockGesturePan) and a tap (SGLockGestureTap) back, in screen points.
#define kSGRelayLockGestureArea kSGRelayPrefix "lockgesture.area"
#define kSGRelayLockGesturePan kSGRelayPrefix "lockgesture.pan"
#define kSGRelayLockGestureTap kSGRelayPrefix "lockgesture.tap"
typedef struct {
    BOOL lyricsShown;
    CGFloat lyricsTop, lyricsBottom;   // screen points, 0 for none
} SGLockGestureAreaState;
static inline uint64_t SGLockGestureArea(SGLockGestureAreaState area) {
    uint64_t (^field)(CGFloat) = ^uint64_t(CGFloat value) { return (uint64_t)MAX(0, MIN(round(value), 32767.0)) & 0x7FFF; };
    return (uint64_t)(area.lyricsShown ? 1 : 0) | field(area.lyricsTop) << 1 | field(area.lyricsBottom) << 16;
}
static inline SGLockGestureAreaState SGLockGestureAreaRead(uint64_t state) {
    return (SGLockGestureAreaState){(BOOL)(state & 1), (CGFloat)((state >> 1) & 0x7FFF), (CGFloat)((state >> 16) & 0x7FFF)};
}
// A drag: its phase (0 began, 1 moved, 2 ended), how far the finger has gone down since it began and how fast it goes
// down, in points and points a second, each in quarters of a point as a signed 31-bit number.
static inline uint64_t SGLockGesturePan(int phase, CGFloat translation, CGFloat velocity) {
    uint32_t (^field)(CGFloat) = ^uint32_t(CGFloat value) { return (uint32_t)((int32_t)MAX(-1e9, MIN(value * 4, 1e9)) & 0x7FFFFFFF); };
    return (uint64_t)(phase & 3) | (uint64_t)field(translation) << 2 | (uint64_t)field(velocity) << 33;
}
static inline void SGLockGesturePanRead(uint64_t state, int *phase, CGFloat *translation, CGFloat *velocity) {
    CGFloat (^field)(uint64_t) = ^CGFloat(uint64_t bits) {
        int32_t value = (int32_t)(bits << 1) >> 1;   // the 31 bits sign-extended
        return value / 4.0;
    };
    *phase = (int)(state & 3);
    *translation = field((state >> 2) & 0x7FFFFFFF);
    *velocity = field((state >> 33) & 0x7FFFFFFF);
}
// A tap at a point of the screen, in quarters of a point.
static inline uint64_t SGLockGestureTap(CGPoint point) {
    return (uint64_t)(uint32_t)MAX(0, point.x * 4) | (uint64_t)(uint32_t)MAX(0, point.y * 4) << 32;
}
static inline CGPoint SGLockGestureTapRead(uint64_t state) {
    return CGPointMake((state & 0xFFFFFFFF) / 4.0, (state >> 32) / 4.0);
}
// Lyrics or the Canvas on the large cover, picked by the button in the lock screen player's header: MediaRemoteUI posts "lockmode.lyrics" or
// "lockmode.canvas" as it is tapped, SpringBoard keeps the choice for the next song and the next boot, and posts it again
// when MediaRemoteUI asks with "lockmode.ask" as it starts. The Canvas until the lyrics are picked.
#define kSGRelayLockModeLyrics kSGRelayPrefix "lockmode.lyrics"
#define kSGRelayLockModeCanvas kSGRelayPrefix "lockmode.canvas"
#define kSGRelayLockModeAsk kSGRelayPrefix "lockmode.ask"
// Whether the add-on plays while the phone is locked, told it by Spotify as the switch is set and each time the add-on
// answers: kSGRelayPrefix "lockscreen.1" plays there, "lockscreen.0" does not.
#define kSGRelayLockOn kSGRelayPrefix "lockscreen.1"
#define kSGRelayLockOff kSGRelayPrefix "lockscreen.0"
// A rumble that is on is posted again at least this often, unchanged or not, and the add-on stops one it has not heard
// of for kSGRelayRumbleLapse: a Spotify that went away mid-rumble (another copy of it opened, the app killed) left the
// last level vibrating with nothing to stop it.
#define kSGRelayRumbleKeepalive 0.2
#define kSGRelayRumbleLapse 0.6

// The key of the switch, off until switched on.
#define SGKeyMusicHapticsEverywhere @"spotifyglass.haptics.music.everywhere"
// Everywhere's second switch, on the lock screen as well; on unless switched off. With Everywhere it makes the three
// places Music Haptics plays: in Spotify only, everywhere but the lock screen, everywhere.
#define SGKeyMusicHapticsLockScreen @"spotifyglass.haptics.music.lockscreen"
// Tells the add-on the lock screen switch as it is now. Main thread.
void SGHapticRelaySendLockScreen(void);
// Locked with the lock screen switch off: nothing goes to SpringBoard, and Spotify does not analyse its output for it.
BOOL SGHapticRelayQuiet(void);
// Tells the add-on whether to fill the lock screen with the cover, and whether to put the lyrics over it, as the
// switches for them are now. Main thread.
void SGHapticRelaySendLockArt(void);
// The notice for a feature that needs the add-on, switched on without it: what it needs and, from Vitrine's IPA, the
// add-on two taps away. `feature` names what asked ("Everywhere", "The full-screen cover").
void SGHapticAddonExplain(NSString *feature);

// Whether SpringBoard's side has answered in this launch. Main thread.
BOOL SGHapticRelayAvailable(void);
// Whether Everywhere is offered: on a jailbroken phone, or wherever the add-on has answered.
BOOL SGHapticEverywhereOffered(void);
// The add-on's .deb inside Spotify.app, from the IPA build; nil in an install of Vitrine's .deb alone.
NSURL *SGHapticAddonPackage(void);
// The add-on's build as it answered, 0 before it has or when its answer carried none.
uint64_t SGHapticAddonInstalledBuild(void);
// Whether the add-on answered with an older build than the copy inside Spotify.
BOOL SGHapticAddonOutdated(void);
// Hands the copy inside Spotify to the package manager (the system's Open In, Save to Files among its choices), from
// `view`. NO when there is no copy.
BOOL SGHapticAddonShare(UIView *view);
// The add-on's .deb handed to the package manager a moment from now, once an alert it was picked from has gone.
void SGHapticAddonShareSoon(void);
// Posted on the main thread when SpringBoard first answers, for the Vibrations page to show the switch.
extern NSNotificationName const SGHapticRelayAvailableNotification;
// Asks SpringBoard whether it is there; called once at launch.
void SGHapticRelayAsk(void);
// A tap of `intensity` and `sharpness`, 0 to 1, felt now from SpringBoard; nothing without the add-on. Any thread.
void SGHapticRelayTap(float intensity, float sharpness);
// The rumble at `level`, 0 to 1, from now on; 0 stops it. Any thread.
void SGHapticRelayRumble(float level);
