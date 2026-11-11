#import "../MRGSafe.h"
#import "MRGDJPages.h"
#import "MRGPlayer.h"
#import "MRGHistory.h"
#import "MRGVoice.h"
#import "MRGDJ.h"
#import "MRGAI.h"
#import "MRGHistory.h"
#import "MRGDJLog.h"
#import "MRGVoiceNet.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#pragma mark - base

@interface MRGDJTablePage : UITableViewController
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
- (UITableViewCell *)cell:(NSString *)title detail:(NSString *)detail symbol:(NSString *)symbol;
- (void)alert:(NSString *)title message:(NSString *)message;
@end

@implementation MRGDJTablePage
- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }
- (void)viewDidLoad {
    [super viewDidLoad];
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    self.tableView.backgroundColor = UIColor.blackColor;
    self.tableView.separatorColor = [UIColor colorWithWhite:1 alpha:0.1];
    UIEdgeInsets inset = self.tableView.contentInset; inset.bottom = 150; self.tableView.contentInset = inset;
    _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    _spinner.hidesWhenStopped = YES;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithCustomView:_spinner];
}
- (UITableViewCell *)cell:(NSString *)title detail:(NSString *)detail symbol:(NSString *)symbol {
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    c.backgroundColor = [UIColor colorWithWhite:0.11 alpha:0.9];
    c.textLabel.text = title;
    c.textLabel.textColor = UIColor.whiteColor;
    c.textLabel.numberOfLines = 0;
    c.detailTextLabel.text = detail;
    c.detailTextLabel.textColor = UIColor.grayColor;
    c.detailTextLabel.adjustsFontSizeToFitWidth = YES;
    c.detailTextLabel.minimumScaleFactor = 0.6;
    if (symbol) { c.imageView.image = [UIImage systemImageNamed:symbol]; c.imageView.tintColor = UIColor.whiteColor; }
    c.tintColor = MRGAccent();
    return c;
}
- (void)alert:(NSString *)title message:(NSString *)message {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}
- (UITableViewCell *)sliderCell:(NSString *)title value:(double)v min:(double)min max:(double)max tag:(NSInteger)tag {
    UITableViewCell *c = [self cell:title detail:nil symbol:nil];
    c.selectionStyle = UITableViewCellSelectionStyleNone;
    UISlider *s = [[UISlider alloc] initWithFrame:CGRectMake(0, 0, 180, 30)];
    s.minimumValue = min; s.maximumValue = max; s.value = v; s.tag = tag;
    s.minimumTrackTintColor = MRGAccent();
    [s addTarget:self action:@selector(slid:) forControlEvents:UIControlEventValueChanged];
    [s addTarget:self action:@selector(slideEnded:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside];
    c.accessoryView = s;
    c.detailTextLabel.text = [NSString stringWithFormat:@"%.2f×", v];
    return c;
}
- (void)slid:(UISlider *)s {}
- (void)slideEnded:(UISlider *)s {}
@end

#pragma mark - Voice

// A preview line that sounds like a real DJ break, about the music actually on (or their top artist), so voices are
// judged on the kind of line they'll say.
static NSString *sampleLine(void) {
    NSDictionary *now = MRGNowPlaying();
    NSString *artist = [now[@"artist"] isKindOfClass:NSString.class] && [now[@"artist"] length] ? now[@"artist"] : nil;
    NSString *title = [now[@"title"] isKindOfClass:NSString.class] && [now[@"title"] length] ? now[@"title"] : nil;
    if (!artist) {
        NSArray *top = MRGHistoryTopArtists(nil, 1);
        NSString *n = [top.firstObject isKindOfClass:NSDictionary.class] ? top.firstObject[@"name"] : nil;
        if ([n isKindOfClass:NSString.class] && n.length) artist = n;
    }
    // Short enough for every voice engine (Groq's Orpheus takes 200 characters).
    if (artist && title)
        return [NSString stringWithFormat:@"Alright, that's %@ with \"%@\", and it never misses. Stay right here, I've got a couple more just like it.", artist, title];
    if (artist)
        return [NSString stringWithFormat:@"What's good, it's your DJ. You've had %@ in heavy rotation, so I pulled some deep cuts from that same lane. Let's go.", artist];
    return @"What's good, it's your DJ. Got a couple of favorites, one throwback and something new lined up for you. Let's get into it.";
}

@interface MRGVoicePageController : MRGDJTablePage
@end

// "Who speaks", in the order shown: the free voices first.
static NSArray<NSNumber *> *engineRows(void) {
    return @[@(MRGVoiceEngineFree), @(MRGVoiceEngineEleven), @(MRGVoiceEngineProvider), @(MRGVoiceEnginePhone), @(MRGVoiceEngineOff)];
}
// The free voices' list (id, name, detail).
static NSArray<NSDictionary *> *listVoices(MRGVoiceEngine e) { return e == MRGVoiceEngineFree ? MRGEdgeVoices() : nil; }

// Sections: 0 presets, 1 engine, 2 sound (sliders, voice style, preview), 3 voices of the engine, 4 ElevenLabs key.
// Sound rows by id: speed, pitch, warmth, breath, pause, style, [stability, similarity with ElevenLabs], preview.
@implementation MRGVoicePageController {
    NSArray<AVSpeechSynthesisVoice *> *_phone;
    NSArray<NSDictionary *> *_provider;
    NSString *_testLine;   // what happened adding a preset's voice
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Voice";
    _phone = MRGVoicePhoneVoices();
    _provider = @[];
    if (MRGProviderHasTTS(MRGAIProvider())) MRGAIProviderVoices(^(NSArray<NSDictionary *> *voices) { self->_provider = voices ?: @[]; [self.tableView reloadData]; });
    if (MRGElevenHasKey()) MRGElevenRefreshVoices(^(NSArray *v, NSString *e) { [self.tableView reloadData]; });
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(voiceResult:) name:MRGVoiceResultNotification object:nil];
}

- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }

- (void)voiceResult:(NSNotification *)n {
    dispatch_async(dispatch_get_main_queue(), ^{ if (self.isViewLoaded) [self.tableView reloadData]; });
}

- (void)viewWillDisappear:(BOOL)animated { [super viewWillDisappear:animated]; [MRGVoiceSpeaker.shared stop]; }

- (NSArray<NSString *> *)soundRows {
    NSMutableArray *r = [@[@"speed", @"pitch", @"warmth", @"breath", @"pause", @"style"] mutableCopy];
    if (MRGVoiceGetEngine() == MRGVoiceEngineEleven) [r addObjectsFromArray:@[@"stability", @"similarity"]];
    [r addObject:@"preview"];
    return r;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)t { return 5; }

- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s {
    return MRGSafeCount(^NSInteger { return [self mrg_rowsIn:t section:s]; });
}

- (NSInteger)mrg_rowsIn:(UITableView *)t section:(NSInteger)s {
    if (s == 0) return MRGVoicePresets().count;
    if (s == 1) return engineRows().count;
    if (s == 2) return [self soundRows].count;
    if (s == 4) return 1 + (MRGElevenHasKey() && MRGElevenNeedsAdd() ? 1 : 0);
    switch (MRGVoiceGetEngine()) {
        case MRGVoiceEngineFree: return MRGEdgeVoices().count;
        case MRGVoiceEnginePhone: return _phone.count + 1 + ([self personalVoiceAsk] ? 1 : 0);
        case MRGVoiceEngineProvider: return MRGProviderHasTTS(MRGAIProvider()) ? MAX((NSInteger)_provider.count, 1) : 0;
        case MRGVoiceEngineEleven: return MRGElevenHasKey() ? MAX((NSInteger)MRGElevenVoices().count, 1) : 0;
        default: return 0;
    }
}

- (BOOL)personalVoiceAsk {
    if (@available(iOS 17.0, *)) return AVSpeechSynthesizer.personalVoiceAuthorizationStatus == AVSpeechSynthesisPersonalVoiceAuthorizationStatusNotDetermined;
    return NO;
}

- (NSString *)tableView:(UITableView *)t titleForHeaderInSection:(NSInteger)s {
    if (s == 0) return @"Presets";
    if (s == 1) return @"Who speaks";
    if (s == 2) return MRGVoicePresetID() ? @"Sound" : @"Sound (custom)";
    if (s == 4) return @"Keys";
    switch (MRGVoiceGetEngine()) {
        case MRGVoiceEngineFree: return @"Free voices (Microsoft Edge, unofficial; tap to hear)";
        case MRGVoiceEnginePhone: return @"iPhone voices, speaking now (tap to hear)";
        case MRGVoiceEngineProvider: return [NSString stringWithFormat:@"%@ voices (tap to hear)", MRGProviderName(MRGAIProvider())];
        case MRGVoiceEngineEleven: return @"Your ElevenLabs voices (tap to hear)";
        default: return nil;
    }
}

- (NSString *)tableView:(UITableView *)t titleForFooterInSection:(NSInteger)s {
    return MRGSafeString(^NSString *{ return [self mrg_footerIn:t section:s]; });
}

- (NSString *)mrg_footerIn:(UITableView *)t section:(NSInteger)s {
    if (s == 0) {
        NSMutableString *f = [NSMutableString stringWithFormat:@"Speaking now: %@", MRGVoiceSummary()];
        if (_testLine.length) [f appendFormat:@"\n%@", _testLine];
        NSString *last = MRGVoiceSpeaker.shared.lastResult;
        if (last.length) [f appendFormat:@"\nLast test: %@", last];
        [f appendString:@"\n\nA preset sets speed, pitch, warmth, breathiness, pauses, a voice style and a fitting voice for every engine, and speaks with the free voices (the iPhone voice stays if you picked it below). It only changes the voice, never the music or the DJ's persona."];
        return f;
    }
    if (s == 0) return @"A preset sets speed, pitch, warmth, breathiness, pauses, a voice style and a fitting voice for every engine. It only changes the voice, never the music or the DJ's persona. Change anything after and it becomes your own.";
    if (s == 1) return @"Free: Microsoft Edge's read-aloud voices, no key and no account. It's unofficial, so Microsoft can change or block it; it follows speed, pitch, loudness and pauses, not the style words (Microsoft's free voices have no whisper or emotion styles). If it fails, the iPhone voice speaks and the line above says why.\nElevenLabs never swaps to another voice when they fail: you see their error instead. AI provider voice: OpenAI, Gemini, xAI and Groq keys (Groq's needs its terms accepted in the Groq console).";
    if (s == 2) return @"Warmth, breathiness, pitch and Voice style are speaking instructions: OpenAI (gpt-4o-mini-tts) and Gemini voices follow them. iPhone voices use speed, pitch and pauses. ElevenLabs uses speed, pauses (as breaks), stability and similarity. xAI uses speed; Groq and xAI get pauses as ellipses.";
    if (s == 3 && MRGVoiceGetEngine() == MRGVoiceEnginePhone)
        return @"Want a better voice? iOS Settings → Accessibility → Spoken Content → Voices → English, and download an Enhanced or Premium voice (Ava, Zoe, Evan, Nathan…). It shows up here after. A Personal Voice you made in Accessibility can be used once you allow it.";
    if (s == 4 && MRGElevenHasKey() && MRGElevenNeedsAdd()) {
        NSDictionary *n = MRGElevenNeedsAdd();
        return n[@"error"] ?: [NSString stringWithFormat:@"%@ isn't in your ElevenLabs voices yet. Mirage uses it by ID (works on paid ElevenLabs plans); if it fails, add it in ElevenLabs → Voice Library or tap Add to my ElevenLabs.", n[@"name"]];
    }
    if (s == 4) return @"Optional keys. ElevenLabs: elevenlabs.io → Developers → API keys (library voices like Arabella need a paid plan through the API). Keys stay in this phone's keychain; only the lines the DJ says are sent.";
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip {
    return MRGSafeCell(ip, ^UITableViewCell *{ return [self mrg_cellIn:t at:ip]; });
}

- (UITableViewCell *)slider:(NSString *)title value:(double)v min:(double)min max:(double)max tag:(NSInteger)tag {
    UITableViewCell *c = [self sliderCell:title value:v min:min max:max tag:tag];
    c.detailTextLabel.text = [self format:v tag:tag];
    return c;
}

- (NSString *)format:(double)v tag:(NSInteger)tag {
    if (tag <= 2) return [NSString stringWithFormat:@"%.2f×", v];
    if (tag == 5) return v < 0.05 ? @"none" : [NSString stringWithFormat:@"%.1fs", v];
    return [NSString stringWithFormat:@"%.0f%%", v * 100];
}

- (UITableViewCell *)mrg_cellIn:(UITableView *)t at:(NSIndexPath *)ip {
    MRGVoiceEngine engine = MRGVoiceGetEngine();
    if (ip.section == 0) {
        NSDictionary *p = MRGVoicePresets()[ip.row];
        UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
        c.backgroundColor = [UIColor colorWithWhite:0.11 alpha:0.9];
        c.textLabel.text = p[@"name"];
        c.textLabel.textColor = UIColor.whiteColor;
        c.detailTextLabel.text = p[@"blurb"];
        c.detailTextLabel.textColor = UIColor.grayColor;
        c.tintColor = MRGAccent();
        c.accessoryType = [MRGVoicePresetID() isEqualToString:p[@"id"]] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
        return c;
    }
    if (ip.section == 1) {
        MRGVoiceEngine e = [engineRows()[ip.row] integerValue];
        NSDictionary *titles = @{@(MRGVoiceEngineFree): @"Free voices", @(MRGVoiceEngineEleven): @"ElevenLabs",
                                 @(MRGVoiceEngineProvider): @"AI provider voice", @(MRGVoiceEnginePhone): @"iPhone voice", @(MRGVoiceEngineOff): @"Off (captions only)"};
        NSDictionary *symbols = @{@(MRGVoiceEngineFree): @"gift.fill", @(MRGVoiceEngineEleven): @"waveform",
                                  @(MRGVoiceEngineProvider): @"sparkles", @(MRGVoiceEnginePhone): @"iphone", @(MRGVoiceEngineOff): @"speaker.slash.fill"};
        BOOL enabled = e == MRGVoiceEngineFree || e == MRGVoiceEnginePhone || e == MRGVoiceEngineOff || (e == MRGVoiceEngineProvider && MRGProviderHasTTS(MRGAIProvider())) ||
                       (e == MRGVoiceEngineEleven && MRGElevenHasKey());
        NSString *detail = e == MRGVoiceEngineFree ? @"no key · unofficial" : e == MRGVoiceEngineProvider && !MRGProviderHasTTS(MRGAIProvider()) ? @"not with this key"
                         : (e == MRGVoiceEngineEleven && !MRGElevenHasKey()) ? @"add a key below" : nil;
        UITableViewCell *c = [self cell:titles[@(e)] detail:detail symbol:symbols[@(e)]];
        c.accessoryType = engine == e ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
        c.textLabel.alpha = enabled ? 1 : 0.4;
        c.userInteractionEnabled = enabled;
        return c;
    }
    if (ip.section == 2) {
        NSString *row = [self soundRows][ip.row];
        if ([row isEqualToString:@"speed"]) return [self slider:@"Speed" value:MRGVoiceSpeed() min:0.6 max:1.5 tag:1];
        if ([row isEqualToString:@"pitch"]) return [self slider:@"Pitch" value:MRGVoicePitch() min:0.75 max:1.5 tag:2];
        if ([row isEqualToString:@"warmth"]) return [self slider:@"Warmth" value:MRGVoiceWarmth() min:0 max:1 tag:3];
        if ([row isEqualToString:@"breath"]) return [self slider:@"Breathiness" value:MRGVoiceBreathiness() min:0 max:1 tag:4];
        if ([row isEqualToString:@"pause"]) return [self slider:@"Pauses" value:MRGVoicePause() min:0 max:1.5 tag:5];
        if ([row isEqualToString:@"stability"]) return [self slider:@"Stability" value:MRGElevenStability() min:0 max:1 tag:6];
        if ([row isEqualToString:@"similarity"]) return [self slider:@"Similarity" value:MRGElevenSimilarity() min:0 max:1 tag:7];
        if ([row isEqualToString:@"style"]) {
            NSString *st = MRGVoiceStyleText();
            UITableViewCell *c = [self cell:@"Voice style" detail:st ? (st.length > 28 ? [[st substringToIndex:28] stringByAppendingString:@"…"] : st) : @"Add" symbol:@"text.quote"];
            c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            return c;
        }
        UITableViewCell *c = [self cell:@"Preview" detail:MRGVoiceSummary() symbol:@"play.circle.fill"];
        c.textLabel.textColor = MRGAccent();
        return c;
    }
    if (ip.section == 4 && ip.row == 1) {
        NSDictionary *n = MRGElevenNeedsAdd();
        UITableViewCell *c = [self cell:[NSString stringWithFormat:@"Add %@ to my ElevenLabs", n[@"name"] ?: @"this voice"] detail:nil symbol:@"plus.circle.fill"];
        c.textLabel.textColor = MRGAccent();
        return c;
    }
    if (ip.section == 4) {
        UITableViewCell *c = [self cell:@"ElevenLabs key" detail:MRGElevenHasKey() ? [NSString stringWithFormat:@"%lu voices", (unsigned long)MRGElevenVoices().count] : @"Add" symbol:@"key.fill"];
        c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return c;
    }
    if (listVoices(engine)) {
        NSDictionary *v = listVoices(engine)[ip.row];
        NSString *chosen = MRGEdgeVoice();
        UITableViewCell *c = [self cell:v[@"name"] detail:v[@"detail"] symbol:nil];
        c.accessoryType = [chosen isEqualToString:v[@"id"]] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
        return c;
    }
    if (engine == MRGVoiceEnginePhone) {
        NSInteger row = ip.row;
        if ([self personalVoiceAsk]) {
            if (row == 0) { UITableViewCell *c = [self cell:@"Allow Personal Voice" detail:nil symbol:@"person.wave.2.fill"]; c.textLabel.textColor = MRGAccent(); return c; }
            row--;
        }
        NSString *chosen = [NSUserDefaults.standardUserDefaults stringForKey:@"mirage.dj.systemVoice"];
        if (row == 0) {
            AVSpeechSynthesisVoice *best = _phone.firstObject;
            UITableViewCell *c = [self cell:@"Automatic" detail:best ? [NSString stringWithFormat:@"best installed: %@", best.name] : nil symbol:nil];
            c.accessoryType = chosen ? UITableViewCellAccessoryNone : UITableViewCellAccessoryCheckmark;
            return c;
        }
        AVSpeechSynthesisVoice *v = _phone[row - 1];
        NSString *g = v.gender == AVSpeechSynthesisVoiceGenderFemale ? @" · female" : v.gender == AVSpeechSynthesisVoiceGenderMale ? @" · male" : @"";
        UITableViewCell *c = [self cell:v.name detail:[NSString stringWithFormat:@"%@ · %@%@", MRGVoiceQualityName(v), v.language, g] symbol:nil];
        c.accessoryType = [chosen isEqualToString:v.identifier] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
        return c;
    }
    if (engine == MRGVoiceEngineProvider) {
        if (!_provider.count) return [self cell:@"Loading voices…" detail:nil symbol:nil];
        NSDictionary *v = _provider[ip.row];
        NSString *chosen = MRGVoiceProviderVoice();
        UITableViewCell *c = [self cell:v[@"name"] ?: v[@"id"] detail:[v[@"name"] isEqualToString:v[@"id"]] ? nil : v[@"id"] symbol:nil];
        c.accessoryType = ([chosen.lowercaseString isEqualToString:[v[@"id"] lowercaseString]] || (!chosen && ip.row == 0)) ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
        return c;
    }
    NSArray *voices = MRGElevenVoices();
    if (!voices.count) return [self cell:@"No voices on that account" detail:nil symbol:nil];
    NSDictionary *v = voices[ip.row];
    UITableViewCell *c = [self cell:v[@"name"] detail:v[@"category"] symbol:nil];
    c.accessoryType = [MRGElevenVoice() isEqualToString:v[@"id"]] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    return c;
}

- (void)preview:(NSInteger)engine voice:(NSString *)voice {
    [self.spinner startAnimating];
    [MRGVoiceSpeaker.shared speak:sampleLine() engine:engine voice:voice started:^{ [self.spinner stopAnimating]; } finished:^{ [self.spinner stopAnimating]; }];
}

- (void)tableView:(UITableView *)t didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [t deselectRowAtIndexPath:ip animated:YES];
    MRGVoiceEngine engine = MRGVoiceGetEngine();
    if (ip.section == 0) {
        NSDictionary *p = MRGVoicePresets()[ip.row];
        NSString *picked = MRGVoiceApplyPreset(p[@"id"]);
        if (picked) MRGDJLog(@"voice: preset picked %@", picked);
        _testLine = nil;
        if (MRGElevenNeedsAdd() && MRGVoiceGetEngine() == MRGVoiceEngineEleven) {
            // Picking the preset is the choice: its library voice is added to his ElevenLabs voices, then tested.
            _testLine = [NSString stringWithFormat:@"Adding %@ to your ElevenLabs voices…", MRGElevenNeedsAdd()[@"name"] ?: @"the voice"];
            [t reloadData];
            [self.spinner startAnimating];
            MRGVoicePreparePreset(p[@"id"], ^(NSString *message) {
                [self.spinner stopAnimating];
                self->_testLine = message;
                [self.tableView reloadData];
                [self preview:-1 voice:nil];
            });
            return;
        }
        [t reloadData];
        [self preview:-1 voice:nil];
        return;
    }
    if (ip.section == 1) {
        MRGVoiceEngine e = [engineRows()[ip.row] integerValue];
        MRGVoiceChooseEngine(e);
        [t reloadData];
        if (e == MRGVoiceEngineProvider && !_provider.count)
            MRGAIProviderVoices(^(NSArray<NSDictionary *> *voices) { self->_provider = voices ?: @[]; [self.tableView reloadData]; });
        return;
    }
    if (ip.section == 2) {
        NSString *row = [self soundRows][ip.row];
        if ([row isEqualToString:@"preview"]) [self preview:-1 voice:nil];
        else if ([row isEqualToString:@"style"]) [self editStyle];
        return;
    }
    if (ip.section == 4 && ip.row == 1) {
        NSDictionary *n = MRGElevenNeedsAdd();
        if (!n) { [t reloadData]; return; }
        MRGElevenAddShared(n[@"id"], n[@"name"], ^(BOOL ok, NSString *message) {
            UIAlertController *a = [UIAlertController alertControllerWithTitle:ok ? @"Added" : @"Couldn't add it" message:message preferredStyle:UIAlertControllerStyleAlert];
            [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            if (self.view.window) [self presentViewController:a animated:YES completion:nil];
            [self.tableView reloadData];
        });
        return;
    }
    if (ip.section == 4) { [self editElevenKey]; return; }
    if (listVoices(engine)) {
        NSString *ident = listVoices(engine)[ip.row][@"id"];
        MRGEdgeSetVoice(ident);
        [t reloadData];
        [self preview:engine voice:ident];
        return;
    }
    if (engine == MRGVoiceEnginePhone) {
        NSInteger row = ip.row;
        if ([self personalVoiceAsk]) {
            if (row == 0) {
                if (@available(iOS 17.0, *)) {
                    [AVSpeechSynthesizer requestPersonalVoiceAuthorizationWithCompletionHandler:^(AVSpeechSynthesisPersonalVoiceAuthorizationStatus status) {
                        dispatch_async(dispatch_get_main_queue(), ^{ self->_phone = MRGVoicePhoneVoices(); [self.tableView reloadData]; });
                    }];
                }
                return;
            }
            row--;
        }
        NSString *ident = row == 0 ? nil : _phone[row - 1].identifier;
        MRGVoiceSetPhoneVoice(ident);
        [t reloadData];
        [self preview:MRGVoiceEnginePhone voice:ident];
    } else if (engine == MRGVoiceEngineProvider && _provider.count) {
        NSString *ident = _provider[ip.row][@"id"];
        MRGVoiceSetProviderVoice(ident);
        [t reloadData];
        [self preview:MRGVoiceEngineProvider voice:ident];
    } else if (engine == MRGVoiceEngineEleven && MRGElevenVoices().count) {
        NSString *ident = MRGElevenVoices()[ip.row][@"id"];
        MRGElevenSetVoice(ident);
        [t reloadData];
        [self preview:MRGVoiceEngineEleven voice:ident];
    }
}

- (void)slid:(UISlider *)s {
    double v = s.tag == 5 ? round(s.value * 10) / 10 : round(s.value * 20) / 20;
    switch (s.tag) {
        case 1: MRGVoiceSetSpeed(v); break;
        case 2: MRGVoiceSetPitch(v); break;
        case 3: MRGVoiceSetWarmth(v); break;
        case 4: MRGVoiceSetBreathiness(v); break;
        case 5: MRGVoiceSetPause(v); break;
        case 6: MRGElevenSetStability(v); break;
        case 7: MRGElevenSetSimilarity(v); break;
    }
    UITableViewCell *c = (UITableViewCell *)s.superview;
    while (c && ![c isKindOfClass:UITableViewCell.class]) c = (UITableViewCell *)c.superview;
    c.detailTextLabel.text = [self format:v tag:s.tag];
}
- (void)slideEnded:(UISlider *)s {
    if (MRGVoicePresetID()) { MRGVoiceMarkCustom(); [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:0] withRowAnimation:UITableViewRowAnimationNone]; }
    [self preview:-1 voice:nil];
}

- (void)editStyle {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Voice style" message:@"How the voice should sound, in your words: sent as speaking instructions to OpenAI and Gemini voices. E.g. \"slow, soft and soothing, warm and close, a little breathy\"." preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *f) { f.text = MRGVoiceStyleText(); f.placeholder = @"slow, soft, warm, soothing…"; f.clearButtonMode = UITextFieldViewModeWhileEditing; }];
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        MRGVoiceSetStyleText(a.textFields.firstObject.text);
        MRGVoiceMarkCustom();
        [self.tableView reloadData];
        [self preview:-1 voice:nil];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)editElevenKey {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"ElevenLabs key" message:@"Paste your ElevenLabs API key. Mirage checks it by listing your voices." preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *f) {
        f.placeholder = @"sk_…";
        f.secureTextEntry = YES;
        f.autocorrectionType = UITextAutocorrectionTypeNo;
        f.autocapitalizationType = UITextAutocapitalizationTypeNone;
    }];
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    if (MRGElevenHasKey()) [a addAction:[UIAlertAction actionWithTitle:@"Remove key" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) {
        MRGElevenSetKey(nil, ^(BOOL ok, NSString *m) { [self.tableView reloadData]; });
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        NSString *key = a.textFields.firstObject.text;
        if (!key.length) return;
        [self.spinner startAnimating];
        MRGElevenSetKey(key, ^(BOOL ok, NSString *message) {
            [self.spinner stopAnimating];
            if (ok) MRGVoiceChooseEngine(MRGVoiceEngineEleven);
            [self.tableView reloadData];
            [self alert:ok ? @"Ready" : @"Couldn't use that key" message:message];
        });
    }]];
    [self presentViewController:a animated:YES completion:nil];
}
@end

UIViewController *MRGVoicePage(void) { return [MRGVoicePageController new]; }

#pragma mark - Vibe

@interface MRGVibePageController : MRGDJTablePage <UITextViewDelegate>
@end

@implementation MRGVibePageController {
    UITextView *_prompt;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Vibe";
    _prompt = [UITextView new];
    _prompt.backgroundColor = UIColor.clearColor;
    _prompt.textColor = UIColor.whiteColor;
    _prompt.font = [UIFont systemFontOfSize:15];
    _prompt.text = MRGDJCustomPrompt() ?: @"";
    _prompt.delegate = self;
    _prompt.tintColor = MRGAccent();
}

- (void)viewWillDisappear:(BOOL)animated { [super viewWillDisappear:animated]; MRGDJSetCustomPrompt(_prompt.text); }
- (void)textViewDidEndEditing:(UITextView *)tv { MRGDJSetCustomPrompt(tv.text); }

- (NSInteger)numberOfSectionsInTableView:(UITableView *)t { return 3; }
- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s {
    return MRGSafeCount(^NSInteger { return [self mrg_rowsIn:t section:s]; });
}

- (NSInteger)mrg_rowsIn:(UITableView *)t section:(NSInteger)s { return s == 0 ? MRGDJPersonaNames().count : s == 1 ? 4 : 1; }
- (NSString *)tableView:(UITableView *)t titleForHeaderInSection:(NSInteger)s { return @[@"Persona", @"How often the DJ talks", @"Your instructions"][s]; }
- (NSString *)tableView:(UITableView *)t titleForFooterInSection:(NSInteger)s {
    return MRGSafeString(^NSString *{ return [self mrg_footerIn:t section:s]; });
}

- (NSString *)mrg_footerIn:(UITableView *)t section:(NSInteger)s {
    if (s == 0) return @"Changes how the DJ talks and how long its lines are, from the next set on. Underground curator also leans the picks off the beaten path.";
    if (s == 1) return @"Auto follows the persona. Every few: the first track of a set and then every third. Only on switches: just when a new set starts.";
    return @"Added to the DJ's instructions for picks and the chat, e.g. \"no rap\", \"call me Alex\", \"mostly 2000s\". Sent to your AI provider with each request.";
}
- (CGFloat)tableView:(UITableView *)t heightForRowAtIndexPath:(NSIndexPath *)ip { return ip.section == 2 ? 120 : UITableViewAutomaticDimension; }

- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip {
    return MRGSafeCell(ip, ^UITableViewCell *{ return [self mrg_cellIn:t at:ip]; });
}

- (UITableViewCell *)mrg_cellIn:(UITableView *)t at:(NSIndexPath *)ip {
    if (ip.section == 0) {
        UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
        c.backgroundColor = [UIColor colorWithWhite:0.11 alpha:0.9];
        c.textLabel.text = MRGDJPersonaNames()[ip.row];
        c.textLabel.textColor = UIColor.whiteColor;
        c.detailTextLabel.text = MRGDJPersonaBlurbs()[ip.row];
        c.detailTextLabel.textColor = UIColor.grayColor;
        c.tintColor = MRGAccent();
        c.accessoryType = MRGDJPersona() == ip.row ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
        return c;
    }
    if (ip.section == 1) {
        UITableViewCell *c = [self cell:@[@"Auto", @"Every track", @"Every few tracks", @"Only on switches"][ip.row] detail:nil symbol:nil];
        c.accessoryType = MRGDJTalkSetting() == ip.row ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
        return c;
    }
    UITableViewCell *c = [self cell:nil detail:nil symbol:nil];
    c.selectionStyle = UITableViewCellSelectionStyleNone;
    _prompt.frame = CGRectInset(c.contentView.bounds, 12, 6);
    _prompt.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [c.contentView addSubview:_prompt];
    return c;
}

- (void)tableView:(UITableView *)t didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [t deselectRowAtIndexPath:ip animated:YES];
    if (ip.section == 0) MRGDJSetPersona(ip.row);
    else if (ip.section == 1) MRGDJSetTalkSetting(ip.row);
    else { [_prompt becomeFirstResponder]; return; }
    [t reloadSections:[NSIndexSet indexSetWithIndex:ip.section] withRowAnimation:UITableViewRowAnimationNone];
}
@end

UIViewController *MRGVibePage(void) { return [MRGVibePageController new]; }

#pragma mark - Listening history

@interface MRGHistoryPageController : MRGDJTablePage <UIDocumentPickerDelegate>
@end

@implementation MRGHistoryPageController {
    NSDictionary *_summary;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Listening history";
    [self refresh];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(refresh) name:MRGHistoryChangedNotification object:nil];
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
- (void)refresh { _summary = MRGHistorySummary(); [self.tableView reloadData]; }

static NSString *day(NSDate *d) {
    if (!d) return @"-";
    static NSDateFormatter *f;
    if (!f) { f = [NSDateFormatter new]; f.dateStyle = NSDateFormatterMediumStyle; f.timeStyle = NSDateFormatterNoStyle; }
    return [f stringFromDate:d];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)t { return 3; }
- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s {
    return MRGSafeCount(^NSInteger { return [self mrg_rowsIn:t section:s]; });
}

- (NSInteger)mrg_rowsIn:(UITableView *)t section:(NSInteger)s { return s == 0 ? 4 : s == 1 ? 1 : 2; }
- (NSString *)tableView:(UITableView *)t titleForHeaderInSection:(NSInteger)s { return @[@"What the DJ chat knows", @"Import", @"Clear"][s]; }
- (NSString *)tableView:(UITableView *)t titleForFooterInSection:(NSInteger)s {
    return MRGSafeString(^NSString *{ return [self mrg_footerIn:t section:s]; });
}

- (NSString *)mrg_footerIn:(UITableView *)t section:(NSInteger)s {
    if (s == 0) return @"Mirage records every track it sees play from the moment it was installed (it counts a play at 30 seconds, like Spotify). Spotify's app doesn't keep a full history Mirage can read, so for anything older import your data. Everything stays on this iPhone; the chat sends only the answer to a question (like an artist's first play) to your AI provider.";
    if (s == 1) return @"Request \"Extended streaming history\" at spotify.com/account/privacy (it takes a few days), then pick the ZIP or the Streaming_History_Audio_*.json files here. The shorter \"Account data\" files (StreamingHistory_music_*.json, last year only) work too.";
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip {
    return MRGSafeCell(ip, ^UITableViewCell *{ return [self mrg_cellIn:t at:ip]; });
}

- (UITableViewCell *)mrg_cellIn:(UITableView *)t at:(NSIndexPath *)ip {
    if (ip.section == 0) {
        NSDictionary *s = _summary;
        switch (ip.row) {
            case 0: return [self cell:@"Plays" detail:[NSString stringWithFormat:@"%@ (%@ min)", s[@"plays"], s[@"minutes"]] symbol:@"music.note"];
            case 1: return [self cell:@"Covers" detail:s[@"from"] ? [NSString stringWithFormat:@"%@ – %@", day(s[@"from"]), day(s[@"to"])] : @"nothing yet" symbol:@"calendar"];
            case 2: return [self cell:@"Recorded by Mirage" detail:[NSString stringWithFormat:@"%@ plays since %@", s[@"livePlays"], day(s[@"liveSince"])] symbol:@"record.circle"];
            default: return [self cell:@"Imported" detail:[NSString stringWithFormat:@"%@ plays, %lu files", s[@"importedPlays"], (unsigned long)[s[@"importedFiles"] count]] symbol:@"square.and.arrow.down"];
        }
    }
    if (ip.section == 1) {
        UITableViewCell *c = [self cell:@"Import Spotify data (ZIP or JSON)" detail:nil symbol:@"doc.badge.plus"];
        c.textLabel.textColor = MRGAccent();
        return c;
    }
    UITableViewCell *c = [self cell:ip.row == 0 ? @"Remove imported history" : @"Remove all history" detail:nil symbol:@"trash"];
    c.textLabel.textColor = UIColor.systemRedColor;
    c.imageView.tintColor = UIColor.systemRedColor;
    return c;
}

- (void)tableView:(UITableView *)t didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [t deselectRowAtIndexPath:ip animated:YES];
    if (ip.section == 1) {
        NSMutableArray *types = [NSMutableArray arrayWithObjects:UTTypeJSON, UTTypeZIP, nil];
        UIDocumentPickerViewController *p = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:types asCopy:YES];
        p.allowsMultipleSelection = YES;
        p.delegate = self;
        p.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
        [self presentViewController:p animated:YES completion:nil];
        return;
    }
    if (ip.section != 2) return;
    BOOL all = ip.row == 1;
    UIAlertController *a = [UIAlertController alertControllerWithTitle:all ? @"Remove all listening history?" : @"Remove imported history?"
        message:all ? @"Mirage's own recording and every import are deleted from this iPhone." : @"Imports are deleted; Mirage's recent recordings are kept."
        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"Remove" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) {
        MRGHistoryClear(YES, all);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self refresh]; });
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)picker didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    if (!urls.count) return;
    [self.spinner startAnimating];
    __block NSUInteger plays = 0, files = 0, left = urls.count;
    __block NSString *lastError = nil;
    for (NSURL *u in urls) {
        MRGHistoryImport(u, ^(NSUInteger p, NSUInteger f, NSString *error) {
            plays += p; files += f;
            if (error) lastError = error;
            if (--left) return;
            [self.spinner stopAnimating];
            [self refresh];
            if (files) [self alert:@"Imported" message:[NSString stringWithFormat:@"%lu plays from %lu files.%@", (unsigned long)plays, (unsigned long)files, lastError ? [@"\n" stringByAppendingString:lastError] : @""]];
            else [self alert:@"Nothing imported" message:lastError ?: @"No streaming history in that file."];
        });
    }
}
@end

UIViewController *MRGHistoryPage(void) { return [MRGHistoryPageController new]; }
