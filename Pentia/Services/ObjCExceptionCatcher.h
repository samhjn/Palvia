#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ObjCExceptionCatcher : NSObject

/// Runs `block`. Returns the raised NSException, or nil if none was raised.
/// Swift's `try?`/`do-catch` only catches `Swift.Error`; NSExceptions raised
/// from Objective-C code (e.g. Core Data validation, fault realization) bypass
/// Swift's error handling and abort the process. Use this bridge at the
/// narrowest possible call sites that cross into ObjC frameworks.
+ (nullable NSException *)tryBlock:(NS_NOESCAPE void (^)(void))block
    NS_SWIFT_NAME(catching(_:));

@end

NS_ASSUME_NONNULL_END
