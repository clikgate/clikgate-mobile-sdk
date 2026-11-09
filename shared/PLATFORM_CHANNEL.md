# Bridge contract (Flutter platform channels, React Native native modules)

Flutter's Android side (Kotlin) and iOS side (Swift) implement exactly these methods, so
the Dart layer is identical on both platforms. The React Native modules use the same
method names, argument maps and result maps (RN: `NativeModules.Clikgate.<method>` returning
promises; deep links on `NativeEventEmitter` event `ClikgateDeepLink`).

Map keys are **camelCase** on the bridge (the native SDK converts from the API's
snake_case). Values are only JSON-compatible types: null, bool, int (64-bit), double,
String, List, Map<String, Object?>.

## Channels (Flutter)

- `MethodChannel("com.clikgate/sdk")`
- `EventChannel("com.clikgate/deep_links")` — each event is a DeepLink map. The native side
  buffers events that arrive before Dart listens (latest 10) and flushes them on
  `onListen`. The Dart side additionally buffers until the first app-level listener is
  attached (`Clikgate.onDeepLink` is a broadcast stream that replays buffered events to
  its first subscriber).

## Methods

| Method | Arguments | Result |
|---|---|---|
| `configure` | `{sdkKey: String, linkDomains: List<String>, apiBaseUrl: String?, logLevel: "verbose"\|"debug"\|"info"\|"warn"\|"error"\|"none", environment: "production"\|"sandbox", attestation: "off"\|"ifAvailable", pasteboardMode: "off"\|"automatic"\|"pasteControlOnly" (iOS only), waitForATT: bool (iOS only), deferredDeepLinkTimeoutMs: int, wrapperVersion: String}` | `null` |
| `getAttribution` | `{}` | Attribution map |
| `identify` | `{customerUserId: String?, identityToken: String?}` | `null` |
| `setTrackingEnabled` | `{enabled: bool}` | `null` |
| `setPushToken` | `{token: String, provider: "fcm"\|"apns"}` (for `apns` the token is the hex device token) | `null` |
| `handleUrl` | `{url: String}` | `bool` (true if it's a Clikgate URL) |
| `referrals.applyCode` | `{programId: String, code: String}` | Referral map |
| `referrals.referredBy` | `{}` | ReferredBy map |
| `sdkVersion` | `{}` | String (native SDK version) |

`configure.linkDomains` is passed to the native SDK unchanged; the native SDK normalises it and adds
the cached server `link_domains` (API_CONTRACT.md, `/config`). The bridge exposes no config, so
connected domains add no method or result map.

`isClikgateMessage` is **not** a channel method; Dart implements it so it works in
background isolates without the plugin registered.

## Result maps

Attribution:
```
{status: "pending"|"attributed"|"organic", matchType: String?, confidence: double?, clickId: String?,
 clickedAt: String? (ISO 8601), isReinstall: bool, installId: String?, link: Link?}
```

DeepLink:
```
{url: String?, path: String?, data: Map, isDeferred: bool, clickId: String?, matchType: String?,
 link: Link?, referral: Referral?, blockMessage: String?}
```

`blockMessage` (Change 17 R.2): set when `/resolve` answered `blocked`; the app shows it and doesn't route
(`path`, `clickId`, `link` and `referral` are null). Older native SDKs leave the key out (read as null).

Link: `{id: String, kind: "standard"|"referral", externalReference: String?, campaignId: String?, metadata: Map}`

Referral:
```
{referralId: String, programId: String, status: String, source: String?, referrerId: String,
 referrerDisplayName: String?, createdAt: String?}
```

ReferredBy: `{referred: bool, referral: Referral?}`

## Errors

Failures are reported as Flutter `PlatformException` / RN promise rejection with:
- `code`: the backend error code (`code_not_found`, `already_referred`, `window_expired`,
  `self_referral`, `identity_required`, `not_identified`, `program_paused`, ...), or SDK codes:
  `not_configured`, `network_error`, `opted_out`, `invalid_argument`, `timeout`,
  `install_pending` (referral call before `/install` finished).
- `message`: human-readable.
- `details`: `{status: int?, param: String?}`.

Dart maps these to `ClikgateException(code, message, status, param)`.

## Native lifecycle hooks the plugins install

- Android: the plugin implements `ActivityAware` + `PluginRegistry.NewIntentListener`, calls
  `Clikgate.handleIntent(activity, activity.intent)` on attach and on every new intent.
- iOS: the plugin registers as an application delegate (`addApplicationDelegate`) and
  forwards `application(_:continue:restorationHandler:)` and `application(_:open:options:)`
  to `Clikgate.shared.continue(userActivity:)` / `handle(url:)`, and
  `application(_:didReceiveRemoteNotification:fetchCompletionHandler:)` to
  `handleRemoteNotification` (calling the completion handler with `.noData` when it
  returns true). Apps that use a custom `UISceneDelegate` must forward
  `scene(_:continue:)` and `scene(_:openURLContexts:)` themselves (documented in the
  Flutter integration guide).

## v3 methods

| Method | Arguments | Result |
|---|---|---|
| `isFeatureEnabled` | `{key: String}` | `bool` |

New error code: `feature_disabled` (details `{feature}`; native error types expose it as an optional
`feature` property, filled from the response or, for client-side no-ops, from the method's feature).

## Engage split (spec v3 new edition, 0.4 / 17A)

The bridges carry **core only**. Referral links and stats, leaderboards, promo codes and share
helpers live in the Engage add-ons (`clikgate_engage`, pure Dart; `@clikgate/react-native-engage`,
pure TypeScript), which call `/v1/sdk/*` themselves over HTTP (API_CONTRACT.md, snake_case JSON),
using the request context the core hands out. The bridge methods `referrals.createLink`,
`referrals.myStats`, `referrals.shareToWhatsApp`, `leaderboards.top` / `me` / `aroundMe` /
`setOptOut` and `codes.redeem` (RN `referralsCreateLink`, `referralsMyStats`,
`referralsShareToWhatsApp`, `leaderboards*`, `codesRedeem`) and their ReferralLink, ReferralStats,
LeaderboardPage, MyRank and Redemption maps are removed.

Two internal methods serve the Engage packages (not part of the app-facing API):

| Method | Arguments | Result |
|---|---|---|
| `getRequestContext` | `{}` | RequestContext map |
| `reportServerError` | `{code: String, feature: String?}` | `null` |

(Same names on React Native, which has no dot to drop.)

RequestContext:
```
{installationId: String, sdkKey: String, environment: "production"|"sandbox", apiBaseUrl: String,
 identityToken: String?, customerUserId: String?,
 sdkVersion: String       // exact Clikgate-SDK-Version header value of the wrapper, e.g. "flutter/1.0.0"
 nativeSdkVersion: String?} // Clikgate-SDK-Native-Version value, e.g. "android/1.0.0"
```

`getRequestContext` behaves like the old referral calls before their request: it fails with
`not_configured`, `opted_out`, `invalid_sdk_key` / `sdk_disabled` (gates), or `install_pending`
(Android waits up to 10 s for the first `/install`; iOS fails at once while it hasn't completed),
sends a pending `/identify` first, and then resolves with a snapshot (callers fetch a fresh one per
call, since `identify` changes the token and user id).

`reportServerError` lets the core react to what Engage received: `feature_disabled` (with `feature`)
switches that feature off in memory and refreshes `/config` in the background, exactly like a core
feature call; `invalid_sdk_key`, `sdk_disabled` and `installation_unknown` apply the core's global
error rules; other codes are ignored. It never fails.

The native SDKs expose the same as internal API: Android `@ClikgateInternalApi`
`Clikgate.requestContext(callback)` / `awaitRequestContext()` / `reportServerError(code, feature)`
(`ClikgateRequestContext`); iOS `@_spi(ClikgateEngage)` `Clikgate.shared.requestContext()` /
`reportServerError(code:feature:)` (`ClikgateRequestContext`). The native Engage modules
(`com.clikgate:clikgate-engage`, `ClikgateEngage`) use them directly.

## Change 03 methods (SDK 1.2.0)

| Method | Arguments | Result |
|---|---|---|
| `setConsent` | `{analytics: String?, attribution: String?, adUserData: String?, adPersonalization: String?}` (each `"granted"\|"denied"\|"unknown"`; null or missing = unchanged) | `null` |
| `getConsent` | `{}` | Consent map |
| `setConsentRegion` | `{region: String?}` (`EEA`, `UK` or an ISO 3166-1 alpha-2 code; null clears) | `null` |
| `enableFirebaseForwarding` | `{logAttributionEvent: bool, setUserProperties: bool}` | `null` |
| `attributionMetadata` | `{}` | `Map<String, String>` (`cg_click_id`, `cg_link_id`; empty map when none) |
| `enableGoogleOnDeviceMeasurement` | `{}` | `null` (Android: no-op) |

Consent map: `{analytics: String, attribution: String, adUserData: String, adPersonalization: String,
region: String?, required: bool?}`.

Invalid values (an unknown state string, a malformed region) fail with `invalid_argument` and
`details.param` set to the argument name. These methods may be called before `configure` (Android
queues them; iOS and the bridges keep them and apply them in `configure`).

`configure.pasteboardMode` (iOS) now defaults to `"off"` in both wrappers (was `"automatic"`).

New SDK error codes (rejections of `referrals.*` and `getRequestContext`): `consent_required`
(consent required, `attribution` not granted) and `sdk_version_blocked` (version policy).

## Change 06 methods (SDK 1.3.0)

| Method | Arguments | Result |
|---|---|---|
| `goal` | `{key: String, value: String?, currency: String?, reference: String?, isFirst: bool?}` | `null` (Change 12: gains `provider` and returns the goal result, below) |

`value` always crosses the bridge as a **decimal string** (`"2000000"`, `"1500.50"`), never as a
double: Dart / TypeScript convert numbers with their shortest representation first (and reject
NaN, infinity and numbers they print with an exponent). The native SDK parses it into
`BigDecimal` (Android, `Clikgate.goalFromWrapper`) / validates and normalises it (iOS,
`goal(_:decimalString:...)`). Validation failures are `invalid_argument` with `details.param` =
`goal`, `value`, `currency` or `reference`. Before `configure`, Android validates and
queues the goal, iOS fails with `not_configured`.

Private mode (config `private_mode`) is handled entirely inside the native SDKs; the bridges have
no new method for it.

## Change 12: `goal` returns a result, `payment` removed

The `payment` method is removed (both bridges, both native plugins). `goal` changes:

| Method | Arguments | Result |
|---|---|---|
| `goal` | `{key: String, value: String?, currency: String?, reference: String?, provider: String?, isFirst: bool?}` | `{status: "counted" \| "waiting" \| "refused", reason: String?, goalKind: "standard" \| "payment" \| null, valueIgnored: bool}` |

- `provider` is the wire value of the wrapper's provider type (`ClikgateProvider.paystack.value` /
  `ClikgateProvider.Paystack`): `^[a-z][a-z0-9_]{1,29}$`, checked by the server (`unknown_provider`). There is
  never a goal kind in the arguments.
- The result arrives when the native SDK has the server's answer for this goal (it stays queued offline; the
  channel / promise stays pending). It is never an error: invalid input, `not_configured`, opt-out, consent
  denied, deep-link-only mode and server rejections all resolve `status: "refused"` with the code in `reason`.
  A bridge-level failure (missing `key`) is still an `invalid_argument` error; the Dart and TypeScript `goal()`
  turn any error into a refused result, so `goal()` never throws.
- Native: Android `Clikgate.goalFromWrapper(key, value, currency, reference, provider, isFirst, onResult)` (the
  listener gets a `GoalResult`; the Flutter plugin answers on the main thread), iOS
  `Clikgate.shared.goal(_:decimalString:currency:reference:providerKey:isFirst:completion:)` (the completion gets
  a `ClikgateGoalResult`). `status` / `goalKind` cross the bridge as their wire strings.
- Unknown `status` values decode as refused; unknown `goalKind` values as null.

## Change 06: browser handoff (SDK 1.4.0; Flutter 1.4.0, React Native 1.5.0)

- `configure` gains `platformDomainBrowserFallback: bool` (absent ⇒ `true`), passed to the native
  option of the same name.
- A browser handoff (SDK_BEHAVIOUR.md "Change 06 (SDK 1.4.0)") travels on the **deep-link event
  stream** (Flutter `EventChannel("com.clikgate/deep_links")`, React Native event
  `ClikgateDeepLink`) as `{event: "browserHandoff", url: String, host: String}`, with the same
  native buffering (latest 10, shared with deep links). The Dart / TypeScript hubs route a map
  whose `event` is `"browserHandoff"` to `onBrowserHandoff` and every other map to `onDeepLink`
  (deep-link maps have no `event` key). One stream keeps one native buffer and listener count.

## Change 13: the Engage packages' share bridge

`share.link` / `share.referralLink` need the phone's share menu, so the Engage packages gained one
native method each (the core bridges are unchanged and still carry no share code):

| Package | Channel / module | Method | Arguments | Result |
|---|---|---|---|---|
| `clikgate_engage` | MethodChannel `com.clikgate/engage` | `shareLink` | map below | `bool` |
| `@clikgate/react-native-engage` | TurboModule `ClikgateEngage` (codegen `RNClikgateEngageSpec`) | `shareLink` | map below | `Promise<boolean>` |

Arguments: `{url: String, message: String?, app: ShareApp value?, shareUrls: {ShareApp value: String}?,
code: String?, shortUrl: String?}`; `code` (with `shortUrl`) means a referral link
(`share.referralLink`). The result is `true` when `app` itself opened. Errors: `share_unavailable`,
`invalid_argument`. Both forward to the native Engage add-on (`EngageShare.link` / `referralLink` on
Android, `ClikgateEngage.share.link` / `referralLink` on iOS), which builds the per-app links and records
the share, so the behaviour is identical on every platform (SDK_BEHAVIOUR.md "Change 13").

## Change 22: one method `goal()`, `getInstallationId`

- **Removed:** the `track` method and the `mirrorEvents` / `eventNameMap` arguments of `enableFirebaseForwarding`.
  `goal` is the only method for what happens in the app. The goal result's `status` may now be `"received"`
  (stored, not counted: the name isn't ticked as a goal yet, reason `not_counted_yet`, or `goal_archived`); the
  wrappers treat it as a success.
- **Added:**

| Method | Arguments | Result |
|---|---|---|
| `getInstallationId` | Flutter: none; React Native: `{}` | Flutter: `String?`; React Native: `{installationId: String \| null}` |

The value comes from the native SDK (Android `Clikgate.getInstallationId(listener)`, iOS
`Clikgate.shared.installationId(completion:)`): the installation's random UUID, or null when tracking is off
(opt-out, consent denied or not given yet where it's required, deep-link-only mode). Before `configure`, Android
answers once `configure` runs; iOS fails with `not_configured`.

