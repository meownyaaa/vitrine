// Host check for Core/SGPrefs.m's memo: a write applies to the next read, through the accessors or straight
// to NSUserDefaults, from this thread or another, and an unset key reads as its fallback.
#import <Foundation/Foundation.h>
#import "Core/SGPrefs.h"

#define CHECK(cond) do { if (!(cond)) { fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #cond); exit(1); } } while (0)

int main(void) {
    @autoreleasepool {
        NSUserDefaults *store = NSUserDefaults.standardUserDefaults;
        NSString *flag = @"spotifyglass.test.flag", *choice = @"spotifyglass.test.int";
        for (NSString *key in @[flag, choice, SGKeyStock]) [store removeObjectForKey:key];

        CHECK(SGEnabled(flag) && !SGHidden(flag));
        CHECK(SGInt(choice, 7) == 7);
        SGSetEnabled(flag, NO);
        CHECK(!SGEnabled(flag));
        SGSetInt(choice, 3);
        CHECK(SGInt(choice, 7) == 3);

        [store setBool:YES forKey:flag];
        CHECK(SGHidden(flag));
        [store removeObjectForKey:flag];
        CHECK(SGEnabled(flag));
        [store setBool:YES forKey:SGKeyStock];
        CHECK(!SGEnabled(flag) && !SGFlag(flag, YES));
        [store removeObjectForKey:SGKeyStock];
        CHECK(SGEnabled(flag));

        dispatch_sync(dispatch_get_global_queue(0, 0), ^{ [store setInteger:9 forKey:choice]; });
        CHECK(SGInt(choice, 7) == 9);
        [store removeObjectForKey:choice];
        CHECK(SGInt(choice, 7) == 7);

        // A write posts one change notification, before it returns, on the thread that wrote. dispatch_sync would run
        // its block on this thread, so the other thread is a real one, waited for.
        NSString *counter = @"spotifyglass.test.counter";
        __block NSUInteger posts = 0;
        __block NSThread *postedOn = nil, *writer = nil;
        dispatch_semaphore_t written = dispatch_semaphore_create(0);
        void (^elsewhere)(void (^)(void)) = ^(void (^write)(void)) {
            dispatch_async(dispatch_get_global_queue(0, 0), ^{
                writer = NSThread.currentThread;
                write();
                dispatch_semaphore_signal(written);
            });
            dispatch_semaphore_wait(written, DISPATCH_TIME_FOREVER);
        };
        [NSNotificationCenter.defaultCenter addObserverForName:NSUserDefaultsDidChangeNotification object:nil queue:nil
                                                    usingBlock:^(NSNotification *note) { posts++; postedOn = NSThread.currentThread; }];
        [store setInteger:1 forKey:choice];
        CHECK(posts == 1 && postedOn == NSThread.currentThread);
        [store setObject:@{@"a": @1} forKey:counter];
        CHECK(posts == 2 && postedOn == NSThread.currentThread);
        elsewhere(^{ [store setInteger:2 forKey:choice]; });
        CHECK(posts == 3 && writer != NSThread.currentThread && postedOn == writer);
        CHECK(SGInt(choice, 7) == 2);

        // The memo itself: a write to the store that posts nothing stays unseen until the next change.
        CFPreferencesSetAppValue((__bridge CFStringRef)choice, (__bridge CFPropertyListRef)@4, kCFPreferencesCurrentApplication);
        CHECK(posts == 3 && [store integerForKey:choice] == 4 && SGInt(choice, 7) == 2);
        // A tagged write of a key the accessors never read leaves the memo in place.
        SGPrefsWriteUnmemoized(^{ [store setObject:@{@"a": @2} forKey:counter]; });
        CHECK(posts == 4 && SGInt(choice, 7) == 2);
        // The tag is this thread's: a write on another thread inside it still drops the memo.
        SGPrefsWriteUnmemoized(^{ elsewhere(^{ [store setObject:@{@"a": @3} forKey:counter]; }); });
        CHECK(posts == 5 && postedOn == writer && SGInt(choice, 7) == 4);
        // And an untagged write after the tagged one drops it too.
        CFPreferencesSetAppValue((__bridge CFStringRef)choice, (__bridge CFPropertyListRef)@5, kCFPreferencesCurrentApplication);
        CHECK(SGInt(choice, 7) == 4);
        [store setObject:@{@"a": @4} forKey:counter];
        CHECK(posts == 6 && SGInt(choice, 7) == 5);

        // SGString answers as -stringForKey: does, through the memo.
        NSString *text = @"spotifyglass.test.text";
        CHECK(SGString(text) == nil);
        [store setObject:@"Recents" forKey:text];
        CHECK([SGString(text) isEqualToString:@"Recents"] && SGString(text) == SGString(text));
        [store setInteger:12 forKey:text];
        CHECK([SGString(text) isEqualToString:@"12"]);
        [store setObject:@[@"a"] forKey:text];
        CHECK(SGString(text) == nil);

        // SGArray answers as -arrayForKey: does, through the memo, and a writer's SGPrefsChanged() shows the write.
        CHECK([SGArray(text) isEqualToArray:@[@"a"]] && SGArray(text) == SGArray(text));
        [store setObject:@"Recents" forKey:text];
        CHECK(SGArray(text) == nil);
        CFPreferencesSetAppValue((__bridge CFStringRef)text, (__bridge CFPropertyListRef)@[@"b"], kCFPreferencesCurrentApplication);
        CHECK(SGArray(text) == nil);
        SGPrefsChanged();
        CHECK([SGArray(text) isEqualToArray:@[@"b"]]);

        for (NSString *key in @[flag, choice, counter, text]) [store removeObjectForKey:key];
        puts("prefs: ok");
    }
    return 0;
}
