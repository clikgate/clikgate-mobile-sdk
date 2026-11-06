# Clikgate Android SDK — integration guide

`com.clikgate:clikgate-android` (the **core SDK**) adds deep links (direct and deferred), install
attribution, in-app events, identify, referee-side referral calls (apply a code, "who referred
me") and uninstall tracking to an Android app. minSdk 21, Kotlin and Java, no Firebase dependency.

The core SDK only does what must happen on the device. Referral links and stats, leaderboards,
promo codes and share helpers are **not** in it:

- **Recommended:** your backend calls the Clikgate control-plane API (referrers, referral stats,
  leaderboards, identity signals, server events) and your app renders its own screens.
- **Apps without a backend:** add the optional Engage add-on `com.clikgate:clikgate-engage`
  (section 6d). See [engage.md](engage.md) for when to use which.

## 1. Install

```kotlin
// app/build.gradle.kts
dependencies {
    implementation("com.clikgate:clikgate-android:1.5.1")
    // Optional Engage add-on (apps without a backend; pulls in clikgate-android):
    // implementation("com.clikgate:clikgate-engage:1.5.1")
    // Optional, only if you enable Play Integrity attestation:
    // implementation("com.google.android.play:integrity:1.6.0")
}
```

The AAR ships its consumer R8 rules; nothing to add to your ProGuard files.

## 2. Configure in `Application.onCreate`

```kotlin
class MyApp : Application() {
    override fun onCreate() {
        super.onCreate()
        Clikgate.configure(
            this,
            sdkKey = "cg_sdk_...",
            options = ClikgateOptions(
                linkDomains = listOf("inv.myapp.com"),   // every Clikgate link domain of your group
                logLevel = LogLevel.WARN,
                environment = Environment.PRODUCTION,
                attestation = Attestation.OFF,            // or PLAY_INTEGRITY_IF_AVAILABLE
                // apiBaseUrl = "http://10.0.2.2:8000",   // local backend from the emulator
                // deferredDeepLinkTimeoutMs = 5_000,
            ),
        )
        Clikgate.onDeepLink { link -> /* route, see §4 */ }
    }
}
```

`configure` returns immediately; work happens on a background thread. All methods are
thread-safe; callbacks run on the main thread. Calls made before `configure` (e.g.
`setTrackingEnabled(false)` from a consent screen) are queued and applied first.

Java:

```java
Clikgate.configure(this, "cg_sdk_...", new ClikgateOptions(Arrays.asList("inv.myapp.com")));
Clikgate.onDeepLink(link -> router.open(link.getPath(), link.getData()));
```

## 3. App Links and custom scheme

Add intent filters to the activity that should receive links, and forward intents:

```xml
<activity android:name=".MainActivity" android:exported="true" android:launchMode="singleTask">
    <intent-filter android:autoVerify="true">
        <action android:name="android.intent.action.VIEW" />
        <category android:name="android.intent.category.DEFAULT" />
        <category android:name="android.intent.category.BROWSABLE" />
        <data android:scheme="https" />
        <data android:host="inv.myapp.com" />
    </intent-filter>
    <!-- optional custom scheme; Clikgate links on it carry cg_click_id -->
    <intent-filter>
        <action android:name="android.intent.action.VIEW" />
        <category android:name="android.intent.category.DEFAULT" />
        <category android:name="android.intent.category.BROWSABLE" />
        <data android:scheme="myapp" />
    </intent-filter>
</activity>
```

```kotlin
override fun onCreate(savedInstanceState: Bundle?) {
    super.onCreate(savedInstanceState)
    Clikgate.handleIntent(this, intent)          // cold start
}

override fun onNewIntent(intent: Intent) {
    super.onNewIntent(intent)
    setIntent(intent)
    Clikgate.handleIntent(this, intent)          // warm start
}
```

`handleIntent` returns `true` for Clikgate links (host in your link domains, or your scheme
with `cg_click_id`); the resolved link arrives in `onDeepLink`. Each intent is processed once,
and intents replayed from Recents are ignored.

**Several link domains.** When your Clikgate domain group has aliases (e.g. `ybr.ng` and
`go.yourbrand.com`, where `ybr.ng/a8K2` and `go.yourbrand.com/a8K2` are the same link), list **every**
domain of the group in `linkDomains` and add one `<data android:host="..." />` per domain to the
`autoVerify` intent filter:

```xml
<intent-filter android:autoVerify="true">
    ...
    <data android:scheme="https" />
    <data android:host="ybr.ng" />
    <data android:host="go.yourbrand.com" />
</intent-filter>
```

Clikgate serves `apple-app-site-association` and `assetlinks.json` on every active domain of the group, but the OS opens your app only for the domains the app itself declares. The SDK also adds the domains the server lists in `/v1/sdk/config` (`link_domains`, cached with the config, compared case-insensitively) and logs a warning naming each server domain missing from `linkDomains`: add it to `linkDomains` and to the intent filter.

**App Link verification.** Clikgate serves `/.well-known/assetlinks.json` for your link
domain from the package name and SHA-256 signing-certificate fingerprints configured for the
app (include the Play App Signing key). Check on a device:

```sh
adb shell pm verify-app-links --re-verify com.example.myapp
adb shell pm get-app-links com.example.myapp        # expect: inv.myapp.com: verified
adb shell am start -a android.intent.action.VIEW -d "https://inv.myapp.com/p/dress"
```

## 4. Deep links

```kotlin
Clikgate.onDeepLink { link ->
    // link.path, link.data, link.isDeferred, link.matchType, link.link, link.referral
    when {
        link.referral != null -> showReferralWelcome(link.referral!!)
        link.path?.startsWith("/products/") == true -> openProduct(link.data["product_id"])
    }
}
```

- **Deferred** (first launch after install via the Play Store): the link the user tapped
  before installing, from the Play Install Referrer. Delivered whenever `/install` answers,
  with `isDeferred = true`.
- **Direct** (App Link / scheme): resolved via the server, `isDeferred = false`.
- Links that arrive before a listener is set are buffered (latest 10).
- **Password and country-restricted links (Change 17).** An App Link opens your app without Clikgate's
  redirect, so the SDK asks the server first. A password link opens in the browser app (the password page;
  `onDeepLink` isn't called). A link blocked for the visitor's country (or by a block rule) arrives with
  `link.blockMessage` set and no `path`, `clickId` or `link`: show the text and don't route
  (`if (link.blockMessage != null) { showNotice(link.blockMessage); return@onDeepLink }`).

**App link subdomain (change 09).** Your app opens links from its own link subdomain (`yourapp.ciz.to`,
shown in the dashboard under Apps › your app › Link subdomain), its test subdomain `yourapp.dev.ciz.to` (debug
builds only) and your verified custom domains. Declare those, and never a shared domain (`ciz.to`, `clk.ng`,
`clkg.to`, `dev.ciz.to`): their app-links files list no customer app, so they can't open yours, and
`npx @clikgate/setup doctor` warns "remove this: shared domains can't open your app". Links on shared domains
still work through the browser, the store and deferred deep links.

**Deep links and basic attribution on every plan (changes 10, 20, 21).** Deep links into your app are included on
every plan: direct links (App Links / Universal Links / your URI scheme) without a limit, and deferred deep links up to
your plan's monthly allowance (Pricing; no monthly cap on Growth and up). On Free your app's link subdomain is
`yourapp.clk.ng` (release builds); debug builds use `yourapp.dev.ciz.to` on every plan. `yourapp.clk.ng` is your
app's own subdomain, not the shared domain `clk.ng`, so declare it like `yourapp.ciz.to`; the setup command does.
Basic install attribution (which link, campaign or creator brought each install), in-app events and goals work on
every plan within its allowances; re-engagement and the advanced app reports need Growth. Only when attribution is
switched off for the app does the SDK run in deep-link-only mode: `Clikgate.goal(...)` and `Clikgate.track(...)` then log one warning and do
nothing (no error, nothing is sent), and attribution reads `organic`. `Clikgate.isFeatureEnabled(ClikgateFeatures.APP_ATTRIBUTION)` tells you which mode the app is in.
Once the monthly deferred deep link allowance is used, new installs open your home screen: the SDK gets its normal
"no deferred link" result, never an error. Links that open your app for people who already have it are sent with
the click they came from, so one tap is one click (change 21).

### Shared-domain links of other organisations (1.4.0)

`ciz.to`, `clk.ng`, `clkg.to` and `dev.ciz.to` are shared by many Clikgate customers, so Android can
open your app for another organisation's link on them. When the server says the link isn't yours
(`/resolve` → `matched: false`), the SDK opens it in **Custom Tabs** (or, without Custom Tabs, the
browser app), always in an explicit browser package so it can't loop back into your App Links. No
deep link is delivered; you can observe the handoff:

```kotlin
Clikgate.onBrowserHandoff { h -> analytics.log("clikgate_handoff", h.host) }   // h.url, h.host
```

Turn it off with `ClikgateOptions(platformDomainBrowserFallback = false)` (the link is then dropped, as
before 1.4.0). Your own custom domains and matched links are unaffected. The SDK manifest adds the
`<queries>` entries Android 11+ needs to find browsers.

Install attribution:

```kotlin
Clikgate.attribution { a -> log(a.status, a.matchType) }   // waits ≤ deferredDeepLinkTimeoutMs on first launch
val a = Clikgate.awaitAttribution()                          // suspend variant
```

## 4a. Replacing Firebase Dynamic Links

Firebase Dynamic Links shut down on August 25, 2025: `page.link` links now answer 404 and the Dynamic Links
APIs no longer work (Firebase's FAQ, https://firebase.google.com/support/dynamic-links-faq, checked 2026-11-05).
Old `page.link` addresses can't be moved; Google owned them. Links on a custom domain you own can be served by
Clikgate with the same paths: the link import's Firebase Dynamic Links preset adds your links and reports each old and new address. The
app side is a small swap:

| Firebase Dynamic Links | Clikgate |
|---|---|
| `page.link` or your domain in the app's associated domains | your app's link subdomain (and verified custom domains) in the app's associated domains |
| create links with `buildShortDynamicLink` or the REST API | create links in the dashboard, with the Clikgate API (`POST /v1/links`, server SDKs `links.create`) or, without a backend, the Engage add-on's referral links |
| read `link` from the received dynamic link | read `path` and `data` from the Clikgate deep link (`url` is the link that opened the app) |
| deferred link on first launch through the same callback | the same: the deferred link arrives on `onDeepLink` with `isDeferred` set |
| `utm_*` and `st` / `sd` / `si` link parameters | the link's tags and preview, set when the link is created (the import maps them) |

```kotlin
// Before: Firebase Dynamic Links
Firebase.dynamicLinks.getDynamicLink(intent)
    .addOnSuccessListener(this) { data: PendingDynamicLinkData? ->
        val deepLink: Uri? = data?.link
        if (deepLink != null) route(deepLink.path, deepLink)
    }

// After: Clikgate (configure once in Application.onCreate, section 2)
Clikgate.onDeepLink { link ->
    if (link.blockMessage != null) return@onDeepLink showNotice(link.blockMessage!!)
    route(link.path, link.data)              // link.isDeferred is true for the first launch after install
}
// in the launcher activity's onCreate and onNewIntent (section 3)
Clikgate.handleIntent(this, intent)
```

Then remove the `firebase-dynamic-links` dependency and the `page.link` intent filter, and add your Clikgate link
domains to the `autoVerify` intent filter (section 3). Firebase Analytics, Crashlytics and Messaging are unaffected.
Test with "See it live" in the dashboard (Developers › SDKs) and a `cg_sdk_test_…` key.

## 5. Events and identity

```kotlin
Clikgate.track("signup")
Clikgate.track("purchase", revenue = ClikgateMoney.ofMinor(1_500_000, "NGN"), properties = mapOf("order_id" to "A-1001"))

Clikgate.identifyUser(label = "Ada (VIP)", customerId = "user_42", identityToken = tokenFromYourBackend)
Clikgate.identifyUser(customerId = null)                   // logout
Clikgate.identifyUser(label = "Ada (VIP)")                   // just the label (the customer ID is kept)
```

Event names match `^[A-Za-z0-9_.$:-]{1,64}$` (`$` prefix reserved), properties ≤ 8 KB, currency
ISO 4217 uppercase. Invalid events are logged and dropped. Events are queued (SQLite, ≤ 1000 /
1 MB) and sent in batches: at 20 events, every 15 s in foreground, on background and on start;
offline batches are retried by WorkManager.

**Identity token** (required by referral programs with `require_identity_token`): computed by
your backend, never in the app:

```
issued_at = unix seconds
signature = base64url_nopad(HMAC_SHA256(identity_secret, "<customer_user_id>.<issued_at>"))
identity_token = "<signature>.<issued_at>"
```

## 5b. Send goals

One method for every goal, `Clikgate.goal(...)`:

```kotlin
import java.math.BigDecimal

// A Standard goal: counts when it's sent.
Clikgate.goal("account_opened", value = BigDecimal("2000000"), currency = "NGN", reference = "APP-55231", isFirst = true)
Clikgate.goal("kyc_passed")                                // no value, SDK-generated reference

// A Payment goal: send your payment provider's reference from the checkout's success callback.
Clikgate.goal("purchase", reference = transaction.reference, provider = Provider.PAYSTACK) { result ->
    // result.status: GoalStatus.COUNTED, WAITING or REFUSED; result.reason says why
}
```

Java: `Clikgate.goal("purchase", null, null, "T123456", Provider.PAYSTACK)` (`@JvmOverloads`).

**The goal's kind is set in the dashboard, never in the call.** A **Standard** goal counts when it's
sent. A **Payment** goal (anything involving money) counts only when your payment provider or your
server confirms it, with the real amount: from the app it is a report that waits for that
confirmation, so pass `reference` and `provider`; a `value` sent from the app is ignored.

| `result.status` | Meaning |
|---|---|
| `GoalStatus.COUNTED` | Counted. |
| `GoalStatus.WAITING` | Stored, not counted yet: `reason = "waiting_for_confirmation"` for a Payment goal until it's confirmed. |
| `GoalStatus.REFUSED` | Not counted. `reason` is the server's code (`unattributed`, `goal_not_found`, `payment_goal_needs_confirmation` when a Payment goal is missing `provider` or `reference`, ...) or, on the device, `invalid_argument`, `feature_disabled` (deep-link-only plan), `opted_out`, `consent_denied` or `sdk_version_blocked`. |

`result.goalKind` (`GoalKind.STANDARD` / `PAYMENT`) and `result.valueIgnored` come from the server.
`onResult` runs on the main thread once Clikgate has answered; while the device is offline the goal
waits in the queue, and a goal still queued when the app closes is sent on a later launch, without a
result. With a test SDK key (`cg_sdk_test_...`) the SDK logs one line when a Payment goal is waiting
for confirmation and one when its value was ignored.

**Providers:** `Provider.PAYSTACK`, `Provider.FLUTTERWAVE`, `Provider.MTN_MOMO`, `Provider.STRIPE`, ...
(`Provider.entries` lists them). For a provider added after this SDK release, use
`Provider.fromString("newpay")` (null when the value isn't a provider key); the server checks it.

**Never put customer data in goal calls; use the business's reference only.** No names, emails,
phone numbers, account numbers or user ids in the key or the reference: `reference` is your own id
for the event (application number, order id, transaction reference).

- **Key:** snake_case, 2–40 characters (`^[a-z][a-z0-9_]*$`), one of the goals defined in the
  Clikgate dashboard (Settings › Goals). An unknown or archived goal is rejected by the server and
  dropped.
- **Value** (optional): normal units, never kobo or cents (₦2,000,000 is `2000000`), ≥ 0, at most
  15 significant digits; a `BigDecimal` (never a `Double`), sent as a decimal string. Whether a value is allowed or required, and how many decimal
  places the currency allows, is checked by the server (rejected goals are dropped and logged).
- **Currency** (optional): ISO 4217; omitted = the goal's default currency.
- **Reference:** 1–128 characters. Omit it and the SDK generates a UUID, which only protects
  against double sends from the app: your backend can't refer to it later (reversals, refunds), so
  pass your own when you have one. A second goal with the same key and reference is ignored.
- **isFirst** (optional): your statement that this is the customer's first such event (for
  "click to first purchase"). Clikgate never checks it against an identity.
- Delivery: queued, batched and retried like events (they share the offline queue), attributed to
  the latest Clikgate link that opened the app, else the install. Consent works as for events: while
  consent is required and `attribution` is unknown, goals wait on the device (up to 7 days); on deny
  they're dropped.
- **Private mode** (an organisation setting for banks, insurers, lenders and health): `goal()`
  works as usual, while the customer ID of `identifyUser()`, event `properties` and event revenue are not sent (labels only when your organisation allows labels in private mode) (one warning
  in debug builds). Send outcomes and values through `goal()`.
- Goals completed on your server (a loan disbursed days later) should be sent by your backend
  (`POST /v1/goals/events`) with the click id from `attributionMetadata()`, saved with your own
  application when the user starts it.

## 6. Referrals (referee side)

```kotlin
val programId = "rpg_..."

Clikgate.referrals.applyCode(programId, "ADA42") { r ->
    when (r) {
        is ClikgateResult.Success -> showReferral(r.value)
        is ClikgateResult.Failure -> when (r.error.code) {
            "code_not_found" -> toast("Unknown code")
            "already_referred" -> toast("Already referred")
            "window_expired" -> toast("Too late to enter a code")
            "self_referral" -> toast("That's your own code")
            else -> toast(r.error.message)
        }
    }
}
Clikgate.referrals.referredBy { r -> r.getOrNull()?.referral?.let(::showInvitedByBanner) }

val referral = Clikgate.referrals.awaitApplyCode(programId, "ADA42")   // suspend; throws ClikgateError
val info = Clikgate.referrals.awaitReferredBy()
```

Referral calls made before the first `/install` completes wait up to 10 s, then fail with
`install_pending`. Errors are `ClikgateError(code, message, status, param)`; backend referral
codes are never retried.

The referrer side (the user's own link and code, stats, sharing) is not in the core SDK: get it
from your backend, or use Engage (section 6d).

## 6a. Feature switches

Each organisation feature can be switched off (per organisation or per app) in the dashboard.
The SDK reads the resolved switches from `/v1/sdk/config` (cached, refreshed on launch and at
most hourly):

```kotlin
if (Clikgate.isFeatureEnabled(ClikgateFeatures.LEADERBOARDS)) showLeaderboardTab()
```

Before the first config is known: `referrals`, `leaderboards`, `offline_codes`,
`app_attribution` on; `identity_checks`, `whatsapp_attribution`, `skan_postbacks`, ... off;
unknown keys off.

Calls of a switched-off feature never crash and never hit the network: they fail with
`ClikgateError(code = "feature_disabled", feature = "leaderboards")`. If the cached config was
stale and the server answers with its no-op body (`200 {"accepted": false, "reason":
"feature_disabled"}`), the call fails the same way, the feature reads as off right away and the
config is re-fetched in the background.

| Feature | Calls |
|---|---|
| `referrals` | `Clikgate.referrals.*`; Engage `referrals.*` |
| `leaderboards` | Engage `leaderboards.*` |
| `offline_codes` | Engage `codes.redeem` |

## 6d. Engage add-on (optional, apps without a backend)

```kotlin
dependencies { implementation("com.clikgate:clikgate-engage:1.1.0") }   // depends on clikgate-android
```

`ClikgateEngage` (package `com.clikgate.engage`) calls the same `/v1/sdk/...` endpoints using the
core SDK's installation, SDK key and identity token; `Clikgate.configure` must have been called.
Every call has a callback (main thread) and a `suspend` variant with the same name (throws
`ClikgateError`).

```kotlin
// Referrer side (needs Clikgate.identifyUser)
ClikgateEngage.referrals.createLink(programId, displayName = "Ada") { r -> r.getOrNull()?.let { show(it.code, it.url, it.shortUrl) } }
val stats = ClikgateEngage.referrals.myStats(programId)          // suspend: clicks, installs, signups, qualified, ...

// Share a link: each app gets its own version, and the share is recorded
ClikgateEngage.share.referralLink(activity, link, "Join me on MyApp:")                  // share menu
val opened = ClikgateEngage.share.link(activity, "https://inv.myapp.com/summer", "Our summer sale", ShareApp.WHATSAPP)  // false = menu used
// Plain text (nothing recorded)
ClikgateEngage.share.system(activity, "Join me on MyApp: ${link.url}")

// Leaderboards (build your own UI)
ClikgateEngage.leaderboards.top(board, LeaderboardPeriod.CURRENT, segment = null, limit = 50) { r -> }
val me = ClikgateEngage.leaderboards.me(board)                   // rank (null = unranked), score, pending, gapToNext, periodEndsAt
val around = ClikgateEngage.leaderboards.aroundMe(board, radius = 5)
ClikgateEngage.leaderboards.setOptOut(programId, optOut = true, callback = null)
val url = ClikgateEngage.leaderboards.hostedPageUrl(board)       // signed hosted-page URL for a WebView

// Promo / offline codes typed in the app
ClikgateEngage.codes.redeem(input.text.toString()) { r -> }      // offlineTouchId, code, referral?
```

Rules:

- A switched-off feature (`referrals`, `leaderboards`, `offline_codes`) fails with
  `feature_disabled` **without a network call**; a server `feature_disabled` answer also switches
  the feature off in the core SDK until the next config fetch.
- `createLink`, `myStats`, `me`, `aroundMe`, `setOptOut` and `hostedPageUrl` act for the user:
  they fail with `not_identified` (no network) until `Clikgate.identifyUser(customerId = userId, identityToken = token)`. Programs
  with `require_identity_token` answer `identity_required` until a valid token was given.
  `top` and `codes.redeem` don't need a user.
- Reads (`myStats`, `top`, `me`, `aroundMe`) are cached **in memory for 60 s** per user (nothing
  on disk); `createLink`, `setOptOut` and `redeem` clear the cache; `ClikgateEngage.clearCache()`
  drops it (e.g. pull to refresh). `hostedPageUrl` is never cached.
- At most **one retry, for network errors only** (interactive calls): HTTP errors such as 429 or
  5xx are reported at once.
- Errors are `ClikgateError` with the backend code: `referrer_not_found`, `client_link_creation_disabled`,
  `referral_link_limit`, `leaderboard_not_found`, `period_not_found`, `invalid_segment`,
  `code_not_found`, `code_expired`, `code_disabled`, `redemption_limit_reached`, `rate_limited`
  (5 code redemptions per hour), plus `hosted_page_unavailable` (server sent no `embed_url`) and
  `share_unavailable` (nothing can show a share sheet). Constants: `EngageErrors`. Referral errors
  from `redeem` carry `offlineTouchId` (the touch was recorded).
- `share.link(context, url, message?, app?, shareUrls?, chooserTitle?)` and
  `share.referralLink(context, link, message?, app?, chooserTitle?)` (Change 13): each app Clikgate knows gets its own version of the link (a short ending so Clikgate knows where you shared it), other apps get the plain link, and the share is recorded as a share count (the app and the link; no personal data, never a click). The
  menu is `Intent.createChooser` with a per-app text for the apps Clikgate knows and an `IntentSender`
  callback (Engage's own receiver) that reports the app picked; "Copy" counts as another app. With `app`,
  the share goes straight into that app (its packages in turn, then the default SMS or email app) and
  falls back to the menu when it isn't installed; no `<queries>` entry is needed. `referralLink` keeps the
  referral code. Apps with a backend pass the link's `share_urls` (Clikgate API) as `shareUrls`.
- `share.whatsApp` starts `ACTION_SEND` text/plain for `com.whatsapp`, else `com.whatsapp.w4b`
  (WhatsApp Business), else the system chooser; no `<queries>` manifest entry is needed. Pass an
  Activity (with an application context the share starts in a new task).
- Codes: 3–30 characters after trimming (`invalid_argument` otherwise); case, spaces and dashes
  are normalised by the server. Limits are clamped: `limit` 1..100, `radius` 1..25.
- No UI components; no polling or push of rank changes (refresh while the screen is visible).
- Engage models are plain classes (no data-class `equals`/`copy`, to keep the add-on under its
  40 KB budget). From Java: `ClikgateEngage.INSTANCE.getReferrals().createLink(programId, null, callback)`.

## 7. Push token and uninstall tracking

The SDK has no Firebase dependency: pass the FCM token and filter Clikgate's silent pushes.

```kotlin
// After Firebase is initialised:
FirebaseMessaging.getInstance().token.addOnSuccessListener { Clikgate.setPushToken(it, PushProvider.FCM) }

class MyMessagingService : FirebaseMessagingService() {
    override fun onNewToken(token: String) = Clikgate.setPushToken(token, PushProvider.FCM)

    override fun onMessageReceived(message: RemoteMessage) {
        if (Clikgate.isClikgateMessage(message.data)) return   // uninstall check: show nothing
        // your own handling
    }
}
```

The token is sent only when it changed. Clikgate's checks are data-only messages
(`{"cg": "uc"}`, normal priority, TTL 0); they never show a notification and need no
notification permission. Uninstalls are detected only for installs that registered a token
and only after you upload FCM credentials in Clikgate.

## 8. Privacy and opt-out

```kotlin
Clikgate.setTrackingEnabled(false)   // clears the queue, tells Clikgate to erase device data, stops all calls
Clikgate.setTrackingEnabled(true)    // resumes (same installation)
```

Opting out before the first launch's install records only an organic, opted-out
installation. While opted out, Clikgate links still reach `onDeepLink` with the URL's path and
query parameters (no server call).

**Fraud signals.** The install request carries `is_emulator` and `is_rooted` (1.1.0+) from cheap
on-device heuristics (Build properties; `test-keys`, `su` paths and, below Android 11, known root
apps), plus the Play Install Referrer click and install-begin times. They need no permission and
no `<queries>` entry, never block the install, and are hints for Clikgate's fraud scoring, not
proof. Not sent when the user opted out. Details: [android/DECISIONS.md](../android/DECISIONS.md).

**Backup.** The SDK's manifest excludes `clikgate.prefs.xml` and `clikgate_events.db` from
Auto Backup and device transfer (a restored app is a new installation). If your app declares
its own `android:fullBackupContent` / `android:dataExtractionRules`, add these excludes to your
files and resolve the merge with `tools:replace`:

```xml
<application
    android:fullBackupContent="@xml/backup_rules"
    android:dataExtractionRules="@xml/data_extraction_rules"
    tools:replace="android:fullBackupContent,android:dataExtractionRules">
```

```xml
<!-- in <full-backup-content> and in both <cloud-backup> and <device-transfer> -->
<exclude domain="sharedpref" path="clikgate.prefs.xml" />
<exclude domain="database" path="clikgate_events.db" />
<exclude domain="database" path="clikgate_events.db-journal" />
```

## 8a. Consent (1.2.0)

```kotlin
Clikgate.setConsentRegion("DE")   // optional hint: "EEA", "UK" or an ISO 3166-1 alpha-2 country
Clikgate.setConsent(
    analytics = ConsentState.GRANTED, attribution = ConsentState.GRANTED,
    adUserData = ConsentState.DENIED, adPersonalization = ConsentState.DENIED,
)                                  // a null / omitted purpose stays unchanged
val consent = Clikgate.getConsent() // purposes + region + required (null while unknown)
```

- Purposes: `analytics`, `attribution`, `adUserData`, `adPersonalization`; each `GRANTED`, `DENIED` or
  `UNKNOWN` (default). Stored on the device and sent with every request.
- Whether consent is **required** comes from the app's consent mode in Clikgate (EEA, UK and
  Switzerland by default) for the device's region (your hint, else the IP country). Before the first
  config only a hint in those regions counts.
- Required and `attribution` **unknown**: the SDK buffers on the device (up to 7 days or 1,000 events)
  and sends nothing identifying (no install, open, events; `/config` without the installation id).
  Clikgate links still reach `onDeepLink` (delivered locally with their query parameters), and the
  install referrer is kept. **Granted** sends the install and the buffer; **denied** drops it (and, if
  your organisation enabled anonymous counts, sends one identifier-free install count).
- Referral calls refused because of consent fail with `ClikgateError.CONSENT_REQUIRED`.
- `setTrackingEnabled(false)` still wins over consent. All consent calls work before `configure`.
- Screen size is sent only when probabilistic matching is enabled for the app **and** attribution
  consent allows it (otherwise Android sends no probabilistic-matching signal).

## 8b. Google click ids and the version policy

- `gclid` / `gbraid` / `wbraid` in a Clikgate App Link that opens the app, or in the Play install
  referrer (Google Ads auto-tagging), are sent with the install, `/resolve` and the next app open.
- LinkedIn `li_fat_id`, Snap `ScCid` and X `twclid` arrive in the same Clikgate links (and the Play referrer) when your app
  passes ad click IDs (dashboard, per network); they reach Clikgate inside the launch / resolved URL and the
  referrer, unchanged.
- Clikgate tells old SDK versions to update: a deprecated version logs a warning once per launch; a
  blocked version logs an error and only sends basic events (links then open locally). Calls a blocked
  version may not make fail with `ClikgateError.SDK_VERSION_BLOCKED`.

## 8c. Firebase forwarding and sales metadata

```kotlin
// On every launch (before or after configure):
Clikgate.enableFirebaseForwarding(FirebaseForwardingOptions(mirrorEvents = true, eventNameMap = mapOf("purchase" to "purchase")))

// Paystack / Flutterwave checkout: put these in metadata / meta so Clikgate can match the sale.
val metadata: Map<String, String> = Clikgate.attributionMetadata() // {"cg_click_id": ..., "cg_link_id": ...}
```

- Needs Firebase Analytics in your app (`com.google.firebase:firebase-analytics`; the SDK finds it by
  reflection and has no Firebase dependency), GA4 forwarding switched on for the app in Clikgate, and
  `analytics` consent. Logs `clikgate_attribution` once per install (`cg_source`, `cg_medium`,
  `cg_campaign`, `cg_channel`, `cg_link_id`, `cg_match_type`), sets `cg_first_source` /
  `cg_first_campaign`, optionally mirrors your `track()` events (Firebase name rules: 1–40 characters,
  ≤ 25 parameters, string values ≤ 100 characters; revenue becomes `value` + `currency`), and reports
  Firebase's app instance id to Clikgate for server-side GA4. Without Firebase it does nothing.
- `attributionMetadata()` is empty when nothing is attributed, when tracking is off, or when consent
  is required and attribution isn't granted.

## 9. Play Integrity (optional)

Add `com.google.android.play:integrity` (the SDK compiles against it but doesn't ship it; it's detected
at runtime, Android 6.0+) and set `attestation = Attestation.PLAY_INTEGRITY_IF_AVAILABLE`. When the
app's Clikgate settings enable Play Integrity (`monitor` / `enforce`) and identity-check consent allows
it (`analytics`, or your organisation's "fraud prevention" basis), the SDK attests the install and
re-attests every 7 days.

- With your Google Cloud project number (`ClikgateOptions.cloudProjectNumber`, or set it in the
  Clikgate dashboard, which sends it in the config) the SDK uses **standard** requests (warmed-up token
  provider, `requestHash` = Clikgate's nonce). Without it, **classic** requests (`nonce`).
- Identity checks on Android use only the Play Integrity verdicts and app-scoped identifiers (the
  installation id); no persistent hardware ids.

## 10. Testing deep links locally

```sh
# Direct App Link (app installed)
adb shell am start -a android.intent.action.VIEW -d "https://inv.myapp.com/p/dress"
# Deferred deep link: install from a Play internal test track after tapping the link.
# The Install Referrer only works for Play installs.
```

Point `apiBaseUrl` at a local backend (`http://10.0.2.2:8000` from the emulator; allow
cleartext for that host in a debug network security config).

## 11. Sample app

`android/sample` demonstrates direct and deferred deep links, apply code / referred-by (core),
invite link + WhatsApp share and stats (Engage add-on), events, FCM token forwarding and (1.2.0)
consent buttons, an EEA region hint, Firebase forwarding (`firebase-analytics` as a runtime-only
dependency) and `attributionMetadata()`. Build:

```sh
cd android
./gradlew :sample:installDebug -Pclikgate.sdkKey=cg_sdk_... -Pclikgate.apiBaseUrl=http://10.0.2.2:8000 \
  -Pclikgate.linkDomain=inv.myapp.com -Pclikgate.programId=rpg_...
```

It builds without `google-services.json` (the google-services plugin isn't applied). For push, pass
your Firebase app's values as Gradle properties; the sample initialises Firebase from them, and
without them push registration is skipped:

```sh
./gradlew :sample:installDebug ... -Pclikgate.firebaseApiKey=... -Pclikgate.firebaseAppId=1:...:android:... \
  -Pclikgate.firebaseProjectId=... -Pclikgate.firebaseSenderId=...
```

For the recommended backend path (invite link, stats and leaderboards from your server), see
[`samples/backend`](../samples/backend/README.md); the identity token it returns from
`POST /auth/demo-login` can be pasted into the sample's identity token field.

## 12. Removing the SDK

1. Remove the dependencies `com.clikgate:clikgate-android` and `com.clikgate:clikgate-engage` (and
   `com.google.android.play:integrity` if you added it only for Clikgate).
2. Remove `Clikgate.configure(...)` and every `Clikgate.*` / `ClikgateEngage.*` call: `onDeepLink`,
   `handleIntent` / `handleUrl` in your activities, `track`, `identify`, consent, Firebase forwarding,
   `attributionMetadata`, referral calls.
3. Remove the manifest entries you added for Clikgate: the `autoVerify` App Link intent filters for your
   Clikgate link domains and the custom-scheme intent filter (if it was only for Clikgate), plus the
   backup-rule excludes (`clikgate.prefs.xml`, `clikgate_events.db`) if you merged them into your own
   rules.
4. Remove push-token forwarding (`Clikgate.setPushToken`) and the `Clikgate.isClikgateMessage` check in
   your `FirebaseMessagingService` (uninstall tracking).
5. Update your Play Data safety answers and privacy policy once the release without the SDK ships.
6. In the Clikgate dashboard, mark the app as no longer tracked (and remove its FCM credentials) so
   Clikgate stops uninstall checks and doesn't warn that the SDK is missing.

The SDK's prefs (`clikgate.prefs`) and event database are deleted with the app; an update without the
SDK leaves them unused in the app's data directory (delete them on first launch if you want).

## API summary

| API | Notes |
|---|---|
| `Clikgate.configure(context, sdkKey, options)` | once, `Application.onCreate` |
| `Clikgate.handleIntent(activity, intent): Boolean` | `onCreate` + `onNewIntent` |
| `Clikgate.handleUrl(uri / url): Boolean` | URLs from other sources (QR codes) |
| `Clikgate.onDeepLink { }` | single listener, buffered |
| `Clikgate.attribution { }` / `awaitAttribution()` | |
| `Clikgate.track(name, revenue?, properties?)` | |
| `Clikgate.goal(key, value?, currency?, reference?, provider?, isFirst?, onResult?)` | `value` is a `BigDecimal`; `provider` a `Provider`; `onResult` gets a `GoalResult` |
| `Clikgate.onBrowserHandoff(listener?)` | 1.4.0; another organisation's shared-domain link opened in Custom Tabs |
| `Clikgate.identifyUser(label?, customerId?, identityToken?)` | customer ID dropped in private mode, label only when allowed |
| `Clikgate.setTrackingEnabled(Boolean)` | |
| `Clikgate.setPushToken(token, PushProvider)` / `isClikgateMessage(data)` | |
| `Clikgate.referrals.applyCode / referredBy` | callbacks + `awaitApplyCode` / `awaitReferredBy` |
| `Clikgate.isFeatureEnabled(key): Boolean` | cached config; `ClikgateFeatures.*` |
| `Clikgate.setConsent(analytics?, attribution?, adUserData?, adPersonalization?)` / `getConsent()` | 1.2.0; `ConsentState`, `ClikgateConsent` |
| `Clikgate.setConsentRegion(region?)` | 1.2.0; `EEA`, `UK` or a country code |
| `Clikgate.enableFirebaseForwarding(FirebaseForwardingOptions)` | 1.2.0; Firebase detected at runtime |
| `Clikgate.attributionMetadata(): Map<String, String>` | 1.2.0; `cg_click_id`, `cg_link_id` |
| `Clikgate.sdkVersion` | |
| *Engage add-on* (`com.clikgate:clikgate-engage`) | callback + same-name `suspend` variants |
| `ClikgateEngage.referrals.createLink(programId, displayName?)` / `myStats(programId)` | `ReferralLink` / `ReferralStats` |
| `ClikgateEngage.share.link(context, url, message?, app?, shareUrls?, chooserTitle?)` / `referralLink(context, link, message?, app?, chooserTitle?)` | `Boolean` (`app` itself opened); `ShareApp` |
| `ClikgateEngage.share.system(context, text, chooserTitle?)` / `whatsApp(context, text)` | `Unit` / `Boolean` (WhatsApp opened) |
| `ClikgateEngage.leaderboards.top(id, period, segment?, limit)` | `LeaderboardPage` |
| `ClikgateEngage.leaderboards.me(id, period, segment?)` / `aroundMe(id, radius, period, segment?)` | `MyRank` / `LeaderboardPage` |
| `ClikgateEngage.leaderboards.setOptOut(programId, optOut)` / `hostedPageUrl(id, period)` | `Unit` / `String` |
| `ClikgateEngage.codes.redeem(code)` | `Redemption` |
| `ClikgateEngage.clearCache()` / `ClikgateEngage.version` | |
