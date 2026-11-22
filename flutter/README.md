# clikgate_flutter

The **core** Clikgate plugin for Flutter: deep links (direct and deferred), install
attribution, goals, `identifyUser`, `getInstallationId`, referee-side **referrals** (apply a code, referred-by),
**uninstall tracking** and feature switches, powered by [Clikgate](https://clikgate.com).

Referral links and stats, leaderboards, promo codes and share helpers are the Engage features of
this package (`import 'package:clikgate_flutter/engage.dart'`) for apps without a
backend; apps with a backend should call the Clikgate API from their server instead (recommended).

The core is a thin bridge over the native Clikgate Android (`com.clikgate:clikgate-android`) and iOS
SDKs: attribution, goals and referee-side referral logic run natively. The Engage features are different: they
call the Clikgate API from Dart over HTTPS (package `http`), with the installation context from the native SDK.

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
await Clikgate.identifyUser(customerId: user.id, identityToken: me.clikgateIdentityToken);
final String? installationId = await Clikgate.getInstallationId(); // send it with your sign-in request
await Clikgate.identifyUser(customerId: null); // sign-out
await Clikgate.setTrackingEnabled(false);

// Uninstall tracking: turn it on in the dashboard (Settings › Features, plus the app's push credentials under
// Connect › Apps › your app); the push token is automatic (automaticPushToken,
// no AppDelegate code, no permission prompt). iOS needs the Push Notifications capability.
if (Clikgate.isClikgateMessage(message.data)) return; // in your FCM onMessage and background handlers

// Referee-side referral calls (tied to this installation)
final referral = await Clikgate.referrals.applyCode(programId: 'rpg_...', code: 'ADA42');
final info = await Clikgate.referrals.referredBy();

await Clikgate.isFeatureEnabled('referrals');

// Consent. Where consent is required (EEA, UK, CH by default) and attribution is unknown,
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

`configure(pasteboardMode:)` (iOS clipboard deferred deep link) defaults to `off`; pass
`ClikgatePasteboardMode.automatic` to opt in (iOS 16+ then shows the system paste prompt
"“<App>” would like to paste from “<source app>”" on the first launch, only if your Clikgate app setting enables it).

## Identify your users

Path A (the default): your server makes an identity token with the server SDK's `createIdentityToken` (secret
`CLIKGATE_IDENTITY_SECRET`, server only) and returns it in the sign-in and "current user" responses; the app passes
it to `identifyUser`. Path B (no token): the app sends its installation ID with the sign-in request and your server
calls `identifyUser({appId, installationId, customerId, label?})`. The installation ID is `null` when tracking is off
(opt-out, consent denied or not given yet where required, deep-link-only mode). The customer ID is your own user ID,
never an email or phone number. Guide: https://clikgate.com/docs/identify-users

Send the `Clikgate-Installation` header (2.1.6) with the sign-in request and with signed-in requests to your own
server, so it knows which Clikgate app is calling; send it only to your own backend, over HTTPS, never to third
parties. It is `null` when the installation ID is, or while the app ID isn't known yet, and never throws:

```dart
dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) async {
  final h = await Clikgate.getInstallationHeader();
  if (h != null) options.headers[h.name] = h.value;
  handler.next(options);
}));
```

`identifyUser` returns nothing about the result, on every platform (Android `Unit`, iOS `Void`, Flutter
`Future<void>`, React Native `Promise<void>`): the native SDK sends the identity in the background, and when a token
doesn't verify, debug builds log the reason (`expired`, `bad_signature`, ...). The Flutter future completes once the
native SDK has the call.

Errors are thrown as `ClikgateException(code, message, status, param, feature)` with the backend codes
(`code_not_found`, `already_referred`, `window_expired`, `self_referral`, `identity_required`, …).

## Testing your app

Without a device every plugin call fails with `ClikgateException(unsupported_platform)`. In widget tests, install
the fake from `package:clikgate_flutter/testing.dart` (tests only, never from `lib/`): it answers the core plugin
and the Engage features (their HTTP calls included), records every call, and is removed when the test ends.

```dart
import 'package:clikgate_flutter/testing.dart';

late ClikgateFake clikgate;
setUp(() => clikgate = ClikgateFake.install());

testWidgets('checkout sends a Payment goal', (tester) async {
  await tester.pumpWidget(const MyApp());
  await tester.tap(find.text('Pay with Paystack'));
  await tester.pumpAndSettle();
  expect(clikgate.goals.last.result.status, GoalStatus.waiting);
});
```

Defaults: `configure` succeeds; the installation ID and header look like real ones; goals answer `counted`
(Payment goals `waiting`); `applyCode` succeeds (`clikgate.applyCodeError = 'code_not_found'` makes it throw);
Engage `createLink` returns a link with a stable code. `clikgate.pushDeepLink(url)` delivers a deep link on
`onDeepLink`. Recorded: `goals`, `identifyCalls`, `appliedCodes`, `shares`, `engageRequests`, `calls`. As on a
device, Engage user calls throw `not_identified` until `identifyUser` (or `ClikgateFake.install(customerId: ...)`).
Everything it answers and how to change it: [Testing your app](https://github.com/clikgate/clikgate-mobile-sdk/blob/main/docs/flutter.md#10-testing-your-app).

## Setup

From your Flutter project's folder:

```sh
flutter pub add clikgate_flutter
dart run clikgate_flutter          # sets up Clikgate (dart run clikgate_flutter:doctor checks it)
```

`dart run clikgate_flutter` is the [Clikgate setup command](https://clikgate.com/docs/setup-command) (the same
program as `npx @clikgate/setup`, no Node.js needed). It shows every change before it writes anything. The
first run downloads the program for your computer once (about 41 MB; up to 55 MB on Linux and Windows) and checks its SHA-256 against the
checksum in this package. `npx @clikgate/setup` still works.

By hand:

- Android: intent filters with `android:autoVerify="true"` for your link domain; the plugin
  forwards launch and `onNewIntent` intents automatically.
- iOS: Associated Domains, Background Modes → Remote notifications.

Full guides: [Flutter integration](https://github.com/clikgate/clikgate-mobile-sdk/blob/main/docs/flutter.md) (Android setup, native SDK
dependency) and [iOS setup](https://github.com/clikgate/clikgate-mobile-sdk/blob/main/docs/flutter_ios_setup.md). The `example/` app demonstrates
the core plugin and its Engage features.

## Deep links on every plan

Deep links work on every plan, Free included (deferred deep links: 1,000 a month on Free, 10,000 on Starter). On
Free the app's link subdomain is `yourapp.ciz.ng` in release builds; debug builds use `yourapp.dev.ciz.to`.
Install attribution and `goal` work on every plan, Free through Enterprise, up to the plan's allowance: basic app
attribution is included in all of them. `goal` does nothing only when app attribution is switched off for the app
(deep-link-only mode), where it logs one warning and the result is `refused` with `feature_disabled` (no exception). See the platform guide.

## Removing the SDK

1. Remove `clikgate_flutter` from `pubspec.yaml` and run
   `flutter pub get`.
2. Delete `Clikgate.configure(...)` and every other `Clikgate.*` / `ClikgateEngage` call
   (deep link listener, `goal`, `identifyUser`, consent, `setPushToken`, `isClikgateMessage` checks).
3. Remove the platform entries you added for Clikgate: iOS Associated Domains
   (`applinks:<your link domains>`), custom URL schemes and Info.plist keys
   (`ClikgateForwardAPNsToken`, `LSApplicationQueriesSchemes` → `whatsapp` if only for Clikgate);
   Android `autoVerify` intent filters for the link domains and custom schemes in
   `AndroidManifest.xml`.
4. Remove push-token forwarding for uninstall tracking (`Clikgate.setPushToken`, the
   `isClikgateMessage` filters in your FCM handlers), and the Push Notifications capability if only
   Clikgate used it. Keep your own push setup.
5. In the Clikgate dashboard, open Connect › Apps › your app and switch off **SDK enabled** (and remove its push
   credentials), so Clikgate stops uninstall checks and doesn't expect goals. Links keep redirecting to their web or store
   destinations. Then run `pod install` (iOS) and a clean build.
