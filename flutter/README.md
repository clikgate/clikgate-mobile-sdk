# clikgate_flutter

The **core** Clikgate plugin for Flutter: deep links (direct and deferred), install
attribution, goals, `identifyUser`, `getInstallationId`, referee-side **referrals** (apply a code, referred-by),
**uninstall tracking** and feature switches, powered by [Clikgate](https://clikgate.com).

Referral links and stats, leaderboards, promo codes and share helpers are in the optional
pure-Dart package [`clikgate_engage`](../flutter_engage) for apps without a backend; apps with a
backend should call the Clikgate API from their server instead (recommended).

A thin bridge over the native Clikgate Android (`com.clikgate:clikgate-android`) and iOS
SDKs — no attribution or referral logic runs in Dart.

| | Android | iOS |
|---|---|---|
| Minimum | API 21 | iOS 13 |
| Deferred deep links | Play Install Referrer | pasteboard token (opt-in) |
| Direct links | App Links, custom scheme | Universal Links, custom scheme |
| Feature switches (`isFeatureEnabled`) | yes | yes |

## Usage

```dart
import 'package:clikgate_flutter/clikgate_flutter.dart';

await Clikgate.configure(sdkKey: 'cg_sdk_...', linkDomains: ['inv.myapp.com']);

Clikgate.onDeepLink.listen((ClikgateDeepLink r) => router.go(r.path ?? '/', extra: r.data));
final attribution = await Clikgate.getAttribution();

// Goals: your end goal, with your own reference (never customer data). goal() is the only method.
final r = await Clikgate.goal('account_opened', value: '2000000', currency: 'NGN', reference: 'APP-55231');
// r.status: GoalStatus.counted, .waiting, .received (stored, not ticked as a goal yet) or .refused (r.reason says why)
// A Payment goal: the provider and the reference your checkout returned. It waits until your payment
// provider or server confirms it, with the real amount (a value sent from the app is ignored).
await Clikgate.goal('purchase', reference: 'T123456', provider: ClikgateProvider.paystack);
// Identify signed-in users: Path A with a token from your server, or Path B with the installation ID.
await Clikgate.identifyUser(customerId: user.id, identityToken: me.clikgateToken);
final String? installationId = await Clikgate.getInstallationId(); // send it with your sign-in request
await Clikgate.identifyUser(customerId: null); // sign-out
await Clikgate.setTrackingEnabled(false);

// Push / uninstall tracking (works with firebase_messaging)
await Clikgate.setPushToken(await FirebaseMessaging.instance.getToken(), provider: PushProvider.fcm);
if (Clikgate.isClikgateMessage(message.data)) return; // in onMessage and the background handler

// Referee-side referral calls (tied to this installation)
final referral = await Clikgate.referrals.applyCode(programId: 'rpg_...', code: 'ADA42');
final info = await Clikgate.referrals.referredBy();

await Clikgate.isFeatureEnabled('referrals');

// Consent (1.2.0). Where consent is required (EEA, UK, CH by default) and attribution is unknown,
// nothing identifying is sent; goals are buffered (7 days / 1,000 goals), sent on grant, dropped on deny.
await Clikgate.setConsent(analytics: ConsentState.granted, attribution: ConsentState.granted,
    adUserData: ConsentState.denied, adPersonalization: ConsentState.denied);
await Clikgate.setConsentRegion('EEA'); // optional hint: EEA, UK or an ISO country code
final consent = await Clikgate.getConsent(); // consent.required: null until known

// Firebase / GA4 (detected natively at runtime; add firebase_analytics yourself)
await Clikgate.enableFirebaseForwarding();

// Sales matching: put this in Paystack `metadata` / Flutterwave `meta`
final metadata = await Clikgate.attributionMetadata(); // {cg_click_id, cg_link_id}

// iOS only: Google's on-device conversion measurement (app links GoogleAdsOnDeviceConversion)
await Clikgate.enableGoogleOnDeviceMeasurement(); // before configure on the first launch
```

`configure(pasteboardMode:)` (iOS clipboard deferred deep link) defaults to `off` from 1.2.0; pass
`ClikgatePasteboardMode.automatic` to opt in (iOS 16+ then shows the system paste prompt
"“<App>” would like to paste from “<source app>”" on the first launch, only if your Clikgate app setting enables it).

## Identify your users

Path A (the default): your server makes an identity token with the server SDK's `createIdentityToken` (secret
`CLIKGATE_IDENTITY_SECRET`, server only) and returns it in the sign-in and "current user" responses; the app passes
it to `identifyUser`. Path B (no token): the app sends its installation ID with the sign-in request and your server
calls `identifyUser({appId, installationId, customerId, label?})`. The installation ID is `null` when tracking is off
(opt-out, consent denied or not given yet where required, deep-link-only mode). The customer ID is your own user ID,
never an email or phone number. Guide: https://clikgate.com/docs/identify-users

Errors are thrown as `ClikgateException(code, message, status, param, feature)` with the backend codes
(`code_not_found`, `already_referred`, `window_expired`, `self_referral`, `identity_required`, …).

## Setup

- Android: intent filters with `android:autoVerify="true"` for your link domain; the plugin
  forwards launch and `onNewIntent` intents automatically.
- iOS: Associated Domains, Background Modes → Remote notifications.

Full guides: [Flutter integration](../docs/flutter.md) (Android setup, native SDK
dependency) and [iOS setup](../docs/flutter_ios_setup.md). The `example/` app demonstrates
the core plugin and the Engage add-on.

## Deep links on every plan

Deep links work on every plan, Free included (deferred deep links: 1,000 a month on Free, 10,000 on Starter). On
Free the app's link subdomain is `yourapp.clk.ng` in release builds; debug builds use `yourapp.dev.ciz.to`.
Install attribution and `goal` work on every plan, Free through Enterprise, up to the plan's allowance: basic app
attribution is included in all of them. `goal` does nothing only when app attribution is switched off for the app
(deep-link-only mode), where it logs one warning (no error). See the platform guide.

## Removing the SDK

1. Remove `clikgate_flutter` (and `clikgate_engage`, if used) from `pubspec.yaml` and run
   `flutter pub get`.
2. Delete `Clikgate.configure(...)` and every other `Clikgate.*` / `ClikgateEngage` call
   (deep link listener, `goal`, `identifyUser`, consent, `setPushToken`, `isClikgateMessage` checks).
3. Remove the platform entries you added for Clikgate: iOS Associated Domains
   (`applinks:<your link domains>`), custom URL schemes and Info.plist keys
   (`ClikgateForwardAPNsToken`, `LSApplicationQueriesSchemes` → `whatsapp` if only for Clikgate);
   Android `autoVerify` intent filters for the link domains and custom schemes in
   `AndroidManifest.xml`.
4. Remove push-token forwarding for uninstall tracking (`Clikgate.setPushToken`, the
   `isClikgateMessage` filters in your FCM handlers). Keep your own push setup.
5. In the Clikgate dashboard, mark the app as no longer tracked (app settings), so Clikgate stops
   uninstall checks and doesn't expect goals. Links keep redirecting to their web or store
   destinations. Then run `pod install` (iOS) and a clean build.
