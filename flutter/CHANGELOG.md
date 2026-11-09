## Unreleased: one method, `goal()`; installation ID

Nothing has been published, so no public version ever has `track()`. The version stays 1.5.1 until the first public release.

- **Removed:** `Clikgate.track(...)`, `ClikgateMoney` and the `track` channel method. `goal()` is the only method; names count once they are ticked in the dashboard.
- **Removed:** `enableFirebaseForwarding(mirrorEvents:, eventNameMap:)`.
- **Added:** `GoalStatus.received` (`not_counted_yet`, `goal_archived`): stored, not counted; a success.
- **Added (docs):** `GoalStatus.refused` with reason `unknown_goal` (a name that isn't set up while the organisation accepts only set-up goals) or `goal_archived`: final, never retried. The native SDKs decide and log; the plugin passes the result through.
- **Added:** `await Clikgate.getInstallationId()` (channel method `getInstallationId`), from the native SDKs; null when tracking is off. Guide: https://clikgate.com/docs/identify-users

## 1.5.1 (unreleased): one tap is one click, X click ids

Nothing has been published yet: this patch also carries everything under "Unreleased" below.

- Requires the native SDKs 1.5.1 (Android default dependency and the iOS pod / Swift package constraint).
- From the native SDKs: a first-launch link that already matched on `/install` is no longer resolved a second time
  (one tap is one click); opens send the URL and the redirect's `cg_click_id` unchanged with the installation ID;
  X `twclid` reaches Clikgate unchanged, like `li_fat_id`. Dart tests added. No Dart API change.

## Unreleased: one `goal()` method, Payment goals and enums

- **Deep link check for "See it live" (test mode and the debug view).** From the native SDKs: when a Clikgate
  deep link is handed to the app, the path it handled is reported (`deeplink_handled`), only with a test SDK key or
  while the dashboard's debug view is open; the query is removed and ID, email and phone segments become `:id` on
  the device. Never an app event, never counted. Your `onDeepLink` result is unchanged. No Dart API change.

- **Apple Ads token and LinkedIn / Snap click ids.** From the native SDKs: on iOS the Apple Ads
  (AdServices) token is requested when the install is sent (after consent when it is required) and never kept on
  the device; LinkedIn `li_fat_id` and Snap `ScCid` in Clikgate links reach Clikgate unchanged. No Dart API change.

- **Password and country-restricted links on app opens.** The native SDKs open a password link's page
  in the system browser (nothing reaches `onDeepLink`) and deliver a link blocked for the visitor's country with
  the new `ClikgateDeepLink.blockMessage` (no path, click or link; show the text, don't route). Channel deep-link
  map key `blockMessage`.

- **identifyUser() replaces identify(); goals take a label.**
- **Breaking:** `identify()` is removed. `Clikgate.identifyUser(label:, customerId:, identityToken:)` takes an optional `label` (what your team sees instead of the click ID; 1-80 characters, `""` clears it; Growth and up), `customerId` (leave it out to keep the stored one; null clears it) and `identityToken`. With nothing to send it does nothing.
- `goal()` takes `label` too. `isFirst` is unchanged.
- Private mode: the customer ID and token are dropped on the device as before; labels are sent only when the organisation allows labels in private mode (config `allow_labels`), else dropped with one debug warning. A `label_ignored: "plan"` answer logs one debug warning. Channel method `identify` is now `identifyUser`.

- **Breaking: `Clikgate.payment()` is removed** (and the `payment` channel method). Report a payment with
  `goal()` on a Payment goal instead: `Clikgate.goal('purchase', reference: 'T123456', provider:
  ClikgateProvider.paystack)`. Nothing that used `payment()` was released.
- **Breaking: `Clikgate.goal()` returns `Future<GoalResult>`** (was `Future<void>`) and never throws:
  `status` is `GoalStatus.counted`, `waiting` (a Payment goal waiting for its confirmation from your payment
  provider or server) or `refused`, with a `reason` code; also `goalKind` (`GoalKind.standard` /
  `GoalKind.payment`) and `valueIgnored`. An invalid key, value, currency or reference completes as `refused`
  with reason `invalid_argument` instead of throwing. The future completes once Clikgate has answered (offline,
  the goal stays queued until it is sent).
- New `provider` parameter and `ClikgateProvider` (the payment providers Clikgate knows, plus
  `ClikgateProvider.fromString('…')` for providers added later; the server checks them). The goal's kind
  is never sent: it lives in the goal's settings.
- Test mode (a `cg_sdk_test_` key): the native SDKs log one line when a goal is waiting for its payment
  confirmation and when a value was ignored.
- Queueing and retries are unchanged.

## 1.5.0 (unreleased): consistency fixes

- **Deep links on every plan**, from the native SDKs: in
  deep-link-only mode (attribution switched off) `goal` and `track` log one warning
  and do nothing; they complete without an error. A `feature_disabled` answer on `/events` or `/goals` is
  dropped and never retried. The "no deferred link" install result at the monthly cap is the normal empty result.
  `isFeatureEnabled('deep_linking')` is on by default.

- Requires the native SDKs 1.5.0 (`com.clikgate:clikgate-android:1.5.0`, `Clikgate ~> 1.5.0`).
- New: `const ClikgateMoney.ofMinor(amountMinor, currency)`, the money helper name used on every platform
. The unnamed `ClikgateMoney(amountMinor, currency)` constructor stays as a deprecated alias.
- From the native SDKs: `/install` no longer sends `tracking_allowed`; an opted-out first install sends every
  consent purpose `denied`.
- Checked: `pasteboardMode` defaults to `off`; no trophy, challenge or progress API.

## 1.4.0 (unreleased): shared-domain browser fallback

- Requires the native SDKs 1.4.0 (`com.clikgate:clikgate-android:1.4.0`, `Clikgate ~> 1.4.0`).
- New: `Clikgate.onBrowserHandoff` (`Stream<ClikgateBrowserHandoff>`, `url` + `host`): another
  organisation's link on a shared domain (`ciz.to`, `clk.ng`, `clkg.to`, `dev.ciz.to`) that the native SDK
  opened in an in-app browser (Custom Tabs / SFSafariViewController) instead of the app. `onDeepLink`
  doesn't fire for it. Buffered and replayed like deep links.
- New `configure(platformDomainBrowserFallback: true)` option (false = old behaviour).
- Bridge: the handoff travels on the `com.clikgate/deep_links` event channel as
  `{event: "browserHandoff", url, host}`; `configure` sends
  `platformDomainBrowserFallback`.

## 1.3.0 (unreleased): goals and private mode

- Requires the native SDKs 1.3.0 (`com.clikgate:clikgate-android:1.3.0`, `Clikgate ~> 1.3.0`).
- New: `Clikgate.goal(key, {value, currency, reference, isFirst})`. `value` is an `int`, `double`, `BigInt`
  or numeric `String`, sent over the channel as a decimal string (never a double); NaN, infinity, doubles Dart
  prints with an exponent and other types throw `invalid_argument` (`param: value`) without a channel call.
  The native SDKs validate the rest and queue, retry and consent-buffer goals like events. Channel method
  `goal`.
- Private mode (`private_mode` in `/config`) is handled by the native SDKs: `identify` and event properties /
  revenue are not sent, goals still are.
- Example app: a "Goal: account opened" button.

## 1.2.0 (unreleased): consent, Google click ids, Firebase forwarding

- Requires the native SDKs 1.2.0 (`com.clikgate:clikgate-android:1.2.0`, `Clikgate ~> 1.2.0`).
- New: `Clikgate.setConsent({analytics, attribution, adUserData, adPersonalization})`,
  `getConsent()` (`ClikgateConsent`, `ConsentState`), `setConsentRegion(region)` (invalid values
  throw `invalid_argument`), `enableFirebaseForwarding({logAttributionEvent, setUserProperties,
  mirrorEvents, eventNameMap})`, `attributionMetadata()`, `enableGoogleOnDeviceMeasurement()` (iOS;
  no-op on Android).
- **Changed default:** `configure(pasteboardMode:)` is `off` (was `automatic`): the iOS clipboard
  deferred deep link is opt-in.
- Native behaviour (no Dart change needed): consent buffering in consent regions, `gclid` /
  `gbraid` / `wbraid` from links and the install referrer, minimum-SDK-version policy, Play Integrity
  standard requests, DeviceCheck on iOS.
- **Privacy (iOS SDK 1.2.0):** the iOS SDK no longer collects the screen size or the jailbreak
  heuristics (`is_rooted`); see `ios/CHANGELOG.md` "Privacy" for the exact list.
- Example: "Privacy & sales" screen (accept all / necessary only / EEA hint, attribution metadata);
  Firebase forwarding enabled at start-up. README: "Removing the SDK".

## 1.1.0 (unreleased): fraud signals

- Requires the native SDKs 1.1.0 (`com.clikgate:clikgate-android:1.1.0`, `Clikgate ~> 1.1.0`), which send
  the `/install` fraud signals `is_emulator` / `is_rooted` (hints, not proof; no new permissions). No Dart
  API change: the signals are collected natively.

## Unreleased

### Connected domains
- Docs: `linkDomains` should list every domain of the Clikgate domain group; the native SDKs add
  the server's `link_domains` and warn about domains missing from `linkDomains`.

### Engage split — breaking

* The core plugin keeps only device responsibilities: `configure`, `onDeepLink`,
  `getAttribution`, `track`, `identify`, `setTrackingEnabled`, `setPushToken`,
  `isClikgateMessage`, `handleUrl`, `nativeSdkVersion`, `isFeatureEnabled`,
  `referrals.applyCode` and `referrals.referredBy`.
* Removed from the core (moved to the new pure-Dart package `clikgate_engage`):
  `referrals.createLink`, `referrals.myStats`, `referrals.shareToWhatsApp`,
  `Clikgate.leaderboards.*`, `Clikgate.codes.redeem` and the models `ReferralLink`,
  `ReferralStats`, `LeaderboardPeriod`, `LeaderboardPeriodInfo`, `LeaderboardEntry`,
  `LeaderboardPage`, `MyRank`, `RedeemedCode`, `Redemption`; `ClikgateException.shareUnavailable`.
* New internal API for `clikgate_engage`: `Clikgate.getRequestContext()` →
  `ClikgateRequestContext` and `Clikgate.reportServerError(code, feature:)` (channel methods
  `getRequestContext`, `reportServerError`); the removed channel methods are gone from the
  Android and iOS plugin code.
* Public-API snapshot test (`test/api_snapshot.txt`) with a check that the core has no Engage
  API and never depends on `clikgate_engage`.
* Example: two variants (`--dart-define=CLIKGATE_VARIANT=backend|engage`). `backend`
  (default) gets sign-in with an identity token, invite link, stats, weekly leaderboard / "my
  rank" and server-side purchases from `samples/backend`; `engage` uses `clikgate_engage` for the
  same screens plus promo codes. Widget tests for both.

### v3 (before the split)


* `Clikgate.isFeatureEnabled(key)` and `ClikgateFeatures` (feature switches). Calls of a
  switched-off feature throw `ClikgateException(feature_disabled)` with `feature` set, without a
  network call.
* `Clikgate.referrals.shareToWhatsApp` (WhatsApp, then WhatsApp Business, then the share sheet).
* Leaderboards: `Clikgate.leaderboards.top`, `me`, `aroundMe`, `setOptOut`; models
  `LeaderboardPage`, `LeaderboardEntry`, `LeaderboardPeriodInfo`, `MyRank` and the
  `LeaderboardPeriod` selector (`current`, `previous`, `LeaderboardPeriod.key(...)`).
* Offline / promo codes: `Clikgate.codes.redeem` returning `Redemption` / `RedeemedCode`.
* `ClikgateException.feature` and `ClikgateException.offlineTouchId`.
* Implemented on both platforms: Android over the Android SDK, iOS over the iOS SDK's new
  v3 API (`Clikgate.shared.leaderboards`, `.codes`, `.referrals.shareToWhatsApp`,
  `isFeatureEnabled`). On iOS, `shareToWhatsApp` opens `whatsapp://send` when the app lists
  `whatsapp` in `LSApplicationQueriesSchemes`, else the share sheet.
* Example: weekly leaderboard screen (live refresh, "my rank", around me, opt-out switch),
  promo-code screen, "Share on WhatsApp".

## 1.0.0

* Initial release over the Clikgate Android SDK 1.0.0 and iOS SDK 1.0.0.
* `Clikgate.configure`, `onDeepLink` (buffered, replayed to the first subscriber),
  `getAttribution`, `track`, `identify`, `setTrackingEnabled`, `setPushToken`,
  `isClikgateMessage` (pure Dart), `handleUrl`.
* Referrals: `createLink`, `applyCode`, `myStats`, `referredBy`.
* Typed models and `ClikgateException`.
