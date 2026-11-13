# Flutter packages — decisions

> **2.1.0 (2026-11-12): the Engage add-on is merged into this package.** See [docs/DECISIONS.md](../docs/DECISIONS.md) "One package per SDK". Entries below that describe Engage as a separate package, module or subspec are history; the core/Engage boundary and the size budgets they describe still apply.

The plugin's earlier decisions (bridge, composite build, example pins) are recorded in
`android/DECISIONS.md` ("Flutter plugin ↔ native SDK", "Flutter example") and
`ios/DECISIONS.md`. This file covers the Flutter-specific parts of the Engage split.

## Engage split (spec v3 new edition, 0.4 / 17A) — 2026-10-21

### Packages and location

- `clikgate_flutter` (`flutter/`) is the **core** plugin: configure, deep links, attribution,
  track, identify, opt-out, push token / `isClikgateMessage`, `handleUrl`, `nativeSdkVersion`,
  `isFeatureEnabled`, `referrals.applyCode` / `referredBy`, plus the internal
  `getRequestContext()` / `reportServerError()`.
- `clikgate_engage` lives at **repo-root `flutter_engage/`**, not under `flutter/`: a package
  nested in `flutter/` would be swept into the plugin's pub archive (pub includes every file
  of the package directory unless `.pubignore`d) and `flutter analyze` / `flutter test` in
  `flutter/` would pick it up. A sibling directory keeps both pub layouts independent and
  valid (`flutter pub publish --dry-run` passes for both: 0 warnings for the plugin; 0 warnings
  and 1 hint for Engage, see below).
- Engage depends on `clikgate_flutter: ^2.0.0` (hosted constraint, as published). In the
  monorepo `flutter_engage/pubspec_overrides.yaml` points it at `../flutter`; that file is in
  `.pubignore` and the `release-engage` CI job deletes it before publishing, so the published
  package resolves the hosted core. The dry run reports the override as a hint. The example
  app needs its own `dependency_overrides: clikgate_flutter: path: ../` because overrides are
  not transitive and two sources (path + hosted) for one package are rejected by pub.
- Publish order: `clikgate_flutter` (tag `flutter-v*`), then `clikgate_engage`
  (tag `flutter-engage-v*`).

### How Engage gets the context

- Channel method `getRequestContext` (`{}` → `{installationId, sdkKey, environment, apiBaseUrl,
  identityToken, customerUserId, sdkVersion, nativeSdkVersion}`) calls the native core's
  internal API: Android `Clikgate.requestContext` (`@ClikgateInternalApi`), iOS
  `Clikgate.shared.requestContext()` (`@_spi(ClikgateEngage)`). The native core applies its
  gates (not configured, opted out, invalid key, kill switch), waits for the first `/install`
  (Android up to 10 s; iOS `install_pending` immediately — existing platform behaviour) and
  sends a pending `identify` first. `sdkVersion` is `flutter/<plugin version>` (the plugin calls
  `setWrapper` before `configure`), `nativeSdkVersion` `android/…` / `ios/…`.
- `reportServerError` (`{code, feature}`) lets Engage hand a server `feature_disabled` body or a
  global error (`invalid_sdk_key`, `sdk_disabled`, `installation_unknown`) back to the native
  core, which switches the feature off in memory / applies its global rules.
- Dart: `Clikgate.getRequestContext()` and `Clikgate.reportServerError(code, feature:)` on the
  main `Clikgate` class, doc-commented as internal (not a separate library): `package:meta`'s
  `@internal` would warn in `clikgate_engage` itself, which is a different package, and the RN
  package uses the same placement (`Clikgate.getRequestContext()`).
- Engage takes an `EngageCore` (default `ClikgateCoreBridge` over those methods); tests pass a
  fake, so Engage tests need no platform channel.

### Engage implementation

- Pure Dart: `http` for the calls; no `android/` / `ios/` directories and no `plugin:` section
  (asserted by `flutter_engage/test/api_snapshot_test.dart`). It depends on two federated
  plugins (`share_plus`, `url_launcher`) for the share helpers; their native code is theirs.
  `share_plus` is `>=12.0.0 <13.0.0` (the example pins 12.0.x, contemporary with Flutter 3.35);
  `url_launcher ^6.3.1`. *(Superseded in 2.1.0: see "Share helpers without share_plus / url_launcher".)*
- 17A.3 rules: `isFeatureEnabled` first (no context call, no network when off); then the context;
  `not_identified` without network for `createLink`, `myStats`, `me`, `aroundMe`, `setOptOut`,
  `hostedPageUrl` when `customerUserId` is null. `identity_required` is left to the server: the
  core plugin doesn't expose the program config (`require_identity_token`), and the server is
  authoritative anyway.
- Cache: successful GET reads (`myStats`, `top`, `me`, `aroundMe`) for 60 s in memory, keyed by
  installation id, user id, whether a token is set, method and full URL. Writes (`createLink`,
  `setOptOut`, `redeem`) clear the whole cache; `clearCache()` is public (the example clears it
  before its 15 s live refresh). `hostedPageUrl` (`/me?embed=1`) is never cached: the embed
  token is short-lived.
- Retries: one retry after 500 ms, only for `http.ClientException`, `SocketException`,
  `HandshakeException` and `TimeoutException` (10 s per request). HTTP errors (429, 5xx) are
  surfaced immediately as `ClikgateException` (`status` set).
- Errors reuse the core's `ClikgateException` (`code`, `message`, `status`, `param`, `feature`,
  `offlineTouchId`); Engage-only codes are in `ClikgateEngageErrors` (`not_identified`,
  `share_unavailable`, `hosted_page_unavailable`). Missing error codes map like the native SDKs
  (401 `invalid_sdk_key`, 422 `validation_error`, 429 `rate_limited`, 5xx `server_error`,
  else `http_<status>`).
- `hostedPageUrl` returns the response's `embed_url` (added by the backend to
  `/v1/sdk/leaderboards/{id}/me?embed=1`); without it (older server): `hosted_page_unavailable`.
- Models parse the API's snake_case JSON directly (`fromJson`); they are no longer bridge maps.
  `Redemption.referral` is the core's `Referral`, built by Engage from the snake_case object.

### Share helpers in pure Dart *(superseded in 2.1.0, see below)*

- `share.system` → `share_plus` (`SharePlus.instance.share(ShareParams(text:, subject:))`).
- `share.whatsApp` → `url_launcher.launchUrl(whatsapp://send?text=…, externalApplication)` with
  RFC 3986 unreserved-only percent-encoding (same as the iOS SDK); `false` or an exception →
  `share.system`, returns `false`. Checked in the plugins' sources: `url_launcher_ios` 6.4
  `launchUrl` calls `UIApplication.open` without `canOpenURL`, so no
  `LSApplicationQueriesSchemes` entry is needed (still recommended in the docs);
  `url_launcher_android` catches `ActivityNotFoundException` (no `<queries>` entry needed for
  `launchUrl`).
- **Difference from the native Android Engage module:** pure Dart can't send an `ACTION_SEND`
  intent with `setPackage("com.whatsapp")`, so WhatsApp Business (`com.whatsapp.w4b`) is only
  reached if it handles `whatsapp://`; otherwise the share sheet offers it. A tiny channel in the
  core would have avoided this but would put share code in the core, which spec 0.4 forbids.

### Share helpers without share_plus / url_launcher — 2026-11-13 (2.1.0, before release)

- **Why:** once Engage was merged into `clikgate_flutter`, `share_plus` (`>=12 <13`) and
  `url_launcher` became dependencies of every Flutter app: apps on `share_plus` 13 couldn't resolve
  the plugin, and a fresh `flutter create` app's release build failed in
  `:url_launcher_android:lintVitalAnalyzeRelease` (lint crash on `UrlLauncher.java`). Flutter
  packages are thin bridges, and the plugin already has a native Engage channel.
- **How:** the default `EngageTextSharer` / `EngageUrlOpener` call the plugin's
  `com.clikgate/engage` channel (`EngageShareBridge`, beside `shareLink`):
  - `shareText {text, subject?}` → Android `ACTION_SEND` text/plain (+ `EXTRA_SUBJECT`) in a
    chooser, started from the Activity (`ActivityAware`) or, without one, from the application
    context with `FLAG_ACTIVITY_NEW_TASK`; `ActivityNotFoundException` → `share_unavailable`.
    iOS `UIActivityViewController` from the top view controller (iPad popover anchored at its
    centre), the subject through `UIActivityItemSource`; no view controller → `share_unavailable`.
    It answers once the sheet is presented (share_plus waited for it to close; the Dart API returns
    `void` either way).
  - `openUrl {url}` → Android `ACTION_VIEW` (new task without an Activity), `false` on
    `ActivityNotFoundException`; iOS `UIApplication.open` without `canOpenURL`, answering its
    completion result.
- Not the native SDK's `ClikgateEngage.share.system` / `whatsApp`: `system` takes no subject, and
  `whatsApp` on iOS checks `canOpenURL` (needs `LSApplicationQueriesSchemes`) while on Android it
  targets packages instead of `whatsapp://`. Using them would change the Dart behaviour; the
  bridge code is ~40 lines per platform. Dart API and results are unchanged (snapshots unchanged):
  `share.system` maps any error to `share_unavailable`; `share.whatsApp` returns `false` after the
  share sheet when the open fails or throws. Tests can still pass `openUrl` / `shareText`.
- The example keeps `share_plus` (12.0.x) for its backend variant's own share button; it is the
  app's dependency, not the plugin's.
- **RunnerTests host:** the example's `main.dart` asks its AppDelegate
  (`com.clikgate.example/host` `isUnitTestHost`, true when `XCTestConfigurationFilePath` is set)
  and skips `Clikgate.configure` / the UI under XCTest, so the plugin's unit tests see an
  unconfigured SDK. Example-only; the plugin behaves the same.

### Boundary checks (spec 20)

- `test/api_snapshot_test.dart` in both packages lists the main library's public API
  (follows `export … show/hide`, public declarations and members, signatures only) with
  `package:analyzer`'s syntactic `parseFile` (dev dependency; no resolution, so it is fast and
  independent of the SDK version) and compares it with `test/api_snapshot.txt`
  (`UPDATE_API_SNAPSHOT=1` rewrites it). The helper `test/api_listing.dart` exists in both
  packages; a test asserts the copies are identical.
- The core test also fails on any forbidden token in the listing (leaderboard, createLink,
  myStats, ReferralLink/Stats, redeem, Redemption, share, whatsapp, identitySignal, MyRank,
  hostedPage; the feature-key constants `ClikgateFeatures.leaderboards` /
  `whatsappAttribution` are allowed), on `clikgate_engage` in `pubspec.yaml` or an import of it
  in `lib/`, and on an Engage module / product / artifact reference in the plugin's native code
  (`import ClikgateEngage`, `"ClikgateEngage"`, `clikgate-engage`, `Clikgate/Engage`; the
  core's `@_spi(ClikgateEngage)` request-context API is allowed).
- `flutter/tool/check_api.sh [--update]` runs both snapshot tests (used by CI and the root
  `scripts/check_sdk_boundaries.sh`).
- No size budget applies to the Dart packages (the spec's budgets are for the native SDKs).

## Example variants (spec 17A.4) — 2026-10-21

- **One entrypoint, build-time switch** `--dart-define=CLIKGATE_VARIANT=backend|engage` (default
  `backend`, the recommended path in every guide), rather than `main_backend.dart` /
  `main_engage.dart`: one `flutter run` command shape, one set of run configurations, and the
  same Android / iOS project (no flavors). The value is a `const String.fromEnvironment`, so
  the `switch` in `createFeatures()` is resolved at compile time and the other implementation is
  tree-shaken. An unknown value throws at start-up.
- Screens are shared and talk to a small `ReferralFeatures` interface
  (`lib/src/variants/features.dart`, a `ChangeNotifier` exposed through an `InheritedNotifier`)
  with app-level models (`InviteLink`, `InviteStats`, `BoardPage`, `BoardEntry`, `BoardRank`,
  `AppError`). `BackendFeatures` uses `package:http` against `samples/backend`;
  `EngageFeatures` wraps `clikgate_engage` and maps `ClikgateException` to `AppError`. The core
  screens (apply code, referred-by banner, product / welcome, push) call `clikgate_flutter`
  directly in both variants.
- Backend variant: demo login → session token + identity token signed by the backend →
  `Clikgate.identify(id, identityToken:)` (verified identity). Invite / stats / leaderboard
  calls carry the session (`Authorization: Bearer`). The share button uses `share_plus`
  directly (the app's own dependency, not the plugin's); there is no WhatsApp deep link in this variant (the helper lives in Engage, and the
  share sheet offers WhatsApp). "Buy something" posts `/orders` (the backend sends the `purchase` goal;
  Change 22: there is no app-side event call). Promo codes are not in the backend variant (a backend would redeem them
  server-side with `POST /v1/codes/redeem`; not part of the sample backend).
- Engage variant: `Clikgate.identify(id)` without a token (no backend to sign one), so the
  program must not set `require_identity_token`; the "hide me" switch (`setOptOut`) and promo
  codes exist only here.
- `clikgate_engage` stays a dependency of the example for both variants (it is the same app);
  the backend variant never imports it at runtime (tree-shaken). `http` moved from dev to
  regular dependencies.
- The sample backend's `/leaderboards/*` JSON mirrors the SDK's `leaderboard_page` / `my_rank`
  shapes, so both implementations map to the same models with little code.
- Tests: `test/backend_variant_test.dart` (6, fake of the sample backend's HTTP API),
  `test/engage_variant_test.dart` (5, fake core + mocked `/v1/sdk/*`),
  `test/core_screens_test.dart` (4, home for both variants, apply code). The home test enlarges
  the test view so the whole list is built.

## Change 03 — 2026-10-22

- **Bridge only.** Consent, buffering, click ids, version policy, Firebase forwarding and identity
  checks live in the native SDKs; the plugin adds six channel methods (`setConsent`, `getConsent`,
  `setConsentRegion`, `enableFirebaseForwarding`, `attributionMetadata`,
  `enableGoogleOnDeviceMeasurement`) and no logic.
- **Omitted = unchanged.** `setConsent` sends only the purposes the caller passed (the native
  APIs take nullable states), so a banner can update one purpose. Values are the enum names
  (`granted` / `denied` / `unknown`); the native sides reject other strings with
  `invalid_argument` + `param`.
- **Region validated in Dart** (`^(EEA|UK|[A-Z]{2})$` after trim + uppercase) and thrown as
  `ClikgateException(invalid_argument, param: region)` without a channel call, so both platforms
  behave the same (the native SDKs only log and ignore). The native plugins validate again.
- **Before `configure`.** The new methods are handled before the "not configured" gate on iOS (the
  iOS SDK keeps them until configure); Android queues them in the SDK as before.
- **Firebase.** The plugin doesn't depend on `firebase_analytics`; the native SDKs find Firebase
  Analytics at runtime (reflection / `NSClassFromString`). The example keeps only
  `firebase_messaging` (pinned FlutterFire 4.1 / 16.0) and documents adding `firebase_analytics`.
- **`enableGoogleOnDeviceMeasurement` on Android** returns `null` (Google's on-device measurement is
  iOS-only), so cross-platform Dart code needs no platform check.
- **Default `pasteboardMode: off`** (Dart default and the iOS plugin's fallback for a missing
  value), matching the iOS SDK 1.2.0 default.
- Verified: `flutter analyze` / `flutter test` in `flutter/` (48), `flutter_engage/`, `flutter/example/`
  (16), `tool/check_api.sh` (snapshot updated), the Android plugin Kotlin through the example's
  composite build (`:clikgate_flutter:compileDebugKotlin` against the 1.2.0 core sources), and
  `swiftc -typecheck` of the iOS plugin against a module built from `ios/Sources/Clikgate` (arm64
  iOS 13, Flutter.xcframework from the 3.35.4 engine cache). Not run: the example on a device or
  simulator.

## Change 06 — goals and private mode (SDK 1.3.0, 2026-10-24)

- **Contract led from `shared/`** (with the backend): `POST /v1/sdk/goals` is a **batch** like `/events`
  (`{"goals": [...], "consent": ...}` → `{accepted, duplicates, rejected[]}`), so goals reuse the event
  queue, its limits, consent buffering and retry policy instead of a second queue. Items are
  `additionalProperties: false` and hold only allow-listed fields (goal, reference, value, currency,
  is_first, occurred_at, click_id), so the same body is valid in private mode. `private_mode` is a
  top-level optional config boolean (absent = off). Every new field is optional both ways; a server without
  the route answers 404, on which the SDK drops the goals (one bad route mustn't block the event queue).
- **Value is a decimal string on the wire**, never a JSON number, so no floating point is involved
  anywhere between the app and the backend's decimal parser. Normalised form: no sign/exponent/leading
  zeros, trailing fractional zeros removed. "15 significant digits" = digits left after removing leading
  zeros and trailing fractional zeros (`0.005` = 1, `2000000` = 7). Currency decimal places and
  `value_mode` are checked by the server only (the SDK doesn't know the goal), and rejected items are dropped.
- **Reference**: required on the wire; a UUIDv4 is generated at `goal()` time when the app passes none and
  kept across retries. Idempotency: the server dedupes `(goal, reference)`; the SDK additionally ignores a
  `goal()` whose `(key, reference)` is already queued.
- **Order**: events and goals keep queue order; `flush()` sends the leading run of one kind per request
  (one request in flight, as before).
- **click_id**: captured at `goal()` time from the latest matched deep link, else the install's click
  (the `attributionMetadata()` source, without its consent gate: the goal itself waits for consent). Null
  lets the backend attribute through the installation.
- **Private mode**: `identify()` is dropped on the device (not stored) and a pending one is discarded with
  its user id and token; event `properties`, `revenue_minor` and `currency` are stripped **at send time**,
  so events queued before the config said so are covered too ("value only through goal()", B.5). There is
  no user-properties API in the core SDKs; the Firebase `cg_first_*` user properties go to the app's own
  Firebase, never to Clikgate, so they're unchanged. The warning is logged once per launch and only in
  debug builds.
- **Consent**: goals are events for the change 03 gate (buffered while `attribution` is unknown, dropped on
  deny, cleared by opt-out), so no new consent rule was needed.
- **Logging**: goal references and values are never logged (validation errors name the field only;
  rejections log a count).
- **Pending**: the change 05 AI guides (`sdks/ai-guides/`: `api-surface.md`, a "Track your end goal"
  section per platform, the "never put customer data in goal calls" assistant rule) — change 05 was never
  built in this workspace. The rule is in each platform doc's "Track your end goal" section instead.
- **Bridge**: one `goal` method; the value crosses the bridge as a decimal string, converted from
  numbers with the language's shortest round-trip representation. Numbers printed with an exponent,
  NaN and infinity are rejected locally (pass a string for those amounts); everything else is validated
  natively. Private mode needs no bridge method (the native SDK reads the config).

## Change 06 — shared-domain browser fallback (plugin 1.4.0, native 1.4.0, 2026-10-26)

- **What**: the native SDKs open another organisation's unmatched shared-domain link (`ciz.to`, `clk.ng`,
  `clkg.to`, `dev.ciz.to`) in an in-app browser; the plugin only passes the option and the event through
  (shared/SDK_BEHAVIOUR.md "Change 06 (SDK 1.4.0)"). The shared-domain list lives in the native SDKs only.
- **Event transport**: the handoff rides the existing `com.clikgate/deep_links` EventChannel as a tagged
  map `{event: "browserHandoff", url, host}` instead of a second EventChannel, so the native buffers
  (latest 10, before Dart listens) and the engine fan-out stay single. The Dart hub routes tagged maps to
  `onBrowserHandoff`; deep-link maps have no `event` key. Both streams buffer and replay to their first
  subscriber.
- **Option**: `platformDomainBrowserFallback` (default true). The spec doesn't mention the fallback at all
  (it is an owner request), so an off switch doesn't conflict with it.
- **Version**: 1.3.0 → **1.4.0** (minor: new public API, and the native dependency moves to 1.4.0;
  the "same minor as the native SDKs" rule in `test/version_test.dart` holds).
- The option is named `platformDomainBrowserFallback` (not `shared...`): every SDK's core/Engage boundary
  check forbids `share` in the public API (Engage share helpers), and "platform domains" is the spec's own
  term for these four short domains.

## Licence: Apache 2.0 (2026-10-26)

Owner chose Apache 2.0 for all mobile SDKs; clikgate_sdks stays MIT. The canonical text
(https://www.apache.org/licenses/LICENSE-2.0.txt, SHA-256 `cfc7749b…3d30`) is the root `LICENSE` and an
identical copy in each package directory that ships one (`ios/`, `flutter/`, `flutter_engage/`,
`react-native/`, `react-native-engage/`); metadata: POM (already Apache 2.0), podspecs
`{ :type => 'Apache-2.0', :file => 'LICENSE' }`, `package.json` `"license": "Apache-2.0"`, pubspec
packages read their `LICENSE`.

## Change 12: one `goal()` method, Payment goals, enums (2026-10-28)

- **`payment()` removed** with its bridge method, tests and docs (never released, no deprecation period).
  A payment is a `goal()` on a Payment goal with `provider` and `reference`; the goal's kind lives only in its
  settings, so nothing in the call (and no wrapper enum) can claim a kind.
- **`goal()` answers with a result** (`GoalResult`: `status`, `reason`, `goalKind`, `valueIgnored`) once the
  native SDK has the server's answer for that goal. The bridge keeps the channel result / promise open until
  then (it is lost if the process dies; the queued goal is still sent next launch). It never throws or rejects:
  local validation failures (`invalid_argument`) and native errors come back as `refused` with the code as
  `reason`, the same mapping the native SDKs use for a final 4xx. Unknown statuses decode as refused, unknown
  kinds as null, so a newer server can't break an older app.
- **The provider type is `ClikgateProvider`, not `Provider`.** Flutter apps very often use `package:provider`
  (whose main class is `Provider`) and React Native apps `react-redux` (which exports `Provider`); a second
  `Provider` export would force import prefixes or aliases on them. Android keeps `Provider` (packages make it
  unambiguous) and iOS uses the module's `Clikgate` prefix like every other type. `GoalStatus`, `GoalKind` and
  `GoalResult` have no clash and keep the spec's names.
- `ClikgateProvider` is generated (`scripts/generate_providers.py` from `shared/providers.json`, the backend's
  OpenAPI `Provider` enum); don't edit the generated file. Flutter: a class with `const` constants, `values` and
  `fromString` (an open set, so not a Dart `enum`). React Native: a `const` object plus an open string type,
  `CLIKGATE_PROVIDERS` and `providerFromString`. Malformed keys give null; the server checks unknown ones.
- **Published packages carry no internal notes** (S.4): comments no longer cite change numbers, spec sections or
  repository documents; examples use fictional domains (`go.yourbrand.com`, `ybr.ng`).
- `flutter/.pubignore` keeps `DECISIONS.md`, `test/`, `tool/` and the example app's sources out of the pub
  package (the example app wires a local sample backend); the package ships `example/example.md`, and the full
  example stays in the repository. A `.pubignore` replaces the directory's `.gitignore` for pub, so it repeats
  those entries; its patterns are unanchored (`**/test/`) so they mean the same to pub and to
  `scripts/scan_release_packages.py`, which reads them relative to the repository root.

## Automatic push token on iOS (2.1.0)

- The plugin was already an application delegate (`registrar.addApplicationDelegate`), so it now forwards
  `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)` to `Clikgate.shared.setPushToken(deviceToken:)`
  whenever `automaticPushToken` is on (Flutter calls this void delegate method on every plugin, so
  `firebase_messaging` still gets it; no swizzling). Before 2.1.0 this needed Info.plist `ClikgateForwardAPNsToken`;
  that key still forces forwarding.
- "A manual token wins": once Dart calls `setPushToken` (typically the FCM token from `firebase_messaging`), the plugin
  stores `com.clikgate.flutter.manualPushToken` in `UserDefaults` and stops forwarding the APNs token. It is kept
  across launches because the APNs callback and the Dart call race on every launch; without it the stored token
  would flip between the APNs and FCM token and be re-sent twice per launch. Cost: an app that later stops calling
  `setPushToken` keeps the flag until reinstall (it can set `ClikgateForwardAPNsToken` = YES).
