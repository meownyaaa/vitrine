// Telemetry blocking: an NSURLProtocol that answers the analytics endpoints itself instead of
// letting them out, and keeps a count of what it stopped for the Privacy page.
//
// The SDKs Spotify ships each send somewhere of their own: Firebase to app-measurement.com, Facebook
// to graph.facebook.com/<id>/activities, then Branch, Comscore, Segment. None of it carries playback,
// search, sign-in or deep links, so a whole host is named where it does nothing else and a path where
// it does. Spotify's own events, sent to spclient's
// /gabo-receiver-service/, are left alone: Recents is built from the plays reported among them.
//
// A protocol handed to +registerClass: is only consulted by NSURLConnection and the shared
// session, so both session configurations are given it as well: that is what the SDKs build their
// sessions from. What the core sends over its own sockets is out of reach either way.
#import "Core/SGCore.h"
#import "Privacy.h"

typedef struct { const char *host, *path, *label; } SGBlockRule;

// host matched on the domain and its subdomains, path as a substring; no path means the whole host.
static const SGBlockRule kRules[] = {
    {"app-measurement.com",               NULL,                      "Firebase"},
    {"crashlytics.com",                   NULL,                      "Crashlytics"},
    {"facebook.com",                      "/activities",             "Facebook"},
    {"ep1.facebook.com",                  NULL,                      "Facebook"},
    {"ep2.facebook.com",                  NULL,                      "Facebook"},
    {"branch.io",                         "/v1/event",               "Branch"},
    {"scorecardresearch.com",             NULL,                      "Comscore"},
    {"segment.io",                        NULL,                      "Segment"},
    {"zqtk.net",                          NULL,                      "Segment"},
    {"google-analytics.com",              NULL,                      "Google"},
    {"googleadservices.com",              NULL,                      "Google"},
    {"doubleclick.net",                   NULL,                      "Google"},
};
static const size_t kRuleCount = sizeof(kRules) / sizeof(kRules[0]);
// The rules as NSStrings, made once: the protocol is asked about nearly every request the app sends.
static NSString *sg_domains[sizeof(kRules) / sizeof(kRules[0])], *sg_dotted[sizeof(kRules) / sizeof(kRules[0])],
                *sg_paths[sizeof(kRules) / sizeof(kRules[0])], *sg_labels[sizeof(kRules) / sizeof(kRules[0])];

static void boxRules(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        for (size_t i = 0; i < kRuleCount; i++) {
            sg_domains[i] = @(kRules[i].host);
            sg_dotted[i] = [@"." stringByAppendingString:sg_domains[i]];
            sg_paths[i] = kRules[i].path ? @(kRules[i].path) : nil;
            sg_labels[i] = @(kRules[i].label);
        }
    });
}

static NSString *const kCounts = @"spotifyglass.privacy.counts";
static NSMutableDictionary<NSString *, NSNumber *> *sg_counts;
static BOOL sg_unsaved;   // blocks counted since the counts were last written
static CFAbsoluteTime sg_savedAt;

@interface SGBlockProtocol : NSURLProtocol
@end

// The class object stands in for a lock: counting happens on whichever thread the request was made
// on, the Privacy page reads on the main one. A count stored under a label no rule has any more is
// dropped as it loads, so the total adds up to the rows the page shows.
static NSMutableDictionary<NSString *, NSNumber *> *countsLocked(void) {
    if (!sg_counts) {
        sg_counts = [[NSUserDefaults.standardUserDefaults dictionaryForKey:kCounts] mutableCopy] ?: [NSMutableDictionary dictionary];
        NSSet<NSString *> *current = [NSSet setWithArray:SGBlockedLabels()];
        for (NSString *label in sg_counts.allKeys) {
            if (![current containsObject:label]) sg_counts[label] = nil;
        }
    }
    return sg_counts;
}

// Counted in memory and written as AdBlock.m writes its counts: when Spotify leaves the screen and at most
// every 30 s while counting goes on, so a kill in the background (no notification comes) loses half a
// minute at most. Each write also wakes every defaults observer and empties the prefs memo. Called under
// the lock.
static void saveLocked(BOOL now) {
    if (!sg_unsaved || (!now && CFAbsoluteTimeGetCurrent() - sg_savedAt < 30)) return;
    SGPrefsWriteUnmemoized(^{ [NSUserDefaults.standardUserDefaults setObject:countsLocked() forKey:kCounts]; });
    sg_unsaved = NO;
    sg_savedAt = CFAbsoluteTimeGetCurrent();
}

static void countOne(NSString *label) {
    @synchronized (SGBlockProtocol.class) {
        NSMutableDictionary<NSString *, NSNumber *> *counts = countsLocked();
        counts[label] = @(counts[label].unsignedIntegerValue + 1);
        sg_unsaved = YES;
        saveLocked(NO);
    }
}

static NSString *labelFor(NSURL *url) {
    NSString *host = url.host.lowercaseString;
    if (!host) return nil;
    boxRules();
    NSString *path = nil;
    for (size_t i = 0; i < kRuleCount; i++) {
        if (![host isEqualToString:sg_domains[i]] && ![host hasSuffix:sg_dotted[i]]) continue;
        if (sg_paths[i]) {
            if (!path) path = url.path ?: @"";
            if (![path containsString:sg_paths[i]]) continue;
        }
        return sg_labels[i];
    }
    return nil;
}

NSArray<NSString *> *SGBlockedLabels(void) {
    boxRules();
    NSMutableArray<NSString *> *labels = [NSMutableArray array];
    for (size_t i = 0; i < kRuleCount; i++) {
        if (![labels containsObject:sg_labels[i]]) [labels addObject:sg_labels[i]];
    }
    return labels;
}

NSUInteger SGBlockedCount(NSString *label) {
    @synchronized (SGBlockProtocol.class) {
        NSDictionary<NSString *, NSNumber *> *counts = countsLocked();
        if (label) return counts[label].unsignedIntegerValue;
        NSUInteger total = 0;
        for (NSNumber *count in counts.allValues) total += count.unsignedIntegerValue;
        return total;
    }
}

void SGResetBlocked(void) {
    @synchronized (SGBlockProtocol.class) {
        sg_counts = [NSMutableDictionary dictionary];
        sg_unsaved = NO;
        [NSUserDefaults.standardUserDefaults removeObjectForKey:kCounts];
    }
}

@implementation SGBlockProtocol

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    return labelFor(request.URL) != nil;
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request {
    return request;
}

- (void)startLoading {
    NSString *label = labelFor(self.request.URL);
    if (label) countOne(label);
    // 204 rather than an error: the sender takes it for delivered and queues no retry behind it.
    NSHTTPURLResponse *answer = [[NSHTTPURLResponse alloc] initWithURL:self.request.URL statusCode:204 HTTPVersion:@"HTTP/1.1" headerFields:@{}];
    [self.client URLProtocol:self didReceiveResponse:answer cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    [self.client URLProtocolDidFinishLoading:self];
}

- (void)stopLoading {
}

@end

static NSURLSessionConfiguration *carryingProtocol(NSURLSessionConfiguration *configuration) {
    if (!configuration || [configuration.protocolClasses containsObject:SGBlockProtocol.class]) return configuration;
    NSMutableArray *classes = [configuration.protocolClasses mutableCopy] ?: [NSMutableArray array];
    [classes insertObject:SGBlockProtocol.class atIndex:0];
    configuration.protocolClasses = classes;
    return configuration;
}

%hook NSURLSessionConfiguration

+ (NSURLSessionConfiguration *)defaultSessionConfiguration {
    NSURLSessionConfiguration *configuration = %orig;
    return carryingProtocol(configuration);
}

+ (NSURLSessionConfiguration *)ephemeralSessionConfiguration {
    NSURLSessionConfiguration *configuration = %orig;
    return carryingProtocol(configuration);
}

%end

%ctor {
    if (SGEnabled(SGKeyBlockTelemetry)) {
        [NSURLProtocol registerClass:SGBlockProtocol.class];
        %init;
        // Spotify leaving the screen writes what was counted since the last write.
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationWillResignActiveNotification object:nil queue:nil
                                                    usingBlock:^(NSNotification *note) {
            @synchronized (SGBlockProtocol.class) { saveLocked(YES); }
        }];
    }
}
