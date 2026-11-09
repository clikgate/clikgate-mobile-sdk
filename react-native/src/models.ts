import type { ClikgateProvider } from './provider';

/** JSON object as delivered by the native SDKs (app-defined maps pass through unchanged). */
export type JsonMap = { [key: string]: unknown };

/**
 * Options of `Clikgate.goal`. Never put customer data in a goal: use your business's own
 * reference only.
 */
export interface GoalOptions {
  /** Normal units (₦2,000,000 is `2000000` or `'2000000'`), ≥ 0, ≤ 15 significant digits. */
  value?: number | string | null;
  /** ISO 4217; omitted = the goal's default currency. */
  currency?: string | null;
  /** Your unique id for this event (1-128 characters); omitted = a generated UUID. For a Payment goal: the payment reference your checkout returned. */
  reference?: string | null;
  /** The payment provider, for a Payment goal: `ClikgateProvider.Paystack`, or `providerFromString('...')` for a newer one. */
  provider?: ClikgateProvider | null;
  /** Your statement that this is the customer's first such event. */
  isFirst?: boolean | null;
  /**
   * The person's label, as with `identifyUser({ label })` (1-80 characters; Growth and up;
   * dropped in private mode unless your organisation allows labels there).
   */
  label?: string | null;
}

/** `Clikgate.identifyUser()`: leave `customerId` out to keep the stored one; `null` clears it. */
export interface IdentifyUserOptions {
  label?: string | null;
  customerId?: string | null;
  identityToken?: string | null;
}

/** The outcome of a goal call. */
export const GoalStatus = {
  /** The goal counted. */
  Counted: 'counted',
  /** Not counted yet: a Payment goal waiting for its confirmation, or a goal waiting for its click. */
  Waiting: 'waiting',
  /**
   * Stored, not counted: the name isn't ticked as a goal in the dashboard yet (`not_counted_yet`)
   * or the goal is archived (`goal_archived`). A success: it isn't retried. It counts once ticked.
   */
  Received: 'received',
  /**
   * Not counted; `reason` says why. Final: never retried. When the organisation accepts only goals it has
   * set up, a name with no goal behind it is refused with `unknown_goal` (an archived goal with
   * `goal_archived`); debug builds log "Goal `name` isn't set up in Clikgate".
   */
  Refused: 'refused',
} as const;
export type GoalStatus = (typeof GoalStatus)[keyof typeof GoalStatus];

/** The kind of a goal, set in the goal's settings (never in the call). */
export const GoalKind = {
  /** Counts when it's sent. */
  Standard: 'standard',
  /** Counts when your payment provider or server confirms it, with the real amount. */
  Payment: 'payment',
} as const;
export type GoalKind = (typeof GoalKind)[keyof typeof GoalKind];

/** The result of `Clikgate.goal`. */
export interface GoalResult {
  status: GoalStatus;
  /**
   * `null` when counted; else a reason code such as `waiting_for_confirmation`, `not_counted_yet`,
   * `goal_archived`, `unknown_goal`, `unattributed`, `payment_goal_needs_confirmation` or `invalid_argument`.
   */
  reason: string | null;
  /** The goal's kind, when Clikgate said (`null` for goals refused on the device). */
  goalKind: GoalKind | null;
  /** True when a value was sent for a Payment goal: it was ignored (the amount comes from the confirmation). */
  valueIgnored: boolean;
}

/** Decodes the bridge's goal result map; unknown statuses are refused. */
export function goalResultFromMap(value: unknown): GoalResult {
  const m = (value ?? {}) as Record<string, unknown>;
  const status: GoalStatus =
    m.status === 'counted' || m.status === 'waiting' || m.status === 'received'
      ? m.status
      : 'refused';
  const goalKind: GoalKind | null =
    m.goalKind === 'standard' || m.goalKind === 'payment' ? m.goalKind : null;
  return {
    status,
    reason: typeof m.reason === 'string' ? m.reason : null,
    goalKind,
    valueIgnored: m.valueIgnored === true,
  };
}

/** Push provider of a token passed to `Clikgate.setPushToken`. */
export type PushProvider = 'fcm' | 'apns';

/** SDK log level (logs never contain keys or tokens). */
export type ClikgateLogLevel =
  'verbose' | 'debug' | 'info' | 'warn' | 'error' | 'none';

/** The environment of the app's SDK key. */
export type ClikgateEnvironment = 'production' | 'sandbox';

/** Device attestation on install (Play Integrity / App Attest). */
export type ClikgateAttestation = 'off' | 'ifAvailable';

/** iOS pasteboard matching mode (ignored on Android). */
export type ClikgatePasteboardMode = 'off' | 'automatic' | 'pasteControlOnly';

/** Install attribution status. */
export type ClikgateAttributionStatus = 'pending' | 'attributed' | 'organic';

/** Options of `Clikgate.configure`. */
export interface ClikgateConfig {
  /** Public SDK key `cg_sdk_...`. */
  sdkKey: string;
  /**
   * Your Clikgate link domains (App Links / Universal Links), e.g. `['inv.myapp.com']`: list every
   * domain of your domain group (aliases such as `ybr.ng` and `go.yourbrand.com` are the same links)
   * and add each one to the iOS Associated Domains (`applinks:<domain>`) and an Android `autoVerify`
   * intent filter (the Expo plugin does both). The native SDK adds the server's `link_domains`
   * (case-insensitive, cached) to these and logs a warning for any server domain missing here.
   */
  linkDomains?: string[];
  /** Override the API base URL (e.g. a local backend). Default `https://sdk.clikgate.com`. */
  apiBaseUrl?: string | null;
  /** Default `warn`. */
  logLevel?: ClikgateLogLevel;
  /** Default `production`. */
  environment?: ClikgateEnvironment;
  /** Default `off`. */
  attestation?: ClikgateAttestation;
  /**
   * iOS only: the opt-in clipboard deferred deep link. Default `off` (since 1.2.0; was
   * `automatic`). `automatic` reads the pasteboard once on first launch, only when your Clikgate
   * app setting enables it, which shows the iOS paste prompt.
   */
  pasteboardMode?: ClikgatePasteboardMode;
  /** iOS only: delay the first install call until the ATT prompt was answered (max 30 s). */
  waitForATT?: boolean;
  /** How long `getAttribution` waits for the server on first launch. Default 5000 ms. */
  deferredDeepLinkTimeoutMs?: number;
  /**
   * A link on a shared Clikgate domain (`ciz.to`, `clk.ng`, `clkg.to`, `dev.ciz.to`) that belongs to
   * another organisation opens in an in-app browser (Android Custom Tabs, iOS
   * SFSafariViewController) and is reported to `onBrowserHandoff`, never to `onDeepLink`. Default
   * `true`; `false` drops it, as before 1.5.0.
   */
  platformDomainBrowserFallback?: boolean;
}

/**
 * A shared-domain link of another organisation that the native SDK opened in an in-app browser
 * instead of the app (no deep link is delivered for it).
 */
export interface ClikgateBrowserHandoff {
  /** The link as it opened the app. */
  url: string;
  /** Its shared domain, lowercased (`ciz.to`, `clk.ng`, `clkg.to` or `dev.ciz.to`). */
  host: string;
}

/** The Clikgate link behind a deep link or attribution. */
export interface ClikgateLink {
  id: string;
  /** `standard` or `referral`. */
  kind: string;
  externalReference: string | null;
  campaignId: string | null;
  metadata: JsonMap;
  isReferral: boolean;
}

/** A referral of this installation (as referee). */
export interface Referral {
  referralId: string;
  programId: string;
  /** `installed`, `signed_up`, `in_progress`, `holding`, `qualified`, `disqualified` or `rejected`. */
  status: string;
  /** `link`, `code_entry` or `byo_code`. */
  source: string | null;
  referrerId: string;
  referrerDisplayName: string | null;
  createdAt: Date | null;
}

/**
 * A deep link: deferred (first launch after install) or direct (App Link, Universal Link,
 * custom scheme).
 */
export interface ClikgateDeepLink {
  url: string | null;
  path: string | null;
  data: JsonMap;
  isDeferred: boolean;
  clickId: string | null;
  /** `app_link`, `install_referrer`, `pasteboard`, `code_entry`, ... */
  matchType: string | null;
  link: ClikgateLink | null;
  referral: Referral | null;
  /**
   * Set when the link is blocked here (allowed countries or a block rule): show this
   * text and don't route. `path`, `clickId` and `link` are null.
   */
  blockMessage: string | null;
}

/** Install attribution of this installation. */
export interface ClikgateAttribution {
  status: ClikgateAttributionStatus;
  matchType: string | null;
  confidence: number | null;
  clickId: string | null;
  clickedAt: Date | null;
  isReinstall: boolean;
  /** Clikgate install id (`ins_...`), null until the install was recorded. */
  installId: string | null;
  link: ClikgateLink | null;
  isAttributed: boolean;
}

/** Whether this installation was referred. */
export interface ReferredBy {
  referred: boolean;
  referral: Referral | null;
}

// ------------------------------------------------------------------ v3: feature switches

/**
 * Feature keys of `Clikgate.isFeatureEnabled` (the SDK-relevant organisation features in
 * `/v1/sdk/config`). Any other string is accepted and answers `false`.
 */
export type ClikgateFeature =
  | 'app_attribution'
  | 'referrals'
  | 'leaderboards'
  | 'identity_checks'
  | 'whatsapp_attribution'
  | 'offline_codes'
  | 'skan_postbacks'
  | 'uninstall_tracking'
  | 'probabilistic_matching'
  | 'apple_search_ads'
  | (string & {});

/**
 * Internal: what a `/v1/sdk/...` call needs to act for this installation. Used by `@clikgate/react-native-engage`; not part of the app-facing API.
 */
export interface ClikgateRequestContext {
  installationId: string;
  sdkKey: string;
  environment: ClikgateEnvironment;
  /** Base URL without trailing slash, e.g. `https://sdk.clikgate.com`. */
  apiBaseUrl: string;
  /** The identity token stored by `identify`, if any. */
  identityToken: string | null;
  /** The user id stored by `identify`; null when the installation isn't identified. */
  customerUserId: string | null;
  /** Value of the `Clikgate-SDK-Version` header (`react-native/1.0.0`). */
  sdkVersion: string;
  /** Value of the `Clikgate-SDK-Native-Version` header (`android/1.0.0`, `ios/1.0.0`), if any. */
  nativeSdkVersion: string | null;
}

// ------------------------------------------------------------------ decoding (bridge maps)

function asMap(v: unknown): JsonMap {
  return typeof v === 'object' && v !== null && !Array.isArray(v)
    ? (v as JsonMap)
    : {};
}

function str(v: unknown, fallback: string): string {
  return typeof v === 'string' ? v : fallback;
}

function optStr(v: unknown): string | null {
  return typeof v === 'string' ? v : null;
}

function bool(v: unknown): boolean {
  return v === true;
}

function date(v: unknown): Date | null {
  if (typeof v !== 'string') return null;
  const d = new Date(v);
  return Number.isNaN(d.getTime()) ? null : d;
}

function optional<T>(v: unknown, f: (m: JsonMap) => T): T | null {
  return typeof v === 'object' && v !== null && !Array.isArray(v)
    ? f(v as JsonMap)
    : null;
}

export function linkFromMap(m: JsonMap): ClikgateLink {
  const kind = str(m.kind, 'standard');
  return {
    id: str(m.id, ''),
    kind,
    externalReference: optStr(m.externalReference),
    campaignId: optStr(m.campaignId),
    metadata: asMap(m.metadata),
    isReferral: kind === 'referral',
  };
}

export function referralFromMap(m: JsonMap): Referral {
  return {
    referralId: str(m.referralId, ''),
    programId: str(m.programId, ''),
    status: str(m.status, 'installed'),
    source: optStr(m.source),
    referrerId: str(m.referrerId, ''),
    referrerDisplayName: optStr(m.referrerDisplayName),
    createdAt: date(m.createdAt),
  };
}

export function deepLinkFromMap(input: unknown): ClikgateDeepLink {
  const m = asMap(input);
  return {
    url: optStr(m.url),
    path: optStr(m.path),
    data: asMap(m.data),
    isDeferred: bool(m.isDeferred),
    clickId: optStr(m.clickId),
    matchType: optStr(m.matchType),
    link: optional(m.link, linkFromMap),
    referral: optional(m.referral, referralFromMap),
    blockMessage: optStr(m.blockMessage),
  };
}

export function browserHandoffFromMap(input: unknown): ClikgateBrowserHandoff {
  const m = asMap(input);
  return { url: str(m.url, ''), host: str(m.host, '') };
}

export function attributionFromMap(input: unknown): ClikgateAttribution {
  const m = asMap(input);
  const status: ClikgateAttributionStatus =
    m.status === 'attributed' || m.status === 'organic' ? m.status : 'pending';
  return {
    status,
    matchType: optStr(m.matchType),
    confidence:
      typeof m.confidence === 'number' && Number.isFinite(m.confidence)
        ? m.confidence
        : null,
    clickId: optStr(m.clickId),
    clickedAt: date(m.clickedAt),
    isReinstall: bool(m.isReinstall),
    installId: optStr(m.installId),
    link: optional(m.link, linkFromMap),
    isAttributed: status === 'attributed',
  };
}

export function referredByFromMap(input: unknown): ReferredBy {
  const m = asMap(input);
  return {
    referred: bool(m.referred),
    referral: optional(m.referral, referralFromMap),
  };
}

export function referralResultFromMap(input: unknown): Referral {
  return referralFromMap(asMap(input));
}

export function requestContextFromMap(input: unknown): ClikgateRequestContext {
  const m = asMap(input);
  return {
    installationId: str(m.installationId, ''),
    sdkKey: str(m.sdkKey, ''),
    environment: m.environment === 'sandbox' ? 'sandbox' : 'production',
    apiBaseUrl: str(m.apiBaseUrl, 'https://sdk.clikgate.com').replace(
      /\/+$/,
      ''
    ),
    identityToken: optStr(m.identityToken),
    customerUserId: optStr(m.customerUserId),
    sdkVersion: str(m.sdkVersion, ''),
    nativeSdkVersion: optStr(m.nativeSdkVersion),
  };
}

/** State of one consent purpose. */
export type ConsentState = 'granted' | 'denied' | 'unknown';

/** Argument of `Clikgate.setConsent`: omitted purposes keep their current state. */
export interface ClikgateConsentUpdate {
  analytics?: ConsentState;
  attribution?: ConsentState;
  adUserData?: ConsentState;
  adPersonalization?: ConsentState;
}

/** Result of `Clikgate.getConsent`. */
export interface ClikgateConsent {
  analytics: ConsentState;
  attribution: ConsentState;
  adUserData: ConsentState;
  adPersonalization: ConsentState;
  /** Region hint from `setConsentRegion` (`EEA`, `UK` or a country code), or null. */
  region: string | null;
  /** Whether consent is required for this device; null while not known yet. */
  required: boolean | null;
}

/** Options of `Clikgate.enableFirebaseForwarding` (each combined with the server setting). */
export interface ClikgateFirebaseForwardingOptions {
  /** Log `clikgate_attribution` once per install. Default true. */
  logAttributionEvent?: boolean;
  /** Set `cg_first_source` / `cg_first_campaign`. Default true. */
  setUserProperties?: boolean;
}

const CONSENT_STATES: readonly string[] = ['granted', 'denied', 'unknown'];

function consentState(v: unknown): ConsentState {
  return typeof v === 'string' && CONSENT_STATES.includes(v)
    ? (v as ConsentState)
    : 'unknown';
}

/** @internal */
export function isConsentState(v: unknown): v is ConsentState {
  return typeof v === 'string' && CONSENT_STATES.includes(v);
}

/** @internal Decodes the bridge's Consent map. */
export function consentFromMap(raw: unknown): ClikgateConsent {
  const m = (typeof raw === 'object' && raw !== null ? raw : {}) as Record<
    string,
    unknown
  >;
  return {
    analytics: consentState(m.analytics),
    attribution: consentState(m.attribution),
    adUserData: consentState(m.adUserData),
    adPersonalization: consentState(m.adPersonalization),
    region: typeof m.region === 'string' ? m.region : null,
    required: typeof m.required === 'boolean' ? m.required : null,
  };
}

/** @internal Decodes the bridge's metadata map (string values only). */
export function stringMapFromMap(raw: unknown): Record<string, string> {
  const out: Record<string, string> = {};
  if (typeof raw !== 'object' || raw === null) return out;
  for (const [k, v] of Object.entries(raw as Record<string, unknown>)) {
    if (typeof v === 'string') out[k] = v;
  }
  return out;
}
