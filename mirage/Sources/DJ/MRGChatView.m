#import "MRGChatView.h"
#import "MRGChat.h"
#import "MRGAI.h"
#import "MRGDJLog.h"
#import "MRGBackgroundView.h"
#import "../MRGSettings.h"
#import <objc/runtime.h>

static UIColor *kDim(void) { return [UIColor colorWithWhite:1 alpha:0.6]; }

static UILabel *label(CGFloat size, UIFontWeight w, UIColor *color, NSInteger lines) {
    UILabel *l = [UILabel new];
    l.font = [UIFont systemFontOfSize:size weight:w];
    l.textColor = color;
    l.numberOfLines = lines;
    return l;
}

static char kURLKey;
static void loadInto(UIImageView *iv, NSString *url) {
    static NSCache *cache;
    if (!cache) { cache = [NSCache new]; cache.countLimit = 80; }
    objc_setAssociatedObject(iv, &kURLKey, url ?: @"", OBJC_ASSOCIATION_COPY_NONATOMIC);
    if (!url.length) return;
    UIImage *hit = [cache objectForKey:url];
    if (hit) { iv.image = hit; iv.contentMode = UIViewContentModeScaleAspectFill; return; }
    NSURL *u = [NSURL URLWithString:url];
    if (!u) return;
    [[NSURLSession.sharedSession dataTaskWithURL:u completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        UIImage *img = d ? [UIImage imageWithData:d] : nil;
        if (!img) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            [cache setObject:img forKey:url];
            if (![objc_getAssociatedObject(iv, &kURLKey) isEqualToString:url]) return;
            [UIView transitionWithView:iv duration:0.2 options:UIViewAnimationOptionTransitionCrossDissolve animations:^{
                iv.image = img; iv.contentMode = UIViewContentModeScaleAspectFill;
            } completion:nil];
        });
    }] resume];
}

static UIImageView *art(CGFloat side, BOOL round, NSString *symbol) {
    UIImageView *iv = [UIImageView new];
    iv.backgroundColor = [UIColor colorWithWhite:1 alpha:0.1];
    iv.clipsToBounds = YES;
    iv.layer.cornerRadius = round ? side / 2 : 6;
    iv.layer.cornerCurve = kCACornerCurveContinuous;
    iv.contentMode = UIViewContentModeCenter;
    iv.tintColor = [UIColor colorWithWhite:1 alpha:0.5];
    iv.image = [UIImage systemImageNamed:symbol withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:side * 0.38 weight:UIImageSymbolWeightMedium]];
    iv.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[[iv.widthAnchor constraintEqualToConstant:side], [iv.heightAnchor constraintEqualToConstant:side]]];
    return iv;
}

static UIView *cardBox(UIView *content) {
    UIView *box = [UIView new];
    box.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
    box.layer.cornerRadius = 18;
    box.layer.cornerCurve = kCACornerCurveContinuous;
    box.layer.borderWidth = 1.0 / UIScreen.mainScreen.scale;
    box.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.1].CGColor;
    content.translatesAutoresizingMaskIntoConstraints = NO;
    [box addSubview:content];
    [NSLayoutConstraint activateConstraints:@[
        [content.leadingAnchor constraintEqualToAnchor:box.leadingAnchor constant:14],
        [content.trailingAnchor constraintEqualToAnchor:box.trailingAnchor constant:-14],
        [content.topAnchor constraintEqualToAnchor:box.topAnchor constant:12],
        [content.bottomAnchor constraintEqualToAnchor:box.bottomAnchor constant:-12],
    ]];
    return box;
}

static NSString *longDate(NSDate *d) {
    if (![d isKindOfClass:NSDate.class]) return @"";
    static NSDateFormatter *f;
    if (!f) { f = [NSDateFormatter new]; f.dateStyle = NSDateFormatterLongStyle; f.timeStyle = NSDateFormatterNoStyle; }
    return [f stringFromDate:d];
}

// A button that carries a block.
@interface MRGBlockButton : UIButton
@property (nonatomic, copy) void (^action)(void);
@end
@implementation MRGBlockButton
+ (instancetype)symbol:(NSString *)name size:(CGFloat)size tint:(UIColor *)tint action:(void (^)(void))action {
    MRGBlockButton *b = [self buttonWithType:UIButtonTypeSystem];
    [b setImage:[UIImage systemImageNamed:name withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:size weight:UIImageSymbolWeightSemibold]] forState:UIControlStateNormal];
    b.tintColor = tint;
    b.action = action;
    [b addTarget:b action:@selector(fire) forControlEvents:UIControlEventTouchUpInside];
    [b setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [b setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    return b;
}
+ (instancetype)pill:(NSString *)title filled:(BOOL)filled color:(UIColor *)color action:(void (^)(void))action {
    UIButtonConfiguration *c = filled ? [UIButtonConfiguration filledButtonConfiguration] : [UIButtonConfiguration grayButtonConfiguration];
    c.title = title;
    c.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    if (filled) { c.baseBackgroundColor = color; c.baseForegroundColor = UIColor.whiteColor; }
    else c.baseForegroundColor = UIColor.whiteColor;
    c.contentInsets = NSDirectionalEdgeInsetsMake(8, 16, 8, 16);
    MRGBlockButton *b = [self buttonWithConfiguration:c primaryAction:nil];
    b.action = action;
    [b addTarget:b action:@selector(fire) forControlEvents:UIControlEventTouchUpInside];
    return b;
}
- (void)fire { if (self.action) self.action(); }
@end

#pragma mark - the page

@interface MRGChatController : UIViewController <UITextFieldDelegate>
@end

@implementation MRGChatController {
    UIScrollView *_scroll;
    UIStackView *_stack;
    UITextField *_field;
    UIButton *_send;
    UILabel *_busy;
    UIView *_empty;
    NSUInteger _shown;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    MRGBackgroundView *bg = [[MRGBackgroundView alloc] initWithFrame:self.view.bounds];
    bg.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    bg.extraDim = 0.35;
    [self.view addSubview:bg];
    UIVisualEffectView *blur = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterialDark]];
    blur.frame = self.view.bounds;
    blur.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:blur];

    // Header: ✦ title, new chat, close.
    UIImageView *mark = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"sparkles" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:18 weight:UIImageSymbolWeightSemibold]]];
    mark.tintColor = MRGAccent();
    [mark setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    UILabel *title = label(20, UIFontWeightBold, UIColor.whiteColor, 1);
    title.text = @"Chat with your DJ";
    __weak typeof(self) weakSelf = self;
    MRGBlockButton *fresh = [MRGBlockButton symbol:@"square.and.pencil" size:17 tint:UIColor.whiteColor action:^{ [MRGChat.shared reset]; [weakSelf rebuild]; }];
    fresh.accessibilityLabel = @"New chat";
    MRGBlockButton *close = [MRGBlockButton symbol:@"xmark" size:15 tint:UIColor.whiteColor action:^{ [weakSelf dismissViewControllerAnimated:YES completion:nil]; }];
    close.accessibilityLabel = @"Close";
    MRGBlockButton *gear = [MRGBlockButton symbol:@"gearshape.fill" size:16 tint:UIColor.whiteColor action:^{ if (weakSelf) MRGShowDJSettings(weakSelf); }];
    gear.accessibilityLabel = @"AI DJ settings";
    title.adjustsFontSizeToFitWidth = YES;
    title.minimumScaleFactor = 0.7;
    UIStackView *head = [[UIStackView alloc] initWithArrangedSubviews:@[mark, title, [UIView new], gear, fresh, close]];
    head.spacing = 14;
    head.alignment = UIStackViewAlignmentCenter;
    head.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:head];

    _scroll = [UIScrollView new];
    _scroll.translatesAutoresizingMaskIntoConstraints = NO;
    _scroll.alwaysBounceVertical = YES;
    _scroll.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    [self.view addSubview:_scroll];
    _stack = [UIStackView new];
    _stack.axis = UILayoutConstraintAxisVertical;
    _stack.spacing = 10;
    _stack.translatesAutoresizingMaskIntoConstraints = NO;
    [_scroll addSubview:_stack];

    // Input bar: a capsule field and a solid accent send button.
    UIView *bar = [UIView new];
    bar.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:bar];
    UIView *fieldBox = [UIView new];
    fieldBox.backgroundColor = [UIColor colorWithWhite:1 alpha:0.12];
    fieldBox.layer.cornerRadius = 22;
    fieldBox.layer.cornerCurve = kCACornerCurveContinuous;
    fieldBox.translatesAutoresizingMaskIntoConstraints = NO;
    [bar addSubview:fieldBox];
    _field = [UITextField new];
    _field.attributedPlaceholder = [[NSAttributedString alloc] initWithString:@"Ask anything, or tell me what to do…" attributes:@{NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:0.45]}];
    _field.textColor = UIColor.whiteColor;
    _field.font = [UIFont systemFontOfSize:16];
    _field.tintColor = MRGAccent();
    _field.returnKeyType = UIReturnKeySend;
    _field.enablesReturnKeyAutomatically = YES;
    _field.delegate = self;
    _field.translatesAutoresizingMaskIntoConstraints = NO;
    [fieldBox addSubview:_field];
    UIButtonConfiguration *sc = [UIButtonConfiguration filledButtonConfiguration];
    sc.image = [UIImage systemImageNamed:@"arrow.up" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:15 weight:UIImageSymbolWeightBold]];
    sc.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    sc.baseBackgroundColor = MRGAccent();
    sc.baseForegroundColor = MRGOnAccent();
    sc.contentInsets = NSDirectionalEdgeInsetsZero;
    _send = [UIButton buttonWithConfiguration:sc primaryAction:nil];
    _send.accessibilityLabel = @"Send";
    _send.translatesAutoresizingMaskIntoConstraints = NO;
    [_send addTarget:self action:@selector(sendTapped) forControlEvents:UIControlEventTouchUpInside];
    [bar addSubview:_send];

    _busy = label(13, UIFontWeightMedium, MRGAccent(), 1);
    _busy.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_busy];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [head.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:22],
        [head.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:20],
        [head.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-20],
        [head.heightAnchor constraintEqualToConstant:36],
        [_scroll.topAnchor constraintEqualToAnchor:head.bottomAnchor constant:8],
        [_scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_scroll.bottomAnchor constraintEqualToAnchor:_busy.topAnchor constant:-4],
        [_stack.topAnchor constraintEqualToAnchor:_scroll.contentLayoutGuide.topAnchor constant:8],
        [_stack.bottomAnchor constraintEqualToAnchor:_scroll.contentLayoutGuide.bottomAnchor constant:-12],
        [_stack.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [_stack.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
        [_busy.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:22],
        [_busy.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-22],
        [_busy.bottomAnchor constraintEqualToAnchor:bar.topAnchor constant:-6],
        [bar.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:14],
        [bar.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-14],
        [bar.bottomAnchor constraintEqualToAnchor:self.view.keyboardLayoutGuide.topAnchor constant:-10],
        [bar.heightAnchor constraintEqualToConstant:44],
        [fieldBox.leadingAnchor constraintEqualToAnchor:bar.leadingAnchor],
        [fieldBox.topAnchor constraintEqualToAnchor:bar.topAnchor],
        [fieldBox.bottomAnchor constraintEqualToAnchor:bar.bottomAnchor],
        [fieldBox.trailingAnchor constraintEqualToAnchor:_send.leadingAnchor constant:-8],
        [_field.leadingAnchor constraintEqualToAnchor:fieldBox.leadingAnchor constant:16],
        [_field.trailingAnchor constraintEqualToAnchor:fieldBox.trailingAnchor constant:-12],
        [_field.topAnchor constraintEqualToAnchor:fieldBox.topAnchor],
        [_field.bottomAnchor constraintEqualToAnchor:fieldBox.bottomAnchor],
        [_send.trailingAnchor constraintEqualToAnchor:bar.trailingAnchor],
        [_send.centerYAnchor constraintEqualToAnchor:bar.centerYAnchor],
        [_send.widthAnchor constraintEqualToConstant:40],
        [_send.heightAnchor constraintEqualToConstant:40],
    ]];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(changed) name:MRGChatChangedNotification object:nil];
    [self rebuild];
}

- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }

- (BOOL)textFieldShouldReturn:(UITextField *)tf { [self sendTapped]; return YES; }

- (void)sendTapped {
    NSString *t = _field.text;
    if (!t.length || MRGChat.shared.isBusy) return;
    _field.text = nil;
    [MRGChat.shared send:t];
}

- (UIView *)emptyView {
    UILabel *t = label(15, UIFontWeightSemibold, UIColor.whiteColor, 0);
    t.text = @"Ask me about your listening or tell me what to do.";
    UILabel *ex = label(14, UIFontWeightRegular, kDim(), 0);
    ex.text = @"“When did I first play Frank Ocean?”\n“Play something underground like Burial.”\n“Make a playlist of rainy-day songs.”\n“Add this song to my Mirage playlist.”";
    UILabel *privacy = label(12, UIFontWeightRegular, [UIColor colorWithWhite:1 alpha:0.45], 0);
    NSString *provider = MRGAIProvider() != MRGProviderNone ? MRGProviderName(MRGAIProvider()) : @"your AI provider";
    privacy.text = [NSString stringWithFormat:@"Privacy: what you type, track and artist names, and only the answers your questions need from the listening history on this iPhone (like an artist's first play) are sent to %@. Your history itself stays on this iPhone. It covers what Mirage recorded since it was installed, plus any Spotify data you import (Settings → Mirage → AI DJ → Listening history).", provider];
    UIStackView *s = [[UIStackView alloc] initWithArrangedSubviews:@[t, ex, privacy]];
    s.axis = UILayoutConstraintAxisVertical;
    s.spacing = 12;
    return cardBox(s);
}

- (void)changed { [self rebuild]; }

- (void)rebuild {
    NSArray<MRGChatItem *> *items = MRGChat.shared.items;
    // Re-rendered whole on every change (a card can change state); cheap at chat sizes.
    for (UIView *v in _stack.arrangedSubviews) [v removeFromSuperview];
    if (!items.count) [_stack addArrangedSubview:[self emptyView]];
    for (MRGChatItem *i in items) {
        UIView *v = nil;
        @try { v = [self viewFor:i]; } @catch (NSException *e) { v = nil; }
        if (v) [_stack addArrangedSubview:v];
    }
    BOOL grew = items.count != _shown;
    _shown = items.count;
    _busy.text = MRGChat.shared.isBusy ? MRGChat.shared.busyText : (MRGAIProvider() == MRGProviderNone ? @"Add an API key in Mirage settings to chat." : @"");
    _send.enabled = !MRGChat.shared.isBusy && MRGAIProvider() != MRGProviderNone;
    [self.view layoutIfNeeded];
    if (grew || MRGChat.shared.isBusy) {
        CGFloat bottom = MAX(0, _scroll.contentSize.height - _scroll.bounds.size.height + _scroll.adjustedContentInset.bottom);
        [_scroll setContentOffset:CGPointMake(0, bottom) animated:YES];
    }
}

- (UIView *)bubble:(NSString *)text mine:(BOOL)mine color:(UIColor *)color {
    UILabel *l = label(16, UIFontWeightRegular, mine ? MRGOnAccent() : UIColor.whiteColor, 0);
    l.text = text;
    UIView *b = [UIView new];
    b.backgroundColor = color ?: (mine ? MRGAccent() : [UIColor colorWithWhite:1 alpha:0.12]);
    b.layer.cornerRadius = 18;
    b.layer.cornerCurve = kCACornerCurveContinuous;
    l.translatesAutoresizingMaskIntoConstraints = NO;
    [b addSubview:l];
    [NSLayoutConstraint activateConstraints:@[
        [l.leadingAnchor constraintEqualToAnchor:b.leadingAnchor constant:14],
        [l.trailingAnchor constraintEqualToAnchor:b.trailingAnchor constant:-14],
        [l.topAnchor constraintEqualToAnchor:b.topAnchor constant:9],
        [l.bottomAnchor constraintEqualToAnchor:b.bottomAnchor constant:-9],
    ]];
    UIView *row = [UIView new];
    b.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:b];
    [NSLayoutConstraint activateConstraints:@[
        [b.topAnchor constraintEqualToAnchor:row.topAnchor],
        [b.bottomAnchor constraintEqualToAnchor:row.bottomAnchor],
        [b.widthAnchor constraintLessThanOrEqualToAnchor:row.widthAnchor multiplier:0.82],
        mine ? [b.trailingAnchor constraintEqualToAnchor:row.trailingAnchor] : [b.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
    ]];
    return row;
}

- (UIView *)viewFor:(MRGChatItem *)i {
    if ([i.kind isEqualToString:@"user"]) return [self bubble:i.text mine:YES color:nil];
    if ([i.kind isEqualToString:@"dj"]) return i.text.length ? [self bubble:i.text mine:NO color:nil] : nil;
    if ([i.kind isEqualToString:@"error"]) return [self bubble:i.text mine:NO color:[UIColor colorWithRed:0.55 green:0.12 blue:0.14 alpha:0.75]];
    if ([i.kind isEqualToString:@"note"]) { UILabel *l = label(13, UIFontWeightMedium, kDim(), 0); l.text = i.text; l.textAlignment = NSTextAlignmentCenter; return l; }
    NSDictionary *c = i.card;
    NSString *type = c[@"type"];
    if ([type isEqualToString:@"first_played"]) return [self firstPlayed:c];
    if ([type isEqualToString:@"tracks"]) return [self tracks:c];
    if ([type isEqualToString:@"playlist"]) return [self playlist:c];
    if ([type isEqualToString:@"confirm_delete"]) return [self confirm:i];
    if ([type isEqualToString:@"list"]) return [self list:c];
    return nil;
}

- (UIView *)firstPlayed:(NSDictionary *)c {
    UIImageView *pic = art(64, YES, @"person.fill");
    loadInto(pic, c[@"image"]);
    UILabel *cap = label(11, UIFontWeightBold, MRGAccent(), 1);
    cap.text = @"FIRST PLAYED";
    UILabel *name = label(18, UIFontWeightBold, UIColor.whiteColor, 1);
    name.text = c[@"artist"];
    UILabel *date = label(15, UIFontWeightSemibold, UIColor.whiteColor, 1);
    date.text = longDate(c[@"date"]);
    UILabel *track = label(13, UIFontWeightRegular, kDim(), 2);
    track.text = [c[@"firstTrack"] length] ? [NSString stringWithFormat:@"with “%@”", c[@"firstTrack"]] : nil;
    // Two short lines that wrap instead of truncating (0.3.1 cut "1 plays · 0 min since · recorded…" off).
    NSInteger plays = [c[@"plays"] respondsToSelector:@selector(integerValue)] ? [c[@"plays"] integerValue] : 0;
    NSInteger minutes = [c[@"minutes"] respondsToSelector:@selector(integerValue)] ? [c[@"minutes"] integerValue] : 0;
    NSMutableArray *bits = [NSMutableArray arrayWithObject:[NSString stringWithFormat:@"%ld play%@ since", (long)plays, plays == 1 ? @"" : @"s"]];
    if (minutes > 0) [bits addObject:minutes >= 120 ? [NSString stringWithFormat:@"%.1f h", minutes / 60.0] : [NSString stringWithFormat:@"%ld min", (long)minutes]];
    UILabel *stats = label(12, UIFontWeightMedium, kDim(), 2);
    stats.text = [bits componentsJoinedByString:@" · "];
    stats.adjustsFontSizeToFitWidth = YES;
    stats.minimumScaleFactor = 0.8;
    UILabel *source = label(11, UIFontWeightRegular, kDim(), 1);
    source.text = [c[@"source"] isEqualToString:@"live"] ? @"Recorded by Mirage" : @"From your Spotify data";
    source.adjustsFontSizeToFitWidth = YES;
    source.minimumScaleFactor = 0.8;
    name.adjustsFontSizeToFitWidth = YES;
    name.minimumScaleFactor = 0.7;
    UIStackView *texts = [[UIStackView alloc] initWithArrangedSubviews:@[cap, name, date, track, stats, source]];
    texts.axis = UILayoutConstraintAxisVertical;
    texts.spacing = 2;
    [texts setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    [texts setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    for (UILabel *l in @[cap, name, date, track, stats, source]) [l setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    [pic setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    NSMutableArray *views = [NSMutableArray arrayWithObjects:pic, texts, nil];
    NSString *uri = c[@"firstURI"];
    if ([uri hasPrefix:@"spotify:track:"]) {
        MRGBlockButton *play = [MRGBlockButton symbol:@"play.circle.fill" size:30 tint:MRGAccent() action:^{ [MRGChat.shared playTrack:@{@"uri": uri}]; }];
        play.accessibilityLabel = @"Play the first track";
        [views addObject:play];
    }
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:views];
    row.spacing = 14;
    row.alignment = UIStackViewAlignmentCenter;
    return cardBox(row);
}

- (UIView *)trackRow:(NSDictionary *)t {
    UIImageView *cover = art(44, NO, @"music.note");
    loadInto(cover, t[@"image"]);
    UILabel *title = label(15, UIFontWeightSemibold, UIColor.whiteColor, 1);
    title.text = [t[@"title"] length] ? t[@"title"] : t[@"uri"];
    UILabel *artist = label(13, UIFontWeightRegular, kDim(), 1);
    artist.text = t[@"artist"];
    UIStackView *texts = [[UIStackView alloc] initWithArrangedSubviews:@[title, artist]];
    texts.axis = UILayoutConstraintAxisVertical;
    texts.spacing = 1;
    MRGBlockButton *play = [MRGBlockButton symbol:@"play.circle.fill" size:28 tint:MRGAccent() action:^{ [MRGChat.shared playTrack:t]; }];
    play.accessibilityLabel = [NSString stringWithFormat:@"Play %@", title.text];
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[cover, texts, play]];
    row.spacing = 12;
    row.alignment = UIStackViewAlignmentCenter;
    return row;
}

- (UIView *)tracks:(NSDictionary *)c {
    UILabel *cap = label(11, UIFontWeightBold, MRGAccent(), 1);
    cap.text = [c[@"title"] uppercaseString];
    NSMutableArray *rows = [NSMutableArray arrayWithObject:cap];
    NSArray *tracks = c[@"tracks"];
    for (NSDictionary *t in tracks) { [rows addObject:[self trackRow:t]]; if (rows.count > 8) break; }
    if (tracks.count > 8) { UILabel *more = label(12, UIFontWeightMedium, kDim(), 1); more.text = [NSString stringWithFormat:@"+ %lu more", (unsigned long)(tracks.count - 8)]; [rows addObject:more]; }
    UIStackView *s = [[UIStackView alloc] initWithArrangedSubviews:rows];
    s.axis = UILayoutConstraintAxisVertical;
    s.spacing = 10;
    return cardBox(s);
}

- (UIView *)playlist:(NSDictionary *)c {
    UIImageView *icon = art(48, NO, @"music.note.list");
    icon.tintColor = MRGAccent();
    UILabel *name = label(16, UIFontWeightSemibold, UIColor.whiteColor, 1);
    name.text = c[@"name"];
    UILabel *detail = label(13, UIFontWeightRegular, kDim(), 2);
    detail.text = c[@"detail"];
    UIStackView *texts = [[UIStackView alloc] initWithArrangedSubviews:@[name, detail]];
    texts.axis = UILayoutConstraintAxisVertical;
    texts.spacing = 2;
    NSString *uri = c[@"uri"];
    MRGBlockButton *open = [MRGBlockButton symbol:@"arrow.up.forward.circle.fill" size:26 tint:UIColor.whiteColor action:^{
        NSURL *u = [NSURL URLWithString:uri];
        if (u) [UIApplication.sharedApplication openURL:u options:@{} completionHandler:nil];
    }];
    open.accessibilityLabel = @"Open playlist";
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[icon, texts, open]];
    row.spacing = 12;
    row.alignment = UIStackViewAlignmentCenter;
    return cardBox(row);
}

- (UIView *)confirm:(MRGChatItem *)item {
    NSDictionary *c = item.card;
    NSString *state = c[@"state"];
    UILabel *t = label(15, UIFontWeightSemibold, UIColor.whiteColor, 0);
    t.text = [NSString stringWithFormat:@"Delete “%@”?", c[@"name"]];
    UILabel *d = label(13, UIFontWeightRegular, kDim(), 0);
    if ([state isEqualToString:@"pending"]) d.text = @"It's removed from your library. If it's yours, Spotify lets you recover it for 90 days at spotify.com/account/recover-playlists.";
    else if ([state isEqualToString:@"working"]) d.text = @"Deleting…";
    else d.text = c[@"detail"] ?: state;
    NSMutableArray *views = [NSMutableArray arrayWithObjects:t, d, nil];
    if ([state isEqualToString:@"pending"]) {
        MRGBlockButton *del = [MRGBlockButton pill:@"Delete" filled:YES color:UIColor.systemRedColor action:^{ [MRGChat.shared confirmDelete:item]; }];
        MRGBlockButton *keep = [MRGBlockButton pill:@"Cancel" filled:NO color:nil action:^{ [MRGChat.shared cancelDelete:item]; }];
        UIStackView *buttons = [[UIStackView alloc] initWithArrangedSubviews:@[del, keep, [UIView new]]];
        buttons.spacing = 10;
        [views addObject:buttons];
    }
    UIStackView *s = [[UIStackView alloc] initWithArrangedSubviews:views];
    s.axis = UILayoutConstraintAxisVertical;
    s.spacing = 8;
    UIView *box = cardBox(s);
    if ([state isEqualToString:@"pending"]) box.layer.borderColor = [UIColor.systemRedColor colorWithAlphaComponent:0.5].CGColor;
    return box;
}

- (UIView *)list:(NSDictionary *)c {
    UILabel *cap = label(11, UIFontWeightBold, MRGAccent(), 1);
    cap.text = [c[@"title"] uppercaseString];
    NSMutableArray *rows = [NSMutableArray arrayWithObject:cap];
    NSUInteger n = 0;
    for (NSDictionary *r in c[@"rows"]) {
        UILabel *num = label(14, UIFontWeightBold, kDim(), 1);
        num.text = [NSString stringWithFormat:@"%lu", (unsigned long)++n];
        [num.widthAnchor constraintEqualToConstant:22].active = YES;
        UILabel *t = label(15, UIFontWeightSemibold, UIColor.whiteColor, 1);
        t.text = r[@"title"];
        UILabel *d = label(13, UIFontWeightRegular, kDim(), 1);
        d.text = r[@"detail"];
        [d setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [d setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[num, t, d]];
        row.spacing = 8;
        [rows addObject:row];
    }
    UIStackView *s = [[UIStackView alloc] initWithArrangedSubviews:rows];
    s.axis = UILayoutConstraintAxisVertical;
    s.spacing = 8;
    return cardBox(s);
}

@end

void MRGShowDJChat(UIViewController *from) {
    UIViewController *top = from;
    while (top.presentedViewController) top = top.presentedViewController;
    if ([top isKindOfClass:MRGChatController.class]) return;
    MRGChatController *chat = [MRGChatController new];
    chat.modalPresentationStyle = UIModalPresentationPageSheet;
    UISheetPresentationController *p = chat.sheetPresentationController;
    p.detents = @[UISheetPresentationControllerDetent.largeDetent];
    p.prefersGrabberVisible = YES;
    p.preferredCornerRadius = 32;
    [top presentViewController:chat animated:YES completion:nil];
}
