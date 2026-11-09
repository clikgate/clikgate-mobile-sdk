# Clikgate React Native — integration guide

`@clikgate/react-native` (core) is a thin bridge over the native Clikgate Android and iOS SDKs: deep
links (direct and deferred), install attribution, goals, identifyUser, `getInstallationId`, referee-side referral calls
(`applyCode`, `referredBy`), feature switches and uninstall tracking. All attribution and referral logic
runs natively; the TypeScript API is identical on both platforms and mirrors the Flutter plugin.

Referrer-side features (the user's referral link and stats, share helpers, leaderboards, promo codes)
are **not** in the core package (spec v3 §0.4):

- **Recommended:** your backend calls the Clikgate control-plane API (referrers, referral stats,
  leaderboards, identity signals, goals from your server) and your app renders its own screens from it.
- **Apps without a backend:** the optional Engage add-on `@clikgate/react-native-engage` (pure TypeScript,
  section 5b). See [engage.md](engage.md) for when to use which.

Requirements: React Native 0.76+ with the **New Architecture** (the module is a TurboModule; tested with
0.86.3), Android minSdk 24 (React Native's; the SDK itself supports 21), iOS 15.1 (React Native's; the SDK
supports 13). Expo: SDK 52+ with a development build / `expo prebuild` (not Expo Go). Old-architecture
apps are not supported.

## 1. Install

```sh
npm install @clikgate/react-native
cd ios && pod install
```

Autolinking adds the Android module (depends on `com.clikgate:clikgate-android` from Maven Central) and
the pod `clikgate-react-native` (depends on the `Clikgate` pod from CocoaPods trunk).

**Expo**: add the config plugin, then `npx expo prebuild` (section 7).

## 2. Configure

Call once, as early as possible — e.g. in `index.js` before `AppRegistry.registerComponent`:

```ts
import { Clikgate } from '@clikgate/react-native';

Clikgate.configure({
  sdkKey: 'cg_sdk_...',
  linkDomains: ['inv.myapp.com'],
  // apiBaseUrl: 'http://10.0.2.2:8000',    // local backend
  // logLevel: 'debug',
  // attestation: 'ifAvailable',
  // pasteboardMode: 'off',                  // iOS only: 'off' (default since 1.2.0) | 'automatic' | 'pasteControlOnly'
  // waitForATT: false,                      // iOS only
  // deferredDeepLinkTimeoutMs: 5000,
}).catch(console.warn);
```

## 3. Deep links

```ts
useEffect(
  () =>
    Clikgate.onDeepLink((link) => {
      // link.path, link.data, link.isDeferred, link.referral, link.matchType, link.link
      navigation.navigate(screenFor(link.path), link.data);
    }),
  []
); // onDeepLink returns the unsubscribe function

const attribution = await Clikgate.getAttribution(); // status: 'pending' | 'attributed' | 'organic'
```

Links that arrive before your first listener (the deferred link on first launch, or the link that
cold-started the app) are buffered (latest 10) and replayed to the first listener, so subscribing in your
root component's `useEffect` is fine. For URLs from elsewhere (QR codes): `await Clikgate.handleUrl(url)`.

App Links / Universal Links / custom-scheme opens are forwarded to the SDK by the platform setup below.

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
nothing (no error, nothing is sent), and attribution reads `organic`. `await Clikgate.isFeatureEnabled('app_attribution')` tells you which mode the app is in.
Once the monthly deferred deep link allowance is used, new installs open your home screen: the SDK gets its normal
"no deferred link" result, never an error. Links that open your app for people who already have it are sent with
the click they came from, so one tap is one click (change 21).

**Password and country-restricted links (Change 17).** App Links and Universal Links open your app without
Clikgate's redirect, so the native SDK asks the server first. A password link opens in the system browser (the
password page; `onDeepLink` isn't called). A link blocked for the visitor's country (or by a block rule) arrives
with `link.blockMessage` set and no `path`, `clickId` or `link`: show the text and don't route.

**Shared-domain links of other organisations (1.5.0).** `ciz.to`, `clk.ng`, `clkg.to` and
`dev.ciz.to` are shared by many Clikgate customers. When one of their links opens your app but the
server says it isn't yours, the native SDK opens it in an in-app browser (Android Custom Tabs, iOS
`SFSafariViewController`) and `onDeepLink` isn't called. Observe it with:

```ts
useEffect(() => Clikgate.onBrowserHandoff((h) => console.log('handed off', h.host)), []); // h.url, h.host
```

`Clikgate.configure({ ..., platformDomainBrowserFallback: false })` turns it off. Custom domains and
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
| create links with `buildShortDynamicLink` or the REST API | create links in the dashboard, with the Clikgate API (`POST /v1/links`, server SDKs `links.create`) or, without a backend, the Engage add-on's referral links |
| read `link` from the received dynamic link | read `path` and `data` from the Clikgate deep link (`url` is the link that opened the app) |
| deferred link on first launch through the same callback | the same: the deferred link arrives on `onDeepLink` with `isDeferred` set |
| `utm_*` and `st` / `sd` / `si` link parameters | the link's tags and preview, set when the link is created (the import maps them) |

```ts
// Before: @react-native-firebase/dynamic-links
useEffect(() => {
  dynamicLinks().getInitialLink().then((link) => link && navigateTo(link.url));
  return dynamicLinks().onLink((link) => navigateTo(link.url));
}, []);

// After: @clikgate/react-native (configure once at startup, section 2). One listener for the link that started
// the app, later links and the deferred link after install.
useEffect(
  () =>
    Clikgate.onDeepLink((link) => {
      if (link.blockMessage) return showNotice(link.blockMessage);
      navigation.navigate(screenFor(link.path), link.data); // link.isDeferred is true for the first launch after install
    }),
  []
);
```

Then remove `@react-native-firebase/dynamic-links`, the `page.link` intent filter (Android) and Associated Domains
entry (iOS), and add your Clikgate link domains (sections 7 to 9; the Expo config plugin writes them). Firebase
Analytics, Crashlytics and Messaging are unaffected. Test with "See it live" in the dashboard (Developers › SDKs)
and a `cg_sdk_test_…` key.

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

```ts
import { Clikgate } from '@clikgate/react-native';

await Clikgate.identifyUser({ customerId: user.id, identityToken: me.clikgateToken }); // after sign-in, and at app open
await Clikgate.identifyUser({ label: 'Ada (VIP)' });  // just the label (the customer ID is kept; Growth and up)
await Clikgate.identifyUser({ customerId: null });    // sign-out
await Clikgate.setTrackingEnabled(false);             // opt-out
```

The token is `base64url_nopad(HMAC_SHA256(identity_secret, "<customer_user_id>.<issued_at>")) + "." + issued_at`,
always made on your server, never in the app. It lasts 30 days by default; no forced refresh.

**Path B: installation ID (no secret, no token).** The app sends this installation's ID with the sign-in request
(and at every signed-in app open); your server calls the server SDK's
`identifyUser({appId, installationId, customerId, label?})`:

```ts
const installationId: string | null = await Clikgate.getInstallationId();
await api.signIn({ email, password, clikgateInstallationId: installationId });
```

`getInstallationId()` returns the random UUID the native SDK created at first launch and sends with every call (not
personal data; allowed in private mode). Right after `configure` it waits for the first launch's config answer (a few
seconds at most; offline it answers at once). A reinstall gets a new ID. It returns `null` when tracking is off
(`setTrackingEnabled(false)`, consent denied or not given yet where it's required, or deep-link-only mode): your
server then skips `identifyUser`.
On iOS these calls reject with `not_configured` before `configure`; on Android they are queued until `configure`.

Fraud signals (`is_emulator`, `is_rooted`, the Play install-referrer times) are collected by the
native SDKs on `/install` (native 1.1.0+; from 1.2.0 the iOS SDK no longer sends `is_rooted`, and uses
App Attest / DeviceCheck instead); there is nothing to call or configure from JavaScript. See
[android.md §8](android.md#8-privacy-and-opt-out) and [ios.md §9](ios.md#9-privacy).

## 4a. Track your end goal

```ts
const result = await Clikgate.goal('account_opened', {
  value: 2000000,
  currency: 'NGN',
  reference: 'APP-55231',
  isFirst: true,
});
await Clikgate.goal('order_paid', { value: '1500.50', currency: 'USD', reference: 'ORD-1001' });
// result.status: GoalStatus.Counted, Waiting, Received or Refused (section 4b)
```

**Never put customer data in goal calls; use the business's reference only.** No names, emails,
phone numbers, account numbers or user ids in the key or the reference: `reference` is your own id
for the event (application number, order id, transaction reference).

- **Key:** snake_case, 2–40 characters (`^[a-z][a-z0-9_]*$`), one of the goals defined in the
  Clikgate dashboard (Settings › Goals). An unknown or archived goal is rejected by the server and
  dropped.
- **Value** (optional): normal units, never kobo or cents (₦2,000,000 is `2000000`), ≥ 0, at most
  15 significant digits; a `number` or a numeric `string` (pass a string for exact amounts: it reaches the native SDK as a decimal string, never a double; numbers JavaScript prints with an exponent are rejected). Whether a value is allowed or required, and how many decimal
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

```ts
import { Clikgate, ClikgateProvider, GoalStatus } from '@clikgate/react-native';

// In your checkout success callback (Paystack, Flutterwave, Monnify, Stripe, ...):
const result = await Clikgate.goal('purchase', {
  reference: transaction.reference,
  provider: ClikgateProvider.Paystack,
});
// result.status === GoalStatus.Waiting, result.reason === 'waiting_for_confirmation'
```

- `Clikgate.goal(key, {value, currency, reference, provider, isFirst})` → `Promise<GoalResult>`: `provider` is a payment provider: `ClikgateProvider.Paystack`, `ClikgateProvider.MtnMomo`, … (`CLIKGATE_PROVIDERS`), or `providerFromString('newpay')` for a provider added after this SDK release
  (the server checks it and refuses unknown ones with `unknown_provider`).
- **A Payment goal waits for its confirmation.** The app can't make a payment count. Clikgate counts it only
  when a trusted source confirms the same reference: your server right after its own verification (the server
  SDKs' `goal()` or payment helpers), a gateway webhook, or the WordPress plugin / Shopify app. The amount and
  currency come from that confirmation: a `value` sent from the app is ignored (`valueIgnored: true`). Without
  `provider` or `reference` the goal is refused with `payment_goal_needs_confirmation`.
- **The result:** `status` is `GoalStatus.Counted`, `GoalStatus.Waiting`, `GoalStatus.Received` (stored, not
  counted: the name isn't ticked as a goal in the dashboard yet, `not_counted_yet`, or the goal is archived,
  `goal_archived`; a success, never retried) or `GoalStatus.Refused`; `reason` is null when counted, else a code such as
  `waiting_for_confirmation`, `pending_click`, `unattributed`, `outside_window`, `already_counted`,
  `payment_goal_needs_confirmation`, `unknown_goal`, `unknown_provider` or `invalid_argument` (bad input, checked on the
  device); `goalKind` is `GoalKind.Standard` / `GoalKind.Payment` when Clikgate said; `valueIgnored` says a value was dropped. `goal()`
  never rejects: errors come back as refused results. The result arrives once Clikgate has answered: while the
  device is offline the goal stays queued (and the result pending), so don't block your UI on it.
- With a test SDK key (`cg_sdk_test_...`) the native SDK logs one line when a goal is waiting for its
  payment confirmation ("purchase is a Payment goal: waiting for confirmation") and when a value was
  ignored.
- Queued, retried and consent-buffered like every goal, idempotent by key and reference, unchanged in private
  mode. It works on every plan (basic app attribution is included).

## 5. Referrals (referee side)

```ts
import { Clikgate, ClikgateError } from '@clikgate/react-native';

const programId = 'rpg_...';

try {
  const referral = await Clikgate.referrals.applyCode({ programId, code: 'ADA42' });
} catch (e) {
  if (e instanceof ClikgateError) {
    switch (e.code) {
      case 'code_not_found': /* ... */ break;
      case 'already_referred': /* ... */ break;
      case 'window_expired': /* ... */ break;
      case 'self_referral': /* ... */ break;
    }
  }
}

const info = await Clikgate.referrals.referredBy(); // info.referred, info.referral
```

`ClikgateError` has `code` (backend code or `not_configured`, `network_error`, `opted_out`,
`invalid_argument`, `timeout`, `install_pending`, `unsupported_platform`, `feature_disabled`), `message`,
`status` (HTTP), `param`, `feature` (set for `feature_disabled`) and `offlineTouchId`.
`ClikgateErrorCode` is the (open) union of the known codes.

The user's own referral link, stats and sharing: from your backend (recommended) or with Engage (5b).

## 5a. Feature switches

Organisations can switch features off (spec v3 §9E). The SDK keeps the `features` map of
`/v1/sdk/config` (refreshed on launch, at most hourly):

```ts
if (await Clikgate.isFeatureEnabled('leaderboards')) showLeaderboardTab();
```

Keys: `referrals`, `leaderboards`, `offline_codes`, `app_attribution` (on until the first config fetch),
`identity_checks`, `whatsapp_attribution`, `skan_postbacks`, `uninstall_tracking`,
`probabilistic_matching`, `apple_search_ads` (off until the first fetch). Unknown keys are `false`.

You don't have to check before calling: a call of a switched-off feature (core `referrals.*`, and every
Engage call) rejects with `ClikgateError` `code: 'feature_disabled'` and `feature`, without a network call
when the cached config already says so. If the server switched the feature off since, its
`{"accepted": false, "reason": "feature_disabled"}` answer becomes the same error and the SDK refreshes
the config.

There is no identity-signal API in any SDK: identity checks are server-to-server only
(`POST /v1/identity-signals` from your backend; the pepper must never ship in an app).

## 5b. Engage add-on (apps without a backend)

```sh
npm install @clikgate/react-native-engage   # needs @clikgate/react-native
```

Pure TypeScript (no native code, no extra pod / Gradle module). It calls the same `/v1/sdk/...` endpoints
with the core SDK's request context (`Clikgate.getRequestContext()`, internal) and keeps no attribution
state. No UI components: render your own screens.

```ts
import { Clikgate } from '@clikgate/react-native';
import { ClikgateEngage } from '@clikgate/react-native-engage';

const engage = new ClikgateEngage(); // keep one instance (it holds the 60 s read cache)

await Clikgate.identifyUser({ customerId: 'user_42', identityToken }); // user calls need identifyUser

// Referrer side (feature `referrals`)
const link = await engage.referrals.createLink({ programId: 'rpg_...', displayName: 'Ada' }); // code, url, shortUrl
const stats = await engage.referrals.myStats({ programId: 'rpg_...' }); // clicks, installs, signups, qualified, ...
await engage.share.referralLink(link, { message: 'Join me on MyApp:' }); // share menu; each app gets its own version
const opened = await engage.share.link('https://inv.myapp.com/summer', { app: ShareApp.WhatsApp }); // false = menu used
await engage.share.system({ text: `Join me on MyApp: ${link.url}` }); // plain text, nothing recorded

// Leaderboards (feature `leaderboards`, boards with visibility = sdk)
const page = await engage.leaderboards.top('lb_...', { period: 'current', limit: 50 }); // limit clamped 1–100
const me = await engage.leaderboards.me('lb_...');                // rank, score, pending, gapToNext, periodEndsAt
const around = await engage.leaderboards.aroundMe('lb_...', { radius: 5 }); // radius clamped 1–25
await engage.leaderboards.setOptOut({ programId: 'rpg_...', optOut: true });
const url = await engage.leaderboards.hostedPageUrl('lb_...');    // signed hosted page URL for a WebView

// Promo / offline codes typed in the app (feature `offline_codes`)
const redemption = await engage.codes.redeem('LAGOS50');           // offlineTouchId, code, referral
```

Rules (spec 17A.3):

- Every call checks `Clikgate.isFeatureEnabled` first and rejects with `feature_disabled` without a
  network call. A server `feature_disabled` answer is reported to the core SDK (the feature then reads
  as off until the next config fetch).
- `createLink`, `myStats`, `me`, `aroundMe`, `setOptOut` and `hostedPageUrl` act for the user: they reject
  with `not_identified` (no network) until `Clikgate.identifyUser({ customerId: userId })` was called. If the program requires
  an identity token, the server answers `identity_required` until `identify` got a valid token.
- Calls also reject with the core's `not_configured`, `opted_out` or `install_pending` (first install not
  recorded yet).
- Reads (`myStats`, `top`, `me`, `aroundMe`) are cached in memory for 60 s per user; any write
  (`createLink`, `setOptOut`, `redeem`) and `engage.clearCache()` drop the cache. Nothing is persisted.
- At most one retry, only for network errors (no connection, 10 s timeout); HTTP errors (429, 5xx, ...)
  surface immediately as `ClikgateError` with the backend `code`, `status`, `param`, `offlineTouchId`.
- `hostedPageUrl` reads `embed_url` from `/leaderboards/{id}/me?embed=1` (never cached; the token is
  short-lived) and rejects with `hosted_page_unavailable` when the server has none.
- `codes.redeem` validates 3–30 characters after trimming; errors `code_not_found`, `code_expired`,
  `code_disabled`, `redemption_limit_reached`, `rate_limited` (5/hour/installation), and for referral codes
  the `applyCode` errors with `offlineTouchId` set (the touch is still recorded).

**Share a link (Change 13).** `share.link(url, {message?, app?, shareUrls?})` and
`share.referralLink(link, {message?, app?})`: each app Clikgate knows gets its own version of the link (a short ending so Clikgate knows where you shared it), other apps get the plain link, and the share is recorded as a share count (the app and the link; no personal data, never a click). They go through the package's
`ClikgateEngage` TurboModule (one method, over the native Engage add-on `com.clikgate:clikgate-engage` /
`Clikgate/Engage`), so rebuild the app after installing the package; without the native module they
fail with `share_unavailable`. Behaviour as on [Android](android.md) and [iOS](ios.md).

**Share helpers.** `share.system({text, title?})` uses React Native `Share`. `share.whatsApp({text})`
calls `Linking.openURL('whatsapp://send?text=<RFC 3986-encoded text>')` and, when that rejects (WhatsApp
not installed), shows the `Share` sheet instead (`false`). `share_unavailable` only when the share sheet
itself fails. `Linking.openURL` needs no `LSApplicationQueriesSchemes` entry on iOS and no `<queries>` on
Android 11+ (only `canOpenURL` does, which Engage doesn't use); the Expo plugin's `whatsapp` query-scheme
entry is harmless and kept for apps that call `Linking.canOpenURL` themselves. On Android this opens
WhatsApp's `whatsapp://send` handler (not WhatsApp Business specifically); the native Android Engage
module's `ACTION_SEND`-with-package path isn't available from pure TypeScript.

## 5c. Consent, Firebase forwarding and sales metadata (1.2.0, change 03)

All calls go to the native SDKs (behaviour: shared/SDK_BEHAVIOUR.md "Change 03"). They may be called
before `configure`.

```ts
// From your consent banner. Omitted purposes keep their state; all start as 'unknown'.
await Clikgate.setConsent({
  analytics: 'granted',      // 'granted' | 'denied' | 'unknown'
  attribution: 'granted',
  adUserData: 'denied',
  adPersonalization: 'denied',
});
await Clikgate.setConsentRegion('DE');  // optional hint: 'EEA', 'UK' or an ISO country code; null clears
const consent = await Clikgate.getConsent(); // {analytics, attribution, adUserData, adPersonalization, region, required}
```

- Where consent is required (your Clikgate privacy settings; EEA, UK and Switzerland by default) and
  `attribution` is still `unknown`, the native SDK buffers goals on the device (up to 7 days or 1,000
  goals) and sends nothing identifying. Granting sends the buffer; denying drops it (and, if you enabled
  anonymous counts, sends one identifier-free install count). Deep links still route locally meanwhile.
- `required` is `null` until the SDK knows (first config fetch, or a region hint).
- Invalid states or regions reject with `invalid_argument` (`param` names the argument).

**Firebase / GA4** (needs GA4 forwarding switched on for the app in Clikgate, and `analytics` consent):

```ts
await Clikgate.enableFirebaseForwarding(); // logAttributionEvent / setUserProperties default to true
```

The native SDKs find Firebase Analytics at runtime (installed for example by
`@react-native-firebase/analytics`); there is no dependency, and without Firebase this does nothing.
They log `clikgate_attribution` once per install, set `cg_first_source` / `cg_first_campaign`, and report
Firebase's app instance id to Clikgate for server-side GA4.

**Sales matching:** `await Clikgate.attributionMetadata()` returns `{cg_click_id, cg_link_id}` (empty when
nothing is attributed or consent doesn't allow it). Add it to Paystack `metadata` / Flutterwave `meta` at
checkout.

**iOS only:** `Clikgate.enableGoogleOnDeviceMeasurement()` (before `configure`, first launch) passes
Google's on-device conversion measurement info to Clikgate when the app links Google's
`GoogleAdsOnDeviceConversion` SDK. No-op on Android.

**Clipboard deferred deep link (iOS):** `pasteboardMode` now defaults to `'off'`. With `'automatic'` the
SDK reads the pasteboard once on first launch, only when your Clikgate app setting enables it; iOS 16+
then shows "“<App>” would like to paste from “<App>”" (Allow Paste / Don't Allow).

## 6. Push token and uninstall tracking

With `@react-native-firebase/messaging` (FCM, Android and iOS):

```ts
import messaging from '@react-native-firebase/messaging';
import { Clikgate, isClikgateMessage } from '@clikgate/react-native';

// index.js — background / headless handler. isClikgateMessage is pure TS: no native call.
messaging().setBackgroundMessageHandler(async (message) => {
  if (isClikgateMessage(message.data)) return;   // never show these
  // your handling
});

messaging().onMessage(async (message) => {
  if (isClikgateMessage(message.data)) return;
  // your handling
});

await Clikgate.setPushToken(await messaging().getToken(), { provider: 'fcm' });
messaging().onTokenRefresh((t) => Clikgate.setPushToken(t, { provider: 'fcm' }));
```

iOS without FCM: forward the APNs token and silent pushes natively (section 8). A token can also be passed
from JS as hex with `{ provider: 'apns' }`. Clikgate's silent uninstall checks (`{"cg": "uc"}`, APNs
`cg.t == "uc"`) must never produce a notification; the SDK never requests notification permission.

## 7. Expo config plugin

```json
{
  "expo": {
    "plugins": [
      [
        "@clikgate/react-native",
        {
          "linkDomains": ["myapp.ciz.to", "inv.myapp.com"],
          "testLinkDomain": "myapp.dev.ciz.to",
          "uriScheme": "myapp",
          "enableBackgroundRemoteNotifications": true,
          "enableWhatsAppSharing": true
        }
      ]
    ]
  }
}
```

| Prop | iOS | Android |
|---|---|---|
| `linkDomains` | `com.apple.developer.associated-domains` += `applinks:<domain>` | main activity: one `VIEW`/`BROWSABLE` intent filter per domain, `https` + host, `android:autoVerify="true"` |
| `testLinkDomain` (1.4.0) | Debug configuration only: `<Target>Debug.entitlements` (a copy of the Release entitlements plus `applinks:<domain>`) linked with `CODE_SIGN_ENTITLEMENTS` | `app/src/debug/AndroidManifest.xml` (and existing debug-based source sets such as `debugOptimized`): a verified filter on the main activity |
| `testVariants` (default `["development", "preview"]`) | Builds whose variant (`APP_VARIANT`, else EAS Build's `EAS_BUILD_PROFILE`) is listed get `testLinkDomain` in **every** configuration, so internal preview (Release) builds open test links too | same |
| `uriScheme` | `CFBundleURLTypes` entry | `VIEW` intent filter for the scheme (skipped if Expo's `scheme` already declares it) |
| `enableBackgroundRemoteNotifications` (default `true`) | `UIBackgroundModes` += `remote-notification` | — |
| `enableWhatsAppSharing` (default `true`) | `LSApplicationQueriesSchemes` += `whatsapp` (only needed if your app calls `Linking.canOpenURL('whatsapp://…')`; Engage's `share.whatsApp` works without it) | — |

**Test link domain.** Your app's test subdomain (`myapp.dev.ciz.to`, Clikgate's test links) must never reach a
production build. Put it in `testLinkDomain`, not `linkDomains` (the plugin refuses both). Never list a shared
domain (`ciz.to`, `clk.ng`, `clkg.to`, `dev.ciz.to`): shared domains can't open your app (change 09). Set the variant per EAS build profile, as
Expo documents for app variants:

```json
{ "build": { "development": { "env": { "APP_VARIANT": "development" } }, "preview": { "env": { "APP_VARIANT": "preview" } }, "production": {} } }
```

Without a variant (local `npx expo run:*`, `production`), only Debug builds get the test domain. After
changing the plugin props, make a new development build: Expo Go and existing builds keep their old
entitlements and intent filters. `npx @clikgate/setup` adds this entry for you.

Existing entries are kept and nothing is duplicated. The plugin does **not** modify the AppDelegate: the
Expo AppDelegate already forwards links to `RCTLinkingManager`, and the module picks them up from its
`RCTOpenURLNotification` automatically. Forwarding silent APNs pushes / APNs tokens natively (only for apps
not using FCM from JS) is a manual step (section 8).

## 8. iOS setup (bare React Native)

1. **Associated Domains**: Xcode → target → Signing & Capabilities → + Associated Domains →
   `applinks:inv.myapp.com`, one entry for **every** domain of your Clikgate domain group (aliases such as
   `ybr.ng` and `go.yourbrand.com` serve the same links; list them all in `linkDomains` too). **Background Modes** → Remote notifications. **URL Types** → your scheme
   (for the interstitial's "Open in app").
2. **AppDelegate** — React Native apps own it. Forward links (keeps `Linking` working too):

   ```swift
   import ClikgateReactNative

   func application(_ app: UIApplication, open url: URL,
                    options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
     let clikgate = ClikgateRN.handle(url: url)
     return RCTLinkingManager.application(app, open: url, options: options) || clikgate
   }

   func application(_ application: UIApplication, continue userActivity: NSUserActivity,
                    restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void) -> Bool {
     let clikgate = ClikgateRN.continue(userActivity: userActivity)
     return RCTLinkingManager.application(application, continue: userActivity,
                                          restorationHandler: restorationHandler) || clikgate
   }
   ```

   If your AppDelegate already forwards to `RCTLinkingManager` you can skip the `ClikgateRN` calls: the
   module observes `RCTOpenURLNotification` from process start (cold starts included). Using both is
   safe — the same URL is handled once. Links received before `Clikgate.configure` are kept and handled
   right after it. Apps with a custom `UISceneDelegate` must forward `scene(_:continue:)` and
   `scene(_:openURLContexts:)` the same way.

3. **Push without FCM** (APNs):

   ```swift
   application.registerForRemoteNotifications()   // in didFinishLaunching; no permission prompt needed

   func application(_ application: UIApplication,
                    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
     ClikgateRN.setPushToken(deviceToken: deviceToken)   // kept until configure if early
   }

   func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                    fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
     if ClikgateRN.handleRemoteNotification(userInfo, completionHandler: completionHandler) { return }
     // your handling
   }
   ```

   Add the Push Notifications capability (`aps-environment`). Apps using
   `@react-native-firebase/messaging` don't need this (section 6).

4. **WhatsApp** (Engage `share.whatsApp`): nothing to add. Add `whatsapp` to
   `LSApplicationQueriesSchemes` only if your own code calls `Linking.canOpenURL('whatsapp://…')`.

Pasteboard modes, App Attest and the privacy manifest are covered in [ios.md](ios.md).

## 9. Android setup (bare React Native)

1. **Intent filters** on `MainActivity` (React Native's template uses `launchMode="singleTask"`, so
   warm-start links arrive through `onNewIntent`):

   ```xml
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
   ```

   With several link domains (aliases in your Clikgate domain group), add one
   `<data android:host="..." />` per domain to the `autoVerify` filter and list them all in
   `linkDomains`. Clikgate serves `apple-app-site-association` and `assetlinks.json` on every active domain of the group, but the OS opens your app only for the domains the app itself declares. The SDK also adds the domains the server lists in `/v1/sdk/config` (`link_domains`, cached with the config, compared case-insensitively) and logs a warning naming each server domain missing from `linkDomains`: add it to `linkDomains` and to the intent filter / Associated Domains (the Expo plugin
   does both from `linkDomains`).
2. **Intent forwarding is automatic**: the module hands the launch intent to the SDK (kept until
   `configure` runs in JS) and every `onNewIntent`. Nothing to add to `MainActivity`.
3. **App Link verification**: `adb shell pm get-app-links <applicationId>`; see
   [TESTING_DEEP_LINKS.md](TESTING_DEEP_LINKS.md).
4. **Backup rules** and **cleartext for a local backend**: as in [android.md](android.md) and
   [flutter.md §7](flutter.md#7-android-setup).

### Native SDK dependency

- Releases: `com.clikgate:clikgate-android` (Maven Central); `-Pclikgate.androidVersion=x.y.z` overrides
  the version.
- Against an unpublished SDK: `cd android && ./gradlew :clikgate:publishToMavenLocal`, then
  `clikgate.useMavenLocal=true` in your app's `android/gradle.properties` (the module then adds
  `mavenLocal()` filtered to `com.clikgate`). This is what `react-native/example` does by default.
- The Gradle composite build used by the Flutter example (`includeBuild(".../android")` with module
  substitution; `-Pclikgate.useLocalSdk=true` in the RN example) only works when the app uses the same
  Android Gradle Plugin as `android/` (8.9.1). React Native 0.86 uses AGP 8.12.0, so with a current React
  Native use the Maven-local route.

## 10. Example app

`react-native/example` (bare React Native 0.86.3): product deep link screen, apply-code screen,
referred-by banner, push-token hook (APNs natively on iOS; FCM wiring shown in `src/push.ts`, no Firebase
needed to build) — core — and, through `@clikgate/react-native-engage`, referral invite (create link,
`Share`, share to WhatsApp, stats), weekly leaderboard (top 10, my rank, around me, hide-me toggle;
`CLIKGATE_LEADERBOARD_ID`) and promo-code redemption. Metro resolves the Engage package from
`../../react-native-engage/src` (see `example/metro.config.js`); TypeScript via `paths` in
`example/tsconfig.json`.

```sh
cd react-native && npm install && cd example && npm install
CLIKGATE_SDK_KEY=cg_sdk_... CLIKGATE_API_BASE_URL=http://10.0.2.2:8000 \
CLIKGATE_LINK_DOMAIN=inv.myapp.com CLIKGATE_PROGRAM_ID=rpg_... CLIKGATE_LEADERBOARD_ID=lb_... \
npx react-native start --reset-cache

# Android (publishes the native SDK to ~/.m2 first)
(cd ../../android && ./gradlew :clikgate:publishToMavenLocal)
cd android && ./gradlew installDebug -Pclikgate.linkDomain=inv.myapp.com

# iOS
cd ios && pod install && cd .. && npx react-native run-ios
# link domain / scheme: Xcode build settings CLIKGATE_LINK_DOMAIN / CLIKGATE_URI_SCHEME
```

## 11. Development

```sh
cd react-native
npm test          # Jest: TS layer with a mocked native module + Expo plugin mods
npm run typecheck
npm run lint
npm run build     # lib/ (bob) + plugin/build

cd ../react-native-engage
npm run devlink   # links node_modules -> ../react-native/node_modules (no second install)
npm test          # Jest: rules, cache, retry, errors, share, API snapshot (fixtures from ../shared)
npm run typecheck
npm run lint
npm run build     # lib/ (bob); needs the core's lib/typescript (`npm run build:lib` in ../react-native)
```

Both packages have a public-API snapshot test (`api/public-api.txt`, `src/__tests__/publicApi.test.ts`).
The core one also fails on any leaderboard / referral-stats / link-creation / code / share /
identity-signal API and on any dependency on, or import of, `@clikgate/react-native-engage`. After an
intended API change: `UPDATE_API_SNAPSHOT=1 npx jest publicApi`.

## 12. Removing the SDK

See [react-native/README.md "Removing the SDK"](../react-native/README.md#removing-the-sdk): remove the
calls and the package(s), the Expo plugin entry or the Associated Domains / intent filters / URL scheme,
the push-token forwarding, and mark the app as no longer tracked in the Clikgate dashboard.
