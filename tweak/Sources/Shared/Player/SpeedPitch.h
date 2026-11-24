// Speed and pitch: two sliders in the more button's menu, done to Spotify's sound, under either look.
// Nothing here draws on a Spotify screen of its own: the block goes into Spotify's own context menu
// sheet, and the rest is audio.
//
//     SpeedPitchMenu.x   the expandable row and its two sliders, put into Spotify's context menu, and under
//                        the redesign the Animated artwork switch under them
//     SpeedPitch.x       speed and pitch done to Spotify's audio, between its mixer and its speaker unit, and
//                        Spotify's outputs kept apart, one of them the music's (SGPlayerMusicOutput)
//     SGTimePitch.m      Apple's time and pitch unit, pulling the mixer or working in place
//
// Speed and pitch last until Spotify quits; neither is stored.
// Threading: main thread only, except what SGTimePitch.h says runs on the render thread.
#import <UIKit/UIKit.h>
#import <AudioToolbox/AudioToolbox.h>

// Whether a context menu sheet is the player's ⋯ card: the first to come up within a few seconds of a tap on
// the player's more button (SpeedPitchMenu.x watches it under either look); decided once per menu.
BOOL SGPlayerMenuIsPlayers(UIViewController *menu);
// The next context menu sheet is the player's ⋯ card, as a tap on the ⋯ would make it: for the redesign's ⋯,
// whose menu runs Spotify's ⋯ action from code (Redesigned/ContextMenu) and keeps the touch from the ⋯.
void SGPlayerMenuMarkPlayers(void);
// Whether the sheet is shown as the system menu instead, unseen under it (Redesigned/ContextMenu), whose own
// items then stand in for the block, which stays out of it. Defined by the redesign; NO under the native look
// and once the sheet itself is shown.
BOOL SGPlayerMenuReplaced(UIViewController *menu);
// The speed Spotify's sound plays at, 1 when normal.
double SGPlayerSpeed(void);
// Whether speed can apply: Spotify's output was taken over when it wired it.
BOOL SGPlayerSpeedAllowed(void);
void SGSetPlayerSpeed(double speed);
// Semitones Spotify's output is moved by, 0 when it is not.
float SGPlayerPitch(void);
void SGSetPlayerPitch(float semitones);
// Speed and pitch move together, like a record, by resampling rather than the time stretch. On until
// switched off, from the switch under the two sliders.
#define SGKeyPitchFollowsSpeed @"spotifyglass.speed.pitchFollows"
BOOL SGPlayerPitchFollowsSpeed(void);
void SGSetPlayerPitchFollowsSpeed(BOOL follows);
// Whether the output could be reached to change its pitch.
BOOL SGPlayerPitchAvailable(void);
// The mod's own volume on Spotify's sound, 0 to 1, 1 when normal: the sleep timer's fade (SleepTimer.h).
// Any thread. The sound moves to it within half a second and never in a step. It scales what the speaker
// unit plays, in the output's own format, so a Connect device is left as it was, and it
// does nothing when Spotify's output was never reached (AudioOutputUnitStart not rebound). Not stored.
void SGPlayerSetGain(float gain);
// The audio effects' reverb as the menu sets it, 0 to 100, 0 while it is off. Any amount turns the effects and
// the reverb on with it; 0 turns the reverb off and leaves the rest of the effects as they were.
float SGPlayerReverb(void);
void SGPlayerSetReverb(float amount);

// The redesign's Animated artwork, switched in the same block: whether the player offers the switch (the
// redesign is running and its background is Fluid, Animated or Visualizer, the three that share a field),
// whether it is on, and switching it, which applies at once and is stored as the Background choice (off is
// Fluid, and from the Visualizer changes nothing). Defined by
// Redesigned/Player/PlayerMotion.x; NO from the first under the native look.
BOOL SGPlayerMenuOffersAnimatedArtwork(void);
BOOL SGPlayerMenuAnimatedArtwork(void);
void SGPlayerMenuSetAnimatedArtwork(BOOL on);
// The speed, pitch and reverb sliders and Pitch follows speed, in a popover from `from` (the redesign's ⋯).
void SGPlayerShowSpeedPitchPanel(UIView *from);
// Below iOS 26, puts the ⋯ menu's glass in place of the blur of the popover `content` (the panel's view) sits in,
// leaving the popover itself, and so its animation, the system's. Defined by Redesigned/Player/PlayerPanelGlass.m;
// does nothing under the native look and on iOS 26. Safe to call on every layout.
void SGPlayerStylePanel(UIView *content);
// A stage between Spotify's mixer and the rest of the chain (Sing's look-ahead, Shared/Sing): it fills the
// chain's buffers, pulling the mixer through `pull` as much as it likes. NULL passes the mixer straight on.
// Called on the render thread, and only on the music's output (below) while Spotify's connection to it is taken
// over (SGPlayerSpeedAllowed). The buffers are in SGPlayerMusicClientFormat's format. With `sounding` set, a pull stops
// at the first part the mixer marks silent (Spotify has none of its sound there yet), leaves the rest silent unrendered
// and sets the frames before it; without, every part is rendered, silent or not.
typedef OSStatus (*SGPlayerPull)(void *context, UInt32 frames, AudioBufferList *data, UInt32 *sounding);
typedef OSStatus (*SGPlayerStage)(UInt32 frames, AudioBufferList *data, SGPlayerPull pull, void *context);
void SGPlayerSetStage(SGPlayerStage stage);
@class SPTPlayerState;
// Sing's lead, for the own clock -[SPTPlayerState position] keeps away from 1x (SpeedPitch.x): the seconds it holds ahead
// of what plays now, and the correction it takes off a report. Set once by Sing.x.
typedef double (*SGPlayerHeldLead)(void);
typedef double (*SGPlayerLeadOf)(SPTPlayerState *state);
void SGPlayerSetLeadReaders(SGPlayerHeldLead held, SGPlayerLeadOf of);

// Experimental source selector, before the existing stage. Registered callback code must live for the
// process lifetime. Called after each successful, non-silent native mixer pull on the music output only.
// The native mixer is still drained exactly once. data is planar Float32 in the client format; replace
// a complete span or leave it untouched. No allocation, file I/O, Objective-C or waits here.
// sourceFrame is an output-local counter, not track position. The caller must prove a recording/frame
// anchor before enabling replacement. No production caller currently does so.
typedef void (*SGPlayerSourceSelector)(AudioUnit output, uint64_t epoch, double sourceFrame,
                                      double sampleRate, UInt32 frames, AudioBufferList *data);
void SGPlayerSetSourceSelector(SGPlayerSourceSelector selector);
uint64_t SGPlayerSourceEpoch(void);
// Any thread, including render. Invalidate on every seek/skip/recording occurrence/policy cancellation.
// Audio-output lifecycle changes also invalidate internally. An already admitted render may finish.
void SGPlayerInvalidateSource(void);

// The music's output: of the RemoteIO units Spotify runs at once (a chain per sample rate, and voice search's),
// the one that carries every processor of its sound (speed and pitch, Sing's stage, the audio effects, Music
// Haptics), NULL until Spotify connects or starts one. Any thread; the render thread compares it with a render
// notify's unit to process the music's output alone.
AudioUnit SGPlayerMusicOutput(void);
// The format Spotify hands the music's output (its input scope, element 0), the one the stage's buffers are
// in. NO when there is no such output. Not on the render thread.
BOOL SGPlayerMusicClientFormat(AudioStreamBasicDescription *format);
// `watcher` is called with the music's output each time it changes (NULL when there is none any more), Spotify
// starts it again, or a format of it changes: the time to read its format, add a render notify to it and start
// over what was held. Called on Spotify's audio thread or a queue of Shared/Player's, under a lock a dispose
// waits for, so the unit stays alive through the call; it must not wait on the main thread. NO when
// Spotify's output cannot be reached at all. Register from a %ctor; up to four.
typedef void (*SGPlayerOutputWatcher)(AudioUnit output);
BOOL SGPlayerWatchMusicOutput(SGPlayerOutputWatcher watcher);

#if SG_DRIVER
// Speed-rebuffer test (FLEX builds): completed runs of silence from the music's mixer so far, and the last one's
// start (mach time) and length; silentNow while one is running.
uint64_t SGSpeedProbeSilence(uint64_t *host, double *ms, bool *silentNow);
#endif
