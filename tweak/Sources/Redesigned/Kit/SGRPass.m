#import "SGRPass.h"
#import "Core/SGCore.h"
#import "SGRRestyle.h"
#import <objc/runtime.h>

void SGRRepeatPass(UIViewController *controller, NSArray<NSNumber *> *delays, SGRControllerPass pass) {
    __weak UIViewController *weak = controller;
    for (NSNumber *delay in delays) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            UIViewController *strong = weak;
            if (strong) pass(strong);
        });
    }
}

void SGRRepeatViewPass(UIView *view, NSArray<NSNumber *> *delays, void (^pass)(UIView *view)) {
    __weak UIView *weak = view;
    for (NSNumber *delay in delays) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            UIView *strong = weak;
            if (strong.window) pass(strong);
        });
    }
}

// `cls`'s own `sel` made `replacement`. Returns what it replaced, or NULL when `cls` only inherited `sel`: the
// replacement then calls its superclass's, looked up as it runs, as Logos does.
static IMP replace(Class cls, SEL sel, IMP replacement) {
    Method own = class_getInstanceMethod(cls, sel);
    Method inherited = class_getInstanceMethod(class_getSuperclass(cls), sel);
    if (own && own != inherited) return method_setImplementation(own, replacement);
    class_addMethod(cls, sel, replacement, method_getTypeEncoding(inherited));
    return NULL;
}

static IMP original(Class cls, SEL sel, IMP replaced) {
    return replaced ?: class_getMethodImplementation(class_getSuperclass(cls), sel);
}

void SGRPassController(Class cls, SGRControllerPass pass) {
    if (!cls || !pass) return;
    pass = [pass copy];
    SEL layout = @selector(viewDidLayoutSubviews), willAppear = @selector(viewWillAppear:), didAppear = @selector(viewDidAppear:);
    __block IMP laidOut = NULL, appearing = NULL, appeared = NULL;
    laidOut = replace(cls, layout, imp_implementationWithBlock(^(UIViewController *controller) {
        ((void (*)(id, SEL))original(cls, layout, laidOut))(controller, layout);
        pass(controller);
    }));
    appearing = replace(cls, willAppear, imp_implementationWithBlock(^(UIViewController *controller, BOOL animated) {
        ((void (*)(id, SEL, BOOL))original(cls, willAppear, appearing))(controller, willAppear, animated);
        pass(controller);
    }));
    appeared = replace(cls, didAppear, imp_implementationWithBlock(^(UIViewController *controller, BOOL animated) {
        ((void (*)(id, SEL, BOOL))original(cls, didAppear, appeared))(controller, didAppear, animated);
        pass(controller);
        SGRRepeatPass(controller, SGRSettleDelays, pass);
    }));
}

void SGRPassControllerGoing(Class cls, SGRControllerPass going) {
    if (!cls || !going) return;
    going = [going copy];
    SEL willDisappear = @selector(viewWillDisappear:);
    __block IMP leaving = NULL;
    leaving = replace(cls, willDisappear, imp_implementationWithBlock(^(UIViewController *controller, BOOL animated) {
        ((void (*)(id, SEL, BOOL))original(cls, willDisappear, leaving))(controller, willDisappear, animated);
        going(controller);
    }));
}

void SGRPassView(Class cls, void (^pass)(UIView *view)) {
    if (!cls || !pass) return;
    pass = [pass copy];
    SEL layout = @selector(layoutSubviews), moved = @selector(didMoveToWindow);
    __block IMP laidOut = NULL, inWindow = NULL;
    laidOut = replace(cls, layout, imp_implementationWithBlock(^(UIView *view) {
        ((void (*)(id, SEL))original(cls, layout, laidOut))(view, layout);
        pass(view);
    }));
    inWindow = replace(cls, moved, imp_implementationWithBlock(^(UIView *view) {
        ((void (*)(id, SEL))original(cls, moved, inWindow))(view, moved);
        pass(view);
    }));
}

void SGRPassControllersNamed(NSArray<NSString *> *names, SGRControllerPass pass) {
    for (NSString *name in names) SGRPassController(NSClassFromString(name), pass);
    SGRequireClasses(names);
}

void SGRPassSwiftController(NSString *module, NSString *name, SGRControllerPass pass) {
    Class cls = SGRSwiftClass(module, name);
    if (cls) SGRPassController(cls, pass);
    else SGLog(@"class %@.%@ not found, its passes are inactive", module, name);
}

#pragma mark - following a scroll

@interface SGROffsetFollower : NSObject
@property (nonatomic, weak) UIScrollView *scroll;
@property (nonatomic, copy) void (^follow)(UIScrollView *scroll);
@end

@implementation SGROffsetFollower
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    UIScrollView *scroll = self.scroll;
    if (scroll) self.follow(scroll);
}
@end

void SGRFollowOffset(UIScrollView *scroll, const void *key, void (^follow)(UIScrollView *scroll)) {
    if (!scroll || !key || !follow || objc_getAssociatedObject(scroll, key)) return;
    SGROffsetFollower *follower = [SGROffsetFollower new];
    follower.scroll = scroll;
    follower.follow = follow;
    [scroll addObserver:follower forKeyPath:@"contentOffset" options:0 context:NULL];
    objc_setAssociatedObject(scroll, key, follower, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
