#import "MRGVoice.h"
#import "MRGAI.h"
#import "MRGKeychain.h"
#import "MRGDJLog.h"
#import "MRGDJ.h"

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

double MRGVoiceSpeed(void) { id v = [D() objectForKey:@"mirage.dj.speed"]; double s = [v isKindOfClass:NSNumber.class] ? [v doubleValue] : 1.0; return MIN(1.5, MAX(0.6, s)); }
void MRGVoiceSetSpeed(double s) { [D() setDouble:s forKey:@"mirage.dj.speed"]; }
double MRGVoicePitch(void) { id v = [D() objectForKey:@"mirage.dj.pitch"]; double p = [v isKindOfClass:NSNumber.class] ? [v doubleValue] : 1.0; return MIN(1.5, MAX(0.75, p)); }
void MRGVoiceSetPitch(double p) { [D() setDouble:p forKey:@"mirage.dj.pitch"]; }

static double num(NSString *k, double def, double lo, double hi) {
    id v = [D() objectForKey:k];
    double x = [v isKindOfClass:NSNumber.class] ? [v doubleValue] : def;
    return MIN(hi, MAX(lo, x));
}
double MRGVoiceWarmth(void) { return num(@"mirage.dj.voiceWarmth", 0.5, 0, 1); }
void MRGVoiceSetWarmth(double v) { [D() setDouble:v forKey:@"mirage.dj.voiceWarmth"]; }
double MRGVoiceBreathiness(void) { return num(@"mirage.dj.voiceBreath", 0, 0, 1); }
void MRGVoiceSetBreathiness(double v) { [D() setDouble:v forKey:@"mirage.dj.voiceBreath"]; }
double MRGVoicePause(void) { return num(@"mirage.dj.voicePause", 0.2, 0, 1.5); }
void MRGVoiceSetPause(double v) { [D() setDouble:v forKey:@"mirage.dj.voicePause"]; }
NSString *MRGVoiceStyleText(void) { NSString *t = [D() stringForKey:@"mirage.dj.voiceStyle"]; return t.length ? t : nil; }
void MRGVoiceSetStyleText(NSString *t) {
    NSString *x = [t stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (x.length) [D() setObject:[x substringToIndex:MIN(x.length, (NSUInteger)400)] forKey:@"mirage.dj.voiceStyle"];
    else [D() removeObjectForKey:@"mirage.dj.voiceStyle"];
}
double MRGElevenStability(void) { return num(@"mirage.dj.elevenStability", 0.5, 0, 1); }
void MRGElevenSetStability(double v) { [D() setDouble:v forKey:@"mirage.dj.elevenStability"]; }
double MRGElevenSimilarity(void) { return num(@"mirage.dj.elevenSimilarity", 0.75, 0, 1); }
void MRGElevenSetSimilarity(double v) { [D() setDouble:v forKey:@"mirage.dj.elevenSimilarity"]; }
static double elevenStyle(void) { return num(@"mirage.dj.elevenStyle", 0, 0, 1); }

NSString *MRGVoicePresetID(void) { return [D() stringForKey:@"mirage.dj.voicePreset"]; }
void MRGVoiceMarkCustom(void) { [D() removeObjectForKey:@"mirage.dj.voicePreset"]; }

// How to say the lines, for the engines that take a style (OpenAI's gpt-4o-mini-tts instructions, Gemini's prompt):
// the listener's own Voice style text, then words for the sliders. nil when everything is at its default.
NSString *MRGVoiceInstructions(void) {
    NSMutableArray *parts = [NSMutableArray array];
    NSString *custom = MRGVoiceStyleText();
    if (custom) [parts addObject:custom];
    double speed = MRGVoiceSpeed(), pitch = MRGVoicePitch(), warm = MRGVoiceWarmth(), breath = MRGVoiceBreathiness(), pause = MRGVoicePause();
    if (speed <= 0.8) [parts addObject:@"Speak slowly and unhurried."];
    else if (speed < 0.95) [parts addObject:@"Speak a little slower than normal, relaxed."];
    else if (speed >= 1.2) [parts addObject:@"Speak at a fast, energetic pace."];
    else if (speed > 1.05) [parts addObject:@"Speak at a brisk pace."];
    if (pitch < 0.95) [parts addObject:@"Use a slightly lower, deeper register."];
    else if (pitch > 1.08) [parts addObject:@"Use a slightly higher, brighter register."];
    if (warm >= 0.75) [parts addObject:@"Very warm, gentle and intimate, like talking to one person you care about."];
    else if (warm >= 0.45 && warm != 0.5) [parts addObject:@"Warm and friendly."];
    else if (warm < 0.25) [parts addObject:@"Crisp and neutral."];
    if (breath >= 0.6) [parts addObject:@"Soft and breathy, close to the mic, trailing off gently at the ends of sentences."];
    else if (breath >= 0.3) [parts addObject:@"A little airy and soft."];
    if (pause >= 0.6) [parts addObject:@"Leave calm, noticeable pauses between sentences."];
    else if (pause >= 0.35) [parts addObject:@"Leave short, natural pauses between sentences."];
    if (!parts.count) return nil;
    NSString *joined = [parts componentsJoinedByString:@" "];
    return joined.length > 700 ? [joined substringToIndex:700] : joined;
}

#pragma mark - presets

// id, name, blurb, speed, pitch, warmth, breathiness, pause, style, persona, voices per engine (OpenAI, Gemini, Groq,
// xAI), ElevenLabs names to look for in the account, the iPhone voice's gender, ElevenLabs stability / similarity / style.
NSArray<NSDictionary *> *MRGVoicePresets(void) {
    static NSArray *list;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        list = @[
            @{@"id": @"soothing", @"name": @"Soft & Soothing", @"blurb": @"Slow, warm, soothing female voice, close and calm.",
              @"speed": @0.85, @"pitch": @0.92, @"warmth": @0.95, @"breath": @0.55, @"pause": @0.6, @"persona": @6,
              @"style": @"A soft, soothing, warm female voice: slow, gentle and intimate, close to the mic, calm and reassuring, with a hint of a smile. Never loud, never rushed.",
              @"openai": @"shimmer", @"gemini": @"Achernar", @"groq": @"diana", @"xai": @"ara",
              @"eleven": @[@"Sarah", @"Lily", @"Matilda", @"Alice", @"Jessica", @"Laura", @"Charlotte", @"Rachel"], @"gender": @"female",
              @"stability": @0.7, @"similarity": @0.8, @"elStyle": @0.15},
            @{@"id": @"hype", @"name": @"Hype Radio DJ", @"blurb": @"Loud, fast, big energy.",
              @"speed": @1.15, @"pitch": @1.05, @"warmth": @0.4, @"breath": @0.0, @"pause": @0.15, @"persona": @2,
              @"style": @"A high-energy radio DJ: punchy, excited and confident, big smile, hits the artist names hard, fast pace.",
              @"openai": @"ash", @"gemini": @"Fenrir", @"groq": @"troy", @"xai": @"rex",
              @"eleven": @[@"Liam", @"Charlie", @"Will", @"Chris", @"Josh", @"Adam"], @"gender": @"male",
              @"stability": @0.3, @"similarity": @0.75, @"elStyle": @0.45},
            @{@"id": @"latenight", @"name": @"Late Night", @"blurb": @"Low, smooth and slow, like 2 a.m. radio.",
              @"speed": @0.9, @"pitch": @0.93, @"warmth": @0.85, @"breath": @0.35, @"pause": @0.5, @"persona": @1,
              @"style": @"A late-night radio host: low, smooth, velvety and relaxed, like it's 2 a.m.; slow, intimate, quiet confidence.",
              @"openai": @"onyx", @"gemini": @"Algieba", @"groq": @"daniel", @"xai": @"leo",
              @"eleven": @[@"Brian", @"Daniel", @"George", @"Bill", @"Eric"], @"gender": @"male",
              @"stability": @0.6, @"similarity": @0.8, @"elStyle": @0.2},
            @{@"id": @"narrator", @"name": @"Chill Narrator", @"blurb": @"Calm, clear and easygoing.",
              @"speed": @0.95, @"pitch": @1.0, @"warmth": @0.6, @"breath": @0.1, @"pause": @0.4, @"persona": @4,
              @"style": @"A calm, clear, friendly narrator: easygoing and even, like a documentary voice-over by someone who loves music.",
              @"openai": @"sage", @"gemini": @"Callirrhoe", @"groq": @"austin", @"xai": @"sal",
              @"eleven": @[@"George", @"Alice", @"Matilda", @"Brian"], @"gender": @"",
              @"stability": @0.6, @"similarity": @0.75, @"elStyle": @0.1},
            @{@"id": @"classic", @"name": @"Classic Spotify DJ", @"blurb": @"Friendly, casual, like Spotify's own DJ.",
              @"speed": @1.0, @"pitch": @1.0, @"warmth": @0.6, @"breath": @0.0, @"pause": @0.3, @"persona": @0,
              @"style": @"A friendly, casual music host like Spotify's DJ: upbeat but relaxed, warm and genuine, conversational, like a friend who knows your taste.",
              @"openai": @"ash", @"gemini": @"Puck", @"groq": @"troy", @"xai": @"eve",
              @"eleven": @[@"Chris", @"Liam", @"Brian", @"Eric"], @"gender": @"male",
              @"stability": @0.45, @"similarity": @0.75, @"elStyle": @0.25},
        ];
    });
    return list;
}

// The best installed iPhone voice of a gender (personal, Premium, Enhanced first), or nil.
static AVSpeechSynthesisVoice *bestPhoneVoice(NSString *gender) {
    if (!gender.length) return nil;
    AVSpeechSynthesisVoiceGender want = [gender isEqualToString:@"female"] ? AVSpeechSynthesisVoiceGenderFemale : AVSpeechSynthesisVoiceGenderMale;
    for (AVSpeechSynthesisVoice *v in MRGVoicePhoneVoices()) {
        if (![v.language hasPrefix:@"en"]) continue;
        if ([v respondsToSelector:@selector(gender)] && v.gender == want) return v;
    }
    return nil;
}

NSString *MRGVoiceApplyPreset(NSString *pid) {
    NSDictionary *p = nil;
    for (NSDictionary *x in MRGVoicePresets()) if ([x[@"id"] isEqualToString:pid]) p = x;
    if (!p) return nil;
    MRGVoiceSetSpeed([p[@"speed"] doubleValue]);
    MRGVoiceSetPitch([p[@"pitch"] doubleValue]);
    MRGVoiceSetWarmth([p[@"warmth"] doubleValue]);
    MRGVoiceSetBreathiness([p[@"breath"] doubleValue]);
    MRGVoiceSetPause([p[@"pause"] doubleValue]);
    MRGVoiceSetStyleText(p[@"style"]);
    MRGElevenSetStability([p[@"stability"] doubleValue]);
    MRGElevenSetSimilarity([p[@"similarity"] doubleValue]);
    [D() setDouble:[p[@"elStyle"] doubleValue] forKey:@"mirage.dj.elevenStyle"];
    NSInteger persona = [p[@"persona"] integerValue];
    if (persona >= 0 && persona < (NSInteger)MRGDJPersonaNames().count) MRGDJSetPersona(persona);
    NSMutableArray *what = [NSMutableArray array];
    MRGProvider prov = MRGAIProvider();
    NSString *key = prov == MRGProviderOpenAI ? @"openai" : prov == MRGProviderGemini ? @"gemini" : prov == MRGProviderGroq ? @"groq" : prov == MRGProviderXAI ? @"xai" : nil;
    if (key && MRGProviderHasTTS(prov)) { MRGVoiceSetProviderVoice(p[key]); [what addObject:[NSString stringWithFormat:@"%@ voice %@", MRGProviderName(prov), p[key]]]; }
    for (NSString *want in p[@"eleven"]) {
        NSDictionary *hit = nil;
        for (NSDictionary *v in MRGElevenVoices()) if ([[v[@"name"] lowercaseString] hasPrefix:want.lowercaseString]) { hit = v; break; }
        if (hit) { MRGElevenSetVoice(hit[@"id"]); [what addObject:[@"ElevenLabs " stringByAppendingString:hit[@"name"]]]; break; }
    }
    AVSpeechSynthesisVoice *phone = bestPhoneVoice(p[@"gender"]);
    if (phone) { MRGVoiceSetPhoneVoice(phone.identifier); [what addObject:[@"iPhone " stringByAppendingString:phone.name]]; }
    [D() setObject:pid forKey:@"mirage.dj.voicePreset"];
    MRGDJLog(@"voice: preset %@ (%@)", p[@"name"], what.count ? [what componentsJoinedByString:@", "] : @"settings only");
    return what.count ? [what componentsJoinedByString:@" · "] : nil;
}

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
        NSDictionary *body = @{@"text": text, @"model_id": model,
                               @"voice_settings": @{@"speed": @(MIN(1.2, MAX(0.7, speed))), @"stability": @(MRGElevenStability()),
                                                    @"similarity_boost": @(MRGElevenSimilarity()), @"style": @(elevenStyle()), @"use_speaker_boost": @YES}};
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

static NSString *engineSummary(void);
NSString *MRGVoiceSummary(void) {
    NSString *pid = MRGVoicePresetID(), *name = nil;
    for (NSDictionary *p in MRGVoicePresets()) if ([p[@"id"] isEqualToString:pid]) name = p[@"name"];
    NSString *e = engineSummary();
    return name && MRGVoiceGetEngine() != MRGVoiceEngineOff ? [NSString stringWithFormat:@"%@ · %@", name, e] : e;
}
static NSString *engineSummary(void) {
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

static NSArray<NSString *> *sentences(NSString *text) {
    NSMutableArray *out = [NSMutableArray array];
    [text enumerateSubstringsInRange:NSMakeRange(0, text.length) options:NSStringEnumerationBySentences usingBlock:^(NSString *sub, NSRange r, NSRange er, BOOL *stop) {
        NSString *t = [sub stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (t.length) [out addObject:t];
    }];
    return out.count ? out : @[text];
}

// The sentences joined with `mark` after each (an ellipsis, or an ElevenLabs <break/>).
static NSString *withPauses(NSString *text, NSString *mark) {
    NSArray<NSString *> *s = sentences(text);
    if (s.count < 2) return text;
    NSMutableString *out = [NSMutableString string];
    for (NSUInteger i = 0; i < s.count; i++) {
        NSString *x = s[i];
        if (i + 1 == s.count) { [out appendString:x]; break; }
        if ([mark isEqualToString:@"..."] && [x hasSuffix:@"."]) x = [x substringToIndex:x.length - 1];
        [out appendFormat:@"%@%@ ", x, mark];
    }
    return out;
}

@interface MRGVoiceSpeaker () <AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate>
@end

@implementation MRGVoiceSpeaker {
    AVSpeechSynthesizer *_synth;
    AVAudioPlayer *_audio;
    void (^_finished)(void);
    NSUInteger _token;
    NSUInteger _pending;
    AVSpeechUtterance *_lastUtterance;
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
    double pause = MRGVoicePause();
    if (engine == MRGVoiceEngineProvider && MRGProviderHasTTS(MRGAIProvider())) {
        MRGProvider p = MRGAIProvider();
        // Engines without a style prompt get their pauses as ellipses.
        NSString *said = (p == MRGProviderGroq || p == MRGProviderXAI) && pause >= 0.5 ? withPauses(text, @"...") : text;
        MRGAISpeech(said, voice ?: MRGVoiceProviderVoice(), speed, MRGVoiceInstructions(), ^(NSData *audio, NSString *error) { play(audio, error, MRGProviderName(MRGAIProvider())); });
        return;
    }
    if (engine == MRGVoiceEngineEleven && MRGElevenHasKey()) {
        NSString *said = pause >= 0.3 ? withPauses(text, [NSString stringWithFormat:@" <break time=\"%.1fs\" />", MIN(1.5, pause)]) : text;
        elevenSpeech(said, voice ?: MRGElevenVoice(), speed, ^(NSData *audio, NSString *error) { play(audio, error, @"ElevenLabs"); });
        return;
    }
    [self speakOnPhone:text voice:(engine == MRGVoiceEnginePhone ? voice : nil) started:started];
}

// Sentence by sentence, with the pause setting after each (the last one ends the line).
- (void)speakOnPhone:(NSString *)text voice:(NSString *)identifier started:(void (^)(void))started {
    AVSpeechSynthesisVoice *voice = (identifier ? [AVSpeechSynthesisVoice voiceWithIdentifier:identifier] : nil) ?: MRGVoicePhoneVoice();
    float rate = AVSpeechUtteranceDefaultSpeechRate * (float)MRGVoiceSpeed();
    double pause = MRGVoicePause();
    NSArray *parts = pause >= 0.1 ? sentences(text) : @[text];
    _pending = parts.count;
    _lastUtterance = nil;
    for (NSUInteger i = 0; i < parts.count; i++) {
        AVSpeechUtterance *u = [AVSpeechUtterance speechUtteranceWithString:parts[i]];
        u.voice = voice;
        u.rate = MIN(AVSpeechUtteranceMaximumSpeechRate, MAX(AVSpeechUtteranceMinimumSpeechRate, rate));
        u.pitchMultiplier = (float)MRGVoicePitch();
        u.volume = 1.0f;
        u.preUtteranceDelay = i == 0 ? 0.05 : 0;
        if (i + 1 < parts.count) u.postUtteranceDelay = pause;
        [_synth speakUtterance:u];
        _lastUtterance = u;
    }
    if (started) started();
}

- (void)speechSynthesizer:(AVSpeechSynthesizer *)s didFinishSpeechUtterance:(AVSpeechUtterance *)u {
    if (_lastUtterance && u != _lastUtterance) return;   // more sentences to come
    [self finish];
}
- (void)speechSynthesizer:(AVSpeechSynthesizer *)s didCancelSpeechUtterance:(AVSpeechUtterance *)u { [self finish]; }
- (void)audioPlayerDidFinishPlaying:(AVAudioPlayer *)p successfully:(BOOL)flag { [self finish]; }
- (void)audioPlayerDecodeErrorDidOccur:(AVAudioPlayer *)p error:(NSError *)error { [self finish]; }

@end
