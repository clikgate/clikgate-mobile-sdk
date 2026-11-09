import type { CodegenTypes, TurboModule } from 'react-native';
import { TurboModuleRegistry } from 'react-native';

/**
 * Codegen spec of the native module `ClikgateEngage`: only `shareLink`, the share menu of
 * `share.link()` / `share.referralLink()`, over the native Engage add-on (Android
 * com.clikgate:clikgate-engage, iOS Clikgate/Engage). Everything else in this package is
 * TypeScript. Resolves `true` when the app itself opened; rejects with `code` and `message`.
 */
export interface Spec extends TurboModule {
  shareLink(args: CodegenTypes.UnsafeObject): Promise<boolean>;
}

// react-native-web has no TurboModuleRegistry: importing this on the web (including Expo Router's
// server rendering during a release build) must give null, not a crash.
export default TurboModuleRegistry == null
  ? null
  : TurboModuleRegistry.get<Spec>('ClikgateEngage');
