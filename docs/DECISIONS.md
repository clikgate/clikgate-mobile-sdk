# Decisions (cross-platform)

Platform-specific decisions stay in each platform's `DECISIONS.md` (`android/`, `ios/`, `flutter/`, `react-native/`,
`cli/`). This file holds the ones that span the SDKs.

## Change 20 — `deeplink_handled` for the live check (C20-S1, 2026-11-04)

Spec: `clikgate_api/docs/spec/clikgate-change-20-activity-offers-billing-dashboards.md` S.1, S.2, F and R.40 (R
wins). The backend side (C20-B5) was not in `clikgate_api` when this was built (no `deeplink_handled` anywhere on
2026-11-04), so the wire shape below is this repository's proposal, written into `shared/API_CONTRACT.md`
"Change 20 additions" for the lead to reconcile with the backend.

- **A call of its own, not an `/events` item.** `POST /v1/sdk/deeplink-handled {path, is_deferred}`. Sending it as
  a `track()` event would put it in the queue, on the attributed-events meter and in deep-link-only mode's
  "nothing is sent" rule (the live check runs on every plan), and private mode strips event properties, so the
  path would be lost. A separate fire-and-forget call (one retry, never queued, failures dropped, like
  `share-events`) is never counted or metered by construction. Version-policy name `deeplink_handled`.
- **"Debug view open" comes on the answer that delivered the link.** The SDK can't see the dashboard; the server
  can. `debug_view: true` on `/resolve` and `/install` answers (optional, absent = false) is current for that
  link, unlike `/config`, which the SDKs cache for an hour. Test keys (`cg_sdk_test_`) always send. Older
  servers: only test keys send.
- **Path cleaning on the device, by shape.** Query and fragment cut; each `/` segment, percent-decoded for the
  test, becomes `:id` when it has an `@`; is only digits and `+-.() ` with a digit; or has a letters-and-digits
  run with a digit and 6+ characters, or 16+ characters in mixed case. This catches numbers, phone numbers,
  UUIDs, hex and base64-like tokens, emails and codes such as `ADA42XYZ`, while `summer-2026`, `iphone-15-pro`,
  `v2` and plain words stay readable. It errs towards `:id` (dates become `/:id/:id/:id`; a 16+ letter
  CamelCase word becomes `:id`). Max 512 characters. One set of vectors for every SDK:
  `shared/fixtures/deeplink_path_cases.json`.
- **Which path:** the delivered result's `path` (the server's `deep_link.path`, which can differ from the URL,
  e.g. an A/B variant), else the opened URL's path. The app's own result keeps the full path and query.
- **When not:** consent pending / denied, opted out, blocked SDK version, gated links (password / blocked),
  unmatched links, browser handoffs, links delivered locally without a server answer.
- **Flutter / React Native:** nothing in Dart / TypeScript; the native SDKs send it. Their tests check that the
  key and links pass through unchanged and that the wrapper adds no call.
- **Versions: no bump (S.2).** Nothing is published yet, so like Changes 10-19 the work folds into the unreleased
  native 1.5.0, Flutter 1.5.0, React Native 1.6.0 (CLI 1.1.0); CHANGELOGs under Unreleased;
  `check_cli_sdk_versions.mjs` passes unchanged. If any of these is published before release, bump the minor
  version of all four with the CLI constants together.
- **iOS size:** measured with `check_size.sh`'s method (`swiftc -wmo -Osize -c`, arm64 iOS 13, the same section
  sum; compiler only, no Xcode build): core **407.0 KB** (416,813 bytes), was 403.9 KB (413,553). The first
  version (`String` / `Character` APIs: `split`, `allSatisfy`, `removingPercentEncoding`) cost 7.6 KB and reached
  411.5 KB, over the ceiling; the shipped one walks the UTF-8 bytes once with indices and no allocations per
  segment (cleaner about 2 KB, `Task` 0.6 KB, the rest the `debug_view` reads and call sites). Android keeps the
  plainer `Regex` version (its budget has room).

## Change 13 — share helpers (C13-S1, 2026-10-29)

Spec: `docs/spec/clikgate-change-13-attribution-qr-sso.md` S.1 (and B.2, B.4). Backend: `POST /v1/share-events`
and `ShareApp` as built in `clikgate_api` (`src/shares`, `src/attribution/utils/share_endings.py`; its
`docs/DECISIONS.md` "Change 13 — backend" and "Change 13 — documentation checks" 13.1–13.3, which this follows).

- **Where it lives: Engage, named `share.link` / `share.referralLink`.** The spec writes `Clikgate.share(link,
  message)` under "Share helpers (Engage)". The core SDKs may not contain share code (spec 0.4/20, enforced by the
  boundary checks and the iOS core's 410 KB ceiling), so it is on the Engage facade next to the existing
  `share.system` / `share.whatsApp`: `ClikgateEngage.share.link(url, message?, app?, shareUrls?)` and
  `share.referralLink(referralLink, message?, app?)` (a separate name instead of `String | ClikgateLink`, which
  only TypeScript can express). Same names on all four platforms.
- **Flutter and React Native call the native Engage add-on.** A per-app link needs the native share sheet
  (Android replacement extras + `IntentSender`, iOS `UIActivityItemSource`), which `share_plus` and RN `Share`
  can't do. The core bridges must stay free of share code, so `clikgate_engage` gained a small Android / iOS plugin
  (MethodChannel `com.clikgate/engage`) and `@clikgate/react-native-engage` a one-method TurboModule
  (`ClikgateEngage.shareLink`), both forwarding to the native Engage add-on (`com.clikgate:clikgate-engage`,
  `Clikgate/Engage`). One implementation per OS; the native Engage code also records the share with the native
  core's request context. The packages are no longer "pure Dart / pure TypeScript"; their boundary tests now
  check that the only native code is that bridge and that it depends on native Engage (never core-only).
- **The endings table is in SDK code.** No SDK-key or web-key endpoint returns `share_urls`, and the per-app link
  must be ready before the share sheet opens, so the SDKs (and the web script) carry the table. It is generated
  from one internal file, `shared/share_targets.json`, by `scripts/generate_share_targets.py` (`--check` in CI and
  the boundary script; it also compares with the backend's `ShareApp` enum and `share_endings.py` when the sibling
  checkout exists). Docs never list it (they say "adds a short ending so Clikgate knows where you shared it"); test
  vectors are in `shared/fixtures/share_cases.json`. The spec already accepts that the table isn't a secret (B.2:
  a hand-typed ending only changes `shared_as` with a `share_tag` basis). **For the owner:** anyone reading the
  open-source SDKs or the served `clikgate.js` can see the letters. If that's not acceptable, the backend needs an
  SDK/web-key route that returns `share_urls` for a link (or `share_urls` on `/v1/sdk/referrals/link` and `/me`);
  the SDKs already prefer given `shareUrls`.
- **Building the link.** The ending goes on the last path segment, or after the referral code when the code is a
  query value (`?ref=CODE`), replacing an ending already there (names can't end in one: the reserved rule).
  Non-http(s) links and links without a path are shared unchanged. Apps without an ending (Slack, Discord,
  Snapchat, iMessage, other) and "Copy" get the plain link. `shareUrls` from the backend always win.
- **Recording.** `POST /v1/share-events {url, app}` with the SDK key (the URL carries the ending, so `link_id` and
  `share_ending` aren't sent). A referral link is recorded by the URL that was shared (`/r/CODE-<ending>`,
  `?ref=CODE-<ending>`), which `POST /v1/share-events` resolves (updated 2026-10-29: the first version used the
  `short_url`, before the backend resolved referral URLs; that code is removed). No
  feature switch (share helpers are on every plan), one network retry, nothing queued, failures dropped; nothing
  without consent / before the first install (the core's request context refuses). The read cache is kept.
- **Android.** `createChooser(target, title, pendingIntent.intentSender)` + `EXTRA_REPLACEMENT_EXTRAS` for the 16
  packages of 13.1; the callback is an explicit (`ClikgateShareReceiver`, not exported) mutable broadcast
  `PendingIntent` with a distinct request code; Android 15+ `EXTRA_CHOOSER_RESULT` first (copy → `other`), else
  `EXTRA_CHOSEN_COMPONENT`. Direct share: `ACTION_SEND` per package, then `ACTION_SENDTO smsto:` / `mailto:`, then the
  chooser; **no `<queries>`** (13.1: nothing checks installation; the spec's `<queries>` line is superseded by the
  docs check). API 21 (no `IntentSender` overload) gets the chooser without a callback.
- **iOS.** One `UIActivityItemSource` answers per `activityType`: `.message` → sms, `.mail` → email, otherwise the
  app whose bundle ID the type starts with (case-insensitive; a share extension's bundle ID is prefixed by its app's).
  Host bundle IDs were confirmed with the App Store lookup API on 2026-10-29 (WhatsApp `net.whatsapp.WhatsApp`,
  WhatsApp Business `net.whatsapp.WhatsAppSMB`, Instagram, Facebook, Messenger, TikTok, X `com.atebits.Tweetie2`,
  LinkedIn, Telegram `ph.telegra.Telegraph`, Gmail, YouTube, Snapchat, Slack, Discord). The completion handler
  records when `completed` and a type are set ("share started"; 13.2: WhatsApp reports completed after a cancel).
  Direct share: `whatsapp://send` (with `canOpenURL`), `https://t.me/share/url`, `https://x.com/intent/tweet`,
  `mailto:`; others use the sheet. `share.link` is `async` (one code path for both). `ClikgateReferralLink` got a
  public initializer for the bridges.
- **Sizes (budget changes for the owner to confirm).** Engage Android 33.4 → 42.2 KB (R8, public API kept): budget
  40 → **44 KB**. Engage iOS 75.6 → 92.8 KB (-Osize): budget 80 → **95 KB**. Trimming tried first (no `Links`
  class, no companion tables, regex-based link building, string-keyed tables, one async path; −4 KB Android,
  −8 KB iOS); what's left is the feature itself. **Core budgets unchanged; iOS core is still 409.4 KB** (no core
  code changed). If the owner wants the old Engage budgets back, the candidates are dropping `referralLink` (callers
  pass the URL and code) and the Android 15 chooser-result branch.
- **Versions: no bump.** Nothing is published; the work folds into the unreleased versions (native 1.5.0, Flutter
  Engage and RN Engage 1.0.0), so the setup command's constants are unchanged (`check_cli_sdk_versions.mjs` passes).

## Change 13 — website share buttons (C13-S2, 2026-10-29)

Built in `clikgate_api/webscript` (see `clikgate_api/docs/DECISIONS.md`): `clikgate.share.mount(element, {link,
apps, message})`. The spec's `cg.share.mount` is read as the script's object, `clikgate` / `Clikgate`; no new
global was added.

## Change 14 — identifyUser and labels (C14-S1, 2026-10-29)

Spec: `docs/spec/clikgate-change-14-customer-cost-people-data.md` S.1, B.4, B.5. Backend as built: `src/sdk`
(`IdentifyRequestSchema`, `IdentifyResponse`, `allow_labels` in `SdkConfigResponse`), `src/people`, `src/web_keys`.

- **"Leave it out" vs "null".** The backend keeps the customer ID when `customer_user_id` is absent and clears it on
  `null`; the SDKs mirror that. Kotlin, Swift and Dart can't tell an omitted argument from `null`, so `customerId`
  defaults to a sentinel (`"\u0000"`, never a real customer ID): Kotlin `KEEP_CUSTOMER_ID` (private), Swift
  `"\u{0}"`, Dart `_keepCustomerId`. TypeScript uses `'customerId' in options`. The bridges carry it as "key present or
  not" (`customerId` in the channel map). The sentinel shows in the generated API listings; the docs say "leave it out".
- **One `/identify` with everything.** The SDK sends the stored customer ID and token (as before) plus a label not
  sent yet, so a label-only call doesn't drop the customer ID and needs no new endpoint. The pending label is
  persisted like the pending identify. A label longer than 80 characters is not sent (error log), the rest of the
  call goes ahead (the backend would refuse the whole goal or identify otherwise).
- **Private mode:** the customer ID and token are never sent (as before); the label follows config `allow_labels`.
  `/identify` in private mode omits `customer_user_id` instead of sending `null`.
- **Goals:** `label` is the last parameter before the callback on Android (`goal(…, isFirst, label, onResult)`), the
  wrappers' `goalFromWrapper` takes it as a trailing parameter (positional callers keep working).
- **iOS core ceiling.** The change added about 1.8 KB; core is **409.7 KB (419,505 bytes, < 410 KB)** after trimming
  1.7 KB elsewhere with no behaviour change: the device model is read without `Mirror`, push tokens are hex-encoded
  without `String(format:)`, the provisioning-profile reader looks for the `aps-environment` key in the text instead
  of parsing the plist, `sendIdentify` is shorter, five long log messages are shorter, the deprecated (never
  published) `ClikgateMoney(amountMinor:currency:)` is gone, and three Objective-C names (`isFeatureEnabled`,
  `setTrackingEnabled`, `sdkVersion`) were dropped (ObjC support was already partial: `goal`/`track` never had ObjC
  names; `identify` had one, `identifyUser` has none). Headroom is now 335 bytes. iOS trims the label server-side
  (no local trim) and counts UTF-16 units against 80, for size.
- **Not stored as personal-data type:** the privacy manifest comment now mentions the label; the declared collected
  data types are unchanged. **For the owner:** a label can contain a name if the app puts one in it; decide whether
  the App Store privacy details should list "Name" for apps that use labels.
- **Docs check:** `scripts/check_no_identify.py` (in the boundary script) fails if `identify(` appears outside the
  CHANGELOGs and these records.
- **Web script** (`clikgate_api/webscript`): `clikgate.identifyUser({label, customerId})` → `POST /v1/web/identify`
  with the stored click ID (text/plain, `web_key` in the body), labels only when `/v1/web/config` says
  `allow_labels` (the config is now fetched once per page and shared with payment detection); `goal(key, {label})`
  likewise. Resolves `{status: identified | not_sent | refused, reason, personId}`, never rejects. 5,894 bytes gzipped
  (budget 6,144).

## Change 17 — link gates on app opens (R.2, 2026-10-31)

Spec: `clikgate_api/docs/spec/clikgate-change-17-ab-password-rewards.md` R.2 (with R.1 and R.3). Backend as built:
`ResolveResponse.status` / `web_url` / `block_message` in `clikgate_api/src/sdk/schemas/session_schemas.py`,
`GatedResolution` in `src/attribution/services/attribution_engine.py`.

- **`status` first.** The SDKs read `status` before anything else: on `password_required` / `blocked` they ignore
  `matched`, `click_id`, `deep_link`, `link` and `referral` even if a server sent them, so a gated link can never
  hand over a destination (direct or deferred) or set the click for `attributionMetadata()`. `status` absent
  (older servers) keeps the old rule (`matched`).
- **Blocked = a deep-link result with `blockMessage`.** No new callback or event: the existing deep-link callback /
  stream gets the opened URL with `blockMessage` set and `path`, `data`, `clickId`, `matchType`, `link`, `referral`
  empty, so an app that doesn't know the field still has nothing to route to. The SDKs show no UI (they have no UI
  pattern for deep links). Same name on every platform; Android, Flutter and React Native add it as a defaulted /
  nullable field, iOS as `public internal(set) var blockMessage: String?`.
- **Password = the system browser, not the in-app view.** The password cookie must be in the browser that then
  follows the redirect. Android: `BrowserOpener.openExternal`, the same explicit browser package search as the
  shared-domain fallback but a plain `ACTION_VIEW` without the Custom Tabs extra (never an implicit intent: this
  app's App Links would catch it). iOS: `UIApplication.shared.open(web_url)`. Whether iOS opens Safari or hands an
  app's own Universal Link straight back to it isn't documented, so the dispatcher opens one password URL at most
  once per 30 s (a loop stops after one bounce). **To check on a device** (TESTING_DEEP_LINKS.md); if iOS does hand
  it back, the fallback is the in-app `SFSafariViewController` (cookie kept in its own store).
- **No handoff event for password links.** `onBrowserHandoff` / `browserHandoffNotification` stays "another
  organisation's shared-domain link"; a password link on a shared domain still goes to the system browser.
- **Deferred deep links.** The backend answers `/install` for a gated `launch_url` without a deep link. iOS then
  `/resolve`s every launch URL (as before), so it gets the gated answer. Android `/resolve`s a first-launch URL
  only on shared domains (Change 06); a gated custom-domain launch URL on the very first launch therefore
  delivers nothing and opens nothing (no destination leaks; the visitor taps the link again). Not widened: a
  `/resolve` after every deep-link-less install could mint a second click. **Closed (follow-up):** `/install` now
  answers `status` / `web_url` / `block_message` for an evaluated launch URL (optional fields). Android acts on a
  gated install answer like a gated `/resolve` answer (`deliverGated`: password page via
  `BrowserOpener.openExternal`, or the blocked result) on every domain and doesn't `/resolve` it again; iOS
  ignores an install `deep_link` when the status is gated (it already re-resolves every launch URL). iOS core
  401.9 → 402.1 KB.
- **iOS size.** The change adds 3.4 KB to the core (3,435 bytes; the `UIApplication.open` call alone is 1.3 KB). Instead of trimming features, the JSON readers on
  `[String: Any]` (`str`, `bool`, `obj`, `int`, `int64`, and one shared `num` number check) are `@inline(never)`: at
  `-Osize` the compiler had copied each dynamic cast into every call site (hundreds). That and the four consent-state reads of the
  state file sharing one helper saved 11.4 KB (11,412 bytes, measured on the code before the change). Core: 409.7 KB → **401.9 KB** (411,528
  bytes; budget 410 KB). No behaviour change (the readers are the same functions).
- **Versions: no bump** (folded into the unreleased versions, as Changes 10–14); CHANGELOGs under Unreleased.

## Change 19 — Apple Ads token timing, LinkedIn and Snap click ids (C19-S1, 2026-11-04)

- **AdServices timing (R.1).** Requested when the first `/install` is sent, renewed after 24 hours (Apple's validity;
  re-checked by backend C19-B3 on 2026-10-31, https://developer.apple.com/documentation/adservices), held in memory
  only. Details: `ios/DECISIONS.md` "Apple Search Ads".
- **IDFV.** Sent with the install when `apple_search_ads` is on, with identity-check consent (the backend stores
  `idfv_hash` only under that rule anyway). The App Store privacy label docs are unchanged: Device ID was already
  declared (`PrivacyInfo.xcprivacy`).
- **No `ad_click_ids` field (S.2).** Change 03's explicit `google_click_ids` exists because Google needs the id on the
  install record. LinkedIn and Snap ids are read by the backend from the URLs and referrer the SDKs already send
  unchanged (C19-B2 `extract_ad_params`), and the backend's request schemas forbid unknown keys, so adding a field
  now would fail every install. `pass_ad_click_ids` is applied by the redirect (the SDK config doesn't return it).
  Open question for the lead: if the backend later wants explicit fields, it adds them first, then the SDKs.
- **Web script (in `clikgate_api/webscript`): unchanged.** A landing page gets `li_fat_id` / `ScCid` only through a
  Clikgate redirect, which already stored them on the click the goal's `click_id` points at; `POST /v1/web/goals`
  forbids unknown keys, so the script has nowhere to send them.
- **Versions: no bump** (nothing published; same practice as changes 12-17).


## Change 21 — opens by existing users, one tap one click, X `twclid` (C21-S, 2026-11-05)

- **S.1 confirmed.** Every platform already sent what the server needs: direct App Link / Universal Link opens go
  to `/resolve` with the URL as opened (the server records the click at receipt), redirect opens carry the redirect's
  `cg_click_id` inside that URL (the server attaches to it, `attribution_engine.resolve_url`), every call has
  `Clikgate-Installation-Id`, and `/open` never carries a URL. Flutter and React Native pass URLs to the native SDK
  unchanged. No new wire field (the backend's `/install`, `/open` and `/resolve` bodies are `extra="forbid"`).
- **R.2 gap found and fixed (the reason for the patch).** After `/install` matched the launch URL (it records that
  URL's click), a second `/resolve` of the same URL minted another click: on iOS whenever the install answer had no
  deep link (link without a deep link, deferred cap reached, attribution off), on Android for shared-domain launch
  URLs. Now both skip it when the install answer says `status: "matched"`. iOS resolves by `click_id` instead (keeps
  the link details, no new click) or, without a click ID (attribution off), delivers the URL locally. Older servers
  (no `status`) keep the old behaviour. `/resolve` retries after a lost response could still mint twice; the contract
  has no idempotency key for it (left for the backend to dedupe if it wants).
- **R.25 `twclid`.** Handled like `li_fat_id` (change 19): no SDK code, tests prove it travels unchanged in
  `launch_url`, `/resolve` `url` and the Play referrer, also through consent buffering. Web script
  (`clikgate_api/webscript`): unchanged for the same reason as change 19 (the redirect stores it on the click the
  `cgid` points at; `POST /v1/web/goals` forbids unknown keys); a test proves `twclid` doesn't change what it keeps,
  posts to `/cg/keep` or sends with goals.
- **Versions.** Patch releases as asked by the lead: Android, iOS, Flutter 1.5.1, React Native 1.6.1, setup command
  1.1.1 (nothing is published yet, so each 1.5.1 / 1.6.1 also carries the "Unreleased" entries). The Engage add-on
  wrappers keep their versions and `~> 1.5.0` / `1.5.0` native constraints (no change in Engage).
- **Docs.** "Replacing Firebase Dynamic Links" sections (Android 4a, iOS 3a, Flutter 3a, React Native 3a) with the
  Firebase and Clikgate calls side by side. Firebase status checked 2026-11-05 at
  https://firebase.google.com/support/dynamic-links-faq (shut down on August 25, 2025; links answer 404) and the
  receive API at https://firebase.google.com/docs/dynamic-links/android/receive. The four guides' Change 10 plan
  paragraph was stale after Change 20 (basic attribution on every plan): rewritten, and "unlimited" became "no monthly
  cap". `shared/API_CONTRACT.md` "Change 21 additions" covers basic attribution (the Change 20 open item), the open
  payloads and `twclid`.
- **Open item.** The deep-link-only warning text in the SDKs still says "needs Growth" (`warnNeedsGrowth`); since
  Change 20 that mode means attribution switched off. Changing the text means touching the iOS core (size budget)
  and the tests that match it, so it is left for a later release.
