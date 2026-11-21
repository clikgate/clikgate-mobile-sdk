# Flutter end-to-end sample app

A small Flutter app that shows everything an app does with Clikgate, working with one of the sample backends
(`examples/end-to-end` in the [server SDK repository](https://github.com/clikgate/clikgate-sdks/tree/main/examples/end-to-end)).
Every sample backend answers the same routes, so pick the language you use.

| File | What it shows |
| --- | --- |
| `lib/src/clikgate_setup.dart` | `Clikgate.configure` with the link domains, and `existingUser` from the app's own storage |
| `lib/src/deep_links.dart` | `Clikgate.onDeepLink` routing (`/product/<id>` opens the product screen; a blocked link shows its message) |
| `lib/src/auth_service.dart` | Sign-up and sign-in with the backend, then `identifyUser` with its `clikgateIdentityToken`; `/me` at every app open; sign-out |
| `lib/src/backend/interceptors.dart` | The no-token option: a dio interceptor that adds `Clikgate.getInstallationHeader()` to requests to your backend |
| `lib/src/screens/home_screen.dart` | An app goal, and a Payment goal with `provider: ClikgateProvider.paystack` that the backend then confirms |
| `lib/src/screens/referral_screen.dart` | Engage `referrals.createLink(programId:)` and `share.referralLink`, plus "Have a code?" with `referrals.applyCode` |
| `test/` | Widget and unit tests with the SDK's test fake (`package:clikgate_flutter/testing.dart`) and a fake backend |

## Run it

The sample uses [fvm](https://fvm.app) with the Flutter version in `.fvmrc`.

```bash
# 1. Generate the Android and iOS folders (they aren't kept in the repository), then set up deep links for them
fvm flutter create --platforms=android,ios --org com.example .
fvm dart run clikgate_flutter

# 2. Start a sample backend (see its README), then run the app with your test keys
fvm flutter run \
  --dart-define=CLIKGATE_SDK_KEY=cg_sdk_test_replace_me \
  --dart-define=CLIKGATE_LINK_DOMAINS=yourapp.dev.ciz.to \
  --dart-define=CLIKGATE_REFERRAL_PROGRAM_ID=rpg_replace_me \
  --dart-define=BACKEND_URL=http://10.0.2.2:8080
```

`BACKEND_URL` defaults to `http://10.0.2.2:8080`, which is your computer as the Android emulator sees it. Use
`http://localhost:8080` on the iOS simulator. In production, talk to your backend over HTTPS only: the installation
header and the identity token go nowhere else.

Check and test (no device, simulator or network needed):

```bash
fvm flutter analyze
fvm flutter test
```

## Two ways to identify the user

The sample shows both; your app needs one.

- **Identity token (the default).** The backend returns `clikgateIdentityToken` from sign-up, sign-in and `/me`, and
  the app passes it to `Clikgate.identifyUser(customerId:, identityToken:)`.
- **Installation header (no secret on the backend).** The dio interceptor sends `Clikgate-Installation` with every
  request to the backend, which calls the server SDK's `identifyUser` after its own sign-in check. A backend without
  an identity secret returns a `null` token, and the app still calls `identifyUser(customerId:)`.

## Plugin version

`pubspec.yaml` uses the plugin from this repository (`path: ../../flutter`), so the sample works before the next
version is published. At release, change it to `clikgate_flutter: ^2.1.6`.
