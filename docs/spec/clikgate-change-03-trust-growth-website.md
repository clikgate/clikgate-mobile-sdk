> **Workspace note (coordinator):** repositories in this workspace — backend `clikgate_api` (code in `src/<domain>/`; `app/...` paths map there, e.g. `app/integrations/google_aap/` → `src/integrations/google_aap/`), SDKs `clikgate_mobile_sdk` (the spec's `clikgate/sdks/`; the web script is served by the backend from `src/static`/`src/snippet`), dashboard `clikgate_frontend` (the spec's `clikgate-dashboard`), website + status page `clikgate_website` (new, the spec's `clikgate-website`). Changes 01 and 02 specs are in `docs/spec/`. Production deploys through `distyla_config` (docker swarm + nginx), except the status page which must run on Cloudflare (W.7). Email goes through the ZeptoMail adapter (Change 02). Link-domain hosts in production: `clik.gt` (existing platform domain), `clk.ng` (new), `test.clik.gt` (test mode), `dsty.la` (Distyla's own custom domain — must keep working).

# Clikgate Change 03 — Link Domain Split, Privacy & Consent, Partner Readiness, Sales Tracking, Agencies, Migration, Status Page & Website

> **Instructions for the AI building this:**
> - This is a **self-contained change set** on an existing Clikgate codebase. Read only this file and the existing code it names.
> - **Prerequisites:** changes 01 (billing plans, staff console) and 02 (summaries, exports, ad spend, fraud) are built.
> - **Three repositories:**
>   - `clikgate` (backend + SDKs): sections A, B and S, milestones C3-B1 to C3-B7 and C3-S1 to C3-S2.
>   - `clikgate-dashboard`: sections A and F, milestones C3-F1 to C3-F4 (after the backend is deployed and API types regenerated). Follow `.claude/skills/`.
>   - `clikgate-website` (**new**): sections A and W, milestones C3-W1 to C3-W4. It holds the marketing website (`clikgate.com`), docs and guides, and the status page (`status.clikgate.com`).
> - Reuse existing conventions: Part 3 connected domains (platform domains, AASA/assetlinks on every domain), destination scanning, feature registry + entitlements (change 01), conversions and attribution facts, conversion sending (change 02), datasets registry, staff console with TOTP step-up (🔐), audit logs, encryption helpers, outbox + webhooks, error format.
> - **Verify against current official documentation before building**, and record findings in `docs/DECISIONS.md`: Apple App Store Review Guidelines and App Tracking Transparency rules on fingerprinting; Apple DeviceCheck / App Attest; Google Play Integrity API; Google Ads API conversion uploads (gclid/gbraid/wbraid, consent fields); Google's on-device conversion measurement for iOS; GA4 Measurement Protocol; Firebase Analytics SDK; Paystack and Flutterwave APIs, webhooks and key types; Shopify app distribution, OAuth scopes, Web Pixels; WooCommerce hooks; Google Web Risk API licensing. Where this file and the documentation disagree, follow the documentation and note it.
> - **Do not guess non-public partner APIs.** Where a feature depends on documentation Clikgate doesn't have yet (Google App Attribution Partner server-to-server spec, Bumpa, Selar), build the adapter interface, configuration and UI behind a flag, and leave the platform-specific client as a documented stub.
> - Never log secrets, API keys, tokens or raw personal data. Run the full test suite after each milestone.

---

## A. Overview (read first)

### A.1 What this change does
1. **Link domain split.** Free-plan links use **`clk.ng`**. Paid plans and staff-verified organisations use **`clik.gt`**. Stronger abuse controls on `clk.ng` keep scammers from getting `clik.gt` blocklisted.
2. **iOS matching change.** Probabilistic (fingerprint) matching is switched off on iOS, permanently. Identity checks on iOS use Apple DeviceCheck/App Attest and IDFV only. Android probabilistic matching needs owner acknowledgement **and** consent.
3. **Consent and privacy.** A consent API in the SDKs and server API, consent modes by region (EEA/UK/CH on by default), enforcement everywhere data leaves Clikgate, consent logs, data requests and NDPA documents.
4. **Google partner readiness.** `gclid`/`gbraid`/`wbraid` carried end to end (click → deep link → install → conversion → Google upload), consent signals on uploads, iOS on-device measurement pass-through, lookback windows of at least 24 hours, a minimum SDK version policy, and an App Attribution Partner adapter behind a flag.
5. **Firebase / GA4 forwarding.** Clikgate attribution and conversions go to the customer's Firebase or GA4, client-side through the SDK (preferred, no secret) or server-side through the GA4 Measurement Protocol.
6. **Payment-based sales tracking.** Sales from Paystack, Flutterwave, Shopify and WooCommerce become purchase conversions with revenue, matched to the click, link, code or referral that brought the customer. A generic sales webhook covers others; Bumpa and Selar are prepared for partnership.
7. **Agency accounts.** Agencies manage many client organisations from one login, with client-approved access, cross-client reporting, optional consolidated billing and agency discounts.
8. **Switching and leaving.** Migration tools and guides for switching from AppsFlyer (and Branch/Adjust): link import, keeping old branded links working, history import and side-by-side comparison. Also "Leaving Clikgate": full export, an SDK removal guide and goodbye redirects.
9. **Status page and uptime monitoring** at `status.clikgate.com`, running outside Clikgate's main infrastructure, with live status in the dashboard.
10. **The Clikgate website**, positioned as **measurement and growth infrastructure**. The URL shortener has its own product page, not the home page. It's designed to be better than Airbridge's website, including its footer.

### A.2 Plan changes (seed as a new plan version for every plan, created by `system`, `apply_to: "all_now"`; prices unchanged)

| Feature key / allowance | Free | Starter | Growth | Pro | Enterprise |
|---|---|---|---|---|---|
| Link domain | `clk.ng` | `clik.gt` | `clik.gt` + own domains (2) | `clik.gt` + own domains (10) | all |
| `consent_tools` (consent API, modes, logs, data requests) | ✓ | ✓ | ✓ | ✓ | ✓ |
| `sales_tracking` | — | ✓ | ✓ | ✓ | ✓ |
| allowance `sales_connections` | 0 | 1 | 3 | unlimited | unlimited |
| `ga4_forwarding` (SDK-side and server-side) | — | — | ✓ | ✓ | ✓ |
| `google_partner_features` (gbraid/wbraid upload, iOS on-device measurement pass-through) | — | — | ✓ | ✓ | ✓ |
| `migration_tools`: link import | ✓ | ✓ | ✓ | ✓ | ✓ |
| `migration_tools`: history import and comparison report | — | — | ✓ | ✓ | ✓ |
| `data_export_full` (leaving Clikgate export) | ✓ | ✓ | ✓ | ✓ | ✓ |
| `agency_white_label` (agency logo on client reports and summaries) | — | — | — | ✓ (agency's own plan) | ✓ |
| Status page | public | public | public | public | public + status emails to named contacts |

**Agency programme** (not a plan; stored in `billing_settings.agency_programme`, editable by super admins 🔐🔑):
- Creating an agency workspace is free. Each client organisation keeps its own plan.
- Agency discount on client subscriptions, applied by staff when recording payments: 10% at 3+ paying clients, 15% at 10+, 20% at 25+.
- While the agency manages **3+ paying clients**, the agency's own organisation gets Growth features at no cost (a staff-applied Enterprise-style `custom_limits` subscription, renewed monthly by the lifecycle worker while the condition holds).
- Optional referral fee for clients an agency brings in: default 10% of the client's first-year payments, tracked as `agency_commissions` for staff to pay manually.

---

## B. Backend (`clikgate`)

### B.1 Link domain split (`clk.ng` / `clik.gt`)

**Configuration**
- Replace `DEFAULT_LINK_DOMAIN` with `FREE_LINK_DOMAIN=clk.ng` and `PAID_LINK_DOMAIN=clik.gt`. Both are **platform short domains** in the Part 3 domain model (role `short`, owner `platform`), with TLS, AASA/assetlinks and root/not-found pages.
- `clk.ng` root → `https://clikgate.com/products/short-links`. `clik.gt` root → `https://clikgate.com`. `clk.ng/report` → the abuse report page on the website (W.6).

**Eligibility**
- `clik.gt` requires an `active` or `grace` paid subscription **or** `organizations.verified_at` set by staff.
- **Organisation verification** (for free organisations that need `clik.gt`, e.g. NGOs and schools, and as a trust signal for everyone): `POST /v1/organization/verification` with legal name, CAC registration number (or other country registry), website, business email domain, contact phone, optional documents (object storage, max 3 files, 5 MB each). Staff review in the console (🔐 approve or reject with reason). The organisation gets a `verified` badge shown in the dashboard and on link preview pages.
- Link creation picks the default domain automatically: own default domain → `clik.gt` if eligible → `clk.ng`. Requests for an ineligible domain return `403 plan_limit_reached` with `param: "domain"`.

**Existing links and plan changes (links never break)**
- Migration: links on `clik.gt` owned by free, unverified organisations keep working. They are flagged `legacy_free_on_paid_domain: true`, their destinations are re-scanned, and new links for those organisations go to `clk.ng`.
- Downgrade or expiry: existing `clik.gt` links keep redirecting. New links go to `clk.ng`. Destination edits on `clik.gt` links are allowed but always pass blocking destination scanning and are rate-limited to 20 a day; an abuse flag on the organisation freezes edits.
- Upgrade: new links use `clik.gt`. `POST /v1/links/move-domain` (bulk, paid only) creates `clik.gt` copies of selected `clk.ng` links with the same slugs where free. The old `clk.ng` links keep redirecting.

**Abuse controls (stricter on `clk.ng`, applied to `clik.gt` as well)**
| Control | `clk.ng` (free) | `clik.gt` (paid/verified) |
|---|---|---|
| Account checks before first link | Verified email **and** phone (OTP) | Paid or staff-verified organisation |
| New-account limits | First 7 days: 10 links/day, 200 clicks/hour per link before review | Plan limits only |
| Destination scanning | **Blocking**: suspicious destinations are refused, not warned | Warning plus staff alert; malicious refused |
| Reputation lookups | Google Web Risk (or Safe Browsing where licensing allows; record the choice) plus Clikgate blocklists on create, on edit, and re-checked daily for active links | Same, re-checked weekly |
| Disallowed destinations | Other URL shorteners (redirect chains), raw IPs, lookalike domains of banks, fintechs and government (a curated list), data/js URLs | Raw IPs, data/js URLs |
| Community reports | 3 distinct reports in 24 h → link paused pending review | 5 reports → staff alert (no auto-pause) |
| Link preview | Appending `+` to any link (`clk.ng/abc+`) shows a safe preview page: destination, organisation name, verified badge, report button | Same |
| Signup throttling | Per IP/ASN and device limits; repeat-abuser detection by verified phone, email domain and device | — |

- **Abuse reports:** public `POST /v1/public/abuse-reports` `{link_url, reason (phishing|scam|malware|spam|impersonation|illegal|other), details, reporter_email?}` (captcha, rate-limited), and `abuse@clikgate.com` parsed into the same queue.
- **Staff abuse queue** (support+): report list with link, destination snapshot, scan results, organisation history. Actions: dismiss, pause link, disable link 🔐, suspend organisation 🔐, ban destination domain 🔐. The target response time of 2 hours is shown on the queue.
- **Domain reputation monitor** (worker, every 6 h): checks `clk.ng`, `clik.gt` and every customer branded domain against Google Web Risk/Safe Browsing status and major blocklists where an API exists. Records results in `domain_reputation_checks`. Raises a **critical system alert** to super admins and the status page component "Link domains" if `clk.ng` or `clik.gt` is listed.
- Data model additions: `organizations.verified_at`, `organizations.verification` (jsonb), `organization_verifications` (submissions), `abuse_reports`, `link_moderation_actions`, `domain_reputation_checks`, `destination_blocklist` (domain, reason, added_by), `lookalike_watchlist`.

### B.2 iOS matching change
- In the attribution matcher, **probabilistic matching never runs for `platform = ios`**, regardless of organisation or app settings. Remove iOS from the probabilistic code path and add a test that fails if it is reintroduced.
- Migration: set `probabilistic_matching` app overrides to `android_only`. The feature setting becomes `{android: bool}`. The API rejects any iOS setting with `422 not_supported_on_ios`.
- **iOS deterministic methods only:** universal-link/deep-link click IDs, Apple Search Ads (AdServices token), SKAdNetwork/AdAttributionKit postbacks, IDFA match only when the user granted ATT **and** the click carried an IDFA (in-app ad networks), and logged-in user identity the customer provides (e.g. referral sign-up).
- **Optional iOS clipboard-based deferred deep link:** off by default, per app. Uses a Clikgate-generated token copied on the link's landing page only after the user taps "Open in app", and read by the SDK with the system paste permission prompt. Document the user-facing prompt clearly.
- **Android probabilistic matching** requires: owner acknowledgement (existing), consent state allowing attribution (B.3), and a match window of at most 24 hours. Matched installs are labelled `match_type: probabilistic` everywhere and are excluded from Google/Meta conversion uploads unless the platform accepts modelled data.
- **Identity checks on iOS** use Apple DeviceCheck (per-device bits) and App Attest (app integrity) plus IDFV only; no hardware or OS fingerprint signals. **Identity checks on Android** use the Play Integrity API verdicts plus app-scoped identifiers (no persistent hardware IDs). Update the identity-signal docs and NDPA notes.

### B.3 Consent and privacy

**Consent model**
- Purposes: `analytics` (measure usage), `attribution` (link installs and conversions to sources), `ad_user_data` (send user data to ad platforms), `ad_personalization` (allow ad platforms to use it for personalised ads). States: `granted | denied | unknown`.
- Organisation setting `consent_mode`: `not_required` (default for organisations whose apps and links only target countries without a consent requirement), `required_in_regions` (default regions: EEA, UK, Switzerland; editable list) or `required_everywhere`. Per-app override.
- Behaviour when consent is **required** and:
  - `unknown`: the SDK **buffers** events locally (up to 7 days or 1,000 events) and sends nothing identifying. On grant, it sends the buffer. On deny or expiry, it drops it.
  - `attribution: denied`: the SDK sends only an anonymous, identifier-free install ping (count only) if the organisation enabled "anonymous counts", otherwise nothing.
  - `ad_user_data: denied`: the event is never sent to ad platforms (conversion sending skipped with `skipped_consent`). `ad_personalization` is passed through to platforms that accept it.
- Server-side conversions (`POST /v1/conversions`, sales tracking) accept an optional `consent` object with the same fields. Missing consent in a required region → treated as `unknown` → stored but not forwarded to ad platforms or GA4.
- **Enforcement points:** SDK sending, attribution matching (probabilistic requires `attribution: granted`), conversion sending (change 02), GA4 forwarding (B.5), Google uploads (B.4), identity checks (they require `analytics: granted`, or the organisation's stated legal basis "fraud prevention"; record the basis), summaries and exports (aggregates only for denied users).
- **Consent log:** `consent_records` (organization_id, environment, subject_type `device|user`, subject_id hash, purposes jsonb, source `sdk|api|web`, region, recorded_at, sdk_version). Append-only, retained for 3 years.
- **Region detection:** from the customer-provided region, otherwise the IP-derived country at the edge (country only; IP not stored).

**Data requests (data subjects)**
- `POST /v1/privacy/requests` `{type: access|delete, subject: {user_id? | email? | phone? | device_id?}}` (org API key, `privacy:write` scope) → job that finds the subject's records (hashed lookups), produces an export (access) or deletes/anonymises (delete) across clicks, installs, conversions, referrals, identity signals, consent, queued conversion sends, sales matches and GA4 queues, within 30 days (target 72 h). Webhook `privacy.request_completed`.
- Dashboard page lists requests and their status.

**Documents and records** (Markdown served on the website's trust centre, W.5): Data Processing Agreement (NDPA 2023 and GDPR clauses), sub-processor list (kept in `docs/subprocessors.yml`, rendered on the website, with change notifications to organisations that subscribe), record of processing activities, retention schedule, security overview. A lawyer must review the legal text before publishing; the build creates templates and clearly marks them "Draft — legal review required" until staff mark them approved.

### B.4 Google partner readiness
- **Click IDs end to end:**
  - Click ingestion stores `gclid`, `gbraid`, `wbraid` (change 02).
  - Deep links and deferred deep links: the redirect appends the click ID to the app link when the organisation enables "pass Google click IDs" (default on for apps with `google_partner_features`). The SDK reads them from universal/app links and from the Android install referrer, and sends them on install.
  - The attribution record keeps the ID type and value.
- **Google Ads conversion uploads** (extends change 02 sending): exactly one of `gclid | gbraid | wbraid` per conversion (prefer `gclid`, then `gbraid` (app), then `wbraid` (web-to-app)); conversion time with the organisation's timezone offset; `order_id` for deduplication; value and currency; a **consent block** with `ad_user_data` and `ad_personalization` from B.3; enhanced-conversion hashed identifiers only when `send_hashed_identifiers` is on and `ad_user_data` is granted. Partial failures are recorded per row.
- **Lookback windows:** per app, click-through attribution window 1–30 days (default 7), never below 24 hours. Validation rejects lower values.
- **iOS on-device measurement pass-through:** if the customer's iOS app includes Google's on-device conversion measurement SDK, the Clikgate iOS SDK (behind `Clikgate.enableGoogleOnDeviceMeasurement()`) obtains the on-device measurement info string as documented by Google and sends it with the install/first-open event. The backend stores it (encrypted, 30-day retention) and includes it in Google server-to-server calls where the API accepts it. The customer supplies first-party data to Google's SDK themselves; Clikgate never sends raw email or phone. **Verify the current SDK API and field names before building.**
- **Minimum SDK version policy:** `sdk_versions` table (platform, version, status `current|supported|deprecated|blocked`, released_at, notes). `GET /v1/sdk/config` returns `min_supported_version` and `latest_version`. SDKs below `supported` get a deprecation warning in logs. Blocked versions get config telling them to send only safe basic events. Dashboard **SDK health** (F.6) shows versions in use per app. Policy: each version is supported for at least 12 months; deprecation is announced 90 days before.
- **App Attribution Partner adapter (flagged):** `app/integrations/google_aap/` with interface `send_app_conversion(app, event, attribution)`, configuration (Google-provided link IDs per app), feature flag `google_aap_mode` (staff console, off). Implementation is a stub with a clear `NotConfigured` error until Google shares the partner specification. Do not guess endpoints.
- `docs/GOOGLE_PARTNER_READINESS.md`: a checklist mapping Google's published requirements (deep links with click IDs, conversion integration, windows ≥ 24 h, EEA consent, minimum SDK versions, iOS on-device measurement) to the Clikgate features and tests that prove them.

### B.5 Firebase / GA4 forwarding
- **Client-side (preferred for apps, no secret stored):** the SDKs gain `Clikgate.enableFirebaseForwarding(options)`. When Firebase Analytics is present in the app, the SDK:
  - logs `clikgate_attribution` once per install with params `cg_source`, `cg_medium`, `cg_campaign`, `cg_channel` (ads|whatsapp|referral|offline_code|link|organic), `cg_link_id`, `cg_match_type`;
  - sets user properties `cg_first_source`, `cg_first_campaign`;
  - optionally mirrors mapped Clikgate events.
  It respects consent (`analytics` granted). No server involvement except the config flag in `/v1/sdk/config`.
- **Server-side (web streams, server conversions, sales tracking):** `analytics_destinations` (id `gad_`, organization_id, environment, platform `ga4`, stream_type `web|app`, `measurement_id` (web) or `firebase_app_id` (app), `api_secret_encrypted`, event_mappings, include_attribution_params, status). The Measurement Protocol API secret is a **write-only key for that one data stream**, created and revocable by the customer in GA4. It is encrypted, never returned, and the only credential this feature stores; the UI says so.
  - Identifiers: web events need the GA `client_id`. The Clikgate web script reads the `_ga` cookie when present (with consent) and attaches it to conversions. App events need `app_instance_id`; the SDK reads it from Firebase (with consent) and sends it on install and when it changes. Events without the needed identifier are skipped with `skipped_no_ga_id`.
  - Worker `ga4_forward`: on `install.attributed`, `conversion.attributed`, `sale.matched`, `referral.qualified` (as mapped), send Measurement Protocol events with attribution params and `consent` fields. Retries with backoff; send log; a validation-endpoint test button.
- API: CRUD `/v1/analytics-destinations`, `POST /v1/analytics-destinations/{id}/test`, `GET /v1/analytics-destinations/{id}/log`.

### B.6 Payment-based sales tracking

**Model**
- `sales_connections` (id `slc_`, organization_id, environment, provider `paystack|flutterwave|shopify|woocommerce|custom_webhook|bumpa|selar`, mode `forward|connect|app|plugin|webhook`, display_name, credentials_encrypted (nullable), webhook_secret_hash (nullable), external_account_id, currency, status `active|needs_attention|disconnected`, last_event_at, last_poll_at, created_by). Count limited by `sales_connections`.
- `sales` (id `sal_`, organization_id, environment, connection_id, provider_order_id (unique per connection), provider_status, amount_minor, currency, amount_reporting_minor, refunded_minor, occurred_at, customer_email_hash, customer_phone_hash (both HMAC with the organisation pepper), items_count, match_method `click_id|identity|none`, match_confidence `exact|identity|none`, click_id, conversion_id, attributed_channel, raw_ref (pointer, not the payload), created_at).
- `sales_events_inbox` (raw provider events, encrypted, 14-day retention, for replay and debugging).

**Providers** (check each provider's current documentation first; record key types and webhook limits in DECISIONS)
| Provider | Modes | How sales arrive | Credential stored |
|---|---|---|---|
| Paystack | **Forward** (default): the customer's server forwards Paystack webhook events to `POST /v1/sales/ingest/paystack` using a Clikgate API key, so their existing webhook stays theirs. **Connect**: paste the Paystack secret key; Clikgate polls transactions and refunds every 10 minutes and never takes the webhook slot | `charge.success`, refunds | Forward: none. Connect: secret key, encrypted with `SALES_KEY_ENCRYPTION_KEY` and used only for read endpoints (code review enforces that) |
| Flutterwave | Forward or Connect, same as Paystack | successful charges, refunds | Same |
| Shopify | **App**: Clikgate Shopify app via OAuth (`read_orders`, plus a Web Pixel extension). Start as a custom or unlisted app for pilots; public listing after Shopify review | `orders/paid`, `refunds/create` webhooks (HMAC verified); the pixel stores `cg_click_id` as a cart attribute | Shopify access token (encrypted) |
| WooCommerce | **Plugin**: `integrations/woocommerce/clikgate-for-woocommerce` (WordPress plugin, PHP 8.1+). Saves the `cg_click_id` cookie into order meta and sends paid and refunded orders signed with the organisation's ingest secret | Plugin webhook to `/v1/sales/ingest/woocommerce/{connection_id}` | Webhook secret hash only |
| Any other system | **Webhook**: generic signed JSON `POST /v1/sales/ingest/custom/{connection_id}` (documented schema) | Customer sends | Secret hash only |
| Bumpa, Selar | Listed as "Coming soon — talk to us". Adapter interface, flagged; no guessed APIs | — | — |

**Matching** (deterministic only; no probabilistic sales matching)
1. **Click ID** (`exact`): the sale carries `cg_click_id`. Ways to get it there:
   - Paystack and Flutterwave: the Clikgate web script exposes `Clikgate.paymentMetadata()`, which returns `{cg_click_id, cg_link_id}` for the customer to add to Paystack `metadata` or Flutterwave `meta` at checkout.
   - Mobile apps: the SDK exposes `Clikgate.attributionMetadata()` for the same purpose.
   - Shopify: the pixel cart attribute.
   - WooCommerce: order meta.
2. **Identity** (`identity`): the hashed email or phone on the sale matches an identity the organisation previously linked to an attributed user (e.g. sign-up conversion with `user_id` + email, or a referral). Uses the latest attribution for that user within the organisation's sales window (default 30 days, max 90).
3. Otherwise `none`: the sale is counted as unattributed revenue and shown in the match-rate report.

- A matched sale creates (or updates) a `purchase` conversion with value. That conversion flows into attribution reports, ROAS (change 02), referral qualification rules (e.g. "first purchase ≥ ₦5,000"), conversion sending, GA4 forwarding and summaries. Webhook `sale.matched`.
- **Refunds** reduce `refunded_minor`, emit `sale.refunded`, and adjust revenue in reports. They send conversion adjustments to Google where supported; for other platforms they are logged only.
- **Idempotency** per (connection, provider_order_id). Test-mode connections only accept provider test keys or test events.
- **Personal data:** only hashed email and phone are stored, plus order ID, amounts, currency, time and item count. No names, addresses or card data. Raw inbox events are encrypted and deleted after 14 days.
- **API:** CRUD `/v1/sales-connections`, `POST /v1/sales-connections/{id}/test`, `GET /v1/sales` (filters), `GET /v1/analytics/sales` (revenue, match rate, by channel/campaign/link/referrer), ingest endpoints above. Add `sales` to the datasets registry.

### B.7 Agency accounts
**Model**
- `agencies` (id `agy_`, name, slug, owner_user_id, website, verified_at, logo_key, white_label_enabled, discount_tier (computed), created_at).
- `agency_members` (agency_id, user_id, role `agency_owner|agency_admin|agency_manager|agency_analyst`).
- `agency_clients` (agency_id, organization_id, status `invited|active|removed`, access_level `full|manage_campaigns|read_only`, billing_mode `client_pays|agency_pays`, invited_by, approved_by_org_owner_at, removed_at, referred_by_agency (bool)).
- `agency_commissions` (agency_id, organization_id, payment_id, amount_minor, currency, status `pending|paid|void`).

**Rules**
- Access always needs the **client owner's approval**. The agency invites the organisation, or the organisation invites the agency; the other side accepts. Owners can remove an agency at any time, which takes effect immediately.
- Agency users act in client organisations through an `agency` membership that maps access levels to existing org roles: `full` → admin minus billing and owner actions, `manage_campaigns` → developer-like without API keys and settings, `read_only` → viewer. Audit entries record `actor_type: agency_user` with the agency ID.
- The agency can create a client organisation for a business. The business owner is invited and becomes the owner on acceptance; until then the agency is a temporary owner-proxy that cannot change billing.
- Agencies cannot see clients' API keys, SDK keys, identity peppers or sales/ad credentials.
- **Cross-client API:**
  - `GET /v1/agency/overview`: per client — plan, status, period end, clicks, installs, conversions, revenue, spend, ROAS, fraud rate, usage %, alerts.
  - `GET /v1/agency/reports`: same datasets aggregated or per client.
  - Agency-wide scheduled exports and summaries (agency `export_schedules` count against the agency owner organisation's plan).
- **White label (Pro on the agency's own organisation):** the agency logo and name on client exports, summaries and shared report links, with "Powered by Clikgate" in small print.
- **Billing:**
  - `billing_mode: agency_pays` groups the agency's client subscriptions for staff. The change 01 staff console gains "Record agency payment", which splits one payment across selected client subscriptions (🔐) and shows the discount tier.
  - The agency's own Growth benefit and commissions are computed by a monthly worker. Staff approve commission payouts (🔐, recorded only).
- Customer-facing upgrade requests can be raised by the agency for a client, but always need the client owner's confirmation, or the agency pays in `agency_pays` mode.

### B.8 Switching from AppsFlyer (and other tools)
- **Link import:** `POST /v1/migration/link-imports` (CSV) with columns `old_url, destination_url, ios_url?, android_url?, deep_link_value?, campaign?, media_source?, channel?, slug?`. Presets for AppsFlyer OneLink exports, Branch and Adjust (header detection). Preview → commit creates Clikgate links with mapped parameters (`media_source` → `utm_source`, `campaign` → `utm_campaign`, `deep_link_value` → deep link data).
- **Keep old branded links working:** if the old tool used the customer's **own** branded domain (e.g. `go.brand.com`), the import offers to connect that domain to Clikgate (Part 3 connected domains) with **the same slugs**, so old links keep working after the DNS switch. The checklist shows DNS steps and a "test before switching" tool that resolves sample old URLs against Clikgate. Links on the old vendor's own domains can't be moved; the guide says so.
- **History import:** `POST /v1/migration/history-imports` (CSV of daily aggregates: `date, platform, media_source, campaign, installs, events?, event_name?, revenue?, currency?, cost?`) into `imported_history_daily` (source `appsflyer|branch|adjust|other`). Reports show imported history as a separate, clearly labelled series before the organisation's `measurement_start_date`; it's never mixed into Clikgate attribution.
- **Side-by-side comparison** (pilot): upload the old tool's daily aggregates for the overlap period → `GET /v1/migration/comparison` shows installs and conversions per channel from both tools, the difference %, and common reasons per row (attribution window, view-through, probabilistic vs deterministic, time zone).
- **Postback checklist:** `GET /v1/migration/postback-checklist` lists the networks found in the imported history with Clikgate's postback template status per network.
- **Migration status** for the dashboard wizard: `GET/PATCH /v1/migration/status` (steps done).

### B.9 Leaving Clikgate
- `POST /v1/organization/export-all` → job builds a zip of all datasets (links, clicks summary, installs, conversions, sales, referrals, spend, fraud flags, settings JSON, audit log) and emails owners a download link valid 7 days. Allowed on every plan; rate-limited to once a day.
- **Goodbye redirects:** on cancellation or deletion, paid organisations' `clik.gt` links keep redirecting to their current destinations **without tracking** for 90 days (then show the not-found page). Branded domains: the organisation repoints DNS. Free `clk.ng` links stop when the organisation is deleted.
- **Organisation deletion:** `POST /v1/organization/delete` (owner, password + email confirmation) → 30-day grace (restorable) → permanent deletion job across all tables and object storage, keeping only billing records required by law. Webhook `organization.deleted`.
- The SDK removal guide lives on the website (W.4) and is linked from the dashboard (F.5). Each SDK's README gains a "Removing the SDK" section (S.1).

### B.10 Status monitoring (backend side)
- Deep health endpoints (no secrets, cached 10 s): `GET /health/redirect` (redirects a canary link on each platform domain internally), `GET /health/api`, `GET /health/sdk`, `GET /health/workers` (queue lag per queue), `GET /health/webhooks` (delivery lag p95). Protected by a shared token `STATUS_PROBE_TOKEN`; summaries only.
- **Heartbeat push:** every minute the backend pushes a signed summary (component → ok/degraded/down, key metrics) to the status app's ingest endpoint (W.7). A missing heartbeat for 3 minutes marks components "degraded" automatically.
- Canary links: `clk.ng/_canary` and `clik.gt/_canary` (excluded from analytics and billing).
- Staff console: "Incidents" shortcut that opens the status app's admin (W.7). The backend doesn't store incidents (they must survive a backend outage).

### B.11 Staff console additions
- Organisation verification queue (approve/reject 🔐), abuse queue (B.1), domain reputation panel, agency management (verify agency 🔐, discount tier override 🔐🔑, record agency payment 🔐, commission payouts 🔐), sales connection health across organisations, Google readiness flags (`google_aap_mode` 🔐), SDK versions table editing (status changes 🔐), link to status admin.

### B.12 Security
New secrets: `SALES_KEY_ENCRYPTION_KEY`, `GA4_SECRET_ENCRYPTION_KEY` (or reuse a KMS key-per-purpose scheme), `WEB_RISK_API_KEY`, `STATUS_PROBE_TOKEN`, `STATUS_INGEST_SIGNING_KEY`, `SHOPIFY_API_KEY`/`SHOPIFY_API_SECRET`, `CAPTCHA_SECRET`. All credential columns encrypted; credentials are never returned and never logged; every credential create, rotate and delete is audit-logged.

### B.13 Tests
- **Domain split:** domain choice per plan and verification; ineligible domain refused; migration flags; downgrade keeps redirects and rate-limits edits; upgrade move; abuse controls (blocking scan, disallowed destinations, report auto-pause thresholds, `+` preview); reputation monitor alerting; canary links excluded from billing.
- **iOS matching:** probabilistic never runs on iOS (guard test); iOS settings rejected; Android requires acknowledgement + consent + ≤ 24 h; probabilistic installs excluded from uploads.
- **Consent:** each mode and region; buffering semantics through the SDK contract; enforcement at every listed point (`skipped_consent`); consent log append-only; data requests access and delete across all stores, including queues.
- **Google:** click ID precedence and propagation through deep links and install referrer; upload payload snapshots with consent block; windows ≥ 24 h validation; on-device measurement field pass-through and retention; SDK version policy responses; AAP stub raises `NotConfigured`.
- **GA4:** SDK-side forwarding config; server-side payload snapshots; missing-ID skips; consent; test endpoint.
- **Sales:** each provider's fixtures (Paystack and Flutterwave forward and connect polling, Shopify webhook HMAC and pixel attribute, WooCommerce signed payload, custom webhook); click-ID and identity matching; no probabilistic; refunds; idempotency; hashing; referral qualification by purchase; downstream sending; the `sales_connections` limit.
- **Agencies:** two-sided approval, access levels mapped to permissions, no secret visibility, removal immediate, cross-client overview, white label gated by plan, agency payment split, Growth benefit worker, commissions.
- **Migration and leaving:** CSV presets, same-slug branded domain takeover test tool, history kept separate in reports, comparison maths, export-all contents, goodbye redirects without tracking, deletion grace and purge.
- **Status:** health endpoints, heartbeat signing, missing heartbeat → degraded.

### B.14 Backend milestones
1. **C3-B1** Plan version migration (A.2), domain split, organisation verification, abuse controls, reputation monitor, staff verification and abuse queues.
2. **C3-B2** iOS matching change, Android probabilistic conditions, identity checks on DeviceCheck/App Attest and Play Integrity (backend verification side).
3. **C3-B3** Consent model, modes, enforcement points, consent log, data requests, legal document templates.
4. **C3-B4** Google readiness: click IDs end to end, upload changes with consent, windows, on-device measurement pass-through, SDK version policy, AAP adapter stub, readiness doc. GA4 server-side forwarding.
5. **C3-B5** Sales tracking: model, Paystack and Flutterwave (forward + connect), custom webhook, matching, refunds, downstream flows, sales analytics. Then Shopify app and WooCommerce plugin.
6. **C3-B6** Agency accounts, cross-client API, white label, agency billing in staff console, commissions.
7. **C3-B7** Migration tools, leaving Clikgate (export-all, goodbye redirects, deletion), health endpoints and heartbeat, staff console additions, docs (`docs/DOMAINS_AND_ABUSE.md`, `docs/CONSENT.md`, `docs/SALES_TRACKING.md`, `docs/AGENCIES.md`, `docs/MIGRATION.md`); regenerate `openapi.json`.

---

## S. SDK changes (`clikgate/sdks/`)

### S.1 All SDKs (Android, iOS, Flutter, React Native, web script)
- `setConsent({analytics, attribution, adUserData, adPersonalization})`, `getConsent()`, region hint `setConsentRegion("EEA")`. Buffering behaviour per B.3. Consent included on every request.
- Read and report `gclid`/`gbraid`/`wbraid` from deep links and (Android) the install referrer.
- `enableFirebaseForwarding(options)` (B.5): detects Firebase at runtime without a hard dependency (reflection/weak linking; Flutter and React Native call through to the native SDKs), and reports `app_instance_id` when consent allows.
- `attributionMetadata()` (apps) and `paymentMetadata()` (web script) for sales matching (B.6).
- Respect `min_supported_version` and blocked-version instructions from config.
- README section "Removing the SDK": delete dependency, remove init and calls, remove manifest/plist entries (associated domains, intent filters), remove push token forwarding (uninstall tracking), and tell the Clikgate dashboard the app is no longer tracked.

### S.2 Platform specifics
- **iOS:** remove every signal used only for probabilistic matching or fingerprinting. Identity checks use DeviceCheck and App Attest; IDFV only. Optional clipboard deferred deep link (B.2), off by default. `enableGoogleOnDeviceMeasurement()` pass-through (B.4); no new required dependency.
- **Android:** identity checks use the Play Integrity API (the customer supplies their Cloud project number in config). Probabilistic matching signals are collected only when the server config allows it (acknowledgement + consent).
- **Web script:** read `_ga` client ID with consent; `paymentMetadata()`; consent API; small size budget (≤ 6 KB gzipped).
- Version bumps: minor for all; changelogs list the iOS privacy changes clearly.

### S.3 SDK milestones
1. **C3-S1** Consent API, click IDs, version policy handling, iOS fingerprint removal + DeviceCheck/App Attest, Android Play Integrity, removal guides.
2. **C3-S2** Firebase forwarding, payment/attribution metadata helpers, Google on-device measurement pass-through, clipboard deferred deep link (iOS, opt-in), sample apps updated.

---

## F. Frontend (`clikgate-dashboard`)

### F.1 Links and domains
- The link create/edit domain picker shows only eligible domains. Free organisations see `clk.ng` with an inline note: "Paid plans and verified organisations use clik.gt. Upgrade or get verified." with buttons.
- Link list: a domain column, a `legacy` badge for flagged links, and a bulk action "Move to clik.gt" (paid).
- **Settings → Organisation → Verification:** form (legal name, CAC number, website, email domain, phone, documents) → status (Pending, Verified badge, Rejected with reason, resubmit).
- Paused-link states with reason and "Request review".

### F.2 Privacy & consent (`/[org]/settings/privacy`)
- Consent mode selector with region chips (EEA, UK, Switzerland and custom), per-app overrides, "anonymous counts" switch, legal basis for identity checks.
- SDK snippet tabs showing `setConsent` usage for each platform.
- Data requests table (type, subject type, status, completed at, export download).
- Links to the DPA, sub-processor list and retention schedule on the trust centre, plus "Subscribe to sub-processor changes".
- App settings: probabilistic matching shows **"Android only"** with an explanation ("Apple doesn't allow device fingerprinting on iOS; Clikgate uses deterministic methods on iOS") and needs acknowledgement + consent mode.

### F.3 Integrations hub (new top-level nav item **Integrations**)
Cards grouped as **Sales** (Paystack, Flutterwave, Shopify, WooCommerce, Custom webhook, Bumpa *coming soon*, Selar *coming soon*), **Analytics** (Firebase/GA4), **Ads** (Meta, Google Ads, TikTok — from change 02), **Exports** (Google Sheets, email — from change 02). Each card shows status and opens a setup flow; plan badges where gated.
- **Paystack/Flutterwave setup:** choose mode.
  - **Forward:** shows the ingest URL, a code snippet for the customer's webhook handler and a test button.
  - **Connect:** a masked key field with the note "Stored encrypted; used only to read transactions".
  - Both show a checkout snippet using `paymentMetadata()` / `attributionMetadata()`.
- **Shopify:** "Install Clikgate app" → OAuth → done. **WooCommerce:** download the plugin, then a copy field for the connection secret.
- **Custom webhook:** schema docs, secret reveal-once, test sender.
- **Sales overview** (`/[org]/sales`): revenue (attributed vs unattributed), match rate with method breakdown (exact / identity), revenue by channel, campaign, link and referrer, a refunds line, and a recent sales table. It also adds revenue tiles to the main Overview when sales exist.
- **Firebase/GA4:** two tabs. **In-app (recommended)**: SDK snippet. **Server-side**: measurement ID or Firebase app ID + API secret (with the note "write-only key for this stream; revoke anytime in GA4"), event mapping, test, send log.

### F.4 Agency experience
- **Workspace switcher** grouped "Your organisations" and "Clients of {Agency}". Agency users land on **Agency home**:
  - a client table (plan, renewal, clicks, installs, revenue, spend, ROAS, fraud %, usage %, alerts) with sorting and filters;
  - "Add client" (invite an existing organisation by owner email, or create a new organisation for a business);
  - an access level and billing mode per client.
- **Agency settings:** profile, logo (white label, Pro), members and roles, discount tier and progress ("2 more paying clients to reach 15%"), commissions list (read-only), "Your agency organisation gets Growth free" status.
- **Client side:** **Settings → Agencies** to approve, change access level, or remove an agency (confirm). The agency's banner shows inside client organisations: "You're viewing {Client} as {Agency} (Read only)".
- Agency-wide scheduled exports and summaries.

### F.5 Help, migration and leaving
- **Help & resources menu** (a "?" icon in the top bar, also in the command palette):
  - Docs
  - Guides
  - **Switching from AppsFlyer**
  - **Removing the Clikgate SDK**
  - **System status** (live dot)
  - Changelog
  - Contact support (WhatsApp and email)
- **Developers → Migration** (`/[org]/developers/migration`), a wizard with steps and saved progress:
  1. Choose the tool you're coming from.
  2. Import links (CSV, presets, preview).
  3. Keep branded links (connect domain, test sample URLs, DNS steps).
  4. Install the Clikgate SDK (per-platform tabs, linking to docs).
  5. Run side by side (upload old-tool aggregates → comparison report).
  6. Postbacks checklist.
  7. Import history.
  8. Switch over (set the measurement start date).

  The onboarding checklist adds "Switching from another tool?", which opens this wizard.
- **Settings → Data & privacy → Leaving Clikgate:**
  - "Export all data" (job status and download);
  - a link to the SDK removal guide;
  - an explanation of goodbye redirects;
  - "Delete organisation" (owner, typed confirmation, 30-day grace with restore).
- **Developers → SDK health:** apps with SDK versions seen in the last 30 days, share of traffic per version, status chips (Current / Supported / Deprecated / Blocked) and upgrade guides.

### F.6 Status in the app
- The app shell fetches `https://status.clikgate.com/api/summary.json` every 60 s (with cache, failure-tolerant).
- **Active incident or maintenance:** a slim banner with the title and a link to the status page.
- **Sidebar footer:** a status dot with tooltip.
- **Login page:** a small status line.

### F.7 Staff console additions (staff route group)
Verification queue, abuse queue with link preview and actions, domain reputation panel, agencies (verify, tier override, record agency payment split, commissions), sales connection health, SDK versions editor, Google readiness flags, and a link to the status admin. Same TOTP step-up patterns as change 01.

### F.8 Frontend tests and milestones
- **Tests (MSW and Playwright):**
  - domain picker per plan and verification;
  - verification flow;
  - privacy settings and data requests;
  - "Android only" matching UI;
  - each integration setup flow and the sales overview;
  - GA4 setup and test;
  - agency switcher, client approval and removal, read-only enforcement in UI, white label preview;
  - migration wizard happy path;
  - leaving flow (export and deletion grace);
  - status banner states;
  - staff abuse and verification queues.
- **Milestones:**
  1. **C3-F1** Domain split UI, verification, privacy & consent, SDK health, status banner.
  2. **C3-F2** Integrations hub, sales setup flows and sales overview, GA4 setup.
  3. **C3-F3** Agency experience (agency home, clients, approvals, white label, agency exports/summaries).
  4. **C3-F4** Help menu, migration wizard, leaving flow, staff console additions, tests.

---

## W. Website and status page (`clikgate-website`, new repository)

### W.1 Stack and structure
- pnpm monorepo with `apps/www` (Next.js App Router, static generation and ISR, TypeScript strict, Tailwind v4, MDX for content, Motion for animation, `next/og` for social images) and `apps/status` (status page and its admin, deployed to Cloudflare Pages + Workers, see W.7). `packages/ui` holds the shared brand components and tokens.
- Content in `content/` as MDX: blog, guides, docs, glossary, customers, changelog, legal and trust pages. Every page has a typed frontmatter schema (Zod) and fails the build if fields are missing.
- Public data from the backend: `GET /v1/public/plans` and `POST /v1/public/plans/recommend` (change 01) for pricing and the calculator, with a build-time fallback snapshot so the site never breaks if the API is down.
- **Performance budget**, for Nigerian mobile networks:
  - Lighthouse ≥ 95 on mobile for Performance, Accessibility, Best Practices and SEO;
  - LCP < 2.0 s and total JS < 120 KB gzipped on the home page;
  - images in AVIF/WebP with explicit sizes;
  - no autoplay video above the fold;
  - fonts self-hosted and subset.
- SEO: metadata per page, OG images, `sitemap.xml`, `robots.txt`, canonical URLs, schema.org (`Organization`, `SoftwareApplication`, `FAQPage`, `BreadcrumbList`), naira prices in structured data.
- Analytics: privacy-friendly site analytics plus **Clikgate's own links and web script** on every CTA (dogfooding). A cookie banner with consent modes that respects B.3.

### W.2 Positioning and content rules
- **Positioning:** "Measurement and growth infrastructure for African apps and businesses." Never "URL shortener" or "link shortener" on the home page, in the main navigation labels, or in meta titles outside its product page.
- **Honesty rules (enforced in review):**
  - No fake testimonials, logos, metrics, customer counts or awards.
  - Customer and case-study sections render **only** when real content exists in `content/customers/`; otherwise they are hidden, not filled with placeholders.
  - No "official partner" or "certified" claims for Google, Meta, TikTok or Apple until staff set `partner_status` flags in site config. Ad platform logos appear only under "Works with", following each brand's guidelines.
- Voice: confident, plain, specific, with numbers in naira where relevant. British/Nigerian English spelling.

### W.3 Visual design (better than Airbridge)
- **Brand tokens:** primary calm blue `#2E5C9E` (from the dashboard), deep navy `#0A1A33` for dark hero and footer bands, electric accent `#5B8DEF` for glows and highlights, success green `#1F9D6B`, warning amber `#D99A00`, neutrals from the dashboard scale. Light sections on white with soft blue-grey `#F4F7FB` panels.
- **Type:** Inter (UI and body) with **Inter Display** or a tight-tracking heading cut for large headlines; JetBrains Mono for code. Display sizes 56–72 px desktop and 36–44 px mobile, tight leading.
- **Signature visual: the Journey line.** A thin animated path that travels through the page connecting channel icons (Instagram ad, WhatsApp chat, agent code, QR poster, referral) → app install → in-app purchase in naira, with small live-looking counters. Built as SVG with CSS/Motion, paused under `prefers-reduced-motion`.
- **Product mockups:** real dashboard components rendered as static, polished "screens" (no blurry screenshots), with subtle depth: 1 px borders, soft shadows, glass panels only on the navy hero.
- Bento-grid feature sections, numbered use-case blocks (01–04), a light/dark aware design, generous whitespace, and crisp 1.5 px line icons (Lucide or custom).
- Interactions: hover lift on cards, smooth mega menu, sticky header that turns solid on scroll, copy-to-clipboard code blocks, keyboard-accessible everything (WCAG 2.2 AA).

### W.4 Site map and pages
**Header navigation**
- **Product** (mega menu with four columns):
  - **Measure:** Attribution, Ad spend & ROAS, Sales tracking, Reports & exports.
  - **Grow:** Deep linking, Referrals & leaderboards, WhatsApp attribution, Offline & USSD codes, Smart links & QR.
  - **Protect:** Fraud protection, Identity checks, Uninstall tracking.
  - **Connect:** SDKs, API & webhooks, Integrations.
- **Solutions:** Fintech, E-commerce, Logistics & mobility, Edtech, Telecom, Agencies.
- **Pricing**
- **Customers** (hidden until real content exists)
- **Resources:** Blog, Guides, Docs, Switching from AppsFlyer, Glossary, Changelog, System status
- Right side: Log in, **Start free** (primary), Talk to us.

**Home page** (`/`), in order:
1. **Hero (navy):**
   - Eyebrow "Measurement & growth infrastructure".
   - Headline "Know exactly what grows your business."
   - Subhead "Attribution, deep links, referrals, WhatsApp and offline tracking, sales from Paystack and Shopify, and fraud protection — in one platform built for Africa."
   - CTAs **Start free** and **Talk to us**.
   - Microcopy "Free plan · Paid plans from ₦7,500/month · Pay in naira" (the price is read from the plans API).
   - The Journey line animation with a dashboard mockup (KPI tiles: Clicks, Installs, Sales, Revenue, ROAS, Fake installs blocked).
2. **"Works with your stack":** logo strip of Meta, Google Ads, TikTok, Apple Search Ads, WhatsApp, Firebase, Paystack, Flutterwave, Shopify and WooCommerce, with a "See all integrations" link.
3. **"Every channel your growth actually runs on":** a channel grid (Ads, Influencers, WhatsApp, Agents & referrals, Offline & QR, SMS, Organic), each with the one metric Clikgate shows for it.
4. **Use cases 01–04:**
   - 01 Know your real ROAS: spend from Meta, Google and TikTok, or CSV, next to installs and sales.
   - 02 Build referral programs in days: APIs, rules, leaderboards, duplicate-account checks.
   - 03 Measure WhatsApp and offline: chats, agent codes, posters, USSD.
   - 04 See sales, not just clicks: Paystack, Flutterwave, Shopify.

   Each has a mockup.
5. **"The full journey":** a funnel from click to install to sign-up to first purchase, by channel, with a drop-off view.
6. **Fraud:** a "Stop paying for fake installs" section with reasons chips and a wasted-spend counter in naira.
7. **Built for developers:** SDK code tabs (Android, iOS, Flutter, React Native, Web), a webhook example, links to docs and the status page, and an SDK size badge.
8. **Privacy and trust:** NDPA and GDPR ready, consent built in, encryption, no fingerprinting on iOS, status page — linking to the trust centre.
9. **Customers:** only if real content exists.
10. **Pricing teaser:** Monthly / 6 months / Yearly toggle with three cards (Starter, Growth, Pro) and "Compare all plans".
11. **Closing CTA (navy):** "Start measuring what matters" with **Start free** and **Talk to us**.

**Other pages**
- **`/pricing`:** the full plan table from the API with the period toggle (Monthly / 6 months / Yearly with savings badges), NGN/USD switch, the **plan calculator** (same behaviour as the dashboard, using the public recommend API), add-ons, FAQ, and an agency programme summary.
- **Product pages:** one per menu item (hero, how it works diagram, screenshots, FAQs, related docs).
- **`/products/short-links` — the dedicated URL shortener page:**
  - Headline "Branded short links that measure everything".
  - Covers `clk.ng` on the free plan, `clik.gt` for paid and verified organisations, your own domain on Growth and up, QR codes, link analytics, deep links, link preview with `+`, and abuse protection with "Report a link".
  - This is the only page that targets "URL shortener" search terms (meta title "Free URL shortener for Nigeria and Africa — Clikgate short links"), and it links to the measurement platform as the next step.
  - Reachable from Product → Smart links & QR and the footer, never from the hero.
- **`/report`:** the public abuse report form (B.1). `clk.ng/report` redirects here.
- **Solutions pages** per sector, with that sector's channels, metrics and a sample dashboard.
- **`/agencies`:** the agency programme (multi-client dashboard, white label, discounts, Growth for your agency, referral fee), with an "Apply as an agency" form that creates an agency lead for staff.
- **`/switch/appsflyer`** (and `/switch/branch`):
  - honest comparison table (where Clikgate is stronger, and where AppsFlyer is, including partner status stated truthfully from site config);
  - migration steps matching the dashboard wizard;
  - "keep your branded links working";
  - the 30-day side-by-side pilot offer;
  - FAQ ("Are you a Google/Meta partner?" answered honestly from config, with the Firebase-alongside recommendation).
- **`/docs`:**
  - Getting started, SDK guides per platform, API reference (rendered from `openapi.json` with Scalar or Redoc), webhooks, consent, sales tracking, GA4 forwarding, Google readiness notes;
  - **Switching from AppsFlyer** guide;
  - **Removing the Clikgate SDK** guide per platform (from S.1);
  - **Leaving Clikgate** (export, goodbye redirects, deletion).
- **`/trust`:** trust centre with security overview, privacy and consent, NDPA/GDPR, DPA download, sub-processors (from `subprocessors.yml`), retention, a link to status, responsible disclosure, and abuse policy.
- **Legal:** Terms, Privacy, DPA, Acceptable Use Policy (covering link abuse), Cookie policy. Drafts are marked "legal review required" until approved.
- **Company:** About (mission: helping African businesses grow on real numbers), Careers (optional), Contact (WhatsApp click-to-chat through a Clikgate link, email, Lagos address).
- **Blog, Guides, Glossary, Changelog:** MDX with tags, authors and reading time. The Glossary covers terms like attribution, deferred deep link, ROAS, SKAdNetwork and CTIT, for SEO.

### W.5 Footer (Airbridge-inspired, better)
A navy footer in three bands:

1. **Top band:**
   - On the left: the Clikgate logo, the tagline "Know which marketing makes money — and which is fake.", **Start free** and **Talk to us** buttons, and a newsletter email field (double opt-in).
   - On the right: an "Ask AI about Clikgate" row with links to ChatGPT, Claude and Perplexity, each with a prefilled prompt like "Summarise what Clikgate does for African apps and businesses: https://clikgate.com".
2. **Link columns** (6 on desktop, accordions on mobile):
   - **Plans:** Compare plans, Free, Starter, Growth, Pro, Enterprise, Plan calculator.
   - **Product:** Attribution, Ad spend & ROAS, Sales tracking, Deep linking, Referrals & leaderboards, WhatsApp attribution, Offline & USSD codes, Fraud protection, Identity checks, Uninstall tracking, Short links & QR, Integrations.
   - **Solutions:** Fintech, E-commerce, Logistics & mobility, Edtech, Telecom, Agencies.
   - **Resources:** Blog, Guides, Docs, SDKs, API reference, Switching from AppsFlyer, Glossary, Changelog.
   - **Company:** About, Customers (when live), Agency programme, Careers, Contact, Trust centre, **System status** with a live dot from the status API.
   - **Legal:** Terms, Privacy, DPA, Acceptable use, Cookie settings (opens the consent banner), Report a link.
3. **Bottom band:**
   - Social icons: LinkedIn, X, Instagram, YouTube, WhatsApp Channel.
   - Currency switch (NGN/USD) and theme switch (light/dark).
   - "© {year} {Clikgate legal company name}. RC {CAC number}. Built in Lagos." (company name and RC number come from site config).
   - A **large, faded "clikgate" wordmark** spanning the full width at the very bottom (subtle gradient from `#2E5C9E` to transparent), revealed with a gentle parallax on scroll. Static under reduced motion.

### W.6 Shared website components
`Header` with mega menu, `Hero`, `JourneyLine`, `LogoStrip`, `ChannelGrid`, `UseCaseBlock`, `BentoGrid`, `FunnelMockup`, `CodeTabs`, `PricingTable` + `PeriodToggle` + `PlanCalculator` (shared logic with the dashboard via the public API), `ComparisonTable`, `FAQ`, `CTASection`, `Footer`, `StatusDot`, `ReportLinkForm`, `ConsentBanner`. Storybook for all components (light/dark).

### W.7 Status page (`apps/status`, `status.clikgate.com`)
- **Runs outside Clikgate's main infrastructure:** Cloudflare Pages for the page, a Cloudflare Worker with a cron every minute for monitors, and Cloudflare D1/KV for data. If a hosted status product is cheaper and meets these requirements, the team may choose it instead; record the decision.
- **Components:**
  - Redirects – clik.gt
  - Redirects – clk.ng
  - Branded domains
  - API
  - SDK API
  - Dashboard
  - Webhooks
  - Exports & summaries
  - Ad and sales integrations
  - Link domains reputation (from B.1 alerts)
- **Monitors:**
  - HTTP checks every minute on canary links and health endpoints, with `STATUS_PROBE_TOKEN`;
  - heartbeat ingest from the backend (B.10, signed);
  - a component is "degraded" on a slow response (> 1.5 s p95 over 5 min) or a stale heartbeat, and "down" after 3 consecutive failures from 2 locations;
  - optional external probe from a Lagos-region host (configurable URL).
- **Public page:**
  - Overall status headline.
  - Components with 90-day uptime bars and uptime %.
  - Current incidents and scheduled maintenance.
  - Incident history.
  - Subscribe by email (double opt-in) and RSS/Atom.
  - `GET /api/summary.json` for the dashboard and website (CORS for Clikgate domains).
  - The same brand design as the website.
- **Admin:**
  - `/admin`, protected by Cloudflare Access (Google Workspace or email login) **plus** a TOTP code.
  - Create/update incidents (investigating → identified → monitoring → resolved) with affected components and messages.
  - Schedule maintenance.
  - Override component status.
  - Subscriber emails sent on each update (via an email provider API key stored as a Worker secret).
  - Audit log.
- **Uptime targets** shown on the trust page: redirects 99.95%, API 99.9%, dashboard 99.9% (targets, not an SLA, until Enterprise contracts say otherwise).

### W.8 Website milestones
1. **C3-W1** Monorepo, brand tokens, shared components, header/mega menu, footer (W.5), Storybook, performance budget CI (Lighthouse CI).
2. **C3-W2** Home page, product pages, solutions, the short-links page, report page, pricing with toggle and calculator, agencies page.
3. **C3-W3** Docs (incl. API reference, switching, SDK removal, leaving), trust centre, legal templates, blog, guides, glossary, changelog, SEO, consent banner, dogfooded Clikgate links.
4. **C3-W4** Status app (monitors, heartbeat ingest, public page, admin with Access + TOTP, subscriptions, summary API), integration with dashboard and website status dots; final Lighthouse and accessibility pass.

---

## Definition of done
- New free-plan links use `clk.ng`, and paid or verified organisations use `clik.gt`. No existing link breaks. Abuse controls, reporting, staff takedown and reputation monitoring are live.
- Probabilistic matching cannot run on iOS, and iOS identity checks use only Apple-sanctioned signals.
- Consent is captured by SDKs and APIs, enforced wherever data leaves Clikgate, and logged. Data requests work end to end.
- Google click IDs flow end to end with consent signals. Lookback windows are at least 24 hours. iOS on-device measurement passes through. The SDK version policy is live. The AAP adapter is ready behind a flag.
- Firebase/GA4 receives Clikgate attribution through the SDK or the Measurement Protocol.
- Sales from Paystack, Flutterwave, Shopify and WooCommerce (plus custom webhooks) become attributed revenue through deterministic matching only.
- Agencies manage approved clients from one place, with discounts and white label per the programme.
- Customers can migrate from AppsFlyer (including keeping branded links) and can leave cleanly with a full export, goodbye redirects and an SDK removal guide.
- `status.clikgate.com` runs independently and shows live status, which the dashboard and website surface.
- The website presents Clikgate as measurement and growth infrastructure, meets the performance and accessibility budget, makes no false claims, and the URL shortener lives only on its own product page.
