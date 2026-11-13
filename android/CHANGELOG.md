# Changelog — Clikgate Android SDK

## 2.1.0 (unreleased): Engage is part of the SDK

- **The Engage add-on is merged into the SDK.** `com.clikgate:clikgate-android` now contains the Engage features
  (`com.clikgate.engage.ClikgateEngage`: referral links and stats, leaderboards, promo codes, share helpers) for apps
  without a backend. There is no `com.clikgate:clikgate-engage` artifact any more; the API and package names are
  unchanged, so apps only remove that dependency. R8 drops Engage from apps that don't use it.
- **Added: automatic push token for uninstall tracking.** `ClikgateOptions(automaticPushToken = true)` (the default):
  when the app ships Firebase Cloud Messaging, the SDK reads the FCM token on each launch (by reflection, still no
  Firebase dependency) and uses it as if passed to `setPushToken(token, PushProvider.FCM)`. Only while uninstall
  tracking is on for the app, tracking isn't opted out, the SDK version isn't blocked and consent allows it. It never
  asks for notification permission; a token passed to `setPushToken` in the same launch always wins; failures are
  silent. Without Firebase Messaging it does nothing (one debug log). Consumer R8 rules keep
  `FirebaseMessaging.getInstance()` / `getToken()` with `-dontwarn`, so apps without Firebase build cleanly. Set
  `automaticPushToken = false` to control push registration timing yourself.

## 2.0.0 (unreleased): one method, `goal()`; installation ID (Change 22)

**Breaking: `track()` was removed in favour of `goal()`.** `goal()` is now the only method for anything that happens in the app; names arrive in the dashboard's "Seen from your app and website" and count once they are ticked. This is the first public release: nothing was published before, so no public version ever had `track()`. It also carries every unreleased section below.

- **Removed:** `Clikgate.track(name, revenue, properties)`, `trackValidated` and `ClikgateMoney`. `goal()` is the only method for what happens in the app. Names arrive in the dashboard's "Seen from your app and website" and count once they are ticked ("Count this as a goal").
- **Removed:** the app-event call and its queue path. App events left in the persisted queue by an earlier development build are dropped on the next flush, without a network call.
- **Removed:** `FirebaseForwardingOptions.mirrorEvents` and `eventNameMap` (there are no app events to mirror). Attribution forwarding to Firebase is unchanged.
- **Added:** `GoalStatus.RECEIVED`: stored, not counted (reason `not_counted_yet` for a name that isn't ticked yet, `goal_archived` for an archived goal). A success: never retried.
- **Added:** `Clikgate.getInstallationId()` (suspend) and `getInstallationId { id -> }` for identity Path B: the app sends it to its own server, which calls the server SDK's `identifyUser({appId, installationId, customerId, label?})`. Null when tracking is off (opt-out, consent denied or not given yet where required, deep-link-only mode). Guide: https://clikgate.com/docs/identify-users
- **Added:** the reason `unknown_goal` (`GoalStatus.REFUSED`) for a name that isn't set up as a goal while the organisation accepts only set-up goals, and `refused` / `goal_archived` for an archived goal there. Both are final: dropped from the queue, never retried. Debug builds (`FLAG_DEBUGGABLE`) log "Goal `{name}` isn't set up in Clikgate" with the goal name only. A whole-request `422` answered as `{status: "refused", reason}` is refused with that reason. The SDK never checks names itself. No public API change.
- A blocked SDK version's default calls no longer list `events`; goals go only when the server lists `goals`.
- Docs: plan wording fixed (goals work on every plan; the old "needs Growth" comment is gone).
- **Changed (R.22):** `identifyUser()` with an identity token that doesn't verify: the server now answers 200 with `verified: false` and a `reason` (`expired`, `bad_signature`, `secret_rotated`, `no_secret_set`, `not_yet_valid`). The SDK keeps the customer ID (unverified) and logs a warning naming the reason in plain words, e.g. "identifyUser: the identity token did not verify (expired); the customer ID is kept but not verified". The new fields are optional: an older server's `422 identity_invalid` is still handled. Referral calls refused with `403 identity_expired` (or `422 identity_invalid`) return that error and log a warning to get a new token. The token, the identity secret and the customer ID are never logged. No public API change (`identifyUser()` returns nothing).

## 1.5.1 (unreleased): one tap is one click, X click ids (Change 21)

Nothing has been published yet: this patch also carries everything under "Unreleased" below.

- **One tap is one click.** When the first launch's link already matched on `/install` (the answer says
  `status: "matched"`), the SDK no longer sends the same URL to `/resolve`, which recorded a second click for the
  same tap. On shared domains, the browser-handoff check runs only when the install didn't match.
- **Opens by people who already have your app.** Confirmed and tested: direct App Link opens send the URL as opened,
  opens after the redirect carry its `cg_click_id` unchanged, and every call carries the installation ID, so
  Clikgate can tell existing-user opens apart (they aren't counted as clicks, up to your plan's allowance).
- **X `twclid`** in Clikgate links and the Play install referrer reaches Clikgate unchanged, like LinkedIn `li_fat_id` (tests added).
- No API change.

## Unreleased

### Deep link check for "See it live" (test mode and the debug view)
- When the SDK hands a Clikgate deep link to the app, it now reports the path it handled with `POST /v1/sdk/deeplink-handled` (`deeplink_handled`), so the dashboard's "See it live" check can tick "Deep link opened the right screen". Only with a test SDK key (`cg_sdk_test_…`) or while the dashboard's debug view is open for the app (the server says so on the `/resolve` or `/install` answer); never in normal live use.
- Path only: the query and fragment are removed, and every path segment that looks like an ID (numbers, UUIDs, long hex or base64-like tokens, codes), an email address or a phone number is replaced with `:id` on the device. Your `onDeepLink` result is unchanged.
- A call of its own: never queued with events, never an app event, never counted or metered; one retry, then dropped. Nothing is sent while consent is pending or denied, after opt-out, or for password-protected or blocked links. No API change.

### LinkedIn and Snap click ids (Change 19)
- `li_fat_id` and Snap `ScCid` in Clikgate App Links and the Play install referrer reach Clikgate unchanged in the launch / resolved URL and the referrer (tests added; no code or API change).

### Password and country-restricted links on app opens (Change 17)
- An App Link no longer skips the link's gates: `/resolve` answers `password_required` (the SDK opens the password page in the browser app itself: an explicit browser package, no Custom Tabs, never this app; nothing is delivered) or `blocked` (`onDeepLink` gets a `ClikgateDeepLink` with the new `blockMessage` and no path, click or link; show the text, don't route). A/B tests: the server picks the version; its path arrives as usual. A gated answer never hands over a destination, deferred or direct.
- First launch on your own domain: when `/install` says the launch URL is `password_required` or `blocked`, the SDK now does the same as for `/resolve` (password page in the browser, or the blocked result) instead of opening nothing.

### identifyUser() replaces identify(); goals take a label
- **Breaking:** `identify()` is removed. `Clikgate.identifyUser(label, customerId, identityToken)` takes an optional `label` (what your team sees instead of the click ID; 1-80 characters, `""` clears it; Growth and up), `customerId` (leave it out to keep the stored one; null clears it) and `identityToken`. With nothing to send it does nothing.
- `goal()` takes `label` too. `isFirst` is unchanged.
- Private mode: the customer ID and token are dropped on the device as before; labels are sent only when the organisation allows labels in private mode (config `allow_labels`), else dropped with one debug warning. A `label_ignored: "plan"` answer logs one debug warning. `goalFromWrapper` gains a trailing `label` (wrappers).

### Share a link, a version per app (Engage)
- `ClikgateEngage.share.link(...)` and `share.referralLink(...)`: the share menu (or one app) with a Clikgate link; each app gets its own version of the link (a short ending so Clikgate knows where you shared it), other apps the plain link, and the share is recorded with `POST /v1/share-events` (no personal data). `ShareApp` names the apps. Referral links keep the code; `shareUrls` takes the API's `share_urls`. Chooser with per-package texts and an explicit, mutable `IntentSender` callback (Engage's own receiver); Android 15's chooser result is read when present. Engage size budget 40 → 44 KB (DECISIONS).

Breaking, with no deprecation period: no version with `payment()` was published. Ships in the next release,
1.5.0 (not published yet; core and Engage share the version). If a 1.x with `payment()` had been published,
this would need 2.0.0.

### Removed
- **`Clikgate.payment(provider, reference, goal)`** and `Clikgate.paymentValidated(...)`: a website or app reports a
  payment with `goal()` on a **Payment goal** instead. The SDK no longer calls `POST /v1/sdk/payments` (the route is
  gone) and the version-policy call name `payments` is unused.
- **`GoalOptions`** and `Clikgate.goalValidated(...)`: `goal()` takes named parameters.

### Changed
- **One `goal()` method:** `Clikgate.goal(key, value = null, currency = null, reference = null, provider = null,
  isFirst = null, onResult = null)` (`@JvmOverloads` for Java). Example:
  `Clikgate.goal("purchase", reference = "T123456", provider = Provider.PAYSTACK)`. The goal's kind (Standard or
  Payment) lives only in its settings, never in the call; a Payment goal counts only when your payment provider or
  server confirms it, with the confirmed amount (a value sent from the app is ignored).
- **Results:** `onResult: GoalResultListener` receives a `GoalResult(status: GoalStatus, reason: String?,
  goalKind: GoalKind?, valueIgnored: Boolean)` on the main thread once Clikgate has answered:
  `GoalStatus.COUNTED`, `WAITING` (for example `waiting_for_confirmation`) or `REFUSED` with a reason (the server's
  rejection code, or `invalid_argument`, `feature_disabled`, `opted_out`, `consent_denied`, `sdk_version_blocked`
  on the device). Queueing and retries are unchanged; a goal still queued when the app closes is sent on a later
  launch, without a result.
- `goalFromWrapper(key, value, currency, reference, provider, isFirst, onResult)` (`@ClikgateInternalApi`) gains the
  provider string and the listener (Flutter and React Native).

### Added
- **`Provider`**, generated from Clikgate's list of payment providers (`Provider.PAYSTACK`, `Provider.MTN_MOMO`,
  ..., `Provider.entries`), and `Provider.fromString("...")` for providers added after this release (the server
  checks them; null for a value that isn't a provider key).
- `GoalStatus`, `GoalKind` and `GoalResult`.
- Test keys (`cg_sdk_test_...`) log one line when a Payment goal is waiting for confirmation and one when its value
  was ignored.

## 1.5.0 (unreleased): consistency fixes

### Deep links on every plan (folded into this unreleased version)
- **Deep-link-only mode** (Free, Starter, or an app with attribution switched off: `/config` says
  `app_attribution: false`, `deep_linking: true`): `goal()` and `track()` log one "attribution is switched off" warning per
  launch and do nothing: nothing is queued or sent, and no error is returned. Direct and deferred deep links work
  as before.
- `/events` and `/goals` answering `200 {"accepted": false, "reason": "feature_disabled", "feature": "app_attribution"}`
  (the config was still cached as "on"): the batch is dropped, never retried, `app_attribution` reads as off until the
  next config fetch (which is refreshed straight away), and the rest of the queue is dropped without a call.
- `/install` in deep-link-only mode always has organic attribution; at the monthly deferred deep link cap
  `deep_link` is `null`. That is the normal "no deferred link" result: the app opens its home screen, nothing errors
  or retries.
- `isFeatureEnabled("deep_linking")`: on before the first config fetch and on older servers (catalogue default).
- Contract: fixtures `config_response_deep_link_only`, `events_response_feature_disabled`,
  `goals_response_feature_disabled`, `install_response_deep_link_only`, `install_response_deferred_cap`.
  Tests: `DeepLinkOnlyTest`.

### Added
- `ClikgateMoney.ofMinor(amountMinor, currency)` (`@JvmStatic`): the money helper name used on every
  platform. The `ClikgateMoney(amountMinor, currency)` constructor stays as a deprecated alias.

### Changed
- **Install consent:** `/install` no longer sends `consent.tracking_allowed`. The opted-out first
  install (`setTrackingEnabled(false)` before the first launch) sends the four-purpose consent object with
  every purpose `denied` instead of `tracking_allowed: false`; the app's own consent values go through
  `/consent` once tracking is back on.

### Checked, already done
- Goals use `/v1/sdk/goals` with one random `Idempotency-Key` per request, reused by its retries.
- `attributionMetadata()` keys are `cg_click_id` / `cg_link_id`; no trophy, challenge or progress
  API in core or Engage.

### Contract
`shared/fixtures/install_request_opted_out.json`; install fixtures no longer carry `tracking_allowed`
(the schemas still accept it).

### Tests
`OptOutTest` (opted-out install consent), `GoalsTest` (key reused across retries, a new key per call),
`EventsTest` (`ofMinor` equals the deprecated constructor).

## 1.4.0 (unreleased): shared-domain browser fallback

### Added
- **Shared platform domains** `ciz.to`, `clk.ng`, `clkg.to`, `dev.ciz.to` (one constant,
  `internal/BrowserHandoff.kt` `SharedDomains`, tested against `shared/fixtures/shared_link_domains.json`).
  When `/resolve` answers `matched: false` for a link on one of them (another organisation's link that
  opened the app), the SDK opens the original URL in **Custom Tabs** in an explicit browser package (the
  default browser when it supports Custom Tabs), else a plain view intent to an explicit browser package;
  never an implicit `ACTION_VIEW` intent (it could resolve to the app's own App Link and loop) and never
  this app's package. Custom Tabs are requested with the protocol extra, so there is no `androidx.browser`
  dependency. Started from the activity of the last `handleIntent`, else the application context.
- `Clikgate.onBrowserHandoff(BrowserHandoffListener?)` with `ClikgateBrowserHandoff(url, host)`: told when
  a link was handed to the browser (main thread; buffered latest 10 like deep links). `onDeepLink` doesn't
  fire for it.
- `ClikgateOptions.platformDomainBrowserFallback` (default `true`); `false` keeps the 1.3.0 behaviour.
- First launch: a shared-domain launch URL that `/install` didn't match (no `deep_link`, not `pending`)
  is now sent to `/resolve` too, so the fallback applies on cold installs.
- Manifest `<queries>` for browsers (`VIEW` `https` `BROWSABLE`) and the Custom Tabs service (Android 11+
  package visibility).

### Unchanged
Custom domains, matched links, consent buffering / blocked versions (links still routed locally) and
silent re-resolves after a consent grant.

### Contract
`shared/fixtures/shared_link_domains.json` (45 fixtures); install fixtures carry `sdk_version` 1.4.0.

### Size
Core R8 dex (public API kept) 118.5 KB → 120.8 KB (budget 150 KB); Engage unchanged at 33.4 KB.

### Tests
`SharedDomainFallbackTest` (11): list = fixture; shared + unmatched opens the browser with a handoff and no
deep link; custom + unmatched unchanged; shared + matched delivered as before; option off; no browser =
no handoff; first-launch shared launch URL resolved and handed off; custom launch URL not re-resolved;
`CustomTabsOpener` picks an explicit Custom Tabs browser, falls back to a plain explicit browser (never
the app itself), opens nothing without a browser.

## 1.3.0 (unreleased): goals and private mode

### Added
- **Goals**: `Clikgate.goal(key, GoalOptions(value: BigDecimal?, currency, reference, isFirst))`. Local
  validation (key `^[a-z][a-z0-9_]*$`, 2–40 characters; value ≥ 0 with ≤ 15 significant digits; currency ISO
  4217; reference 1–128 characters) fails with `invalid_argument` and an error log (never the reference or the
  value). The value is a `BigDecimal` end to end and goes on the wire as a decimal string (`2E+6` → `"2000000"`,
  `1500.50` → `"1500.5"`). A missing reference becomes a UUIDv4. Goals share the SQLite event queue (limits,
  flush triggers, WorkManager retry, consent buffering, opt-out) and are sent to the new `POST /v1/sdk/goals` in
  runs separate from events, in queue order; a goal with a `(key, reference)` already queued is ignored. Per-item
  rejections, a 422 and a 404 from a server without the route drop the goals; other failures retry.
  `click_id` = the latest matched deep link's click, else the install's. Calls before `configure` are validated
  and queued. `GoalOptions.toString()` redacts the value and the reference.
- **Private mode**: `private_mode` from `/config` (absent = off). When on, `identify()` is dropped on the
  device (not stored, not sent; a pending identify is discarded), `/events` items go without `properties`,
  `revenue_minor` and `currency` (stripped at send time), and one warning is logged per launch in debuggable
  apps (`FLAG_DEBUGGABLE`). Goals are unaffected.
- Wrapper entry point `goalFromWrapper(key, value: String?, ...)` (`@ClikgateInternalApi`) for Flutter / React
  Native: the value crosses the bridge as a decimal string.
- Version policy: `goals` is a call name in `allowed_calls`; a blocked SDK drops queued goals.

### Contract
- `shared/` (34 schemas, 44 fixtures): `goals_request`, `goals_response` (+ `_rejected`), `config_response`
  gains optional `private_mode` (`config_response_private_mode`), `goals` in the SDK call vocabulary; install
  fixtures carry `sdk_version` 1.3.0.

### Size
Core R8 dex (public API kept) 110.4 KB → 118.5 KB (budget 150 KB); Engage unchanged at 33.4 KB.

### Tests
`GoalsTest` (17): decimal round trips and significant digits, local validation, the contract item and schema,
wrapper strings, queueing with consent body and headers, install click id, events/goals ordering, idempotency
and retries keeping the item, persistence across a relaunch, rejected / 422 / 404 drops, goals waiting for the
install, consent buffering + grant and deny, config without `private_mode` = off, private mode dropping identify
and event properties/revenue (including events queued earlier and a pending identify).

## 1.2.0 (unreleased): trust and growth 

### Added
- **Consent**: `Clikgate.setConsent(analytics, attribution, adUserData, adPersonalization)` (each
  `ConsentState?`, null = unchanged), `getConsent(): ClikgateConsent` (with `region` and `required`),
  `setConsentRegion(region)`. Consent travels in every request body (`consent`) and as `region_hint` on
  `/config`. When consent is required and `attribution` is unknown the SDK buffers on the device (7 days /
  1,000 events, rolling) and sends nothing identifying; grant flushes, deny drops (plus one anonymous
  `/install-ping` when the organisation enabled anonymous counts); changes are recorded with `/consent`.
  New error codes `CONSENT_REQUIRED`, `SDK_VERSION_BLOCKED`.
- **Google click ids**: `gclid` / `gbraid` / `wbraid` read from App Links / custom-scheme links and the
  Play install referrer; sent as `google_click_ids` on `/install`, `/resolve` and `/open`.
- **Version policy**: `min_supported_version`, `latest_version`, `version_status`,
  `blocked_instructions` from `/config`; a deprecation warning once per launch; blocked versions send only
  the allowed calls with a minimal install body and filtered events, and route links locally.
- **Firebase forwarding**: `enableFirebaseForwarding(FirebaseForwardingOptions)`. Firebase Analytics is
  found by reflection (no dependency; consumer R8 rules keep the four methods used): `clikgate_attribution`
  once per install, `cg_first_source` / `cg_first_campaign`, optional event mirroring within Firebase's
  limits, and `app_instance_id` on `/install` and `/open`. Needs `analytics` consent and the server's
  `firebase_forwarding.enabled`.
- **Sales metadata**: `attributionMetadata()` → `{cg_click_id, cg_link_id}`.
- **Play Integrity standard requests** when a Google Cloud project number is known
  (`ClikgateOptions.cloudProjectNumber` or `features.attestation.android_cloud_project_number`); classic
  requests otherwise; `attestation.request_type` says which. The library stays an optional app dependency.
- Install response `attribution.source` / `medium` / `campaign` / `channel` are read (for Firebase).

### Changed
- `ClikgateOptions.cloudProjectNumber` now selects standard Play Integrity requests (before: passed to
  classic requests).
- Identity checks (Play Integrity) need `analytics` consent or the organisation's "fraud prevention" basis.

### Privacy
- `screen` (size and density, a probabilistic-matching signal) is sent only when the server enables
  probabilistic matching for the app **and** `attribution` consent allows it (was: always).
- Nothing identifying is sent while consent is required and unknown; `/config` then goes without the
  installation id header (also on a first launch before the consent requirement is known).
- `com.clikgate:clikgate-engage` moves to 1.2.0 with the core (shared version; no Engage changes).

### Sample
- Consent buttons, EEA region hint, Firebase forwarding (`firebase-analytics` runtime-only) and
  `attributionMetadata()`.

## 1.1.0 (unreleased): fraud signals

### Added
- `/install` sends `is_rooted` (optional): `test-keys` build tags, an `su` binary in a common path, or a
  known root-manager app (checked only below API 30, where no `<queries>` entry is needed). No new
  permission, manifest entry or dependency.
- `is_emulator` (already sent) and `is_rooted` are hints for fraud scoring, not proof. Each is computed
  once per request body; a check that throws leaves its field out and never fails the install.
- The click and install-begin times are the existing `install_referrer.referrer_click_timestamp_seconds`
  / `install_begin_timestamp_seconds`; unchanged.
- `com.clikgate:clikgate-engage` moves to 1.1.0 with the core (shared version; no Engage changes).

## 1.0.x (unreleased): Engage add-on split

### Connected domains (backend Part 3)
- `config.link_domains` (connected domains): optional in `/v1/sdk/config`; added to
  `ClikgateOptions.linkDomains` case-insensitively and cached with the config. Malformed values are
  ignored. A warning names each server domain missing from `linkDomains` (add it to the intent
  filter too).

### Core `com.clikgate:clikgate-android` — breaking
- Removed from core (moved to the Engage add-on): `Clikgate.referrals.createLink` / `awaitLink`,
  `myStats` / `awaitMyStats`, `shareIntent` / `awaitShareIntent`, `shareToWhatsApp` /
  `awaitShareToWhatsApp`, `Clikgate.leaderboards.*`, `Clikgate.codes.*`, the models
  `ReferralLink`, `ReferralStats`, `LeaderboardPeriod`, `LeaderboardEntry`, `LeaderboardPage`,
  `MyRank`, `RedeemedCode`, `Redemption`, the `ReferralLinkResult` alias and
  `ClikgateError.SHARE_UNAVAILABLE`.
- Core keeps `referrals.applyCode` / `awaitApplyCode`, `referrals.referredBy` / `awaitReferredBy`
  and `isFeatureEnabled`.
- Added (internal, `@ClikgateInternalApi` opt-in): `ClikgateRequestContext`,
  `Clikgate.requestContext`, `Clikgate.awaitRequestContext`, `Clikgate.reportServerError`, used
  by the Engage add-on and the Flutter / React Native wrappers. `@ClikgateInternalApi` can now
  annotate classes.
- Public-API snapshot `clikgate/api/clikgate.api` (binary-compatibility-validator, `apiCheck`),
  `CoreBoundaryTest` (no Engage API in core) and `checkNoEngageDependency`.

### New: Engage add-on `com.clikgate:clikgate-engage` 1.0.0
- For apps without their own backend: `ClikgateEngage.referrals.createLink/myStats`,
  `share.system/whatsApp`, `leaderboards.top/me/aroundMe/setOptOut/hostedPageUrl`,
  `codes.redeem`, `clearCache()`; callback and same-name `suspend` variants.
- Rules: feature switch checked first (no network when off), `not_identified`
  without `identify`, 60 s in-memory read cache, at most one retry for network errors only.
- `hostedPageUrl` reads `embed_url` from `/v1/sdk/leaderboards/{id}/me?embed=1`; `MyRank.embedUrl`.
- Behaviour changes versus the old core calls: leaderboard and code calls retried up to 2
  attempts on 408/429/5xx too, `createLink`/`myStats` up to 3; Engage retries once, and only on
  network errors. WhatsApp share no longer creates the link itself: call `createLink`, build the
  text, then `share.whatsApp(context, text)`.

### Sample
- Optional FCM without `google-services.json`: Firebase is initialised from the
  `clikgate.firebaseApiKey` / `firebaseAppId` / `firebaseProjectId` / `firebaseSenderId` Gradle properties
  (before, push registration was always skipped because nothing initialised Firebase).

## 1.0.0
- Initial SDK (deep links, deferred deep links, attribution, events, referrals, uninstall
  tracking, v3 feature switches, leaderboards, codes, WhatsApp share).
