#import "MvmtExceptionGuard.h"

@implementation MvmtExceptionGuard

+ (NSException *)catching:(void (^)(void))block {
  @try {
    block();
    return nil;
  } @catch (NSException *exception) {
    return exception;
  }
}

@end
