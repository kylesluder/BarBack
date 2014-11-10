// The MIT License (MIT)
//
// Copyright (c) 2014 Kyle Sluder
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

#import "BBBarBackPlugin.h"

#import <objc/runtime.h>

typedef NS_ENUM(NSInteger, NSWindowTitleVisibility) {
    NSWindowTitleVisible  = 0,
    NSWindowTitleHidden = 1,
};

@interface NSWindow : NSObject
@property NSWindowTitleVisibility titleVisibility;
@end

@interface IDEWorkspaceWindowController : NSObject
- (void)windowDidLoad;
- (NSWindow *)window;
@end

@interface IDERunPauseContinueToolbarButton : NSObject
- (NSWindow *)window;
- (void)viewWillMoveToWindow:(NSWindow *)window;
@end

@implementation BBBarBackPlugin

static NSMutableArray *swizzleUndoers;

+ (void)_BarBack_registerSwizzleUndoer:(void (^)(void))undoer;
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        swizzleUndoers = [[NSMutableArray alloc] init];
    });
    
    [swizzleUndoers addObject:undoer];
}

+ (void)_BarBack_undoSwizzling;
{
    for (void (^undoer)(void) in swizzleUndoers)
        undoer();
    
    [swizzleUndoers removeAllObjects];
}

static NSString *BBCouldntSwizzleMethodException = @"com.ksluder.BarBack.BBCouldntSwizzleMethodException";

+ (void)_BarBack_swizzleMethodNamed:(SEL)methodName ofClassNamed:(NSString *)className withImplementationFactory:(IMP (^)(IMP originalImplementation))impFactory;
{
    Class targetClass = NSClassFromString(className);
    if (!targetClass) {
        @throw [NSException exceptionWithName:BBCouldntSwizzleMethodException reason:[NSString stringWithFormat:@"Class '%@' not found; can't swizzle method '%@'", className, NSStringFromSelector(methodName)] userInfo:nil];
    }
    
    BOOL isClassMethod = class_isMetaClass(targetClass);
    
    Method originalMethod = class_getInstanceMethod(targetClass, methodName);
    if (!originalMethod) {
        @throw [NSException exceptionWithName:BBCouldntSwizzleMethodException reason:[NSString stringWithFormat:@"Method '%c%@' not found on class '%@'", isClassMethod ? '+' : '-', NSStringFromSelector(methodName), className] userInfo:nil];
    }
    
    IMP originalImp = method_getImplementation(originalMethod);
    IMP replacementImp = impFactory(originalImp);
    
    if (!replacementImp) {
        @throw [NSException exceptionWithName:BBCouldntSwizzleMethodException reason:[NSString stringWithFormat:@"No replacement implementation provided for method '%c%@ %@'", isClassMethod ? '+' : '-', className, NSStringFromSelector(methodName)] userInfo:nil];
    }
    
    method_setImplementation(originalMethod, replacementImp);
    
    [self _BarBack_registerSwizzleUndoer:^{
        method_setImplementation(originalMethod, originalImp);
    }];
}

+ (void)pluginDidLoad:(NSBundle *)bundle;
{
    @try {
        [self _BarBack_swizzleMethodNamed:@selector(windowDidLoad) ofClassNamed:@"IDEWorkspaceWindowController" withImplementationFactory:^IMP(IMP originalImplementation) {
            void (*originalWindowDidLoad)(__unsafe_unretained id, SEL) = (typeof(originalWindowDidLoad))originalImplementation;
            return imp_implementationWithBlock(^(__unsafe_unretained IDEWorkspaceWindowController *wc){
                originalWindowDidLoad(wc, @selector(windowDidLoad));
                wc.window.titleVisibility = NSWindowTitleVisible;
            });
        }];
        
        [self _BarBack_swizzleMethodNamed:@selector(viewWillMoveToWindow:) ofClassNamed:@"IDERunPauseContinueToolbarButton" withImplementationFactory:^IMP(IMP originalImplementation) {
            void (*originalViewWillMoveToWindow)(__unsafe_unretained id, SEL, NSWindow *) = (typeof(originalViewWillMoveToWindow))originalImplementation;
            return imp_implementationWithBlock(^(__unsafe_unretained IDERunPauseContinueToolbarButton *button, NSWindow *newWindow){
                // If the title bar is visible, adding the debugger bar to the window (because the user choose the Run command) causes toolbar buttons to get reparented to a new view in the same window.
                // This apparently exposes a bug somewhere in IDERunPauseContinueToolbarButton. -_buttonIsMovingToWindowController: unregisters some KVO observers, then reregisters them on objects derived from the new window's window controller. Perhaps it's double-unregistering?
                // Either way, the work it's doing is unnecessary when moving to a new parent view within the same window, so we can just squelch it here.
                if (!newWindow || [button window] != newWindow)
                    originalViewWillMoveToWindow(button, @selector(viewWillMoveToWindow:), newWindow);
            });
        }];
        
        NSLog(@"BarBack: Swizzled %lu methods", (unsigned long)[swizzleUndoers count]);
        
    } @catch(NSException *e) {
        [self _BarBack_undoSwizzling];
        
        NSLog(@"BarBack: installation FAILED! %@", [e description]);
        
        if (!([[e name] isEqualToString:BBCouldntSwizzleMethodException]))
            @throw;
    }
}

@end
