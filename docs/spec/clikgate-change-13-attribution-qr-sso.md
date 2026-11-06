# Clikgate Change 13 — One Link, Many Doors (where clicks came from), QR Placements and the QR Designer, the Referral Map, "App banners", and Single Sign-on with Custom Roles

> **Instructions for the AI building this:**
> - Changes 01–12 are built (nothing is live yet). This change has five parts:
>   - **Part 1, Where clicks came from:** every click gets **Clicked on** (where the tap happened, evidence first) and **Shared as** (which version of the link was shared). Share endings (`ciz.to/summer-w`), share helpers, preview-fetch share counts with a labelled estimate, and the "Where clicks came from" panel.
>   - **Part 2, QR:** QR codes use the `-q` ending; **QR placements** (`-q1`, `-q2`…) with their own reports; the **QR designer** (logo, shape, frame, margin, a real scan check before every download); and the `/short-links` page's new QR content (W.1).
>   - **Part 3, Referral map:** a pan-and-zoom canvas of who brought whom across campaigns, leaderboards and challenges.
>   - **Part 4, Rename "Journeys" to "App banners"** everywhere.
>   - **Part 5, Single sign-on, the branded sign-in page and custom roles** (Pro and Enterprise; a single sign-on add-on for Growth).
> - **Backend repository** (`clikgate`, including `sdks/`): sections A, B and S; milestones C13-B1 to C13-B10 and C13-S1 to C13-S2.
> - **Dashboard repository** (`clikgate-dashboard`): sections A and F; milestones C13-F1 to C13-F8, after the backend part is deployed and the OpenAPI types are regenerated.
> - **Website repository** (`clikgate-website`): sections A and W; milestones C13-W1 to C13-W2.
> - **Design references** (the owner shares them with the builder; numbers in them are example data):
>   - "Clikgate Where Clicks Came From" (https://claude.ai/artifact/G9fCoPcGHpXseuxnHPv2pa): Share menu, certainty bar, By app table, QR placements table, Clicked on vs Shared as, Shared on, phone share sheet and website share widget.
>   - "Clikgate QR Designer" (https://claude.ai/artifact/Ni1VYuocxL32aQEmRDCSyP): live preview, logo shapes, margin, frame, scan check.
>   - "Clikgate Referral Map" (https://claude.ai/artifact/AejWCRCJcmCzYXVTeSWqe5): canvas, frames, chain tree, clusters, side panel.
>   - Match their layout, flow and wording; colours and type follow the dashboard design system.
> - **Check current official documentation before building**, and record findings with dates in `docs/DECISIONS.md`: Android `Intent.createChooser` with `IntentSender` and `EXTRA_CHOSEN_COMPONENT`; iOS `UIActivityViewController` completion handler and `activityType` values; the Web Share API; the in-app browser user-agent markers of Instagram, Facebook, TikTok, LinkedIn, Snapchat, X and others; preview-fetch user agents (WhatsApp, Telegram, iMessage, Slack, Discord and the existing bot list); OpenID Connect (authorisation code with PKCE, `state`, `nonce`, `prompt=none`) and SAML 2.0 (signed assertions, metadata) with Google Workspace, Microsoft Entra ID and Okta; the maintained SAML/OIDC library you choose; zxing or zbar for server-side QR decoding. Never guess a value; write what the docs say.
> - **Later changes win.** This file supersedes: backend spec 10 (`GET /v1/links/{id}/qr` encoding `?qr=1`, and its `margin=0..8`, now 2–4), change 10 G.1's price rule (amended in B.10), and change 01's placeholder `flags.sso` (replaced by feature keys, B.9). It adds to, and does not remove, the existing `channel` groupings (offline touches, spend, challenges, goals analytics).
> - Nothing is live, so renamed fields, routes and keys are renamed outright (no compatibility period), except where this file says a legacy name is kept.
> - Never log secrets, keys, SSO client secrets, SAML certificates' private parts, tokens, payloads or private-mode references. Run the full test suite after each milestone.

---

## A. Overview and decisions

| # | Decision |
|---|---|
| D1 | **One link everywhere.** A business shares `ciz.to/summer` everywhere; Clikgate tells it where clicks came from without separate links per platform. |
| D2 | **Two answers per click.** `clicked_on` = where the tap happened, strongest evidence first (paid ad click → the app's own browser → the referring site → the share ending or the link's Made for → `direct_or_unknown`). `shared_as` = which version of the link was shared (the ending or channel, or `plain`). Confirmed evidence overrides the tag. Never guess. |
| D3 | **Share endings:** a hyphen and one letter on the link: `-w` WhatsApp, `-i` Instagram, `-f` Facebook, `-t` TikTok, `-x` X, `-l` LinkedIn, `-s` SMS, `-g` Telegram, `-e` Email, `-y` YouTube, `-q` QR. **Reserved:** no link name may end in a hyphen and one letter, or `-q` followed by digits. The table lives in code, is **not published** on the website or docs, and staff with a dedicated permission can only **view** it. |
| D4 | **Preview fetches are share counts, not clicks.** "Shared on WhatsApp 6 times today" is a count (a minimum, since some phones turn previews off and apps fetch from shared servers); "likely from WhatsApp shares: about 70" is a separate, labelled **estimate** that never feeds attribution, goals, referrals, leaderboards, challenges, ad sending or billing. |
| D5 | **Certainty is always shown:** Confirmed · Tagged · Estimated · Unknown, with labels and patterns, never colour alone. |
| D6 | **QR codes encode `-q`;** **QR placements** get `-q1`, `-q2`… on the same link, numbered per link and never reused. `?qr=1` stays accepted forever. |
| D7 | **QR designer:** logo (Square, Rectangle or Circle; corner radius; spacing), colours, frame, margin 2–4, error correction H with a logo; a **server-side scan check** before every download. Logo cover at most 20%, never touching the corner squares, timing lines or alignment squares. |
| D8 | **Referral map:** Growth and up; customer dashboard only; no sharing; each card shows sales from everyone the person brought in. Insight, not a payout calculator: Clikgate never computes multi-level rewards and never messages anyone on the map. |
| D9 | **"Journeys" becomes "App banners"** everywhere a person reads it, and in the API; `jrn_` IDs and `?jrn=` stay as legacy names. |
| D10 | **Single sign-on** (OpenID Connect and SAML 2.0) on **Pro and Enterprise**, and on **Growth with the Single sign-on add-on**. Needs at least one custom link domain verified by DNS. |
| D11 | **Branded sign-in page** on **Pro and Enterprise** (agencies on Pro included): only on the organisation's own verified link domain (`go.yourbrand.com/login`); SSO required, so no password box; **"Powered by Clikgate" always at the bottom**. Never called "white-label". |
| D12 | **Custom roles** (named roles with ticked permissions) on **Pro and Enterprise**. The four standard roles stay. Some powers never go in a custom role. |
| D13 | **Dropping below the plan pauses SSO-only staff; it never deletes them.** At least one Owner always keeps a normal Clikgate sign-in. |
| D14 | **Single sign-on add-on for Growth** priced so Growth + add-on is a little under Pro; the add-on screen always offers Pro first and sales get a Pro lead. |
| D15 | **Honest promise:** "Share one link everywhere. Clikgate tells you where each click came from: automatically for social apps and ads, and for WhatsApp, SMS and email when you share with Clikgate's Share button. Anything left shows as Direct or unknown, with an estimate of where it came from." Never "automatically knows every social network". |
| D16 | **The `/short-links` page sells QR codes properly** (owner, 2026-10-29): the existing page and its look stay; it gains logo customisation in the try-it box and showcase, and a full set of QR sections: use cases for every surface, placements, codes that open apps, bulk and API, built to scan, and QR questions in the FAQ (W.1). |

**Plans for this change**

| | Free | Starter | Growth | Pro | Enterprise |
|---|---|---|---|---|---|
| Clicked on / Shared as on every click, basic split by app | ✓ | ✓ | ✓ | ✓ | ✓ |
| Share menu, share endings, share helpers | ✓ | ✓ | ✓ | ✓ | ✓ |
| "Shared on" counts | ✓ | ✓ | ✓ | ✓ | ✓ |
| Likely-from-shares estimate | — | ✓ | ✓ | ✓ | ✓ |
| Full "Where clicks came from" panel (certainty bar, Clicked on vs Shared as, goals by app) | — | — | ✓ | ✓ | ✓ |
| QR placements per link (`qr_placements_per_link`) | 3 | 10 | 50 | unlimited | unlimited |
| QR designer | colours | + logo, shape, frame | + saved organisation QR style | same as Growth | same as Growth |
| Referral map | — | — | ✓ | ✓ | ✓ |
| Single sign-on (`sso`) | — | — | add-on | ✓ | ✓ |
| Branded sign-in page (`branded_sign_in`) | — | — | — | ✓ | ✓ |
| Custom roles (`custom_roles`) | — | — | — | ✓ | ✓ |

The estimate from Starter and the full panel from Growth are the owner's provisional choices; confirm before C13-B3 (see "Before building").

---

## B. Backend

### Part 1 — Where clicks came from

#### B.1 Click fields and the order of evidence (D2)
- New click fields (also on attributed installs, conversions and goal events, copied from the click):
  - `clicked_on`: `whatsapp|instagram|facebook|tiktok|x|linkedin|snapchat|youtube|telegram|sms|email|qr|google_ads|meta_ads|tiktok_ads|google_search|other_site|direct_or_unknown` (enum `ClickedOn`; new values only by code release).
  - `clicked_on_basis`: `ad_click_id|in_app_browser|referrer|share_tag|none`.
  - `shared_as`: the same values as `clicked_on` limited to the share-ending table and Made for values, or `plain`.
  - `share_ending` (nullable, the letter seen, e.g. `w`) and `qr_placement_id` (nullable, B.5).
- New optional **link field `made_for`** (same values as `shared_as`, nullable): "this link was made for WhatsApp". Also on bulk create and the API. (Not called `channel`: that name already means offline and spend channels elsewhere.)
- **Order for `clicked_on`** (first match wins), set at click time in the redirect service (backend spec 11) and at the edge Worker for backup clicks (change 08 E, same code shared as a data-driven module):
  1. **Paid ad click** (already stored by change 02): `gclid`, `gbraid`, `wbraid` → `google_ads`; `ttclid` → `tiktok_ads`; basis `ad_click_id`. **`fbclid` alone is not proof of an ad**: Facebook and Instagram add it to ordinary unpaid links too. A click with `fbclid` counts as `meta_ads` only with a paid signal (the `{{site_source_name}}` placement tag, `cg_ad_id`/`cg_campaign_id`, or a paid `utm_medium` such as `cpc`, `paid`, `paid_social` from the alias table). With a placement tag the platform is kept: `fb` → facebook, `ig` → instagram, `msg` → facebook (Messenger), `an` → other_site (Audience Network), and the click is also marked paid (`is_paid_ad = true`). `fbclid` without a paid signal falls through to steps 2–3 (usually facebook or instagram from the app's browser or referrer).
  2. **The app's own browser** from the user agent (existing `in_app_browser` detection, growth spec 6.1 and change 07): Instagram, Facebook (`FBAN`/`FBAV`), TikTok, LinkedIn, Snapchat, X and others in the maintained list; basis `in_app_browser`.
  3. **Referring site** (`referrer_host`) through a maintained table: `l.facebook.com`, `lm.facebook.com` → facebook; `l.instagram.com` → instagram; `t.co` → x; `lnkd.in` → linkedin; Google search hosts → google_search; YouTube redirect hosts → youtube; mail web clients where the host is known → email; anything else → other_site; basis `referrer`.
  4. **Share ending, then the link's `made_for`, then `utm_source`** mapped by a maintained alias table (`ig`, `insta` → instagram; `wa`, `whatsapp` → whatsapp; `fb` → facebook …); a QR ending or `?qr=1` → qr; basis `share_tag`.
  5. Otherwise `direct_or_unknown`, basis `none`.
- `shared_as` = the share ending if present, else the link's `made_for`, else `plain`.
- Known limit, documented: an Instagram-tagged link pasted into WhatsApp leaves no evidence, so it counts as Instagram with basis `share_tag` ("based on link tag").
- **Data files with tests:** `attribution/user_agents.yml`, `attribution/referrers.yml`, `attribution/utm_aliases.yml`, each with fixtures. The edge Worker (TypeScript) and the origin (Python) read the **same data files** and pass the **same shared fixtures** (one test suite run against both). **Marker monitor** (new daily job): per organisation and overall, the share of clicks with `in_app_browser` set compared with the 14-day baseline; a sharp drop for one app raises a staff alert ("Instagram's in-app browser marker may have changed").
- The edge Worker's backup click payload (change 08 B.2) gains `clicked_on`, `clicked_on_basis`, `shared_as`, `share_ending` and `qr_placement_id`; share events seen at the edge go on the same queue as type `share`.
- **Backfill** existing clicks from stored fields (ad click IDs, `in_app_browser`, `referrer_host`, `utm_source`, `is_qr`) in a resumable worker; never invent a value the stored fields don't support.
- **Analytics:** `group_by` gains `clicked_on`, `shared_as` and `qr_placement` on `/v1/analytics/summary`, `/v1/analytics/goals` and exports; filters with the same names. The existing `channel` groupings stay as they are (they include offline touches, codes and spend that have no click). Check what change 05's `source` grouping reads in the code today and record it in `docs/DECISIONS.md`; if it is the raw `utm_source`, rename it `utm_source`. Rollups: add `clicked_on` and `shared_as` to `dimension_stats_daily`.
- Webhooks and API objects for clicks, installs, conversions and goals include `clicked_on`, `clicked_on_basis`, `shared_as` and `qr_placement_id`.

#### B.2 Share endings (D3)
- **Table** in code (`attribution/share_endings.py`, not configuration): `w` whatsapp, `i` instagram, `f` facebook, `t` tiktok, `x` x, `l` linkedin, `s` sms, `g` telegram, `e` email, `y` youtube, `q` qr. New letters only by code release, with a test.
- **Resolving a path** (redirect service, before "not found"):
  1. Exact link name on that domain.
  2. If not found and the path ends in `-<letter>` from the table, or `-q<digits>`: strip it, resolve the link by exact name, and record `share_ending` (and the QR placement for `-q<n>`).
  3. Accept common mangling: upper case (`-W`), a percent-encoded hyphen (`%2D`), a trailing slash, and stray trailing punctuation (`.`, `,`, `)`, `!`, `?`) after the ending.
  4. Unknown letters are not stripped (the path resolves by exact name only, otherwise not found).
  5. Query strings and `+` (preview page, backend spec 11) keep working: `ciz.to/summer-w+` previews the link.
  6. `-q<n>` with no such placement: the link resolves, the click is a QR scan with no placement (`qr_placement_unknown = true` in debug only).
  7. **Referral code paths** (`/r/{code}`, `/invite?ref={code}` and other `code_url_patterns`, sdk-referrals spec 10): the ending goes after the code (`/r/ADA42-w`, `/invite?ref=ADA42-w`); generated referral codes never contain hyphens, and BYO codes ending in a hyphen and a letter are refused.
  8. **App opens through Universal Links / App Links** (`POST /v1/sdk/resolve`, sdk-referrals spec): strips endings the same way and sets `clicked_on` (from the SDK's reported referrer where available, else `share_tag`) and `shared_as`.
  9. A `-q` ending or a placement ending sets `clicks.is_qr = true`, exactly like `?qr=1`, so existing QR reports and the change 08 queue keep working.
- Works on every domain: shared link domains, app subdomains (change 09 N.1) and customers' own domains. Deep links and open-in-app (change 07) behave exactly as for the plain link. Backup redirects at the edge (change 08) resolve endings the same way.
- **Reserved rule:** link names, custom slugs and vanity codes may not match `-[A-Za-z]$` or `-[qQ][0-9]+$` → `422 reserved_link_ending` ("Link names can't end in a hyphen and one letter; that's reserved for sharing."). Generated codes never contain hyphens. Applies to create, rename, bulk import and migration imports (change 03). Migration: any existing test link breaking the rule is renamed by appending `-link` (e.g. `summer-w` → `summer-w-link`) and listed in `docs/PROGRESS.md`.
- **Not published:** the website and docs say only "the Share button adds a short ending so Clikgate knows where you shared it". The API returns ready-made `share_urls` (B.4) so integrators never need the table. In `openapi.json`, the API reference and SDK docs, `share_urls`, `share_ending` and the `ShareApp` enum are documented with **made-up example values** (e.g. `"share_ending": "z"` marked "example"), and the endings are never listed; a docs test fails if the real letter set appears together anywhere in published docs or OpenAPI.
- **Staff console:** a read-only "Share endings" page, visible only to staff with the new permission `share_endings.view` (granted per staff member by a super admin with 🔐). No edit controls exist.
- Why not secret by design: a hand-typed ending only changes `shared_as` and a `share_tag` basis; it can never create a confirmed source, count a goal, confirm a payment, qualify a referral or change billing.

#### B.3 Preview fetches and "Shared on" (D4)
- The existing preview-bot step (backend spec 11, step 5) keeps returning the Open Graph page and **never records a click**. For **chat and social preview agents only** (WhatsApp, Telegram, Facebook/Messenger, X, LinkedIn, Slack, iMessage, Discord, Snapchat; never search crawlers such as Googlebot, bingbot, Applebot or Pinterest) it also writes a **share event**: `link_share_events` (organization_id, link_id, share_ending (nullable), app (same enum as `ShareApp`: `whatsapp|instagram|facebook|tiktok|x|linkedin|telegram|sms|email|youtube|slack|imessage|discord|snapchat|other`), source `preview|helper`, occurred_at, ip_hash). Raw IPs never stored; never used to identify the sharer; excluded from allowances and billing.
- **Matching order:** iMessage's preview agent contains both `facebookexternalhit` and `Twitterbot`; match that combined string first (→ `imessage`), then the others. Fixtures for every agent.
- **Deduplicate:** one preview share event per (link, app, ip_hash) per 10 minutes. Telegram, Facebook and X fetch from shared servers and Facebook re-fetches pages, so counts are labelled "counted (a minimum)" and never "exact". A helper share (B.4) followed by its own preview fetch within 2 minutes for the same link and app counts once.
- **Counts:** `GET /v1/links/{id}/shares?from&to&group_by=app|day|source` and campaign totals. Labelled as a minimum ("Some phones and settings turn previews off, and some apps fetch once for many shares").
- **Estimate (Starter and up):** for each share event, unknown-basis clicks on that link in the following 6 hours with a decaying weight, minus the link's normal background rate of unknown clicks (same hours, previous 14 days). Output per link and app: a range (low–high), the point value, and confidence High / Medium / Low. Low when shares on several apps overlap, or the link had other clear sources in the same window; hidden below 20 unknown clicks. Computed hourly by worker `share_estimates`; stored in `link_share_estimates`.
- **Never used for** `clicked_on`, attribution, goals, referrals, leaderboards, challenges, ad-platform sending, fraud scores or billing (tests prove it). Exports label the columns "estimate".
- **Nudge data:** when the estimate says more than half of a link's **unknown** clicks over 7 days likely came from WhatsApp shares, the link's API object gets `suggestion: "make_whatsapp_link"` (message in F.1 matches this trigger).

#### B.4 Share helpers in the API
- Every link object gains `share_urls`: `{whatsapp: "https://ciz.to/summer-w", instagram: …, …, qr: "https://ciz.to/summer-q"}` for every letter in the table; also in bulk export and campaign link lists.
- `POST /v1/share-events` (SDK and web keys, change 09 web keys): `{link_id | url, app, share_ending}` records that a share happened through a helper (`source: helper`). A key can only record shares for its own organisation's links (others → `404`). Rate-limited like other public endpoints (change 12 B.6).
- Campaigns: the campaign Share menu lists each of the campaign's links with its own "Copy for …" options.

### Part 2 — QR

#### B.5 QR codes and QR placements (D6)
- `GET /v1/links/{id}/qr` encodes `…/{slug}-q` instead of `?qr=1` (shorter URL, fewer squares). `?qr=1` stays accepted forever and sets `shared_as = qr` like the ending.
- **QR placements:** `qr_placements` (id `qrp_`, organization_id, link_id, number (int, per link, never reused, also after deletion), name (required, ≤ 60), location_text (≤ 120), put_up_on, taken_down_on (dates), spend_minor + currency (optional), notes (≤ 500), status `active|archived`, created_by, timestamps). The placement's URL is `…/{slug}-q{number}`.
- Archived placements still resolve and are marked "archived" in reports.
- **Limits:** plan key `qr_placements_per_link` (Free 3, Starter 10, Growth 50, Pro and Enterprise unlimited); archived placements count until deleted. At the limit: `403 plan_limit_reached` (`param: qr_placements_per_link`); the general QR code still works.
- **Reports:** `GET /v1/links/{id}/qr-placements/report?from&to`: per placement scans, unique scanners, goals (the link's effective goal), goal rate, cost per scan and per goal (when spend is entered), first and last scan, daily series. Scans with `-q` or `?qr=1` only are "QR code, no placement".
- **API:** `POST /v1/links/{id}/qr-placements`, `GET …/qr-placements`, `PATCH …/qr-placements/{id}`, `POST …/{id}/archive`, `DELETE …/{id}` (owner and admin; number not reused). `qr_placement_id` on clicks and attributed goals; `group_by=qr_placement`.
- **Downloads:** per placement in PNG, SVG and PDF with the placement name printed small under the code (optional); `POST /v1/links/{id}/qr-placements/download` builds a ZIP of all active placements with `index.csv` (number, name, URL, file) as a background job (change 02 exports pattern, signed URL, 24 h).

#### B.6 QR designer and the scan check (D7)
Correction of earlier notes: today's QR endpoint supports SVG and PNG, size, margin and colours only. Logo, shape, frame, label and PDF are new here.
- **QR styles:** `qr_styles` (id `qrs_`, organization_id, name, is_default, dark_hex, light_hex, accent_hex, logo_key (R2), logo_shape `square|rectangle|circle`, logo_size `small|medium|large` (0.16 / 0.21 / 0.26 of the width of the symbol plus a fixed 4-square reference margin, whatever margin is chosen, so the logo doesn't change size when the margin changes), logo_corner_radius 0–50 (%), logo_padding 0–2 (squares, step 0.5), margin 2–4 (squares), frame `none|scan_me`, frame_text (≤ 22), show_label (bool), timestamps). The default style (Growth and up) applies to every new QR code and placement; each code can override.
- **Logo upload:** PNG, JPEG or SVG, ≤ 1 MB. SVG is sanitised (no scripts, event handlers, external references, `foreignObject` or embedded HTML) and rasterised server-side; stored in R2. Rectangle follows the logo's width-to-height ratio, capped at 2.6:1, with the same area as a square of the chosen size. Circle crops the logo to a circle; Square and Rectangle keep the whole logo inside a patch with matching corners.
- **Rendering:** with a logo the code always uses error correction **H**; without one, M. The logo sits on a knock-out patch in the code's background colour (white by default), same shape as the logo, with `logo_padding` around it. Frame: accent-colour border with the text below in white; white text on the accent colour must reach 4.5:1 (otherwise `qr_frame_unreadable`, fix "Use a darker frame colour"); the label (placement name) small under the code.
- **Long URLs:** from QR version 7 an alignment square sits in the centre, so a centred logo is impossible. When the URL needs version 7 or more at level H, the logo option is unavailable for that code with the message "This link is too long for a logo in the middle. Use a shorter link name or your short domain." (`qr_logo_unavailable_long_url`).
- **Rules checked before rendering** (each with a reason and a one-click fix in the dashboard):
  - contrast between dark and light at least 4.5:1, and dark must be darker than light (inverted codes refused) → `qr_colours_unreadable` ("Use darker squares" / "Swap colours");
  - patch cover at most 20% of the symbol area (measured for the actual shape, size, radius and padding) → `qr_logo_too_large` ("Make logo smaller");
  - the patch never reaches the finder squares, the timing lines (row and column 6) or any alignment square for the code's version → `qr_logo_covers_guides` ("Make logo smaller");
  - margin at least 2 squares → `qr_margin_too_small` ("Use Tight margin (2)").
- **Scan check:** **every** code (plain or designed) is decoded server-side with zxing or zbar at full size, at a small size (about 120 px, a 2 cm print), and blurred (Gaussian, about 1.2 px at 240 px). It must decode to the exact expected URL at all three, otherwise `422 qr_scan_check_failed` with `{tests: [...], reasons: [...]}`. Results cached by (style hash, URL).
- `GET /v1/links/{id}/qr` gains `style_id`, inline overrides (`logo_shape`, `logo_corner_radius`, `logo_padding`, `margin`, `frame`, `frame_text`, `label`), `placement_id` and `format=png|svg|pdf` (PDF print-ready with an optional 3 mm bleed). `margin` is 2–4 for every code (the old `0..8` is replaced; below 2 → `qr_margin_too_small`).
- **Plans:** Free colours only; Starter and up logo, shape, frame and label; Growth and up the saved organisation style (`plan_upgrade_required` otherwise).

### Part 3 — Referral map

#### B.7 Graph endpoint (D8)
- **A person** is a referrer or referee within the organisation, identified by `customer_user_id` (referrers.customer_user_id, referrals.referee_customer_user_id), or, without one, by installation (`referee_install_id` ∈ `referrers.known_installation_ids`). A chain forms when a referee later becomes a referrer in any programme of the same organisation.
- **Private mode** (change 05): chains connect by Clikgate's own referrer and installation IDs only; cards show the referral code, never a name or customer ID; sales show only from goals that allow value. Check how referrer identity is held in private mode today and record it in `docs/DECISIONS.md`.
- **Precompute** in worker `referral_graph` (every 15 minutes and on referral state changes): `referral_people` (person key, organization_id, display (masked per board display rules), first_referrer_person, joined_via_campaign_id, joined_via_program_id, direct_count, chain_size, qualified_count, direct_sales_minor, chain_sales_minor (organisation reporting currency, counted goal values attributed to the people they brought; payment goals use confirmed amounts), updated_at) and `referral_edges` (from_person, to_person, campaign_id, program_id, status, created_at).
- `GET /v1/referrals/graph?view=campaign|chain&root=&depth=&campaign_id=&program_id=&board_id=&cursor=&limit=`: opens folded: top 50 starting people by chain size (or by the chosen board's rank); in `view=campaign` each frame returns its top 10 (by the chosen board's rank, then chain sales) with a cursor for 8 more; `depth` ≤ 4 per call; people with more than 10 direct referrals return **clusters** per campaign (`{campaign, count, qualified, chain_sales}`) instead of people; `GET …/graph/clusters/{person}/{campaign}?cursor=` returns 8 people at a time ordered by chain sales.
- `GET /v1/referrals/people/{person}`: path upstream, direct vs chain counts and sales, chain by campaign, ranks on every leaderboard and challenge, **biggest branches** (top 5 direct referrals by their own sales plus their chain's).
- `GET /v1/referrals/people/search?q=` (name as displayed, or referral code) returns the person and the cluster and page that contain them.
- `GET /v1/referrals/people/{person}/chain.csv` (owners, admins, and custom roles with the referrals export tick).
- Opted-out (`leaderboard_opt_out`) and fraud-flagged people are shown without rank; never hidden from the chain counts (counts must add up), and the card says "Not ranked".
- Plan: Growth and up (`plan_upgrade_required`). Not in the staff console. No share links, no public endpoint. Clikgate never messages anyone from the map.
- Wording rules in every response label and doc: "people they brought in", "sales from everyone they brought in"; never "earn from your friends' friends" or "levels". Docs add: "Rewards are your decision. Some countries regulate multi-level rewards; check your local rules."

### Part 4 — App banners

#### B.8 Rename "Journeys" to "App banners" (D9)
Customer-facing name: **App banners**. Types: **Banner** (top or bottom bar), **Full-screen prompt** (was interstitial) and **Floating button**. Explainer: "Banners on your mobile website that open your app, or send people to install it and then open the same page."
- Routes: `/v1/journeys*` → `/v1/app-banners*`; `/v1/journey-sites*` → `/v1/app-banner-sites*`; `/v1/public/journeys*` → `/v1/public/app-banners*`.
- Loader `journeys.js` and `/v1/static/journeys.js` → `app-banners.js` and `/v1/static/app-banners.js`; columns and tables such as `clicks.journey_id` → `app_banner_id` and `journey_events` → `app_banner_events` (sweep every `journey` identifier in the schema); webhooks `journey.published|paused` → `app_banner.published|paused`; analytics `group_by=journey` → `app_banner`; metrics `journey_impressions|dismissals|ctr` → `app_banner_impressions|dismissals|ctr`; feature key `journeys` → `app_banners`; plan entitlements and plan comparison rows; the App banner **type** value `interstitial` → `full_screen` (only that enum: `clicks.served = interstitial` and other uses of the word stay).
- Tables renamed by migration; code modules renamed.
- **Kept as legacy names** (documented in `docs/DECISIONS.md` and the API reference): ID prefixes `jrn_` and `cg_site_`, and the `?jrn=` link parameter, so test links keep working.
- Sweep every spec-derived string (emails, onboarding checklist, AI guides, OpenAPI descriptions, error messages) and add a test that fails if "journey" appears in any customer-facing string, with no exceptions (change 09 S22 already replaced "End of journey" with "End goal").

### Part 5 — Single sign-on, branded sign-in and custom roles

#### B.9 Single sign-on (D10)
- **Eligibility:** feature key `sso` (Pro and Enterprise, and Growth with the `sso_addon`, B.10), like every other feature in the entitlements (change 10 G.2); `branded_sign_in` and `custom_roles` are feature keys too. Change 01's placeholder `flags.sso` is removed (nothing reads it). **And** at least one custom link domain verified by DNS with an active certificate. Errors: `403 plan_upgrade_required` (`param` = the feature key); `409 sign_in_domain_required` when the organisation has no verified link domain at all.
- **Email domains:** `organization_email_domains` (organization_id, domain, verified_at, method `dns_txt`). Always verified by a DNS TXT record on that exact domain (`clikgate-verify=<token>`); controlling `go.yourbrand.com` is not proof of `yourbrand.com`. An email domain can be verified by **one organisation only** (`409 email_domain_taken`, staff can resolve disputes with 🔐). Public mail domains (gmail.com, outlook.com, yahoo.com and the maintained list) are refused (`422 public_email_domain`). SSO members' emails must be on a verified email domain.
- **Connections:** `sso_connections` (id `sso_`, organization_id, protocol `oidc|saml`, display_name ("Continue with {Company}"), oidc_issuer, oidc_client_id, oidc_client_secret (encrypted, write-only), saml_idp_entity_id, saml_sso_url, saml_idp_certificate (public), status `draft|tested|active|disabled`, tested_at, created_by, timestamps). One active connection per organisation.
- **Paths:** the same paths on both hosts, `https://{sign_in_domain}/_cg/sso/…` and `https://app.clikgate.com/_cg/sso/…`: `start`, `callback` (OIDC), `saml/acs`, `metadata` (SP metadata). The `/_cg/` prefix is already reserved on link domains (change 09). **Both** callback/ACS addresses are registered with the company's provider at setup and both are tested (F.6), so sign-in keeps working at `app.clikgate.com` if the sign-in domain lapses. The SAML entity ID is fixed per connection (`https://app.clikgate.com/_cg/sso/saml/{connection_id}`) and never changes with the domain.
- **OIDC:** authorisation code with PKCE, `state` and `nonce`, `response_mode=query`; checks issuer, audience, expiry and signature. Identities are matched on **issuer + subject** (`iss` + `sub`; for Microsoft Entra ID the tenant and object IDs `tid` + `oid`), never on the email alone; the email must be on a verified email domain. **SAML:** SP-initiated only in this change (sign-in started from the provider's own app tile is refused with a helpful message); signed assertions required, audience, recipient and `InResponseTo` checked, replay protection by assertion ID, clock skew ≤ 3 minutes. Use a maintained library (record the choice).
- **Transaction state** (state, nonce, PKCE verifier, SAML request ID) is kept **on the server**, keyed by a random request ID that travels as `state` / `RelayState`; no cookie is needed to finish the provider's response (SAML responses arrive as a cross-site POST, which drops `SameSite=Lax` cookies). Records expire after 10 minutes and are single use.
- **Getting into the dashboard** (the dashboard stays at `app.clikgate.com`), bound to the browser that started:
  1. "Continue with {Company}" goes first to `https://app.clikgate.com/_cg/sso/begin?connection=…`, which sets a `__Host-cg_sso` cookie (random nonce; Secure, HttpOnly, SameSite=Lax, Path=/, 10 minutes) and redirects to the provider through the sign-in domain's `/_cg/sso/start` with the nonce's hash.
  2. After a valid response, the backend creates a **one-time sign-in code** (random, single use, 60 seconds) bound to the organisation, the user and that nonce hash, and redirects to `https://app.clikgate.com/sso/complete#code=…` (fragment, so it never reaches server logs or referrers).
  3. The complete page (`Referrer-Policy: no-referrer`) removes the code from the address with `history.replaceState` and exchanges it by **POST** with the cookie; the exchange is refused unless the cookie's nonce matches. A link with someone else's code therefore can't sign a victim into another account.
- **Sessions are per organisation:** tokens from an SSO exchange are limited to that organisation (and, for an agency organisation, its approved client workspaces). Switching to another organisation the user belongs to applies that organisation's own sign-in rules (its password and two-factor, or its own SSO); an SSO session never unlocks another organisation.
- **Joining** (organisation setting, owners only): `invite_only` (default; existing invitations, accepted by signing in with SSO) or `email_domain` (anyone on a verified email domain joins with a default role the owner picks; never Owner or Admin; default Viewer). Seat limits (`team_members`) apply; when full: "Ask your Clikgate owner for a seat", and owners get at most one email a day.
- **Users:** `users.password_hash` becomes nullable; `user_identities` (user_id, organization_id, sso_connection_id, issuer, subject, email, last_sign_in_at). A user can be SSO-only. **SSO-only members can't create a password themselves**: password reset and password sign-in are refused for them ("Your company signs you in. Use Continue with {Company}."); only an Owner's move-to-password (B.13) gives them one. So turning off someone's company account really cuts them off, even when "Everyone must use company login" is off.
- **Sessions:** SSO members' refresh tokens require a fresh SSO check every 12 hours, done as a **top-level redirect** (OIDC `prompt=none`, SAML `IsPassive`), never in a hidden frame; if the provider says the person must sign in again, the session ends. Access ends at the next check (the 12-hour check plus the remaining life of the current access token). Record the providers' behaviour in `docs/DECISIONS.md`. Owners can still remove a member at once (existing).
- **Second step:** SSO members don't get Clikgate's two-factor prompt (change 09 N.3); the company's provider handles it. Change 09's fresh code for sensitive actions becomes **re-confirm with the company login**: an SSO round trip with `max_age=0` (OIDC) or `ForceAuthn` (SAML), and the backend checks that `auth_time` / `AuthnInstant` is within the last 5 minutes.
- **Agencies:** agency staff are `agency_members` (change 03). An agency's SSO is set up on the agency's own organisation and applies to its agency members; client organisations' SSO rules never apply to agency members, who keep their agency access levels.
- **"Everyone must use company login"** (optional): password sign-in refused for members on verified email domains, **except Owners**.
- **Owner way in (D13):** at least one Owner must keep a normal Clikgate sign-in with two-factor. The last such Owner can't be removed, demoted or made SSO-only (`409 last_password_owner`).
- **Test before switching on:** `POST /v1/organization/sso/test` runs a full sign-in for the person testing; the connection can only become `active` after a passed test.
- **Audit and emails:** creating, changing, testing, enabling and disabling a connection, changing joining or the email domains are audit-logged and emailed to all Owners. Staff can disable a connection for abuse (🔐, reason).
- **API:** `GET/POST/PATCH /v1/organization/sso`, `POST …/sso/test`, `GET/POST/DELETE /v1/organization/email-domains`, `POST …/email-domains/{id}/verify`. Secrets are write-only and never returned or logged. Errors: `sign_in_domain_required`, `email_domain_not_verified`, `email_domain_taken`, `public_email_domain`, `sso_test_failed` (with the provider's safe error text), `sso_required`, `last_password_owner`.
- SCIM (automatic removal from the company's directory) is not built in this change.

#### B.10 Single sign-on add-on for Growth (D14)
Reuses change 10 Part 2 add-ons (definitions in plan versions, `subscription_add_ons`, entitlements = plan + add-ons, the manual buy flow, proration, invoices, renewals, and Upgrade opportunities, the extended Pro candidates list of D.11).
- **Definition:** key `sso_addon`, name "Single sign-on", adds feature key `sso` (B.9 only; the branded sign-in page and custom roles stay Pro and up), eligible plan `growth`, max quantity 1.
- **Seed prices** (staff can change, like other add-ons; same period discounts):

  | | Add-on | Growth + add-on | Pro |
  |---|---|---|---|
  | NGN monthly | 75,000 | 105,000 | 120,000 |
  | NGN 6 months | 405,000 | 567,000 | 648,000 |
  | NGN yearly | 750,000 | 1,050,000 | 1,200,000 |
  | USD monthly | 50 | 70 | 80 |
  | USD 6 months | 270 | 378 | 432 |
  | USD yearly | 500 | 700 | 800 |
- **Amended price rule** (change 10 G.1, enforced by the staff price editor): the change 10 rule (Growth + any two of Domains pack, Clicks pack and Fraud protection = 90–99% of Pro; all three > Pro) stays for those three. New: **Growth + Single sign-on = 80–95% of Pro**, and Growth + Single sign-on + any other add-on > Pro.
- **Pro first:** the "Request Pro instead" message (change 10 G.3) **always** shows for this add-on, whatever the total: "For ₦15,000 more a month, Pro includes single sign-on plus your own sign-in page, custom roles, unlimited team members and 10 custom domains." (amounts from the plans API).
- **Sales:** every Single sign-on request and every active Single sign-on add-on at renewal adds the organisation to **Billing → Upgrade opportunities**, tab Growth → Pro (change 10 G.5 as extended by D.11), with reason "Single sign-on add-on".
- Upgrading to Pro ends the add-on with the change 10 credit line. Removing it, or expiry, triggers B.13.

#### B.11 Branded sign-in page (D11)
- **Eligibility:** `branded_sign_in` (Pro and Enterprise), an **active** SSO connection, and a verified custom link domain with an active certificate. An agency's own organisation on Pro qualifies; its client workspaces are chosen after sign-in (change 03 agency membership).
- **Sign-in domain:** the Owner picks one of the organisation's verified link domains (`organizations.sign_in_domain_id`). No other domain or path can be used.
- **Page** at `https://{sign_in_domain}/login`: server-rendered, light, no third-party scripts. Organisation logo, display name, colours (contrast checked ≥ 4.5:1 for text and button), optional background image (≤ 1 MB, R2), the **"Continue with {Company}"** button (starts `/_cg/sso/start`), a small "Owner? Sign in with Clikgate" link to `app.clikgate.com/login`, and **"Powered by Clikgate"** at the bottom. No password box. No custom HTML, CSS or scripts.
- **"Powered by Clikgate" can't be removed or hidden** on this page: not by `flags.powered_by_removable` (change 09 P10), not by any setting or API field; a test renders the page for every plan and checks the line is present and visible.
- **Headers:** `Content-Security-Policy` with `frame-ancestors 'none'` and no inline scripts, `X-Frame-Options: DENY`, `Referrer-Policy: same-origin`, HSTS as the domain's existing setting.
- **Reserved slug:** `login` is added to the reserved words list (backend spec 10 slug rules); `422 reserved_link_name`. The `/_cg/` paths are already reserved.
- **App links:** `/login` is excluded from `apple-app-site-association` and `assetlinks.json` on every domain (like `/_t`, `/_f` and `/_cg` in change 09 N.1), so tapping it never opens the customer's app.
- **Edge Worker** (change 08): `/login` and `/_cg/sso/*` on any link domain are passed straight to the origin and never answered from the backup redirect copy; when the origin is unavailable the Worker returns a small "Sign-in is briefly unavailable. Please try again in a moment." page (no link redirect, no click queued).
- **Fallback:** if the sign-in domain is removed, stops pointing to Clikgate or loses its certificate (existing daily domain checks), `/login` there can't be served; members use `app.clikgate.com/login`, which offers "Continue with {Company}" after they type their work email (looked up by verified email domain, unique per B.9) and uses the `app.clikgate.com` callback registered at setup. Owners get an email and a dashboard alert (system alert type `sign_in_domain_unavailable`).
- **Audit and emails:** turning it on or off, branding changes and sign-in domain changes are audit-logged and emailed to all Owners. Staff can switch it off for abuse (🔐, reason).
- **API:** `GET/PUT /v1/organization/sign-in` (`enabled`, `sign_in_domain_id`, `display_name`, `logo`, `colours`, `background`). Errors: `sign_in_domain_not_verified` (the chosen domain isn't verified or has no active certificate), `sso_required`, `plan_upgrade_required`. Only Owners and Admins can remove or change a domain that is the sign-in domain.

#### B.12 Custom roles (D12)
- `roles` (id `rol_`, organization_id (null for the four standard roles), name, permissions text[], is_standard, created_by, timestamps); `memberships.role_id` replaces `memberships.role`, and `invitations.role_id` replaces `invitations.role` (migration maps the four standard roles; nothing is live).
- **Permissions:** one fixed list, `area:action`, with `view` and `manage` (manage includes view) for: `links_qr`, `campaigns`, `referrals_leaderboards`, `app_banners`, `goals_payments`, `reports`, `webhooks`, `apps_sdk_keys`, `domains`, `team` (view only for custom roles), plus `exports:run` as its own tick. The existing scopes (backend spec 4, change 01 and later) map onto this list in one table so API checks and dashboard checks use the same source; test that every endpoint maps to exactly one permission.
- **Never in a custom role** (`422 role_permission_not_allowed`): creating or revealing API keys and web keys, billing, security and SSO settings, branded sign-in and removing the sign-in domain, private mode off, deleting the organisation, managing members and roles. These stay with Owner and Admin. `apps_sdk_keys:manage` can create and view SDK keys (which ship inside apps) but never server API keys or web keys.
- The four standard roles can't be edited; the API returns them with their permissions as read-only examples. A custom role can be created by copying one.
- Members have exactly one role. Changing a role's permissions applies to everyone with it at once, needs the fresh security code (change 09) or SSO re-confirm, is audit-logged and emailed to Owners.
- `GET/POST/PATCH/DELETE /v1/organization/roles`; `DELETE` refused while members have the role (`409 role_in_use`). Plan: Pro and Enterprise (`plan_upgrade_required`). Custom roles don't need a verified domain.
- Agency access levels (change 03) keep mapping to standard roles.

#### B.13 Dropping below the plan (D13)
How it happens (change 01): the Owner downgrades, the Growth Single sign-on add-on is removed or expires, or the plan isn't renewed (period ends → 7 days' grace with everything working → expired → Free).
1. **Warn early:** renewal reminders (14, 7, 1 days) and the grace banner add "{N} staff sign in with your company login. They'll lose access if your plan ends." when the organisation has SSO-only members.
2. **Warn on downgrade:** the downgrade and add-on removal requests return `affected_members` (SSO-only members and custom-role members), shown before the Owner confirms.
3. **Pause, don't delete:** when SSO stops being available, SSO-only members become `paused` (new membership status, reason `sso_unavailable`; role and history kept; paused members don't count towards seats). `go.yourbrand.com/login` redirects to `app.clikgate.com/login` with "Your company's sign-in is paused. Ask your Clikgate account owner." SSO and branded sign-in settings are kept for 90 days (change 01 data rule); custom roles are kept, read-only, until an Owner deletes them. Paused members stay paused after 90 days until an Owner moves or removes them.
4. **Move people to normal sign-in:** the Owner chooses members to keep within the new plan's seat limit (Free 1, Starter 3, Growth 10) through the existing `POST /v1/billing/over-limit-selection`; `POST /v1/organization/members/{id}/move-to-password` emails each one a link (valid 7 days, single use) to set a Clikgate password and two-factor.
5. **Custom roles below Pro:** members with a custom role who can still sign in become Viewer until an Owner reassigns them.
6. **Upgrade within 90 days:** SSO comes back on, paused members are active again with their old roles (custom roles included), and branded sign-in returns if still eligible. If the plan's seats (`team_members`) can't hold everyone, the Owner chooses who returns first.
- `GET /v1/organization/members?status=paused`.

#### B.14 Tests
- **Clicked on / Shared as:** every evidence path and the order (paid ad click beats app browser beats referrer beats tag); `fbclid` without a paid signal is not `meta_ads`; Meta placement values `fb`, `ig`, `msg`, `an`; Instagram-tagged link opened in WhatsApp (counts Instagram, basis share_tag); WhatsApp ending opened inside Instagram (Instagram, shared as WhatsApp); data-file fixtures; backfill never invents values; edge and origin produce the same result for the same request.
- **Share endings:** every letter; mangled forms; unknown letters; `-q`, `-q12`, unknown `-q99`; referral code paths with endings; `/v1/sdk/resolve` stripping; `is_qr` set by `-q`; docs/OpenAPI test that the real letter set never appears; preview `+` after an ending; every domain type; reserved-rule refusals on create, rename, bulk, import; migration rename; staff page needs `share_endings.view` and has no write route.
- **Shared on:** chat and social preview agents create share events and never clicks; search crawlers never do; iMessage matched before Facebook and X; helper + preview counted once; web keys limited to their own links; dedupe; counts; estimate math on synthetic series; hidden below 20; never present in goals, attribution, referrals, leaderboards, challenges, ad sending, fraud or billing (schema and pipeline tests).
- **QR:** `-q` encoding; `?qr=1` still works; placement numbering never reused; limits per plan; archive; reports; ZIP job; designer rules (contrast, inverted, frame text contrast, cover > 20%, guide lines touched by a wide rectangle at Large, margin < 2, version 7+ logo unavailable); plain codes also scan-checked; server scan check pass/fail at three sizes; SVG sanitising (scripts, external refs, `foreignObject`); plan gates.
- **Referral map:** chains across programmes by user ID and by installation; private mode shows codes only; clusters above 10, paging by 8 ordered by chain sales; counts add up with opted-out and fraud-flagged people; sales from counted goal values with confirmed payment amounts; Growth gate; no public route.
- **App banners:** every renamed route, webhook and key; legacy `jrn_` and `?jrn=` still work; the "journey" string test.
- **SSO:** session limited to one organisation; code from another browser refused (nonce cookie); SAML POST works without cookies; both callback hosts; identity matched on issuer+subject (Entra `tid`+`oid`); SSO-only member can't reset a password; `auth_time` check on re-confirm; email domain unique and public domains refused; IdP-initiated SAML refused; OIDC (PKCE, state, nonce, wrong issuer/audience/expired) and SAML (unsigned, wrong audience, replay, skew) against mock providers; one-time code single use and 60-second expiry; domain and plan gates; joining modes and seat limit; 12-hour re-check; re-confirm for sensitive actions; "everyone must use company login" with the Owner exception; last password Owner protected; secrets never returned or logged (log scan).
- **Add-on:** entitlements, Pro-first message always, Pro candidate reason, price rule check, end on upgrade with credit, removal triggers B.13.
- **Branded sign-in:** eligibility; only the chosen verified domain; "Powered by Clikgate" present on every plan and with `powered_by_removable` true; headers; `login` slug reserved; edge Worker never serves backups for these paths; fallback alert.
- **Custom roles:** forbidden permissions refused; every endpoint mapped to one permission; role change applies to all members; delete refused in use; Pro gate.
- **Dropping below the plan:** warnings, `affected_members`, pausing, seats, move-to-password link single use, Viewer fallback, restore within 90 days.

#### B.15 Backend milestones
1. **C13-B1** B.1 click fields, evidence order, data files, analytics groupings and rollups, webhooks; edge Worker parity; backfill worker; tests; regenerate `openapi.json`.
2. **C13-B2** B.2 share endings: resolver, mangling, reserved rule and migration, staff permission and read-only page API; B.4 `share_urls` and share events; tests.
3. **C13-B3** B.3 share events, counts, estimate worker, never-used-for tests, nudge data (after the owner confirms the plans).
4. **C13-B4** B.5 QR `-q` encoding, placements, limits, reports, ZIP downloads; tests.
5. **C13-B5** B.6 QR styles, logo upload and sanitising, rendering, rules, server scan check, PDF; tests.
6. **C13-B6** B.7 referral graph worker, endpoints, search, CSV, private mode; tests.
7. **C13-B7** B.8 App banners rename and the string test; regenerate `openapi.json`.
8. **C13-B8** B.9 single sign-on (email domains, connections, OIDC and SAML, one-time code, joining, sessions, re-confirm, Owner protection, audit); tests.
9. **C13-B9** B.10 add-on, B.11 branded sign-in page (page, headers, edge Worker rule, fallback), B.12 custom roles; tests.
10. **C13-B10** B.13 dropping below the plan; full suite; regenerate `openapi.json`; update `docs/PROGRESS.md`.

---

## S. SDKs (`sdks/`)

### S.1 Share helpers (Engage)
- `Clikgate.share(link: String | ClikgateLink, message: String? = null)` on Android, iOS, Flutter and React Native opens the phone's share menu with the link.
  - **Android:** `Intent.createChooser` with `Intent.EXTRA_REPLACEMENT_EXTRAS`, giving each known package (WhatsApp, WhatsApp Business, Instagram, Facebook, Messenger, TikTok, X, LinkedIn, Telegram, Gmail and the main SMS apps; a maintained map with tests) its own `EXTRA_TEXT` with the right ending; other apps get the plain link. An `IntentSender` callback reads `EXTRA_CHOSEN_COMPONENT` to record the share event. `Clikgate.share(link, app = ShareApp.WHATSAPP)` shares straight to one app with a direct intent (declare the target packages in `<queries>` for Android 11+). Follow what the docs check shows and record it.
  - **iOS:** `UIActivityViewController` with an item provider that returns the URL per `activityType` (so the chosen app gets its ending where iOS asks the provider per activity); the completion handler records the share event.
  - Apps the phone doesn't report get the plain link.
- `ShareApp` enum on every platform. Referral links shared this way keep the referrer and carry the ending.
- Share events go to `POST /v1/share-events` with the SDK key; no personal data.

### S.2 Website share widget
- `cg.share.mount(element, {link, apps: [...]})` in the web script: buttons for WhatsApp, X, Facebook, Telegram, LinkedIn, Email and Copy link that open each app's share URL with the ending added; generic icons with names, no third-party logos. A "More" button uses the Web Share API with the plain link (the API can't report the chosen app).
- Docs, AI guides and snippets for S.1 and S.2; never mention the endings table, only "adds a short ending so Clikgate knows where you shared it".

Milestones: **C13-S1** S.1 on all four mobile SDKs with example apps; **C13-S2** S.2 and docs, AI guides, snippets.

---

## F. Dashboard

### F.1 Link and campaign pages: Share menu and "Where clicks came from" — follow the "Where Clicks Came From" mockup
- **Share** button on every link and campaign: a menu (closed by default) with **QR code** first (opens the QR placements section), then "Copy for WhatsApp / Instagram / Facebook / TikTok / X / LinkedIn / Telegram / SMS / Email" (copies `share_urls`), and "Copy plain link". Toast: "Copied. Clicks from this copy are tagged WhatsApp."
- **Link create:** optional "Made for" picker (`made_for`) with the hint "Making a link for WhatsApp? Choose WhatsApp so its clicks are tagged WhatsApp."
- **Basic split** (every plan): clicks by app with a "how we know" label (Ad click · App's browser · Referring site · Link tag · Unknown), plus "Shared on" counts. On **Starter** the basic split also shows the estimate line (below) under the table; the full panel stays Growth and up.
- **Full panel** (Growth and up; others see the basic split and an upgrade note):
  - **Certainty bar:** Confirmed (solid), Tagged (lighter tint), Estimated (striped, a range with confidence), Unknown (grey), with labels and a legend.
  - **By app** table: per app confirmed, tagged, estimated (range), share counts, goals and revenue (confirmed + tagged only).
  - **How the link travelled:** a Clicked on × Shared as table.
  - **Shared on:** share counts per app with sparklines, and the note "Some phones turn previews off, so these are a minimum."
  - **Estimate** (Starter and up) shown only in its own labelled area: "Unknown clicks: 120 · likely from WhatsApp shares: about 70 (estimate, medium confidence)".
  - **Nudges:** Unknown above 30%: "38% of clicks have no clue. Share with the Share button to know more." WhatsApp suggestion (B.3 trigger): "Many of this link's unknown clicks look like WhatsApp shares. Share it with the Share button, or make a WhatsApp link, to know for sure" (one click creates a copy with Made for WhatsApp).
- Reports and exports everywhere gain Clicked on, Shared as and QR placement as group-by and filter options; estimate columns say "estimate".
- Never colour alone; reduced motion respected; "Example data" only in previews.

### F.2 QR placements — follow the mockup's QR placements table
- On the link page: placements table (placement, ending, scans, goals, goal rate, cost per goal, first and last scan, sparkline), "QR code, no placement" row, archived filter.
- **New placement** form: name (required), location, dates put up and taken down, spend, notes; shows the new ending (`-q4`) before saving; at the limit, the upgrade note.
- Per-placement download (opens the designer) and **Download all** (ZIP, progress and email when ready).

### F.3 QR designer — follow the "QR Designer" mockup
- Live preview; placement picker; logo (none / upload) with Small, Medium, Large; **shape** Square, Rectangle, Circle with **corner radius** (disabled for Circle) and **space around logo**; **margin** Standard 4 / Medium 3 / Tight 2 with the hint; colours with presets; frame "Scan me" with editable text; "Print the placement name under the code".
- **Scan check panel** fed by the server check: three results (full size, small print, far away/blurred), what it reads as, code size, repair level, logo cover %, margin and contrast; on failure the reason and the one-click fix button. Downloads (PNG, SVG, PDF) disabled until it passes.
- "Save as the organisation's QR style" (Growth and up). Plan locks shown with the plan chip.

### F.4 Referral map — follow the "Referral Map" mockup
- Referrals › **Referral map** (Growth and up). Canvas: drag to pan, wheel and pinch zoom, − / + / Fit, minimap, dotted background.
- **Group by Campaign** (frames per campaign, programme, leaderboard or challenge, each showing its top 10 with "Show 8 more"; frames draggable by their title; connectors coloured by the campaign that brought the referee) and **Group by Referral chain** (tree, fold and unfold).
- Cards: name as displayed (masked by default; codes only in private mode), joined via, brought directly, whole chain, qualified/pending, rank badge from the chosen board, **sales from everyone they brought in**. Clusters for more than 10 ("24 via Summer sale · 20 qualified · ₦X sales"), opening 8 at a time; "Show 8 more" and "Fold this group".
- Below 50% zoom cards show names only. Selecting a person highlights their path and chain and opens the side panel (path, direct vs chain, sales direct vs whole chain, chain by campaign, ranks, **Biggest branches**). Toolbar: campaign chips, "Ranks from", Find (jumps to the right cluster and page), Download chain CSV.
- Light and dark themes; keyboard: arrow keys pan, `+`/`-` zoom, `F` fit, Tab moves through cards; reduced motion stops flowing connectors. No share button.

### F.5 App banners
- Menu, pages, forms, empty states, onboarding checklist and plan comparison say **App banners**, with the explainer line; types Banner, Full-screen prompt, Floating button. Routes `/app-banners` (old `/journeys` routes removed).

### F.6 Settings → Security: single sign-on and branded sign-in
- **Single sign-on:** steps with progress: (1) verify an email domain (DNS TXT, or "matches your link domain"), (2) choose Google Workspace, Microsoft Entra ID, Okta or "Other (OpenID Connect / SAML)", (3) copy the values shown: **both** callback addresses (`https://{sign_in_domain}/_cg/sso/callback` and `https://app.clikgate.com/_cg/sso/callback`), both SAML ACS addresses, the entity ID and the metadata URL, with copy buttons and a short guide per provider, (4) paste the provider's values, (5) **Test sign-in** on both addresses (both must pass), (6) turn on.
- Without a verified link domain: "Add and verify your own domain first" with a link to Domains. Growth without the add-on: the add-on card (F.8).
- Joining: Invite only / Anyone from @{domain} with default role. "Everyone must use company login" toggle with the Owner exception explained.
- **Why turn it on** (shown on the screen): "Staff access follows your company email. When you disable someone's work account, they lose access to Clikgate too, without anyone remembering to remove them here." Small print: "Access ends at the next check, unless you remove them here."
- **Branded sign-in page** (Pro and up): pick the sign-in domain, logo, colours, background, display name; live preview with "Powered by Clikgate" shown and not editable; turn on; the page address with a copy button.
- Every change asks for the fresh security code (or SSO re-confirm) and shows "All owners are emailed about this change."

### F.7 Team and custom roles
- Team page: role column, status (Active, Invited, Paused), sign-in method (Company login / Clikgate password), filter by role and status, **Move to Clikgate sign-in** for paused members.
- **Roles** tab (Pro and up): the four standard roles as read-only cards; **New role** (name, copy from, a permission grid by area with View / Manage and an Exports tick; locked rows for the never-allowed powers with "Only Owners and Admins can do this"); members count per role; delete disabled while in use.
- Downgrade and add-on removal confirmations list affected members (B.13) before confirming.

### F.8 Plan & usage → Add-ons: Single sign-on
- A fourth card on the Growth Add-ons tab (change 10): "Single sign-on: staff sign in with your company's Google, Microsoft or Okta login." Price per period, status, Add / Remove at renewal. Opening **Add** always shows the Pro comparison first, with **Request Pro instead** as the main button and "Add single sign-on only" as the secondary.

### F.9 Staff console
- **Share endings** page (read-only, `share_endings.view` only).
- Organisation page: SSO status, sign-in domain, branded page on/off, custom roles count; **Disable** SSO or branded sign-in for abuse (🔐, reason).
- Upgrade opportunities (Growth → Pro tab) shows the "Single sign-on add-on" reason (change 10 G.5 and D.11); add-on definitions in the plan-version editor with the amended price rule check (B.10).

Milestones:
1. **C13-F1** F.1 Share menu, basic split, full panel, report and export options.
2. **C13-F2** F.2 QR placements.
3. **C13-F3** F.3 QR designer.
4. **C13-F4** F.4 Referral map.
5. **C13-F5** F.5 App banners rename.
6. **C13-F6** F.6 single sign-on and branded sign-in settings, the `/sso/complete` route and the sign-in page fallback flow at `app.clikgate.com/login` ("Continue with {Company}" after typing a work email).
7. **C13-F7** F.7 team, roles, paused members and downgrade warnings; F.8 the add-on card.
8. **C13-F8** F.9 staff console; Playwright suite for every part; update `docs/PROGRESS.md`.

---

## W. Website (`clikgate-website`)

### W.1 The `/short-links` page: QR codes (D16)
The page from change 09 (D10) **keeps its current look, order and components**; this adds to it. Build with the existing brand tokens and real dashboard components as mockups. Inspired by how leading QR pages cover use cases and features, but **Clikgate's own wording, pictures and layout: never copy another site's text, images or layout details.** Illustrations follow change 12 D10 (global, objects and abstract scenes, diverse people, no regional settings, flags or landmarks, no third-party logos). "Example data" on every mock with numbers.
1. **Hero subhead and meta description** add QR codes ("Short links and QR codes that show you every click and scan"); the meta title stays.
2. **Try-it box, QR code tab:** after pasting a URL, a small designer preview: colours, **"Add your logo"** (upload, drawn in the browser only, never uploaded or stored; a note says so), logo shape Square / Rectangle / Circle, and the "Scan me" frame. Logo and frame show a **"Starter and up"** chip; colours are free. Nothing can be downloaded without an account: "Create it free" carries only the URL to sign-up (the logo is not carried; after sign-up the QR designer opens on the new link). The preview runs the same in-browser scan check as the mockup and shows "Scans" or the reason it doesn't.
3. **QR codes showcase block** (existing) is rewritten: "Your logo in the middle, and it still scans": logo with Square, Rectangle or Circle and rounded corners, brand colours, a "Scan me" frame, tighter margins, PNG, SVG and print-ready PDF; **every code is test-scanned before download**; change where it goes after printing; scans counted. Mock: the QR designer.
4. **New section "QR codes for every surface"**, a grid of use-case tiles (icon, name, one-line outcome, the Clikgate feature that makes it work), with a few tiles opening a short example:
   - **Product packaging and labels:** "Reorder, register a warranty or see how to use it" · open in app, change destination later.
   - **Posters and billboards:** "See which poster sells" · QR placements, cost per order.
   - **Flyers and direct mail:** "Compare batches and areas" · a placement per batch.
   - **Shop windows, counters and tills:** "Turn walk-past into follow" · WhatsApp chat links, open in app.
   - **Restaurant tables and menus:** "Menus, orders and reviews from the table" · a placement per table or branch.
   - **Events, tickets and badges:** "Check-in, schedules and sponsor offers" · goals for sign-ups and sales.
   - **Business cards and email signatures:** "Your contact page, always up to date" · change destination later.
   - **Delivery bags, receipts and invoices:** "Bring buyers back for the next order" · open in app, goals.
   - **TV, video and screens:** "From the screen to the app in one scan" · deep links, a placement per channel or slot.
   - **Vehicles and shopfronts:** "Every van and branch, measured" · a placement per vehicle or branch.
   - **Agents and field sales:** "Credit every sign-up to the right agent" · a code or placement per agent, leaderboards.
5. **New section "One link, a code for every place"** (QR placements): name each place it's printed and compare scans, orders and cost per order on the same link; mock: the placements table. Placement allowances per plan from the plans API.
6. **New section "QR codes that open your app"**: a scan opens the right screen in the app when it's installed, or the store and then the same screen after install (deferred deep links); popular apps open in their own app (change 07). No SDK needed for open in app; deep links into the business's own app need the app set up.
7. **New section "Many codes at once"**: bulk placements and a ZIP of every code with an index, the API for creating codes and placements, and UTM and attribution details carried into the business's analytics. Link to the API docs.
8. **New section "Built to scan"**: plain advice without guarantees: dark squares on a light background, keep the margin, don't stretch it, size it for the distance (a rule of thumb shown as guidance: about 1 cm of code for every 10 cm of scanning distance, and at least about 2 cm wide), test before printing (Clikgate does this for you). Never "guaranteed to scan" or "works on every phone".
9. **FAQ** gains QR questions: Do QR codes expire? (No, not while the link is active.) Can I put my logo in it? (Yes, from Starter.) Will a logo stop it scanning? (Clikgate checks every code before you download it and won't let you download one that fails.) Can I change where it goes after printing? (Yes, unless the link is locked.) How do I know which poster works? (QR placements.) Do people need a special app? (No, a phone camera is enough on most phones.) How small can I print it? (The sizing guidance above.)
10. **Structured data:** FAQ schema for the FAQ; the page stays within the existing Lighthouse and accessibility budgets; mobile first.

- **Attribution page and docs:** "Where your clicks came from": the D15 promise; Confirmed / Tagged / Estimated / Unknown explained; why WhatsApp, SMS and email need the Share button; "the Share button adds a short ending so Clikgate knows where you shared it" (**never publish the endings table**); the estimate is labelled an estimate and never used for goals, rewards or billing.
- **QR page and docs:** QR placements (one link, a code per poster or flyer, scans and orders per placement); the designer with logo and shapes, and the scan check ("every code is test-scanned before you can download it", true because B.6 checks every code). No "guaranteed to scan".
- **Referral map** on the referrals product page: illustration in the change 12 D10 global style (abstract cards and connectors, example data); wording "see who brought whom"; never "levels" or "earn from your friends' friends".
- **App banners:** rename every page, menu item, docs page and URL (`/docs/app-banners`, with redirects from the old docs URLs since the site may already be indexed in staging).
- **Security / Enterprise:** "Single sign-on with Google, Microsoft or Okta" and "Your own sign-in page on your own domain" listed for **Pro and Enterprise**; the staff-access benefit line (F.6) with its honest limit ("at the next check"). Never "white-label".
- **Pricing:** comparison rows for the plans table in A (estimate, full panel, QR placements, QR designer, referral map, single sign-on, branded sign-in, custom roles); the "Add-ons for Growth" section gains **Single sign-on** with its price from the plans API and the line "Pro includes single sign-on plus your own sign-in page and custom roles."
- Docs for SSO setup per provider (with the `/_cg/sso/…` values), custom roles and what happens on downgrade.
- `llms.txt`: the new and renamed pages.

Milestones:
1. **C13-W1** W.1 `/short-links` QR sections and try-it designer; attribution, QR and referral map pages and docs; App banners rename and redirects.
2. **C13-W2** Security and pricing updates, SSO and roles docs, `llms.txt`; Lighthouse and accessibility checks; update `docs/PROGRESS.md`.

---

## Definition of done
- Every click has Clicked on, its basis and Shared as; confirmed evidence beats the tag; reports, exports, webhooks and the API show them.
- Share endings resolve on every domain, are reserved, and appear nowhere on the website or docs; staff can only view them.
- Preview fetches create share counts, never clicks; the estimate is labelled and used for nothing else.
- QR codes use `-q`; placements have their own endings, limits and reports; `?qr=1` still works.
- The QR designer refuses unreadable designs and every customised download passed the server scan check.
- The referral map works on Growth and up with clusters, paging and chain sales, and never shows names in private mode.
- "Journeys" is gone from every customer-facing string; `jrn_` and `?jrn=` still work.
- Single sign-on works with Google Workspace, Microsoft Entra ID and Okta (OIDC) and a SAML provider; the branded page lives only on a verified link domain, has no password box and always shows "Powered by Clikgate"; custom roles can't hold the forbidden powers; dropping below the plan pauses, never deletes, and at least one Owner can always sign in.
- The Single sign-on add-on is sold on Growth with Pro offered first, and its requests reach Upgrade opportunities.
- `/short-links` shows logo customisation in the try-it box and the QR sections in W.1, with no copied wording and no scan guarantees.

## Before building: things only the owner can provide
- Share the three mockups (Where clicks came from, QR Designer, Referral Map) with the builder.
- Approval of the `/short-links` QR wording and the use-case illustrations (W.1), drawn by a designer or the builder's set in the change 12 D10 style.
- Confirm the provisional plans: the share estimate from Starter, the full "Where clicks came from" panel from Growth, and that custom roles don't need a verified domain.
- One Android phone and one iPhone (the same phones used for the change 07 device checks) for the launch check: paste tagged links into WhatsApp (chat, group, status), iMessage, Telegram, Instagram bio and messages, X, Gmail and SMS, and confirm the ending survives; added to the change 07 device checks and re-run after major app updates.
- Test accounts for single sign-on: a Google Workspace domain, a Microsoft Entra ID test tenant and an Okta developer account (and one SAML provider, e.g. Okta's SAML app).
- A real custom link domain on the test organisation for the branded sign-in page.
- Approval of the D15 promise wording and the SSO benefit line.
