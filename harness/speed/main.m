// Spotify's audio chain (AudioUnitDriver2: a converter fed by a render callback, a mixer, RemoteIO, wired
// with MakeConnection and slices of 4096) rebuilt with real units in the simulator, with
// PlayerSpeedPitch.x's rebinding, render callback and SPTPlayerState hook running on it for real. The
// converter's callback stands in for Spotify's decoder and counts what it hands over, so the log shows
// how fast the song is drained at each speed, and how far a mock player state's position drifts from it.
//
//     THEOS=$HOME/theos ./build.sh && xcrun simctl install booted build/SpeedHarness.app
//     xcrun simctl launch --console-pty booted com.vojta.speedharness [rate]
//
// `rate` hands the running output a 48 kHz format halfway through the 1.5x step, with no new start, while its
// mixer stays at 44.1 kHz: the mod's format listener gives Spotify's own connection back rather than play the
// mixer fast through its callback.
//
// `two` runs a second chain at 48 kHz beside the first at 44.1, both started, the way Spotify runs a chain per
// sample rate, and checks that each decoder is drained at its own rate and only the music's output (the one
// started last, or the one with sound) takes the speed, through a stop, a start, a silent decoder, a disposed
// mixer and a disposed output. Each check prints PASS or FAIL.
//
// Last, the sleep timer's gain: 0.25, then 1 again. A notify of the harness's own, added after the mod's,
// reads the loudest sample the speaker unit played over the last second of each step: 0.05 at 1, 0.0125
// at 0.25.
#import <UIKit/UIKit.h>
#import <AudioToolbox/AudioToolbox.h>
#import <AVFoundation/AVFoundation.h>
#import <stdatomic.h>

double SGPlayerSpeed(void);
void SGSetPlayerSpeed(double speed);
void SGSetPlayerPitch(float semitones);
BOOL SGPlayerSpeedAllowed(void);
void SGPlayerSetGain(float gain);

static const double kRate = 44100;
static atomic_uint_fast64_t sg_decoded;
// The loudest float sample the output played since the main thread last zeroed it, as its bits.
static atomic_uint sg_peakBits;

static OSStatus metered(void *refCon, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *timestamp, UInt32 bus,
                        UInt32 frames, AudioBufferList *data) {
    if (!(*flags & kAudioUnitRenderAction_PostRender) || bus != 0) return noErr;
    uint32_t bits = atomic_load(&sg_peakBits);
    float peak;
    memcpy(&peak, &bits, sizeof peak);
    for (UInt32 b = 0; b < data->mNumberBuffers; b++) {
        const float *samples = data->mBuffers[b].mData;
        for (UInt32 i = 0; samples && i < data->mBuffers[b].mDataByteSize / sizeof(float); i++) peak = fmaxf(peak, fabsf(samples[i]));
    }
    memcpy(&bits, &peak, sizeof bits);
    atomic_store(&sg_peakBits, bits);
    return noErr;
}

AudioUnit SGPlayerMusicOutput(void);

// A chain of its own, for `two`: its decoder's count, and whether it hands over silence.
typedef struct {
    double rate;
    atomic_uint_fast64_t decoded;
    atomic_bool mute;
    AudioUnit converter, mixer, output;
    atomic_uint_fast64_t played;   // frames its output rendered, at the hardware's rate
    double hardwareRate;
    uint64_t lastDecoded, lastPlayed;
} Chain;

// Spotify's player state as far as -position goes (disassembly of -[SPTPlayerState position]).
@interface SPTPlayerState : NSObject
@property (nonatomic) double positionAsOfTimestamp;
@property (nonatomic, strong) NSDate *timestamp;
@end

@implementation SPTPlayerState
// The hooked -position (SpeedPitch.x) also reads which track and whether paused: one track, playing.
- (id)track {
    return nil;
}
- (BOOL)isPaused {
    return NO;
}
- (double)playbackSpeed {
    return 1;
}
- (double)position {
    return MAX(0, self.positionAsOfTimestamp - self.timestamp.timeIntervalSinceNow * [self playbackSpeed]);
}
@end

// Shared/Player/PlayerState.x: no player state for SGSetPlayerSpeed to start the mod's clock from (the mock has
// no track), so the speed checks see the units alone.
SPTPlayerState *SGPlayerState(void) { return nil; }

static OSStatus decoder(void *refCon, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *timestamp, UInt32 bus,
                        UInt32 frames, AudioBufferList *data) {
    uint64_t start = atomic_fetch_add(&sg_decoded, frames);
    for (UInt32 i = 0; i < frames; i++) {
        float value = 0.05f * sinf(2 * M_PI * 440 * (start + i) / kRate);
        for (UInt32 b = 0; b < data->mNumberBuffers; b++) ((float *)data->mBuffers[b].mData)[i] = value;
    }
    return noErr;
}

static OSStatus chainDecoder(void *refCon, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *timestamp, UInt32 bus,
                             UInt32 frames, AudioBufferList *data) {
    Chain *chain = refCon;
    uint64_t start = atomic_fetch_add(&chain->decoded, frames);
    BOOL mute = atomic_load(&chain->mute);
    for (UInt32 i = 0; i < frames; i++) {
        float value = mute ? 0 : 0.05f * sinf(2 * M_PI * 440 * (start + i) / chain->rate);
        for (UInt32 b = 0; b < data->mNumberBuffers; b++) ((float *)data->mBuffers[b].mData)[i] = value;
    }
    return noErr;
}

static OSStatus counted(void *refCon, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *timestamp, UInt32 bus,
                        UInt32 frames, AudioBufferList *data) {
    Chain *chain = refCon;
    if ((*flags & kAudioUnitRenderAction_PostRender) && bus == 0) atomic_fetch_add(&chain->played, frames);
    return noErr;
}

// Voice search's kind of unit: Spotify's own callback, silence here.
static OSStatus silentInput(void *refCon, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *timestamp, UInt32 bus,
                            UInt32 frames, AudioBufferList *data) {
    for (UInt32 b = 0; b < data->mNumberBuffers; b++) memset(data->mBuffers[b].mData, 0, data->mBuffers[b].mDataByteSize);
    *flags |= kAudioUnitRenderAction_OutputIsSilence;
    return noErr;
}

static AudioUnit make(OSType type, OSType subType) {
    AudioComponentDescription description = {type, subType, kAudioUnitManufacturer_Apple, 0, 0};
    AudioUnit unit = NULL;
    AudioComponentInstanceNew(AudioComponentFindNext(NULL, &description), &unit);
    return unit;
}

static void check(OSStatus status, const char *what) {
    if (status) NSLog(@"[harness] %s failed: %d", what, (int)status);
}

@interface SGRHarnessDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation SGRHarnessDelegate {
    SPTPlayerState *_state;
    AudioUnit _output;
    uint64_t _lastDecoded;
    NSTimeInterval _lastAt, _startedAt;
}

- (void)startChain {
    [AVAudioSession.sharedInstance setCategory:AVAudioSessionCategoryPlayback error:nil];
    [AVAudioSession.sharedInstance setActive:YES error:nil];
    AudioUnit converter = make(kAudioUnitType_FormatConverter, kAudioUnitSubType_AUConverter);
    AudioUnit mixer = make(kAudioUnitType_Mixer, kAudioUnitSubType_MultiChannelMixer);
    AudioUnit output = make(kAudioUnitType_Output, kAudioUnitSubType_RemoteIO);
    AURenderCallbackStruct callback = {decoder, NULL};
    check(AudioUnitSetProperty(converter, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback, sizeof callback), "callback");
    AudioUnitConnection toMixer = {converter, 0, 0}, toOutput = {mixer, 0, 0};
    check(AudioUnitSetProperty(mixer, kAudioUnitProperty_MakeConnection, kAudioUnitScope_Input, 0, &toMixer, sizeof toMixer), "connect mixer");
    check(AudioUnitSetProperty(output, kAudioUnitProperty_MakeConnection, kAudioUnitScope_Input, 0, &toOutput, sizeof toOutput), "connect output");
    AudioStreamBasicDescription format = {kRate, kAudioFormatLinearPCM, kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved, 4, 1, 4, 2, 32, 0};
    check(AudioUnitSetProperty(converter, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format, sizeof format), "converter in");
    check(AudioUnitSetProperty(converter, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &format, sizeof format), "converter out");
    check(AudioUnitSetProperty(mixer, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format, sizeof format), "mixer in");
    check(AudioUnitSetProperty(mixer, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &format, sizeof format), "mixer out");
    check(AudioUnitSetProperty(output, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format, sizeof format), "output in");
    UInt32 slice = 4096;
    AudioUnit units[] = {converter, mixer, output};
    for (int i = 0; i < 3; i++) check(AudioUnitSetProperty(units[i], kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &slice, sizeof slice), "slice");
    for (int i = 0; i < 3; i++) check(AudioUnitInitialize(units[i]), "initialize");
    check(AudioOutputUnitStart(output), "start");
    check(AudioUnitAddRenderNotify(output, metered, NULL), "meter");
    _output = output;
}

// Spotify's side of the output at another rate while it runs, the way a file at another rate may bring one.
- (void)changeRate {
    AudioStreamBasicDescription format = {48000, kAudioFormatLinearPCM, kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved, 4, 1, 4, 2, 32, 0};
    OSStatus status = AudioUnitSetProperty(_output, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format, sizeof format);
    NSLog(@"[harness] output's input set to 48000 Hz while running: status %d", (int)status);
}

// Spotify's chain at `rate`, wired and started the way AudioUnitDriver2 does it.
static void startChain(Chain *chain) {
    chain->converter = make(kAudioUnitType_FormatConverter, kAudioUnitSubType_AUConverter);
    chain->mixer = make(kAudioUnitType_Mixer, kAudioUnitSubType_MultiChannelMixer);
    chain->output = make(kAudioUnitType_Output, kAudioUnitSubType_RemoteIO);
    AURenderCallbackStruct callback = {chainDecoder, chain};
    check(AudioUnitSetProperty(chain->converter, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback, sizeof callback), "callback");
    AudioStreamBasicDescription format = {chain->rate, kAudioFormatLinearPCM, kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved, 4, 1, 4, 2, 32, 0};
    AudioUnit units[] = {chain->converter, chain->mixer, chain->output};
    for (int i = 0; i < 3; i++) {
        if (i < 2) check(AudioUnitSetProperty(units[i], kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format, sizeof format), "format in");
        if (i < 2) check(AudioUnitSetProperty(units[i], kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &format, sizeof format), "format out");
    }
    check(AudioUnitSetProperty(chain->output, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format, sizeof format), "output in");
    AudioUnitConnection toMixer = {chain->converter, 0, 0}, toOutput = {chain->mixer, 0, 0};
    check(AudioUnitSetProperty(chain->mixer, kAudioUnitProperty_MakeConnection, kAudioUnitScope_Input, 0, &toMixer, sizeof toMixer), "connect mixer");
    check(AudioUnitSetProperty(chain->output, kAudioUnitProperty_MakeConnection, kAudioUnitScope_Input, 0, &toOutput, sizeof toOutput), "connect output");
    UInt32 slice = 4096;
    for (int i = 0; i < 3; i++) check(AudioUnitSetProperty(units[i], kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &slice, sizeof slice), "slice");
    for (int i = 0; i < 3; i++) check(AudioUnitInitialize(units[i]), "initialize");
    AudioStreamBasicDescription hardware = {0};
    UInt32 size = sizeof hardware;
    check(AudioUnitGetProperty(chain->output, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &hardware, &size), "hardware format");
    chain->hardwareRate = hardware.mSampleRate;
    check(AudioUnitAddRenderNotify(chain->output, counted, chain), "count");
    check(AudioOutputUnitStart(chain->output), "start");
}

static Chain sg_a = {.rate = 44100}, sg_b = {.rate = 48000};
static int sg_failures;

// Each chain's decoder drained since the last call, in seconds of its own rate for each second its output
// played (the simulator's output stalls now and then, so the wall clock is no measure), against what is
// expected; 0 for a chain that should not be drained at all, or whose output does not play.
static void expect(NSString *what, double wantA, double wantB) {
    Chain *chains[] = {&sg_a, &sg_b};
    double want[] = {wantA, wantB}, got[2];
    for (int i = 0; i < 2; i++) {
        uint64_t decoded = atomic_load(&chains[i]->decoded), played = atomic_load(&chains[i]->played);
        double playedSeconds = chains[i]->hardwareRate > 0 ? (played - chains[i]->lastPlayed) / chains[i]->hardwareRate : 0;
        got[i] = playedSeconds > 0.5 ? (decoded - chains[i]->lastDecoded) / chains[i]->rate / playedSeconds : 0;
        chains[i]->lastDecoded = decoded;
        chains[i]->lastPlayed = played;
    }
    if (wantA < 0) return;
    BOOL pass = fabs(got[0] - wantA) < 0.06 && fabs(got[1] - wantB) < 0.06;
    if (!pass) sg_failures++;
    AudioUnit musicUnit = SGPlayerMusicOutput();
    NSLog(@"[harness] %@ %-44@ 44.1 kHz chain drained %.2fx (want %.2f), 48 kHz chain %.2fx (want %.2f); the processors on %@", pass ? @"PASS" : @"FAIL",
          what, got[0], want[0], got[1], want[1], musicUnit == sg_a.output ? @"44.1" : musicUnit == sg_b.output ? @"48" : @"neither");
}

- (void)report:(NSString *)what {
    NSTimeInterval now = CACurrentMediaTime();
    uint64_t decoded = atomic_load(&sg_decoded);
    double content = decoded / kRate;
    uint32_t bits = atomic_load(&sg_peakBits);
    float peak;
    memcpy(&peak, &bits, sizeof peak);
    NSLog(@"[harness] %-28@ decoder drained %.2fx over the last %.1f s; content %.2f s, state position %.2f s (off %+.0f ms), state speed %.2f, peak %.4f",
          what, (decoded - _lastDecoded) / kRate / (now - _lastAt), now - _lastAt, content, _state.position,
          (_state.position - content) * 1000, [_state playbackSpeed], peak);
    _lastDecoded = decoded;
    _lastAt = now;
}

// The player reporting: a state whose position is what the decoder has handed over, as of now.
- (void)playerReports {
    _state = [SPTPlayerState new];
    _state.positionAsOfTimestamp = atomic_load(&sg_decoded) / kRate;
    _state.timestamp = [NSDate date];
}

- (void)after:(double)seconds do:(void (^)(void))block {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)), dispatch_get_main_queue(), block);
}

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [UIViewController new];
    [self.window makeKeyAndVisible];
    if ([NSProcessInfo.processInfo.arguments containsObject:@"two"]) {
        [self runTwo];
        return YES;
    }
    [self startChain];
    NSLog(@"[harness] speed allowed: %d", SGPlayerSpeedAllowed());
    [self after:1 do:^{ [self playerReports]; self->_lastDecoded = atomic_load(&sg_decoded); self->_lastAt = CACurrentMediaTime(); }];
    NSArray *script = @[
        @[@3, @"normal", @1, @0],
        @[@6, @"1.5x", @1.5, @0],
        @[@9, @"1.5x, +3 st", @1.5, @3],
        @[@12, @"0.75x", @0.75, @3],
        @[@15, @"back to normal", @1, @0],
        @[@18, @"normal, unit out", @1, @0],
        @[@21, @"gain 0.25", @1, @0, @0.25],
        @[@24, @"gain back to 1", @1, @0, @1],
    ];
    __block NSString *label = @"normal";
    for (NSArray *step in script) {
        [self after:[step[0] doubleValue] do:^{
            [self report:label];
            label = step[1];
            SGSetPlayerSpeed([step[2] doubleValue]);
            SGSetPlayerPitch([step[3] floatValue]);
            if (step.count > 4) SGPlayerSetGain([step[4] floatValue]);
        }];
        // The peak is read over the step's last second, past the gain's half second ramp.
        [self after:[step[0] doubleValue] + 2 do:^{ atomic_store(&sg_peakBits, 0); }];
        // A report mid step, the way Spotify's player reports now and then.
        [self after:[step[0] doubleValue] + 1.5 do:^{ [self playerReports]; }];
    }
    if ([NSProcessInfo.processInfo.arguments containsObject:@"rate"]) [self after:7.5 do:^{ [self changeRate]; }];
    [self after:27 do:^{
        [self report:label];
        exit(0);
    }];
    return YES;
}

// Two chains at once. Every step is measured over 2 s, from half a second after the change it makes; a silent
// output gives the processors up within 1.5 s, so that step waits 2 s first.
- (void)runTwo {
    [AVAudioSession.sharedInstance setCategory:AVAudioSessionCategoryPlayback error:nil];
    [AVAudioSession.sharedInstance setActive:YES error:nil];
    startChain(&sg_a);
    __block double at = 0.5;
    __block double settle = 0.5;
    void (^step)(NSString *, double, double, void (^)(void)) = ^(NSString *what, double wantA, double wantB, void (^change)(void)) {
        [self after:at do:^{
            if (change) change();
        }];
        [self after:at + settle do:^{
            expect(@"(settling)", -1, -1);
        }];
        [self after:at + settle + 2 do:^{
            expect(what, wantA, wantB);
        }];
        at += settle + 2;
        settle = 0.5;
    };
    // The second chain is the music's once started; the first plays on at its own rate.
    step(@"one chain, normal", 1, 0, nil);
    step(@"48 kHz chain started too, normal", 1, 1, ^{ startChain(&sg_b); });
    step(@"1.5x: only the 48 kHz chain", 1, 1.5, ^{ SGSetPlayerSpeed(1.5); });
    step(@"48 kHz stopped: 1.5x moves to 44.1", 1.5, 0, ^{ check(AudioOutputUnitStop(sg_b.output), "stop"); });
    step(@"48 kHz started again: back to it", 1, 1.5, ^{ check(AudioOutputUnitStart(sg_b.output), "start"); });
    // A unit Spotify feeds through a render callback of its own (voice search) never takes the processors from a
    // connected one.
    step(@"a callback-fed unit started: 1.5x stays", 1, 1.5, ^{
        AudioUnit voice = make(kAudioUnitType_Output, kAudioUnitSubType_RemoteIO);
        AURenderCallbackStruct callback = {silentInput, NULL};
        check(AudioUnitSetProperty(voice, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback, sizeof callback), "voice callback");
        check(AudioUnitInitialize(voice), "voice initialize");
        check(AudioOutputUnitStart(voice), "voice start");
    });
    settle = 2;
    step(@"48 kHz silent for a while: 1.5x to 44.1", 1.5, 1, ^{ atomic_store(&sg_b.mute, true); });
    step(@"48 kHz sound again: stays on 44.1", 1.5, 1, ^{ atomic_store(&sg_b.mute, false); });
    step(@"48 kHz mixer disposed: 44.1 unchanged", 1.5, 0, ^{ check(AudioComponentInstanceDispose(sg_b.mixer), "dispose mixer"); });
    step(@"44.1 stopped, 48 output disposed", 0, 0, ^{
        check(AudioOutputUnitStop(sg_a.output), "stop");
        check(AudioComponentInstanceDispose(sg_b.output), "dispose output");
    });
    settle = 1;   // the simulator's IO takes a moment to come back once nothing runs
    step(@"44.1 started again, still 1.5x", 1.5, 0, ^{ check(AudioOutputUnitStart(sg_a.output), "start"); });
    step(@"back to normal", 1, 0, ^{ SGSetPlayerSpeed(1); });
    [self after:at + 0.5 do:^{
        NSLog(@"[harness] two chains: %d failures", sg_failures);
        exit(sg_failures ? 1 : 0);
    }];
}

@end

__attribute__((constructor(101))) static void sgr_harnessDefaults(void) {
    [NSUserDefaults.standardUserDefaults setBool:YES forKey:@"spotifyglass.redesign"];
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(SGRHarnessDelegate.class));
    }
}
