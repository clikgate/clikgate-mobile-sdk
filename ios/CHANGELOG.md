# Changelog — Clikgate iOS SDK

## Unreleased: one method, `goal()`; installation ID (Change 22)

Nothing has been published, so no public version ever has `track()`. The version stays 1.5.1 until the first public release.

- **Removed:** `Clikgate.shared.track(_:revenue:properties:completion:)` and `ClikgateMoney`. `goal()` is the only method for what happens in the app. Names arrive in the dashboard's "Seen from your app and website" and count once they are ticked.
- **Removed:** the app-event call and its queue path. App events left in the persisted queue by an earlier development build are dropped on the next flush, without a network call.
- **Removed:** SKAdNetwork / AdAttributionKit conversion-value updates on the device and the `conversion_value_schema` config (change 22 R.5). The SDK no longer imports StoreKit or AdAttributionKit.
- **Removed:** `ClikgateFirebaseForwardingOptions.mirrorEvents` and `eventNameMap`. Attribution forwarding to Firebase is unchanged.
- **Added:** `ClikgateGoalStatus.received`: stored, not counted (`not_counted_yet`, `goal_archived`). A success: never retried.
- **Added:** `try await Clikgate.shared.installationId()` (and a completion form) for identity Path B. Nil when tracking is off. Guide: https://clikgate.com/docs/identify-users
- **Added:** the reason `unknown_goal` (`.refused`) for a name that isn't set up as a goal while the organisation accepts only set-up goals, and `.refused` / `goal_archived` for an archived goal there. Both are final: dropped from the queue, never retried. Debug builds log "Goal `{name}` isn't set up in Clikgate" with the goal name only. A whole-request `422` answered as `{status: "refused", reason}` is refused with that reason. The SDK never checks names itself. No public API change.
- A blocked SDK version's default calls no longer list `events`; goals go only when the server lists `goals`.
- **Changed (R.22):** `identifyUser()` with an identity token that doesn't verify: the server now answers 200 with `verified: false` and a `reason` (`expired`, `bad_signature`, `secret_rotated`, `no_secret_set`, `not_yet_valid`). The SDK keeps the customer ID (unverified) and logs a warning naming the reason in plain words, e.g. "identifyUser: the identity token did not verify (expired); the customer ID is kept but not verified". The new fields are optional: an older server's `422 identity_invalid` is still handled. Referral calls refused with `403 identity_expired` (or `422 identity_invalid`) return that error and log a warning to get a new token. The token, the identity secret and the customer ID are never logged. No public API change (`identifyUser()` returns nothing).
- Size: core 385.3 KB after R.22 (382.6 KB before; was 407.6 KB; ceiling 410 KB).

## 1.5.1 (unreleased): one tap is one click, X click ids (Change 21)

Nothing has been published yet: this patch also carries everything under "Unreleased" below.

- **One tap is one click.** When the first launch's link already matched on `/install` (the answer says
  `status: "matched"`), the SDK no longer sends the same URL to `/resolve`, which recorded a second click for the
  same tap. Without a deep link in that answer, the SDK now resolves by the click the install recorded (`click_id`), or delivers the link locally when attribution is off.
- **Opens by people who already have your app.** Confirmed and tested: direct Universal Link opens send the URL as opened,
  opens after the redirect carry its `cg_click_id` unchanged, and every call carries the installation ID, so
  Clikgate can tell existing-user opens apart (they aren't counted as clicks, up to your plan's allowance).
- **X `twclid`** in Clikgate links reaches Clikgate unchanged, like LinkedIn `li_fat_id` (tests added).
- No API change.

## Unreleased: one `goal()` method, Payment goals

### Deep link check for "See it live" (test mode and the debug view)
- When the SDK hands a Clikgate deep link to the app, it now reports the path it handled with `POST /v1/sdk/deeplink-handled` (`deeplink_handled`), so the dashboard's "See it live" check can tick "Deep link opened the right screen". Only with a test SDK key (`cg_sdk_test_…`) or while the dashboard's debug view is open for the app (the server says so on the `/resolve` or `/install` answer); never in normal live use.
- Path only: the query and fragment are removed, and every path segment that looks like an ID (numbers, UUIDs, long hex or base64-like tokens, codes), an email address or a phone number is replaced with `:id` on the device. Your `onDeepLink` result is unchanged.
- A call of its own: never queued with events, never an app event, never counted or metered; one retry, then dropped. Nothing is sent while consent is pending or denied, after opt-out, or for password-protected or blocked links. No API change.
- Size: core 407.0 KB (was 403.9 KB; ceiling 410 KB). The path check works on UTF-8 bytes without allocations: a `String`/`Character` version cost 7.6 KB and went over the ceiling.

### Apple Ads token at send time; LinkedIn and Snap click ids (Change 19)
- The AdServices token (`apple_search_ads`, iOS 14.3+) is now requested when the install is sent, so after the consent grant when consent is required, instead of on the first launch. A new token is requested when 24 hours have passed since it was fetched (long retries). It is kept in memory only and never written to the SDK's storage; a token stored by an earlier build is dropped. It isn't requested when attribution consent is denied.
- With identity-check consent the install also carries the IDFV when Apple Ads is on, so Clikgate can link an Apple Ads redownload to the earlier install.
- LinkedIn `li_fat_id` and Snap `ScCid` in Clikgate links reach Clikgate unchanged in the launch / resolved URL (tests added; no API change).
- Size: core about +0.5 KB (estimate, not measured in this change; was 402.1 KB, ceiling 410 KB).

### Password and country-restricted links on app opens (Change 17)
- A Universal Link no longer skips the link's gates: `/resolve` answers `password_required` (the SDK opens the password page in Safari with `UIApplication.open`, at most once per URL per 30 s, and delivers nothing) or `blocked` (`onDeepLink` gets a result with the new `ClikgateDeepLinkResult.blockMessage` and no path, click or link; show the text, don't route). A/B tests: the server picks the version; its path arrives as usual. A gated answer never hands over a destination, deferred or direct.
- An `/install` answer whose `status` is `password_required` or `blocked` never delivers its deep link; the launch URL is resolved as before and gets the gate's answer.
- Size: core 402.1 KB (was 409.7 KB): the JSON readers are no longer inlined at every call site (no behaviour change).

### identifyUser() replaces identify(); goals take a label
- **Breaking:** `identify()` is removed. `Clikgate.shared.identifyUser(label:customerId:identityToken:)` takes an optional `label` (what your team sees instead of the click ID; 1-80 characters, `""` clears it; Growth and up), `customerId` (leave it out to keep the stored one; null clears it) and `identityToken`. With nothing to send it does nothing.
- `goal()` takes `label` too. `isFirst` is unchanged.
- Private mode: the customer ID and token are dropped on the device as before; labels are sent only when the organisation allows labels in private mode (config `allow_labels`), else dropped with one debug warning. A `label_ignored: "plan"` answer logs one debug warning.
- Size: core stays under its 410 KB ceiling (409.7 KB) after trimming (shorter log messages, a smaller provisioning-profile and device-model reader, no Mirror). Removed with it: the deprecated `ClikgateMoney(amountMinor:currency:)` (use `ofMinor`) and the Objective-C names of `isFeatureEnabled`, `setTrackingEnabled` and `sdkVersion`; `identify` had an Objective-C name, `identifyUser` has none.

### Share a link, a version per app (Engage)
- `ClikgateEngage.share.link(...)` and `share.referralLink(...)`: the share menu (or one app) with a Clikgate link; each app gets its own version of the link (a short ending so Clikgate knows where you shared it), other apps the plain link, and the share is recorded with `POST /v1/share-events` (no personal data). `ShareApp` names the apps. Referral links keep the code; `shareUrls` takes the API's `share_urls`. `UIActivityItemSource` per activity type; the completion handler records the app. `ClikgateReferralLink` gains a public initializer. Engage size budget 80 → 95 KB; core unchanged (409.4 KB).

Breaking against the unreleased 1.5.0 API. No version is published yet, so this ships in the next release
(1.5.0 if it is still unpublished then; otherwise a new minor version, 1.6.0).

- **Breaking:** `Clikgate.shared.payment(...)` is removed (it was never released). A website or app reports a
  payment with `goal()` on a goal whose kind is *Payment*; the kind is set in the dashboard, never in the call.
- `goal(_:value:currency:reference:provider:isFirst:completion:)` takes `provider: ClikgateProvider?` and its
  completion now receives a `ClikgateGoalResult` (`status: ClikgateGoalStatus` `.counted` / `.waiting` /
  `.refused`, `reason`, `goalKind: ClikgateGoalKind?`, `valueIgnored`) once Clikgate answers, instead of a
  `ClikgateError?`. Invalid input is refused at once with reason `invalid_argument`; `not_configured`,
  `opted_out`, `consent_denied`, `feature_disabled` and `sdk_version_blocked` are the other local reasons. A
  final `4xx` is refused with the error code as the reason. Example:
  `Clikgate.shared.goal("purchase", reference: "T123456", provider: .paystack)`.
- The wrapper variant is `goal(_:decimalString:currency:reference:providerKey:isFirst:completion:)`; a malformed
  provider key is refused (`invalid_argument`).
- `ClikgateProvider`: the payment providers Clikgate knew at release (`.paystack`, `.flutterwave`, `.mtnMomo`, …),
  generated from the committed provider list, plus `ClikgateProvider.fromString(_:)` for providers
  added later (the server checks them).
- With a test SDK key (`cg_sdk_test_…`) the SDK logs one line when a Payment goal is waiting for its
  confirmation ("purchase is a Payment goal: waiting for confirmation"), ending "; its value was ignored" when a
  value was sent.
- A second call with the same key and reference while the first is still queued completes at once with
  `.waiting`, reason `already_queued` (the first call gets the server's answer).
- To stay within the 410 KB size budget, the debug log of a retried request no longer prints the wait to a
  tenth of a second, and two long warnings are shorter.
- Payment goals go to `POST /v1/sdk/goals` with `provider` and `reference`; `/v1/sdk/payments` and the
  `payments` version-policy call are gone. Queueing, retries and idempotency are unchanged.
- Published sources no longer carry internal notes or references; `Change03.swift` is now `ConsentPolicy.swift`.

## 1.5.0 (unreleased): consistency fixes

- Core size budget raised from 400 KB to 410 KB; core `-Osize` is 400.8 KB.

### Deep links on every plan
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
  Tests: `DeepLinkOnlyTests`.

### Added
- `ClikgateMoney.ofMinor(_:currency:)`: the money helper name used on every platform.
  `ClikgateMoney(amountMinor:currency:)` stays as a deprecated alias.

### Changed
- **Install consent:** `/install` no longer sends `consent.tracking_allowed`. The opted-out first
  install sends every consent purpose `denied` instead of `tracking_allowed: false`; the app's own consent
  values go through `/consent` once tracking is back on.

### Checked, already in place
- `Clikgate.shared.goal(...)` is the iOS goal call.
- Goals use `/v1/sdk/goals` with one random `Idempotency-Key` per request, reused by its retries.
- `pasteboardMode` defaults to `.off`; no trophy, challenge or progress API in core or Engage.

### Tests
`ReferralAndOptOutTests` (opted-out install consent), `Change03Tests` / `LifecycleTests` (no
`tracking_allowed`), `GoalsTests` (key reused across retries, a new key per call), `EventQueueTests`
(`ofMinor`).

## 1.4.0 (unreleased): shared-domain browser fallback

### Added
- **Shared platform domains** `ciz.to`, `clk.ng`, `clkg.to`, `dev.ciz.to` (one constant, `SharedDomains` in
  `Internal/Rules.swift`, tested against `shared/fixtures/shared_link_domains.json`). When `/resolve` answers
  `matched: false` for an `http(s)` link on one of them (another organisation's link that opened the app), the
  SDK presents it in an **`SFSafariViewController`** over the key window's top view controller. Never
  `UIApplication.open(_:)` (Safari would hand the Universal Link straight back to the app). `onDeepLink`
  isn't called.
- `Clikgate.browserHandoffNotification` (`Notification.Name("ClikgateBrowserHandoff")`), posted on the main
  thread after the browser was shown; `object` is the link's `URL`. Not buffered: observe it early.
- `ClikgateOptions.platformDomainBrowserFallback` (default `true`; `false` = the 1.3.0 behaviour).
- Links `SafariServices` (system framework; added to the podspec's frameworks).

### Unchanged
Custom domains, matched links, consent buffering / blocked versions, silent re-resolves after a consent grant.
A first-launch launch URL was already re-resolved after `/install` when unmatched, so the fallback applies there.

### Size
Core `-Osize` 394.7 KB → 398.3 KB (budget 400 KB); Engage unchanged at 75.6 KB.

### Tests
`SharedDomainFallbackTests` (8): list = fixture; shared + unmatched → browser + notification, no deep link;
custom + unmatched unchanged; shared + matched delivered as before; option off; browser failure = no
notification; first-launch shared launch URL; public facade end to end.

## 1.3.0 (unreleased): goals and private mode

### Added
- **Goals**: `Clikgate.shared.goal(_:value: Decimal?, currency:reference:isFirst:completion:)` and, for
  the wrappers, `goal(_:decimalString:currency:reference:isFirst:completion:)`. Local validation as on Android
  (`invalid_argument` with `param`), errors to `completion` and the log (never the reference or the value). The
  value stays a `Decimal` and goes on the wire as a normalised decimal string. A missing reference becomes a
  UUIDv4. Goals share `events.json` (limits, consent buffering, opt-out, background flush) and go to
  `POST /v1/sdk/goals` in runs separate from events, in queue order; duplicate `(key, reference)` in the queue is
  ignored; per-item rejections, 422 and 404 (server without the route) drop, other failures retry. `click_id` =
  the latest matched deep link's click, else the attributed install's.
- **Private mode**: `private_mode` from `/config` (absent = off). When on, `identify` is dropped on the
  device (a pending one is discarded with the stored user id), `/events` items go without `properties`,
  `revenue_minor` and `currency`, and one warning per launch is logged in Debug builds (`#if DEBUG`). Goals are
  unaffected.
- Version policy: `goals` call name; a blocked SDK drops queued goals.

### Size
Core `-Osize` 384.4 KB → 394.7 KB (budget 400 KB); Engage unchanged at 75.6 KB. Kept small on purpose: the goal
item is stored as the wire JSON, goals reuse the single `/events` request site in `flush()`, and value
normalisation uses Foundation regular expressions (the first draft was 412 KB).

### Tests
`GoalsTests` (12, Mac Catalyst): decimal round trips, validation, facade errors and the contract item, wrapper
strings, install click id, events/goals ordering, idempotency + retries + persistence, rejected / 422 / 404
drops, consent buffering then grant and deny, config without `private_mode` = off, private mode dropping
identify and event properties/revenue (including a pending identify and events queued on an earlier launch).
129 tests in total (core + Engage).

## 1.2.0 (unreleased): trust and growth

### Privacy
iOS never uses probabilistic matching. Everything the SDK collected only for probabilistic
matching or as a device fingerprint is **removed**:
- **Screen size and scale** (`screen` `{w, h, scale}` from `UIScreen.nativeBounds` / `nativeScale`) is no
  longer read or sent on `/install`.
- **Jailbreak heuristics** (`is_rooted`, added in 1.1.0) are removed: the 11 jailbreak file-path probes
  (Cydia, Sileo, Zebra, MobileSubstrate, `/usr/libexec/cydia`, `/usr/sbin/sshd`, `/bin/bash`, `/etc/apt`,
  `/private/var/lib/apt/`, `/var/jb`, `/var/binpack`) and the write test outside the sandbox
  (`/private/clikgate-jb-probe.txt`). Identity checks now rely on App Attest and DeviceCheck instead.
- **The clipboard is off by default**: `ClikgateOptions.pasteboardMode` defaults to `.off` (was `.automatic`).
  Opt in with `.automatic` or `.pasteControlOnly`; the dashboard switch `pasteboard_matching` must also be on.
- Kept: `is_emulator` (compile-time Simulator flag), OS version, device model, locale, time zone (analytics),
  and the installation id. The only device identifier sent is the IDFV, and only for identity checks with
  consent (below).
- `PrivacyInfo.xcprivacy` unchanged: IDFV and the DeviceCheck token fall under the declared Device ID type; no
  required-reason API is used.

### Added
- **Consent**: `setConsent(analytics:attribution:adUserData:adPersonalization:)` (nil = unchanged),
  `getConsent()` → `ClikgateConsent` (purposes, `region`, `isRequired`), `setConsentRegion(_:)`;
  `ClikgateConsentState`. The `consent` object goes on every request body, the region hint on `/config`
  (`region_hint`). When consent is required (server mode, EEA/UK/CH by default) and `attribution` is unknown,
  the SDK buffers on the device (≤ 7 days, ≤ 1,000 events), sends nothing identifying (`/config` without the
  installation id), delivers links locally and resolves them silently after grant; grant flushes, deny drops
  (plus one anonymous `/install-ping` when the organisation enabled anonymous counts, or a `/consent` record
  after the install). New `/consent` record on every change. New error codes `consent_required`,
  `sdk_version_blocked`. All consent calls work before `configure`.
- **Google click ids**: `gclid` / `gbraid` / `wbraid` from Clikgate links on `/install`
  (`google_click_ids`), `/resolve` and the next `/open`.
- **Version policy**: `version_status` / `min_supported_version` / `latest_version` from `/config`;
  deprecated → one warning per launch; blocked → one error per launch, only the allowed calls, a minimal
  `/install`, filtered / stripped events, links delivered locally.
- **Identity checks**: Apple DeviceCheck token (`device_check_token`, on `/install` and every `/attest`)
  and IDFV (`idfv`), with identity-check consent and when `identity_checks` or App Attest is on. App Attest
  also needs that consent now.
- **Firebase forwarding**: `enableFirebaseForwarding(_:)` with `ClikgateFirebaseForwardingOptions`;
  Firebase Analytics detected at runtime (`NSClassFromString("FIRAnalytics")`, no dependency):
  `clikgate_attribution` once per install, `cg_first_source` / `cg_first_campaign`, optional event mirroring,
  `app_instance_id` on `/install` and on `/open` when it changes. Needs the server switch and `analytics`
  consent.
- **`attributionMetadata()`**: `cg_click_id` / `cg_link_id` for Paystack / Flutterwave metadata.
- **Google on-device conversion measurement**: `enableGoogleOnDeviceMeasurement()`; when the app links
  `GoogleAdsOnDeviceConversion`, the installation's aggregate conversion info goes with the first install
  (`google_on_device_measurement.odm_info`). Not sent when `adUserData` is denied.
- `ClikgateAttribution.source`, `medium`, `campaign`, `channel` (optional server fields).
- `ClikgateEngage` moves to 1.2.0 with the core (shared version; no Engage changes).

### Changed
- `ClikgateOptions.pasteboardMode` default `.automatic` → `.off` (see Privacy).
- Size (`-Osize`, all public API): core 296.8 KB → 384.3 KB (budget 400 KB); Engage 75.6 KB (unchanged).

## 1.1.0 (unreleased): fraud signals

### Added
- `/install` sends `is_rooted` (optional): jailbreak file-path checks (Cydia, Sileo, Zebra,
  MobileSubstrate, `sshd`, `bash`, `apt`, rootless `/var/jb`) and a write test outside the sandbox. No URL-scheme
  probing (nothing to add to `LSApplicationQueriesSchemes`), no required-reason API, no privacy-manifest
  change. Omitted on the Simulator, Mac Catalyst and iOS apps on Mac, and when tracking is disabled.
- `is_emulator` (Simulator, already sent) and `is_rooted` are hints for fraud scoring, not proof; they never
  block or fail the install.
- `ClikgateEngage` moves to 1.1.0 with the core (shared version; no Engage changes).

## Unreleased: Engage add-on split

### Connected domains (backend Part 3)
- `config.link_domains` (connected domains): optional in `/v1/sdk/config`; added to
  `ClikgateOptions.linkDomains` case-insensitively and cached with the config. Malformed values are
  ignored. A warning names each server domain missing from `linkDomains` (add `applinks:<domain>` to
  Associated Domains too).

### Breaking (core `Clikgate`)
- Removed from the core SDK:
  `referrals.createLink`, `referrals.myStats`, `referrals.shareToWhatsApp`, `referrals.shareSheet`,
  `Clikgate.shared.leaderboards` (`top`, `me`, `aroundMe`, `setOptOut`), `Clikgate.shared.codes.redeem`, and
  the models `ClikgateReferralLink`, `ClikgateReferralStats`, `ClikgateLeaderboard*`, `ClikgateMyRank`,
  `ClikgateRedemption`. The error-code constants used only by those calls (`shareUnavailable`,
  `leaderboardNotFound`, `periodNotFound`, `invalidSegment`, `codeExpired`, `codeDisabled`,
  `redemptionLimitReached`, `referrerNotFound`, `referralLinkLimit`, `clientLinkCreationDisabled`) moved to
  the Engage add-on (as `ClikgateError` extensions, so `ClikgateError.leaderboardNotFound` still compiles
  with Engage imported).
- Kept: `referrals.applyCode`, `referrals.referredBy`, `isFeatureEnabled`, and everything else.

### Added
- **`ClikgateEngage`** (SPM product / `Clikgate/Engage` pod subspec; the pod's default subspec is
  `Clikgate/Core`): `ClikgateEngage.referrals.createLink/myStats`, `ClikgateEngage.share.system/whatsApp`,
  `ClikgateEngage.leaderboards.top/me/aroundMe/setOptOut/hostedPageUrl`, `ClikgateEngage.codes.redeem`,
  `ClikgateEngage.clearCache()`; async and completion-handler variants. Rules: feature switch
  checked first (`feature_disabled` without network), `not_identified` before `identify`, 60 s in-memory read
  cache, at most one retry and only for network errors.
- `leaderboards.hostedPageUrl` (new): the signed hosted-page URL (`/me?embed=1` → `embed_url`).
  `ClikgateMyRank.embedUrl`.
- Core: internal `@_spi(ClikgateEngage)` request context (`ClikgateRequestContext`,
  `Clikgate.shared.requestContext()`, `reportServerError(code:feature:)`) used by Engage.
- `ios/scripts/check_api.sh` (public-API snapshots in `ios/api/`, core/Engage boundary and dependency
  check) and `ios/scripts/check_size.sh` (core < 400 KB, Engage < 80 KB).

### Changed
- Engage leaderboard / referral calls retry only network errors, once (they used to retry 5xx / 429 as
  well, up to 2 attempts).
- Engage models are no longer `Equatable` (code size); leaderboard period / rank timestamps expose
  `startsAtRaw`, `endsAtRaw`, `periodEndsAtRaw` publicly (they were wrapper SPI).

### Distribution and sample
- `scripts/build_xcframework.sh` also builds `ClikgateEngage.xcframework` (Engage code only; link it together
  with `Clikgate.xcframework`). The `ios-v*` release checks the Engage version against the tag too and attaches
  both XCFramework zips.
- Sample: product screen for `/products/…` deep links, referred-by banner at launch, identity-token field.

## 1.0.0
- First version: deep links, deferred deep links, attribution, events, identify, referrals, push tokens,
  opt-out, App Attest, SKAN / AdAttributionKit, Apple Search Ads, v3 feature switches, leaderboards, codes,
  WhatsApp share.
