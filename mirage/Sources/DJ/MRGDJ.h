// Mirage DJ: asks the user's AI provider for a plan and about 15 tracks with a short line before each, from the
// listener's taste (what is playing, what was played, the queue around it: names only) and the request, finds each on
// Spotify (dropping too-popular picks when the request is for underground music, and asking again to refill), plays
// the set in Spotify's own player and says lines as their tracks start (as often as the persona's talk setting says),
// with the music lowered under the voice.
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
@property (nonatomic) NSInteger popularity;    // Spotify's 0-100 from search, -1 when unknown
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
- (void)startWithRequest:(NSString *)request;   // nil: just play something for me
- (void)switchItUp;                              // a new set in a clearly different direction from the last plan
// Plays these tracks (dictionaries with uri, title, artist, optional image/line) as a DJ set, for the chat.
- (void)playTracks:(NSArray<NSDictionary *> *)tracks intro:(NSString *)intro;
// Plays a playlist, album, artist or Liked Songs as Spotify's own context (the DJ set steps aside, the queue is
// emptied first); shuffle nil leaves the listener's setting. done: ok when the player took it; error is a note when
// it was taken but not confirmed playing.
- (void)playContext:(NSString *)uri shuffle:(NSNumber *)shuffle done:(void (^)(BOOL ok, NSString *error))done;
@property (nonatomic, readonly, copy) NSString *plan;         // the model's plan for the current set
@property (nonatomic, readonly, copy) NSString *lastRequest;
- (void)stop;
@end

// Personas: how the DJ talks and how much. Settings → Mirage → AI DJ → Vibe.
NSArray<NSString *> *MRGDJPersonaNames(void);       // "Classic", "Chill radio host", "Hype", …
NSArray<NSString *> *MRGDJPersonaBlurbs(void);
NSInteger MRGDJPersona(void);
void MRGDJSetPersona(NSInteger i);
typedef NS_ENUM(NSInteger, MRGDJTalk) { MRGDJTalkAuto = 0, MRGDJTalkEvery = 1, MRGDJTalkFew = 2, MRGDJTalkSwitches = 3 };
MRGDJTalk MRGDJTalkSetting(void);                  // Auto follows the persona
void MRGDJSetTalkSetting(MRGDJTalk t);
MRGDJTalk MRGDJTalkEffective(void);
NSString *MRGDJCustomPrompt(void);                 // appended to the base prompt, for picks and the chat
void MRGDJSetCustomPrompt(NSString *s);
NSString *MRGDJPersonaStyle(void);                 // the persona's voice instructions, for the chat too
BOOL MRGDJShowsPill(void);
void MRGDJSetShowsPill(BOOL on);
BOOL MRGDJShowsPlayerButton(void);   // the DJ button and caption on Now Playing
void MRGDJSetShowsPlayerButton(BOOL on);
BOOL MRGDJDucks(void);
void MRGDJSetDucks(BOOL on);
NSString *MRGDJDeviceVoiceName(void);   // the on-device voice it picked, for settings

// Talking like the listener (Settings → AI DJ → Talk like me, on by default): their last chat messages, kept on this
// phone, are given to the model as samples of how they write.
BOOL MRGDJMirrorsUser(void);
void MRGDJSetMirrorsUser(BOOL on);
void MRGDJNoteUserMessage(NSString *text);
void MRGDJForgetUserStyle(void);
NSString *MRGDJStyleInstructions(void);   // nil when off or too few samples
// The listener's taste from the on-phone history (on repeat, top and recent artists, throwbacks) as prompt text, or nil.
NSString *MRGDJTasteText(void);
