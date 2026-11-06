/**
 * Clikgate for React Native (core): deep links, install attribution, events, referee-side
 * referral calls and uninstall tracking over the native Clikgate Android and iOS SDKs.
 * Referrer-side features live in `@clikgate/react-native-engage`.
 */
import { Clikgate } from './Clikgate';

export { Clikgate };
export { ClikgateError, type ClikgateErrorCode } from './errors';
export { isClikgateMessage } from './isClikgateMessage';
export { referrals, type ClikgateReferrals } from './referrals';
export type { BrowserHandoffListener, DeepLinkListener } from './deepLinkHub';
export type {
  ClikgateAttestation,
  ClikgateAttribution,
  ClikgateBrowserHandoff,
  ClikgateAttributionStatus,
  ClikgateConfig,
  ClikgateConsent,
  ClikgateConsentUpdate,
  ClikgateDeepLink,
  ClikgateEnvironment,
  ClikgateFeature,
  ClikgateFirebaseForwardingOptions,
  ClikgateLink,
  ClikgateLogLevel,
  ClikgatePasteboardMode,
  ClikgateRequestContext,
  ConsentState,
  GoalOptions,
  IdentifyUserOptions,
  GoalResult,
  JsonMap,
  PushProvider,
  Referral,
  ReferredBy,
} from './models';
export { ClikgateMoney, GoalKind, GoalStatus } from './models';
export {
  CLIKGATE_PROVIDERS,
  ClikgateProvider,
  providerFromString,
} from './provider';
export { VERSION } from './version';
export default Clikgate;
