//
//  ViewBridgeCrashGuard.h
//  Flotilla
//
//  Guards against ViewBridge framework assertions on macOS where
//  `-[NSRemoteView containingWindowWillOrderOnScreen:]` (and related methods)
//  throw an uncaught NSInternalInconsistencyException when a child window
//  or popover orders on screen (e.g. SPCompletionListServiceViewController).
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

/// Installs method swizzles on NSRemoteView to guard against ViewBridge
/// window-ordering assertion crashes. Idempotent and thread-safe.
void InstallViewBridgeCrashGuard(void);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
