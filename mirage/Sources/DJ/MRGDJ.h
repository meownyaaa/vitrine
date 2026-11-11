// Mirage DJ: asks the user's AI provider for a set of 12 tracks with a short line before each, from the
// listener's taste (what is playing, what was played, top and liked tracks: names only), finds each on
// Spotify, plays the set in Spotify's own player and says each line as its track starts, with the music
// lowered under the voice.
#import <Foundation/Foundation.h>

extern NSString *const MRGDJChangedNotification;   // main queue: status, line, set or error changed
// Main queue, as the DJ starts and stops talking; userInfo: line (NSString), speaking (NSNumber BOOL). With the
// voice off it still "talks" for as long as reading the line takes, so the caption on Now Playing shows it.
extern NSString *const MRGDJSpeakingNotification;

typedef NS_ENUM(NSInteger, MRGDJState) {
    MRGDJIdle = 0,
    MRGDJThinking,    // asking the model / finding tracks
    MRGDJPlaying,     // a set is on
};

@interface MRGDJTrack : NSObject
@property (nonatomic, copy) NSString *title, *artist, *line, *uri;
@property (nonatomic, copy) NSString *image;   // cover URL (https), when Spotify's search gave one
@property (nonatomic, copy) NSString *why;     // the model's 1-4 word reason ("deep cut", "fresh find"), optional
@end

@interface MRGDJ : NSObject
+ (instancetype)shared;
@property (nonatomic, readonly) MRGDJState state;
@property (nonatomic, readonly, copy) NSString *status;       // what it is doing, for the sheet
@property (nonatomic, readonly, copy) NSString *currentLine;  // the last thing it said
@property (nonatomic, readonly, copy) NSString *error;        // the last failure, user-facing
@property (nonatomic, readonly, copy) NSArray<MRGDJTrack *> *set;
@property (nonatomic, readonly) NSInteger currentIndex;       // in `set`, -1 when the player is elsewhere
@property (nonatomic, readonly, copy) NSString *playbackMode; // "queue" (the rest of the set is in Spotify's queue) or "step" (each next track played by Mirage)
@property (nonatomic, readonly, getter=isSpeaking) BOOL speaking;
- (void)playFromIndex:(NSInteger)index;          // jumps to a track of the set (a new context from it)
- (void)startWithRequest:(NSString *)request;   // nil: just play something for me; also "Switch it up"
- (void)stop;
@end

// Voice (Mirage settings).
typedef NS_ENUM(NSInteger, MRGDJVoiceMode) { MRGDJVoiceDevice = 0, MRGDJVoiceProvider = 1, MRGDJVoiceOff = 2 };
MRGDJVoiceMode MRGDJVoice(void);
void MRGDJSetVoice(MRGDJVoiceMode m);
BOOL MRGDJShowsPill(void);
void MRGDJSetShowsPill(BOOL on);
BOOL MRGDJShowsPlayerButton(void);   // the DJ button and caption on Now Playing
void MRGDJSetShowsPlayerButton(BOOL on);
BOOL MRGDJDucks(void);
void MRGDJSetDucks(BOOL on);
NSString *MRGDJDeviceVoiceName(void);   // the on-device voice it picked, for settings
