# Clikgate spec v3 — additions to v2

v3 = `clikgate-sdk-referrals-uninstall-spec.md` (v2, everything still applies) **plus** this file.
This file holds every section v3 adds or changes, transcribed from the v3 document. Sections
9A–9D (leaderboards, identity checks, WhatsApp chat attribution, offline/USSD codes) are **core**
and also apply to web-only customers (no app required). 9E (feature switches) gates everything.

## 0. Scope additions
5. **Leaderboards (core, headless)** — configurable rankings over referral activity (or custom points) that any customer can use to build their own in-app leaderboards and contests via API and SDK (9A).
6. **Duplicate-identity checks (core)** — customers send *hashed* identity signals (BVN, NIN, phone, email, bank account); Clikgate flags the same verified person appearing as several users, a referee matching their referrer, or a returning user posing as new (9B).
7. **WhatsApp chat attribution (core)** — links that open a WhatsApp chat with a reference code; with a WhatsApp Business Platform webhook connected, Clikgate attributes the chat and later sales to the click (9C).
8. **Offline and USSD codes (core)** — human-friendly codes for posters, agents, USSD, SMS keywords and in-store use, redeemed through one API and attributed like clicks (9D).

Docs added: `docs/LEADERBOARDS.md`, `docs/IDENTITY_CHECKS.md` (hashing helper code in Python, Node, Kotlin, Swift, Dart, with test vectors), `docs/WHATSAPP.md`, `docs/OFFLINE_CODES.md` (incl. USSD integration example).

Concept: **Feature switch** — per-organisation on/off setting (with optional per-app override) for each optional capability (9E).

## 3. Changes to existing backend code (additions)
- links + redirect: new link kind `whatsapp` and optional `offline_code` on any link (9C, 9D).
- conversion matching: new identifiers `whatsapp_ref`, `whatsapp_contact_hash`/`whatsapp_contact`, `offline_touch_id`, `subject` (9C.5, 9D.4); conversion `source` gains `whatsapp` and `offline`.
- inbound: WhatsApp Cloud API webhook receiver (9C.3).
- New routers: `leaderboards`, `identity`, `whatsapp`, `codes`.

## 4. Data model additions
### 4.3 referrals (additions)
- referral reasons add `duplicate_identity`.
- **referrers** add: `attributes` (jsonb, app-supplied, e.g. `{"city":"Lagos","campus":"UNILAG"}`; used for leaderboard segments), `leaderboard_opt_out` (bool, default false), `display_name` (exists).
- **referrals** add: `source` value `offline_code`; `rules_snapshot` (exists).

### 4.4 leaderboards (9A)
- **leaderboards**: id (`lb_`), organization_id, program_id (nullable: `null` = points-only board not tied to one program), name, status (`active|archived`), metric (jsonb: `{"type":"qualified|installs|signups|step|points", "step_event": null, "weights": null}`), period (jsonb: `{"type":"all_time|daily|weekly|monthly|custom", "start": null, "end": null, "timezone":"Africa/Lagos", "week_starts":"monday"}`), segment_by (nullable: `"country"` or `"attribute:<key>"`), min_score_to_appear (int, default 1), show_pending (bool, default true), visibility (`sdk|server`), display (jsonb: `{"name_mode":"masked|display_name|code", "max_entries": 100}`), finalize_delay (jsonb: `{"mode":"auto"}` — auto = program's longest step window + hold days; or `{"mode":"fixed","hours":N}`), created_at, updated_at.
- **leaderboard_periods**: id, leaderboard_id, organization_id, period_key (`all`, `2026-10-20`, `2026-W43`, `2026-10`, `custom`), starts_at, ends_at, status (`open|closed_provisional|final`), finalize_at, finalized_at, finalized_by (`system|user_id`).
- **leaderboard_snapshots**: id, leaderboard_id, period_key, segment (`_all` or value), status (`provisional|final`), entries (jsonb: ordered list `{rank, referrer_id, display, score, pending, tie_break_at}` up to 1,000), computed_at.
- **leaderboard_adjustments**: id (`lba_`), organization_id, leaderboard_id, referrer_id, period_key, points (int, may be negative), reason, actor_type, actor_id, created_at. Applies only to `points` metric boards or as an additive bonus on any board (`applies_to_metric: true` flag on the board's metric config).

### 4.5 identity checks (9B)
- **identity_signals**: id, organization_id, app_scope (`org` or app_id — dedupe scope), subject_type (`customer_user_id|installation_id|external_customer_id`), subject_id, signal_type (`bvn|nin|phone|email|bank_account|tax_id|custom:<name>`), signal_hash (server re-HMAC of the hash the customer sent, hex), verified (bool), first_seen_at, last_seen_at. Unique (organization_id, app_scope, subject_type, subject_id, signal_type, signal_hash). Index (organization_id, app_scope, signal_type, signal_hash).
- **identity_matches**: id (`idm_`), organization_id, app_scope, signal_type, signal_hash_ref (no hash exposed via API), subject_a (type+id), subject_b (type+id), first_detected_at, context (`referral_check|signup|manual_query`), status (`open|confirmed|dismissed`).

### 4.6 WhatsApp (9C)
- **whatsapp_channels**: id (`wac_`), organization_id, display_name, phone_number_e164, phone_number_id (nullable), waba_id (nullable), connection (`none|cloud_api|forwarded`), webhook_token, app_secret_encrypted (nullable), verify_token, prefill_template (default `"Hi! {message} (ref: {ref})"`), status, created_at.
- **whatsapp_refs**: ref (6-char code, alphabet without ambiguous characters, unique per org while active), organization_id, channel_id, click_id, link_id, created_at, expires_at (default 30 days). Also cached in Redis `waref:{org}:{ref}`.
- **whatsapp_conversations**: id (`wcv_`), organization_id, channel_id, contact_hash (server HMAC of the sender's WhatsApp ID / phone), ref, click_id, link_id, campaign_id, first_message_at, attributed (bool), attribution_method (`ref_in_message|manual|none`), created_at. **Message text is not stored.**

### 4.6A organisation features (9E)
- **organization_features**: organization_id, feature_key, enabled (bool), config (jsonb), enabled_at, enabled_by, disabled_at, disabled_by, updated_at. PK (organization_id, feature_key).
- **app_feature_overrides**: organization_id, app_id, feature_key, enabled (bool), config (jsonb), updated_at. PK (app_id, feature_key). An override can only switch a feature **off** or change its config for one app.
- **plan_feature_limits** (platform-managed, staff only): plan, feature_key, allowed (bool), limits (jsonb, e.g. `{"max_leaderboards": 3}`).
- **feature_data_purges**: id, organization_id, feature_key, requested_by, scheduled_for, completed_at, status (`scheduled|cancelled|completed`), counts (jsonb).

### 4.7 codes and offline touches (9D)
- **codes**: id, organization_id, code (unique per org, case-insensitive, `^[A-Z0-9]{3,20}$` after normalisation), kind (`referral|link`), referrer_id (nullable), program_id (nullable), link_id (nullable), status (`active|disabled`), valid_from, valid_until, max_redemptions (nullable), redemptions_count, created_at. Referral codes are written here too, so all codes share one namespace and one resolver.
- **offline_touches**: id (`oft_`), organization_id, code_id, link_id, campaign_id, referrer_id (nullable), channel (`ussd|sms_keyword|agent|pos|in_store|call_center|event|print|radio|other`), subject_type (`installation_id|customer_user_id|external_customer_id|phone_hash|none`), subject_id, agent_id (nullable), location (jsonb: `{country, region, city, store_id}`), occurred_at, external_id (idempotency, unique per org), metadata (jsonb), created_at.

## 5. SDK API additions
| Method | Path | Purpose |
|---|---|---|
| GET | `/v1/sdk/leaderboards/{id}` | Top entries for a `visibility = sdk` board: `?period=current|previous|<period_key>&segment=&limit=` (≤ 100). Names per board display mode; opted-out referrers excluded |
| GET | `/v1/sdk/leaderboards/{id}/me` | Current user's rank, score, pending, gap to next rank, period end (identified user; identity token if program requires) |
| GET | `/v1/sdk/leaderboards/{id}/around-me` | `?radius=5` entries above and below the current user |
| POST | `/v1/sdk/leaderboards/opt-out` | `{program_id, opt_out: true|false}` — hide the current user from all boards of a program |
| POST | `/v1/sdk/identity-signals` | Optional client path for identity hashes (9B.3); only with a valid identity token and only if the app enables `identity_checks.accept_from_sdk` |
| POST | `/v1/sdk/codes/redeem` | Redeem an offline code inside the app (e.g. promo code typed at signup) — same rules as 9D.3 with subject = current installation |

Server-to-server additions: `POST /v1/identity-signals` (scope `identity:write`), `POST /v1/codes/redeem` (`conversions:write`). New scopes `identity:write`, `identity:read`, `leaderboards:manage` (role mapping: `developer` gets all three; `viewer` gets `identity:read`).

## 8.4 fraud config addition
```json
"identity_dedupe": {"enabled": false, "signal_types": ["bvn", "nin", "phone"], "require_verified": true, "action": "reject"}
```
- **Duplicate identity** (if `identity_dedupe.enabled`, see 9B): the referee's identity signals match the referrer's → `self_referral`; match an earlier user of the app or another referee in this program → `duplicate_identity`. Action per program setting (`reject` or `flag`). Checked when signals arrive, at each step, and again before qualification — referrals in `holding` re-check at `hold_until`.

## 9A. Leaderboards (core, headless)
Clikgate provides ranking data and logic; customers build their own screens. No Clikgate UI is required (optional hosted page in 9A.7).

### 9A.1 Definitions
Any number of leaderboards per program (or org-wide points boards). Config (table 4.4):
- **Metric**: `qualified` (default, +1 per qualified referral); `installs` (+1 per referral created, non-rejected — warn in docs and API response `warnings: ["gameable_metric"]`); `signups` (+1 per referral reaching `signed_up`); `step` (+1 per referral completing `step_event`); `points` (weighted: `{"weights": {"installed": 1, "signed_up": 2, "step:purchase": 5, "qualified": 10}}` plus adjustments). Rejected/disqualified referrals remove any points they earned (reversal), so scores only reflect referrals still in good standing.
- **Period**: `all_time | daily | weekly | monthly | custom(start, end)` in the board's timezone. A referral counts in the period in which the scoring transition happened (e.g. qualified_at).
- **Segments**: none, `country` (referrer's install country), or `attribute:<key>` from `referrers.attributes`.
- **Display**: `masked` (e.g. "Ada O." from display_name, else code with middle masked), `display_name`, or `code`. Never exposes customer_user_id or anything about referees via SDK.
- **Eligibility**: `min_score_to_appear`; blocked referrers, `leaderboard_opt_out` referrers and referrers with an open fraud flag are excluded.

### 9A.2 Live ranking
- Redis sorted set per `(leaderboard, period_key, segment)`: `lb:{id}:{period_key}:{segment}`; member = referrer_id; score encodes `points * 1e10 + (9_999_999_999 - first_reach_unix_seconds)` so ties go to whoever reached the score first.
- Pending counts in hash `lbp:{id}:{period_key}`.
- Updated by a consumer of referral state-change events (and adjustments) — idempotent per (referral_id, transition).
- Nightly reconciliation recomputes open periods from PostgreSQL (`referrals`, `referral_state_changes`, `leaderboard_adjustments`) and repairs Redis drift.

### 9A.3 Periods and finalisation
- `open` → at `ends_at`: `closed_provisional` (snapshot written) → at `finalize_at`: recompute from PostgreSQL after all referrals created in the window have reached a terminal state or the finalise delay elapsed → `final` (snapshot, immutable) → emit `leaderboard.period_finalized` with top N (default 100).
- `finalize_delay.mode = auto`: program's longest step window + hold days. Owners can finalise early (`POST …/finalize`), which records who and when.
- Once final, later reversals don't change the snapshot; they're listed in `post_final_changes` on the period.

### 9A.4 Adjustments
`POST /v1/leaderboards/{id}/adjustments` `{referrer_id, points, reason, period_key?}` (default current period). Audit-logged; reflected immediately; included in snapshots as a separate `adjustments` field per entry.

### 9A.5 Control-plane API (scope `leaderboards:manage` for writes, `analytics:read` for reads)
| Method | Path | Purpose |
|---|---|---|
| POST · GET | `/v1/leaderboards` (filter `program_id`) | Create / list |
| GET · PATCH · DELETE | `/v1/leaderboards/{id}` | Retrieve / update (metric and period changes apply from the next period) / archive |
| GET | `/v1/leaderboards/{id}/entries` | `?period=current|previous|<key>&segment=&limit=&starting_after=` → `{period, status, entries:[{rank, referrer_id, display, score, pending, adjustments}]}` |
| GET | `/v1/leaderboards/{id}/entries/around/{referrer_id}` | `?radius=5` |
| GET | `/v1/leaderboards/{id}/referrers/{referrer_id}` | Rank, score, pending, gap to next rank, best rank this period |
| GET | `/v1/leaderboards/{id}/periods` · `/periods/{key}` | Period list and final/provisional snapshot |
| POST | `/v1/leaderboards/{id}/periods/{key}/finalize` | Finalise early |
| POST · GET | `/v1/leaderboards/{id}/adjustments` | Add / list adjustments |
| PATCH | `/v1/referrers/{id}` | Add `attributes`, `leaderboard_opt_out`, `display_name` |

### 9A.6 Webhooks
`leaderboard.period_closed` (provisional), `leaderboard.period_finalized` (final top N), `leaderboard.rank_changed` (opt-in per board; only when a referrer enters/leaves the top N or moves ≥ 1 rank within the top N; max one event per referrer per board per hour).

### 9A.7 Optional hosted leaderboard page
`GET https://{program link domain}/leaderboard/{leaderboard_id}` — server-rendered, mobile-first, light page (< 40 KB) showing top entries for `visibility = sdk` boards, styled with the program's OG image and colours (`display.theme`), embeddable in a web view. `?me=<signed token>` (token minted by `/v1/sdk/leaderboards/{id}/me?embed=1`) highlights the viewer.

## 9B. Duplicate-identity checks (core)
Detects the same real person behind multiple accounts **without Clikgate ever receiving raw identity data**.

### 9B.1 Hashing contract
1. The customer normalises each value: `phone`: E.164 (`+2348031234567`); `email`: trimmed lowercase (for Gmail, remove dots and `+tags` in the local part); `bvn` / `nin` / `bank_account` / `tax_id`: digits only; `custom:*`: trimmed uppercase.
2. The customer computes `hex(HMAC_SHA256(customer_pepper, signal_type + ":" + normalised_value))` with a **pepper only the customer knows** (never sent to Clikgate).
3. Clikgate re-hashes: `stored = hex(HMAC_SHA256(server_identity_key, organization_id + ":" + received_hash))`.
- Matching only within one organisation (optionally one app). **No cross-customer matching.**
- Copy-paste helpers in `docs/IDENTITY_CHECKS.md` (Python, Node, Kotlin, Swift, Dart) with test vectors.

### 9B.2 What it checks
- **Same person, many accounts**: another subject in the same scope already has a matching verified signal → `identity_matches` row, `identity.duplicate_detected` webhook.
- **Referrals**: during referral checks (8.4), compare referee signals with the referrer's (→ `self_referral`), with users who existed before the referee's install (→ `duplicate_identity`), and with other referees in the program (→ `duplicate_identity`).
- **Sign-up bonuses without referrals**: `GET /v1/identity/matches?subject_type=customer_user_id&subject_id=…` before granting any bonus.

### 9B.3 API (scopes `identity:write` / `identity:read`)
| Method | Path | Purpose |
|---|---|---|
| POST | `/v1/identity-signals` | `{app_id?, subject: {type, id}, signals: [{type:"bvn", hash:"…", verified:true}], check: true}` → stores signals and, if `check`, returns `{matches:[{match_id, signal_type, other_subject:{type,id}, first_detected_at}]}` synchronously (≤ 200 ms) |
| DELETE | `/v1/identity-signals` | `{subject}` — remove all signals for a subject (also via privacy erasure) |
| GET | `/v1/identity/matches` | Filters: subject, signal_type, status, from, to |
| PATCH | `/v1/identity/matches/{id}` | `{status: "confirmed"|"dismissed"}`; dismissed matches are not re-raised for the same pair |
| GET · PATCH | `/v1/identity/settings` | Org/app scope, accepted signal types, `accept_from_sdk` (default false), retention days (default: keep while subject active, delete 30 days after erasure) |

SDK path (`/v1/sdk/identity-signals`) exists for apps without a backend; server-to-server is recommended; the SDK never hashes with a pepper shipped inside the app unless the customer explicitly opts in (docs explain the weaker guarantee).

### 9B.4 Webhooks
`identity.duplicate_detected` — `{match_id, signal_type, subject_a, subject_b, context}` (never hashes).

### 9B.5 Privacy
Purpose limited to fraud prevention; hashes only; per-org re-hashing; deletion on erasure; customers remain responsible for a lawful basis (NDPA).

## 9C. WhatsApp chat attribution (core)
### 9C.1 WhatsApp links
- New link kind `whatsapp` with `whatsapp_channel_id` and `whatsapp_message`.
- On click the redirect: mints the click ID; creates a 6-char **ref** (e.g. `K7Q2PZ`), stores `whatsapp_refs` (+ Redis `waref:{org}:{ref}`), TTL 30 days; renders the channel's `prefill_template` with `{message}` and `{ref}` → `https://wa.me/{phone_without_plus}?text=…` → `302`.
- Preview bots get OG tags as usual (no ref minted).

### 9C.2 Channels
`POST /v1/whatsapp/channels` `{display_name, phone_number_e164, connection: "none"|"cloud_api"|"forwarded", prefill_template?}`.
- `none`: no ingestion; attribution relies on manual confirmation (9C.4).
- `cloud_api`: customer provides `phone_number_id`, `waba_id`, `app_secret`; Clikgate returns a webhook URL + verify token to configure in their Meta app.
- `forwarded`: customer's BSP/inbox forwards inbound payloads in Cloud API format or simple `{from, text, timestamp}` signed with the channel's webhook secret.

### 9C.3 Inbound webhook
- `GET /in/whatsapp/{webhook_token}` — Meta verification handshake (`hub.mode`, `hub.verify_token`, `hub.challenge`); verify against current Meta documentation.
- `POST /in/whatsapp/{webhook_token}` — verify the signature (Meta's `X-Hub-Signature-256` with the app secret for `cloud_api`; channel secret for `forwarded`; verify current header names), respond `200` immediately, process in a worker: find refs with `\b[A-HJ-NP-Z2-9]{6}\b`, validate against `waref:{org}:{ref}`; `contact_hash = HMAC(server_key, org + ":" + sender_wa_id)`; create/update `whatsapp_conversations` (first matching message per contact per ref), `attributed = true`; emit `whatsapp.conversation_attributed`.
- Discard message text after extraction; never log it. Ignore non-text messages except for updating `last_message_at`.

### 9C.4 Manual confirmation
`POST /v1/whatsapp/attributions` `{channel_id, ref, contact: {phone_e164? | contact_hash?}, occurred_at}`.

### 9C.5 Sales from WhatsApp chats
`POST /v1/conversions` accepts `whatsapp_ref` or `whatsapp_contact` (`{phone_e164}` hashed server-side, or `contact_hash`) when no `click_id`: most recent attributed conversation for that contact (or the ref) within the link's attribution window → `attributed`, `source = whatsapp`, `click_id` = the conversation's click.

### 9C.6 API, analytics, webhooks
| Method | Path | Scope |
|---|---|---|
| POST · GET · PATCH · DELETE | `/v1/whatsapp/channels` | links:write / links:read (secrets write-only) |
| POST | `/v1/whatsapp/channels/{id}/test` | links:write |
| GET | `/v1/whatsapp/conversations` | attribution:read (contact shown only as hash prefix) |
| POST | `/v1/whatsapp/attributions` | conversions:write |
Analytics summary gains `chats_started` and `chat_to_sale_rate`. Webhook `whatsapp.conversation_attributed`.

## 9D. Offline and USSD codes (core)
### 9D.1 Codes
Referral codes and link codes share the `codes` table and resolver. Any link can have an `offline_code` (`POST/PATCH /v1/links`). Codes are case-insensitive, normalised (strip spaces/dashes, uppercase), ambiguous characters avoided when generated; optional validity window and redemption cap.

### 9D.2 How channels connect
Clikgate does **not** run USSD or SMS shortcodes. The customer's (or aggregator's) system calls `POST /v1/codes/redeem` when a code is used (USSD `*347*ADA42#`, SMS keyword, agent POS). `docs/OFFLINE_CODES.md` includes a USSD session example and an SMS keyword example.

### 9D.3 Redemption API
`POST /v1/codes/redeem` (scope `conversions:write`; idempotent by `external_id`):
```json
{"external_id": "ussd-session-88231", "code": "ADA42", "channel": "ussd",
 "subject": {"type": "phone_hash", "id": "<customer HMAC of +2348031234567>"},
 "app_id": "app_android_...", "agent_id": "AGT-1029",
 "location": {"country": "NG", "region": "Lagos", "store_id": null},
 "occurred_at": "2026-10-20T11:02:00Z", "metadata": {"menu": "signup"}}
```
Response: `{offline_touch_id, code: {kind, link_id, campaign_id, referrer_id, program_id}, referral: {...}|null}`. Errors: `code_not_found`, `code_expired`, `code_disabled`, `redemption_limit_reached`.
- Creates an `offline_touches` row (counted like a click with `channel`); increments `redemptions_count`; for referral codes with a subject that maps to an install or customer user not yet referred → creates a referral with `source = offline_code` (all fraud and identity checks apply); otherwise stores the touch for later matching.
- Later matching: when the subject installs or identifies (same `customer_user_id`/`installation_id`, or the customer sends the same `phone_hash` as an identity signal), the pending touch is linked and, for referral codes, the referral is created if still within `manual_code_entry_window_days`.

### 9D.4 Conversions from offline touches
`POST /v1/conversions` accepts `offline_touch_id` or `subject` (`{type, id}`): most recent offline touch for that subject within the link's attribution window → `attributed`, `source = offline`.

### 9D.5 API, analytics, webhooks
| Method | Path | Scope |
|---|---|---|
| POST | `/v1/codes/redeem` | conversions:write |
| GET | `/v1/codes` · `/v1/codes/{code}` | links:read |
| PATCH | `/v1/codes/{id}` | links:write |
| GET | `/v1/offline-touches` | attribution:read (filters channel, code, link, campaign, agent_id, from, to) |
Analytics summary gains `offline_touches` and grouping by `channel` and `agent_id`. Webhook `code.redeemed`.

## 9E. Organisation settings and feature switches (core)
### 9E.1 Feature catalogue and defaults
| Feature key | What it controls | Default |
|---|---|---|
| `app_attribution` | SDK API, install attribution, deferred deep links, app events | On (when the org has an app) |
| `referrals` | Referral programs, referrers, referral engine | On |
| `leaderboards` | Leaderboards (9A) | On (needs `referrals` unless the board is points-only) |
| `identity_checks` | Identity signals and duplicate detection (9B) | **Off** |
| `whatsapp_attribution` | WhatsApp links, channels, inbound webhooks (9C) | Off |
| `offline_codes` | Offline/USSD code redemption (9D) | On |
| `uninstall_tracking` | Silent-push uninstall checks (9) | Off |
| `probabilistic_matching` | Probabilistic install matching (0.2) | Off; enabling still requires the owner acknowledgement |
| `apple_search_ads` | AdServices token flow (7.3) | Off |
| `skan_postbacks` | AdAttributionKit/SKAdNetwork receiver and reports (11) | Off |
| `inbound_conversion_webhooks` | `/in/{token}` endpoints | On |
| `qr_codes` | QR generation | On |
| `destination_scanning` | Safe-browsing checks on links | On (staff can force on) |

Code-level registry (`core/features.py`): key, default, dependencies (`leaderboards` → `referrals`), conflicts, staff-forceable, per-app override allowed, data categories (for purges).

### 9E.2 Resolution
`is_enabled(org, feature, app_id=None)` = plan allows it (`plan_feature_limits`) **and** org row says enabled (or catalogue default) **and** all dependencies enabled **and**, if `app_id`, no app override turning it off. Cache resolved flags in Redis `features:{org_id}` (and `features:{org_id}:{app_id}`), invalidated on change; redirect and SDK API read only the cache. Expose the resolved set in `GET /v1/sdk/config`.

### 9E.3 Behaviour when a feature is off
- Control-plane endpoints return `403` `{"error": {"type": "permission", "code": "feature_disabled", "message": "Identity checks are turned off for this organisation. Enable them in organisation settings.", "param": "identity_checks"}}`. Read endpoints for historical data still work while data exists.
- SDK endpoints return `200` with a no-op body (`{"accepted": false, "reason": "feature_disabled"}`); SDK methods return a typed `feature_disabled` result.
- Engines skip the feature: with `identity_checks` off, referral fraud checks skip identity rules (programs keep their `identity_dedupe` config but the API response shows `"inactive_reason": "feature_disabled"`); with `whatsapp_attribution` off, WhatsApp links fall back to their `fallback_url`; with `uninstall_tracking` off, no pushes are sent and hold periods ignore `require_installed`.
- Webhooks for a disabled feature are not emitted.
- In-flight: referrals already in `holding` when a fraud-related feature is turned off are evaluated with the rules active at evaluation time; recorded in their state history.

### 9E.4 Turning a feature off — data
`PATCH` with `enabled: false` takes a `data_action`: `keep` (default; stop collecting, keep data read-only); `purge` (delete after a 7-day grace period via `feature_data_purges`, cancellable by re-enabling; identity → all `identity_signals` and `identity_matches`; whatsapp → refs and conversations; uninstall → push tokens and check history, installs keep last known status); `purge_now` (owners only, immediate, irreversible, audit-logged). Emit `organization.feature_data_purged` when done.

### 9E.5 API (scope `org:manage` to change; any read scope to view)
| Method | Path | Purpose |
|---|---|---|
| GET · PATCH | `/v1/organization/settings` | General settings (name, default domain, default `click_id_param`, attribution window, data retention, timezone, `require_destination_allowlist`, webhook `api_version`) + resolved feature summary |
| GET | `/v1/organization/features` · `/{key}` | `{key, enabled, source: "org"|"default"|"plan", allowed_by_plan, dependencies, config, enabled_at, enabled_by}` |
| PATCH | `/v1/organization/features/{key}` | `{enabled, config?, data_action?, acknowledgement?}`. Enabling `leaderboards` with `referrals` off → `409 dependency_disabled`; disabling `referrals` while leaderboards are on → `409 dependent_enabled` unless `cascade: true`. `probabilistic_matching` still requires `acknowledged_policy_version` and the owner role |
| POST | `/v1/organization/features/batch` | Several changes atomically |
| GET · PUT · DELETE | `/v1/apps/{id}/features/{key}` | Per-app overrides (off or config only) |
| GET | `/v1/organization/features/purges` · POST `/{id}/cancel` | Scheduled purges |
| GET · PATCH | `/v1/admin/plans/{plan}/features` | Staff: plan limits |
| POST | `/v1/admin/organizations/{id}/features/{key}` | Staff: force on/off with reason |

Feature-specific config moves under the feature (old endpoints stay as aliases): `identity_checks.config = {scope: "org"|"app", accepted_signal_types, accept_from_sdk: false, retention_days}`; `uninstall_tracking.config = {schedule}`; `whatsapp_attribution.config = {ref_ttl_days: 30}`.

### 9E.6 Audit and webhooks
Audit `organization.feature_enabled` / `feature_disabled` / `settings_updated` with before/after. Webhooks `organization.feature_changed` (`{key, enabled, changed_by, data_action}`), `organization.feature_data_purged`.

### 9E.7 SDK behaviour
`/v1/sdk/config` returns `features: {referrals: true, leaderboards: true, identity_checks: false, ...}` (SDK-relevant only). SDKs expose `Clikgate.isFeatureEnabled(key)`; calls to disabled features resolve with a `feature_disabled` result without network calls. Config refreshed on launch and at most hourly.

## 12. New webhook types
`leaderboard.period_closed`, `leaderboard.period_finalized`, `leaderboard.rank_changed`, `identity.duplicate_detected`, `whatsapp.conversation_attributed`, `code.redeemed`, `organization.feature_changed`, `organization.feature_data_purged`.

## 13. New jobs
| Job | Schedule | Purpose |
|---|---|---|
| `retention_cleanup` (extended) | daily | + WhatsApp refs after expiry, identity signals 30 days after subject erasure |
| `leaderboard_updater` | stream consumer | Apply referral transitions and adjustments to Redis rankings (idempotent) |
| `leaderboard_period_roller` | every minute | Close ended periods (provisional snapshot), open new ones, emit `period_closed` |
| `leaderboard_finalizer` | every 10 min | Finalise periods past `finalize_at` from PostgreSQL, emit `period_finalized` |
| `leaderboard_reconcile` | nightly | Rebuild open-period Redis rankings from PostgreSQL |
| `leaderboard_rank_notifier` | every 5 min | Throttled `rank_changed` events for opted-in boards |
| `identity_recheck_holding` | every 10 min | Re-run identity checks for holding referrals when new signals arrived |
| `whatsapp_inbound_processor` | queue | Extract refs, attribute conversations |
| `offline_touch_linker` | queue + hourly | Link pending offline touches to installs/users as subjects appear |

## 15–18. SDK additions
Android:
```kotlin
Clikgate.referrals.shareToWhatsApp(context, programId, message = "Join me on MyApp: {url}") // opens WhatsApp directly if installed, else share sheet
Clikgate.leaderboards.top(leaderboardId, period = Period.CURRENT, segment = null, limit = 50) { page -> }
Clikgate.leaderboards.me(leaderboardId) { myRank -> }            // rank, score, pending, gapToNext, periodEndsAt
Clikgate.leaderboards.aroundMe(leaderboardId, radius = 5) { entries -> }
Clikgate.leaderboards.setOptOut(programId, optOut = true)
Clikgate.codes.redeem(code = "LAGOS50") { result -> }
```
iOS:
```swift
Clikgate.shared.referrals.shareToWhatsApp(programId:message:)          // whatsapp:// if installed, else share sheet (LSApplicationQueriesSchemes "whatsapp")
let page = try await Clikgate.shared.leaderboards.top(id: "lb_...", period: .current, segment: nil, limit: 50)
let me = try await Clikgate.shared.leaderboards.me(id: "lb_...")
let around = try await Clikgate.shared.leaderboards.aroundMe(id: "lb_...", radius: 5)
try await Clikgate.shared.leaderboards.setOptOut(programId: "rpg_...", optOut: true)
let redemption = try await Clikgate.shared.codes.redeem("LAGOS50")
```
Flutter:
```dart
await Clikgate.referrals.shareToWhatsApp(programId: 'rpg_...', message: 'Join me on MyApp: {url}');
final page = await Clikgate.leaderboards.top('lb_...', period: LeaderboardPeriod.current, limit: 50);
final me = await Clikgate.leaderboards.me('lb_...');
final around = await Clikgate.leaderboards.aroundMe('lb_...', radius: 5);
await Clikgate.leaderboards.setOptOut(programId: 'rpg_...', optOut: true);
final redemption = await Clikgate.codes.redeem('LAGOS50');
```
Flutter example adds: share to WhatsApp, **weekly leaderboard screen with "my rank" and around-me**, promo code redemption.
React Native: same surface (`referrals.shareToWhatsApp`, `leaderboards.{top, me, aroundMe, setOptOut}`, `codes.redeem`).
All SDKs: `Clikgate.isFeatureEnabled(key)`; disabled-feature calls resolve with `feature_disabled` without network calls.

## 19. Milestones (v3 order)
1. Backend schema, organisation settings & feature switches (+ v2 M1 content). Every later milestone checks its feature flag.
2. Redirect & landing. 3. SDK API & attribution. 4. Events pipeline.
5. **Codes + identity checks backend** (built before referrals so referral fraud checks can use them).
6. Referrals backend (incl. offline codes, duplicate identity). 7. **Leaderboards**. 8. **WhatsApp**.
9. Uninstall tracking. 10. Android + Flutter Android. 11. iOS + Flutter iOS. 12. Attestation.
13. ASA + SKAN. 14. React Native. 15. Customer APIs, analytics (incl. chats and offline touches), privacy (incl. identity signals, offline touches, WhatsApp conversations).
16. Hardening & docs (load tests add leaderboard updates at 100 transitions/s, WhatsApp inbound at 50 msg/s).

## 20. New E2E scenarios and definition of done
6. **Duplicate identity**: referrer A identified with a BVN hash → referee B installs via A's link, signs up, sends the same BVN hash → `referral.rejected` (`self_referral`); referee C sends a phone hash already used by an older user → `referral.rejected` (`duplicate_identity`) and `identity.duplicate_detected`; dismissing the match via API prevents re-raising.
7. **Leaderboard**: weekly `qualified` board → three referrers qualify different counts → `GET entries` ranks correctly with tie-break by time → a referral is disqualified after counting → score reverses → period ends → `period_closed` (provisional) → after finalise delay → `period_finalized` matches PostgreSQL recomputation; a +5 adjustment is reflected; an opted-out referrer is hidden from SDK endpoints but visible to the owner API.
8. **WhatsApp**: click WhatsApp link → `302` to `wa.me` with prefilled ref → simulated Cloud API webhook (valid signature) with the ref → `whatsapp.conversation_attributed` → `POST /v1/conversions` with `whatsapp_contact` → `attributed`, `source = whatsapp`, original click ID; invalid signature rejected; message text not persisted.
9. **USSD referral code**: `POST /v1/codes/redeem` with a referral code and `phone_hash` subject → pending touch → the app later identifies a user and sends the same phone hash as an identity signal → referral created with `source = offline_code` → qualifies through its steps.
10. **Feature switches**: new org → `identity_checks` off by default → `POST /v1/identity-signals` returns `403 feature_disabled`; SDK identity call returns no-op; referral fraud checks skip identity rules → enable → signals accepted and checks run → disable with `data_action: purge` → purge scheduled, cancellable → after grace period signals and matches deleted and `organization.feature_data_purged` emitted; enabling `leaderboards` with `referrals` off returns `409 dependency_disabled`; an app override turns `uninstall_tracking` off for one app only; a plan that disallows `whatsapp_attribution` blocks enabling it.

Definition of done additions:
- Every optional feature can be switched on/off per organisation (and off per app); disabled features collect nothing, emit no webhooks and fail gracefully in SDKs; identity checks are off by default.
- The Flutter example's leaderboard screen shows live ranks and "my rank"; a final weekly snapshot matches a full recomputation.
- **No raw identity values, WhatsApp message text or raw phone numbers are stored anywhere** (verified by a test that scans tables and logs after the e2e suite).
- A WhatsApp link click → chat → sale is attributed end to end, and a USSD code redemption leads to a qualified referral.

## 21. Out of scope additions
Cross-customer (consortium) identity matching; sending WhatsApp messages or running USSD/SMS shortcodes (Clikgate only receives events and redemptions).
