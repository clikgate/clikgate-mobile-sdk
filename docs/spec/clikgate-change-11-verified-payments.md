# Workspace notes for Change 11 (read first; these override the spec body where they differ)

## Repository mapping
- `clikgate` (backend) is `clikgate_api`. It uses the legacy layout: code under `src/`, Alembic migrations.
  - The web script is `clikgate_api/src/static/clikgate.js`, served at `https://sdk.clikgate.com/v1/static/clikgate.js`.
  - The robot/canary is `clikgate_api/canary/`, with workflows in `.github/workflows/canary-*.yml`.
  - The change 03 WooCommerce plugin is `clikgate_api/integrations/woocommerce/clikgate-for-woocommerce/`. The
    spec's `integrations/wordpress/clikgate` is its new home; move it there.
  - Sales connections and providers are in `clikgate_api/src/sales/`, including Shopify.
- `sdks/` maps to two repos:
  - mobile SDKs (S.2) are in `clikgate_mobile_sdk`;
  - server SDKs (S.3) are in `clikgate_sdks/server`, with the shared conformance suite in `server/conformance`.
- `clikgate-dashboard` is `clikgate_frontend` (Next 15, BFF).
- `clikgate-website` is `clikgate_website` (pnpm monorepo, `apps/www`).

## Earlier changes and contracts
- Changes 01–10 are built. Their final backend contracts are in this scratchpad:
  - `c9-contract.md`;
  - `c10-contract.md`;
  - `fraud-hide-contract.md`, an owner follow-up that is in progress: fraud weights and thresholds are no
    longer public.
- **The Change 11 backend contract** goes in
  `/private/tmp/claude-501/-Users-user-Documents-PROJECTS-distyla-distyla-webapp/9dc4797d-093f-4e6a-b3ad-3a6c2d9efb08/scratchpad/c11-contract.md`.
  - The backend agent writes it, in the style of c10-contract.md.
  - A `STATUS: C11-Bn final` line means that milestone's section is final.
  - SDK, plugin, dashboard and website agents build against it.

## Owner decisions since Change 10
- The website has no changelog any more. Don't add changelog entries or links.
- Fraud weights, thresholds and exact limits aren't public. They are shown only to signed-in Growth+ customers.
- Legal pages show no "draft / legal review required" flag. Never add one.
- The iOS core SDK must stay at or under 410 KB (`ios/scripts/check_size.sh`). If it grows past that, trim code;
  never raise the budget.

## Gateways
- **Check official docs first (spec rule).** Use the web (WebFetch/WebSearch) to check each gateway's current
  official docs, and record the URL and date.
- **Only what the docs confirm.** Build only the routes the docs confirm. A gateway with nothing confirmed ships
  `disabled`, still with routes C–E.
- **No gateway accounts or keys.** None exist yet (an owner item). Test with recorded samples and test vectors
  built from the documented payloads, and with signatures made locally from made-up test secrets. Never call a
  real gateway in tests.

## Names
- Don't name Distyla or any real company as a customer. Use clearly fictional names.
- Payment gateway names are fine; they're integrations.

## House rules
- No git writes; the owner commits. The GitHub Actions in P.1 are files only: never push, create repos or
  generate real deploy keys.
- Never print secrets, keys, TOTP secrets or recovery codes. Never cat `.env` files, and don't create `.env` files.
- Don't migrate the owner's dev database `clikgate`; the coordinator does it. Test migrations on a scratch database
  on port 5433, then drop it.
- Run heavy commands one at a time through
  `/private/tmp/claude-501/-Users-user-Documents-PROJECTS-distyla-distyla-webapp/9dc4797d-093f-4e6a-b3ad-3a6c2d9efb08/scratchpad/heavy.sh`.
  This includes full test suites, builds, gradle, xcode, flutter and playwright. The machine has 16 GB.
- Don't kill processes you didn't start, and don't list processes with their arguments.
- Running services must stay up: the API on 8000 (`--reload`), redirect on 8100, the worker and ingest, the
  dashboard on 7010 and the website on 7020.
- Never run a bare `pnpm build` in `clikgate_website/apps/www`, because it wipes the live `.next/standalone`.
  Use a separate distDir.

---

# Clikgate Change 11 — Payments Reported by Websites and Apps, Confirmed by a Trusted Source (backend, SDKs, plugins, dashboard, website)

> **Instructions for the AI building this:**
> - Changes 01–10 are built (not yet deployed). This change lets a website or app **report** a payment and counts it only when a **trusted source confirms** it, without Clikgate ever holding a key that can move money. It also **removes** the "Connect with secret key" option from change 03.
> - **Backend repository** (`clikgate`, including `sdks/` and `integrations/`): sections A, B, S, P, milestones C11-B1 to C11-B5, C11-S1 to C11-S2, C11-P1 to C11-P2.
> - **Dashboard repository** (`clikgate-dashboard`): section F, milestones C11-F1 to C11-F2, after the backend part is deployed and the OpenAPI types are regenerated.
> - **Website repository** (`clikgate-website`): section W, milestone C11-W1.
> - Reuse: goals and value rules (change 05), the web key and `POST /v1/web/goals` (change 09 N.2), `POST /v1/sdk/goals` (change 09 N.4), sales connections, ingest endpoints, identity matching and refunds (change 03 B.6), the WooCommerce plugin and Shopify app (change 03), server SDKs (change 06), private mode (change 05), staff alerts (change 09), the robot (change 08), test mode.
> - **Check every gateway's current official documentation before building its adapter** — its verify/status API, whether it offers read-only (restricted) credentials, how its webhooks are signed (a separate webhook secret vs the API secret key), and its test mode. Record the source and date in `docs/DECISIONS.md` and in a gateway capability table (`docs/PAYMENT_GATEWAYS.md`). **A route the docs don't confirm is not built for that gateway; a gateway with nothing confirmed ships disabled.** Never guess an endpoint or a signature scheme.
> - **Hard rule: Clikgate never stores, requests or accepts a credential that can charge, refund, transfer or change anything at a payment gateway.** Only read-only credentials and webhook-only secrets. The API rejects anything else where it can tell (e.g. a Stripe key that isn't restricted).
> - Never log references with personal data, keys, webhook secrets or payload bodies. Run the full test suite after each milestone.

---

## A. Overview

### A.1 What this change does
1. **Payment confirmation is an option on a goal.** Goals with confirmation **None** (the default — every goal today) keep working exactly as now. Goals set to **Payment confirmed** use the new flow.
2. **Report:** after a payment succeeds, the website (`clikgate.payment(...)`, or automatic detection) or the app (`Clikgate.payment(...)`) tells Clikgate the gateway, the payment reference and the click ID — **never an amount**. The payment waits as *Waiting for confirmation*.
3. **Confirm:** a trusted source confirms the reference through one of five routes (B.3): a read-only key, a direct webhook with a separate webhook secret, the WordPress/WooCommerce plugin or Shopify app, a one-line server call after the business's own verification, or a forwarded webhook.
4. **Count:** Clikgate matches confirmation to report by reference, checks it, and counts the goal with **the confirmed amount and currency**.
5. **Remove** "Connect with secret key" for Paystack and Flutterwave (nothing deployed yet: delete the option and any stored keys).
6. **More gateways**, each built only with the routes its documentation confirms.
7. **The WordPress plugin grows** beyond WooCommerce to popular payment-form and donation plugins, with key-free connection.

### A.2 Not in scope
- Holding full secret keys for any gateway (by rule).
- Counting browser-reported payments without confirmation.
- Charging, refunding or moving money (Clikgate never does).
- A secure no-code route for **Paystack** businesses without WordPress, Shopify or a developer (Paystack offers no read-only keys and signs webhooks with its full secret key). The docs say this honestly.

### A.3 Who uses which route
| Business | Route |
|---|---|
| WooCommerce or another WordPress site | **C** — the Clikgate plugin, no code, no key |
| Shopify | **C** — the Clikgate app |
| Has a developer | **D** — one line after its own verification, or **E** — forward the webhook |
| Flutterwave, no developer | **B** — Flutterwave webhook to Clikgate with the secret hash |
| Stripe (and other gateways with read-only keys) | **A** — read-only key, or **B** — webhook signing secret |
| Paystack, no developer, not on WordPress or Shopify | No secure no-code route yet (A.2) |

### A.4 Plans
Payment confirmation is part of **sales tracking** (Starter and up; `sales_connections` allowances unchanged). Goals with confirmation None are unaffected on every plan.

---

## B. Backend

### B.1 Goal setting: confirmation
- Goals gain `confirmation`: `none` (default, today's behaviour) | `payment`.
- A `payment` goal must allow or require a value (change 05) and has a default currency. Its value always comes from the confirmation, never from the report.
- A `payment` goal can still be sent directly by the business's server with `goal()` (route D sends the confirmed result this way); browser-sent `goal()` calls (web key) are **refused** for `payment` goals (`422 payment_goal_needs_confirmation`), so a browser can never count a payment.
- Existing purchase goals stay `none` (no change for built integrations); the dashboard suggests switching purchase-type goals that are fed by browser reports.

### B.2 Payment reports (from websites and apps)
- **Website:** `POST /v1/web/payments` (web key, origin check, CORS, rate limits per key and IP — as change 09 N.2) `{provider, reference, click_id?, goal?, occurred_at?}`. The web script fills `click_id` from `_cg_{click_id_param}`.
- **Apps:** `POST /v1/sdk/payments` (SDK key) `{provider, reference, goal?}`; attribution from the installation's latest touch, as SDK goals.
- **Stored** as `payment_reports` (`prp_`): organisation, environment, provider, reference (stored scrambled in private mode, change 05), click ID or installation, goal, source (`web|app`), created_at, status (`waiting|verified|rejected|not_confirmed|refunded`), status_reason, matched_payment_id. **No amount is accepted.** Unknown fields are refused.
- One report per (organisation, provider, reference); repeats return the existing status.
- Without `goal`, the organisation's default payment goal is used (setting); if none, the report is refused with a fix message.
- The response tells the caller the status (`waiting`) — never "paid".

### B.3 Confirmations (trusted sources) — five routes
All routes produce a `payment_confirmations` record (`pcf_`): organisation, environment, provider, reference, status from the gateway (normalised: `success|failed|pending|reversed|refunded|partial`), amount and currency (from the gateway or the verified result), occurred_at, route (`read_only_key|direct_webhook|plugin|server_verified|forwarded_webhook`), connection, raw payload (encrypted, 14 days; not stored in private mode, change 05), received_at.

**A — Read-only key.** For gateways whose docs confirm read-only credentials (e.g. Stripe restricted keys with read permissions; Square OAuth read scopes and Adyen roles if the docs confirm read-only access). The connection stores the credential encrypted; when a report arrives, a worker calls the gateway's verify/status API for that reference (retrying with backoff while the gateway says pending, up to 24 hours). The connection setup **tests that the credential is read-only** where the gateway allows it (e.g. checks the key type or attempts a harmless forbidden write that must be refused) and refuses keys that can write. Stored in an isolated component whose only allowed calls are the gateway's read endpoints (enforced by an allow-list of request paths and methods in the adapter).

**B — Direct webhook with a separate webhook secret.** For gateways whose webhooks are signed with a secret that is **not** the API key (e.g. Flutterwave secret hash, Stripe endpoint signing secret, Square signature key, Adyen HMAC key — each confirmed from docs). The business points a webhook at `POST /v1/payments/webhooks/{provider}/{connection_id}`; Clikgate verifies the signature with the stored webhook secret and records confirmations and refunds. Gateways that sign webhooks with their full API secret (Paystack, Squad, Monnify and others) don't get route B. If the business already uses its gateway webhook for its own systems and the gateway allows only one URL, the dashboard recommends route D or E instead (Clikgate does **not** relay webhooks to the business).

**C — Plugins and apps.** The WordPress plugin (section P) and the Shopify app send the confirmed result after the business's own gateway plugin or Shopify has marked the order paid, signed with a plugin key that can only send payment results and goals. No gateway key is involved.

**D — Server one-liner after the business's own verification.** Server SDK helpers that take the gateway's own verified response and send it: `clikgate.payments.fromPaystack(verifyResponse)`, `fromFlutterwave(...)`, `fromMonnify(...)`, `fromStripe(...)` and a generic `clikgate.payments.confirm({provider, reference, status, amount, currency, occurredAt})`. Sent with a server API key (scope `conversions:write`). The helpers read only the fields needed and never send the whole response.

**E — Forwarded webhook.** The existing change 03 forward mode (`POST /v1/sales/ingest/{provider}` with a Clikgate API key) and the generic signed webhook and no-code mapper now also produce confirmations.

### B.4 Matching, checks and counting
- A matcher joins confirmations and reports on (organisation, environment, provider, reference), whichever arrives first.
- **A payment is counted only if all hold:** the confirmation came through an authenticated route of that organisation; normalised status is `success` (or `partial` is treated as rejected unless the goal allows partial — default not); amount > 0 and currency valid; the reference hasn't been counted before; the confirmation arrives within **24 hours** of the report (or the report within 24 hours of the confirmation); the report is within the goal's attribution window of the click.
- **Counted** → a goal event with `source = payment`, the confirmed amount and currency, `reference` (scrambled in private mode), the click or installation from the report, linked to both records; all downstream features use it (reports, ROAS, referral rules, challenges, ad-platform and GA4 sending, webhooks `goal.completed`).
- **Report without confirmation** after 24 hours → `not_confirmed` (not counted), with a reason and setup tips.
- **Confirmation without report** (closed tab, ad blocker, payment link outside the site) → matched by click ID in the gateway metadata if present, then by scrambled email or phone (change 03 identity matching, off in private mode), else **unattributed revenue** with a fix hint. Counted as today's sales are.
- **Refunds and reversals** through any route → goal reversal (full or partial).
- New webhooks: `payment.verified`, `payment.rejected`, `payment.not_confirmed`, `payment.refunded` (with reference masked as configured).

### B.5 Removing "Connect with secret key"
- Delete the `connect` mode for Paystack and Flutterwave from the sales connections code, API (`422 mode_not_supported` if sent), polling worker and docs.
- A migration deletes any stored secret keys (`credentials_enc` for those connections) and converts those connections to `forward` mode with a note; staff and owners of test organisations get an in-app notice.
- A CI check fails if any adapter declares a credential type that can write.

### B.6 Gateways
Build an adapter per gateway with only the routes its docs confirm (B.3), plus routes C–E which work for all. Record capabilities in `docs/PAYMENT_GATEWAYS.md` and expose them at `GET /v1/payment-gateways` (provider, name, countries, routes available, read-only credential type if any, webhook secret type if any, test mode support, status `enabled|disabled`).
| Region | Gateways |
|---|---|
| Nigeria and West Africa | Paystack, Flutterwave, Monnify, Squad, OPay, Interswitch, Remita, Korapay, Paga, Moniepoint, Hubtel (Ghana) |
| East Africa | M-Pesa (Daraja), Pesapal, MTN MoMo, Airtel Money |
| Southern Africa | Yoco, PayFast, Peach Payments, DPO Pay |
| Global | Stripe, PayPal, Adyen, Square, Checkout.com |
- Start with Paystack, Flutterwave and Stripe (C11-B3), then the rest (C11-B4). A gateway whose routes A and B aren't confirmed still appears with routes C–E.

### B.7 Security
- Web and SDK reports: origin and key checks, rate limits, duplicate protection, refusal of amounts and unknown fields.
- Only read-only credentials and webhook-only secrets are stored (encrypted, never shown again, never logged); adding or changing one needs a fresh two-factor code (change 09 N.3); every use is audit-logged and visible to the organisation; owners are reminded yearly to rotate them.
- Route A adapters can only call allow-listed read endpoints.
- A reference confirmed for another organisation can never match (all matching is per organisation; route A verifies with that organisation's own credential).
- Private mode: references scrambled, raw payloads not stored, identity matching off.

### B.8 Tests
- `none` goals unchanged across every source; `payment` goals refuse browser `goal()`.
- Reports: web key/origin, SDK, no amounts, duplicates, default goal.
- Each route: A (read-only check, allow-list, retries), B (signature, refunds), C (plugin key scope), D (helpers per gateway, generic confirm), E (forward and mapper).
- Matcher: either order, 24-hour windows, attribution window, partial and failed, duplicates, not confirmed, confirmation without report (metadata, identity, unattributed), refunds, private mode.
- Removal of connect mode and key deletion migration; CI write-credential check.
- Gateway capability endpoint and disabled gateways.

### B.9 Backend milestones
1. **C11-B1** B.1 goal confirmation setting, B.2 reports (web and SDK endpoints), tables, tests.
2. **C11-B2** B.3 routes C–E (plugins key scope, server helpers' API, forward and mapper produce confirmations), B.4 matcher, counting, statuses, webhooks, tests.
3. **C11-B3** B.5 removal and migration; gateway adapters with docs-confirmed routes A/B for **Paystack, Flutterwave and Stripe**; `docs/PAYMENT_GATEWAYS.md`; capability endpoint; tests.
4. **C11-B4** Remaining gateways in B.6 (each only with confirmed routes), tests.
5. **C11-B5** B.7 security review items, robot weekly check (R.1), docs (`docs/PAYMENTS.md`), regenerate `openapi.json`.

---

## S. SDKs (`sdks/`)

### S.1 Web script
- `clikgate.payment({ provider, reference, goal? })` — the **recommended** one line, called in the gateway's success callback; returns a promise resolving to `{status: "waiting"}`; never throws into the page.
- **Automatic detection (optional, off by default):** `data-clikgate-payments="auto"` on the script tag. For gateways whose browser checkout library exposes a documented success callback or event, the script listens for it and calls `clikgate.payment` itself. Documented as "may stop working if the gateway changes its checkout; the one-line call is recommended". Supported list from `GET /v1/payment-gateways`.
- Uses the web key (change 09). No amounts are ever read from the page.

### S.2 Mobile SDKs (Android, iOS, Flutter, React Native)
- `Clikgate.payment(provider, reference, goal = null)` after the gateway's mobile checkout reports success; queued and retried like goals; no amounts.

### S.3 Server SDKs (Node.js, Python, PHP, Java, .NET)
- `payments.fromPaystack(verifyResponse)`, `fromFlutterwave`, `fromMonnify`, `fromStripe` (and others as adapters are confirmed) and `payments.confirm({...})`; they extract only reference, status, amount, currency and time; private-mode guards apply. Docs show where to call them: right after the business's own verification.

1. **C11-S1** S.1 web script (one line and automatic detection), S.2 mobile SDKs, tests.
2. **C11-S2** S.3 server SDK helpers in all five languages with the shared conformance suite, docs.

## P. WordPress plugin (`integrations/wordpress/clikgate`)

- Grows from the WooCommerce plugin into **"Clikgate for WordPress"** (WooCommerce support kept).
- **Connect without copying keys:** "Connect to Clikgate" in WordPress admin starts the device sign-in flow (as the setup command, change 06): the admin approves a short code in the Clikgate dashboard; the plugin receives a **plugin key** that can only send payment results and goals and read its own settings.
- **Adds the web script** to the site automatically (no theme editing), with the web key.
- **Payment confirmations from other plugins:** hooks into the confirmed-payment step of popular payment-form, donation and booking plugins that take Paystack, Flutterwave and other gateway payments. The builder lists candidate plugins, checks each one documents a reliable "payment completed/verified" hook, and supports only those (recorded in `docs/WORDPRESS.md`). Each confirmation carries the click ID from the cookie.
- **Settings:** which goal each form, product or plugin records; a "Send a test" button; a status panel showing the last results.
- Requirements: WordPress and PHP versions the builder confirms as current; works with caching plugins (no server-side page changes beyond the script tag).

### P.1 Publishing (public repo and WordPress.org)
- **Source of truth stays in this repo** (`integrations/wordpress/clikgate`); the plugin and its tests change in the same commits as the API.
- **Public read-only repo `clikgate/clikgate-wordpress`:** a GitHub Action runs on tags `wordpress-v*` (e.g. `wordpress-v1.0.0`); it splits only the `integrations/wordpress/clikgate` folder with its history (subtree split, as change 06 does for `clikgate-php`), pushes it to the public repo's `main` with a **deploy key that has write access to that one repo only** (secret `WORDPRESS_PUBLIC_REPO_DEPLOY_KEY`), and pushes the same version tag. Nothing outside that folder is ever pushed; the action fails if the split contains any other path. The public repo gets a README note ("Developed in Clikgate's main repository; please open issues here, pull requests are closed automatically") and a small action that closes pull requests with that message.
- **WordPress.org release:** on the same tag, after the plugin is approved, an action deploys to the WordPress.org SVN repository (trunk + `tags/{version}` + assets such as banner, icon and screenshots from `integrations/wordpress/clikgate/.wordpress-org/`) using secrets `WPORG_SVN_USERNAME` and `WPORG_SVN_PASSWORD` (the SVN password generated in the WordPress.org profile, not the login password). Until the approval arrives (`WPORG_ENABLED` repository variable not set), this job is skipped with a notice.
- **Checks before either push:** plugin tests, PHP lint on the supported versions, WordPress Plugin Check, and that the version in the plugin header, `readme.txt` "Stable tag" and the git tag all match.
- **First submission** to WordPress.org is done by the owner (upload of the zip the action builds as a release artifact); later releases are automatic.
- `docs/WORDPRESS.md` lists the owner's one-time setup in plain steps: create the empty public repo, add the deploy key (the builder generates the key pair and gives the owner the two halves: public half → public repo Settings → Deploy keys with "Allow write access"; private half → main repo Actions secret), submit the plugin once, then add the two WordPress.org secrets and set `WPORG_ENABLED`. Keys are never committed or printed in logs.

1. **C11-P1** Plugin rename and structure, device sign-in, plugin key, automatic script, WooCommerce kept, tests.
2. **C11-P2** Integrations with the confirmed payment plugins, settings, test button, `docs/WORDPRESS.md`, P.1 publishing actions (public repo split and WordPress.org deploy) and the first-submission zip (owner submits).

## R. Robot (change 08)
- **R.1** Weekly: a test-mode payment through route D (server helper) and route B (Flutterwave or Stripe test webhook) with a matching web report; checks it becomes Verified with the confirmed amount.

---

## F. Dashboard

### F.1 Customer screens
- **Goal settings:** "Confirmation" — **None** (default; "count this goal when it's sent") or **Payment confirmed** ("count only when a trusted source confirms the payment; the amount comes from the payment"), with a short explanation and a link to set up a payment connection.
- **Integrations → Payments:** a gateway picker (from `GET /v1/payment-gateways`); for each gateway, the routes it supports in order from most secure to most convenient, each with its setup checklist:
  - read-only key (with the gateway's steps to create one and Clikgate's check that it's read-only);
  - direct webhook (URL, where to paste it in the gateway, the webhook secret field);
  - WordPress plugin / Shopify app (install links);
  - server one-liner (code tabs in five languages);
  - forward the webhook (URL and snippet).
  For Paystack the screen states plainly: "Paystack doesn't offer read-only keys, so Clikgate never asks for your Paystack key. Use the WordPress plugin, the Shopify app, or one line on your server."
- **Payments activity:** each reported and confirmed payment with status (Waiting, Verified, Rejected with reason, Not confirmed, Refunded), route, goal, amount (once confirmed), click and channel; filters; a "Not confirmed" panel with fixes.
- Website setup snippet shows `clikgate.payment(...)` for payment goals and the automatic-detection option.

### F.2 Staff console
- Gateway capability table (read-only view) and per-organisation payment connections (routes, last confirmation, errors), without ever showing credentials.

1. **C11-F1** F.1 goal setting, Integrations → Payments with every route, Paystack message, tests.
2. **C11-F2** Payments activity and not-confirmed panel, staff view, tests; update `docs/PROGRESS.md`.

---

## W. Website (`clikgate-website`)
- **Integrations / sales tracking pages:** "Track payments without touching your server" — how the report-and-confirm flow works (a small diagram), the routes, the gateway list from the capability endpoint, and the honest limits (Paystack without WordPress/Shopify/developer; confirmation needed; Clikgate never holds keys that can move money).
- **Docs:** "Payment goals", "Reporting payments from your website and app", a page per gateway with its confirmed routes, "Clikgate for WordPress", and the server helpers in all languages.
- **Trust centre:** "Clikgate never holds a key that can move your money."
- `llms.txt`: the new pages.
1. **C11-W1** The above; Lighthouse and accessibility checks; update `docs/PROGRESS.md`.

---

## Definition of done
- Goals with confirmation None work exactly as before; payment goals count only after a trusted confirmation, with the confirmed amount.
- Websites and apps report payments with one line (or automatic detection on websites); nothing counts from the browser alone.
- Every gateway offers routes C–E; routes A and B exist only where the gateway's docs confirm read-only credentials or separate webhook secrets.
- "Connect with secret key" is gone and no secret key remains stored.
- The WordPress plugin connects without copying keys and confirms payments from WooCommerce and the supported payment plugins.
- The robot proves the flow weekly; the website explains it honestly.

## Before building: things only the owner can provide
- Test accounts for Paystack, Flutterwave and Stripe (and any other gateway to be enabled first).
- A WordPress.org account for publishing the plugin, and its SVN password (after approval).
- An empty public repository `clikgate-wordpress` in the `clikgate` GitHub organisation, and the deploy key added as described in `docs/WORDPRESS.md`.
- Approval of the Paystack limitation wording on the website.
