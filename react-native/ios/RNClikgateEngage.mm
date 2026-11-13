#import "RNClikgateEngage.h"

#if __has_include(<ClikgateReactNative/ClikgateReactNative-Swift.h>)
#import <ClikgateReactNative/ClikgateReactNative-Swift.h>
#else
#import "ClikgateReactNative-Swift.h"
#endif

@implementation RNClikgateEngage

+ (NSString *)moduleName
{
  return @"ClikgateEngage";
}

+ (BOOL)requiresMainQueueSetup
{
  return NO;
}

- (void)shareLink:(NSDictionary *)args resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [ClikgateEngageRN shareLink:args resolve:^(BOOL opened) {
    resolve(@(opened));
  } reject:^(NSString *code, NSString *message) {
    reject(code, message, nil);
  }];
}

- (std::shared_ptr<facebook::react::TurboModule>)getTurboModule:
    (const facebook::react::ObjCTurboModule::InitParams &)params
{
  return std::make_shared<facebook::react::NativeClikgateEngageSpecJSI>(params);
}

@end
