import {
  DeepLinkHub,
  type BrowserHandoffListener,
  type DeepLinkListener,
} from './deepLinkHub';
import { ClikgateError } from './errors';
import { isClikgateMessage } from './isClikgateMessage';
import {
  attributionFromMap,
  type ClikgateAttribution,
  type ClikgateConfig,
  type ClikgateConsent,
  type ClikgateConsentUpdate,
  type ClikgateFirebaseForwardingOptions,
  consentFromMap,
  isConsentState,
  stringMapFromMap,
  type ClikgateFeature,
  type ClikgateMoney,
  type ClikgateRequestContext,
  type GoalOptions,
  type IdentifyUserOptions,
  goalResultFromMap,
  type GoalResult,
  GoalStatus,
  type PushProvider,
  requestContextFromMap,
} from './models';
import { invoke, subscribeToNativeDeepLinks } from './native';
import { referrals } from './referrals';
import { VERSION } from './version';

let hub = new DeepLinkHub(subscribeToNativeDeepLinks);

/**
 * The decimal string sent for a goal value (`2000000` → `'2000000'`; strings are trimmed and
 * validated natively). NaN, infinity, numbers JavaScript prints with an exponent (`1e21`,
 * `1e-7`) and other types are rejected: pass those amounts as strings.
 */
function goalValueString(value: unknown): string | null {
  if (value == null) return null;
  if (typeof value === 'string') return value.trim();
  if (typeof value === 'bigint') return value.toString();
  if (typeof value === 'number' && Number.isFinite(value)) {
    const s = String(value);
    if (!/e/i.test(s)) return s;
  }
  throw new ClikgateError(
    ClikgateError.invalidArgument,
    'Goal value must be a number or a numeric string (pass very large or small amounts as a string)',
    { param: 'value' }
  );
}

/**
 * Clikgate (core): deep links, install attribution, events, identifyUser, referee-side referral
 * calls, uninstall tracking and feature switches. A thin bridge over the native Android and iOS
 * SDKs (no attribution or referral logic in JS). Referral links/stats, leaderboards, promo codes
 * and share helpers live in `@clikgate/react-native-engage` (apps without a backend) or, the
 * recommended path, in your backend via the Clikgate API.
 */
export const Clikgate = {
  /** Version of this package (reported as `Clikgate-SDK-Version: react-native/<version>`). */
  pluginVersion: VERSION,

  /** Referee-side referral calls (`applyCode`, `referredBy`). */
  referrals,

  /**
   * Whether an organisation feature is on, from the SDK's cached `/config` (refreshed on launch,
   * at most hourly). Before the first config fetch the defaults apply (`referrals`,
   * `leaderboards`, `offline_codes`, `app_attribution` on; the rest off); unknown keys are
   * `false`. Calls of a switched-off feature reject with `ClikgateError('feature_disabled')`
   * without a network call, so checking first is only needed to hide UI.
   */
  async isFeatureEnabled(key: ClikgateFeature): Promise<boolean> {
    if (typeof key !== 'string' || key.length === 0) return false;
    return (await invoke<boolean | null>('isFeatureEnabled', { key })) === true;
  },

  /**
   * Starts the SDK. Call once, as early as possible (e.g. in `index.js` before
   * `AppRegistry.registerComponent`, or at the top of your root component's module).
   */
  async configure(config: ClikgateConfig): Promise<void> {
    if (config == null || typeof config.sdkKey !== 'string') {
      throw new ClikgateError(
        ClikgateError.invalidArgument,
        'sdkKey is required',
        { param: 'sdkKey' }
      );
    }
    // Listen before configuring so no deep link is missed.
    hub.start();
    await invoke<void>('configure', {
      sdkKey: config.sdkKey,
      linkDomains: config.linkDomains ?? [],
      apiBaseUrl: config.apiBaseUrl ?? null,
      logLevel: config.logLevel ?? 'warn',
      environment: config.environment ?? 'production',
      attestation: config.attestation ?? 'off',
      pasteboardMode: config.pasteboardMode ?? 'off',
      waitForATT: config.waitForATT ?? false,
      deferredDeepLinkTimeoutMs: config.deferredDeepLinkTimeoutMs ?? 5000,
      platformDomainBrowserFallback:
        config.platformDomainBrowserFallback ?? true,
      wrapperVersion: VERSION,
    });
  },

  /**
   * Every deep link: the deferred one after install and direct opens. Returns the
   * unsubscribe function. Links received before the first listener is attached are replayed
   * to it, so subscribing in your root component's `useEffect` is fine.
   */
  onDeepLink(listener: DeepLinkListener): () => void {
    return hub.addListener(listener);
  },

  /**
   * Shared-domain links of other organisations that the native SDK opened in an in-app browser
   * instead of the app (`platformDomainBrowserFallback`). Returns the unsubscribe function;
   * buffered and replayed like `onDeepLink`.
   */
  onBrowserHandoff(listener: BrowserHandoffListener): () => void {
    return hub.addHandoffListener(listener);
  },

  /**
   * Install attribution. On first launch waits for the server up to
   * `deferredDeepLinkTimeoutMs`, then resolves with status `pending`.
   */
  async getAttribution(): Promise<ClikgateAttribution> {
    return attributionFromMap(await invoke<unknown>('getAttribution', {}));
  },

  /**
   * Tracks an app event (queued and batched natively). Rejects with
   * `ClikgateError('invalid_argument')` for an invalid name, currency or properties over 8 KB.
   */
  async track(
    name: string,
    options: {
      revenue?: ClikgateMoney | null;
      properties?: Record<string, unknown> | null;
    } = {}
  ): Promise<void> {
    const revenue = options.revenue ?? null;
    if (revenue != null && !Number.isInteger(revenue.amountMinor)) {
      throw new ClikgateError(
        ClikgateError.invalidArgument,
        'revenue.amountMinor must be an integer amount in minor units',
        { param: 'revenueMinor' }
      );
    }
    await invoke<void>('track', {
      name,
      revenueMinor: revenue?.amountMinor ?? null,
      currency: revenue?.currency ?? null,
      properties: options.properties ?? null,
    });
  },

  /**
   * Records a goal: an outcome your business chose, such as `account_opened`, `loan_disbursed`
   * or `purchase`, attributed to the click or install that brought this user:
   * `Clikgate.goal('account_opened', { value: 2000000, currency: 'NGN', reference: 'APP-55231', isFirst: true })`.
   *
   * For a **Payment goal** (set in the dashboard), pass the payment provider and the reference
   * your checkout returned:
   * `Clikgate.goal('purchase', { reference: 'T123456', provider: ClikgateProvider.Paystack })`.
   * It waits until your payment provider or server confirms it, with the real amount (any
   * `value` sent from the app is ignored).
   *
   * `value` is in normal units (never kobo or cents): a number or a numeric string such as
   * `'1500.50'` (pass a string for exact amounts: it reaches the native SDK as a decimal string,
   * never as a double); zero or more, at most 15 significant digits. `reference` is your own
   * unique id (1-128 characters; a UUID is generated when omitted). Queued, retried and
   * consent-buffered like `track`, idempotent by key and reference, and sent in private mode too.
   * Never put customer data in a goal.
   *
   * Resolves with a `GoalResult` once Clikgate has answered: `GoalStatus.Counted`,
   * `GoalStatus.Waiting` (a Payment goal waiting for its confirmation) or `GoalStatus.Refused`
   * with a `reason` (`invalid_argument` for a bad key, value, currency or reference). Never
   * rejects. While the device is offline the goal stays queued and the promise resolves when it
   * is sent, so don't block your UI on it.
   */
  async goal(key: string, options: GoalOptions = {}): Promise<GoalResult> {
    try {
      const result = await invoke<unknown>('goal', {
        key,
        value: goalValueString(options.value),
        currency: options.currency ?? null,
        reference: options.reference ?? null,
        provider: options.provider ?? null,
        isFirst: options.isFirst ?? null,
        label: options.label ?? null,
      });
      return goalResultFromMap(result);
    } catch (e) {
      const reason = e instanceof ClikgateError ? e.code : 'unknown';
      return {
        status: GoalStatus.Refused,
        reason,
        goalKind: null,
        valueIgnored: false,
      };
    }
  },

  /**
   * Tells Clikgate who this user is: an optional `label` your team sees instead of the click ID
   * (1-80 characters, `''` clears it; Growth and up), your `customerId` (`null` clears it on
   * logout; leave it out to keep the stored one) and an `identityToken` from your backend (for
   * referral programs with `require_identity_token`). With nothing to send it does nothing. In
   * private mode the customer ID and token are dropped on the device, and the label too unless
   * your organisation allows labels there. Don't put information in labels that your customers
   * wouldn't expect you to keep.
   */
  async identifyUser(options: IdentifyUserOptions = {}): Promise<void> {
    await invoke<void>('identifyUser', {
      label: options.label ?? null,
      ...('customerId' in options
        ? { customerId: options.customerId ?? null }
        : {}),
      identityToken: options.identityToken ?? null,
    });
  },

  /** Opt-out switch: `false` stops all processing for this installation. */
  async setTrackingEnabled(enabled: boolean): Promise<void> {
    await invoke<void>('setTrackingEnabled', { enabled: enabled === true });
  },

  /**
   * Registers the push token used for uninstall checks. A null or empty token is ignored
   * (e.g. `messaging().getToken()` failed). For `apns` pass the hex device token.
   */
  async setPushToken(
    token: string | null | undefined,
    options: { provider: PushProvider }
  ): Promise<void> {
    if (token == null || token.length === 0) return;
    await invoke<void>('setPushToken', { token, provider: options.provider });
  },

  /**
   * True for Clikgate's silent uninstall-check pushes (FCM `data.cg == "uc"`, APNs
   * `cg.t == "uc"`). Pure TypeScript, so it works in headless JS / background handlers.
   */
  isClikgateMessage,

  /**
   * Hands a URL to the SDK (e.g. from a QR scanner). Resolves true for Clikgate links; the
   * result arrives on `onDeepLink`. App Links / Universal Links that open the app are
   * forwarded automatically (see the integration guide).
   */
  async handleUrl(url: string): Promise<boolean> {
    return (await invoke<boolean | null>('handleUrl', { url })) === true;
  },

  /**
   * @internal Used by `@clikgate/react-native-engage`; not part of the app-facing API.
   *
   * The request context (installation id, SDK key, environment, base URL, identity token, user
   * id, version headers) for a `/v1/sdk/...` call, once the first install was recorded and a
   * pending `identify` was sent. Rejects with `not_configured`, `opted_out`, `install_pending`,
   * `invalid_sdk_key` or `sdk_disabled`.
   */
  async getRequestContext(): Promise<ClikgateRequestContext> {
    return requestContextFromMap(
      await invoke<unknown>('getRequestContext', {})
    );
  },

  /**
   * @internal Used by `@clikgate/react-native-engage`; not part of the app-facing API.
   *
   * Reports an error code a `/v1/sdk/...` call made with the request context got:
   * `feature_disabled` (with `feature`) switches the feature off until the next config fetch;
   * `invalid_sdk_key`, `sdk_disabled` and `installation_unknown` apply the native SDK's global
   * rules. Other codes are ignored. Never rejects.
   */
  async reportServerError(
    code: string,
    feature?: string | null
  ): Promise<void> {
    try {
      await invoke<void>('reportServerError', {
        code,
        feature: feature ?? null,
      });
    } catch {
      // Best effort.
    }
  },

  /**
   * Sets the user's consent per purpose. Omitted purposes keep their state; all are
   * `unknown` until set. Where consent is required (EEA, UK, Switzerland by default) and
   * `attribution` is unknown, the native SDK buffers events (up to 7 days / 1,000 events) and
   * sends nothing identifying; grant sends the buffer, deny drops it. Rejects with
   * `invalid_argument` for an unknown state.
   */
  async setConsent(consent: ClikgateConsentUpdate): Promise<void> {
    const args: Record<string, unknown> = {};
    for (const key of [
      'analytics',
      'attribution',
      'adUserData',
      'adPersonalization',
    ] as const) {
      const v = consent?.[key];
      if (v === undefined || v === null) continue;
      if (!isConsentState(v)) {
        throw new ClikgateError(
          ClikgateError.invalidArgument,
          `${key} must be 'granted', 'denied' or 'unknown'`,
          { param: key }
        );
      }
      args[key] = v;
    }
    await invoke<void>('setConsent', args);
  },

  /** The consent set with `setConsent`, the region hint and whether consent is required here. */
  async getConsent(): Promise<ClikgateConsent> {
    return consentFromMap(await invoke<unknown>('getConsent', {}));
  },

  /**
   * Region hint for consent: `'EEA'`, `'UK'` or an ISO 3166-1 alpha-2 country (e.g. `'DE'`);
   * null clears it. Rejects with `invalid_argument` for anything else.
   */
  async setConsentRegion(region: string | null): Promise<void> {
    let value: string | null = null;
    if (region != null) {
      value = String(region).trim().toUpperCase();
      if (!/^(EEA|UK|[A-Z]{2})$/.test(value)) {
        throw new ClikgateError(
          ClikgateError.invalidArgument,
          "region must be 'EEA', 'UK' or an ISO 3166-1 alpha-2 country code",
          { param: 'region' }
        );
      }
    }
    await invoke<void>('setConsentRegion', { region: value });
  },

  /**
   * Sends Clikgate attribution to Firebase Analytics when the app includes it (detected by the
   * native SDK; with `@react-native-firebase/analytics` it is): `clikgate_attribution` once per
   * install, `cg_first_source` / `cg_first_campaign`, optionally every tracked event, and reports
   * Firebase's app instance id to Clikgate. Needs `analytics` consent and GA4 forwarding switched
   * on in Clikgate. Call on every launch.
   */
  async enableFirebaseForwarding(
    options: ClikgateFirebaseForwardingOptions = {}
  ): Promise<void> {
    const map: Record<string, string> = {};
    for (const [k, v] of Object.entries(options.eventNameMap ?? {})) {
      if (typeof v === 'string') map[k] = v;
    }
    await invoke<void>('enableFirebaseForwarding', {
      logAttributionEvent: options.logAttributionEvent ?? true,
      setUserProperties: options.setUserProperties ?? true,
      mirrorEvents: options.mirrorEvents ?? false,
      eventNameMap: map,
    });
  },

  /**
   * `{cg_click_id, cg_link_id}` of the click that brought this user, for Paystack `metadata` /
   * Flutterwave `meta`, so Clikgate can match the sale. Empty when there is none or consent
   * doesn't allow attribution.
   */
  async attributionMetadata(): Promise<Record<string, string>> {
    return stringMapFromMap(await invoke<unknown>('attributionMetadata', {}));
  },

  /**
   * iOS only (no-op on Android): pass Google's on-device conversion measurement info to Clikgate
   * with the first install, when the app includes Google's GoogleAdsOnDeviceConversion SDK. Call
   * before `configure` on the first launch.
   */
  async enableGoogleOnDeviceMeasurement(): Promise<void> {
    await invoke<void>('enableGoogleOnDeviceMeasurement', {});
  },

  /** Version of the native SDK underneath. */
  async nativeSdkVersion(): Promise<string> {
    return (await invoke<string | null>('sdkVersion')) ?? 'unknown';
  },
};

/** @internal Test hook: drops listeners/buffered links and re-subscribes lazily. */
export function resetClikgateForTesting(): void {
  hub.dispose();
  hub = new DeepLinkHub(subscribeToNativeDeepLinks);
}
