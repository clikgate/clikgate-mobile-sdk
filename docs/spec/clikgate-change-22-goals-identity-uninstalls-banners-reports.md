# Clikgate Change 22 — One `goal()` Method, the Dashboard Chooses What Counts, "No Goals Arriving" Checks, Ad Network Transparency, Easy Identity, Chart Notes and Targets, Shared Views, the Uninstall Add-on and Uninstall Data, App Banners Results, and Cohort Revenue, Time to Convert and Explore

> **Instructions for the AI building this:**
> - Changes 01–21 are built; nothing is live yet. **No SDK has been published to a public store yet:** the first public SDK releases happen after this change, so no public version ever contains `track()`.
> - **The parts, built in this order:**
>
>   | Section | What | Plan |
>   |---|---|---|
>   | G | **One method `goal()`**; `track()`, app events and Event rules removed; "Seen from your app and website" with "Count this as a goal"; "app active but no goals arriving" checks | All |
>   | E | **Easy setup:** suggestions, aliases, typo warnings, names in "See it live" | All (ad mappings Growth and up) |
>   | S | **Complete sweep** of every SDK, integration and doc, plus a CI guard | All |
>   | I | **Identity made easy:** `createIdentityToken()`, `getInstallationId()`, failure reasons, rotation overlap, the "Identify your users" docs page | All (labels Growth and up) |
>   | A | **What was sent to ad networks, and why** | Growth and up |
>   | N | **Weekly summary** with fraud counts, and the website section | See N |
>   | M | **Chart notes, monthly targets, dashboards shared by link** | Notes and targets all; sharing Growth and up |
>   | U | **Uninstall tracking add-on** (Growth) and the website page | Growth add-on |
>   | V | **Uninstall data for marketing** | Pro and Enterprise, or Growth with the add-on |
>   | B | **App banners results** | Growth and up |
>   | P | **Cohort revenue and ROAS by day, time to convert, Explore, "Updated n minutes ago"** | See P |
>
> - **Backend repository** (`clikgate`, and the SDK and integration repositories the builder actually uses): G, E, S, I, A, N (backend), M, U, V, B, P, T.
> - **Dashboard repository** (`clikgate-dashboard`): the dashboard parts of every section, DB, T.
> - **Website repository** (`clikgate-website`): W (with N.2, U website, I docs, S docs).
> - **How to build and test (owner's routine, same as changes 16–21):**
>   - build every milestone in order first, writing the tests with each, without running the full suite after each one;
>   - when everything is built, run the full test suite once, fix every failure, and re-run until all pass;
>   - then follow section T.
> - **Check current documentation first and record findings with dates in `docs/DECISIONS.md` and `docs/ADS.md`:**
>   - each ad network's standard event names (for E.1 suggestions), its "optimise for this event" menus and help links (A.3), and whether its reporting API shows which conversion events active campaigns optimise for;
>   - Meta's event match quality reporting.
>
>   Never guess.
> - **Reuse:**
>   - change 01: meters, `uninstall_checks`, plan versions, add-on billing;
>   - change 02: conversion sending, spend, fraud queue, exports;
>   - change 05 / change 12: goals, `goal()`, payment goals, reference dedup;
>   - change 11: confirmed payments;
>   - change 13: permissions;
>   - change 14: people, timeline, labels, keep/hide/restore, `identifyUser()`;
>   - change 16: saved dashboards, metric registry, Present mode, section T;
>   - change 17 J: notification catalogue; A/B; banners on WooCommerce;
>   - change 19: D10, send log, skip reasons;
>   - change 20: default dashboards and template versioning, sample organisations, "See it live", `app_active_days`, retention, add-on rules;
>   - change 21: existing-user opens, creatives, match quality, `/facts`, R.40 (no comparisons), R.41 (API audiences);
>   - SDK spec §4 (installation ID, reinstalls), §8.5 (identity tokens), §24 / backend spec §24 (App banners).
> - **Section R (review fixes) at the end of this file wins over any earlier text it changes.**
> - **Owner rules:**
>   - links and redirects never stop working because of plan, usage or payment;
>   - revenue counts confirmed payments only;
>   - describe what happened, never predict (change 19 D10): no "on track", "projected", "expected", "will", forecast lines or estimates for days not reached;
>   - no result promises ("improve your ads", "more sales", "reduce uninstalls");
>   - never "fake", "fraudster", "unlimited", "guaranteed" or "certified";
>   - never log secrets, tokens, identity secrets, hashed identifiers, customer IDs or labels;
>   - Clikgate never messages the business's customers;
>   - no competitor comparisons on the website.

---

## 0. Decisions

| # | Decision |
|---|---|
| D1 | **`goal()` is the only method** for anything that happens in an app, website or server. **`track()` is removed completely** (no alias), along with app events, Event rules, `app_event.received`, `POST /v1/sdk/events` and `GET /v1/app-events`. |
| D2 | **The business decides what counts:** names arrive, appear in "Seen from your app and website", and count only once ticked. Ticking counts "from now on" by default, with an option to include the last 30 days after a usage notice. **Older events are never sent to ad networks**, and the dashboard says so. |
| D3 | **Webhooks:** only `goal.completed` for counted goals. **Referral steps:** counted goals only. |
| D4 | **"App active but no goals arriving"** checks on every plan: 3 days with active users and zero goals; 2 days for a usually-busy goal; likely-rename detection. Adjustable. |
| D5 | **Identity:** `createIdentityToken()` in every server SDK; `getInstallationId()` in every mobile SDK; token life stays 30 days by default; no forced refresh; secret rotation only when the business chooses, with a 7-day overlap. |
| D6 | **Uninstall tracking add-on:** Growth only, ₦37,500 ($25) a month, 300,000 checks a month; checks pause at the limit with no extra charge. Six add-ons in total. |
| D7 | **Facts only** in every new report, widget, alert, summary and website text. |
| D8 | **Later list (not in this change):** link naming rules and presets; campaign launch kit; banner fatigue, quality of banner-acquired users, web vs app outcome, banner A/B tests; map view; BigQuery and S3 exports; ad revenue for gaming apps. |

---

## G. One method, `goal()`: the dashboard chooses what counts (Part 1)

**Why:** today `track()` stores app events (Attribution › App events, `GET /v1/app-events`), isn't metered on its own, can be promoted by Event rules, advances referral steps and sends `app_event.received`. Two methods confuse developers, and Clikgate isn't a product analytics tool. **Also fixed:** the SDK pages and an Android code comment wrongly say events and goals need Growth and up; basic app attribution is on every plan since change 20.

### G.0 What changes
1. **One method: `goal()`.** **Remove `track()` completely**, not as a deprecated alias.
   - It's removed from every SDK (Android, iOS, Flutter, React Native, web script, server SDKs if present), from the docs, samples, AI guides, the setup command and the dashboard snippets.
   - It's a major SDK version.
2. **The dashboard decides what counts.**
   - Every name sent with `goal()` (from apps, the website and servers) appears in **"Seen from your app and website"**: name, count, last received, source (app or website, platform, app version).
   - The business ticks **"Count this as a goal"**. **From now on** is the default, with an option to **include the last 30 days**, after a notice of the usage it adds ("This adds {n} events to this month's usage").
   - Unticked names are stored for 30 days. They're not in reports, not metered, not sent to ad networks, and shown on the person's timeline as activity.
3. **"Your app is active, but no goals are arriving"** checks, on every plan, with these defaults (adjustable per organisation):
   - active users (app opens) but **zero goals for 3 days**, per app and per website;
   - a goal that normally arrives (based on the last 4 weeks) **has had none for 2 days**, with longer windows for rare goals so they don't raise false alarms;
   - **a likely rename:** a goal stops while a new unticked name starts ("Did you rename `purchase` to `purchase_done`?"), with one click to count it as the same goal.

### G.1 Rules
- **Names:** `^[a-z][a-z0-9_]{1,39}$` (as change 05 goal keys); other names are refused with a clear error. At most 200 unticked names per app or website. Beyond that, new names are refused (`422 too_many_event_names`) and staff are alerted.
- **Counting:**
  - only ticked goals feed Goals, funnels, Who's stuck, Progress, cost per new customer, ad network sending and the "installs and events" meter;
  - the same `reference` counts once (change 05 / change 12 dedup);
  - **payment goals still count only when Paystack, Flutterwave, Stripe or Shopify confirm** (change 11);
  - values sent from the app on a payment goal are "reported", never revenue.
- **Ticking with the last 30 days:**
  - counts the stored events in order, attributed with the same rules as at the time;
  - adds the usage to the current month (with the notice first);
  - **never sends these older events to ad networks** (G.3);
  - fires webhooks only if the business chooses.
- **Unticking (archiving a goal):** stops counting from that moment; history is kept (change 05 archive rules).
- **Replaces:**
  - **Event rules** (promoting events to goals or conversions): existing rules are migrated to ticked goals or conversion mappings;
  - **Attribution › App events tab:** becomes "Seen from your app and website";
  - **`app_event.received` webhooks:** removed (G.3 item 2);
  - **referral steps on events:** become referral steps on ticked goals (G.3 item 3).
- **Private mode:** as for goals today (no properties, IDs or labels).
- **Consent, opt-out and deep-link-only mode:** unchanged.
- **The "no goals arriving" check:**
  - runs daily (Lagos time), from app opens (change 20 `app_active_days`), website goal traffic, and goal history;
  - shows the banner, a Getting started item and "Send to my developer";
  - alerts through the change 17 J catalogue: one alert per problem until it's fixed or snoozed;
  - **likely reasons from facts:** app or SDK version changed that day, test key used in a live build, consent denied, private mode, a different name arriving, the goal archived;
  - **wording:** describe, never predict ("Normally about 40 a day; none since 6 November").
- **Rate limits and test mode:** unchanged (change 20 test cap of 2,000 events a day).

### G.3 Owner decisions on edge cases
1. **The 30-day option never sends old events to ad networks.**
   - In the tick dialog, under the 30-day option, the dashboard says plainly: "Events from before today won't be sent to Meta, Google, TikTok or other ad networks. Only new events from now on are sent. Your Clikgate reports will include the last 30 days."
   - **On the goal's ad-sending screen:** "Sending started {date}. Earlier events (included in reports from {date − 30 days}) were not sent to ad networks."
2. **Webhooks:** only `goal.completed` for counted (ticked) goals. **Remove** `app_event.received`, and add no `event.received`. Existing webhook subscriptions to `app_event.received` are moved to `goal.completed` for the matching ticked goals (with a note to the business), or disabled with a note if the name isn't ticked.
3. **Referral steps use ticked goals only.** Existing referral steps on event names: the name is ticked automatically as a goal during migration (so programmes keep working), with a note to the business.
4. **No SDK is published yet,** so there are no compatibility concerns. Remove `track()` and the old events endpoint completely (`POST /v1/sdk/events` / `GET /v1/app-events` are replaced by the goal intake and "Seen from your app and website"). The builder is asked to pause public SDK releases until change 22 ships.

## A. What was sent to ad networks, and why (Part 2)
**Today** (changes 02, 19, 21) the business sees the send log, test send, health screen and match quality. There's no plain explanation of why sending matters, no simple summary, no reminder to optimise campaigns for the event, and nothing on the person's timeline.

1. **"What this does" box** on the ad connection and event-mapping screens (fixed text, per network name):
   > "When a goal you've ticked happens, Clikgate sends it to {network}. Ad networks use the results you send to measure your ads, and you can set your campaigns to optimise for them, so the network looks for people more like the ones who completed this goal. How each network uses this data is up to them."

   It describes the networks' stated use, never promises results (change 19 D10, banned-word scan).
2. **"Sent to ad networks" summary:**
   - on each goal page and on Ad platforms: per network, for the last 7 and 30 days, events sent, accepted, skipped (top reasons in plain words) and the last sent time;
   - a badge on each ticked goal: "Sent to Meta, Google", or "Not sent to any ad network" with "Set up";
   - a metric registry source and widget for default and custom dashboards (change 16 / change 20).
3. **"Use it in your campaigns" checklist** per network and goal:
   - plain step-by-step text on choosing the event as the campaign's conversion or optimisation event (for example "In Meta Ads Manager, choose Purchase (from Clikgate) as the conversion event"), with links to each network's own help page (the builder checks current menus and wording);
   - a gentle note after 14 days of sending if the network's reporting API shows no active campaign optimising for that event, **only where the network exposes this**; otherwise the note isn't shown.
4. **Person timeline** (change 14): each goal shows its send status per network, for example "sent to Meta ✓ 8 Nov 10:42", or "not sent: no ad click", "skipped: consent", "skipped: payment not yet confirmed". It's visible to people with `people:view`; in private mode only the status, with no identifiers.
5. **Weekly summary** (optional, off by default) through the change 17 J notification channels (email, Slack, Teams): counts sent, accepted and skipped per network, with the top skip reasons. Counts only.

- **Wording rule:** only "sent", "accepted", "skipped" and dates. Never "will improve your ads", "better customers", "more sales" or "boost".
- **Plans:** Growth and up (where `conversion_sending` exists). Below Growth, the goal badge reads "Sending to ad networks comes with Growth".

## N. Weekly summary and the website section (Part 3)
**Goal:** build trust by showing that Clikgate tells the team what was sent and what was blocked, where they work.

### 3.1 Weekly summary gains fraud counts (extends Part 2 item 5)
- **Contents:**
  - results sent, accepted and skipped per ad network (top reasons);
  - **suspicious installs, clicks and referrals flagged or removed** by the organisation's fraud rules, and the value kept out of reports;
  - confirmed payments, refunds and disputes;
  - goals that stopped arriving (Part 1 checks).
- **Channels:** the change 17 J channels (email, Slack, Teams, mobile push). Big events stay immediate as today.
- **Counts and links only:** never names, emails, phones, customer IDs or labels; private mode is counts only. Fraud weights and thresholds are never shown.
- **Plans:**
  - sends and full fraud summaries: Growth and up;
  - basic alerts (payments, goals stopped): every plan where the channel exists.
- **Words:** "flagged as suspicious", "removed by your fraud rules". **Never "fake"** or "fraudster".

### 3.2 Website section (`clikgate-website`)
- **Where:** the home page and the ad networks page. Working title: "Know what happened, where your team works".
- **Text:**
  - results sent to ad networks (confirmed sales and sign-ups; how many skipped and why);
  - suspicious activity flagged or removed by your fraud rules, and the value kept out;
  - confirmed payments, refunds and disputes;
  - when goals stop arriving;
  - "Big events arrive straight away; the rest come in a daily or weekly summary".
  - Privacy line: "Messages carry counts and links back to Clikgate, never your customers' names, emails or phone numbers."
- **Picture:** a real Slack (and Teams) message rendered from the sample organisation's invented data, labelled "Sample". No customer names, numbers or logos.
- **Rules:**
  - shown only when the features are live (`GET /v1/public/features`);
  - plan labels (Growth and up for sends and full fraud summaries);
  - no result claims ("catches every fraud", "improves your ads", "saves ₦…");
  - no aggregate "blocked X" numbers until real, permitted data exists;
  - **no comparison with other tools** (change 21 R.40);
  - banned-word scan; never "fake".
- Also in `/facts` (change 21 J) and its `.md` copy: one factual line about notifications.

## E. Easy goal setup (Part 4)
1. **Suggested setup for common names.** A built-in list (`config/goal_suggestions.yml`) of common names and synonyms (for example `purchase`, `order_completed`, `checkout_completed`, `sign_up`, `signup`, `registration`, `account_opened`, `first_deposit`, `kyc_completed`, `first_trip`, `subscription_started`, `add_to_cart`, `lead`).
   - **When a matching name first arrives,** "Seen from your app and website" shows a suggestion card:
     - "Count this as a goal";
     - the **goal type** (for example `purchase` → payment goal, which needs a confirmed payment);
     - **suggested ad network events** (for example `purchase` → Meta Purchase, TikTok CompletePayment, Google purchase conversion; `sign_up` → Meta CompleteRegistration, TikTok CompleteRegistration; checked against each network's current standard events).
   - **Accept** applies all of it, **Edit** opens the normal screens, and **Dismiss** hides the card.
   - Never applied without a click.
   - Mappings only matter on Growth and up; below that, the card says "Sending to ad networks comes with Growth".
2. **"Also count this name as the same goal" (aliases).**
   - A goal can have several names, for example `purchase` from the app and `order_completed` from the website. Events with any alias count as that goal.
   - Dedup by `reference` across aliases, so the same order sent under two names counts once.
   - **Adding an alias:** "from now on" by default; the 30-day option follows Part 1 (with notice; never sent to ad networks).
   - **The rename detection** (Part 1) offers "Add as an alias".
   - **Limits:** 10 aliases per goal; a name can belong to only one goal.
3. **Typo and near-duplicate warnings.**
   - When a new name is close to an existing goal or alias, the list shows "Looks like `purchase`. Count it as the same goal?" with one-click "Add as alias". "Close" means:
     - edit distance ≤ 2;
     - differences only in `_`;
     - singular or plural;
     - a common separator change.
   - Also shown in "See it live".
   - Never merged automatically.
4. **"See it live" (change 20 F) shows names as they arrive** during the test, with **"Count this"**, the suggestion card and typo warnings inline, so testing and setup happen in one place.
   - Test-mode names are separate from live ones. Ticking in test mode offers "Also count this in live".

## S. Complete sweep of every SDK, integration and doc (Part 5)
The builder searches the **actual code in every repository** (not only the specs) and fixes every place that mentions `track()`, app events, Event rules, `app_event.received`, `/v1/sdk/events`, `/v1/app-events`, or "events and goals need Growth and up". Checklist (the builder adds anything else it finds):

- **Mobile SDKs:** Android (including the code comment the builder found), iOS, Flutter, React Native / Expo, and the Engage add-ons (Android, iOS, Flutter): public API, sample apps, READMEs, changelogs, inline docs, tests.
- **Web script** and its npm package.
- **Server SDKs:** Node, Python, PHP, Laravel, Java / Spring Boot, .NET, and any others built.
- **Integrations:**
  - WordPress plugin, Shopify app;
  - Google Tag Manager template (tag types and field names);
  - Zapier and Make apps (triggers and actions named after events);
  - HubSpot, Slack and Teams messages;
  - push.
- **Setup command** (`npx @clikgate/setup`): the code it writes, `doctor` checks, and templates.
- **AI guides** (`clikgate-skills`), `llms.txt`, `llms-full.txt`, and the `.md` copies.
- **Website docs:** SDK pages, the API reference (including "SDK protocol (advanced)", change 21 R.41), guides, FAQ, `/facts`, use cases.
- **Dashboard:**
  - snippet generators;
  - Attribution › App events (replaced);
  - Event rules (replaced);
  - webhook event pickers;
  - referral step pickers;
  - "See it live";
  - empty states and help text.
- **Backend:**
  - removed routes and schemas;
  - OpenAPI files (public, dashboard, staff);
  - webhook catalogue;
  - change 17 J notification catalogue;
  - seed and demo data (section T);
  - sample organisations (change 20).
- **The plan wording fix everywhere:** "Events and goals work on every plan, up to the plan's allowance. Growth and up add re-engagement, Apple Ads, install fraud scoring, and uninstall tracking on Pro."
- **Internal docs:** the sales handbook, if it mentions `track()` or Event rules (owner side).

**Automatic guard** so nothing slips back in: a CI check in every repository fails the build if public code, docs, samples, snippets or text files contain `track(`, `Clikgate.track`, `trackEvent`, `app_event.received`, `/v1/sdk/events`, `/v1/app-events` or "Event rules". It allows only the changelog entry that records the removal, and test files that assert the old endpoints return 404.

**Versions:**
- since no SDK is published yet, the first public release of each SDK is built after change 22, so **no public version ever has `track()`**;
- the changelog records the removal in the pre-release history.

## I. Identity made easy (Part 6)
**Owner concern:** "refreshing the secret may be stressful for server engineers and they may ignore it." **Decision: no scheduled or forced work.**

1. **`createIdentityToken(customerId, {appId?})`** in every server SDK (Node, Python, PHP, Laravel, Java, .NET):
   - reads `CLIKGATE_IDENTITY_SECRET`, or a per-app map for several apps;
   - returns `base64url(HMAC_SHA256(secret, customerId + "." + issuedAt)) + "." + issuedAt` (SDK spec 8.5);
   - no network call;
   - refuses to run in browser or mobile builds;
   - unit-tested against shared test vectors so every language produces identical tokens.
2. **Developers find it easily:**
   - the app settings page (identity secret) shows a copy-ready snippet per server language: "Add this to your sign-in response";
   - the mobile `identifyUser()` docs link to it;
   - the setup command and AI guides (`clikgate-skills`) add it when they set up `identifyUser()`;
   - **recommended pattern:** return the token in the responses the app already calls (sign-in, and the "current user" or "me" response at app open). That's one extra line, with no new endpoint.
3. **Clear failure reasons:**
   - the `identifyUser()` response returns `verified: true|false` and `reason`: `expired`, `wrong_customer_id`, `bad_signature`, `secret_rotated`, `no_secret_set`, or `not_yet_valid` (clock);
   - debug builds log it;
   - a dashboard **"Test a token"** box (customer ID + token → valid or why) that never reveals the secret or the expected signature;
   - a Part 1 health check: "{n}% of sign-ins this week had an invalid identity token ({reason})".
4. **Token life stays 30 days by default** (no change), adjustable from 1 to 30 days for businesses that want stricter. **No forced refresh.**
   - The mobile SDK quietly uses the newest token the app passes.
   - When a token expires, only features that need a verified identity (referrer actions, leaderboards with identity, "existing customer" checks) pause for that user, with reason `expired`. Nothing else breaks.
   - A health warning appears only if many users have expired tokens.
5. **Secret rotation only when the business chooses** (for example after a leak). **Never scheduled or forced.**
   - **Overlap:** after "Rotate", the old and new secrets both work for 7 days (adjustable from 0 to 30). Setting 0 means "stop the old one now", for a leak. The dashboard shows "Old secret stops working on {date}".
   - **Reminders** at 5 and 1 days before the old one stops, sent to Owners and Admins through the change 17 J channels.
   - Tokens signed with the old secret return `secret_rotated` once it stops.
6. **Optional no-token path** for teams that prefer it: the app sends `Clikgate.getInstallationId()` to its own backend at sign-in, and the backend calls the server SDK `identifyUser({appId, installationId, customerId, label?})` (change 14, already trusted through the API key). **No identity secret or token is needed.** The docs present both paths side by side; the token path is the default because it needs no extra server call.
7. **Mobile SDKs get a public `getInstallationId()`.** The specs define the installation ID (a UUID the SDK creates at first launch, kept in iOS Keychain and Android app storage) and the server `identifyUser({appId, installationId})`, but no public way for the app to read it. Add it to Android, iOS, Flutter and React Native, in each platform's style:
   - `Clikgate.getInstallationId()` (Kotlin), `Clikgate.shared.installationId` (Swift), `await Clikgate.getInstallationId()` (Flutter and React Native);
   - it returns the same value the SDK sends to Clikgate. Available right after `configure()`, it **waits for the first launch to finish** if called very early, and works offline.
   - **Returns null when tracking is off:** user opt-out, consent denied where required, or deep-link-only mode, so the app's server simply skips `identifyUser`.
   - Not personal data (a random ID); allowed in private mode.
   - **Docs** show the no-token path: read it, include it in the sign-in request to the business's own server, and the server calls `identifyUser({appId, installationId, customerId, label?})`.
   - The builder first checks whether such a getter already exists in code, and only adds or renames as needed (part of the Part 5 sweep).
8. **Docs: a dedicated page, "Identify your users"** (`/docs/identify-users`, website docs, with a `.md` copy, `llms.txt` and `llms-full.txt` entries, and AI guides in `clikgate-skills`). Plain words; code tabs for every mobile platform (Android, iOS, Flutter, React Native) and every server SDK (Node, Python, PHP, Laravel, Java, .NET).
   1. **What it does and when you need it:**
      - labels and the person timeline;
      - referrals and leaderboards that need a verified user;
      - "existing customer" checks;
      - **you don't need it** for anonymous users; they're tracked by click or installation.
   2. **What the customer ID is:** your own internal user ID from your database. **Never** an email, phone, BVN or NIN. Use the same ID on app, website and server. Not accepted in private mode.
   3. **Choose a path** (a short table):
      - **A: Identity token:** the server adds one line to the sign-in response, and the app passes it on. The default.
      - **B: Installation ID:** the app sends it to your server, and your server calls Clikgate. No secret or token.
   4. **Path A step by step:**
      - create the identity secret in Apps › {app} › Identity secret;
      - store it as `CLIKGATE_IDENTITY_SECRET` on the server only;
      - call `createIdentityToken(user.id)` in the sign-in and current-user responses;
      - the app calls `identifyUser(label?, customerId, identityToken)`.
   5. **Path B step by step:**
      - the app reads `getInstallationId()` and includes it in the sign-in request;
      - the server calls `identifyUser({appId, installationId, customerId, label?})`;
      - handle a null installation ID (tracking off) by skipping.
   6. **When to call:** after sign-in or sign-up; at app open when already signed in; **clear on sign-out**.
   7. **Labels:** what to put and what never to put (no balances or ID numbers); Growth and up.
   8. **Token life and rotation:**
      - 30 days by default, adjustable;
      - no forced refresh;
      - rotate only when you choose, with the 7-day overlap and reminders;
      - "stop now" for a leak.
   9. **Troubleshooting:**
      - every `reason` (`expired`, `wrong_customer_id`, `bad_signature`, `secret_rotated`, `no_secret_set`, `not_yet_valid`), what it means and how to fix it;
      - the dashboard "Test a token" box;
      - debug-log examples.
   10. **Security notes:**
       - the secret never goes in the app or website;
       - `createIdentityToken()` refuses browser and mobile builds;
       - what a copied token can and can't do.

   **Also:**
   - each mobile SDK's reference page documents `identifyUser()` and `getInstallationId()` and links to this page;
   - each server SDK page documents `createIdentityToken()` and `identifyUser()` with the link;
   - the setup command and the dashboard snippet generator follow Path A by default and mention Path B;
   - the Part 5 CI guard checks that every SDK reference page links to `/docs/identify-users`.

## M. Chart notes, targets and shared views (Part 7)

### 7.1 Notes on charts (every plan)
- **Table `chart_notes`** (`cnt_`): org, environment, date (or start and end), text (≤ 140 characters, banned-word scan), optional scope (whole organisation, or a campaign, link, app or goal), created_by, source `member` or `system`, timestamps.
- **Who:** members with edit rights to the area (change 13 permissions) add, edit and delete their notes. Owner and Admin can delete any note. Audit-logged.
- **Shown:**
  - as small markers on every time chart (dashboards, default dashboards, reports, App activity, goal pages) and in Present mode;
  - hovering shows the text and author;
  - scoped notes show only on charts filtered to that campaign, link, app or goal, or the whole organisation;
  - a "Notes" toggle hides them.
- **Automatic notes** (`system`, on by default, each type can be switched off), from facts Clikgate already has:
  - campaign created, paused or ended;
  - link created or destination changed (for links with more than 100 clicks a week);
  - app version first seen;
  - goal ticked or archived (Part 1);
  - "goals stopped arriving" (Part 1);
  - offer started or ended (change 20, staff only);
  - ad network connection broken or fixed.
- **Private mode:** no personal data in notes; a warning appears if text looks like an email or phone number.
- **Sample organisations** (change 20) include example notes.
- **API:** `GET` and `POST /v1/chart-notes` (scope `reports:view`, or `reports:manage` to write). Metric registry overlay.

### 7.2 Monthly targets with progress (every plan)
- **Targets on any counted goal**, and also on clicks, installs and confirmed revenue:
  - period: monthly (the default, in the organisation's timezone) or a campaign's dates;
  - scope: whole organisation, campaign, channel or app.
- **Shown:**
  - a progress bar "640 of 1,000 sign-ups (64%) · 12 days left" on Overview, goal pages, campaign pages and the default dashboards, plus a `target_progress` registry widget;
  - progress in the Part 3 weekly summary.
- **Facts only:**
  - done, remaining and days left;
  - never "on track", "will reach", "projected" or a forecast line (change 19 D10);
  - after the period: "Reached on 24 November" or "Ended at 870 of 1,000 (87%)".
- **Optional alert** when a target is reached (change 17 J channels), off by default.
- **Revenue targets** use confirmed payments only (change 11).
- **History:** past targets and results are kept and listed.
- **Who sets them:** `goals_payments:manage` (or the area's manage permission).
- **API:** `/v1/targets`.

### 7.3 Share a dashboard with someone outside Clikgate (Growth and up)
- **"Share by link"** on any saved or default dashboard (change 16 / change 20) creates a read-only link `https://app.clikgate.com/s/{random}`:
  - an unguessable random token, stored as a hash;
  - **expiry required** (default 30 days, at most 90);
  - **optional password** (rate-limited attempts);
  - revocable any time;
  - every view logged (time and country, no personal data) on the share's page.
- **What viewers see:**
  - the dashboard's charts and counts for its saved date range (an optional date picker the sharer allows);
  - chart notes;
  - target progress;
  - a "Shared view · {org name}" watermark;
  - Clikgate branding (agency branding where the plan has it, change 03).
- **Never shown:**
  - people, labels, customer IDs, click IDs, references, exports, settings;
  - any widget the sharer's role can't see;
  - anything private mode hides.
  - Widgets showing people-level data are replaced with "Not available in a shared view".
- **Security:**
  - `noindex`, no sign-in links, `Cache-Control: private`;
  - the Content Security Policy forbids embedding unless the sharer allows it;
  - data computed for the share's scope only (tenant-isolation tests);
  - rate limits.
- **Limits:** Growth 10 active shares, Pro and Enterprise 100.
- **Who:** members with `reports:manage` (`dashboards:share`).
- **Staff:** Owners see all shares in Settings › Shared links and can revoke all.
- Sample organisations can't create shares.
- **On downgrade below Growth:** links stop working with "This shared view is no longer available" (keep, hide, restore).

### Later list (not in change 22)
- Link naming rules (UTM governance) and presets.
- Campaign launch kit (one link per channel and a QR sheet).

## U. Uninstall tracking add-on and website page (Part 8)
- **New add-on `uninstall_addon`, "Uninstall tracking":**
  - **Growth only** (Starter lacks advanced app features; Pro and Enterprise already include it);
  - **₦37,500 ($25) a month**, following the plan period and discounts (change 20 I.2);
  - quantity 1;
  - local-currency prices set by `super_admin`.
- **Switches on** `uninstall_tracking` for the organisation's apps, with exactly Pro's behaviour:
  - uninstalls over time;
  - day 1, 7 and 30 uninstall rate;
  - by source and campaign;
  - "Real installs" on the default dashboards;
  - the Uninstalls widget.
- **Allowance:** `uninstall_checks` (change 01 meter; one per silent push) **300,000 a month**, about 10,000 active installs checked daily. (Pro stays at 500,000.)
- **At the allowance:** the change 01 rule for this meter applies (the scheduler stops sending checks until the next period; reports say "Uninstall checks paused: monthly limit reached").
  - Alerts at 80% and 100%, plus the change 20 "last month on Pro would have cost…" fact.
  - **No extra-usage charge for this meter** (keeps billing simple).
- **The one add-on rule** (change 20 I.2) applies: adding it as a second add-on shows "Request Pro instead".
- **Staff price editor warning** (extends change 20): Growth + Fraud protection + Uninstall tracking at 75% of Pro or more.
  - At seed prices: ₦75,000 + ₦67,500 + ₦37,500 = ₦180,000 (60% of Pro), so no warning.
- **Requirements unchanged:**
  - push setup (FCM/APNs keys) in the app's settings;
  - never used to message users;
  - private mode respected;
  - opt-out and consent honoured.
- **On removal or downgrade:** keep, hide, restore (change 14). Checks stop; history is kept and hidden.
- **Website pricing "Need just one more thing?"** (change 20 W.1) lists six add-ons. The docs and sales handbook are updated.
- **Tests:**
  - only Growth can buy it;
  - the entitlement switches on;
  - allowance pause;
  - the second-add-on prompt;
  - the editor warning;
  - removal keeps data;
  - plans API and pricing page values.
- **Website (owner, 2026-11-08): the website explains uninstall tracking properly.**
  - **Product page `/uninstall-tracking`** (or a section on the App activity / app attribution product page if one exists; the builder picks and links it from the menu, `/use-cases`, `/deep-links` and pricing). It covers:
    - **what it is,** in plain words: "See how many people delete your app, how soon, and which channels and campaigns bring people who stay";
    - **how it works:** a quiet daily check through the app's own push setup (Firebase / Apple). It never shows a notification and never messages anyone;
    - **what you see:** uninstalls over time; day 1, 7 and 30 uninstall rate; by source and campaign; "Real installs" (installs minus 7-day uninstalls). A screenshot from a sample organisation, labelled "Sample";
    - **plans:** included on Pro and Enterprise; **an add-on on Growth at {price from the plans API}**, with 300,000 checks a month (about 10,000 active installs checked daily); checks pause at the limit until next month;
    - **setup:** the app's push keys (FCM, APNs) in app settings; the SDK does the rest;
    - **honest limits:** needs push set up and the user's device reachable; iPhone and Android report differently; the counts are measurements, not perfect; users who turned off tracking or didn't consent aren't checked;
    - **privacy line:** no personal data; private mode respected.
  - **Pricing page** "Need just one more thing?": the Uninstall tracking add-on row (Growth), and the plan comparison row "Uninstall tracking: — · — · add-on · ✓ · ✓".
  - **Docs page** "Uninstall tracking" (setup per platform, what the numbers mean, troubleshooting), linked from each mobile SDK page, with a `.md` copy and `llms.txt` / `llms-full.txt` entries.
  - **`/facts`** (change 21 J): one factual line.
  - **Use-cases card:** "Find channels that bring people who keep your app".
  - **Rules:**
    - shown only when the feature is live (`GET /v1/public/features`);
    - prices only from the plans API;
    - no claims ("reduce uninstalls", "guaranteed"), no customer numbers, no competitor comparisons;
    - banned-word scan.

## V. Uninstall data for marketing (Part 9)
**Today:** the change 20 Marketing Overview "Uninstalls" widget only (over time; day 1, 7 and 30 rate; by media source; Real installs). It's missing from the Performance Overview, from campaign and referral breakdowns, from time-to-uninstall, and from the metric registry.

**Plans:** everything here needs `uninstall_tracking` (Pro and Enterprise, or Growth with `uninstall_addon`). Others see a preview with "Comes with Pro, or the Uninstall tracking add-on on Growth".

### 9.A Everywhere it matters
- **Performance Overview** (change 20 G.3) gains an **Uninstalls** section: day 1, 7 and 30 uninstall rate by media source, Real installs, and time to uninstall (9.B). Template versioning rules apply (unedited copies update; edited ones get "New widgets available").
- **Campaign table** (change 20 G.2 item 6): optional columns **7-day uninstall rate** and **Real installs**.
- **Breakdowns:**
  - source, campaign, ad creative (change 21 M.3);
  - referral programme, **individual referrer**, partner, creator;
  - link, country, platform, app version.
- **Metric registry source `uninstalls`:**
  - measures: uninstalls, uninstall rate d1/d7/d30, real installs, median time to uninstall, time-to-uninstall buckets, uninstalled-before-goal share, reinstalls, reinstall rate, cost per real install;
  - every breakdown above;
  - usable in custom dashboards, shared views (counts only) and Present mode.
- **API:** `GET /v1/analytics/uninstalls?from&to&group_by=…&interval=…`.

### 9.B How long until they uninstalled
- `time_to_uninstall` = detected uninstall time minus install `first_open_at`. Detection happens by daily silent push, so the precision is about 1 day, and the docs say so.
- **Shown as:**
  - the median;
  - buckets: same day, 1–3 days, 4–7, 8–30, more than 30;
  - per campaign, referrer and source.
- **Person timeline** (change 14, `people:view`): "Uninstalled about 3 days after install" and "Reinstalled on {date}".

### 9.C Things marketers will love
1. **Uninstalled before reaching a goal:**
   - the share of uninstalled installs that never reached the chosen goal (default: the organisation's end goal), for example "62% never signed up";
   - in funnels, an "uninstalled at this step" count per step (with Who's stuck, change 20 E.2).
2. **Cost per real install** = spend (change 02 / change 19 spend only) ÷ installs not uninstalled within 7 days, per source, campaign and creative. "No spend in Clikgate" where there's no spend.
3. **Reinstalls:** the reinstall count and rate, and the median time to come back. Uses the existing `is_reinstall` and Keychain or previous-installation matching (SDK spec §4).
4. **By app version:** the uninstall rate per app version, with the part 7 automatic chart note on each new version.
5. **Referral quality:**
   - a "Check these referrers" list (Growth and up with uninstall tracking): referrers whose referees' 7-day uninstall rate is far above the programme's usual rate, with minimum counts;
   - worded "flagged for review", **never "fraud"**;
   - links to the referrer's page;
   - feeds the change 02 fraud review queue as a signal. Its weight stays internal.
   - **Optional referral programme rule:** "Only count a referral if the friend keeps the app for {7} days" (1–30), off by default. Referrals wait in `holding` until passed, then qualify; uninstalled before that becomes `not_qualified: uninstalled`.
   - Partner and creator rewards follow the same rule if the programme uses it. Shown to partners only as "waiting".
6. **Alerts** (change 17 J; off by default; threshold adjustable): when a campaign's, referrer's, creative's or app version's 7-day uninstall rate is well above the organisation's usual rate (with minimum installs).
   - Wording: "Campaign 'Black Friday': 48% uninstalled within 7 days (your usual: 21%)."
   - Also in the part 3 weekly summary.

### Rules
- **Facts only:** "uninstalled within 2 days". Never "bad channel", "will churn" or "low quality".
- **The "usual rate"** is the organisation's own last 90 days.
- **Privacy:** counts only in shared views, the summary and alerts; private mode respected; no personal data.
- **Opted-out and non-consenting users aren't checked;** the docs explain that rates cover checked installs only.
- **Sample organisations** (change 20) get invented uninstall data for every widget.
- **The website `/uninstall-tracking` page** lists these views (time to uninstall, by campaign and referrer, uninstalled before a goal, cost per real install), with samples labelled "Sample".

### Tests
- every measure on fixtures (day boundaries, reinstalls, Keychain);
- breakdowns, including referrer;
- the registry source and widgets;
- template updates;
- cost per real install with and without spend;
- the funnel "uninstalled at this step";
- the referral 7-day rule (holding, qualify, not qualified);
- the "check these referrers" thresholds;
- alert thresholds and wording scan;
- plan gating and previews;
- private mode;
- shared views without people data.

## B. App banners results (Part 10)
**Today:** per banner, views, taps, dismissals, tap rate and installs (backend spec §24, change 16). App banners stay Growth and up (locked preview below).

### Where it lives (owner asked; there are only two default dashboards)
1. **Main place: the App banners page** (menu › App banners, change 16) gains a **Results** tab for all banners, and a Results section on each banner's own page. This holds the full detail below.
2. **The two default dashboards get compact widgets** that **appear only when the organisation has at least one published banner** (otherwise they're left out of the template, not shown empty):
   - **Marketing Overview:** "App banners" widget with the path to money (views → taps → installs → goal → confirmed revenue) and the "free installs" tile;
   - **Performance Overview:** "App banners performance" widget with tap rate, new vs existing users, right-screen rate, and the top 5 pages.

   Each links to the Results tab. Template versioning (change 20): unedited copies gain the widgets when the first banner is published; edited ones get "New widgets available".
3. **Custom dashboards:** metric registry source `app_banners` with every measure and breakdown below. Also in shared views (counts only), Present mode and the weekly summary.

### 10.1 The path to money
- **Per banner and in total:** views → taps → **opened the app** or **went to the store** → installs → **reached a goal** (chosen goal; default the end goal) → **confirmed revenue** (change 11 only).
- **Attribution:** banner taps are normal clicks with `app_banner_id`; installs, goals and payments follow the click's normal attribution (last click, windows unchanged).

### 10.2 New users vs existing users
- **Taps that opened the app for people who already had it** (change 21 existing-user opens) vs **new installs** vs **store visits with no install yet**.
- **Billing:** existing-user opens from banners follow change 21's free-opens rules.

### 10.3 Which pages and products work best
- **Breakdowns:** page path (stored without query strings; IDs in paths replaced by `:id`), page type (home, product, category, blog, other, inferred from the change 17 page rules where set), product (WooCommerce product pages, change 17), platform, country, and **the web visit's traffic source** (referrer category from the loader: search, social, email, direct, other; plus `utm_source` if present).
- No cookies or personal data, as in §24.

### 10.4 Opened the right screen
- The share of taps where the app reported handling the deep link for that page or product (change 20 S.1 `deeplink_handled`, sent only for banner and test flows when the banner's "measure right screen" setting is on; path only, IDs masked), vs the app's home screen or unknown.
- **Wording:** "Opened the matching screen: 87% of taps where the app reported it".
- **Alert** if it drops sharply (10.6).

### 10.5 Free installs
- **Tile:** "{n} installs from your website this month, no ad spend", plus goals and confirmed revenue from them.
- Shown next to paid channels in cost per new customer (change 14) as "No spend in Clikgate".

### 10.6 Dashboards and alerts
- **Registry source and widgets:** as above.
- **Weekly summary** (part 3): banner views, taps, installs and confirmed revenue.
- **Alerts** (change 17 J, on by default for organisations with published banners):
  - "Banner views continue but taps or installs dropped to zero for {24} hours" (script or link broken);
  - "Matching-screen rate fell from {x}% to {y}%".
- Facts only.

### Rules and tests
- **Facts only:** never "the banner will increase sales". Revenue is confirmed payments only. Growth and up.
- **Sample organisations** get invented banner data for every widget.
- **The website App banners page** lists these results with "Sample" screenshots.
- **Tests:** each funnel step and attribution; new vs existing split; page path masking; traffic source categories; right-screen rate; the free installs tile; conditional widgets in both templates; registry; alerts; plan gating; privacy.

## P. Cohort revenue, time to convert, Explore and freshness (Part 11)
### 11.1 Revenue and ROAS by day since install (cohort ROAS)
- **Install cohorts** (by day or by week, organisation timezone) by source, campaign, ad creative, channel, referral programme, country and platform.
- **For each cohort:**
  - installs;
  - spend (change 02 / change 19 spend for that cohort's dates and source);
  - **confirmed revenue** (change 11 only) **by day 0, 7, 14 and 30** after install (cumulative);
  - **ROAS** at each day (revenue ÷ spend);
  - revenue per install;
  - paying users (first confirmed payment).
- **Days a cohort hasn't reached yet show "—"** (never estimated or projected), following change 20 R.37.
- **Shown as:** a table plus a line chart (cumulative revenue per cohort), on a new **Measure › Cohort revenue** page.
  - Widgets: "ROAS day 7 by source" on Performance Overview (template versioning), and a registry source `cohort_revenue`.
- **Refunds** reduce revenue on the day they happen (change 11 reversals), shown with a footnote.
- **Plans:** Growth and up (retention and cohorts, change 20). ROAS needs connected or imported spend; without spend it shows "No spend in Clikgate".
- **Wording:** facts with dates; never "expected", "projected" or "will pay back". (Change 14's "payback looking ahead" wording is checked against D10 in the review.)

### 11.2 Time to convert
- **Measures:**
  - click → install (change 20 already);
  - **install → first goal** (chosen goal, default the end goal);
  - **install → first confirmed purchase**;
  - **click → first goal** (web and app).
- **Shown as:** the median, buckets (same day, 1–3 days, 4–7, 8–30, more than 30), and the share converted by day 1, 7 and 30, by source, campaign, creative, referral programme, platform and country.
- **Where:** goal pages, Measure › Time to convert, a registry source `time_to_convert`, and an optional widget on both default dashboards.
- **Plans:** every plan for click → goal; app measures where app attribution applies.

### 11.3 Explore (pivot table)
- **A new page Measure › Explore:**
  - choose **measures** (any registry measure the plan allows: clicks, installs, goals, confirmed revenue, spend, ROAS, uninstall rate, retention, time to convert, banner results…) and **breakdowns** (up to 3 levels: source, campaign, creative, link, country, city, platform, app version, referral programme, referrer, partner, creator, page, month or week or day);
  - filters, a date range with comparison, sorting, totals and subtotals;
  - **save** (personal, or shared with the team like change 16 dashboards);
  - **export** CSV or XLSX (`exports:run`);
  - "Add to dashboard" as a table widget.
- **Limits:**
  - up to 20 columns and 10,000 rows on screen (export streams more);
  - query timeouts with a friendly message;
  - viewer masking and private-mode rules from change 16;
  - people-level breakdowns (person, label, customer ID) are **not** available.
- **Plans:** Growth and up (saved and shared); Free and Starter see a limited version (2 measures, 1 breakdown, no saving).
- **API:** `POST /v1/analytics/explore` (same registry and permission checks).

### 11.4 "Data updated" note
- **Every report, dashboard widget, Explore, shared view and Present mode** shows "Updated {n} minutes ago" (from the newest rollup time for that data), with a tooltip explaining how often each source refreshes:
  - clicks: live;
  - rollups: about every 15 minutes;
  - ad spend: daily;
  - uninstalls: daily.
- **If a source is late** (more than twice its normal refresh), it shows "Delayed: last updated {time}", plus a staff alert (change 08 health).

### Tests
- **Cohorts:** cohort sums against fixtures (day boundaries, timezones, refunds, cohorts that haven't reached a day), ROAS with and without spend;
- **Time to convert:** buckets and medians;
- **Explore:** measures and breakdowns allowed per plan, masking, limits, save/share/export, "Add to dashboard";
- **Data updated:** freshness labels and the "Delayed" state;
- **Wording:** a scan for forecast words.


---

## Milestones
- **Backend:**
  1. **C22-B1:** G (goal intake, names list, ticking, migration from Event rules and app events, webhook and referral migration, removal of old endpoints) and the no-goals checks.
  2. **C22-B2:** E and I (suggestions, aliases, typo warnings, identity reasons, rotation overlap).
  3. **C22-B3:** S: SDK and integration changes (`track()` removed, `getInstallationId()`, `createIdentityToken()`, shared test vectors), the setup command and AI guides, and the CI guard in every repository.
  4. **C22-B4:** A and N (backend), and M (chart notes, targets, shared views).
  5. **C22-B5:** U and V.
  6. **C22-B6:** B and P.

  Regenerate the OpenAPI files (change 21 R.41 audiences); update `docs/PROGRESS.md`, `docs/DECISIONS.md`, `docs/ADS.md`, `docs/PLANS.md` and `docs/LAUNCH.md`.
- **Dashboard:**
  1. **C22-F1:** G and E screens (Seen from your app and website, tick dialog with the 30-day option and notices, suggestion cards, aliases, typo warnings, no-goals banner and Getting started item, "See it live" names).
  2. **C22-F2:** I (identity secret page with snippets, rotation, Test a token) and A (What this does, Sent to ad networks summary, badges, checklist, timeline status).
  3. **C22-F3:** M (chart notes, targets, Share by link and the shared view app), U and V (add-on purchase, uninstall widgets everywhere, Performance Overview section, campaign columns, referral rule and Check these referrers).
  4. **C22-F4:** B (App banners Results tab and conditional default-dashboard widgets), P (Cohort revenue, Time to convert, Explore, freshness notes), and the Playwright suite.
- **Website:** **C22-W1:** W.

## DB. Dashboard summary
Every screen named in G, E, I, A, N, M, U, V, B and P, built with:
- the change 16 registry, default dashboard template versioning (change 20);
- plan locks and previews;
- viewer masking and private mode;
- light and dark, phone and desktop, axe.

**Removed screens:** Attribution › App events and Event rules. Their URLs redirect to "Seen from your app and website".

## W. Website
- **N.2:** "Know what happened, where your team works".
- **U:** the uninstall tracking page, pricing add-on row and comparison row (six add-ons), docs page.
- **V:** the listed views on the uninstall page.
- **B:** App banners results on the App banners page.
- **I:** the "Identify your users" docs page, and SDK reference updates.
- **S:** every docs and SDK page swept, with `llms.txt`, `llms-full.txt` and the `.md` copies.
- **`/facts`:** lines for notifications and uninstall tracking.
- **Use-case cards:** uninstall.
- **Checks:**
  - live features only;
  - prices from the plans API;
  - no comparisons (change 21 R.40);
  - banned-word and forecast-word scans;
  - the S CI guard;
  - Lighthouse and accessibility.

## T. Final test run, database reset and demo data
Follow change 16 section T and changes 20–21 T, with these additions:
- **Bloom Foods (demo), Pro:**
  - "Seen from your app and website" with 8 names: 5 ticked (one with an alias, one added with the 30-day option and its notice), 2 unticked, 1 typo suggestion;
  - a "goals stopped arriving" alert with a likely rename;
  - Sent to ad networks summaries for Meta and Google;
  - chart notes (member and system);
  - two targets (one reached, one in progress);
  - one shared view link (with a password);
  - uninstall data across every widget, including Check these referrers and an alert;
  - App banners results with all widgets;
  - cohort revenue for 8 weekly cohorts;
  - time to convert;
  - two saved Explore views.
- **Growth demo:** the Uninstall tracking add-on at 85% of its checks.
- **Identity:**
  - an identity secret in its 7-day rotation overlap;
  - one valid and one expired token shown in "Test a token" examples;
  - a user identified via the installation ID path.
- **Sample organisations** gain these features.
- **The final report:** test counts and coverage per repository, the sign-in table, and confirmation that the CI guard passes in every repository.

## Definition of done
- `track()`, app events and Event rules are gone everywhere, and the CI guard passes in every repository.
- `goal()` names appear and count only when ticked.
- The no-goals checks work.
- Identity can be set up with one line by either path, with clear reasons on failure.
- Ad network sends are explained and summarised.
- The weekly summary and website section are live.
- Chart notes, targets and shared views work.
- The uninstall add-on is sold on Growth, and uninstall data appears everywhere described.
- App banners results and widgets work.
- Cohort revenue, time to convert, Explore and freshness notes work.
- All tests pass, including every earlier change.

## Before building: things only the owner can provide
- **Pause the public SDK releases** until this change is built.
- **Decide the copy for the "What this does" box** if you want different words (the default is in A.1).
- **Lawyer:** a quick look at the shared-view-by-link terms (who may receive links), and the referral rule wording for partners.

---

## R. Review fixes (these win over every earlier section)
An independent review checked this change against changes 01–21, the SDK spec (§4, §7.4, §8.3–8.6, §10–§12) and backend spec §24. Each rule below replaces the earlier text it names.

### Things that still depended on `track()` and app events
- **R.1 [G.1, S]** Referral and leaderboard pieces:
  - referral steps `{"event": …}` (SDK spec §8.3) become `{"goal": key}` (change 09 E11), and `min_revenue_minor` becomes `min_value`;
  - step property filters are dropped in migration, with a note to the business;
  - the `$identify` step becomes `{"identify": true}`;
  - the leaderboard `step_event` becomes `step_goal`;
  - `POST /v1/referrals/{id}/steps` takes `{goal}`, and webhook `referral.step_completed` carries `goal`.
- **R.2 [G.1]** Remove `POST /v1/apps/{app_id}/events` (SDK spec §10) and `/v1/apps/{id}/event-rules`. `POST /v1/goals/events` accepts `(app_id, installation_id)` or `customer_id` in place of `click_id` / `code` if it doesn't already. Both old routes go in the 404 tests.
- **R.3 [G.1]** Funnels: remove the "App event" step type (change 05). Stored `app_event` steps become goal steps on the ticked goal of that name. Who's stuck and Progress use counted goals only.
- **R.4 [G.1]** Remove "events by name" and "revenue" from `GET /v1/analytics/apps/summary` (SDK spec 10.3), replaced by counted goals and confirmed revenue. App-sent values are never revenue anywhere.
- **R.5 [S]** The iOS SDK doesn't update SKAdNetwork / AdAttributionKit conversion values from `goal()` (change 19 B.3.3 lists conversion-value schemas as not built). Delete any on-device update code and `conversion_value_schemas` from `/v1/sdk/config` in the sweep.
- **R.6 [B.10.4, change 20 R.40]** `deeplink_handled` in live mode:
  - **When it's sent:** live mode too, but only when the opening click has an `app_banner_id` and that banner has "measure right screen" on (the SDK learns this from `/v1/sdk/resolve`). This amends change 20 R.40.
  - It's an internal SDK signal: never in "Seen from your app and website" and never metered. The S sweep keeps it.
  - Tests.
- **R.7 [G.1, change 05 B.4]** Event rules using `value_property` migrate to ticked goals without value mapping; the business is told to pass `value` in `goal()`. Rules pointing at payment goals stay off (change 12).

### Ticking, metering and billing
- **R.8 [G.1, change 01 B.5]** The meter is `attributed_events`. "Counted when": an attributed install, or a **counted goal event**.
  - **A goal event counts when** its goal is ticked and it isn't a duplicate. Payment goals are metered once, at confirmation.
  - **Never metered:** unticked names, waiting payment reports and duplicates. Refunds don't return usage.
- **R.9 [G.1, change 12 B.3]** Add `received` to `GoalStatus` ("stored, not counted"). `goal()` with an unticked name returns `200 {status: "received", reason: "not_counted_yet"}`. SDKs treat it as success and don't retry.
- **R.10 [G.1, change 05 B.1]** Archived goals no longer return `410 goal_archived`:
  - events are stored as `received` with reason `goal_archived` for 30 days;
  - the list shows "Archived goal · Count again";
  - "Count again" un-archives.
- **R.11 [G.1]** Goals created on the Goals page or via `POST /v1/goals` are ticked from creation. Only names arriving without a goal start unticked.
- **R.12 [G.1, change 20 R.12/R.16, I.3]** Including the last 30 days:
  - **the notice shows count and money:** "Counting {n} events adds {amount} to this month's extra usage". Nothing is billed without it;
  - **usage month:** all backfilled events count in the current usage month;
  - **limits:** events are counted in order up to the allowance plus any extra-usage limit, and on Free up to the 1,000 hard limit. The dialog says "{x} of {n} can be counted now"; the rest stay `received` until they expire;
  - test mode is never billed.
- **R.13 [G.1]** Backfilled events:
  - never move referral states, partner earnings, challenges or leaderboards;
  - never go to any destination (`conversion_send`, `ga4_forward`, HubSpot, Zapier/Make);
  - fire `goal.completed` only if the business ticks "Also send webhooks", with `backfilled: true`.

  The dialog says this.
- **R.14 [G.1]** Abuse caps for unticked events:
  - at most 10,000 stored per name per day and 100,000 per organisation per day; beyond that only a daily count is kept;
  - the backfill covers stored events only, and the dialog says so;
  - staff are alerted when a cap is hit.
- **R.15 [G.1, E.1, change 12 B.2]** Ticking a name as a **payment goal**:
  - the dialog shows the share of the last 30 days' events that had `provider` and `reference`, and warns that calls without them are refused (`payment_goal_needs_confirmation`);
  - a backfill turns only events with both into payment reports (status `waiting`), which count only when confirmed. No backfilled value is ever revenue.
- **R.16 [G.1, change 09]** For a name from a website with "Allow from browser" off, the tick dialog shows that switch. Ticking alone doesn't make browser events count.

### Aliases and dedup
- **R.17 [E.2, change 09 E1]** Dedup on `(organization_id, goal_id, reference_hash)` using the canonical goal.
  - `goal.completed`, the send log and exports carry the canonical `goal` plus `received_as`.
  - The docs say the SDK generates a random reference when none is given (change 05 B.4), so app and website sends match only when both pass the same real order reference.
- **R.18 [E.2]** A ticked goal with its own history can't become an alias ("Archive `{name}` first, or keep both goals"). `/v1/server-sdk/config` `goals[]` lists aliases.
- **R.19 [E.3]** "Close": names of 5 characters or fewer use edit distance 1; longer names use 2.

### "No goals arriving" checks
- **R.20 [G.0, G.1]** Exact defaults (adjustable with `goals_payments:manage`):
  - **only apps and websites that have had at least one counted goal are checked;** before that, only the Getting started item shows;
  - **"active":** at least 20 active installs a day (app) or 50 tracked clicks a day (website), on each of the 3 days;
  - **usually busy:** arrived on 20 or more of the last 28 days, with a median of 5 or more a day;
  - **rare goals:** the window is the larger of 2 days and 3 × the longest gap in the last 28 days, capped at 14;
  - **payment goals:** reports and confirmations both count as arrivals;
  - **likely rename:** the new name first arrived within ±1 day of the old one stopping.
- **R.21 [G, A, M, U, V, B, I]** New change 17 J catalogue keys, each with a default, routing permission and test:
  - `goals_stopped`, `identity_tokens_invalid`, `identity_secret_rotation`;
  - `target_reached`;
  - `uninstall_checks_usage`, `uninstall_rate_high`;
  - `banner_drop`, `banner_right_screen_drop`;
  - `weekly_summary`.

### Identity
- **R.22 [I.3]** Failure reasons:
  - drop `wrong_customer_id`, because HMAC can't tell it from `bad_signature`;
  - `secret_rotated` means the token checks against a retired secret. Retired secrets are kept encrypted for 90 days after they stop working, then deleted, and become `bad_signature`;
  - `not_yet_valid` means `issuedAt` is more than 5 minutes ahead.
- **R.23 [I.3]** Logging and "Test a token":
  - debug logs, "Test a token", the audit log and server logs never contain the token, customer ID or secret; only the reason and app ID;
  - "Test a token" needs `apps_sdk_keys:manage`, is dashboard-only (no public API), allows 20 tries per member per hour, and stores nothing.
- **R.24 [I.4, SDK §8.3–8.4]** If a referee's token has expired, referrals needing the "existing user" check stay in `holding` (up to the hold window). They never qualify unverified, and the check never fails open.
- **R.25 [I.6, change 14]** Path B (`POST /v1/people/identify` with `app_id` + `installation_id`) is verified and satisfies `require_identity_token`.
  - Accepted only for installations active in the last 7 days.
  - Moving an installation between customer IDs is audit-logged without either ID, and counts toward a staff anomaly alert.
- **R.26 [I.7]** `getInstallationId()`:
  - **async everywhere:** `suspend` / callback on Android, `try await Clikgate.shared.installationId()` on iOS (not a stored property), `await` on Flutter and React Native. It never blocks the main thread;
  - **value:** the current installation's ID, which is new after a reinstall. iOS reports the previous one as `keychain_previous_installation_id` (SDK §4);
  - **docs:** Path B servers call `identifyUser` at every signed-in app open.
- **R.27 [I.1]** `createIdentityToken()` throws `ClikgateServerOnlyError`:
  - **Node:** when `window`, `document` or React Native (`navigator.product === "ReactNative"`) is detected;
  - **Java:** when `android.os.Build` loads;
  - **.NET:** under MAUI / Xamarin.

  Tests per language; shared test vectors include non-ASCII customer IDs.

### Shared views and Explore
- **R.28 [M.7.3, changes 13/16]** There is no `dashboards:share`. Creating and revoking links needs `reports:manage` plus 🔐 (change 09).
  - Settings › Shared links is for Owners and Admins (not staff).
  - A share stops when its creator leaves or loses `reports:manage`.
  - Widgets are checked against the creator's **current** role and plan at every view.
- **R.29 [M.7.3]** Link security:
  - `/s/{token}` is redacted in every log (origin, Cloudflare, Sentry, analytics);
  - `Referrer-Policy: no-referrer` and `Cache-Control: no-store`;
  - the page swaps the token for a 1-hour view cookie, and data calls use the cookie, never the token in a URL;
  - passwords use argon2id; 10 wrong tries lock that IP for 15 minutes;
  - view logs keep the country only;
  - live data only.
- **R.30 [M.7.1, M.7.3, V.9.A]** Left out:
  - **shared views** show no note author names and no breakdowns by referrer, partner or creator ("Not available in a shared view");
  - **alerts and the weekly summary** say "{n} referrers flagged for review" with a link, never names or codes.
- **R.31 [M.7.3, owner rule]** "Links never break" covers short links and redirects. Shared-view links are reports and may stop after a downgrade (keep, hide, restore).
- **R.32 [P.11.3]** Explore:
  - referrer, partner and creator breakdowns need `referrals_leaderboards:view` or `partners:view`, and are hidden in private mode;
  - Free and Starter can't export from Explore; exports follow change 02 plan rules and `exports:run`;
  - the API needs `analytics:read`.
- **R.33 [M.7.1, M.7.2]** Permissions and endpoints:
  - chart notes: write with `reports:manage`; `PATCH` and `DELETE /v1/chart-notes/{id}` exist;
  - targets: `reports:manage`, with `/v1/targets` GET, POST, PATCH and DELETE;
  - "offer started or ended" notes show in the staff console only, never on customer charts.

### Uninstalls
- **R.34 [U, change 01]** The add-on and plan limits:
  - Growth's plan-version `uninstall_checks` stays 0, and the add-on adds 300,000 through its entitlement;
  - bought mid-month, the full 300,000 applies until the end of that usage month;
  - moving to Pro ends the add-on with a credit line and the allowance becomes 500,000.

  Tests.
- **R.35 [U, change 20 I.2]** The staff editor warning becomes general: **any plan + add-ons at 75% of the next plan or more.** Change 20's "Growth + Fraud + SSO at 100%" warning stays.
- **R.36 [V.9.C.5, SDK §8.3/8.6]** No new rule or state for "keep the app N days". The UI sets the existing `hold.days` and `hold.require_installed: true`.
  - **Uninstall during hold:** the referral goes to `disqualified`, reason `uninstalled` (not `not_qualified`).
  - **Partner earnings** stay `on_hold` (change 16); "waiting" is display text only.
  - **While uninstall checks are paused** (limit reached or no push), referrals keep holding until checks resume or the hold window ends, then qualify with the note "uninstall check unavailable".
- **R.37 [V.9.A, V.9.C]** Day-7 and day-30 rates, Real installs, cost per real install and "uninstalled before goal" show "—" for installs younger than the window. Never estimated.

### Banners and cohorts
- **R.38 [B.10.3]** Page paths:
  - strip the query and fragment;
  - replace with `:id` any segment that looks like an ID, email, phone or token (numbers, UUIDs, 16+ hex characters, or 6+ digits mixed with letters);
  - at most 200 characters;
  - `utm_source` keeps the organisation's top 50 values, the rest become "other";
  - private mode stores the page type only.
- **R.39 [B.10.5]** The tile reads "{n} installs from your website this month · no ad spend recorded in Clikgate". The word "free" isn't used.
- **R.40 [B.10.6]** The "dropped to zero" alert fires only if the last 7 days averaged 20 or more taps (or 5 or more installs) per 24 hours.
- **R.41 [P.11.1]** Cohort ROAS:
  - **spend** is matched by spend date = install date, only where spend exists for that breakdown (source, campaign, and creative where reported). Country, platform, channel and referral programme show "No spend for this breakdown";
  - **"day N"** means within N × 24 hours of `first_open_at`;
  - **currency:** revenue is converted to the reporting currency at the payment date's rate.
- **R.42 [P.11.1, change 14 B.3]** Change 14 payback wording, checked against D10:
  - replace "looks ahead 180 days" with a past fact: "Customers won {from}–{to} paid back their cost in {n} days";
  - rename the bands `healthy|ok|below_cost` to "3× or more", "1–3×" and "below cost".

### Weekly summary, CI guard and API
- **R.43 [A.5, N.3.1]** There is one `weekly_summary` notification, off by default, with sections gated by plan:
  - sends and the full fraud section: Growth and up;
  - payments, goals stopped and targets: every plan.
- **R.44 [S]** The CI guard matches Clikgate identifiers only:
  - `\bClikgate(\.shared)?\.track\b`, `clikgate\.track\(`, `trackEvent` in Clikgate SDK sources;
  - `app_event.received`, `/v1/sdk/events`, `/v1/app-events`;
  - "Event rules" (case-sensitive).

  It excludes third-party code and migration guides (Adjust's `trackEvent`, Segment's `track(`), `docs/specs/`, database migrations, and the webhook and referral migration code.
- **R.45 [G, DB]** Names:
  - **tables:** `goal_names` (`gnm_`, per organisation, environment and source); `goal_aliases`; `goal_name_events` (partitioned, deleted after 30 days, included in privacy requests);
  - **endpoints:** `GET /v1/goal-names`; `POST /v1/goal-names/{name}/count` `{include_last_30_days, goal_kind, send_webhooks}`; `POST` / `DELETE /v1/goals/{id}/aliases`;
  - **permissions:** `goals_payments:view` to read, `goals_payments:manage` to change.

  A test for each.
