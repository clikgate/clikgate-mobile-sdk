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

export default TurboModuleRegistry.get<Spec>('ClikgateEngage');
