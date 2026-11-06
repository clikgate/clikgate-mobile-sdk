> **Workspace note (coordinator):** backend repository = `clikgate_api` (code in `src/<domain>/`; `app/core/features.py` → `src/core/features.py` + `src/features/`, `app/services/...` → `src/<domain>/services/...`), dashboard repository = `clikgate_frontend`, SDKs = `clikgate_mobile_sdk` (B.5.2 SDK signal fields). Change 01 is in `docs/spec/clikgate-change-01-billing-plans.md` and is built (billing in `src/billing`, staff console in `src/staff`).
>
> **Email (user instruction):** Clikgate's email adapter must send real email through **ZeptoMail**, the provider distyla_api already uses (`distyla_api/src/messaging/services/mailer.py`: `POST {MAIL_URL}` — ZeptoMail's send-email API — with header `authorization: <MAIL_AUTHORIZATION_CODE>` (the `Zoho-enczapikey …` send-mail token) and JSON `{from: {address, name}, to: [{email_address: {address, name}}], subject, htmlbody}`). Build it as a proper adapter next to the existing console adapter: async httpx, timeouts, check the response status, retries through the worker, text + HTML bodies, attachments for exports, never log bodies/tokens. Settings: `MAIL_URL`, `MAIL_AUTHORIZATION_CODE` (secret), `EMAIL_FROM_ADDRESS`, `EMAIL_FROM_NAME`; console adapter when the token is empty.

# Clikgate Change 02 — Weekly Summaries, Exports, Ad Spend & Ad Fraud Protection (backend + frontend)

> **Instructions for the AI building this:**
> - This is a **self-contained change set** on an existing Clikgate codebase. Read only this file and the existing code it names.
> - **Prerequisite:** change 01 (`clikgate-change-01-billing-plans.md`) is built. Every feature here is gated by plan through its entitlements.
> - **Backend repository** (`clikgate`): build sections A and B, milestones C2-B1 to C2-B5.
> - **Dashboard repository** (`clikgate-dashboard`): build sections A and F, milestones C2-F1 to C2-F4, after the backend part is deployed and OpenAPI types are regenerated. Follow the skills in `.claude/skills/`.
> - Reuse existing conventions: `TenantContext` and environment columns (test mode), the feature registry and entitlements (change 01), `usage_daily` and fact tables, saved reports, the email adapter, the WhatsApp adapter, system alerts, outbox events and webhooks, audit log, encryption helpers (Fernet), error format, idempotency, Arq workers.
> - **Ad platform APIs change often.** Before building each platform integration (B.4.5, B.4.7), check that platform's current official documentation (API versions, OAuth scopes, required permissions, rate limits, approval/access levels) and record findings in `docs/DECISIONS.md`. Where this file and current documentation disagree, follow the documentation and note it.
> - Never log tokens, feed secrets or hashed customer identifiers. Run the full test suite after each milestone.

---

## A. Overview (read first)

### A.1 What this change does
1. **Weekly summaries (no AI):** rule-based plain sentences about the past week, sent by email and optionally WhatsApp.
2. **Exports:** scheduled CSV/Excel files by email, and Google Sheets sync by (a) sharing a sheet with Clikgate's service account or (b) a private CSV feed link for `IMPORTDATA`. **Clikgate never stores customer Google or cloud credentials.**
3. **Ad spend:** one spend table filled by **manual entry**, **CSV import**, or **connected Meta / Google Ads / TikTok accounts**; campaign matching; cost and ROAS reports; sending conversions back to ad platforms.
4. **Ad fraud protection:** a fraud score and reasons on every attributed install; flag-only on Growth, exclude/hold/custom rules/dispute evidence on Pro; wasted-spend reporting.

### A.2 Plans (seed as a new plan version for every plan, created by `system`)

| Feature key / allowance | Free | Starter | Growth | Pro | Enterprise |
|---|---|---|---|---|---|
| `weekly_summary` | ✓ (short: 3 metrics) | ✓ | ✓ (+ monthly) | ✓ (+ daily option) | ✓ |
| `whatsapp_summary` | — | — | ✓ | ✓ | ✓ |
| `scheduled_exports` | — | ✓ | ✓ | ✓ (+ raw event rows) | ✓ |
| allowance `export_schedules` | 0 | 1 (weekly only) | 5 | unlimited | custom |
| `sheets_sync` | — | — | ✓ (daily refresh) | ✓ (hourly refresh) | ✓ |
| `ad_spend_import` (manual + CSV) | — | — | ✓ | ✓ | ✓ |
| `ad_connections` | — | — | ✓ | ✓ | ✓ |
| allowance `ad_accounts` | 0 | 0 | 2 | unlimited | unlimited |
| `conversion_sending` | — | — | — | ✓ | ✓ |
| `fraud_insights` (flag only) | — | — | ✓ | ✓ | ✓ |
| `fraud_protection` (act) | — | — | — | ✓ | ✓ |
| allowance `whatsapp_summary_numbers` | 0 | 0 | 3 | 3 | custom |

- Register all keys in `app/core/features.py` with dependencies: `ad_connections` → `ad_spend_import`; `conversion_sending` → `ad_connections` or the "own token" mode (B.4.7); `fraud_protection` → `fraud_insights`; `fraud_insights` → `app_attribution`.
- Migration: for each plan, create plan version N+1 copying the active version and adding these keys/allowances; activate with `apply_to: "all_now"` and `created_by: system`. Do not change prices.
- Dashboard CSV download (existing) stays on all plans.

### A.3 Out of scope
AI-written text, storing customer cloud credentials (S3, BigQuery, Snowflake), automatic ad budget changes, view-through attribution, paying networks or blocking ad traffic at the network.

---

## B. Backend

### B.1 Shared pieces
- **Datasets registry** `app/services/datasets.py`: named datasets used by summaries, exports and feeds — `daily_summary`, `links`, `clicks_raw` (Pro), `installs`, `conversions`, `referrals`, `spend_roas`, `fraud_flags`. Each defines columns, a query builder (live environment only, organisation-scoped, date range), and a row cap per plan. All exports, feeds and sheets use this registry; never write ad-hoc queries.
- **FX rates:** table `fx_rates_daily` (date, base, quote, rate, source). Worker pulls daily from a configurable provider (`FX_PROVIDER_URL`, document the choice in DECISIONS); fallback to the last known rate and mark `fx_estimated: true`. Used to convert spend and revenue to the organisation's reporting currency.

### B.2 Weekly summaries

**Data model**
- `summary_preferences`: user_id, organization_id, email_enabled (default true for owners/admins), whatsapp_enabled, whatsapp_number_id (fk `summary_whatsapp_numbers`), frequency (`weekly|monthly|daily`, daily Pro only), updated_at.
- `summary_whatsapp_numbers`: id (`swn_`), organization_id, user_id, phone_e164, verified_at, verification_code_hash, created_at. Count limited by `whatsapp_summary_numbers`.
- `summary_runs`: id (`smr_`), organization_id, period_start, period_end, frequency, sentences (jsonb), metrics (jsonb), sent_to (jsonb: channel, user_id, status, provider_message_id), created_at.

**Worker `summaries_dispatch`** (hourly):
1. Select active organisations whose local time is Monday 08:00 (weekly), the 1st 08:00 (monthly), or 08:00 daily (Pro with daily preference), using the organisation timezone. Skip suspended/expired organisations and organisations without `weekly_summary`.
2. Compute metrics for the period and the previous period (live only): clicks, installs, conversions, revenue, qualified referrals, top 3 links, top 3 channels, top 3 referrers, spend and cost per install (if spend exists), fraud flagged count and wasted spend (if `fraud_insights`), usage percentages, destination scan failures.
3. Run the **rules engine** `app/services/summaries/rules.py`: an ordered list of pure functions `rule(metrics, prev) -> Sentence | None` with `priority` and template. Required rules:
   - channel change ≥ 20% with ≥ 50 events in either period: "Installs from {channel} {rose|fell} {pct}% ({prev} → {curr})."
   - totals line: "{clicks} clicks, {installs} installs and {conversions} conversions this week."
   - top referrer: "{name} brought {n} qualified customers."
   - top link: "Your top link was '{slug}' with {clicks} clicks."
   - broken destination: "Link '{slug}' points to a page that isn't loading."
   - usage ≥ 80%: "You've used {pct}% of this month's {meter}."
   - fraud: "{n} installs from {network} looked fake, about {wasted} of spend."
   - spend: "You spent {spend} on ads; cost per install was {cpi}."
   - quiet week fallback.
   Keep the top 5 by priority (Free: totals line + 2). Numbers formatted in the organisation's currency and locale.
4. Render email (HTML + text) and, for opted-in verified numbers, a WhatsApp **utility template** message (`clikgate_weekly_summary`, parameters: org name, up to 5 short lines joined, dashboard URL). Template name configurable `WHATSAPP_SUMMARY_TEMPLATE`.
5. Store `summary_runs`; idempotent per (organization, period, frequency).

**API**
| Method | Path | Purpose |
|---|---|---|
| GET · PATCH | `/v1/me/summary-preferences?organization_id=` | Own preferences |
| POST | `/v1/summary-whatsapp-numbers` | Add number → sends verification code (rate-limited) |
| POST | `/v1/summary-whatsapp-numbers/{id}/verify` | Confirm code |
| DELETE | `/v1/summary-whatsapp-numbers/{id}` | Remove |
| GET | `/v1/summaries/preview` | Render the current period's summary without sending |
| GET | `/v1/summaries` | Past runs |

Unsubscribe link in emails uses a signed token (`/v1/public/summaries/unsubscribe?token=`).

### B.3 Exports

**Scheduled email exports**
- `export_schedules`: id (`exs_`), organization_id, name, datasets (text[]), format (`csv|xlsx`), frequency (`daily|weekly|monthly`), time_local, weekday/monthday, date_range (`previous_period|last_7_days|last_30_days|month_to_date`), recipients (jsonb: user_ids and verified external emails), status (`active|paused`), last_run_at, created_by, created_at. Count limited by `export_schedules`; Starter: weekly only.
- `export_recipients_external`: organization_id, email, verified_at, token_hash.
- `export_runs`: id (`exr_`), schedule_id (nullable for one-off), status, row_counts (jsonb), file_key, file_size, expires_at, error, created_at.
- Worker `exports_dispatch` (every 5 min): due schedules → build files in chunks (streaming CSV; `openpyxl` write-only for xlsx; one sheet per dataset, or a zip of CSVs for multiple datasets) → store in object storage → email: attach if total ≤ 10 MB, otherwise a signed download link valid 7 days (`/v1/exports/download/{token}`).
- `clicks_raw` only with Pro; row cap per plan from the datasets registry; if truncated, say so in the email.
- API: CRUD `/v1/export-schedules`, `POST /v1/export-schedules/{id}/run-now`, `GET /v1/export-runs`, `POST /v1/export-recipients` (+ verify), `POST /v1/exports` (one-off export by email).

**Google Sheets option A — share with Clikgate's service account**
- Config: `GOOGLE_SHEETS_SERVICE_ACCOUNT_JSON` (secret), shown address `GOOGLE_SHEETS_SERVICE_ACCOUNT_EMAIL`.
- `sheet_syncs`: id (`shs_`), organization_id, spreadsheet_id, spreadsheet_url, datasets (text[]), date_range, mode (`replace`), refresh (`daily|hourly`, hourly Pro only), status (`pending_access|active|error|paused`), last_synced_at, last_error, created_by, created_at.
- Flow: customer pastes URL → backend parses ID → `POST /v1/sheet-syncs/{id}/check` tries to open it with the service account → `active` or `pending_access` with the instruction "Share this sheet with {email} as Editor".
- Worker `sheets_sync`: for due syncs, for each dataset write a tab named `Clikgate – {dataset}` (create if missing), clear and write values in batches (`values.batchUpdate`), and a `Clikgate – info` tab with last updated time. Respect Google Sheets API quotas: global token bucket + per-spreadsheet serialisation, exponential backoff on 429/5xx. Cap cells per sync (configurable, default 2,000,000) and skip raw datasets that would exceed it with an error message.
- On 403/404 → `status: error`, `last_error: "Clikgate no longer has access to this sheet"`, email the creator once.
- API: CRUD `/v1/sheet-syncs`, `POST /v1/sheet-syncs/{id}/check`, `POST /v1/sheet-syncs/{id}/sync-now`, `GET /v1/sheet-syncs/service-account` (returns email).

**Google Sheets option B — private CSV feed for `IMPORTDATA`**
- `data_feeds`: id (`fed_`), organization_id, dataset, date_range, secret_hash (sha256 of a 32-byte random secret, shown once), status (`active|revoked`), last_fetched_at, fetch_count, created_by, created_at.
- Public endpoint `GET /feeds/{secret}.csv` (separate router, no auth header): look up by hash, live data only, cached 15 minutes in Redis, row cap 50,000 (Growth) / 200,000 (Pro), rate-limited per feed, every fetch logged (time, ip hash). Revoked or unknown → 404.
- API: `POST /v1/data-feeds` (returns URL and the `=IMPORTDATA("…")` formula once), `GET /v1/data-feeds`, `POST /v1/data-feeds/{id}/rotate`, `POST /v1/data-feeds/{id}/revoke`.
- Feeds require `sheets_sync`.

### B.4 Ad spend, connections and conversion sending

#### B.4.1 Data model
- `ad_accounts`: id (`ada_`), organization_id, environment, platform (`meta|google|tiktok|other`), external_account_id (nullable for manual), name, currency, timezone, spend_source (`manual|csv|connection`), connection_id (nullable), connected_since (nullable), status (`active|disconnected|error`), created_at. Unique (organization_id, environment, platform, external_account_id). Count of `connection`-sourced accounts limited by `ad_accounts`.
- `ad_spend_daily`: organization_id, environment, ad_account_id, source (`manual|csv|meta|google|tiktok`), date, campaign_id, campaign_name, adset_id, adset_name, ad_id, ad_name, spend_minor, currency, spend_reporting_minor, reporting_currency, fx_estimated, impressions, clicks, import_id (nullable), manual_entry_id (nullable), updated_at. Unique key (organization_id, environment, ad_account_id, date, campaign_id, adset_id, ad_id) with empty-string defaults for missing levels.
- `spend_imports`: id (`spi_`), organization_id, environment, filename, column_mapping (jsonb), detected_format (`clikgate|meta|google|tiktok|custom`), row_count, error_count, errors (jsonb, first 200), status (`previewed|committed|removed`), created_by, created_at.
- `spend_manual_entries`: id (`spm_`), organization_id, environment, ad_account_id, campaign_name, campaign_id (nullable), date_from, date_to, amount_minor, currency, note, link_ids (text[], optional), offline_code_ids (text[], optional), created_by, created_at.
- `ad_connections`: id (`adc_`), organization_id, platform, mode (`oauth|own_token`), token_encrypted, refresh_token_encrypted (nullable), scopes (text[]), external_user_or_business_id, expires_at, status (`active|needs_reconnect|revoked`), last_sync_at, last_error, created_by, created_at.
- `campaign_mappings`: organization_id, ad_account_id, campaign_id, match (`campaign_id_param|utm_campaign|manual`), clikgate_campaign_key (string used on links), link_ids (text[]), created_at.
- `conversion_destinations`: id (`cvd_`), organization_id, environment, platform, connection_id, target (Meta dataset/pixel id, Google conversion action resource name, TikTok pixel/event source id), event_mappings (jsonb: clikgate event → platform event name, value/currency fields), send_hashed_identifiers (bool, default false), status, created_at.
- `conversion_sends`: id, destination_id, source_event_id, platform_event_name, status (`queued|sent|failed|skipped_fraud|skipped_no_click_id`), attempts, response_code, error, sent_at. Idempotent per (destination_id, source_event_id).

All tables are environment-scoped (test mode works; connections in test mode only allowed against sandbox/test accounts).

#### B.4.2 One source per ad account
- When an account switches source (e.g. `csv` → `connection`), the API returns `409 spend_source_conflict` with `{existing_source, rows_from_date}` unless the request includes `replace_from: "<date>"`; then existing rows for that account from that date are deleted (soft-deleted with audit) and the new source owns them.
- Manual entries for an account with `connection` source are rejected with `409` (advise a separate "Other costs" account).

#### B.4.3 Manual entry
- `POST /v1/spend/manual` `{ad_account_id | new_account {platform, name, currency}, campaign_name, campaign_id?, date_from, date_to, amount_minor, currency, note?, link_ids?, offline_code_ids?}`.
- Spread evenly across days (remainder on the last day) into `ad_spend_daily`; response includes `per_day_minor` and the human message.
- `link_ids` / `offline_code_ids` create `campaign_mappings` with `match: manual` so ROAS works for offline and influencer costs.
- `GET/PATCH/DELETE /v1/spend/manual/{id}` (edit re-spreads; delete removes its rows).

#### B.4.4 CSV import
- `GET /v1/spend/imports/template` → CSV with header `date,platform,account,campaign_id,campaign_name,adset,ad,spend,currency,impressions,clicks`.
- `POST /v1/spend/imports` (multipart, ≤ 20 MB, ≤ 200,000 rows) → detect format (Clikgate template, standard Meta Ads Manager export, Google Ads campaign report, TikTok Ads export — detection by header sets; keep detectors in `app/services/spend/csv_formats.py` with fixtures), propose column mapping, parse dates (ISO, `DD/MM/YYYY`, `MM/DD/YYYY` with a required choice when ambiguous), validate (amount ≥ 0, known currency, date not in the future), return preview of first 20 rows + row-level errors + totals per account. Status `previewed`.
- `PATCH /v1/spend/imports/{id}` to adjust mapping → re-preview.
- `POST /v1/spend/imports/{id}/commit` → upsert rows by unique key (accounts auto-created with `spend_source: csv`, subject to B.4.2), status `committed`.
- `POST /v1/spend/imports/{id}/remove` → delete its rows, status `removed`.
- Idempotency-Key supported on commit.

#### B.4.5 Connected accounts (Meta, Google Ads, TikTok)
> Check current platform docs first (see header). The descriptions below are the intended design.

- **Platform switches (staff):** `ads_meta_live`, `ads_google_live`, `ads_tiktok_live` in platform settings (staff console, 🔐). When off, OAuth connect is available only to organisations on an allowlist (`ads_dev_org_ids`) used for development/testing against your own or test accounts.
- **OAuth:** `POST /v1/ad-connections/{platform}/start` → returns the authorisation URL with signed `state` (org, user, nonce, expiry 10 min); `GET /v1/ad-connections/{platform}/callback` exchanges the code, stores encrypted tokens, lists accessible ad accounts → `GET /v1/ad-connections/{id}/accounts` → `POST /v1/ad-connections/{id}/accounts` `{external_account_ids[], replace_from?}` to select (B.4.2, `ad_accounts` limit).
  - Meta: Facebook Login for Business; minimum scopes to read ad insights (and send conversions if `conversion_sending`). Read insights at campaign/adset/ad level by day.
  - Google Ads: OAuth with the Ads API scope; Clikgate's developer token (`GOOGLE_ADS_DEVELOPER_TOKEN`) and optional login customer id for manager accounts; read campaign/ad group/ad metrics by day via GAQL.
  - TikTok: TikTok for Business OAuth; read integrated reports by day.
- **Sync worker `ad_spend_sync`:** daily 03:00 organisation time + `POST /v1/ad-connections/{id}/sync-now` (rate-limited 1 per 15 min). Pull from the last successful date (first sync: last 90 days) through today, always re-pull the last 3 days. Upsert into `ad_spend_daily` with `source` = platform. Handle pagination, rate limits (backoff), token refresh. On auth failure → `needs_reconnect`, email owner once, banner.
- `DELETE /v1/ad-connections/{id}` → revoke token at the platform where supported, delete tokens, keep spend rows (accounts become `disconnected`).
- Tokens: Fernet-encrypted with a dedicated key `AD_TOKEN_ENCRYPTION_KEY`; never returned by any API; never logged.

#### B.4.6 Matching spend to results
- Click ingestion (existing) must store `fbclid`, `gclid`, `wbraid`, `gbraid`, `ttclid` and all `utm_*` parameters, plus any of the platform macros' values passed as `cg_campaign_id`, `cg_adset_id`, `cg_ad_id`. Document recommended link templates per platform in `docs/ADS.md` (Meta `cg_campaign_id={{campaign.id}}`, Google `cg_campaign_id={campaignid}`, TikTok `cg_campaign_id=__CAMPAIGN_ID__`) — verify macro syntax against current docs.
- Attribution facts get `ad_platform`, `ad_campaign_id`, `ad_adset_id`, `ad_ad_id` resolved in order: `cg_*` ids → `utm_campaign` matched against campaign names/ids → `campaign_mappings` (manual).
- `GET /v1/spend/unmatched` lists spend campaigns with no results and result campaigns with no spend; `POST /v1/campaign-mappings` links them.

#### B.4.7 Reports and conversion sending
- **Reports API:** `GET /v1/analytics/spend` with `group_by` (platform, account, campaign, adset, ad, day, channel) returning spend, impressions, clicks (platform), Clikgate clicks, installs, cost per install, conversions, CPA, revenue, ROAS, fraud-flagged installs, wasted spend, `fx_estimated`. Include non-paid channels (WhatsApp, referrals, offline codes, organic links) with spend 0 when `include_unpaid=true`. Add `spend_roas` to the datasets registry and saved reports.
- **Conversion sending (`conversion_sending`, Pro):**
  - Modes: `oauth` (uses the connection, requires the platform switch on) or `own_token` (customer pastes a Meta Conversions API access token or TikTok Events API token created in their own Events Manager; allowed before approval; encrypted like OAuth tokens). Google Ads requires `oauth`.
  - CRUD `/v1/conversion-destinations`, `POST /v1/conversion-destinations/{id}/test` (sends a test event using the platform's test-event mechanism where available).
  - Worker `conversion_send`: on outbox events `install.attributed`, `conversion.attributed` (and referral qualified if mapped) for live environment, build the platform payload (event name per mapping, event time, event id = Clikgate event id for deduplication, value/currency if present, click id: Meta `fbc` built from `fbclid` and click time, Google `gclid`/`gbraid`/`wbraid`, TikTok `ttclid`). If `send_hashed_identifiers` is on, add SHA-256 normalised email/phone when the organisation provided them on the conversion. Skip with `skipped_no_click_id` when the platform needs a click id and none exists. **Never send events whose install/conversion has fraud decision `exclude` or `hold`** (`skipped_fraud`). Retry with backoff up to 24 h; log every send.
  - `GET /v1/conversion-sends?destination_id=&status=` for the dashboard log.
  - The NDPA notice text for hashed identifiers lives in `docs/ADS.md` and is returned by the API for the UI.

### B.5 Ad fraud protection

#### B.5.1 Data model
- `fraud_rule_sets`: id (`frs_`), version, is_default, rules (jsonb: rule key → enabled, weight, params), created_at. Seed version 1 with the defaults below.
- `fraud_org_settings`: organization_id, threshold (default 70), action (`flag|exclude|hold`, Growth forced `flag`), rule_overrides (jsonb, Pro), per_app_overrides (jsonb), per_network_overrides (jsonb), updated_by, updated_at.
- `fraud_scores`: id, organization_id, environment, install_id (and/or conversion_id), app_id, network/channel, campaign_id, sub_publisher (from `cg_sub` / `af_siteid`-style param `cg_publisher`), score (0–100), reasons (jsonb list of {rule, weight, detail}), rule_set_version, decision (`clean|flagged|excluded|held`), reviewed_label (`real|fake|null`), reviewed_by, created_at.
- `asn_lists`: asn, org_name, category (`datacenter|hosting|vpn|mobile_carrier_ng|mobile_carrier_other`), source, updated_at. Monthly refresh worker from a configurable source (`ASN_LIST_SOURCE_URL`); seed known Nigerian mobile carriers (MTN, Airtel, Glo, 9mobile) as `mobile_carrier_ng` — verify ASNs before seeding and record in DECISIONS.

#### B.5.2 Default rules (version 1)
| Rule key | Signal | Default weight |
|---|---|---|
| `ctit_too_fast` | Click-to-install time < 10 s (use install-begin time when available) | 45 |
| `install_before_click` | Android install referrer `install_begin_timestamp` earlier than the attributed click | 70 |
| `click_flooding` | Source/link with ≥ 1,000 clicks and click-to-install rate < 0.1% over 24 h, or ≥ 20 clicks per device per 24 h | 35 |
| `datacenter_ip` | Click or install from `datacenter|hosting|vpn` ASN | 40 |
| `emulator_or_rooted` | SDK reports emulator or rooted/jailbroken | 40 |
| `device_farm_pattern` | ≥ 10 installs in 1 h for the same app/source sharing ASN (non-carrier), device model and OS version | 35 |
| `geo_mismatch` | Click country ≠ install country (ignore when either is unknown) | 20 |
| `known_bad_device` | Device previously flagged by identity checks or reviewed `fake` | 50 |
| `ctit_very_long` | CTIT > 24 h | 5 (low on purpose) |

- Score = min(100, sum of weights of matched rules). Never use IP address alone; `mobile_carrier_ng` ASNs never trigger `datacenter_ip` and reduce `device_farm_pattern` weight to 10.
- Add SDK fields if missing: `is_emulator`, `is_rooted`, Android `install_begin_timestamp` and `referrer_click_timestamp` (core SDK; no new permissions). Bump SDK minor versions; old SDKs simply contribute fewer signals.

#### B.5.3 Scoring and actions
- Scoring runs synchronously after attribution decision (budget 20 ms; heavy aggregate rules read Redis counters updated on click/install) and is re-evaluated by worker `fraud_rescore` after 1 h for aggregate rules.
- Decision: score ≥ threshold → `flagged` (Growth) or org action `exclude`/`hold` (Pro). `exclude`: install stays recorded but attribution credit moves to `organic (excluded: fraud)`; partner postbacks and conversion sends skipped. `hold`: credit kept but postbacks/conversion sends/`install.attributed` webhooks to networks held for review; release or exclude via review.
- Review: `POST /v1/fraud/installs/{id}/review` `{label: real|fake}` (Pro) → updates decision, releases or excludes held items, feeds `known_bad_device`.
- Webhook `fraud.install_flagged` (batched every 15 min).

#### B.5.4 Fraud API and reports
| Method | Path | Plan | Purpose |
|---|---|---|---|
| GET | `/v1/fraud/summary?from&to&group_by=network|campaign|sub_publisher|app|day` | `fraud_insights` | Flagged counts, rate, top reasons, wasted spend |
| GET | `/v1/fraud/installs` | `fraud_insights` | Flagged installs with reasons (paginated) |
| POST | `/v1/fraud/installs/{id}/review` | `fraud_protection` | Label real/fake |
| GET · PATCH | `/v1/fraud/settings` | read: insights; write: protection | Threshold, action, overrides |
| GET | `/v1/fraud/evidence?network=&from&to` | `fraud_protection` | CSV: install id, click id, times, CTIT, ASN category, reasons, score |

- **Wasted spend** = Σ over campaigns (flagged installs × campaign cost per install), using `ad_spend_daily`; null when no spend for that campaign.
- Add `fraud_flags` to the datasets registry; summaries use fraud metrics.

### B.6 Staff console additions (change 01 console)
- Platform switches for ad platforms (🔐), the dev allowlist, view an organisation's ad connections (no tokens), fraud rule set versions (create/activate 🔐), FX provider status.

### B.7 Security and privacy
- New secrets: `GOOGLE_SHEETS_SERVICE_ACCOUNT_JSON`, `AD_TOKEN_ENCRYPTION_KEY`, `GOOGLE_ADS_DEVELOPER_TOKEN`, `META_APP_ID`/`META_APP_SECRET`, `TIKTOK_APP_ID`/`TIKTOK_APP_SECRET`, `WHATSAPP_SUMMARY_TEMPLATE`, `FX_PROVIDER_URL`, `ASN_LIST_SOURCE_URL`.
- Feed secrets and verification codes stored as hashes only. Tokens encrypted, never returned or logged. OAuth `state` signed and single-use.
- Every connection, disconnection, feed creation/rotation, conversion destination change and fraud setting change writes the organisation audit log.
- Hashed identifiers only sent when the organisation opts in; deletion requests (existing data-subject flow) also delete queued conversion sends for that person.

### B.8 Tests
- **Summaries:** each rule (fires / doesn't fire at thresholds), top-5 selection, Free short version, timezone dispatch, idempotency, test data excluded, WhatsApp opt-in verification and number limit.
- **Exports:** schedule due logic per timezone, attachment vs link at 10 MB, xlsx output, row caps and truncation note, Starter weekly-only, external recipient verification.
- **Sheets:** access check states, tab writing with a mocked Sheets client, quota backoff, error on lost access; feeds: hash lookup, cache, revoke/rotate, row caps, 404s.
- **Spend:** manual spread (remainder), CSV detection for each fixture format, ambiguous dates, preview errors, commit upsert idempotency, remove import, one-source conflict and `replace_from`, FX conversion and estimated flag, `ad_accounts` limit.
- **Connections:** OAuth state validation, token encryption, sync pagination and 3-day re-pull (mocked clients), `needs_reconnect`, platform switch + dev allowlist gating.
- **Matching & reports:** `cg_*` ids, utm fallback, manual mappings, ROAS maths, unpaid channels included.
- **Conversion sending:** payload builders per platform (snapshot tests), dedup event id, skip no click id, skip fraud, retries, hashed identifiers only when opted in, own-token mode.
- **Fraud:** every rule, Nigerian carrier exemption, threshold decisions per plan, exclude moves credit, hold/release, review labels, wasted spend, evidence CSV.
- **E2E:** Growth org imports Meta CSV → links with `cg_campaign_id` get clicks and installs → ROAS report correct → 5 fast installs flagged → wasted spend shown → weekly summary contains spend and fraud sentences → Pro upgrade → action `exclude` → conversion sends skip excluded installs.

### B.9 Backend milestones
1. **C2-B1** Plan version migration with new keys/allowances, datasets registry, FX rates, weekly summaries (email), scheduled email exports.
2. **C2-B2** WhatsApp summaries, Google Sheets option A, data feeds (option B).
3. **C2-B3** Spend data model, manual entry, CSV import with format detection, one-source rule, click-id capture, campaign matching, spend reports.
4. **C2-B4** Fraud model, rules v1, ASN lists, SDK signal fields, scoring, actions, review, fraud API, wasted spend; summaries/exports include fraud.
5. **C2-B5** Ad connections (Meta, Google Ads, TikTok) with platform switches and dev allowlist, sync worker, conversion destinations and sending (oauth + own token), staff console additions, docs (`docs/ADS.md`, `docs/EXPORTS.md`, `docs/FRAUD.md`); regenerate `openapi.json`.

---

## F. Frontend (dashboard)

### F.1 Modules and navigation
- New modules: `modules/summaries`, `modules/exports`, `modules/spend` (spend, imports, connections, mappings, conversion destinations), `modules/fraud`. Architecture rules as usual; API types regenerated.
- Navigation additions:
  - **Measure → Ad spend & ROAS** (`/[org]/spend`): overview, Spend entries, Imports, Connections, Campaign matching, Conversion sending.
  - **Protect → Ad fraud** (`/[org]/fraud`): overview, Flagged installs, Settings.
  - **Settings → Summaries** (`/[org]/settings/summaries`) and **Settings → Exports & Sheets** (`/[org]/settings/exports`).
- All gated with `FeatureGate`; features outside the plan show the change 01 **Plan upgrade** intro variant (e.g. "Ad fraud protection is included in Growth and above"). Nav items show plan badges.

### F.2 Summaries settings
- Personal toggles: email on/off, frequency (daily option only on Pro), WhatsApp on/off with number selector.
- WhatsApp numbers: add number → code entry (`OtpInput` from change 01) → verified list with remove; limit shown ("2 of 3 numbers").
- **Preview** card rendering this period's sentences exactly as the email shows them, plus "Send me a test" (email only).
- History list of past summaries.

### F.3 Exports & Sheets
- **Scheduled exports:** table of schedules (name, datasets, format, frequency, recipients, last run, status) and a create/edit sheet: datasets multiselect (raw clicks shows a Pro badge), format, frequency (Starter: weekly only, others disabled with tooltip), time, date range, recipients (members picker + external emails with "verification sent" state). "Run now". Runs history with download links (until expiry).
- **Google Sheets — Option A card:** paste sheet URL → step card showing the service-account email with Copy button and a 3-step illustrated guide ("Open your sheet → Share → paste this email as Editor") → "Check access" → status chip (Waiting for access, Active, Error with message). Choose datasets, date range, refresh (hourly Pro only). "Sync now", last synced time.
- **Google Sheets — Option B card:** create feed (dataset, date range) → reveal dialog (`SecretRevealDialog`) showing the URL and the ready `=IMPORTDATA("…")` formula with Copy buttons, shown once; list of feeds with last fetched, fetch count, Rotate, Revoke (confirm).
- Usage of `export_schedules` limit shown with upgrade link.

### F.4 Ad spend & ROAS
- **Overview:** date range + currency (reporting currency; `fx_estimated` footnote), KPI tiles (spend, installs, cost per install, conversions, CPA, revenue, ROAS, wasted spend if fraud data), chart of spend vs installs by day (Recharts wrapper), table grouped by platform → campaign → ad set (expandable), toggle "Include unpaid channels" adding WhatsApp, referrals, offline codes, organic rows. "Why don't our numbers match Meta?" info panel (static copy from API).
- **Add spend** button with three choices:
  1. **Enter manually** sheet: platform (Meta, Google, TikTok, Influencer, Radio/TV, Print/Outdoor, Other), account (select or create), campaign, single date or range, amount + currency, link/offline code pickers, note. Live helper text "₦300,000 over 10 days = ₦30,000 a day".
  2. **Upload CSV** wizard: download template → drop file → detected format badge → column mapping (only if needed) and date-format choice when ambiguous → preview table (first 20 rows, error rows highlighted with reasons, totals per account) → confirm. Imports list with status and "Remove this import" (confirm with row count).
  3. **Connect an account**: platform cards (Meta, Google Ads, TikTok). If the platform switch is off and the org isn't allowlisted, the card shows "Coming soon — use CSV or manual entry for now". Otherwise OAuth redirect → account picker (respecting `ad_accounts` limit) → one-source conflict dialog ("This account has CSV spend up to 14 Oct. Replace it from the connection date?").
- **Connections:** list with platform, accounts, last sync, status chip (Active, Needs reconnect, Disconnected), "Sync now", "Reconnect", "Disconnect" (confirm; spend kept).
- **Campaign matching:** two columns "Spend with no results" / "Results with no spend" with a link action; link-template helper showing recommended URL parameters per platform with Copy.
- **Conversion sending (Pro):** destinations list; create: platform → mode (Connected account / Paste your own token, the latter with masked `SecretCodeInput` and help text on where to create it) → target id → event mapping table (Clikgate event → platform event, value field) → hashed identifiers switch with the NDPA notice → "Send test event". Send log table with status filters (Sent, Failed, Skipped – no click ID, Skipped – fraud).

### F.5 Ad fraud
- **Overview:** KPI tiles (installs checked, flagged, flagged rate, wasted spend), flagged-rate trend chart, breakdown table by network / campaign / sub-publisher with top reasons (reason chips with plain-language tooltips, e.g. "Installed 4 seconds after the click — too fast for a real download").
- **Flagged installs:** table (time, app, network, campaign, score bar, reasons, decision chip). Pro: row actions "Mark real" / "Mark fake", bulk actions, filters by decision (Held for review first).
- **Settings:** Growth sees threshold and action read-only with "Upgrade to Pro to exclude or hold suspicious installs". Pro: threshold slider (50–95), action (Flag only / Exclude from attribution / Hold for review) with consequences explained, rule list with on/off and weight (advanced, collapsed), per-network overrides.
- **Dispute evidence (Pro):** pick network and date range → download CSV.

### F.6 Shared UI additions
- `ScoreBar` (0–100 with warning/danger tones), `ReasonChip`, `CurrencyAmount` (minor units + currency + estimated marker), `CsvImportWizard` (generic steps reused by spend), `PlatformCard`, `CopyField`.
- Storybook stories for each (light/dark).

### F.7 Frontend tests
- **Unit:** spread helper text, ROAS/CPI formatting, fraud reason copy mapping, CSV wizard state machine, plan gating per feature key.
- **Component (MSW):** summaries preview and WhatsApp verification; schedules with plan limits; Sheets option A states and option B reveal-once; manual entry spread; CSV wizard (detected Meta format, ambiguous dates, error rows, commit, remove); connection cards with switch off/on, conflict dialog, needs-reconnect; conversion destination with own token and hashed identifiers notice; fraud overview, review actions (Pro) and read-only settings (Growth).
- **Playwright:** Growth org uploads a Meta CSV → spend overview shows ROAS → fraud page shows flagged installs and wasted spend → creates a weekly export and an IMPORTDATA feed.

### F.8 Frontend milestones
1. **C2-F1** Regenerate types and mocks, shared components, Summaries settings, Exports & Sheets.
2. **C2-F2** Ad spend overview, manual entry, CSV import wizard, campaign matching.
3. **C2-F3** Ad fraud overview, flagged installs, settings, evidence download.
4. **C2-F4** Connections (OAuth flows, conflict dialog), conversion sending, nav badges and plan gating everywhere, tests.

---

## Definition of done
- Every feature in this file turns on and off with the organisation's plan via change 01 entitlements.
- Summaries are rule-based (no AI), sent by email and optionally WhatsApp, never count test data.
- Exports go by email; Google Sheets works by sharing with Clikgate's service account or an `IMPORTDATA` link; no customer cloud credentials are stored.
- Spend can be added by manual entry, CSV import, or a connected Meta, Google Ads or TikTok account, all into one table with one source per ad account and no double counting; everything except connecting other businesses' real accounts works before platform approval.
- Fraud scoring flags suspicious installs with reasons on Growth and lets Pro exclude, hold, review and export evidence; flagged events are never sent to ad platforms; wasted spend is reported.
