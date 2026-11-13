# Privacy: what the Clikgate SDKs collect and why

This page is for app owners preparing App Store privacy labels, Google Play's Data safety
form, and their own privacy policy. It describes the SDKs and the Clikgate backend as built
(SDK 1.x, API contract v1 with the v3 and change 03 additions; SDK 1.2.0). App Store and Play review decisions are the app owner's
responsibility.

## Summary

- Clikgate measures which links and campaigns lead to installs and goals, opens the
  right screen after install (deferred deep linking), tracks referrals for the app's own
  referral program, and detects uninstalls.
- The SDKs never request ATT, notification or location permission, never read the IDFA or
  GAID by default, and never show notifications.
- Raw IP addresses are never stored. Push tokens, push credentials and identity secrets are
  encrypted at rest and never returned by any API.
- Data isn't shared with or sold to anyone. Each app owner (organisation) only sees its own data.
- A user can opt out in the app (`setTrackingEnabled(false)`), and the app owner can erase or
  export one user's data (`POST /v1/privacy/requests`).

## Data collected

| Data | When | Purpose | Notes |
|---|---|---|---|
| Installation ID (random UUID) | first launch | app functionality, analytics | Created by the SDK, not derived from the device. iOS also keeps it in the Keychain (not synced) to recognise reinstalls |
| App version, SDK version, OS version | install, opens | analytics, compatibility | |
| Device model (e.g. `iPhone15,2`) | install | analytics | Not collected in `restricted_mode` |
| Locale, time zone | install | analytics; probabilistic matching only if enabled | |
| Screen size and scale | install (Android only) | probabilistic matching only | **Android:** sent only when probabilistic matching is enabled for the app **and** attribution consent allows it (1.2.0). **iOS:** never sent from 1.2.0 |
| Country | install | analytics | From the request IP at the edge (`CF-IPCountry`) or a GeoIP lookup; the IP itself isn't kept |
| IP address | every request | rate limiting, fraud checks, probabilistic matching | Stored only as an HMAC with a salt that rotates daily. For probabilistic matching, a separately salted HMAC lives in Redis for at most the matching window (max 24 h) |
| Google Play Install Referrer | first launch (Android) | deterministic install attribution | The referrer string Play provides |
| Installer package | first launch (Android) | attribution, fraud checks | e.g. `com.android.vending` |
| Pasteboard contents | first launch only (iOS), only if the app opts in (1.2.0: `pasteboardMode` defaults to `off`) and the app's Clikgate setting enables it | deferred deep linking | Only a `cgdl_` token Clikgate's own landing page copied after the user tapped "Open in app" is sent; nothing else from the pasteboard leaves the device. Never read again after first launch. iOS 16+ shows the system "Allow Paste" prompt |
| Paste step outcome (`pasteboard_outcome`) | first install only (iOS), only when the paste flow above runs | measuring the app's iPhone match rate | Not personal data: one of `token_found`, `no_link`, `no_token`, `denied`, `paste_control`, describing the paste step, never the pasteboard contents. Not sent when the user opted out or denied consent. No privacy-manifest change |
| Launch URLs | when a link opens the app | deep linking, re-engagement | Only URLs on the app's Clikgate link domains or with a Clikgate click id |
| Handled deep link path (`deeplink_handled`) | when a Clikgate deep link is handed to the app, only with a test SDK key or while the dashboard's debug view is open for the app | checking the integration ("See it live", debug view) | Path only: the query and fragment are removed and every segment that looks like an ID, email address or phone number is replaced with `:id` on the device. Never sent in normal live use, never a goal, never counted |
| Customer user ID | when the app calls `identifyUser()` | referrals, linking goals to the app's own user | The app's own identifier; optionally verified with an HMAC identity token from the app's backend. Never sent in the organisation's private mode (SDK 1.3.0) |
| Goal events (key, value, currency, reference, `is_first`, click id) | when the app calls `goal()` (SDK 1.3.0; the only method for what happens in the app since Change 22) | goal measurement, conversions, value-based bidding, referral qualification. Names not yet ticked as goals in the dashboard are stored for 30 days only, not counted and not sent to ad networks | The business's own reference (or an SDK-generated UUID), never customer data; the value is a decimal amount. Allowed in private mode, where Clikgate stores the reference only as a keyed hash |
| Push token (APNs / FCM) | when the app provides it | uninstall detection | Encrypted at rest; only used to send silent check pushes (below) |
| Attestation results (App Attest / Play Integrity) | install, every 7 days, only if enabled | fraud prevention | The server keeps the attested public key and a valid/invalid verdict |
| Apple Ads (AdServices) attribution token | with the first install request (iOS 14.3+), only if Apple Ads is on in the dashboard and attribution consent allows it | Apple Ads attribution | Requested when the install is sent (after consent when consent is required), renewed after 24 hours, kept in memory only and never stored on the device. Resolved with Apple's AdServices API |
| Emulator / Simulator heuristic | install | fraud prevention | A boolean (`is_emulator`) |
| Root heuristic (Android) | install | fraud prevention | A boolean (`is_rooted`), SDK 1.1.0+. Computed on the device from build tags, a few `su` file paths and, below Android 11, whether a known root-manager app is installed. Only the boolean leaves the device; the list of installed apps is never read or sent. A hint for fraud scoring, not proof. **iOS:** the jailbreak heuristic (file-path probes and a test write outside the sandbox) was removed in 1.2.0 |
| Consent choices | whenever the app calls `setConsent` / `setConsentRegion` | legal compliance (consent records) | The four purposes, the region hint and the time; sent with every request and logged by Clikgate (`consent_records`, 3 years) |
| Google click ids (`gclid`, `gbraid`, `wbraid`) | when a Clikgate link carrying one opens the app; Android install referrer | Google Ads conversion measurement | Only these three query parameters are read |
| LinkedIn, Snap and X click ids (`li_fat_id`, `ScCid`, `twclid`) | inside the Clikgate link that opens the app (launch URL) or the Android install referrer, when the app passes ad click ids | LinkedIn, Snap and X conversion measurement | Not parsed or stored by the SDK: they are part of the URL / referrer already listed above |
| Firebase app instance id | install / opens, only if the app enabled Firebase forwarding and analytics consent allows it | sending Clikgate attribution to the app owner's own GA4 | Read from the app's own Firebase Analytics |
| Apple DeviceCheck token, IDFV (iOS) | install, re-attestation, only with identity checks / App Attest enabled and identity-check consent; IDFV also on the install when Apple Ads is on (same consent) | fraud prevention (identity checks); IDFV also links an Apple Ads redownload to the earlier install | The DeviceCheck token is ephemeral; Clikgate's server asks Apple for the app's two per-device bits. IDFV is Apple's per-vendor id. No hardware or OS fingerprint signals |
| Google on-device measurement info (iOS) | first install, only if the app links Google's on-device conversion SDK and calls `enableGoogleOnDeviceMeasurement()`, not when `ad_user_data` is denied | Google Ads measurement | An opaque aggregate string from Google's SDK, stored encrypted for 30 days; Clikgate never sends raw email or phone |

Not collected: names, email addresses, phone numbers, contacts, precise or coarse location from
device APIs, IDFA / GAID (off by default; even if enabled they aren't used for matching in this
version), canvas/WebGL/audio/font fingerprints, browsing history.

## Uninstall tracking

When the app owner enables it and uploads APNs / FCM credentials, Clikgate sends **silent**
pushes (`content-available` / FCM data messages with `"cg": "uc"`) on a schedule: one after
24 hours, then daily for 30 days, then weekly until day 180, then never. The push provider's
answer (e.g. APNs `410 Unregistered`, FCM `UNREGISTERED`) shows whether the app is still
installed. Users never see these pushes; the SDK recognises and drops them. Detection isn't
real time (iOS can take days), only works for installs that registered a push token, and opted-out
installs are never checked.

## Consent (SDK 1.2.0)

Apps call `setConsent` with four purposes (`analytics`, `attribution`, `ad_user_data`,
`ad_personalization`; each granted, denied or unknown) and optionally `setConsentRegion`. Where the
organisation's consent mode requires consent (EEA, UK and Switzerland by default), the SDK sends
nothing identifying while `attribution` is unknown: events stay on the device (at most 7 days or 1,000
events) and are sent on grant or deleted on deny. With `attribution` denied, at most one anonymous,
identifier-free install count is sent (if the organisation enabled it). Firebase forwarding needs
`analytics`; identity checks need `analytics` unless the organisation's stated legal basis is fraud
prevention. Details: `shared/SDK_BEHAVIOUR.md` "Change 03".

## Probabilistic matching (off by default; never on iOS)

From change 03 Clikgate never runs probabilistic matching for iOS installs, and the iOS SDK 1.2.0 no
longer collects any signal used only for it (screen size) or any device-configuration probe (jailbreak
checks). iOS attribution is deterministic only: link click ids, Apple Search Ads, SKAdNetwork /
AdAttributionKit, the opt-in clipboard token and the app's own user identity (no IDFA). On Android it additionally needs attribution consent and a window of at most
24 hours; the rest of this section describes it.

Apple prohibits deriving data from a device to uniquely identify it ("fingerprinting"),
regardless of ATT consent. Whether short-lived, first-party matching used only to route a user to
the content they just tapped is acceptable is not clearly settled by Apple. So:

- It is off by default. Only an organisation **owner** can turn it on, signed in to the dashboard,
  with an explicit acknowledgement of this policy (recorded with the user and time in the audit
  log). Clikgate can switch it off for the whole platform (`SDK_PROBABILISTIC_ENABLED`).
- It only matches clicks on links of the **same organisation** as the app, within a window of 60
  minutes by default (24 hours at most).
- The landing page sends only coarse values: screen size and pixel ratio, time zone, languages, OS
  version. These are kept only in Redis for the window, keyed by an HMAC of the IP; nothing is
  written to the database and no persistent device identifier is created.
- A match needs a confidence of at least 0.9 by default, a clear margin over any other candidate,
  and fewer than five recent clicks from the same IP. Matches are labelled
  `match_type = "probabilistic"` with a confidence score.
- Referrals never qualify on a probabilistic match unless the referral program explicitly allows it.
- `restricted_mode` (for kids' or regulated apps) disables it, along with advertising IDs and device
  model collection.

## Opt-out, erasure and export

- `setTrackingEnabled(false)` in the app: the SDK clears its event queue, tells Clikgate, and
  stops sending anything. Clikgate erases the device fields (OS, model, locale, time zone, IP hash,
  installer, referrer, customer user ID, push token) and stops all processing for that
  installation, including uninstall checks. If the user opts out before the first launch, the SDK
  sends one install marked as not consenting and nothing else.
- `POST /v1/privacy/requests` (app owner, `apps:manage` scope), for an installation ID or a customer
  user ID:
  - `export` produces a JSON file with the installs, goal events and referrals concerned.
  - `erasure` deletes goal events, opens and uninstall checks, strips the install of every device
    field and identifier (the anonymous row stays so aggregate counts don't change), removes the
    user from referrals they were referred in, and anonymises them as a referrer (the referral
    history of the people they invited stays, without their identity).
  - The request log keeps only a hash of the subject once done.

## Retention

| Data | Kept for |
|---|---|
| Installs | until inactive for 25 months |
| Goal events | 25 months (names not ticked as goals: 30 days) |
| App opens | 13 months |
| Uninstall checks | 6 months |
| Probabilistic signals, pasteboard tokens | the matching window / install lookback (Redis only) |
| Attestation challenges | 5 minutes (Redis only) |

## Optional features (spec v3)

Each of these is an organisation feature switch (`/v1/organization/features`). A feature that is
off collects nothing, sends no webhooks and makes the SDK calls no-ops; switching it off with
`data_action: "purge"` deletes its data after a 7-day grace period (cancellable), or at once with
`purge_now` (owner only).

| Feature | Default | What is stored | What is never stored |
|---|---|---|---|
| Identity checks (duplicate accounts) | **off** | Per signal: type (e.g. `bvn`, `phone`), Clikgate's HMAC of the hash the customer sent, verified flag, first/last seen; duplicate matches between two subjects | The identity value itself or the customer's hash of it (it is re-hashed with a per-organisation server key on arrival). Never shown in APIs or webhooks |
| WhatsApp chat attribution | off | Per chat: an HMAC of the sender's WhatsApp ID, the 6-character ref, the click/link it came from, first and last message time | Message text, raw phone numbers. Inbound payloads are reduced in memory before anything is queued |
| Offline and USSD codes | on | Per redemption: code, channel, agent ID, location fields the customer sends, time, and the subject (installation / customer user ID, or a phone hash stored as Clikgate's HMAC) | Raw phone numbers |
| Leaderboards | on | Ranks and scores derived from referrals; per-referrer opt-out | Customer user IDs and referee data on SDK endpoints and the hosted page (display names are masked per board setting) |

Matching (identity, WhatsApp contacts) only ever happens inside one organisation; there is no
cross-customer matching. Identity checks are for fraud prevention only, and the customer remains
responsible for a lawful basis (e.g. Nigeria's NDPA) for the values it hashes and sends.

**Users can opt out of leaderboards** (`leaderboards.setOptOut(true)` in the SDK): they disappear
from SDK endpoints and the hosted page; the app owner still sees them, flagged, in the API.

### Erasure and export (additions)

- An `installation` or `customer_user` request also exports (types and dates only) and erases
  identity signals and matches, and offline touches of that subject.
- `subject_type: "whatsapp_contact"` with an E.164 number or the contact hash from the
  `whatsapp.conversation_attributed` webhook exports and erases that contact's WhatsApp
  conversations. A number is hashed when the request is made and is never stored, not even in the
  pending request. Sales credited to an erased chat keep their click and link.
- Offline touches whose subject is a phone hash can't be found from a raw number (the hash uses the
  customer's own pepper); erase them through the identity signal subject, or purge the feature.

### Retention (additions)

| Data | Kept for |
|---|---|
| Identity signals | while the subject is active; deleted 30 days after the subject's erasure; or `retention_days` from the feature config |
| WhatsApp refs | until expiry (`ref_ttl_days`, default 30) |
| WhatsApp conversations, offline touches | until erasure or a feature purge |
| Leaderboard snapshots | final snapshots are kept (they hold display names, never user IDs) until a feature purge |

## Platform declarations

- **iOS**: the SDK ships a `PrivacyInfo.xcprivacy` declaring the collected data types (app
  functionality and analytics, not tracking) and its required-reason API usage. See
  [ios.md](ios.md). Clikgate doesn't track users across apps or websites owned by other companies,
  so the SDK alone doesn't require ATT; if your app enables advertising-ID collection, you need ATT.
- **Android**: for Play's Data safety form, declare: device or other IDs (installation ID; app
  functionality, analytics), app activity (goals you send; analytics), and, if you enable
  uninstall tracking, the push token. Data is encrypted in transit; users can request deletion
  (via your app's process, which calls the privacy API).
