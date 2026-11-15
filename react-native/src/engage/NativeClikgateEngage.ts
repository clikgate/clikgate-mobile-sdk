import type { TurboModule } from 'react-native';
import type { UnsafeObject } from '../codegenTypes';
import { TurboModuleRegistry } from 'react-native';

/**
 * Codegen spec of the native module `ClikgateEngage`: only `shareLink`, the share menu of
 * `share.link()` / `share.referralLink()`, over the native Engage features (Android
 * com.clikgate:clikgate-engage, iOS Clikgate/Engage). Everything else in this package is
 * TypeScript. Resolves `true` when the app itself opened; rejects with `code` and `message`.
 */
export interface Spec extends TurboModule {
  shareLink(args: UnsafeObject): Promise<boolean>;
  /**
   * The referral link the native SDK saved for the signed-in customer
   * (`{link: JSON string | null, token: string | null}`); the first call also starts preparing links
   * after each `identifyUser()`.
   */
  savedLink(programId: string): Promise<UnsafeObject>;
  /** Saves a link answer (JSON string) unless another customer signed in since `token` was read. */
  saveLink(programId: string, link: string, token: string): Promise<void>;
}

// react-native-web has no TurboModuleRegistry: importing this on the web (including Expo Router's
// server rendering during a release build) must give null, not a crash.
export default TurboModuleRegistry == null
  ? null
  : TurboModuleRegistry.get<Spec>('ClikgateEngage');
