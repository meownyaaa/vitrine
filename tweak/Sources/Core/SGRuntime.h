// Private UIKit the SDK does not declare.
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

// Core Animation's private CAFilter of `type` (gaussianBlur, colorMatrix, colorInvert...), for a layer's filters or
// a backdrop's. Nil where the class or its maker is gone.
static inline id SGFilterOfType(NSString *type) {
    Class filterClass = NSClassFromString(@"CAFilter");
    SEL make = NSSelectorFromString(@"filterWithType:");
    if (![filterClass respondsToSelector:make]) return nil;
    return ((id (*)(Class, SEL, NSString *))objc_msgSend)(filterClass, make, type);
}

@interface UIView (SGPrivate)
- (NSString *)recursiveDescription;
@end

@interface UIViewController (SGPrivate)
- (NSString *)_printHierarchy;
@end
