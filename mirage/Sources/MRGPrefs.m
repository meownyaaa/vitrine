#import "MRGPrefs.h"

NSString *const MRGSettingsChangedNotification = @"MirageSettingsChanged";

static NSUserDefaults *D(void) { return NSUserDefaults.standardUserDefaults; }
static id V(NSString *k, id def) { id v = [D() objectForKey:k]; return v ?: def; }

void MRGPostChange(void) {
    void (^post)(void) = ^{ [NSNotificationCenter.defaultCenter postNotificationName:MRGSettingsChangedNotification object:nil]; };
    if (NSThread.isMainThread) post(); else dispatch_async(dispatch_get_main_queue(), post);
}

BOOL MRGBackgroundEnabled(void) { return [V(@"mirage.bg.enabled", @YES) boolValue]; }
void MRGSetBackgroundEnabled(BOOL on) { [D() setBool:on forKey:@"mirage.bg.enabled"]; MRGPostChange(); }
double MRGBlur(void) { return MAX(0, MIN(1, [V(@"mirage.bg.blur", @0) doubleValue])); }
void MRGSetBlur(double v) { [D() setDouble:v forKey:@"mirage.bg.blur"]; MRGPostChange(); }
double MRGDim(void) { return MAX(0, MIN(0.9, [V(@"mirage.bg.dim", @0.35) doubleValue])); }
void MRGSetDim(double v) { [D() setDouble:v forKey:@"mirage.bg.dim"]; MRGPostChange(); }
MRGScaleMode MRGScale(void) { NSInteger m = [V(@"mirage.bg.scale", @0) integerValue]; return (m >= 0 && m <= 2) ? m : MRGScaleFill; }
void MRGSetScale(MRGScaleMode m) { [D() setInteger:m forKey:@"mirage.bg.scale"]; MRGPostChange(); }
MRGScreen MRGScreens(void) { return [V(@"mirage.bg.screens", @(MRGScreenHome | MRGScreenLibrary)) unsignedIntegerValue]; }
void MRGSetScreens(MRGScreen s) { [D() setObject:@(s) forKey:@"mirage.bg.screens"]; MRGPostChange(); }
BOOL MRGClearPages(void) { return [V(@"mirage.bg.clearPages", @YES) boolValue]; }
void MRGSetClearPages(BOOL on) { [D() setBool:on forKey:@"mirage.bg.clearPages"]; MRGPostChange(); }
BOOL MRGProfileGlow(void) { return [V(@"mirage.profile.glow", @YES) boolValue]; }
void MRGSetProfileGlow(BOOL on) { [D() setBool:on forKey:@"mirage.profile.glow"]; MRGPostChange(); }

BOOL MRGWantsScreen(MRGScreen s) {
    if (!MRGBackgroundEnabled() || MRGCurrentKind() == MRGMediaNone) return NO;
    MRGScreen on = MRGScreens();
    if (s == MRGScreenEverywhere) return (on & MRGScreenEverywhere) != 0;
    if (s == MRGScreenDrawer) return (on & MRGScreenDrawer) != 0;
    // "Everywhere" already puts one background behind every page, Home and Library included,
    // so their own hooks stand down rather than stack a second one. Now playing is not a page.
    if ((s == MRGScreenHome || s == MRGScreenLibrary) && (on & MRGScreenEverywhere)) return NO;
    return (on & s) != 0;
}

NSURL *MRGMediaDirectory(void) {
    NSURL *docs = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *dir = [docs URLByAppendingPathComponent:@"Mirage/Backgrounds" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

MRGMediaKind MRGCurrentKind(void) {
    NSString *name = [D() stringForKey:@"mirage.bg.file"];
    if (!name.length) return MRGMediaNone;
    if (![NSFileManager.defaultManager fileExistsAtPath:[MRGMediaDirectory() URLByAppendingPathComponent:name].path]) return MRGMediaNone;
    return [D() integerForKey:@"mirage.bg.kind"];
}

NSURL *MRGCurrentMediaURL(void) {
    if (MRGCurrentKind() == MRGMediaNone) return nil;
    return [MRGMediaDirectory() URLByAppendingPathComponent:[D() stringForKey:@"mirage.bg.file"]];
}

void MRGSetCurrentMedia(NSURL *file, MRGMediaKind kind) {
    NSString *old = [D() stringForKey:@"mirage.bg.file"];
    [D() setObject:file.lastPathComponent forKey:@"mirage.bg.file"];
    [D() setInteger:kind forKey:@"mirage.bg.kind"];
    if (old.length && ![old isEqualToString:file.lastPathComponent])
        [NSFileManager.defaultManager removeItemAtURL:[MRGMediaDirectory() URLByAppendingPathComponent:old] error:nil];
    MRGPostChange();
}

void MRGRemoveCurrentMedia(void) {
    NSString *old = [D() stringForKey:@"mirage.bg.file"];
    if (old.length) [NSFileManager.defaultManager removeItemAtURL:[MRGMediaDirectory() URLByAppendingPathComponent:old] error:nil];
    [D() removeObjectForKey:@"mirage.bg.file"];
    [D() setInteger:MRGMediaNone forKey:@"mirage.bg.kind"];
    MRGPostChange();
}
