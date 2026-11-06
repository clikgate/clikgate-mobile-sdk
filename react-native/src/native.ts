import { NativeEventEmitter } from 'react-native';

import NativeClikgate, { type Spec } from './NativeClikgate';
import { ClikgateError } from './errors';

/** Name of the deep-link event emitted by the native module. */
export const DEEP_LINK_EVENT = 'ClikgateDeepLink';

/** Method names of the bridge. */
export type NativeMethod = Exclude<
  keyof Spec,
  'addListener' | 'removeListeners' | 'getConstants'
>;

function nativeModule(): Spec {
  if (NativeClikgate == null) {
    throw new ClikgateError(
      ClikgateError.unsupportedPlatform,
      'The Clikgate native module is not available. Rebuild the app after installing ' +
        '@clikgate/react-native (Expo: use a development build or prebuild, not Expo Go).'
    );
  }
  return NativeClikgate;
}

/**
 * Organisation feature behind each feature-gated bridge method. Used to name the feature of a `feature_disabled` error when native doesn't.
 */
const METHOD_FEATURE: Partial<Record<NativeMethod, string>> = {
  referralsApplyCode: 'referrals',
  referralsReferredBy: 'referrals',
};

/**
 * Invokes a native method, mapping rejections to `ClikgateError`. The native SDKs report a
 * switched-off feature as a `feature_disabled` rejection; a `{accepted: false, reason:
 * "feature_disabled"}` map resolved by an older bridge is turned into the same error.
 */
export async function invoke<T>(
  method: NativeMethod,
  args: Record<string, unknown> = {}
): Promise<T> {
  const module = nativeModule();
  const feature = METHOD_FEATURE[method] ?? null;
  let result: unknown;
  try {
    const fn = module[method] as (a?: object) => Promise<unknown>;
    result =
      method === 'sdkVersion'
        ? await fn.call(module)
        : await fn.call(module, args);
  } catch (e) {
    throw ClikgateError.fromNative(e, feature);
  }
  if (feature != null && isFeatureDisabledBody(result)) {
    const named = (result as { feature?: unknown }).feature;
    throw new ClikgateError(
      ClikgateError.featureDisabled,
      'This feature is switched off for the organisation.',
      { feature: typeof named === 'string' ? named : feature }
    );
  }
  return result as T;
}

function isFeatureDisabledBody(v: unknown): boolean {
  if (typeof v !== 'object' || v === null) return false;
  const m = v as { accepted?: unknown; reason?: unknown };
  return m.accepted === false && m.reason === 'feature_disabled';
}

/**
 * Subscribes to native deep-link events. Returns null when the native module is missing
 * (the TS layer then simply never receives links).
 */
export function subscribeToNativeDeepLinks(
  handler: (event: unknown) => void
): (() => void) | null {
  if (NativeClikgate == null) return null;
  const emitter = new NativeEventEmitter(NativeClikgate);
  const subscription = emitter.addListener(DEEP_LINK_EVENT, handler);
  return () => subscription.remove();
}
