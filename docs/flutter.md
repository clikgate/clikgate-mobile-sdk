# Clikgate Flutter plugin — integration guide

`clikgate_flutter` is the **core** plugin: a thin bridge over the native Clikgate Android and
iOS SDKs for what must happen on the device (spec 0.4): deep links (direct and deferred),
install attribution, goals, `identifyUser`, `getInstallationId`, referee-side referral calls (`applyCode`,
`referredBy`), push token / uninstall tracking and feature switches. All attribution and
referral logic runs natively; the Dart API is identical on both platforms.

Referral links and stats, leaderboards, promo codes and share helpers are **not** in the core
plugin. Two ways to build those screens:

- **Recommended:** your backend calls the Clikgate control-plane API (referrers, referral stats,
  leaderboards, identity signals, goals from your server) and your app renders what it returns. The app
  only needs `clikgate_flutter`.
- **Apps without a backend:** the Engage features in the same package,
  `package:clikgate_flutter/engage.dart` (§5d). See [engage.md](engage.md) for when to
  use which.

Requirements: Flutter 3.24+ (tested with 3.35.4), Android minSdk 21, iOS 13 (build with Xcode 26 or newer).

## 1. Install

The quickest way is the setup command, in two steps from your Flutter project's folder:

```sh
flutter pub add clikgate_flutter
dart run clikgate_flutter
```

`dart run` only finds packages that are in `pubspec.yaml`, so add the package first. The second command is
the Clikgate setup command (the same program as `npx @clikgate/setup`, without Node.js): it signs you in,
configures app links on Android and iOS and adds the start-up code, showing every change before it writes
anything. The first run downloads the program for your computer once (about 41 MB; up to 55 MB on Linux and Windows), checks its SHA-256
against the checksum in this package, and keeps it in `~/.clikgate/setup/` (Windows:
`%LOCALAPPDATA%\clikgate\setup\`). `dart run clikgate_flutter:doctor` checks the setup and changes nothing.
Flags such as `--dry-run`, `--yes` or `doctor --json` work as with npx
([setup command docs](https://clikgate.com/docs/setup-command)). With fvm: `fvm dart run clikgate_flutter`.
`npx @clikgate/setup` still works if you have Node.js.

By hand: add the dependency and follow the sections below (configure, deep links, Android and iOS setup).

```yaml
dependencies:
  clikgate_flutter: ^2.1.0
```

## 2. Configure

```dart
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Clikgate.configure(
    sdkKey: 'cg_sdk_...',
    linkDomains: ['inv.myapp.com'],
    // apiBaseUrl: 'http://10.0.2.2:8000',      // local backend
    // logLevel: ClikgateLogLevel.debug,
    // attestation: ClikgateAttestation.ifAvailable,
    // pasteboardMode: ClikgatePasteboardMode.automatic,   // iOS only, opt-in (default off since 1.2.0)
    // deferredDeepLinkTimeout: const Duration(seconds: 5),
    // automaticPushToken: false,   // default true: push token for uninstall checks without app code (§6)
  );
  runApp(const MyApp());
}
```

## 3. Deep links

```dart
Clikgate.onDeepLink.listen((ClikgateDeepLink link) {
  router.go(link.path ?? '/', extra: link.data);   // link.isDeferred, link.referral, link.matchType
});

final attribution = await Clikgate.getAttribution(); // status: pending | attributed | organic
```

`onDeepLink` is a broadcast stream. Links that arrive before your first listener (e.g. the
deferred link on first launch, or the App Link that cold-started the app) are buffered and
replayed to the first subscriber, so subscribing in your root widget's `initState` is fine.

The plugin forwards App Links / Universal Links and custom-scheme opens to the native SDK
automatically (platform setup below). For URLs from elsewhere (QR codes):
`await Clikgate.handleUrl(url)`.

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
Basic install attribution (which link, campaign or creator brought each install) and goals work on every plan, up to
the plan's allowance; re-engagement and the advanced app reports need Growth. Only when attribution is
switched off for the app does the SDK run in deep-link-only mode: `Clikgate.goal(...)` then logs one warning and does
nothing (no error, nothing is sent), and attribution reads `organic`. `await Clikgate.isFeatureEnabled(ClikgateFeatures.appAttribution)` tells you which mode the app is in.
Once the monthly deferred deep link allowance is used, new installs open your home screen: the SDK gets its normal
"no deferred link" result, never an error. Links that open your app for people who already have it are sent with
the click they came from, so one tap is one click (change 21).

**Password and country-restricted links (Change 17).** App Links and Universal Links open your app without
Clikgate's redirect, so the native SDK asks the server first. A password link opens in the system browser (the
password page; `onDeepLink` stays silent). A link blocked for the visitor's country (or by a block rule) arrives
with `link.blockMessage` set and no `path`, `clickId` or `link`: show the text and don't route.

**Shared-domain links of other organisations (1.4.0).** `ciz.to`, `clk.ng`, `clkg.to` and
`dev.ciz.to` are shared by many Clikgate customers. When one of their links opens your app but the
server says it isn't yours, the native SDK opens it in an in-app browser (Custom Tabs /
`SFSafariViewController`) and `onDeepLink` stays silent. Observe it with:

```dart
Clikgate.onBrowserHandoff.listen((h) => debugPrint('handed off ${h.host}'));   // h.url, h.host
```

`Clikgate.configure(..., platformDomainBrowserFallback: false)` turns it off. Custom domains and
matched links are unaffected.

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

```dart
// Before: firebase_dynamic_links
final initial = await FirebaseDynamicLinks.instance.getInitialLink();
if (initial != null) router.go(initial.link.path);
FirebaseDynamicLinks.instance.onLink.listen((data) => router.go(data.link.path));

// After: clikgate_flutter (configure once at startup, section 2). One stream for the link that started the app,
// later links and the deferred link after install.
Clikgate.onDeepLink.listen((link) {
  if (link.blockMessage != null) return showNotice(link.blockMessage!);
  router.go(link.path ?? '/', extra: link.data);   // link.isDeferred is true for the first launch after install
});
```

Then remove `firebase_dynamic_links` from `pubspec.yaml`, the `page.link` intent filter (Android) and Associated
Domains entry (iOS), and add your Clikgate link domains (sections 7 and 8). Firebase Analytics, Crashlytics and
Messaging are unaffected. Test with "See it live" in the dashboard (Developers › SDKs) and a `cg_sdk_test_…` key.

## 4. Identify your users, opt-out

Optional: you need it for labels and the person timeline, referrals and leaderboards that need a verified user, and
"existing customer" checks. Anonymous users are tracked by click or installation without it. The customer ID is your
own internal user ID (never an email, phone, BVN or NIN), the same on app, website and server. Full guide:
https://clikgate.com/docs/identify-users

**Path A: identity token (the default).** Your server makes the token in one line with the server SDK (Node
`createIdentityToken`, Python `create_identity_token`, PHP `\Clikgate\IdentityToken::create`, Java / .NET
`IdentityTokens.create` / `Create`; the secret is `CLIKGATE_IDENTITY_SECRET`, or `CLIKGATE_IDENTITY_SECRETS` for
several apps, on the server only) and returns it in the sign-in response and the "current user" response the app
already calls at open. The app passes the newest token:

```dart
await Clikgate.identifyUser(customerId: user.id, identityToken: me.clikgateToken); // after sign-in, and at app open
await Clikgate.identifyUser(label: 'Ada (VIP)');   // just the label (the customer ID is kept; Growth and up)
await Clikgate.identifyUser(customerId: null);     // sign-out
await Clikgate.setTrackingEnabled(false);          // opt-out
```

The token is `base64url_nopad(HMAC_SHA256(identity_secret, "<customer_user_id>.<issued_at>")) + "." + issued_at`,
always made on your server, never in the app. It lasts 30 days by default; no forced refresh.

**Path B: installation ID (no secret, no token).** The app sends this installation's ID with the sign-in request
(and at every signed-in app open); your server calls the server SDK's
`identifyUser({appId, installationId, customerId, label?})`:

```dart
final String? installationId = await Clikgate.getInstallationId();
await api.signIn(email, password, clikgateInstallationId: installationId);
```

`getInstallationId()` returns the random UUID the native SDK created at first launch and sends with every call (not
personal data; allowed in private mode). Right after `configure` it waits for the first launch's config answer (a few
seconds at most; offline it answers at once). A reinstall gets a new ID. It returns `null` when tracking is off
(`setTrackingEnabled(false)`, consent denied or not given yet where it's required, or deep-link-only mode): your
server then skips `identifyUser`.

Fraud signals (`is_emulator`, `is_rooted`, the Play install-referrer times) are collected by the
native SDKs on `/install` (native 1.1.0+); there is nothing to call or configure from Dart. See
[android.md §8](android.md#8-privacy-and-opt-out) and [ios.md §9](ios.md#9-privacy).

## 4a. Track your end goal

```dart
final result = await Clikgate.goal('account_opened',
    value: 2000000, currency: 'NGN', reference: 'APP-55231', isFirst: true);
// result.status: GoalStatus.counted, .waiting, .received or .refused (section 4b)
await Clikgate.goal('order_paid', value: '1500.50', currency: 'USD', reference: 'ORD-1001');
```

**Never put customer data in goal calls; use the business's reference only.** No names, emails,
phone numbers, account numbers or user ids in the key or the reference: `reference` is your own id
for the event (application number, order id, transaction reference).

- **Key:** snake_case, 2–40 characters (`^[a-z][a-z0-9_]*$`), one of the goals defined in the
  Clikgate dashboard (Settings › Goals). An unknown or archived goal is rejected by the server and
  dropped.
- **Value** (optional): normal units, never kobo or cents (₦2,000,000 is `2000000`), ≥ 0, at most
  15 significant digits; an `int`, a `double` or a numeric `String` (pass a string for exact amounts: it reaches the native SDK as a decimal string, never a double; doubles Dart prints with an exponent are rejected). Whether a value is allowed or required, and how many decimal
  places the currency allows, is checked by the server (rejected goals are dropped and logged).
- **Currency** (optional): ISO 4217; omitted = the goal's default currency.
- **Reference:** 1–128 characters. Omit it and the SDK generates a UUID, which only protects
  against double sends from the app: your backend can't refer to it later (reversals, refunds), so
  pass your own when you have one. A second goal with the same key and reference is ignored.
- **isFirst** (optional): your statement that this is the customer's first such event (for
  "click to first purchase"). Clikgate never checks it against an identity.
- Delivery: queued, batched and retried natively (the offline queue), attributed to the latest Clikgate link
  that opened the app, else the install. `goal()` is the only method for what happens in your app. Consent: while
  consent is required and `attribution` is unknown, goals wait on the device (up to 7 days); on deny
  they're dropped.
- **Private mode** (an organisation setting for banks, insurers, lenders and health): `goal()`
  works as usual, while the customer ID of `identifyUser()` is not sent (labels only when your organisation allows labels in private mode) (one warning
  in debug builds). Send outcomes and values through `goal()`.
- Goals completed on your server (a loan disbursed days later) should be sent by your backend
  (`POST /v1/goals/events`) with the click id from `attributionMetadata()`, saved with your own
  application when the user starts it.

## 4b. Payment goals

One method, `goal()`, sends every goal. Whether a goal is a **Standard goal** or a **Payment goal** is set in the
dashboard (Settings › Goals), never in the call. For a Payment goal, pass the payment provider and the
reference your checkout returned:

```dart
// In your checkout success callback (Paystack, Flutterwave, Monnify, Stripe, ...):
final result = await Clikgate.goal('purchase',
    reference: transaction.reference, provider: ClikgateProvider.paystack);
// result.status == GoalStatus.waiting, result.reason == 'waiting_for_confirmation'
```

- `Clikgate.goal(key, {value, currency, reference, provider, isFirst})` → `Future<GoalResult>`: `provider` is a payment provider: `ClikgateProvider.paystack`, `ClikgateProvider.mtnMomo`, … (`ClikgateProvider.values`), or `ClikgateProvider.fromString('newpay')` for a provider added after this SDK release
  (the server checks it and refuses unknown ones with `unknown_provider`).
- **A Payment goal waits for its confirmation.** The app can't make a payment count. Clikgate counts it only
  when a trusted source confirms the same reference: your server right after its own verification (the server
  SDKs' `goal()` or payment helpers), a gateway webhook, or the WordPress plugin / Shopify app. The amount and
  currency come from that confirmation: a `value` sent from the app is ignored (`valueIgnored: true`). Without
  `provider` or `reference` the goal is refused with `payment_goal_needs_confirmation`.
- **The result:** `status` is `GoalStatus.counted`, `GoalStatus.waiting`, `GoalStatus.received` (stored, not
  counted: the name isn't ticked as a goal in the dashboard yet, `not_counted_yet`, or the goal is archived,
  `goal_archived`; a success, never retried) or `GoalStatus.refused`; `reason` is null when counted, else a code such as
  `waiting_for_confirmation`, `pending_click`, `unattributed`, `outside_window`, `already_counted`,
  `payment_goal_needs_confirmation`, `unknown_goal`, `unknown_provider` or `invalid_argument` (bad input, checked on the
  device); `goalKind` is `GoalKind.standard` / `GoalKind.payment` when Clikgate said; `valueIgnored` says a value was dropped. `goal()`
  never throws: errors come back as refused results. The result arrives once Clikgate has answered: while the
  device is offline the goal stays queued (and the result pending), so don't block your UI on it.
- With a test SDK key (`cg_sdk_test_...`) the native SDK logs one line when a goal is waiting for its
  payment confirmation ("purchase is a Payment goal: waiting for confirmation") and when a value was
  ignored.
- Queued, retried and consent-buffered like every goal, idempotent by key and reference, unchanged in private
  mode. It works on every plan (basic app attribution is included).

## 5. Referrals (referee side)

```dart
const programId = 'rpg_...';

try {
  final referral = await Clikgate.referrals.applyCode(programId: programId, code: 'ADA42');
} on ClikgateException catch (e) {
  switch (e.code) {
    case 'code_not_found': ...
    case 'already_referred': ...
    case 'window_expired': ...
    case 'self_referral': ...
  }
}

final info = await Clikgate.referrals.referredBy();   // info.referred, info.referral
```

`ClikgateException` has `code` (backend code or `not_configured`, `network_error`, `opted_out`,
`invalid_argument`, `timeout`, `install_pending`, `unsupported_platform`, `feature_disabled`),
`message`, `status` (HTTP), `param`, `feature` (for `feature_disabled`) and `offlineTouchId`
(Engage `codes.redeem`).

The user's own link and stats (referrer side) come from your backend, or from the
Engage features (§5d).

## 5a. Feature switches

```dart
if (await Clikgate.isFeatureEnabled(ClikgateFeatures.leaderboards)) { /* show the tab */ }
```

Read from the native SDK's cached config. Calls of a switched-off feature (core
`referrals.*`, and every Engage call) throw `ClikgateException(code: 'feature_disabled',
feature: ...)` without a network call (also when the server answers with its
`feature_disabled` no-op body). Before the first config: `referrals`, `leaderboards`,
`offline_codes`, `app_attribution` on, the rest off.

## 5d. Engage features (`package:clikgate_flutter/engage.dart`, apps without a backend)

Nothing extra to install: the Engage features are in `clikgate_flutter` (since 2.1.0; there is no
separate `clikgate_engage` package). Import them with
`import 'package:clikgate_flutter/engage.dart';`. Apps that never import it don't ship it
(tree-shaking).

Pure Dart (package `http`; `share_plus` and `url_launcher` for the share helpers), apart from the
share menu (below). It calls the same `/v1/sdk/*` endpoints with the core plugin's request context
(installation id, SDK key, environment, base URL, identity token), obtained through the core's
internal `Clikgate.getRequestContext()`; it keeps no attribution state.

```dart
final engage = ClikgateEngage();

// Referrer side (needs Clikgate.identifyUser)
final link = await engage.referrals.createLink(programId: programId, displayName: 'Ada');   // code, url, shortUrl
final stats = await engage.referrals.myStats(programId: programId);    // clicks, installs, signups, inProgress, qualified, ...
await engage.share.referralLink(link, message: 'Join me on MyApp:');   // share menu; each app gets its own version
final opened = await engage.share.link('https://inv.myapp.com/summer', app: ShareApp.whatsapp);   // false = menu used
await engage.share.system(text: 'Join me on MyApp: ${link.url}');      // plain text, nothing recorded

// Leaderboards (build your own UI)
const board = 'lb_...';
final page = await engage.leaderboards.top(board, period: LeaderboardPeriod.current, limit: 50);
// page.name, page.metric, page.period (key, status, startsAt, endsAt), page.entries (rank, display, score, pending, isMe)
final w42 = await engage.leaderboards.top(board, period: const LeaderboardPeriod.key('2026-W42'));
final me = await engage.leaderboards.me(board);          // rank (null = not ranked), score, pending, gapToNext, bestRank, periodEndsAt, optedOut
final around = await engage.leaderboards.aroundMe(board, radius: 5);   // name/metric null
await engage.leaderboards.setOptOut(programId: programId, optOut: true);
final embedUrl = await engage.leaderboards.hostedPageUrl(board);       // signed hosted-page URL for a web view

// Promo / offline codes typed in the app
try {
  final r = await engage.codes.redeem('LAGOS50');   // r.offlineTouchId, r.code.kind ('link' | 'referral'), r.referral
} on ClikgateException catch (e) {
  // code_not_found, code_expired, code_disabled, redemption_limit_reached, rate_limited,
  // invalid_argument (not 3-30 chars), feature_disabled, referral errors (e.offlineTouchId set)
}
```

Rules (spec 17A.3):

- Every network call checks `Clikgate.isFeatureEnabled` first: `feature_disabled` without a
  network call.
- `createLink`, `myStats`, `me`, `aroundMe`, `setOptOut` and `hostedPageUrl` act for the user:
  `not_identified` (no network call) until `Clikgate.identifyUser` was called. Programs with
  `require_identity_token` answer `identity_required` from the server until a valid token was
  passed to `identify`. `top` and `codes.redeem` don't need a user.
- Reads (`myStats`, `top`, `me`, `aroundMe`) are cached in memory for 60 s per installation and
  user; writes (`createLink`, `setOptOut`, `redeem`) and `engage.clearCache()` drop the cache.
  Nothing is persisted. `hostedPageUrl` is never cached (short-lived token).
- At most one retry, for network errors only (no retry on HTTP errors such as 429/5xx).
- Leaderboard errors: `leaderboard_not_found`, `referrer_not_found`, `period_not_found`,
  `invalid_segment`, `identity_invalid`; `hosted_page_unavailable` when the server returns no
  `embed_url`. Share: `share_unavailable` when not even the share sheet can be shown.
- Ranks are live server-side; poll while the screen is visible and call `clearCache()` before
  an explicit refresh (the example refreshes every 15 s).

`share.link(url, {message, app, shareUrls})` / `share.referralLink(link, {message, app})` (Change 13):
each app Clikgate knows gets its own version of the link (a short ending so Clikgate knows where you shared it), other apps get the plain link, and the share is recorded as a share count (the app and the link; no personal data, never a click). They use the native SDK's Engage share menu (the plugin's
`com.clikgate/engage` channel, over `com.clikgate.engage` on Android and `ClikgateEngage` on iOS; everything else stays Dart),
so the behaviour is the [Android](android.md) and [iOS](ios.md) one. With CocoaPods nothing extra is
needed; the monorepo example substitutes the native SDK from `../../android`.

Share helper setup:

- **iOS:** listing `whatsapp` in `LSApplicationQueriesSchemes` (`ios/Runner/Info.plist`) is
  recommended (the native SDKs and docs use it), but the Dart helper doesn't depend on it:
  `url_launcher` opens the URL with `UIApplication.open` (no `canOpenURL`), and a failed open
  falls back to the share sheet.
- **Android:** nothing required. `whatsapp://send?text=` is opened with
  `url_launcher.launchUrl`, which needs no `<queries>` entry (only `canLaunchUrl` would); if no
  app handles it, the share sheet (`share_plus`) is used. Unlike the native Android Engage
  module, the Dart helper can't target WhatsApp Business by package name.

## 5e. Consent, Firebase forwarding and sales metadata (1.2.0, change 03)

The native SDKs implement the behaviour (shared/SDK_BEHAVIOUR.md "Change 03"); the plugin only
passes the calls through.

```dart
// Call from your consent banner. Omitted purposes stay unchanged; all are unknown until set.
await Clikgate.setConsent(
  analytics: ConsentState.granted,       // usage measurement, Firebase forwarding
  attribution: ConsentState.granted,     // link installs and conversions to their source
  adUserData: ConsentState.denied,       // send user data to ad platforms
  adPersonalization: ConsentState.denied,
);
await Clikgate.setConsentRegion('DE');  // optional hint (EEA, UK or ISO country); else the IP country
final c = await Clikgate.getConsent();   // c.required: true / false / null (unknown yet)
```

- Where consent is required (the app's Clikgate consent mode; EEA, UK and Switzerland by
  default) and `attribution` is `unknown`, the SDK sends nothing identifying: goals are buffered
  on the device (up to 7 days or 1,000 goals), Clikgate links still open the right screen
  (delivered locally), and everything is sent once `attribution` is granted. `denied` drops the
  buffer. Consent travels with every request.
- `setConsent` / `setConsentRegion` may be called before `configure` (put them first when you
  already know the answer).
- `Clikgate.enableFirebaseForwarding(...)` (call on every launch): `clikgate_attribution` once per
  install, user properties `cg_first_source` / `cg_first_campaign`, and
  the Firebase app instance id for server-side GA4. Needs `firebase_analytics` in the app (detected
  natively, no dependency of this plugin), GA4 forwarding enabled for the app in Clikgate, and
  `analytics` consent.
- `Clikgate.attributionMetadata()` → `{cg_click_id, cg_link_id}` for Paystack `metadata` /
  Flutterwave `meta`; empty when nothing is attributed or consent doesn't allow it.
- `Clikgate.enableGoogleOnDeviceMeasurement()` (iOS only, no-op on Android): with Google's
  `GoogleAdsOnDeviceConversion` pod in the app, the on-device measurement info goes with the first
  install. Call it before `configure`.
- Google click ids (`gclid`, `gbraid`, `wbraid`) in Clikgate links and the Android install
  referrer are picked up natively; nothing to do in Dart. LinkedIn `li_fat_id`, Snap `ScCid` and X `twclid` reach Clikgate
  in the same links and referrer when your app passes ad click IDs. On iOS the Apple Ads token is requested
  when the install is sent (after consent when it is required) and never kept on the device.

## 6. Push token and uninstall tracking

1. Turn on uninstall tracking in the dashboard.
2. iOS: add the Push Notifications capability (the `aps-environment` entitlement; `npx @clikgate/setup` adds it).
   No AppDelegate code: the plugin is an application delegate and passes the APNs token to the SDK itself.
3. Android: nothing, when `firebase_messaging` (Firebase Messaging) is in the app.

Users don't have to allow notifications. With `automaticPushToken` (default `true`), while uninstall tracking is
on, tracking isn't opted out, the SDK version isn't blocked and consent allows it, the SDK gets a push token on
every launch: on iOS it calls `registerForRemoteNotifications()` and the plugin receives the token through
Flutter's official app-delegate callback (no swizzling; `firebase_messaging` gets the same callback, so both keep
working); on Android it fetches the FCM token when Firebase Messaging is in the app. It never asks for notification
permission and never shows anything.

A token you pass with `setPushToken` always wins. On iOS, once Dart has passed a token the plugin stops passing on
the APNs token (so an FCM token and the APNs token don't take turns).

```dart
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  if (Clikgate.isClikgateMessage(message.data)) return;   // pure Dart: works in this isolate
  // your handling
}

// after Firebase.initializeApp():
FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
FirebaseMessaging.onMessage.listen((m) {
  if (Clikgate.isClikgateMessage(m.data)) return;
  // your handling
});
// Optional: send the FCM token yourself (it wins over the automatic one).
// await Clikgate.setPushToken(await FirebaseMessaging.instance.getToken(), provider: PushProvider.fcm);
// FirebaseMessaging.instance.onTokenRefresh.listen((t) => Clikgate.setPushToken(t, provider: PushProvider.fcm));
```

Clikgate's silent uninstall checks (`{"cg": "uc"}`) must never produce a notification.

**Side effect.** Registering early also hands the push token to any other push tool in your app, which may count
the device as registered. Users still see no notifications without permission. To control push registration
timing yourself, pass `automaticPushToken: false` to `configure` and call `setPushToken` (FCM token, or the hex
APNs token with `provider: PushProvider.apns`) when you choose.

## 7. Android setup

1. **Intent filters** on your `MainActivity` (keep `launchMode="singleTop"` from the Flutter
   template, so warm-start links arrive through `onNewIntent`):

   ```xml
   <activity android:name=".MainActivity" android:launchMode="singleTop" ...>
       <!-- Let Clikgate handle links instead of Flutter's built-in deep-link router -->
       <meta-data android:name="flutter_deeplinking_enabled" android:value="false" />

       <intent-filter android:autoVerify="true">
           <action android:name="android.intent.action.VIEW" />
           <category android:name="android.intent.category.DEFAULT" />
           <category android:name="android.intent.category.BROWSABLE" />
           <data android:scheme="https" />
           <data android:host="inv.myapp.com" />
       </intent-filter>
       <intent-filter>
           <action android:name="android.intent.action.VIEW" />
           <category android:name="android.intent.category.DEFAULT" />
           <category android:name="android.intent.category.BROWSABLE" />
           <data android:scheme="myapp" />
       </intent-filter>
   </activity>
   ```

   **Several link domains**: when your Clikgate domain group has aliases (e.g. `ybr.ng` and
   `go.yourbrand.com`, the same links on both), list **every** domain in `linkDomains`, add one
   `<data android:host="..." />` per domain to the `autoVerify` filter and one `applinks:<domain>`
   per domain to the iOS Associated Domains ([iOS setup](flutter_ios_setup.md)). Clikgate serves `apple-app-site-association` and `assetlinks.json` on every active domain of the group, but the OS opens your app only for the domains the app itself declares. The SDK also adds the domains the server lists in `/v1/sdk/config` (`link_domains`, cached with the config, compared case-insensitively) and logs a warning naming each server domain missing from `linkDomains`: add it to `linkDomains` and to the intent filter / Associated Domains.

   To keep the domain out of the manifest, use a placeholder
   (`android:host="${clikgateLinkDomain}"` + `manifestPlaceholders["clikgateLinkDomain"] = "inv.myapp.com"`
   in `app/build.gradle.kts`), as the example app does.

2. **Intent forwarding is automatic.** The plugin is `ActivityAware`: it hands the launch intent
   to the SDK when the activity attaches (kept until `Clikgate.configure` runs in Dart) and
   every `onNewIntent`. You don't need to override anything in `MainActivity`. If you also call
   `Clikgate.handleIntent` natively, each intent is still processed once.

3. **App Link verification**: Clikgate serves `assetlinks.json` for your link domain from the
   app's package name and signing-certificate SHA-256 fingerprints (add the Play App Signing
   key). Check with `adb shell pm get-app-links <applicationId>`.

4. **minSdk** 21 (the SDK) — `firebase_messaging` needs at least 23 (24 for newer releases).

5. **Backup**: if your app declares `android:fullBackupContent` / `android:dataExtractionRules`,
   `npx @clikgate/setup` adds Clikgate's excludes and `tools:replace`; by hand, see
   [android.md §8](android.md#8-privacy-and-opt-out).

6. **Cleartext for a local backend**: `apiBaseUrl: 'http://10.0.2.2:8000'` needs a debug
   network security config allowing cleartext to `10.0.2.2`.

### Native SDK dependency

The plugin's Android side depends on `com.clikgate:clikgate-android` (same version as the
plugin), resolved from Maven Central. Nothing to configure for published versions.

Developing against an unpublished SDK:

- **This monorepo**: `flutter/example/android/settings.gradle.kts` includes `../../../android`
  as a Gradle composite build and substitutes the module with the `:clikgate` project, so the
  example always builds the native SDK from source. Pass `-Pclikgate.useLocalSdk=false` to use
  the published artifact.
- **Another app**: either add the same block to your `android/settings.gradle.kts`

  ```kotlin
  includeBuild("/path/to/clikgate_mobile_sdk/android") {
      dependencySubstitution {
          substitute(module("com.clikgate:clikgate-android")).using(project(":clikgate"))
      }
  }
  ```

  (your app must use AGP 8.9.1 / Kotlin 2.1.0 like the SDK build, since Gradle can't mix AGP
  versions in one build), or publish locally (`cd android && ./gradlew :clikgate:publishToMavenLocal`)
  and set `clikgate.useMavenLocal=true` in your app's `android/gradle.properties`.

## 8. iOS setup

Associated Domains (Universal Links), the Push Notifications capability, the
`UISceneDelegate` forwarding for scene-based apps, pasteboard modes and APNs tokens are
covered in [flutter_ios_setup.md](flutter_ios_setup.md).

## 9. Example app (two variants)

`flutter/example` is the primary demo. It builds in two variants (spec 17A.4), chosen at build
time with `--dart-define=CLIKGATE_VARIANT=backend|engage` (default `backend`). The value is a
compile-time constant, so the unused implementation is tree-shaken; one entrypoint
(`lib/main.dart`) and one Android / iOS project serve both.

Same in both variants (core `clikgate_flutter` only): product deep link screen (`/products/…`,
direct and deferred), referral welcome screen, apply-code screen, referred-by banner on the home
screen, `firebase_messaging` token registration (optional, below).

| | `backend` (recommended path) | `engage` (no backend) |
|---|---|---|
| Sign-in | Demo login on [`samples/backend`](../samples/backend/README.md) → session + identity token → `Clikgate.identifyUser(customerId: id, identityToken:)` | `Clikgate.identifyUser(customerId: id)` (no token: the program must not require one) |
| Invite link, share, stats | `GET /me/referral-link`, `/me/referral-stats` (the backend calls `/v1/referral-programs/{id}/referrers`) | `engage.referrals.createLink` / `myStats`, `engage.share.system` / `whatsApp` |
| Weekly leaderboard (live ranks, "my rank", around me) | `GET /leaderboards/{id}`, `/me`, `/around-me` (backend calls `/v1/leaderboards/{id}/entries`, `/referrers/{id}`, `/entries/around/{id}`) | `engage.leaderboards.top` / `me` / `aroundMe`, plus the "hide me" switch (`setOptOut`) |
| Promo codes | not in the app (a backend redeems with `POST /v1/codes/redeem`) | `engage.codes.redeem` screen |
| "Buy something" | `POST /orders` → the `purchase` goal from the server (`POST /v1/goals/events`, credited to the installation from `getInstallationId()`) | `Clikgate.goal('purchase', …)` from the app |

The screens are shared: they use a small `ReferralFeatures` interface
(`lib/src/variants/features.dart`) with `BackendFeatures` (package `http`) and `EngageFeatures`
(the Engage features). The leaderboard screen polls every 15 s while visible and clears client
caches first (Engage keeps reads for 60 s).

```sh
# Backend variant: start samples/backend first (see its README), then
cd flutter/example
flutter run \
  --dart-define=CLIKGATE_VARIANT=backend \
  --dart-define=SAMPLE_BACKEND_URL=http://10.0.2.2:8080 \
  --dart-define=CLIKGATE_SDK_KEY=cg_sdk_... \
  --dart-define=CLIKGATE_API_BASE_URL=http://10.0.2.2:8000 \
  --dart-define=CLIKGATE_LINK_DOMAIN=inv.myapp.com \
  --dart-define=CLIKGATE_PROGRAM_ID=rpg_... \
  --dart-define=CLIKGATE_LEADERBOARD_ID=lb_... \
  -Pclikgate.linkDomain=inv.myapp.com

# Engage variant (no backend): same, with
#   --dart-define=CLIKGATE_VARIANT=engage   (SAMPLE_BACKEND_URL not needed)
# optional push: --dart-define=FIREBASE_API_KEY=... FIREBASE_APP_ID=... FIREBASE_MESSAGING_SENDER_ID=... FIREBASE_PROJECT_ID=...
```

`SAMPLE_BACKEND_URL` defaults to `http://10.0.2.2:8080` (the host from the Android emulator); use
`http://localhost:8080` on the iOS simulator. In the backend variant `CLIKGATE_PROGRAM_ID` is used
only by the apply-code screen; the invite link and stats use the backend's program.

Push is optional in both variants: without the `FIREBASE_*` defines Firebase is not initialised,
push setup is skipped (the home screen says so) and no `google-services.json` /
`GoogleService-Info.plist` is needed.

Widget tests cover both variants (`flutter test`): `test/backend_variant_test.dart` against a
fake of the sample backend's HTTP API, `test/engage_variant_test.dart` with a fake core and
mocked `/v1/sdk/*` responses, `test/core_screens_test.dart` for the shared core screens.

Integration tests against a sandbox backend (skipped unless `CLIKGATE_API_BASE_URL` is set):

```sh
flutter test integration_test --dart-define=CLIKGATE_API_BASE_URL=http://10.0.2.2:8000 \
  --dart-define=CLIKGATE_SDK_KEY=cg_sdk_... --dart-define=CLIKGATE_PROGRAM_ID=rpg_...
```
