// SponsorBlock API client and statistics store for Spotify podcast episodes.
// Ported from EeveeSpotify Reincarnated (GPL-3.0) and Spot-SponsorBlock-Extension.
#import "SGSponsorBlockAPI.h"
#import "Core/SGCore.h"
#import <CommonCrypto/CommonDigest.h>

@implementation SGSponsorBlockSegment
- (NSTimeInterval)duration {
    return self.end - self.start;
}

- (BOOL)isEqual:(id)object {
    if (self == object) return YES;
    if (![object isKindOfClass:[SGSponsorBlockSegment class]]) return NO;
    SGSponsorBlockSegment *other = (SGSponsorBlockSegment *)object;
    return (fabs(self.start - other.start) < 0.001 &&
            fabs(self.end - other.end) < 0.001 &&
            [self.category isEqualToString:other.category] &&
            [self.actionType isEqualToString:other.actionType] &&
            [self.uuid isEqualToString:other.uuid]);
}

- (NSUInteger)hash {
    return self.uuid.hash ^ (NSUInteger)(self.start * 1000);
}
@end

static NSUInteger sg_sponsorBlockSkipCount = 0;
static NSTimeInterval sg_sponsorBlockTimeSaved = 0;
static id kStatsLock;

static void ensureStatsLoaded(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        kStatsLock = [NSObject new];
        NSInteger storedCount = [NSUserDefaults.standardUserDefaults integerForKey:SGKeySponsorBlockSkipCount];
        sg_sponsorBlockSkipCount = storedCount > 0 ? (NSUInteger)storedCount : 0;
        double storedTime = [NSUserDefaults.standardUserDefaults doubleForKey:SGKeySponsorBlockTimeSaved];
        sg_sponsorBlockTimeSaved = (isfinite(storedTime) && storedTime > 0) ? storedTime : 0;
    });
}

static void persistStatsLocked(void) {
    NSInteger count = (NSInteger)sg_sponsorBlockSkipCount;
    double saved = sg_sponsorBlockTimeSaved;
    SGPrefsWriteUnmemoized(^{
        [NSUserDefaults.standardUserDefaults setInteger:count forKey:SGKeySponsorBlockSkipCount];
        [NSUserDefaults.standardUserDefaults setDouble:saved forKey:SGKeySponsorBlockTimeSaved];
    });
}

NSUInteger SGSponsorBlockSkipCount(void) {
    ensureStatsLoaded();
    @synchronized (kStatsLock) {
        return sg_sponsorBlockSkipCount;
    }
}

NSTimeInterval SGSponsorBlockTimeSaved(void) {
    ensureStatsLoaded();
    @synchronized (kStatsLock) {
        return sg_sponsorBlockTimeSaved;
    }
}

NSString *SGSponsorBlockFormattedTimeSaved(void) {
    NSInteger seconds = (NSInteger)llround(SGSponsorBlockTimeSaved());
    if (seconds <= 0) return @"0 s";
    if (seconds < 60) return [NSString stringWithFormat:@"%ld s", (long)seconds];
    NSInteger mins = seconds / 60;
    NSInteger secs = seconds % 60;
    if (mins < 60) {
        return secs > 0 ? [NSString stringWithFormat:@"%ldm %02lds", (long)mins, (long)secs]
                        : [NSString stringWithFormat:@"%ldm", (long)mins];
    }
    NSInteger hours = mins / 60;
    mins %= 60;
    if (hours < 24) {
        return mins > 0 ? [NSString stringWithFormat:@"%ldh %02ldm", (long)hours, (long)mins]
                        : [NSString stringWithFormat:@"%ldh", (long)hours];
    }
    NSInteger days = hours / 24;
    hours %= 24;
    return hours > 0 ? [NSString stringWithFormat:@"%ldd %ldh", (long)days, (long)hours]
                     : [NSString stringWithFormat:@"%ldd", (long)days];
}

void SGRecordSponsorBlockSkip(NSTimeInterval duration) {
    ensureStatsLoaded();
    @synchronized (kStatsLock) {
        sg_sponsorBlockSkipCount++;
        if (isfinite(duration) && duration > 0) sg_sponsorBlockTimeSaved += duration;
        persistStatsLocked();
    }
}

void SGUndoRecordSponsorBlockSkip(NSTimeInterval duration) {
    ensureStatsLoaded();
    @synchronized (kStatsLock) {
        if (sg_sponsorBlockSkipCount > 0) sg_sponsorBlockSkipCount--;
        if (isfinite(duration) && duration > 0) {
            sg_sponsorBlockTimeSaved = MAX(0.0, sg_sponsorBlockTimeSaved - duration);
        }
        persistStatsLocked();
    }
}

void SGResetSponsorBlockStats(void) {
    ensureStatsLoaded();
    @synchronized (kStatsLock) {
        sg_sponsorBlockSkipCount = 0;
        sg_sponsorBlockTimeSaved = 0;
        persistStatsLocked();
    }
}


static NSString *const kDefaultServerURL = @"https://sponsor.ajay.app";

static NSString *validatedServerURL(NSString *url) {
    if (!url.length) return nil;
    NSString *trimmed = [url stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    while ([trimmed hasSuffix:@"/"]) trimmed = [trimmed substringToIndex:trimmed.length - 1];
    NSURL *parsed = [NSURL URLWithString:trimmed];
    if (!parsed || ![parsed.scheme.lowercaseString isEqualToString:@"https"] || !parsed.host.length) {
        return nil;
    }
    return trimmed;
}

NSString *SGSponsorBlockServerURL(void) {
    NSString *stored = SGString(SGKeySponsorBlockServerURL);
    NSString *validated = validatedServerURL(stored);
    return validated ?: kDefaultServerURL;
}

void SGSetSponsorBlockServerURL(NSString *url) {
    NSString *validated = validatedServerURL(url);
    if (!validated || [validated.lowercaseString isEqualToString:kDefaultServerURL]) {
        [NSUserDefaults.standardUserDefaults removeObjectForKey:SGKeySponsorBlockServerURL];
    } else {
        [NSUserDefaults.standardUserDefaults setObject:validated forKey:SGKeySponsorBlockServerURL];
    }
    SGPrefsChanged();
}

@implementation SGSponsorBlockAPI

static NSString *sha256HexPrefix(NSString *input, NSUInteger length) {
    NSData *data = [input dataUsingEncoding:NSUTF8StringEncoding];
    uint8_t digest[CC_SHA256_DIGEST_LENGTH];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
#pragma clang diagnostic pop
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) {
        [hex appendFormat:@"%02x", digest[i]];
    }
    return [hex substringToIndex:MIN(length, hex.length)];
}

static NSCache<NSString *, NSArray<SGSponsorBlockSegment *> *> *segmentCache(void) {
    static NSCache *c;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        c = [NSCache new];
        c.countLimit = 100;
    });
    return c;
}

static NSURLSession *sharedSession(void) {
    static NSURLSession *session;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        config.timeoutIntervalForRequest = 8.0;
        config.timeoutIntervalForResource = 10.0;
        config.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        session = [NSURLSession sessionWithConfiguration:config];
    });
    return session;
}

static NSString *nonEmptyString(id value, NSString *fallback) {
    if ([value isKindOfClass:NSString.class] && [(NSString *)value length] > 0) {
        return (NSString *)value;
    }
    return fallback;
}

+ (void)fetchSegmentsForEpisode:(NSString *)episodeID
                     categories:(NSArray<NSString *> *)categories
                     completion:(void (^)(NSArray<SGSponsorBlockSegment *> *segments, NSError *error))completion {
    if (!episodeID.length || !categories.count) {
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(@[], nil); });
        return;
    }

    NSString *cacheKey = [NSString stringWithFormat:@"%@|%@", episodeID, [categories componentsJoinedByString:@","]];
    NSArray<SGSponsorBlockSegment *> *cached = [segmentCache() objectForKey:cacheKey];
    if (cached) {
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(cached, nil); });
        return;
    }

    NSString *prefix = sha256HexPrefix(episodeID, 4);
    NSMutableArray<NSString *> *quoted = [NSMutableArray arrayWithCapacity:categories.count];
    for (NSString *cat in categories) {
        [quoted addObject:[NSString stringWithFormat:@"\"%@\"", cat]];
    }
    NSString *catsJSON = [NSString stringWithFormat:@"[%@]", [quoted componentsJoinedByString:@","]];

    NSURLComponents *components = [NSURLComponents componentsWithString:SGSponsorBlockServerURL()];
    if (!components) components = [NSURLComponents componentsWithString:@"https://sponsor.ajay.app"];
    components.path = [NSString stringWithFormat:@"/api/skipSegments/%@", prefix];
    components.queryItems = @[
        [NSURLQueryItem queryItemWithName:@"service" value:@"Spotify"],
        [NSURLQueryItem queryItemWithName:@"categories" value:catsJSON],
    ];

    NSURL *url = components.URL;
    if (!url) {
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(@[], nil); });
        return;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url
                                                           cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                       timeoutInterval:10.0];
    request.HTTPMethod = @"GET";
    [request setValue:@"Vitrine-SponsorBlock/1" forHTTPHeaderField:@"X-CLIENT-NAME"];

    [[sharedSession() dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(@[], error); });
            return;
        }

        if (![response isKindOfClass:NSHTTPURLResponse.class]) {
            NSError *respErr = [NSError errorWithDomain:@"SGSponsorBlockAPIErrorDomain" code:-1 userInfo:nil];
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(@[], respErr); });
            return;
        }

        NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
        if (http.statusCode == 404) {
            [segmentCache() setObject:@[] forKey:cacheKey];
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(@[], nil); });
            return;
        }

        if (http.statusCode < 200 || http.statusCode >= 300 || !data.length) {
            NSError *statusErr = [NSError errorWithDomain:@"SGSponsorBlockAPIErrorDomain" code:http.statusCode userInfo:nil];
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(@[], statusErr); });
            return;
        }

        NSError *jsonErr = nil;
        id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonErr];
        if (![json isKindOfClass:NSArray.class]) {
            NSError *parseErr = jsonErr ?: [NSError errorWithDomain:@"SGSponsorBlockAPIErrorDomain" code:-2 userInfo:nil];
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(@[], parseErr); });
            return;
        }

        NSMutableArray<SGSponsorBlockSegment *> *segments = [NSMutableArray array];
        for (NSDictionary *obj in (NSArray *)json) {
            if (![obj isKindOfClass:NSDictionary.class]) continue;
            if (![nonEmptyString(obj[@"videoID"], nil) isEqualToString:episodeID]) continue;

            NSArray *segs = obj[@"segments"];
            if (![segs isKindOfClass:NSArray.class]) continue;

            for (NSDictionary *s in segs) {
                if (![s isKindOfClass:NSDictionary.class]) continue;
                NSArray *pair = s[@"segment"];
                if (![pair isKindOfClass:NSArray.class] || pair.count < 2) continue;
                if (![pair[0] respondsToSelector:@selector(doubleValue)] ||
                    ![pair[1] respondsToSelector:@selector(doubleValue)]) continue;

                double start = MAX(0.0, [pair[0] doubleValue]);
                double end = [pair[1] doubleValue];
                if (!isfinite(start) || !isfinite(end) || end <= start) continue;

                NSString *category = [[nonEmptyString(s[@"category"], @"sponsor") lowercaseString]
                    stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
                if ([category isEqualToString:@"exclusive"]) category = @"exclusive_access";
                NSString *actionType = [[nonEmptyString(s[@"actionType"], @"skip") lowercaseString]
                    stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
                NSString *uuid = nonEmptyString(s[@"UUID"], nonEmptyString(s[@"uuid"], [[NSUUID UUID] UUIDString]));

                SGSponsorBlockSegment *segment = [SGSponsorBlockSegment new];
                segment.start = start;
                segment.end = end;
                segment.category = category;
                segment.actionType = actionType;
                segment.uuid = uuid;
                [segments addObject:segment];
            }
        }

        // Sort outer/earlier segments first (start ASC, end DESC) so duplicate nested submissions
        // are subsumed cleanly by the widest enclosing segment.
        [segments sortUsingComparator:^NSComparisonResult(SGSponsorBlockSegment *a, SGSponsorBlockSegment *b) {
            if (a.start < b.start) return NSOrderedAscending;
            if (a.start > b.start) return NSOrderedDescending;
            if (a.end > b.end) return NSOrderedAscending;
            if (a.end < b.end) return NSOrderedDescending;
            return NSOrderedSame;
        }];

        NSArray<SGSponsorBlockSegment *> *immutable = [segments copy];
        [segmentCache() setObject:immutable forKey:cacheKey];
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(immutable, nil);
            });
        }
    }] resume];
}

@end
