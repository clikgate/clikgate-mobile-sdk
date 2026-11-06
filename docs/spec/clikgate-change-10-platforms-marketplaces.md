# Workspace notes for Change 10 (read first; these override the spec body where they differ)

- **Repository mapping:**
  - `clikgate` (backend) = `clikgate_api`. It uses the legacy layout: code under `src/`, not `app/`, and Alembic migrations.
  - `clikgate-dashboard` = `clikgate_frontend` (Next 15, BFF).
  - `clikgate-website` = `clikgate_website` (pnpm monorepo, `apps/www`, `apps/status`, `packages/ui`).
  - The SDK work in D.5 goes to `clikgate_mobile_sdk` (mobile SDKs, `shared/` contract, `cli/` setup command) and `clikgate_sdks` (server SDKs and `ai-guides`).
- **Earlier changes:** Changes 01–09 are built. Change 09's backend contract is final at
  `/private/tmp/claude-501/-Users-user-Documents-PROJECTS-distyla-distyla-webapp/9dc4797d-093f-4e6a-b3ad-3a6c2d9efb08/scratchpad/c9-contract.md`.
  It covers app subdomains, staff alerts and the staff Home page, challenges, public stats and more.
- **The Change 10 backend contract** goes in
  `/private/tmp/claude-501/-Users-user-Documents-PROJECTS-distyla-distyla-webapp/9dc4797d-093f-4e6a-b3ad-3a6c2d9efb08/scratchpad/c10-contract.md`.
  - The backend agent writes it, in the same style as c9-contract.md.
  - A `STATUS: C10-Bn final` line at the bottom means that milestone's section is final.
  - Website, dashboard and SDK agents build against it.
- **The dashboard's Change 09 work (F1–F5) may still be in progress.** The dashboard Change 10 work starts after it.
- **Cross-promotion was removed** from the product (2026-10-27). Don't mention it.
- **The website pricing page:** Change 09 renamed "Add-ons and overage" to "Overage". G.6 adds a real "Add-ons for Growth" section back.
- **The "How Clikgate works" home section** is a light panel band with the map in a navy card, by the owner's choice. Keep it.
- **Names:** don't name Distyla or any real company as a customer. Use clearly fictional names.
- **Wildcard certificate for `*.clk.ng`:** an owner purchase or DNS decision. Don't buy or configure anything outside the repos; list it as an owner action.
- **House rules:**
  - No git writes; the owner commits.
  - Never print secrets, keys, TOTP secrets or recovery codes. Never cat `.env` files, and don't create `.env` files.
  - Don't migrate the owner's dev database `clikgate`. Test migrations on a scratch database on port 5433, then drop it.
  - Run heavy commands one at a time through
    `/private/tmp/claude-501/-Users-user-Documents-PROJECTS-distyla-distyla-webapp/9dc4797d-093f-4e6a-b3ad-3a6c2d9efb08/scratchpad/heavy.sh`
    (16 GB machine).
  - Don't kill processes you didn't start, and don't list processes with their arguments.
- **Running services, which must stay up:**
  - API on 8000, redirect on 8100, the worker and ingest;
  - the production dashboard on 7010 and the production website on 7020.

---

# Clikgate Change 10 — "Platforms and marketplaces" Solution, Growth Add-ons, Free Deep Links, Fraud Protection Page and Setup Sessions with Slack Support (website, backend, dashboard)

> **Instructions for the AI building this:**
> - Changes 01–09 are built. This change adds a new solution, **Platforms and marketplaces**, to the website's Solutions menu (change 09 D11) with a full, highly informative page, plus the small backend and dashboard pieces the page relies on (a platform enquiry form and a "Talk to us" route for staff).
> - The change has four parts: **Part 1, Platforms and marketplaces** (sections A, W, B.1, F.1), **Part 2, Growth add-ons** (section G), **Part 3, Free deep links and upgrade opportunities** (section D) and **Part 4, the fraud protection page, setup sessions and Slack support** (section E).
> - **Website repository** (`clikgate-website`): sections W, G.6, D.8, E.1 and E.4.4, milestones C10-W1 to C10-W6.
> - **Backend repository** (`clikgate`): sections B, G.1–G.5, D.1–D.7, D.11, E.2–E.3 and E.4.1–E.4.2, milestones C10-B1 to C10-B4.
> - **Dashboard repository** (`clikgate-dashboard`): sections F, G.7–G.8, D.9, D.11, E.2 and E.4.3, milestones C10-F1 to C10-F5.
> - Part 2 reuses change 01 (plans, plan versions, entitlements, upgrade requests, staff confirmation with 🔐 and 🔑, the calculator), change 04 (invoices, receipts, renewals) and change 09 (staff alerts and staff Home).
> - Reuse: the change 09 solution page template and content model, the Solutions mega menu, `JourneyLine` and `ClickMap` components, the real dashboard components used as mockups, the docs layout and language tabs (change 06), the agency lead form and staff lead list (change 03), the plans API and calculator (change 01), the wording rules (D9 "for every business", no time claims, no invented customers or numbers, Clikgate never pays or messages people).
> - **Every code sample on the page must use the real API and SDK names from the current `openapi.json` and the released server SDKs** (check field and parameter names such as link `metadata`, `external_reference`, `group_by=metadata.<key>` against the code; never invent an endpoint). Code samples are compiled or executed in CI like the docs samples (change 06).
> - **Do not name Distyla or any other company as a customer** unless the owner has approved it in writing. Examples use clearly fictional names.
> - Run Lighthouse CI and accessibility checks; update `docs/PROGRESS.md`.

---

## A. Overview

### A.1 Who this is for
A **platform** is a business whose own product creates links **for the brands, sellers, merchants, creators, restaurants or organisers that use it** — and needs to show each of them what those links produced. Examples:
- **Marketplaces** — sellers' product and shop links.
- **Store builders and e-commerce platforms** — each merchant's campaign links and QR codes.
- **Creator and affiliate networks** — a link per creator per brand campaign, with exact credit for sales.
- **Delivery and food aggregators** — restaurant promo links, table and flyer QR codes.
- **Booking and ticketing platforms** — event organisers' and venues' links.
- **Business software for merchants** (point of sale, invoicing, loyalty, booking tools) — trackable links built into their product.
- **Referral and loyalty platforms** — links and codes for each client business's members.

### A.2 Platform vs agency (the page must make this clear)
| | Agency | Platform or marketplace |
|---|---|---|
| What it does | Runs marketing **for** separate client businesses | Its **own product** creates links for the brands or sellers on it |
| Clikgate setup | Each client is its own Clikgate organisation with its own plan; the agency gets approved access | **One organisation** — the platform's. Brands are the platform's users, not Clikgate users |
| Who pays | Each client (or the agency for them) | The platform, once, for all its brands |
| How brands see results | Their own Clikgate dashboard | Inside the platform's own app or dashboard, built on Clikgate's API |
| Programme | Agency programme (discounts, white label) | Plans by volume; Enterprise for very large platforms |

### A.3 What the page must achieve
1. A platform founder or product lead understands in one scroll how Clikgate becomes the "link and results layer" inside their product.
2. A developer sees exactly which API calls, fields and webhooks to use, in their language.
3. Honest about limits (one organisation, no Clikgate log-ins for brands, shared allowance) so the right platforms enquire.
4. Clear next step: "Talk to us about your platform" (a dedicated enquiry form) or "Start free" to try the API in test mode.

### A.4 Out of scope
- Separate Clikgate sub-accounts or log-ins per brand inside a platform's organisation (noted as a possible future product feature; see the notes file — **do not build or promise it here**).
- A special platform price or reseller programme (Enterprise conversation for now).
- Payouts, commissions or messaging brands' customers (Clikgate never does these).

---

## W. Website (`clikgate-website`)

### W.1 Menu and routing
- **Solutions → Your industry:** add the tile **"Platforms & marketplaces"** with the one-line outcome **"Give every brand on your platform proof of what it sold"** and an icon in the existing set. Place it after "E-commerce & retail". The menu's featured journey card for this tile: "Seller's link → shopper taps → order paid → shown in the seller's dashboard".
- **Your stage → Agencies** page and **Your team → Developers** page: add a short "Not an agency? / Building for many brands?" callout linking to the new page, with the comparison from A.2 in two lines.
- URL: **`/solutions/platforms-and-marketplaces`**. Add to the sitemap, `llms.txt`, the footer's Solutions list and the site search.
- SEO: title "Link tracking and attribution for platforms and marketplaces — Clikgate"; description "Create trackable links for every brand or seller on your platform through one API, and show each of them the clicks, orders and value their links produced."; FAQ structured data.

### W.2 The page (change 09 solution template, extended for platforms)
Build on the change 09 solution template so the page looks and behaves like the other solutions, with these sections in this order. All mockups are real components with **clearly fictional data, labelled "Example data"**.

1. **Hero**
   - Chip: "Industry · Platforms & marketplaces".
   - Headline: **"Give every brand on your platform proof of what it sold."**
   - Subhead: "Create trackable links for every seller, merchant or creator through one API, on your own domain — and show each of them the clicks, orders and value their links brought. Clikgate sees to every click, so you don't have to build it."
   - Buttons: **Talk to us about your platform** (primary, opens the enquiry form, W.3) and **Start free** (secondary, "try the API in test mode").
   - Visual: a compact animated journey built from real components: "Seller 'Ada's Fabrics' on *Shopwave* (fictional) → link `swv.ng/ada-ankara` created by your server → shopper taps on WhatsApp → order paid ₦18,500 → appears in Ada's dashboard inside Shopwave". Reduced motion: static.
2. **What gets in the way** — four short problems, one line each:
   - "Your sellers ask what your platform brought them, and you can't show it per seller."
   - "Building link tracking, deep links, QR codes, fraud filtering and reporting yourself takes a team."
   - "Sales happen in apps, on websites, in WhatsApp chats and offline — and credit gets lost between them."
   - "Creators and affiliates dispute who drove a sale, and you have no neutral record."
3. **How it works — a drawn architecture diagram** (SVG component, keyboard-accessible, reads well on phones as a vertical sequence):
   - Left: **Your platform's server** creates links through the Clikgate API (one per seller, product, creator or campaign), tagging each with fields such as `brand_id`, `seller_id`, `creator_id`.
   - Middle: **Shoppers tap** the links on your domain (e.g. `go.yourplatform.com`), in apps, WhatsApp, social media or QR; Clikgate records each click, opens apps where possible, removes bots.
   - Right: **Results come back** — from your checkout, Paystack, Flutterwave, Shopify or WooCommerce, or your server — as goals with value; Clikgate credits the link and sends a **webhook** to your server.
   - Bottom: **Your dashboard for brands** reads per-brand results from the Clikgate API (`group_by` your field) and shows each brand only its own numbers.
   - One sentence under it: "Your brands see everything inside your product. Clikgate is the engine underneath."
4. **What your brands get vs what you get** — two columns:
   - *Your brands (inside your product):* their own links and QR codes; clicks, orders and value per link; which channel worked (WhatsApp, Instagram, TikTok, QR, offline); app opening on Instagram, TikTok, Jumia and others; trustworthy numbers with fake clicks removed.
   - *You (the platform):* one API and one bill for all brands; results across every brand in one view; webhooks to automate commissions, payouts or rankings in your own system; fraud and abuse protection; your domain and branding; no tracking infrastructure to run.
5. **Building blocks** — a grid of cards, each with what it is, why it matters for a platform and a "Docs" link:
   - **Links at scale:** API and bulk jobs (up to 1,000 links per job), your own reference per link (`external_reference`), up to 50 custom fields (`metadata`) such as brand, seller, creator, product.
   - **Your domain:** short and branded domains, domain groups so one link works on several of your domains; app link subdomain for your own app (`yourapp.ciz.to`) or your own domain.
   - **Per-brand reporting:** analytics grouped by any custom field (e.g. revenue per seller), time series, top links, exports.
   - **Results with value:** goals with value and currency, once-per-click or every time, reversals for refunds, unattributed reasons with fixes.
   - **Sales connections:** Paystack, Flutterwave, Shopify, WooCommerce, inbound webhook mapping; click ID kept through checkout by the web script and server SDKs.
   - **Webhooks:** link, goal, reversal, install, referral and code events, signed and retried, to drive your own commission, payout or ranking logic.
   - **QR codes and offline codes:** per product, table, flyer, agent or store; destinations changeable after printing.
   - **Open in app:** links to Instagram, TikTok, YouTube, Jumia, Konga, Spotify and other supported apps open in the app; affiliate tags are never changed.
   - **Deep links into your own app:** sellers' links open your app at the product page, even after install.
   - **Referrals, leaderboards, trophies and challenges:** run seller or creator contests ("Top sellers this weekend") on your platform; you decide and pay the rewards.
   - **Protection:** bot and fake-click filtering, install fraud scoring, link safety (allowlist, locked links, two-person approval), backup redirects.
   - **Developer tools:** server SDKs (Node.js, Python, PHP, Java 8+, .NET), test mode and test links, API keys with scopes, rate limits by plan.
6. **For developers — the three calls you need** (code tabs synced with the docs language picker: Node.js, Python, PHP, Java, C#/.NET, curl), each compiled/run in CI:
   1. **Create a link for a seller** with `metadata` (`seller_id`, `product_id`) and `external_reference`, on your domain, with a campaign.
   2. **Record an order as a goal** with value, currency and the click ID from checkout (or let Paystack/Shopify do it).
   3. **Show a seller their results:** analytics for the period with `group_by=metadata.seller_id` (or filtered to one seller), plus a webhook handler that verifies the signature and updates the seller's dashboard.
   Under the tabs: "Your server keeps the API key. Never put it in an app or a browser."
7. **Keeping brands apart** — a short, honest explainer:
   - Everything lives in **your one Clikgate organisation**. Brands are separated by the fields you set on links and goals.
   - **Your product decides who sees what:** only ever request and show a brand its own records (always filter by its ID on your server). Clikgate API keys must never be given to brands.
   - Brands **don't log in to Clikgate** and don't need to know it's there. On Pro and up "Powered by Clikgate" is removed and the pages on your domains carry your branding.
   - If a brand needs its **own Clikgate account** (its own plan, team and dashboard), that's the agency-style setup instead — the page links to the comparison.
8. **Example playbooks** (each: who it's for, the steps, the Clikgate features used, "Try this" opening the dashboard at the right screen after sign-up, per change 09):
   - **"One link per seller product"** (marketplace): bulk-create product links with `seller_id`, show sales per seller, run a "Top sellers this weekend" challenge.
   - **"Creator commission links"** (creator and affiliate networks): a link per creator per brand campaign, goals from the brand's checkout, webhooks into your commission ledger; Clikgate provides the neutral record, you pay commissions.
   - **"Restaurant QR kits"** (food and delivery): a QR code per table and flyer per restaurant, opening your app at the restaurant's menu; orders per restaurant and per QR.
   - **"Merchant campaign links"** (store builders and business software): merchants create links inside your product; you show them clicks, orders and value by channel.
9. **Example dashboard** — a platform overview mock labelled "Example data": total orders and value across all sellers; a table "Results by seller" (seller, links, clicks, orders, value, conversion rate); a "Seller view" panel showing what one seller would see inside the platform.
10. **Trust and control** — your domain and branding; link safety; private mode for platforms that can't share shoppers' data (results still counted, identity data refused); fraud protection; backup redirects; status page; data export and no lock-in. Link to the trust centre.
11. **Plans that fit** — read from the plans API (no hard-coded prices):
    - "**Growth** — for platforms getting started: 250,000 tracked clicks a month across all your brands, app attribution, 2 own domains."
    - "**Pro** — for most platforms: 2,000,000 tracked clicks, 10 own domains, unlimited team and goals, sending results to ad platforms, fraud protection, higher API limits."
    - "**Enterprise** — for very large platforms, more domains (for example a domain per brand), custom limits and an SLA: talk to us."
    - A clear note: "**All your brands share your plan's allowance.**" and a link to the calculator with "Estimate for your platform" (prefilled with platform-like defaults: number of brands × links × clicks per link).
12. **Questions** (FAQ, structured data) — at least:
    - Is this the agency programme? (No — A.2.)
    - Will my brands see Clikgate? (Not unless you choose to show it; branding removed on Pro and up.)
    - Can each brand use its own domain? (Yes; each counts towards your plan's domains — Enterprise for many.)
    - Can brands log in to Clikgate? (Not under your account; you show them results in your product. If they need their own accounts, see agencies.)
    - How do we report per brand? (Custom fields + `group_by`; exports; webhooks.)
    - Who owns the data? (You do; full export at any time.)
    - Does Clikgate pay commissions or rewards? (No — it records and tells your systems; you pay.)
    - Can Clikgate message our brands' customers? (No.)
    - How many links can we create? (Unlimited links on paid plans; bulk jobs of up to 1,000; API rate limits by plan.)
    - What happens when a brand leaves our platform? (Give each brand its own campaign so pausing the campaign pauses all its links in one action, or bulk-pause its links; its history stays.)
13. **Related** — Agencies, E-commerce & retail, Media, creators & entertainment, Developers, the leaderboards and challenges page, the API docs. Closing call to action: "Build your platform's results on Clikgate" with **Talk to us about your platform** and **Start free**.

### W.3 Platform enquiry form
- Opened from the hero, plans and closing buttons; also reachable at `/solutions/platforms-and-marketplaces#talk`.
- Fields: name, work email, company, website, platform type (marketplace / store builder / creator or affiliate network / delivery or food / booking or ticketing / business software / referral or loyalty / other), number of brands or sellers (ranges), expected monthly clicks (ranges), has a mobile app (yes/no), needs a domain per brand (yes/no/not sure), message; consent to be contacted.
- Submits to the backend (B.1); shows "Thanks — our team will reply by email." (no time promise). Spam protection as the existing agency form.

### W.4 Other website updates
- **Pricing page FAQ:** "Running a platform or marketplace?" → two sentences and a link to the page.
- **Agencies page:** the A.2 comparison as a small table under the hero ("Agency or platform?").
- **Docs:** a guide **"Building on Clikgate as a platform"**: account structure, tagging links with custom fields, per-brand analytics, webhooks into your system, keeping brands apart, domains, limits and rate limits, test mode first. Linked from the page and from the API reference. Code in all six language tabs.
- **`llms.txt`:** the page and the guide.

### W.5 Quality bar
- Same quality as the best change 09 solution pages: specific, useful on its own, real components, no stock images.
- Honest: no customer names or logos (hidden blocks until approved), no uplift or time claims, "Example data" on every mock, limits stated (section 7 and FAQ).
- Wording rules: "brands", "sellers", "merchants", "creators"; never "credit"/"earn"/"payout" as something Clikgate does; Clikgate never pays or messages.
- Lighthouse and accessibility budgets as other solution pages; the diagram and code tabs work with keyboard and screen readers; no layout shift.

### W.6 Milestones
1. **C10-W1** Menu tile, routing, SEO, page sections 1–5 and 7, the architecture diagram.
2. **C10-W2** Developer code tabs (compiled/run in CI), playbooks, example dashboard, trust, plans with calculator link, FAQ, related, enquiry form (W.3).
3. **C10-W3** Agencies and Developers callouts, pricing FAQ, docs guide, `llms.txt`, sitemap; Lighthouse and accessibility checks; list all new copy in `docs/PROGRESS.md` for the owner's review.

---

## B. Backend (`clikgate`)

### B.1 Platform enquiries
- Extend the existing agency lead endpoint and table (change 03) with a lead `type` (`agency` | `platform`) and the W.3 fields as structured columns or a validated JSON field. If the leads storage already has a type, add `platform`.
- Public endpoint (the website's form posts here), rate-limited and spam-protected as the agency form; email to staff "New platform enquiry"; no auto-reply promising a response time.
- Tests: validation, rate limits, staff notification, no personal data in logs beyond what the agency form already logs.
1. **C10-B1** B.1, tests; regenerate `openapi.json`.

## F. Dashboard (`clikgate-dashboard`)

### F.1 Staff console
- The staff leads list gains a **Type** filter (Agency / Platform) and shows the platform fields; statuses as for agency leads.
1. **C10-F1** F.1, tests; update `docs/PROGRESS.md`.

---

## G. Part 2 — Growth add-ons (owner decision, 2026-10-27)

### G.0 Why
Growth (₦30,000) to Pro (₦120,000) is a fourfold jump. Some Growth organisations need only one Pro thing — more domains, more clicks, or fraud protection. Add-ons let them buy exactly that, **priced so that any two add-ons bring the total within a few thousand naira of Pro**, which makes upgrading to Pro the obvious next step. Staff see these organisations and contact them about Pro.

### G.1 The add-ons (Growth plan only; prices confirmed by the owner, 2026-10-27)
| Add-on | What it adds | Monthly (NGN) | Monthly (USD) |
|---|---|---|---|
| **Domains pack** | +3 own domains (Growth 2 → 5; subdomains or bare domains) | ₦40,000 | $27 |
| **Clicks pack** | +500,000 tracked clicks a month (resets monthly, no carry-over; normal overage applies beyond it) | ₦42,500 | $28 |
| **Fraud protection** | Pro's fraud protection: threshold slider, exclude or hold for review, mark real/fake in bulk, rule weights and per-network overrides, dispute evidence CSV (change 02 B.5) | ₦45,000 | $30 |

- **The rule behind the prices (keep it when prices change):** Growth + any two add-ons = between 90% and 99% of Pro's price for the same period and currency; Growth + all three > Pro. With today's prices: Growth + two add-ons = ₦112,500–₦117,500 (Pro ₦120,000); Growth + three = ₦157,500. The staff price editor (G.5) shows a warning when a price change breaks this rule.
- **Each add-on at most once** per organisation. More than that is Pro.
- Only **Growth** organisations can buy add-ons. Starter is pointed to Growth; Pro and Enterprise already include more.
- Add-ons follow the plan's **billing period** and its discounts (6 months 10% off, yearly two months free), billed on the same invoice as the plan.
- **Adding in the middle of a period:** charged for the days left in the current period (rounded to whole days), on its own invoice; from the next renewal it is part of the renewal invoice.
- **Removing:** takes effect at the end of the paid period (no refunds for part periods). Owners or admins can mark "Remove at renewal".
- **Upgrading to Pro** ends all add-ons; the unused value of add-ons already paid for is shown on the Pro upgrade quote as a credit line (change 04 credit note or discount line).
- **Downgrading from Growth** ends add-ons at the end of the period; extra domains follow the existing downgrade rules (read-only, owner chooses which stay active).

### G.2 Data and entitlements
- Plan versions (change 01) gain **add-on definitions**: key (`domains_pack`, `clicks_pack`, `fraud_protection`), name, description, prices per currency and period, the allowance or feature it adds, eligible plans (`growth`), max quantity (1), status. Changed only by super admins with 🔐🔑, versioned like plan prices; existing subscribers keep their agreed add-on price.
- `subscription_add_ons`: subscription, add-on key, price snapshot, started_at, ends_at, status (`pending_payment|active|ending|ended`), remove_at_renewal, created_by.
- **Entitlements = plan + active add-ons**, calculated in one place and used everywhere limits and features are checked (domains count, clicks allowance, fraud actions, usage meters, warnings at 80% and 100%).
- Add-ons appear on the Plan & usage API response and in webhooks `subscription.updated` (with add-ons listed).

### G.3 Buying an add-on (same manual flow as upgrades)
1. Owner or admin opens **Plan & usage → Add-ons** and clicks **Add** on an add-on.
2. The quote shows the price for the days left in this period and the amount from the next renewal, plus VAT when it applies.
3. **Request** creates an upgrade-style request with payment instructions, a unique reference and a numbered PDF invoice (change 04).
4. The customer pays and clicks "I've paid"; staff confirm the payment (🔐) and the add-on becomes active immediately; a receipt is emailed.
- Requests expire after 14 days like upgrade requests.
- **Before the request is created, if the new total would be at least 90% of Pro**, the screen shows: "With this add-on you'd pay ₦117,500 a month. Pro is ₦120,000 and includes 10 domains, 2,000,000 clicks, fraud protection, sending results to ad platforms, identity checks, uninstall tracking and more." with **Request Pro instead** (primary) and **Add only this** (secondary). The customer chooses; nothing is changed automatically.

### G.4 Reminders and renewals
- Renewal reminders and invoices (14, 7 and 1 day before) include add-on lines.
- Grace and expiry as for the plan: when the plan expires, add-ons end with it.
- The Clicks pack's 500,000 clicks are added to the monthly tracked-clicks allowance; usage meters show "Growth 250,000 + Clicks pack 500,000".

### G.5 Staff: Pro candidates and price controls
- **Pro candidates list** (staff console → Billing → Pro candidates): Growth organisations where **any** of these is true, with the reasons shown:
  - two or more active add-ons;
  - one add-on and tracked clicks above 80% of the allowance in the last 30 days;
  - overage invoices in two of the last three months;
  - an add-on request that was abandoned after seeing the "Pro instead" message.
- Columns: organisation, current monthly total (plan + add-ons, in the billing currency), Pro price, the difference, add-ons, usage %, months on Growth, last contact, assigned staff member, status (`new|contacted|offer_sent|upgraded|not_now`), next follow-up date.
- Actions: assign, log a contact (note, channel), set the next follow-up date, mark status, open the organisation. Every action is audit-logged.
- **Staff alert** (change 09 staff alerts) when an organisation becomes a Pro candidate, and a **weekly digest** email of candidates with no contact in 14 days. A "Pro candidates" card on the staff Home with counts by status.
- **Price editor checks:** when a super admin edits add-on or plan prices, the editor shows the Growth + two add-ons total against Pro for each currency and period, and warns if the G.1 rule is broken (save still possible with 🔑 and a reason).
- **Reports:** monthly add-on revenue by add-on, Growth organisations with add-ons, and how many moved to Pro within 90 days of their first add-on.

### G.6 Website
- **Pricing page:** an **"Add-ons for Growth"** section under the plan cards with the three add-ons, their prices (from the plans API) and one line: "Need two or more? Pro is better value." (This restores the add-ons section removed in change 09, now backed by real add-ons.)
- **Plan calculator** (change 01): includes add-ons when the inputs need more domains, more clicks or fraud protection on Growth; recommends **Pro** whenever Growth + add-ons is 90% of Pro or more, and shows the comparison ("Growth + 2 add-ons ₦117,500 vs Pro ₦120,000 — Pro includes …").
- **Comparison table:** a row "Available as Growth add-ons" listing the three.
- Wording: "add-ons", never "pay as you go" (they are prepaid monthly items). No time or savings claims beyond the plain prices.

### G.7 Dashboard (customer)
- **Plan & usage → Add-ons** tab (Growth only): the three cards with what they add, price per period, status (Not added, Waiting for payment, Active, Ending on {date}), Add / Remove at renewal, and the G.3 Pro message.
- Usage meters and limits include add-ons (e.g. "5 of 5 domains (2 Growth + 3 Domains pack)").
- Fraud screens: on Growth with the Fraud protection add-on, the Pro actions are enabled; without it, the existing read-only message adds "Add Fraud protection for ₦45,000 a month, or upgrade to Pro".
- Domain limit message: "Your plan includes 2 domains. Add 3 more with the Domains pack, or upgrade to Pro for 10."
- Starter, Pro and Enterprise don't see the tab (Starter sees "Add-ons are available on Growth").

### G.8 Dashboard (staff console)
- The Pro candidates list, actions and Home card (G.5); add-on definitions in the plan-version editor with the price check; the organisation page shows active add-ons and their history; staff can apply or end an add-on with 🔐 (audit-logged), e.g. after a payment.

### G.9 Tests
- Entitlements with each add-on and combinations; limits and feature checks; max one each; Growth only.
- Proration for the days left; renewal invoices with add-ons; period discounts; removal at renewal; ending on upgrade with the credit line; ending on expiry or downgrade.
- The 90–99% price rule check and editor warning, for NGN and USD and each period.
- "Pro instead" message thresholds; calculator recommendations.
- Pro candidates rules, alert, digest, statuses, audit log.

### G.10 Milestones
1. **C10-B2** G.1–G.5 backend: add-on definitions in plan versions, subscription add-ons, entitlements, request and payment flow, proration, invoices and renewals, Pro candidates rules and alerts, price check, reports, tests; regenerate `openapi.json`.
2. **C10-F2** G.7 customer screens and calculator integration in the dashboard, tests.
3. **C10-F3** G.8 staff console screens, tests; update `docs/PROGRESS.md`.
4. **C10-W4** G.6 pricing page, calculator and comparison table on the website; Lighthouse and accessibility checks.

---

## D. Part 3 — Free deep links (owner decision, 2026-10-27)

### D.0 Why
New apps should be able to add the Clikgate SDK and have working deep links from day one, for free. Once the SDK is in the app, upgrading to Growth for attribution is a small step, not a new integration. **The free part makes links work; Growth tells you which links work.**

### D.1 What Free and Starter now include
| | Free | Starter | Growth and up |
|---|---|---|---|
| Apps (an iOS + Android pair counts as one app) | 1 | 1 | As today |
| Direct deep links into the app's own screens when the app is already installed (Universal Links, App Links, URI schemes) | **No limit** | **No limit** | No limit |
| **Deferred deep links** (someone without the app taps a link, installs it, and the app opens on the intended screen) | **1,000 a month** | **10,000 a month** | Unlimited |
| Tracked clicks a month (all links) | **1,200** (was 2,000; D.1a) | 25,000 | As today |
| App link subdomain | `{app}.clk.ng` | `{app}.ciz.to` | `{app}.ciz.to` (change 09) |
| Test app link subdomain | `{app}.dev.ciz.to` | `{app}.dev.ciz.to` | `{app}.dev.ciz.to` |
| Link behaviour per link (open app or store / open app or website / web only), iOS helper page, validator, debugger | ✓ | ✓ | ✓ |
| Mobile SDKs, setup command and `doctor`, AI setup guides, test mode | ✓ | ✓ | ✓ |
| **Install attribution** (which link, campaign or creator brought each install), in-app events and SDK goals, re-engagement, referrals, leaderboards, challenges, uninstall tracking, Apple Search Ads, SKAdNetwork, install fraud scoring | — | — | ✓ (as today) |

- Implement as a new feature key `deep_linking` (Free and up) separate from `app_attribution` (Growth and up), plus limits `apps` and `deferred_deep_links_per_month`, through a **new plan version** (change 01 workflow, 🔐🔑).
- The app subdomain rules from change 09 N.1 apply to all plans; on Free the hostname is under `clk.ng` and gets `clk.ng`'s abuse controls (verified email and phone before the first app, reputation checks, reserved names). Wildcard DNS and a certificate for `*.clk.ng` (first-level wildcard). Shared domains still never list customer apps.

### D.1a Free plan click allowance: 2,000 → 1,200 (owner decision, 2026-10-27)
- New plan version (change 01 workflow, 🔐🔑) sets Free tracked clicks to **1,200 a month**. All other Free allowances stay.
- **New Free organisations** get 1,200 from activation. **Existing Free organisations** move to 1,200 from the first day of the next calendar month after activation, with an email and dashboard notice at least 14 days before ("From {date}, the Free plan tracks 1,200 clicks a month. Your links keep working. Starter tracks 25,000.").
- The existing Free rules apply to the new number: links never stop redirecting; warnings at 80% (960) and 100% (1,200); analytics counting pauses at 120% (1,440) until the next month. Routing data for app links is still recorded (D.2), so deep links and deferred deep links keep working within their own limits.
- Update the pricing page, plan cards, comparison table, calculator defaults, plan info API, docs and the onboarding/lifecycle email copy that mentions the Free allowance.

### D.2 Counting deferred deep links
- One **deferred deep link** = a first app open after an install that receives deep-link data matched to an earlier click on that organisation's link. Counted per organisation per calendar month (organisation time zone). Test mode never counts.
- Warnings at 80% and 100% (email, dashboard banner, webhook `usage.threshold`), like other allowances.
- **At the cap nothing breaks:** links still open the installed app or the store and website as usual; direct deep links keep working; only the deferred data is held back until the next month, so **new installs open the app's home screen instead of the exact screen**. The SDK receives "no deferred link" (its normal empty result) and must never error. The owner sees "Deferred deep links paused until {date} — upgrade to Starter / Growth for more."
- **Routing data for app links is always recorded** (so deferred matching can work) even after the Free plan's analytics click counting pauses at 120%; analytics still follow the plan's click rules.

### D.3 What happens to the match data
- To deliver a deferred deep link Clikgate works out which click led to the install. On Free and Starter this match is used for routing and kept for **30 days**; it is **not shown** (no per-link, campaign or source install reports, not in the API, exports or webhooks).
- **On upgrading to Growth,** installs matched in the last 30 days appear in attribution reports straight away ("Your last 30 days of installs are ready"). This is a selling point: the integration and the data are already there.

### D.4 The upgrade teaser
- A card on the Overview and Apps pages (Free and Starter, when there was at least one matched install this month): **"214 installs came through your links this month. Upgrade to Growth to see which links and campaigns brought them."** with **Upgrade to Growth** and **Compare plans**.
- A matching line in the weekly summary email.
- Shows the **total only**: never a breakdown by link, campaign, country or source, and never through the API.
- Owners and admins can dismiss it for 30 days.

### D.5 SDKs
- No new SDK methods. Confirm every SDK handles "deep linking on, attribution off" (no install or event reports sent, or they are accepted and discarded server-side without errors) and the "no deferred link" result at the cap. `goal()` and event methods on Free/Starter log a one-time console warning ("needs Growth") and do nothing. Update SDK READMEs and docs.
- The setup command and AI guides work on Free: they configure deep links and the app subdomain (`{app}.clk.ng` in release builds on Free, `{app}.dev.ciz.to` in debug builds).

### D.6 Downgrades and upgrades
- Growth → Starter or Free: deep links keep working; attribution data becomes read-only per the existing downgrade rules; a second app beyond the limit becomes read-only (its links keep redirecting to the store or website, deep links into it stop) — the owner chooses which app stays active. The app's subdomain moves from `ciz.to` to `clk.ng` only when downgrading to Free, with old links kept redirecting for 180 days.
- Free → Starter: `{app}.clk.ng` links keep working; new links use `{app}.ciz.to` ("Move to ciz.to" as for other links).

### D.7 Tests
- Feature split (`deep_linking` vs `app_attribution`) on every plan; app limits; subdomains on each plan and their well-known files.
- Deferred counting, warnings, the cap behaviour (no errors, direct links unaffected), monthly reset, test mode excluded.
- Match data hidden on Free/Starter in every API, export and webhook; visible after upgrade for the last 30 days; deleted after 30 days.
- Teaser shows totals only; dismiss; summary line.
- SDK behaviour without attribution; downgrades and upgrades.

### D.8 Website
- **Pricing comparison rows:** "Deep links into your app — every plan"; "Deferred deep links a month — Free 1,000 · Starter 10,000 · Growth and up unlimited"; "Tracked clicks a month — Free 1,200"; "Install attribution (which link brought each install) — Growth and up"; "Apps — Free 1 · Starter 1".
- Plan cards: Free and Starter gain "✓ Deep links into your app".
- **Deep linking product page:** a section "Free deep links for your app" (what's free, the limits, what Growth adds, the teaser idea in plain words) and a "Moving from Firebase Dynamic Links?" box linking to link import and the docs (factual, no claims about other tools).
- **Developers page** and docs: "Deep links on the free plan" guide.
- Wording: never "free forever" or time claims; "Deep links are included on every plan."

### D.9 Dashboard
- Free and Starter see **Deep linking** (apps, link behaviour, validator, debugger) and the app subdomain; attribution tabs show the plan intro page with "Upgrade to Growth".
- A usage meter for deferred deep links on Plan & usage and the Apps page.
- The teaser card (D.4) and the "last 30 days are ready" message after upgrading.

### D.11 Staff: upgrade opportunities for organisations hitting limits (owner decision, 2026-10-27)
Extend G.5's **Pro candidates** into one staff list, **Billing → Upgrade opportunities**, with three tabs: **Free → paid**, **Starter → Growth** and **Growth → Pro** (the G.5 rules). An organisation appears with every reason that applies, the plan suggested and the monthly price difference.

| Tab | An organisation appears when (in the last 30 days unless stated) | Suggested plan |
|---|---|---|
| Free → paid | deferred deep links reached 80% or the 1,000 cap; tracked clicks reached 80% (960) or counting paused at 120%; the 50-links-a-month limit was reached; tried to add a second app; the install teaser (D.4) showed 100+ installs this month; opened an upgrade page for a Growth feature (attribution, referrals) 3+ times | Starter if only clicks, links or `ciz.to` are the issue; Growth if installs, attribution or the deferred cap are the issue |
| Starter → Growth | deferred deep links reached 80% or the 10,000 cap; tracked clicks above 80% or overage billed; tried to add a second app or a second domain; the install teaser showed 500+ installs this month; opened a Growth feature's upgrade page 3+ times | Growth |
| Growth → Pro | the G.5 rules (two add-ons, add-on + high usage, repeated overage, abandoned add-on after the Pro message) | Pro |

- **Columns:** organisation, current plan, reasons (as chips with the numbers, e.g. "Deferred 1,000/1,000 on 14 Nov", "Clicks paused"), suggested plan and price difference, installs this month (total only), months on the plan, owner's name and email (and phone if the organisation gave one), last contact, assigned staff member, status (`new|contacted|offer_sent|upgraded|not_now`), next follow-up date.
- **Actions** (as G.5): assign, log a contact (note and channel), set a follow-up date, change status, open the organisation; audit-logged. "Upgraded" is set automatically when the organisation's plan goes up, and staff see which contacts led to upgrades.
- **Sorting and filters:** by reason, plan, suggested plan, status, assigned to me, no contact in 14 days; default sort puts organisations at a hard limit (cap reached, counting paused) first.
- **Alerts and digest** (change 09 staff alerts): an alert when an organisation **hits a hard limit** (deferred cap, clicks paused, link limit, second app refused); a weekly digest of opportunities with no contact in 14 days. A staff Home card "Upgrade opportunities" with counts per tab and per status.
- **Respect customers' choices:** organisations whose owner asked not to be contacted for sales (a new **Do not contact for sales** flag on the organisation, set by staff on request and shown in the list) stay visible but greyed out and are excluded from the digest. Staff use only the contact details the organisation gave Clikgate. Unsubscribing from lifecycle emails (change 04) does not hide an organisation from the list, but the list shows it.
- **Reports:** monthly opportunities per tab, contacts made, upgrades within 30 and 90 days, and revenue added.
- **Tests:** each rule and threshold, suggested plan logic, automatic "upgraded", hard-limit alerts, digest, Do not contact flag, audit log.

### D.10 Milestones
1. **C10-B3** D.1–D.7 and D.11 (opportunity rules, alerts, digest, Do not contact flag, reports): plan version, feature split, limits, `*.clk.ng` app subdomains, counting and cap, hidden match data and 30-day reveal, teaser totals, summary line, SDK checks and docs, tests; regenerate `openapi.json`.
2. **C10-F4** D.9 dashboard screens and the staff **Upgrade opportunities** list with its three tabs, actions and Home card (D.11; replaces the separate Pro candidates screen from G.8), tests.
3. **C10-W5** D.8 website pricing rows, product page section, docs; Lighthouse and accessibility checks.

---

## E. Part 4 — Fraud protection page, setup sessions and Slack support (owner decisions, 2026-10-27)

### E.1 Website: a full "How fraud protection works" page (`/products/fraud-protection`)
The current page doesn't show *how* fraud protection works. Rebuild it so a sceptical marketer or finance lead can see the exact rules, try them, and understand the limits. **"Proof" here means transparency and things people can check themselves** — published rules, a live simulator, example evidence and the customer's own data — never invented results, customer numbers or percentages ("blocks 99% of fraud" is banned).

Sections, in order (real components, example data labelled "Example data"):
1. **Hero:** headline **"See which installs are fake — and exactly why."** Subhead: "Every attributed install gets a fraud score from 0 to 100 with plain reasons, so you can stop paying for fake installs and show ad networks the evidence." Buttons: **Start free** and **Talk to us**.
2. **The problem:** install farms, click flooding, emulators, fake sign-ups for bonuses, and wasted ad spend that looks like growth. Short, factual, no statistics unless sourced and dated.
3. **How it works — a drawn flow:** click recorded → install arrives → nine signals checked → score 0–100 with reasons → flagged at the threshold (70 by default) → Growth: see it and the wasted spend; Pro or the Fraud protection add-on: exclude or hold for review → excluded installs are never sent to ad platforms → dispute evidence for ad networks.
4. **Every rule, published:** a table read **from the public rules endpoint (E.3)**, so the page always matches the product: each rule's name, what it means in plain words, why it signals fraud, its default weight, and an example (e.g. "Install less than 10 seconds after the click — a real person can't download and open an app that fast — weight 45").
5. **Try it — the score simulator:** toggles for each signal (and a click-to-install time slider); the page adds up the score with the published weights, shows the reasons and whether the default threshold flags it, and what a Growth vs Pro customer would see. Runs in the browser; labelled "Example — uses our published default rules".
6. **An example flagged install:** the real dashboard install-detail component with example data: timeline (click 14:02:11, install 14:02:16 — 5 seconds), network type "data centre", device "emulator", score 85, reasons listed, actions (Mark real / Mark fake / Exclude).
7. **Built for African mobile networks:** MTN, Airtel, Glo and 9mobile are never treated as data-centre traffic; the device-farm rule is weighted lower on them; decisions are never made on IP address alone — so ordinary mobile users aren't wrongly flagged. Explain why this matters (false flags cost real customers).
8. **You stay in control:** the threshold slider (50–95), rule switches and weights, per-network overrides, hold for review, mark real or fake one by one or in bulk; nothing is deleted, and flagged installs stay visible.
9. **Wasted spend and evidence:** how wasted spend is calculated (flagged installs × the campaign's cost per install); a **sample dispute evidence CSV** to download (example data, the real column layout); how customers use it with ad networks. Honest line: "Whether an ad network refunds you is their decision."
10. **Referral and bonus fraud:** hold periods, self-referral and existing-user blocks, referrer quality scores, duplicate-identity checks (Pro), uninstalls during the hold; link to referrals.
11. **Privacy:** no fingerprinting on iPhone, IP addresses not stored in raw form, optional Apple App Attest and Google Play Integrity checks.
12. **How we keep it honest:** the rules and weights are published here; Clikgate's automatic end-to-end checks confirm every day that a data-centre install is flagged (change 08); rule changes are announced in the changelog; the limits — scores are signals, not proof; Clikgate doesn't block traffic at the ad network; older SDK versions send fewer signals; no system catches everything.
13. **See it on your own data:** the **fraud test lab** in test mode (E.2) for anyone who signs up, and fraud insights on Growth with real installs.
14. **Plans:** Growth — fraud insights (flags, reasons, wasted spend); Growth + Fraud protection add-on (₦45,000 a month) or Pro — exclude, hold, thresholds, evidence. Prices from the plans API; link to the calculator.
15. **FAQ:** What if a real customer is flagged? Can I change the rules? Do you block the traffic? Do you send fake installs to Meta or Google? What's in the evidence file? Does it work for websites? (Bots and preview robots are labelled for every link; install scoring needs the app SDK.) Is it on iPhone? Will it slow my app?
- Link to the page from the home page's fraud mention, the Ad spend & ROAS page, pricing (fraud rows and the add-on), the Growth → Pro upgrade prompt and the docs.
- SEO: title "Install fraud protection: how Clikgate scores every install — Clikgate"; FAQ structured data; `llms.txt`.

### E.2 Fraud test lab (dashboard, test mode only)
- In **Protect → Fraud** while in **Test mode**: "Create a sample install" with the signals to include (fast install, install before click, data-centre network, emulator, click flooding pattern, device farm pattern, country mismatch, known bad device, slow install). Clikgate creates a test install through the normal scoring pipeline and shows its score, reasons and what each plan's settings would do.
- Available on every plan in test mode (it never touches live data, usage or billing). Up to 50 sample installs a day per organisation; "Clear samples" removes them.
- Backend: `POST /v1/test-data/fraud-samples` (test keys or a test-mode dashboard session only; refused in live mode) `{signals: [...], click_to_install_seconds?, network_type?}` → the scored test install.

### E.3 Public rules endpoint
- `GET /v1/public/fraud-rules` → the default rules: key, name, plain description, why it matters, default weight, default threshold, the mobile-carrier adjustments, and `updated_at`. No secrets, cached, versioned. The website page and the simulator read it at build time and refresh daily; a CI check fails the website build if the page's rules differ from the endpoint.
- When default rules or weights change, a changelog entry is required (staff tooling reminds them).

### E.4 Setup session and Slack support (Growth and above) — owner decision, 2026-10-27
**E.4.1 What customers get** (plan feature `slack_support` and `setup_session` through a new plan version, change 01 workflow):
| Plan | Help from the Clikgate team |
|---|---|
| Free | Docs (self-serve help pages and guides) |
| Starter | Email support |
| **Growth** | A **1-on-1 setup session** with our team, then help **on Slack** in a shared channel |
| **Pro** | A 1-on-1 setup session, then help on Slack (priority) |
| **Enterprise** | A 1-on-1 setup session, help on Slack, a named contact and the support terms in the contract |
- **No schedule or count of sessions** is promised beyond the one setup session. Don't publish response times.
- The **setup session** is a video call (up to 45 minutes, up to 5 people from the organisation) to get links, goals, apps, sales connections and reports set up. One per organisation when it first moves to Growth or above (not again on renewals or plan changes within Growth and above).
- **Slack:** a shared channel between the organisation and the Clikgate team (Slack Connect). Customers who don't use Slack get help by email instead.
- Replaces the earlier support line "Email + WhatsApp" for Growth: Growth and above use Slack; Starter uses email; Free uses the docs. Update the pricing support row accordingly.
- Wording: "1-on-1 setup session and help on Slack". Never promise a specific person or a response time.

**E.4.2 Backend**
- `setup_sessions`: organisation, requested_by, topics (links, goals, apps, sales, fraud, referrals, platform integration, other), notes, up to 3 preferred times (organisation time zone), attendees (up to 5 members or verified emails), status (`requested|scheduled|completed|cancelled|no_show`), scheduled_at, meeting link, staff member, staff notes (private) and shared notes. One completed or scheduled session per organisation per move to Growth and above; staff can grant another (🔐, with a reason).
- `slack_channels`: organisation, status (`requested|invited|active|closed`), the email(s) to invite, channel name, requested_by, staff member, created_at. Closed automatically (staff task created) when the organisation drops below Growth.
- Emails: setup session requested, scheduled (time, link, calendar file), reminder the day before, follow-up with shared notes; Slack invitation sent (with what to expect). Staff alert for new requests (change 09 staff alerts).

**E.4.3 Dashboard**
- **Customer:** Help → **Get help from our team**. Growth and above: **Book your setup session** (shown until used) and **Join our Slack channel** (request with the email(s) to invite; shows the status); Starter sees "Email support@… — 1-on-1 setup and Slack help come with Growth"; Free sees links to the docs and guides with "Email support comes with Starter; setup and Slack help with Growth"; both see the plan intro.
- After upgrading to Growth or above, a one-time prompt: "Book your 1-on-1 setup session".
- **Staff console:** **Setup sessions** queue (propose or set a time and link, assign, complete, notes) and **Slack channels** queue (create the shared channel in Slack, then mark invited and active, assign the staff owner); staff Home cards for open requests; both shown on the organisation page.

**E.4.4 Website**
- Pricing comparison row **"Help from our team"**: Free "Docs" · Starter "Email" · Growth "1-on-1 setup session + Slack" · Pro "1-on-1 setup session + Slack (priority)" · Enterprise "Setup session, Slack, named contact". Plan cards for Growth and up gain "✓ 1-on-1 setup session and help on Slack". The pricing FAQ explains both.

### E.5 Tests
- Public rules endpoint and the website CI check; simulator maths against the endpoint's weights.
- Fraud test lab refused in live mode, daily limit, scoring results match the live scoring pipeline.
- Setup session once per move to Growth and above, staff grant of another, Slack channel requests and automatic close on downgrade, emails, staff queues, Starter sees email support and Free the docs only.

### E.6 Milestones
1. **C10-B4** E.2 backend sample endpoint, E.3 public rules endpoint, E.4.1–E.4.2 setup sessions, Slack channel requests and plan version, tests; regenerate `openapi.json`.
2. **C10-F5** E.2 fraud test lab screen, E.4.3 customer help page and staff Setup sessions and Slack channels queues, tests.
3. **C10-W6** E.1 the fraud protection page with the simulator and sample CSV, E.4.4 pricing "Help from our team" row and FAQ; Lighthouse and accessibility checks.

---

## Definition of done
- "Platforms & marketplaces" appears in Solutions → Your industry and links from Agencies, Developers and Pricing.
- The page explains the platform model end to end with a drawn architecture, real code in six languages that runs in CI, playbooks, an example dashboard, plans, honest limits and FAQ — with no invented customers or numbers.
- Platform enquiries reach staff and can be filtered in the staff console.
- Growth organisations can buy the Domains pack, Clicks pack and Fraud protection (each once), priced so any two bring the total to 90–99% of Pro; the dashboard and calculator suggest Pro at that point; staff see Pro candidates with reasons and follow them up.
- Free tracks 1,200 clicks a month (existing Free organisations from the next month, with notice).
- Free and Starter apps (1 each) get working deep links and deferred deep links (1,000 and 10,000 a month) on their own app subdomain; install attribution stays on Growth; the teaser shows totals only, and upgrading reveals the last 30 days.
- `/products/fraud-protection` explains every rule from the live rules endpoint, lets visitors try the score simulator, shows example evidence and the limits; anyone can try the fraud test lab in test mode.
- Growth and above get a 1-on-1 setup session and help on Slack; Starter gets email support and Free the docs; staff run setup sessions and Slack channels from their queues.
- Staff see every Free, Starter and Growth organisation hitting a limit in **Upgrade opportunities**, with reasons, suggested plan, alerts and follow-up tracking.

## Before building: things only the owner can provide
- Approval of the page wording (the builder lists it in `docs/PROGRESS.md`).
- Whether any real platform customer may be named (default: none).
- ~~Confirmation of the add-on prices~~ — confirmed by the owner on 2026-10-27 (G.1 prices are final).
