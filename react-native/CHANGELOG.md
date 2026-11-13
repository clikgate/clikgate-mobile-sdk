# Changelog

## 2.1.0 (unreleased): Engage is part of the package

- **`@clikgate/react-native-engage` is merged into `@clikgate/react-native`.** `ClikgateEngage`, `ShareApp`,
  `EngageErrorCodes` and the Engage types are exported from `@clikgate/react-native` (same API; Engage's own
  `VERSION` export is gone, use `ClikgateEngage.version`). The `ClikgateEngage` TurboModule (share menu) is part of this
  package's native code.
- Requires the native SDKs 2.1.0 (which contain the native Engage features).
- **Automatic push token for uninstall tracking.** `Clikgate.configure({ automaticPushToken })` (default `true`) is
  passed to both native SDKs: when uninstall tracking is on in the dashboard (and tracking and consent allow it)
  they get a push token without asking for notification permission (iOS registers for remote notifications;
  Android fetches the FCM token when Firebase Messaging is in the app). iOS still needs the one AppDelegate line
  `ClikgateRN.setPushToken(deviceToken:)` and the Push Notifications capability: the Expo config plugin adds both
  (new prop `automaticPushToken`, default `true`: `aps-environment` and the line in `AppDelegate.swift` /
  `AppDelegate.mm`), and so does `npx @clikgate/setup` for bare apps. A token passed to `setPushToken` always wins.

## 2.0.0 (unreleased): one method, `goal()`; installation ID

**Breaking: `track()` was removed in favour of `goal()`.** `goal()` is now the only method for anything that happens in the app; names arrive in the dashboard's "Seen from your app and website" and count once they are ticked. This is the first public release: nothing was published before, so no public version ever had `track()`. It also carries every unreleased section below.

- Requires the native SDKs 2.0.0 (Android default dependency and the iOS pod constraint).
- **Requires Xcode 26 or newer to build** (App Store submissions need the iOS 26 SDK). Devices from iOS 13 are still supported.
- **Fixed:** importing the package on the web (react-native-web, including Expo Router's server rendering during an Android or iOS release build) crashed with "Cannot read properties of undefined (reading 'get')"; the native module is now `null` there, as documented.

- **Removed:** `Clikgate.track(...)`, `ClikgateMoney` and the native `track` method. `goal()` is the only method; names count once they are ticked in the dashboard.
- **Removed:** `enableFirebaseForwarding({ mirrorEvents, eventNameMap })`.
- **Added:** `GoalStatus.Received` (`not_counted_yet`, `goal_archived`): stored, not counted; a success.
- **Added (docs):** `GoalStatus.Refused` with reason `unknown_goal` (a name that isn't set up while the organisation accepts only set-up goals) or `goal_archived`: final, never retried. The native SDKs decide and log; the bridge passes the result through.
- **Added:** `await Clikgate.getInstallationId()` (native method `getInstallationId`, resolving `{installationId}`); null when tracking is off. Guide: https://clikgate.com/docs/identify-users

## 1.6.1 (unreleased): one tap is one click, X click ids

Nothing has been published yet: this patch also carries everything under "Unreleased" below.

- Requires the native SDKs 1.5.1 (Android default dependency and the iOS pod / Swift package constraint).
- From the native SDKs: a first-launch link that already matched on `/install` is no longer resolved a second time
  (one tap is one click); opens send the URL and the redirect's `cg_click_id` unchanged with the installation ID;
  X `twclid` reaches Clikgate unchanged, like `li_fat_id`. Jest tests added. No JavaScript API change.

## Unreleased: one `goal()` method, Payment goals and enums

### Deep link check for "See it live" (test mode and the debug view)
- From the native SDKs: when a Clikgate deep link is handed to the app, the path it handled is reported (`deeplink_handled`), only with a test SDK key or while the dashboard's debug view is open; the query is removed and ID, email and phone segments become `:id` on the device. Never an app event, never counted. Your `onDeepLink` result is unchanged. No JavaScript API change.

### Apple Ads token and LinkedIn / Snap click ids
- From the native SDKs: on iOS the Apple Ads (AdServices) token is requested when the install is sent (after consent when it is required) and never kept on the device; LinkedIn `li_fat_id` and Snap `ScCid` in Clikgate links reach Clikgate unchanged. No JavaScript API change.

### Password and country-restricted links on app opens
- The native SDKs open a password link's page in the system browser (nothing reaches `onDeepLink`) and deliver a link blocked for the visitor's country with the new `ClikgateDeepLink.blockMessage` (no path, click or link; show the text, don't route). Native module deep-link map key `blockMessage`.

### identifyUser() replaces identify(); goals take a label
- **Breaking:** `identify()` is removed. `Clikgate.identifyUser({ label, customerId, identityToken })` takes an optional `label` (what your team sees instead of the click ID; 1-80 characters, `""` clears it; Growth and up), `customerId` (leave it out to keep the stored one; null clears it) and `identityToken`. With nothing to send it does nothing.
- `goal()` takes `label` too. `isFirst` is unchanged.
- Private mode: the customer ID and token are dropped on the device as before; labels are sent only when the organisation allows labels in private mode (config `allow_labels`), else dropped with one debug warning. A `label_ignored: "plan"` answer logs one debug warning. TurboModule method `identify` is now `identifyUser`; new type `IdentifyUserOptions`.

### Removed (breaking)
- `Clikgate.payment()` and the TurboModule method `payment`. Report a payment with `goal()` on a Payment goal
  instead: `Clikgate.goal('purchase', { reference: 'T123456', provider: ClikgateProvider.Paystack })`. Nothing
  that used `payment()` was released.

### Changed (breaking)
- `Clikgate.goal()` resolves with a `GoalResult` (was `void`) and never rejects: `status` is
  `GoalStatus.Counted`, `GoalStatus.Waiting` (a Payment goal waiting for its confirmation from your payment
  provider or server) or `GoalStatus.Refused`, with a `reason` code; also `goalKind` (`GoalKind.Standard` /
  `GoalKind.Payment`) and `valueIgnored`. An invalid key, value, currency or reference resolves as refused with
  reason `invalid_argument` instead of rejecting. The promise resolves once Clikgate has answered (offline, the
  goal stays queued until it is sent).

### Added
- `GoalOptions.provider` and `ClikgateProvider` (constants and type of the payment providers Clikgate knows),
  `CLIKGATE_PROVIDERS` and `providerFromString('…')` for providers added later (the server checks them). The
  goal's kind is never sent: it lives in the goal's settings.
- Test mode (a `cg_sdk_test_` key): the native SDKs log one line when a goal is waiting for its payment
  confirmation and when a value was ignored.

Queueing and retries are unchanged.

## 1.6.0 (unreleased): consistency fixes

- **Deep links on every plan**, from the native SDKs: in
  deep-link-only mode (attribution switched off) `goal` and `track` log one warning
  and do nothing; they complete without an error. A `feature_disabled` answer on `/events` or `/goals` is
  dropped and never retried. The "no deferred link" install result at the monthly cap is the normal empty result.
  `isFeatureEnabled('deep_linking')` is on by default.

Requires the native SDKs 1.5.0 (`com.clikgate:clikgate-android:1.5.0`, `Clikgate ~> 1.5.0`).

### Added
- `ClikgateMoney.ofMinor(amountMinor, currency)`: the money helper name used on every platform,
  exported as a value next to the `ClikgateMoney` type. A plain `{amountMinor, currency}` object still works.

### Changed
- From the native SDKs: `/install` no longer sends `tracking_allowed`; an opted-out first install sends every
  consent purpose `denied`.

### Checked
- `pasteboardMode` defaults to `'off'`; no trophy, challenge or progress API.

## 1.5.0 (unreleased): shared-domain browser fallback

Requires the native SDKs 1.4.0 (`com.clikgate:clikgate-android:1.4.0`, `Clikgate ~> 1.4.0`).

### Added
- `Clikgate.onBrowserHandoff(listener)` (returns the unsubscribe function; types `ClikgateBrowserHandoff
  {url, host}` and `BrowserHandoffListener`): another organisation's link on a shared domain (`ciz.to`,
  `clk.ng`, `clkg.to`, `dev.ciz.to`) that the native SDK opened in an in-app browser (Android Custom Tabs,
  iOS SFSafariViewController) instead of the app. `onDeepLink` doesn't fire for it. Buffered (latest 10)
  and replayed like deep links.
- `ClikgateConfig.platformDomainBrowserFallback` (default `true`; `false` = old behaviour).
- Bridge: the handoff is the `ClikgateDeepLink` event tagged `{event: "browserHandoff", url, host}`
  so the native buffering and listener counting are unchanged.

## 1.4.0 (unreleased): Expo test link domain (setup command)

Requires the native SDKs 1.3.0 (unchanged: `com.clikgate:clikgate-android:1.3.0`, `Clikgate ~> 1.3.0`).

### Added
- Expo config plugin props `testLinkDomain` (e.g. `"dev.ciz.to"`) and `testVariants` (default
  `["development", "preview"]`). The test domain goes **only into development builds**: always into
  Android debug-based source sets (`app/src/debug/AndroidManifest.xml`, plus existing ones such as
  `debugOptimized`) and into the iOS Debug configuration (a `<Target>Debug.entitlements` copy of the
  Release entitlements plus `applinks:<testLinkDomain>`, linked with `CODE_SIGN_ENTITLEMENTS` on Debug
  only), and into every build of a variant listed in `testVariants` (`APP_VARIANT`, else EAS Build's
  `EAS_BUILD_PROFILE`). Release builds of other variants never get it. Written by finalized mods, after
  every other mod. Listing the test domain in `linkDomains` too is an error.
- `npx @clikgate/setup` writes `["@clikgate/react-native", {"linkDomains": [...], "testLinkDomain": "dev.ciz.to"}]`.

### Changed
- Docs, samples and fixtures use the final link domains (`ciz.to`, `dev.ciz.to`) instead of `clik.gt`.

## 1.3.0 (unreleased): goals and private mode

Requires the native SDKs 1.3.0 (`com.clikgate:clikgate-android:1.3.0`, `Clikgate ~> 1.3.0`).

### Added
- `Clikgate.goal(key, {value, currency, reference, isFirst})` (type `GoalOptions`). `value` is a `number`,
  `bigint` or numeric `string`, sent to the native module as a decimal string (never a double); NaN, infinity,
  numbers JavaScript prints with an exponent and other types reject with `invalid_argument` (`param: value`)
  without a native call. TurboModule method `goal` (Android `Clikgate.goalFromWrapper`, iOS
  `goal(_:decimalString:...)`).
- Private mode (`private_mode` in `/config`) is handled by the native SDKs: `identify` and event properties /
  revenue are not sent, goals still are.
- Example app: a "Goal: account opened" button.

## 1.2.0 (unreleased): consent, Firebase forwarding, sales metadata

Requires the native SDKs 1.2.0 (`com.clikgate:clikgate-android:1.2.0`, `Clikgate ~> 1.2.0`).

### Added
- `Clikgate.setConsent({analytics, attribution, adUserData, adPersonalization})` (omitted = unchanged),
  `Clikgate.getConsent()` (`ClikgateConsent`: the four `ConsentState`s, `region`, `required`) and
  `Clikgate.setConsentRegion(region)`. Consent travels with every native request; in consent regions the
  native SDKs buffer until `attribution` is granted (7 days / 1,000 events) and drop the buffer on deny.
- `Clikgate.enableFirebaseForwarding({logAttributionEvent, setUserProperties, mirrorEvents, eventNameMap})`
  (Firebase detected natively at runtime; no new dependency).
- `Clikgate.attributionMetadata()` → `{cg_click_id, cg_link_id}` for Paystack / Flutterwave metadata.
- `Clikgate.enableGoogleOnDeviceMeasurement()` (iOS; no-op on Android).
- Types `ConsentState`, `ClikgateConsent`, `ClikgateConsentUpdate`, `ClikgateFirebaseForwardingOptions`.
- TurboModule methods `setConsent`, `getConsent`, `setConsentRegion`, `enableFirebaseForwarding`,
  `attributionMetadata`, `enableGoogleOnDeviceMeasurement` (Android Kotlin, iOS Swift + ObjC++).
- The native SDKs also read Google click ids (`gclid` / `gbraid` / `wbraid`) from links and the Android
  install referrer, and follow Clikgate's minimum SDK version policy. No JS API for these.

### Changed
- `pasteboardMode` (iOS) defaults to `'off'` (was `'automatic'`): the clipboard deferred deep link is
  opt-in.

### Privacy (iOS, native SDK 1.2.0)
- The iOS SDK no longer collects screen size and scale or the jailbreak heuristic (`is_rooted`). Full
  list: the iOS SDK CHANGELOG, "Privacy".

## 1.1.0 (unreleased): fraud signals

- Requires the native SDKs 1.1.0 (`com.clikgate:clikgate-android:1.1.0`, `Clikgate ~> 1.1.0`), which send
  the `/install` fraud signals `is_emulator` / `is_rooted` (hints, not proof; no new permissions). No
  JavaScript / TurboModule API change: the signals are collected natively.

## Unreleased (Engage split)

Breaking (pre-release): the referrer-side API moved to the new optional package
`@clikgate/react-native-engage`. Needs the native SDKs with the Engage request context.

- Removed from core: `referrals.createLink`, `referrals.myStats`, `referrals.shareToWhatsApp`,
  `leaderboards.*`, `codes.redeem`, the `ReferralLink`, `ReferralStats`, `Leaderboard*`, `MyRank`,
  `Redemption`, `RedeemedCode` types, `MAX_LEADERBOARD_LIMIT` / `MAX_AROUND_ME_RADIUS`, and the
  leaderboard / code-only `ClikgateError` constants and `ClikgateErrorCode` members.
- Core keeps `configure`, `onDeepLink`, `getAttribution`, `track`, `identify`, `setTrackingEnabled`,
  `setPushToken`, `isClikgateMessage`, `handleUrl`, `isFeatureEnabled`, `referrals.{applyCode, referredBy}`.
- New internal methods for Engage: `Clikgate.getRequestContext()` (type `ClikgateRequestContext`) and
  `Clikgate.reportServerError(code, feature?)`.
- TurboModule: removed `referralsCreateLink`, `referralsMyStats`, `referralsShareToWhatsApp`,
  `leaderboardsTop/Me/AroundMe/SetOptOut`, `codesRedeem`; added `getRequestContext`, `reportServerError`
  (Android Kotlin + iOS Swift / ObjC++).
- Public-API snapshot test (`api/public-api.txt`) with a no-Engage-API / no-Engage-dependency check.
- Example: invite, stats, leaderboard and promo-code screens use `@clikgate/react-native-engage`.

### Connected domains
- Docs: `linkDomains` should list every domain of the Clikgate domain group; the native SDKs add
  the server's `link_domains` and warn about domains missing from `linkDomains`.

## Unreleased (feature switches, superseded by the Engage split above)

Needs the v3 native SDKs (Android / iOS) that add the methods below.

- `Clikgate.isFeatureEnabled(key)` (organisation feature switches from the cached `/config`).
- Calls of a switched-off feature reject with `ClikgateError('feature_disabled')`; `ClikgateError` gains
  `feature`. A resolved `{accepted: false, reason: "feature_disabled"}` map is mapped to the same error.
- `Clikgate.referrals.shareToWhatsApp({programId, message, displayName})` → `true` when WhatsApp opened.
- `Clikgate.leaderboards.{top, me, aroundMe, setOptOut}` with `LeaderboardPage`, `LeaderboardPeriod`,
  `LeaderboardEntry`, `MyRank` types (`aroundMe` pages have null `name` / `metric` / `segment`; `MyRank.rank`
  may be null).
- `Clikgate.codes.redeem(code)` → `Redemption` (`offlineTouchId`, `code`, `referral`).
- `ClikgateErrorCode` union with the v3 codes (`feature_disabled`, `leaderboard_not_found`,
  `referrer_not_found`, `invalid_segment`, `period_not_found`, `identity_invalid`, `code_expired`,
  `code_disabled`, `redemption_limit_reached`, `rate_limited`, ...) and matching `ClikgateError` constants.
- TurboModule methods `isFeatureEnabled`, `referralsShareToWhatsApp`, `leaderboardsTop`, `leaderboardsMe`,
  `leaderboardsAroundMe`, `leaderboardsSetOptOut`, `codesRedeem` (Android Kotlin + iOS Swift).
- Expo plugin: `enableWhatsAppSharing` (default `true`) adds `whatsapp` to `LSApplicationQueriesSchemes`.
- Example: weekly leaderboard screen, promo-code screen, share to WhatsApp.

## 1.0.0

- First release: `configure`, `onDeepLink` (with early-event buffering), `getAttribution`, `track`,
  `identify`, `setTrackingEnabled`, `setPushToken`, `isClikgateMessage`, `handleUrl`,
  `referrals.{createLink, applyCode, myStats, referredBy}` over Clikgate Android/iOS SDK 1.0.0.
- Expo config plugin (associated domains, App Link / scheme intent filters, remote-notification
  background mode).
