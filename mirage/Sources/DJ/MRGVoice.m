#import "MRGVoice.h"
#import "MRGAI.h"
#import "MRGKeychain.h"
#import "MRGDJLog.h"

static NSUserDefaults *D(void) { return NSUserDefaults.standardUserDefaults; }
static NSString *const kEleven = @"elevenlabs-key";

MRGVoiceEngine MRGVoiceGetEngine(void) {
    id v = [D() objectForKey:@"mirage.dj.voiceEngine"];
    if (![v isKindOfClass:NSNumber.class]) v = nil;
    if (v) { NSInteger e = [v integerValue]; return (e >= 0 && e <= 3) ? e : MRGVoiceEnginePhone; }
    // 0.2.x kept 0 phone, 1 provider, 2 off.
    NSInteger old = [D() integerForKey:@"mirage.dj.voice"];
    return old == 2 ? MRGVoiceEngineOff : old == 1 ? MRGVoiceEngineProvider : MRGVoiceEnginePhone;
}
void MRGVoiceSetEngine(MRGVoiceEngine e) { [D() setInteger:e forKey:@"mirage.dj.voiceEngine"]; }

double MRGVoiceSpeed(void) { id v = [D() objectForKey:@"mirage.dj.speed"]; double s = [v isKindOfClass:NSNumber.class] ? [v doubleValue] : 1.0; return MIN(1.5, MAX(0.7, s)); }
void MRGVoiceSetSpeed(double s) { [D() setDouble:s forKey:@"mirage.dj.speed"]; }
double MRGVoicePitch(void) { id v = [D() objectForKey:@"mirage.dj.pitch"]; double p = [v isKindOfClass:NSNumber.class] ? [v doubleValue] : 1.0; return MIN(1.5, MAX(0.75, p)); }
void MRGVoiceSetPitch(double p) { [D() setDouble:p forKey:@"mirage.dj.pitch"]; }

#pragma mark - phone voices

static BOOL isPersonal(AVSpeechSynthesisVoice *v) {
    if (@available(iOS 17.0, *)) return (v.voiceTraits & AVSpeechSynthesisVoiceTraitIsPersonalVoice) != 0;
    return NO;
}

static NSInteger voiceScore(AVSpeechSynthesisVoice *v) {
    return (isPersonal(v) ? 100 : 0) + (NSInteger)v.quality * 10;
}

NSString *MRGVoiceQualityName(AVSpeechSynthesisVoice *v) {
    if (isPersonal(v)) return @"Personal";
    if (v.quality == AVSpeechSynthesisVoiceQualityPremium) return @"Premium";
    if (v.quality == AVSpeechSynthesisVoiceQualityEnhanced) return @"Enhanced";
    return @"Default";
}

NSArray<AVSpeechSynthesisVoice *> *MRGVoicePhoneVoices(void) {
    NSString *lang = [NSLocale.preferredLanguages.firstObject componentsSeparatedByString:@"-"].firstObject ?: @"en";
    NSMutableArray *out = [NSMutableArray array];
    for (AVSpeechSynthesisVoice *v in AVSpeechSynthesisVoice.speechVoices) {
        if (![v.language hasPrefix:@"en"] && ![v.language hasPrefix:lang]) continue;
        if (@available(iOS 17.0, *)) { if (v.voiceTraits & AVSpeechSynthesisVoiceTraitIsNoveltyVoice) continue; }
        [out addObject:v];
    }
    [out sortUsingComparator:^NSComparisonResult(AVSpeechSynthesisVoice *a, AVSpeechSynthesisVoice *b) {
        NSInteger sa = voiceScore(a), sb = voiceScore(b);
        if (sa != sb) return sa > sb ? NSOrderedAscending : NSOrderedDescending;
        BOOL la = [a.language isEqualToString:AVSpeechSynthesisVoice.currentLanguageCode], lb = [b.language isEqualToString:AVSpeechSynthesisVoice.currentLanguageCode];
        if (la != lb) return la ? NSOrderedAscending : NSOrderedDescending;
        return [a.name localizedCaseInsensitiveCompare:b.name];
    }];
    return out;
}

AVSpeechSynthesisVoice *MRGVoicePhoneVoice(void) {
    NSString *wanted = [D() stringForKey:@"mirage.dj.systemVoice"];
    AVSpeechSynthesisVoice *v = wanted ? [AVSpeechSynthesisVoice voiceWithIdentifier:wanted] : nil;
    return v ?: MRGVoicePhoneVoices().firstObject ?: [AVSpeechSynthesisVoice voiceWithLanguage:AVSpeechSynthesisVoice.currentLanguageCode];
}

void MRGVoiceSetPhoneVoice(NSString *identifier) {
    if (identifier.length) [D() setObject:identifier forKey:@"mirage.dj.systemVoice"];
    else [D() removeObjectForKey:@"mirage.dj.systemVoice"];
}

NSString *MRGVoiceProviderVoice(void) { return [D() stringForKey:@"mirage.dj.providerVoice"]; }
void MRGVoiceSetProviderVoice(NSString *voiceID) {
    if (voiceID.length) [D() setObject:voiceID forKey:@"mirage.dj.providerVoice"]; else [D() removeObjectForKey:@"mirage.dj.providerVoice"];
}

#pragma mark - ElevenLabs

// api.elevenlabs.io: GET /v1/voices lists the account's voices (and checks the key), POST /v1/text-to-speech/{id}
// returns MP3. Header xi-api-key.
static NSMutableURLRequest *elevenRequest(NSString *path, NSString *key, NSDictionary *body) {
    NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[@"https://api.elevenlabs.io" stringByAppendingString:path]]];
    r.timeoutInterval = 30;
    [r setValue:key forHTTPHeaderField:@"xi-api-key"];
    if (body) {
        r.HTTPMethod = @"POST";
        [r setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
        [r setValue:@"audio/mpeg" forHTTPHeaderField:@"Accept"];
        r.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    }
    return r;
}

static NSString *elevenError(NSInteger status, NSData *data, NSError *error) {
    if (error) return error.localizedDescription;
    id j = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    NSString *detail = nil;
    id d = [j isKindOfClass:NSDictionary.class] ? j[@"detail"] : nil;
    if ([d isKindOfClass:NSDictionary.class] && [d[@"message"] isKindOfClass:NSString.class]) detail = d[@"message"];
    else if ([d isKindOfClass:NSString.class]) detail = d;
    return [NSString stringWithFormat:@"ElevenLabs answered HTTP %ld%@", (long)status, detail ? [@": " stringByAppendingString:detail] : @"."];
}

BOOL MRGElevenHasKey(void) { return MRGKeychainGet(kEleven).length > 0; }
NSArray<NSDictionary *> *MRGElevenVoices(void) {
    NSMutableArray *a = [NSMutableArray array];
    for (NSDictionary *v in [D() arrayForKey:@"mirage.dj.elevenVoices"])
        if ([v isKindOfClass:NSDictionary.class] && [v[@"id"] isKindOfClass:NSString.class] && [v[@"name"] isKindOfClass:NSString.class]) [a addObject:v];
    return a;
}
NSString *MRGElevenVoice(void) { return [D() stringForKey:@"mirage.dj.elevenVoice"] ?: [MRGElevenVoices().firstObject objectForKey:@"id"]; }
void MRGElevenSetVoice(NSString *voiceID) { if (voiceID) [D() setObject:voiceID forKey:@"mirage.dj.elevenVoice"]; }

static void fetchElevenVoices(NSString *key, void (^done)(NSArray *, NSString *)) {
    [[NSURLSession.sharedSession dataTaskWithRequest:elevenRequest(@"/v1/voices", key, nil) completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
        NSInteger status = [resp isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)resp).statusCode : 0;
        NSMutableArray *voices = [NSMutableArray array];
        NSString *err = nil;
        if (error || status < 200 || status >= 300) err = elevenError(status, data, error);
        else {
            id j = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            for (NSDictionary *v in [j isKindOfClass:NSDictionary.class] && [j[@"voices"] isKindOfClass:NSArray.class] ? j[@"voices"] : @[]) {
                if (![v isKindOfClass:NSDictionary.class] || ![v[@"voice_id"] isKindOfClass:NSString.class]) continue;
                [voices addObject:@{@"id": v[@"voice_id"], @"name": [v[@"name"] isKindOfClass:NSString.class] ? v[@"name"] : v[@"voice_id"],
                                    @"category": [v[@"category"] isKindOfClass:NSString.class] ? v[@"category"] : @""}];
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{ done(err ? nil : voices, err); });
    }] resume];
}

void MRGElevenSetKey(NSString *raw, void (^done)(BOOL, NSString *)) {
    NSString *key = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!key.length) {
        MRGKeychainSet(kEleven, nil);
        [D() removeObjectForKey:@"mirage.dj.elevenVoices"];
        if (MRGVoiceGetEngine() == MRGVoiceEngineEleven) MRGVoiceSetEngine(MRGVoiceEnginePhone);
        done(YES, @"ElevenLabs key removed.");
        return;
    }
    fetchElevenVoices(key, ^(NSArray *voices, NSString *error) {
        if (error) { done(NO, error); return; }
        if (!MRGKeychainSet(kEleven, key)) { done(NO, @"Couldn't save the key on this phone."); return; }
        [D() setObject:voices forKey:@"mirage.dj.elevenVoices"];
        done(YES, [NSString stringWithFormat:@"ElevenLabs key saved: %lu voices.", (unsigned long)voices.count]);
    });
}

void MRGElevenRefreshVoices(void (^done)(NSArray<NSDictionary *> *, NSString *)) {
    NSString *key = MRGKeychainGet(kEleven);
    if (!key.length) { done(@[], @"No ElevenLabs key."); return; }
    fetchElevenVoices(key, ^(NSArray *voices, NSString *error) {
        if (voices) [D() setObject:voices forKey:@"mirage.dj.elevenVoices"];
        done(voices ?: MRGElevenVoices(), error);
    });
}

static void elevenSpeech(NSString *text, NSString *voice, double speed, void (^done)(NSData *, NSString *)) {
    NSString *key = MRGKeychainGet(kEleven);
    if (!key.length || !voice.length) { done(nil, @"No ElevenLabs key or voice."); return; }
    NSString *path = [NSString stringWithFormat:@"/v1/text-to-speech/%@?output_format=mp3_44100_128", voice];
    void (^run)(NSString *, void (^)(NSData *, NSInteger, NSString *)) = ^(NSString *model, void (^cb)(NSData *, NSInteger, NSString *)) {
        NSDictionary *body = @{@"text": text, @"model_id": model, @"voice_settings": @{@"speed": @(MIN(1.2, MAX(0.7, speed)))}};
        [[NSURLSession.sharedSession dataTaskWithRequest:elevenRequest(path, key, body) completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
            NSInteger status = [resp isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)resp).statusCode : 0;
            NSString *err = (error || status < 200 || status >= 300) ? elevenError(status, data, error) : nil;
            dispatch_async(dispatch_get_main_queue(), ^{ cb(err ? nil : data, status, err); });
        }] resume];
    };
    run(@"eleven_flash_v2_5", ^(NSData *d, NSInteger s, NSString *e) {
        if (d || (s != 400 && s != 422)) { done(d, e); return; }
        run(@"eleven_multilingual_v2", ^(NSData *d2, NSInteger s2, NSString *e2) { done(d2, e2); });
    });
}

NSString *MRGVoiceSummary(void) {
    switch (MRGVoiceGetEngine()) {
        case MRGVoiceEngineOff: return @"Off";
        case MRGVoiceEngineProvider: {
            MRGProvider p = MRGAIProvider();
            if (!MRGProviderHasTTS(p)) break;
            return [NSString stringWithFormat:@"%@ · %@", MRGProviderName(p), MRGVoiceProviderVoice() ?: @"default"];
        }
        case MRGVoiceEngineEleven: {
            if (!MRGElevenHasKey()) break;
            NSString *vid = MRGElevenVoice();
            for (NSDictionary *v in MRGElevenVoices()) if ([v[@"id"] isEqualToString:vid]) return [@"ElevenLabs · " stringByAppendingString:v[@"name"]];
            return @"ElevenLabs";
        }
        default: break;
    }
    AVSpeechSynthesisVoice *v = MRGVoicePhoneVoice();
    return v ? [NSString stringWithFormat:@"%@ (%@)", v.name, MRGVoiceQualityName(v)] : @"Phone";
}

#pragma mark - speaker

@interface MRGVoiceSpeaker () <AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate>
@end

@implementation MRGVoiceSpeaker {
    AVSpeechSynthesizer *_synth;
    AVAudioPlayer *_audio;
    void (^_finished)(void);
    NSUInteger _token;
}

+ (instancetype)shared {
    static MRGVoiceSpeaker *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [MRGVoiceSpeaker new]; });
    return s;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    _synth = [AVSpeechSynthesizer new];
    _synth.delegate = self;
    // The speech goes through its own session, never Spotify's, so playback is not touched.
    _synth.usesApplicationAudioSession = NO;
    return self;
}

- (BOOL)isSpeaking { return _synth.isSpeaking || _audio.isPlaying; }

- (void)finish {
    void (^f)(void) = _finished;
    _finished = nil;
    if (f) f();
}

- (void)stop {
    _token++;
    [_synth stopSpeakingAtBoundary:AVSpeechBoundaryImmediate];
    [_audio stop];
    _audio = nil;
    [self finish];
}

- (void)speak:(NSString *)text engine:(NSInteger)engineArg voice:(NSString *)voice started:(void (^)(void))started finished:(void (^)(void))finished {
    [self stop];
    NSUInteger token = ++_token;
    _finished = [finished copy];
    MRGVoiceEngine engine = engineArg >= 0 ? (MRGVoiceEngine)engineArg : MRGVoiceGetEngine();
    double speed = MRGVoiceSpeed();
    void (^play)(NSData *, NSString *, NSString *) = ^(NSData *audio, NSString *error, NSString *what) {
        if (token != self->_token) return;
        if (audio) {
            self->_audio = [[AVAudioPlayer alloc] initWithData:audio error:nil];
            self->_audio.delegate = self;
            if (self->_audio && [self->_audio play]) { if (started) started(); return; }
        }
        MRGDJLog(@"voice: %@ failed (%@), phone voice instead", what, error ?: @"unplayable audio");
        [self speakOnPhone:text voice:nil started:started];
    };
    if (engine == MRGVoiceEngineProvider && MRGProviderHasTTS(MRGAIProvider())) {
        MRGAISpeech(text, voice ?: MRGVoiceProviderVoice(), speed, ^(NSData *audio, NSString *error) { play(audio, error, MRGProviderName(MRGAIProvider())); });
        return;
    }
    if (engine == MRGVoiceEngineEleven && MRGElevenHasKey()) {
        elevenSpeech(text, voice ?: MRGElevenVoice(), speed, ^(NSData *audio, NSString *error) { play(audio, error, @"ElevenLabs"); });
        return;
    }
    [self speakOnPhone:text voice:(engine == MRGVoiceEnginePhone ? voice : nil) started:started];
}

- (void)speakOnPhone:(NSString *)text voice:(NSString *)identifier started:(void (^)(void))started {
    AVSpeechUtterance *u = [AVSpeechUtterance speechUtteranceWithString:text];
    u.voice = (identifier ? [AVSpeechSynthesisVoice voiceWithIdentifier:identifier] : nil) ?: MRGVoicePhoneVoice();
    float rate = AVSpeechUtteranceDefaultSpeechRate * (float)MRGVoiceSpeed();
    u.rate = MIN(AVSpeechUtteranceMaximumSpeechRate, MAX(AVSpeechUtteranceMinimumSpeechRate, rate));
    u.pitchMultiplier = (float)MRGVoicePitch();
    u.volume = 1.0f;
    u.preUtteranceDelay = 0.05;
    [_synth speakUtterance:u];
    if (started) started();
}

- (void)speechSynthesizer:(AVSpeechSynthesizer *)s didFinishSpeechUtterance:(AVSpeechUtterance *)u { [self finish]; }
- (void)speechSynthesizer:(AVSpeechSynthesizer *)s didCancelSpeechUtterance:(AVSpeechUtterance *)u { [self finish]; }
- (void)audioPlayerDidFinishPlaying:(AVAudioPlayer *)p successfully:(BOOL)flag { [self finish]; }
- (void)audioPlayerDecodeErrorDidOccur:(AVAudioPlayer *)p error:(NSError *)error { [self finish]; }

@end
