# Clikgate Change 09 — Consistency Fixes, App Subdomains, Web Goals, Customer Two-Factor Sign-in, Leaderboard Trophies and Challenges (workspace copy)

> **Workspace notes (these override the spec below where they differ)**
> - **Repositories:**
>   - `clikgate` means `clikgate_api`: backend `src/`, plus the edge Workers in `edge/` and `canary/`.
>   - `clikgate-dashboard` means `clikgate_frontend`, which holds both the customer dashboard and the staff console.
>   - `clikgate-website` means `clikgate_website/apps/www`.
>   - The mobile SDKs and the `@clikgate/setup` command (`cli/`) are in `clikgate_mobile_sdk`.
>   - The server SDKs and AI guides are in `clikgate_sdks`.
>   - Paths written `app/...` mean clikgate_api's `src/...`; for example, `python -m app.internal.mark` is `python -m src.internal.mark`.
> - **State:**
>   - Changes 01–08 are built.
>   - The migration head is `2026_11_02_0038`.
>   - After Change 08:
>     - **Cross-promotion was removed from the dashboard** (owner decision, 2026-10-27). F.4's "only cross-promotion stays deferred" therefore becomes "nothing stays deferred from that list". Don't bring cross-promotion back.
>     - The dashboard has ⓘ feature-help panels (`src/shared/config/feature-help.ts` plus `feature-help.en.json`) linking to clikgate.com docs pages. New features in this change get a help id, panel content and a docs slug.
>     - The canary setup already writes secrets straight to GitHub and Worker secrets (X.S16: check, it's probably already done).
>     - `scripts/seed.py` puts demo links on `clk.ng` and skips the custom domain on Free (X.H6: give the demo organisation a plan instead).
> - **Design references:** the spec names `docs/design/clikgate-hero-click-map.png` and `.html`. **They don't exist in the repo.** Build the click map from the written description. The owner can drop the files in later for a visual check.
> - **Owner-only items:**
>   - **The `*.dev.ciz.to` certificate:** research the price and options, and record them. **Do not buy anything.**
>   - **The subdomain blocklist:** ship a starter list in config.
> - **House rules:**
>   - Never run git commit or any other git write.
>   - Never print secrets.
>   - On this 16 GB machine, run every heavy step through the scratchpad `heavy.sh`, one at a time.
>   - Never create a `.env` in distyla_api.
>   - Don't kill processes you didn't start, and don't list processes with their arguments.
> - **Local production servers are running:**
>   - API: 8000, redirect: 8100, the worker and ingest.
>   - Dashboard (production build): 7010.
>   - Website (production build): 7020.
>
>   Tests and e2e use other ports and their own test databases. The owner's local dev database `clikgate` on port 5433 is migrated by the coordinator, not by agents.

---

# Clikgate Change 09 — Consistency Fixes, App Subdomains, Web Goals, Customer Two-Factor Sign-in, Leaderboard Trophies and Challenges (backend, SDKs, dashboard, website)

> **Instructions for the AI building this:**
> - Changes 01–08 are **already built**. This change comes from an independent review of every spec. It (1) adds four owner decisions as new features, and (2) settles places where earlier specs disagreed. **Where this file and an earlier spec disagree, this file wins.**
> - **Check before you change.** For every item in sections X and H: read the current code first. If the code already behaves as this file says, write "already done" against the item ID in `docs/PROGRESS.md` and move on. If it doesn't, fix it, with a migration where data changes, and tests. Never rebuild working features from scratch.
> - **Backend repository** (`clikgate`): sections N (N.1–N.6) and X, milestones C9-B1 to C9-B8.
> - **Dashboard repository** (`clikgate-dashboard`): section F, milestones C9-F1 to C9-F5, after the backend part is deployed and the OpenAPI types are regenerated. Update the repository's `.claude/skills/clikgate-api-integration/SKILL.md` as F.4 says.
> - **Website repository** (`clikgate-website`): section W, milestone C9-W1.
> - Check current official documentation before building N.1 (Apple associated domains and AASA, Android App Links and `assetlinks.json`, Cloudflare certificates for `*.ciz.to` and `*.dev.ciz.to`) and N.3 (RFC 6238 TOTP). Record findings and dates in `docs/DECISIONS.md`.
> - Never log secrets, TOTP secrets, recovery codes, API keys, web keys, SDK keys or private-mode references. Run the full test suite after each milestone.

---

## D. Owner decisions (2026-10-27)

| # | Decision |
|---|---|
| D1 | **App links use a per-app subdomain** (for example `yourapp.ciz.to`) or the customer's own domains. Customer apps never claim app links on the shared domains `ciz.to`, `clk.ng`, `clkg.to` or `dev.ciz.to`, because one organisation's link could open another organisation's app. (N.1) |
| D2 | **Web goals use a publishable web key** that only works from the organisation's verified websites. Browser goals are marked "from browser". (N.2) |
| D3 | **Customer two-factor sign-in now:** optional authenticator for everyone, organisations can require it, required by default for regulated organisations. (N.3) |
| D4 | **Internal organisations are treated as customers:** Clikgate's own organisation and the canary organisations hold normal paid subscriptions recorded by staff (no complimentary plans). (X.P5) |
| D6 | **Leaderboard trophies:** a board can have a trophy target; the default trophy type is **"Everyone who reaches it"**, and each organisation can change its default and each board's type ("First N to reach it"). The dashboard shows a **progress-bands** view. **No pace estimates** ("about N days to go") anywhere. (N.5) |
| D7 | **Challenges:** marketing can create time-boxed referral challenges at any time (scheduled start and end, their own score, rules, trophy and prize), several at once. Plan limit counts challenges **live or scheduled at the same time** (Growth 2, Pro and Enterprise unlimited; past challenges unlimited). Everyone eligible takes part **automatically** by default; a challenge can be set to "only people who join". (N.6) |
| D8 | **Server API and webhooks only for leaderboards and challenges.** Clikgate **never messages participants** (no WhatsApp, SMS, email or push to referrers); it sends webhooks to the organisation, which decides what to tell its users. Trophy, challenge and progress data are **not added to any mobile SDK** (core or Engage): businesses read them from their own server through the API and show them in their own screens. The Engage leaderboard endpoints already built (growth spec 5.2) stay as they are but get no new fields, and docs recommend the server API. (N.5, N.6) |
| D9 | **Clikgate is for every business and organisation, not a bank platform.** Customer-facing words are "businesses", "organisations" and, where strict rules matter, "regulated businesses" or "organisations with strict security and privacy needs". Banks appear only as one use case among many. (W, F.1) |
| D10 | **"Short links" becomes the first item in the website header**, before Product, with its own page at `/short-links` in the style of a modern link-shortener homepage (inspired by the structure of sites like Bitly, built entirely in Clikgate's own brand, copy and components). This replaces change 03's rule that the short-links page is never reached from the header or hero. (W) |
| D11 | **Solutions are organised three ways — by industry, by team and by stage of growth** — with Clikgate's own names, layout and wording, and every solution page uses one rich, informative template. Replaces the change 03 Solutions list and change 05's separate Banking, Insurance and Lending pages (now one Financial services page). (W) |
| D12 | **New home page hero illustration, the "click map".** The current one (channels flowing into one Sign-up → Order paid box) looks like generic analytics and hides what Clikgate does: it merges every channel into one total, so it never shows **which channel earned the result** — the core of attribution. The new one keeps each channel's path visible to the result, and shows the link, the app opening, fraud removal, the goal, results per channel and the results sent back. (W) |
| D5 | Defaults chosen by the owner's advisor and accepted unless the owner says otherwise: live destinations are always `https` (X.L6); identity checks are hard-capped with no overage (X.P2); the `api_requests_per_month` meter is dropped (X.P3); the iOS pasteboard match is off by default (X.E13); no IDFA matching (X.E14). |

---

## N. New features

### N.1 Per-app link subdomains (D1)
- **Field:** `apps.link_subdomain` — 3–30 characters, lowercase letters, digits and hyphens, not starting or ending with a hyphen, unique across Clikgate. Reserved: `www`, `api`, `app`, `apps`, `dev`, `test`, `staff`, `status`, `mail`, `email`, `admin`, `docs`, `cdn`, `static`, `sdk`, `edge`, `canary`, `link`, `links`, `go`, `help`, `support`, `clikgate`, plus a configurable blocklist of brand names and offensive words. Suggested from the app name at creation; editable by the organisation **until the first link uses it**; afterwards only staff can change it (🔐, audit-logged, old hostname keeps redirecting for 180 days).
- **Hostnames:** live `{link_subdomain}.ciz.to` (organisations on a paid plan or verified; Free organisations have no app attribution), test `{link_subdomain}.dev.ciz.to`. Wildcard DNS `*.ciz.to` and `*.dev.ciz.to` proxied by Cloudflare. **Certificates:** `*.ciz.to` is a first-level wildcard; `*.dev.ciz.to` is second-level and may need an extra Cloudflare certificate product — check the current options and price, record them, and ask the owner before buying.
- **Well-known files:** on an app subdomain, `apple-app-site-association` and `assetlinks.json` list **only that app** with all paths (`/*`, excluding `/_t/*`, `/_f/*`, `/_cg/*`). On the shared domains (`ciz.to`, `clk.ng`, `clkg.to`, `dev.ciz.to`) they list **no customer apps**.
- **Links:** an organisation's links can use any of its hostnames. Links with app routing default to the app's subdomain (`yourapp.ciz.to/summer`); the domain picker shows it first with "Opens your app directly". Slugs are unique per hostname. On shared domains, links to apps still work through the redirect, the store and deferred deep links — just without opening the app directly.
- **Setup command and AI guides** (change 06 S.3/S.4): release builds add `applinks:{link_subdomain}.ciz.to` and the organisation's verified custom domains; debug builds add `applinks:{link_subdomain}.dev.ciz.to`. Never a shared domain. `doctor` checks the app subdomain's files contain the app, and warns if a project still lists `applinks:ciz.to`, `clk.ng`, `clkg.to` or `dev.ciz.to` ("remove this: shared domains can't open your app").
- **Backup redirects** (change 08): the edge Worker's routes include `*.ciz.to/*`; KV keys use the full hostname; each app subdomain gets its `_domain` entry with its well-known files.
- **Custom domains** keep working as today (one app or several per custom domain, as change 06 allows).
- **Migration:** existing apps get a suggested `link_subdomain` (not yet confirmed); the dashboard asks the organisation to confirm it. Nothing has launched, so remove customer apps from the shared domains' well-known files immediately.

### N.2 Publishable web key and browser goals (D2)
- **Web keys:** each organisation gets one live and one test **publishable web key** (`cgw_live_…`, `cgw_test_…`), shown in the web script snippet. It is not secret, can only send browser goals and read the web script config, and is not an API key (snippets still never contain API keys). Rotate from Settings → Developers.
- **Allowed origins:** live key — the organisation's verified websites (change 06 site verification) and their subdomains; test key — verified websites plus `localhost`, `127.0.0.1` and verified tunnels.
- **Endpoint:** `POST /v1/web/goals` on `sdk.clikgate.com`, header `Clikgate-Web-Key`, CORS limited to allowed origins, body `{goal, reference?, value?, currency?, is_first?, click_id?, consent?}`. The web script fills `click_id` from its stored cookie (`_cg_{click_id_param}`).
- **Checks:** origin must match; rate limits per key and per IP; the goal must exist and have **"Allow from browser"** switched on (new goal setting, default off; dashboard explains "Browser goals can be faked by visitors; use your server for payments"); optional per-goal maximum browser value; private-mode allow-list applies.
- **Stored** with `source = web` and `trust = browser`. Reports and exports show "From browser". Organisations choose per destination whether browser goals are sent to ad platforms and GA4 (default: sent, as pixels do).
- **Web script:** `clikgate.goal(key, {reference, value, currency})` uses the web key. Without a web key in the snippet, `goal()` logs a console warning and does nothing.

### N.3 Customer two-factor sign-in (D3)
- **Authenticator (TOTP, RFC 6238):** enrolment shows a QR code and secret, confirms one code, then shows **10 recovery codes** once (stored hashed, single use). Same verification rules as staff (change 01): ±1 step, no reuse of a step, lock for 15 minutes after 5 failed codes, rate limit per IP, constant-time compare. Secrets encrypted at rest.
- **Sign-in:** password, then code (or a recovery code). No "remember this device" in this version.
- **Organisation setting** `security.require_two_factor` (owners and admins; **on by default for regulated organisations**, can only be switched off there with a fresh code). When on, members without an authenticator must enrol at their next sign-in before seeing the organisation.
- **Fresh code for sensitive actions** (code entered in the last 10 minutes): creating or revealing API keys and web keys, changing members' roles or removing members, connecting or removing domains, changing link-safety settings, turning private mode off, deleting the organisation, changing the sign-in email, turning two-factor off.
- **Lost authenticator:** use a recovery code; otherwise staff reset it (🔐) after the documented identity check in `docs/RUNBOOK.md`; the user and the organisation's owners get an email; audit-logged. A password reset never removes two-factor.
- **Device sign-in for the setup command** (change 06) asks for the code when the user has two-factor.
- **Canary users** (change 08) enrol an authenticator; their TOTP secrets go into the robot's secrets (as change 08 originally said). API keys are unaffected.
- **Emails:** "Two-factor turned on/off", "New recovery codes created", "Two-factor reset by Clikgate support".

### N.4 Goals APIs that the SDKs and dashboard need (X.E2, X.E3)
Check the code; add whatever is missing:
| Method | Path | Notes |
|---|---|---|
| POST | `/v1/sdk/goals` | Mobile SDKs (SDK key). Body as `/v1/goals/events` minus `click_id`; attribution from the installation's latest touch; same queueing and rate limits as `/v1/sdk/events`; private-mode allow-list applies |
| POST · GET | `/v1/goals` | Create and list goals. Writes `org:manage`, reads `analytics:read`. Key editable until the first event |
| GET · PATCH | `/v1/goals/{key}` | Includes `allow_from_browser`, `max_browser_value` (N.2) |
| POST | `/v1/goals/{key}/archive` | |
| POST · GET · PATCH · DELETE | `/v1/funnels`, `/v1/funnels/{id}` | |
| PATCH | `/v1/organization/settings` | Gains `end_goal_key`, `reporting_currency` |
| POST | `/v1/organization/private-mode/enable` · `/disable` | Owner only; disable needs `{confirmation: "TURN OFF PRIVATE MODE", password}` and a fresh code (N.3) |
| — | Link and campaign create/update | Gain `end_goal_key` |

### N.5 Leaderboard trophies and the trophy view (D6)
Extends growth spec 9A. Leaderboards stay a Growth-and-up feature.
- **Trophy on a board:** `leaderboards.target` (nullable jsonb): `{score, label, prize_text?, mode: "everyone" | "first_n", n?}`.
  - `score` is an integer for count metrics, or a decimal string in normal units (with the board's currency) for value metrics.
  - `label` example: "First to 50 qualified referrals"; `prize_text` is free text shown to staff and, if the board is public, to participants. Clikgate never pays prizes.
  - `mode` defaults to the organisation setting `leaderboards.default_target_mode` (new; default **`everyone`**); `first_n` needs `n` ≥ 1 (default 1).
  - Changing the target applies from the next period, like metric changes.
- **Winners:** table `leaderboard_target_winners` (`lbw_` IDs): leaderboard, period_key, segment, referrer, reached_at, score_at_reach, status (`provisional|final|revoked`).
  - A person reaches the trophy when their score (good-standing referrals only, as today) first meets the target. `everyone`: all who reach it win. `first_n`: the first N by `reached_at`, ties broken as in the ranking.
  - If a reversal drops a provisional winner below the target before the period is final, the win is `revoked` (and in `first_n`, the next person who had reached it moves up). At finalisation, winners become `final` and later reversals are listed in `post_final_changes` (as 9A.3).
  - Webhooks `leaderboard.target_reached` and `leaderboard.target_revoked`; `leaderboard.period_finalized` includes the winners.
- **Goals as the score:** new metric `{"type": "goal", "goal_key": "first_deposit", "measure": "count" | "value", "currency": "NGN"}`.
  - Credits a referrer when a **counted** goal (change 05) is attributed to one of their referees or to a click on their referral link. Reversed goals remove the credit.
  - `value` totals use normal units; goals in another currency are converted with the exchange-rate source from change 02 at the goal's time and labelled "converted". Redis scores store minor units.
  - Works in private mode (goal value is allowed there).
- **Progress and bands** (computed by the backend, not the client): `progress_pct = min(100, floor(score ÷ target × 100))`; `gap_to_target = max(0, target − score)`. Bands: **Reached** (winners), **Almost there** 90–99%, **Close** 75–89%, **On the way** 50–74%, **Started** 1–49%. Pending referrals are shown separately ("+3 pending") and never counted in progress.
- **API additions:**
  | Method | Path | Notes |
  |---|---|---|
  | GET | `/v1/leaderboards/{id}/trophy` | `?period=&segment=` → `{target, winners[], bands:[{key, label, min_pct, max_pct, count, entries}]}`; Reached, Almost there and Close include up to 100 entries each, lower bands return counts plus the first 20 |
  | GET | `/v1/leaderboards/{id}/entries` | Gains `?band=` and per entry `progress_pct`, `gap_to_target`, `band`, `reached_at` |
  | GET | `/v1/leaderboards/{id}/referrers/{referrer_id}` | Gains `progress_pct`, `gap_to_target`, `reached_at`, a breakdown of the score by step or goal, pending, adjustments, and the last 50 scoring events (time, what happened, points, masked referee) |
  | PATCH | `/v1/organization/settings` | Gains `leaderboards.default_target_mode` |
- **Never** calculate or return pace, projected finish or "days to go".
- Privacy as today: opted-out and fraud-flagged people are excluded; the optional hosted page uses masked names; fraud flags appear only in the dashboard detail.
- The optional hosted leaderboard page (9A.7) can show the trophy view with masked names.
- **Tests:** trophy reached and revoked, `everyone` vs `first_n` with ties, next-in-line promotion, finalisation, goal metric count and value with reversals and currency conversion, band boundaries (0, 49, 50, 74, 75, 89, 90, 99, 100%), pending not counted, opt-out and fraud exclusion, hosted-page masking, no pace fields anywhere in responses.

### N.6 Challenges (D7)
A **challenge** is a leaderboard with a fixed start and end, created whenever marketing needs one. It reuses everything in 9A and N.5 (ranking, trophy, winners, progress bands, finalisation). Referral links and codes never change between challenges.
- **Data:** `leaderboards` gains `kind` (`board` | `challenge`, default `board`), `starts_at`, `ends_at` (in the board's timezone), `participation` (`automatic` | `opt_in`, default **`automatic`**), `eligibility` (`{"type": "all"}` or `{"type": "group", "by": "country" | "attribute:<key>", "values": [...]}`), `rules` (below), `prize_cost` (optional amount and currency entered by the business, for results only), `template_key`, `cloned_from_id`, `cancelled_at`, `cancel_reason`. A challenge has exactly one period (`period_key = "challenge"`).
- **Lifecycle:** `draft` → `scheduled` → `live` (at `starts_at`) → `ended` (at `ends_at`: provisional snapshot) → `final` (after the finalise delay, 9A.3); or `cancelled` (no winners). Worker `challenge_scheduler` runs every minute. `starts_at` must be in the future when scheduling; minimum length 1 hour, maximum 366 days.
- **Editing:** drafts and scheduled challenges are fully editable. Once live: name, description and prize text can change, and the end can be **extended** (never shortened); score, rules, trophy and eligibility are locked, so the contest stays fair. Cancelling a live challenge needs a reason and notifies participants through the webhook.
- **What counts:** only scoring events whose time falls between `starts_at` and `ends_at`, from referees of eligible participants. Referees who joined before the challenge still count when their goal happens inside the window, unless the rule `new_referees_only` is on.
- **Rules on existing goals** (so marketing can run new challenges without developers): for goal scores — `min_value` (with currency), `first_per_customer` (the referee's first ever event of that goal), `campaign_ids`, `link_ids`, `sources` (for example `whatsapp`, `qr`, `sdk`, `web`), `exclude_browser_goals` (N.2); for any score — `new_referees_only`, `min_referee_age_days`. Rules are evaluated when an event is credited and in the nightly reconciliation. The API rejects rules that reference archived goals or other organisations' campaigns.
- **Participation:** `automatic` — every eligible referrer is in. `opt_in` — only referrers who join (`challenge_participants`: challenge, referrer, joined_at, source `api|dashboard`); points count only from the moment they joined. People who opted out of leaderboards are never included.
- **Templates:** built-in — "First deposits race" (goal count, first per customer), "Top sellers this weekend" (goal value, Friday 18:00 to Sunday 23:59), "Campus contest" (group by `attribute:campus`, separate rankings per group). Organisations can **save any challenge as a template**. **Duplicate** copies a challenge as a draft with new dates.
- **Results:** `GET /v1/challenges/{id}/results` → participants, active participants (score ≥ 1), new referees, goals completed, total value, winners, `prize_cost` and, when entered, cost per new referee and per goal. `GET /v1/challenges/compare?ids=` (up to 4) for side-by-side results. Results of `final` challenges never change; later reversals appear under `post_final_changes`.
- **Plan limits:** feature `challenges` (Growth and up) with limit `max_active_challenges` (live + scheduled): Growth **2**, Pro and Enterprise unlimited; drafts and past challenges don't count. Over the limit, scheduling returns `403 plan_limit_reached`. Permanent boards keep their existing `max_leaderboards` limit. Add through a new plan version (change 01 workflow) and the pricing comparison.
- **API** (writes `leaderboards:manage`, reads `analytics:read`):
  | Method | Path | Notes |
  |---|---|---|
  | POST · GET | `/v1/challenges` | Create (draft) and list (`?status=`) |
  | GET · PATCH · DELETE | `/v1/challenges/{id}` | Edit per the rules above; delete drafts only |
  | POST | `/v1/challenges/{id}/schedule` · `/cancel` · `/duplicate` · `/save-as-template` | |
  | GET | `/v1/challenge-templates` | Built-in and saved |
  | GET · POST | `/v1/challenges/{id}/participants` | List; add a referrer (opt-in challenges) |
  | GET | `/v1/challenges/{id}/results`, `/v1/challenges/compare` | |
  | — | Trophy, entries and person details | Same as N.5 under `/v1/leaderboards/{id}/…` (a challenge's ID works there) |
- **Opt-in joining** happens through the organisation's own app and server, which calls `POST /v1/challenges/{id}/participants` (there is no SDK join).
- **Webhooks** (the only way Clikgate tells anyone about challenges; it never messages participants): `challenge.scheduled`, `challenge.started`, `challenge.ended`, `challenge.finalized` (with winners), `challenge.cancelled`, plus N.5's `leaderboard.target_reached` / `target_revoked` with `challenge_id`.
- **Tests:** scheduling and every status change on time (in Africa/Lagos and other time zones), events just before/after the window, each rule, automatic vs opt-in (points only after joining), group eligibility, live-edit restrictions and end extension, cancel, duplicate and templates, plan limit counting only live + scheduled, results and comparison numbers, finalised results unchanged by later reversals.

---

## X. Consistency fixes (check the code for each)

### X.L Links, domains and redirects
- **L2 · Canary links and monitors.** The status page (change 03 W.7) checks the **health endpoints** every minute, not by tapping links. Change 03's `/_canary` platform links stay for `/health/redirect` only. The change 08 robot uses the canary organisations' own links. A canary link response carrying `x-clikgate-served-by: edge-backup` counts as **degraded** on the status page. Expected robot clicks: 5 hostnames × 72 runs = 360 a day; update `app/canary/expected.py`.
- **L3 · Canary custom domain.** Must be on a separate domain the owner controls, not under `clikgate.com` or a link domain (`reserved_domain` stays as is).
- **L4 · Canary link rules.** Canary organisations may create links on every platform domain including `clkg.to` and `clk.ng`; the `dev.ciz.to` canary link never expires and doesn't count toward test limits; each canary organisation has a live **and** a test canary key; the 20-minute robot compares backup entries for live hostnames only.
- **L5 · One allowlist setting:** `link_safety.destination_allowlist_required` (migrate the old `require_destination_allowlist` value and remove it); error code `422 destination_not_allowed` everywhere.
- **L6 · HTTPS:** live destinations are always `https` for every organisation (`http` only for test links to local addresses). Remove the `https_only_destinations` toggle from API and UI, or force it on and hide it.
- **L7 · Test clicks:** 500 test-link clicks per organisation per day (change 06 B.8) replaces the 10,000 in backend §19.2. Install and webhook test limits in §19.2 stay.
- **L8 · Goodbye redirects** apply on **organisation deletion** only. Subscription cancellation or downgrade follows change 03 B.1 (links keep redirecting with tracking). The 30-day purge keeps a minimal `goodbye_redirects` row (hostname, slug, destination, until) per link until day 90; the KV backup value carries `goodbye: true` so backup mode doesn't track those clicks.
- **L9 · Reserved slugs:** customer slugs may not start with `_` and may not be `r`, `leaderboard`, `report`, `api`, `admin`, `healthz`, `static`, `.well-known`. System paths `_t`, `_f`, `_cg`, `_canary` are created only internally.
- **L10 · One abuse-report endpoint:** `POST /v1/public/abuse-reports` `{link_url, reason, details?, reporter_email?}` with change 03's reasons; the old `POST /v1/public/reports` stays as a deprecated alias mapping `short_url` → `link_url`; one `abuse_reports` table with a `source` (`form|email`) column. The preview form posts to the new path.
- **L11 · Locked vs approval:** a locked link refuses destination changes (`409 link_locked`); two-person approval returns `202` with a change request. Fix the change 08 robot step and B.1 wording to use "allowlist rejection or a rejected change request".
- **L12 · Backup redirects cover all custom hostnames** (subdomains and bare domains through Cloudflare for SaaS) and every alias in a domain group; a link is republished when a domain joins a group.
- **L13 · Status components:** the edge marks "Redirects – ciz.to", "Redirects – clk.ng", "Redirects – clkg.to" (add it) and "Branded domains" as appropriate. Define one fixed component ID list and the signed ingest body `{component_id, status, ts, signature}` used by both the backend heartbeat and the edge.
- **L14 · Intentional responses:** the edge switches to backup on `5xx` except responses with `x-clikgate-intentional: 1`. Suspended organisations get `404` (as backend §11.2), not `503`.
- **L15 · Referrer policy per link** in the KV value (regulated organisations use `no-referrer` on shared domains).
- **L16 · Starter custom subdomain everywhere:** plan seed Starter custom domains = 1 subdomain; website and change 03 copy say "your own subdomain from Starter, more domains from Growth". Enterprise custom domains = unlimited.

### X.P Plans, billing and staff
- **P2 · Identity checks** are hard-capped (`429 usage_limit_reached`); remove "identity ₦15 / check" from Pro overage.
- **P3 · Seed values:** drop `api_requests_per_month` (rate limits only). USD prices: 6 months = 6 × monthly − 10%, yearly = 10 × monthly (Starter $27/$50, Growth $108/$200, Pro $432/$800). USD overage: clicks $1 per 10,000, events $2 per 1,000.
- **P4 · Rate limits** read the entitlement plan key: free 10, starter 50, growth 200, **pro 500**, enterprise 1,000 requests a second. `organizations.plan` is a copy updated on every subscription change and includes `pro`.
- **P5 · Internal organisations (D4).** Clikgate's own organisation and the canary organisations hold **normal subscriptions recorded by staff** (Clikgate's own: Pro; canary: Growth), with invoices and receipts like any customer. `settings.internal = true` is set only by `python -m app.internal.mark --org` (no API or UI) and excludes only lifecycle emails, platform statistics and fraud-model training. Change 08's fixed canary list keeps its own exclusions (usage counting, cleanup, results API) and no longer excludes billing or invoices.
- **P7 · Agency programme:** the free Growth subscription for qualifying agencies is a `complimentary: true` subscription (amount 0) created monthly by the agency worker; complimentary subscriptions get no reminders or renewal invoices. Agency discounts are a `discount` line on the client invoice when issued. "Record agency payment" creates one payment and receipt per client invoice from one bank transfer.
- **P8 · Lifecycle emails are plan-aware:** skip any message whose action needs a feature or allowance outside the plan (`invite_team` only when `team_members` > 1; referral tips only with referrals; `sdk_*` only with app attribution). Subject "Create your first Clikgate link in 1 minute" → "Create your first Clikgate link" (no time claims).
- **P9 · One scheduled-email rule:** saved-report schedules (backend §22) use change 02's recipient rules (members plus verified external emails), count toward `export_schedules` and need `scheduled_exports`.
- **P10–P17 (small):** `remove_powered_by` → `flags.powered_by_removable`; Free summary = totals line + 2 sentences; remove "add-ons" from the pricing page; upgrade message "You're on {plan_name}. …"; staff check page at `staff.clikgate.com/staff/open-in-app/check`; change 03 heading "links never break" → "Existing links keep redirecting".
- **P16 · Email provider:** base config gains `EMAIL_PROVIDER`, `EMAIL_API_KEY`, `EMAIL_FROM` and an HTTP adapter supporting attachments and `List-Unsubscribe-Post` (ZeptoMail is the owner's provider).
- **S9 · Staff alerts store** (one system for every change): table `staff_alerts` (`sta_` IDs; key, severity `info|warning|critical`, title, detail, source, status `open|resolved`, opened_at, resolved_at, last_notified_at, dedupe key); critical → super admins, warning → all active staff; email on open, hourly while critical, and on resolve; `GET /v1/staff/alerts`; a staff console **Home** page listing open alerts with the cards later changes add (checks due, backup redirects, end-to-end checks). Point change 01, 03, 04, 07 and 08 alerts at it.
- **S19 · Staff session transport:** `/v1/staff/auth/verify` returns `{session_token, expires_at}`; the staff BFF keeps it in its own httpOnly cookie on `staff.clikgate.com` and sends `Authorization: Staff <token>`; the API accepts that header (and the old cookie if built).
- **S23 · Staff roles:** open-in-app task emails go to the assigned staff member, or all `support`+ staff if unassigned (no "open-in-app role").

### X.E Events, attribution and SDKs
- **E1 · Goal references:** outside private mode store `external_id = "goal:{goal_key}:{reference}"`; idempotency for goal events is `(organization_id, goal_id, reference_hash)` in every mode, so two goals may share a reference.
- **E4 · One event per goal:** a counted goal emits `goal.completed` only (never `conversion.attributed`); reversals emit `goal.reversed`; rows with `duplicate_of_id` are excluded from rollups and emit nothing. `conversion_send` and `ga4_forward` subscribe to `goal.completed` for goal rows; `sale.matched` is informational and never forwarded.
- **E5 · Legacy conversions link to goals automatically:** `purchase`/`signup`/`lead`/`install` → the goal of that key; `custom` → `custom_type`; created with `value_mode: optional` on first use (counts toward the goals allowance; over it, stored unlinked with a warning).
- **E6 · Private mode and consent:** add optional `consent {analytics, attribution, ad_user_data, ad_personalization}` to the goal schema and both private-mode allow-lists. In private mode `/v1/conversions` accepts only requests with `goal` (`external_id` read as `reference`); anything else → `422 private_mode_field_rejected`.
- **E7 · Names:** cookie `_cg_{click_id_param}`; payment metadata keys `cg_click_id`, `cg_link_id` everywhere (web script `paymentMetadata()`, WooCommerce, server SDK `fromPaymentMetadata`).
- **E8 · One install-fraud system:** growth spec 7.5 flags feed change 02's rules (`ctit_too_short`→`ctit_too_fast`, `referrer_timestamp_inconsistent`→`install_before_click`, `install_burst`→`device_farm_pattern`, `emulator`→`emulator_or_rooted`); attribution credit changes only through change 02 decisions; webhook `fraud.install_flagged` replaces `install.fraud_flagged`.
- **E9 · Windows:** SDK and app-event goals use the goal's `window_days` from the latest touch (replacing `event_attribution_window_days`); install matching keeps its own lookback; sales goals use the goal window for click-ID matches and the sales window for identity matches.
- **E10 · Money units:** goal inputs in normal units; API, webhook and analytics outputs give `value` as a decimal string **and** `value_minor`; `value_property` in normal units; mobile `track()` money helpers are named `ClikgateMoney.ofMinor(...)` on every platform.
- **E11 · Referral steps by goal:** qualification steps accept `{"goal": "<key>", "within_days": N, "min_value": "5000", "currency": "NGN"}`.
- **E12 · Names:** "Device integrity checks" (App Attest, DeviceCheck, Play Integrity) vs "duplicate-identity checks" (growth 9B, server-only). Rename in change 03 copy and code comments.
- **E13 · iOS pasteboard:** default `off`; when on, the token is copied when the visitor taps the interstitial's main button.
- **E14 · No IDFA matching** (remove the clause from change 03).
- **E15 · SDK idempotency:** goals use one random `Idempotency-Key` per call, reused across that call's retries (never a hash of the reference).
- **E16 · Privacy requests and scopes:** change 03's `POST /v1/privacy/requests` shape replaces the growth spec's; add scopes `privacy:read`/`privacy:write`; sales ingest needs `conversions:write`; sales connections, conversion and analytics destinations need `org:manage` to change and `analytics:read` to view.
- **E17–E23 (small):** goal response includes `counted` and `reason`; iOS `Clikgate.shared.goal(...)`; dashboard goal snippets include C#/.NET; `once_per_click` for code events uses (code redemption, goal), unattributed events are counted; onboarding "goals" stay separate from change 05 goals; "fraud scoring on installs and bot detection on clicks"; `/v1/sdk/install` consent uses the four-purpose object (`attribution: denied` replaces `tracking_allowed=false`).

### X.S Structure, references and operations
- **S6 · ID prefixes:** invoices use `ivc_` (`inv_` is invitations); canary runs use `cnr_` (`crn_` is credit notes). Migrate existing IDs only if collisions exist in data; otherwise change the prefix for new rows and accept both on read.
- **S13 · R2 for files:** production object storage is R2 bucket `clikgate-files` (exports, verification documents, PDFs) alongside `clikgate-backups`, with an app-server R2 token (read/write both) and a read-only restore token. Env: `R2_ACCOUNT_ID`, `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`, `R2_FILES_BUCKET`, `R2_BACKUPS_BUCKET`.
- **S14 · Metrics at launch:** the `worker` scrapes `redirect` and `api` `/metrics` on the internal Docker network every minute and keeps 1-hour windows in Valkey for the alert rules; host CPU, memory and disk come from a `node-exporter` container or a read-only `/proc` mount.
- **S15 · Dashboard image:** `clikgate-dashboard` gets a `Dockerfile` (Next.js standalone) and `deploy-dashboard.yml` that pushes its image and runs the backend's `deploy.sh` for the `dashboard` service only.
- **S16 · Canary setup never prints secrets:** it writes keys, passwords and TOTP secrets straight into GitHub secrets and Worker secrets using short-lived tokens, and prints only their names and the organisation IDs.
- **S17 · Hashing:** `daily_salt = HMAC_SHA256(IP_HASH_SALT_SECRET, "YYYY-MM-DD" UTC)` (derived, never stored), so the edge computes the same `ip_hash`.
- **S20 · Dashboard error mapping:** `plan_upgrade_required` → the upgrade intro page; `plan_limit_reached` → inline limit message; codes from change files map before the generic `permission` toast.
- **S21 · One fraud area:** remove the "Fraud signals" tab from `/[org]/protect` (keep Identity matches and Blocked, link to Ad fraud); remove the old "Coming later" Integrations/Cost tabs from `/[org]/ads`.
- **S22 · Words:** "End goal", never "journey", for the goal at the end of a funnel.
- **S26 · Spill file:** `redirect` and `ingest` share a named volume at `/var/clikgate/spill`; `deploy.sh` never removes it.
- **S5, S8, S25 · Wrong references** (fix the doc comments and any docs that copied them): browser snippet is backend §14; feature switches are growth spec 9E; onboarding is backend §23; link cache is §9; temporary copy is change 08 R.3; `/report` and trust centre are change 03 W.4; SDK health is change 03 F.5; Settings → Privacy & consent → Leaving Clikgate; `pending_click` shows in the event debugger and Attribution → Conversions.

### X.H Housekeeping from the change 07 and 08 builds
1. `POST /v1/open-in-app/match {url}` → `{app_key, app_name, status}` or `null` (rate-limited); the link form uses it before saving.
2. Alerts list filter by link; link Activity uses it.
3. `app_name` alongside `app_key` in performance rows; enums instead of plain text for fixed-value fields; assignee name and email on staff tasks.
4. Fix the flaky tests: the date-dependent backend test (use a fixed fake clock) and the dashboard timing tests including the test-mode banner (wait for the element, not a timeout).
5. Dark-mode primary button hover meets WCAG AA contrast (one token change).
6. `scripts/seed.py`: give the demo organisation a plan that allows its custom domain.
7. Developers pages and Links/Campaigns pages: trim before adding anything (they are at their size budgets).
8. One full, uninterrupted run of every test suite in each repository when no other agents are running, before tagging a release.

### X.M Backend milestones
1. **C9-B1** N.4 goals APIs, X.E1–E6, E15 (check first), tests.
2. **C9-B2** N.1 app subdomains, well-known files, link hostnames, setup command and `doctor`, backup-redirect routes, tests.
3. **C9-B3** N.2 web keys and browser goals, web script, tests.
4. **C9-B4** N.3 customer two-factor, fresh-code actions, emails, canary users, tests.
5. **C9-B5** X.L, X.P (including S9 staff alerts and S19), remaining X.E items, tests.
6. **C9-B6** N.5 leaderboard trophies, goal metric, progress bands, API and webhook additions, tests.
7. **C9-B7** N.6 challenges: fields, scheduler, rules, participation, templates, results and comparison, plan limit and plan version, API, webhooks, tests.
8. **C9-B8** X.S and X.H; `docs/DECISIONS.md` entries for D1–D12; regenerate `openapi.json`; full uninterrupted test run.

---

## F. Frontend (dashboard)

### F.1 Customer screens
- **Apps:** "Link subdomain" field with availability check and the rules; after the first link it's read-only with "Contact support to change". Link domain picker shows the app subdomain first ("Opens your app directly"); shared domains show "Works through the store and deferred deep links".
- **Settings → Developers:** web keys (live/test) with copy and rotate (fresh code); web script snippet includes the web key.
- **Goals:** "Allow from browser" switch with the warning, optional maximum browser value; reports show a "From browser" filter and label.
- **Account → Security:** set up an authenticator (QR, confirm, recovery codes shown once with download/copy), regenerate recovery codes, turn off (fresh code). **Organisation → Security:** "Require two-factor for all members" (owners/admins), with the list of members who haven't enrolled.
- **Sign-in:** code step and "Use a recovery code"; forced enrolment screen when the organisation requires it; fresh-code dialog before sensitive actions.
- **Leaderboards:**
  - Builder sheet gains a **Trophy** section: target (number, or amount with currency for value boards), label, prize text, and type — **Everyone who reaches it** (default from the organisation setting) or **First N to reach it** (with N). Metric picker gains "Goal" (pick a goal; count or total value).
  - Board detail gains a **Trophy** tab (opens first when a trophy is set): the trophy and label at the top with the winners strip ("Reached: Ada O. · 2 days ago"); then the **progress bands** — Almost there, Close, On the way, Started — each row showing name, score, a progress bar with the percentage written out, "N to go", and "+N pending"; On the way and Started are collapsed to a count with "Show". Works on phones (bands stack, rows stay one line). Bars always have text values (no colour-only meaning). **No pace or "days to go".**
  - Tapping a person opens a detail drawer: score, progress, gap, reached time if any, score breakdown, pending, adjustments (with "Add bonus or penalty"), recent scoring events, and any fraud flag.
- **Challenges** (Grow → Challenges):
  - Tabs **Live**, **Scheduled**, **Drafts**, **Past**, and a **Calendar** (month view) showing every challenge as a bar from start to end.
  - **New challenge** wizard: start from a template, a past challenge (duplicate) or blank → what counts (goal count or value, or a referral step) and rules (minimum value, first per customer, campaigns, links, channels, new referees only) → dates (with the time zone shown) → who can take part (everyone / a group; automatic or "only people who join") → trophy and prize text, optional prize cost → review with a plain-English summary ("From 1 to 31 Dec, every referrer earns a point when a friend makes a first deposit of ₦50,000 or more. Everyone who reaches 15 wins ₦15,000 bonus.") → Save draft / Schedule.
  - Challenge page: status, countdown to start or end, the **Trophy** tab (N.5 bands), participants, results; actions Extend end, Cancel (with reason), Duplicate, Save as template. Locked fields show why ("Can't change after the challenge starts, to keep it fair").
  - **Compare** up to 4 past challenges side by side (participants, new referees, goals, value, winners, prize cost and cost per new referee).
  - Plan limit shown on the list ("2 of 2 live or scheduled on Growth") with an upgrade link.
- Settings → Referrals & leaderboards (or the nearest existing settings page): "Default trophy type" (Everyone who reaches it / First N to reach it).
- **Continue from the website's try-it box (D10):** after sign-up or sign-in, `?shorten=<url>&type=link|qr` opens Create link (or Create QR code) with the destination filled in; the user confirms before anything is created; the URL is validated and safety-checked as usual.
- **Playbook links from solution pages (D11):** `?start=<playbook_key>` after sign-up or sign-in opens the right screen (for example the challenge wizard with a template selected, or Create QR code); nothing is created until the user confirms.
- **Wording audit (D9):** search the dashboard's customer-facing copy (labels, help text, empty states, tooltips, onboarding, upgrade prompts) and the backend's email templates for "bank"/"banks"/"banking"; keep only bank-transfer payment wording and mixed-industry examples; use "regulated organisations" for the regulated flag. Record changes in `docs/PROGRESS.md`.
- X.S20 error mapping, X.S21 navigation clean-up, X.S22 wording, the `pending_click` label placement, C#/.NET goal snippet tab.

### F.2 Staff console
- **Home** page (X.S9) with open staff alerts and the existing cards (checks due, backup redirects, end-to-end checks).
- Organisation detail: reset a user's two-factor (🔐) with the identity-check checklist; change an app's link subdomain (🔐).
- Staff session per X.S19.

### F.3 Milestones
1. **C9-F1** Two-factor screens and fresh-code dialog.
2. **C9-F2** App subdomains, web keys, browser goals, error mapping, navigation and wording fixes.
3. **C9-F3** Leaderboard trophy section, Trophy tab with progress bands, person drawer, default trophy setting, tests.
4. **C9-F4** Challenges: list, calendar, wizard, challenge page, compare, plan limit, tests.
5. **C9-F5** Staff Home and staff changes, X.H items for the dashboard, `Dockerfile` and `deploy-dashboard.yml` (X.S15), full uninterrupted test run; update `docs/PROGRESS.md`.

### F.4 Skill update (`.claude/skills/clikgate-api-integration/SKILL.md`)
- Deferred table: only "cross-promotion" stays deferred; add a row for change 02's ad spend, connections, conversion sending and fraud endpoints.
- Error table: add `plan_upgrade_required` and `plan_limit_reached` rows above `permission`, and the note that codes from change files map before the generic fallbacks.
- Staff console calls use a separate `staffClient` through `/api/staff-proxy`, without `Clikgate-Organization` or `Clikgate-Mode`.

---

## W. Website (`clikgate-website`)
- **Docs:** "Opening your app from links" (app subdomains, why shared domains can't open apps directly, what to put in Xcode and Android); "Sending goals from your website" (web key, allowed origins, "Allow from browser", why payments should come from the server); "Two-factor sign-in" (and "Require two-factor" for organisations); update the setup command and AI guide pages for app subdomains.
- **Docs → Leaderboards:** trophies (everyone who reaches it vs first N), goal-based scores, progress bands and the new API fields; note that Clikgate records winners but never pays prizes. **Docs → Challenges:** creating and scheduling challenges, templates, rules on existing goals (what marketing can do without developers, and when developers must send a new goal), automatic vs opt-in, editing limits once live, results and comparison, the server API and webhooks (no SDK, and Clikgate never messages participants).
- **Product page: Leaderboards, trophies and challenges** (new `/products/challenges`, or a full section on the existing referrals/leaderboards page if one exists; in the Product menu next to Referrals). It must explain the whole flow plainly, with a visual, not just list features:
  1. **Headline and intro:** "Turn your customers into your best marketers" (or similar, no uplift claims) and one sentence: "Run referral challenges whenever you need them. Clikgate tracks who brought whom, counts the goals that matter to you, and shows everyone's progress towards the trophy."
  2. **How it works, in six steps** with small illustrations: (1) choose the goal that matters (a first purchase, a first deposit, an activated card, a completed order); (2) create a challenge with dates, a trophy and a prize ("Everyone who reaches 15 first purchases this month wins a ₦15,000 voucher from you"); (3) your customers share their own referral link or code — it never changes between challenges; (4) when a friend completes the goal, Clikgate counts it for the person who referred them; (5) everyone's progress shows in bands — Almost there, Close, On the way, Started — and pending referrals don't count until they complete the goal; (6) when someone reaches the trophy, Clikgate tells your systems instantly (webhook), and **you** reward them.
  3. **A static progress-bands visual** (the dashboard Trophy tab as a polished mock, with obviously fictional masked names).
  4. **"Run a new challenge whenever marketing needs one":** templates, duplicate last month's challenge, schedule ahead, the calendar, and rules on goals you already send (minimum value, first purchase only, one campaign or channel, one city or campus) — so most new challenges need no developer work. Say plainly that a brand-new kind of event needs your developers to send it once.
  5. **Fair by design:** rules lock when a challenge starts; reversed or fraudulent goals are removed; winners are final only after your waiting period; opt-out and fraud-flagged people never appear.
  6. **Use cases**, a mix with no single industry dominating: online store "sales race this weekend", fintech "first deposits this month", delivery app "first orders", campus or community contest by group, creators and affiliates (Distyla-style) "top sellers". Banking can be one card among these.
  7. **What Clikgate does and doesn't do:** it tracks, counts, ranks and tells your systems; it does **not** pay prizes or message your customers — you choose how to reward and notify them.
  8. **Compare challenges:** results side by side (people taking part, new customers, goals, value, cost per new customer when you enter prize costs).
  9. Plans ("Leaderboards and challenges from Growth; 2 live or scheduled at once on Growth, unlimited on Pro") and a link to the docs. FAQ: opt-in vs automatic, changing a live challenge, what happens on reversals, time zones, privacy.
  The home page's growth section and the referrals page link to it.
- **Home page hero illustration — the "click map" (D12).** Replaces the current channels → Sign-up → Order paid illustration (and change 03's journey line in the hero). Built in SVG/React with brand tokens on the navy hero. Two sizes of the same component:
  - **Compact (in the hero's right column, about 680 × 430 px, next to the headline and buttons):** three columns only —
    1. **five channel cards** (about 200 × 52 px each), each with its colour dot, name and the tracked thing in small monospace: Instagram ad `ciz.to/summer` · TikTok creator `shop.ciz.to/ada` · WhatsApp chat "2,381 chats tracked" · QR poster "1,252 scans" · Referral "Tunde's link";
    2. **the Clikgate node** (about 150 × 150 px, soft glow): "Clikgate", "every click gets an ID", and two badges — green "✓ Opened in the app", red "✕ 214 fake clicks removed";
    3. **"Where your orders came from"**: one row per channel in the same colour with a value bar and amount (Instagram ₦7.9M, TikTok ₦4.2M, WhatsApp ₦3.1M, QR poster ₦1.6M, Referral 🏆 ₦1.9M), then **Total ₦18.7M**.
    Under it, one slim line "Sent back: ✓ Meta ✓ Google ✓ TikTok ✓ GA4 ✓ Your server", and the caption "Each channel keeps its colour from the click to the orders it brought. Illustration with example data." The separate Sign-up and goal boxes are left out of the compact version (the goal is named in the results heading). The same one-person animation runs, smaller. **Build it as live HTML in the hero, never as an image:** a React component (`ClickMap`, with `size="compact" | "full"`) made of HTML elements for the cards, rows and badges and one inline SVG for the connecting paths and the moving dot, styled with the site's brand tokens and Tailwind. All words and numbers are real text (selectable, translatable, read by screen readers and search engines); example data comes from one typed data file so numbers stay consistent; paths are computed from the card positions so nothing misaligns when text or sizes change; it scales with the hero column (no fixed pixel width), and below the hero's two-column breakpoint it switches to the vertical phone story. Animation uses CSS or the site's existing Motion library, respects reduced motion, and pauses when off screen. No raster images, no canvas, no external requests; the hero stays within its Lighthouse budget with no layout shift.
    References in `docs/design/`: `clikgate-hero-click-map.png` (how it should look) and `clikgate-hero-click-map.html` (a rough static HTML sketch used to make the picture — for layout and proportions only; rebuild it properly as the component above).
  - **Full (a section just below the hero, "How Clikgate works"):** the complete five-stage version described below, with six channels, the Sign-up and goal boxes, hover funnels and the "Sent back" strip.
  On phones both collapse to the vertical story described below.
  - Full version details:
  - **Desktop layout, left to right, each channel keeping its own colour all the way to the end:**
    1. **Where people found you** — six cards, each showing the real thing Clikgate tracks rather than just a count: Instagram ad `ciz.to/summer` · TikTok creator `yourapp.ciz.to/ada` · WhatsApp chat (WhatsApp attribution) · QR poster (scans) · Agent code `AGT-142` · Referral (Tunde's link).
    2. **Clikgate** — the centre node with the logo and "Every click gets an ID", and three small badges that light up as paths pass: **"Opened in the app"** (deep link / open in app), **"Fake clicks removed: 214"** (fraud), **"Private mode on"** (optional, smaller).
    3. **Your goals** — "Sign-up" then the goal you chose, "Order paid".
    4. **Where your results came from** — one result row per channel, with bars sized by value: e.g. Instagram ad ₦7.9M · ROAS 4.1× · TikTok creator ₦4.2M · WhatsApp ₦3.1M · Referral ₦1.8M with "🏆 3 reached the trophy" · QR poster ₦0.9M · Agent codes ₦0.5M · **Total ₦18.4M**. Totals must add up; sign-ups and orders must be smaller than clicks.
    5. **Sent back** — a slim strip: "Meta ✓ · Google ✓ · TikTok ✓ · GA4 ✓ · Your server (webhook) ✓".
  - **Animation (the story of one person, repeating):** a glowing dot travels one channel's path — e.g. Instagram ad → `ciz.to/summer` → "Opened in the app" badge pulses → Sign-up → "Order paid ₦18,500 · Goal reached" → the Instagram row ticks up by ₦18,500 → "Sent to Meta ✓" flashes. Every ~6 seconds it follows a different channel (WhatsApp; QR poster; Referral, which also adds "+1" towards the trophy; a fake click that stops at the centre with "Removed"). Calm and slow; pauses on hover; **reduced-motion users see one highlighted path, static**.
  - **Interaction:** hovering or focusing a channel highlights its path and shows a small card with its full funnel (clicks → sign-ups → orders → value → cost → ROAS). Keyboard-accessible; every number is real text (screen readers get a summary table).
  - **Phones:** the same story as a vertical sequence of small cards (channel → link → app opened → goal → counted for the channel → sent back), followed by the per-channel results list.
  - **Words:** never "credit", "earn", "payout" or "paid by Clikgate" in the illustration or near it — it must not look as if Clikgate handles money. Use "orders", "sales", "results", "brought", "came from".
  - **Example data rules:** obviously fictional names and links, consistent maths, naira values; no claims that these are real customers' results; brand lines not used inside the illustration.
  - **Shorter hero text (owner, 2026-10-27):** replace the headline with **"See the clicks that grow your business."** (no "exactly": some results are honestly labelled estimates) — also replace the old headline wherever it was reused: page title, meta description, social share image, `llms.txt`, emails; replace change 05's long subhead with **"From the first tap to the result you care about — across apps, websites, social media and offline. Clikgate sees to every click, and every referral."** (the last sentence in the accent blue; it is the hero's one brand line, so the change 06 rotation rule doesn't apply to the hero); remove the separate "Works for apps, websites, WhatsApp and offline." line (now in the subhead); keep the buttons and "Free plan · Paid plans from ₦7,500/month · Pay in naira". The fuller list of features (attribution, deep links, referrals, fraud protection) belongs in the sections below, not the hero.
  - Keep the hero buttons and microcopy as above; the dashboard tiles mockup moves below the full click map section or is dropped if the page gets crowded (builder's choice, recorded in `docs/DECISIONS.md`).
- **Short links page (D10)** — new top-level page `/short-links`; header order becomes **Short links · Product · Solutions · Pricing · Resources** (Customers stays hidden until real content exists). `/products/short-links` redirects (301) to it; `clk.ng`'s root redirect, the Product menu's "Smart links & QR", the footer and the sitemap point to it; it keeps change 03's search role and meta title ("Free URL shortener for Nigeria and Africa — Clikgate short links"). Built with the existing brand tokens and components (navy hero, calm blue, real dashboard components as mockups). Inspired by the *structure* of leading shortener homepages — **don't copy any other site's text, images, illustrations or layout details.** Sections, top to bottom:
  1. **Hero with a "try it" box:** headline such as "Short links that show you every click" (a brand line may sit under it), one-sentence subhead, and a box with two tabs, **Short link** and **QR code**. Paste a long URL → the page shows a preview of the result (`clk.ng/…` and a QR preview) and "Create it free" → sign-up, carrying the URL across so the link is created right after sign-up (dashboard F.1). **No links are created without an account** (anonymous short links attract abuse). Under the box: the Free plan in three bullets read from the public plans API (links per month, clicks per month, `clk.ng`), and the buttons **Start free** and **Talk to us**.
  2. **Three showcase blocks**, alternating text and product mockups, each with a few bullets and a "Learn more" link:
     - **Short links:** your domain (`ciz.to` premium, your own subdomain from Starter), custom endings, UTM builder, routing by device and country, deep links and "open in app".
     - **QR codes:** designs and colours, scan counting, change where a QR code goes after printing.
     - **Link analytics:** clicks by day, country, device and channel, and the step beyond clicks — goals reached (links to the goals and attribution pages).
  3. **"Two domains, one rule: keep good links clean"** (change 06 W.4 section moves here, with "Why ciz.to? Say it out loud: sees to.").
  4. **"More than a short link":** how a click becomes a measured result — click → goal → attribution, referrals and challenges — linking to Product pages.
  5. **Safe by design:** link scanning, "Report a link", link safety for organisations with strict security needs, HSTS; backup redirects only once change 08's reliability wording is switched on (same setting).
  6. **Numbers band — only real numbers:** links created, clicks counted, from a public stats endpoint, shown only when a staff setting is on and the numbers pass a minimum (hidden by default). Never invented or rounded-up figures.
  7. **Use cases:** a mixed grid (online stores, creators, events, delivery apps, schools, fintechs, community groups) per D9.
  8. **Customer quotes and logos:** hidden until real, approved ones exist.
  9. **Pricing teaser** (Free and Starter from the plans API, link to Pricing), **FAQ** (Is it free? Can I use my own domain? Can I change a link after sharing it? Do links expire? What happens to links if I stop paying?), and a final call to action.
  - **No exit pop-ups** or "wait, don't go" modals. Mobile first; the try-it box is the first thing on a phone screen. Lighthouse and accessibility budgets as other pages.
- **Solutions menu and pages (D11).** Inspired by how leading sites group solutions; **Clikgate's own names, wording and presentation — nothing copied.**
  - **Menu presentation** (different from a plain column list): a wide panel with a **left selector** of three groups — **Your industry**, **Your team**, **Your stage** — and a right pane showing that group's items as **tiles** (icon, name, one-line outcome such as "See which posts sell"). A **featured card** on the far right shows a small animated journey for the tile being hovered or focused (for example "WhatsApp tap → App opened → First order"), using the existing `JourneyLine` component; reduced-motion users see it static. Footer row: "Not sure where you fit? Compare plans · Talk to us". Keyboard: arrow keys move between groups and tiles. On phones: an accordion of the three groups with simple rows.
  - **Your industry:** E-commerce & retail · Fintech & financial services (banking, lending, insurance, payments and wallets as sections of one page) · Delivery & mobility · Education · Media, creators & entertainment · Events & ticketing · Food & hospitality · Telecom & digital services · Health & wellness (private mode front and centre).
  - **Your team:** Marketing · Growth & product · Developers · Sales & partnerships (referrals, agents, offline codes) · Customer retention (re-engagement, uninstall tracking) · Security & compliance (private mode, link safety, two-factor, data handling).
  - **Your stage:** Creators & solo sellers · Startups · Growing businesses · Large & regulated organisations · Agencies (the existing agencies page).
  - Old URLs redirect (301): the change 03 sector pages and change 05's Banking & fintech, Insurance and Lending pages → the matching new page or section.
  - **One page template for every solution**, driven by a typed content file per solution (MDX + frontmatter validated at build), so all pages stay consistent. Sections in order:
    1. **Hero:** group chip ("Industry · E-commerce & retail"), an outcome headline, one-sentence subhead, Start free and Talk to us, and a sector-specific journey mock built from real components (e.g. "Instagram story → product page → order ₦18,500 · Goal reached").
    2. **What gets in the way:** three short problems this audience really has in the market (for example sales shared on WhatsApp you can't see, mostly-Android customers on patchy networks, offline and agent sales), each one line.
    3. **How Clikgate fits — an interactive journey:** tabs **Reach → Click → Visit or install → Goal → Reward and retain**; each tab shows which Clikgate features do the work, with a small mockup and a link to the product page.
    4. **Goals that matter here:** example goal chips for this audience (first order, repeat order, first deposit, course completed, ticket bought) linking to the goals page.
    5. **Channels:** the channels this audience uses (WhatsApp, Instagram, TikTok, SMS, QR on packaging or posters, USSD and offline codes, agents, influencers) as an icon grid.
    6. **Example dashboard:** a sector-specific dashboard mock, clearly labelled **"Example data"**.
    7. **Ready-made playbooks:** two or three step-by-step playbooks (e.g. "Weekend sales race" challenge, "QR codes on packaging", "Agent referral codes"), each listing the features and any challenge template used, with "Try this" opening the dashboard at the right screen after sign-up.
    8. **Trust and privacy:** what matters for this audience (private mode, link safety, two-factor, backup redirects once switched on), linking to the trust centre.
    9. **Works with:** the relevant integrations (Shopify, WooCommerce, Paystack, Flutterwave, Meta, Google, TikTok, GA4, the server SDKs).
    10. **Plans that fit:** which plan features this audience usually needs, from the plans API (no "most customers choose" claims).
    11. **Questions:** five to eight audience-specific FAQs (FAQ structured data).
    12. **Related:** guides, docs and other solutions; closing call to action.
    Customer stories, quotes and logos appear only when real and approved (hidden blocks until then). No uplift or time claims. Team pages lean on day-to-day workflows; stage pages lean on how to start and grow with the plans.
  - **Quality bar:** better than typical solution pages — specific to the African market and to each audience, real product components instead of stock images, every page useful on its own. Each page passes Lighthouse and accessibility budgets. The builder lists every new page in `docs/PROGRESS.md` for the owner's review of the wording.
- **Wording audit (D9)** across the whole website, docs, `llms.txt` and the email templates kept in this repository (the dashboard does its own audit, F.1):
  - Search the built site for "bank", "banks", "banking" (and the same in headings, page titles, meta descriptions, image alt text and `llms.txt`). For each, keep it only if it is (a) on the financial-services use-case page, (b) one example in a mixed list of industries, or (c) about paying by bank transfer. Otherwise replace it: "for banks" → "for organisations with strict security needs" or "for regulated businesses"; "banks and everyone else" → "every business"; banking-only examples on general pages → a mix (online stores, fintechs, delivery apps, creators, schools, banks).
  - Examples: "Link safety for banks" → "Link safety for organisations with strict security needs"; "Built for banks" → "Built for businesses that can't compromise on security".
  - Rotate example industries across pages so no single industry dominates; the home page and pricing page name no single industry in headlines.
  - Record every replaced phrase (page, before, after) in `docs/PROGRESS.md`. Add a CI check that fails if "bank" appears outside the allowed pages and an allow-list file.
- **Pricing:** rows "Challenges live or scheduled at once" (Growth 2, Pro and Enterprise unlimited).
- **Trust centre → Security:** customer two-factor sign-in, required for regulated organisations by default.
- **Copy fixes:** "your own subdomain from Starter, more domains from Growth"; remove "add-ons" from pricing; no "in 1 minute" or other time claims anywhere; abuse report form uses the new endpoint.
- **`llms.txt`:** add the new docs pages.
1. **C9-W1** The above, Lighthouse and accessibility checks; update `docs/PROGRESS.md`.

---

## Definition of done
- A customer's app opens directly from `yourapp.ciz.to` links and its own domain, never from shared domains; `doctor` catches old shared-domain entries.
- Websites can send browser goals only from verified origins with the web key, only for goals that allow it, clearly labelled.
- Customers can turn on two-factor; regulated organisations require it; sensitive actions ask for a fresh code; the robot signs in with its authenticator.
- Leaderboards can have a trophy (default "everyone who reaches it", configurable per organisation and board), goal-based scores, and a progress-bands view with person details and no pace estimates.
- The home page hero shows the click map: each channel's path stays visible to the result, with the link, app opening, fraud removal, goals, results per channel and results sent back.
- The Solutions menu groups pages by industry, team and stage in Clikgate's own design, and every solution page follows the informative template with honest example data.
- The website header starts with **Short links**, whose page lets visitors try a link or QR code and continue to sign-up with it, with no invented numbers or testimonials.
- Marketing can create, schedule, duplicate and compare challenges at any time with rules on existing goals; participation is automatic by default; plan limits count only live and scheduled challenges.
- Every X item is either "already done" or fixed, recorded in `docs/PROGRESS.md`, with all test suites passing in one uninterrupted run.

## Before building: things only the owner can provide
- Approval for the `*.dev.ciz.to` certificate if it costs extra (the builder reports the price).
- The brand and offensive-word blocklist for app subdomains (a starter list is fine).
- An authenticator on your phone for testing the customer two-factor flow.
- Recording the paid subscriptions for Clikgate's own organisation (Pro) and the two canary organisations (Growth) in the staff console after this change.
