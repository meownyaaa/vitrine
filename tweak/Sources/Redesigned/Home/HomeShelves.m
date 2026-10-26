// Home redesign: which shelf a shelf is. Spotify's feed names a shelf only in its heading (no id or URI reaches
// the view tree), so a shelf is known by what the heading says: "Recents", an artist's name, or the small line
// over a title ("More like" over an artist, stored as "More like …") so one switch covers that kind whoever the
// artist is today. The heading is a supplementary view of the shelf's own collection view, dequeued when the
// shelf lays out, so the shelf is laid out first, the way Native/Home/HomeDeclutter.x lays nested lists out
// before it reads them.
//
// Tree (out/sim/home/tree-before.txt, 9.1.90): TouchCancellingCollectionView > ... > SupplementaryItemView >
// UIView id=Components.UI.SectionHeadingHome > ... > NoIntrinsicContentSizeButton (a11y "More like  Chief Keef")
// > SPTEncoreLabels "More like " 11pt and "Chief Keef" 17pt, each over a UILabel id=Encore.Label-internal.
//
// The shelves seen lately are kept as identity -> date, so the settings page can list them when Home is not
// open. Threading: main thread only.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Home.h"

static const NSTimeInterval kSeenFor = 30 * 24 * 3600, kSeenWriteEvery = 3600;
static char kHeadingKey;

// The labels found last time, good while the title label is the same one with the same text: a shelf is measured
// and laid out many times a scroll, and the walk (and the layout it forces first) would run on each.
@interface SGRHomeHeadingCache : NSObject
@property (nonatomic, weak) UILabel *title, *over;
@property (nonatomic, copy) NSString *text;
@end
@implementation SGRHomeHeadingCache
@end
static char kCacheKey;

// The heading's labels: Spotify's only (the Kit's title in HomeHeadings.x has no identifier), the largest being
// the title and a smaller one above it the line over it.
static BOOL headingLabels(UIView *shelf, UILabel **title, UILabel **over) {
    if (![shelf isKindOfClass:UICollectionView.class]) return NO;
    SGRHomeHeadingCache *cache = objc_getAssociatedObject(shelf, &kCacheKey);
    UILabel *cached = cache.title;
    if (cached && cached.window && [cached.text isEqualToString:cache.text]) {
        *title = cached;
        *over = cache.over;
        return YES;
    }
    [shelf layoutIfNeeded];
    UIView *heading = SGRFindByIdentifier(shelf, @"Components.UI.SectionHeadingHome", &kHeadingKey);
    if (!heading) return NO;
    __block UIView *button = nil;
    SGForEachView(heading, ^(UIView *v) {
        if (!button && [NSStringFromClass(v.class) containsString:@"NoIntrinsicContentSizeButton"]) button = v;
    });
    if (!button) return NO;
    __block UILabel *largest = nil, *small = nil;
    SGForEachView(button, ^(UIView *v) {
        if (![v isKindOfClass:UILabel.class] || ![v.accessibilityIdentifier containsString:@"Encore.Label"]) return;
        UILabel *label = (UILabel *)v;
        if (!label.text.length || !SGShownUnder(label, button)) return;
        if (!largest || label.font.pointSize > largest.font.pointSize) {
            if (largest) small = largest;
            largest = label;
        } else if (!small || label.font.pointSize < small.font.pointSize) {
            small = label;
        }
    });
    *title = largest;
    *over = small;
    if (largest) {
        cache = [SGRHomeHeadingCache new];
        cache.title = largest;
        cache.over = small;
        cache.text = largest.text;
        objc_setAssociatedObject(shelf, &kCacheKey, cache, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return largest != nil;
}

static NSString *trimmed(UILabel *label) {
    return [label.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
}

NSString *SGRHomeShelfIdentityFrom(NSString *small, NSString *title) {
    return small.length ? [small stringByAppendingString:@" …"] : title;
}

NSString *SGRHomeShelfIdentity(UIView *shelf) {
    UILabel *title = nil, *over = nil;
    if (!headingLabels(shelf, &title, &over)) return nil;
    return SGRHomeShelfIdentityFrom(trimmed(over), trimmed(title));
}

NSString *SGRHomeShelfTitle(UIView *shelf) {
    UILabel *title = nil, *over = nil;
    return headingLabels(shelf, &title, &over) ? trimmed(title) : nil;
}

// identity -> @{first: the date it was first seen, last: the date it was last seen}.
static NSMutableDictionary<NSString *, NSDictionary<NSString *, NSDate *> *> *seen(void) {
    static NSMutableDictionary *table;
    if (!table) {
        table = [NSMutableDictionary dictionary];
        NSDictionary *stored = [NSUserDefaults.standardUserDefaults dictionaryForKey:SGRKeyHomeShelvesSeen];
        NSDate *cutoff = [NSDate dateWithTimeIntervalSinceNow:-kSeenFor];
        for (NSString *identity in stored) {
            NSDictionary *dates = stored[identity];
            if (![identity isKindOfClass:NSString.class] || ![dates isKindOfClass:NSDictionary.class]) continue;
            NSDate *first = dates[@"first"], *last = dates[@"last"];
            if ([first isKindOfClass:NSDate.class] && [last isKindOfClass:NSDate.class] && [last compare:cutoff] == NSOrderedDescending) table[identity] = dates;
        }
    }
    return table;
}

void SGRHomeNoteShelf(NSString *identity) {
    if (!identity.length) return;
    NSDictionary<NSString *, NSDate *> *dates = seen()[identity];
    // A pass of Home sees every shelf again; the store is written once an hour per shelf.
    if (dates && -dates[@"last"].timeIntervalSinceNow < kSeenWriteEvery) return;
    NSDate *now = [NSDate date];
    seen()[identity] = @{@"first": dates[@"first"] ?: now, @"last": now};
    [NSUserDefaults.standardUserDefaults setObject:seen() forKey:SGRKeyHomeShelvesSeen];
    if (!dates) SGLog(@"redesign home: shelf \"%@\" seen for the first time", identity);
}

// In the order first seen: Home's own order on the first day, a new shelf after the ones before it.
NSArray<NSString *> *SGRHomeShelvesSeen(void) {
    NSDictionary<NSString *, NSDictionary<NSString *, NSDate *> *> *table = seen();
    return [table.allKeys sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        return [table[a][@"first"] compare:table[b][@"first"]];
    }];
}

NSString *SGRHomeShelfHideKey(NSString *identity) {
    return [SGRKeyHomeShelfHidePrefix stringByAppendingString:identity];
}

BOOL SGRHomeShelfHidden(NSString *identity) {
    return identity.length > 0 && SGHidden(SGRHomeShelfHideKey(identity));
}

BOOL SGRHomeLook(void) {
    static int state = -1;
    if (state < 0) state = SGEnabled(SGRKeyHomeLook) ? 1 : 0;
    return state == 1;
}

NSString *SGRHomeTopPicksFrom(void) {
    NSString *from = SGString(SGRKeyHomeTopPicksFrom);
    return from.length ? from : nil;
}
