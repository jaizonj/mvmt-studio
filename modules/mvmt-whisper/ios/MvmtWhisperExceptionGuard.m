#import "MvmtWhisperExceptionGuard.h"

@implementation MvmtWhisperExceptionGuard

+ (NSException *)catching:(void (^)(void))block {
  @try {
    block();
    return nil;
  } @catch (NSException *exception) {
    return exception;
  }
}

@end
