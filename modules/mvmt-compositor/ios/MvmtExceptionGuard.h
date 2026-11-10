#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// A one-method bridge that lets Swift run code inside an ObjC
/// @try/@catch. Several AVFoundation APIs validate their inputs by
/// RAISING an NSException instead of returning an error, and Swift
/// cannot catch those — an uncaught one aborts the whole process.
/// Swift call sites route throw-prone AVFoundation calls through
/// `+[MvmtExceptionGuard catching:]` (see `avTry` in
/// MvmtCompositorModule.swift) so a rejection degrades gracefully
/// instead of crashing the app.
@interface MvmtExceptionGuard : NSObject

/// Executes `block` synchronously on the calling thread. Returns the
/// NSException it raised, or nil when it completed normally.
+ (nullable NSException *)catching:(void (^)(void))block;

@end

NS_ASSUME_NONNULL_END
