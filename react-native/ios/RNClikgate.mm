#import "RNClikgate.h"

#if __has_include(<ClikgateReactNative/ClikgateReactNative-Swift.h>)
#import <ClikgateReactNative/ClikgateReactNative-Swift.h>
#else
#import "ClikgateReactNative-Swift.h"
#endif

static NSString *const kDeepLinkEvent = @"ClikgateDeepLink";

@implementation RNClikgate {
  ClikgateRNImpl *_impl;
}

+ (NSString *)moduleName
{
  return @"Clikgate";
}

+ (BOOL)requiresMainQueueSetup
{
  return NO;
}

/// Links an app forwards to RCTLinkingManager (React Native's Linking API; the Expo AppDelegate
/// does this) are posted as RCTOpenURLNotification. Observe from process start so cold-start
/// links are not missed while the module doesn't exist yet. Duplicates are dropped in ClikgateRN.
+ (void)load
{
  [[NSNotificationCenter defaultCenter] addObserverForName:@"RCTOpenURLNotification"
                                                    object:nil
                                                     queue:[NSOperationQueue mainQueue]
                                                usingBlock:^(NSNotification *note) {
                                                  id url = note.userInfo[@"url"];
                                                  if ([url isKindOfClass:[NSString class]]) {
                                                    [ClikgateRN handleLinkingNotificationURL:url];
                                                  }
                                                }];
}

- (instancetype)init
{
  if (self = [super init]) {
    _impl = [ClikgateRNImpl new];
    __weak RNClikgate *weakSelf = self;
    _impl.emitter = ^(NSDictionary<NSString *, id> *event) {
      [weakSelf sendEventWithName:kDeepLinkEvent body:event];
    };
  }
  return self;
}

- (void)invalidate
{
  [_impl invalidate];
  [super invalidate];
}

- (NSArray<NSString *> *)supportedEvents
{
  return @[ kDeepLinkEvent ];
}

- (void)startObserving
{
  [_impl setHasListeners:YES];
}

- (void)stopObserving
{
  [_impl setHasListeners:NO];
}

// `addListener:` / `removeListeners:` come from RCTEventEmitter (listener counting drives
// startObserving / stopObserving).

static void (^rejecter(RCTPromiseRejectBlock reject))(NSString *, NSString *, NSDictionary<NSString *, id> *)
{
  return ^(NSString *code, NSString *message, NSDictionary<NSString *, id> *userInfo) {
    NSNumber *status = [userInfo[@"status"] isKindOfClass:[NSNumber class]] ? userInfo[@"status"] : nil;
    NSError *error = [NSError errorWithDomain:@"com.clikgate.sdk"
                                         code:status != nil ? status.integerValue : -1
                                     userInfo:userInfo];
    reject(code, message, error);
  };
}

- (void)configure:(NSDictionary *)args resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [_impl configure:args resolve:resolve reject:rejecter(reject)];
}

- (void)getAttribution:(NSDictionary *)args resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [_impl getAttribution:args resolve:resolve reject:rejecter(reject)];
}

- (void)getInstallationId:(NSDictionary *)args resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [_impl getInstallationId:args resolve:resolve reject:rejecter(reject)];
}

- (void)identifyUser:(NSDictionary *)args resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [_impl identifyUser:args resolve:resolve reject:rejecter(reject)];
}

- (void)setTrackingEnabled:(NSDictionary *)args resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [_impl setTrackingEnabled:args resolve:resolve reject:rejecter(reject)];
}

- (void)setPushToken:(NSDictionary *)args resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [_impl setPushToken:args resolve:resolve reject:rejecter(reject)];
}

- (void)handleUrl:(NSDictionary *)args resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [_impl handleUrl:args resolve:resolve reject:rejecter(reject)];
}

- (void)referralsApplyCode:(NSDictionary *)args resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [_impl referralsApplyCode:args resolve:resolve reject:rejecter(reject)];
}

- (void)referralsReferredBy:(NSDictionary *)args resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [_impl referralsReferredBy:args resolve:resolve reject:rejecter(reject)];
}

// v3

- (void)isFeatureEnabled:(NSDictionary *)args resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [_impl isFeatureEnabled:args resolve:resolve reject:rejecter(reject)];
}

- (void)getRequestContext:(NSDictionary *)args resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [_impl getRequestContext:args resolve:resolve reject:rejecter(reject)];
}

- (void)reportServerError:(NSDictionary *)args resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [_impl reportServerError:args resolve:resolve reject:rejecter(reject)];
}

- (void)goal:(NSDictionary *)args resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [_impl goal:args resolve:resolve reject:rejecter(reject)];
}

// Consent, Firebase forwarding, sales metadata
- (void)setConsent:(NSDictionary *)args resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [_impl setConsent:args resolve:resolve reject:rejecter(reject)];
}

- (void)getConsent:(NSDictionary *)args resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [_impl getConsent:args resolve:resolve reject:rejecter(reject)];
}

- (void)setConsentRegion:(NSDictionary *)args resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [_impl setConsentRegion:args resolve:resolve reject:rejecter(reject)];
}

- (void)enableFirebaseForwarding:(NSDictionary *)args resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [_impl enableFirebaseForwarding:args resolve:resolve reject:rejecter(reject)];
}

- (void)attributionMetadata:(NSDictionary *)args resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [_impl attributionMetadata:args resolve:resolve reject:rejecter(reject)];
}

- (void)enableGoogleOnDeviceMeasurement:(NSDictionary *)args resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [_impl enableGoogleOnDeviceMeasurement:args resolve:resolve reject:rejecter(reject)];
}

- (void)sdkVersion:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [_impl sdkVersion:resolve];
}

- (std::shared_ptr<facebook::react::TurboModule>)getTurboModule:
    (const facebook::react::ObjCTurboModule::InitParams &)params
{
  return std::make_shared<facebook::react::NativeClikgateSpecJSI>(params);
}

@end
