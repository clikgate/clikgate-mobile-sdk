# Clikgate Change 21 — Free App Opens for Existing Users, Deep Links and Firebase Migration, a Website AI Assistants Read Correctly, Click-to-WhatsApp Sales, Match Quality, Ad Creatives, X Ads, Live Chat Support, and Company-Email-Only Staff Sign-in

> **Instructions for the AI building this:**
> - Changes 01–20 are built; nothing is live yet.
> - **The parts, built in this order:**
>
>   | Part | What | Plan |
>   |---|---|---|
>   | P | **App opens by existing users aren't counted** (up to a cap), and Free gets **5,000** counted clicks | All |
>   | Z | **Staff sign-in:** `@clikgate.com` only, emailed code plus authenticator, one emergency account | Staff |
>   | M | **Ads:** Click-to-WhatsApp sales sent to Meta, match quality, ad creatives, **X ads** | Growth and up (X spend also with the Starter Ad spend add-on) |
>   | L | **Live chat support** with tawk.to on the website and dashboard | All |
>   | K | **Deep links page refresh** and **moving from Firebase Dynamic Links** | Website, link import |
>   | J | **A website AI assistants read correctly** (facts page, full FAQ, text copies, `llms-full.txt`, crawler rules) | Website |
>
> - **Backend repository** (`clikgate`): sections 0, P, Z, M, L (backend parts), K.2 (import preset), S and T.
> - **Dashboard repository** (`clikgate-dashboard`): sections 0 and DB, and T.
> - **Website repository** (`clikgate-website`): sections 0, W (with K and J) and L.4.
> - **How to build and test (owner's routine, same as changes 16–20):**
>   - build every milestone in order first, writing the tests with each, without running the full suite after each one;
>   - when everything is built, run the full test suite once, fix every failure, and re-run until all pass;
>   - then follow section T.
> - **Check current documentation before building, and record findings with dates in `docs/DECISIONS.md` (and `docs/ADS.md` for ads):**
>   - Meta Conversions API for business messaging (Click-to-WhatsApp), the WhatsApp Cloud API message `referral` object, and Meta event match quality reporting;
>   - X Ads API (OAuth, accounts, analytics, Conversions API, rate limits, terms), and **confirm in X's developer console that Ads API access has no charge for approved developers**;
>   - creative and ad fields for Meta, Google, TikTok, LinkedIn and Snap;
>   - Firebase Dynamic Links (shutdown status and export options);
>   - tawk.to (embed, secure mode, JavaScript API);
>   - the current names of AI answer and search crawlers and AI training crawlers.
>
>   Never guess.
> - **Reuse:**
>   - change 01: meters, plan versions, entitlements, staff auth (B.6), staff CLI;
>   - change 02: ad connections and spend;
>   - change 03: link import, `/switch` pages, consent, schema.org, trust centre and sub-processor list;
>   - change 06: `llms.txt`, `.md` docs;
>   - change 09: banned-word scan, staff alerts;
>   - change 10: support row E.4, deep linking page D.8;
>   - change 14: `acquired_via`;
>   - change 16: metric registry, `/cg/keep`, section T;
>   - change 19: ad network framework, confirmed-only guard, hashed matching, private mode rules, D10;
>   - change 20: plans API everywhere, `GET /v1/public/features`, the use-cases page, extra usage, the limit and billing usage boxes;
>   - SDK spec: WhatsApp 9C, `app_opens` and installs.
> - **Section R (review fixes) at the end of this file wins over any earlier text it changes.**
> - **Owner rules:**
>   - links and redirects never stop working because of plan, usage or payment;
>   - revenue counts confirmed payments only;
>   - describe what happened, never predict (change 19 D10);
>   - no accuracy, uplift or results promises;
>   - never log secrets, tokens, emailed codes, hashed identifiers, click IDs with personal data, customer IDs or labels;
>   - Clikgate never messages the business's customers;
>   - never "unlimited", "guaranteed", "forever", "free forever", "official partner" or "certified";
>   - no competitor comparison pages.

---

## 0. Decisions

| # | Decision |
|---|---|
| D1 | **Prices don't change.** Free counted clicks become **5,000** a month (was 1,200). All other allowances, extra-usage prices and add-ons stay as change 20. |
| D2 | **A click that opens the app for a device that already has it isn't counted,** up to a monthly cap: Free 20,000, Starter 200,000, Growth 2,000,000, Pro 20,000,000, Enterprise custom. Above the cap, such opens count as normal tracked clicks. |
| D3 | **Staff sign in with an `@clikgate.com` email only:** email, then a code emailed to that address, then an authenticator code. No passwords, except for one emergency account: the server-created super admin (`break_glass`), whose every use alerts all super admins. |
| D4 | **Click-to-WhatsApp, match quality, ad creatives and X ads** build on the change 19 framework. Growth and up (X spend also with the Starter Ad spend add-on). |
| D5 | **Live chat (tawk.to) on every plan.** "24/7 chat support" shows only while the staff setting `live_chat_247` is on (default off). Never publish a response time. |
| D6 | **Deep links and Firebase:** no new plan or price. A refreshed page, a switching guide, an import preset and SDK docs. |
| D7 | **The AI-readable website** changes no design. Two footer links are added. AI answer and search crawlers are allowed on public pages; AI training crawlers are blocked. |

---

## P. Free app opens for existing users, and 5,000 Free clicks

### P.1 Plan version
A new version for every plan (`created_by: system`, `apply_to: all_now`, idempotent):
- **Free `tracked_clicks`:** 5,000.
- **New meter `existing_user_opens`** with monthly allowances:

  | Plan | Allowance |
  |---|---|
  | Free | 20,000 |
  | Starter | 200,000 |
  | Growth | 2,000,000 |
  | Pro | 20,000,000 |
  | Enterprise | custom |

  It has no price of its own (see P.3).
- **Everything else** is copied from the current version.
- **Change 01's Free rule** (click counting pauses past 120% of the allowance) now applies to 5,000.

### P.2 What isn't counted
A click is an **existing-user open** when both are true:
- it opened the app on a device whose **install existed before the click**: an SDK open (`/v1/sdk/open` or `/v1/sdk/resolve`) carrying the click, for an `install_id` first seen earlier than the click time;
- it isn't flagged as fraud or a bot (change 02 / change 10 checks).

**Counted as normal tracked clicks** (no change):
- clicks by people without the app;
- clicks that lead to a store, an install or a reinstall (including deferred deep links);
- clicks that only open a website;
- clicks on links with no app.

### P.3 Counting and settling
- **Links that open the app directly** (Universal Links / App Links, no redirect): the SDK open is the click. When P.2 holds it's recorded as an existing-user open; otherwise it's a tracked click.
- **Links that hit the redirect first** (in-app browsers, then the app opens):
  - the click counts as a tracked click at once;
  - if the SDK confirms an open for an existing install **within 10 minutes**, it's moved from `tracked_clicks` to `existing_user_opens` (a reversing entry in `usage_daily`, same day and organisation);
  - **billing, the extra-usage limit, alerts and the Free 120% rule** all use settled counts (settled 15 minutes after the click).
- **The cap:**
  - while `existing_user_opens` is under its allowance, a qualifying open goes there;
  - once it's reached, further qualifying opens count as `tracked_clicks`.
  - The billing month and Lagos time follow change 01 and change 20 R.13.
- **Alerts** at 80% and 100% of the `existing_user_opens` allowance (change 17 J catalogue, change 20 H.1 channels).
- **Reports** still show every open and click: the link and campaign reports gain a split "New visitors / Existing app users". Re-engagement crediting (Growth and up) is unchanged and is not billed. Goals sent afterwards are metered as today.
- **Test mode** has no meters.

### P.4 Abuse checks
- Only SDK opens from real installs (change 10 install checks) qualify; an install first seen within 60 seconds of the click never qualifies.
- **Staff console › Billing:** an "Unusual share of free opens" list (organisations where existing-user opens are more than 95% of clicks with fewer than 100 installs a month, or other sudden jumps), with reasons. Staff decide; nothing happens automatically.

### P.5 API and surfaces
- `GET /v1/billing/usage` gains `existing_user_opens {used, allowance}`.
- The plans API gains the new allowance.
- The calculator gains an input "Links opened by people who already have your app".
- The change 20 hard-coded price scan also covers the new numbers.

### P.6 Tests
- P.2 rules (install before click, the 60-second rule, fraud excluded, store and install clicks counted);
- direct opens versus redirect-then-open;
- settling within and after 10 minutes;
- reversal entries;
- cap reached mid-day;
- alerts;
- the Free 120% rule at 5,000;
- extra usage and the limit (change 20) on settled counts;
- reports split;
- the staff list;
- the plan version is idempotent.

---

## Z. Staff sign-in: company email only

### Z.1 Allowed domain
- **Env:** `STAFF_EMAIL_DOMAINS` (comma list). **Production must be exactly `clikgate.com`,** or startup fails. Development and staging may add a test domain.
- **Checked on the server at:**
  - the create CLI;
  - inviting and accepting an invite;
  - changing a staff email;
  - every sign-in step.
- **Matching:**
  - the part after the last "@", lower-cased, must equal an allowed domain exactly;
  - no subdomains;
  - a "+" in the local part is refused;
  - Unicode look-alikes are refused (ASCII only).
- **Failure:** `403 staff_email_domain_not_allowed`, audit-logged with the attempted domain only.

### Z.2 Sign-in (replaces the change 01 B.6 password step)
1. `POST /v1/staff/auth/email` `{email}` returns `{challenge_id}`, and **always the same reply** whether or not the email is staff.
   - For an active staff email, a 6-digit code is emailed to it:
     - valid 10 minutes, single use, stored only as a hash;
     - a new request cancels the old one;
     - at most 5 sends an hour per email and per IP.
   - The email shows the time, browser and IP country, and "If this wasn't you, tell a super admin".
2. `POST /v1/staff/auth/email/verify` `{challenge_id, code}`:
   - 5 wrong codes cancel the challenge;
   - success moves the challenge to "needs authenticator".
3. `POST /v1/staff/auth/verify` `{challenge_id, totp_code | recovery_code}` creates the session (change 01 TOTP rules, lockout and audit).

**Unchanged:** 🔐 fresh authenticator codes, 🔑 the price code, 8-hour and 30-minute session limits, `STAFF_IP_ALLOWLIST`, and the audit log.

**Codes are never logged.** An email sending failure shows "We couldn't send the code. Try again, or contact a super admin."

### Z.3 Invites and enrolment
- An invite link opens enrolment: an emailed code check (Z.2 steps 1–2), then TOTP enrolment and recovery codes (change 01).
- **No password is set.**

### Z.4 Emergency account (`break_glass`)
- **Who:** the super admin created with `python -m app.staff.create --email … --name … --role super_admin` is marked `break_glass`.
- **The flag:**
  - **only one** at a time;
  - set **only from the server CLI**, never from the console or API;
  - `--replace` moves the flag (the old account loses it and its password) and alerts all super admins;
  - it must still be an allowed-domain email.
- **Sign-in:**
  - `break_glass` keeps **password plus authenticator** (`POST /v1/staff/auth/login` → `/verify`, change 01);
  - it can also use the Z.2 path.
- **Every password sign-in** by `break_glass`:
  - emails all super admins and raises a critical staff alert;
  - appears on staff Home for 7 days;
  - is audit-logged.
- **Recovery:** password reset needs the old password plus TOTP (change 01).

### Z.5 Migration
- Passwords are removed from every staff user except `break_glass`.
- Staff whose email isn't allowed are **disabled, never deleted**. Their sessions are revoked, and they're listed in the migration output and audit log.
- The password login route refuses non-`break_glass` users (`403 password_login_not_allowed`).

### Z.6 Tests
- domain matching (look-alikes, subdomains, uppercase, "+", Unicode) at every entry point;
- the same reply for unknown emails;
- code expiry, reuse, replacement, wrong-code and send limits;
- the authenticator is still required;
- invites without passwords;
- `break_glass`:
  - CLI-only;
  - only one;
  - `--replace`;
  - alerts;
  - password sign-in refused for others;
- the migration;
- production startup check;
- a log scan for codes and challenge IDs.

---

## M. Ads: Click-to-WhatsApp sales, match quality, ad creatives, X

### M.1 Click-to-WhatsApp sales sent to Meta (Growth and up; needs `whatsapp_attribution` and `conversion_sending`)
- **Capture:** when a WhatsApp channel is connected by `cloud_api`, or `forwarded` in the Cloud API format (SDK spec 9C), the first inbound message's `referral` object is read.
  - Source type `ad`, the ad ID (`source_id`), and the Click-to-WhatsApp click ID (`ctwa_clid`).
  - It's stored on `whatsapp_conversations`: `ad_platform` (`meta`), `ad_source_id`, `ctwa_clid` (encrypted at rest, never logged), `ad_referral_at`.
  - The conversation is credited to that ad, its ad set and campaign (mapped through change 02 spend sync), with `acquired_via = meta_ads` and channel `whatsapp`.
- **Linking the payment:**
  - a confirmed payment (change 11) is linked to the conversation through `whatsapp_ref`, `whatsapp_contact` (hashed), or the business's payment metadata (`clikgate_whatsapp_ref`), within the attribution window;
  - only confirmed payments.
- **Sending:**
  - Meta Conversions API for business messaging: action source business messaging, messaging channel WhatsApp;
  - `ctwa_clid`, event name from the change 19 mapping (Purchase for payments, chosen goals for others), value, currency, event ID;
  - the WhatsApp Business account ID or page ID as Meta's current documentation requires.
  - It runs through the change 19 pipeline: confirmed-only guard, retries, health, and approval and permission scopes; the connection needs the scopes Meta requires for business messaging events.
- **Private mode:** only `ctwa_clid`, event, value and currency are sent. Hashed phone numbers only per the change 19 private-mode rule.
- **Not covered:** chats not started from a Meta ad, and channels connected only by `wa.me` links (those keep Clikgate's own ref attribution).
- **API:** `GET /v1/analytics/whatsapp-ads?from&to&group_by=campaign|adset|ad` returns conversations, confirmed sales, value and sends.

### M.2 Match quality (Growth and up, where sending is on)
- **Per connection and event type, per day:**
  - events sent;
  - the share with a network click ID (`gclid`, `fbclid`/`fbc`, `ttclid`, `li_fat_id`, `ScCid`, `ctwa_clid`, `twclid`);
  - the share with hashed email or phone (when on);
  - the share accepted;
  - the share rejected, with reasons.
- **Where the network reports its own quality score** (for example Meta's event match quality), it's read through the network's API and shown with its date, read-only. Networks without one show "Not provided by {network}".
- **Tips, generated from the facts above** (a fixed list in `app/ads/match_tips.py`). For example:
  - "38% of WhatsApp sales had no ad click ID: turn on hashed phone numbers to send them";
  - "Website purchases often miss the click ID: save it from your server (/cg/keep)";
  - "12 events were rejected: currency missing".
- **Wording:** facts with dates only. Never "accuracy", "better results" or a predicted improvement.
- **API:** `GET /v1/ads/match-quality?connection&from&to`.
- **Metric registry source:** `ads_matching`.

### M.3 Ad creatives (Growth and up, with connected ad accounts)
- **Sync** (daily, with change 02 spend sync), read-only from Meta, Google, TikTok, LinkedIn, Snap and X:
  - ad ID, name, creative name, format (`image`, `video`, `carousel`, `text`, `other`), status, thumbnail URL;
  - daily spend, impressions and clicks per ad.
- **Thumbnails** are copied to R2 at up to 320 px wide, and deleted when the account is disconnected (change 14 keep, hide, restore otherwise).
- **Crediting results to an ad:**
  - first the network click ID mapped to the ad where the network provides that mapping;
  - otherwise the ad ID in click parameters (`utm_content` or `cg_ad` from the link builder's ad tag templates: `{{ad.id}}` for Meta, `{adid}`-style ValueTrack for Google, `__CID__`-style macros for TikTok, and the builder confirms each network's current macro);
  - ads without either show spend only, with "Add the ad ID to your link tags to see sales" and a one-click template.
- **API:** `GET /v1/analytics/ad-creatives?from&to&network&campaign&format&sort&cursor` returns, per creative:
  - spend, impressions, clicks, CTR;
  - installs, sign-ups and goals;
  - **confirmed sales, value, return on ad spend and cost per new customer** (change 14);
  - WhatsApp chats (M.1).
- **History:** Growth 13 months, Pro and Enterprise 25 months.
- **Metric registry source:** `ad_creatives`, with a "Top creatives" panel.
- **Wording:** "This video brought 42 confirmed sales at ₦3,100 each in the last 30 days". Never "best", "winning" or "will perform".

### M.4 X ads (the seventh network on change 19)
- **Plans:** ad spend on Growth and up, or with the Starter Ad spend add-on (counts as its one account); sending (`conversion_sending`) on Growth and up.
- **Platform switch:** `ads_x_live`, like the other networks (change 02 / change 19).
- **Click ID:** capture `twclid` on clicks; keep it through `/cg/keep`; include it in the click ID list everywhere other networks' IDs appear.
- **Connect:**
  - X OAuth (3-legged, the method X's docs require), then pick an ad account;
  - check the user's access with `authenticated_user_access` (AD_MANAGER or ACCOUNT_ADMIN), with a clear error if neither;
  - tokens encrypted and never logged;
  - read-only: Clikgate never creates or edits campaigns, ads or audiences.
- **Sending:**
  - X Conversions API to the business's X Pixel and chosen event ID ("Install with Conversion API");
  - identifiers: `twclid`, or hashed email or phone (SHA-256, no salt; email trimmed and lower-cased; phone E.164) only with the change 19 matching opt-in. IP or user agent are never sent alone;
  - `conversion_id` = Clikgate's event ID, so the business's own X Pixel isn't double counted;
  - value and currency;
  - queue below X's limit (60,000 events per account per 15 minutes);
  - confirmed-only guard, retries and health as change 19.
- **Spend:** campaign, line item (ad group) and ad stats through X Ads API analytics (async jobs for long ranges), synced daily.
- **Not built:** adjustments (`adjustment_not_supported`), audiences, and app install conversions (unless X's docs show app events through the same API; record it in `docs/ADS.md`).
- **Credits:** Clikgate must never call X endpoints outside the Ads API that use pay-per-use credits. A test fails if the X client calls a non-ads host or path.
- **Approvals page:** X added to the change 19 staff approvals and health page and to `docs/AD_PLATFORM_APPROVALS.md`.

### M.5 Tests
- **Click-to-WhatsApp:** `referral` parsing (Cloud API and forwarded), storage encrypted, crediting, payment linking each way, confirmed-only, the business-messaging payload (mocked), private-mode payload.
- **Match quality:** shares on fixtures, network score read and dated, tips chosen from facts, a banned-word scan.
- **Creatives:** sync per network (mocked), thumbnail copy and delete, crediting by click ID or ad parameter, spend-only state, retention by plan.
- **X:** OAuth and the access check, `twclid` capture and keep, payload hashing rules, `conversion_id`, rate queue, spend sync, the non-ads host check, switch off.
- **All:** plan gates, and a log scan for tokens, `ctwa_clid`, `twclid` and hashes.

---

## L. Live chat support (tawk.to), every plan

### L.1 Where it appears
- **Website:** marketing and docs pages.
- **Dashboard:** customers' organisation pages (a small "Chat with us" button and Help › Chat with us).
- **Never on:**
  - the staff console, partner portal, sample organisations, Present mode, link redirect and preview pages;
  - test-mode views, or the "See it live" page in test mode.

### L.2 Privacy and security
- **Consent:**
  - the widget script loads **only after cookie consent** (change 03);
  - before consent, the button shows "Chat with us" and loads the widget on click, after a one-line notice and link to the privacy policy.
- **Identifying the member:**
  - **Dashboard:** when `support_chat_identify` is on (default), the widget receives only the signed-in member's name and email, organisation name and plan, using tawk.to **secure mode** (a server-made hash with the secure-mode key, `TAWK_SECURE_KEY`, a backend secret never sent to the browser or logged).
  - **Never sent:** customer IDs, labels, links, keys, payment details or report data.
  - `GET /v1/support/chat-identity` returns `{name, email, org_name, plan, hash}` for the signed-in member.
- **Content Security Policy:** tawk.to's own hosts only, on the pages that load the widget. The builder confirms the current hosts.
- **Privacy policy and the sub-processor list** (`docs/subprocessors.yml`) add tawk.to. The lawyer checks where chats are stored.
- **Staff rules** (`docs/SUPPORT.md`):
  - never ask for passwords, API keys, card details or one-time codes in chat;
  - the canned first message says so;
  - staff macros link to docs.

### L.3 Settings (Staff console › Site settings, 🔐)
- `support_chat_enabled_website`, `support_chat_enabled_dashboard` (default on once IDs are set);
- `tawk_property_id`, `tawk_widget_id` (not secret);
- `support_chat_identify` (default on);
- **`live_chat_247` (default off).**

### L.4 Plans and wording (replaces the change 10 E.4.4 "Help from our team" row)
| Plan | Help from our team |
|---|---|
| Free | Live chat + docs |
| Starter | Live chat + email |
| Growth | Live chat + 1-on-1 setup session + help on Slack |
| Pro | Live chat + 1-on-1 setup session + help on Slack (priority) |
| Enterprise | Live chat + setup session + Slack + named contact + contract support terms |

- **The pricing page** shows a row "Live chat support ✓" on every plan, and each plan card gets a line.
- **When `live_chat_247` is on,** the row and cards say **"24/7 chat support"**; when off, "Live chat support". The value comes from the public site config (cached for 5 minutes).
- **Offline message** (set in tawk.to, documented in `docs/SUPPORT.md`): "We're offline. Leave a message and we'll reply by email."
- **Never publish a response time** (change 10).

### L.5 Tests
- the widget absent before consent and on every excluded surface;
- identity hash correct, and fields limited to the four allowed;
- the secret never in the browser or logs;
- CSP;
- the wording follows `live_chat_247`;
- the support row on pricing;
- the banned-word scan.

---

## K. Deep links and moving from Firebase Dynamic Links

### K.1 Deep links page refresh (website, `/deep-links`, change 10 D.8)
- **Headline:** "Deep links that open the right screen, even after install." Subline: "Free to start. Your own domain from {Starter monthly}." (from the plans API).
- **Facts from the current plans:**
  - basic install attribution on every plan within allowances;
  - deferred deep links per plan;
  - Free 5,000 counted clicks;
  - **app opens by people who already have your app aren't counted, up to {cap}.**

  Remove the stale change 10 numbers.
- **The developer path:** the one-command setup (`npx @clikgate/setup`), AI assistant guides and "See it live", with screenshots from the real product.
- **"Start small, then grow":** what Growth adds (retention, confirmed sales, referrals, partners, ad networks) in calm wording.
- **Wording rules:** no claims about other tools, no time claims, never "free forever" or "unlimited".

### K.2 Link import preset: Firebase Dynamic Links (backend)
- **A new preset** `firebase_dynamic_links` in change 03 link import (`POST /v1/migration/link-imports`). It accepts a CSV of short links and long links (the builder checks the export formats that existed).
- **Long-link parameters are mapped:**
  - `link` → the deep link / web destination;
  - `apn`, `afl` → the Android app and fallback;
  - `ibi`, `isi`, `ifl` → the iOS app, App Store ID and fallback;
  - `ofl` → the other-platform fallback;
  - `st`, `sd`, `si` → the link preview;
  - `utm_*` → tags.

  The app must already exist in Clikgate (else the row is reported with "Add your app first").
- **Old `page.link` short links** become new Clikgate links with the same path where free. The import report lists old-to-new pairs to update in the app or campaigns.
- **The report says plainly:** "Old page.link addresses can't be moved; Google owned them."
- **Tests:** the parameter mapping, a missing app, preview fields, the report.

### K.3 Website and docs
- **`/switch/firebase-dynamic-links`**, in the style and with the rules of change 03 `/switch` pages:
  - what moves and what can't (`page.link` addresses);
  - export and import steps;
  - SDK changes per platform;
  - testing with "See it live".
- **SDK docs:** a "Replacing Firebase Dynamic Links" section for Android, iOS, Flutter and React Native (the replacement API calls side by side).
- **A "Deep links" card** on `/use-cases` (change 20 W.2) under "Get app installs", requiring live `deferred_deep_links`.

---

## J. A website AI assistants read correctly

Design doesn't change; two footer links are added. No competitor comparison pages.

1. **`/facts`, "Clikgate at a glance"** (footer). One plain page of facts:
   - what Clikgate is and who it's for;
   - what it does by area;
   - **what it doesn't do** (it doesn't hold or pay money, sell ads, or message customers, and its measurement-partner status comes from site config (R.33));
   - plans, prices, allowances, add-ons and extra-usage prices (plans API);
   - platforms and SDKs, integrations, ad networks;
   - where data is stored, security and privacy basics, company details, support;
   - "Last updated {date}".

   **Only live features** (`GET /v1/public/features`). No customer names, numbers or claims; banned-word scan.
2. **`/faq`** (footer): every FAQ answer on the site, generated from the same content files, with FAQPage data.
3. **`.md` copies** of home, pricing, `/facts`, `/faq`, `/use-cases`, `/deep-links`, product pages and `/switch` pages, generated at build from the same content. Each HTML page links its copy with `<link rel="alternate" type="text/markdown">`.
4. **`llms.txt` refresh** (lists facts, pricing, FAQ, use cases, products, docs) and a new **`llms-full.txt`** (facts, pricing and FAQ in one file).
5. **Structured data:** SoftwareApplication `offers` per plan in NGN and USD from the plans API, alongside the change 03 data.
6. **Readable without JavaScript:** marketing and docs pages are rendered on the server. A build test fetches key pages with JavaScript off and checks prices, plan rows and FAQ text are in the HTML.
7. **One source of truth:** a build check fails if `/facts`, `/pricing`, `llms-full.txt`, the `.md` copies and structured data show different numbers or features.
8. **`robots.txt`:**
   - allow named AI **answer and search** crawlers on public marketing and docs pages;
   - disallow named AI **training** crawlers site-wide;
   - search engines are unchanged;
   - dashboard, staff and partner hosts stay disallowed for all.

   The crawler names come from a dated list in `config/ai_crawlers.yml` (the builder checks each company's current documentation).
9. **`docs/AI_ANSWER_CHECK.md`:** a monthly staff routine.
   - Ask 4 assistants 10 standard questions (what Clikgate is, prices per plan, Paystack, WhatsApp, apps, data location, what it doesn't do, how it compares in general).
   - Log wrong answers with the date and fix unclear pages.
   - No paid "AI ranking" services.

---

## S. SDKs
- **S.1** The SDKs already send opens with the click (`/v1/sdk/open`, `/v1/sdk/resolve`). Confirm each platform sends `install_id` and the click reference on direct App Link and Universal Link opens. If any doesn't, add it (patch release, changelog). No other SDK change.
- **S.2 Tests:** each platform's open payload on direct and redirect opens.

---

## Milestones
- **Backend:**
  1. **C21-B1:** P and S.
  2. **C21-B2:** Z.
  3. **C21-B3:** M.1 and M.2.
  4. **C21-B4:** M.3 and M.4.
  5. **C21-B5:** L backend (identity endpoint, settings, site config), K.2.

  Regenerate `openapi.json`; update `docs/PROGRESS.md`, `docs/DECISIONS.md`, `docs/ADS.md`, `docs/PLANS.md`, `docs/LAUNCH.md` and `docs/SUPPORT.md`.
- **Dashboard:**
  1. **C21-F1:** DB.1–DB.3.
  2. **C21-F2:** DB.4–DB.6 and the Playwright suite.
- **Website:** **C21-W1:** W.

## DB. Dashboard and staff console
- **DB.1 Billing:**
  - "This month so far" gains "App opens by existing users (not charged): {used} of {allowance}";
  - the alerts;
  - usage settles with a note "Counted clicks update about 15 minutes after a click";
  - link and campaign reports show the "New visitors / Existing app users" split.
- **DB.2 Staff sign-in:**
  - email → code → authenticator screens;
  - invite enrolment without a password;
  - `break_glass` password sign-in (separate "Emergency sign-in" link, small);
  - Home card for emergency sign-ins;
  - the staff users list shows the domain and `break_glass` badge.
- **DB.3 Staff console:**
  - the "Unusual share of free opens" list;
  - site settings for chat (L.3) with 🔐;
  - the X platform switch;
  - X on the approvals page.
- **DB.4 Ads:**
  - Ad platforms › Meta: "Click-to-WhatsApp sales";
  - the campaign table: "WhatsApp chats" column;
  - **Match quality** page per connection;
  - **Ad creatives** page (Measure › Ad creatives: grid and table, filters, export, the tag template helper);
  - X connection screens like the other networks.
- **DB.5 Live chat:** the chat button and Help › Chat with us, the consent behaviour, never on excluded surfaces.
- **DB.6 Tests:** Playwright for every screen above, phone and desktop, light and dark, axe; the chat widget absence checks; the banned-word scan.

## W. Website
- **Pricing (change 20 W.1):**
  - Free shows 5,000 clicks;
  - a row "App opens by people who already have your app: not counted, up to {cap}";
  - the FAQ "What counts as a click?";
  - the support row (L.4) and plan-card line.

  All from the plans API and site config.
- **K.1** and **K.3** pages.
- **J.1–J.8.**
- **L:** the widget with consent on marketing and docs pages.
- **The ad networks page and docs** add X, Click-to-WhatsApp sales, match quality and ad creatives (only when live).
- **Checks:** no hard-coded prices, banned words, Lighthouse and accessibility, sitemap, the J.6 and J.7 build tests.

## T. Final test run, database reset and demo data
Follow change 16 section T and change 20 T, with these additions:
- **Bloom Foods (demo), Pro:**
  - 30 days of opens with about 70% existing-user opens and the split in reports;
  - Click-to-WhatsApp: 3 Meta ads with chats, confirmed sales and sends (mocked network);
  - match quality for Meta and Google with tips;
  - 20 ad creatives with thumbnails (generated placeholder images, no real brands) and results;
  - an X connection with spend and sends (mocked).
- **Starter demo:** existing-user opens at 85% of 200,000 (alert shown).
- **Free demo:** 5,000-click allowance visible.
- **Staff:**
  - the `break_glass` super admin (password shown once in the final report);
  - two staff users who sign in by email code (development uses a mail catcher; the report says where to read codes);
  - one emergency sign-in alert on Home;
  - one disabled staff user with a non-company email;
  - one "unusual free opens" entry.
- **Chat:** settings filled with test IDs, and `live_chat_247` off.
- **Sample organisations** (change 20) gain these features where sensible.
- **The final report:** test counts and coverage per repository, and the sign-in table.

## Definition of done
- Existing-user opens are free up to each cap and settle correctly; Free has 5,000 clicks; billing, limits and alerts use settled counts.
- Staff can only be `@clikgate.com` and sign in with an emailed code plus authenticator. One emergency account exists and every use alerts super admins.
- Click-to-WhatsApp sales reach Meta for confirmed payments only. Match quality and ad creatives work for every connected network, and X is the seventh network.
- Live chat works on the website and dashboard after consent, never on excluded surfaces, with "24/7" only when switched on.
- The deep links page, Firebase guide, import preset and SDK docs are live.
- `/facts`, `/faq`, the `.md` copies, `llms-full.txt`, offers data and the robots rules are live, and the consistency checks pass.
- All tests pass, including every earlier change.

## Before building: things only the owner can provide
- **X:**
  - an X developer account on Clikgate's company handle;
  - the Ads API access form (approval can take days to weeks);
  - a test ad account and X Pixel;
  - a terms review.
- **Meta:** confirm the Meta app has the permissions business-messaging events need. A test WhatsApp Business number on the Cloud API, and a small Click-to-WhatsApp test ad.
- **tawk.to:**
  - account, property and widget IDs, and the secure-mode key (into backend secrets);
  - staff agents with the phone app, office hours and the offline message;
  - decide when `live_chat_247` can honestly be switched on.
- **Zoho:**
  - an `@clikgate.com` mailbox for every staff member;
  - SPF, DKIM and DMARC for clikgate.com;
  - keep the `break_glass` password and recovery codes in a safe place.
- **Lawyer:** add tawk.to to the privacy policy and sub-processor list, and confirm where chats are stored.

---

## R. Review fixes (these win over every earlier section)
An independent review checked this change against changes 01–20 and the SDK spec (§4, §7.4, 9C). Each rule below replaces the earlier text it names.

### Counting existing-user opens
- **R.1 [P.2]** Which install counts:
  - "install" means the `installs` row (`ins_`, SDK spec §4), and "first seen" means `installs.first_open_at`;
  - `installation_id` is only used to find the row;
  - an iOS Keychain reinstall is a new row (`is_reinstall = true`), and its own `first_open_at` applies;
  - the install must belong to the same organisation and app as the link, otherwise the click is a tracked click.
- **R.2 [P.3, S.1]** **One tap is one click, never two.** When `/v1/sdk/resolve` or `/v1/sdk/open` carries a click ID from the redirect, it attaches to that click and never mints a new one. A click is minted only when there is no click ID. Test: redirect then open = 1 click.
- **R.3 [P.2, P.3]** **Times are server times:** the redirect time, or for a direct open, when the server received the SDK call. Device timestamps are never used for "install before click" or the 60-second rule. An open sent late from the SDK's offline queue (more than 10 minutes after the click) stays a tracked click.
- **R.4 [P.2]** Only opens with a Clikgate URL or click ID (SDK §7.4 `app_opens`) can qualify. Opens without a URL and `app_active_days` rows (change 20 R.36) never touch meters.
- **R.5 [P.3, DB.1]** The report split shows what happened, not the cap:
  - "Existing app users" = every open meeting P.2, including those counted as clicks above the cap;
  - "New visitors" is renamed **"People without the app"**.

### Meters, settling and billing
- **R.6 [P.1, change 01 B.5]** Add `existing_user_opens` to the change 01 meter table:
  - counted when an open qualifies;
  - at 100%, further qualifying opens count as `tracked_clicks`;
  - change 01's unpriced or capped meter rules (paused webhooks, 429) don't apply to it;
  - `usage.threshold_reached` covers it;
  - it resets each usage month, with no carry-over;
  - after a mid-month plan change, the new cap applies at once against the month's use so far.
- **R.7 [P.1]** The Enterprise allowance is always a number set by staff (seed 20,000,000), never `null` (change 01 reads `null` as no cap). It's shown as "Custom". Change 01's "Unlimited" usage row label becomes "No cap".
- **R.8 [P.3]** Two counts:
  - **provisional** (real time, lowered by moves) drives decisions made when a click arrives: the Free 120% pause, the change 20 H.2 limit and the change 20 R.12 block check;
  - **settled** (clicks 15 minutes or older) drives the usage API, alerts and invoices.

  A click already marked "not counted" (Free pause or limit) is recounted only by the change 20 R.16 backfill, never by a move.
- **R.9 [P.3]** **A move only subtracts from `tracked_clicks` if that click was counted there.** If it wasn't (Free pause, limit reached, test mode, sample organisation), a qualifying open only adds to `existing_user_opens` (if under the cap). Tests prove counts never go below the true count.
- **R.10 [P.3, change 01]** `usage_daily` holds totals keyed by (organisation, meter, `period_start`), with no day and no entries. So moves are recorded in a new table `usage_adjustments`:
  - columns: organisation, `click_id` (unique), from_meter, to_meter, `period_start`, created_at;
  - each move is applied to Redis and `usage_daily`; the unique `click_id` makes retries safe;
  - change 20 H.3.7 reconciliation counts `tracked_clicks` as counted clicks minus adjustments.
- **R.11 [P.3, change 20 R.13, R.19]** Month boundaries:
  - a move belongs to the click's usage month (Lagos time), even if the open arrives after midnight;
  - the month-end extra-usage invoice runs only after month end + 30 minutes;
  - a move arriving after the invoice is issued doesn't change billing, and is recorded as a reconciliation note.
- **R.12 [P.3, change 20 H.1]** Alerts and the cap check:
  - `existing_user_opens` alerts at 80% and 100% only;
  - the wording is "{n} of {allowance} app opens by existing users this month. Above this, they count as clicks.", with no projection;
  - the cap check is atomic (a Redis increment only while under the cap).
- **R.13 [P.1, change 10 D.8, D.11]** Remove the hard-coded Free numbers "1,200" (D.8) and "80% (960)" (D.11); they come from the plans API (alert at 4,000, pause at 6,000). The change 20 price scan also fails on 1,200 and 960.

### Staff sign-in
- **R.14 [Z.1, Z.2]** `POST /v1/staff/auth/email` never returns `403 staff_email_domain_not_allowed`:
  - it gives the same 200 reply for every address and audit-logs only the domain;
  - that 403 is only for the CLI, invites and email changes;
  - emails are sent from a job, and send limits are counted the same way for every address, so timing and 429s reveal nothing.
- **R.15 [Z.2]** Emailed codes:
  - stored as HMAC-SHA256 with a new secret `STAFF_CODE_PEPPER`, not a plain hash;
  - each challenge is bound to its browser by an HttpOnly cookie, and verifying from another browser fails;
  - a new request cancels only that browser's challenge;
  - wrong codes count toward change 01 `failed_attempts` / `locked_until`, with a staff alert on lockout.
- **R.16 [Z.2]** Challenge states are `email_sent → needs_authenticator → done` (plus `password_ok` for `break_glass`). `/v1/staff/auth/verify` refuses any other state with the same generic error. Test: skipping the emailed-code step fails.
- **R.17 [Z.4, change 01 B.6, T]** Making the emergency account:
  - `break_glass` is set only with `python -m app.staff.create … --role super_admin --break-glass`; a plain create makes a normal super admin with no password;
  - the password is typed at a hidden prompt, or generated and shown once in the terminal. It's never a CLI argument, file or log line;
  - invites never set a password.

  **T:** the final report says "break_glass password: printed once in the terminal" and never contains it.
- **R.18 [Z.4]** The `break_glass` account can't be disabled, demoted, re-emailed or have its authenticator reset from the console or API. Only the CLI can (`--reset-totp`, `--replace`, `--disable`). A lost authenticator is recovered with the CLI.
- **R.19 [Z.4, Z.5]** Never only one super admin:
  - every `break_glass` sign-in raises a change 09 critical staff alert;
  - while fewer than two active super admins exist, staff Home shows a critical "Add a second super admin" alert, and `docs/LAUNCH.md` requires two;
  - the migration aborts if it would leave no active super admin with an allowed email;
  - it marks `break_glass` only when exactly one CLI-created super admin exists; otherwise it tells the owner to run the CLI;
  - `--replace` refuses a disabled or other-domain target.
- **R.20 [change 03 status page admin]** Company addresses everywhere:
  - the status page `/admin` access policy allows only `@clikgate.com` (Zoho, not "Google Workspace"), plus TOTP;
  - staff tawk.to agent accounts and the X and Meta developer accounts also use `@clikgate.com` with two-factor sign-in.

### Ads
- **R.21 [M.1, SDK 9C]** Click-to-WhatsApp conversations:
  - add `attribution_method = ctwa_referral`;
  - one conversation per contact per referral, with `click_id` null;
  - only Cloud API-format payloads carry `referral` (never the `forwarded` simple format);
  - `acquired_via = meta_ads` is set on the change 14 new-customer record, not on the conversation;
  - the window is the organisation's attribution window, capped at Meta's documented `ctwa_clid` validity (recorded in `docs/ADS.md`).
- **R.22 [M.1, change 05]** Private mode:
  - linking by `whatsapp_contact` is off, because change 05 turns off phone-based WhatsApp features. Linking uses only `whatsapp_ref` or `clikgate_whatsapp_ref`;
  - `contact_hash` is a server HMAC and is never sent to Meta;
  - hashed phone numbers come only from the payment or goal, under change 19 `matching_mode`, and in private mode only values the business hashed itself;
  - `ctwa_clid` is nulled after the window plus send retries.
- **R.23 [M.1, change 03 B.3, change 11 B.4]** Consent and single credit:
  - Click-to-WhatsApp sends follow consent: in regions that require it, a sale without `ad_user_data: granted` is `skipped_consent`;
  - one sale = one Meta event (one event ID) and one credit, using change 11 priority. A Clikgate click from the chat's ref wins credit; the `ctwa_clid` is still sent as the identifier.
- **R.24 [M.4, change 19 R.15, R.16, R.4]** X corrections:
  - `/cg/keep` is unchanged and keeps only the Clikgate click ID. `twclid` is stored on the click and found through it (remove "keep it through `/cg/keep`");
  - **IP address and user agent are never sent** (remove "alone");
  - in private mode, only values the business hashed itself are passed on, Owner only, using the `matching_mode` name.
- **R.25 [M.4, S.1, changes 13, 14, 19 R.15]** Wire X in everywhere:
  - `clicked_on` gains `x_ads` (code release; `twclid` gives basis `ad_click_id`), and `acquired_via` gains `x_ads`;
  - `ad_accounts.platform` and `ad_spend_daily.source` gain `x`; `spend_sources` gains `x_connected`; `pass_ad_click_ids` gains X;
  - the edge Worker's shared click module reads `twclid`;
  - every SDK and the web script read `twclid` like `li_fat_id` (change 19 S.2). This replaces S.1's "no other SDK change".
- **R.26 [M.4]** The X client's allowed hosts are X's documented OAuth hosts plus the Ads API host, added to the change 18 outbound allowlist. The test fails on any other X host or path.
- **R.27 [M.3, M.4, change 20 I.2]** Plans:
  - with the Starter Ad spend add-on, any one network (X included) can be the one spend account;
  - Click-to-WhatsApp, match quality, ad creatives and X sending are Growth and up;
  - the creative sync skips accounts connected only through the Starter add-on.

  The M heading and D4 follow this.
- **R.28 [M.3, Definition of done]** Creatives:
  - Apple Ads creatives are synced only where Apple's API gives creative fields; otherwise "Not provided by Apple Ads". The DoD reads "where the network provides the data";
  - thumbnails are fetched server-side only, from each network's allowlisted hosts, image types only, at most 2 MB, no cross-host redirects, and re-encoded.
- **R.29 [M.2]** Tips state the organisation's own dated counts ("{n}% of website purchases in the last 30 days had no click ID"), never "often". In private mode, the hashed-phone tip says "hashed on your server" and only Owners see it.

### Live chat
- **R.30 [L.1, L.2]** When the widget loads:
  - **dashboard** (no cookie banner): only when the member clicks "Chat with us", after the notice;
  - **website:** after consent, or on click where no banner is shown.
- **R.31 [L.2]** tawk.to shows agents the page URL and title, so:
  - turn off visitor page tracking if tawk.to allows it;
  - otherwise send the title "Clikgate dashboard" and paths with IDs replaced by `:id`;
  - never load the widget on people, customer, payment or export pages.

  The builder confirms the tawk.to options.
- **R.32 [L.2]** `GET /v1/support/chat-identity`:
  - member session only, `Cache-Control: no-store`;
  - **404** when identify is off, in sample organisations, and in private-mode organisations unless the member turns on "Share my details with support";
  - the hash follows tawk.to secure mode exactly.

### Deep links and the AI-readable website
- **R.33 [J.1]** "certified" is a banned word:
  - in `/facts`, measurement-partner status comes from change 03 `partner_status`, for example "Clikgate is not listed as a measurement partner by any ad network";
  - `/facts` shows no support response time.
- **R.34 [J.4, change 06]** `llms-full.txt` already exists (change 06: setup, SDK and concept docs). Add facts, pricing and FAQ at the top and keep the docs content.
- **R.35 [J.2, J.3, K.3]** Comparisons:
  - `/faq`, the `.md` copies and `llms-full.txt` leave out competitor-comparison content (change 03 `/switch` tables, change 20 R.42 AppsFlyer FAQ);
  - `/switch/firebase-dynamic-links` has no comparison table;
  - the existing change 03 `/switch` comparison tables are removed (R.40, owner decision 2026-11-05).
- **R.36 [K.1, K.3, J.5]**
  - The use-case card requires `deep_linking` (change 10); there is no `deferred_deep_links` key.
  - The subline reads "Your own subdomain from {Starter monthly}" (Starter allows a subdomain only, change 06).
  - Growth's deferred deep links show "No monthly cap", never "Unlimited".
  - Enterprise has no `offers` entry in structured data.
- **R.37 [K.2]** If the export shows a custom domain the business owns (not `page.link`), the import report offers to add it as a Clikgate domain with the same paths, so old links work again. Only `page.link` addresses can't move.

### Environment and tests
- **R.38 [0, docs/LAUNCH.md]** New environment variables and secrets: `STAFF_EMAIL_DOMAINS`, `STAFF_CODE_PEPPER`, `TAWK_SECURE_KEY`, `X_ADS_CONSUMER_KEY`, `X_ADS_CONSUMER_SECRET`. Add them to startup validation, `docs/LAUNCH.md` and the log scan.
- **R.39 [P.6, Z.6, M.5, L.5]** Extra tests:
  - **usage:**
    - redirect + SDK open = one click;
    - a move for a click that wasn't counted (Free pause, limit);
    - a move across midnight at month end;
    - the invoice issued only after settling;
    - reconciliation with moves;
    - the Enterprise cap is never `null`;
    - Keychain reinstalls and other-app installs refused;
  - **staff sign-in:**
    - skipping a challenge state fails;
    - a challenge used from another browser fails;
    - `break_glass` locked against console changes;
    - the "only super admin" alert;
  - **ads:**
    - Click-to-WhatsApp consent, private mode and a single event;
    - X `clicked_on`, `acquired_via` and SDK `twclid`;
  - **website and chat:**
    - tawk.to page data on excluded pages;
    - `/facts` passes the banned-word scan.

### Comparison content removed from the website (owner decision, 2026-11-05)
- **R.40 [change 03 W, change 20 W.1 and R.42, K.3]** The public website has **no competitor comparison content**:
  - **`/switch/appsflyer` and `/switch/branch`** (change 03) become **migration guides only**, titled "Moving from AppsFlyer" and "Moving from Branch". Same addresses, so links keep working.
    - **Remove:** the comparison table, every "where Clikgate is stronger" or "where they are stronger" text, and any price or feature comparison.
    - **Keep:** migration steps, "keep your branded links working", the side-by-side pilot (described as "run both for 30 days and check your own numbers", with no claims about the result), and the honest partner-status FAQ.
  - **The pricing FAQ** "AppsFlyer gives you 12,000 in your first year…" (change 20 W.1, R.42) is **removed**, together with the dated AppsFlyer figure in site config.
    - It's replaced by a plain FAQ: "Is there a free plan? Yes: {Free allowances} every month while you're on Free." (from the plans API).
  - **Every website page, `.md` copy, `llms.txt` and `llms-full.txt`** contains no tables, lists or sentences comparing Clikgate with a named tool.
    - Naming a tool is allowed only as a fact: in migration guides ("Moving from Firebase Dynamic Links"), integrations ("Works with Shopify"), and the honest partner-status answer.
  - **Not affected:**
    - the internal sales handbook (private);
    - in-product reports that compare a customer's own numbers (change 03 side-by-side pilot, change 19 "From your measurement partner").
  - **Test:** the website build fails if a page or text copy contains comparison patterns next to a competitor name ("vs", "compared with", "cheaper than", "better than", "stronger", "unlike"). The list of competitor names is kept in `config/competitor_names.yml`.

### Which APIs are published (owner decision, 2026-11-05)
- **R.41 [backend spec §6, change 03 W docs, change 06 S.16, change 08]** Today one `openapi.json` holds every route and feeds the public API reference, the server SDKs and the dashboard types. From now on:

  **1. Every route declares an audience** (a route tag `x-audience`):

  | Audience | Examples | Published? |
  |---|---|---|
  | `public` | Routes a business's developers call with API keys (links, goals, conversions, reports, exports, webhooks management) | **Yes:** main API reference and server SDKs |
  | `sdk` | Routes the mobile and web SDKs call with SDK keys (opens, installs, resolve, events) | **Yes, but only** in a separate "SDK protocol (advanced)" section (see 4) and never in server SDKs |
  | `dashboard` | Member sign-in and two-step setup, invites, billing payments and cards, chat identity, sample organisations, settings screens | No |
  | `partner` | Partner portal sign-in codes, earnings | No |
  | `webhook` | Incoming receivers: Paystack billing, payment-provider ingest, Meta deletion and deauthorize callbacks, WhatsApp inbound, ad network callbacks | No. Setup guides show only the URL to paste |
  | `staff` | `/v1/staff/*` | **Never** |
  | `internal` | `/internal/*`, queue consumers, reconciliation | **Never** |

  **2. Hidden by default.** A route without an audience is treated as hidden, and a test fails the build until every route has one.

  **3. Three generated files:**
  - `openapi-public.json` (`public` + `sdk`, with `sdk` in its own tag group): the only file the docs site and the server SDK generator read. The server SDK generator also excludes `sdk` routes;
  - `openapi-dashboard.json`: dashboard types, kept in the private repositories;
  - `openapi-staff.json`: staff console types, private.

  `GET /openapi.json` and `/docs` stay off in production (backend spec §6). The docs site uses the build-time public file only.

  **4. SDK protocol (advanced) section:** shown under "API reference › SDK protocol (advanced)", collapsed by default. Every page in it starts with a fixed warning box:

  > **Use the Clikgate SDK instead.** These endpoints are documented for platforms we don't have an SDK for yet. The SDKs handle install IDs, retries, offline queues, consent, deep link timing and fraud checks for you; calling these endpoints yourself can count installs wrongly, miss attribution, or get your app's traffic flagged as suspicious. Use an `cg_sdk_test_*` key until your integration passes "See it live".

  - It links to the SDK list and "Request an SDK".
  - The `deeplink_handled` debug event (change 20 S.1) and SDK-internal fields (fraud signals, device checks) aren't documented.

  **5. Never in public files** (a build check scans the public file, `.md` copies and `llms-full.txt`):
  - `/v1/staff`, `/internal`, webhook receiver paths;
  - fraud scoring weights and thresholds (change 12), the share-ending list (change 13), private-mode internals;
  - staff-only fields in responses (staff notes, review reasons, internal IDs of staff), and any response field marked `x-internal: true`. These are stripped from public schemas and also never returned to API keys.

- **R.42 [backend spec §6.5 and §17 tests, change 13, change 18]** Security checks for every published route (publishing a route isn't a flaw in itself, because routes can be discovered from apps and network traffic; these checks are what keep them safe):
  1. **Authentication:** every `public` route needs an API key or OAuth token, and every `sdk` route an SDK key, except a fixed list of routes meant to be open (`GET /v1/public/*`, health), kept in `config/open_routes.yml`. A test generated from `openapi-public.json` calls every route without credentials and expects 401, except the list.
  2. **Scopes and permissions:** every route declares its required scope (change 13 `area:view|manage` for keys). A generated test calls each route with a key lacking that scope and expects 403. SDK keys are refused on `public` routes, and API keys on `sdk` routes.
  3. **Tenant isolation:** a generated test calls every route with organisation B's key on organisation A's objects and expects 404 (backend spec §17). The test fails the build if a new route has no isolation case.
  4. **Rate limits:** every published route has a limit (backend spec §6.5), per key and per IP for open routes, with `429` and `Retry-After`. A test checks each route has a limit set.
  5. **No guessable IDs:** public IDs stay random with prefixes (`lnk_`, `ins_`…); no sequential numbers in published responses or paths.
  6. **No secrets in docs:** examples use obvious fakes (`cg_live_EXAMPLE…`, `cg_sdk_test_EXAMPLE…`). A docs build check fails on anything that looks like a real key, token or webhook secret.
  7. **Errors don't leak:** published errors use the standard error shape. No stack traces, SQL, internal hostnames or "this email belongs to…" hints.
  8. **Writes are safe to repeat:** `POST` routes that create things accept `Idempotency-Key` (backend spec), and mass actions have size limits documented.
  9. **Private mode and personal data:** published response schemas show where fields are removed in private mode, and a test checks each published route's response in a private-mode organisation contains no customer IDs, labels or phone and email values.
  10. **Keys can be locked down:** the docs explain key scopes, test vs live keys, IP allowlists (change 18, Pro and Enterprise), rotation and revoking. The API reference marks which scope each route needs.

- **Tests (R.41–R.42):**
  - every route has an audience;
  - the public file contains no hidden audiences or banned paths and fields;
  - the server SDK generator uses only `public`;
  - the SDK protocol warning appears on every page in that section;
  - the generated authentication, scope, isolation and rate-limit tests pass for every published route;
  - the docs secret scan passes.

### Live chat on Growth and above (owner decision, 2026-11-05)
- **R.43 [D5, L.1, L.4, P.1, DB.5, W]** In-product live chat support is a **Growth, Pro and Enterprise** feature, replacing "every plan".
  - **Feature key `live_chat_support`,** added in the P.1 plan version: on for Growth, Pro and Enterprise; off for Free and Starter. A Starter organisation with add-ons doesn't get it.
  - **Dashboard:**
    - the chat button and Help › Chat with us appear only when the organisation has `live_chat_support`;
    - `GET /v1/support/chat-identity` returns `403 plan_upgrade_required` without it;
    - Free and Starter see Help › "Get help from our team" as before (docs; email on Starter), plus "Live chat comes with Growth" linking to the upgrade page (and any running offer);
    - on downgrade the button disappears (keep, hide, restore; no data in Clikgate to keep);
    - all L.2 privacy rules are unchanged.
  - **Website:** the chat stays on marketing and docs pages for **visitors' sales and pre-sales questions**, titled "Questions about Clikgate? Chat with us".
    - It doesn't identify the visitor and never offers account support.
    - Staff macros point signed-in Free and Starter customers to docs or email (`docs/SUPPORT.md`).
    - The owner can turn it off with `support_chat_enabled_website`.
  - **Support table (replaces L.4):**

    | Plan | Help from our team |
    |---|---|
    | Free | Docs |
    | Starter | Email |
    | Growth | **Live chat** + 1-on-1 setup session + help on Slack |
    | Pro | **Live chat** + 1-on-1 setup session + help on Slack (priority) |
    | Enterprise | **Live chat** + setup session + Slack + named contact + contract support terms |

  - **Pricing:**
    - the row reads "Live chat support": — · — · ✓ · ✓ · ✓;
    - with `live_chat_247` on, the Growth, Pro and Enterprise cells and plan cards say **"24/7 chat support"**;
    - Free and Starter cards don't mention chat.
  - **Tests:**
    - button and identity endpoint by plan;
    - downgrade and upgrade;
    - Free and Starter help text;
    - the website chat is unidentified;
    - the pricing row and the 24/7 wording only on Growth and up.
