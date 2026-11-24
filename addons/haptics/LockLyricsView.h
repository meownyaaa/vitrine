// The lyrics of Vitrine Addon's lock screen Canvas (MediaRemoteUICanvas.x): the song's lines over the large cover's
// Canvas, drawn as the redesign's lyrics page draws them, by the same code (tweak/Sources/Shared/Lyrics/KaraokeLines,
// built into the add-on). The line being sung rests at the page's anchor and lights up word by word, the rest stack
// around it, dimmer, smaller and more blurred the further off, and move up on the page's springs; three dots hold an
// instrumental break. A finger scrolls the lines, sharp and standing still, and kBrowseHold after it lets go they go back
// to the line sung; a tap on a line seeks the song to it (`seek`), as the lyrics page's do.
//
// The lines, their look and the song's tag come in a file Spotify writes (LockScreenAddonLyrics.x); the song's clock
// comes in a notification's state (SGLockLyricsClock) and runs on from when it is heard. A clock of another song than
// the lines' holds them still, and they count as missing (`available` NO) until the two agree.
//
// Threading: main thread; the song is measured on a queue of its own.
#import <UIKit/UIKit.h>

@interface SGVLockLyrics : UIView
// Reads the file Spotify wrote; NO when it holds no lines that read. The lines in it replace the ones shown.
- (BOOL)takeFile:(NSString *)path;
// Drops the lines, for a song without lyrics.
- (void)clear;
// The clock's state as just heard (SGLockLyricsClock).
- (void)setClockState:(uint64_t)state;
// Holds the lines where they are, as a new song begins and its lines are on their way.
- (void)hold;
// Lines there are, timed, and the clock is theirs, or they are held while the next song's come.
@property (nonatomic, readonly) BOOL available;
// Called when `available` changes.
@property (nonatomic, copy) void (^availabilityChanged)(void);
// The window the lyrics are drawn in takes no touches (SpringBoard's cover sheet is over it), so a drag and a tap are
// handed in: how far the finger has gone down since the drag began, its speed down at the end, and a tap's point in the
// view's own space.
- (void)dragBegan;
- (void)dragTo:(CGFloat)translation;
- (void)dragEndedWithVelocity:(CGFloat)velocity;
- (void)tapAt:(CGPoint)point;
// Asked to seek the song to `positionMs`, a line's start plus the Lyrics page's delay, for a tap on the line.
@property (nonatomic, copy) void (^seek)(NSInteger positionMs);
// Nothing is drawn or worked out: the screen is dark, or the lyrics are not on screen.
- (void)setSuspended:(BOOL)suspended;
@end
