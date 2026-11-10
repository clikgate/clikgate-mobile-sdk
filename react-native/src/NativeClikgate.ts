import type { CodegenTypes, TurboModule } from 'react-native';
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
 * `getRequestContext` / `reportServerError` are the internal methods the Engage add-on
 * (`@clikgate/react-native-engage`) uses.
 *
 * Deep links are emitted as `ClikgateDeepLink` events (`NativeEventEmitter`), hence
 * `addListener` / `removeListeners`.
 */
export interface Spec extends TurboModule {
  configure(args: CodegenTypes.UnsafeObject): Promise<void>;
  getAttribution(
    args: CodegenTypes.UnsafeObject
  ): Promise<CodegenTypes.UnsafeObject>;
  identifyUser(args: CodegenTypes.UnsafeObject): Promise<void>;
  setTrackingEnabled(args: CodegenTypes.UnsafeObject): Promise<void>;
  setPushToken(args: CodegenTypes.UnsafeObject): Promise<void>;
  handleUrl(args: CodegenTypes.UnsafeObject): Promise<boolean>;
  referralsApplyCode(
    args: CodegenTypes.UnsafeObject
  ): Promise<CodegenTypes.UnsafeObject>;
  referralsReferredBy(
    args: CodegenTypes.UnsafeObject
  ): Promise<CodegenTypes.UnsafeObject>;
  sdkVersion(): Promise<string>;

  // v3
  isFeatureEnabled(args: CodegenTypes.UnsafeObject): Promise<boolean>;

  // Consent, Firebase forwarding, sales metadata
  setConsent(args: CodegenTypes.UnsafeObject): Promise<void>;
  getConsent(
    args: CodegenTypes.UnsafeObject
  ): Promise<CodegenTypes.UnsafeObject>;
  setConsentRegion(args: CodegenTypes.UnsafeObject): Promise<void>;
  enableFirebaseForwarding(args: CodegenTypes.UnsafeObject): Promise<void>;
  attributionMetadata(
    args: CodegenTypes.UnsafeObject
  ): Promise<CodegenTypes.UnsafeObject>;
  enableGoogleOnDeviceMeasurement(
    args: CodegenTypes.UnsafeObject
  ): Promise<void>;

  // Resolves {status, reason, goalKind, valueIgnored}.
  goal(args: CodegenTypes.UnsafeObject): Promise<CodegenTypes.UnsafeObject>;
  // Resolves {installationId: string | null} (null when tracking is off).
  getInstallationId(
    args: CodegenTypes.UnsafeObject
  ): Promise<CodegenTypes.UnsafeObject>;

  // Engage add-on (internal)
  getRequestContext(
    args: CodegenTypes.UnsafeObject
  ): Promise<CodegenTypes.UnsafeObject>;
  reportServerError(args: CodegenTypes.UnsafeObject): Promise<void>;

  addListener(eventName: string): void;
  removeListeners(count: number): void;
}

/** `null` when the native module isn't linked (web, tests, Expo Go). */
// react-native-web has no TurboModuleRegistry: importing this on the web (including Expo Router's
// server rendering during a release build) must give null, not a crash.
export default TurboModuleRegistry == null
  ? null
  : TurboModuleRegistry.get<Spec>('Clikgate');
