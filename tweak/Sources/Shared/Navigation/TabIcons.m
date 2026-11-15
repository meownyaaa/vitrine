#import "Core/SGCore.h"
#import "TabIcons.h"
#import "Headers/SPTEncoreIconView.h"
#import <objc/message.h>
#import <objc/runtime.h>

NSString *const SGTabIconSetSymbols = @"symbols";

static char kSymbolNameKey;

static NSBundle *privateGlyphsBundle(void) {
    static NSBundle *bundle;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class cls = NSClassFromString(@"SFSCoreGlyphsBundle");
        SEL sel = NSSelectorFromString(@"private");
        if (cls && [cls respondsToSelector:sel]) {
            bundle = ((NSBundle *(*)(id, SEL))objc_msgSend)(cls, sel);
        }
        if (!bundle) bundle = [NSBundle bundleWithPath:@"/System/Library/PrivateFrameworks/SFSymbols.framework/CoreGlyphsPrivate.bundle"];
        if (!bundle) bundle = [NSBundle bundleWithPath:@"/System/Library/CoreServices/CoreGlyphsPrivate.bundle"];
    });
    return bundle;
}

static id privateAssetManager(void) {
    static id mgr;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSBundle *bundle = privateGlyphsBundle();
        if (!bundle) return;
        Class cls = NSClassFromString(@"_UIAssetManager");
        SEL sel = NSSelectorFromString(@"assetManagerForBundle:");
        if (cls && [cls respondsToSelector:sel]) {
            mgr = ((id (*)(id, SEL, id))objc_msgSend)(cls, sel, bundle);
        }
    });
    return mgr;
}

UIImage *SGSymbolImage(NSString *name) {
    if (!name.length) return nil;
    static UIImageSymbolConfiguration *config;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        config = [UIImageSymbolConfiguration configurationWithPointSize:19 weight:UIImageSymbolWeightSemibold];
    });
    UIImage *image = [UIImage systemImageNamed:name withConfiguration:config];
    if (image) return image;

    SEL privateSel = NSSelectorFromString(@"_systemImageNamed:withConfiguration:allowPrivate:");
    if ([UIImage respondsToSelector:privateSel]) {
        image = ((UIImage *(*)(id, SEL, NSString *, id, BOOL))objc_msgSend)(UIImage.class, privateSel, name, config, YES);
        if (image) return image;
    }

    id assetMgr = privateAssetManager();
    if (assetMgr && [assetMgr respondsToSelector:@selector(imageNamed:)]) {
        @synchronized (assetMgr) {
            image = ((UIImage *(*)(id, SEL, NSString *))objc_msgSend)(assetMgr, @selector(imageNamed:), name);
        }
        if (image) image = [image imageByApplyingSymbolConfiguration:config] ?: image;
    }
    return image;
}

NSString *SGTabIconSymbolName(UIView *icon) {
    return icon ? objc_getAssociatedObject(icon, &kSymbolNameKey) : nil;
}

// SPTEncoreIcon exposes one class method per glyph ("podcasts", "heart"), 538 of them in 9.1.78.
static UIView *encoreView(NSString *name, UIColor *color) {
    Class icon = NSClassFromString(@"SPTEncoreIcon");
    Class view = NSClassFromString(@"SPTEncoreIconView");
    SEL glyphSel = NSSelectorFromString(name.length ? name : @"star");
    if (!icon || !view || ![icon respondsToSelector:glyphSel]) return nil;
    id glyph = ((id (*)(id, SEL))objc_msgSend)(icon, glyphSel);
    SPTEncoreIconView *encore = glyph ? [[view alloc] initWithIcon:glyph] : nil;
    [encore setForegroundColor:color];
    return encore;
}

static UIView *symbolView(UIImage *image, UIColor *color) {
    UIImageView *view = [[UIImageView alloc] initWithImage:[image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate]];
    view.tintColor = color;
    view.contentMode = UIViewContentModeCenter;
    return view;
}

UIView *SGTabIconView(NSString *name, BOOL symbol, UIColor *color) {
    UIImage *image = symbol ? SGSymbolImage(name) : nil;
    UIView *view = image ? symbolView(image, color) : encoreView(name, color);
    if (view) {
        if (image) objc_setAssociatedObject(view, &kSymbolNameKey, name, OBJC_ASSOCIATION_COPY_NONATOMIC);
        return view;
    }
    view = symbolView(SGSymbolImage(@"star.fill"), color);
    objc_setAssociatedObject(view, &kSymbolNameKey, @"star.fill", OBJC_ASSOCIATION_COPY_NONATOMIC);
    return view;
}

#pragma mark - the catalogs

// Methods every class answers, which are not glyphs and some of which must not be called bare.
static BOOL notAGlyph(NSString *name) {
    static NSSet *names;
    if (!names) names = [NSSet setWithArray:@[@"alloc", @"new", @"class", @"superclass", @"copy", @"mutableCopy", @"description",
                                              @"debugDescription", @"initialize", @"load", @"hash", @"self", @"dealloc", @"init"]];
    return [name hasPrefix:@"_"] || [name hasPrefix:@"."] || [names containsObject:name];
}

// The class methods on SPTEncoreIcon's metaclass that take nothing and return an object, each called
// once and kept when what it returns has a name.
NSArray<NSString *> *SGEncoreGlyphNames(void) {
    static NSArray<NSString *> *glyphs;
    if (glyphs) return glyphs;
    Class icon = NSClassFromString(@"SPTEncoreIcon");
    NSMutableArray<NSString *> *found = [NSMutableArray array];
    unsigned int count = 0;
    Method *methods = icon ? class_copyMethodList(object_getClass(icon), &count) : NULL;
    for (unsigned int i = 0; i < count; i++) {
        NSString *name = NSStringFromSelector(method_getName(methods[i]));
        // Two arguments are self and _cmd: a selector with no colon of its own.
        if (method_getNumberOfArguments(methods[i]) != 2 || [name containsString:@":"] || notAGlyph(name)) continue;
        const char *types = method_getTypeEncoding(methods[i]);
        if (!types || types[0] != '@') continue;
        @try {
            id glyph = ((id (*)(id, SEL))objc_msgSend)(icon, method_getName(methods[i]));
            if ([glyph respondsToSelector:@selector(name)] && [[glyph name] isKindOfClass:NSString.class] && [glyph name].length) [found addObject:name];
        } @catch (NSException *e) {
            SGLog(@"tab icons: +[SPTEncoreIcon %@] threw %@", name, e.reason);
        }
    }
    free(methods);
    glyphs = [found sortedArrayUsingSelector:@selector(caseInsensitiveCompare:)];
    SGLog(@"tab icons: %lu Encore glyphs", (unsigned long)glyphs.count);
    return glyphs;
}

NSArray<NSString *> *SGCommonTabGlyphs(void) {
    NSArray<NSString *> *all = SGEncoreGlyphNames();
    NSMutableArray<NSString *> *kept = [NSMutableArray array];
    for (NSString *name in @[@"home", @"search", @"collection", @"heart", @"playlist", @"album", @"artist", @"podcasts",
                             @"audiobook", @"downloaded", @"bookmark", @"browse", @"star", @"user", @"events", @"queue",
                             @"radio", @"plus"]) {
        if ([all containsObject:name]) [kept addObject:name];
    }
    return kept;
}

static NSArray<NSString *> *curatedPrivateSymbols(void) {
    return @[
        @"music.note.square.stack.fill", @"music.note.square.stack",
        @"apple.podcasts.square.stack.fill", @"apple.podcasts.square.stack",
        @"apple.music", @"apple.music.fill",
        @"apple.news", @"apple.news.fill",
        @"apple.tv", @"apple.tv.fill",
        @"homepod.2.fill", @"homepod.2",
        @"homepodmini.2.fill", @"homepodmini.2",
        @"visionpro.fill", @"visionpro",
        @"airplayaudio", @"airplayvideo",
        @"faceid", @"touchid"
    ];
}

NSArray<NSString *> *SGCommonTabSymbols(void) {
    NSMutableArray<NSString *> *kept = [NSMutableArray array];
    for (NSString *name in @[@"house.fill", @"magnifyingglass", @"books.vertical.fill", @"heart.fill", @"music.note.list",
                             @"square.stack.fill", @"square.stack", @"music.note.square.stack.fill", @"music.note.square.stack",
                             @"square.grid.2x2.fill", @"square.grid.2x2", @"play.circle.fill",
                             @"music.mic", @"mic.fill", @"globe", @"dot.radiowaves.left.and.right", @"radio.fill", @"headphones",
                             @"star.fill", @"clock.fill", @"arrow.down.circle.fill", @"bookmark.fill", @"person.crop.circle.fill",
                             @"sparkles", @"flame.fill", @"chart.bar.fill", @"waveform", @"calendar", @"ticket.fill",
                             @"list.bullet", @"plus"]) {
        if (SGSymbolImage(name)) [kept addObject:name];
    }
    return kept;
}

// The same symbol drawn for a script (heart.text.square.ar, .hi, .ja…), which a search would list
// once per language.
static BOOL scriptVariant(NSString *name) {
    static NSSet *scripts;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        scripts = [NSSet setWithArray:@[@"ar", @"hi", @"he", @"ja", @"th", @"zh", @"bn", @"gu", @"kn", @"ko", @"ml",
                                        @"mr", @"or", @"pa", @"te", @"si", @"ta", @"el", @"ru", @"km", @"my"]];
    });
    NSRange dot = [name rangeOfString:@"." options:NSBackwardsSearch];
    return dot.location != NSNotFound && [scripts containsObject:[name substringFromIndex:dot.location + 1]];
}

static NSArray<NSString *> *readPlistSymbolNames(NSBundle *bundle) {
    if (!bundle) return nil;
    NSString *path = [bundle pathForResource:@"symbol_order" ofType:@"plist"];
    NSArray *names = path ? [NSArray arrayWithContentsOfFile:path] : nil;
    if ([names isKindOfClass:NSArray.class] && names.count) return names;

    path = [bundle pathForResource:@"name_availability" ofType:@"plist"];
    NSDictionary *availability = path ? [NSDictionary dictionaryWithContentsOfFile:path] : nil;
    NSDictionary *symbols = [availability isKindOfClass:NSDictionary.class] ? availability[@"symbols"] : nil;
    if ([symbols isKindOfClass:NSDictionary.class] && symbols.count) return symbols.allKeys;

    path = [bundle pathForResource:@"metadata" ofType:@"plist"];
    NSDictionary *meta = path ? [NSDictionary dictionaryWithContentsOfFile:path] : nil;
    NSDictionary *metaSymbols = [meta isKindOfClass:NSDictionary.class] ? meta[@"symbols"] : nil;
    if ([metaSymbols isKindOfClass:NSDictionary.class] && metaSymbols.count) return metaSymbols.allKeys;

    return nil;
}

// UIKit lists no symbol names. The system's own catalog does, in CoreGlyphs (a link in CoreServices to
// SFSymbols.framework's bundle on iOS 26 and 27, checked against the iOS 27 simulator runtime): its
// symbol_order.plist names each symbol once, in the SF Symbols app's order.
static NSArray<NSString *> *systemSymbolNames(void) {
    NSMutableOrderedSet<NSString *> *set = [NSMutableOrderedSet orderedSet];

    NSBundle *publicBundle = [NSBundle bundleWithPath:@"/System/Library/CoreServices/CoreGlyphs.bundle"];
    if (!publicBundle) publicBundle = [NSBundle bundleWithPath:@"/System/Library/PrivateFrameworks/SFSymbols.framework/CoreGlyphs.bundle"];
    NSArray *publicNames = readPlistSymbolNames(publicBundle);
    if (publicNames.count) [set addObjectsFromArray:publicNames];

    NSBundle *privateBundle = privateGlyphsBundle();
    NSArray *privateNames = readPlistSymbolNames(privateBundle);
    if (privateNames.count) [set addObjectsFromArray:privateNames];

    [set addObjectsFromArray:curatedPrivateSymbols()];

    return set.array;
}

void SGLoadSymbolNames(void (^done)(NSArray<NSString *> *names)) {
    static NSArray<NSString *> *loaded;
    static NSMutableArray *waiting;
    if (loaded) {
        done(loaded);
        return;
    }
    BOOL first = !waiting;
    if (first) waiting = [NSMutableArray array];
    [waiting addObject:[done copy]];
    if (!first) return;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray *names = systemSymbolNames();
        // Each name is asked of UIKit, 8,500 of them on iOS 27, so the asking is spread over the cores.
        NSUInteger count = names.count;
        BOOL *draws = calloc(count ?: 1, sizeof(BOOL));
        dispatch_apply(count, DISPATCH_APPLY_AUTO, ^(size_t i) {
            id name = names[i];
            draws[i] = [name isKindOfClass:NSString.class] && !scriptVariant(name) && SGSymbolImage(name);
        });
        NSMutableArray<NSString *> *kept = [NSMutableArray array];
        for (NSUInteger i = 0; i < count; i++) if (draws[i]) [kept addObject:names[i]];
        free(draws);
        dispatch_async(dispatch_get_main_queue(), ^{
            loaded = kept.count ? [kept copy] : SGCommonTabSymbols();
            SGLog(@"tab icons: %lu SF Symbols of %lu listed", (unsigned long)kept.count, (unsigned long)names.count);
            for (void (^callback)(NSArray *) in waiting) callback(loaded);
            waiting = nil;
        });
    });
}
