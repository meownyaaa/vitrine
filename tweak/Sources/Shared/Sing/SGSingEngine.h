// Sing's engine: the vocals of what Spotify plays separated ahead of it, and turned down as it plays.
//
// The model takes two seconds at a time and is far too slow for the render thread, so the engine stands
// between Spotify's mixer and its output and pulls the mixer ahead of what plays: up to twice what a
// render asks for, until the sound it holds (the lead) is a window plus the model's time, and never past sound Spotify
// has not decoded yet (a part its mixer marks silent is left out, and read again at the next render). A worker thread
// takes the held sound two seconds at a time, every 1.5 s, runs the separator and writes the vocals into a
// second ring beside it, the half second the windows share crossfaded. Each render plays the held sound
// from the oldest frame on, the vocals turned down by the level once a hop of them is in ahead, and dry once fewer
// than the reserve are (as the lead fills, or when the model falls behind), with a budget for falling behind. Not
// separating (switched off, held, given up, without a model), it plays the lead it holds on as it is, dry, and lets it
// go only with a flush, where nothing heard is lost; once off and let go, it is a straight pull again.
//
// Spatial voice: the vocals' middle (left plus right, halved) can be put at an angle off straight ahead,
// where Sing.x holds it as the head turns. The ear facing it hears it louder and the other quieter at the same
// power (an equal-power pan, narrowed so that the far ear never loses it), and the far ear hears it up to
// 0.65 ms later (the time sound takes around a head) and duller, through a one-pole low-pass for the head's
// shadow. The vocals' sides (left less right, halved) stay where they are, so straight ahead plays the vocals
// exactly as separated.
//
// What plays is the lead behind what Spotify's decoder has handed over, which is what Spotify's clock
// counts when the player reports. Its clock then runs on by the time alone, so a position reported at a moment
// (Sing.x: when that line of the clock began) has the lead held at that moment taken off, less what was dropped since (SGSingEngineLeadAt): a lead filling
// after a report does not move what is heard, and one let go moves it on. Sing.x asks for a flush when Spotify
// seeks or skips, which drops the sound held from before it.
//
// Threading: SGSingEngineRender on the render thread only, allocation and lock free; the worker is the
// engine's own; everything else from any thread.
#import <Foundation/Foundation.h>
#import <math.h>

@class SGSingSeparator;

enum {
    kSGSingEngineHop = 66150,   // 1.5 s between windows, so neighbors share half a second
};

typedef struct SGSingEngine SGSingEngine;

// Fills `frames` frames of each channel with the next of Spotify's sound. With `sounding` set, it stops at the first
// part Spotify's mixer marks silent (none of Spotify's sound there yet), leaves the rest silent and sets the frames
// before it.
typedef OSStatus (*SGSingPull)(void *context, UInt32 frames, float *left, float *right, UInt32 *sounding);

// bufferSeconds: the least lead to keep (0 for what the model asks); the rings are sized to hold it.
SGSingEngine *SGSingEngineCreate(double bufferSeconds);
// The same, changed while the engine runs: held to what its rings hold.
void SGSingEngineSetMinimumLead(SGSingEngine *engine, double seconds);
// Stops the worker and frees the engine; nothing may be rendering through it.
void SGSingEngineDestroy(SGSingEngine *engine);
// The separator the worker runs, nil for none (what plays is then dry).
void SGSingEngineSetSeparator(SGSingEngine *engine, SGSingSeparator *separator);
void SGSingEngineSetOn(SGSingEngine *engine, bool on);
bool SGSingEngineOn(SGSingEngine *engine);
// On, not held, with a separator and not given up: the lead is kept up for the vocals.
bool SGSingEngineSeparating(SGSingEngine *engine);
// The vocals' level from 0 (gone) through 1 (as the song has them) to 2 (the vocals alone, the rest gone).
void SGSingEngineSetLevel(SGSingEngine *engine, float level);
// Where the separated voice sounds, in radians to the listener's right of straight ahead (left is negative,
// behind sounds as the front does): 0, where it starts, leaves the vocals exactly as the song has them. The
// render glides to a new angle over a few tens of milliseconds, so it can be set as often as the head moves.
void SGSingEngineSetVoiceAngle(SGSingEngine *engine, float radians);
// Spatial voice's Distance (meters, 1 to 6.5), Room (0 to 1) and Instruments width (0 to 2, 1 as the song has them),
// which apply while `on`: farther, the voice is quieter and more of it is the room; wider, the rest of the song spreads
// further to each side. Off, or at 1 m, no room and width 1, the song is as the angle alone leaves it. Any thread.
void SGSingEngineSetSpatial(SGSingEngine *engine, bool on, float meters, float room, float width);

// Where spatial voice holds the voice, for Sing.x and the Spatial voice page's preview alike: off a front that
// follows where the head points, 95% of the way there `frontSeconds` after it turned (Back in front, 20 s unless set), so the voice drifts back ahead of a head that stays turned and the
// attitude's own drift never carries it off. A gap in the motion over 1 s (headphones out and in again), or a
// front cleared to zero, starts it over where the head points.
typedef struct {
    bool hasFront;
    double front, last;
} SGSpatialFront;

// The voice's angle off the head in radians to its right, from a head motion's yaw and timestamp (seconds).
static inline double SGSpatialVoiceAngle(SGSpatialFront *f, double yaw, double time, double frontSeconds) {
    // CoreMotion's yaw turns counterclockwise seen from above, so it grows as the head turns left, and the voice
    // held ahead is then off to the head's right. Not yet heard on AirPods; flip it here.
    const double yawToRight = 1;
    const double motionGap = 1;
    double since = time - f->last;
    if (!f->hasFront || since < 0 || since > motionGap) f->front = yaw;
    // Three time constants: e^-3 of the turn, 5%, is left after frontSeconds.
    else f->front = remainder(f->front + remainder(yaw - f->front, 2 * M_PI) * (1 - exp(-3 * since / frontSeconds)), 2 * M_PI);
    f->hasFront = true;
    f->last = time;
    return yawToRight * remainder(yaw - f->front, 2 * M_PI);
}
// The vocals fell short for longer than the engine's budget: it plays the song as it is, the lead kept as it is,
// until switched off and on again.
bool SGSingEngineGaveUp(SGSingEngine *engine);
// A faster copy of the model is loading: the slower one falling behind meanwhile is not yet a reason to give up, so no
// budget is spent, and it starts full once the hold is let go (the faster copy in, or failed).
void SGSingEngineHoldBudget(SGSingEngine *engine, bool held);
// Holds the worker (a hot phone, or Sing resting at As sung): what plays is dry, the lead kept as it is.
void SGSingEngineSetPaused(SGSingEngine *engine, bool paused);
// The most the lead may hold, in seconds, separating or not (INFINITY for no limit): one held past it drains down to it
// at half speed, every frame played. Sing.x reads nothing ahead of a seek or a skip Spotify has not carried out yet
// (0), and on the queue's last track nothing past a second before its end, where Spotify's output may stop.
void SGSingEngineSetLeadCap(SGSingEngine *engine, double seconds);
// Drops the sound held ahead, at the next render; the lead reads as dropped from now.
void SGSingEngineFlush(SGSingEngine *engine);
// Seconds of Spotify's sound held ahead of what plays, as the render thread left it.
double SGSingEngineLead(SGSingEngine *engine);
// The seconds to take off a position Spotify's player counted at `when` (CFAbsoluteTime) and has run on by the
// time since: the lead held then, less what was dropped since; negative when more was dropped than was held.
double SGSingEngineLeadAt(SGSingEngine *engine, CFAbsoluteTime when);

OSStatus SGSingEngineRender(SGSingEngine *engine, UInt32 frames, float *left, float *right, SGSingPull pull, void *context);

typedef struct {
    double lead, targetLead;   // seconds
    double ready;              // seconds of the held sound separated, ahead of what plays (negative when behind)
    double averageMS;          // a window's separation, a running average
    double voiceAngle;         // radians, as last set
    unsigned long long windows, failures, dryFrames;   // dry: frames played unseparated while separating
    double dropped;            // seconds of held sound never played (flushes), since the engine was made
    unsigned long long aheadStops;   // renders whose reading ahead stopped where Spotify's mixer had no sound yet
    unsigned long long written, played;   // frames pulled from Spotify's mixer and played, since the engine was made
    bool mixing;               // the vocals are turned down now (the hysteresis in SGSingEngine.m)
    double budgetSpent;        // seconds short of vocals since they were last in, of the 8 s it gives up after
    bool budgetHeld;           // none spent while a faster copy loads (SGSingEngineHoldBudget)
} SGSingEngineStats;
SGSingEngineStats SGSingEngineReadStats(SGSingEngine *engine);
// The loudness (RMS) of the separated vocals and of the rest of the song, per tenth of a second, for the `count`
// tenths up to what plays now, oldest first; 0 where none was separated. For the Sing page to draw: a few atomic
// reads, the measuring done on the worker.
void SGSingEngineReadLevels(SGSingEngine *engine, float *vocals, float *rest, int count);
// The model's last error, nil when its last window went through.
NSString *SGSingEngineError(SGSingEngine *engine);
