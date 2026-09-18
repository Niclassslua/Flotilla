//
//  ViewBridgeCrashGuard.m
//  Flotilla
//
//  Guards against ViewBridge framework assertions on macOS where
//  `-[NSRemoteView containingWindowWillOrderOnScreen:]` (and related methods)
//  throw an uncaught NSInternalInconsistencyException when a child window
//  or popover orders on screen (e.g. SPCompletionListServiceViewController).
//

#import "ViewBridgeCrashGuard.h"
#import <Cocoa/Cocoa.h>
#import <objc/runtime.h>
#import <os/log.h>

static os_log_t crash_guard_log(void) {
    static os_log_t log;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        log = os_log_create("com.niclassslua.flotilla", "ViewBridgeCrashGuard");
    });
    return log;
}

typedef void (*WindowNotificationIMP)(id, SEL, id);

static WindowNotificationIMP sOriginalWillOrderOnScreen = NULL;
static WindowNotificationIMP sOriginalDidOrderOnScreen = NULL;
static WindowNotificationIMP sOriginalWillOrderOffScreen = NULL;
static WindowNotificationIMP sOriginalDidOrderOffScreen = NULL;
static WindowNotificationIMP sOriginalDidMove = NULL;
static WindowNotificationIMP sOriginalDidChangeOcclusionState = NULL;

static BOOL ShouldProcessNotification(NSView *view, id note) {
    if (![note isKindOfClass:[NSNotification class]]) {
        return YES;
    }
    NSNotification *notification = (NSNotification *)note;
    id notificationWindow = notification.object;
    if (notificationWindow != nil && [notificationWindow isKindOfClass:[NSWindow class]]) {
        NSWindow *containingWindow = [view window];
        if (containingWindow != notificationWindow) {
            // Notification is for a different window (e.g. _NSPopoverWindow, sheet, child window).
            // NSRemoteView's internal assertion asserts notification.object == containingWindow.
            // When mismatched, it throws NSInternalInconsistencyException:
            // "notified of <_NSPopoverWindow:...> but expected (null)".
            // Safely ignore foreign window notifications.
            return NO;
        }
    }
    return YES;
}

static void Swizzled_containingWindowWillOrderOnScreen(id self, SEL _cmd, id note) {
    if (!ShouldProcessNotification((NSView *)self, note)) {
        return;
    }
    @try {
        if (sOriginalWillOrderOnScreen) {
            sOriginalWillOrderOnScreen(self, _cmd, note);
        }
    } @catch (NSException *exception) {
        os_log_error(crash_guard_log(), "Suppressed ViewBridge exception in containingWindowWillOrderOnScreen: %@ (%@)", exception.name, exception.reason);
    }
}

static void Swizzled_containingWindowDidOrderOnScreen(id self, SEL _cmd, id note) {
    if (!ShouldProcessNotification((NSView *)self, note)) {
        return;
    }
    @try {
        if (sOriginalDidOrderOnScreen) {
            sOriginalDidOrderOnScreen(self, _cmd, note);
        }
    } @catch (NSException *exception) {
        os_log_error(crash_guard_log(), "Suppressed ViewBridge exception in containingWindowDidOrderOnScreen: %@ (%@)", exception.name, exception.reason);
    }
}

static void Swizzled_containingWindowWillOrderOffScreen(id self, SEL _cmd, id note) {
    if (!ShouldProcessNotification((NSView *)self, note)) {
        return;
    }
    @try {
        if (sOriginalWillOrderOffScreen) {
            sOriginalWillOrderOffScreen(self, _cmd, note);
        }
    } @catch (NSException *exception) {
        os_log_error(crash_guard_log(), "Suppressed ViewBridge exception in containingWindowWillOrderOffScreen: %@ (%@)", exception.name, exception.reason);
    }
}

static void Swizzled_containingWindowDidOrderOffScreen(id self, SEL _cmd, id note) {
    if (!ShouldProcessNotification((NSView *)self, note)) {
        return;
    }
    @try {
        if (sOriginalDidOrderOffScreen) {
            sOriginalDidOrderOffScreen(self, _cmd, note);
        }
    } @catch (NSException *exception) {
        os_log_error(crash_guard_log(), "Suppressed ViewBridge exception in containingWindowDidOrderOffScreen: %@ (%@)", exception.name, exception.reason);
    }
}

static void Swizzled_containingWindowDidMove(id self, SEL _cmd, id note) {
    if (!ShouldProcessNotification((NSView *)self, note)) {
        return;
    }
    @try {
        if (sOriginalDidMove) {
            sOriginalDidMove(self, _cmd, note);
        }
    } @catch (NSException *exception) {
        os_log_error(crash_guard_log(), "Suppressed ViewBridge exception in containingWindowDidMove: %@ (%@)", exception.name, exception.reason);
    }
}

static void Swizzled_containingWindowDidChangeOcclusionState(id self, SEL _cmd, id note) {
    if (!ShouldProcessNotification((NSView *)self, note)) {
        return;
    }
    @try {
        if (sOriginalDidChangeOcclusionState) {
            sOriginalDidChangeOcclusionState(self, _cmd, note);
        }
    } @catch (NSException *exception) {
        os_log_error(crash_guard_log(), "Suppressed ViewBridge exception in containingWindowDidChangeOcclusionState: %@ (%@)", exception.name, exception.reason);
    }
}

static void SwizzleMethod(Class cls, SEL sel, IMP newImp, WindowNotificationIMP *origImp) {
    Method method = class_getInstanceMethod(cls, sel);
    if (!method) {
        return;
    }
    *origImp = (WindowNotificationIMP)method_getImplementation(method);
    method_setImplementation(method, newImp);
}

void InstallViewBridgeCrashGuard(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSBundle *bundle = [NSBundle bundleWithPath:@"/System/Library/PrivateFrameworks/ViewBridge.framework"];
        [bundle load];

        Class remoteViewClass = NSClassFromString(@"NSRemoteView");
        if (!remoteViewClass) {
            os_log_info(crash_guard_log(), "NSRemoteView class not found; skipping ViewBridge crash guard installation");
            return;
        }

        SwizzleMethod(remoteViewClass, sel_registerName("containingWindowWillOrderOnScreen:"), (IMP)Swizzled_containingWindowWillOrderOnScreen, &sOriginalWillOrderOnScreen);
        SwizzleMethod(remoteViewClass, sel_registerName("containingWindowDidOrderOnScreen:"), (IMP)Swizzled_containingWindowDidOrderOnScreen, &sOriginalDidOrderOnScreen);
        SwizzleMethod(remoteViewClass, sel_registerName("containingWindowWillOrderOffScreen:"), (IMP)Swizzled_containingWindowWillOrderOffScreen, &sOriginalWillOrderOffScreen);
        SwizzleMethod(remoteViewClass, sel_registerName("containingWindowDidOrderOffScreen:"), (IMP)Swizzled_containingWindowDidOrderOffScreen, &sOriginalDidOrderOffScreen);
        SwizzleMethod(remoteViewClass, sel_registerName("containingWindowDidMove:"), (IMP)Swizzled_containingWindowDidMove, &sOriginalDidMove);
        SwizzleMethod(remoteViewClass, sel_registerName("containingWindowDidChangeOcclusionState:"), (IMP)Swizzled_containingWindowDidChangeOcclusionState, &sOriginalDidChangeOcclusionState);

        os_log_info(crash_guard_log(), "Installed ViewBridge NSRemoteView window ordering crash guards");
    });
}

__attribute__((constructor))
static void ViewBridgeCrashGuardAutoInit(void) {
    InstallViewBridgeCrashGuard();
}
