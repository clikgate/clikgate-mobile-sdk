# Clikgate mobile SDKs and setup command

This repository holds the **mobile SDKs + setup command**: the Android, iOS, Flutter and React Native
SDKs (Apache 2.0), and `npx @clikgate/setup` in [`cli/`](cli) (MIT), which installs and configures them
in an app project. The server SDKs and AI guides are in `clikgate_sdks`.

Deep linking, deferred deep linking, install attribution, referrals and uninstall tracking for
apps that use [Clikgate](https://clikgate.com) links. The backend side lives in the
`clikgate_api` repository (`src/sdk`, `/v1/sdk/*` on `sdk.clikgate.com`).

| Package | Path | Distribution | Guide |
|---|---|---|---|
| Android SDK (Kotlin, minSdk 21) | [`android/`](android) | Maven Central `com.clikgate:clikgate-android` | [docs/android.md](docs/android.md) |
| iOS SDK (Swift, iOS 13+) | [`ios/`](ios) | Swift Package Manager, CocoaPods `Clikgate`, XCFramework | [docs/ios.md](docs/ios.md) |
| Flutter plugin | [`flutter/`](flutter) | pub.dev `clikgate_flutter` | [docs/flutter.md](docs/flutter.md), [iOS setup](docs/flutter_ios_setup.md) |
| React Native | [`react-native/`](react-native) | npm `@clikgate/react-native` (+ Expo config plugin) | [docs/react-native.md](docs/react-native.md) |
| Setup command (TypeScript, Node 18+, **MIT**) | [`cli/`](cli) | npm `@clikgate/setup` (`npx @clikgate/setup`, bin `clikgate-setup`) | [docs/SETUP_COMMAND.md](docs/SETUP_COMMAND.md) |

These are the **core SDKs**: only what must happen on the device (deep links, attribution,
events, identify, apply code / referred-by, push token / uninstall checks, feature switches). The
Flutter and React Native packages are thin bridges over the native SDKs: all attribution,
queueing and referral logic is in the native code.

### Engage add-on (optional, apps without a backend)

Referral links and stats, leaderboards, promo codes and share helpers are in separate packages
that depend on the core. Apps with a backend should call the Clikgate control-plane API from
their server instead: see [docs/engage.md](docs/engage.md).

| Package | Path | Distribution |
|---|---|---|
| Android | [`android/clikgate-engage`](android/clikgate-engage) | Maven Central `com.clikgate:clikgate-engage` |
| iOS | [`ios/Sources/ClikgateEngage`](ios/Sources/ClikgateEngage) | SPM product `ClikgateEngage`, CocoaPods subspec `Clikgate/Engage` |
| Flutter (pure Dart) | [`flutter_engage/`](flutter_engage) | pub.dev `clikgate_engage` |
| React Native (pure TypeScript) | [`react-native-engage/`](react-native-engage) | npm `@clikgate/react-native-engage` |

## Setup command (`cli/`)

`npx @clikgate/setup` sets up Clikgate in a Flutter, React Native, Expo, Android or iOS app project
(the SDK dependency, start-up code, app links on the app's link subdomain and custom domains, with the test subdomain in debug builds only), and
`npx @clikgate/setup doctor` checks one. It moved here from `clikgate_sdks` on 2026-10-26 because it
writes these SDKs' versions and configure snippets, so an SDK change and the matching command change
land in one PR. `scripts/check_cli_sdk_versions.mjs` fails when the versions in
`cli/src/constants.ts` drift from `android/gradle.properties`, `ios/Clikgate.podspec`,
`flutter/pubspec.yaml` or `react-native/package.json`. Flags, edits, doctor, fixtures and publishing:
[docs/SETUP_COMMAND.md](docs/SETUP_COMMAND.md); decisions: [cli/DECISIONS.md](cli/DECISIONS.md).

## Samples

Each sample demonstrates direct and deferred deep links, apply code / referred-by and push-token
registration (spec deliverable 6):

| Sample | Path | Notes |
|---|---|---|
| Flutter (primary demo) | [`flutter/example`](flutter/example) | Two variants, `--dart-define=CLIKGATE_VARIANT=backend\|engage`: with the sample backend (recommended path), or the Engage add-on without a backend. Invite, stats, weekly leaderboard with live ranks and "my rank" in both; promo codes in the Engage variant. [docs/flutter.md §9](docs/flutter.md#9-example-app-two-variants) |
| Sample backend | [`samples/backend`](samples/backend) | FastAPI (Python 3.12): demo login with identity tokens, referral link / stats, leaderboards and server-side purchase events through the Clikgate control-plane API. The API key and identity secret stay on the server |
| Android | [`android/sample`](android/sample) | Kotlin, core SDK + Engage invite/stats; optional FCM via `-Pclikgate.firebase*` |
| iOS | [`ios/Sample`](ios/Sample) | Swift (xcodegen), core SDK + Engage invite/stats, APNs token |
| React Native | [`react-native/example`](react-native/example) | Bare RN, core + Engage screens |

How to run each one and what to test on devices: [docs/TESTING_DEEP_LINKS.md](docs/TESTING_DEEP_LINKS.md) §7.

## Link domains

Pass your app's **link subdomain** (`yourapp.ciz.to`, or `yourapp.clk.ng` on the Free plan; debug builds also `yourapp.dev.ciz.to`) and **every**
custom link domain of your domain group as `linkDomains` (aliases such as `ybr.ng` and `go.yourbrand.com` serve
the same links) and declare each one in the app: iOS Associated Domains
`applinks:<domain>`, and an Android `autoVerify` intent filter host. The OS opens the app only for
declared domains. The SDKs also add the domains the server returns in `/v1/sdk/config`
(`link_domains`) and log a warning for each one missing from `linkDomains`. Never declare a shared domain
(`ciz.to`, `clk.ng`, `clkg.to`, `dev.ciz.to`): from change 09 their app-links files list no customer app, so
they can't open yours. Platform details are in each guide.

## Consent, privacy and growth features (SDK 1.2.0, change 03)

Every SDK has a consent API (`setConsent`, `getConsent`, `setConsentRegion`; buffering in consent
regions), Google click ids (`gclid` / `gbraid` / `wbraid`), the minimum-SDK-version policy, Firebase
forwarding (`enableFirebaseForwarding`, Firebase detected at runtime), `attributionMetadata()` for
sales matching, and on iOS DeviceCheck / App Attest identity checks, the opt-in clipboard deferred
link and Google on-device measurement (`enableGoogleOnDeviceMeasurement`). The iOS SDK no longer
collects any probabilistic-matching or fingerprinting signal (see `ios/CHANGELOG.md` "Privacy").
Behaviour: [shared/SDK_BEHAVIOUR.md](shared/SDK_BEHAVIOUR.md) "Change 03"; wire format:
[shared/API_CONTRACT.md](shared/API_CONTRACT.md) "Change 03 additions".

## Send goals: one `goal()` method (Payment goals, enums)

Every SDK has one `goal()` method for the outcomes the business chose (`account_opened`, `loan_disbursed`,
`purchase`), with an optional value in normal units, currency, reference and payment `provider`:

| Platform | Example |
|---|---|
| Android | `Clikgate.goal("purchase", reference = "T123456", provider = Provider.PAYSTACK) { r -> }` |
| iOS | `Clikgate.shared.goal("purchase", reference: "T123456", provider: .paystack) { r in }` |
| Flutter | `final r = await Clikgate.goal('purchase', reference: 'T123456', provider: ClikgateProvider.paystack);` |
| React Native | `const r = await Clikgate.goal('purchase', { reference: 'T123456', provider: ClikgateProvider.Paystack });` |

- The result has `status` (`GoalStatus`: counted, waiting or refused), `reason`, `goalKind` (`GoalKind`: standard or
  payment, when Clikgate said) and `valueIgnored`.
- A goal's kind is set in the dashboard, never in the call. On a **Payment goal** the app only reports the
  payment: send the gateway's `provider` and its payment `reference`. It is `waiting` until the payment provider
  or the business's server confirms it, with the real amount; a value the app sends is ignored.
- The `Provider` type is generated from Clikgate's provider list (`shared/providers.json`, from the backend's
  OpenAPI `Provider` enum) by `scripts/generate_providers.py`; CI runs it with `--check`. `fromString(...)` takes a
  provider added after the SDK release (the server checks it).
- With a test SDK key (`cg_sdk_test_…`) the SDKs log one line when a Payment goal is waiting and when a value was
  ignored.
- Goals share the event queue, consent buffering and retries, and are idempotent by key and reference. **Never put
  customer data in goal calls; use the business's reference only.** In an organisation's **private mode** the SDKs
  stop sending the customer ID of `identifyUser()`, event properties and event revenue; goals still work.
- `payment()` (Change 11) is removed on every platform. Behaviour: [shared/SDK_BEHAVIOUR.md](shared/SDK_BEHAVIOUR.md)
  "Change 12"; wire format: [shared/API_CONTRACT.md](shared/API_CONTRACT.md) "Change 12 additions".

## Password and country-restricted links on app opens (Change 17)

App Links and Universal Links open the app without Clikgate's redirect, so `/v1/sdk/resolve` runs the link's gates.
A password link opens its password page in the system browser (nothing is delivered); a link blocked for the
visitor's country (or by a block rule) arrives on the deep-link callback with `blockMessage` set and no path, click
or link. A/B tests: the server picks the version and its path arrives as usual. Behaviour:
[shared/SDK_BEHAVIOUR.md](shared/SDK_BEHAVIOUR.md) "Change 17"; wire format: [shared/API_CONTRACT.md](shared/API_CONTRACT.md)
"Change 17 additions".

## Shared-domain links of other organisations (native SDKs 1.4.0, Flutter 1.4.0, React Native 1.5.0)

`ciz.to`, `clk.ng`, `clkg.to` and `dev.ciz.to` are Clikgate's shared platform domains, so the OS can
open an app for another organisation's link on them. When `/resolve` answers `matched: false` for
such a link, the SDKs open it in an in-app browser (Android Custom Tabs in an explicit browser
package, iOS `SFSafariViewController`; never an implicit intent or `UIApplication.open`, which could
loop back into the app), deliver no deep link, and report a browser handoff (`onBrowserHandoff` on Android, Flutter and React
Native; the `Clikgate.browserHandoffNotification` notification on iOS). Option `platformDomainBrowserFallback` (default on) turns it off. Behaviour:
[shared/SDK_BEHAVIOUR.md](shared/SDK_BEHAVIOUR.md) "Change 06 (SDK 1.4.0)"; contract:
[shared/API_CONTRACT.md](shared/API_CONTRACT.md) "Shared platform domains".

## Consistency fixes (native SDKs 1.5.0, Flutter 1.5.0, React Native 1.6.0, setup command 1.1.0, change 09)

- `ClikgateMoney.ofMinor(amountMinor, currency)` is the `track()` revenue helper on every platform (the old
  constructors stay as deprecated aliases).
- `/install` sends the four-purpose consent object only; an opted-out first install sends every purpose
  `denied` (no more `tracking_allowed`).
- Goals keep one random `Idempotency-Key` per request, reused by its retries.
- Apps open links from their own **app link subdomain** (`yourapp.ciz.to`, debug builds `yourapp.dev.ciz.to`)
  and the organisation's custom domains, never from the shared domains `ciz.to`, `clk.ng`, `clkg.to` or
  `dev.ciz.to`. The setup command writes that, and `doctor` flags shared domains left in a project.
- Leaderboard trophies, challenges and progress are server API and webhooks only: no SDK has them.

Contract: [shared/API_CONTRACT.md](shared/API_CONTRACT.md) "Change 09 additions"; behaviour:
[shared/SDK_BEHAVIOUR.md](shared/SDK_BEHAVIOUR.md) "Change 09".

## Deep links on every plan (change 10)

- Deep links into your app work on every plan, Free included: direct links without a limit, deferred deep
  links 1,000 a month on Free and 10,000 on Starter (unlimited on Growth and up).
- On Free the app's link subdomain is `yourapp.clk.ng` in release builds (`yourapp.ciz.to` on Starter and up);
  debug builds use `yourapp.dev.ciz.to` on every plan. The setup command and `doctor` handle both. An app
  subdomain under `clk.ng` is not a shared domain.
- Install attribution, in-app events and goals need **Growth**. On Free and Starter `goal()` and `track()` log
  one "needs Growth" warning and do nothing (no error); attribution reads `organic`.
- At the monthly deferred deep link allowance the SDK gets the normal "no deferred link" result (the app opens
  its home screen), never an error.

Contract: [shared/API_CONTRACT.md](shared/API_CONTRACT.md) "Change 10 additions"; behaviour:
[shared/SDK_BEHAVIOUR.md](shared/SDK_BEHAVIOUR.md) "Change 10".

## Replacing Firebase Dynamic Links (change 21)

Firebase Dynamic Links has shut down. Each guide shows the Firebase calls and the Clikgate calls side by side:
[Android](docs/android.md#4a-replacing-firebase-dynamic-links), [iOS](docs/ios.md#3a-replacing-firebase-dynamic-links),
[Flutter](docs/flutter.md#3a-replacing-firebase-dynamic-links),
[React Native](docs/react-native.md#3a-replacing-firebase-dynamic-links).

## Removing the SDK

Each guide has a "Removing the SDK" section: [Android](docs/android.md#12-removing-the-sdk),
[iOS](docs/ios.md#11-removing-the-sdk), [Flutter](flutter/README.md#removing-the-sdk),
[React Native](react-native/README.md#removing-the-sdk). In short: remove the dependency, `configure` and
every call, the Associated Domains / intent filters / URL schemes, and push-token forwarding (uninstall
tracking), then mark the app as no longer tracked in the Clikgate dashboard.

## Shared contract

[`shared/`](shared) is the single source of truth every SDK and the backend implement:

- [API_CONTRACT.md](shared/API_CONTRACT.md): every `/v1/sdk` endpoint, header, body, error code
  and the retry policy.
- [SDK_BEHAVIOUR.md](shared/SDK_BEHAVIOUR.md): lifecycle, storage, queueing, deep-link delivery,
  pasteboard, push tokens, opt-out.
- [PLATFORM_CHANNEL.md](shared/PLATFORM_CHANNEL.md): the bridge contract for Flutter and React Native.
- `schemas/` (JSON Schema) and `fixtures/` (example payloads), generated by
  `python3 shared/generate.py`. SDK unit tests decode the fixtures; the backend tests validate
  its responses against the schemas.

Change a field in the contract, the schemas, the backend and every SDK together.

## Docs

- [engage.md](docs/engage.md): core SDK vs Engage add-on vs the recommended backend path.
- [PRIVACY.md](docs/PRIVACY.md): what is collected, why, retention, probabilistic matching policy.
- [TESTING_DEEP_LINKS.md](docs/TESTING_DEEP_LINKS.md): the device test matrix, step by step.
- [RELEASING.md](docs/RELEASING.md): tags, what each release job publishes, and the publish order
  (native → Flutter / RN core → Flutter / RN Engage → setup command).
- [SETUP_COMMAND.md](docs/SETUP_COMMAND.md): `npx @clikgate/setup` and `doctor`.
- `docs/spec/`: the build specification.
- Each SDK (and `cli/`) keeps a `DECISIONS.md` with platform-doc findings and judgement calls.

## Building

| | Command |
|---|---|
| Android | `cd android && ./gradlew :clikgate:testDebugUnitTest :clikgate-engage:testDebugUnitTest apiCheck :clikgate:assembleRelease :clikgate-engage:assembleRelease :sample:assembleDebug` |
| iOS | `cd ios && xcodebuild test -scheme Clikgate-Package -destination 'platform=macOS,variant=Mac Catalyst'` (core + Engage tests, no simulator) |
| Flutter | `cd flutter && flutter pub get && flutter analyze && flutter test`, same in `flutter_engage/` and `flutter/example/` (Flutter 3.35) |
| Sample backend | `cd samples/backend && python3.12 -m venv .venv && .venv/bin/pip install -r requirements-dev.txt && .venv/bin/python -m pytest` |
| React Native | `cd react-native && npm ci && npm test`; `cd react-native-engage && npm run devlink && npm test` |
| Core / Engage boundaries | `scripts/check_sdk_boundaries.sh` (API snapshots, "no Engage API in core", "core never depends on Engage", size budgets) |
| Setup command | `cd cli && npm ci && npm run typecheck && npm test && npm run build` (output `cli/dist/cli.cjs`); `node scripts/check_cli_sdk_versions.mjs` (versions it writes = the SDKs here) |

CI workflows are in `.github/workflows/` (one per SDK, each with a release job on its own tag
prefix: `android-v*`, `ios-v*`, `flutter-v*` / `flutter-engage-v*`, `react-native-v*` /
`react-native-engage-v*`; plus `sdk-boundaries.yml` running `scripts/check_sdk_boundaries.sh`, and `cli.yml` /
`cli-release.yml` for the setup command on `cli-v*`, npm trusted publishing). Releases need the publishing
secrets described in each workflow and have not been run yet; the order is in
[docs/RELEASING.md](docs/RELEASING.md).

## Licence

This repository has mixed licences:

- **Apache License 2.0** for every mobile SDK (Android, iOS, Flutter, React Native and the Engage
  add-ons; owner decision 2026-10-26): [LICENSE](LICENSE), with the same text in `ios/`, `flutter/`,
  `flutter_engage/`, `react-native/` and `react-native-engage/` for their packages. The Android POM,
  the podspecs and the SDK `package.json` files declare `Apache-2.0`.
- **MIT** for the setup command in `cli/`: [cli/LICENSE](cli/LICENSE), and `"license": "MIT"` in
  `cli/package.json` (it kept its licence when it moved here from `clikgate_sdks`, owner decision
  2026-10-26).

The server SDKs and AI guides in `clikgate_sdks` are MIT.
