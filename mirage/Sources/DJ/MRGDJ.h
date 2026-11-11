// Mirage DJ: asks the user's AI provider for a set of 8-10 tracks with a short line before each, from the
// listener's taste (what is playing, what was played, top and liked tracks: names only), finds each on
// Spotify, plays the set in Spotify's own player and says each line as its track starts, with the music
// lowered under the voice.
#import <Foundation/Foundation.h>

extern NSString *const MRGDJChangedNotification;   // main queue: status, line, set or error changed

typedef NS_ENUM(NSInteger, MRGDJState) {
    MRGDJIdle = 0,
    MRGDJThinking,    // asking the model / finding tracks
    MRGDJPlaying,     // a set is on
};

@interface MRGDJTrack : NSObject
@property (nonatomic, copy) NSString *title, *artist, *line, *uri;
@end

@interface MRGDJ : NSObject
+ (instancetype)shared;
@property (nonatomic, readonly) MRGDJState state;
@property (nonatomic, readonly, copy) NSString *status;       // what it is doing, for the sheet
@property (nonatomic, readonly, copy) NSString *currentLine;  // the last thing it said
@property (nonatomic, readonly, copy) NSString *error;        // the last failure, user-facing
@property (nonatomic, readonly, copy) NSArray<MRGDJTrack *> *set;
@property (nonatomic, readonly) NSInteger currentIndex;       // in `set`, -1 when the player is elsewhere
@property (nonatomic, readonly, copy) NSString *playbackMode; // "context", "queue" or "playlist"
- (void)startWithRequest:(NSString *)request;   // nil: just play something for me; also "Switch it up"
- (void)stop;
@end

// Voice (Mirage settings).
typedef NS_ENUM(NSInteger, MRGDJVoiceMode) { MRGDJVoiceDevice = 0, MRGDJVoiceProvider = 1, MRGDJVoiceOff = 2 };
MRGDJVoiceMode MRGDJVoice(void);
void MRGDJSetVoice(MRGDJVoiceMode m);
BOOL MRGDJShowsPill(void);
void MRGDJSetShowsPill(BOOL on);
BOOL MRGDJDucks(void);
void MRGDJSetDucks(BOOL on);
NSString *MRGDJDeviceVoiceName(void);   // the on-device voice it picked, for settings
