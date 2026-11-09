# @clikgate/react-native

Deep links (direct and deferred), install attribution, goals, identifyUser, the installation ID, referee-side referral calls,
feature switches and uninstall tracking for React Native — a TurboModule over the native Clikgate
Android and iOS SDKs, with an Expo config plugin. Referrer-side features (referral links and stats,
share helpers, leaderboards, promo codes) are in the optional pure-TypeScript add-on
[`@clikgate/react-native-engage`](../react-native-engage) for apps without a backend; apps with a
backend call the Clikgate API from their server instead.

```ts
import { Clikgate, ClikgateProvider, isClikgateMessage } from '@clikgate/react-native';

await Clikgate.configure({ sdkKey: 'cg_sdk_...', linkDomains: ['inv.myapp.com'] });
const unsubscribe = Clikgate.onDeepLink((link) => navigate(link.path, link.data));
const attribution = await Clikgate.getAttribution();
// Goals: your end goal, with your own reference (never customer data). goal() is the only method.
const r = await Clikgate.goal('account_opened', { value: '2000000', currency: 'NGN', reference: 'APP-55231' });
// r.status: GoalStatus.Counted, Waiting, Received (stored, not ticked as a goal yet) or Refused (r.reason says why)
// A Payment goal: the provider and the reference your checkout returned. It waits until your payment
// provider or server confirms it, with the real amount (a value sent from the app is ignored).
await Clikgate.goal('purchase', { reference: 'T123456', provider: ClikgateProvider.Paystack });
// Identify signed-in users: Path A with a token from your server, or Path B with the installation ID.
await Clikgate.identifyUser({ customerId: user.id, identityToken: me.clikgateToken });
const installationId = await Clikgate.getInstallationId(); // string | null: send it with your sign-in request
await Clikgate.identifyUser({ customerId: null });          // sign-out
await Clikgate.referrals.applyCode({ programId: 'rpg_...', code: 'ADA42' });
const info = await Clikgate.referrals.referredBy();

// Consent, Firebase forwarding, sales metadata
await Clikgate.setConsent({ analytics: 'granted', attribution: 'granted', adUserData: 'denied' });
await Clikgate.setConsentRegion('EEA');               // optional region hint
await Clikgate.enableFirebaseForwarding();
const metadata = await Clikgate.attributionMetadata(); // {cg_click_id, cg_link_id} for Paystack metadata
```

Expo: `"plugins": [["@clikgate/react-native", { "linkDomains": ["myapp.ciz.to", "inv.myapp.com"], "testLinkDomain": "myapp.dev.ciz.to", "uriScheme": "myapp" }]]` (the test domain goes into development builds only).

Integration guide: [docs/react-native.md](https://github.com/clikgate/clikgate-mobile-sdk/blob/main/docs/react-native.md).
Requires the New Architecture (React Native 0.76+).

## Identify your users

Path A (the default): your server makes an identity token with the server SDK's `createIdentityToken` (secret
`CLIKGATE_IDENTITY_SECRET`, server only) and returns it in the sign-in and "current user" responses; the app passes
it to `identifyUser`. Path B (no token): the app sends its installation ID with the sign-in request and your server
calls `identifyUser({appId, installationId, customerId, label?})`. The installation ID is `null` when tracking is off
(opt-out, consent denied or not given yet where required, deep-link-only mode). The customer ID is your own user ID,
never an email or phone number. Guide: https://clikgate.com/docs/identify-users

## Deep links on every plan

Deep links work on every plan, Free included (deferred deep links: 1,000 a month on Free, 10,000 on Starter). On
Free the app's link subdomain is `yourapp.clk.ng` in release builds; debug builds use `yourapp.dev.ciz.to`.
Install attribution and `goal` work on every plan, Free through Enterprise, up to the plan's allowance: basic app
attribution is included in all of them. `goal` does nothing only when app attribution is switched off for the app
(deep-link-only mode), where it logs one warning (no error). See the platform guide.

## Removing the SDK

1. Remove every call: `Clikgate.configure`, `onDeepLink`, `goal`, `identifyUser`, `getInstallationId`, `setConsent`,
   `enableFirebaseForwarding`, `attributionMetadata` (and any Paystack / Flutterwave metadata built
   from it), `referrals.*`, plus `@clikgate/react-native-engage` if you use it.
2. Remove the package: `npm uninstall @clikgate/react-native @clikgate/react-native-engage`, then
   `cd ios && pod install` (bare apps) or a fresh `npx expo prebuild --clean` (Expo).
3. Remove the platform entries: the `@clikgate/react-native` entry in `app.json` / `app.config.*`
   `plugins` (Expo), or by hand the `applinks:<your link domains>` Associated Domains, the Android
   `autoVerify` intent filters for your link domains, and the URI scheme only Clikgate links used.
4. Remove push-token forwarding for uninstall tracking: `Clikgate.setPushToken(...)`, the
   `isClikgateMessage` checks in your FCM handlers, and any `ClikgateRN` calls in the AppDelegate.
5. In the Clikgate dashboard, mark the app as no longer tracked (and switch off uninstall
   tracking) so Clikgate stops sending silent check pushes and your reports show the cut-off.
   Leaving Clikgate entirely: export your data first (Settings › Leave Clikgate).
