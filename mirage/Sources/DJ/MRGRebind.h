// See MRGRebind.m. Returns YES when at least one slot named `symbol` (without the leading underscore) was
// repointed; `original` receives what the first slot held. Call from a %ctor.
#import <Foundation/Foundation.h>
BOOL MRGRebindImport(const char *symbol, void *replacement, void **original);
