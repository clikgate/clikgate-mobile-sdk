# Behaviour common to the native SDKs

Android (Kotlin) and iOS (Swift) implement the same lifecycle. Flutter and React Native
are thin bridges over them and contain no attribution or referral logic.

## Core SDK vs Engage add-on (spec v3 new edition, 0.4 / 17A)

The **core SDK** only does what must happen on the device: installation id, first launch /
reinstall / opens, Play Install Referrer, pasteboard token, deep link delivery, goals with the
offline queue, `identifyUser` and the installation ID, push token + silent-push filtering, attestation,
Apple Search Ads token, opt-out, feature switches (`isFeatureEnabled`), and the referee-side
referral calls tied to this installation: `referrals.applyCode` and `referrals.referredBy`.

The optional **Engage add-on** holds the convenience reads and actions for apps without their own
backend: create/get the user's referral link, "my referral stats", leaderboard top / me /
around-me / opt-out / hosted page URL, promo/offline code redemption, and share helpers (system
share sheet, WhatsApp). Packages: `com.clikgate:clikgate-engage` (Android), `ClikgateEngage` SPM
product / `Clikgate/Engage` pod subspec (iOS), `clikgate_engage` (Dart, plus a share-menu plugin over
the native Engage add-on), and `@clikgate/react-native-engage` (TypeScript, plus a share-menu
TurboModule over the native Engage add-on).

The recommended path for apps **with** a backend is core SDK + the app's backend calling the
control-plane API (referrers, referral stats, leaderboards, identity signals, goals from the server) and
rendering its own screens (`docs/engage.md`).

Rules (checked in CI by `scripts/check_sdk_boundaries.sh`):
- The core SDKs contain no leaderboard, referral-stats, link-creation, code or share code, and no
  identity-signal API (public-API snapshot per core SDK, with a forbidden-name check).
- Engage depends on core, never the other way round; installing core alone never pulls Engage in.
- Neither computes anything the backend decides (no qualification, ranking or reward logic).
- Size budgets: core Android < 150 KB, core iOS < 410 KB (a hard ceiling), Engage Android < 44 KB,
  Engage iOS < 95 KB (40 / 80 KB before Change 13's share.link; methods in each platform's DECISIONS.md).
- There is no SDK identity-signal endpoint or method: identity signals are server-to-server only
  (the customer's pepper never ships in an app).

### Request context (core → Engage)

The core exposes a small internal request context (`installationId`, SDK key, environment, base
URL, identity token, customer user id, the SDK version headers) and an error report-back
(`reportServerError`); see PLATFORM_CHANNEL.md "Engage split" for the exact shape. Getting the
context applies the core gates (not configured, opted out, invalid key, kill switch), waits for /
requires the first `/install` (`install_pending`), and sends a pending `/identify` first. Engage
keeps no attribution state and persists nothing.

### Engage rules (17A.3)

- Every call first checks `isFeatureEnabled(feature)` (`referrals` for link/stats, `leaderboards`,
  `offline_codes`) and fails with `feature_disabled` without a network call.
- Calls that act on behalf of a user (`createLink`, `myStats`, leaderboard `me` / `aroundMe` /
  `setOptOut` / `hostedPageUrl`) fail with `not_identified` without a network call when no user is
  identified. If the program has `require_identity_token`, the server answers `identity_required`
  until `identifyUser()` was called with a valid token; Engage surfaces it as a typed error.
- Headers as in API_CONTRACT.md (SDK key, SDK version (+ native version), installation id, identity
  token when stored); 10 s timeouts.
- Read results (`myStats`, `top`, `me`, `aroundMe`) are cached **in memory for 60 s** (key: the
  installation, the identified user and the request); nothing is written to disk. Writes
  (`createLink`, `setOptOut`, `redeem`) clear the cache; `hostedPageUrl` is never cached (its embed
  token is short-lived). `clearCache()` is public.
- At most **one retry, and only for network errors** (connection / IO / timeout). HTTP errors,
  including 429 and 5xx, surface at once as typed errors. Nothing is queued.
- A `200 {"accepted": false, "reason": "feature_disabled"}` body fails with `feature_disabled` and is
  reported to the core (which switches the feature off in memory and refreshes `/config`);
  `invalid_sdk_key`, `sdk_disabled` and `installation_unknown` errors are reported too.
- `hostedPageUrl` = `embed_url` from `GET /leaderboards/{id}/me?embed=1`; error
  `hosted_page_unavailable` when the server returns none.
- Share helpers: `share.system(text)` opens the system share sheet; `share.whatsApp(text)` opens
  WhatsApp when it can (Android: `ACTION_SEND` with package `com.whatsapp`, then
  `com.whatsapp.w4b`, then the chooser; iOS / Dart / RN: `whatsapp://send?text=<RFC 3986
  encoded>`, then the share sheet) and returns whether WhatsApp itself was opened; error
  `share_unavailable` only when not even the share sheet can be shown. On iOS, `canOpenURL` needs
  `whatsapp` in `LSApplicationQueriesSchemes`. `system` / `whatsApp` make no network call; no share
  helper is feature-gated. `share.link` / `share.referralLink`: "Change 13" below.
- No UI components: apps render their own screens.

## Storage

| Key | Android | iOS |
|---|---|---|
| installation id | SharedPreferences `clikgate.prefs` (exclude from Auto Backup) | `Application Support/Clikgate/state.json` **and** Keychain item `com.clikgate.installation-id` (`kSecAttrAccessibleAfterFirstUnlock`, `kSecAttrSynchronizable = false`) |
| install id (`ins_...`), install done flag | prefs | state.json |
| install referrer done flag + raw response | prefs | — |
| cached config + fetched-at | prefs (JSON) | state.json |
| last push token sent (SHA-256 of token+provider) | prefs | state.json |
| customer user id + identity token | prefs | state.json |
| tracking enabled flag | prefs | state.json |
| last open / last background time | prefs | state.json |
| pending deep link (not yet delivered) | memory | memory |
| goal queue | SQLite `clikgate_events.db` (name kept) | `Application Support/Clikgate/events.json` (name kept) |

iOS reinstall detection: on first launch, if state.json has no installation id but the
Keychain has one, generate a **new** installation id, store it in both places, and send
the old one as `keychain_previous_installation_id`.

## Lifecycle

`configure(sdkKey, options)` must be called once, as early as possible (Application
`onCreate` / `application(_:didFinishLaunchingWithOptions:)`). It returns immediately;
work runs on a background executor / actor.

1. Load state. If tracking is disabled (opted out), stop here (except `/opt-out`).
2. Get config: use the cache if younger than 1 h; otherwise `GET /config` (failure → use
   any cached copy, else defaults: everything off).
3. **First launch** (no stored `install_id`):
   - Android: query Play Install Referrer once (retry `SERVICE_UNAVAILABLE` up to 3 times
     with 1 s, 2 s, 4 s waits; `FEATURE_NOT_SUPPORTED` / `DEVELOPER_ERROR` → skip),
     installer package, emulator and root heuristics.
   - iOS: pasteboard (see below), App Attest if enabled (the Apple Ads AdServices token is
     not a first-launch signal since change 19: it is requested when `/install` is sent, below); wait for ATT up to 30 s if `waitForATT`; Simulator flag and
     jailbreak heuristics.
   - Fraud signals (`is_emulator`, `is_rooted`; see API_CONTRACT `/install`) are hints, not
     proof. They're computed once per `/install` request body, with no permission, manifest
     `<queries>` entry or `LSApplicationQueriesSchemes` entry, and never delay or fail the
     install: a check that throws leaves its field out.
   - Include a launch URL if the app was opened by one before `/install` completed.
   - Include the current push token if known.
   - `POST /install` with retries (persisting: if the app is killed, the next launch
     retries). Store `install_id`. Deliver `deep_link` + `referral` through the deep link
     callback (see "Deep link delivery"). Resolve `attribution()` waiters.
4. **Later launches**: `POST /open` with `is_cold_start: true`.
5. Foreground after ≥ `session_timeout_minutes` (default 30) in background:
   `POST /open` with `is_cold_start: false`.
6. Flush the goal queue on start.

## Deep link delivery

- One callback/stream receives every deep link: deferred (from `/install`) and direct
  (from `/resolve`).
- Links that arrive before the app registers its callback are buffered (latest 10) and
  delivered on registration.
- The deferred link from `/install` is delivered whenever it arrives; the result has
  `isDeferred = true`. Options `deferredDeepLinkTimeout` (default 5 s) controls only
  `awaitAttribution()` / `getAttribution()`, which resolves with `status: pending`
  after the timeout if the server hasn't answered.
- A URL is handled (and `handle(url)` returns `true`) when its host is in
  `config.link_domains` ∪ `options.linkDomains`, or its scheme is the app's URI scheme
  and it carries `cg_click_id`. The SDK calls `/resolve` and delivers the result if
  `matched`. Host comparison is case-insensitive. `config.link_domains` comes from the last
  successful `/config` (cached; optional, `[]` from older servers); the SDK warns once per launch
  about each server domain missing from `options.linkDomains` (API_CONTRACT.md, `/config`).
- From 1.4.0, an unmatched link on a shared platform domain opens in an in-app browser instead of
  being dropped ("Change 06 (SDK 1.4.0)" below).

Deep link result fields (every SDK):
`url`, `path`, `data` (map), `isDeferred`, `clickId`, `matchType`, `link`
(`id`, `kind`, `externalReference`, `campaignId`, `metadata`), `referral`
(`referralId`, `programId`, `status`, `referrerId`, `referrerDisplayName`) or null.

## Goal queue

- `goal()` is the only method for what happens in the app (Change 22). Goals are validated locally and queued
  (section "Change 06 / Change 12" below).
- Queue limit: `max_queue_events` (1000) and `max_queue_bytes` (1 MB); when full, drop the oldest.
- Flush when: 20 goals queued, every 15 s while in foreground, when the app goes to background, and on start.
  Batches ≤ 100. Android uses WorkManager for an offline retry (network-connected constraint); iOS uses a
  `beginBackgroundTask` window on background.
- Goals sent before `/install` succeeds wait in the queue.

## Identify

`identifyUser(label?, customerId?, identityToken?)` stores the customer ID and token and calls `/identify` (with the label once)
(retried until sent). `customerId: null` clears them; leaving it out keeps them. Referral calls send
`Clikgate-Identity-Token` when a token is stored. Identity tokens are made on the business's server only (server
SDK `createIdentityToken`); identity Path B uses the installation ID instead ("Change 22"). Guide:
https://clikgate.com/docs/identify-users

## Push tokens and uninstall checks

- `setPushToken(token, provider)` stores the token; if `sha256(provider + token)` differs
  from the last successful send, call `/push-token`.
- On every launch, if the stored token's hash differs from the last sent hash, send it.
- `isClikgateMessage(data)`: true when `data["cg"] == "uc"` or `data["cg"]["t"] == "uc"`.
  The SDK never shows a notification and never requests notification permission.

## Opt-out

`setTrackingEnabled(false)`: clear the goal queue, call `/opt-out {"opt_out": true}`
(retried until it succeeds, persisted), and stop all other calls. `true`: call
`/opt-out {"opt_out": false}` and resume. If opted out before the first launch's
`/install`, send `/install` with every consent purpose `denied` first (so the installation
exists; change 09, X.E23, replacing `consent.tracking_allowed = false`) and nothing afterwards.
The app's own consent values go through `/consent` once tracking is back on.

## Pasteboard (iOS only)

From 1.2.0 this is the opt-in **clipboard deferred deep link** of change 03 (B.2):
`options.pasteboardMode` defaults to `.off`, so the SDK never touches the pasteboard unless the
app opts in, the app's server setting `features.pasteboard_matching` is `on_interstitial_tap`
(per app, off by default) **and** consent allows attribution (see "Consent"). A token read while
consent is still `unknown` is kept on the device and sent only after `attribution` is granted
(dropped on deny).

- Only on first launch, only if `config.features.pasteboard_matching == "on_interstitial_tap"`
  and `options.pasteboardMode == .automatic`.
- The interstitial copies a URL of the form `https://<link_domain>/_cg/p/cgdl_<26 base62>`.
  The SDK first calls `UIPasteboard.general.detectPatterns(for: [.probableWebURL])`
  (iOS 14+, no paste prompt). Only if a web URL is likely does it read `string`
  (iOS 16+ shows the paste prompt), and extracts the first `cgdl_[0-9A-Za-z]{26}`.
  On iOS 13 it reads `string` only when `hasStrings` is true.
- Never read again after the first launch.
- `.pasteControlOnly`: never read automatically. The app shows `ClikgatePasteControl`
  (a `UIPasteControl` wrapper, iOS 16+); a tap delivers the pasteboard without the
  system prompt, and the SDK calls `/install` again with `pasteboard_token`. The server
  re-attributes an install that is still `organic` and less than 1 h old when the token
  is valid (install is otherwise idempotent and returns the stored attribution).
- `.off`: never touch the pasteboard.

## Logging

Log level option (`verbose`/`debug`/`info`/`warn`/`error`/`none`, default `warn`). Never
log the SDK key, push tokens, identity tokens or the pasteboard contents.

## Threading

All public methods are thread-safe and non-blocking. Callbacks are delivered on the main
thread. Suspend/async variants exist where the spec lists them.

## Versions

Every SDK exposes `Clikgate.sdkVersion`. Wrappers call the native SDK's internal
`setWrapper(name, version)` before `configure` so headers report both.

## v3: feature switches

- Keep the `features` map from `/config` (cached 1 h, refreshed on launch). `isFeatureEnabled(key)`
  reads it; before the first fetch use the defaults in API_CONTRACT.md.
- Before calling a feature endpoint (`referrals` in core; `referrals`, `leaderboards`,
  `offline_codes` in Engage), check the flag; if off, fail fast with `feature_disabled` (no network).
- Treat a `200 {"accepted": false, "reason": "feature_disabled"}` body on any of those endpoints
  as `feature_disabled` too, and refresh the config in the background.
- Core referral calls (`applyCode`, `referredBy`) keep their v1 retry policy (interactive, never
  queued). Engage calls follow "Engage rules" above (at most one retry, network errors only).

## Change 03 (SDK 1.2.0): consent, click ids, version policy, Firebase, identity checks

### Public API (all SDKs)

| | Android (`Clikgate.`) | iOS (`Clikgate.shared.`) | Flutter (`Clikgate.`) / React Native (`Clikgate.`) |
|---|---|---|---|
| Set consent | `setConsent(analytics, attribution, adUserData, adPersonalization)` (each `ConsentState?`, null = unchanged) | `setConsent(analytics:attribution:adUserData:adPersonalization:)` (`ClikgateConsentState?`) | `setConsent({analytics, attribution, adUserData, adPersonalization})` (`ConsentState` / `'granted' \| 'denied' \| 'unknown'`, omitted = unchanged) |
| Read consent | `getConsent(): ClikgateConsent` | `getConsent() -> ClikgateConsent` | `getConsent()` (async) |
| Region hint | `setConsentRegion(region: String?)` | `setConsentRegion(_:)` | `setConsentRegion(region)` |
| Firebase forwarding | `enableFirebaseForwarding(FirebaseForwardingOptions)` | `enableFirebaseForwarding(_ options: ClikgateFirebaseForwardingOptions)` | `enableFirebaseForwarding({setUserProperties, logAttributionEvent})` |
| Sales metadata | `attributionMetadata(): Map<String, String>` | `attributionMetadata() -> [String: String]` | `attributionMetadata()` (async) |
| Google on-device measurement | — (iOS only) | `enableGoogleOnDeviceMeasurement()` | `enableGoogleOnDeviceMeasurement()` (no-op on Android) |

`ClikgateConsent`: the four purposes, `region` (the hint, or null) and `required` (bool or null:
whether consent is required for this device, null before the first config with a `consent`
object and without a hint). All of these may be called before `configure`; the values apply from
the first request.

### Consent state

- Stored on the device (prefs / state.json): the four purposes (`granted | denied | unknown`,
  default `unknown`), `updated_at`, the region hint, and `consent_pending_since` (when buffering
  started). Survives relaunches; cleared only by the app.
- Every request body carries the `consent` object (API_CONTRACT "Change 03"); `GET /config` carries
  `region_hint`.
- `setConsent` / `setConsentRegion` with a changed value: store, mark a `/consent` send pending
  (sent once the installation exists, retried like `/identify`), re-evaluate the gate below, and
  refetch `/config` when the region hint changed.

### Is consent required?

1. `config.consent.mode == "not_required"` → no; `"required_everywhere"` → yes.
2. `"required_in_regions"`: with a region hint, yes when the hint is in `required_regions`
   (`EEA` also matches the 30 EEA country codes; `UK` matches `GB`; a country matches itself);
   without a hint, `config.consent.required`.
3. No `consent` object (older server, or no config yet): yes only when the hint is in the default
   regions (`EEA`, `UK`, `CH`); otherwise no. (The backend enforces again on its side.)

A purpose is **allowed** when it is `granted`, or when consent isn't required and it isn't
`denied`.

### The gate (when consent is required and tracking is enabled)

| `attribution` | What the SDK does |
|---|---|
| `granted` | Normal operation. |
| `unknown` | **Buffering.** Referral calls and the Engage request context fail with `consent_required` (API_CONTRACT "SDK-side error codes"). No identifying call: no `/install`, `/open`, `/resolve`, `/goals`, `/identify`, `/push-token`, `/attest`, `/consent`; `GET /config` only, without `Clikgate-Installation-Id`. Goals are queued (oldest dropped above `buffer_max_events`, default 1000; goals older than `buffer_max_days`, default 7, are dropped — "expiry"). Clikgate URLs are delivered to the app locally (URL, path, query parameters as `data`, `isDeferred: false`) and kept (latest 10) for a silent `/resolve` after grant. First-launch signals (install referrer, pasteboard token) are collected and kept on the device. |
| `granted` after `unknown` | **Flush**: `/install` (with the kept launch URL / tokens), then the kept URLs (resolved without delivering them again), identify, push token, and the buffered goals. `consent_pending_since` is cleared. |
| `denied` | **Drop**: the goal queue, kept URLs and kept first-launch tokens are cleared. Before the first `/install`: if `consent.anonymous_counts`, send one `/install-ping` (no installation id header), else nothing. After it: send `/consent` (records the withdrawal) and nothing else. URLs are still delivered locally. Granting later resumes normal operation (with a fresh `/install` if none succeeded). |

`setTrackingEnabled(false)` (opt-out) stays the master switch and wins over consent.

When consent isn't required, nothing is buffered; the purposes still travel in `consent`, and the
backend enforces them (B.3).

Per purpose, on top of the gate:
- **`analytics`** allowed → Firebase forwarding and `app_instance_id`; identity checks (App Attest,
  DeviceCheck, IDFV, Play Integrity) also need it unless `config.consent.identity_checks_basis`
  is `fraud_prevention`.
- **`attribution`** allowed → Android sends `screen` only with this and
  `features.probabilistic_matching` (B.2); the iOS SDK never sends it.
- **`ad_user_data`** denied → no Google on-device measurement info.
- `ad_user_data` / `ad_personalization` are otherwise only passed through in `consent`.

### Google click ids (`gclid`, `gbraid`, `wbraid`)

- Read from the query of every Clikgate URL the app is opened with (app links, universal links,
  custom scheme with `cg_click_id`), and on Android from the Play install referrer string
  (URL-decoded once, split on `&`, first `key=value` per key). Values are trimmed; empty or longer
  than 512 characters are ignored. No other parameters are parsed.
- `/install`: from the launch URL (`source: "deep_link"`), else from the install referrer
  (`source: "install_referrer"`). `/resolve`: from that URL. `/open`: the ids of the last Clikgate
  URL handled since the previous `/open` (cleared after a successful send).

### Change 19: Apple Ads (AdServices) token, LinkedIn and Snap click ids

- **AdServices token (iOS, `features.apple_search_ads`).** Requested with
  `AAAttribution.attributionToken()` (iOS 14.3+) when the first `/install` is actually sent:
  after the consent grant when consent was buffering, not at first launch. Each attempt of that
  `/install` reuses it while it is younger than 24 hours (Apple's validity) and requests a new
  one otherwise (long retries, `Retry-After`). It lives in memory only: never written to the
  SDK's storage, dropped once the install is answered and when consent is denied. Not
  requested when the SDK version is blocked, when consent is required and `attribution` isn't
  granted, or when `attribution` is denied. Later `/install` polls carry no token. There is no
  app-side switch: the dashboard's Apple Ads setting (`apple_search_ads`) decides.
- **IDFV for Redownload linking.** `idfv` is also sent on `/install` when
  `features.apple_search_ads` is on, under the same identity-check consent rule as above (the
  backend links an Apple Ads `Redownload` to the earlier install on that device).
- **LinkedIn `li_fat_id` and Snap `ScCid`.** No new field: they reach the server inside the URLs
  it already reads (`/install` `launch_url`, `/resolve` `url`) and, on Android, inside the Play
  install referrer string, exactly as the link carried them (`ScCid` is case-sensitive). The
  redirect adds them to app links only when the app's `pass_ad_click_ids` names the network and
  only on the organisation's own domains; the server stores them on the click (backend C19-B2).
  The SDKs never strip or rewrite these parameters, also while consent is buffering.

### Version policy

- After each `/config`: `version_status` (or, when absent, own version < `min_supported_version`
  ⇒ deprecated). The SDK's own version is the outermost one (the wrapper's when wrapped).
- `deprecated`: log a warning once per launch ("Clikgate SDK x.y.z is deprecated; update to
  `latest_version`").
- `blocked`: log `blocked_instructions.message` as an error once per launch and restrict calls as
  in API_CONTRACT "Version policy" (calls outside `allowed_calls` that the app makes directly,
  such as referral calls, fail with `sdk_version_blocked`). The restriction lasts until a config without `blocked` (the
  cached config applies offline).

### Firebase / GA4 forwarding (client-side, B.5)

- `enableFirebaseForwarding(options)` turns it on for this process (call it on every launch, e.g.
  next to `configure`). Options: `logAttributionEvent` (default true), `setUserProperties`
  (default true). (Change 22: no event mirroring.)
- Active only when also `config.firebase_forwarding.enabled`, Firebase Analytics is present at
  runtime, tracking is enabled and `analytics` is allowed. Each server switch is ANDed with the
  option of the same name.
- **Detection without a dependency.** Android: reflection on
  `com.google.firebase.analytics.FirebaseAnalytics` (`getInstance(Context)`, `logEvent(String,
  Bundle)`, `setUserProperty(String, String)`, `getAppInstanceId(): Task<String>`). iOS:
  `NSClassFromString("FIRAnalytics")` and the Objective-C selectors `logEventWithName:parameters:`,
  `setUserPropertyString:forName:`, `appInstanceID`. Flutter and React Native call the native SDK
  (their Firebase plugins ship the same native classes). Absent ⇒ a debug log, nothing else.
- **`clikgate_attribution`**, once per installation, when the install attribution is final
  (`attributed` or `organic`, after polling): params `cg_source`, `cg_medium`, `cg_campaign`,
  `cg_channel` (`organic` when organic, else the response's `channel`), `cg_link_id`,
  `cg_match_type`; null values are left out. If forwarding is enabled only later, it is logged
  then.
- **User properties** `cg_first_source`, `cg_first_campaign`, set once with that event.
- **Firebase limits** (Google Analytics, checked 2026-10-22): string parameter values ≤ 100 characters; user
  property values ≤ 36. The SDK truncates longer values.
- **`app_instance_id`**: when `report_app_instance_id`, read from Firebase (Android
  `getAppInstanceId()` task, iOS `appInstanceID`; nil when Firebase's analytics storage consent is
  denied) and sent with `/install` (waiting at most 2 s for it) and with the next `/open` whenever
  it differs from the last value sent.

### `attributionMetadata()` (B.6)

Returns `{"cg_click_id": ..., "cg_link_id": ...}` (only non-null keys) for the customer to put in
Paystack `metadata` / Flutterwave `meta`: the click and link of the most recent Clikgate deep link
that opened the app (`/resolve` match), else the install attribution. Empty when nothing is
attributed, when tracking is disabled, or when consent is required and `attribution` isn't
granted. Synchronous on the native SDKs; no network.

### Identity checks (B.2)

- All identity checks (App Attest included) need identity-check consent as described in
  "Per purpose".
- **iOS:** App Attest (existing), DeviceCheck tokens (`DCDevice.current.generateToken`, iOS 11+,
  `isSupported`; sent as `device_check_token` with `/install` and each `/attest`) and IDFV
  (`identifierForVendor`, `idfv` on `/install`). Both are sent when identity-check consent allows
  (see "Per purpose") and either `features.identity_checks` is on or App Attest is in use. No
  hardware or OS fingerprint signals.
- **Android:** Play Integrity. Standard request (`createStandard` → `prepareIntegrityToken` with
  the cloud project number → `request(setRequestHash(nonce))`) when a project number is known
  (`ClikgateOptions.cloudProjectNumber`, else `features.attestation.android_cloud_project_number`);
  otherwise the classic request (`setNonce(nonce)`). `attestation.request_type` says which.
  The Play Integrity library stays an optional app dependency (detected at runtime).
- The token providers are injectable in every SDK (tests).

### Google on-device conversion measurement (iOS, B.4)

`enableGoogleOnDeviceMeasurement()` before the first launch's `/install` (calling it later has no
effect). On the first launch, when Google's `GoogleAdsOnDeviceConversion` SDK is linked
(`NSClassFromString("ODCConversionManager")`), the SDK calls
`ODCConversionManager.sharedInstance` → `setFirstLaunchTime(<first launch date>)` →
`fetchAggregateConversionInfoForInteraction:ODCInteractionTypeInstallation completion:` (waits at
most 3 s; both nil = not available) and sends a non-empty result as
`google_on_device_measurement.odm_info` with `/install`. Not sent when `ad_user_data` is denied.
Signatures checked against the GoogleAdsOnDeviceConversion 3.7.0 headers on 2026-10-22. No
dependency: the class is looked up at runtime.

### Removing the SDK

Each SDK README has a "Removing the SDK" section (S.1): remove the dependency, `configure` and
every call; remove the platform entries (Associated Domains / intent filters / URL schemes,
Info.plist keys); remove push-token forwarding (uninstall tracking); then mark the app as no
longer tracked in the Clikgate dashboard.

## Change 06 (SDK 1.3.0): goals and private mode

### Public API

| | Android (`Clikgate.`) | iOS (`Clikgate.shared.`) | Flutter (`Clikgate.`) / React Native (`Clikgate.`) |
|---|---|---|---|
| Record a goal | `goal(key: String, options: GoalOptions = GoalOptions())`; `GoalOptions(value: BigDecimal?, currency: String?, reference: String?, isFirst: Boolean?)` | `goal(_ key: String, value: Decimal? = nil, currency: String? = nil, reference: String? = nil, isFirst: Bool? = nil)` | `goal(key, {value, currency, reference, isFirst})`; `value` is a `num`/`number` or a numeric `String` (`"1500.50"`) |

Before `configure`: Android validates the goal and queues it until `configure`; iOS
(and the bridges on iOS) fail with `not_configured`. Android and iOS take decimal
types only (`BigDecimal` / `Decimal`); Flutter and React Native pass the value to the native SDK as
a **string**, never as a double. Dart and TypeScript numbers are converted with their shortest
round-trip representation, so pass a string for amounts with many digits (`0.1 + 0.2` is
`0.30000000000000004`: 17 significant digits, rejected).

### Validation (local, before queueing)

Rejected with `invalid_argument` (and logged as an error, without the reference or the value):
- `key` not matching `^[a-z][a-z0-9_]*$` with 2–40 characters (`param: "goal"`);
- `value` negative, not a plain decimal (NaN, infinity, exponent left after conversion, empty
  string), or more than 15 significant digits (`param: "value"`);
- `currency` not 3 uppercase letters (`param: "currency"`);
- `reference` empty / blank or longer than 128 characters (`param: "reference"`).

The SDK doesn't check the currency's decimal places or the goal's `value_mode` (only the server
knows the goal); those come back as per-item rejections and are dropped.

Wire value: the decimal's plain string with trailing fractional zeros removed (`BigDecimal("2E+6")`
→ `"2000000"`, `Decimal(string: "1500.50")` → `"1500.5"`, `0` → `"0"`). Parsing it back gives the
same decimal.

### Queueing, delivery and idempotency

- `goal()` assigns `occurred_at = now`, the reference (the app's, else a new UUIDv4) and `click_id`
  (latest matched deep link, else the install's click; the `attributionMetadata()` value) at call
  time, and appends the item to the persisted **goal queue** (limits, flush triggers, background flush and
  retry policy above).
- Flush sends the queue in order to `/goals` (each batch ≤ `max_batch_size`), one request at a time.
- **Idempotent by reference:** a `goal()` whose `(key, reference)` is already in the queue is
  ignored (debug log); the server dedupes everything else by `(goal, reference)` (`duplicates`).
  Retries resend the same item.
- **`Idempotency-Key`** (change 09, X.E15): one random UUIDv4 per `/goals` request,
  reused by that request's retries; a later flush is a new request with a new key. Never a hash
  of the reference.
- Success: `accepted + duplicates` and `rejected` items leave the queue (rejections are logged as
  a count with their codes). `422` for the whole batch, a `404` that isn't `installation_unknown`
  (a server without `/goals`) or a `feature_disabled` body: the batch is dropped with a warning.
  Network errors / 408 / 429 / 5xx: kept and retried.
- Version policy `blocked` without `goals` in `allowed_calls`: queued goals are dropped and refused on the
  device (`sdk_version_blocked`).
- Never logged: references, values, or the content of rejected fields.

### Consent (change 03)

The consent gate for goals:
- consent not required, or `attribution` granted: sent normally;
- required and `attribution` `unknown`: buffered in the queue (counted in
  `buffer_max_events`, expired after `buffer_max_days`), sent after grant (once `/install`
  succeeded), with the `occurred_at` of the `goal()` call;
- required and `denied`: dropped with the rest of the buffer; later `goal()` calls are dropped;
- opt-out (`setTrackingEnabled(false)`) clears them;
- `consent` travels in the `/goals` body.

### Private mode

- Read from `/config` `private_mode` (cached with the config; absent ⇒ off). The cached value
  applies offline and from the start of the next launch.
- On: `identifyUser()`'s customer ID is dropped on the device (not stored, not sent; a pending identify is
  discarded); one warning per launch **in debug builds only** (Android:
  `ApplicationInfo.FLAG_DEBUGGABLE`; iOS: the SDK compiled in the Debug configuration,
  `#if DEBUG`; Flutter / React Native: the native SDK's check). Release builds log nothing about it.
- `goal()` is unchanged (its fields are all on the private-mode allow-list).
- Unchanged in private mode: installs, opens, deep links, consent, push token / uninstall checks,
  `attributionMetadata()`, and Firebase forwarding (local to the app's own Firebase).
- There is no user-properties API in the core SDKs, so nothing else is dropped.

## Change 06 (SDK 1.4.0): shared-domain browser fallback

Shared platform domains: `ciz.to`, `clk.ng`, `clkg.to`, `dev.ciz.to` (API_CONTRACT.md "Shared
platform domains"; one constant per native SDK, checked against `fixtures/shared_link_domains.json`).

- Trigger: a direct `/resolve` (a URL the app was opened with or passed to `handle(url)`) answers
  `matched: false`, the URL is `http(s)` and its host is a shared domain, and
  `platformDomainBrowserFallback` is on (default). Silent re-resolves after a consent grant (the URL
  was already routed locally) never open a browser. While consent is buffering / denied or the
  version is blocked, no `/resolve` happens, so the link is routed locally as before.
- First launch: a shared-domain launch URL goes with `/install` as `launch_url`; when the install
  response carries no `deep_link` (and isn't `pending`), the SDK calls `/resolve` for it (iOS did
  this for every launch URL already) and the rule above applies.
- Action: open the original URL in an in-app browser. iOS: `SFSafariViewController` presented from
  the top view controller of the key window (no key window ⇒ nothing opens, no event).
  Android: Custom Tabs in an explicit browser package (the default browser if it supports Custom
  Tabs, else another one that does; the `android.support.customtabs.extra.SESSION` protocol extra,
  no `androidx.browser` dependency), else a plain `ACTION_VIEW` intent to an explicit browser
  package; never this app's package. Started from the activity of the last `handleIntent`, else
  the application context with `FLAG_ACTIVITY_NEW_TASK`. The library manifest adds the
  `<queries>` entries for Android 11+ package visibility. No browser ⇒ warning, no event.
- Never `UIApplication.open(_:)` / `openURL` or an implicit view intent (they can resolve to this
  app's own Universal Link / App Link and loop).
- The deep-link callback does not fire. When the browser opened, the SDK emits a **browser
  handoff** `{url, host}` (the URL as it opened the app; the shared domain, lowercased).
- Logs name the host only, never the URL.

| | Android (`Clikgate.`) | iOS (`Clikgate.shared.`) | Flutter (`Clikgate.`) | React Native (`Clikgate.`) |
|---|---|---|---|---|
| Option (default `true`) | `ClikgateOptions(platformDomainBrowserFallback = …)` | `ClikgateOptions(platformDomainBrowserFallback:)` | `configure(platformDomainBrowserFallback: …)` | `configure({platformDomainBrowserFallback})` |
| Event | `onBrowserHandoff(BrowserHandoffListener?)` → `ClikgateBrowserHandoff(url: String, host: String)` | `NotificationCenter` notification `Clikgate.browserHandoffNotification` (main thread), `object` = the link's `URL` (host = `url.host`) | `onBrowserHandoff` (`Stream<ClikgateBrowserHandoff>`) | `onBrowserHandoff(listener)` → unsubscribe; `ClikgateBrowserHandoff {url, host}` |
| Buffering before a listener | latest 10 (like deep links) | none: observe early (iOS core size budget) | latest 10 (native plugin + Dart) | latest 10 (native module + JS) |

## Change 09 (SDK 1.5.0, React Native 1.6.0): consistency fixes

- **Install consent (X.E23):** `/install` sends the four-purpose consent object like every other
  call and no longer sends `tracking_allowed`. The opted-out first install sends every purpose
  `denied` (API_CONTRACT.md "Change 09 additions").
- **Goal idempotency (X.E15):** one random `Idempotency-Key` per request, reused by its retries
  (see "Queueing, delivery and idempotency" above). The backend now honours it on `/goals`.
- **Money helper (X.E10):** removed in Change 22 with the app-event method it served.
- **iOS `Clikgate.shared.goal(...)` (X.E17):** the documented iOS call (it is the API since 1.3.0).
- **Pasteboard (X.E13):** off by default on iOS and in both wrappers (`pasteboardMode` `off`).
- **No trophy, challenge or progress data (D8)** in any SDK, core or Engage.
- **App link subdomains (N.1):** apps declare `{link_subdomain}.ciz.to` (release) and
  `{link_subdomain}.dev.ciz.to` (debug) plus custom domains, never a shared domain; see
  `docs/SETUP_COMMAND.md`.

## Change 10 (folded into SDK 1.5.0, React Native 1.6.0): deep links on every plan

- **Deep-link-only mode** (`/config` `features.app_attribution: false`, `features.deep_linking: true`; Free,
  Starter, or attribution switched off): deep links work exactly as before, direct and deferred.
- `goal()` validates as usual (invalid input still errors), then, when `app_attribution` is off
  (cached config, or a `feature_disabled` answer since the last config fetch), logs one warning per launch
  ("app attribution is switched off") and returns without queueing (refused `feature_disabled`). No error reaches the app.
- Flush: while `app_attribution` is off, the queue is dropped without a network call. A
  `200 {"accepted": false, "reason": "feature_disabled"}` body on `/goals` drops that batch (never
  retried), marks `app_attribution` off and refreshes the config in the background (a fresh config is
  authoritative again, so an upgrade to Growth switches it back on without a relaunch).
- `/install` at the monthly deferred deep link cap answers `deep_link: null`: the normal "no deferred link"
  result (no callback, no error, no retry). Attribution in this mode is always `organic`.
- `deep_linking` joins the catalogue defaults that count as on before the first config fetch.
- Free app subdomains: `yourapp.clk.ng` (release builds) and `yourapp.dev.ciz.to` (debug builds), from
  `app_link_domains` (`docs/SETUP_COMMAND.md`). Not shared domains.

## Change 12 (folded into the unreleased versions): one `goal()` method, Payment goals

`payment()` (Change 11) is removed on every platform, with no deprecation period (nothing was released). An app
reports a payment with `goal()` on a goal whose kind is **Payment** in the dashboard; the kind is never in the call.

### Public API

| | Android (`Clikgate.`) | iOS (`Clikgate.shared.`) | Flutter (`Clikgate.`) | React Native (`Clikgate.`) |
|---|---|---|---|---|
| Send a goal | `goal(key, value?, currency?, reference?, provider?, isFirst?, onResult?)` | `goal(_:value:currency:reference:provider:isFirst:completion:)` | `Future<GoalResult> goal(key, {value, currency, reference, provider, isFirst})` | `goal(key, {value, currency, reference, provider, isFirst}): Promise<GoalResult>` |
| Result | `GoalResult(status: GoalStatus, reason, goalKind: GoalKind?, valueIgnored)` | `ClikgateGoalResult` | `GoalResult` | `GoalResult` |
| Provider | `Provider.PAYSTACK`, `Provider.fromString("…")` | `.paystack`, `ClikgateProvider.fromString(_:)` | `ClikgateProvider.paystack`, `ClikgateProvider.fromString(…)` | `ClikgateProvider.Paystack`, `providerFromString(…)` |

Example: `Clikgate.goal("purchase", reference = "T123456", provider = Provider.PAYSTACK)`. The provider type is
generated from `shared/providers.json` (`scripts/generate_providers.py`; CI runs `--check`). The wrappers pass the
provider's string to the native SDK, which validates it (a malformed key is refused with `invalid_argument`).

### Behaviour

- Validation is as in Change 06, plus `provider` (a provider key). Invalid input is refused locally: the result is
  `refused` / `invalid_argument` and an error line is logged (never the reference or the value).
- Queueing, consent gate, opt-out, deep-link-only mode, batching, retries and idempotency by `(key, reference)`
  are unchanged; the item carries `provider` when given. A second `goal()` with a queued `(key, reference)` is
  ignored as before (Android: its listener gets the queued goal's result; iOS: answered at once `waiting` /
  `already_queued`).
- The result comes from `/goals` `results[index]` (API_CONTRACT "Change 12"); batch drops and local refusals map
  to `refused` with a reason code. Results are delivered on the main thread, at most once per call.
- The SDK never decides a goal's kind and never drops a value itself: the server ignores a value sent for a
  Payment goal and says so (`valueIgnored`).
- **Test mode** (SDK key `cg_sdk_test_…`): a warning line `"<key> is a Payment goal: waiting for confirmation"`
  when a Payment goal waits, and one when its value was ignored (Android: a separate line; iOS: the same line ends
  with "; its value was ignored", for size).
- Matching, scoring and attribution stay on the server; the SDKs only send the goal.

## Change 13 (folded into the unreleased versions): share a link, a version per app

`ClikgateEngage.share.link(url, message?, app?, shareUrls?)` and `share.referralLink(link, message?,
app?)` on all four platforms (Flutter / React Native through the Engage package's native bridge to the
native Engage add-on, one implementation per OS). Spec: Change 13 S.1; backend: `POST /v1/share-events`
(API_CONTRACT.md "Change 13 additions").

- **The link per app.** For each app in the internal table (`shared/share_targets.json`, generated into
  each platform by `scripts/generate_share_targets.py`; never listed in docs) the link gets that app's
  short ending: on the last path segment (`/summer` → `/summer-<ending>`), or after the referral code
  when the code is a query value (`/invite?ref=ADA42-<ending>`). An ending the link already has is
  replaced; apps without an ending, "Copy" and unknown apps get the plain link; non-http(s) links and
  links with no path are shared unchanged. `shareUrls` (the link's `share_urls` from the Clikgate API,
  keyed by app) win over the computed URL. Test cases: `fixtures/share_cases.json`.
- **Android.** `Intent.createChooser(ACTION_SEND text/plain, title, IntentSender)` with
  `EXTRA_REPLACEMENT_EXTRAS` (per-package `EXTRA_TEXT`; packages in the table). The callback is an explicit,
  mutable broadcast `PendingIntent` to Engage's non-exported `ClikgateShareReceiver`; it reads
  `EXTRA_CHOOSER_RESULT` on Android 15+ (copy → `other`) and `EXTRA_CHOSEN_COMPONENT` otherwise. With
  `app`: `ACTION_SEND` with each of the app's packages, then `ACTION_SENDTO smsto:` / `mailto:` for SMS
  and email, then the chooser. No `<queries>` (nothing checks installation).
- **iOS.** `UIActivityViewController` with one `UIActivityItemSource` that returns the text per
  `activityType` (`.message` → sms, `.mail` → email, otherwise the app whose bundle ID the type starts
  with). The completion handler records the share when `completed` is true and a type is set ("share
  started": some apps report completed after a cancel). With `app`: `whatsapp://send?text=` (only when
  `canOpenURL` allows it), `https://t.me/share/url`, `https://x.com/intent/tweet`, `mailto:`; else the sheet.
- **Recording.** `POST /v1/share-events` `{url, app}` with the SDK key, sent with the core's request
  context (so nothing when not configured, opted out or before the first install); no feature switch,
  no retry beyond Engage's one network retry, nothing queued, failures dropped, the read cache is kept.
  A referral link is recorded by the referral URL that was shared (`/r/CODE-…`, `?ref=CODE-…`; the API resolves it).
- **Returns** `true` when `app` itself opened, `false` when the menu was shown; `share_unavailable`
  when nothing can show it.

## Change 14 (folded into the unreleased versions): `identifyUser` replaces `identify`; goal labels

Spec: Change 14 S.1 (and B.4/B.5). Wire format: API_CONTRACT.md "Change 14 additions".

| | Android | iOS | Flutter | React Native |
|---|---|---|---|---|
| Call | `Clikgate.identifyUser(label = …, customerId = …, identityToken = …)` | `Clikgate.shared.identifyUser(label:customerId:identityToken:)` | `Clikgate.identifyUser(label: …, customerId: …, identityToken: …)` | `Clikgate.identifyUser({ label, customerId, identityToken })` |
| Goal label | `goal(…, label = "Ada")` | `goal(…, label: "Ada")` | `goal(…, label: 'Ada')` | `goal(key, { label: 'Ada' })` |

- **Arguments.** All optional. Leaving `customerId` out keeps the stored one; `null` / `nil` clears it (logout, as
  the old `identify` with null did). Nothing to send is a no-op (no request). `label`: 1–80 characters (Android trims; iOS
  counts UTF-16 units and leaves trimming to the server), `""` clears it; a longer label is not sent (error log), the
  rest of the call goes ahead. `identityToken` as before (referral programs with `require_identity_token`).
- **Sending.** One `/identify` per change, queued and retried like before: the stored customer ID and token, plus the
  label not sent yet (Android keeps it in SharedPreferences, iOS in the state file), sent once. `label_ignored:
  "plan"` in the answer logs one debug warning ("labels need Growth"); the label is dropped from the queue either way.
- **Private mode.** The customer ID and token are always dropped on the device (one warning per launch); the label
  only when config `allow_labels` is false (one debug warning). With `allow_labels` true a label-only `/identify` is
  sent (no `customer_user_id` key). Goals drop `label` the same way. A pending identify from before private mode
  loses its customer ID and token and keeps an allowed label.
- **`isFirst`** is unchanged (sent, never decides a new customer on its own; the docs say to send it from the server).
- **Wrappers.** Flutter: method `identifyUser` `{label, customerId?, identityToken}` (the `customerId` key absent =
  keep); `goal` gains `label`. React Native: TurboModule method `identifyUser` (same map); `goal` gains `label`.
  `identify` is removed from both channels.
- **Web script:** `clikgate.identifyUser({ label, customerId })` → `POST /v1/web/identify` with the stored click ID
  (labels only when `/v1/web/config` says `allow_labels`); `goal(key, { label })` likewise.

## Change 17 (folded into the unreleased versions): link gates on app opens (R.2)

Wire format: API_CONTRACT.md "Change 17 additions". Applies to a direct `/resolve` (a URL the app was opened with
or passed to `handle(url)`) and to the first-launch `/resolve` of a launch URL; silent re-resolves after a consent
grant (`deliver: false`) open nothing and deliver nothing.

| `status` | Android | iOS | Flutter / React Native |
|---|---|---|---|
| `password_required` | `web_url` in the browser app itself: explicit browser package, plain `ACTION_VIEW`, no Custom Tabs, never this app (`BrowserOpener.openExternal`) | `UIApplication.shared.open(web_url)` (Safari); the same URL at most once per 30 s, so a Universal Link handed straight back can't loop | native |
| `blocked` | `onDeepLink` gets `ClikgateDeepLink(url, path = null, data = {}, isDeferred = false, clickId = null, matchType = null, link = null, referral = null, blockMessage = text)` | `onDeepLink` gets `ClikgateDeepLinkResult` with `blockMessage` set, the opened `url`, everything else empty / nil | the `blockMessage` key on the deep-link map (PLATFORM_CHANNEL.md) |

- First launch: `/install` carries the same `status` / `web_url` / `block_message` for the launch URL. Android
  handles a gated install answer exactly like a gated `/resolve` answer (no second `/resolve`); iOS drops the
  install `deep_link` when `status` is gated and `/resolve`s the launch URL as before. A launch URL already
  delivered locally while buffering for consent opens and delivers nothing more.
- Nothing else changes for `matched` (A/B: the server's version path) and `no_match`.
- No browser handoff event for password links (that event stays for other organisations' shared-domain links).
  Logs name the host only.
- Consent buffering, denied consent and a blocked SDK version make no `/resolve` call, as before: the URL is
  delivered locally (its own path and query, never a destination), so no gate is skipped.
- iOS core size: the change adds 3.4 KB; the JSON readers (`str`, `bool`, `obj`, `int`, `int64`, one shared
  number check) are no longer inlined at every call site, which saves 11.4 KB (docs/DECISIONS.md "Change 17").

## Change 20 (folded into the unreleased versions): `deeplink_handled` for the live check

Wire format: API_CONTRACT.md "Change 20 additions".

- **When:** right after the SDK hands a matched Clikgate deep link to the app (direct from `/resolve`, deferred
  from `/install`), only with a test key (`cg_sdk_test_`) or when that answer says `debug_view: true`.
  Not for gated links (password / blocked), handoffs, unmatched links or links delivered locally while consent is
  buffering or after opt-out.
- **What:** `{path, is_deferred}`; the path is cleaned on the device (no query or fragment; ID-like, email and
  phone segments → `:id`; cases in `fixtures/deeplink_path_cases.json`). The app's own deep-link result is
  unchanged (it still gets the full path and query).
- **How:** a separate fire-and-forget call (`POST /v1/sdk/deeplink-handled`): not queued, not an event, not
  metered, one retry. Android: `DeepLinkPath.kt`, `Core.reportHandled`; iOS: `DeepLinkPath` (`Rules.swift`, on UTF-8 bytes for size),
  `ClikgateCore.reportHandled`. Flutter and React Native: nothing in Dart / TypeScript (the native SDKs send it).
- **No public API change.**

## Change 21 (SDK 1.5.1, React Native 1.6.1): one tap is one click, X `twclid`

- **Open payloads (S.1).** Every platform already sent what the server needs to count existing-user opens: direct
  App Link / Universal Link opens go to `/resolve` with the URL as opened, redirect opens carry the redirect's
  `cg_click_id` inside that URL, and every call has `Clikgate-Installation-Id`. Flutter and React Native hand URLs to
  the native SDK unchanged. Contract: API_CONTRACT "Change 21 additions".
- **One tap, one click (R.2), the fix in this release.** After `/install` answered `status: "matched"` for the launch
  URL, the SDK no longer `/resolve`s the same URL (the server would have recorded a second click):
  - iOS (`handleInstallResponse`), when the install answer has no deep link: `/resolve` with `click_id` (the click
    the install recorded), or local delivery when attribution is off and there is no click ID;
  - Android (`sendInstall`): the shared-domain re-check `/resolve` is skipped when the install matched.
  Without `status` (older servers) nothing changes.
- **X `twclid` (R.25).** No new field: it travels in the URLs and the Play referrer like `li_fat_id` and `ScCid`,
  never stripped or rewritten, also while consent is buffering.
- **No public API change.**

## Change 22: one `goal()` method, `received`, the installation ID

Spec: `docs/spec/clikgate-change-22-goals-identity-uninstalls-banners-reports.md` S, I.7, R.5, R.9, R.26.
Contract: API_CONTRACT.md "Change 22 additions".

- **One method.** The app-event method, its validation, its money helper, Firebase event mirroring
  (`mirrorEvents` / `eventNameMap`) and the iOS SKAdNetwork / AdAttributionKit conversion-value updates (R.5) are
  removed on every platform. `goal()` is the only method; its names appear in the dashboard's "Seen from your app
  and website" and count once ticked. The app-event endpoint, schemas and fixtures are gone.
- **Persisted queue on upgrade.** An app-event item a development build left in the queue (no `goal`) is dropped on
  the next flush without a network call (debug log); the goals around it are sent.
- **`received` (R.9).** A `results[]` item with `status: "received"` (reason `not_counted_yet`: the name isn't
  ticked yet; or `goal_archived`) is a success: the item leaves the queue, is never retried, and the app gets
  `GoalStatus.RECEIVED` (Android), `.received` (iOS), `GoalStatus.received` (Flutter), `GoalStatus.Received`
  (React Native). Unknown statuses stay refusals.
- **Version policy.** The default calls of a blocked SDK no longer include `events`; goals go only when
  `allowed_calls` lists `goals` (otherwise refused on the device with `sdk_version_blocked`).
- **Installation ID (I.7, R.26).** Async everywhere, never blocking the main thread:

| Android | iOS | Flutter | React Native |
|---|---|---|---|
| `suspend fun getInstallationId(): String?`; `getInstallationId(InstallationIdListener)` (main thread) | `func installationId() async throws -> String?`; `installationId(completion:)` (main queue) | `Future<String?> getInstallationId()` | `getInstallationId(): Promise<string \| null>` |

  - The value is the installation's random UUID, the one sent as `Clikgate-Installation-Id`; new after a reinstall
    (iOS keeps reporting the previous one as `keychain_previous_installation_id` on `/install`).
  - `null` when tracking is off: opted out, consent denied or not given yet where it's required, or deep-link-only
    mode (`app_attribution` off, cached config or a `feature_disabled` answer).
  - On a first launch it waits for the first config answer (one attempt; at most about 5 s) so the consent and
    attribution switches are known; offline it answers at once. Android waits for `configure` when called before
    it; iOS throws `not_configured` (the Flutter and React Native bridges pass that through on iOS).
  - Not personal data; allowed in private mode. Never logged in full.
  - Identity Path B: the app sends it to its own server at sign-in and at every signed-in app open; the server calls
    `identifyUser({appId, installationId, customerId, label?})` (`POST /v1/people/identify`). Path A (the default)
    stays `identifyUser(customerId, identityToken)` with a token from the server SDK's `createIdentityToken`. Guide:
    https://clikgate.com/docs/identify-users

## Change 23: "Allow unknown goal names" off (`unknown_goal`)

Spec: `docs/spec/clikgate-change-23-unknown-goals-goal-groups.md` S, R.1, R.9. Contract: API_CONTRACT.md "Change 23
additions".

- `refused` with `unknown_goal` or `goal_archived` (a `results[]` item, or a whole-request `422` whose body is the
  result `{status: "refused", reason}`) is final: removed from the queue, never retried, delivered once as
  `refused` with the reason.
- No name checks and no cached setting on the device: a name refused once is sent again the next time it is used.
- Debug builds only: ``Goal `{name}` isn't set up in Clikgate`` (warning level, so it shows with the default log
  level). The goal name only. Release builds stay silent.
- Tests per platform: Android `StrictGoalNamesTest`, iOS `StrictGoalNamesTests`, Flutter
  `strict_goal_names_test.dart`, React Native `strictGoalNames.test.ts`.
