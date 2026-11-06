> **Workspace note (coordinator, 2026-10-26):** this is the owner's official **Change 05**. It was received earlier with the label "Change 06" and was **built in full on 2026-10-24** under that label (backend, SDK 1.3.0, dashboard, website): code comments, DECISIONS entries and docs that say "Change 06" about goals, funnels or private mode mean this change. The web script exposes both `Clikgate.clickId()` and `Clikgate.getClickId()`. The owner has not yet confirmed Growth as the private-mode minimum plan (one constant: `PRIVATE_MODE_MINIMUM_PLAN`).

# Clikgate Change 05 — Goals, Value & Private Mode, and Website Repositioning (backend, SDKs, dashboard, website)

> **Instructions for the AI building this:**
> - This is a **self-contained change set** on an existing Clikgate codebase. Read only this file and the existing code it names.
> - **Backend repository** (`clikgate`): build sections B and S, milestones C5-B1 to C5-B4, then C5-S1. Changes 01–05 are already built.
> - **Dashboard repository** (`clikgate-dashboard`): build section F, milestones C5-F1 to C5-F2, after the backend part is deployed and the OpenAPI types are regenerated. Follow the skills in `.claude/skills/`.
> - **Website repository** (`clikgate-website`): build section W, milestone C5-W1.
> - **Goals are a layer on the existing conversions system, not a second system.** A goal event is stored as a row in `conversions` (backend spec 10.7) with `type = "goal"`, and reuses its matching rules, reversals, rollups, fraud decisions, conversion sending (change 02), sales connections (change 03), GA4 forwarding and webhooks. Extend those; don't copy them.
> - The word **"journey"** is already used for web-to-app banners (backend spec section 24). In code and UI, the click-to-goal path is called a **funnel**, never a journey.
> - **Verify against current official documentation before building**, and record findings in `docs/DECISIONS.md`: Google Ads offline conversion import (value, currency, conversion action value settings), Meta Conversions API (custom vs standard events, `value`/`currency`, `fbc`), TikTok Events API (value events), ISO 4217 currency minor units.
> - Never log goal references, values with references, or rejected private-mode field contents.
> - Run the full test suite after each milestone.

---

## A. Overview (read first)

### A.1 What this change does
1. **Goals.** Each organisation names the outcomes it cares about (`account_opened`, `loan_disbursed`, `order_paid`, `first_trip`, `course_paid` …) and chooses which one is the **end of the journey**. The start is always a click (or a code, for offline and creator codes). The end goal can be set for the whole organisation and overridden per campaign or per link.
2. **Any source sends the same goal:**
   - the business's own server (`POST /v1/goals/events`);
   - the app SDKs (`Clikgate.goal("account_opened")`);
   - Paystack, Flutterwave, Shopify, WooCommerce and custom webhooks (change 03), each mapped to a goal;
   - inbound webhook mappings (backend spec 10.11).
3. **Value and currency, both optional.** A goal event can carry a `value` in normal units (₦2,000,000 is `2000000`, decimals allowed) and an optional `currency`, which defaults to the goal's currency. Each goal chooses whether a value is off, optional or required. Values give revenue, average value, return on ad spend, and value-based bidding on Google, Meta and TikTok.
4. **Funnels.** Optional named steps between the click and the end goal (click → install → sign-up → KYC passed → account opened) with drop-off and time between steps.
5. **Private mode.** An organisation switch for banks, insurers, lenders, health and any business that can't share customer data. In private mode Clikgate **refuses** names, emails, phone numbers, customer IDs, hashed identifiers and free-form metadata. It accepts only the goal, the click ID or code, the business's own reference (stored scrambled) and, if the goal allows it, value and currency. Raw payloads from payment and shop connections are read in memory and thrown away.
6. **First vs repeat.** Every goal event is marked first or repeat **for its click**, and the business can optionally mark it as the customer's first (`is_first`) without telling Clikgate who the customer is. This closes the "click to first purchase" gap.
7. **Website repositioning.** The home page stops leading with app installs and shows what Clikgate is: measurement from **click to the goal the business chooses**, for apps, websites, WhatsApp and offline, with a private mode for regulated businesses (W).

### A.2 Out of scope
- Value scores or labels instead of money (decided against; value is money only).
- Probabilistic or cross-device matching without a click ID or code (unchanged: deterministic only).
- Multi-touch attribution (unchanged: last click).
- Predicted value or lifetime value modelling.

### A.3 Plans
Add to the plan catalogue through a new plan version (as changes 02 and 03 did):

| Key | Free | Starter | Growth | Pro | Enterprise |
|---|---|---|---|---|---|
| Allowance `goals` (active goals) | 2 | 5 | 20 | Unlimited | Unlimited |
| `goal_values` (value, revenue, value per goal) | ✓ | ✓ | ✓ | ✓ | ✓ |
| `funnels` (allowance `funnels`) | — | 1 | 5 | Unlimited | Unlimited |
| `private_mode` | — | — | ✓ | ✓ | ✓ |

Return on ad spend still needs the existing ad-spend keys (change 02), and sending goals to ad platforms still needs `conversion_sending`.

---

## B. Backend

### B.1 Data model (migration)

**goals**
- id (`gol_`), organization_id, environment, key (snake_case, 2–40 characters, `^[a-z][a-z0-9_]*$`, unique per org and environment), name ("Account opened"), description (nullable), status (`active|archived`).
- `value_mode` (`none|optional|required`), `default_currency` (ISO 4217; defaults to the organisation's currency), `count_mode` (`once_per_click` default | `every` for repeat purchases), `window_days` (default 30, 1–180; used instead of the link's attribution window for this goal), `platform_mappings` (jsonb, B.7), created_by, timestamps.
- Archived goals keep their data and stop accepting events (`410 goal_archived`).

**organizations.settings** (extend): `end_goal_key` (nullable: the organisation's default end goal), `private_mode` (B.5), `reporting_currency` (if not already present from change 02).

**campaigns, links** (extend): `end_goal_key` (nullable). The effective end goal for a click = link's → campaign's → organisation's. It is resolved when reporting, not stored on the click, so changing it updates reports.

**funnels**
- id (`fnl_`), organization_id, environment, name, steps (jsonb, ordered, 2–8 steps; the first is always `{"type": "click"}`; others are `{"type": "install"}`, `{"type": "goal", "goal_key": "kyc_passed"}` or `{"type": "app_event", "name": "signup"}`), end goal = the last step (must be a goal), is_default (one per org), timestamps.

**conversions** (extend the existing table):
- `type` gains the value `goal`; `goal_id` (nullable, FK), `goal_key` (denormalised).
- `value_minor` is the existing `amount_minor`; keep that column and the existing `currency` column.
- `first_for_click` (bool), `is_first_customer` (nullable bool, as sent by the business), `duplicate_of_id` (nullable, B.3), `reference_hash` (nullable, B.5).
- Unique index on `(organization_id, goal_id, reference_hash)` where not null, for idempotency in private mode.

**Migration and backfill:**
- For each organisation, create two goals: `purchase` (`value_mode: optional`, the organisation's currency, `count_mode: every`) and `signup` (`value_mode: none`, `once_per_click`).
- Link existing conversions of type `purchase` and `signup` to them (set `goal_id`, `goal_key`; keep `type` as it is so old API clients still work).
- Set `end_goal_key = purchase` where the organisation has purchases, otherwise `signup`.
- Compute `first_for_click` for existing rows in a background job.

### B.2 Goal events API
`POST /v1/goals/events` (scope `conversions:write`; batch: `POST /v1/goals/events/batch`, up to 500 per request, per-item results in order):
```json
{
  "goal": "account_opened",
  "click_id": "clk_8F2K…",
  "reference": "APP-55231",
  "value": 2000000,
  "currency": "NGN",
  "is_first": true,
  "occurred_at": "2026-10-23T09:12:00Z"
}
```
- **Required:** `goal`, and **one** of `click_id` or `code` (an offline or creator code, using the existing code resolution), and `reference` (the business's own unique ID for this event: an application number, order ID or transaction reference; 1–128 characters).
- **`value`** (optional): a JSON number or a numeric string, ≥ 0, at most 15 significant digits, with no more decimal places than the currency allows (₦ and $: 2; currencies with 0 decimals: 0). It is stored as minor units using the ISO 4217 exponent. **Values are in normal units, never kobo or cents.**
- **`currency`** (optional): ISO 4217. Defaults to the goal's `default_currency`. If `value` is absent, `currency` is ignored.
- **Value rules by `value_mode`:** `none` → a value is rejected (`422 value_not_allowed`); `required` → a missing value is rejected (`422 value_required`); `optional` → either way.
- **`is_first`** (optional boolean): the business's own statement that this is the customer's first such event. Clikgate never checks it against an identity.
- **`occurred_at`** (optional): defaults to now; rejected if more than 5 minutes in the future.
- Outside private mode, the existing `metadata` field (≤ 8 KB) is also accepted. In private mode it is rejected (B.5).
- Response: `201` with `{id, status, goal, first_for_click, attributed_to: {link_id, campaign_id, clicked_at} | null}`, or `200` with the existing result when the same `(goal, reference)` was already received.

`POST /v1/goals/events/reverse` `{goal, reference, value?, reason?}`: a full or partial reversal (refund, cancelled loan, chargeback) using the existing reversal logic. It emits `goal.reversed`.

The existing `POST /v1/conversions` gains optional `goal` and `value` fields. If `goal` is given it behaves exactly like the goals endpoint, and `amount_minor` stays supported for old clients. A request with both `value` and `amount_minor` is rejected.

### B.3 Matching and counting
- **Attribution** uses the existing matching rules (backend spec 10.7, steps 1–2) with the goal's `window_days` in place of the link's window, and the existing bot and fraud decisions (change 02).
- **`once_per_click`:** the first attributed event for a (click, goal) pair counts. Later ones are stored with `status = attributed`, `duplicate_of_id` set, and are **not counted** in totals or sent to ad platforms. The API response says `"counted": false, "reason": "already_counted_for_click"`.
- **`every`:** all events count. `first_for_click` is true only for the first.
- **Without a click ID or code** the event is stored as `unattributed` (reason `no_click`) so the match rate is visible, as today.
- **Codes:** an event with a `code` is attributed to the code's link or referrer, with `clicked_at` null and "time to goal" not computed.
- **Funnels:** a click completes a funnel step when an event for that step (install, app event or goal) is attributed to the same click, or to the install that came from that click, within the end goal's window. Steps may be completed out of order; reports show both "completed" and "completed in order".

### B.4 Sources mapped to goals
| Source | How it maps |
|---|---|
| Business server | `POST /v1/goals/events` |
| App SDKs | `Clikgate.goal(key, {value, currency, reference, isFirst})` (S.1). The SDK attaches the click/install attribution. `reference` is required; the SDK generates a UUID if the app doesn't pass one (for app-side idempotency only) |
| App event rules (growth spec `app_event_rules`) | Add `goal_key` to a rule: "when the app sends event `deposit_made`, record goal `first_deposit` with value from property `amount`" (`value_property`, optional) |
| Sales connections (change 03: Paystack, Flutterwave, Shopify, WooCommerce, custom) | Each connection gains `goal_key` (default `purchase`). A successful payment or paid order becomes that goal; the reference is the provider's transaction or order ID; the value is the amount if the goal allows a value; refunds become reversals |
| Inbound webhook mappings (backend spec 10.11) | The mapping gains `goal` (constant or path) and `value` (path, normal units) |
| Offline and creator codes | Via `code` on the goals endpoint |

### B.5 Private mode
**Setting:** `organizations.settings.private_mode = {enabled, enabled_at, enabled_by}`. Turning it **on** is open to owners; turning it **off** needs an owner, a typed confirmation and a re-entered password, is audit-logged and emails all owners and admins. Neither direction changes data already stored. It applies to live and test mode alike.

**What private mode refuses** (`422 private_mode_field_rejected`, naming the **field** but never echoing its content):
- On goal events and conversions: `metadata`, `email`, `phone`, `customer_user_id`, `user_id`, `name`, any `hashed_*` identifier, and **any field not on the allow-list** (`goal`, `click_id`, `code`, `reference`, `value`, `currency`, `is_first`, `occurred_at`).
- On the SDKs: `identify()`, user properties and event `properties` are dropped on the device and not sent. Value comes only through `goal()`. The SDK logs a single warning in debug builds. The SDK reads `private_mode` from `/v1/sdk/config`.
- On sales connections and inbound webhooks, the provider's payload is parsed **in memory**. Only the success status, the click ID (from metadata, cart attribute or order meta), the reference, and the amount and currency (only when the goal allows a value) are kept. The raw-payload inbox (change 03: kept encrypted for 14 days; backend spec 10.11: 7 days) is **not written**. The debug view shows field **names** received, never values.

**What is switched off while private mode is on** (the UI explains each; APIs return `409 private_mode_conflict`):
- Sending hashed identifiers to ad platforms (`send_hashed_identifiers` forced false).
- Identity-based sales matching (change 03 matching rule 2). Click ID and code matching still work.
- Identity checks and duplicate-account detection (growth spec), referral programs that require identity tokens, and WhatsApp attribution features that store phone numbers.

**What still works:** clicks and codes (stored as today, without raw IPs), installs and app opens, goals with value, funnels, ad spend and ROAS, fraud scoring on clicks and installs, conversion sending with the platform's own click IDs (`gclid`/`gbraid`/`wbraid`, `fbclid` as `fbc`, `ttclid`), GA4 forwarding (without user IDs), summaries, exports and webhooks.

**References are stored scrambled:** `reference_hash = HMAC-SHA256(org_reference_key, goal_key + ":" + reference)`. `org_reference_key` is a per-organisation secret, encrypted at rest. The plain reference is never stored or logged in private mode. Duplicate detection and reversals work by recomputing the hash. Outside private mode the reference is stored as `external_id` as today, plus the hash.

**Private mode report:** `GET /v1/organization/private-mode/report` returns, for the last 30 days, the number of requests that had a field rejected (by field name), the share of goal events with a click ID or code, and confirmation that no raw payloads were stored. This is for the organisation's compliance team. It is downloadable as a PDF using change 04's renderer.

### B.6 Analytics
`GET /v1/analytics/goals` with `from`, `to`, `goal` (default: the end goal), `group_by` (`none|link|campaign|channel|source|creator|referrer|code|ad_platform|country|device_type|day|week`), and existing filters. Each row returns:
- `clicks`, `goal_completions` (counted only), `completion_rate`, `first_for_click` and `repeat` counts, `is_first_customer` count;
- `value` per currency and `value_reporting` (converted with change 02's FX rates to the organisation's reporting currency, with the rate date), `average_value`, `reversed_value`;
- `median_time_to_goal` and `p90_time_to_goal` (from click), and `unattributed` count with reasons;
- with ad spend (change 02): `spend`, `cost_per_goal`, `value_roas`.

`GET /v1/analytics/funnels/{id}`: per step: count, conversion from the previous step and from the click, drop-off, median time from the previous step, both "any order" and "in order".

Add `goals` to the datasets registry (change 02) so summaries, scheduled exports and Google Sheets include them. Weekly summaries lead with the end goal: "This week: 312 accounts opened (+18%), ₦41.6m value, ₦4,180 per account opened."

The existing overview endpoints used by the dashboard's KPI tiles gain the end goal's completions and value, so the dashboard no longer hard-codes installs as the main outcome.

### B.7 Conversion sending
- `conversion_destinations.event_mappings` (change 02) gains goal keys as sources: `goal:account_opened → Meta "CompleteRegistration"` (or a custom event name), `→ Google conversion action "Account opened"`, `→ TikTok "CompleteRegistration"`.
- The goal's `platform_mappings` field holds the suggested default mappings shown in the UI; the destination's mapping is the one actually used.
- Send `value` and `currency` when the event has them. Send nothing extra when it doesn't. Duplicates (`already_counted_for_click`) and fraud-excluded events are never sent.
- Reversals: send Google conversion adjustments where supported (as change 03 does for refunds); log only for Meta and TikTok.
- Docs (`docs/GOALS.md`) explain that ad platforms optimise for the value they receive, and recommend sending a value that reflects real business worth, such as expected profit or 30-day value, rather than a gross amount that can be withdrawn.

### B.8 Webhooks and events
`goal.completed` (counted events only; payload: goal, value, currency, first_for_click, is_first_customer, link, campaign, clicked_at; the reference only outside private mode) and `goal.reversed`. Outbox events also feed referral qualification: rules can say "goal `first_deposit` with value ≥ ₦5,000", and the fraud model gets a "clicks or installs with no goal value" signal per source.

### B.9 Tests
- Value parsing: integers, decimals, numeric strings; too many decimals for the currency; zero-decimal currencies; negative; 16+ digits; currency default and override; currency ignored without a value; `value_mode` none/optional/required.
- Idempotency by `(goal, reference)` in and out of private mode; batch per-item results.
- `once_per_click` vs `every`; `first_for_click`; `is_first` stored as sent; code attribution; no-click unattributed.
- The goal window replaces the link window; end goal resolution link → campaign → organisation.
- Funnels: any-order and in-order completion; install-to-click linkage.
- Private mode: every disallowed field rejected with the field named and the value never logged (assert on captured logs); unknown fields rejected; SDK config flag; raw inbox not written for Paystack/Shopify/WooCommerce/inbound; debug view shows names only; hashed identifiers forced off; identity matching, identity checks and identity-token referrals return `409`; references stored only as HMAC; turning private mode off requires owner, typed confirmation and password.
- Conversion sending: goal mappings, value/currency present or absent, duplicates and fraud never sent, private mode never sends hashed identifiers.
- Analytics: FX conversion, cost per goal, value ROAS, medians, reversals subtract value.
- Backfill: `purchase`/`signup` goals created and old conversions linked; old `/v1/conversions` clients keep working unchanged.

### B.10 Backend milestones
1. **C5-B1** Goals table, settings, end-goal resolution, plan keys, goal events API, value/currency parsing, idempotency, reversals, counting modes, first-for-click, migration and backfill.
2. **C5-B2** Source mappings: app event rules, sales connections, inbound mappings, codes; `/v1/conversions` compatibility; conversion sending mappings; webhooks; referral qualification and fraud signal.
3. **C5-B3** Private mode: field allow-list enforcement everywhere, in-memory provider parsing, raw inbox disabled, scrambled references, feature conflicts, SDK config flag, private-mode report and PDF, audit and emails.
4. **C5-B4** Funnels, goals and funnel analytics, datasets registry, summaries, overview endpoints, tests, docs (`docs/GOALS.md`, `docs/PRIVATE_MODE.md`); regenerate `openapi.json`.

---

## S. SDKs (`sdks/`)

### S.1 All SDKs (Android, iOS, Flutter, React Native, web script)
- New method `goal(key, options)`:
  - Kotlin: `Clikgate.goal("account_opened", GoalOptions(value = BigDecimal("2000000"), currency = "NGN", reference = "APP-55231", isFirst = true))`
  - Swift: `Clikgate.goal("account_opened", value: 2_000_000, currency: "NGN", reference: "APP-55231", isFirst: true)` (`value` is `Decimal`)
  - Dart, TypeScript and the web script: the same names, with `value` as a number or numeric string.
- Uses decimal types (never floating point) for value on Android and iOS. Rejects locally what the server would reject (bad key format, negative value) and logs it in debug builds.
- Queued and retried like other SDK events; idempotent by `reference`.
- **Private mode:** reads `private_mode` from `/v1/sdk/config`. When on, `identify()`, user properties and event `properties` are not sent, and one debug warning is logged. `goal()` works normally.
- The web script's `goal()` sends with the stored click ID (the same cookie `paymentMetadata()` uses). For server-side completion, the docs show passing `Clikgate.getClickId()` into the business's own sign-up form so its backend can keep it (the "Keep the click ID" docs page, W.2).
- The AI-assistant setup guides and server SDKs come in change 06 and will document `goal()` from the start; nothing to add to guides here.

### S.2 SDK milestone
1. **C5-S1** `goal()` in all SDKs and the web script, private-mode handling, sample apps updated, SDK docs.

---

## F. Frontend (dashboard)

### F.1 Goals (`/[org]/settings/goals`; also linked from Measure)
- A list: name, key, value setting, currency, counting, window, status, last 30 days completions and value, and a "Journey end" badge on the organisation's end goal.
- **Create / edit:** name (the key is generated from it and editable before the first event), value (**No value · Optional · Required**), default currency (shown only with a value), counting (**Once per click** · **Every time** with helper text: "Use 'every time' for repeat purchases"), window (days), "Make this the end of the journey".
- **"How to send this goal"** panel with tabs: Your server (curl, Node, Python, PHP, Java with the exact JSON), App SDK, Paystack/Flutterwave, Shopify, WooCommerce, Webhook mapping, and a **Send test event** button (test mode) showing the result: counted, duplicate, or rejected and why.
- Archive with confirmation.
- Plan limits through the existing `plan_limit_reached` handling.

### F.2 End goal on links and campaigns
- Link create/edit and campaign create/edit gain **"End of journey"**: a goal picker defaulting to "Organisation default ({goal name})". The link detail page shows the effective goal and its source (link, campaign or organisation).

### F.3 Funnels (`/[org]/measure/funnels`)
- Builder: Click (fixed first step) → add steps (Install, App event, Goal) → the end goal last. Drag to reorder, 2–8 steps.
- Funnel report: horizontal funnel chart with counts, step conversion, drop-off and median time between steps, "Any order / In order" toggle, filters (date, campaign, channel, link, country, device).

### F.4 Goals report and dashboard overview
- A **Goals** report (`/[org]/measure/goals`): goal picker (default: end goal), KPI tiles (completions, value in the reporting currency, average value, cost per goal, value ROAS, median time to goal), a table grouped by the chosen dimension, a first vs repeat split, and an unattributed panel with reasons and fixes ("No click ID on 38% of Paystack payments: add `paymentMetadata()` at checkout").
- **Overview page:** the first KPI tiles become the **end goal** (labelled with its name, e.g. "Accounts opened") and its value, then cost per goal and ROAS, then clicks. Installs move to the Apps section and appear on the overview only for organisations with apps. The overview funnel uses the default funnel, or Click → End goal if none exists.

### F.5 Private mode (`/[org]/settings/privacy`, next to the consent settings from change 03)
- A card "Private mode" with a plain explanation:
  - **Clikgate will refuse:** names, emails, phone numbers, customer IDs, hashed identifiers and custom data.
  - **Still works:** clicks, installs, goals with value, funnels, ROAS, fraud protection, sending goals to ad platforms with their own click IDs.
  - **Turned off:** identity checks, identity-based matching, referral programs that need identity tokens, phone-based WhatsApp features.
- Turning on: owner only, with a confirmation dialog listing the effects. Turning off: owner, type "TURN OFF PRIVATE MODE", re-enter password.
- A **"Private mode"** badge in the app header while on.
- **Private mode report**: 30-day stats from B.5, with Download PDF.
- **Event debugger** (in Developers): shows recent goal events and rejections with the rejected field **names** and the fix.
- Plan gating: the `private_mode` key (Growth and up), with the plan-upgrade variant otherwise.

### F.6 Other screens
- Sales connections (change 03): a "Records goal" picker per connection.
- App event rules: "Record as goal" with an optional value property.
- Conversion sending destinations (change 02): goals listed as sources in the mapping table, with the suggested platform events.
- Referral program rules: goal and minimum value conditions.

### F.7 Tests and milestones
- Goal form validation and test-event results; end goal resolution display; funnel builder and report; goals report numbers and currency formatting; overview tiles use the end goal; private mode flows (owner-only, typed confirmation, badge, conflicts shown on disabled features, report download); plan gating.
1. **C5-F1** Goals settings and test events, end goal on links and campaigns, goals report, overview changes, the other screens (F.6).
2. **C5-F2** Funnels builder and report, private mode settings, report and badge, event debugger, tests; update `docs/PROGRESS.md`.

---

## W. Website (`clikgate-website`): show what Clikgate is

The home page from change 03 (W.4) leans on app installs. Clikgate is **measurement from click to the goal each business chooses** (an account opened, a loan disbursed, an order paid, a first trip), for apps, websites, WhatsApp and offline. Installs are one step for businesses with apps, not the main message. Update the site as follows. Change 03's honesty rules still apply.

### W.1 Home page changes
1. **Hero:**
   - Keep the headline "Know exactly what grows your business."
   - Subhead: "Measure every click to the result you care about — an order paid, an account opened, a loan disbursed — with attribution, deep links, referrals, WhatsApp and offline tracking, and fraud protection, built for Africa."
   - Add a line under the buttons: "Works for apps, websites, WhatsApp and offline."
   - **Dashboard mockup tiles in this order:** the goal (e.g. "Orders paid"), Revenue, ROAS, Cost per goal, Clicks, **Fake clicks & installs blocked**. Installs aren't a headline tile.
2. **New section after the channel grid, "From click to the goal you choose":**
   - Tabs by business type, each showing Click → steps → goal with example numbers:
     - Online shop: order paid;
     - Bank or fintech: account opened;
     - Lender: loan disbursed;
     - Insurance: policy bought;
     - Edtech: course paid;
     - App: first purchase.
   - Below it, the goal event JSON from B.2 with copy, and the line "Send it from your server, your app, or straight from Paystack, Flutterwave, Shopify or WooCommerce."
3. **"The full journey" section** (renamed **"See where people drop off"**): the funnel uses a goal as the last step and doesn't assume an app ("Click → Sign-up → KYC passed → Account opened"), with an app variant in a toggle.
4. **Use cases:** the **first** use case is a business without an app (an online shop or a WhatsApp seller measuring orders); app installs and deep links become one use case among the others.
5. **Fraud section** renamed "Stop paying for fake clicks and installs".
6. **New section "Private mode — measure without customer data"** (before the privacy and trust section):
   - For banks, insurers, lenders and health.
   - Three points: "Clikgate never receives your customers' names, emails, phone numbers or account numbers"; "Send only the goal, the click ID, your reference and, if you want, the value"; "Anything else is refused, not just ignored, and you get a report to prove it."
   - Link to `/products/private-mode` and the trust centre.
   - **Honesty:** don't say "no personal data at all". Clikgate still records click details such as country, device type and time (without full IP addresses). The page says this plainly in a "What Clikgate still records" note.

### W.2 New and updated pages
- **`/products/goals`** (Product menu: "Goals & funnels"): what goals are, value and currency, any source, funnels, first vs repeat, sending goals with value to Google, Meta and TikTok (value-based bidding explained simply: "without a value, ad platforms find more customers; with a value, they find better ones"), and the advice to send a value that reflects real worth.
- **`/products/private-mode`**: who it's for, exactly what is refused and what still works, how the click ID travels (the "Keep the click ID" diagram: click → the business saves the click ID with its own application → its server sends the goal days later), the private mode report, and a FAQ ("Is this zero personal data?" answered honestly).
- **Solutions pages:** add or update Banking & fintech, Insurance and Lending pages around goals and private mode. **Don't claim bank customers** unless real ones exist (change 03 honesty rules).
- **Pricing:** comparison rows for Goals (allowance), Goal values, Funnels and Private mode from the plans API, and an FAQ "What is a goal?".
- **Docs:** "Goals" (setup, the API, value rules, normal units not kobo, currency default, counting modes, reversals), "Keep the click ID" (web, app, server), "Private mode", and "Send goals to ad platforms".
- **Main navigation and meta:** product menu order puts Attribution & goals first, then Sales tracking, then Deep linking. The home meta description uses the new subhead.
- **Search the site** for copy that presents installs as the main outcome (e.g. "track installs" as a headline, KPI mockups led by installs) and change it to goals/outcomes, keeping install-specific wording on app pages.

### W.3 Milestone
1. **C5-W1** W.1–W.2, the Lighthouse and accessibility pass; update `docs/PROGRESS.md`.

---

## Definition of done
- An organisation defines its goals, picks the end of the journey (organisation, campaign or link), and receives the same goal from its server, its app, Paystack, Flutterwave, Shopify, WooCommerce or a webhook.
- Value and currency are optional, in normal units, defaulting to the goal's currency, and feed revenue, cost per goal, ROAS, funnels and value-based bidding on Google, Meta and TikTok.
- In private mode, Clikgate refuses every identity field and unknown field, stores references only scrambled, keeps no raw payloads, and proves it with a report, while goals, value, ROAS and conversion sending still work.
- The dashboard leads with the end goal, not installs, and the website presents Clikgate as measurement from click to the goal each business chooses, with private mode for regulated businesses and no exaggerated claims.

## Before building: things only the owner can provide
- A decision on whether Growth is the right minimum plan for private mode (A.3).
- Legal review of the private-mode wording on the website (what is and isn't collected) together with the Privacy Policy and DPA from change 03.
