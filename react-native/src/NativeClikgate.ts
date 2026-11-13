import type { TurboModule } from 'react-native';
import type { UnsafeObject } from './codegenTypes';
import { TurboModuleRegistry } from 'react-native';

/**
 * Codegen spec of the native module `Clikgate`.
 *
 * Every method takes the contract's argument map and resolves with the contract's result map
 * (camelCase keys, JSON values). Failures reject with `code`, `message` and
 * `userInfo: {status, param}`.
 *
 * The contract's `referrals.*` method names contain a dot, which is not a valid TurboModule
 * method name, so they are exposed as `referralsApplyCode` and `referralsReferredBy`.
 * `getRequestContext` / `reportServerError` are the internal methods the Engage features
 * (src/engage) use.
 *
 * Deep links are emitted as `ClikgateDeepLink` events (`NativeEventEmitter`), hence
 * `addListener` / `removeListeners`.
 */
export interface Spec extends TurboModule {
  configure(args: UnsafeObject): Promise<void>;
  getAttribution(args: UnsafeObject): Promise<UnsafeObject>;
  identifyUser(args: UnsafeObject): Promise<void>;
  setTrackingEnabled(args: UnsafeObject): Promise<void>;
  setPushToken(args: UnsafeObject): Promise<void>;
  handleUrl(args: UnsafeObject): Promise<boolean>;
  referralsApplyCode(args: UnsafeObject): Promise<UnsafeObject>;
  referralsReferredBy(args: UnsafeObject): Promise<UnsafeObject>;
  sdkVersion(): Promise<string>;

  // v3
  isFeatureEnabled(args: UnsafeObject): Promise<boolean>;

  // Consent, Firebase forwarding, sales metadata
  setConsent(args: UnsafeObject): Promise<void>;
  getConsent(args: UnsafeObject): Promise<UnsafeObject>;
  setConsentRegion(args: UnsafeObject): Promise<void>;
  enableFirebaseForwarding(args: UnsafeObject): Promise<void>;
  attributionMetadata(args: UnsafeObject): Promise<UnsafeObject>;
  enableGoogleOnDeviceMeasurement(args: UnsafeObject): Promise<void>;

  // Resolves {status, reason, goalKind, valueIgnored}.
  goal(args: UnsafeObject): Promise<UnsafeObject>;
  // Resolves {installationId: string | null} (null when tracking is off).
  getInstallationId(args: UnsafeObject): Promise<UnsafeObject>;

  // Engage features (internal)
  getRequestContext(args: UnsafeObject): Promise<UnsafeObject>;
  reportServerError(args: UnsafeObject): Promise<void>;

  addListener(eventName: string): void;
  removeListeners(count: number): void;
}

/** `null` when the native module isn't linked (web, tests, Expo Go). */
// react-native-web has no TurboModuleRegistry: importing this on the web (including Expo Router's
// server rendering during a release build) must give null, not a crash.
export default TurboModuleRegistry == null
  ? null
  : TurboModuleRegistry.get<Spec>('Clikgate');
