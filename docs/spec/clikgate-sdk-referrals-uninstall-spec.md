# Clikgate Mobile SDKs, Install Attribution, Referrals & Uninstall Tracking — Build Specification (v2)

> **Instructions for the AI building this:**
> - This spec **extends an existing codebase** built from `clikgate-backend-build-spec.md` (FastAPI backend with organisations, auth, domains, links, campaigns, redirect service, click ingestion, conversions, outbox events, webhooks, workers, analytics). Read that codebase first. Reuse its conventions (prefixed ULIDs, error format, pagination, idempotency, tenant-scoped repositories, outbox + webhook dispatcher, Arq workers, audit log). Do not duplicate infrastructure that already exists.
> - It also defines **new SDKs**: iOS (Swift), Android (Kotlin), **Flutter** (plugin over the native SDKs, built alongside each native SDK) and React Native.
> - Build **in the milestone order of section 18**. After each milestone, run all tests (backend and SDK) and fix failures before continuing.
> - Where the spec says "verify against current platform documentation", check Apple's / Google's current docs before coding and record what you found in `docs/DECISIONS.md`. Do not guess platform API details.
> - Do not implement matching or tracking techniques that are not described here.
> - This v2 supersedes `clikgate-mobile-sdk-attribution-spec.md`.

---

## 0. Scope and principles

Clikgate gives apps what Branch, AppsFlyer and Singular give them for owned and earned media:

1. **Deep linking** — a link opens the right screen in the app, and if the app isn't installed, the user lands on that screen after installing (deferred deep linking).
2. **Install attribution** — which link/click led to an install, plus later in-app events.
3. **Referrals (core feature)** — users invite friends with personal links or codes; Clikgate tracks the full journey (click → install → signup → qualifying actions → retention) and tells the app owner which referrals **qualified**, blocking common referral fraud. Works with apps that already have a referral system.
4. **Uninstall tracking (available to every app customer)** — detects when an installed app has been removed, using push-token validity checks, and feeds retention analytics and referral qualification.

**Clikgate does not pay rewards.** It decides whether a referral qualified and tells the app owner; the app owner pays. **Reward amounts are not recorded by default**; an app owner may optionally attach reward information to a referral program for reporting and webhook payloads (section 8.2).

### 0.1 Matching methods (in order of preference)

| Method | Platform | Certainty | Notes |
|---|---|---|---|
| Direct open via Universal Links / App Links | iOS, Android | Deterministic | App already installed |
| Google Play Install Referrer | Android (Play installs) | Deterministic | Click ID passes through Play Store to the app |
| Pasteboard token (user-initiated copy on the landing page, read on first open) | iOS | Deterministic | iOS 16+ shows a paste prompt unless the app uses `UIPasteControl` |
| Manual referral code entry | iOS, Android | Deterministic | Referrals only, user types the friend's code |
| Apple Search Ads token (`AdServices`) | iOS | Deterministic for Apple Search Ads | Optional |
| AdAttributionKit / SKAdNetwork postback copies | iOS | Aggregated | Paid ads; no user-level match |
| Short-window probabilistic match | iOS, non-Play Android | Probabilistic | **Off by default** (0.2) |

### 0.2 Policy note — probabilistic matching

Apple prohibits deriving data from a device to uniquely identify it for tracking ("fingerprinting"), regardless of ATT consent. Whether short-lived, first-party matching used only to route a user to content they just tapped is acceptable is not clearly settled by Apple. Therefore:

- Disabled by default; enabled per app only by an org **owner** with an explicit acknowledgement (`acknowledged_policy_version`) recorded in the audit log.
- Only matches clicks on links owned by the **same organisation** as the app.
- Window default 60 minutes, max 24 hours; signals stored only in Redis with that TTL; no persistent device identifier; never shared.
- Results labelled `match_type = "probabilistic"` with a confidence score.
- **Referrals never qualify on a probabilistic match by default** (program setting `allow_probabilistic = false`).
- Global kill switch env var `SDK_PROBABILISTIC_ENABLED=false`.
- `docs/PRIVACY.md` explains this; App Store review is the app owner's responsibility.

### 0.3 Out of scope (design for later, section 19)

Paid ad-network integrations (Meta/Google/TikTok self-reporting networks), cost/ROAS, IDFA/GAID matching against ad clicks, non-Play store referrers, web-to-app smart banners, App Clips/Instant Apps, paying rewards, multi-touch attribution.

---

## 1. Deliverables

1. **Backend changes** to the existing Clikgate FastAPI codebase: SDK API, attribution engine, deferred deep links, app events, **referrals engine**, **uninstall tracking**, interstitial landing pages, AdAttributionKit/SKAdNetwork receiver, new customer APIs, webhooks, analytics, workers.
2. **Android SDK** (Kotlin, Maven Central, minSdk 21).
3. **iOS SDK** (Swift, SPM + CocoaPods, iOS 13+).
4. **Flutter plugin** `clikgate_flutter` (pub.dev) over both native SDKs — built **in the same milestones** as each native SDK, not at the end.
5. **React Native package** `@clikgate/react-native` with Expo config plugin.
6. **Sample apps**: Flutter (primary demo), native Android, native iOS, React Native — each demonstrating direct and deferred deep links, referrals (share link, apply code, status) and push-token registration.
7. **Docs**: integration guides per platform, `docs/REFERRALS.md`, `docs/UNINSTALL_TRACKING.md`, `docs/PRIVACY.md`, `docs/TESTING_DEEP_LINKS.md`, API reference additions.

### Repository layout additions

```
clikgate/                       # existing backend
  app/services/attribution/     # matchers + decision core
  app/services/referrals/       # programs, referrers, engine, fraud, qualification
  app/services/uninstall/       # push senders (APNs, FCM), scheduler, result handling
  app/services/skan/            # AdAttributionKit/SKAdNetwork receiver
  app/api/routers/sdk/          # SDK-facing routes (sdk.clikgate.com)
  app/redirect/landing/         # interstitial, signals endpoint, referral URL patterns
sdks/
  android/                      # :clikgate library + sample
  ios/                          # Swift package + podspec + sample
  flutter/                      # clikgate_flutter plugin (android/, ios/, lib/) + example/
  react-native/                 # package + expo plugin + example
  shared/                       # JSON Schemas for SDK<->API payloads, fixtures
```

---

## 2. Concepts

| Term | Meaning |
|---|---|
| **App** | Existing `apps` row (iOS or Android). Gains SDK settings |
| **SDK key** | Public per-app key `cg_sdk_<random>`. Not a secret |
| **Installation ID** | UUIDv4 created by the SDK on first launch. iOS: also in Keychain (survives reinstall). Android: app storage |
| **Install** | First launch for an installation ID (`ins_` row) |
| **Customer user ID** | The app's own user ID, set after login |
| **Identity token** | HMAC signature from the app's backend proving a customer user ID belongs to the current user (8.5). Prevents impersonating referrers |
| **Referral program** | Per-app configuration of how referrals work and qualify |
| **Referrer** | An app user who invites others; has a code and a link per program |
| **Referral** | One referee (new user) attributed to one referrer, moving through states |
| **Push token** | APNs device token or FCM registration token, used for uninstall checks |

---

## 3. Changes to existing backend code (summary)

Touch these existing modules; keep their patterns:

- `models/`, `migrations/`: new and altered tables (section 4).
- `schemas/links.py`, `services/links.py`, link cache writer: new link fields (`app_ids`, `deep_link_path`, `deep_link_data`, `app_behavior`, `ios_interstitial`, `kind`, `referrer_id`, `referral_program_id`).
- `redirect/resolver.py`: platform handling, Android intent/Play referrer URLs, iOS interstitial, referral code URL patterns (section 6).
- `services/conversions.py`: accept `source = sdk`, `installation_id`, `install_id`, `match_type`.
- `services/webhooks` event catalogue: new event types (section 12).
- `workers/settings.py`: new jobs (section 13).
- `api/routers/apps.py`: SDK settings, push credentials, SDK key rotation.
- `services/analytics`: install, referral and uninstall metrics.
- New SDK router mounted at `sdk.clikgate.com` (same codebase, separate host + rate limits).

---

## 4. Data model

All tables tenant-scoped with `organization_id` unless noted. Partition large append-only tables monthly.

### 4.1 Altered tables

**apps** — add:
- `sdk_key` (unique), `previous_sdk_key`, `previous_sdk_key_expires_at`
- `ios_app_store_id`, `android_store_url`, `uri_scheme`
- `environment` (`production|sandbox`)
- `settings` jsonb:
  - `deferred_deep_linking` (true), `pasteboard_matching` (`off|on_interstitial_tap`, default `on_interstitial_tap`)
  - `probabilistic_matching` `{enabled:false, window_minutes:60, min_confidence:0.9, acknowledged_policy_version, acknowledged_by, acknowledged_at}`
  - `install_lookback_days` (7), `event_attribution_window_days` (30), `reattribution_window_days` (90)
  - `attestation` `{ios_app_attest:"off|monitor|enforce", android_play_integrity:"off|monitor|enforce"}`
  - `apple_search_ads` (false), `collect_advertising_id` (false), `restricted_mode` (false)
  - `uninstall_tracking` `{enabled:false, schedule:{first_check_after_hours:24, daily_until_day:30, weekly_until_day:180}, confirm_after_consecutive_unregistered:1}`
  - `conversion_value_schema_id` (nullable)
- `push_credentials` (separate table, 4.2)

**links** — add:
- `kind` (`standard|referral`), `app_ids` (text[]), `deep_link_path`, `deep_link_data` (jsonb ≤ 4 KB), `app_behavior` (`app_or_store|app_or_web|web_only`), `ios_interstitial` (`auto|always|never`), `referral_program_id` (nullable), `referrer_id` (nullable).
- Update the redirect cache contract to include these fields and each target app's store URL, scheme, bundle/team IDs, package name.

**clicks** — add: `platform` (`ios|android|desktop|other`), `in_app_browser` (nullable), `served` (`redirect|interstitial|store|intent|app_link`), `deferred_token` (nullable), `referral_program_id` (nullable), `referrer_id` (nullable).

**conversions** — `source` gains `sdk`; add `installation_id`, `install_id`, `match_type`.

### 4.2 New tables — attribution and SDK

- **installs**: id (`ins_`), organization_id, app_id, installation_id (unique per app), platform, first_open_at, app_version, sdk_version, os_version, device_model (coarse), locale, timezone, country, installer_package (Android), is_reinstall, previous_install_id, attribution_status (`pending|attributed|organic`), match_type, confidence, click_id, link_id, campaign_id, attributed_at, install_referrer_raw, referrer_click_at, install_begin_at, attestation_status (`not_checked|valid|invalid|unavailable`), fraud_flags (text[]), customer_user_id, identity_verified (bool), last_seen_at, active_days_count (int), opt_out (bool),
  **uninstall fields**: push_provider (`apns|fcm|null`), push_token_encrypted, push_token_hash (for dedupe/index), push_token_updated_at, apns_environment (`production|sandbox|null`), uninstall_status (`installed|uninstalled|unknown`), uninstalled_detected_at, uninstall_evidence (`apns_410|fcm_unregistered|null`), last_uninstall_check_at, next_uninstall_check_at, uninstall_reverted_at.
  - Unique (app_id, installation_id); indexes (organization_id, first_open_at), (link_id), (app_id, customer_user_id), (app_id, next_uninstall_check_at) where uninstall tracking active, (push_token_hash).
- **app_opens** (partitioned): id, organization_id, app_id, install_id, occurred_at, url, click_id, link_id, match_type, is_reengagement.
- **app_events** (partitioned): id (`aev_`), organization_id, app_id, install_id, event_id (SDK UUID, unique per app), name, revenue_minor, currency, properties (jsonb ≤ 8 KB), occurred_at, received_at, attributed_link_id, attributed_click_id, conversion_id, source (`sdk|server`).
- **app_event_rules**: id, organization_id, app_id, event_name, promote_to_conversion, conversion_type, only_first.
- **push_credentials**: id, organization_id, app_id, provider (`apns|fcm`), apns_key_id, apns_team_id, apns_topic (bundle id), apns_p8_encrypted, apns_environment, fcm_project_id, fcm_service_account_encrypted, status (`valid|invalid|untested`), last_tested_at, last_error. One row per provider per app.
- **uninstall_checks** (partitioned): id, organization_id, app_id, install_id, provider, sent_at, result (`accepted|unregistered|bad_token|auth_error|rate_limited|error`), http_status, provider_reason, latency_ms.
- **skan_postbacks**, **conversion_value_schemas**, **privacy_requests**: as in section 9 / 14.
- Redis only: `dfr:{token}` (deferred pasteboard tokens, TTL = lookback), `prb:{app_id}:{ip_hmac}` (probabilistic signals, TTL = window).

### 4.3 New tables — referrals

- **referral_programs**: id (`rpg_`), organization_id, app_id (nullable → program spans the org's iOS+Android pair; store `app_ids` text[] instead), app_ids (text[]), name, status (`active|paused|archived`), link_domain_id, link_defaults (jsonb: `deep_link_path`, `deep_link_data`, `og_title`, `og_description`, `og_image_url`, `fallback_url`), code_format (`{length:6, alphabet:"ABCDEFGHJKLMNPQRSTUVWXYZ23456789", prefix:""}`), code_url_patterns (text[], e.g. `["/r/{code}", "/invite?ref={code}"]`), allow_manual_code_entry (true), manual_code_entry_window_days (7), client_link_creation (true), require_identity_token (true), allow_probabilistic (false), attribution_window_days (7), qualification (jsonb, 8.3), fraud (jsonb, 8.4), reward (jsonb, **nullable, default null**, 8.2), created_at, updated_at.
- **referrers**: id (`rfr_`), organization_id, program_id, customer_user_id, code (unique per program, case-insensitive), external_code (nullable; bring-your-own code, unique per program), link_id, status (`active|blocked`), blocked_reason, known_installation_ids (text[]; installs where this user was identified), created_at, updated_at, stats (jsonb cache: clicks, installs, qualified, disqualified, rejected, referee_uninstall_rate_7d), quality_score (0–100), last_activity_at.
  - Unique (program_id, customer_user_id), (program_id, lower(code)), (program_id, lower(external_code)).
- **referrals**: id (`ref_`), organization_id, program_id, referrer_id, referee_install_id, referee_customer_user_id, link_id, click_id, source (`link|code_entry|byo_code`), match_type, status (`installed|signed_up|in_progress|holding|qualified|disqualified|rejected`), current_step (int), steps_completed (jsonb), hold_until, qualified_at, disqualified_at, rejection_reason / disqualification_reason (enum below), fraud_flags (text[]), reward_snapshot (jsonb, nullable — copied from program at qualification only if program.reward is set), referee_uninstalled_after_qualification (bool), created_at, updated_at.
  - Unique (program_id, referee_install_id). Index (referrer_id, status), (organization_id, created_at).
  - Reasons: `self_referral`, `existing_user`, `reinstall_already_referred`, `referrer_blocked`, `velocity_limit`, `attestation_invalid`, `emulator`, `install_burst`, `probabilistic_not_allowed`, `step_timeout`, `uninstalled_during_hold`, `inactive_during_hold`, `manual_rejection`, `code_entry_window_expired`.
- **referral_state_changes**: id, referral_id, organization_id, from_status, to_status, reason, actor (`system|api|staff`), created_at.

---

## 5. SDK API (called by SDKs) — `https://sdk.clikgate.com/v1`

### 5.1 Auth and integrity
- `Clikgate-SDK-Key`, `Clikgate-SDK-Version` (`ios/1.0.0`, `android/…`, `flutter/…`, `react-native/…`), `Clikgate-Installation-Id` (after first launch).
- Optional attestation (App Attest / Play Integrity) on install and every 7 days; `monitor` records, `enforce` excludes from attribution and referrals.
- Rate limits: per SDK key and per IP; installs 10/min/IP; events 600/min/installation; referral link creation 5/day/installation; code apply 5/hour/installation.

### 5.2 Endpoints

| Method | Path | Purpose |
|---|---|---|
| GET | `/v1/sdk/config` | Feature flags (pasteboard, probabilistic allowed, Apple Search Ads, uninstall tracking enabled, referral programs summary: id, name, client_link_creation, allow_manual_code_entry), conversion value schema, batching limits, server time |
| POST | `/v1/sdk/install` | First launch → attribution + deep link + referral result |
| POST | `/v1/sdk/open` | App open (with launch URL if any) |
| POST | `/v1/sdk/resolve` | Resolve a Clikgate URL or click ID received by the app; **mints a click** (Universal/App Links bypass the redirect server) |
| POST | `/v1/sdk/events` | Batch app events (≤ 100) |
| POST | `/v1/sdk/identify` | Set/clear customer user ID, with optional identity token |
| POST | `/v1/sdk/push-token` | Register/refresh push token `{provider:"apns"|"fcm", token, apns_environment?}` |
| POST | `/v1/sdk/opt-out` | Stop processing; erase device fields |
| POST | `/v1/sdk/attest/challenge` | Attestation challenge |
| POST | `/v1/sdk/apple-search-ads` | AdServices token submission |
| POST | `/v1/sdk/referrals/link` | Get-or-create the current user's referral link + code for a program (requires identified user; identity token if program requires it) |
| GET | `/v1/sdk/referrals/me` | Referrer's own stats for a program: code, link, invited/installed/qualified counts (identity token if required). No referee personal data |
| POST | `/v1/sdk/referrals/apply-code` | Referee manually enters a friend's code |
| GET | `/v1/sdk/referrals/referred-by` | For the current installation: whether it was referred, program, referrer display info allowed by the app (only `referrer_id` and optional `referrer_display_name` the app supplied), referral status |

#### `POST /v1/sdk/install` request
```json
{
  "installation_id": "6a1f...",
  "keychain_previous_installation_id": "b8c2...",
  "app_version": "3.4.1", "sdk_version": "1.0.0", "platform": "ios",
  "os_version": "18.1", "device_model": "iPhone15,2",
  "locale": "en-NG", "timezone": "Africa/Lagos",
  "screen": {"w": 1179, "h": 2556, "scale": 3},
  "launch_url": null,
  "install_referrer": {"referrer": "cg_click_id=clk_...", "referrer_click_timestamp_seconds": 0,
    "install_begin_timestamp_seconds": 0, "referrer_click_timestamp_server_seconds": 0,
    "install_begin_timestamp_server_seconds": 0, "install_version": "3.4.1"},
  "installer_package": "com.android.vending",
  "pasteboard_token": "cgdl_9Xk2...",
  "push": {"provider": "fcm", "token": "...", "apns_environment": null},
  "attestation": {"type": "app_attest", "token": "..."},
  "consent": {"tracking_allowed": true},
  "is_emulator": false
}
```

#### `POST /v1/sdk/install` response
```json
{
  "install_id": "ins_...",
  "attribution": {"status": "attributed", "match_type": "install_referrer", "confidence": 1.0,
    "click_id": "clk_...", "clicked_at": "...", "is_reinstall": false,
    "link": {"id": "lnk_...", "kind": "referral", "external_reference": null, "campaign_id": null, "metadata": {}}},
  "deep_link": {"url": "https://inv.myapp.com/r/ADA42", "path": "/welcome", "data": {"ref": "ADA42"}, "is_deferred": true},
  "referral": {"referral_id": "ref_...", "program_id": "rpg_...", "status": "installed",
    "referrer_id": "rfr_...", "referrer_display_name": "Ada"},
  "retry_after_ms": null
}
```

#### `POST /v1/sdk/referrals/link`
Request: `{"program_id": "rpg_...", "display_name": "Ada"}` (installation must be identified; header `Clikgate-Identity-Token` if required).
Response: `{"referrer_id":"rfr_...","code":"ADA42","url":"https://inv.myapp.com/r/ADA42","short_url":"https://inv.myapp.com/a8K2"}`. Idempotent per (program, customer_user_id).

#### `POST /v1/sdk/referrals/apply-code`
Request: `{"program_id":"rpg_...","code":"ADA42"}`. Rules: program allows manual entry; installation has no referral yet in this program; install age ≤ `manual_code_entry_window_days`; code exists and referrer active; not self-referral (8.4). Response: referral object or error `code_not_found|already_referred|window_expired|self_referral|program_paused`.

### 5.3 Server-to-server (customer backend → Clikgate), control-plane auth
| Method | Path | Scope | Purpose |
|---|---|---|---|
| POST | `/v1/apps/{app_id}/events` | conversions:write | Server-side events identified by `installation_id` or `customer_user_id` |
| POST | `/v1/apps/{app_id}/identify` | conversions:write | Link a customer user ID to an installation server-side (verified identity) |

---

## 6. Redirect and landing changes

Apply after link resolution and rule evaluation, when `app_ids` is set and `app_behavior != web_only`.

### 6.1 Platform and in-app browser detection
UA-based platform (`ios|android|desktop|other`) and in-app browser markers (Instagram, `FBAN`/`FBAV`, WhatsApp, TikTok `musical_ly`, X/Twitter, Snapchat, LinkedIn, Gmail/GSA). Marker list in config with tests.

### 6.2 Android
Reaching the server means the App Link didn't open the app.
- `app_or_store`: Chrome-based non-in-app browser → `302` to `intent://{host}/{path}#Intent;scheme=https;package={package};S.browser_fallback_url={urlencoded PLAY_URL};end`; otherwise `302` to `PLAY_URL`.
- `PLAY_URL = https://play.google.com/store/apps/details?id={package}&referrer={urlencode("cg_click_id={click_id}&cg_link={link_id}" + utm)}`.
- `app_or_web`: destination URL with click ID.

### 6.3 iOS
Reaching the server means the Universal Link didn't open the app (not installed, or in-app browser).
- Serve the **interstitial** when `ios_interstitial = always`, or `auto` and (in-app browser, or pasteboard/probabilistic enabled, or link `kind = referral`). Otherwise `302` to `https://apps.apple.com/app/id{ios_app_store_id}`.
- Interstitial (< 30 KB, inline CSS/JS, works without JS):
  - App name/icon, link OG title/image; for referral links: "{display_name} invited you to {App}" if the app supplied a display name.
  - **Open in app** → `{uri_scheme}://{deep_link_path}?cg_click_id=…`, falls back to App Store after ~1.5 s.
  - **Get the app** → if pasteboard matching is on, copy `cgdl_<token>` via `navigator.clipboard.writeText` on tap (user gesture), with visible explanation; store `dfr:{token}`; then go to App Store.
  - If probabilistic matching enabled: post coarse signals (screen w/h/dpr, timezone, languages, OS version) to `/_cg/signals` before navigating. No canvas/WebGL/audio/font probing.
  - In-app browser hint: "Open in Safari".

### 6.4 Signals endpoint
`POST https://{link_domain}/_cg/signals` `{click_id, screen, timezone, languages, os_version}` → Redis `prb:{app_id}:{ip_hmac}` sorted set, TTL = window. Accept only for clicks < 2 minutes old with probabilistic enabled for a target app.

### 6.5 Referral code URL patterns (bring-your-own URL format)
For each active referral program, its `code_url_patterns` are registered on `link_domain`. When a request path matches a pattern (e.g. `/r/ADA42` or `/invite?ref=ADA42`):
1. Look up referrer by `code` or `external_code` (case-insensitive) in the program (cache `refcode:{program_id}:{code}` in Redis).
2. Unknown code → program `link_defaults.fallback_url` or app store, with no referrer.
3. Known → treat exactly as the referrer's link (mint click with `referral_program_id`, `referrer_id`), continue with 6.2/6.3.

This lets apps that already share `https://myapp.com/invite?ref=CODE` point that domain (or a subdomain) at Clikgate without changing what users share.

### 6.6 Well-known files
AASA `components` include the link paths and code patterns, excluding `/_cg/*` and `/*+`. assetlinks unchanged.

---

## 7. Attribution engine

`app/services/attribution/` — matchers + pure decision core. `/sdk/install` budget 300 ms; slow paths (Apple Search Ads) return `pending` and finish async (`install.attribution_updated`).

### 7.1 Install attribution order
1. **Opt-out** (`tracking_allowed = false`) → organic, no matching, no referral.
2. **Attestation enforce + invalid** → organic, flag.
3. **Launch URL** on a Clikgate domain → `app_link`.
4. **Install Referrer** (Android) → `install_referrer`. Click must exist, belong to org, link targets this app, click within `install_lookback_days`. Flag `referrer_timestamp_inconsistent` if install began before click.
5. **Pasteboard token** (iOS) → `pasteboard`; single-use.
6. **Probabilistic** (only if enabled) → `probabilistic`; same-IP gate, scoring (7.2), top candidate ≥ min_confidence, margin ≥ 0.15 over runner-up, fewer than 5 candidates on the IP.
7. Else **organic**.

Reinstall (iOS Keychain): new install `is_reinstall = true`, `previous_install_id`. Re-attribute to a new deterministic click only if previous install inactive longer than `reattribution_window_days`.

### 7.2 Probabilistic scoring (config constants, unit-tested)
Same IP HMAC required. OS major.minor match +0.35 (major only +0.15; mismatch reject); screen+DPR exact +0.25 (mismatch reject); timezone exact +0.15 (mismatch −0.3); primary language +0.1; time since click ≤ 10 min +0.15, ≤ 30 min +0.1. Cap 1.0.

### 7.3 Apple Search Ads
Worker resolves AdServices token with Apple's API (verify current endpoint). Recorded as a separate touch; wins if no deterministic Clikgate match; if both, the later touch before install wins (Clikgate wins when Apple gives no click date).

### 7.4 Re-engagement and event attribution
- `/sdk/resolve` and `/sdk/open` with a Clikgate URL create `app_opens`; `is_reengagement` if last open older than `reattribution_window_days`; emit `app.reengaged`.
- Events attributed to the latest touch (install or re-engagement) within `event_attribution_window_days`. Rules in `app_event_rules` promote events to conversions (`external_id = "app_event:{app_id}:{event_id}"`, `source = sdk`, `click_id` = attributed click) so existing `conversion.*` webhooks fire.

### 7.5 Install fraud flags
`ctit_too_short` (Android install < 10 s after click), `referrer_timestamp_inconsistent`, `attestation_invalid`, `install_burst` (> 20 installs/hour per IP HMAC per link), `emulator` (not allowed unless sandbox). Flagged installs are visible but count as organic for referrals and payouts.

---

## 8. Referrals (core)

### 8.1 Program lifecycle and referrer creation
- Customer creates a program (control-plane API 10.2), choosing the app(s), link domain, code format, URL patterns, qualification rules, fraud settings and (optionally) reward info.
- Referrers are created:
  - **Server-side**: `POST /v1/referral-programs/{id}/referrers` `{customer_user_id, display_name?, external_code?, code?}` (idempotent on customer_user_id). Returns code + link.
  - **Bulk import** (apps with existing systems): `POST /v1/referral-programs/{id}/referrers/import` `{referrers:[{customer_user_id, external_code, display_name?}]}` ≤ 1,000 per call (bulk job). Existing codes keep working via 6.5.
  - **Client-side** via SDK `createReferralLink()` → `/sdk/referrals/link` (if `client_link_creation`), requiring an identified installation and, if `require_identity_token`, a valid identity token.
- Each referrer gets one Clikgate link (`kind = referral`, `referrer_id`, `referral_program_id`, deep link defaults from the program) on the program's domain; slug random, plus the code URL (`/r/{code}`).

### 8.2 Optional reward information (not recorded by default)
`referral_programs.reward` is `null` unless the customer sets it:
```json
{
  "referrer": {"amount_minor": 100000, "currency": "NGN", "description": "₦1,000 wallet credit"},
  "referee":  {"amount_minor": 50000,  "currency": "NGN", "description": "₦500 off first order"},
  "note": "Paid by the app; Clikgate does not pay rewards"
}
```
- Amounts optional even within this object (description-only is valid).
- At qualification, if `reward` is set, copy it into `referrals.reward_snapshot` and include it in `referral.qualified` webhooks and reports. If `null`, no reward fields appear anywhere.
- Changing `reward` affects only referrals that qualify afterwards.
- Clikgate never initiates payments.

### 8.3 Qualification rules
`referral_programs.qualification`:
```json
{
  "steps": [
    {"event": "signup", "within_days": 7},
    {"event": "purchase", "within_days": 14, "min_revenue_minor": 500000, "currency": "NGN"}
  ],
  "hold": {"days": 7, "require_installed": true, "min_active_days": 3},
  "counting": "from_install"            // step windows counted from install (or "from_previous_step")
}
```
- `steps` are ordered; each matches an app event name (from SDK or server events), with optional revenue threshold and property filters `{"properties": {"plan": "pro"}}`. Zero steps allowed (install-only programs).
- Signup step may also be satisfied by `/sdk/identify` with a new customer user ID if `{"event": "$identify"}` is used.
- `hold`: after the last step, referral enters `holding` until `hold_until = last_step_at + days`. At expiry, it qualifies only if: **not uninstalled** (when `require_installed` and uninstall tracking enabled for the app; if uninstall tracking is disabled, this check is skipped and documented), and the referee was active on at least `min_active_days` distinct days since install (from opens).
- Timeouts: a step not completed within its window → `disqualified` (`step_timeout`).

### 8.4 Fraud and eligibility rules (`referral_programs.fraud`)
Defaults (all configurable):
```json
{
  "block_self_referral": true,
  "block_existing_users": true,
  "block_reinstall_rereferral": true,
  "require_attestation": false,
  "allow_emulators": false,
  "max_referrals_per_referrer_per_day": 20,
  "max_installs_per_ip_per_day": 5,
  "auto_block_referrer_quality_below": null
}
```
Checks at referral creation and again at qualification:
- **Self-referral**: referee installation ID ∈ referrer's `known_installation_ids`; referee `customer_user_id` = referrer's; referee iOS Keychain previous installation ID belongs to the referrer; same push token hash as any of the referrer's installs. → `rejected` (`self_referral`).
- **Existing user**: referee `customer_user_id` already seen on an earlier install of the app (before this install) → `rejected` (`existing_user`) when identified.
- **Reinstall re-referral**: install `is_reinstall` and the previous install was already a referee or organic install with activity → `rejected`.
- **Velocity**: referrer exceeds daily cap → further referrals `rejected` (`velocity_limit`) and flagged.
- **IP bursts**: more than `max_installs_per_ip_per_day` referred installs from the same IP HMAC for one referrer → flagged; beyond 2× → rejected.
- **Attestation / emulator** per settings.
- **Probabilistic matches** rejected unless `allow_probabilistic`.
- **Referrer blocked** → new referrals rejected.

### 8.5 Identity tokens (prevent impersonation)
App backend computes `identity_token = base64url(HMAC_SHA256(app_identity_secret, customer_user_id + "." + issued_at_unix))` + `.` + issued_at. SDK passes it to `identify()`. Server verifies (max age 30 days, configurable). Identity secret managed via `POST /v1/apps/{id}/identity-secret/rotate` (shown once). When `require_identity_token` is true, referral link creation, `referrals/me` and referee "existing user" checks only trust verified identities.

### 8.6 Referral state machine
```
(created at install or code entry)
installed ──signup step──▶ signed_up ──more steps──▶ in_progress ──last step──▶ holding
   │                         │                         │                         │
   ├─fraud────────▶ rejected  ├─timeout──▶ disqualified ├─timeout──▶ disqualified ├─hold passes──▶ qualified
                                                                                 └─uninstalled/inactive──▶ disqualified
```
- With zero steps, `installed → holding` immediately.
- `qualified` and `rejected` are terminal; `disqualified` is terminal except via staff/API override (`POST /v1/referrals/{id}/override` with reason, audit-logged).
- After `qualified`, if the referee later uninstalls, set `referee_uninstalled_after_qualification = true` and emit `referral.referee_uninstalled` (reporting only; no status change).
- Every transition writes `referral_state_changes` and an outbox event.

### 8.7 Referrer quality score
Nightly job: score 0–100 from qualified rate, referee 7-day uninstall rate, fraud flag rate, velocity anomalies. Optional auto-block below `auto_block_referrer_quality_below`. Exposed in APIs and `referrer.quality_changed` webhook (on band change: `good|watch|poor`).

---

## 9. Uninstall tracking (all app customers)

### 9.1 How it works
1. App owner uploads push credentials (APNs .p8 key and/or FCM service account) and enables `uninstall_tracking`.
2. SDK registers the push token on every launch and on token refresh (`/sdk/push-token`, also included in `/sdk/install`). Tokens stored encrypted; `push_token_hash` for dedupe.
3. Scheduler sends a **silent push** to each tracked install per schedule: first check after `first_check_after_hours`, daily until `daily_until_day`, weekly until `weekly_until_day`, then stop.
4. Provider response decides status:
   - **APNs** `410 Unregistered` → `uninstalled` (evidence `apns_410`; use the timestamp APNs returns as `uninstalled_detected_at` when provided).
   - **FCM** HTTP v1 `404` with `UNREGISTERED` → `uninstalled` (evidence `fcm_unregistered`).
   - APNs `400 BadDeviceToken` / `DeviceTokenNotForTopic`, FCM `400 INVALID_ARGUMENT` on token → `unknown` (bad token or environment mismatch), stop checking until a new token arrives.
   - Auth errors → mark credentials `invalid`, pause checks for the app, email admins, emit `app.push_credentials_invalid`.
   - 429 / 5xx → retry later with backoff.
   - Verify exact status codes and error bodies against current APNs and FCM documentation.
5. Emit `install.uninstalled`. If the install later opens the app or registers a new token after being marked uninstalled → set `uninstall_reverted_at`, status `installed`, emit `install.uninstall_reverted` (false positive or reinstall without Keychain).
6. A newer token for the same installation always supersedes an older one; never mark uninstalled based on a stale token.

### 9.2 Push payloads (no user-visible notification)
- **APNs** (HTTP/2, token-based auth with the .p8 key): headers `apns-push-type: background`, `apns-priority: 5`, `apns-topic: {bundle_id}`, `apns-expiration: 0`; body `{"aps":{"content-available":1},"cg":{"t":"uc"}}`.
- **FCM HTTP v1**: `{"message":{"token":"…","data":{"cg":"uc"},"android":{"priority":"normal","ttl":"0s"},"apns":{"headers":{"apns-push-type":"background","apns-priority":"5"},"payload":{"aps":{"content-available":1}}}}}` (FCM may be used for iOS tokens too when the app uses FCM on iOS).
- SDKs recognise `cg`/`uc` and swallow the message (10.4, 11.4). Apps must forward incoming data/remote notifications to the SDK; document this clearly for apps with custom push handling.

### 9.3 Sender implementation
- `app/services/uninstall/apns.py`: HTTP/2 client (httpx with `http2=True`), JWT provider token cached and rotated (verify current refresh interval), per-app connection pooling, production vs sandbox hosts.
- `app/services/uninstall/fcm.py`: OAuth2 access token from service account (`google-auth`), per-project concurrency limits.
- Worker `uninstall_check_dispatcher` every minute: select installs where `next_uninstall_check_at <= now` (batch 5,000, `FOR UPDATE SKIP LOCKED`), group by app/provider, send with bounded concurrency, record `uninstall_checks`, compute next check time.
- Respect provider quotas; jitter schedules so checks spread across the day.
- Credentials test endpoint sends to a supplied test token and reports the result.

### 9.4 Privacy and limits
- Document: detection is not real-time (iOS can lag days), works only for installs that registered a push token, needs push credentials, and silent pushes are only used for this check.
- No user-visible notification is ever sent by Clikgate.
- Opted-out installs are never checked; erasure deletes tokens.

---

## 10. Customer-facing control-plane APIs

### 10.1 Apps, SDK settings, credentials (scope `apps:manage`)
| Method | Path | Purpose |
|---|---|---|
| PATCH | `/v1/apps/{id}/sdk-settings` | Update `settings`; enabling probabilistic requires owner + acknowledgement |
| POST | `/v1/apps/{id}/sdk-key/rotate` | New SDK key; old valid 30 days |
| POST | `/v1/apps/{id}/identity-secret/rotate` | New identity secret (shown once) |
| PUT | `/v1/apps/{id}/push-credentials/apns` | `{key_id, team_id, topic, p8, environment}` |
| PUT | `/v1/apps/{id}/push-credentials/fcm` | `{project_id, service_account_json}` |
| GET | `/v1/apps/{id}/push-credentials` | Status only (no secrets) |
| POST | `/v1/apps/{id}/push-credentials/test` | `{provider, token}` → provider result |
| DELETE | `/v1/apps/{id}/push-credentials/{provider}` | |
| GET | `/v1/apps/{id}/sdk-status` | Integration health and warnings (14) |
| GET/POST/PATCH/DELETE | `/v1/apps/{id}/event-rules` | Promote events to conversions |
| POST/GET/PATCH | `/v1/apps/{id}/conversion-value-schemas`, `/activate` | AdAttributionKit/SKAN schemas |
| POST | `/v1/apps/{id}/sandbox/reset-installation` | Sandbox apps: reset an installation for re-testing |

### 10.2 Referral programs and referrers (scopes `links:write` / `links:read` / `attribution:read`)
| Method | Path | Purpose |
|---|---|---|
| POST | `/v1/referral-programs` | Create program |
| GET | `/v1/referral-programs` · `/{id}` | List / retrieve |
| PATCH | `/v1/referral-programs/{id}` | Update (qualification/fraud/reward changes apply to new referrals; existing in-flight referrals keep the rules snapshot taken at creation — store `rules_snapshot` on referral) |
| POST | `/v1/referral-programs/{id}/pause` · `/resume` · DELETE (archive) | Paused: links still open the app but no new referrals created |
| POST | `/v1/referral-programs/{id}/referrers` | Get-or-create referrer by `customer_user_id` |
| POST | `/v1/referral-programs/{id}/referrers/import` | Bulk import (job) |
| GET | `/v1/referral-programs/{id}/referrers` | List; filters `status`, `quality_band`, `q` (code/customer_user_id), sort by qualified/installs |
| GET | `/v1/referrers/{id}` · `/v1/referral-programs/{id}/referrers/by-user/{customer_user_id}` · `/by-code/{code}` | Retrieve |
| PATCH | `/v1/referrers/{id}` | display_name, external_code |
| POST | `/v1/referrers/{id}/block` · `/unblock` | |
| GET | `/v1/referrals` | Filters: program_id, referrer_id, status, reason, from, to, referee_customer_user_id |
| GET | `/v1/referrals/{id}` | Includes state history |
| POST | `/v1/referrals/{id}/override` | Staff/owner override with reason (`qualify` or `disqualify`) |
| POST | `/v1/referrals/{id}/steps` | Server-side: mark a step complete when the event isn't sent via SDK (`{event, occurred_at, revenue?}`) — same validation as events |

Program create body example:
```json
{
  "name": "Invite friends",
  "app_ids": ["app_ios_...", "app_android_..."],
  "link_domain": "inv.myapp.com",
  "code_format": {"length": 6, "prefix": ""},
  "code_url_patterns": ["/r/{code}", "/invite?ref={code}"],
  "link_defaults": {"deep_link_path": "/welcome", "deep_link_data": {"screen": "referral_welcome"},
                    "og_title": "Join me on MyApp", "og_image_url": "https://…"},
  "allow_manual_code_entry": true,
  "client_link_creation": true,
  "require_identity_token": true,
  "qualification": {"steps": [{"event": "signup", "within_days": 7}, {"event": "purchase", "within_days": 14}],
                    "hold": {"days": 7, "require_installed": true, "min_active_days": 3}},
  "fraud": {"max_referrals_per_referrer_per_day": 20},
  "reward": null
}
```

### 10.3 Installs, events, uninstalls, analytics (`attribution:read`, `analytics:read`)
| Method | Path | Purpose |
|---|---|---|
| GET | `/v1/installs` | Filters incl. `uninstall_status`, `match_type`, `link_id`, `fraud_flag` |
| GET | `/v1/installs/{id}` · `/by-installation/{installation_id}?app_id=` · `/by-customer-user/{id}?app_id=` | |
| GET | `/v1/app-events` | Filters |
| GET | `/v1/analytics/apps/summary` | Metrics: clicks, installs, reinstalls, re-engagements, opens, events by name, revenue, click→install rate, median CTIT, **uninstalls, D1/D7/D30 uninstall rate**, grouped by link/campaign/external_reference/metadata.key/match_type/country/os/day |
| GET | `/v1/analytics/referrals/summary` | Per program: referrers active, invites (links created), clicks, installs, signups, qualified, disqualified by reason, rejected by reason, median time to qualify, referee D7 uninstall rate; group_by referrer/day/source; optional reward totals **only when program has reward amounts** |
| GET | `/v1/analytics/referrals/leaderboard` | Top referrers by qualified referrals in a period |
| GET | `/v1/apps/{id}/skan/reports` | AdAttributionKit/SKAN reports |
| POST | `/v1/privacy/requests` · GET `/{id}` | Erasure/export by installation or customer user ID (covers installs, events, referrals as referee; as referrer, anonymise customer_user_id and display_name) |

---

## 11. AdAttributionKit / SKAdNetwork postback copies

- App Info.plist points postback copies to a Clikgate domain: AdAttributionKit `AttributionCopyEndpoint` inside the `AdAttributionKit` dictionary; SKAdNetwork `NSAdvertisingAttributionReportEndpoint`. Apple posts to `/.well-known/appattribution/report-attribution/` and `/.well-known/skadnetwork/report-attribution/`. **Verify keys, paths, payloads and signature verification against current Apple documentation.**
- Receive on the platform domain, verify Apple's signature, store in `skan_postbacks`, map to app by advertised app ID → `ios_app_store_id`, decode with active schema, report via 10.3, emit `skan.postback_received`.
- iOS SDK updates conversion values on-device from the schema in `/sdk/config` (AdAttributionKit where available, SKAdNetwork otherwise; verify current API signatures).

---

## 12. Webhook event types (add to existing catalogue)

| Type | When |
|---|---|
| `install.attributed` | Install attributed |
| `install.organic` | Organic install (opt-in) |
| `install.attribution_updated` | Async change (e.g. Apple Search Ads) |
| `install.fraud_flagged` | Install flagged |
| `install.uninstalled` | Uninstall detected |
| `install.uninstall_reverted` | Install seen again after being marked uninstalled |
| `app.reengaged` | Re-engagement open |
| `app_event.received` | App event stored (opt-in, filter by names) |
| `app.push_credentials_invalid` | APNs/FCM auth failure |
| `referral.created` | Referral created (state `installed`) |
| `referral.step_completed` | A qualification step completed (`step_index`, `event`) |
| `referral.holding` | Entered hold period (`hold_until`) |
| `referral.qualified` | Qualified — the app should reward. Includes `reward_snapshot` **only if** program has reward info |
| `referral.disqualified` | With reason |
| `referral.rejected` | With reason (fraud/eligibility) |
| `referral.referee_uninstalled` | Referee uninstalled after qualification (reporting) |
| `referrer.created` | Referrer created |
| `referrer.blocked` · `referrer.unblocked` | |
| `referrer.quality_changed` | Quality band changed |
| `skan.postback_received` | Postback copy stored |

`referral.*` payload object: referral fields + `program {id, name}` + `referrer {id, customer_user_id, code}` + `referee {install_id, installation_id, customer_user_id}` + `link {id}` + `reasons/flags`. No reward fields unless configured.

---

## 13. Workers and jobs (add to existing Arq settings)

| Job | Schedule | Purpose |
|---|---|---|
| `process_sdk_events` | stream/queue | Store events, attribute, promote to conversions, advance referrals |
| `referral_step_timeouts` | every 10 min | Disqualify referrals past step windows |
| `referral_hold_evaluator` | every 10 min | Evaluate `holding` referrals past `hold_until` (uninstall + activity checks) |
| `referral_quality_scores` | nightly | Recompute referrer quality, auto-block if configured |
| `referrer_stats_cache` | every 15 min | Refresh `referrers.stats` |
| `uninstall_check_dispatcher` | every minute | Section 9.3 |
| `uninstall_schedule_backfill` | hourly | Set `next_uninstall_check_at` for newly tracked installs / new tokens |
| `apple_search_ads_resolver` | queue | 7.3 |
| `skan_decoder` | queue | Decode postbacks |
| `privacy_requests` | queue | Erasure/export |
| `retention_cleanup` | daily | Installs/events 25 months (configurable), opens 13 months, uninstall_checks 6 months, SDK logs 7 days |

---

## 14. Security, privacy, developer experience

- SDK key is public: rely on rate limits, validation, attestation, fraud flags, identity tokens for referrer actions.
- **App Attest** server verification (certificate chain to Apple App Attestation root, challenge, app ID, counter) and **Play Integrity** token verification (customer links Google Cloud project; credentials encrypted per app). Verify current procedures.
- IPs only as daily-salted HMAC; never raw; probabilistic signals Redis-only.
- Push tokens, APNs keys, FCM service accounts, identity secrets: encrypted at rest (Fernet), never returned by APIs after creation.
- Advertising IDs off by default (IDFA only with ATT `authorized` and setting enabled; GAID only with AD_ID permission, user not opted out, setting enabled). Not used for matching in this build.
- `restricted_mode` (kids/regulated apps): disables probabilistic, advertising IDs, device model; uninstall tracking still allowed.
- `GET /v1/apps/{id}/sdk-status` warnings: AASA/assetlinks unreachable or missing IDs; Play installs without referrer data; no push tokens received while uninstall tracking enabled; push credentials invalid; high `pending`/`organic` share on app links; old SDK versions; referral program with zero qualified referrals after N installs (rules may be too strict).
- `GET /v1/links/{id}/debug?platform=ios&in_app_browser=instagram` → what the redirect would serve.

---

## 15. Android SDK (Kotlin)

### 15.1 Packaging
`com.clikgate:clikgate-android` on Maven Central. Dependencies: Play Install Referrer library, AndroidX Core, WorkManager; Play Integrity optional (`compileOnly` + runtime check). **No Firebase dependency** — the app passes push tokens and forwards messages. Consumer R8 rules. Size < 150 KB (excl. Install Referrer). Verify current artifact coordinates.

### 15.2 Public API
```kotlin
Clikgate.configure(context, sdkKey = "cg_sdk_...", options = ClikgateOptions(
    linkDomains = listOf("inv.myapp.com"), logLevel = LogLevel.WARN,
    environment = Environment.PRODUCTION, attestation = Attestation.PLAY_INTEGRITY_IF_AVAILABLE))

Clikgate.handleIntent(activity, intent): Boolean           // onCreate + onNewIntent
Clikgate.onDeepLink { result -> }                           // path, data, isDeferred, link, matchType, referral
Clikgate.attribution { attribution -> }  ;  suspend fun Clikgate.awaitAttribution()

Clikgate.track("purchase", revenue = ClikgateMoney(1_500_000, "NGN"), properties = mapOf("order_id" to "A-1001"))
Clikgate.identify(customerUserId = "user_42", identityToken = "...")   // null to clear
Clikgate.setTrackingEnabled(false)

// Push / uninstall
Clikgate.setPushToken(token = fcmToken, provider = PushProvider.FCM)
Clikgate.isClikgateMessage(remoteMessageData: Map<String, String>): Boolean  // call in FirebaseMessagingService.onMessageReceived; return early if true

// Referrals
Clikgate.referrals.createLink(programId = "rpg_...", displayName = "Ada") { result: ReferralLinkResult -> } // code, url
suspend fun Clikgate.referrals.awaitLink(programId, displayName)
Clikgate.referrals.applyCode(programId, "ADA42") { result -> }           // referral or typed error
Clikgate.referrals.myStats(programId) { stats -> }                      // invited, installed, qualified
Clikgate.referrals.referredBy { info -> }                               // for the referee
Clikgate.referrals.shareIntent(context, programId, message = "Join me on MyApp: {url}") // ready Intent.ACTION_SEND
```

### 15.3 Behaviour
- First launch: generate installation ID (exclude from Auto Backup; document `fullBackupContent`/`dataExtractionRules`).
- Install Referrer once on first launch with retries (`SERVICE_UNAVAILABLE`, `FEATURE_NOT_SUPPORTED` handled); store a done flag.
- `installer_package` via `getInstallSourceInfo` (API 30+) / `getInstallerPackageName`.
- App Links + URI scheme in `handleIntent`; warm starts via `onNewIntent`.
- Opens on cold start and foreground after ≥ 30 min; events queued in SQLite (≤ 1,000 / 1 MB), flushed every 15 s / on background / at 20 events, WorkManager retry when offline; event IDs UUID at `track` time.
- Push token: send on every launch if changed since last send, and whenever `setPushToken` is called.
- `isClikgateMessage` returns true for `data["cg"] == "uc"`; such messages must not show notifications.
- Emulator detection sets `is_emulator` (heuristics in config).
- Deep link from install response waits up to 5 s on first launch (`deferredDeepLinkTimeout`), may arrive later.
- Thread-safe; callbacks on main thread; Java-friendly overloads.

### 15.4 Tests
JUnit + Robolectric: first launch, referrer parsing/timestamps (mock client), intents, queue/retry, push token change detection, `isClikgateMessage`, referral API calls and error mapping, opt-out. Instrumented App Link test in sample (`adb shell pm verify-app-links`).

---

## 16. iOS SDK (Swift)

### 16.1 Packaging
Swift Package + CocoaPods + XCFramework script. No third-party deps. Swift 5.9+, iOS 13+. `PrivacyInfo.xcprivacy` declaring data collected (installation ID for app functionality/analytics, not tracking; product interaction; purchase history when revenue events used; push token for app functionality) and any required-reason APIs (verify categories). Size < 400 KB.

### 16.2 Public API
```swift
Clikgate.configure(sdkKey: "cg_sdk_...", options: ClikgateOptions(
    linkDomains: ["inv.myapp.com"], logLevel: .warning, environment: .production,
    pasteboardMode: .automatic,            // .off | .automatic | .pasteControlOnly
    waitForATT: false, attestation: .appAttestIfAvailable))

Clikgate.shared.handle(url: URL) -> Bool
Clikgate.shared.continue(userActivity: NSUserActivity) -> Bool
Clikgate.shared.onDeepLink { (result: ClikgateDeepLinkResult) in }   // includes .referral
let attribution = try await Clikgate.shared.attribution()

Clikgate.shared.track("purchase", revenue: ClikgateMoney(amountMinor: 1_500_000, currency: "NGN"), properties: ["order_id": "A-1001"])
Clikgate.shared.identify(customerUserId: "user_42", identityToken: "...")
Clikgate.shared.setTrackingEnabled(false)

// Push / uninstall
Clikgate.shared.setPushToken(deviceToken: Data)                       // APNs (from didRegisterForRemoteNotificationsWithDeviceToken)
Clikgate.shared.setPushToken(fcmToken: String)                        // if the app uses FCM on iOS
Clikgate.shared.handleRemoteNotification(_ userInfo: [AnyHashable: Any]) -> Bool  // true = Clikgate check; call completionHandler(.noData)

// Referrals
let link = try await Clikgate.shared.referrals.createLink(programId: "rpg_...", displayName: "Ada")   // code, url
let referral = try await Clikgate.shared.referrals.applyCode(programId: "rpg_...", code: "ADA42")
let stats = try await Clikgate.shared.referrals.myStats(programId: "rpg_...")
let info = try await Clikgate.shared.referrals.referredBy()
Clikgate.shared.referrals.shareSheet(programId:message:from:)         // presents UIActivityViewController

ClikgatePasteControl(...)   // UIPasteControl wrapper (iOS 16+) to read pasteboard tokens without the system prompt
```

### 16.3 Behaviour
- Installation ID in app storage + Keychain (`AfterFirstUnlock`, not synced); report previous Keychain ID on reinstall.
- Pasteboard (if enabled server-side, first launch only): `detectPatterns(for:)` to check likelihood without reading; read `string` only if likely (iOS 16+ prompt expected); extract `cgdl_` token. Never read after first launch. `.pasteControlOnly` never reads automatically.
- Universal Links via `continue(userActivity:)`; schemes via `handle(url:)`; both → `/sdk/resolve`.
- Opens/events queue (JSON in Application Support, ≤ 1,000 / 1 MB), flush rules as Android, background-task safe.
- Push token sent on change and every launch if changed; `handleRemoteNotification` recognises `cg.t == "uc"`, does nothing else, returns true. The SDK never requests notification permission (silent pushes need only `registerForRemoteNotifications`); document Background Modes → Remote notifications capability.
- ATT never prompted by the SDK; `waitForATT` delays install call up to 30 s.
- Apple Search Ads token (iOS 14.3+) if enabled; AdAttributionKit/SKAN conversion value updates per schema; App Attest if enabled. Verify current APIs.
- All public methods thread-safe; callbacks on main.

### 16.4 Tests
XCTest: first launch/reinstall (Keychain mocked), URL parsing, queue persistence/retry, pasteboard token extraction (mocked), push token change, remote notification recognition, referral calls/errors, conversion value mapping, opt-out. Sample app UI test for Universal Links.

---

## 17. Flutter plugin `clikgate_flutter` (built with each native SDK)

Thin bridge over the native SDKs — **no attribution or referral logic in Dart**. Built in milestones 7 (Android side) and 8 (iOS side), with the Flutter example app as the primary demo.

### 17.1 Dart API
```dart
await Clikgate.configure(sdkKey: 'cg_sdk_...', linkDomains: ['inv.myapp.com']);

Clikgate.onDeepLink.listen((ClikgateDeepLink r) => router.go(r.path ?? '/', extra: r.data));
final attribution = await Clikgate.getAttribution();

await Clikgate.track('purchase', revenue: const ClikgateMoney(1500000, 'NGN'), properties: {'order_id': 'A-1001'});
await Clikgate.identify('user_42', identityToken: token);
await Clikgate.setTrackingEnabled(false);

// Push / uninstall (works with firebase_messaging)
await Clikgate.setPushToken(await FirebaseMessaging.instance.getToken(), provider: PushProvider.fcm);
FirebaseMessaging.instance.onTokenRefresh.listen((t) => Clikgate.setPushToken(t, provider: PushProvider.fcm));
// In the background handler and onMessage:
if (Clikgate.isClikgateMessage(message.data)) return;

// Referrals
final link = await Clikgate.referrals.createLink(programId: 'rpg_...', displayName: 'Ada');
await Share.share('Join me on MyApp: ${link.url}');           // app's own share plugin
final referral = await Clikgate.referrals.applyCode(programId: 'rpg_...', code: 'ADA42');
final stats = await Clikgate.referrals.myStats(programId: 'rpg_...');
final info = await Clikgate.referrals.referredBy();
```

### 17.2 Requirements
- Method channel for calls, event channel for deep links; **buffer deep-link events** received before Dart listeners attach and deliver on first subscription.
- Typed errors (`ClikgateException` with codes matching backend error codes: `code_not_found`, `already_referred`, `window_expired`, `self_referral`, `identity_required`, …).
- iOS: plugin registers for `application(_:continue:)` and `application(_:open:)` via the Flutter app delegate; document Associated Domains and Background Modes. Android: document intent filters (`autoVerify="true"`) and `onNewIntent` forwarding.
- `isClikgateMessage` implemented in Dart (pure check on the data map) so it works in background isolates.
- Example app: product deep link, referral invite screen (create link, share, stats), apply-code screen, referred-by banner, push token registration with `firebase_messaging`.
- Tests: Dart unit tests with mocked channels; integration test running the example on Android emulator and iOS simulator against a sandbox app.
- Publish to pub.dev with platform support declared.

---

## 18. React Native package

Same surface as Flutter (TypeScript): `configure`, `onDeepLink`, `getAttribution`, `track`, `identify`, `setTrackingEnabled`, `setPushToken`, `isClikgateMessage`, `referrals.{createLink, applyCode, myStats, referredBy}`. Expo config plugin for associated domains, intent filters, background modes. Early-event buffering. Example app.

---

## 19. Milestones (build in order)

1. **Backend schema & settings** — migrations (4.1–4.3), link fields + cache contract, app SDK settings, SDK key + identity secret issuance/rotation, push credentials storage.
2. **Redirect & landing** — platform/in-app browser detection, Android intent + Play referrer, iOS interstitial, pasteboard tokens, signals endpoint, referral code URL patterns, AASA updates.
3. **SDK API & attribution engine** — config, install, open, resolve, identify (+identity tokens), push-token, opt-out; matchers; reinstall; install fraud flags; `install.*`, `app.reengaged` webhooks.
4. **Events pipeline** — SDK + server events, event attribution, event rules → conversions, `app_event.received`.
5. **Referrals backend** — programs, referrers (API, import, SDK link creation), referral creation on install and code entry, qualification engine (steps, hold, timeouts), fraud checks, state machine + history, optional reward snapshot, overrides, quality scores, referral webhooks, referral analytics + leaderboard.
6. **Uninstall tracking backend** — APNs and FCM senders, scheduler, result handling, reversal on reappearance, credentials test, uninstall webhooks and analytics, hold-period integration with referrals.
7. **Android SDK + Flutter plugin (Android side) + Flutter example on Android + native Android sample** — including referrals, push token and message filtering.
8. **iOS SDK + Flutter plugin (iOS side) + Flutter example on iOS + native iOS sample** — including Universal Links, pasteboard, Keychain, referrals, push token and remote notification filtering.
9. **Attestation** — App Attest and Play Integrity server verification + SDK support.
10. **Apple Search Ads and AdAttributionKit/SKAdNetwork** — token flow, postback receiver, schemas, SDK conversion values, reports.
11. **React Native package + Expo plugin + example.**
12. **Customer APIs, analytics & developer tools** — installs/events/uninstall endpoints, apps analytics, SDK status warnings, link debugger, sandbox reset, privacy requests.
13. **Hardening & docs** — rate limits, retention jobs, kill switches, load tests (`/sdk/install`, `/sdk/events`, uninstall dispatcher at 1M installs/day), all docs, release pipelines (Maven Central, SPM tags, CocoaPods trunk, pub.dev, npm).

---

## 20. Testing

### Backend (pytest)
- Attribution: every branch of 7.1, reinstall, scoring boundaries, crowded IP, CTIT/timestamp flags, event windows, re-engagement.
- Referrals: program CRUD validation; referrer get-or-create idempotency; BYO code URL patterns (`/invite?ref=`); SDK link creation with/without identity token; manual code entry rules; every fraud rule (self-referral by installation, user ID, Keychain ID, push token; existing user; reinstall; velocity; IP burst; emulator; attestation; probabilistic); each state transition including timeouts and hold outcomes; rules snapshot isolation when program changes; reward snapshot present only when configured; overrides; quality score computation; webhooks payloads (no reward fields when null).
- Uninstall: APNs and FCM response mapping using mocked HTTP/2 / HTTP servers for 200, 410, 404 UNREGISTERED, 400 bad token, 403 auth error, 429, 5xx; schedule computation; stale-token protection; reversal on reappearance; credentials invalidation pause; referral hold disqualification on uninstall.
- Redirect: Android intent/Play URL encoding, iOS interstitial vs App Store, in-app browsers, pasteboard token, signals gating, referral pattern routing.
- SDK API: auth, idempotent install, events dedupe, opt-out, rate limits, attestation paths with fake verifiers.
- E2E (simulated devices):
  1. **Referral, Android**: create program (no reward) → referrer via API → click referral link as Android → Play referrer → `/sdk/install` with referrer → `referral.created` → `/sdk/identify` new user → `signup` event → `purchase` event → `holding` → advance clock past hold with 3 active days and no uninstall → `referral.qualified` webhook **without** reward fields.
  2. **Referral with reward + uninstall**: same with program reward set → referee uninstalls during hold (mock FCM `UNREGISTERED`) → `referral.disqualified` (`uninstalled_during_hold`); second referee qualifies → webhook **with** `reward_snapshot`.
  3. **Self-referral**: referrer's own second device identified as same customer user → `referral.rejected` (`self_referral`).
  4. **Manual code entry** on iOS without link match → referral via `code_entry`.
  5. **Uninstall for non-referral app**: install with push token → scheduled check → APNs 410 → `install.uninstalled` → later open → `install.uninstall_reverted`.

### SDK and device matrix
Unit tests per SDK (15.4, 16.4, 17.2). Manual device matrix before each release:

| Scenario | iOS | Android |
|---|---|---|
| App installed, link in Safari/Chrome | Universal Link → app | App Link → app |
| App installed, link in Instagram/WhatsApp/TikTok | Interstitial → Open in app | Intent / App Link |
| Not installed → install → open | Pasteboard (if on) / probabilistic (if on) / organic | Install Referrer deferred deep link |
| Referral link → install → signup → purchase → hold | Qualified webhook | Qualified webhook |
| Friend types code instead of using link | `applyCode` succeeds | Same |
| Uninstall during hold | Disqualified (may lag on iOS) | Disqualified |
| Reinstall | Keychain reinstall detection | New install (no prior ID) |
| Opted out | No data after opt-out | Same |
| Offline first launch | Install retried, deep link late | Same |

### Definition of done
- All backend tests and SDK unit tests pass in CI; Flutter plugin builds and its integration tests pass on Android emulator and iOS simulator; RN package builds.
- With the **Flutter example app** against a local Clikgate: Android deferred deep link via Install Referrer (Play internal test track) lands on the referral welcome screen; iOS Universal Link opens the right screen; iOS deferred deep link works with pasteboard enabled; a referral goes from link to `referral.qualified`; an uninstall during hold produces `referral.disqualified`; uninstall tracking detects removal on both platforms.
- Reward fields never appear unless the program sets them.
- Probabilistic matching off by default, gated by owner acknowledgement, globally switchable.
- `docs/REFERRALS.md`, `docs/UNINSTALL_TRACKING.md`, `docs/PRIVACY.md` complete and accurate.

---

## 21. Out of scope (design for later)

- Paying or managing reward balances (wallets, payouts) — Clikgate reports qualification only.
- Self-reporting ad networks and paid ad postbacks; cost/ROAS; IDFA/GAID matching against ad clicks.
- Store referrers beyond Google Play (Huawei, Samsung, Xiaomi) — add as matchers behind the same interface.
- Web-to-app smart banners; App Clips / Instant Apps.
- Multi-touch attribution; incrementality testing; audience exports; scheduled warehouse exports.
- Distyla-specific features (e.g. creator cost-per-install campaigns) — Distyla can build these on top of `install.attributed`, `referral.*` and `install.uninstalled` webhooks.
