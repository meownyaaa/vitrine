#import <os/lock.h>
#import <pthread.h>
#import <stdatomic.h>
#import "SGSingEngine.h"
#import "SGSingSeparator.h"
#import "Shared/AudioEffects/SGDSPEffects.h"

enum {
    kRing = kSGSingRate * 10,        // what the rings hold: the longest lead and a window, with room to spare
    kLongestLead = kSGSingRate * 6,
    kShortestLead = kSGSingRate * 5 / 2,
};
// The lead asked for over a window: this many times the model's average time, and this much more. Just before each
// window lands, the vocals separated ahead of what plays are down to half the model's time and the spare, which must
// stay above the reserve with room for a window that comes in late.
static const double kLeadPerModelTime = 1.5, kLeadSpare = 0.75;
// The vocals come in and go out over this long, so the switch and the lead filling do not click.
static const float kFadeSeconds = 0.1f;
// Changes in what Spotify's clock runs ahead of what plays, kept for SGSingEngineLeadAt: a fill or two's worth, as
// it is read soon after each report; and the moments last asked about, kept for as long as their report stands.
enum { kHistory = 1024, kAsked = 8 };
// Hysteresis, so a model about as fast as the song fades the vocals out once rather than at every window: the mix
// goes back to the song as it is when the vocals separated ahead of what plays fall under the reserve (more than
// the fade), and comes back to them only with a full hop separated ahead, which the lead (a window, 1.5 times the
// model's time and the spare) reaches just as each window lands. Time spent so after the vocals were first in comes
// out of a budget, renewed by that long with the vocals in throughout; spent, the engine gives up (SGSingEngineGaveUp).
// While a faster copy is on its way (SGSingEngineHoldBudget) none is spent, and the budget starts full once it is in.
static const uint64_t kReserve = kSGSingRate * 12 / 100;
static const uint64_t kReturn = kSGSingEngineHop;
static const uint64_t kBudget = kSGSingRate * 8;
// The loudness the Sing page draws: per tenth of a second of the song, kept for the last kLevelSlots of them.
enum { kLevelBlock = kSGSingRate / 10, kLevelSlots = 128 };
// How often the worker looks for a new window; and after this many looks at a `written` that has not moved (0.5 s,
// longer than any IO buffer: Spotify paused, or its decoder stalled) it sleeps until a render moves it.
static const useconds_t kPoll = 10000;
static const unsigned kStillPolls = 500000 / kPoll;
// Spatial voice: at 90 degrees the pan goes this far of the way to one ear, the far ear hears the voice this
// many frames late (0.65 ms, sound's way around a head) and through a one-pole low-pass of this coefficient
// (about 3 kHz); the angle glides to where it is set over this long.
static const float kVoiceWidth = 0.5f;
static const float kVoiceDelay = 0.00065f * kSGSingRate;
static const float kVoiceShadow = 0.35f;
static const float kVoiceGlideSeconds = 0.05f;
// Distance and Room, with Spatial voice on: the voice is at its own level at kNearest and quieter farther off, by the
// square root of the distance (gentler than a free field's 1/d, so the far end still sings); the room's share grows from
// half of Room's at the nearest to all of it at the farthest. The room is AUReverb2's medium room, wet only, fed the
// voice's middle so its tail stays put as the head turns, and let ring kRoomTailSeconds after the voice stops reaching it.
static const float kNearest = 1, kFarthest = 6.5f;
static const int kRoomPreset = 2;
static const float kRoomTailSeconds = 4;

struct SGSingEngine {
    float *left, *right, *vocalsLeft, *vocalsRight;   // rings, a frame at position p at p % kRing

    // Positions in frames of Spotify's sound since the engine was made: what was pulled, what was played,
    // and up to where the vocals are in.
    _Atomic uint64_t written, played, ready;
    _Atomic uint64_t base;        // where the worker starts over, at the latest flush
    atomic_uint generation;       // counts the flushes
    atomic_bool flushAsked, on, paused, hasSeparator;
    atomic_bool mixing, gaveUp;   // the render's, for the stats and Sing.x
    atomic_bool freshBudget;      // switched on again: the render starts the budget over
    atomic_bool budgetHeld;       // a faster copy is on its way: falling behind spends no budget
    _Atomic uint64_t spent;       // the render's `recovering`, for the stats
    _Atomic uint64_t dropped;     // frames of held sound never played: flushes
    _Atomic uint64_t aheadStops;  // renders whose reading ahead stopped where Spotify's mixer had no sound yet
    // What Spotify's clock had counted past what plays, at each render that changed it (written less played,
    // plus dropped: a flush leaves it as it was), with when; `historyCount` counts the entries made.
    struct { _Atomic double at; _Atomic uint64_t ahead; } history[kHistory];
    _Atomic uint64_t historyCount;
    struct { double when; uint64_t ahead; } asked[kAsked];
    unsigned askedNext;
    atomic_uint levelBits, targetLead, voiceAngleBits;
    atomic_bool spatial;                // Spatial voice on: Distance and Room apply
    atomic_uint distanceBits, roomBits; // meters, and 0 to 1
    atomic_uint widthBits;              // the instruments' stereo width, 1 as the song has it
    SGDSPReverb *room;                  // NULL where AUReverb2 is missing (the Mac): no room
    float *send[2];                     // the room's input and output, kSGDSPEffectMaxFrames each
    float directGain, sendGain, width;  // the render's, gliding to what Distance, Room and width ask for
    uint64_t roomTail;                  // frames the room still rings after the voice stops reaching it
    atomic_uint leadCap;          // frames the lead may hold at most, separating or not (SGSingEngineSetLeadCap)

    // The render thread's own.
    bool running;                 // the rings are in use: Sing is on, or the lead is not given back yet
    float amount, vocalsGain, otherGain;
    bool established;             // the vocals have been in since the rings last started over or the work resumed
    bool wasWorking;              // the last render's: working resumed (after a heat hold, a new model) starts over
    uint64_t recovering, steady;  // frames short of vocals since they were in, and frames in with them since
    float voiceAngle;             // where the voice is now, gliding to voiceAngleBits
    float shadowLeft, shadowRight;   // the low-passes' last outputs, an ear each
    uint64_t ahead;               // the last entry made in `history`

    // The worker's.
    pthread_t worker;
    atomic_bool alive;
    dispatch_semaphore_t wake;    // slept on while off, held or without a model; the setters and Destroy signal it
    atomic_bool sleeping;         // asleep on `wake` until `written` moves: the one render that moves it signals
    os_unfair_lock lock;          // the separator, the error and `asked`
    void *separator;              // retained
    NSString *error;
    float *window[2], *vocals[2];

    _Atomic uint64_t windows, failures, dryFrames, averageMicroseconds;

    // The worker's loudness of the vocals and the rest per block, the block's number written last; and the next
    // block it measures.
    struct { _Atomic uint64_t block; atomic_uint vocals, rest; } levels[kLevelSlots];
    uint64_t nextLevel;
};

static float loadFloat(atomic_uint *slot) {
    uint32_t bits = atomic_load_explicit(slot, memory_order_relaxed);
    float value;
    memcpy(&value, &bits, sizeof value);
    return value;
}

static void storeFloat(atomic_uint *slot, float value) {
    uint32_t bits;
    memcpy(&bits, &value, sizeof bits);
    atomic_store(slot, bits);
}

#pragma mark - the render thread

// Starts the rings over where the mixer is now.
static void startOver(SGSingEngine *engine) {
    // The room's tail is the old place's: it does not ring on over the new one.
    if (engine->room) SGDSPReverbReset(engine->room);
    engine->roomTail = 0;
    uint64_t written = atomic_load_explicit(&engine->written, memory_order_relaxed);
    atomic_fetch_add(&engine->dropped, written - atomic_load_explicit(&engine->played, memory_order_relaxed));
    atomic_store(&engine->played, written);
    atomic_store(&engine->base, written);
    atomic_fetch_add(&engine->generation, 1);
    engine->amount = 0;
    engine->established = false;
    atomic_store(&engine->mixing, false);
}

// `count` frames from the mixer into the rings at `at`, in up to two runs where the ring wraps. With `kept`, it stops
// at the first part the mixer marks silent and sets the frames before it.
static OSStatus pullInto(SGSingEngine *engine, uint64_t at, uint64_t count, SGSingPull pull, void *context, uint64_t *kept) {
    if (kept) *kept = 0;
    while (count) {
        uint64_t index = at % kRing, run = MIN(count, kRing - index);
        UInt32 sounding = (UInt32)run;
        OSStatus status = pull(context, (UInt32)run, engine->left + index, engine->right + index, kept ? &sounding : NULL);
        if (status != noErr) return status;
        if (kept) *kept += sounding;
        if (sounding < run) return noErr;
        at += run;
        count -= run;
    }
    return noErr;
}

// The gains for a level: the vocals up to 1, then the rest down to nothing at 2.
static void gainsFor(float level, float *vocals, float *other) {
    level = fmaxf(0, fminf(level, 2));
    *vocals = fminf(level, 1);
    *other = level <= 1 ? 1 : 2 - level;
}

// Where the voice is put at an angle: each ear's gain, delay in frames and low-pass coefficient (1 passes).
typedef struct {
    float gain[2], delay[2], shadow[2];
} Placement;

static Placement placementAt(float angle) {
    if (angle == 0) return (Placement){{1, 1}, {0, 0}, {1, 1}};
    // From -1 (the left ear) to 1 (the right): behind sounds as the front does, as it does to two ears.
    float side = sinf(angle), far = fabsf(side);
    // Equal power, with straight ahead at 1 each: the gains' squares always add up to 2.
    float pan = (kVoiceWidth * side + 1) * (float)M_PI_4;
    float gainLeft = (float)M_SQRT2 * cosf(pan), gainRight = (float)M_SQRT2 * sinf(pan);
    float delay = far * kVoiceDelay, shadow = 1 - far * (1 - kVoiceShadow);
    return side > 0 ? (Placement){{gainLeft, gainRight}, {delay, 0}, {shadow, 1}}
                    : (Placement){{gainLeft, gainRight}, {0, delay}, {1, shadow}};
}

// The vocals' middle at `position`.
static inline float middleAt(SGSingEngine *engine, uint64_t position) {
    uint64_t index = position % kRing;
    return (engine->vocalsLeft[index] + engine->vocalsRight[index]) * 0.5f;
}

// The vocals' middle `delay` frames before `position`, between two frames; at once where that is before the
// rings started over at `base`, whose frames are a different moment's.
static inline float middleBefore(SGSingEngine *engine, uint64_t position, uint64_t base, float delay) {
    uint64_t whole = (uint64_t)delay;
    float part = delay - (float)whole;
    if (position < base + whole + 1) return middleAt(engine, position);
    return middleAt(engine, position - whole) * (1 - part) + middleAt(engine, position - whole - 1) * part;
}

OSStatus SGSingEngineRender(SGSingEngine *engine, UInt32 frames, float *left, float *right, SGSingPull pull, void *context) {
    // Larger than any slice an output asks for, and more than the rings leave room for: passed as it is.
    if (frames > kSGSingRate / 4) return pull(context, frames, left, right, NULL);
    bool on = atomic_load_explicit(&engine->on, memory_order_relaxed);
    if (!engine->running) {
        if (!on) return pull(context, frames, left, right, NULL);
        engine->running = true;
        startOver(engine);
        atomic_store(&engine->flushAsked, false);
    }
    if (atomic_exchange_explicit(&engine->flushAsked, false, memory_order_relaxed)) startOver(engine);
    if (atomic_exchange_explicit(&engine->freshBudget, false, memory_order_relaxed)) engine->recovering = engine->steady = 0;

    uint64_t written = atomic_load_explicit(&engine->written, memory_order_relaxed);
    uint64_t played = atomic_load_explicit(&engine->played, memory_order_relaxed);
    uint64_t held = written - played;
    bool working = on && !atomic_load_explicit(&engine->paused, memory_order_relaxed)
                   && atomic_load_explicit(&engine->hasSeparator, memory_order_relaxed)
                   && !atomic_load_explicit(&engine->gaveUp, memory_order_relaxed);
    // Separating: up to twice what plays while the lead fills, half while a shorter target is reached. Not separating
    // (off, held, given up, no model), what plays: the lead held plays on as it is, nothing skipped, until a flush
    // (Spotify seeks, skips, stops, or Sing.x seeks it back to what is heard at a pause), and none is built. Either way
    // never more than the cap, which it drains down to at half speed, every frame still played.
    int64_t cap = atomic_load_explicit(&engine->leadCap, memory_order_relaxed);
    int64_t target = atomic_load_explicit(&engine->targetLead, memory_order_relaxed);
    bool capped = cap < target;
    int64_t want = MIN(working ? target : (int64_t)held, cap) - (int64_t)held;
    int64_t count = (int64_t)frames + MAX(-(int64_t)frames / 2, MIN(want, (int64_t)frames));
    count = MAX(count, (int64_t)frames - (int64_t)held);
    count = MIN(count, (int64_t)(kRing - kSGSingWindowFrames) - (int64_t)held);
    if (count > 0) {
        // What this render plays and the lead does not hold is pulled whatever it is. The rest reads ahead, and a part of
        // it the mixer marks silent is sound Spotify has not decoded yet: it is not taken into the lead, and reading ahead
        // stops there until the next render.
        uint64_t need = (uint64_t)MIN(count, MAX(0, (int64_t)frames - (int64_t)held)), ahead = 0;
        OSStatus status = pullInto(engine, written, need, pull, context, NULL);
        if (status == noErr && (uint64_t)count > need) {
            status = pullInto(engine, written + need, (uint64_t)count - need, pull, context, &ahead);
            if (ahead < (uint64_t)count - need) atomic_fetch_add_explicit(&engine->aheadStops, 1, memory_order_relaxed);
        }
        if (status != noErr) {
            memset(left, 0, frames * sizeof(float));
            memset(right, 0, frames * sizeof(float));
            return status;
        }
        written += need + ahead;
        // Sequentially consistent, with the worker's store of `sleeping` and its re-read of `written`: one of the two
        // threads sees the other's write, so a worker going to sleep as this moves `written` is never left asleep.
        atomic_store(&engine->written, written);
        if (need + ahead && atomic_load(&engine->sleeping) && atomic_exchange(&engine->sleeping, false)) dispatch_semaphore_signal(engine->wake);
    }

    uint64_t ready = atomic_load_explicit(&engine->ready, memory_order_acquire);
    int64_t ahead = (int64_t)ready - (int64_t)played;
    // Work that resumes (cooled down, a model loaded again) has no vocals ahead yet: that is a start, not falling behind.
    if (working && !engine->wasWorking) {
        engine->established = false;
        engine->recovering = engine->steady = 0;
    }
    engine->wasWorking = working;
    bool mixing = atomic_load_explicit(&engine->mixing, memory_order_relaxed);
    if (mixing && (!working || ahead < (int64_t)(kReserve + frames))) {
        mixing = false;
        engine->steady = 0;
    } else if (!mixing && working && ahead >= (int64_t)kReturn) {
        mixing = engine->established = true;
    }
    if (mixing) {
        engine->steady += frames;
        if (engine->steady >= kBudget) engine->recovering = 0;
    } else if (capped || atomic_load_explicit(&engine->budgetHeld, memory_order_relaxed)) {
        // Short of vocals for the cap, not the model: none of the budget is spent.
        engine->recovering = 0;
    } else if (working && engine->established) {
        engine->recovering += frames;
        if (engine->recovering >= kBudget) atomic_store_explicit(&engine->gaveUp, true, memory_order_relaxed);
    }
    atomic_store_explicit(&engine->mixing, mixing, memory_order_relaxed);
    atomic_store_explicit(&engine->spent, engine->recovering, memory_order_relaxed);
    float vocalsTo, otherTo;
    gainsFor(loadFloat(&engine->levelBits), &vocalsTo, &otherTo);
    float vocalsStep = (vocalsTo - engine->vocalsGain) / frames, otherStep = (otherTo - engine->otherGain) / frames;
    float directTo = 1, sendTo = 0, widthTo = 1;
    if (atomic_load_explicit(&engine->spatial, memory_order_relaxed)) {
        widthTo = loadFloat(&engine->widthBits);
        float distance = fmaxf(kNearest, loadFloat(&engine->distanceBits)), room = loadFloat(&engine->roomBits);
        directTo = sqrtf(kNearest / distance);
        sendTo = engine->room ? room * (0.5f + 0.5f * (distance - kNearest) / (kFarthest - kNearest)) : 0;
    }
    float directStep = (directTo - engine->directGain) / frames, sendStep = (sendTo - engine->sendGain) / frames;
    float widthStep = (widthTo - engine->width) / frames;
    bool sending = engine->room && (sendTo > 0 || engine->sendGain > 0 || engine->roomTail > 0);
    float fade = 1.0f / (kFadeSeconds * kSGSingRate), amountTo = on && mixing ? 1 : 0;

    // The voice's angle glides the short way round toward the one set, and lands on it; within the buffer
    // each ear's gain, delay and low-pass move in a straight line from where the angle was to where it is.
    float angleTo = loadFloat(&engine->voiceAngleBits), angleFrom = engine->voiceAngle;
    float turn = remainderf(angleTo - angleFrom, 2 * (float)M_PI);
    float angle = fabsf(turn) < 1e-4f ? angleTo : remainderf(angleFrom + turn * (1 - expf(-(float)frames / (kVoiceGlideSeconds * kSGSingRate))), 2 * (float)M_PI);
    engine->voiceAngle = angle;
    bool placed = angleFrom != 0 || angle != 0;
    Placement from = placementAt(angleFrom), to = placementAt(angle);
    uint64_t base = atomic_load_explicit(&engine->base, memory_order_relaxed);

    uint64_t dry = 0;
    for (UInt32 i = 0; i < frames; i++) {
        uint64_t position = played + i, index = position % kRing;
        float x = engine->left[index], y = engine->right[index];
        engine->vocalsGain += vocalsStep;
        engine->otherGain += otherStep;
        engine->directGain += directStep;
        engine->sendGain += sendStep;
        engine->width += widthStep;
        float voiceSend = 0;
        if (position < ready) {
            engine->amount += fmaxf(-fade, fminf(amountTo - engine->amount, fade));
            float a = engine->amount, otherGain = engine->otherGain - 1;
            float v = engine->vocalsLeft[index], w = engine->vocalsRight[index];
            // The vocals where they are to sound: as separated straight ahead.
            float placedLeft = v, placedRight = w;
            if (placed) {
                float t = (float)(i + 1) / (float)frames, sides = (v - w) * 0.5f;
                float leftIn = middleBefore(engine, position, base, from.delay[0] + (to.delay[0] - from.delay[0]) * t);
                float rightIn = middleBefore(engine, position, base, from.delay[1] + (to.delay[1] - from.delay[1]) * t);
                engine->shadowLeft += (from.shadow[0] + (to.shadow[0] - from.shadow[0]) * t) * (leftIn - engine->shadowLeft);
                engine->shadowRight += (from.shadow[1] + (to.shadow[1] - from.shadow[1]) * t) * (rightIn - engine->shadowRight);
                placedLeft = (from.gain[0] + (to.gain[0] - from.gain[0]) * t) * engine->shadowLeft + sides;
                placedRight = (from.gain[1] + (to.gain[1] - from.gain[1]) * t) * engine->shadowRight - sides;
            } else {
                engine->shadowLeft = engine->shadowRight = (v + w) * 0.5f;
            }
            float voice = engine->vocalsGain * engine->directGain;
            voiceSend = a * engine->vocalsGain * engine->sendGain * (v + w) * 0.5f;
            // Instruments width: the rest's side (half its left less its right) scaled, its middle kept.
            float side = (engine->width - 1) * ((x - v) - (y - w)) * 0.5f * engine->otherGain;
            left[i] = fmaxf(-1, fminf(x + a * (voice * placedLeft - v + otherGain * (x - v) + side), 1));
            right[i] = fmaxf(-1, fminf(y + a * (voice * placedRight - w + otherGain * (y - w) - side), 1));
        } else {
            engine->amount = 0;
            left[i] = x;
            right[i] = y;
            dry += working;
        }
        if (sending) engine->send[0][i % kSGDSPEffectMaxFrames] = voiceSend;
        // The room's next stretch, once its input is full or the buffer ends: rung through and added.
        if (sending && ((i + 1) % kSGDSPEffectMaxFrames == 0 || i + 1 == frames)) {
            UInt32 count = i % kSGDSPEffectMaxFrames + 1, first = i + 1 - count;
            memcpy(engine->send[1], engine->send[0], count * sizeof(float));
            SGDSPReverbRun(engine->room, engine->send[0], engine->send[1], count);
            for (UInt32 j = 0; j < count; j++) {
                left[first + j] = fmaxf(-1, fminf(left[first + j] + engine->send[0][j], 1));
                right[first + j] = fmaxf(-1, fminf(right[first + j] + engine->send[1][j], 1));
            }
        }
    }
    if (sending) engine->roomTail = sendTo > 0 || engine->sendGain > 1e-4f ? (uint64_t)(kRoomTailSeconds * kSGSingRate)
                                                                          : engine->roomTail > frames ? engine->roomTail - frames : 0;
    engine->directGain = directTo;
    engine->sendGain = sendTo;
    engine->width = widthTo;
    engine->vocalsGain = vocalsTo;
    engine->otherGain = otherTo;
    played += frames;
    atomic_store_explicit(&engine->played, played, memory_order_release);
    if (dry) atomic_fetch_add_explicit(&engine->dryFrames, dry, memory_order_relaxed);
    uint64_t counted = written - played + atomic_load_explicit(&engine->dropped, memory_order_relaxed);
    if (counted != engine->ahead) {
        engine->ahead = counted;
        uint64_t n = atomic_load_explicit(&engine->historyCount, memory_order_relaxed);
        atomic_store_explicit(&engine->history[n % kHistory].at, CFAbsoluteTimeGetCurrent(), memory_order_relaxed);
        atomic_store_explicit(&engine->history[n % kHistory].ahead, counted, memory_order_relaxed);
        atomic_store_explicit(&engine->historyCount, n + 1, memory_order_release);
    }
    // The lead given back and the vocals faded out: a straight pull from the next render on.
    if (!on && played == written) engine->running = false;
    return noErr;
}

#pragma mark - the worker

static void setError(SGSingEngine *engine, NSString *error) {
    os_unfair_lock_lock(&engine->lock);
    engine->error = error;
    os_unfair_lock_unlock(&engine->lock);
}

static SGSingSeparator *currentSeparator(SGSingEngine *engine) {
    os_unfair_lock_lock(&engine->lock);
    SGSingSeparator *separator = (__bridge SGSingSeparator *)engine->separator;
    os_unfair_lock_unlock(&engine->lock);
    return separator;
}

// The lead that keeps the vocals in ahead of what plays: a window, then the model's time and some spare.
static void updateTarget(SGSingEngine *engine, double modelSeconds) {
    double lead = kSGSingWindowFrames + (modelSeconds * kLeadPerModelTime + kLeadSpare) * kSGSingRate;
    atomic_store(&engine->targetLead, (unsigned)fmax(kShortestLead, fmin(lead, kLongestLead)));
}

// The loudness (RMS of both channels) of the vocals and of the rest, per block not measured yet from `start`, where
// the window just separated begins, to `ready`; read from the worker's own copy of the window and its vocals, as the
// render may have pulled new sound over the rings there while the model ran.
static void measureLevels(SGSingEngine *engine, uint64_t start, uint64_t ready) {
    engine->nextLevel = MAX(engine->nextLevel, (start + kLevelBlock - 1) / kLevelBlock);
    for (; (engine->nextLevel + 1) * kLevelBlock <= ready; engine->nextLevel++) {
        double vocals = 0, rest = 0;
        for (uint64_t p = engine->nextLevel * kLevelBlock; p < (engine->nextLevel + 1) * kLevelBlock; p++) {
            uint64_t i = p - start;
            float v = engine->vocals[0][i], w = engine->vocals[1][i], x = engine->window[0][i] - v, y = engine->window[1][i] - w;
            vocals += v * v + w * w;
            rest += x * x + y * y;
        }
        __typeof__(engine->levels[0]) *slot = &engine->levels[engine->nextLevel % kLevelSlots];
        storeFloat(&slot->vocals, (float)sqrt(vocals / (2 * kLevelBlock)));
        storeFloat(&slot->rest, (float)sqrt(rest / (2 * kLevelBlock)));
        atomic_store_explicit(&slot->block, engine->nextLevel + 1, memory_order_release);   // + 1: 0 is never written
    }
}

static void *work(void *argument) {
    SGSingEngine *engine = argument;
    pthread_setname_np("spotifyglass.sing");
    unsigned generation = UINT_MAX, still = 0;
    uint64_t start = 0, previousEnd = 0, lastWritten = 0;
    while (atomic_load(&engine->alive)) {
        unsigned now = atomic_load(&engine->generation);
        if (now != generation) {
            generation = now;
            start = previousEnd = atomic_load(&engine->base);
            engine->nextLevel = (start + kLevelBlock - 1) / kLevelBlock;
            atomic_store_explicit(&engine->ready, start, memory_order_release);
        }
        SGSingSeparator *separator = currentSeparator(engine);
        uint64_t written = atomic_load_explicit(&engine->written, memory_order_acquire);
        uint64_t played = atomic_load_explicit(&engine->played, memory_order_relaxed);
        if (!separator || !atomic_load(&engine->on) || atomic_load(&engine->paused)) {
            dispatch_semaphore_wait(engine->wake, DISPATCH_TIME_FOREVER);
            continue;
        }
        if (written < start + kSGSingWindowFrames) {
            if (written != lastWritten) {
                lastWritten = written;
                still = 0;
            } else if (++still >= kStillPolls) {
                // Woken with `written` as it was (a setter, a stray signal), it comes straight back here and sleeps on.
                atomic_store(&engine->sleeping, true);
                if (atomic_load(&engine->written) == written) dispatch_semaphore_wait(engine->wake, DISPATCH_TIME_FOREVER);
                atomic_store(&engine->sleeping, false);
                continue;
            }
            usleep(kPoll);
            continue;
        }
        // Fallen behind what plays: the next window starts where the sound is, with nothing to crossfade with.
        if (start < played) start = previousEnd = played;
        if (written < start + kSGSingWindowFrames) continue;
        for (int c = 0; c < 2; c++) {
            const float *ring = c ? engine->right : engine->left;
            uint64_t index = start % kRing, run = MIN((uint64_t)kSGSingWindowFrames, kRing - index);
            memcpy(engine->window[c], ring + index, run * sizeof(float));
            memcpy(engine->window[c] + run, ring, (kSGSingWindowFrames - run) * sizeof(float));
        }
        CFAbsoluteTime began = CFAbsoluteTimeGetCurrent();
        NSError *error;
        BOOL separated;
        @autoreleasepool {
            separated = [separator separateLeft:engine->window[0] right:engine->window[1] vocalsLeft:engine->vocals[0]
                                    vocalsRight:engine->vocals[1] error:&error];
        }
        double took = CFAbsoluteTimeGetCurrent() - began;
        if (!separated) {
            atomic_fetch_add(&engine->failures, 1);
            setError(engine, error.localizedDescription ?: @"The model failed");
            usleep(1000000);
            continue;
        }
        setError(engine, nil);
        // A value the model got wrong is silence, not a click or a channel gone quiet.
        for (int c = 0; c < 2; c++) {
            for (int i = 0; i < kSGSingWindowFrames; i++) {
                if (!isfinite(engine->vocals[c][i])) engine->vocals[c][i] = 0;
            }
        }
        uint64_t windows = atomic_fetch_add(&engine->windows, 1);
        uint64_t average = atomic_load(&engine->averageMicroseconds);
        average = windows ? (uint64_t)(average * 0.8 + took * 1e6 * 0.2) : (uint64_t)(took * 1e6);
        atomic_store(&engine->averageMicroseconds, average);
        updateTarget(engine, average / 1e6);
        if (atomic_load(&engine->generation) != generation) continue;   // flushed meanwhile: the window is gone
        // The rings past `ready` are the worker's: the render thread reads only below it.
        for (uint64_t i = 0; i < kSGSingWindowFrames; i++) {
            uint64_t position = start + i, index = position % kRing;
            float a = position < previousEnd ? (float)(position - start) / (float)(previousEnd - start) : 1;
            engine->vocalsLeft[index] = engine->vocalsLeft[index] * (1 - a) + engine->vocals[0][i] * a;
            engine->vocalsRight[index] = engine->vocalsRight[index] * (1 - a) + engine->vocals[1][i] * a;
        }
        if (atomic_load(&engine->generation) == generation) atomic_store_explicit(&engine->ready, start + kSGSingEngineHop, memory_order_release);
        measureLevels(engine, start, start + kSGSingEngineHop);
        previousEnd = start + kSGSingWindowFrames;
        start += kSGSingEngineHop;
    }
    return NULL;
}

#pragma mark - any thread

SGSingEngine *SGSingEngineCreate(void) {
    SGSingEngine *engine = calloc(1, sizeof *engine);
    if (!engine) return NULL;
    engine->lock = OS_UNFAIR_LOCK_INIT;
    engine->wake = dispatch_semaphore_create(0);
    engine->left = calloc(kRing, sizeof(float));
    engine->right = calloc(kRing, sizeof(float));
    engine->vocalsLeft = calloc(kRing, sizeof(float));
    engine->vocalsRight = calloc(kRing, sizeof(float));
    for (int c = 0; c < 2; c++) {
        engine->window[c] = calloc(kSGSingWindowFrames, sizeof(float));
        engine->vocals[c] = calloc(kSGSingWindowFrames, sizeof(float));
    }
    engine->vocalsGain = engine->otherGain = engine->directGain = engine->width = 1;
    storeFloat(&engine->widthBits, 1);
    storeFloat(&engine->levelBits, 1);
    storeFloat(&engine->distanceBits, kNearest);
    engine->room = SGDSPReverbCreate(kSGSingRate, kRoomPreset, 0);
    if (engine->room) {
        SGDSPReverbSetSend(engine->room, kRoomPreset);
        engine->send[0] = calloc(kSGDSPEffectMaxFrames, sizeof(float));
        engine->send[1] = calloc(kSGDSPEffectMaxFrames, sizeof(float));
        if (!engine->send[0] || !engine->send[1]) {
            SGDSPReverbFree(engine->room);
            engine->room = NULL;
        }
    }
    updateTarget(engine, 1);
    atomic_store(&engine->leadCap, UINT_MAX);
    atomic_store(&engine->alive, true);
    if (!engine->left || !engine->right || !engine->vocalsLeft || !engine->vocalsRight || !engine->window[0] || !engine->window[1]
        || !engine->vocals[0] || !engine->vocals[1] || pthread_create(&engine->worker, NULL, work, engine) != 0) {
        atomic_store(&engine->alive, false);
        engine->worker = NULL;
        SGSingEngineDestroy(engine);
        return NULL;
    }
    return engine;
}

void SGSingEngineDestroy(SGSingEngine *engine) {
    if (!engine) return;
    atomic_store(&engine->alive, false);
    if (engine->worker) {
        dispatch_semaphore_signal(engine->wake);
        pthread_join(engine->worker, NULL);
    }
    engine->wake = nil;
    if (engine->separator) CFRelease(engine->separator);
    engine->error = nil;
    for (int c = 0; c < 2; c++) {
        free(engine->window[c]);
        free(engine->vocals[c]);
    }
    free(engine->left);
    free(engine->right);
    free(engine->vocalsLeft);
    free(engine->vocalsRight);
    SGDSPReverbFree(engine->room);
    free(engine->send[0]);
    free(engine->send[1]);
    free(engine);
}

void SGSingEngineSetSeparator(SGSingEngine *engine, SGSingSeparator *separator) {
    void *retained = separator ? (void *)CFBridgingRetain(separator) : NULL;
    os_unfair_lock_lock(&engine->lock);
    void *old = engine->separator;
    engine->separator = retained;
    os_unfair_lock_unlock(&engine->lock);
    atomic_store(&engine->hasSeparator, retained != NULL);
    if ((old != NULL) != (retained != NULL)) dispatch_semaphore_signal(engine->wake);
    // Released outside the lock; the worker holds its own reference while it runs one.
    if (old) CFRelease(old);
}

void SGSingEngineSetOn(SGSingEngine *engine, bool on) {
    bool was = atomic_exchange(&engine->on, on);
    // Switched on again, it tries again with a full budget.
    if (on && !was) {
        atomic_store(&engine->freshBudget, true);
        atomic_store(&engine->gaveUp, false);
    }
    if (was != on) dispatch_semaphore_signal(engine->wake);
}

void SGSingEngineHoldBudget(SGSingEngine *engine, bool held) {
    atomic_store(&engine->budgetHeld, held);
}

bool SGSingEngineGaveUp(SGSingEngine *engine) {
    return atomic_load(&engine->gaveUp);
}

bool SGSingEngineOn(SGSingEngine *engine) {
    return atomic_load(&engine->on);
}

bool SGSingEngineSeparating(SGSingEngine *engine) {
    return engine && atomic_load(&engine->on) && !atomic_load(&engine->paused) && atomic_load(&engine->hasSeparator) && !atomic_load(&engine->gaveUp);
}

void SGSingEngineSetLevel(SGSingEngine *engine, float level) {
    storeFloat(&engine->levelBits, level);
}

void SGSingEngineSetSpatial(SGSingEngine *engine, bool on, float meters, float room, float width) {
    storeFloat(&engine->widthBits, isfinite(width) ? fminf(2, fmaxf(0, width)) : 1);
    storeFloat(&engine->distanceBits, isfinite(meters) ? fminf(kFarthest, fmaxf(kNearest, meters)) : kNearest);
    storeFloat(&engine->roomBits, isfinite(room) ? fminf(1, fmaxf(0, room)) : 0);
    atomic_store(&engine->spatial, on);
}

void SGSingEngineSetVoiceAngle(SGSingEngine *engine, float radians) {
    storeFloat(&engine->voiceAngleBits, isfinite(radians) ? remainderf(radians, 2 * (float)M_PI) : 0);
}

void SGSingEngineSetPaused(SGSingEngine *engine, bool paused) {
    if (atomic_exchange(&engine->paused, paused) != paused) dispatch_semaphore_signal(engine->wake);
}

void SGSingEngineSetLeadCap(SGSingEngine *engine, double seconds) {
    atomic_store(&engine->leadCap, seconds < (double)kRing / kSGSingRate ? (unsigned)fmax(0, seconds * kSGSingRate) : UINT_MAX);
}

void SGSingEngineFlush(SGSingEngine *engine) {
    atomic_store(&engine->flushAsked, true);
}

// The frames a flush asked for and not yet done will drop: the render may not run before it is read (Spotify paused).
static uint64_t pendingDrop(SGSingEngine *engine) {
    if (!atomic_load_explicit(&engine->flushAsked, memory_order_acquire)) return 0;
    uint64_t played = atomic_load_explicit(&engine->played, memory_order_acquire);
    uint64_t written = atomic_load_explicit(&engine->written, memory_order_acquire);
    return written > played ? written - played : 0;
}

double SGSingEngineLead(SGSingEngine *engine) {
    if (!engine || atomic_load_explicit(&engine->flushAsked, memory_order_acquire)) return 0;
    uint64_t played = atomic_load_explicit(&engine->played, memory_order_acquire);
    uint64_t written = atomic_load_explicit(&engine->written, memory_order_acquire);
    return written > played ? (double)(written - played) / kSGSingRate : 0;
}

double SGSingEngineLeadAt(SGSingEngine *engine, CFAbsoluteTime when) {
    if (!engine) return 0;
    os_unfair_lock_lock(&engine->lock);
    uint64_t ahead = 0;
    bool known = false;
    for (unsigned i = 0; i < kAsked && !known; i++) {
        if (engine->asked[i].when == when) ahead = engine->asked[i].ahead, known = true;
    }
    if (!known) {
        // What the clock had counted past what played at `when`: the last entry made by then, none before the first;
        // kept for the next time the same report is read.
        // ponytail: a `when` first asked about more than kHistory changes on reads the oldest kept; Sing.x reads the
        // player's state twice a second while on. The render would have to make kHistory entries while this reads
        // for one to tear.
        uint64_t n = atomic_load_explicit(&engine->historyCount, memory_order_acquire);
        for (uint64_t k = n; k > 0 && n - k < kHistory; k--) {
            __typeof__(engine->history[0]) *entry = &engine->history[(k - 1) % kHistory];
            ahead = atomic_load_explicit(&entry->ahead, memory_order_relaxed);
            if (atomic_load_explicit(&entry->at, memory_order_relaxed) <= when) break;
            if (k == 1) ahead = 0;
        }
        engine->asked[engine->askedNext++ % kAsked] = (__typeof__(engine->asked[0])){when, ahead};
    }
    os_unfair_lock_unlock(&engine->lock);
    // Less what was dropped since, which what plays skipped, a flush asked for with it.
    double dropped = (double)atomic_load_explicit(&engine->dropped, memory_order_relaxed) + (double)pendingDrop(engine);
    return ((double)ahead - dropped) / kSGSingRate;
}

SGSingEngineStats SGSingEngineReadStats(SGSingEngine *engine) {
    uint64_t played = atomic_load(&engine->played), ready = atomic_load(&engine->ready);
    return (SGSingEngineStats){
        .lead = SGSingEngineLead(engine),
        .targetLead = atomic_load(&engine->targetLead) / (double)kSGSingRate,
        .ready = ((double)ready - (double)played) / kSGSingRate,
        .averageMS = atomic_load(&engine->averageMicroseconds) / 1000.0,
        .voiceAngle = loadFloat(&engine->voiceAngleBits),
        .windows = atomic_load(&engine->windows),
        .failures = atomic_load(&engine->failures),
        .dryFrames = atomic_load(&engine->dryFrames),
        .dropped = atomic_load(&engine->dropped) / (double)kSGSingRate,
        .aheadStops = atomic_load(&engine->aheadStops),
        .written = atomic_load(&engine->written),
        .played = played,
        .mixing = atomic_load(&engine->mixing),
        .budgetSpent = atomic_load(&engine->spent) / (double)kSGSingRate,
        .budgetHeld = atomic_load(&engine->budgetHeld),
    };
}

NSString *SGSingEngineError(SGSingEngine *engine) {
    os_unfair_lock_lock(&engine->lock);
    NSString *error = engine->error;
    os_unfair_lock_unlock(&engine->lock);
    return error;
}

void SGSingEngineReadLevels(SGSingEngine *engine, float *vocals, float *rest, int count) {
    uint64_t now = atomic_load_explicit(&engine->played, memory_order_relaxed) / kLevelBlock;
    for (int k = 0; k < count; k++) {
        uint64_t block = now + k + 1 - (uint64_t)count;
        __typeof__(engine->levels[0]) *slot = &engine->levels[block % kLevelSlots];
        bool known = now + 1 >= (uint64_t)count - k && atomic_load_explicit(&slot->block, memory_order_acquire) == block + 1;
        vocals[k] = known ? loadFloat(&slot->vocals) : 0;
        rest[k] = known ? loadFloat(&slot->rest) : 0;
    }
}
