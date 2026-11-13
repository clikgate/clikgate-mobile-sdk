# Clikgate SDK API contract (v1)

The single source of truth for what the mobile SDKs send to Clikgate and what they get
back. The backend (`clikgate_api`, `src/sdk`) implements it; the Android, iOS, Flutter and
React Native SDKs call it. JSON Schemas for every body are in `schemas/`, example payloads
in `fixtures/` (SDK unit tests load these instead of hand-writing JSON).

If you change a field here, change the schema, the fixture, the backend and every SDK in
the same change.

## Transport

- Base URL: `https://sdk.clikgate.com` (configurable in every SDK as `apiBaseUrl` for
  local testing, e.g. `http://10.0.2.2:8000` from the Android emulator).
- Every path starts with `/v1/sdk/`.
- Request and response bodies are JSON (`Content-Type: application/json; charset=utf-8`).
  Field names are `snake_case`. Unknown response fields must be ignored by SDKs (the
  server adds fields without bumping the version).
- Timestamps are UTC ISO 8601 with `Z` (`2026-10-20T10:02:41Z`; fractional seconds allowed).
- Goal values are decimal strings in normal units (`value`) plus `currency` (ISO 4217, uppercase).
- Timeouts: SDKs use 10 s connect + 10 s read.

### Headers (sent by SDKs)

| Header | When | Value |
|---|---|---|
| `Clikgate-SDK-Key` | always | the app's public key `cg_sdk_...` |
| `Clikgate-SDK-Version` | always | `<platform>/<semver>` of the outermost SDK: `android/1.0.0`, `ios/1.0.0`, `flutter/1.0.0`, `react-native/1.0.0` (Engage calls send the core's value) |
| `Clikgate-SDK-Native-Version` | when wrapped | the native SDK underneath a wrapper: `android/1.0.0` or `ios/1.0.0` |
| `Clikgate-Installation-Id` | every call after the installation id exists (i.e. always, including `/install`) | UUIDv4, lowercase |
| `Clikgate-Identity-Token` | referral calls, when the app supplied one | see "Identity tokens" |
| `Idempotency-Key` | `/goals` (batch UUID) | one random UUIDv4 per request, reused by that request's retries, never derived from the content (change 09, X.E15); the server dedupes goals by `(goal, reference)` anyway |

### Errors

Every non-2xx response has the standard Clikgate error body:

```json
{"error": {"type": "invalid_request", "code": "code_not_found", "message": "No referrer has this code.", "param": "code", "request_id": "req_..."}}
```

SDKs surface `error.code` as their typed error code (Flutter `ClikgateException.code`,
Kotlin `ClikgateError.code`, Swift `ClikgateError.code`, RN `error.code`).

| HTTP | `code` | Meaning / SDK behaviour |
|---|---|---|
| 401 | `invalid_sdk_key` | Unknown or expired SDK key. Log an error once; stop calling until the next app launch |
| 403 | `sdk_disabled` | Kill switch / app's SDK access disabled. Back off 1 h |
| 403 | `opted_out` | Installation opted out. Stop sending anything except `/opt-out` |
| 404 | `installation_unknown` | Call before a successful `/install`. Re-run the install flow |
| 409 | `install_in_progress` | Concurrent `/install` for the same installation. Retry after `Retry-After` |
| 422 | `validation_error` | Malformed body. Drop the request (don't retry) and log |
| 429 | `rate_limited` | Honour `Retry-After` (seconds) |
| 5xx | `server_error` / any | Retry with backoff |

Referral-specific codes (surfaced to the app, never retried automatically):

| HTTP | codes |
|---|---|
| 403 | `not_identified`, `identity_required`, `client_link_creation_disabled`, `manual_entry_disabled`, `referrer_blocked` |
| 404 | `program_not_found`, `code_not_found`, `referrer_not_found` |
| 409 | `program_paused`, `already_referred` |
| 422 | `window_expired`, `self_referral`, `identity_invalid` |
| 429 | `referral_link_limit` (with `Retry-After`; only creating a new referrer link counts) |

### Retry policy (SDKs)

Retry on network errors, 408, 429 and 5xx with exponential backoff
`min(60 s, 1 s * 2^attempt)` with ±20 % jitter. `/install` retries until it succeeds
(persisting across launches). Other calls give up after 5 attempts (events stay queued).

## Endpoints

### GET `/v1/sdk/config`

Feature flags and limits. SDKs cache it for 1 h (and use the cached copy offline).

Response `200` — `schemas/config_response.schema.json`:

```json
{
  "app_id": "app_01J...",
  "environment": "production",
  "server_time": "2026-10-20T10:00:00Z",
  "link_domains": ["inv.myapp.com", "ciz.to"],
  "features": {
    "deferred_deep_linking": true,
    "pasteboard_matching": "on_interstitial_tap",
    "probabilistic_matching": false,
    "apple_search_ads": false,
    "uninstall_tracking": true,
    "collect_advertising_id": false,
    "restricted_mode": false,
    "attestation": {"ios_app_attest": "off", "android_play_integrity": "monitor"}
  },
  "referral_programs": [
    {"id": "rpg_01J...", "name": "Invite friends", "status": "active", "client_link_creation": true, "allow_manual_code_entry": true, "require_identity_token": true}
  ],
  "batching": {"max_batch_size": 100, "flush_interval_seconds": 15, "flush_at_count": 20, "max_queue_events": 1000, "max_queue_bytes": 1048576},
  "reattestation_interval_days": 7,
  "session_timeout_minutes": 30
}
```

`pasteboard_matching` is `off` or `on_interstitial_tap`. (Change 22, R.5: there is no `conversion_value_schema`;
the SDKs never set SKAdNetwork / AdAttributionKit conversion values.)

`link_domains` (connected domains, backend Part 3 §31.3): every **active** link domain in the
organisation's domain groups, as host names (`["ybr.ng", "go.yourbrand.com"]`). Domains in a group are
aliases: `ybr.ng/a8K2` and `go.yourbrand.com/a8K2` are the same link. The field is **optional**
(servers before Part 3 omit it; the schema default is `[]`). SDKs:

- treat the effective domain set as `options.linkDomains` ∪ `link_domains` of the last successful
  `/config` (persisted with the config cache, so it applies offline and on the next cold start).
  The configured domains always count; server domains only add to them;
- compare host names case-insensitively (lowercased, trimmed; a scheme or path is stripped);
- ignore a malformed field (not an array → `[]`; non-string or empty items are dropped);
- log a warning (once per domain per launch) for each server domain missing from
  `options.linkDomains`: the OS opens the app only for domains in the iOS Associated Domains
  entitlement (`applinks:<domain>`) and the Android intent filters, so the developer has to add
  it there and to `linkDomains`.

### POST `/v1/sdk/install`

First launch of an installation id. **Idempotent per installation id**: calling it again
returns the same `install_id` and the current attribution (use this to poll while
`retry_after_ms` is set).

Request — `schemas/install_request.schema.json` (all fields except `installation_id`,
`platform`, `app_version`, `sdk_version` optional):

```json
{
  "installation_id": "6a1f0c2e-...",
  "keychain_previous_installation_id": "b8c2...",
  "app_version": "3.4.1", "sdk_version": "1.1.0", "platform": "ios",
  "os_version": "18.1", "device_model": "iPhone15,2",
  "locale": "en-NG", "timezone": "Africa/Lagos",
  "screen": {"w": 1179, "h": 2556, "scale": 3},
  "launch_url": null,
  "install_referrer": {
    "referrer": "cg_click_id%3Dclk_01J...%26cg_link%3Dlnk_01J...",
    "referrer_click_timestamp_seconds": 1760954400,
    "install_begin_timestamp_seconds": 1760954460,
    "referrer_click_timestamp_server_seconds": 1760954400,
    "install_begin_timestamp_server_seconds": 1760954460,
    "install_version": "3.4.1",
    "google_play_instant": false
  },
  "installer_package": "com.android.vending",
  "pasteboard_token": "cgdl_9Xk2...",
  "push": {"provider": "fcm", "token": "...", "apns_environment": null},
  "attestation": {"type": "app_attest", "token": "<base64>", "key_id": "<base64>", "challenge": "atc_..."},
  "apple_search_ads_token": null,
  "consent": {"analytics": "granted", "attribution": "granted", "ad_user_data": "unknown", "ad_personalization": "unknown", "region": null, "updated_at": null},
  "is_emulator": false,
  "is_rooted": false
}
```

- `platform`: `ios` | `android`.
- `install_referrer.referrer` is the raw string from the Play Install Referrer API,
  passed through unmodified (the server URL-decodes it).
- `screen.w/h` are physical pixels; `scale` is the device pixel ratio.
- **Opted out before the first launch** (`setTrackingEnabled(false)`): the SDK sends only the
  required fields and the consent object with **every purpose `denied`**
  (`fixtures/install_request_opted_out.json`); the server records an organic install and nothing
  else. Change 09 (X.E23): `attribution: "denied"` replaces the old `tracking_allowed: false`. SDKs
  from 1.5.0 (React Native 1.6.0) never send `tracking_allowed`; the backend keeps reading
  `tracking_allowed: false` from older SDKs.
- **Fraud signals** (change 02, B.5.2; all optional, SDK 1.1.0+, older SDKs send fewer of them).
  Device heuristics, so treat them as **hints, not proof**: each one only adds weight to a fraud
  score, never decides on its own. The SDK computes them once per request, never blocks or fails
  the install on them, and omits a field when its check fails. Not sent on the opted-out
  install (iOS still sends `is_emulator` there, as before).
  - `is_emulator`: Android emulator images (Build properties) / the iOS Simulator.
  - `is_rooted`: Android root heuristics (`test-keys` build tags, an `su` binary in a common
    path, a root-manager app below API 30) / iOS jailbreak heuristics (jailbreak file paths, a write
    outside the sandbox). iOS omits it on the Simulator and on Macs, where it can't be judged.
  - Click and install-begin times are the existing `install_referrer.referrer_click_timestamp_seconds`
    and `install_begin_timestamp_seconds` (plus the `*_server_seconds` variants), straight from the
    Play Install Referrer API (Android only; `null` when Play reports none). No top-level
    duplicates. When both are present the backend prefers the `*_server_seconds` values. They feed
    `ctit_too_fast` and `install_before_click`.
  - Rules: `emulator_or_rooted` (either flag `true`); see the change 02 spec for the weights.

Response `200` (also `201` on first creation; treat both the same) —
`schemas/install_response.schema.json`:

```json
{
  "install_id": "ins_01J...",
  "attribution": {
    "status": "attributed",
    "match_type": "install_referrer",
    "confidence": 1.0,
    "click_id": "clk_01J...",
    "clicked_at": "2026-10-20T09:59:00Z",
    "is_reinstall": false,
    "link": {"id": "lnk_01J...", "kind": "referral", "external_reference": null, "campaign_id": null, "metadata": {}}
  },
  "deep_link": {"url": "https://inv.myapp.com/r/ADA42", "path": "/welcome", "data": {"ref": "ADA42"}, "is_deferred": true},
  "referral": {"referral_id": "ref_01J...", "program_id": "rpg_01J...", "status": "installed", "referrer_id": "rfr_01J...", "referrer_display_name": "Ada"},
  "retry_after_ms": null
}
```

- `attribution.status`: `pending` | `attributed` | `organic`.
- `match_type`: `app_link` | `install_referrer` | `pasteboard` | `probabilistic` |
  `apple_search_ads` | `code_entry` | `null` (organic).
- `deep_link` and `referral` are `null` when there is none.
- `retry_after_ms` non-null ⇒ attribution is still `pending` (e.g. Apple Search Ads being
  resolved). The SDK calls `/install` again after that delay, at most 3 times, and emits
  the deep link if one arrives (marked `is_deferred: true`).

### POST `/v1/sdk/open`

App open: cold start, and foreground after ≥ `session_timeout_minutes` in background.
**Do not** send launch URLs here — URLs go to `/resolve`.

Request: `{"app_version": "3.4.1", "os_version": "18.1", "is_cold_start": true, "push": {"provider": "apns", "token": "...", "apns_environment": "production"}}`
(`push` only when the token changed since the last successful send).

Response `200`: `{"open_id": "aop_01J...", "uninstall_status": "installed"}`

### POST `/v1/sdk/resolve`

The app was opened by a URL (Universal Link, App Link or custom scheme), or received a
click id some other way. Universal / App Links bypass the redirect server, so this call
**mints the click**. Records an app open with the link (re-engagement detection).

Request: `{"url": "https://inv.myapp.com/r/ADA42?utm_source=x"}` or
`{"click_id": "clk_01J..."}` (custom-scheme URLs carrying `cg_click_id` should send the URL;
the server extracts the click id).

Response `200` — `schemas/resolve_response.schema.json`:

```json
{
  "matched": true,
  "click_id": "clk_01J...",
  "deep_link": {"url": "https://inv.myapp.com/r/ADA42", "path": "/welcome", "data": {"ref": "ADA42"}, "is_deferred": false},
  "link": {"id": "lnk_01J...", "kind": "referral", "external_reference": null, "campaign_id": null, "metadata": {}},
  "is_reengagement": false,
  "referral": null,
  "match_type": "app_link"
}
```

`match_type` is always `app_link` when matched (null otherwise); it is optional for older servers,
so SDKs default to `app_link`. Maps such as `deep_link.data`, `link.metadata` and event
`properties` cross every bridge (Flutter channels, RN modules) unchanged — no key case conversion.

`matched: false` (with everything else null) when the URL isn't a Clikgate link of this
organisation; the SDK then emits nothing and returns `false` from `handle(url)` for
non-Clikgate hosts without calling the server at all (hosts not in `link_domains` and
schemes other than the app's). Exception from SDK 1.4.0: an unmatched link on a shared platform
domain is opened in an in-app browser (below).

#### Shared platform domains (change 06, SDK 1.4.0)

`ciz.to` (paid), `clk.ng` (free), `clkg.to` (spare) and `dev.ciz.to` (test) are Clikgate's
platform short domains. Many organisations' links live on them, and their AASA / assetlinks list
every app that uses the domain, so iOS or Android can open *this* app for *another*
organisation's link. `/resolve` then answers `200` with the `matched: false` body above
(`fixtures/resolve_response_unmatched.json`).

When `/resolve` answers `matched: false` for a URL whose host (lowercased) is one of these four
and the app hasn't turned the fallback off (`platformDomainBrowserFallback`, default on), the SDK
opens the original URL in an **in-app browser** so the person still reaches the link's
destination: `SFSafariViewController` on iOS, Custom Tabs on Android (an explicit browser package;
a plain view intent to that browser when none supports Custom Tabs). Never
`UIApplication.open(_:)` or an implicit `ACTION_VIEW` intent: both can hand the Universal Link /
App Link straight back to the same app. No deep link is delivered (no fake match); the app gets a
**browser handoff** event (the URL and its shared host) instead (SDK_BEHAVIOUR.md "Change 06 (SDK 1.4.0)").
Custom domains and `matched: true` responses behave as before. The list is fixed in each SDK
(not from `/config`) and must equal `fixtures/shared_link_domains.json` (generated from
`SHARED_LINK_DOMAINS` in `generate.py`; each SDK's tests compare the two). A future shared domain
needs an SDK release; until then its unmatched links are dropped as before.

### App events (removed in Change 22)

There is no app-event call. `goal()` is the only method for what happens in an app; goals go to
`POST /v1/sdk/goals` ("Change 06 additions"). See "Change 22 additions".

### POST `/v1/sdk/identify`

Request: `{"customer_user_id": "user_42", "identity_token": "<token>"}`; send
`{"customer_user_id": null}` to clear (logout).

Response `200`: `{"customer_user_id": "user_42", "identity_verified": true}`.
`identity_invalid` (422) when a token was sent but doesn't verify; the SDK still keeps
the user id locally and reports the error to the app via the log.

### POST `/v1/sdk/push-token`

Request: `{"provider": "fcm", "token": "...", "apns_environment": null}`
(`provider`: `apns` | `fcm`; `apns_environment`: `production` | `sandbox` for APNs
tokens — the iOS SDK derives it from the provisioning profile's `aps-environment`,
defaulting to `production`).

Response `200`: `{"ok": true}`. SDKs send on every launch if the token changed since the
last successful send, and whenever the app calls `setPushToken`.

### POST `/v1/sdk/opt-out`

Request: `{"opt_out": true}` (or `false` to opt back in). Opting out erases the device
fields server-side and stops all processing. While opted out the SDK sends nothing else;
opting back in resumes normal calls (no new install is created).

Response `200`: `{"opt_out": true}`.

### POST `/v1/sdk/attest/challenge` and POST `/v1/sdk/attest`

`/attest/challenge` → `{"challenge": "atc_01J...", "nonce": "<base64url 32 bytes>", "expires_at": "..."}`.
The SDK attests with the `nonce` (App Attest: `clientDataHash = SHA256(nonce)`; Play
Integrity: `nonce` field / `requestHash`), then either includes `attestation` in
`/install` or, for the 7-day re-attestation, calls
`/attest` with `{"type": "app_attest" | "play_integrity", "challenge": "atc_...", "token": "...", "key_id": "..."}` →
`{"attestation_status": "valid" | "invalid" | "unavailable"}`.

App Attest: the first call sends the attestation object (`token`) and `key_id`; later
calls send an assertion (`type: "app_attest_assertion"`) for the same `key_id`.

Exact bytes (App Attest): `nonce` is base64url (no padding) of 32 random bytes; decode it to
those 32 bytes and pass `SHA256(nonce_bytes)` as `clientDataHash` to both
`attestKey(_:clientDataHash:)` and `generateAssertion(_:clientDataHash:)`. Send `token` as standard
base64 of the attestation / assertion object and `key_id` exactly as `generateKey()` returned it
(base64). Play Integrity: standard requests pass `requestHash = nonce` (the base64url string);
classic requests pass `nonce` as the nonce. Challenges are single use and expire after 5 minutes.

### POST `/v1/sdk/apple-search-ads`

Request: `{"token": "<AAAttribution.attributionToken()>"}` → `{"status": "pending"}`.
Resolved asynchronously; the result arrives on the next `/install` poll or as the
`install.attribution_updated` webhook.

### Referrals

`apply-code` and `referred-by` are called by the **core** SDKs; `link` and `me` only by the
**Engage features** (spec 0.4 / 17A; apps with a backend use the control-plane referrer API instead).

All referral calls need a successful `/install`. `link` and `me` also need an
identified installation (`/identify`), and, if the program's
`require_identity_token` is true, a valid identity token (sent on `/identify` or as the
`Clikgate-Identity-Token` header).

#### POST `/v1/sdk/referrals/link`

Request: `{"program_id": "rpg_...", "display_name": "Ada"}` → `200`:
`{"referrer_id": "rfr_...", "program_id": "rpg_...", "code": "ADA42", "url": "https://inv.myapp.com/r/ADA42", "short_url": "https://inv.myapp.com/a8K2"}`.
Idempotent per (program, customer user id).

#### GET `/v1/sdk/referrals/me?program_id=rpg_...`

`200`: `{"referrer_id": "rfr_...", "program_id": "rpg_...", "code": "ADA42", "url": "...", "short_url": "...", "status": "active", "stats": {"clicks": 12, "installs": 4, "signups": 3, "in_progress": 1, "qualified": 2, "disqualified": 0, "rejected": 1}}`.
`404 referrer_not_found` if the user has no link yet in that program.

#### POST `/v1/sdk/referrals/apply-code`

Request: `{"program_id": "rpg_...", "code": "ADA42"}` → `200` referral object (below).
Errors: `code_not_found`, `already_referred`, `window_expired`, `self_referral`,
`program_paused`, `manual_entry_disabled`, `referrer_blocked`.

#### GET `/v1/sdk/referrals/referred-by`

`200`: `{"referred": true, "referral": {...}}` or `{"referred": false, "referral": null}`.
With several programs, returns the most recent referral.

#### Referral object

```json
{"referral_id": "ref_01J...", "program_id": "rpg_01J...", "status": "installed", "source": "link",
 "referrer_id": "rfr_01J...", "referrer_display_name": "Ada", "created_at": "2026-10-20T10:00:00Z"}
```

`status`: `installed` | `signed_up` | `in_progress` | `holding` | `qualified` |
`disqualified` | `rejected`. `source`: `link` | `code_entry` | `byo_code`.

## Identity tokens

The app's backend computes, for the logged-in user:

```
issued_at = unix seconds (integer)
signature = base64url_nopad(HMAC_SHA256(identity_secret, f"{customer_user_id}.{issued_at}"))
identity_token = f"{signature}.{issued_at}"
```

`identity_secret` comes from `POST /v1/apps/{id}/identity-secret/rotate` (control-plane API,
shown once). Tokens are valid for 30 days. SDKs treat the token as opaque.

## Pasteboard tokens (iOS)

The interstitial copies `https://<link_domain>/_cg/p/cgdl_<26 base62>` (a URL, so iOS
can check `detectPatterns(for: [.probableWebURL])` without a paste prompt). On first launch
(only) the iOS SDK may read the pasteboard and sends the first match of
`cgdl_[0-9A-Za-z]{26}` found anywhere in the string as `pasteboard_token`. Tokens are
single-use. Opening that URL in a browser just redirects to the App Store.

`pasteboard_outcome` (optional, iOS only) says what that first-launch paste step saw, so the
dashboard can measure the iPhone match rate. It is omitted when the paste flow didn't run
(`pasteboardMode` `off`, `features.pasteboard_matching` not `on_interstitial_tap`, SDK blocked,
opted out or consent denied), and resent unchanged when `/install` is retried. It is an enum about
the paste step, never the pasteboard contents.

| value | meaning |
|---|---|
| `token_found` | a `cgdl_` token was read and is sent as `pasteboard_token` (also a Paste button token that arrives before the first `/install`) |
| `no_link` | `detectPatterns` said no web URL is likely (iOS 13: `hasStrings` false), so nothing was read |
| `no_token` | the pasteboard was read but held no Clikgate token |
| `denied` | a web URL was likely but reading returned nil (the user tapped "Don't Allow") |
| `paste_control` | `pasteboardMode` `.pasteControlOnly`: no automatic read; a token may arrive later through the Paste button retry |

Unknown values are rejected with 422. The server also stores `expired` (a token was sent but was not
redeemable) and sets `token_found` when a `.pasteControlOnly` retry redeems a token.

## Play Install Referrer (Android)

Clikgate builds the Play URL with
`referrer=urlencode("cg_click_id=<clk>&cg_link=<lnk>[&utm_...]")`. The SDK sends the
`referrer` string exactly as returned by `ReferrerDetails.getInstallReferrer()`.

## Uninstall-check pushes

Clikgate's silent pushes carry:
- APNs: `{"aps": {"content-available": 1}, "cg": {"t": "uc"}}`
- FCM: `data: {"cg": "uc"}`

`isClikgateMessage(data)` is true when `data["cg"] == "uc"` (FCM data map) or
`data["cg"]["t"] == "uc"` (APNs userInfo). Apps must not show a notification for these.

## SKAN / AdAttributionKit

Removed in Change 22 (R.5): `/config` has no `conversion_value_schema` and the iOS SDK never updates postback
conversion values from `goal()`. Postback copies still reach Clikgate through the app's `Info.plist` endpoints.

## v3 additions (spec v3: feature switches, leaderboards, identity checks, offline codes, WhatsApp)

### Feature switches

`GET /v1/sdk/config` → `features` gains one boolean per SDK-relevant organisation feature
(already resolved for this app): `app_attribution`, `referrals`, `leaderboards`,
`identity_checks`, `whatsapp_attribution`, `offline_codes`, `skan_postbacks` (plus the existing
`uninstall_tracking`, `probabilistic_matching`, `apple_search_ads`, which are now also gated by
their organisation feature). Missing keys mean "on" for `referrals`, `leaderboards`,
`offline_codes`, `app_attribution`, `deep_linking` (change 10) and "off" for the rest (older servers).

SDK endpoints of a switched-off feature answer **`200`** with this body instead of their normal
response:

```json
{"accepted": false, "reason": "feature_disabled", "feature": "leaderboards"}
```

SDKs must (1) skip the network call when the cached config already says the feature is off and
(2) recognise this body on any feature endpoint. Both cases surface as the typed error / result
code `feature_disabled` (never a crash). `Clikgate.isFeatureEnabled(key)` answers from the cached
config (unknown keys → false; before the first config fetch → the defaults above).

Feature of each endpoint: `/referrals/*` → `referrals`; `/leaderboards/*` → `leaderboards`;
`/codes/redeem` → `offline_codes`. (Identity signals are server-to-server only: there is no SDK endpoint.)

### Leaderboards (`leaderboards`)

Called only by the Engage features (17A).

All need a completed `/install`; `me`/`around-me` also an identified installation (and a verified
identity when the board's program has `require_identity_token`). Only boards with
`visibility = sdk` are served (others → `404 leaderboard_not_found`).

`GET /v1/sdk/leaderboards/{id}?period=current|previous|<period_key>&segment=<value>&limit=50` (≤ 100):

```json
{"leaderboard_id": "lb_01J...", "name": "Weekly top inviters",
 "period": {"key": "2026-W43", "status": "open", "starts_at": "2026-10-19T23:00:00Z", "ends_at": "2026-10-26T23:00:00Z"},
 "segment": null, "metric": "qualified",
 "entries": [{"rank": 1, "referrer_id": "rfr_01J...", "display": "Ada O.", "score": 12, "pending": 3, "is_me": false}]}
```

`display` follows the board's name mode (masked / display name / code); customer user ids and
anything about referees are never returned. `pending` is omitted (null) when the board hides it.

`GET /v1/sdk/leaderboards/{id}/me?period=current`:

```json
{"leaderboard_id": "lb_01J...", "period": {...same as above...}, "referrer_id": "rfr_01J...",
 "rank": 4, "score": 7, "pending": 1, "gap_to_next": 2, "best_rank": 3, "period_ends_at": "2026-10-26T23:00:00Z",
 "opted_out": false, "embed_token": null, "embed_url": null}
```

`rank` is null when the user has no score yet (or is opted out / below `min_score_to_appear`).
`?embed=1` adds a short-lived `embed_token` and `embed_url` (`https://{program link domain}/leaderboard/{id}?me=<token>`, the hosted page; Engage `hostedPageUrl`).
`404 referrer_not_found` when the user has never had a referral link in the board's program.

`GET /v1/sdk/leaderboards/{id}/around-me?radius=5` (≤ 25) → `{"leaderboard_id", "period", "entries": [...]}`
(the user's own entry has `is_me: true`; empty entries when the user isn't ranked).
`/me` and `/around-me` also accept `segment`. Other leaderboard errors: `403 not_identified` /
`identity_required` (program requires a verified identity token), `422 identity_invalid`,
`422 invalid_segment`, `404 period_not_found`. SDKs must ignore unknown response fields.

`POST /v1/sdk/leaderboards/opt-out` `{"program_id": "rpg_...", "opt_out": true}` →
`{"program_id": "rpg_...", "opt_out": true}`. Hides the user from every board of the program.

### Offline / promo codes (`offline_codes`)

`/codes/redeem` is called only by the Engage features (17A); backends use `POST /v1/codes/redeem`.

`POST /v1/sdk/codes/redeem` `{"code": "LAGOS50"}` (case-insensitive; spaces and dashes ignored;
rate limit 5/hour/installation) → `200`:

```json
{"offline_touch_id": "oft_01J...", "code": {"code": "LAGOS50", "kind": "link", "link_id": "lnk_01J...",
 "campaign_id": null, "referrer_id": null, "program_id": null}, "referral": null}
```

For a referral code (`kind: "referral"`) an eligible installation gets a referral
(`source: "offline_code"`), returned in `referral` (same object as `apply-code`). Errors:
`404 code_not_found`, `409 code_expired`, `409 code_disabled`, `409 redemption_limit_reached`,
`429 rate_limited`, plus the referral errors of `apply-code` when a referral can't be created
(`self_referral`, `already_referred`, `window_expired`, ...) — in that case the touch is still
recorded and the error is returned with `offline_touch_id` in the error body.

### Identity signals

Server-to-server only (spec v3 new edition, 9B.3): the customer's pepper must never ship in an app, so
there is no `/v1/sdk/identity-signals` endpoint and no SDK method. Use `POST /v1/identity-signals`
from the app's backend (see the backend's `docs/IDENTITY_CHECKS.md`).

### Share helpers (client-only, Engage features)

No endpoint. The Engage packages' `share.whatsApp(text)` (the app builds the text, typically from
`referrals.createLink`'s `url`) opens:
- Android: `ACTION_SEND` text/plain with `setPackage("com.whatsapp")`, else `"com.whatsapp.w4b"`,
  else the system chooser.
- iOS: `whatsapp://send?text=<urlencoded>` if `canOpenURL` (app must list `whatsapp` in
  `LSApplicationQueriesSchemes`), else the share sheet.
- Flutter (pure Dart) / React Native (pure TS): `whatsapp://send?text=<urlencoded>` through
  `url_launcher` / `Linking`, else the share sheet (`share_plus` / `Share`).
Returns/resolves `true` when WhatsApp itself was opened, `false` when the fallback share sheet was used.
`share.system(text)` always uses the share sheet. (The former core `referrals.shareToWhatsApp`
is removed.)

## Change 03 additions (trust and growth: consent, Google click ids, version policy, Firebase, identity checks)

SDK 1.2.0+ (Android, iOS, Flutter, React Native). **Every new field is optional** in both
directions: servers before change 03 don't send the new config fields (SDKs fall back to the
defaults below), and SDKs before 1.2.0 don't send the new request fields (the backend must treat
a missing `consent` as `unknown` purposes in a required region, see B.3). Schemas and fixtures:
`shared/schemas/*` and `shared/fixtures/*` (`*_consent*`, `*_blocked`, `*_deprecated`,
`open_request`, `resolve_request`, `consent_*`, `install_ping_*`, `attest_request_device_check`,
`install_response_attributed_source`).

### Consent object (requests)

Sent as `consent` in the body of **every** SDK `POST` from 1.2.0: `/install`, `/open`,
`/resolve`, `/goals` (top level of the batch), `/identify`, `/push-token`, `/attest`, `/consent`,
`/install-ping`. (`/opt-out` and `/attest/challenge` carry none; `GET /config` carries only the
region hint, below.)

```json
"consent": {
  "analytics": "granted",
  "attribution": "granted",
  "ad_user_data": "denied",
  "ad_personalization": "unknown",
  "region": "EEA",
  "updated_at": "2026-10-20T09:58:00Z"
}
```

| Field | Type | Meaning |
|---|---|---|
| `tracking_allowed` | bool, **deprecated** | SDKs before 1.5.0 (React Native 1.6.0) sent it on `/install`: `false` only on the opted-out first `/install`. Newer SDKs never send it (change 09, X.E23: every purpose `denied` says it). The schemas still accept it for old SDKs. |
| `analytics`, `attribution`, `ad_user_data`, `ad_personalization` | `"granted"` \| `"denied"` \| `"unknown"` | The app's `setConsent` values (B.3 purposes). `unknown` until the app sets them. |
| `region` | string \| null, `^(EEA\|UK\|[A-Z]{2})$` | The app's region hint (`setConsentRegion`): an ISO 3166-1 alpha-2 country or `EEA` / `UK`. Null when the app gave none. |
| `updated_at` | ISO 8601 \| null | When the app last called `setConsent`; null = never. |

Backend: record a `consent_records` row (source `sdk`, `sdk_version` from the header) when the
values differ from the installation's last record; use `region` (else the IP country) for the
region decision; apply the enforcement points in B.3 with these values. A body without `consent`
(old SDK) means every purpose is `unknown`.

### GET `/v1/sdk/config` additions

Request: optional query parameter `region_hint` (same format as `consent.region`), sent when the
app set a hint: `GET /v1/sdk/config?region_hint=DE`. The SDK sends `/config` **without**
`Clikgate-Installation-Id` while it is buffering for consent or consent is denied (SDK_BEHAVIOUR.md
"Change 03"), and also before it knows whether consent is required (no cached `consent` object and
no hint, e.g. the first launch) unless the app already granted `attribution`. The backend must not
require that header on `/config`.

Response additions (all optional; `fixtures/config_response*.json`):

```json
{
  "consent": {
    "mode": "required_in_regions",
    "required": true,
    "region": "DE",
    "required_regions": ["EEA", "UK", "CH"],
    "anonymous_counts": true,
    "buffer_max_days": 7,
    "buffer_max_events": 1000,
    "identity_checks_basis": "consent"
  },
  "min_supported_version": "1.0.0",
  "latest_version": "1.2.0",
  "version_status": "current",
  "blocked_instructions": null,
  "firebase_forwarding": {"enabled": true, "log_attribution_event": true, "set_user_properties": true, "report_app_instance_id": true},
  "features": {"attestation": {"ios_app_attest": "monitor", "android_play_integrity": "monitor", "android_cloud_project_number": 123456789012}}
}
```

| Field | Type | Meaning / SDK default when absent |
|---|---|---|
| `consent.mode` | `not_required` \| `required_in_regions` \| `required_everywhere` | The app's effective mode (org setting or per-app override). Absent object ⇒ the SDK treats consent as not required unless the local region hint is in the default regions (EEA, UK, CH). |
| `consent.required` | bool | Already resolved by the server for this request: `region_hint` if sent, else the IP country. |
| `consent.region` | string \| null | The region the server used (country code or `EEA`/`UK`). Informational. |
| `consent.required_regions` | string[] | Regions where consent is required (`EEA`, `UK`, or country codes; `CH` = Switzerland). The SDK re-evaluates a hint the app sets later against this list (it knows the EEA member countries). Default `["EEA", "UK", "CH"]`. |
| `consent.anonymous_counts` | bool | When consent is required and `attribution` is `denied`: send one identifier-free `/install-ping`. Default `false`. |
| `consent.buffer_max_days` | int 1–7 | How long buffered events are kept while consent is `unknown`. Default 7. |
| `consent.buffer_max_events` | int 1–1000 | Buffer size while consent is `unknown`. Default 1000. |
| `consent.identity_checks_basis` | `consent` \| `fraud_prevention` | Legal basis for identity checks (attestation, DeviceCheck, IDFV). `consent` ⇒ only with `analytics` allowed; `fraud_prevention` ⇒ also without. Default `consent`. |
| `min_supported_version` | semver \| null | Lowest version still `supported` for the platform of `Clikgate-SDK-Version`. |
| `latest_version` | semver \| null | Newest released version for that platform. |
| `version_status` | `current` \| `supported` \| `deprecated` \| `blocked` \| null | From `sdk_versions` for the SDK making the call (`Clikgate-SDK-Version`; when wrapped, the worse of it and `Clikgate-SDK-Native-Version`). Null/absent ⇒ the SDK compares itself with `min_supported_version` (lower ⇒ treated as `deprecated`). |
| `blocked_instructions` | object \| null | Only with `version_status: "blocked"`. `allowed_calls`: SDK calls still allowed (`config`, `install`, `install_ping`, `open`, `resolve`, `goals`, `identify`, `push_token`, `opt_out`, `consent`, `attest`, `apple_search_ads`, `referrals`, `leaderboards`, `codes`); `message`: logged as an error once per launch. Absent with `blocked` ⇒ the SDK uses `["config", "install", "open", "events", "opt_out", "consent", "install_ping"]`, any event name, properties stripped. |
| `firebase_forwarding.enabled` | bool | Plan feature `ga4_forwarding` + the app's GA4 setting. The SDK forwards to Firebase only when this is true **and** the app called `enableFirebaseForwarding`. Absent ⇒ off. |
| `firebase_forwarding.log_attribution_event` / `set_user_properties` / `report_app_instance_id` | bool | Server-side switches ANDed with the app's options. Defaults: `true`, `true`, `true`. |
| `features.attestation.android_cloud_project_number` | int \| null | The customer's Google Cloud project number. When set (or `ClikgateOptions.cloudProjectNumber`), Android uses Play Integrity **standard** requests. |

Backend: `version_status` / `blocked_instructions` must come from the `sdk_versions` table (B.4).
The SDK never decides "blocked" by itself.

### POST `/v1/sdk/install` additions

`fixtures/install_request_android.json`, `install_request_ios.json`:

```json
{
  "consent": {"analytics": "granted", "attribution": "granted", "ad_user_data": "denied", "ad_personalization": "unknown", "region": null, "updated_at": "2026-10-20T09:58:00Z"},
  "google_click_ids": {"gclid": "Cj0KCQjw-test_gclid", "gbraid": null, "wbraid": null, "source": "install_referrer"},
  "app_instance_id": "1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d",
  "attestation": {"type": "play_integrity", "token": "...", "key_id": null, "challenge": "atc_...", "request_type": "standard"},
  "device_check_token": "<base64>",
  "idfv": "6F9619FF-8B86-D011-B42D-00C04FC964FF",
  "google_on_device_measurement": {"odm_info": "abcdEfadGdaf", "sdk_version": "3.7.0"}
}
```

| Field | Type | When the SDK sends it |
|---|---|---|
| `google_click_ids` | object \| null: `gclid`, `gbraid`, `wbraid` (string ≤ 512 or null), `source` (`deep_link` \| `install_referrer`, required) | A Google click id was found in the launch URL (app link / universal link / custom scheme, query parameters `gclid` / `gbraid` / `wbraid`) or, on Android, in the Play install referrer string (URL-decoded, `&`-separated `key=value`). The launch URL wins when both have one. The backend picks `gclid` > `gbraid` > `wbraid` (B.4) and stores the type and value on the attribution. |
| `app_instance_id` | string ≤ 128 \| null | Firebase Analytics app instance id, only when the app called `enableFirebaseForwarding`, `firebase_forwarding.enabled` and `report_app_instance_id` are true, Firebase Analytics is in the app, and `analytics` consent allows it. |
| `attestation.request_type` | `standard` \| `classic` | Play Integrity only. `standard`: `StandardIntegrityTokenRequest.setRequestHash(nonce)` (verify `requestDetails.requestHash == nonce`); `classic`: `IntegrityTokenRequest.setNonce(nonce)` (verify `requestDetails.nonce`). Absent ⇒ classic (SDK ≤ 1.1). |
| `device_check_token` | base64 string \| null | iOS: `DCDevice.current.generateToken()` (iOS 11+, when `isSupported`). Ephemeral; the backend queries / updates the per-device bits with Apple's DeviceCheck server right away. Sent with identity-check consent (above) when `features.identity_checks` is on or App Attest is enabled. |
| `idfv` | string \| null | iOS `UIDevice.identifierForVendor`, under the same condition as `device_check_token`. The only device identifier the iOS SDK sends. |
| `google_on_device_measurement` | object \| null: `odm_info` (string, required), `sdk_version` | iOS, first install only, when the app called `enableGoogleOnDeviceMeasurement()` and Google's `GoogleAdsOnDeviceConversion` SDK is in the app: the non-empty string from `ConversionManager.sharedInstance.fetchAggregateConversionInfo(for: .installation)`. Not sent when `ad_user_data` is `denied`. Backend: store encrypted, 30-day retention, pass as `odm_info` in Google App Conversion API calls where accepted. |
| `pasteboard_token` | unchanged | The **clipboard deferred-link token** of B.2: `cgdl_` + 26 base62, copied by the landing page only after "Open in app". From 1.2.0 the iOS SDK reads the pasteboard only when the app opted in (`pasteboardMode` defaults to `off`) and the app's `features.pasteboard_matching` is `on_interstitial_tap` (per-app, default `off`). |
| `pasteboard_outcome` | new, optional | iOS only: what the first-launch paste step saw (`token_found` \| `no_link` \| `no_token` \| `denied` \| `paste_control`); omitted when the paste flow didn't run. See "Pasteboard tokens (iOS)". |

Removed from iOS requests in 1.2.0 (the schema keeps them for older SDKs): `screen` (only used for
probabilistic matching) and `is_rooted` (jailbreak heuristics). The backend must never run
probabilistic matching for `platform = ios` (B.2). Android sends `screen` only when
`features.probabilistic_matching` is true and `attribution` consent allows it.

Response: `attribution` gains optional `source`, `medium`, `campaign` (strings) and `channel`
(`ads` \| `whatsapp` \| `referral` \| `offline_code` \| `link` \| `organic` \| null), used for the
Firebase `clikgate_attribution` event (`fixtures/install_response_attributed_source.json`). Same
fields on later `/install` polls.

### Change 19 notes (no new fields)

- `apple_search_ads_token` (unchanged field): requested when the first `/install` is sent (also
  after consent buffering), renewed when older than 24 hours, never stored on the device
  (SDK_BEHAVIOUR "Change 19"). The backend registers it only when attribution consent isn't
  denied and `apple_search_ads` is on (`src/sdk/services/sdk_install_service.py`).
- `idfv`: also sent when `features.apple_search_ads` is on (identity-check consent still
  required), for Apple Ads `Redownload` linking (`src/attribution/services/search_ads_resolver.py`).
- LinkedIn `li_fat_id` and Snap `ScCid` travel in `launch_url`, `/resolve` `url` and the Play
  `install_referrer.referrer`; the backend extracts them itself (`src/clicks/utils/ad_params.py`,
  stored as `li_fat_id` / `sccid`). `/install` and `/open` bodies are `extra="forbid"` on the
  backend, so no `ad_click_ids` object is sent until the backend adds one.

### POST `/v1/sdk/open`, `/resolve`, `/goals`, `/identify`, `/push-token`, `/attest` additions

- All: `consent` (above).
- `/open`: `google_click_ids` (`source: "deep_link"`) when the app was opened by a Clikgate link
  carrying one since the previous `/open`; `app_instance_id` when it changed since the last
  successful send (same conditions as on `/install`).
- `/resolve`: `google_click_ids` parsed from `url` (the server should still read the URL itself).
- `/attest`: `request_type` (Play Integrity), `device_check_token` (iOS, with each weekly
  re-attestation).

### POST `/v1/sdk/consent` (new)

Request `{"consent": {...}}` (`schemas/consent_request.schema.json`) → `200 {"ok": true}`. Sent when
the app changes consent or the region hint and the installation exists (also when the new state is
`denied`: recording a withdrawal is required). Retried like `/identify`. Append-only
`consent_records` row; then apply the new state to everything still queued server-side for the
installation (for example skip pending conversion sends with `skipped_consent`).

### POST `/v1/sdk/install-ping` (new)

Anonymous install count, sent **once** per installation when consent is required, `attribution`
is `denied` before the first `/install`, and `config.consent.anonymous_counts` is true. **No**
`Clikgate-Installation-Id` header, no identifiers in the body:

```json
{"platform": "android", "app_version": "3.4.1", "sdk_version": "1.2.0", "consent": {"analytics": "unknown", "attribution": "denied", "ad_user_data": "denied", "ad_personalization": "denied", "region": "DE", "updated_at": "2026-10-20T10:05:00Z"}}
```

→ `200 {"ok": true}`. Count only (per app, day, platform, app version); store nothing else and
don't keep the request IP beyond rate limiting.

### Version policy (SDK side)

| `version_status` | SDK behaviour |
|---|---|
| `current`, `supported` | normal |
| `deprecated` (or no status and the SDK's version < `min_supported_version`) | normal, plus one warning per launch naming `latest_version` |
| `blocked` | one error per launch (`blocked_instructions.message`); only the `allowed_calls`; `/install` with the required fields + `consent` + `install_referrer` / `launch_url` only (no device details, attestation, pasteboard, click ids, Firebase or ODM data); goals only when `allowed_calls` lists `goals` (otherwise refused on the device with `sdk_version_blocked`); `/resolve` not allowed ⇒ deep links are delivered locally (URL, path, query parameters) without a server call |

### SDK-side error codes (Change 03)

Not sent by the server; the SDKs return them to the app (and to the Engage features through the
request context) without a network call:

| `code` | When |
|---|---|
| `consent_required` | Consent is required for this device and `attribution` isn't `granted`: referral calls (`applyCode`, `referredBy`) and the Engage request context fail with it. |
| `sdk_version_blocked` | `version_status` is `blocked` and the call isn't in `blocked_instructions.allowed_calls`. |

### Pasteboard (clipboard) prompt (iOS)

Reading `UIPasteboard.general.string` on iOS 16+ shows the system prompt
"“<App>” would like to paste from “<Source app>”" with **Allow Paste** / **Don't Allow** (users
can change it later in Settings › <App> › Paste from Other Apps). The pattern check before it
(`detectPatterns` / `detectedPatterns`) shows nothing. `ClikgatePasteControl` (`UIPasteControl`)
pastes without the prompt because the user tapped the system paste button.

## Change 06 additions (goals and private mode)

SDK 1.3.0+ (Android, iOS, Flutter, React Native). As in change 03, **every new field is optional in
both directions**: a server before change 06 doesn't send `private_mode` (the SDK treats it as
`false`) and has no `/v1/sdk/goals` route (the SDK drops queued goals on that `404`, see below);
SDKs before 1.3.0 never call `/goals` and don't know `private_mode` (the backend enforces private
mode on its side anyway). Schemas and fixtures: `schemas/goals_request.schema.json`,
`schemas/goals_response.schema.json`, `fixtures/goals_request.json`, `fixtures/goals_response.json`,
`fixtures/goals_response_rejected.json`, `fixtures/config_response_private_mode.json`.

### POST `/v1/sdk/goals` (new)

The app SDKs' source for goal events (backend spec B.2 / B.4). A **batch** from the SDK's persisted queue. Same transport and headers as every SDK call: `Clikgate-SDK-Key`,
`Clikgate-SDK-Version` (+ `Clikgate-SDK-Native-Version` when wrapped), `Clikgate-Installation-Id`
(the backend attributes through the installation's install / opens when `click_id` is absent), and
`Idempotency-Key` (one random UUIDv4 per request, reused by its retries; honoured by the backend
from change 09, see "Change 09 additions"; the server also dedupes by `(goal, reference)`). Needs a
completed `/install` (`404 installation_unknown` otherwise). Version-policy call
name: `goals` (added to the `allowed_calls` vocabulary).

Request — `schemas/goals_request.schema.json`:

```json
{
  "goals": [
    {"goal": "account_opened", "reference": "APP-55231", "value": "2000000", "currency": "NGN",
     "is_first": true, "occurred_at": "2026-10-23T09:12:00.000Z", "click_id": "clk_01J..."},
    {"goal": "kyc_passed", "reference": "0b7e4c1a-2f3d-4e5a-9b8c-7d6e5f4a3b2c", "occurred_at": "2026-10-23T09:10:02.512Z"}
  ],
  "consent": {"analytics": "granted", "attribution": "granted", "ad_user_data": "denied", "ad_personalization": "unknown", "region": null, "updated_at": "2026-10-20T09:58:00.000Z"}
}
```

| Field | Type | Meaning |
|---|---|---|
| `goals` | array, 1–100 items | ≤ `batching.max_batch_size`. Items are `additionalProperties: false`: the SDK never sends anything else (no metadata, no user id, no properties). |
| `goals[].goal` | string, required, `^[a-z][a-z0-9_]{1,39}$` | The goal key (B.1: snake_case, 2–40 characters). |
| `goals[].reference` | string, required, 1–128 chars | The business's own reference (application number, order id). When the app passes none, the SDK generates a UUIDv4 at `goal()` time (app-side idempotency only: such a goal can't be reversed or matched by the business). Kept across retries. |
| `goals[].value` | **string** \| null, optional | Normal units, never minor units. Always a JSON string from the SDKs (no floating point on the wire): `^(0\|[1-9][0-9]*)(\.[0-9]*[1-9])?$` — no sign, exponent, leading zeros or trailing fractional zeros (`"2000000"`, `"1500.5"`, `"0.25"`). At most **15 significant digits** (digits left after removing leading zeros and trailing fractional zeros: `"2000000"` = 7, `"0.005"` = 1). The backend applies B.2 on top: decimal places allowed by the currency's ISO 4217 exponent, `value_mode` none/required. Absent/null = no value. |
| `goals[].currency` | string \| null, optional, `^[A-Z]{3}$` | ISO 4217. Absent = the goal's `default_currency`. Ignored by the backend when `value` is absent. |
| `goals[].is_first` | bool \| null, optional | The business's statement that this is the customer's first such event (`is_first_customer`). Absent/null = not stated. |
| `goals[].occurred_at` | ISO 8601 UTC, required | Set at `goal()` time and kept across retries. Backend B.2 rule: rejected when more than 5 minutes in the future (`occurred_at_in_future`). Old queued goals (up to the consent buffer's 7 days) are accepted. |
| `goals[].click_id` | string \| null, optional | The click of the most recent Clikgate deep link that opened the app (`/resolve` match), else the install's attributed click — the value `attributionMetadata()` returns as `cg_click_id`, captured at `goal()` time. Null/absent: the backend attributes through the installation (`Clikgate-Installation-Id` → install / re-engagement opens), using the goal's `window_days`. |
| `consent` | object \| null, optional | The change 03 consent object. Backend B.3 enforcement applies to goals. |

Private mode (B.5) allow-list for this endpoint: exactly the item fields above plus the top-level
`consent`. They are all goal / click / reference / value fields or the device's own consent record,
so a private-mode organisation accepts them; anything else is refused with
`private_mode_field_rejected` (naming the field, never echoing its content). In private mode the
backend stores the reference only as `reference_hash`.

Response `200` — `schemas/goals_response.schema.json`:

```json
{"accepted": 1, "duplicates": 0,
 "rejected": [{"goal": "order_paid", "reference": "ORD-1001", "code": "invalid_value", "param": "value", "message": "USD allows at most 2 decimal places."}]}
```

- `accepted`: new goal events stored (counted or not — `once_per_click` duplicates count as accepted
  here; the SDK doesn't distinguish).
- `duplicates`: items whose `(goal, reference)` the backend already had (idempotent replay, also
  across installations of the same app). Success for the SDK.
- `rejected[]`: per-item rejections, **dropped by the SDK, never retried** (logged as a count and
  codes, never references or values). `code` is a string; the current codes are:

| `code` | Meaning |
|---|---|
| `invalid_goal_key` | Key doesn't match the B.1 format (the SDK already checks it). |
| `goal_not_found` | No goal with this key in the organisation / environment. |
| `goal_archived` | The goal is archived. Since change 22 R.10 an archived goal answers `received` / `goal_archived`; with "Allow unknown goal names" off it is `refused` / `goal_archived` (change 23 R.1). |
| `unknown_goal` | No goal behind this name and the organisation's "Allow unknown goal names" is off (change 23). |
| `invalid_value` | Negative, more than 15 significant digits, or more decimal places than the currency allows. |
| `value_not_allowed` | The goal's `value_mode` is `none` and a value was sent. |
| `value_required` | The goal's `value_mode` is `required` and no value was sent. |
| `invalid_currency` | Not an ISO 4217 code the backend knows. |
| `invalid_reference` | Empty or longer than 128 characters. |
| `occurred_at_in_future` | More than 5 minutes in the future. |
| `private_mode_field_rejected` | A field outside the allow-list in private mode (`param` names it). |
| `validation_error` | Anything else malformed in that item. |

Unknown codes are treated as rejections (dropped). `param` is the field name or null.

Whole-request errors: the standard SDK errors (`401 invalid_sdk_key`, `403 sdk_disabled`,
`403 opted_out`, `404 installation_unknown`, `422 validation_error` → the batch is dropped,
`429 rate_limited`, `5xx` → retried with the queue). A `404` with any other code (a server before
change 06 without this route) → the SDK drops the goals in that batch with a warning
("this Clikgate server doesn't accept goals yet"). A `200 {"accepted": false, "reason":
"feature_disabled", "feature": "goals"}` body (if the backend ever switches goals off for an app)
→ dropped with a warning.

Backend notes: map each item onto the B.2 goal-event pipeline exactly as `POST /v1/goals/events`
(same value parsing — the SDK's string is a valid B.2 numeric string —, currency default,
`value_mode` rules, idempotency by `(goal, reference)`, counting modes, `first_for_click`,
private-mode hashing); attribution: `click_id` if present and valid for the organisation, else the
installation's install / latest re-engagement click, within the goal's `window_days`. `code`
(offline codes) is not sent by the SDKs.

### GET `/v1/sdk/config` addition

```json
{"private_mode": true}
```

| Field | Type | Meaning / SDK default when absent |
|---|---|---|
| `private_mode` | bool, optional | `organizations.settings.private_mode.enabled` (B.5; live and test alike). Absent ⇒ `false` (servers before change 06). |

When `true` the SDKs (1.3.0+), from the cached config:
- don't send `/identify` (an `identifyUser()` customer ID is dropped on the device and not stored; a pending
  identify is discarded);
- log one warning per launch in debug builds;
- send goals normally.

The backend still enforces private mode: it refuses `/v1/sdk/identify` with
`422 private_mode_field_rejected` (`param: "customer_user_id"`). (There is no SDK user-properties
call; the Firebase `cg_first_*` user properties are written to the app's own Firebase, never to
Clikgate.)

### SDK-side error codes (Change 06)

`goal()` validation failures are `invalid_argument` (with `param`: `goal`, `value`, `currency`,
`reference`), returned to the wrappers and logged; the goal is not queued.

## Change 09 additions (consistency fixes)

SDK 1.5.0 (Android, iOS, Flutter), React Native 1.6.0. No new endpoint and no new required field:
change 09 settles places where earlier specs disagreed. Fixture: `fixtures/install_request_opted_out.json`.

### `/v1/sdk/install` consent (X.E23)

`/install` carries the same four-purpose consent object as every other call (`analytics`,
`attribution`, `ad_user_data`, `ad_personalization`, plus `region` and `updated_at`). The opted-out
first install (`setTrackingEnabled(false)` before the first launch) sends **every purpose `denied`**
instead of `tracking_allowed: false`; the backend reads `attribution: "denied"` as "no attribution"
(an organic install, nothing else), as for any other request. The app's own consent values are sent
through `/consent` once tracking is switched back on. `tracking_allowed` is deprecated: newer SDKs
never send it, and the schemas keep it only so older SDKs' bodies still validate.

### `/v1/sdk/goals` idempotency (X.E15)

The backend honours `Idempotency-Key` on `/goals` (scoped per SDK key): the same key with the same
body replays the stored response (`Idempotent-Replayed: true`); the same key with a different body
answers `409 idempotency_key_reused`; the same key while the first request still runs answers
`409 idempotency_request_in_progress`. The SDKs send **one random UUIDv4 per request, reused by that
request's retries** (the in-call retry policy; a later flush is a new request with a new key), never
a hash of the reference. The `(goal, reference)` dedupe still applies on top: a new key with a
reference the backend already has counts as `duplicates`. A `409` is a whole-request `4xx`, so the
batch stays queued and goes again with the next flush under a new key (the backend then reports the
items as `duplicates`). Android and iOS did this already; change 09 makes it the contract.

### Money helper name (X.E10)

Removed in Change 22 with the app-event method (it only built event revenue). Goals keep normal units (`value`).

### App link subdomains (N.1)

Customer apps no longer claim app links on the shared platform domains: from change 09 the
shared domains' AASA / assetlinks list no customer apps, and each app opens from its own
`{link_subdomain}.ciz.to` (test: `{link_subdomain}.dev.ciz.to`) and the organisation's custom
domains. For the SDKs nothing changes on the wire: pass the app subdomain (and custom domains) in
`linkDomains`; `/config` `link_domains` lists them. App subdomains are **not** shared platform
domains (the shared-domain check is an exact host match on the four hosts), so the browser fallback
never applies to them. The browser fallback stays as a safety net for projects that still declare a
shared domain.

### Leaderboard trophies and challenges (D8)

Trophy, challenge and progress data are **not** in any mobile SDK (core or Engage), and no SDK call
joins a challenge. Businesses read them from their own server through the API
(`/v1/leaderboards/{id}/trophy`, `/v1/challenges/...`) and webhooks. The Engage leaderboard calls
above stay as they are and gain no fields.

## Change 10 additions (deep links on every plan)

Backend contract C10 B3a.2. No new endpoint, field or SDK method. **Deep-link-only mode** is an app whose
`/config` `features` say `"deep_linking": true, "app_attribution": false`: the Free and Starter plans, or an
app with attribution switched off. The SDK key works on every plan (`403 sdk_disabled` only when both are off).

| Call | Response in deep-link-only mode | SDK behaviour |
|---|---|---|
| `GET /v1/sdk/config` | Normal shape; `link_domains` has the app subdomain, `yourapp.clk.ng` on Free or `yourapp.ciz.to` (fixture `config_response_deep_link_only`) | Cache as usual; `isFeatureEnabled("app_attribution")` is false |
| `POST /v1/sdk/install` | Normal shape; `attribution` is always the organic shape (`channel: "organic"`, no link, click or source); `deep_link` is the deferred link when one matched (fixture `install_response_deep_link_only`) | Deliver `deep_link` as today; attribution reads organic |
| `POST /v1/sdk/install` at the monthly deferred deep link cap (Free 1,000, Starter 10,000) | The same with `deep_link: null` (fixture `install_response_deferred_cap`) | The normal "no deferred link" result: the app opens its home screen. Never an error, never retried |
| `POST /v1/sdk/resolve` and the other calls | Normal; `is_reengagement` is always `false` | Unchanged |
| `POST /v1/sdk/goals` | `200 {"accepted": false, "reason": "feature_disabled", "feature": "app_attribution"}` (fixture `goals_response_feature_disabled`) | Not called while the cached config says `app_attribution` is off. If the body comes back anyway: drop the batch, mark `app_attribution` off until the next config fetch, refresh the config, never retry |

`goal()` in deep-link-only mode logs **one** warning per launch ("app attribution is switched off") and does
nothing: nothing is queued or sent and no error is returned. Free app
subdomains are under `clk.ng` (`yourapp.clk.ng`); like `yourapp.ciz.to` they are app subdomains, **not** shared
platform domains (the shared-domain check stays an exact host match), so the browser fallback never applies to them.

## Change 12 additions (one `goal()` method, Payment goals, enums)

Backend contract C12 B2 and B3 (final). Versions: folded into the unreleased SDK versions (see `docs/PROGRESS.md`).
Change 11's `POST /v1/sdk/payments` is **removed** (404) and so is `payment()` on every platform: an app reports a
payment with `goal()` on a **Payment goal**. There is never a goal kind in the call: the kind lives only in the
goal's settings (D4), so the SDK can't know it and the server decides. Schemas and fixtures:
`schemas/goals_request.schema.json` (item `provider`), `schemas/goals_response.schema.json` (`results`,
`rejected[].index` / `missing`), `fixtures/goals_request_payment.json`, `fixtures/goals_response_results.json`.
The `payments` version-policy call name is gone (the backend never sent it).

### POST `/v1/sdk/goals` changes

- Items gain optional **`provider`** (a `Provider` value: `shared/providers.json`, copied from the backend's
  OpenAPI `Provider` enum and generated into each SDK by `scripts/generate_providers.py`). The schema accepts any
  provider key (`^[a-z][a-z0-9_]{1,29}$`) so `Provider.fromString(...)` can send a provider added after the SDK
  release; the server answers `unknown_provider` for keys it doesn't know.
- By goal kind (decided on the server):

  | Goal kind | What the app's goal does |
  |---|---|
  | `standard` | Counted as before. `provider` is checked and otherwise ignored. |
  | `payment` | Stored as a payment report, `waiting` until the business's server or a gateway confirms it. `provider` and `reference` are required, else the item is rejected `payment_goal_needs_confirmation` with `missing: ["provider" \| "reference"]`. A `value` / `currency` is **ignored** (`value_ignored: true`): the amount comes from the confirmation. |

- The response gains **`results`**: one per item, in request order (`index`), also for rejected items:

  ```json
  {"accepted": 2, "duplicates": 0, "rejected": [{"index": 2, "goal": "order_paid", "reference": "ORD-1",
    "code": "payment_goal_needs_confirmation", "param": "provider", "missing": ["provider"], "message": "..."}],
   "results": [
     {"index": 0, "goal": "account_opened", "reference": "APP-1", "status": "counted", "reason": null,
      "goal_kind": "standard", "counted": true, "value_ignored": false, "id": "cnv_..."},
     {"index": 1, "goal": "purchase", "reference": "T123456", "status": "waiting",
      "reason": "waiting_for_confirmation", "goal_kind": "payment", "counted": false, "value_ignored": true, "id": "prp_..."},
     {"index": 2, "goal": "order_paid", "reference": "ORD-1", "status": "refused",
      "reason": "payment_goal_needs_confirmation", "goal_kind": "payment", "counted": false, "value_ignored": false, "id": null}]}
  ```

  `status` is a `GoalStatus` (`counted` | `waiting` | `refused`); `reason` is null when counted, else a reason code
  (`waiting_for_confirmation`, `pending_click`, `already_counted_for_click`, `unattributed`, `rejected_bot`,
  `outside_window`, `already_counted`, a report status such as `rejected` / `not_confirmed`, or a rejection code).
  `goal_kind` is a `GoalKind` (`standard` | `payment`).
- Queueing, batching, retries, the `Idempotency-Key` and the drop rules for `/goals` are **unchanged**.

### What `goal()` returns (all SDKs)

`goal()` answers with a result `{status: GoalStatus, reason, goalKind, valueIgnored}` once Clikgate has answered
for that goal (Android `GoalResultListener`, iOS `completion`, Flutter `Future<GoalResult>`, React Native
`Promise<GoalResult>`; never an exception or a rejected promise):

- From the server: the item's `results[index]` entry (an unknown `status` is `refused` with the raw value as
  `reason`). A server without `results` (older backends): items in `rejected` are `refused` with their `code`,
  the others `counted`.
- A final batch failure (a 4xx `/goals` drops, `feature_disabled`, a version-blocked SDK, a cleared queue) is
  `refused` with the error code (`feature_disabled`, `sdk_version_blocked`, ...).
- Refused on the device without a request: `invalid_argument` (bad key, value, currency, reference or provider
  string), `feature_disabled` (deep-link-only plan), `opted_out`, `consent_denied`, and on iOS `not_configured`.
- While offline the result waits with the queue (in memory: a goal still queued when the app is killed is sent
  on a later launch, without a result).
- **Test mode** (an SDK key starting `cg_sdk_test_`): one warning line when a Payment goal is waiting
  (`purchase is a Payment goal: waiting for confirmation`) and when its value was ignored. Never the reference or
  the value.

### Enums

| Type | Android | iOS | Flutter | React Native |
|---|---|---|---|---|
| Provider | `Provider.PAYSTACK`, `Provider.fromString("…")` | `ClikgateProvider.paystack`, `.fromString(_:)` | `ClikgateProvider.paystack`, `.fromString(…)` | `ClikgateProvider.Paystack`, `providerFromString(…)` |
| Goal status | `GoalStatus.COUNTED` / `WAITING` / `REFUSED` | `ClikgateGoalStatus.counted` … | `GoalStatus.counted` … | `GoalStatus.Counted` … |
| Goal kind | `GoalKind.STANDARD` / `PAYMENT` | `ClikgateGoalKind.standard` / `.payment` | `GoalKind.standard` / `.payment` | `GoalKind.Standard` / `.Payment` |

`fromString` trims and lower-cases, returns the constant when there is one, and null for a string that isn't a
provider key.

## Change 13 additions (share helpers)

`POST /v1/share-events` (note: under `/v1`, not `/v1/sdk`), SDK key headers as every Engage call
(`Clikgate-SDK-Key`, installation and version headers). Schemas `share_event_request` /
`share_event_response`; fixtures of the same names.

Request: `{"url": "<the URL that was shared>", "app": ShareApp}`. The SDKs send the URL (its ending tells
Clikgate which version was shared); `link_id` instead of `url`, and `share_ending`, are accepted by the
server but not sent. `ShareApp`: `whatsapp|instagram|facebook|tiktok|x|linkedin|telegram|sms|email|youtube|
slack|imessage|discord|snapchat|other` (backend `ShareApp` enum; `shared/share_targets.json`, checked by
`scripts/generate_share_targets.py --check`).

Response `201` `share_event` `{object, id: "shv_…", link_id, app, share_ending, source: "helper",
occurred_at, livemode}`. Errors: `404` when the URL isn't one of this organisation's links (another
organisation's link included), `422 unknown_share_ending`, `422` validation, `429` (per IP and 20/s per
key). A share event is a count, never a click. The SDKs ignore the answer.

The website share buttons (web script `share.mount`) call the same route with the web key in the body
(`web_key`), `text/plain`, from a verified website origin.

## Change 14 additions (identifyUser, labels)

- `POST /v1/sdk/identify` (schema `identify_request`): `customer_user_id` optional (absent keeps, `null` clears; never
  sent in private mode), `identity_token`, `consent`, `label` (1–80 characters, `""` clears). Response
  (`identify_response`): `customer_user_id`, `identity_verified`, `person_id`, `label_ignored` (`plan` | `lower_rank` |
  null), and since Change 22 `verified` (the token check on this call; `false` when no token was sent) and `reason`
  (`expired` | `bad_signature` | `secret_rotated` | `no_secret_set` | `not_yet_valid` | null). A bad token answers
  `200` with the customer ID kept unverified; it no longer answers `422 identity_invalid`. Fixtures
  `identify_request_label`, `identify_request_user`, `identify_response_plan`, `identify_response_token_expired`.
- `POST /v1/sdk/goals` items: optional `label` (same rules).
- `GET /v1/sdk/config`: `allow_labels` (absent = true; false only in private mode without "Allow labels in private
  mode"). Fixture `config_response_private_mode` now carries `allow_labels: false`; `config_response_private_mode_labels`
  has it on.
- Errors: `422 labels_off_in_private_mode` (the SDKs drop labels first, so they don't normally see it),
  `403 browser_labels_off` (web only).
- Server side (not the mobile SDKs): `POST /v1/people/identify` replaces the removed `POST /v1/apps/{app_id}/identify`.

## Change 17 additions (link gates on app opens, R.2)

Universal Links and App Links open the app without the redirect, so `POST /v1/sdk/resolve` runs the same gates
as the redirect (allowed countries, password, smart-routing block rules, then the A/B split). Every answer now
carries three more fields (`schemas/resolve_response.schema.json`, all required):

| Field | Type | Meaning |
|---|---|---|
| `status` | `matched` \| `no_match` \| `password_required` \| `blocked` | Which answer this is. |
| `web_url` | string \| null | `password_required` only: the link's own URL (the password page). |
| `block_message` | string \| null | `blocked` only: the text to show (the link's message, else the organisation's default). |

- **`password_required`**: `matched: false`; `click_id`, `deep_link`, `link`, `referral` and `match_type` are null
  (the schema enforces it). The SDK opens `web_url` in the **system browser** (not an in-app view) and delivers
  nothing. No click is minted until the password is entered on the web.
- **`blocked`**: the same fields null. The SDK delivers a deep-link result with `blockMessage` set and no path,
  click or link; the app shows the text and doesn't route. The SDK shows no UI itself.
- **`matched`**: as before. On a link with an A/B test the server picks the version (the unit is the click, R.3)
  and `deep_link.path` is that version's path; the SDK delivers it unchanged.
- **`no_match`**: the old `matched: false` answer (shared-domain browser fallback unchanged).
- A gated answer never routes into the app, whatever else it carries: the SDKs read `status` first and ignore
  `click_id`, `deep_link`, `link` and `referral` on `password_required` / `blocked`.
- **Deferred deep links** never carry a gated link's destination: `/install` with a gated `launch_url` answers
  without a `deep_link` (and without a click: `attribution.click_id` is null).
- **`/install` gate fields** (`schemas/install_response.schema.json`, optional, so answers to older SDKs stay
  valid): `status`, `web_url` and `block_message` with the same values as above, whenever the request carried a
  `launch_url` that was evaluated; null / absent otherwise (no launch URL, tracking off, attribution consent
  denied, attestation enforced and invalid). `matched` / `no_match` say whether the launch URL itself matched
  (another matcher, such as the Play Install Referrer, can still attribute a `no_match` install). A gated launch
  URL ends matching: no other click stands in for it. A replayed `/install` (same installation id) gives the
  same gate answer for a gated launch URL without minting anything.
  - **Android** acts on it directly: `password_required` opens `web_url` in the system browser, `blocked`
    delivers the blocked result; the launch URL is not `/resolve`d again (on any domain).
  - **iOS** ignores the install `deep_link` when `status` is gated and `/resolve`s the launch URL as before, so
    it gets the `/resolve` gate answer.
- Older servers send none of the three fields: `status` absent is read as before (`matched` decides).
- Fixtures: `resolve_response_password_required`, `resolve_response_blocked`, `resolve_response_ab_variant`,
  `install_response_password_required`, `install_response_blocked`;
  `resolve_response_matched` / `_unmatched` gained `status` (`matched` / `no_match`), `web_url` and
  `block_message` (null).

## Change 20 additions (`deeplink_handled` for the live check, S.1 / R.40)

**Status: SDK side built; the backend endpoint is being built in parallel (C20-B5) and must match this, or this
section is updated to what the backend ships.**

### POST `/v1/sdk/deeplink-handled` (new)

Sent by the native SDKs (Flutter and React Native through them) right after a matched Clikgate deep link is
handed to the app: a direct link from `/resolve` or the deferred link from `/install`. It feeds the "See it live"
checklist item "Deep link opened the right screen" and the debug view's event stream; it is not a goal.

Request — `schemas/deeplink_handled_request.schema.json` (no unknown keys):

```json
{"path": "/products/:id", "is_deferred": false}
```

- `path`: the delivered link's `deep_link.path` (else the opened URL's path), cleaned **on the device**: query
  (`?…`) and fragment (`#…`) removed; split on `/`; each segment is percent-decoded to test it and becomes `:id`
  when it contains `@` (email), is only digits and `+ - . ( )` / space with at least one digit (numbers, phone
  numbers), or contains a run of ASCII letters and digits that has a digit and is 6+ characters long, or is 16+
  characters long in mixed case (UUIDs, hex and base64-like tokens, codes). Other segments are sent as they were.
  Empty → `/`; at most 512 characters. Test vectors: `fixtures/deeplink_path_cases.json` (every SDK runs them).
- `is_deferred`: the delivered result's `isDeferred`.
- Headers as every SDK call (`Clikgate-SDK-Key`, `Clikgate-SDK-Version`, `Clikgate-Installation-Id`); no
  `Idempotency-Key`. Device model, OS and app version are the installation's (from `/install` / `/open`).
- Version-policy call name: `deeplink_handled` (not in the blocked default list).

Response `200` — `schemas/deeplink_handled_response.schema.json`: `{"ok": true}`. The SDK ignores the body.

**When it is sent (all must hold):**

1. the SDK key is a test key (`cg_sdk_test_…`), **or** the `/resolve` / `/install` answer that delivered the link
   has `debug_view: true` (below). Never otherwise: normal live use sends nothing;
2. consent allows SDK calls (not while buffering or denied), tracking is on (not opted out), and the SDK version
   isn't blocked for `deeplink_handled`;
3. the link was matched and delivered: not for `password_required` / `blocked` answers, unmatched links, browser
   handoffs, or links delivered locally without a server answer (consent buffering, opt-out).

**Delivery:** a call of its own, never put in the goal queue, never sent to `/goals`, so it never
counts as an attributed event and is never metered; it is sent in deep-link-only mode and private mode too (the
path is already cleaned). One retry on network errors / 408 / 429 / 5xx, then dropped. A 404 from an older server
is dropped silently.

**Backend expectations (for C20-B5):** test mode → the live check's item 4 and the live event stream (filtered to
the app and test mode); live mode only while the debug view is open; never written as a goal, never on a
meter or an invoice, no personal data stored (the path is already cleaned; the backend may clean it again).

### `debug_view` on `/resolve` and `/install` answers (new, optional)

`debug_view: true` when the dashboard's debug view for this app is open at the time of the call; absent or
`false` otherwise. Older servers send nothing (the SDK then reports only in test mode). An answer, not
`/config`, so it is current for that link (the config is cached for an hour). Fixtures:
`resolve_response_debug_view` (a path with an email, a UUID, a query and a fragment), `install_response_debug_view`,
`deeplink_handled_request`, `deeplink_handled_request_deferred`, `deeplink_handled_response`.

## Change 21 additions (opens by existing users, one tap one click, X `twclid`, basic attribution)

No new endpoint, field or SDK method. SDK patch release: Android, iOS and Flutter 1.5.1, React Native 1.6.1
(setup command 1.1.1). This section also closes the Change 20 open item on basic attribution.

### Basic attribution on every plan (Change 20 I.3, R.3, R.11)

- `GET /v1/sdk/config` `features.app_attribution` now reports the organisation's **basic** app attribution
  (`app_attribution_basic`), which is on for every plan. `features.app_attribution_basic` may be listed too; the SDKs
  read only `app_attribution`, unchanged. So on every plan the SDKs send `/install` and `/goals` as usual.
- **Deep-link-only mode** (Change 10 above) now means only an app whose attribution is switched off
  (`app_attribution: false`), no longer "the Free and Starter plans". The SDK behaviour in that mode is unchanged.
- **Full** attribution (`app_attribution`, Growth and up) is server-side only: `is_reengagement` on `/resolve` is
  `false` without it. Nothing changes in the SDKs.
- **Free limit (Change 20 R.11):** at the Free `attributed_events` limit the server keeps matching installs (deferred
  deep links still arrive) but credits them later; `/install` answers the organic attribution shape and
  `/goals` answers as usual. Never an error, never retried differently.

### What an app open sends (S.1, R.1–R.4)

The server decides whether a click is an **existing-user open** (not counted on `tracked_clicks`, up to the
`existing_user_opens` allowance) from these calls. Times are server times (the redirect time, or when the server
received the SDK call); the SDKs send no new timestamp, and device times are never used for it.

| Open | SDK call | What identifies the install | What identifies the click |
|---|---|---|---|
| **Direct** App Link / Universal Link (no redirect) | `POST /v1/sdk/resolve` `{"url": "<the URL as opened>"}` | `Clikgate-Installation-Id` header (the server finds the `ins_` row; R.1) | none: the server records the click when it receives the call |
| **Redirect, then the app opens** (in-app browsers, the interstitial's "Open in app", custom schemes) | `POST /v1/sdk/resolve` `{"url": "<URL carrying cg_click_id>"}` | `Clikgate-Installation-Id` | the redirect's `cg_click_id` inside `url`: the server attaches to that click and never records a new one (R.2) |
| First launch with a launch URL | `POST /v1/sdk/install` `launch_url` (no `/resolve` for that URL; see below) | `installation_id` in the body and the header | `cg_click_id` inside `launch_url`, else the server records it |
| Plain app open (no URL) | `POST /v1/sdk/open` (never carries a URL) | `Clikgate-Installation-Id` | none: opens without a Clikgate URL or click ID never touch meters (R.4) |

- URLs are sent **exactly as opened**: the SDKs never strip, reorder or re-encode query parameters (`cg_click_id`,
  `cg_link`, `utm_*`, ad click IDs), also while consent is buffering.
- **One tap is one click (R.2).** When `/install` matched the launch URL (`status: "matched"`, Change 17), it has
  already recorded that URL's click, so the SDK never sends the same URL to `/resolve`:
  - iOS, when the install answer has no `deep_link`: sends `/resolve` with `{"click_id": "<attribution.click_id>"}`
    (the server attaches, no new click), or, without a click ID (attribution off), delivers the link locally
    (URL, path, query) without a call;
  - Android: never `/resolve`s the launch URL after a matched install (the shared-domain browser check runs only
    when the install didn't match).
  - Older servers that send no `status` keep the earlier behaviour.
- An open sent late from the offline queue (more than 10 minutes after the click) stays a tracked click (R.3,
  server-side).

### X `twclid` (R.25)

Like LinkedIn `li_fat_id` and Snap `ScCid` (Change 19 notes above): no new field. `twclid` travels inside
`/install` `launch_url`, `/resolve` `url` and the Play `install_referrer.referrer` exactly as the link carried it;
the backend reads it from there and stores it on the click (`/install` and `/resolve` bodies stay
`extra="forbid"`). The redirect adds it to app links only when the app's `pass_ad_click_ids` names X. The web script
keeps only the Clikgate click ID (the redirect already stored `twclid` on that click; `POST /v1/web/goals` forbids
unknown keys).

Tests: `android/clikgate/src/test/java/com/clikgate/Change21Test.kt`, `ios/Tests/ClikgateTests/Change21Tests.swift`,
`flutter/test/change21_test.dart`, `react-native/src/__tests__/change21.test.ts`, and the web script's
`clikgate_api/tests/js/clikgate_snippet.test.mjs` (Change 21 block).

## Change 22 additions (one `goal()` method, `received`, the installation ID)

Spec: `docs/spec/clikgate-change-22-goals-identity-uninstalls-banners-reports.md` S, I.7, R.5, R.9, R.26 (R wins).

- **Removed (app events):** the app-event endpoint, its request / response schemas and fixtures (`events_request`,
  `events_request_consent`, `events_response`, `events_response_feature_disabled`), the SDK method that fed it and
  its money helper. `goal()` is the only method for what happens in an app; goals go to `POST /v1/sdk/goals`. No
  public SDK version ever had the old method (nothing was published before this change).
- **`received` goal status (R.9).** `GoalStatus` gains `received` = stored, not counted. A goal whose name isn't
  ticked in the dashboard yet answers `200` with a `results[]` item `{status: "received", reason: "not_counted_yet"}`;
  an archived goal answers `{status: "received", reason: "goal_archived"}` (R.10: no more `410 goal_archived`). The
  SDKs treat it as success: removed from the queue, never retried, delivered to the app as `received`. Fixture
  `goals_response_received`.
- **Old queue items.** The queue is persisted. An app-event item left by an earlier development build (no `goal`)
  is dropped on the next flush without a network call.
- **Version policy.** The `allowed_calls` vocabulary has no `events`. A blocked SDK without `allowed_calls` uses the
  default `config`, `install`, `open`, `opt_out`, `consent`, `install_ping`: it sends goals only when the server
  lists `goals`. `allowed_events` and `strip_event_properties` are gone from `blocked_instructions` (ignored if sent).
- **Firebase forwarding.** `firebase_forwarding.mirror_events` is gone (ignored if sent); the SDKs log only
  `clikgate_attribution` and set the `cg_first_*` user properties. Goals aren't logged to Firebase.
- **No conversion values (R.5).** `conversion_value_schema` is gone from `/config` (ignored if sent); the iOS SDK
  never updates SKAdNetwork / AdAttributionKit conversion values.
- **Installation ID for the app (I.7, R.26).** Not a wire change: the value is the `Clikgate-Installation-Id` /
  `installation_id` the SDK already sends. Android `Clikgate.getInstallationId()` (suspend) or
  `getInstallationId(listener)`, iOS `try await Clikgate.shared.installationId()` (or the completion form), Flutter
  and React Native `await Clikgate.getInstallationId()`. It waits for the first launch's config answer (one attempt,
  at most about 5 s; offline it answers at once) and is `null` when tracking is off: opted out, consent denied or not
  given yet where it's required, or deep-link-only mode (`app_attribution` off). New after a reinstall (iOS reports
  the previous one as `keychain_previous_installation_id`, SDK spec §4). Not personal data; allowed in private mode.
  The business's server uses it for identity Path B: `POST /v1/people/identify` with `app_id` + `installation_id`
  (R.25), or `POST /v1/goals/events` with `app_id` + `installation_id` in place of `click_id` (R.2). Guide:
  https://clikgate.com/docs/identify-users

## Change 23 additions ("Allow unknown goal names" off: `unknown_goal`)

Spec: `docs/spec/clikgate-change-23-unknown-goals-goal-groups.md` U, S, R.1, R.2, R.9 (R wins).

- **The setting** (`goals.allow_unknown_names`, per organisation, live only; default on) is server-side. On, names
  with no goal behind them answer `received` / `not_counted_yet` (change 22). Off, they are **refused**:
  - a `results[]` item `{status: "refused", reason: "unknown_goal", counted: false, goal_kind: null}` (and, like
    `payment_goal_needs_confirmation`, the matching `rejected[]` item with `code: "unknown_goal"`);
  - an archived goal: `{status: "refused", reason: "goal_archived"}` (never `410`);
  - a whole request answered `422` with the result body itself (`{status: "refused", reason: ...}`, schema
    `goal_refusal`, no `error` envelope) is read as that reason for every goal in the batch.
- **SDK behaviour (S, R.9):** final. The item leaves the persisted queue, is never retried or re-queued, and the app
  gets `refused` with the reason. The SDKs never check names on the device and never cache the setting: every call
  goes to the server, which decides. Debug builds only (Android `FLAG_DEBUGGABLE`, iOS `#if DEBUG`) log
  ``Goal `{name}` isn't set up in Clikgate`` — the goal name only, never the reference, customer ID, values or labels.
  Flutter and React Native pass the native result through.
- **Check order (R.2):** name format, key and environment, unknown or archived name, "Allow from browser", payment
  fields. An unknown name sent with `provider` and `reference` in strict mode gets `unknown_goal`.
- **Fixtures:** `goals_response_refused_unknown_goal` (`goals_response`), `goal_refusal_unknown_goal` and
  `goal_refusal_goal_archived` (`goal_refusal`).
