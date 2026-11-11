#import "MRGVoice.h"
#import "MRGAI.h"
#import "MRGKeychain.h"
#import "MRGDJLog.h"
#import "MRGDJ.h"
#import "MRGVoiceNet.h"

static NSUserDefaults *D(void) { return NSUserDefaults.standardUserDefaults; }
static NSString *const kEleven = @"elevenlabs-key";
NSString *const MRGVoiceResultNotification = @"MirageVoiceResult";

MRGVoiceEngine MRGVoiceGetEngine(void) {
    id v = [D() objectForKey:@"mirage.dj.voiceEngine"];
    if (![v isKindOfClass:NSNumber.class]) v = nil;
    if (v) { NSInteger e = [v integerValue]; return (e >= 0 && e <= 5 && e != 4) ? e : MRGVoiceEngineFree; }   // 4 was Qwen (0.5.0), gone in 0.5.1
    // 0.2.x kept 0 phone, 1 provider, 2 off; nothing saved: the free voices.
    id old = [D() objectForKey:@"mirage.dj.voice"];
    if (![old isKindOfClass:NSNumber.class]) return MRGVoiceEngineFree;
    return [old integerValue] == 2 ? MRGVoiceEngineOff : [old integerValue] == 1 ? MRGVoiceEngineProvider : MRGVoiceEnginePhone;
}
void MRGVoiceSetEngine(MRGVoiceEngine e) { [D() setInteger:e forKey:@"mirage.dj.voiceEngine"]; }
void MRGVoiceChooseEngine(MRGVoiceEngine e) { MRGVoiceSetEngine(e); [D() setBool:YES forKey:@"mirage.dj.engineChosen"]; }
NSString *MRGVoiceEngineName(MRGVoiceEngine e) {
    switch (e) {
        case MRGVoiceEnginePhone: return @"iPhone";
        case MRGVoiceEngineProvider: return MRGProviderName(MRGAIProvider());
        case MRGVoiceEngineEleven: return @"ElevenLabs";
        case MRGVoiceEngineFree: return @"Free (Microsoft Edge voices, unofficial)";
        default: return @"Off";
    }
}

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
            @{@"edge": @"en-US-JennyNeural", @"edgeVol": @0.9, @"id": @"soothing", @"name": @"Soft & Soothing", @"blurb": @"Slow, warm, soothing female voice, close and calm.",
              @"speed": @0.85, @"pitch": @0.92, @"warmth": @0.95, @"breath": @0.55, @"pause": @0.6, @"persona": @6,
              @"style": @"A soft, soothing, warm female voice: slow, gentle and intimate, close to the mic, calm and reassuring, with a hint of a smile. Never loud, never rushed.",
              @"openai": @"shimmer", @"gemini": @"Achernar", @"groq": @"diana", @"xai": @"ara",
              @"eleven": @[@"Sarah", @"Lily", @"Matilda", @"Alice", @"Jessica", @"Laura", @"Charlotte", @"Rachel"], @"gender": @"female",
              @"stability": @0.7, @"similarity": @0.8, @"elStyle": @0.15},
            // Alex's pick for his first sample: ElevenLabs "Ivy" (low, soft, slow, close-mic, calm, a bit caring and bossy).
            @{@"edge": @"en-US-AvaNeural", @"edgeVol": @0.85, @"id": @"velvet", @"name": @"Soft & Close", @"blurb": @"Low, soft and slow, right at the mic; calm, caring, a little bossy (ElevenLabs Ivy).",
              @"speed": @0.84, @"pitch": @0.95, @"warmth": @1.0, @"breath": @0.6, @"pause": @0.8,
              @"style": @"A low, soft, slow female voice right at the mic: calm and caring with a gentle, slightly bossy confidence, short phrases with unhurried pauses, a narrow calm melody and a soft smile. Never loud, never bright, never rushed.",
              @"openai": @"shimmer", @"gemini": @"Sulafat", @"groq": @"autumn", @"xai": @"ara",
              @"elevenID": @"KhpuFRhu6kfNvpalcYtz", @"elevenIDName": @"Ivy",
              @"phone": @[@"Ava", @"Zoe", @"Samantha"], @"gender": @"female",
              @"stability": @0.75, @"similarity": @0.8, @"elStyle": @0.1},
            // ElevenLabs' classic "Nicole": a soft, breathy, intimate whisper.
            @{@"edge": @"en-US-AvaMultilingualNeural", @"edgeVol": @0.7, @"edgeSpeed": @0.8, @"edgePitch": @0.94, @"id": @"whisper", @"name": @"Classic Whisper", @"blurb": @"Soft, breathy, intimate whisper (ElevenLabs Nicole).",
              @"speed": @0.88, @"pitch": @1.05, @"warmth": @0.8, @"breath": @0.95, @"pause": @0.6,
              @"style": @"Whisper the whole time: a soft, breathy, intimate ASMR whisper, light and high, very close to the mic, calm, gentle and hushed, every word unhurried. Never use a normal speaking voice.",
              @"openai": @"shimmer", @"gemini": @"Achernar", @"groq": @"diana", @"xai": @"ara",
              @"elevenID": @"piTKgcLEGmPE4e6mEKli", @"elevenIDName": @"Nicole",
              @"phone": @[@"Zoe", @"Ava", @"Samantha"], @"gender": @"female",
              @"stability": @0.6, @"similarity": @0.8, @"elStyle": @0.0},
            // Modeled on Alex's second sample (ElevenLabs "Arabella" v3 demo: young bright American female, very expressive).
            @{@"edge": @"en-US-EmmaMultilingualNeural", @"edgeVol": @1.0, @"id": @"spark", @"name": @"Playful Spark", @"blurb": @"Young, bright and super expressive; laughs, whispers, big swings.",
              @"speed": @1.06, @"pitch": @1.05, @"warmth": @0.6, @"breath": @0.25, @"pause": @0.35, @"persona": @0,
              @"style": @"A young, bright American female voice, playful and very expressive: big pitch swings, quick excited delivery that drops to a conspiratorial whisper, little laughs and giggles, dramatic pauses before the reveal, sounds amazed by everything, like a friend gushing about a song.",
              @"openai": @"coral", @"gemini": @"Zephyr", @"groq": @"hannah", @"xai": @"eve",
              @"elevenID": @"Z3R5wn05IrDiVCyEkUrK", @"elevenIDName": @"Arabella",
              @"phone": @[@"Zoe", @"Ava", @"Nicky"], @"gender": @"female",
              @"stability": @0.3, @"similarity": @0.75, @"elStyle": @0.55},
            @{@"edge": @"en-US-GuyNeural", @"id": @"hype", @"name": @"Hype Radio DJ", @"blurb": @"Loud, fast, big energy.",
              @"speed": @1.15, @"pitch": @1.05, @"warmth": @0.4, @"breath": @0.0, @"pause": @0.15, @"persona": @2,
              @"style": @"A high-energy radio DJ: punchy, excited and confident, big smile, hits the artist names hard, fast pace.",
              @"openai": @"ash", @"gemini": @"Fenrir", @"groq": @"troy", @"xai": @"rex",
              @"eleven": @[@"Liam", @"Charlie", @"Will", @"Chris", @"Josh", @"Adam"], @"gender": @"male",
              @"stability": @0.3, @"similarity": @0.75, @"elStyle": @0.45},
            @{@"edge": @"en-US-ChristopherNeural", @"id": @"latenight", @"name": @"Late Night", @"blurb": @"Low, smooth and slow, like 2 a.m. radio.",
              @"speed": @0.9, @"pitch": @0.93, @"warmth": @0.85, @"breath": @0.35, @"pause": @0.5, @"persona": @1,
              @"style": @"A late-night radio host: low, smooth, velvety and relaxed, like it's 2 a.m.; slow, intimate, quiet confidence.",
              @"openai": @"onyx", @"gemini": @"Algieba", @"groq": @"daniel", @"xai": @"leo",
              @"eleven": @[@"Brian", @"Daniel", @"George", @"Bill", @"Eric"], @"gender": @"male",
              @"stability": @0.6, @"similarity": @0.8, @"elStyle": @0.2},
            @{@"edge": @"en-US-BrianMultilingualNeural", @"id": @"narrator", @"name": @"Chill Narrator", @"blurb": @"Calm, clear and easygoing.",
              @"speed": @0.95, @"pitch": @1.0, @"warmth": @0.6, @"breath": @0.1, @"pause": @0.4, @"persona": @4,
              @"style": @"A calm, clear, friendly narrator: easygoing and even, like a documentary voice-over by someone who loves music.",
              @"openai": @"sage", @"gemini": @"Callirrhoe", @"groq": @"austin", @"xai": @"sal",
              @"eleven": @[@"George", @"Alice", @"Matilda", @"Brian"], @"gender": @"",
              @"stability": @0.6, @"similarity": @0.75, @"elStyle": @0.1},
            @{@"edge": @"en-US-AndrewNeural", @"id": @"classic", @"name": @"Classic Spotify DJ", @"blurb": @"Friendly, casual, like Spotify's own DJ.",
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
    // Voice only: a preset never changes the DJ's persona or the music (0.4.2's "Soft & soothing" persona leaked into
    // the sets: "a quiet flow", "a soft pulse").
    NSMutableArray *what = [NSMutableArray array];
    MRGProvider prov = MRGAIProvider();
    NSString *key = prov == MRGProviderOpenAI ? @"openai" : prov == MRGProviderGemini ? @"gemini" : prov == MRGProviderGroq ? @"groq" : prov == MRGProviderXAI ? @"xai" : nil;
    // Groq's voices (Orpheus) need their terms accepted in the Groq console first (HTTP 400 otherwise), so a preset
    // never sets one up; the provider voice stays what the listener picked.
    if (key && prov != MRGProviderGroq && MRGProviderHasTTS(prov)) { MRGVoiceSetProviderVoice(p[key]); [what addObject:[NSString stringWithFormat:@"%@ voice %@", MRGProviderName(prov), p[key]]]; }
    BOOL elevenSet = NO;
    [D() removeObjectForKey:@"mirage.dj.elevenNeedsAdd"];
    NSDictionary *override = [D() dictionaryForKey:[@"mirage.dj.presetVoice." stringByAppendingString:pid]];
    if ([override[@"id"] isKindOfClass:NSString.class]) {
        NSMutableDictionary *m = [p mutableCopy];
        m[@"elevenID"] = override[@"id"];
        if ([override[@"name"] isKindOfClass:NSString.class]) m[@"elevenIDName"] = override[@"name"];
        p = m;
    }
    // The free voice of the preset, with its own loudness (and for the whisper a slower, lower read: Microsoft's free
    // voices have no whisper style, so it is quiet, slow and a touch lower instead).
    if ([p[@"edge"] length]) { MRGEdgeSetVoice(p[@"edge"]); [what addObject:[@"Free voice " stringByAppendingString:[[p[@"edge"] componentsSeparatedByString:@"-"].lastObject stringByReplacingOccurrencesOfString:@"Neural" withString:@""]]]; }
    [D() setDouble:p[@"edgeVol"] ? [p[@"edgeVol"] doubleValue] : 1.0 forKey:@"mirage.dj.edgeVolume"];
    if (p[@"edgeSpeed"]) MRGVoiceSetSpeed([p[@"edgeSpeed"] doubleValue]);
    if (p[@"edgePitch"]) MRGVoiceSetPitch([p[@"edgePitch"] doubleValue]);
    // 0.5.1: every preset speaks with the free voices; only the iPhone voice, if the listener picked it, stays (paid
    // engines failed for Alex: ElevenLabs' free plan refuses library voices, Qwen wants a $1 card check).
    MRGVoiceEngine current = MRGVoiceGetEngine();
    BOOL keep = [D() boolForKey:@"mirage.dj.engineChosen"] && current == MRGVoiceEnginePhone;
    if (!keep) MRGVoiceSetEngine(MRGVoiceEngineFree);
    if ([p[@"elevenID"] length] && MRGKeychainGet(kEleven).length) {
        // The voice Alex picked, by its ID: never silently swapped for another. Shared-library voices that aren't in his
        // ElevenLabs voices yet work by ID on paid plans; otherwise the voice page offers "Add to my ElevenLabs".
        NSString *vid = p[@"elevenID"], *vname = p[@"elevenIDName"] ?: vid;
        BOOL mine = NO;
        for (NSDictionary *v in MRGElevenVoices()) if ([v[@"id"] isEqualToString:vid]) mine = YES;
        MRGElevenSetVoice(vid);
        elevenSet = YES;
        [what addObject:[NSString stringWithFormat:@"ElevenLabs %@%@", vname, mine ? @"" : @" (by ID, not in your voices)"]];
        if (!mine && MRGVoiceGetEngine() == MRGVoiceEngineEleven) {
            [D() setObject:@{@"id": vid, @"name": vname} forKey:@"mirage.dj.elevenNeedsAdd"];
            MRGDJLog(@"voice: ElevenLabs %@ (%@) isn't in your ElevenLabs voices; using it by ID. If it fails, add it in ElevenLabs → Voice Library (or Add to my ElevenLabs on the voice page).", vname, vid);
        }
    }
    for (NSString *want in elevenSet ? @[] : p[@"eleven"]) {
        NSDictionary *hit = nil;
        for (NSDictionary *v in MRGElevenVoices()) if ([[v[@"name"] lowercaseString] hasPrefix:want.lowercaseString]) { hit = v; break; }
        if (hit) { MRGElevenSetVoice(hit[@"id"]); [what addObject:[@"ElevenLabs " stringByAppendingString:hit[@"name"]]]; elevenSet = YES; break; }
    }
    AVSpeechSynthesisVoice *phone = nil;
    for (NSString *want in p[@"phone"]) {
        for (AVSpeechSynthesisVoice *v in MRGVoicePhoneVoices())
            if ([v.language hasPrefix:@"en"] && [v.name.lowercaseString hasPrefix:want.lowercaseString]) { phone = v; break; }
        if (phone) break;
    }
    if (!phone) phone = bestPhoneVoice(p[@"gender"]);
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

// ElevenLabs' errors are {"detail": {"type", "code", "status", "message"}} (or a string / validation list). The text
// says what it means in plain words, then ElevenLabs' own message, status code and code; the full body is logged.
static NSString *elevenError(NSInteger status, NSData *data, NSError *error) {
    if (error) return [@"ElevenLabs: " stringByAppendingString:error.localizedDescription ?: @"network error"];
    id j = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    NSString *detail = nil, *code = nil;
    id d = [j isKindOfClass:NSDictionary.class] ? j[@"detail"] : nil;
    if ([d isKindOfClass:NSDictionary.class]) {
        if ([d[@"message"] isKindOfClass:NSString.class]) detail = d[@"message"];
        if ([d[@"status"] isKindOfClass:NSString.class]) code = d[@"status"];
        else if ([d[@"code"] isKindOfClass:NSString.class]) code = d[@"code"];
    } else if ([d isKindOfClass:NSString.class]) detail = d;
    else if ([d isKindOfClass:NSArray.class] && [[d firstObject] isKindOfClass:NSDictionary.class] && [[d firstObject][@"msg"] isKindOfClass:NSString.class]) detail = [d firstObject][@"msg"];
    NSString *body = data.length ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"";
    MRGDJLog(@"voice: ElevenLabs HTTP %ld body: %@", (long)status, body.length > 600 ? [body substringToIndex:600] : body);
    NSString *lower = [[NSString stringWithFormat:@"%@ %@", code ?: @"", detail ?: @""] lowercaseString];
    NSString *meaning = nil;
    if (status == 402 || [lower containsString:@"paid_plan"] || [lower containsString:@"free_users"] || [lower containsString:@"payment"])
        meaning = @"library voices need a paid ElevenLabs plan through the API";
    else if (status == 404 || [lower containsString:@"voice_not_found"] || [lower containsString:@"not found"])
        meaning = @"this voice isn't available to your account (add it in ElevenLabs → Voice Library, or it was retired)";
    else if (status == 401) meaning = @"the key was refused (check it, and its Text to Speech permission)";
    else if (status == 429) meaning = @"too many requests or out of credits for now";
    else if ([lower containsString:@"quota"] || [lower containsString:@"credits"]) meaning = @"out of credits";
    return [NSString stringWithFormat:@"ElevenLabs: %@%@ (HTTP %ld%@)", meaning ?: @"request refused", detail ? [@". " stringByAppendingString:detail] : @"",
            (long)status, code ? [@", " stringByAppendingString:code] : @""];
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
        if (MRGVoiceGetEngine() == MRGVoiceEngineEleven) MRGVoiceSetEngine(MRGVoiceEngineFree);
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

// The preset voice the account doesn't have yet ({id, name, error?}), or nil.
NSDictionary *MRGElevenNeedsAdd(void) {
    NSDictionary *n = [D() dictionaryForKey:@"mirage.dj.elevenNeedsAdd"];
    if (![n[@"id"] isKindOfClass:NSString.class]) return nil;
    for (NSDictionary *v in MRGElevenVoices()) if ([v[@"id"] isEqualToString:n[@"id"]]) return nil;
    return n;
}

// GET /v1/shared-voices (needs a key; filters are refused when logged out): the library's voices for a search.
static void sharedSearch(NSString *query, NSString *extra, void (^done)(NSArray<NSDictionary *> *voices, NSString *error)) {
    NSString *key = MRGKeychainGet(kEleven);
    if (!key.length) { done(nil, @"Add your ElevenLabs key first."); return; }
    NSString *q = [query stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.alphanumericCharacterSet] ?: @"";
    NSString *path = [NSString stringWithFormat:@"/v1/shared-voices?page_size=100&search=%@%@", q, extra ?: @""];
    [[NSURLSession.sharedSession dataTaskWithRequest:elevenRequest(path, key, nil) completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
        NSInteger status = [resp isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)resp).statusCode : 0;
        id j = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSMutableArray *out = [NSMutableArray array];
        id list = [j isKindOfClass:NSDictionary.class] ? j[@"voices"] : nil;
        for (id v in [list isKindOfClass:NSArray.class] ? list : @[]) if ([v isKindOfClass:NSDictionary.class] && [v[@"voice_id"] isKindOfClass:NSString.class]) [out addObject:v];
        NSString *err = (error || status < 200 || status >= 300) ? elevenError(status, data, error) : nil;
        dispatch_async(dispatch_get_main_queue(), ^{ done(err ? nil : out, err); });
    }] resume];
}

// POST /v1/voices/add/{public_user_id}/{voice_id} with {"new_name"}: the voice goes into the account's voices.
static void addShared(NSString *owner, NSString *voiceID, NSString *name, void (^done)(BOOL ok, NSString *message)) {
    NSString *key = MRGKeychainGet(kEleven);
    NSString *addPath = [NSString stringWithFormat:@"/v1/voices/add/%@/%@", owner, voiceID];
    [[NSURLSession.sharedSession dataTaskWithRequest:elevenRequest(addPath, key, @{@"new_name": name ?: voiceID}) completionHandler:^(NSData *d2, NSURLResponse *r2, NSError *e2) {
        NSInteger s2 = [r2 isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)r2).statusCode : 0;
        BOOL ok = !e2 && s2 >= 200 && s2 < 300;
        NSString *msg = ok ? [NSString stringWithFormat:@"%@ was added to your ElevenLabs voices.", name ?: voiceID] : elevenError(s2, d2, e2);
        MRGDJLog(@"voice: add %@ (%@) → HTTP %ld %@", name, voiceID, (long)s2, ok ? @"added" : msg);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!ok) { done(NO, msg); return; }
            [D() removeObjectForKey:@"mirage.dj.elevenNeedsAdd"];
            MRGElevenRefreshVoices(^(NSArray<NSDictionary *> *voices, NSString *err) { done(YES, msg); });
        });
    }] resume];
}

// Adds a shared Voice Library voice to the user's ElevenLabs voices with their own key: finds its public_owner_id with
// a shared-voices search for its name, then adds it. Only on the user's own choice (a preset tap or the Add button).
void MRGElevenAddShared(NSString *voiceID, NSString *name, void (^done)(BOOL ok, NSString *message)) {
    if (!MRGElevenHasKey() || !voiceID.length) { done(NO, @"Add your ElevenLabs key first."); return; }
    sharedSearch(name ?: voiceID, nil, ^(NSArray<NSDictionary *> *voices, NSString *error) {
        if (error) { done(NO, error); return; }
        NSString *owner = nil;
        for (NSDictionary *v in voices) if ([v[@"voice_id"] isEqualToString:voiceID] && [v[@"public_owner_id"] isKindOfClass:NSString.class]) owner = v[@"public_owner_id"];
        if (!owner) {
            NSString *msg = [NSString stringWithFormat:@"%@ (%@) isn't in ElevenLabs' Voice Library (retired or private).", name ?: voiceID, voiceID];
            MRGDJLog(@"voice: add: %@", msg);
            done(NO, msg);
            return;
        }
        addShared(owner, voiceID, name, done);
    });
}

// Before a preset's first line: if its ElevenLabs voice isn't in the account, add it (the tap is the user's choice).
// Nicole (piTKgcLEGmPE4e6mEKli) is one of ElevenLabs' old default voices, which are being retired: when the library
// doesn't have her, the closest current whisper voice from a shared-voices search takes her place for that preset.
void MRGVoicePreparePreset(NSString *pid, void (^done)(NSString *message)) {
    NSDictionary *p = nil;
    for (NSDictionary *x in MRGVoicePresets()) if ([x[@"id"] isEqualToString:pid]) p = x;
    NSDictionary *need = MRGElevenNeedsAdd();
    if (!p || !need || !MRGElevenHasKey() || MRGVoiceGetEngine() != MRGVoiceEngineEleven) { done(nil); return; }
    MRGElevenAddShared(need[@"id"], need[@"name"], ^(BOOL ok, NSString *message) {
        if (ok || ![pid isEqualToString:@"whisper"] || ![message containsString:@"isn't in ElevenLabs' Voice Library"]) { done(message); return; }
        sharedSearch(@"whisper", @"&gender=female&language=en", ^(NSArray<NSDictionary *> *voices, NSString *error) {
            NSDictionary *pick = nil;
            for (NSDictionary *v in voices) {
                NSString *text = [[NSString stringWithFormat:@"%@ %@ %@", v[@"name"] ?: @"", v[@"description"] ?: @"", v[@"descriptive"] ?: @""] lowercaseString];
                if ([v[@"public_owner_id"] isKindOfClass:NSString.class] && ([text containsString:@"whisper"] || [text containsString:@"asmr"])) { pick = v; break; }
            }
            if (!pick) { done([message stringByAppendingFormat:@" No current whisper voice found to replace her%@.", error ? [@" (" stringByAppendingFormat:@"%@)", error] : @""]); return; }
            NSString *name = [pick[@"name"] isKindOfClass:NSString.class] ? pick[@"name"] : @"Whisper";
            MRGDJLog(@"voice: Nicole is retired; Classic Whisper uses %@ (%@) from the Voice Library instead", name, pick[@"voice_id"]);
            [D() setObject:@{@"id": pick[@"voice_id"], @"name": name} forKey:@"mirage.dj.presetVoice.whisper"];
            MRGVoiceApplyPreset(pid);
            addShared(pick[@"public_owner_id"], pick[@"voice_id"], name, ^(BOOL ok2, NSString *m2) {
                done([NSString stringWithFormat:@"Nicole is retired; using %@ instead. %@", name, m2 ?: @""]);
            });
        });
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
    void (^finish)(NSData *, NSInteger, NSString *) = ^(NSData *d, NSInteger st, NSString *e) {
        if (!d && st >= 400 && st < 500) {
            BOOL mine = NO;
            for (NSDictionary *v in MRGElevenVoices()) if ([v[@"id"] isEqualToString:voice]) mine = YES;
            if (!mine) {
                NSString *name = voice;
                for (NSDictionary *p in MRGVoicePresets()) if ([p[@"elevenID"] isEqualToString:voice]) name = p[@"elevenIDName"] ?: voice;
                NSString *msg = [NSString stringWithFormat:@"ElevenLabs refused %@ (HTTP %ld): it isn't in your ElevenLabs voices. Add it in ElevenLabs → Voice Library, or tap Add to my ElevenLabs below.", name, (long)st];
                [D() setObject:@{@"id": voice, @"name": name, @"error": msg} forKey:@"mirage.dj.elevenNeedsAdd"];
                MRGDJLog(@"voice: %@ (%@)", msg, e ?: @"?");
            }
        }
        done(d, e);
    };
    run(@"eleven_flash_v2_5", ^(NSData *d, NSInteger s, NSString *e) {
        if (d || (s != 400 && s != 422)) { finish(d, s, e); return; }
        run(@"eleven_multilingual_v2", ^(NSData *d2, NSInteger s2, NSString *e2) { finish(d2, s2, e2); });
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
        case MRGVoiceEngineFree: {
            NSString *vid = MRGEdgeVoice();
            for (NSDictionary *v in MRGEdgeVoices()) if ([v[@"id"] isEqualToString:vid]) return [@"Free · " stringByAppendingString:v[@"name"]];
            return [@"Free · " stringByAppendingString:vid];
        }
        case MRGVoiceEngineEleven: {
            if (!MRGElevenHasKey()) break;
            NSString *vid = MRGElevenVoice();
            for (NSDictionary *v in MRGElevenVoices()) if ([v[@"id"] isEqualToString:vid]) return [@"ElevenLabs · " stringByAppendingString:[v[@"name"] componentsSeparatedByString:@" - "].firstObject];
            NSDictionary *need = [D() dictionaryForKey:@"mirage.dj.elevenNeedsAdd"];
            if ([need[@"id"] isEqual:vid] && [need[@"name"] isKindOfClass:NSString.class]) return [NSString stringWithFormat:@"ElevenLabs · %@ (by ID)", need[@"name"]];
            return vid.length ? [NSString stringWithFormat:@"ElevenLabs · %@", vid] : @"ElevenLabs";
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
    NSArray<AVSpeechUtterance *> *_batch;   // the current line's utterances: callbacks for older ones are ignored
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

// The last line's result ("✓ ElevenLabs · Arabella spoke" or "✗ ElevenLabs: … (HTTP 402, …)"), for the voice page and
// the DJ sheet.
- (void)report:(NSString *)result failed:(BOOL)failed {
    _lastResult = [result copy];
    [NSNotificationCenter.defaultCenter postNotificationName:MRGVoiceResultNotification object:self userInfo:@{@"result": result ?: @"", @"failed": @(failed)}];
}

- (void)finish {
    void (^f)(void) = _finished;
    _finished = nil;
    if (f) f();
}

- (void)stop {
    _token++;
    // A cancelled line's delegate callbacks arrive later; without this they ended the next line early (the caption
    // dropped and the music came back up while the new line was still being fetched).
    _batch = nil;
    _lastUtterance = nil;
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
            BOOL playing = self->_audio && [self->_audio play];
            if (playing && [what hasPrefix:@"Free"]) { static BOOL said; if (!said) { said = YES; MRGDJLog(@"voice: %@ spoke (%lu KB from Microsoft's free voice)", what, (unsigned long)(audio.length / 1024)); } }
            if (playing) { [self report:[NSString stringWithFormat:@"✓ %@ spoke", engine == MRGVoiceEngineEleven ? engineSummary() : what] failed:NO]; if (started) started(); return; }
        }
        if (engine == MRGVoiceEngineEleven) {
            // Never Samantha in place of an ElevenLabs voice the listener picked: the error is shown instead.
            NSString *msg = error ?: @"ElevenLabs sent audio that couldn't be played";
            MRGDJLog(@"voice: ElevenLabs failed, not falling back to the phone voice: %@", msg);
            [self report:[@"✗ " stringByAppendingString:msg] failed:YES];
            [self finish];
            return;
        }
        if (engine == MRGVoiceEngineProvider && ![what hasPrefix:@"Free"]) {
            // The provider's voice failed: the free voice says it, and the line says so.
            MRGDJLog(@"voice: %@ failed (%@), the free voice instead", what, error ?: @"unplayable audio");
            NSString *why = error ?: @"unplayable audio";
            MRGEdgeSpeech(withPauses(text, @"..."), nil, speed, MRGVoicePitch(), ^(NSData *a2, NSString *e2) {
                if (token != self->_token) return;
                if (a2) {
                    self->_audio = [[AVAudioPlayer alloc] initWithData:a2 error:nil];
                    self->_audio.delegate = self;
                    if (self->_audio && [self->_audio play]) { [self report:[NSString stringWithFormat:@"✗ %@ failed (%@); the free voice spoke instead", what, why] failed:YES]; if (started) started(); return; }
                }
                [self report:[NSString stringWithFormat:@"✗ %@ failed (%@) and so did the free voice (%@); the iPhone voice spoke", what, why, e2 ?: @"?"] failed:YES];
                [self speakOnPhone:text voice:nil started:started];
            });
            return;
        }
        // The free voice failing: the iPhone voice speaks, and the reason is shown (and logged) once, not on every line.
        static NSString *shownReason;
        NSString *why = error ?: @"unplayable audio";
        if ([what hasPrefix:@"Free"] && [shownReason isEqualToString:why]) { [self speakOnPhone:text voice:nil started:started]; return; }
        if ([what hasPrefix:@"Free"]) shownReason = [why copy];
        MRGDJLog(@"voice: %@ failed (%@), phone voice instead", what, why);
        [self report:[NSString stringWithFormat:@"✗ %@ failed (%@); the iPhone voice spoke instead", what, why] failed:YES];
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
    if (engine == MRGVoiceEngineFree) {
        NSString *said = pause >= 0.4 ? withPauses(text, @"...") : text;
        NSString *v = voice ?: MRGEdgeVoice(), *vname = v;
        for (NSDictionary *x in MRGEdgeVoices()) if ([x[@"id"] isEqualToString:v]) vname = x[@"name"];
        MRGEdgeSpeech(said, v, speed, MRGVoicePitch(), ^(NSData *audio, NSString *error) { play(audio, error, [@"Free · " stringByAppendingString:vname]); });
        return;
    }
    if (engine == MRGVoiceEngineEleven && MRGElevenHasKey()) {
        NSString *said = pause >= 0.3 ? withPauses(text, [NSString stringWithFormat:@" <break time=\"%.1fs\" />", MIN(1.5, pause)]) : text;
        elevenSpeech(said, voice ?: MRGElevenVoice(), speed, ^(NSData *audio, NSString *error) { play(audio, error, @"ElevenLabs"); });
        return;
    }
    if (engine == MRGVoiceEngineEleven && !MRGElevenHasKey()) {
        [self report:@"✗ ElevenLabs is picked but there's no ElevenLabs key" failed:YES];
        [self finish];
        return;
    }
    AVSpeechSynthesisVoice *pv = (engine == MRGVoiceEnginePhone && voice ? [AVSpeechSynthesisVoice voiceWithIdentifier:voice] : nil) ?: MRGVoicePhoneVoice();
    [self report:[NSString stringWithFormat:@"✓ iPhone · %@ spoke", pv.name ?: @"voice"] failed:NO];
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
    NSMutableArray *batch = [NSMutableArray array];
    for (NSUInteger i = 0; i < parts.count; i++) {
        AVSpeechUtterance *u = [AVSpeechUtterance speechUtteranceWithString:parts[i]];
        u.voice = voice;
        u.rate = MIN(AVSpeechUtteranceMaximumSpeechRate, MAX(AVSpeechUtteranceMinimumSpeechRate, rate));
        u.pitchMultiplier = (float)MRGVoicePitch();
        u.volume = 1.0f;
        u.preUtteranceDelay = i == 0 ? 0.05 : 0;
        if (i + 1 < parts.count) u.postUtteranceDelay = pause;
        [batch addObject:u];
        _lastUtterance = u;
    }
    _batch = batch;
    for (AVSpeechUtterance *u in batch) [_synth speakUtterance:u];
    if (started) started();
}

- (void)speechSynthesizer:(AVSpeechSynthesizer *)s didFinishSpeechUtterance:(AVSpeechUtterance *)u {
    if (!_lastUtterance || u != _lastUtterance) return;   // more sentences to come, or an older line
    [self finish];
}
- (void)speechSynthesizer:(AVSpeechSynthesizer *)s didCancelSpeechUtterance:(AVSpeechUtterance *)u { if ([_batch containsObject:u]) [self finish]; }
- (void)audioPlayerDidFinishPlaying:(AVAudioPlayer *)p successfully:(BOOL)flag { if (p == _audio) [self finish]; }
- (void)audioPlayerDecodeErrorDidOccur:(AVAudioPlayer *)p error:(NSError *)error { if (p == _audio) [self finish]; }

@end
