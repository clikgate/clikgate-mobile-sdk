/**
 * Clikgate for React Native: deep links, install attribution, events, referee-side referral calls
 * and uninstall tracking over the native Clikgate Android and iOS SDKs, plus (since 2.1.0) the
 * Engage features for apps without their own backend (`ClikgateEngage`: referral links and stats,
 * leaderboards, promo codes, share helpers; see ./engage).
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
export { GoalKind, GoalStatus } from './models';
export {
  CLIKGATE_PROVIDERS,
  ClikgateProvider,
  providerFromString,
} from './provider';
export { VERSION } from './version';
// Engage features (was @clikgate/react-native-engage). Core code never imports ./engage.
export * from './engage';
export default Clikgate;
