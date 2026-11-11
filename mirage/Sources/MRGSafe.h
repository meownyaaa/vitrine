#import <UIKit/UIKit.h>
#import <os/log.h>

// One bad settings row must never take Spotify down: every Mirage cell builder runs through this, and a builder that
// throws gets a plain "—" row instead (the exception is logged).
static inline UITableViewCell *MRGSafeCell(NSIndexPath *ip, UITableViewCell *(^build)(void)) {
    @try {
        UITableViewCell *c = build();
        if (c) return c;
    } @catch (NSException *e) {
        os_log_error(OS_LOG_DEFAULT, "[Mirage] settings row %ld.%ld threw %{public}@: %{public}@", (long)ip.section, (long)ip.row, e.name, e.reason);
    }
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    c.textLabel.text = @"—";
    c.textLabel.textColor = UIColor.grayColor;
    c.backgroundColor = UIColor.clearColor;
    c.selectionStyle = UITableViewCellSelectionStyleNone;
    return c;
}

static inline NSString *MRGSafeString(NSString *(^build)(void)) {
    @try { id s = build(); return [s isKindOfClass:NSString.class] ? s : nil; } @catch (NSException *e) { return nil; }
}

static inline NSInteger MRGSafeCount(NSInteger (^build)(void)) {
    @try { return MAX(0, build()); } @catch (NSException *e) { return 0; }
}

// Runs Mirage's own work inside a UIKit hook; an exception there is logged and dropped, never propagated into Spotify.
static inline void MRGSafeRun(const char *where, void (^work)(void)) {
    @try { work(); } @catch (NSException *e) {
        os_log_error(OS_LOG_DEFAULT, "[Mirage] %{public}s threw %{public}@: %{public}@", where, e.name, e.reason);
    }
}
