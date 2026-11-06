# Clikgate Change 14 — Cost per New Customer, Labels on People with `identifyUser()`, and Keep, Hide, Restore (no deleting data because of a downgrade)

> **Instructions for the AI building this:**
> - Changes 01–13 are built (nothing is live yet). This change has three parts:
>   - **Part 1, Cost per new customer:** what a new customer costs, blended and by how they were acquired and by campaign, with value and payback. It uses **only spend Clikgate already has**; Clikgate is not a place to enter business costs.
>   - **Part 2, Labels on people:** an optional label the business gives the person behind a click, shown on the dashboard instead of the click ID, with people search and a timeline; a new `identifyUser()` on every SDK replacing `identify()`.
>   - **Part 3, Keep, hide, restore:** features turned off by a downgrade keep their data hidden instead of deleting it; only stored login details for other services are disconnected after 90 days.
> - **Backend repository** (`clikgate`, including `sdks/`): sections A, B and S; milestones C14-B1 to C14-B7 and C14-S1.
> - **Dashboard repository** (`clikgate-dashboard`): sections A and F; milestones C14-F1 to C14-F4, after the backend part is deployed and the OpenAPI types are regenerated.
> - **Website repository** (`clikgate-website`): sections A and W; milestone C14-W1.
> - **Design reference:** the mockup "Cost Per New Customer" (https://claude.ai/artifact/EgrJ84ctzJX7nfTrBaBhiL; the owner shares it with the builder). Match its layout, order and wording; numbers in it are example data.
> - **Later changes win.** This file supersedes:
>   - change 01 B.4's "kept read-only for 90 days, after which a purge is scheduled", and change 01's "analytics history" as a deletion limit (it becomes a viewing window, B.6);
>   - change 01's downgrade emails "listing features turned off and the data-retention date" (B.6);
>   - change 05 B.5's private-mode allow-list and change 06's SDK private-mode check, only to add `label` when the Owner's switch is on (B.4);
>   - change 09 N.2's "the web key can only send browser goals and read the web script config" (it can also send browser labels when allowed, B.5) and change 09's `prize_cost` "for results only" (it now also feeds spend, B.2);
>   - change 12's `goal()` signature, only to add `isFirst` and `label` (S.1);
>   - change 13 B.7's "cards show the referral code, never a name" in private mode, for organisations that switched labels on (B.4); change 13 B.12's permission list (adds the `people` area); change 13 B.13's 90-day limit on SSO settings (B.7);
>   - the SDKs' `identify()` and `POST /v1/apps/{app_id}/identify` (Part 2).
> - Nothing is live, so renamed methods and removed endpoints go outright.
> - Never log labels, customer IDs, search text, secrets, tokens, payloads or private-mode references. Run the full test suite after each milestone.

---

## A. Overview and decisions

| # | Decision |
|---|---|
| D1 | **Cost per new customer** (customer acquisition cost) on **Growth and up**: blended, by how customers were acquired, by campaign, value ÷ cost and payback. Free and Starter see a locked teaser. |
| D2 | **Clikgate is not used to enter or track business costs.** No costs page, no "Add cost" form, no expense ledger. Spend comes only from connected ad platforms and ad spend imports (change 02), QR placement spend (change 13) and challenge prize costs (change 09). Rows without spend show "No spend in Clikgate", never ₦0. |
| D3 | **A new customer** is someone reaching the organisation's "new customer" goal for the first time, counted once per customer. |
| D4 | **Payback** looks ahead **180 days** using the gross margin the business sets; "a guide, not a profit figure". |
| D5 | **Labels on people** (Growth and up): an optional label the business chooses, shown wherever the person appears; the click ID when unset; searchable; a timeline per person. |
| D6 | **`identifyUser()`** on every SDK (Android, iOS, Flutter, React Native, the web script, Node.js, Python, PHP, Java, .NET) **replaces `identify()`**. |
| D7 | **Private mode and labels:** labels work in private mode once an Owner switches on "Allow labels in private mode". No content checks on labels (the switch is a deliberate opt-in). Wording: "refuses names, emails, phone numbers and customer IDs, except a label you choose to set". |
| D8 | **Labels are never deleted because of the plan:** below Growth they're hidden and new ones aren't stored; upgrading shows them again. |
| D9 | **Keep, hide, restore** for every plan-driven turn-off; data is deleted only by the organisation's choice, deletion requests, the organisation's retention settings, deleting the organisation, or 24 months of complete inactivity with warnings. |
| D10 | **Stored login details for other services** are disconnected and deleted after 90 days with their feature turned off; settings are kept for a one-step reconnect. |
| D11 | **Honesty:** never "profit", "true cost" or "ROI guaranteed"; the report says which rows have no spend; estimates (change 13 "likely from shares") never feed it. Sales lines: "Your ad dashboards tell you cost per click. Clikgate tells you what a new customer costs across every channel it has spend for, and whether they're worth it." and "Downgrading never deletes your data. Come back any time and it's all there." |

---

## B. Backend

### Part 1 — Cost per new customer

#### B.1 Who counts as a new customer (D3)
- **Setting:** `organizations.settings.new_customer_goal_key` (defaults to the end goal, change 05); one per organisation; shown on the goal as "Counts new customers". **Value goals:** `organizations.settings.value_goal_keys` (defaults to the new-customer goal only), the goals whose values count as a customer's value, so one sale reported as two goals (order placed and order paid) is never counted twice.
- **At most one new customer per resolved customer, ever.** A counted event of the new-customer goal is a new customer when:
  1. **outside private mode, with a customer ID:** it is the first event of that goal for that `customer_user_id` in the organisation's live environment that Clikgate has seen, attributed or not (an earlier unattributed `no_click` event counts as "seen before"). `is_first: true` on a later event never creates a second new customer; `is_first: false` makes the event not new even if it is the first seen;
  2. **apps without a customer ID:** first for the installation; when the installation is later identified, the new-customer record moves to the customer, and a second one is never created for the same customer (reinstalls and new phones included);
  3. **in private mode** (Clikgate holds no customer identifier): only when the event carries `is_first: true` from a **trusted sender** (the business's server, a payment confirmation, or a sales connection); a duplicate `is_first` with the same `reference` is ignored. (The notes suggested counting by the scrambled reference; that reference is per order, not per customer, so `is_first` is used instead.)
  4. **websites without a customer ID:** only by `is_first: true` from a trusted sender, as in 3.
  `is_first` sent from a browser or an app (change 09 "from browser" goals) is stored but **never** makes a new customer.
- Only counted goals: Payment goals with confirmed amounts (changes 11/12); reversed, refunded and fraud-excluded events don't count, and a reversal of the first event removes the new-customer record (the next counted event becomes it).
- Store `goal_events.is_new_customer` at count time; worker `new_customer_backfill` (resumable) recomputes when the settings change.
- **How they were acquired** (`acquired_via`, one value per new customer, first rule that applies):
  1. `referrals` when the event is attributed to a referral (referral link, referral code or a known referrer, sdk-referrals spec);
  2. the paid ad channel when the attributed click is a paid ad (`google_ads`, `tiktok_ads`, or `meta_ads` for any paid Meta click, `is_paid_ad` from change 13 B.1);
  3. the offline channel for code-based goals (`offline_touches.channel`: agent, ussd, pos, …);
  4. `qr` for QR scans (`is_qr`);
  5. otherwise the click's `clicked_on` (change 13), e.g. `whatsapp`, `instagram` (unpaid), `email`;
  6. `direct_or_unknown`.
  The new-customer row also stores campaign, link, QR placement and referrer when known. It is a new grouping called `acquired_via`; the existing `channel` groupings (offline touches, spend) are unchanged (change 13 B.1).

#### B.2 Spend that feeds the report (D2)
| Spend | Comes from | `acquired_via` it's matched to | Campaign |
|---|---|---|---|
| Meta, Google, TikTok | `ad_spend_daily` source `meta|google|tiktok` (change 02 sync) | `meta_ads`, `google_ads`, `tiktok_ads` (Meta is one row: spend has no placement split) | matched campaign (change 02 matching) |
| Imported ad spend | `ad_spend_daily` source `manual|csv` (change 02) | the row's ad account platform (`ad_accounts.platform`); else the channel of its mapped links or offline codes (`link_ids`, `offline_code_ids`, change 02); else the new optional `channel` column on CSV and manual rows; else **Other spend** (blended only) | the row's campaign |
| QR placement spend | `qr_placements.spend_minor` (change 13), spread evenly from put-up to taken-down date; with no take-down date, over 30 days from put-up; with no dates, over 30 days from creation | `qr` | the link's campaign |
| Challenge prize costs | `leaderboards.prize_cost` where `kind = challenge` (change 09), on the challenge's end date | `referrals` for challenges that count referrals; otherwise Other spend (blended only) | the challenge's campaign, if any |

- Converted to the reporting currency with the existing FX rules (`fx_estimated`).
- No new place to type costs. The change 02 manual ad spend entry stays as it is and gains only the optional `channel` field.
- `spend_sources` values: `meta_connected`, `google_connected`, `tiktok_connected`, `ad_spend_import`, `qr_placement_spend`, `challenge_prize_costs`.

#### B.3 The report data
`GET /v1/analytics/customer-cost?from&to&group_by=acquired_via|campaign` (Growth and up; scope `analytics:read`; `403 plan_upgrade_required` otherwise). All day boundaries use the organisation's timezone.
- **Blended:** all spend in the period ÷ all new customers in the period (every `acquired_via`, including no-spend rows and `direct_or_unknown`): `spend`, `new_customers`, `cost_per_new_customer`, `previous` (the same length period before), `trend` (up to 6 earlier periods of the same length, only those inside the plan's analytics history and with data; missing periods are returned as `null` and drawn as gaps).
- **Rows:** `new_customers`, `spend`, `spend_sources[]`, `cost_per_new_customer` (null with `no_spend: true` when no spend), `avg_first_value`.
- **Average first value:** value of the value goals on the customer's first day (organisation timezone), averaged over new customers in the period; goals without value count as 0 and the response says how many had a value.
- **Value and value ÷ cost use one cohort, so value and cost belong to the same customers:** the **value cohort** is the customers who became new in the newest window of the same length as the period that ended at least 180 days ago (for a 30-day period: customers won 180–210 days ago). For that cohort: `cohort_spend` (spend in its window) ÷ its customers = `cohort_cost`; cumulative value per customer at day 0, 30, 90 and 180 (value goals only); `avg_value_90d`; `value_to_cost = avg_value_90d ÷ cohort_cost`. Returned with `value_cohort: {from, to, customers}`.
  - If that cohort has fewer than 30 customers, use the newest window that ended at least 90 days ago and return points up to day 90 only (`curve_to: 90`); if that also has fewer than 30, `value: null, reason: "not_enough_history"`.
  - Rows use their own cohort the same way; a row with fewer than 30 customers in its cohort shows "Not enough customers yet" for value columns (it never borrows the blended values).
  - The curve is cumulative, so it never goes down.
- **Payback:** `organizations.settings.gross_margin_pct` (1–95, nullable; Owners, Admins and custom roles with `reports:manage`). Using the cohort's curve and `cohort_cost`: the payback day is the first point where value × margin ≥ cost, linearly interpolated; results `on_first_order`, `{days: n}`, `not_within_180_days` (or `not_within_90_days` when `curve_to: 90`), `not_enough_history`, or `margin_not_set`. 180 days is the limit.
- **Value ÷ cost bands:** `healthy` (≥ 3), `ok` (1–3), `below_cost` (< 1). It is **sales value**, not margin; the dashboard says so.
- Cached per organisation and period for 15 minutes; worker `customer_cost_rollup` hourly.
- **Export:** dataset `customer_cost` in the change 02 datasets registry (CSV, Sheets, scheduled exports).
- **Links into it:** the Overview's end-goal tiles (change 05) gain a "Cost per new customer" tile linking here; the Goals report and the Ad spend report link to it.
- **Summaries** (change 02): Growth and up add "Cost per new customer: ₦3,501 (down 7%)" only when spend exists.

### Part 2 — Labels on people

#### B.4 People and labels (D5, D7, D8)
- **A person** is, in order: a `customer_user_id` (outside private mode); else an app installation (`app_id` + installation ID); else a web visitor's click ID (the first-party cookie, change 09 N.2). Table `people` (id `per_`, organization_id, environment, customer_user_id (nullable), label (nullable, ≤ 80), label_source `server|device|browser|dashboard`, label_updated_at, created_at, merged_into (nullable)); `person_links` (person_id, kind `click|installation|visitor`, ref, linked_by, linked_at, verified bool); `person_label_history` (person_id, label, source, set_at). A `pg_trgm` index on `label`.
- **Linking and merging:**
  - A click or installation is linked to a person by a **verified** source only: the business's server (`POST /v1/people/identify`, server goals with a customer ID), a mobile `identifyUser()` with a valid identity token, or a deterministic attribution (click ID carried into the install or goal). Probabilistic matches never link.
  - **Two people with different `customer_user_id`s are never merged.** When a click or installation already linked to customer A is identified as customer B (a shared phone, a reused or forwarded click ID), the click or installation is **moved** to B from then on, and both timelines show "moved from/to"; history before the move stays with A.
  - Merging (a visitor or installation person into a customer person) keeps the newest server-set label, falls back to the newest other label, and keeps every label in the history. Owners and staff can **undo a merge** (`POST /v1/people/{id}/unmerge`, audit-logged).
  - Browser and unverified device customer IDs (no identity token) are stored as hints, never used to merge, never used in referral or identity checks.
- **Label rules:** optional; 1–80 characters after trimming; empty string clears it; the latest one wins **within the same or a lower source rank** (server and dashboard > device > browser), so a device or browser can't overwrite a label the business's server or team set; every value kept in history; not unique.
- **Safe display (not content checks):** labels are always HTML-escaped wherever shown, control characters are removed on save, and CSV/Sheets exports escape leading `= + - @` to stop formula injection.
- **Where labels show:** click details, installs, goals, People, referral map cards (change 13; the map uses `person_id`, and in private mode with labels on, cards show the label), leaderboard and challenge **admin** views, exports, and webhooks. Objects carry `person: {id, label}` (`label` null when unset, hidden or not permitted). With no label, the click ID is shown.
- **Labels never go to:** ad platforms, GA4 or Firebase forwarding, other organisations, public or embedded leaderboard pages, SDK responses to end users (`referrals/me`, `referred-by`, leaderboard endpoints), agency cross-client reports.
- **Private mode:** the allow-lists (change 05 B.5 server, change 09 N.2 browser, change 06 SDK check) accept `label` only when `settings.private_mode.allow_labels` is on; otherwise `422 labels_off_in_private_mode` (not `private_mode_field_rejected`), and the SDKs drop the label on the device with one debug warning. `/v1/sdk/config` and the web script config return `allow_labels`. The switch is turned on by an Owner (fresh security code or SSO re-confirm; audit-logged; emailed to all Owners) with the text "Labels are stored and shown to your team exactly as you send them, including any personal details you put in them." **No content checks.** Turning it off asks: "Keep saved labels hidden" or "Delete saved labels" (Owners, fresh code). `customerId` is still refused in private mode. The private-mode PDF report (change 05) states whether labels are on.
- **Browser labels:** `settings.labels.allow_from_browser` (default **off**). When off, `POST /v1/web/identify` with a label and labels on browser goals are refused (`403 browser_labels_off`). When on: only click IDs of this organisation, at most 30 days old, from an allowed origin; at most 5 label changes per click ID per day; browser labels never overwrite server, dashboard or device labels.
- **Plans:** feature key `people_labels`, Growth and up. Below Growth: `identifyUser()` still links `customerId` (what `identify()` did); the label is not stored (`label_ignored: "plan"`); existing labels are **kept and hidden** (D8) and show again on upgrade.
- **Permissions** (added to change 13 B.12 as area `people`): `people:view` (see labels, People and timelines) and `people:manage` (edit, clear, unmerge). Standard roles: Owner and Admin have both; Developer has `people:view`; **Viewer has neither** (an organisation that wants Viewers to see labels makes a custom role). Agency members see labels only with access level `full`. API scopes `people:read` and `people:write` are added to the backend scope list (Owner/Admin both, Developer `people:read`). **Wherever a user or key lacks `people:view` / `people:read`, labels are replaced by the click ID**, including exports and the dashboard's webhook test view. Webhooks include labels only when the organisation turns on "Include labels in webhooks" (default off).
- **Retention and privacy:** new organisation setting `retention.labels_days` (optional; labels older than this since last set are cleared, history included). Deletion and access requests (change 03 `POST /v1/privacy/requests`) gain subjects `person_id` and `click_id`, and Owners and staff can find the person by label; access requests export labels and history, including hidden ones; deletion removes them. The docs and Settings say "Don't put information in labels that your customers wouldn't expect you to keep".

#### B.5 Endpoints
- `POST /v1/sdk/identify` (mobile SDKs, SDK key) gains `label`; `customer_user_id` and `identity_token` as today; without a valid token, the customer ID is a hint (B.4) and the label has source `device`. Response `{person_id, label_ignored?}`.
- `POST /v1/web/identify` (web key; change 09 N.2 now also allows this): `{click_id, label?, customer_id?}` (the web script fills `click_id` from its cookie); `customer_id` from the browser is always a hint; refused in private mode for `customer_id`, and for labels unless both switches allow it. Rate-limited like other public endpoints (change 12 B.6).
- `POST /v1/people/identify` (server, scope `conversions:write`): `{click_id? | (app_id, installation_id)? | customer_id?, label?}` with at least one reference (when a click or installation is given, `customer_id` links it to that customer); always **verified**, so it also satisfies `require_identity_token` for referral programmes (as the removed `POST /v1/apps/{app_id}/identify` did).
- `POST /v1/people/search` (`people:read`; search text in the body, never in the URL): `{q, cursor?}` → label contains, customer ID exact, click ID exact; results always show label **and** click ID. `GET /v1/people/{id}` (timeline: clicks with `clicked_on`/`shared_as`, link, campaign, QR placement; installs; goals with values and the new-customer tag; label history; moves and merges). `PATCH /v1/people/{id}` (`label`, `people:write`), `POST /v1/people/{id}/unmerge`.
- **Labels with goals:** server goal endpoints and the mobile `goal()` accept `label` (mobile labels have source `device`); browser goals accept it only when browser labels are allowed.
- Audit log entries for label changes record who and when, never the label text.

### Part 3 — Keep, hide, restore

#### B.6 Plan-driven turn-off keeps data (D9)
- Downgrade, add-on ended or plan expired: features no longer included turn off with `data_action: keep` (growth spec 9E.4, change 01 B.4). **No purge is scheduled** (remove the 90-day purge job). Kept data is **hidden**: not shown in the dashboard, API or webhooks and not used (no collecting, ranking or sending); the API returns `403 plan_upgrade_required` with `data_kept: true`.
- Over plan limits (QR placements, export schedules, saved reports, roles and any other counted item, not only change 01's domains, members and programmes): extra items are kept read-only and hidden from use; the over-limit selection (change 01) is extended to every counted item.
- **Export-all** (change 03) and privacy access requests always include hidden data, people and labels, on every plan, so leaving is never blocked.
- **Analytics history** (change 01 plan table) is a **viewing window, not a deletion limit**: clicks older than the plan's window are hidden, not deleted, and show again on upgrade. Raw clicks are kept for **25 months** on every plan (Enterprise: as agreed), then rolled up into the daily totals and the raw rows deleted.
- Where a feature lived, a locked panel: "Your {thing} is saved. Upgrade to {plan} to see it again." with the amount when cheap to count ("14 months of referral history", "230 labelled people").
- **Upgrade restores instantly**, subject to the new plan's limits.
- **Deletion only when:** the organisation chooses it (the existing `purge` with 7-day grace and `purge_now`, plus **"Delete this feature's data now"** on each locked panel, Owners only, fresh security code, with a list of what will go); a deletion request; the organisation's retention settings (`retention.labels_days`, `identity_checks.retention_days` and any later retention setting); deleting the organisation; or **24 months of inactivity** (B.8).
- **Emails:** the change 01 downgrade email's "features turned off and the data-retention date" becomes: "These features are now off: {list}. Your data is saved and comes back as soon as you upgrade. Connections to other services will be disconnected on {date + 90 days} if you don't upgrade."

#### B.7 Login details for other services (D10)
- After **90 days** with the feature turned off (by the plan **or** by the organisation), stored credentials are **disconnected and deleted** (and revoked at the provider where its API allows): ad platform tokens (change 02), Google Sheets and other export connections, payment provider read-only keys and webhook secrets (change 11), sales connection secrets (change 03), SSO client secrets and SAML certificates (change 13), push credentials (growth spec). The connection's settings stay, marked **"Reconnect to use again"**.
- Owners are emailed 7 days before; turning the feature back on before then cancels it. Worker `credential_cleanup` daily; audit-logged; never logs the secret.
- Change 13 B.13 is updated: SSO and branded sign-in **settings** are kept with no time limit; only the SSO secret is disconnected after 90 days off; paused members stay paused. On upgrade after the secret was removed, an Owner reconnects SSO (one step, the settings are kept) and paused members become active again once the connection's test passes.

#### B.8 Long inactivity
- An organisation with **no member sign-in, no API, SDK or web script traffic, and no human (non-bot) link clicks for 24 months** is scheduled for deletion. Organisations with an active paid subscription are never in this state. Warning emails to all Owners at 60, 30 and 7 days before; any sign-in, traffic or human click cancels it; staff can extend (🔐, reason).
- Deletion follows the existing organisation deletion (including change 09 L8 goodbye redirects).

#### B.9 Tests
- **New customers:** first per customer ID with earlier unattributed events; `is_first` true/false rules; browser and app `is_first` ignored; private mode only by trusted `is_first`; duplicate references; installation identified later and reinstalls (one new customer); reversals moving the record; settings backfill.
- **Acquired via and spend:** each precedence rule; paid vs unpaid Meta (`meta_ads` row vs unpaid instagram/facebook rows); each spend source and its matching, account platform and mapped link defaults, CSV `channel`, Other spend, QR spreads (with and without dates), prize costs for referral and non-referral challenges, FX.
- **Report maths** on fixed fixtures: blended, rows, no-spend rows, trend gaps, the value cohort (180-day and the 90-day fallback), per-row cohorts and "not enough customers", payback interpolation and each result, cumulative curve, bands, timezone boundaries, value goals preventing double counting, Growth gate, caching, export dataset.
- **People:** resolution; verified-only linking; never merging two customer IDs (moves instead); merge label precedence and unmerge; label source ranks; escaping and CSV formula escaping; search in the body and never logged (log scan); permissions everywhere (exports, webhooks, agency access levels, Viewer); browser labels off by default, origin, age and rate limits; private-mode switch on/off with keep or delete; `customerId` refused in private mode; plan below Growth (ignored, hidden, restored); deletion and access requests by `person_id`/`click_id`; labels never in ad sending, GA4, public leaderboards or end-user SDK responses (pipeline tests); retention.
- **Keep, hide, restore:** no purge on downgrade; hidden everywhere except export-all and access requests; analytics history as a viewing window and the 25-month click rollup; over-limit for every counted item; restore on upgrade; organisation-chosen deletion; new downgrade email; credential disconnect at 90 days (plan and organisation turn-off) with warning and cancel; SSO reconnect then paused members restored; inactivity rules, warnings, cancel, paid organisations excluded.

#### B.10 Backend milestones
1. **C14-B1** B.1 new-customer and value-goal settings, counting rules, `acquired_via`, backfill; tests.
2. **C14-B2** B.2 spend matching (account and mapping defaults, CSV/manual `channel`, QR spreads, prize costs); tests.
3. **C14-B3** B.3 report endpoint, cohorts, payback, rollup, export dataset, summary line, Overview tile data; tests; regenerate `openapi.json`.
4. **C14-B4** B.4 people, linking, moves and merges, labels, source ranks, escaping, private-mode and browser switches, permissions and scopes, retention and privacy requests, plan handling; tests.
5. **C14-B5** B.5 endpoints (SDK, web, server, search, timeline, unmerge, labels on goals), removal of `/v1/apps/{app_id}/identify`, allow-list and config updates; tests; regenerate `openapi.json`.
6. **C14-B6** B.6–B.7 keep, hide, restore (viewing window, rollup, over-limit extension, emails), credential cleanup, change 13 B.13 update; tests.
7. **C14-B7** B.8 inactivity; full suite; update `docs/PROGRESS.md`.

---

## S. SDKs (`sdks/`)

### S.1 `identifyUser()` replaces `identify()`; `goal()` gains `isFirst` and `label` (D6)
- **Mobile** (Android, iOS, Flutter, React Native): `identifyUser(label?, customerId?, identityToken?)` in each platform's idiom (named arguments or an options object). `identify()` is removed. Calls `POST /v1/sdk/identify`. Passing nothing is a no-op; `customerId: null` clears the customer ID as `identify(null)` did. Referral programmes with `require_identity_token` keep working through `identityToken`.
- **Web script:** `clikgate.identifyUser({ label, customerId })` → `POST /v1/web/identify` with the stored click ID (labels only when the organisation allows browser labels; the script reads it from config).
- **Server SDKs** (Node.js, Python, PHP, Java, .NET): `clikgate.identifyUser({ clickId | appId + installationId | customerId, label })` (at least one reference; with a click or installation, `customerId` links it to that customer) → `POST /v1/people/identify`.
- **`goal()` on every SDK** gains optional `isFirst` and `label` (change 12's signature otherwise unchanged; the goal kind still never travels in the call). `isFirst` from browsers and apps is sent but never makes a new customer (B.1); the docs say to send it from the server.
- **Private mode:** the SDKs read `private_mode` and `allow_labels` from config; without the switch they drop the label on the device with one debug warning; they always drop `customerId` (as today). The SDK's local private-mode check (change 06) allows `label` and `isFirst` accordingly.
- **Below Growth:** the call succeeds; one debug warning when the response says `label_ignored: "plan"`.
- Docs, AI guides, setup-command snippets and examples updated; a docs test fails if `identify(` appears outside the changelog.

Milestone **C14-S1**: S.1 on every SDK with examples, docs and AI guides.

---

## F. Dashboard

### F.1 Cost per new customer — follow the "Cost Per New Customer" mockup
- Measure › **Cost per new customer** (Growth and up; Free and Starter see a locked teaser with the tiles blurred and "Available on Growth").
- Header: period (Last 30 days / Last 90 days / custom) and the **New customer** strip ("Someone reaching **Order paid** for the **first time**, counted once by your customer ID." In private mode: "…counted when your server sends `is_first`."), linking to the goal settings (new-customer goal and value goals).
- **Tiles:** blended cost per new customer (spend ÷ new customers, trend with gaps where there's no data, change vs previous period), new customers, average first order, average value after 90 days ("Sales value 6.9× what it cost to win them", from the value cohort, with a small "from customers won {month range}" note, or "Not enough history yet").
- **By how they were acquired** bars (spend ÷ new customers) with a dashed blended line; rows without spend: warning stripe, "No spend in Clikgate"; Direct or unknown: "In blended only". A **By campaign** toggle.
- **Payback:** margin slider (saved; `reports:manage`), the chart up to day 180 (or 90 with a note), the cost line, the answer in words, and "A guide, not a profit figure: it doesn't include your other running costs." With no margin set: "Set your margin to see payback."
- **Is each channel worth it?** table: acquired via, new customers, spend, spend from, cost each, first order, 90-day value, value ÷ cost (marker and number; "sales value, not margin" in the header tooltip), blended footer; under it the line naming the spend sources.
- No cost entry anywhere. Empty state with no spend: "Connect an ad platform or import ad spend to see what a new customer costs." with links.
- Overview gets a "Cost per new customer" tile (Growth and up) linking here; Goals and Ad spend reports link here.

### F.2 People
- **Search** in the top bar and a **People** page (Growth and up; `people:view`). Results always show the label **and** the click ID (labels aren't unique), plus customer ID when present, last seen, goals count and value.
- **Person page:** label with **Edit label** (`people:manage`), label history with source (server, team, app, browser), the timeline (clicks with Clicked on / Shared as, link, campaign and QR placement; installs; goals with values and a "New customer" tag; moves and merges), and **Undo merge** (`people:manage`).
- Everywhere a person appears, the label (or the click ID) links to the person page; without `people:view`, only the click ID shows.
- Settings › People: **Allow labels from the browser** (off by default), **Include labels in webhooks** (off by default), label retention.
- Settings › Privacy (private-mode organisations): **Allow labels in private mode** with its text and the fresh-code step; turning it off asks keep hidden or delete.
- Below Growth: People locked with "Your labels are saved. Upgrade to Growth to see them again." when labels exist.

### F.3 Locked features keep their data
- Every feature turned off by the plan shows the locked panel with what's saved, **Upgrade** and **Delete this feature's data now** (Owners; confirmation listing what will be deleted; fresh security code).
- Connections show "Reconnect to use again" (with the date) after their login details were disconnected, and a banner 7 days before.
- Reports beyond the plan's analytics history show "Older clicks are saved. Upgrade to see up to {n} months."
- Remove the old "data will be deleted on {date}" banners.

### F.4 Staff console
- Organisation page: features off with data kept, scheduled credential disconnects, inactivity state with **Extend** (🔐, reason), and **Undo merge** on a person for support (🔐, reason, audit-logged).

Milestones: **C14-F1** F.1; **C14-F2** F.2; **C14-F3** F.3 and F.4; **C14-F4** Playwright suite for all three; update `docs/PROGRESS.md`.

---

## W. Website (`clikgate-website`)
- **Goals / measurement pages:** a "Cost per new customer" section (what a new customer costs by how they were acquired and by campaign, sales value after 90 days and payback, from connected ad platforms, imported ad spend, QR placements and challenge prizes). Growth and up. Never "profit" or "true cost".
- **Docs:** "Cost per new customer" (how new customers are counted, sending `is_first` from your server, value goals, where spend comes from, cohorts and payback), "Labels and people" (`identifyUser()` on every platform, search, verified vs browser labels, private-mode switch, retention), updated SDK and `goal()` pages (no `identify(`).
- **Private mode** wording everywhere (website, docs, trust centre, private-mode report): "refuses names, emails, phone numbers and customer IDs, except a label you choose to set".
- **Pricing:** comparison rows "Cost per new customer" and "Labels and people search" (Growth and up); FAQ "What happens to my data if I downgrade?" → "It's saved. Features and history your plan doesn't include are hidden until you upgrade again; nothing is deleted because of a downgrade. Connections to other services are disconnected after 90 days, and you reconnect them in one step."
- **Trust centre retention schedule:** keep, hide, restore; raw clicks kept 25 months then rolled up; the 90-day credential disconnect; the 24-month inactivity rule.
- `llms.txt`: the new pages.

Milestone **C14-W1**: all of the above; Lighthouse and accessibility checks; update `docs/PROGRESS.md`.

---

## Definition of done
- Growth organisations see cost per new customer, blended and by how customers were acquired and by campaign, with value and payback from consistent cohorts, from existing spend only; there is no cost entry; rows without spend say so.
- Each customer is a new customer at most once; private mode counts only trusted `is_first`.
- `identifyUser()` replaces `identify()` on every SDK and `goal()` has `isFirst` and `label`; labels show instead of click IDs only to people allowed to see them, are searchable and have a timeline; two customers are never merged; browser labels are off by default; private mode accepts labels only with the Owner's switch, with no content checks; below Growth labels are kept hidden.
- A downgrade never deletes data (features, labels and click history are hidden and restored on upgrade); only login details for other services are disconnected after 90 days; inactivity deletion only after 24 months with warnings.

## Before building: things only the owner can provide
- Share the "Cost Per New Customer" mockup with the builder.
- Confirm: new customers in private mode counted by `is_first` from the business's server (not by the per-order scrambled reference); raw clicks kept 25 months on every plan; human link clicks counting as activity for the 24-month rule; browser labels off by default.
- Approval of the private-mode wording change, the downgrade FAQ answer and the new downgrade email.
- A legal check that the trust centre retention schedule matches the 25-month click and 24-month inactivity rules.
