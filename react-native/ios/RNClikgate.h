#import <React/RCTEventEmitter.h>
#import <RNClikgateSpec/RNClikgateSpec.h>

NS_ASSUME_NONNULL_BEGIN

/// The `Clikgate` TurboModule (New Architecture). The implementation lives in Swift
/// (ClikgateRNImpl); this class adapts it to the codegen spec and emits `ClikgateDeepLink`.
@interface RNClikgate : RCTEventEmitter <NativeClikgateSpec>
@end

NS_ASSUME_NONNULL_END
