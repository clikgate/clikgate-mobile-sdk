# React Native package — decisions

> **2.1.0 (2026-11-12): the Engage add-on is merged into this package.** See [docs/DECISIONS.md](../docs/DECISIONS.md) "One package per SDK". Entries below that describe Engage as a separate package, module or subspec are history; the core/Engage boundary and the size budgets they describe still apply.

Checked on 2026-10-20 against the npm registry (`npm view`) and the installed packages.

## Versions

| Item | Choice | Why |
|---|---|---|
| React Native (example, dev deps) | **0.86.3** | 0.88.0 is the latest release, but 0.87/0.88 declare `engines.node` `^22.13 \|\| ^24.3 \|\| >=26`, which excludes this machine's Node 25. 0.86.3 accepts `>= 25.0.0` and is the version Expo SDK 57 ships with (`expo@57` `bundledNativeModules.json`). |
| React | 19.2.3 | Paired with RN 0.86. |
| Peer range | `react-native >= 0.76` | 0.76 made the New Architecture the default; the module is a TurboModule. |
| Expo config plugins | `@expo/config-plugins ~57.0.10` (dev) | Matches Expo SDK 57. The plugin is built to `plugin/build` (CommonJS) and loaded from `app.plugin.js`. `expo` is an optional peer dependency. |
| RN community CLI | 20.1.0 | What `@react-native-community/cli init --version 0.86.3` generates. |
| Gradle / AGP / Kotlin (example) | Gradle 9.3.1, AGP 8.12.0, Kotlin 2.1.20 | RN 0.86 template and `@react-native/gradle-plugin` 0.86.3. |
| TypeScript | 6.0.x | What `create-react-native-library` 0.63.1 scaffolds; `typescript@7` (native port) is not yet supported by typescript-eslint. |
| Jest | 29.7 | `@react-native/jest-preset` 0.86.3 depends on `babel-jest` / `jest-environment-node` 29. |
| Build tool | `react-native-builder-bob` 0.43 | ESM output + `.d.ts`; `src/` stays the Metro source via the `clikgate-react-native-source` export condition. |
| Package manager | npm | The brief asks for `npm test`; root and `example/` are two separate npm installs (no workspaces: npm hoisting would move `react-native` away from where the example's Gradle/CocoaPods scripts look for it). `react-native-monorepo-config` (with `workspaces: []`) makes Metro resolve the package from `../src` and use the example's single copy of `react` / `react-native`. |

## Architecture: New Architecture only

- The native module is a **TurboModule** generated from `src/NativeClikgate.ts` (codegen name
  `RNClikgateSpec`, module name `Clikgate`, iOS class `RNClikgate` via `codegenConfig.ios.modulesProvider`).
- React Native 0.82 removed the legacy architecture, so a bridge-only (old-architecture) implementation
  can't be built or tested with a current React Native. The JS side uses `TurboModuleRegistry.get`, which
  falls back to `NativeModules.Clikgate` on old-architecture apps, and the Android codegen spec keeps
  `@ReactMethod` annotations, but **old-architecture apps are not supported or tested**.
- Deep links use `NativeEventEmitter` + event `ClikgateDeepLink` exactly as in
  shared/PLATFORM_CHANNEL.md (the spec declares `addListener` / `removeListeners`). iOS subclasses
  `RCTEventEmitter`; Android emits with `ReactContext.emitDeviceEvent`.

## Bridge contract deviations

- **Method names**: `referrals.createLink` etc. are not valid TurboModule method names (the dot). They
  are `referralsCreateLink`, `referralsApplyCode`, `referralsMyStats`, `referralsReferredBy`. Argument
  and result maps are unchanged.
- Every method takes the contract's argument map as one `UnsafeObject` (`getAttribution` and
  `referralsReferredBy` receive `{}`), so maps (`data`, `metadata`, `properties`) cross unchanged.
- Errors: Android `promise.reject(code, message, userInfo)`; iOS `reject(code, message, NSError)` with
  the NSError's `userInfo = {status, param}` (React Native copies it to the JS error's `userInfo`).
  JS reads `userInfo` (or `details`) and builds `ClikgateError(code, message, {status, param})`.
- Android: JS numbers arrive as doubles; whole numbers in `properties` are passed to the SDK as `Long`
  so they serialise as `3`, not `3.0`.
- Missing native module → `ClikgateError('unsupported_platform')` (same code as Flutter).

## v3 surface (feature switches, leaderboards, codes, WhatsApp)

- **Names**: `isFeatureEnabled`, `referralsShareToWhatsApp`, `leaderboardsTop`, `leaderboardsMe`,
  `leaderboardsAroundMe`, `leaderboardsSetOptOut`, `codesRedeem` (PLATFORM_CHANNEL.md without the dot);
  argument / result maps exactly as in PLATFORM_CHANNEL.md "v3 methods".
- **JS API shape**: id first plus an options object (`leaderboards.top(id, {period, segment, limit})`,
  `me(id, {period})`, `aroundMe(id, {radius})`), `codes.redeem(code)`; `setOptOut` and `shareToWhatsApp`
  take one options object like the other `referrals.*` methods.
- **`isFeatureEnabled` is async** (`Promise<boolean>`): all bridge methods are promise-based; a synchronous
  TurboModule method would block the JS thread on the native lock for little gain.
- **Feature-disabled**: the native SDKs fail fast from the cached config and recognise the server's
  `200 {"accepted": false, "reason": "feature_disabled"}` body; the bridge only forwards the rejection,
  with `userInfo.feature` = the native error's `feature` (both native `ClikgateError` types have it), the
  method's feature (`referrals`, `leaderboards`, `offline_codes`) as fallback, and `userInfo.offlineTouchId`
  for `codes.redeem` referral errors. JS also fills `feature` from the method when the
  rejection lacks it, and turns a resolved feature-disabled map into the same error, so the result is the
  same whichever layer detected it. JS does not pre-check `isFeatureEnabled` (that would add a bridge
  round trip to every call).
- **Validation in JS** before crossing the bridge: blank ids / code → `invalid_argument` (with `param`);
  `limit` must be an integer 1–100 and `radius` 1–25 (rejected, not clamped, so mistakes surface).
- **Decoding**: timestamps become `Date` (as in v1); `aroundMe` has no `name` / `metric` / `segment`
  (null in `LeaderboardPage`); `MyRank.rank`, `pending`, `gapToNext`, `bestRank` are nullable; unknown
  keys are dropped. `embed_token` (hosted page) is not part of the bridge map.
- **Period argument**: passed to the native SDKs as the raw contract string (`current`, `previous`, key)
  through one helper on each platform (`ClikgateModule.period`, `ClikgateRNImpl.period`) so a typed period
  in the native API is a one-line change.
- **Native timestamps** (period `startsAt`/`endsAt`, `periodEndsAt`) are converted to ISO strings in the
  bridge whatever the SDK model type (String, `Date`, `Instant`).
- **iOS** v3 calls use the SDK's async API inside `Task { @MainActor in }` (the WhatsApp share presents UI).
- **iOS bridge reconciled with the shipped iOS SDK (2026-10-21).** The bridge was written before the iOS
  v3 API existed; the method and type names it expected all shipped as written
  (`isFeatureEnabled(_:)`, `referrals.shareToWhatsApp(programId:message:displayName:)` — the SDK adds an
  optional `from:` presenter, defaulting to the top view controller —, `leaderboards.top(id:period:segment:limit:)`,
  `me(id:period:)`, `aroundMe(id:radius:)`, `setOptOut(programId:optOut:)`, `codes.redeem(_:)`,
  `ClikgateLeaderboardPage` / `Period` / `Entry`, `ClikgateMyRank`, `ClikgateRedemption` with nested
  `RedeemedCode`). Changes: the period argument is the SDK's `ClikgateLeaderboardPeriodSelector`
  (`ClikgateRNImpl.period` builds it from the raw string); timestamps come from the SDK's SPI raw strings
  (`startsAtRaw`, `endsAtRaw`, `periodEndsAtRaw`) so JS gets the server's string unchanged (the old
  `Date` → ISO formatter, which would have added `.000`, is gone); `Entry.rank` is non-optional in the SDK;
  `reject` now passes `feature` (error's, method's as fallback) and `offlineTouchId`, like the Android bridge.
- **Expo plugin**: `enableWhatsAppSharing` (default on) adds `whatsapp` to `LSApplicationQueriesSchemes`;
  without it `shareToWhatsApp` silently always uses the share sheet on iOS.

## Engage split (spec v3 new edition, 2026-10-21)

Spec 0.4 / 17A: the core package keeps only device responsibilities; referrer-side convenience calls
moved to `@clikgate/react-native-engage` (sibling directory `react-native-engage/`). The "v3 surface"
section above is superseded for `shareToWhatsApp`, `leaderboards.*` and `codes.redeem`.

- **Core.** Keeps `isFeatureEnabled` and `referrals.{applyCode, referredBy}`. New bridge methods
  `getRequestContext` (`{}` → `{installationId, sdkKey, environment, apiBaseUrl, identityToken,
  customerUserId, sdkVersion, nativeSdkVersion}`) and `reportServerError` (`{code, feature}` → null),
  exposed in JS as `Clikgate.getRequestContext()` / `Clikgate.reportServerError()`, documented as internal
  (`@internal` JSDoc; they stay in the type surface because Engage, a separate package, must call them).
  `reportServerError` never rejects (best effort). Android calls the `@ClikgateInternalApi`
  `Clikgate.requestContext` / `reportServerError`; iOS uses `@_spi(ClikgateEngage) import Clikgate`.
  `sdkVersion` in the context is `react-native/<version>` (the bridge calls `setWrapper` before configure)
  and `nativeSdkVersion` `android/…` / `ios/…`, so Engage sends the same headers as the core.
- **Engage is pure TypeScript** (`fetch`, React Native `Share` / `Linking`), peer-depends on
  `@clikgate/react-native` and `react-native`, no native code, no codegen. Everything injectable
  (`core`, `fetch`, `now`, `shareSheet`, `linking`, `timeoutMs`, `retryDelayMs`) for tests.
  - API shape: `new ClikgateEngage()` with `referrals.createLink({programId, displayName})`,
    `referrals.myStats({programId})`, `share.system({text, title})`, `share.whatsApp({text})`,
    `leaderboards.top(id, {period, segment, limit})`, `me(id, {period, segment})`,
    `aroundMe(id, {radius, period, segment})`, `setOptOut({programId, optOut})`,
    `hostedPageUrl(id, {period})`, `codes.redeem(code)`, `clearCache()`. Options objects like the core.
  - Every method is `async` (argument errors reject, never throw synchronously).
  - **Judgement call:** `limit` / `radius` are clamped (1–100 / 1–25), as in the native SDKs, instead of
    rejecting as the old core TS did.
  - Rules exactly as shared/SDK_BEHAVIOUR.md "Engage": feature check first (no network), context, user
    calls `not_identified` without `customerUserId`, 60 s in-memory cache keyed by installation + user +
    token presence + path/query, any write clears it, one retry only for network errors / 10 s timeout
    (`AbortController`), `feature_disabled` bodies and `invalid_sdk_key` / `sdk_disabled` /
    `installation_unknown` errors reported to the core.
  - Parses the API's snake_case bodies itself (models: `ReferralLink`, `ReferralStats`, `LeaderboardPage`,
    `LeaderboardEntry`, `LeaderboardPeriod`, `MyRank`, `Redemption`, `RedeemedCode`; dates as `Date`);
    `Redemption.referral` is the core `Referral` type.
  - **WhatsApp:** `Linking.openURL('whatsapp://send?text=…')` (RFC 3986 encoding), reject → `Share.share`.
    RN's `openURL` doesn't need `LSApplicationQueriesSchemes` (iOS) or `<queries>` (Android 11+): iOS
    `openURL:options:completionHandler:` and Android `startActivity` report failure → rejection. Pure TS
    can't target `com.whatsapp` / `com.whatsapp.w4b` by package like the native Android Engage module.
- **Tooling without a second install.** `react-native-engage/package.json` lists its real devDependencies
  (an `npm install` there works), but `npm run devlink` symlinks `node_modules` to
  `../react-native/node_modules` (same Jest / Babel / TypeScript / ESLint / bob versions) — used locally
  and in CI. Jest maps `@clikgate/react-native` to `../react-native/src` (so `ClikgateError` is the real
  class); `tsc` uses a `paths` entry. `bob build` resolves the core's types from
  `../react-native/lib/typescript` (`tsconfig.build.json`; build the core first); the published JS keeps
  the bare `@clikgate/react-native` import.
- **Example app.** Imports `@clikgate/react-native-engage`; `example/tsconfig.json` and the core
  `tsconfig.json` map it to `../react-native-engage/src`, and `example/metro.config.js` resolves it to the
  source, adds the folder to `watchFolders`, blocks its `node_modules` and resolves bare imports from
  Engage files as if from the example (one copy of `react-native` / the core). Checked with
  `npx react-native bundle --platform android` (bundles; no device run).
- **API snapshots.** `api/public-api.txt` in both packages (runtime exports, facade members, error
  constants, exported type names parsed from `src/index.ts`), checked by `src/__tests__/publicApi.test.ts`;
  the core test also fails on forbidden tokens (leaderboard, createLink, myStats, referral link/stats,
  redeem/redemption, share, whatsapp, identity signal, my rank, hosted page) and on a dependency on / import
  of the Engage package. Feature keys in the `ClikgateFeature` string union (`'leaderboards'`) aren't
  listed (only type names are), so they don't trip the check.
- **Compile checks done:** Android bridge `:clikgate_react-native:compileDebugKotlin` in
  `example/android` against the core in mavenLocal; iOS bridge Swift with `swiftc -typecheck` (Mac Catalyst
  target) against the core module built by `xcodebuild` for Catalyst. The ObjC++ `RNClikgate.mm` needs the
  React Native pods and was not compiled (no `pod install` on this machine budget).

## Deep-link delivery and buffering (three layers)

1. Native SDK: buffers links until a handler is set (latest 10). The bridge sets its single SDK handler
   once per process (`DeepLinkHub`, Android object / Swift singleton) so it survives JS reloads.
2. Bridge: buffers (latest 10) until JS has a `ClikgateDeepLink` listener (Android: listener count from
   `addListener`/`removeListeners`; iOS: `startObserving`/`stopObserving`), then flushes.
3. TS: `Clikgate.configure` (or the first `onDeepLink`) subscribes to the emitter; links received while
   no app listener exists are buffered (latest 10) and replayed to the next first listener in a
   microtask after `onDeepLink` returns. If that listener unsubscribes before the replay, the links stay
   buffered. `onDeepLink(listener)` returns the unsubscribe function.

`isClikgateMessage` is pure TypeScript (`src/isClikgateMessage.ts` imports nothing native) so it works
in headless JS / background message handlers.

## Android lifecycle

- `ClikgateModule` implements `ActivityEventListener` (`onNewIntent` → `Clikgate.handleIntent`) and
  `LifecycleEventListener` (`onHostResume` → `handleIntent(activity.intent)`), and handles the current
  activity's intent at creation and after `configure`. The SDK marks intents as handled, so repeats are
  harmless. The package registers the module with `needsEagerInit = true` so the launch intent and the
  SDK listener are in place before JS runs.
- `setWrapper("react-native", <package version>)` is called (opt-in `@ClikgateInternalApi`) right before
  `Clikgate.configure`. A second `configure` (JS reload) does nothing natively.
- No manifest changes from the library; apps (or the Expo plugin) add the intent filters.

## iOS lifecycle (RN apps own their AppDelegate)

- `ClikgateRN` (Swift, `@objc`) offers `handle(url:)`, `continue(userActivity:)`,
  `handleRemoteNotification(_:completionHandler:)`, `setPushToken(deviceToken:)` / `setPushToken(fcmToken:)`
  and `isClikgateMessage(_:)` for the AppDelegate.
- **Automatic path**: `RNClikgate +load` observes `RCTOpenURLNotification`, which `RCTLinkingManager`
  posts for `application(_:open:options:)` and `application(_:continue:...)`. The Expo AppDelegate template
  (and any app using React Native's `Linking`) already forwards to `RCTLinkingManager`, so links reach
  the SDK with no AppDelegate change. Observing from `+load` catches cold-start links before the
  (lazy) TurboModule exists. The same URL arriving through `ClikgateRN` and the notification within
  2 seconds is handled once.
- **Expo plugin does not inject AppDelegate code**: Expo's AppDelegate (Swift, `ExpoAppDelegate`)
  changes between SDK versions and regex injection is fragile; the notification path makes it unnecessary.
  Silent-push forwarding to `ClikgateRN.handleRemoteNotification` and APNs-token forwarding remain a
  documented manual step (apps using `@react-native-firebase/messaging` instead filter in JS with
  `isClikgateMessage` and pass the FCM token from JS).
- Wrapper hooks are `@_spi(ClikgateWrapper)` in the iOS SDK (`setWrapper`, `isConfigured`,
  `setPushToken(_:provider:)`, raw timestamps), used like the Flutter plugin does.
- The Swift implementation exposes only Foundation types to the `.mm` file: the generated
  `ClikgateReactNative-Swift.h` is imported from Objective-C++, where `@import Clikgate` is unavailable.
- Pod: `clikgate-react-native` (module `ClikgateReactNative`) depends on `Clikgate ~> 1.2.0`.

## Native SDK dependency

| | Android | iOS |
|---|---|---|
| Release | `com.clikgate:clikgate-android:1.2.0` from Maven Central (`clikgate.androidVersion` overrides) | `Clikgate ~> 1.2.0` from CocoaPods trunk |
| Monorepo example (default) | `~/.m2` artifact from `cd android && ./gradlew :clikgate:publishToMavenLocal` (`clikgate.useMavenLocal=true` in `example/android/gradle.properties`; `npm run example:android` publishes first) | `pod 'Clikgate', :path => '../../../ios'` in the example Podfile (built from source) |
| Composite build (Flutter's option) | `-Pclikgate.useLocalSdk=true` | — |

**Composite build limitation (verified):** with the composite build the example fails with
`Using multiple versions of the Android Gradle plugin(8.9.1, 8.12.0) in the same build is not allowed`.
`android/` pins AGP 8.9.1 to match Flutter 3.35, React Native 0.86 brings AGP 8.12.0, and AGP's
`AgpVersionCompatibilityRule` rejects any mismatch with no opt-out. The composite option is therefore
opt-in and only works once both use the same AGP version; the default is the locally published artifact.

## Example app

- Bare React Native 0.86.3 (`@react-native-community/cli init`), not Expo, so CI builds it without
  `expo prebuild` and the AppDelegate shows the manual lines. The Expo plugin is covered by unit tests.
- Config from `CLIKGATE_*` environment variables inlined at bundle time
  (`babel-plugin-transform-inline-environment-variables`); link domain / scheme natively via Gradle
  properties `clikgate.linkDomain` / `clikgate.uriScheme` and the Xcode build settings
  `CLIKGATE_LINK_DOMAIN` / `CLIKGATE_URI_SCHEME`.
- Navigation is a small state stack (no react-navigation) to keep native dependencies minimal; sharing
  uses React Native's `Share` API.
- Push: no Firebase. iOS forwards the APNs token and silent pushes natively through `ClikgateRN`;
  `src/push.ts` shows the `@react-native-firebase/messaging` wiring.

## Native SDK issues found (worked around in the bridge)

- **iOS: calls before `configure` are dropped** (`setPushToken`, `identify`, `setTrackingEnabled` log a
  warning and return), unlike Android, which queues them. RN apps receive the APNs token in the
  AppDelegate, often before JS calls `configure`; `ClikgateRN.setPushToken(deviceToken:)` therefore keeps
  the token and applies it right after `configure`. JS-side calls before `configure` reject with
  `not_configured` on iOS (as in the Flutter plugin) and are queued on Android.
- **Android: `Clikgate.attribution` before `configure` waits until `configure`** (queued), whereas
  iOS rejects with `not_configured`. Kept as is (same as Flutter).
- **Single deep-link listener** in both SDKs: an app that also sets `Clikgate.onDeepLink` natively would
  replace the bridge's listener (documented).
- **AGP pin**: see the composite build limitation above. Flutter (8.9.1) and React Native 0.86 (8.12.0)
  can't both include `android/` as a composite build until the Flutter toolchain moves to AGP ≥ 8.12.

## Licence

Apache 2.0 (see "Licence: Apache 2.0 (2026-10-26)" below).

## Change 03 — 2026-10-22

- **Bridge methods** exactly as shared/PLATFORM_CHANNEL.md "Change 03 methods" (no dots, so no renaming):
  `setConsent`, `getConsent`, `setConsentRegion`, `enableFirebaseForwarding`, `attributionMetadata`,
  `enableGoogleOnDeviceMeasurement`, each taking one `UnsafeObject` like the other methods.
- **Validation twice.** JS rejects unknown consent states and malformed regions (`invalid_argument`,
  `param`) before crossing the bridge; the native modules check again (Android `ConsentState.fromWire` +
  the region pattern; iOS `ClikgateConsentState(rawValue:)` + the SDK's SPI
  `setConsentRegionValidated`) so other callers of the TurboModule get the same error.
- **Before `configure`.** Unlike `track` / `identify` on iOS, the change 03 methods don't require
  `configure`: both native SDKs keep consent, the region, the Firebase options and the ODM flag set
  before configure (Android queues them, iOS stores them on the facade), so apps can apply the stored
  consent first thing. `getConsent` / `attributionMetadata` before configure answer from what the SDK
  has (unknown / empty).
- **Firebase** stays native: no `@react-native-firebase/*` dependency. The native SDKs find Firebase
  Analytics at runtime (Android reflection, iOS `NSClassFromString`); RN Firebase installs exactly those
  native SDKs. `eventNameMap` values that aren't strings are dropped in JS and natively.
- **ODM on Android** resolves `null` without doing anything (Google's on-device measurement is iOS only).
- **`pasteboardMode`** default `'off'` in JS and in the iOS bridge's fallback (an unknown value now maps to
  `.off`, previously `.automatic`).
- **Checks done (2026-10-22):** `tsc` (library + plugin), jest (core 85, Engage 45), Android bridge
  `:clikgate_react-native:compileDebugKotlin` in `example/android` against core 1.2.0 in mavenLocal, iOS
  bridge `swiftc -typecheck` (arm64 iOS) against a `Clikgate.swiftmodule` emitted from `ios/Sources/Clikgate`.
  `RNClikgate.mm` (ObjC++) was not compiled (needs the React Native pods); its six new methods follow the
  existing pattern line for line. No device run.

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

## Change 06 — shared-domain browser fallback (1.5.0, native 1.4.0, 2026-10-26)

- **What**: the native SDKs open another organisation's unmatched shared-domain link (`ciz.to`, `clk.ng`,
  `clkg.to`, `dev.ciz.to`) in an in-app browser (Custom Tabs / SFSafariViewController); the bridge passes
  the option and the event through (shared/SDK_BEHAVIOUR.md "Change 06 (SDK 1.4.0)"). The list lives in
  the native SDKs only.
- **Event transport**: the handoff is emitted as the existing `ClikgateDeepLink` event, tagged
  `{event: "browserHandoff", url, host}`, not as a second event name: `RCTEventEmitter` and the Android
  module count listeners per module, and the native hubs buffer one queue (latest 10) until JS
  subscribes, so one event keeps that logic untouched. `src/deepLinkHub.ts` routes tagged maps to
  `onBrowserHandoff` (own buffer + replay) and everything else to `onDeepLink`.
- **Option**: `platformDomainBrowserFallback` (default true); the spec doesn't mention the fallback, so an
  off switch doesn't conflict with it.
- **Version**: 1.4.0 → **1.5.0**, not 1.4.1: it adds public API (`onBrowserHandoff`, two types, a config
  field) and raises the native dependency to 1.4.0, which is a minor change under semver and matches how
  every earlier change set got its own minor even while unreleased (1.4.0 = the Expo test link domain).

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
