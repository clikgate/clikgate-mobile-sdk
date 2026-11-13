# Clikgate iOS SDK — integration guide

Deep links (Universal Links and custom schemes), deferred deep links, install attribution, goals,
identifyUser, referee-side referral calls and push-token registration for uninstall tracking — the things
that must happen on the device (spec 0.4). Referrer-side features (the user's invite link and stats,
leaderboards, promo codes, share helpers) are **not** in the core SDK: the recommended path is your
backend calling the Clikgate control-plane API; apps without a backend can use the **Engage
features** (`ClikgateEngage`, section 7b), which ship in the same package. See [engage.md](engage.md).

- iOS 13+ devices. Build with **Xcode 26 or newer** (Swift 6.2; clean under strict concurrency): App Store
  submissions need the iOS 26 SDK, and CI builds and tests only with Xcode 26.
- No third-party dependencies. Size budgets (arm64, `-Osize`, every public API in use): core
  < 410 KB (measured 385.4 KB in 2.1.0), Engage features < 95 KB (measured 92.4 KB), each measured on its own module; see `ios/DECISIONS.md`.
- It never shows the ATT prompt or the notification-permission prompt.

## 1. Install

**Swift Package Manager**: add `https://github.com/clikgate/clikgate-ios-sdk` (the SPM mirror: `Package.swift`,
`Sources`, `LICENSE` and `ios/README.md` from this repository) from version `2.1.0`, and link the `Clikgate` product. It contains two modules: `Clikgate` (core) and
`ClikgateEngage` (the Engage features, section 7b; `import ClikgateEngage` only if you use them).

**CocoaPods**

```ruby
platform :ios, '13.0'
pod 'Clikgate', '~> 2.1'   # core and the Engage features
```

With CocoaPods the core and the Engage sources are compiled into the one `Clikgate` module, so Engage
code uses `import Clikgate`; with SPM it is `import ClikgateEngage`.

**XCFramework**: download `Clikgate-<version>.xcframework.zip` from the GitHub release (or build it with
`ios/scripts/build_xcframework.sh`) and embed it. It's a static framework that includes `PrivacyInfo.xcprivacy`.
For the Engage features, also add `ClikgateEngage-<version>.xcframework.zip` (Engage code only; it needs
`Clikgate.xcframework` next to it) and `import ClikgateEngage`. Both are built from the one package.

## 2. Configure

```swift
import Clikgate

func application(_ application: UIApplication,
                 didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
    Clikgate.configure(sdkKey: "cg_sdk_...", options: ClikgateOptions(
        linkDomains: ["inv.myapp.com"],      // every link domain of your group (+ the server's link_domains)
        logLevel: .warning,
        environment: .production,
        pasteboardMode: .off,                // default; .automatic | .pasteControlOnly opt in (§5)
        waitForATT: false,
        attestation: .appAttestIfAvailable,  // or .off (default)
        deferredDeepLinkTimeout: 5))

    Clikgate.shared.onDeepLink { result in  // main thread; deferred and direct links
        if let referral = result.referral { showWelcome(invitedBy: referral.referrerDisplayName) }
        router.open(path: result.path ?? "/", data: result.data)
    }
    return true   // the SDK registers for remote notifications itself (automaticPushToken, §8)
}
```

`configure` returns immediately. Links that arrive before you register `onDeepLink` (the latest 10)
are delivered when you register it. Links that arrive before `configure` are handled right after it.

| Option | Default | Meaning |
|---|---|---|
| `apiBaseUrl` | `https://sdk.clikgate.com` | Override only for a local backend. |
| `linkDomains` | `[]` | Universal Link hosts: **every** link domain of your Clikgate domain group, each also in Associated Domains (§3). The server's `link_domains` are added to these. |
| `logLevel` | `.warning` | `.verbose` `.debug` `.info` `.warning` `.error` `.none`. Keys, tokens and pasteboard contents are never logged. |
| `environment` | `.production` | Logs a warning if it doesn't match the SDK key's app. |
| `pasteboardMode` | `.off` | Clipboard deferred deep link, opt-in since 1.2.0. See §5. |
| `waitForATT` | `false` | Waits up to 30 s for *your* ATT prompt before the first `/install`. |
| `attestation` | `.off` | App Attest, when the device supports it and your app's settings enable it. |
| `deferredDeepLinkTimeout` | `5` s | How long `attribution()` waits on the first launch. |
| `automaticPushToken` | `true` | While uninstall tracking is on, calls `registerForRemoteNotifications()` on each launch (no prompt). See §8. |

## 3. Universal Links and URL schemes

1. In Xcode, under **Signing & Capabilities → Associated Domains**, add `applinks:inv.myapp.com` for each
   Clikgate link domain. Clikgate serves the `apple-app-site-association` file once your app's Team ID and
   bundle id are set in the dashboard. **Several link domains**: when your domain group has aliases (e.g.
   `ybr.ng` and `go.yourbrand.com`, where `ybr.ng/a8K2` and `go.yourbrand.com/a8K2` are the same link), add
   `applinks:ybr.ng` *and* `applinks:go.yourbrand.com`, and list both in `linkDomains`. Clikgate serves `apple-app-site-association` and `assetlinks.json` on every active domain of the group, but the OS opens your app only for the domains the app itself declares. The SDK also adds the domains the server lists in `/v1/sdk/config` (`link_domains`, cached with the config, compared case-insensitively) and logs a warning naming each server domain missing from `linkDomains`: add it to `linkDomains` and to Associated Domains.
2. Add a URL scheme (**Info → URL Types**, e.g. `myapp`). The interstitial's "Open in app" button opens
   `myapp://<path>?cg_click_id=…`.
3. Forward both to the SDK. `handle(url:)` and `continue(userActivity:)` return `true` for Clikgate links;
   the result arrives on `onDeepLink`.

```swift
// AppDelegate (no scenes)
func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
    Clikgate.shared.handle(url: url)
}
func application(_ application: UIApplication, continue userActivity: NSUserActivity,
                 restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void) -> Bool {
    Clikgate.shared.continue(userActivity: userActivity)
}

// SceneDelegate
func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
    options.userActivities.forEach { Clikgate.shared.continue(userActivity: $0) }
    options.urlContexts.forEach { Clikgate.shared.handle(url: $0.url) }
}
func scene(_ scene: UIScene, continue userActivity: NSUserActivity) { Clikgate.shared.continue(userActivity: userActivity) }
func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    URLContexts.forEach { Clikgate.shared.handle(url: $0.url) }
}

// SwiftUI
.onOpenURL { Clikgate.shared.handle(url: $0) }
.onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { Clikgate.shared.continue(userActivity: $0) }
```

A URL counts as a Clikgate link when its host is in the link domains, or when it uses one of your app's
schemes and carries `cg_click_id`. Other URLs return `false` without a network call.

**App link subdomain.** Your app opens links from its own link subdomain (`yourapp.ciz.to`,
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
Basic install attribution (which link, campaign or creator brought each install) and goals work on every plan, up to
the plan's allowance; re-engagement and the advanced app reports need Growth. Only when attribution is
switched off for the app does the SDK run in deep-link-only mode: `Clikgate.shared.goal(...)` then logs one warning and does
nothing (no error, nothing is sent), and attribution reads `organic`. `Clikgate.shared.isFeatureEnabled(ClikgateFeatures.appAttribution)` tells you which mode the app is in.
Once the monthly deferred deep link allowance is used, new installs open your home screen: the SDK gets its normal
"no deferred link" result, never an error. Links that open your app for people who already have it are sent with
the click they came from, so one tap is one click (change 21).

**Password and country-restricted links (Change 17).** A Universal Link opens your app without Clikgate's
redirect, so the SDK asks the server first. A **password link** opens in Safari (the password page; your app gets
nothing). A link **blocked for the visitor's country** (or by a block rule) arrives on `onDeepLink` with
`result.blockMessage` set and no `path`, `clickId` or `link`: show the text and don't route.

```swift
Clikgate.shared.onDeepLink { result in
    if let message = result.blockMessage { showNotice(message); return }
    router.open(result.path, result.data)
}
```

**Shared-domain links of other organisations (1.4.0).** `ciz.to`, `clk.ng`, `clkg.to` and `dev.ciz.to`
are shared by many Clikgate customers, so iOS can open your app for another organisation's link. When
the server says the link isn't yours (`matched: false`), the SDK shows it in an in-app
`SFSafariViewController` over your top view controller (never `UIApplication.open`, which would hand
the Universal Link straight back to your app). `onDeepLink` isn't called; instead the SDK posts
`Clikgate.browserHandoffNotification` on the main thread with the link's `URL` as `object` (observe it
early; it isn't buffered):

```swift
NotificationCenter.default.addObserver(forName: Clikgate.browserHandoffNotification, object: nil, queue: .main) { n in
    if let url = n.object as? URL { Analytics.log("clikgate_handoff", url.host ?? "") }
}
```

Turn it off with `ClikgateOptions(platformDomainBrowserFallback: false)` (the link is dropped, as
before). Custom domains and matched links are unaffected. The SDK links `SafariServices` (a system
framework).

## 3a. Replacing Firebase Dynamic Links

Firebase Dynamic Links shut down on August 25, 2025: `page.link` links now answer 404 and the Dynamic Links
APIs no longer work (Firebase's FAQ, https://firebase.google.com/support/dynamic-links-faq, checked 2026-11-05).
Old `page.link` addresses can't be moved; Google owned them. Links on a custom domain you own can be served by
Clikgate with the same paths: the link import's Firebase Dynamic Links preset adds your links and reports each old and new address. The
app side is a small swap:

| Firebase Dynamic Links | Clikgate |
|---|---|
| `page.link` or your domain in the app's associated domains | your app's link subdomain (and verified custom domains) in the app's associated domains |
| create links with `buildShortDynamicLink` or the REST API | create links in the dashboard, with the Clikgate API (`POST /v1/links`, server SDKs `links.create`) or, without a backend, the Engage features' referral links |
| read `link` from the received dynamic link | read `path` and `data` from the Clikgate deep link (`url` is the link that opened the app) |
| deferred link on first launch through the same callback | the same: the deferred link arrives on `onDeepLink` with `isDeferred` set |
| `utm_*` and `st` / `sd` / `si` link parameters | the link's tags and preview, set when the link is created (the import maps them) |

```swift
// Before: Firebase Dynamic Links
func application(_ application: UIApplication, continue userActivity: NSUserActivity,
                 restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void) -> Bool {
    guard let url = userActivity.webpageURL else { return false }
    return DynamicLinks.dynamicLinks().handleUniversalLink(url) { dynamicLink, _ in
        if let link = dynamicLink?.url { self.route(link) }
    }
}
func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
    if let link = DynamicLinks.dynamicLinks().dynamicLink(fromCustomSchemeURL: url)?.url { route(link); return true }
    return false
}

// After: Clikgate (configure once at launch, section 2)
Clikgate.shared.onDeepLink { result in
    if let message = result.blockMessage { showNotice(message); return }
    router.open(result.path, result.data)    // result.isDeferred is true for the first launch after install
}
func application(_ application: UIApplication, continue userActivity: NSUserActivity,
                 restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void) -> Bool {
    Clikgate.shared.continue(userActivity: userActivity)
}
func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
    Clikgate.shared.handle(url: url)
}
```

Scene and SwiftUI apps forward the same two calls (section 3). Then remove the `FirebaseDynamicLinks` package or
pod, the `applinks:….page.link` Associated Domains entry and `FirebaseDynamicLinksCustomDomains` from Info.plist,
and add `applinks:` entries for your Clikgate link domains. Firebase Analytics, Crashlytics and Messaging are
unaffected. Test with "See it live" in the dashboard (Developers › SDKs) and a `cg_sdk_test_…` key.

## 4. Attribution

```swift
let attribution = try await Clikgate.shared.attribution()   // .attributed / .organic / .pending
Clikgate.shared.attribution { result in ... }               // completion-handler variant
```

On the first launch this waits up to `deferredDeepLinkTimeout` for the server. If the server doesn't
answer in time it returns `.pending`; the deferred deep link still arrives on `onDeepLink` later.

## 5. Deferred deep links on iOS: clipboard (opt-in)

Off by default since 1.2.0: the SDK touches the pasteboard only when you set `pasteboardMode` to
`.automatic` or `.pasteControlOnly` **and** clipboard deferred linking is switched on for the app in the
dashboard (`pasteboard_matching`, per app, off by default). Probabilistic matching never runs on iOS, so
without it a deferred deep link needs a Universal Link, Apple Search Ads or a code.

The landing page copies `https://<link domain>/_cg/p/cgdl_…` only after the user taps **Open in app**.
On the first launch only:

- `.automatic`: the SDK checks `UIPasteboard.detectPatterns` (no prompt) and reads the pasteboard only if a
  web URL is likely. **On iOS 16+ the user sees the system prompt** "“<Your app>” would like to paste from
  “Safari”" with **Allow Paste** / **Don't Allow** (wording varies by iOS version and language; users can
  change it under Settings › <Your app> › Paste from Other Apps). Explain this on your onboarding screen if
  you use it. While consent is still unknown in a consent region the token stays on the device and is sent
  only after `attribution` is granted (dropped on deny).
- `.pasteControlOnly`: the SDK never reads automatically. Show the system Paste button instead (no prompt);
  a match delivers the deferred link on `onDeepLink`:

```swift
let paste = ClikgatePasteControl(showsLabel: true)        // UIPasteControl on iOS 16+
paste.onPaste = { found in if !found { showNoInviteFound() } }
view.addSubview(paste)
```
- `.off`: the SDK never touches the pasteboard.

**What the dashboard measures.** When the paste flow runs, the first `/install` also says what the paste
step saw (`pasteboard_outcome`; never the pasteboard contents), so the dashboard can show the app's iPhone
match rate:

- **Token found**: the link the landing page copied was on the pasteboard.
- **Didn't tap Open in app** (`no_link`): no link was on the pasteboard, so nothing was read.
- **Something else was copied** (`no_token`): the pasteboard held something, but not a Clikgate link.
- **Declined paste** (`denied`): the user tapped **Don't Allow** on the paste prompt.
- **Paste button** (`paste_control`): `.pasteControlOnly`, no automatic read; a tap on the Paste button can
  still match later.
- **Token expired** (worked out by the server): a token was sent but had expired or was already used.

Nothing is sent with `.off`, when the dashboard setting is off, or when the user opted out or denied
consent. How it works end to end: https://clikgate.com/docs/deferred-deep-links-iphone

## 5a. Consent (1.2.0)

```swift
Clikgate.shared.setConsentRegion("DE")              // optional hint: EEA, UK or a country code
Clikgate.shared.setConsent(analytics: .granted, attribution: .granted,
                           adUserData: .denied, adPersonalization: .denied)   // nil = unchanged
let consent = Clikgate.shared.getConsent()            // + region, isRequired (nil while unknown)
```

- Purposes: `analytics`, `attribution`, `adUserData`, `adPersonalization`; each `.granted`, `.denied` or
  `.unknown` (default). Stored on the device and sent with every request.
- Whether consent is **required** comes from the app's consent mode in Clikgate (EEA, UK and Switzerland
  by default) for the device's region (your hint, else the IP country). Before the first config, only a
  hint in those regions counts.
- Required and `attribution` **unknown**: the SDK buffers on the device (up to 7 days or 1,000 goals) and
  sends nothing identifying (no install, open, goals; `/config` without the installation id). Clikgate
  links still open the right screen (delivered locally with their query parameters). **Granted** flushes
  the buffer; **denied** drops it (one anonymous install count if the organisation enabled it).
- `setTrackingEnabled(false)` still wins over consent.
- Calls refused because of consent fail with `ClikgateError.consentRequired` (`consent_required`).
- All consent calls work before `configure`.

## 5b. Google click ids, version policy, identity checks

- `gclid` / `gbraid` / `wbraid` in a Clikgate link that opens the app are sent with the install, the
  `/resolve` call and the next app open (Google Ads conversion uploads).
- LinkedIn `li_fat_id`, Snap `ScCid` and X `twclid` arrive in the same Clikgate links when your app passes ad click IDs
  (dashboard, per network); they reach Clikgate inside the launch / resolved URL, unchanged.
- Clikgate tells old SDK versions to update: a deprecated version logs a warning once per launch; a blocked
  version logs an error and only makes basic calls (links then open locally; goals only if Clikgate allows them). Calls a blocked version may
  not make fail with `ClikgateError.sdkVersionBlocked`.
- Identity checks use App Attest (`attestation: .appAttestIfAvailable`), Apple DeviceCheck tokens and the
  IDFV only, when `analytics` consent allows (or the organisation's basis is fraud prevention) and identity
  checks or App Attest are enabled. No hardware or OS fingerprint signals.

## 5c. Firebase forwarding, sales metadata, Google on-device measurement

```swift
// Before or after configure, on every launch:
Clikgate.shared.enableFirebaseForwarding(ClikgateFirebaseForwardingOptions())
```

- Needs Firebase Analytics in your app (looked up at runtime, no dependency), GA4 forwarding switched on in
  Clikgate, and `analytics` consent. Logs `clikgate_attribution` once per install (`cg_source`,
  `cg_medium`, `cg_campaign`, `cg_channel`, `cg_link_id`, `cg_match_type`), sets `cg_first_source` /
  `cg_first_campaign`, and reports Firebase's app instance id to Clikgate for server-side GA4.
- Sales tracking (Paystack, Flutterwave): add `Clikgate.shared.attributionMetadata()`
  (`["cg_click_id": …, "cg_link_id": …]`) to the transaction's `metadata` / `meta`. Empty when nothing is
  attributed or consent doesn't allow attribution.
- Google on-device conversion measurement: link Google's `GoogleAdsOnDeviceConversion` SDK yourself, then
  call `Clikgate.shared.enableGoogleOnDeviceMeasurement()` **before** `configure` on the first launch. The SDK
  asks it for the installation's aggregate conversion info and passes it to Clikgate with the install (not
  when `adUserData` is denied). You give first-party data to Google's SDK yourself; Clikgate never sends raw
  email or phone numbers.

## 6. Identify your users, opt-out

Optional: you need it for labels and the person timeline, referrals and leaderboards that need a verified user, and
"existing customer" checks. Anonymous users are tracked by click or installation without it. The customer ID is your
own internal user ID (never an email, phone, BVN or NIN), the same on app, website and server. Full guide:
https://clikgate.com/docs/identify-users

**Path A: identity token (the default).** Your server makes the token in one line with the server SDK (Node
`createIdentityToken`, Python `create_identity_token`, PHP `\Clikgate\IdentityToken::create`, Java / .NET
`IdentityTokens.create` / `Create`; the secret is `CLIKGATE_IDENTITY_SECRET`, or `CLIKGATE_IDENTITY_SECRETS` for
several apps, on the server only) and returns it in the sign-in response and the "current user" response the app
already calls at open. The app passes the newest token:

```swift
Clikgate.shared.identifyUser(customerId: user.id, identityToken: me.clikgateToken)  // after sign-in, and at app open
Clikgate.shared.identifyUser(label: "Ada (VIP)")      // just the label (the customer ID is kept; Growth and up)
Clikgate.shared.identifyUser(customerId: nil)         // sign-out
Clikgate.shared.setTrackingEnabled(false)             // stops everything; tells Clikgate to erase device data
```

The token is `base64url_nopad(HMAC_SHA256(identity_secret, "<customer_user_id>.<issued_at>")) + "." + issued_at`,
always made on your server, never in the app. It lasts 30 days by default; no forced refresh.

**Path B: installation ID (no secret, no token).** The app sends this installation's ID with the sign-in request
(and at every signed-in app open); your server calls the server SDK's
`identifyUser({appId, installationId, customerId, label?})`:

```swift
let installationId: String? = try await Clikgate.shared.installationId()
// or: Clikgate.shared.installationId { result in … }   (Result<String?, ClikgateError>, main queue)
```

`installationId()` returns the random UUID the SDK created at first launch (kept in the Keychain) and sends with every
call (not personal data; allowed in private mode). Right after `configure` it waits for the first launch's config
answer (a few seconds at most; offline it answers at once) and never blocks the main thread. A reinstall gets a new ID
(the previous one goes to Clikgate as `keychain_previous_installation_id`). It returns `nil` when tracking is off
(`setTrackingEnabled(false)`, consent denied or not given yet where it's required, or deep-link-only mode): your
server then skips `identifyUser`. It throws `not_configured` before `configure`.

**No SKAdNetwork / AdAttributionKit updates from goals.** The SDK doesn't set postback conversion values. To get
postback copies, add to `Info.plist`:
- AdAttributionKit: the `AdAttributionKit` dictionary with `AttributionCopyEndpoint` = `https://<your Clikgate domain>`.
- SKAdNetwork: `NSAdvertisingAttributionReportEndpoint` = `https://<your Clikgate domain>`.

**Apple Ads.** Turn it on in the dashboard (the setting is still called `apple_search_ads` in the API); there is no SDK switch. The SDK requests the AdServices token (iOS 14.3+) when it sends the install, so after the consent grant when consent is required, requests a new one if 24 hours passed since it was fetched, and keeps nothing on the device after sending. It isn't requested when attribution consent is denied. With identity-check consent the install also carries the IDFV, so Clikgate can link an Apple Ads redownload to the earlier install. No ATT prompt is involved.

## 6a. Send goals: one `goal()` method

`goal()` is the one method for every goal, Standard or Payment. Each goal's **kind** is set in the dashboard
(Settings › Goals), never in the call:

- **Standard** goals (sign-ups, bookings, leads, accounts opened) count when they're sent.
- **Payment** goals (anything involving money) count only when your payment provider or your server confirms
  them, with the confirmed amount. From the app, pass the payment `reference` your checkout returned and the
  `provider`; any `value` is ignored.

```swift
Clikgate.shared.goal("account_opened", value: 2_000_000, currency: "NGN", reference: "APP-55231", isFirst: true)

// A Payment goal, from your checkout's success callback:
Clikgate.shared.goal("purchase", reference: transaction.reference, provider: .paystack) { result in
    switch result.status {
    case .counted: break                      // counted
    case .waiting: break                      // a Payment goal waiting for its confirmation
    case .received: break                     // stored, not counted: the name isn't ticked in the dashboard yet
    case .refused: print(result.reason ?? "") // e.g. invalid_argument, payment_goal_needs_confirmation
    }
}
```

The completion gets a `ClikgateGoalResult` on the main queue once Clikgate answers: `status`
(`ClikgateGoalStatus`: `.counted`, `.waiting`, `.received` or `.refused`), `reason` (nil when counted), `goalKind`
(`ClikgateGoalKind`: `.standard` or `.payment`) and `valueIgnored`. Invalid input is refused at once
(`invalid_argument`). If the business has switched off "Allow unknown goal names", a name that isn't set up as a goal is refused with `unknown_goal` (an archived goal with `goal_archived`). That refusal is final: it isn't retried or queued again, and debug builds log "Goal `{name}` isn't set up in Clikgate". The SDK never checks names itself: Clikgate decides. Calling again with the same key and reference while the first call is still queued
completes at once with `.waiting` and reason `already_queued`. Offline, the goal stays queued and the completion waits; if the app quits first the
completion isn't called, but the goal is still sent on the next launch. `.received` (reason `not_counted_yet`, or
`goal_archived`) is a success: the name is stored and counts once you tick "Count this as a goal" in "Seen from your
app and website"; it isn't retried.

**Providers.** `ClikgateProvider` lists the payment providers Clikgate knew when this SDK was released
(`.paystack`, `.flutterwave`, `.monnify`, `.mtnMomo`, `.stripe`, …). For a
provider added later, use `ClikgateProvider.fromString("newpay")` (nil for a malformed key); the server checks
it (`unknown_provider`).

**Payment goals from the app.** A Payment goal sent without `provider` or `reference` is refused
(`payment_goal_needs_confirmation`). Otherwise it waits (`reason: "waiting_for_confirmation"`) until a trusted
source confirms it: your server (`POST /v1/goals/events` or a server SDK payment helper such as
`payments.fromPaystack(...)`), the gateway's webhook, or the WordPress plugin or Shopify app. Clikgate then counts
it with the confirmed amount and currency. With a test SDK key (`cg_sdk_test_…`) the SDK logs one line when a
Payment goal is waiting ("purchase is a Payment goal: waiting for confirmation"), ending "; its value was
ignored" when you sent a value.

**Never put customer data in goal calls; use the business's reference only.** No names, emails,
phone numbers, account numbers or user ids in the key or the reference: `reference` is your own id
for the event (application number, order id, transaction reference).

- **Key:** snake_case, 2–40 characters (`^[a-z][a-z0-9_]*$`), one of the goals defined in the
  Clikgate dashboard (Settings › Goals). An unknown or archived goal is rejected by the server and
  dropped.
- **Value** (optional, Standard goals): normal units, never kobo or cents (₦2,000,000 is `2000000`), ≥ 0, at most
  15 significant digits; a `Decimal` (never a `Double`: build it from a string or an integer literal), sent as a decimal string. Whether a value is allowed or required, and how many decimal
  places the currency allows, is checked by the server (rejected goals are dropped and logged).
- **Currency** (optional): ISO 4217; omitted = the goal's default currency.
- **Reference:** 1–128 characters. Omit it and the SDK generates a UUID, which only protects
  against double sends from the app: your backend can't refer to it later (reversals, refunds), so
  pass your own when you have one. A second goal with the same key and reference is ignored.
- **isFirst** (optional): your statement that this is the customer's first such event (for
  "click to first purchase"). Clikgate never checks it against an identity.
- Delivery: queued on disk (up to 1,000 / 1 MB), sent in batches (at 20, every 15 s in the foreground, on
  background and on launch) and retried, attributed to the latest Clikgate link that opened the app, else the
  install. Goals sent before the first install completes wait in the queue. Consent: while
  consent is required and `attribution` is unknown, goals wait on the device (up to 7 days); on deny
  they're dropped.
- **Private mode** (an organisation setting for banks, insurers, lenders and health): `goal()`
  works as usual, while the customer ID of `identifyUser()` is not sent (labels only when your organisation allows labels in private mode) (one warning
  in debug builds). Send outcomes and values through `goal()`.
- Goals completed on your server (a loan disbursed days later) should be sent by your backend
  (`POST /v1/goals/events`) with the click id from `attributionMetadata()`, saved with your own
  application when the user starts it.

## 7. Referrals (referee side)

```swift
let referral = try await Clikgate.shared.referrals.applyCode(programId: "rpg_...", code: "ADA42")
let referredBy = try await Clikgate.shared.referrals.referredBy()
```

Both are tied to this installation and need the first install to have completed. Each has a
completion-handler variant. Errors are `ClikgateError` with `code`, `message`, `status` and `param`:
- Backend codes (`code_not_found`, `already_referred`, `window_expired`, `self_referral`,
  `program_paused`, `manual_entry_disabled`, `referrer_blocked`, …).
- SDK codes:
  - `feature_disabled`: the feature is switched off for the app (`error.feature` names it)
  - `not_configured`
  - `install_pending`: the first install hasn't completed yet
  - `opted_out`
  - `network_error`
  - `timeout`
  - `invalid_argument`

Creating the user's own invite link, "my referral stats", leaderboards and promo codes are referrer-side
features. Do them from your backend with the control-plane API (recommended), or with the Engage features
(section 7b) if the app has no backend. Identity-check signals are server-to-server only: there is no SDK
API for them (the hashing pepper must never ship in an app).

## 7a. Feature switches

Your organisation can switch features off per app. The SDK keeps the switches from `/v1/sdk/config`
(cached; refreshed on launch, at most hourly):

```swift
if Clikgate.shared.isFeatureEnabled(ClikgateFeatures.referrals) { showEnterCodeField() }
```

- Before the first config fetch, and for keys an older server doesn't send, `referrals`,
  `leaderboards`, `offline_codes` and `app_attribution` count as on; everything else is off.
  Unknown keys are off.
- A call to a switched-off feature throws `ClikgateError` `feature_disabled` (with `feature` set)
  **without a network call**. You only need `isFeatureEnabled` to hide UI.
- If the cached config is out of date, the server answers `feature_disabled` and the SDK reports the same
  error, treats the feature as off and refreshes the config in the background.

## 7b. Engage features (apps without a backend)

Nothing extra to install: the Engage features are in the `Clikgate` package (since 2.1.0; there is no
separate Engage product or subspec).

```swift
import ClikgateEngage   // SPM; with CocoaPods it's part of `import Clikgate`

let link = try await ClikgateEngage.referrals.createLink(programId: "rpg_...", displayName: "Ada")  // code, url, shortUrl
let stats = try await ClikgateEngage.referrals.myStats(programId: "rpg_...")     // clicks, installs, qualified, …
try await ClikgateEngage.share.referralLink(link, message: "Join me on MyApp:")  // share sheet; each app gets its own version
let opened = try await ClikgateEngage.share.link("https://inv.myapp.com/summer", app: .whatsapp)  // false = share sheet used
try ClikgateEngage.share.system(text: "Join me on MyApp: \(link.url)")            // plain text, nothing recorded

let lb = ClikgateEngage.leaderboards
let page = try await lb.top(id: "lb_...", period: .current, limit: 50)   // name, metric, period, entries
let me = try await lb.me(id: "lb_...")                   // rank (nil if unranked), score, pending, gapToNext, periodEndsAt
let around = try await lb.aroundMe(id: "lb_...", radius: 5)
try await lb.setOptOut(programId: "rpg_...", optOut: true)
let embed = try await lb.hostedPageUrl(id: "lb_...")     // signed URL of the hosted leaderboard page, for a WKWebView

let redemption = try await ClikgateEngage.codes.redeem("LAGOS50")   // offlineTouchId, code.kind, referral
```

Engage has no state of its own: it calls the same `/v1/sdk/*` endpoints with the core SDK's context
(installation id, SDK key, identity token), so `Clikgate.configure` must have run and the first install
must have completed (`install_pending` otherwise). Every call has a completion-handler variant (main thread).

Rules:
- A switched-off feature (`referrals`, `leaderboards`, `offline_codes`) fails with `feature_disabled`
  **without a network call**.
- Calls on behalf of the user (`createLink`, `myStats`, `me`, `aroundMe`, `setOptOut`, `hostedPageUrl`)
  fail with `not_identified` until `Clikgate.shared.identifyUser(customerId:identityToken:)` was called.
  If the program requires a verified identity token, the server answers `identity_required` /
  `identity_invalid`.
- Reads (`myStats`, `top`, `me`, `aroundMe`) are cached in memory for 60 s (never on disk);
  `ClikgateEngage.clearCache()` drops them, and every write clears them.
- A network error is retried once; nothing else is retried (a long `Retry-After` comes back as `rate_limited`).
- No UI components: render your own screens.

Details:
- `period` is `.current` (default), `.previous` or a period key (`.key("2026-W43")` or `"2026-W43"`).
  `limit` is clamped to 1…100 and `radius` to 1…25. `me` and `aroundMe` also take `period` and `segment`.
- Leaderboard errors: `leaderboard_not_found`, `referrer_not_found` (the user never had a referral link
  in the program), `period_not_found`, `invalid_segment`, `hosted_page_unavailable` (older server without
  `embed_url`). Link errors: `client_link_creation_disabled`, `referral_link_limit`.
- `codes.redeem` trims the code (3–30 characters; the server ignores case, spaces and dashes). Errors:
  `code_not_found`, `code_expired`, `code_disabled`, `redemption_limit_reached`, `rate_limited`
  (5/hour), or a referral error (`already_referred`, `self_referral`, …) with `error.offlineTouchId` set,
  because the touch was still recorded.
- `share.link(_:message:app:shareUrls:from:)` and `share.referralLink(_:message:app:from:)` (Change 13,
  `async`): each app Clikgate knows gets its own version of the link (a short ending so Clikgate knows where you shared it), other apps get the plain link, and the share is recorded as a share count (the app and the link; no personal data, never a click). The share sheet asks for the item per app (`UIActivityItemSource`), and its
  completion handler reports the app; Messages and Mail are named by iOS, other apps by their share
  extension. iOS reports "completed" for some apps even after a cancel inside them, so a recorded share
  means "share started". With `app`, WhatsApp (needs `whatsapp` in `LSApplicationQueriesSchemes`),
  Telegram, X and Mail open directly; other apps use the sheet. `shareUrls` takes the link's `share_urls`
  object from your backend (keyed by app, e.g. `"whatsapp"`).
- `share.whatsApp` opens `whatsapp://send?text=…`, else presents the share sheet from the top view
  controller (or `from:`). `share_unavailable` when there is nothing to present from. To open WhatsApp
  directly, list the scheme in `Info.plist` — `canOpenURL` answers `false` for unlisted schemes and Engage
  then always uses the share sheet (which offers WhatsApp too):

```xml
<key>LSApplicationQueriesSchemes</key>
<array>
    <string>whatsapp</string>
</array>
```

## 8. Push tokens and uninstall tracking

1. Turn on uninstall tracking in the dashboard.
2. **Signing & Capabilities → Push Notifications** (the `aps-environment` entitlement; `npx @clikgate/setup`
   adds it). Background Modes → Remote notifications is not needed: the check reads APNs' reply, not delivery.
3. Keep the one forward line. Users don't have to allow notifications: with `automaticPushToken` (default
   `true`) the SDK calls `registerForRemoteNotifications()` on every launch while uninstall tracking is on, tracking
   isn't opted out, the SDK version isn't blocked and consent allows it. It never asks for notification permission
   and never shows anything. A debug log says when it registered; if no token has reached the SDK by the next
   launch, a warning names the missing forward line or the missing Push Notifications capability.

```swift
func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
    Clikgate.shared.setPushToken(deviceToken: deviceToken)
}
// Using Firebase Messaging on iOS instead? Send the FCM token:
// Clikgate.shared.setPushToken(fcmToken: token)
```

4. Let Clikgate swallow its silent checks:

```swift
func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                 fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
    if Clikgate.shared.handleRemoteNotification(userInfo) { completionHandler(.noData); return }
    // ... your own handling
}
```

Clikgate's silent pushes are `{"aps":{"content-available":1},"cg":{"t":"uc"}}` (APNs), or a data message
`{"cg":"uc"}` (FCM). `Clikgate.isClikgateMessage(_:)` is a pure check you can use anywhere, including a
notification service extension. The SDK reads the APNs environment from the embedded provisioning profile.
Tokens are re-sent whenever they change. A token you pass to `setPushToken` always wins.

**Side effect.** Registering early also hands the APNs token to any other push tool in your app, which may count
the device as registered. Users still see no notifications without permission. To control push registration
timing yourself, set `ClikgateOptions(automaticPushToken: false)`, call `registerForRemoteNotifications()` when you
choose, and keep forwarding the token with `setPushToken`.

## 9. Privacy

- The SDK ships `PrivacyInfo.xcprivacy`. Collected data, none of it used for tracking:
  - device ID (installation id, push token)
  - user ID (if you call `identifyUser`)
  - product interaction (goals)
  - purchase history (goal values and payment references, when you send them)
- No required-reason APIs are used.
- No IDFA. ATT is never prompted. IDFV only for identity checks (§5b) and Apple Ads redownload linking, with consent.
- Mention the pasteboard read in your privacy policy if you opt in to `.automatic`.
- 1.2.0 removed every signal used only for probabilistic matching or fingerprinting: screen size / scale and
  the 1.1.0 jailbreak heuristics (`is_rooted`). `/install` still carries `is_emulator` (a compile-time
  Simulator flag). Details: [ios/CHANGELOG.md](../ios/CHANGELOG.md), [ios/DECISIONS.md](../ios/DECISIONS.md).

See [PRIVACY.md](PRIVACY.md).

## 10. Sample app and testing

- `ios/Sample` is a UIKit sample covering:
  - direct and deferred deep links (`/products/…` links open a product screen)
  - apply code, a referred-by banner at launch, `identify` with an optional identity token (core), and, through the Engage features, the invite link (shared to
    WhatsApp or the share sheet) and stats
  - the paste control
  - push registration
  - goals, the installation ID and opt-out
  - consent buttons (grant / deny / region hint), Firebase forwarding (enabled at launch; active only when
    the app links Firebase) and `attributionMetadata()`
- Set your SDK key, link domain and program id in `ios/Sample/Config.xcconfig` (or a git-ignored
  `Local.xcconfig`). Regenerate the project with `cd ios/Sample && xcodegen generate`.
- Unsigned simulator builds have no Keychain access, so reinstall detection needs a signed build.
- See [TESTING_DEEP_LINKS.md](TESTING_DEEP_LINKS.md).

```sh
cd ios
xcodebuild test -scheme Clikgate-Package -destination 'platform=iOS Simulator,name=iPhone 16'
# or, without booting a simulator (host Mac Catalyst run of the same unit tests, core + Engage):
xcodebuild test -scheme Clikgate-Package -destination 'platform=macOS,variant=Mac Catalyst'
./scripts/check_api.sh                  # public-API snapshots + core/Engage boundary (--update to accept)
./scripts/check_size.sh                 # size budgets: core < 410 KB, Engage < 80 KB
./scripts/build_xcframework.sh          # build/xcframework/{Clikgate,ClikgateEngage}.xcframework + size report
pod lib lint Clikgate.podspec --allow-warnings
```

## 11. Removing the SDK

1. Remove the dependency: the `Clikgate` package product (Xcode › Package Dependencies), or
   `pod 'Clikgate'` and run `pod install`, or the XCFrameworks.
2. Remove `Clikgate.configure(...)` and every `Clikgate.shared…` / `ClikgateEngage…` call (deep-link handler,
   `handle(url:)`, `continue(userActivity:)`, `goal`, `identifyUser`, consent, Firebase forwarding,
   `attributionMetadata`, `ClikgatePasteControl`).
3. Remove the app entries: the `applinks:<domain>` Associated Domains of your Clikgate link domains, the custom
   URL scheme (CFBundleURLTypes) if it was only for Clikgate, and Clikgate keys in Info.plist.
4. Remove push-token forwarding (`setPushToken`) and the `handleRemoteNotification` check (uninstall
   tracking); keep `registerForRemoteNotifications` only if your app needs it.
5. Remove Clikgate from your privacy policy and App Store privacy answers once the release without it ships.
6. In the Clikgate dashboard, mark the app as no longer tracked (and remove its APNs key) so Clikgate stops
   uninstall checks and shows no "SDK missing" warnings.

The Keychain item `com.clikgate.installation-id` and `Application Support/Clikgate` stay on devices that had
the SDK; they are deleted with the app.
