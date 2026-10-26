// Runs Sing's separator and engine (tweak/Sources/Shared/Sing) on the Mac the way the tweak runs them. Each
// check prints a line.
//
// - the STFT: a sine's peak bin at the size torch.stft gives it (amplitude times the window's sum over two), and
//   noise through the STFT and back unchanged;
// - the loader (SGSingLoader.m): the CPU copy loaded and warmed first, then the Neural Engine copy of the same model
//   beside it (`cpu` for none); a second want joining the load in flight; a load past its deadline abandoned, Sing
//   Failed, and a fresh load working while the abandoned one still runs, which is let go when it comes back; a purge
//   during a load dropping its result; the copies kept over a quick off and on, and dropped after the time kept; every
//   window on the Neural Engine copy once it is in; a window it fails done again on the CPU's, and it not used again;
//   a Neural Engine copy past its deadline leaving Sing Ready on the CPU's, and dropped, as Sing.x drops it;
// - the model: its shapes, the time a window takes, and a voice mixed over chords taken apart: the vocals it finds
//   against the voice, beside the mix's own score;
// - the engine: Spotify's mixer stood in for by the mix, pulled through SGSingEngineRender in IO buffers on a
//   thread that keeps real time, while the engine's worker separates ahead: the lead it builds, every frame
//   out in order, the vocals level applied, a flush, the lead kept and played on when Sing is switched off, and
//   no allocation on the render thread.
// - the lead, without the model: the lead reported is the frames pulled and not played, to the frame; held (the
//   heat, resting), given up or switched off, it is kept and played on as it is, nothing skipped and none built; a
//   flush (a pause, a seek) drops it at once; and the lead to take off a position Spotify counted at a moment is the
//   lead held then, less what was dropped since.
// - the lead's cap, without the model: a lead held past it drains at half speed, every frame played and none of the
//   budget spent, is built again once it is lifted, and drains with Sing switched off too.
// - reading ahead of a slow decoder, without the model: past what Spotify has decoded its mixer marks the sound silent;
//   that is never taken into the lead, reading ahead tries again at the next render, and a stall of the decoder plays
//   through on the lead, so what plays is the song with no gap, every frame in order.
// - a track reached as the last one ends, without the model: Spotify reports it a moment after its first frame is
//   handed over; its position (Sing.x's -position: Spotify's run on less the lead held at the report, never below 0)
//   starts where its first frame plays, not at the report.
// - spatial voice, without the model: a separator that hands the whole window back as vocals, so what plays is
//   the vocals placed. A tone straight ahead plays exactly as it came; at 90 degrees right the right ear has it
//   louder by the pan's 7.7 dB at the same power and the left ear late by the delay around the head; at 90
//   degrees left the same mirrored; back ahead it is exact again; and no turn clicks. Then the front the voice
//   is held off: a turned head has it off to the side, the front catching up over 20 s, across +-180 degrees
//   without a jump, and ahead again after a gap in the motion.
// - the Neural Engine copy loading, without the model: copies that take a set time a window; the CPU's falling behind
//   while the budget is held spends none of it, and the budget starts full once the copy is in or has failed. A Neural
//   Engine copy that only falls behind reads unfailed; one that fails a window reads failed after CPU windows too.
//
//     ./build.sh && build/sing <separator-ane.mlmodelc> <voice> <out dir> [ane|cpu]   (with or without the Neural Engine copy)
//     ./build.sh && build/sing spatial        (the checks without the model: the lead, spatial voice, falling behind)
#import <Foundation/Foundation.h>
#import <Accelerate/Accelerate.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CoreML/CoreML.h>
#import <pthread.h>
#import <stdatomic.h>
#import "Shared/Sing/SGSingLoader.h"
#import "Shared/Sing/SGSingSeparator.h"
#import "Shared/Sing/SGSingEngine.h"

static int sg_failures;
static NSString *sg_outDir;

#define CHECK(ok, ...) do { bool _ok = (ok); if (!_ok) sg_failures++; printf("%s ", _ok ? "  ok  " : "FAILED"); printf(__VA_ARGS__); printf("\n"); } while (0)

#pragma mark - audio

typedef struct {
    float *left, *right;
    size_t frames;
} Audio;

static Audio makeAudio(size_t frames) {
    return (Audio){calloc(frames, sizeof(float)), calloc(frames, sizeof(float)), frames};
}

static AudioStreamBasicDescription floatFormat(double rate, UInt32 channels, bool interleaved) {
    UInt32 bytes = interleaved ? 4 * channels : 4;
    return (AudioStreamBasicDescription){rate, kAudioFormatLinearPCM,
        kAudioFormatFlagsNativeFloatPacked | (interleaved ? 0 : kAudioFormatFlagIsNonInterleaved), bytes, 1, bytes, channels, 32, 0};
}

static Audio readAudio(NSString *path) {
    ExtAudioFileRef file;
    if (ExtAudioFileOpenURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], &file)) {
        printf("cannot open %s\n", path.UTF8String);
        exit(1);
    }
    AudioStreamBasicDescription format = floatFormat(kSGSingRate, 2, false);
    ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat, sizeof format, &format);
    Audio audio = makeAudio(kSGSingRate * 60);
    size_t done = 0;
    while (done < audio.frames) {
        UInt32 frames = (UInt32)MIN((size_t)8192, audio.frames - done);
        struct { AudioBufferList list; AudioBuffer second; } buffers = {{2, {{1, frames * 4, audio.left + done}}}, {1, frames * 4, audio.right + done}};
        if (ExtAudioFileRead(file, &frames, &buffers.list) || !frames) break;
        done += frames;
    }
    ExtAudioFileDispose(file);
    audio.frames = done;
    return audio;
}

static void writeWAV(NSString *name, Audio audio) {
    NSString *path = [sg_outDir stringByAppendingPathComponent:name];
    AudioStreamBasicDescription stored = floatFormat(kSGSingRate, 2, true);
    ExtAudioFileRef file;
    if (ExtAudioFileCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], kAudioFileWAVEType, &stored, NULL, kAudioFileFlags_EraseFile, &file)) return;
    AudioStreamBasicDescription client = floatFormat(kSGSingRate, 2, false);
    ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat, sizeof client, &client);
    struct { AudioBufferList list; AudioBuffer second; } buffers = {{2, {{1, (UInt32)audio.frames * 4, audio.left}}}, {1, (UInt32)audio.frames * 4, audio.right}};
    ExtAudioFileWrite(file, (UInt32)audio.frames, &buffers.list);
    ExtAudioFileDispose(file);
}

// Signal to error in dB of `estimate` against `truth` over [from, to).
static double snr(Audio truth, Audio estimate, size_t from, size_t to) {
    double signal = 0, noise = 0;
    for (size_t i = from; i < to; i++) {
        double l = truth.left[i], r = truth.right[i];
        double el = estimate.left[i] - l, er = estimate.right[i] - r;
        signal += l * l + r * r;
        noise += el * el + er * er;
    }
    return 10 * log10(signal / fmax(noise, 1e-20));
}

// Block chords with a decay, a note every half second, in a fifth of the stereo field each side.
static Audio chords(size_t frames) {
    Audio audio = makeAudio(frames);
    static const double roots[] = {130.81, 174.61, 196.00, 110.00};
    size_t beat = kSGSingRate / 2;
    for (size_t i = 0; i < frames; i++) {
        size_t bar = i / (beat * 4), within = i % beat;
        double root = roots[bar % 4], env = exp(-3.0 * within / beat), t = (double)i / kSGSingRate;
        double l = 0, r = 0;
        static const double ratios[] = {1, 1.26, 1.5, 2};
        for (int n = 0; n < 4; n++) {
            double f = root * ratios[n];
            double tone = sin(2 * M_PI * f * t) + 0.4 * sin(4 * M_PI * f * t) + 0.2 * sin(6 * M_PI * f * t);
            l += tone * (n % 2 ? 0.6 : 1.0);
            r += tone * (n % 2 ? 1.0 : 0.6);
        }
        audio.left[i] = (float)(0.06 * env * l);
        audio.right[i] = (float)(0.06 * env * r);
    }
    return audio;
}

#pragma mark - the STFT

static void checkSTFT(void) {
    SGSingSeparator *stft = [[SGSingSeparator alloc] initWithModel:nil];
    float *spectrum = calloc(kSGSingSpectrumFloats, sizeof(float));
    Audio in = makeAudio(kSGSingWindowFrames), out = makeAudio(kSGSingWindowFrames);
    int bin = 100;
    double frequency = bin * (double)kSGSingRate / kSGSingFFT;
    for (int i = 0; i < kSGSingWindowFrames; i++) {
        in.left[i] = (float)(0.5 * cos(2 * M_PI * frequency * i / kSGSingRate));
        in.right[i] = (float)(0.25 * cos(2 * M_PI * frequency * i / kSGSingRate));
    }
    [stft analyzeLeft:in.left right:in.right into:spectrum];
    int frame = 100;
    const float *left = spectrum + ((size_t)(2 * bin) * kSGSingSTFTFrames + frame) * 2;
    const float *right = spectrum + ((size_t)(2 * bin + 1) * kSGSingSTFTFrames + frame) * 2;
    double magnitude = hypot(left[0], left[1]), rightMagnitude = hypot(right[0], right[1]);
    // The periodic Hann window of 2048 sums to 1024, so a cosine of amplitude A peaks at A * 1024 / 2.
    CHECK(fabs(magnitude - 256) < 1 && fabs(rightMagnitude - 128) < 0.5, "a 0.5 cosine on bin %d peaks at %.2f (256 expected), 0.25 at %.2f in the right channel's slot",
          bin, magnitude, rightMagnitude);
    srand48(7);
    for (int i = 0; i < kSGSingWindowFrames; i++) {
        in.left[i] = (float)(drand48() * 2 - 1) * 0.5f;
        in.right[i] = (float)(0.3 * sin(i * 0.01) + (drand48() - 0.5) * 0.1);
    }
    [stft analyzeLeft:in.left right:in.right into:spectrum];
    [stft synthesize:spectrum left:out.left right:out.right];
    float worst = 0;
    for (int i = 0; i < kSGSingWindowFrames; i++) worst = fmaxf(worst, fmaxf(fabsf(out.left[i] - in.left[i]), fabsf(out.right[i] - in.right[i])));
    CHECK(worst < 1e-5, "noise through the STFT and back, edges included, within %.2g", worst);
    free(spectrum);
}

#pragma mark - the model

static double now(void) {
    return CFAbsoluteTimeGetCurrent();
}

// The offline pass the engine makes as it plays: windows a hop apart, their overlaps crossfaded.
static Audio separateOffline(SGSingSeparator *separator, Audio mix, double *slowest, double *average) {
    Audio vocals = makeAudio(mix.frames);
    Audio window = makeAudio(kSGSingWindowFrames);
    int count = 0;
    double total = 0;
    *slowest = 0;
    size_t previousEnd = 0;
    for (size_t start = 0; start + kSGSingWindowFrames <= mix.frames; start += kSGSingEngineHop) {
        double began = now();
        NSError *error;
        if (![separator separateLeft:mix.left + start right:mix.right + start vocalsLeft:window.left vocalsRight:window.right error:&error]) {
            printf("the model failed: %s\n", error.localizedDescription.UTF8String);
            exit(1);
        }
        double took = now() - began;
        total += took;
        *slowest = fmax(*slowest, took);
        count++;
        for (size_t i = 0; i < kSGSingWindowFrames; i++) {
            size_t p = start + i;
            float a = p < previousEnd ? (float)(p - start) / (float)(previousEnd - start) : 1;
            vocals.left[p] = vocals.left[p] * (1 - a) + window.left[i] * a;
            vocals.right[p] = vocals.right[p] * (1 - a) + window.right[i] * a;
        }
        previousEnd = start + kSGSingWindowFrames;
    }
    *average = total / count;
    return vocals;
}

// The main run loop turned until `done` holds or `seconds` pass; the loader hands back on the main queue.
static bool waitFor(double seconds, bool (^done)(void)) {
    double until = now() + seconds;
    while (!done() && now() < until) CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, true);
    return done();
}

// An MLModel whose every prediction fails, standing in for a Neural Engine copy whose window Core ML fails.
@interface SGFailingModel : MLModel
@end

@implementation SGFailingModel
- (id<MLFeatureProvider>)predictionFromFeatures:(id<MLFeatureProvider>)input error:(NSError **)error {
    if (error) *error = [NSError errorWithDomain:@"harness" code:1 userInfo:@{NSLocalizedDescriptionKey: @"refused, as Core ML can refuse a window"}];
    return nil;
}
@end

// The loader through its cases; hands back the separator it leaves Ready, both copies in it. With `neural`, the
// model's Neural Engine copy loads beside its CPU copy, as Sing.x has it on Automatic.
static SGSingSeparator *checkLoader(NSString *path, bool neural) {
    NSURL *url = [NSURL fileURLWithPath:path];
    SGSingLoaderSetForeground(YES);

    // A load past its deadline is abandoned and Sing is Failed; the mic off and on starts a fresh one at once,
    // which works while the first is still out, and the first is let go when it comes back.
    SGSingLoaderCPUDeadline = 0.2;
    SGSingLoaderWant(url, NO);
    waitFor(5, ^bool { return SGSingLoaderCurrentState() != SGSingLoaderLoading; });
    CHECK(SGSingLoaderCurrentState() == SGSingLoaderFailed && [SGSingLoaderError() containsString:@"did not load in"],
          "a load past its deadline is abandoned, and Sing is Failed: %s", SGSingLoaderError().UTF8String ?: "(no reason)");
    SGSingLoaderCPUDeadline = 120;
    SGSingLoaderWant(url, NO);
    CHECK(SGSingLoaderCurrentState() == SGSingLoaderFailed && SGSingLoaderAttempts() == 1, "Failed stays Failed until the mic is switched off and on");
    SGSingLoaderRelease();
    double began = now();
    SGSingLoaderWant(url, neural);
    SGSingLoaderWant(url, neural);
    CHECK(SGSingLoaderAttempts() == 2 && SGSingLoaderOutstanding() == 2, "off and on starts a fresh load beside the abandoned one, and a second want joins it (%u loads, %u out)",
          SGSingLoaderAttempts(), SGSingLoaderOutstanding());
    waitFor(300, ^bool { return SGSingLoaderCurrentState() != SGSingLoaderLoading; });
    double ready = now() - began;
    SGSingSeparator *separator = SGSingLoaderSeparator();
    CHECK(SGSingLoaderCurrentState() == SGSingLoaderReady && separator, "the CPU copy loads and warms in %.1f s, and Sing is Ready", ready);
    waitFor(300, ^bool { return SGSingLoaderOutstanding() == 0 && SGSingLoaderFastState() != SGSingFastLoading; });
    CHECK(SGSingLoaderSeparator() == separator, "the abandoned load came back and was let go: the separator is still the fresh load's");
    if (neural) {
        CHECK(SGSingLoaderFastState() == SGSingFastReady, "then the Neural Engine copy loads and warms beside it, %.1f s after the want (state %ld)",
              now() - began, (long)SGSingLoaderFastState());
    } else {
        CHECK(SGSingLoaderFastState() == SGSingFastNone, "and no Neural Engine copy loads (state %ld)", (long)SGSingLoaderFastState());
    }

    // Kept over a quick off and on, dropped once the time kept has passed.
    SGSingLoaderKeepSeconds = 1.5;
    SGSingLoaderRelease();
    waitFor(0.5, ^bool { return false; });
    SGSingLoaderWant(url, neural);
    waitFor(2, ^bool { return false; });
    CHECK(SGSingLoaderSeparator() == separator && SGSingLoaderAttempts() == 2 + neural,
          "switched off and on within the time kept, the copies are still there and nothing loads (%u loads)", SGSingLoaderAttempts());
    SGSingLoaderRelease();
    waitFor(3, ^bool { return SGSingLoaderCurrentState() == SGSingLoaderIdle; });
    CHECK(SGSingLoaderCurrentState() == SGSingLoaderIdle && !SGSingLoaderSeparator(), "left off past the time kept, the copies are dropped");

    // A purge during a load: what the load brings back is let go.
    SGSingLoaderWant(url, NO);
    SGSingLoaderPurge(@"the harness purges during the load");
    waitFor(300, ^bool { return SGSingLoaderOutstanding() == 0; });
    waitFor(0.5, ^bool { return false; });
    CHECK(SGSingLoaderCurrentState() == SGSingLoaderIdle && !SGSingLoaderSeparator(), "a load purged on its way is let go when it comes back");

    // Another model wanted (the update in place of the old one), here the same files through a link: the first model's
    // copies go at once and the other loads.
    SGSingLoaderKeepSeconds = 60;
    NSString *link = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"sing-other-%d.mlmodelc", getpid()]];
    [NSFileManager.defaultManager createSymbolicLinkAtPath:link withDestinationPath:path error:nil];
    SGSingLoaderWant(url, NO);
    waitFor(300, ^bool { return SGSingLoaderCurrentState() != SGSingLoaderLoading; });
    SGSingSeparator *first = SGSingLoaderSeparator();
    SGSingLoaderWant([NSURL fileURLWithPath:link], NO);
    CHECK(first && SGSingLoaderCurrentState() == SGSingLoaderLoading && !SGSingLoaderSeparator(), "another model wanted: the first's copies go at once and it loads");
    waitFor(300, ^bool { return SGSingLoaderCurrentState() != SGSingLoaderLoading; });
    CHECK(SGSingLoaderSeparator() && SGSingLoaderSeparator() != first && [SGSingLoaderURL().path isEqualToString:link], "and Sing is Ready on it");
    [NSFileManager.defaultManager removeItemAtPath:link error:nil];

    // The separator for the rest of the run, both copies in it, as Sing.x has it (the first model again).
    SGSingLoaderWant(url, neural);
    waitFor(300, ^bool { return SGSingLoaderCurrentState() != SGSingLoaderLoading && SGSingLoaderFastState() != SGSingFastLoading; });
    separator = SGSingLoaderSeparator();
    CHECK(separator != nil && [SGSingLoaderURL() isEqual:url], "loaded again for the rest of the run");
    return separator;
}

// Each window on the faster copy while it is in; a failed one done again on the CPU's, which keeps the rest until
// another faster copy is handed over.
static void checkCopies(SGSingSeparator *separator, Audio mix, bool hasFast) {
    float *vl = calloc(kSGSingWindowFrames, sizeof(float)), *vr = calloc(kSGSingWindowFrames, sizeof(float));
    NSError *error;
    SGSingSeparatorStats before = [separator stats];
    if (hasFast) {
        [separator separateLeft:mix.left right:mix.right vocalsLeft:vl vocalsRight:vr error:&error];
        SGSingSeparatorStats stats = [separator stats];
        CHECK(stats.fast && stats.windows[1] == before.windows[1] + 1, "a window goes to the Neural Engine copy");
        before = stats;
    }
    // The fast copy swapped for one that fails, then for a working one.
    SGFailingModel *failing = [SGFailingModel alloc];
    [separator setFastModel:failing named:@"failing"];
    BOOL ok = [separator separateLeft:mix.left right:mix.right vocalsLeft:vl vocalsRight:vr error:&error];
    SGSingSeparatorStats stats = [separator stats];
    CHECK(ok && stats.fallbacks == before.fallbacks + 1 && stats.windows[0] == before.windows[0] + 1 && !stats.fast && stats.fastFailed,
          "a window the faster copy fails is done again on the CPU's (%s)", ok ? "separated" : error.localizedDescription.UTF8String);
    [separator separateLeft:mix.left right:mix.right vocalsLeft:vl vocalsRight:vr error:&error];
    stats = [separator stats];
    CHECK(stats.fallbacks == before.fallbacks + 1 && stats.windows[0] == before.windows[0] + 2, "and the failed copy is not tried again");
    [separator setFastModel:nil named:nil];
    free(vl);
    free(vr);
}

// The model's Neural Engine copy against its CPU copy on the same window: the vocals they find alike. The CPU's window
// is had with the Neural Engine copy dropped, which is then loaded again (from Core ML's cache).
static void checkNeuralMatches(SGSingSeparator *separator, Audio mix, NSString *path) {
    size_t at = (size_t)kSGSingRate * 5;
    Audio cpu = makeAudio(kSGSingWindowFrames), neural = makeAudio(kSGSingWindowFrames);
    NSError *error;
    SGSingLoaderDropFast(nil);
    BOOL cpuOK = [separator separateLeft:mix.left + at right:mix.right + at vocalsLeft:cpu.left vocalsRight:cpu.right error:&error];
    bool onCPU = ![separator stats].fast;
    SGSingLoaderWant([NSURL fileURLWithPath:path], YES);
    waitFor(300, ^bool { return SGSingLoaderFastState() != SGSingFastLoading; });
    double began = now();
    BOOL neuralOK = [separator separateLeft:mix.left + at right:mix.right + at vocalsLeft:neural.left vocalsRight:neural.right error:&error];
    double took = now() - began;
    bool onNeural = [separator stats].fast;
    double alike = snr(cpu, neural, kSGSingWindowFrames / 8, kSGSingWindowFrames * 7 / 8);
    CHECK(cpuOK && neuralOK && onCPU && onNeural && alike > 25,
          "on the same window the Neural Engine copy (%.0f ms) finds the vocals the CPU copy does, %.1f dB apart", took * 1000, alike);
}

// The Neural Engine copy past its deadline: it times out and the CPU's carries on; asked for no Neural Engine copy then,
// as Sing.x does once it has failed, the windows stay on the CPU's.
static void checkNeuralFallback(NSString *path) {
    NSURL *url = [NSURL fileURLWithPath:path];
    SGSingSeparator *separator = SGSingLoaderSeparator();
    SGSingLoaderWant(url, NO);
    CHECK(SGSingLoaderFastState() == SGSingFastNone && ![separator stats].fast, "asked for none, the Neural Engine copy is dropped");
    SGSingLoaderNeuralDeadline = 0.001;
    SGSingLoaderWant(url, YES);
    waitFor(60, ^bool { return SGSingLoaderFastState() != SGSingFastLoading; });
    CHECK(SGSingLoaderFastState() == SGSingFastTimedOut && SGSingLoaderSeparator() == separator && SGSingLoaderCurrentState() == SGSingLoaderReady,
          "the Neural Engine copy past its deadline times out, and Sing stays Ready on the CPU's");
    SGSingLoaderNeuralDeadline = 600;
    SGSingLoaderWant(url, NO);
    float *vl = calloc(kSGSingWindowFrames, sizeof(float)), *vr = calloc(kSGSingWindowFrames, sizeof(float));
    float *silence = calloc(kSGSingWindowFrames, sizeof(float));
    NSError *error;
    BOOL ok = [separator separateLeft:silence right:silence vocalsLeft:vl vocalsRight:vr error:&error];
    CHECK(ok && ![separator stats].fast && SGSingLoaderFastState() == SGSingFastNone, "then asked for none, nothing loads and the windows go to the CPU's");
    waitFor(300, ^bool { return SGSingLoaderOutstanding() == 0; });
    free(vl);
    free(vr);
    free(silence);
}

// Which device Core ML means to run each operation on, counted, where the OS can tell.
static void describePlan(NSString *path, bool neural) {
    if (@available(macOS 14.4, *)) {
        MLModelConfiguration *configuration = [MLModelConfiguration new];
        configuration.computeUnits = neural ? MLComputeUnitsCPUAndNeuralEngine : MLComputeUnitsCPUOnly;
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        [MLComputePlan loadContentsOfURL:[NSURL fileURLWithPath:path] configuration:configuration completionHandler:^(MLComputePlan *plan, NSError *error) {
            NSMutableDictionary<NSString *, NSNumber *> *counts = [NSMutableDictionary dictionary];
            MLModelStructureProgramFunction *main = plan.modelStructure.program.functions[@"main"];
            for (MLModelStructureProgramOperation *operation in main.block.operations) {
                MLComputePlanDeviceUsage *usage = [plan computeDeviceUsageForMLProgramOperation:operation];
                if (!usage) continue;
                id<MLComputeDeviceProtocol> device = usage.preferredComputeDevice;
                NSString *name = [device isKindOfClass:MLNeuralEngineComputeDevice.class] ? @"Neural Engine"
                               : [device isKindOfClass:MLGPUComputeDevice.class] ? @"GPU" : @"CPU";
                counts[name] = @(counts[name].intValue + 1);
            }
            printf("  info  the plan on %s: %s\n", neural ? "the CPU and Neural Engine" : "the CPU", counts.description.UTF8String);
            dispatch_semaphore_signal(done);
        }];
        dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
    }
}

#pragma mark - the engine

typedef struct {
    Audio source;
    size_t pulled;
    bool limited;      // Spotify has decoded only up to `decoded`
    size_t decoded;
} Source;

// As Spotify's mixer: past what is decoded the sound is marked silent and does not move on, and a pull asked to stop
// there (`sounding`) does.
static OSStatus pullSource(void *context, UInt32 frames, float *left, float *right, UInt32 *sounding) {
    Source *source = context;
    size_t has = !source->limited ? frames : source->decoded > source->pulled ? MIN(frames, source->decoded - source->pulled) : 0;
    if (sounding) *sounding = (UInt32)has;
    for (UInt32 i = 0; i < frames; i++) {
        size_t at = source->pulled + i;
        left[i] = i < has && at < source->source.frames ? source->source.left[at] : 0;
        right[i] = i < has && at < source->source.frames ? source->source.right[at] : 0;
    }
    source->pulled += has;
    return noErr;
}

typedef void(malloc_logger_t)(uint32_t type, uintptr_t arg1, uintptr_t arg2, uintptr_t arg3, uintptr_t result, uint32_t skip);
extern malloc_logger_t *malloc_logger;
static pthread_t sg_renderThread;
static atomic_bool sg_inRender;
static atomic_uint sg_renderAllocations;

static void countAllocation(uint32_t type, uintptr_t a, uintptr_t b, uintptr_t c, uintptr_t result, uint32_t skip) {
    if (atomic_load_explicit(&sg_inRender, memory_order_relaxed) && pthread_equal(pthread_self(), sg_renderThread)) {
        atomic_fetch_add_explicit(&sg_renderAllocations, 1, memory_order_relaxed);
    }
}

// Plays `mix` through the engine in real time, in buffers of `slice`; `script` is called once a buffer with the
// seconds played, for the test to switch things.
static Audio play(SGSingEngine *engine, Audio mix, Source *source, UInt32 slice, double seconds, void (^script)(double played)) {
    Audio out = makeAudio((size_t)(seconds * kSGSingRate));
    sg_renderThread = pthread_self();
    double began = now();
    for (size_t done = 0; done + slice <= out.frames; done += slice) {
        script((double)done / kSGSingRate);
        atomic_store(&sg_inRender, true);
        SGSingEngineRender(engine, slice, out.left + done, out.right + done, pullSource, source);
        atomic_store(&sg_inRender, false);
        double due = began + (double)(done + slice) / kSGSingRate;
        double wait = due - now();
        if (wait > 0) usleep((useconds_t)(wait * 1e6));
    }
    return out;
}

static void checkEngine(SGSingSeparator *separator, Audio mix, Audio voice, Audio offlineVocals) {
    SGSingEngine *engine = SGSingEngineCreate();
    SGSingEngineSetSeparator(engine, separator);
    SGSingEngineSetLevel(engine, 0);
    Source source = {mix, 0};
    // On from the first buffer, so the engine's windows fall where the offline pass's do; off at 17 s.
    SGSingEngineSetOn(engine, true);
    __block double leadAtOn = 0, leadAtOff = 0, leadMax = 0;
    malloc_logger = countAllocation;
    Audio out = play(engine, mix, &source, 1024, fmin(mix.frames / (double)kSGSingRate, 28), ^(double played) {
        double lead = SGSingEngineLead(engine);
        leadMax = fmax(leadMax, lead);
        if (played >= 12 && leadAtOn == 0) leadAtOn = lead;
        if (played >= 17 && SGSingEngineOn(engine)) SGSingEngineSetOn(engine, false);
        if (played >= 27) leadAtOff = lead;
    });
    malloc_logger = NULL;
    CHECK(atomic_load(&sg_renderAllocations) == 0, "no allocation on the render thread (%u)", atomic_load(&sg_renderAllocations));
    SGSingEngineStats stats = SGSingEngineReadStats(engine);
    printf("  info  lead at 12 s %.2f s (at most %.2f s, target %.2f s), %llu windows at %.0f ms average, %llu frames played dry while on\n",
           leadAtOn, leadMax, stats.targetLead, stats.windows, stats.averageMS, stats.dryFrames);
    CHECK(leadAtOn > 2 && leadAtOn < 7, "with Sing on the engine pulls ahead of what plays (%.2f s)", leadAtOn);
    CHECK(leadAtOff > 2, "switched off it keeps the lead and plays it on (%.2f s)", leadAtOff);
    size_t skipped = (size_t)llround(stats.dropped * kSGSingRate);
    // What plays is the mixer's frames in order, from 6 s to 16 s the mix less the vocals the offline pass finds,
    // with the vocals at 0.
    size_t from = 6 * kSGSingRate, to = 16 * kSGSingRate;
    Audio expected = makeAudio(out.frames), instrumental = makeAudio(out.frames);
    for (size_t i = 0; i < out.frames; i++) {
        expected.left[i] = mix.left[i] - offlineVocals.left[i];
        expected.right[i] = mix.right[i] - offlineVocals.right[i];
        instrumental.left[i] = mix.left[i] - voice.left[i];
        instrumental.right[i] = mix.right[i] - voice.right[i];
    }
    double first = 0;
    for (size_t i = 0; i < kSGSingRate; i++) first = fmax(first, fabs(out.left[i] - mix.left[i]) + fabs(out.right[i] - mix.right[i]));
    CHECK(first == 0, "while the lead fills the mix plays dry (%.2g)", first);
    double match = snr(expected, out, from, to);
    CHECK(match > 25, "then what plays is the mix less the vocals the offline pass finds (%.1f dB)", match);
    printf("  info  the karaoke against the true instrumental: %.1f dB; the mix's own: %.1f dB\n", snr(instrumental, out, from, to), snr(instrumental, mix, from, to));
    double after = 0;
    size_t firstOff = 0;
    for (size_t i = 26 * kSGSingRate; i < out.frames / 1024 * 1024 && i + skipped < mix.frames; i++) {
        double d = fabs(out.left[i] - mix.left[i + skipped]) + fabs(out.right[i] - mix.right[i + skipped]);
        if (d > 1e-6 && !firstOff) firstOff = i;
        after = fmax(after, d);
    }
    if (firstOff) printf("  info  first difference at %.4f s: out %g, mix %g, mix a frame on %g\n", firstOff / (double)kSGSingRate, out.left[firstOff], mix.left[firstOff], mix.left[firstOff + 1]);
    CHECK(after < 1e-6 && skipped == 0, "off again, the mix plays on where it was, nothing skipped (%.2g, %.2f s dropped)", after, stats.dropped);
    writeWAV(@"engine.wav", out);

    // The level: at 2 only the vocals play.
    SGSingEngine *loud = SGSingEngineCreate();
    SGSingEngineSetSeparator(loud, separator);
    SGSingEngineSetLevel(loud, 2);
    SGSingEngineSetOn(loud, true);
    Source third = {mix, 0};
    __block double inAt = -1;
    __block int switches = 0;
    __block bool was = false;
    Audio alone = play(loud, mix, &third, 1024, 10, ^(double played) {
        bool mixing = SGSingEngineReadStats(loud).mixing;
        if (mixing && inAt < 0) inAt = played;
        switches += mixing != was;
        was = mixing;
    });
    printf("  info  at the top of the slider the vocals came in at %.2f s and switched %d times\n", inAt, switches);
    double vocalsOnly = snr(offlineVocals, alone, 6 * kSGSingRate, 9 * kSGSingRate);
    CHECK(vocalsOnly > 30, "at the top of the slider the vocals play alone (%.1f dB against the offline vocals)", vocalsOnly);
    SGSingEngineDestroy(loud);

    // A flush drops what was pulled ahead: the next frame out is the one the mixer hands over next.
    SGSingEngine *flushing = SGSingEngineCreate();
    SGSingEngineSetSeparator(flushing, separator);
    Source second = {mix, 0}, *secondSource = &second;
    __block size_t pulledAtFlush = 0;
    __block bool flushed = false;
    Audio afterFlush = play(flushing, mix, &second, 512, 8, ^(double played) {
        if (!SGSingEngineOn(flushing)) SGSingEngineSetOn(flushing, true);
        if (played >= 5 && !flushed) {
            flushed = true;
            pulledAtFlush = secondSource->pulled;
            SGSingEngineFlush(flushing);
        }
    });
    size_t at = (size_t)(5 * kSGSingRate / 512 + 1) * 512;
    CHECK(fabsf(afterFlush.left[at] - mix.left[pulledAtFlush]) < 1e-6 && fabsf(afterFlush.left[at + 100] - mix.left[pulledAtFlush + 100]) < 1e-6,
          "after a flush the mixer's next frame plays next (%.0f s of lead dropped)", (pulledAtFlush - (size_t)(5 * kSGSingRate)) / (double)kSGSingRate);
    SGSingEngineDestroy(flushing);
    SGSingEngineDestroy(engine);
}

#pragma mark - spatial voice

// Every window is all vocals.
@interface SGWholeSeparator : SGSingSeparator
@end

@implementation SGWholeSeparator
- (BOOL)separateLeft:(const float *)left right:(const float *)right vocalsLeft:(float *)vocalsLeft vocalsRight:(float *)vocalsRight error:(NSError **)error {
    memcpy(vocalsLeft, left, kSGSingWindowFrames * sizeof(float));
    memcpy(vocalsRight, right, kSGSingWindowFrames * sizeof(float));
    return YES;
}
@end

// Whole windows back as vocals, as fast as asked: the first `fastWindows` at once, then `slow` seconds each; with a
// NaN in every window when `poison` is set.
@interface SGPacedSeparator : SGWholeSeparator
@property (nonatomic) int fastWindows;
@property double slow;   // atomic: changed while the worker runs a window
@property (nonatomic) bool poison;
@end

@implementation SGPacedSeparator {
    int _done;
}
- (BOOL)separateLeft:(const float *)left right:(const float *)right vocalsLeft:(float *)vocalsLeft vocalsRight:(float *)vocalsRight error:(NSError **)error {
    [super separateLeft:left right:right vocalsLeft:vocalsLeft vocalsRight:vocalsRight error:error];
    if (_poison) vocalsLeft[1000] = vocalsRight[2000] = NAN;
    if (_done++ >= _fastWindows) usleep((useconds_t)(self.slow * 1e6));
    return YES;
}
@end

// The lead without the model: what is reported against what was pulled and played, kept and played on when not
// separating, dropped by a flush, and the lead to take off a position counted at a moment.
static void checkHold(void) {
    size_t frames = 40 * kSGSingRate;
    Audio tone = makeAudio(frames);
    for (size_t i = 0; i < frames; i++) tone.left[i] = tone.right[i] = (float)(0.5 * sin(2 * M_PI * 440 * i / kSGSingRate));
    SGSingEngine *engine = SGSingEngineCreate();
    SGPacedSeparator *steady = [[SGPacedSeparator alloc] initWithModel:nil];
    steady.fastWindows = INT_MAX;
    SGSingEngineSetSeparator(engine, steady);
    SGSingEngineSetLevel(engine, 1);
    SGSingEngineSetOn(engine, true);
    Source source = {tone, 0}, *pulled = &source;
    __block double worst = 0, at1 = 0, leadAt1 = 0, leadAt8 = 0, heldLeast = 100, heldMost = 0, takeOffHeld = -1, leadAt12 = 0;
    __block double afterFlush = -1, takeOffFlushed = 0, leadAt19 = 0, leadAt21 = 0, droppedAt12 = -1;
    malloc_logger = countAllocation;
    Audio out = play(engine, tone, &source, 1024, 22, ^(double played) {
        // Between renders: what was pulled less what was played out, less what was dropped.
        double held = ((double)pulled->pulled - played * kSGSingRate) / kSGSingRate - SGSingEngineReadStats(engine).dropped;
        if (!SGSingEngineReadStats(engine).dropped || played > 12.1) worst = fmax(worst, fabs(SGSingEngineLead(engine) - held));
        // While the lead fills.
        if (played >= 1 && !at1) {
            at1 = CFAbsoluteTimeGetCurrent();
            leadAt1 = SGSingEngineLead(engine);
        }
        if (played >= 8 && !leadAt8) leadAt8 = SGSingEngineLead(engine);
        // Held (the heat, resting) from 8 s to 12 s, then separating again; off at 20 s.
        SGSingEngineSetPaused(engine, played >= 8 && played < 12);
        if (played >= 8.5 && played < 12) {
            heldLeast = fmin(heldLeast, SGSingEngineLead(engine));
            heldMost = fmax(heldMost, SGSingEngineLead(engine));
        }
        if (played >= 11 && takeOffHeld < 0) takeOffHeld = SGSingEngineLeadAt(engine, at1);
        // A pause or a seek: the flush drops the lead, read as dropped at once.
        if (played >= 12 && droppedAt12 < 0) {
            leadAt12 = SGSingEngineLead(engine);
            SGSingEngineFlush(engine);
            afterFlush = SGSingEngineLead(engine);
            takeOffFlushed = SGSingEngineLeadAt(engine, at1);
            droppedAt12 = SGSingEngineReadStats(engine).dropped;
        }
        if (played >= 19 && !leadAt19) leadAt19 = SGSingEngineLead(engine);
        if (played >= 20 && SGSingEngineOn(engine)) SGSingEngineSetOn(engine, false);
        if (played >= 21 && !leadAt21) leadAt21 = SGSingEngineLead(engine);
    });
    malloc_logger = NULL;
    double dropped = SGSingEngineReadStats(engine).dropped;
    CHECK(atomic_load(&sg_renderAllocations) == 0, "the lead: no allocation on the render thread (%u)", atomic_load(&sg_renderAllocations));
    CHECK(worst < 0.5 / kSGSingRate, "the lead reported is the frames pulled and not yet played, to the frame (off by %.0f at most)", worst * kSGSingRate);
    CHECK(heldLeast == leadAt8 && heldMost == leadAt8 && leadAt8 > leadAt1 + 1,
          "held at 8 s (the heat, resting), the %.2f s held are kept as they are (%.2f to %.2f s), none dropped or built", leadAt8, heldLeast, heldMost);
    CHECK(fabs(takeOffHeld - leadAt1) < 1100.0 / kSGSingRate,
          "a position counted at 1 s, as the lead filled, has the %.2f s held then taken off (%.2f s), not the %.2f s held later", leadAt1, takeOffHeld, leadAt8);
    double skippedBefore = 0;
    for (size_t i = 0; i < 12 * kSGSingRate; i++) skippedBefore = fmax(skippedBefore, fabsf(out.left[i] - tone.left[i]));
    CHECK(skippedBefore < 1e-6, "until the flush every frame plays in order, held or not: nothing skipped (%.2g)", skippedBefore);
    CHECK(afterFlush == 0 && droppedAt12 >= 0 && fabs(takeOffFlushed - (leadAt1 - leadAt12)) < 1100.0 / kSGSingRate,
          "a flush (a pause, a seek) drops the %.2f s at once: the lead reads %.2f s, and a position counted at 1 s has %.2f s taken off (%.2f less %.2f)",
          leadAt12, afterFlush, takeOffFlushed, leadAt1, leadAt12);
    size_t skipped = (size_t)llround(dropped * kSGSingRate);
    double after = 0;
    for (size_t i = 12.1 * kSGSingRate; i < 13 * kSGSingRate; i++) after = fmax(after, fabsf(out.left[i] - tone.left[i + skipped]));
    CHECK(after < 1e-6, "after it, the tone plays on from the mixer's next frame, %.2f s on (%.2g)", dropped, after);
    CHECK(leadAt19 > 2, "separating again from 12 s, the lead is built again (%.2f s at 19 s)", leadAt19);
    CHECK(fabs(leadAt21 - leadAt19) < 0.6, "switched off at 20 s, the lead is kept and plays on (%.2f s at 21 s)", leadAt21);
    SGSingEngineDestroy(engine);
}

// The lead's cap (Sing.x: 0 while a seek or a skip is on its way, the time left on the queue's last track): a lead held
// past it drains at half speed with every frame played, the mixer then pulled as it plays, none of the budget spent
// however long it lasts; lifted, the lead is built again; and switched off, the lead kept drains to it too.
static void checkCap(void) {
    size_t frames = 32 * kSGSingRate;
    Audio tone = makeAudio(frames);
    for (size_t i = 0; i < frames; i++) tone.left[i] = tone.right[i] = (float)(0.5 * sin(2 * M_PI * 440 * i / kSGSingRate));
    SGSingEngine *engine = SGSingEngineCreate();
    SGPacedSeparator *steady = [[SGPacedSeparator alloc] initWithModel:nil];
    steady.fastWindows = INT_MAX;
    SGSingEngineSetSeparator(engine, steady);
    SGSingEngineSetLevel(engine, 1);
    SGSingEngineSetOn(engine, true);
    Source source = {tone, 0}, *pulled = &source;
    __block double leadAt6 = 0, emptyAt = 0, pulledAt6 = 0, pulledEmpty = 0, mostAfter = 0, leadAt25 = 0, leadAt30 = 0;
    __block bool gaveUp = false;
    malloc_logger = countAllocation;
    Audio out = play(engine, tone, &source, 1024, 30, ^(double played) {
        double lead = SGSingEngineLead(engine);
        if (played >= 6 && !leadAt6) {
            leadAt6 = lead;
            pulledAt6 = pulled->pulled;
            SGSingEngineSetLeadCap(engine, 0);
        }
        if (leadAt6 && !emptyAt && lead == 0) {
            emptyAt = played;
            pulledEmpty = pulled->pulled;
        }
        if (emptyAt && played < 18) mostAfter = fmax(mostAfter, lead);
        gaveUp |= SGSingEngineGaveUp(engine);
        if (played >= 18 && played < 25) SGSingEngineSetLeadCap(engine, INFINITY);
        if (played >= 25 && !leadAt25) {
            leadAt25 = lead;
            SGSingEngineSetOn(engine, false);
            SGSingEngineSetLeadCap(engine, 1);
        }
        if (played >= 30 - 0.05 && !leadAt30) leadAt30 = lead;
    });
    malloc_logger = NULL;
    double drained = emptyAt - 6, rate = (pulledEmpty - pulledAt6) / (drained * kSGSingRate);
    CHECK(emptyAt && fabs(drained - 2 * leadAt6) < 0.05 && fabs(rate - 0.5) < 0.02,
          "capped at 0 at 6 s, the %.2f s held drain in %.2f s, the mixer pulled at %.2fx", leadAt6, drained, rate);
    CHECK(mostAfter < 1100.0 / kSGSingRate, "then the mixer is pulled as it plays, the lead at most %.0f frames", mostAfter * kSGSingRate);
    CHECK(!gaveUp, "12 s capped while separating spends none of the 8 s budget");
    CHECK(leadAt25 > 2, "the cap lifted at 18 s, the lead is built again (%.2f s at 25 s)", leadAt25);
    CHECK(fabs(leadAt30 - 1) < 0.05, "switched off at 25 s with a cap of 1 s, the lead kept drains to it (%.2f s at 30 s)", leadAt30);
    double worst = 0;
    // play() renders whole buffers: the tail short of one is not played.
    for (size_t i = 0; i < out.frames / 1024 * 1024; i++) worst = fmax(worst, fabsf(out.left[i] - tone.left[i]));
    CHECK(worst < 1e-6, "through it all every frame plays in order, nothing skipped (%.2g)", worst);
    CHECK(atomic_load(&sg_renderAllocations) == 0, "the cap: no allocation on the render thread (%u)", atomic_load(&sg_renderAllocations));
    SGSingEngineDestroy(engine);
}

// A decoder slower than the lead fills (Spotify on a slow network): its mixer marks what it has not decoded silent, and
// none of that is taken into the lead; reading ahead stops there and tries again at the next render, so the lead fills
// as fast as the decoder lets it. A stall of the decoder plays through on the lead, which is read again after it.
static void checkStarved(void) {
    size_t frames = 14 * kSGSingRate;
    Audio tone = makeAudio(frames);
    for (size_t i = 0; i < frames; i++) tone.left[i] = tone.right[i] = (float)(0.5 * sin(2 * M_PI * 440 * i / kSGSingRate));
    SGSingEngine *engine = SGSingEngineCreate();
    SGPacedSeparator *steady = [[SGPacedSeparator alloc] initWithModel:nil];
    steady.fastWindows = INT_MAX;
    SGSingEngineSetSeparator(engine, steady);
    SGSingEngineSetLevel(engine, 1);
    SGSingEngineSetOn(engine, true);
    Source source = {tone, 0, true, 0}, *pulled = &source;
    __block double worst = 0, leadAt6 = 0, leastInStall = 100, leadAt12 = 0;
    __block unsigned long long stopsAt6 = 0, stopsAt12 = 0, windowsAt8 = 0, windowsAt12 = 0;
    malloc_logger = countAllocation;
    Audio out = play(engine, tone, &source, 1024, 12.5, ^(double played) {
        // Decoded at 1.5 times what plays from a quarter second in, stalled from 6 s to 8 s.
        double decoding = played - fmin(fmax(played - 6, 0), 2);
        pulled->decoded = (size_t)((0.25 + 1.5 * decoding) * kSGSingRate);
        worst = fmax(worst, fabs(SGSingEngineLead(engine) - ((double)pulled->pulled - played * kSGSingRate) / kSGSingRate));
        if (played >= 6 && !leadAt6) {
            leadAt6 = SGSingEngineLead(engine);
            stopsAt6 = SGSingEngineReadStats(engine).aheadStops;
        }
        if (played >= 6 && played < 8.1) leastInStall = fmin(leastInStall, SGSingEngineLead(engine));
        if (played >= 8 && !windowsAt8) windowsAt8 = SGSingEngineReadStats(engine).windows;
        if (played >= 12 && !leadAt12) {
            leadAt12 = SGSingEngineLead(engine);
            stopsAt12 = SGSingEngineReadStats(engine).aheadStops;
            windowsAt12 = SGSingEngineReadStats(engine).windows;
        }
    });
    malloc_logger = NULL;
    CHECK(worst < 0.5 / kSGSingRate, "a slow decoder: the lead is the frames the decoder handed over and not yet played, to the frame (off by %.0f at most): "
          "none marked silent is taken in", worst * kSGSingRate);
    CHECK(stopsAt6 > 100 && leadAt6 > 2, "reading ahead stopped at the decoder %llu times by 6 s and tried again each next render, the lead "
          "filling as the decoder let it (%.2f s at 6 s)", stopsAt6, leadAt6);
    CHECK(leastInStall > 0.5 && leastInStall < leadAt6 - 1, "a 2 s stall of the decoder at 6 s plays through on the lead (down to %.2f s)", leastInStall);
    CHECK(leadAt12 > 2 && stopsAt12 > stopsAt6, "after it the lead is read again (%.2f s at 12 s, %llu stops)", leadAt12, stopsAt12);
    CHECK(windowsAt12 > windowsAt8, "and the model runs windows again, the worker asleep through the stall woken (%llu by 8 s, %llu by 12 s)",
          windowsAt8, windowsAt12);
    double gap = 0;
    for (size_t i = 0; i < 12 * kSGSingRate; i++) gap = fmax(gap, fabsf(out.left[i] - tone.left[i]));
    CHECK(gap < 1e-6, "what plays is the song with no gap and every frame in order, the stall included (%.2g)", gap);
    CHECK(atomic_load(&sg_renderAllocations) == 0, "a slow decoder: no allocation on the render thread (%u)", atomic_load(&sg_renderAllocations));
    SGSingEngineDestroy(engine);
}

// A track reached as the last one ends: Spotify reports it 0.1 s after its first frame is handed over, the last one's
// end still in the lead. Its position as Sing.x's -position takes it, Spotify's own run on from the report less the lead
// held then and never below 0, starts at the frame where its audio starts; with the lead taken off before running on,
// as it was, it ran from the report.
static void checkBoundary(void) {
    size_t frames = 14 * kSGSingRate, boundary = 8 * kSGSingRate;
    Audio tone = makeAudio(frames);
    for (size_t i = 0; i < frames; i++) tone.left[i] = tone.right[i] = (float)(0.5 * sin(2 * M_PI * (i < boundary ? 440 : 660) * i / kSGSingRate));
    SGSingEngine *engine = SGSingEngineCreate();
    SGPacedSeparator *steady = [[SGPacedSeparator alloc] initWithModel:nil];
    steady.fastWindows = INT_MAX;
    SGSingEngineSetSeparator(engine, steady);
    SGSingEngineSetLevel(engine, 1);
    SGSingEngineSetOn(engine, true);
    Source source = {tone, 0}, *pulled = &source;
    __block CFAbsoluteTime reported = 0;
    __block double handed = 0, leadThen = 0, starts = -1, startedBefore = -1, at2 = -1;
    play(engine, tone, &source, 1024, 12, ^(double played) {
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (!reported && pulled->pulled >= boundary + kSGSingRate / 10) {
            reported = now;
            handed = (double)(pulled->pulled - boundary) / kSGSingRate;
            // Read soon after the report, as Sing.x's tick reads it.
            leadThen = SGSingEngineLeadAt(engine, reported);
        }
        if (!reported) return;
        double lead = SGSingEngineLeadAt(engine, reported), since = now - reported;
        double heard = fmax(0, handed + since - lead), before = fmax(0, handed - lead) + since;
        if (heard > 0 && starts < 0) starts = played;
        if (before > 0 && startedBefore < 0) startedBefore = played;
        if (played >= 10 && at2 < 0) at2 = heard;
    });
    double edge = (double)boundary / kSGSingRate;
    CHECK(fabs(starts - edge) < 0.05, "the next track reported %.2f s into it with %.2f s held: its position starts with %.3f s played, where its "
          "first frame plays (%.3f s)", handed, leadThen, starts, edge);
    CHECK(fabs(at2 - 2) < 0.05, "and reads %.3f s as 2 s of it have played", at2);
    CHECK(startedBefore >= 0 && startedBefore < edge - 2, "with the lead taken off before running on, it started at the report, %.2f s played, "
          "%.2f s early", startedBefore, edge - startedBefore);
    SGSingEngineDestroy(engine);
}

// A model that keeps up for a while and then falls behind: the vocals fade out once, not at every window, and
// after 8 s short of them the engine gives up and gives the lead back. And a NaN from the model never plays.
static void checkFallingBehind(void) {
    size_t frames = 40 * kSGSingRate;
    Audio tone = makeAudio(frames);
    for (size_t i = 0; i < frames; i++) tone.left[i] = tone.right[i] = (float)(0.5 * sin(2 * M_PI * 440 * i / kSGSingRate));
    SGSingEngine *engine = SGSingEngineCreate();
    SGPacedSeparator *separator = [[SGPacedSeparator alloc] initWithModel:nil];
    separator.fastWindows = 6;
    separator.slow = 2.2;
    SGSingEngineSetSeparator(engine, separator);
    SGSingEngineSetLevel(engine, 0);
    SGSingEngineSetOn(engine, true);
    Source source = {tone, 0};
    __block int switches = 0;
    __block bool was = false, everIn = false;
    __block double gaveUpAt = 0;
    Audio out = play(engine, tone, &source, 1024, 40, ^(double played) {
        bool mixing = SGSingEngineReadStats(engine).mixing;
        if (mixing != was) switches++;
        was = mixing;
        everIn |= mixing;
        if (!gaveUpAt && SGSingEngineGaveUp(engine)) gaveUpAt = played;
    });
    CHECK(everIn && switches <= 2, "a model falling behind: the vocals came in and went out %d times (at most once each)", switches);
    CHECK(gaveUpAt > 0 && SGSingEngineLead(engine) > 1, "and after 8 s short of them the engine gave up (at %.1f s) and kept the lead (%.2f s)",
          gaveUpAt, SGSingEngineLead(engine));
    size_t skipped = (size_t)llround(SGSingEngineReadStats(engine).dropped * kSGSingRate);
    double last = 0;
    // Past the tone's end the source hands over silence.
    for (size_t i = 38 * kSGSingRate; i < 40 * kSGSingRate - 1024; i++) last = fmax(last, fabsf(out.left[i] - (i + skipped < frames ? tone.left[i + skipped] : 0)));
    CHECK(last == 0, "then the song plays as it is (%.2g)", last);
    // Sing.x tries again at the next track by switching the engine off and on: a fresh budget, and the vocals back.
    separator.slow = 0;
    SGSingEngineSetOn(engine, false);
    SGSingEngineSetOn(engine, true);
    Source next = {tone, 0};
    __block bool again = false;
    play(engine, tone, &next, 1024, 12, ^(double played) { again |= SGSingEngineReadStats(engine).mixing; });
    CHECK(again && !SGSingEngineGaveUp(engine), "switched off and on after giving up, it tries again and the vocals come back");
    SGSingEngineDestroy(engine);

    // Held for the heat for 10 s and let go: a start again, which the budget does not count.
    SGSingEngine *held = SGSingEngineCreate();
    SGPacedSeparator *steady = [[SGPacedSeparator alloc] initWithModel:nil];
    steady.fastWindows = INT_MAX;
    SGSingEngineSetSeparator(held, steady);
    SGSingEngineSetOn(held, true);
    Source third = {tone, 0};
    __block bool backIn = false;
    __block double spentAfter = -1;
    __block unsigned long long windowsAt8 = 0, windowsAt15 = 0;
    Audio heldOut = play(held, tone, &third, 1024, 30, ^(double played) {
        SGSingEngineSetPaused(held, played >= 6 && played < 16);
        if (played >= 17 && spentAfter < 0) spentAfter = SGSingEngineReadStats(held).budgetSpent;
        if (played >= 20) backIn |= SGSingEngineReadStats(held).mixing;
        if (played < 8) windowsAt8 = SGSingEngineReadStats(held).windows;
        if (played < 15) windowsAt15 = SGSingEngineReadStats(held).windows;
    });
    CHECK(spentAfter == 0 && !SGSingEngineGaveUp(held) && backIn,
          "held for 10 s and let go, the wait for the vocals is a start (%.1f s of the budget spent 1 s on), they come back, and the engine does not give up", spentAfter);
    // Sing.x rests the same way at the vocals as sung: no window runs, and the song plays exactly as it is.
    double heldDiff = 0;
    skipped = (size_t)llround(SGSingEngineReadStats(held).dropped * kSGSingRate);
    for (size_t i = 8 * kSGSingRate; i < 15 * kSGSingRate; i++) heldDiff = fmax(heldDiff, fabsf(heldOut.left[i] - tone.left[i + skipped]));
    CHECK(windowsAt15 == windowsAt8 && heldDiff == 0, "held, the model runs no window (%llu then %llu) and the song plays exactly as it is (%.2g)",
          windowsAt8, windowsAt15, heldDiff);
    SGSingEngineDestroy(held);

    SGSingEngine *poisoned = SGSingEngineCreate();
    SGPacedSeparator *bad = [[SGPacedSeparator alloc] initWithModel:nil];
    bad.poison = true;
    bad.fastWindows = INT_MAX;
    SGSingEngineSetSeparator(poisoned, bad);
    SGSingEngineSetLevel(poisoned, 2);
    SGSingEngineSetOn(poisoned, true);
    Source second = {tone, 0};
    Audio sung = play(poisoned, tone, &second, 1024, 8, ^(double played) {});
    bool finite = true;
    for (size_t i = 0; i < sung.frames; i++) finite &= isfinite(sung.left[i]) && isfinite(sung.right[i]);
    CHECK(finite && SGSingEngineReadStats(poisoned).mixing, "a NaN from the model plays as silence, never as a NaN");
    SGSingEngineDestroy(poisoned);
}

// A copy of the model without the model, on the compute units it is given: each prediction takes `seconds` and hands
// back silence as the vocals, or fails.
@interface SGMockModel : MLModel
@property double seconds;   // atomic: changed while the worker runs a window
@property (nonatomic) bool fails;
@property (nonatomic) MLComputeUnits units;
@end

@implementation SGMockModel
- (MLModelConfiguration *)configuration {
    MLModelConfiguration *configuration = [MLModelConfiguration new];
    configuration.computeUnits = _units;
    return configuration;
}
- (id<MLFeatureProvider>)predictionFromFeatures:(id<MLFeatureProvider>)input error:(NSError **)error {
    usleep((useconds_t)(self.seconds * 1e6));
    if (_fails) {
        if (error) *error = [NSError errorWithDomain:@"harness" code:2 userInfo:@{NSLocalizedDescriptionKey: @"the mock copy fails every window"}];
        return nil;
    }
    MLMultiArray *vocals = [[MLMultiArray alloc] initWithShape:@[@1, @(2 * kSGSingBins), @(kSGSingSTFTFrames), @2] dataType:MLMultiArrayDataTypeFloat32 error:error];
    [vocals getMutableBytesWithHandler:^(void *bytes, NSInteger size, NSArray<NSNumber *> *strides) { memset(bytes, 0, (size_t)size); }];
    return vocals ? [[MLDictionaryFeatureProvider alloc] initWithDictionary:@{@"vocals_spectrum": vocals} error:error] : nil;
}
@end

static SGMockModel *mockCopy(MLComputeUnits units, double seconds) {
    SGMockModel *model = [SGMockModel alloc];
    model.units = units;
    model.seconds = seconds;
    return model;
}

// The Neural Engine copy loading while the CPU's falls behind (Sing.x holds the budget while the loader reads
// Loading): a Neural Engine copy keeps up, is dropped at 6 s and another loads until 24 s (a first compile), the CPU's
// taking 2.2 s a window meanwhile. Held, the engine never gives up; let go with the copy in, the vocals come back; let
// go with the load failed, the budget starts then, full, and the engine gives up 8 s on, as before.
static void checkFasterCopyLoading(void) {
    size_t frames = 40 * kSGSingRate;
    Audio tone = makeAudio(frames);
    for (size_t i = 0; i < frames; i++) tone.left[i] = tone.right[i] = (float)(0.5 * sin(2 * M_PI * 440 * i / kSGSingRate));
    for (int loads = 1; loads >= 0; loads--) {
        SGSingSeparator *separator = [[SGSingSeparator alloc] initWithModel:mockCopy(MLComputeUnitsCPUOnly, 2.2)];
        [separator setFastModel:mockCopy(MLComputeUnitsCPUAndNeuralEngine, 0.25) named:@"Neural Engine (mock)"];
        SGSingEngine *engine = SGSingEngineCreate();
        SGSingEngineSetSeparator(engine, separator);
        SGSingEngineSetLevel(engine, 0);
        SGSingEngineSetOn(engine, true);
        Source source = {tone, 0};
        __block bool inBefore = false, outWhileHeld = false, backAfter = false;
        __block double gaveUpAt = 0, spentWhileHeld = 0;
        play(engine, tone, &source, 1024, loads ? 32 : 36, ^(double played) {
            SGSingEngineStats stats = SGSingEngineReadStats(engine);
            if (played < 6) inBefore |= stats.mixing;
            if (played >= 6 && !stats.budgetHeld && played < 24) {
                [separator setFastModel:nil named:nil];
                SGSingEngineHoldBudget(engine, true);
            }
            if (played >= 10 && played < 24) {
                outWhileHeld |= !stats.mixing;
                spentWhileHeld = fmax(spentWhileHeld, stats.budgetSpent);
            }
            if (played >= 24 && stats.budgetHeld) {
                if (loads) [separator setFastModel:mockCopy(MLComputeUnitsCPUAndNeuralEngine, 0.3) named:@"Neural Engine (mock, compiled)"];
                SGSingEngineHoldBudget(engine, false);
            }
            if (played >= 24) backAfter |= stats.mixing;
            if (!gaveUpAt && SGSingEngineGaveUp(engine)) gaveUpAt = played;
        });
        if (loads) {
            CHECK(inBefore && outWhileHeld && spentWhileHeld == 0 && (!gaveUpAt || gaveUpAt >= 24),
                  "a Neural Engine copy loading from 6 s to 24 s while the CPU's falls behind: the vocals went out, none of the 8 s was spent (%.1f s) and the engine did not give up",
                  spentWhileHeld);
            CHECK(backAfter && !gaveUpAt && [separator stats].fast, "with the Neural Engine copy in at 24 s the vocals come back and the windows go to it");
        } else {
            CHECK(gaveUpAt >= 31.9 && gaveUpAt < 33,
                  "with that load failed at 24 s, the budget starts then, full: the engine gives up at %.1f s (8 s on), as a copy that cannot keep up does", gaveUpAt);
        }
        SGSingEngineDestroy(engine);
    }
}

// What Sing.x drops a Neural Engine copy on (`fastFailed`): a failed window, not a slow one. A copy that falls behind
// until the engine gives up still reads unfailed, the last window on it; one that fails a window reads failed after the
// CPU's has run the windows since; a fresh copy reads unfailed again.
static void checkNeuralFaults(void) {
    size_t frames = 30 * kSGSingRate;
    Audio tone = makeAudio(frames);
    for (size_t i = 0; i < frames; i++) tone.left[i] = tone.right[i] = (float)(0.5 * sin(2 * M_PI * 440 * i / kSGSingRate));
    SGSingSeparator *separator = [[SGSingSeparator alloc] initWithModel:mockCopy(MLComputeUnitsCPUOnly, 2.2)];
    SGMockModel *slow = mockCopy(MLComputeUnitsCPUAndNeuralEngine, 0.25);
    [separator setFastModel:slow named:@"Neural Engine (mock)"];
    SGSingEngine *engine = SGSingEngineCreate();
    SGSingEngineSetSeparator(engine, separator);
    SGSingEngineSetOn(engine, true);
    Source source = {tone, 0};
    __block double gaveUpAt = 0;
    play(engine, tone, &source, 1024, 24, ^(double played) {
        if (played >= 6) slow.seconds = 2.2;
        if (!gaveUpAt && SGSingEngineGaveUp(engine)) gaveUpAt = played;
    });
    SGSingEngineDestroy(engine);
    SGSingSeparatorStats stats = [separator stats];
    CHECK(gaveUpAt > 0 && stats.fast && !stats.fastFailed && stats.fallbacks == 0,
          "a Neural Engine copy slowed to 2.2 s a window: the engine gives up (%.1f s), and the copy reads unfailed, so Sing.x keeps it", gaveUpAt);

    float *vl = calloc(kSGSingWindowFrames, sizeof(float)), *vr = calloc(kSGSingWindowFrames, sizeof(float));
    NSError *error;
    SGSingSeparator *quick = [[SGSingSeparator alloc] initWithModel:mockCopy(MLComputeUnitsCPUOnly, 0)];
    SGMockModel *failing = mockCopy(MLComputeUnitsCPUAndNeuralEngine, 0);
    failing.fails = true;
    [quick setFastModel:failing named:@"Neural Engine (mock, failing)"];
    BOOL first = [quick separateLeft:tone.left right:tone.right vocalsLeft:vl vocalsRight:vr error:&error];
    BOOL second = [quick separateLeft:tone.left right:tone.right vocalsLeft:vl vocalsRight:vr error:&error];
    stats = [quick stats];
    CHECK(first && second && stats.fallbacks == 1 && stats.windows[0] == 2 && !stats.fast && stats.fastFailed,
          "a Neural Engine copy that fails a window: the window done on the CPU's, and after a second window on the CPU's "
          "it still reads failed, so Sing.x drops it");
    [quick setFastModel:mockCopy(MLComputeUnitsCPUAndNeuralEngine, 0) named:@"Neural Engine (mock, fresh)"];
    [quick separateLeft:tone.left right:tone.right vocalsLeft:vl vocalsRight:vr error:&error];
    stats = [quick stats];
    CHECK(stats.fast && !stats.fastFailed, "a fresh Neural Engine copy put in its place reads unfailed and takes the window");
    free(vl);
    free(vr);
}

static double energy(const float *samples, size_t from, size_t to) {
    double sum = 0;
    for (size_t i = from; i < to; i++) sum += (double)samples[i] * samples[i];
    return sum;
}

// The lag in frames by which the left channel follows the right, the best of +-45 (the tone's period is 100).
static int leftLag(Audio audio, size_t from, size_t to) {
    int best = 0;
    double bestSum = -INFINITY;
    for (int lag = -45; lag <= 45; lag++) {
        double sum = 0;
        for (size_t i = from; i < to; i++) sum += (double)audio.right[i] * audio.left[i + lag];
        if (sum > bestSum) bestSum = sum, best = lag;
    }
    return best;
}

static void checkSpatial(void) {
    size_t frames = 14 * kSGSingRate;
    Audio tone = makeAudio(frames);
    for (size_t i = 0; i < frames; i++) tone.left[i] = tone.right[i] = (float)(0.5 * sin(2 * M_PI * 440 * i / kSGSingRate));
    SGSingEngine *engine = SGSingEngineCreate();
    SGSingEngineSetSeparator(engine, [[SGWholeSeparator alloc] initWithModel:nil]);
    SGSingEngineSetLevel(engine, 1);
    SGSingEngineSetOn(engine, true);
    Source source = {tone, 0};
    atomic_store(&sg_renderAllocations, 0);
    malloc_logger = countAllocation;
    Audio out = play(engine, tone, &source, 1024, 14, ^(double played) {
        if (played >= 5 && played < 8) SGSingEngineSetVoiceAngle(engine, (float)M_PI_2);
        if (played >= 8 && played < 11) SGSingEngineSetVoiceAngle(engine, -(float)M_PI_2);
        if (played >= 11) SGSingEngineSetVoiceAngle(engine, 0);
    });
    malloc_logger = NULL;
    CHECK(atomic_load(&sg_renderAllocations) == 0, "spatial voice: no allocation on the render thread (%u)", atomic_load(&sg_renderAllocations));
    // The loudness the Sing page draws: all of the tone is vocals here, a sine of 0.5 at an RMS of 0.354.
    float vocalsLevel[5], restLevel[5];
    SGSingEngineReadLevels(engine, vocalsLevel, restLevel, 5);
    CHECK(fabsf(vocalsLevel[0] - 0.3536f) < 0.01f && fabsf(vocalsLevel[4] - 0.3536f) < 0.01f && restLevel[0] < 0.001f,
          "the loudness of what plays now: vocals %.3f (a 0.5 sine's 0.354), the rest %.3f", vocalsLevel[4], restLevel[4]);
    SGSingEngineStats stats = SGSingEngineReadStats(engine);
    CHECK(stats.ready > 0 && stats.dryFrames < 4 * kSGSingRate, "spatial voice: the vocals are in (%.2f s separated ahead, %.2f s played dry)",
          stats.ready, stats.dryFrames / (double)kSGSingRate);

    double ahead = 0;
    for (size_t i = 3 * kSGSingRate; i < 5 * kSGSingRate; i++) ahead = fmax(ahead, fmax(fabsf(out.left[i] - tone.left[i]), fabsf(out.right[i] - tone.right[i])));
    CHECK(ahead == 0, "straight ahead the vocals play exactly as they came (%.2g)", ahead);

    // Expected at 90 degrees: the pan's gains, sqrt 2 times the cosine and sine of (0.5 + 1) * 45 degrees.
    double panDB = 20 * log10(sin(1.5 * M_PI_4) / cos(1.5 * M_PI_4));
    size_t rightFrom = (size_t)(6.5 * kSGSingRate), rightTo = (size_t)(7.5 * kSGSingRate);
    size_t leftFrom = (size_t)(9.5 * kSGSingRate), leftTo = (size_t)(10.5 * kSGSingRate);
    double toneEnergy = energy(tone.left, rightFrom, rightTo);
    double rightDB = 10 * log10(energy(out.right, rightFrom, rightTo) / energy(out.left, rightFrom, rightTo));
    double rightPower = 10 * log10((energy(out.left, rightFrom, rightTo) + energy(out.right, rightFrom, rightTo)) / (2 * toneEnergy));
    int rightLag = leftLag(out, rightFrom, rightTo);
    CHECK(fabs(rightDB - panDB) < 0.5 && fabs(rightPower) < 0.5,
          "at 90 degrees right the right ear is %.2f dB louder (the pan's %.2f), at %+.2f dB of the power ahead", rightDB, panDB, rightPower);
    // The delay around the head, 28.7 frames, and the low-pass's own lag at 440 Hz, about 2.
    CHECK(rightLag >= 27 && rightLag <= 33, "and the left ear hears it %d frames later (%.2f ms)", rightLag, rightLag * 1000.0 / kSGSingRate);
    double leftDB = 10 * log10(energy(out.left, leftFrom, leftTo) / energy(out.right, leftFrom, leftTo));
    int leftLagFrames = leftLag(out, leftFrom, leftTo);
    CHECK(fabs(leftDB - panDB) < 0.5 && leftLagFrames <= -27 && leftLagFrames >= -33,
          "at 90 degrees left the left ear is %.2f dB louder and the right ear %d frames later", leftDB, -leftLagFrames);

    double back = 0;
    for (size_t i = 12 * kSGSingRate; i < 14 * kSGSingRate - 1024; i++) back = fmax(back, fmax(fabsf(out.left[i] - tone.left[i]), fabsf(out.right[i] - tone.right[i])));
    CHECK(back == 0, "back straight ahead, exactly as they came again (%.2g)", back);

    // No click: from one frame to the next the output moves no further than the tone at its loudest placement.
    double toneStep = 0, step = 0;
    for (size_t i = 3 * kSGSingRate; i < 14 * kSGSingRate - 1024; i++) {
        toneStep = fmax(toneStep, fabsf(tone.left[i] - tone.left[i - 1]));
        step = fmax(step, fmax(fabsf(out.left[i] - out.left[i - 1]), fabsf(out.right[i] - out.right[i - 1])));
    }
    double loudest = M_SQRT2 * sin(1.5 * M_PI_4);
    CHECK(step <= toneStep * loudest * 1.02, "no click through the turns: the largest step is %.4f, the tone's %.4f times the louder gain %.3f",
          step, toneStep, loudest);
    writeWAV(@"spatial.wav", out);
    SGSingEngineDestroy(engine);

    // Distance: at 4 m, straight ahead and with no room, the voice is at the square root of 1/4 of its level, -6.02 dB.
    engine = SGSingEngineCreate();
    SGSingEngineSetSeparator(engine, [[SGWholeSeparator alloc] initWithModel:nil]);
    SGSingEngineSetLevel(engine, 1);
    SGSingEngineSetSpatial(engine, true, 4, 0, 1);
    SGSingEngineSetOn(engine, true);
    source = (Source){tone, 0};
    Audio far = play(engine, tone, &source, 1024, 8, ^(double played) {});
    size_t from = 5 * kSGSingRate, to = 7 * kSGSingRate;
    double farDB = 10 * log10(energy(far.left, from, to) / energy(tone.left, from, to));
    CHECK(fabs(farDB + 6.02) < 0.2, "at 4 m the voice is %.2f dB (the square root of 1/4: -6.02)", farDB);
    // Room, where AUReverb2 is (not on the Mac): the room adds to the far voice.
    SGSingEngineSetSpatial(engine, true, 4, 1, 1);
    source = (Source){tone, 0};
    Audio roomy = play(engine, tone, &source, 1024, 8, ^(double played) {});
    double roomDB = 10 * log10(energy(roomy.left, from, to) / energy(tone.left, from, to));
    printf("note: with Room at 100%% the voice at 4 m is %.2f dB (%s)\n", roomDB,
           roomDB > farDB + 0.5 ? "the room is heard" : "no room here: AUReverb2 is missing or silent");
    SGSingEngineDestroy(engine);
}

// The front the voice is held off (SGSpatialVoiceAngle), fed at 25 Hz as AirPods send their motion.
static void checkFront(void) {
    SGSpatialFront front = {0};
    double angle = SGSpatialVoiceAngle(&front, 0.3, 10, 20);
    CHECK(angle == 0, "the first motion is the front: the voice straight ahead (%.3f)", angle);
    // The head turned 60 degrees left (yaw grows) at once, then held there.
    double turned = SGSpatialVoiceAngle(&front, 0.3 + M_PI / 3, 10.04, 20), held = turned;
    double time = 10.04;
    for (; time < 30.04 - 1e-9; time += 0.04) held = SGSpatialVoiceAngle(&front, 0.3 + M_PI / 3, time + 0.04, 20);
    CHECK(fabs(turned - M_PI / 3) < 0.01 && fabs(held - M_PI / 3 * exp(-3)) < 0.01,
          "a head turned 60 degrees left has the voice %.1f degrees right, and 20 s on %.1f (5%% of the turn left: %.1f)",
          turned * 180 / M_PI, held * 180 / M_PI, 60 * exp(-3));
    // Across the back: yaw wraps from +179 to -179 degrees, which is 2 degrees further left, not 358 right.
    SGSpatialFront back = {0};
    SGSpatialVoiceAngle(&back, M_PI - 0.01, 0, 20);
    double wrapped = SGSpatialVoiceAngle(&back, -M_PI + 0.01, 0.04, 20);
    CHECK(fabs(wrapped - 0.02) < 0.001, "across +-180 degrees the voice moves %.2f degrees", wrapped * 180 / M_PI);
    // Headphones out for 2 s and in again: the front starts over where the head points.
    double again = SGSpatialVoiceAngle(&front, -1, time + 2, 20);
    CHECK(again == 0, "after a gap in the motion the voice is ahead again (%.3f)", again);
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IOLBF, 0);
    @autoreleasepool {
        if (argc == 2 && !strcmp(argv[1], "spatial")) {
            sg_outDir = NSTemporaryDirectory();
            checkHold();
            checkCap();
            checkStarved();
            checkBoundary();
            checkSpatial();
            checkFront();
            checkFallingBehind();
            checkFasterCopyLoading();
            checkNeuralFaults();
            printf("%s\n", sg_failures ? "FAILED" : "all passed");
            return sg_failures ? 1 : 0;
        }
        if (argc < 4 || (argc > 4 && strcmp(argv[4], "ane") && strcmp(argv[4], "cpu"))) {
            printf("usage: sing <separator-ane.mlmodelc> <voice> <out dir> [ane|cpu]   (with the Neural Engine copy beside the CPU's, the default, or the CPU's alone)\n"
                   "       sing spatial\n");
            return 2;
        }
        NSString *modelPath = @(argv[1]);
        bool neural = argc < 5 || !strcmp(argv[4], "ane");
        sg_outDir = @(argv[3]);
        [NSFileManager.defaultManager createDirectoryAtPath:sg_outDir withIntermediateDirectories:YES attributes:nil error:nil];
        checkSTFT();

        SGSingSeparator *separator = checkLoader(modelPath, neural);
        if (!separator) return 1;
        MLModel *shapes = [MLModel modelWithContentsOfURL:[NSURL fileURLWithPath:modelPath] configuration:[MLModelConfiguration new] error:nil];
        MLFeatureDescription *input = shapes.modelDescription.inputDescriptionsByName[@"spectrum"];
        MLFeatureDescription *output = shapes.modelDescription.outputDescriptionsByName[@"vocals_spectrum"];
        CHECK([input.multiArrayConstraint.shape isEqualToArray:(@[@1, @2050, @201, @2])] && [output.multiArrayConstraint.shape isEqualToArray:(@[@1, @2050, @201, @2])],
              "its spectrum and vocals_spectrum are [1, 2050, 201, 2]");
        shapes = nil;
        describePlan(modelPath, neural);

        Audio voice = readAudio(@(argv[2]));
        size_t frames = (size_t)kSGSingRate * 30;
        frames = (frames - kSGSingWindowFrames) / kSGSingEngineHop * kSGSingEngineHop + kSGSingWindowFrames;
        Audio padded = makeAudio(frames), backing = chords(frames), mix = makeAudio(frames);
        for (size_t i = 0; i < frames; i++) {
            // The voice over and over, a second apart, from a second in.
            size_t from = i >= kSGSingRate ? (i - kSGSingRate) % (voice.frames + kSGSingRate) : voice.frames;
            padded.left[i] = padded.right[i] = from < voice.frames ? 0.5f * voice.left[from] : 0;
            mix.left[i] = padded.left[i] + backing.left[i];
            mix.right[i] = padded.right[i] + backing.right[i];
        }
        double slowest, average;
        Audio vocals = separateOffline(separator, mix, &slowest, &average);
        printf("  info  a two second window takes %.0f ms on average, %.0f ms at most (the copies were warmed with silence)\n", average * 1000, slowest * 1000);
        size_t to = frames - kSGSingWindowFrames / 2;
        double found = snr(padded, vocals, kSGSingRate, to), baseline = snr(padded, mix, kSGSingRate, to);
        CHECK(found > baseline + 10, "the vocals it finds score %.1f dB against the voice, the mix itself %.1f dB", found, baseline);
        Audio accompaniment = makeAudio(frames);
        for (size_t i = 0; i < frames; i++) {
            accompaniment.left[i] = mix.left[i] - vocals.left[i];
            accompaniment.right[i] = mix.right[i] - vocals.right[i];
        }
        printf("  info  the mix less them scores %.1f dB against the chords, the mix itself %.1f dB\n", snr(backing, accompaniment, kSGSingRate, to),
               snr(backing, mix, kSGSingRate, to));
        if (neural) checkNeuralMatches(separator, mix, modelPath);
        writeWAV(@"mix.wav", mix);
        writeWAV(@"vocals.wav", vocals);
        writeWAV(@"accompaniment.wav", accompaniment);

        checkEngine(separator, mix, padded, vocals);
        // Last, as it swaps the faster copy out.
        checkCopies(separator, mix, neural);
        if (neural) checkNeuralFallback(modelPath);
        checkHold();
        checkCap();
        checkStarved();
        checkBoundary();
        checkSpatial();
        checkFront();
        checkFallingBehind();
        checkFasterCopyLoading();
        checkNeuralFaults();
        printf("%s\n", sg_failures ? "FAILED" : "all passed");
        return sg_failures ? 1 : 0;
    }
}
