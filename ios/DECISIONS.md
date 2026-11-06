# iOS SDK — platform findings and decisions

Checked on 2026-10-20 against the iOS 26.2 SDK headers / `.swiftinterface` files shipped with
Xcode 26.3 (the authoritative signatures) and Apple's documentation (developer.apple.com, fetched
as Markdown). Where the two differ, the SDK headers win.

## Pasteboard (`UIPasteboard`, `UIPasteControl`)

- **Findings.** `detectPatterns(for: Set<UIPasteboard.DetectionPattern>)` (`.probableWebURL`) is iOS 14.0 and
  **deprecated in iOS 15**. The replacement is `detectPatterns(for: Set<PartialKeyPath<UIPasteboard.DetectedValues>>)` /
  `async detectedPatterns(for:)` (iOS 15+), using `\UIPasteboard.DetectedValues.probableWebURL`. Pattern detection
  and `hasStrings` are metadata reads: no paste banner or prompt. Reading `string` shows the paste prompt on
  iOS 16+. `UIPasteControl` (iOS 16+) pastes without a prompt into its `target`, which is any
  `UIPasteConfigurationSupporting` (every `UIResponder`) whose `pasteConfiguration` accepts the item types.
- **Decision.** On iOS 15+ the SDK uses the key-path API, on iOS 14 the deprecated one, and on iOS 13 `hasStrings`
  (contract). It reads `string` only when a web URL is likely, only on the first launch, and only if the server
  enables `pasteboard_matching = on_interstitial_tap` and `pasteboardMode == .automatic`. Token = the first match
  of `cgdl_[0-9A-Za-z]{26}` (NSRegularExpression).
- `ClikgatePasteControl` is a `UIView` that is its own paste target (`pasteConfiguration` = URL + plain text,
  `paste(itemProviders:)`). It hands the text to the SDK, which calls `/install` again with `pasteboard_token`.
  On iOS 13–15 it falls back to a plain button that reads `UIPasteboard.general.string` on tap (no prompt exists there).

## App Attest (`DCAppAttestService`)

- **Findings.** iOS 14+. `isSupported`, `generateKey()`, `attestKey(_:clientDataHash:)` and `generateAssertion(_:clientDataHash:)`.
  Apple: store the key identifier yourself ("no way to get the identifier later"); the private key stays in the
  Secure Enclave; only action/SSO extensions are supported among extensions; the simulator reports unsupported.
- **Decision.** Used only when `options.attestation == .appAttestIfAvailable`, `config.features.attestation.ios_app_attest != "off"`
  and `isSupported`. The key id goes in state.json (it isn't secret, and a reinstall must create a new key anyway).
  `clientDataHash = SHA256(base64url-decoded nonce bytes)` for both attestation and assertion (confirmed by the
  coordinator after the contract was clarified). `token` = standard base64 of the attestation or assertion,
  `key_id` exactly as `generateKey()` returned it. First launch: challenge → attest → `attestation` in `/install`.
  Challenges are single use with a 5-minute expiry, so `/install` retries made more than 4.5 minutes after the
  challenge leave the attestation out, and `/attest` runs once the install exists. Re-attestation: every
  `reattestation_interval_days` an assertion goes to `/attest` (`type: app_attest_assertion`). If the key was never
  accepted, a full `app_attest` is sent instead. If attestation fails, a new key is generated once.

## Apple Search Ads (`AAAttribution`)

- **Findings.** `AAAttribution.attributionToken() throws -> String` (AdServices, iOS 14.3+). The Objective-C
  `attributionTokenWithError:` is synchronous and errors when the network is unavailable or on unsupported OS
  versions. The simulator returns an error.
- **Decision.** Read once on the first launch when `features.apple_search_ads` is true. Sent as
  `apple_search_ads_token` in `/install`; the server resolves it and the result arrives through the
  `retry_after_ms` polling.
- **Change 19 (C19-S1, R.1, 2026-11-04): superseded timing.** The token is requested when the first `/install` is
  actually sent (after the consent grant when consent buffers; a first-launch token could be days old by then, and
  Apple's token is valid for 24 hours, as re-checked by backend C19-B3 on 2026-10-31,
  https://developer.apple.com/documentation/adservices). Every attempt of that `/install` (`installAttempt`) reuses
  it while it is younger than 24 hours, else requests a new one. It is held in memory only
  (`ClikgateCore.adServicesToken`), never in `Storage` (the old `apple_search_ads_token` state key is dropped from
  the state file on the next save), and cleared when the install is answered or consent is denied. Not requested when
  blocked, when the consent gate isn't `allowed`, or when `attribution` is denied. Polls carry no token
  (`InstallExtras.sendsSearchAds`). IDFV goes with the install when `apple_search_ads` is on (identity-check
  consent unchanged) for the backend's Redownload linking. There was never an `enableAppleAdsAttribution()`; the
  dashboard setting is the only switch.

## AdAttributionKit vs SKAdNetwork

- **Findings.** AdAttributionKit (iOS 17.4+): `Postback.updateConversionValue(_ fine: Int, coarseConversionValue: CoarseConversionValue, lockPostback: Bool) async throws`
  and `updateConversionValue(_:lockPostback:)`. iOS 18 adds `PostbackUpdate` (and iOS 18.4 `conversionTag`).
  SKAdNetwork: `updatePostbackConversionValue(_:coarseValue:lockWindow:completionHandler:)` (iOS 16.1+) and
  `updatePostbackConversionValue(_:completionHandler:)` (15.4+).
  Apple's *AdAttributionKit and SKAdNetwork interoperability* article: "If your framework is integrated with both
  AdAttributionKit and SKAdNetwork, call APIs from both". It also says SKAdNetwork mirrors its calls into
  AdAttributionKit (fine value only), and that calls are ignored when no postback is pending.
- **Decision.** Use AdAttributionKit where available and SKAdNetwork otherwise. Because SKAdNetwork-attributed
  installs still exist, on 17.4+ the SDK calls SKAdNetwork first and then AdAttributionKit (so the AdAttributionKit
  value carries the coarse value last). 16.1–17.3: SKAdNetwork with fine + coarse + lock. 15.4–16.0: fine value only.
  Below 15.4: nothing (the remaining API is deprecated, and too few devices still run those versions). Values
  only go up: the last value set is kept in state.json and only stored when a call succeeds.

## Privacy manifest

- **Findings.** The required-reason categories are `NSPrivacyAccessedAPICategoryUserDefaults`, `…FileTimestamp`,
  `…SystemBootTime`, `…DiskSpace` and `…ActiveKeyboards`. The reasons must cover the third-party SDK's *own* use,
  in the SDK's own manifest.
- **Decision.** The SDK uses none of these categories. State lives in a JSON file (not `UserDefaults`); it never
  reads file timestamps (`creationDate` / `modificationDate` / `stat`), disk space, `systemUptime` /
  `mach_absolute_time`, or keyboards. The clock is `Date()` and sleeps are `Task.sleep`. So
  `NSPrivacyAccessedAPITypes` is empty. Anyone changing the SDK must keep it that way or declare the reason
  (e.g. `CA92.1` for UserDefaults, `C617.1` for file timestamps in the app container, `35F9.1` for boot time).
  Collected data, none of it used for tracking (`NSPrivacyTracking = false`):
  - DeviceID (installation id, push token): app functionality and analytics.
  - UserID (`identify`): app functionality and analytics.
  - ProductInteraction (events): analytics.
  - PurchaseHistory (revenue events): analytics.

  All linked to the user. The manifest ships as a package resource (SPM), the `Clikgate_Privacy` resource bundle
  (CocoaPods), and `PrivacyInfo.xcprivacy` inside each framework of the XCFramework.

## Keychain

- **Findings.** `kSecAttrAccessibleAfterFirstUnlock` keeps items readable in the background after the first
  unlock. Setting `kSecAttrSynchronizable = false` keeps them off iCloud Keychain. Keychain items survive app
  deletion on current iOS.
- **Decision.** Generic password, service `com.clikgate.installation-id`, account `installation_id`,
  `AfterFirstUnlock` (not `ThisDeviceOnly`, per the spec), not synchronizable. `Application Support/Clikgate/` is
  excluded from backups, so a restore to a new device shows up as a reinstall (new installation id plus the
  previous one from the Keychain) instead of a cloned installation.
- **Verified on the simulator:** with an ad-hoc-signed build, uninstall → reinstall sent the first install's id as
  `keychain_previous_installation_id`. **Unsigned** builds (`CODE_SIGNING_ALLOWED=NO`, `flutter build --no-codesign`)
  have no Keychain access (no application-identifier entitlement), so reinstall detection only works in signed builds.

## ATT

- `ATTrackingManager.trackingAuthorizationStatus` (iOS 14+) is read only. The SDK never calls
  `requestTrackingAuthorization`. With `waitForATT` it polls every 0.5 s for up to 30 s while the status is
  `.notDetermined`, then sends `/install`. IDFA is not read (out of scope for this build; spec §14).

## Background work

- `UIApplication.beginBackgroundTask(withName:expirationHandler:)` wraps the flush on `didEnterBackground`. On
  expiry the task ends and the queue stays persisted for the next start. The `BGTaskScheduler` API isn't used:
  it needs app-side Info.plist registration, and the contract only asks for a background-task window.
- Launches in the background (e.g. by a silent uninstall-check push) don't send `/open`; the cold open is sent at
  the first `willEnterForeground`.

## `aps-environment`

- An `embedded.mobileprovision` exists in development, ad-hoc and enterprise builds. It is a CMS-signed plist, and
  the SDK extracts the XML between `<?xml` and `</plist>` and reads `Entitlements["aps-environment"]`
  (`development` → `sandbox`). App Store builds have no profile, so the value is `production`, which is also the
  default when anything is missing. Simulator builds report `sandbox` (Apple-silicon simulators receive sandbox
  tokens).

## Weak linking

- With deployment target iOS 13, AdServices (14.3), AdAttributionKit (17.4), AppTrackingTransparency (14) and
  DeviceCheck (14) are referenced only behind `#available`. The linker weak-links them automatically: confirmed in
  the Release sample binary, which has `LC_LOAD_WEAK_DYLIB` for all four. The podspec also lists them as
  `weak_frameworks`.

## Other judgement calls

- **JSON.** Hand-written `JSONSerialization` mapping instead of `Codable`. Synthesized Codable conformances made
  the SDK about 550 KB linked; with manual mapping it is about 381 KB at `-O` (see Size). Unknown response fields
  are ignored, and missing optional fields fall back to defaults.
- **Size** (linked contribution to an arm64 Release app, from the linker map, excluding zero-fill):
  **381 KB at `-O`** (SPM default) and **about 300 KB at `-Osize`** (the podspec sets `-Osize` for Release; the
  XCFramework script also builds with `-Osize`). Cold JSON-mapping functions carry `@_optimize(size)`.
- **The module and the class are both named `Clikgate`** (the spec's API). Module interfaces then need
  `-alias-module-names-in-module-interface` (swiftlang/swift#56573); `build_xcframework.sh` passes it, and
  interface verification succeeds.
- **Wrapper API is SPI.** `setWrapper(name:version:)`, `isConfigured`, `setPushToken(_:provider:)` and the raw
  timestamp strings are `@_spi(ClikgateWrapper) public`. They're hidden from normal `import Clikgate` but usable
  by the Flutter and React Native bridges.
- **URLs received before `configure`** (a Universal Link that cold-starts a Flutter app reaches the native
  delegate before Dart calls `configure`) are kept (the latest 10) and handled right after `configure`.
  `handle(url:)` returns `false` for them.
- **Referral calls** (interactive) use at most 2 attempts. `/install` and `/opt-out` retry until they succeed, with
  the 60 s cap. Other background calls give up after 5 attempts (events stay queued).
- **Flutter APNs token.** The plugin doesn't forward the APNs device token automatically, because apps using FCM
  would then register two providers. Native-APNs Flutter apps opt in with Info.plist
  `ClikgateForwardAPNsToken = YES`.
- **`environment` option.** It only produces a warning when it doesn't match the environment the server reports
  for the SDK key's app. Nothing else in the contract consumes it.
- **Restricted mode** (`features.restricted_mode`): `device_model` is omitted from `/install`.

## v3: feature switches, leaderboards, codes, WhatsApp (2026-10-21)

> Superseded in part by "Engage split" below: leaderboards, codes, link creation, stats and the WhatsApp
> share now live in the `ClikgateEngage` add-on, with different retry rules.

Mirrors `android/DECISIONS.md` (v3). Differences are called out.

- **Feature switches.** `RemoteConfig.switches` = the JSON-boolean entries of `/config` `features`
  (nil when the response has no `features` object); `pasteboard_matching` / `attestation` aren't
  switches and read as off. `FeatureSwitches` (lock-protected, `nonisolated` on the core actor) answers
  `Clikgate.shared.isFeatureEnabled(_:)` synchronously: the server's value, else the catalogue default
  (`referrals`, `leaderboards`, `offline_codes`, `app_attribution` on; the rest and unknown keys off).
  It is loaded from the cached config in `ClikgateCore.init`, so a relaunch knows the switches before any
  fetch. Before `configure` the defaults apply.
- **Gating.** Referral, leaderboard and code calls go through `ClikgateCore.featureCall`: `feature_disabled`
  (no network) when the switch is off, checked before the call and again after the pending-identify send.
  A `200 {"accepted": false, "reason": "feature_disabled"}` body maps to the same error
  (`ClikgateError.feature` = the body's `feature`, else the method's). That feature (and the method's)
  then reads as off in memory, and a background `/config` refresh (one attempt, bypassing the 1 h cache)
  starts; a successful fetch clears the in-memory switch-offs (re-enabling works without a relaunch).
- **Install wait — difference from Android.** iOS referral calls never waited for the first `/install`
  (they throw `install_pending` straight away; Android waits up to 10 s). v3 calls keep the iOS v1
  behaviour. On iOS the launch `/config` fetch runs before `/install`, so by the time an install exists the
  switches are known; the second check covers a config fetched during the identify send.
- **Interactive calls.** Leaderboards and codes: at most 2 attempts, and `APIClient.send(maxRetryDelay: 5)`
  skips a retry whose wait (Retry-After or backoff) exceeds 5 s, so `Retry-After: 3600` from the 5/hour
  code limit is `rate_limited` at once. Referral calls keep 2 attempts and no wait cap (v1 behaviour;
  Android uses 3 attempts — an existing difference).
- **API shape.** async/await plus completion-handler variants (main actor), like referrals.
  `leaderboards.top(id:period:segment:limit:)`, `me(id:period:segment:)`, `aroundMe(id:radius:period:segment:)`,
  `setOptOut(programId:optOut:)`, `codes.redeem(_:)`. The period argument is
  `ClikgateLeaderboardPeriodSelector` (`.current`, `.previous`, `.key(_:)`, string literal; RawRepresentable
  so wrappers pass the contract string), so the spec's `period: .current` compiles; the result model is
  `ClikgateLeaderboardPeriod` (as on Android). `limit` (1…100) and `radius` (1…25) are clamped; a blank
  id/period (or an id containing `/`) is `invalid_argument` before any other check.
  `aroundMe` returns `ClikgateLeaderboardPage` with `name`/`metric`/`segment` nil.
- **Models** are hand-mapped (no Codable, see JSON above), `Sendable` + `Equatable`. Timestamps are
  `Date?` computed from the server strings; the raw strings are `@_spi(ClikgateWrapper)` (`startsAtRaw`,
  `endsAtRaw`, `periodEndsAtRaw`) so the bridges pass them through unchanged. `embed_token` and
  `/me?embed=1` aren't exposed. `ClikgateRedemption.RedeemedCode` is nested.
- **Errors.** `ClikgateError` gained `feature` and `offlineTouchId` (from the error object's
  `offline_touch_id` on `/codes/redeem` referral errors), both also in `errorUserInfo` (`feature`,
  `offline_touch_id`); new codes `feature_disabled`, `share_unavailable` and constants for the v3 backend
  codes. The memberwise `init` gained two defaulted parameters (source compatible).
- **`codes.redeem`** trims, validates 3–30 characters (schema `code_redeem_request`), sends the trimmed
  code; normalisation is the server's.
- **WhatsApp share** (needs only `referrals`; `whatsapp_attribution` is a server-side feature).
  `@MainActor shareToWhatsApp(programId:message:displayName:from:) async throws -> Bool`: `createLink`, fill
  the message (same placeholders as Android: `{url}`, `{short_url}`, `{code}`; link appended without a URL
  placeholder), then `whatsapp://send?text=<RFC 3986 unreserved-only percent-encoding>` if
  `UIApplication.canOpenURL` is true and `open` succeeds → `true`. Otherwise a `UIActivityViewController`
  with the text, from `from:` or the top-most presented view controller of the foreground window scene →
  `false`. `share_unavailable` only when there is nothing to present from. WhatsApp Business has no
  separate documented URL scheme on iOS (Android tries `com.whatsapp.w4b`). `canOpenURL` needs
  `whatsapp` in the host app's `LSApplicationQueriesSchemes`; the SDK doesn't require it (without it the
  share sheet is used) and the docs say so. `canOpenURL` isn't a required-reason API, and no new data
  types are collected, so `PrivacyInfo.xcprivacy` is unchanged.
- **Tests** run on the host via Mac Catalyst (`xcodebuild test -destination 'platform=macOS,variant=Mac Catalyst'`),
  no simulator needed. `swift build` / `swift test` on plain macOS don't apply: the package is iOS-only
  (UIKit).
- Not implemented (as on Android): `/v1/sdk/identity-signals` (only the `identity_checks` switch is readable).

## Engage split (spec v3 new edition, 2026-10-21)

Spec 0.4 / 17A: the core SDK keeps only device work; referrer-side convenience features move to the
optional **Engage add-on**.

- **Packaging.** SPM: products `Clikgate` (target without dependencies) and `ClikgateEngage` (target
  `Sources/ClikgateEngage`, depends on `Clikgate`). CocoaPods: `s.default_subspec = 'Core'` (the former sources,
  resources and frameworks), subspec `Engage` depending on `Clikgate/Core`; `pod 'Clikgate'` installs Core only.
- **One module under CocoaPods.** CocoaPods builds all subspecs into the single `Clikgate` module, so the Engage
  sources can't `import Clikgate` there. The Engage subspec adds `CLIKGATE_POD_SINGLE_MODULE` to
  `SWIFT_ACTIVE_COMPILATION_CONDITIONS` (subspec `pod_target_xcconfig`, merged into the pod target only when Engage
  is installed), and every Engage file wraps `@_spi(ClikgateEngage) import Clikgate` in
  `#if !CLIKGATE_POD_SINGLE_MODULE`. Engage's internal names are all `Engage`-prefixed so they can't collide with
  core internals in that mode. Verified: a `swiftc -typecheck -D CLIKGATE_POD_SINGLE_MODULE` of both source trees
  as one module, and `pod lib lint Clikgate.podspec --subspec=Engage --platforms=ios` (full build, passed).
  App code: `import ClikgateEngage` with SPM, `import Clikgate` with CocoaPods.
- **Namespace type = module name.** `public enum ClikgateEngage` (static `referrals`, `share`, `leaderboards`,
  `codes`, `clearCache()`, `version`) lives in module `ClikgateEngage`, the same pattern as `Clikgate`. Source
  imports are fine; textual interfaces need `-alias-module-names-in-module-interface` (already passed by
  `build_xcframework.sh`). Checked: with library evolution and that flag, both `.swiftinterface` files rebuild
  with `swift-frontend -compile-module-from-interface`.
- **XCFrameworks** (2026-10-21): `build_xcframework.sh` builds `Clikgate.xcframework` and
  `ClikgateEngage.xcframework` (+ zip and SwiftPM checksum each). Engage is archived with its own package scheme,
  which also compiles the core; only `ClikgateEngage.o` goes into `ClikgateEngage.framework` (checked: `ar -t`
  lists only it, and the only `Clikgate`-namespaced symbols it defines are its own `ClikgateError` extensions), so
  apps link both frameworks and the core framework alone never contains Engage. The privacy manifest is in the core
  framework only (Engage collects nothing itself; its calls use the core's context). Verified locally: both
  frameworks build, and a consumer importing `Clikgate` + `ClikgateEngage` typechecks against them
  (`swiftc -typecheck -F …` for arm64 iOS). Device static libraries without debug symbols: core 1,016,640 B,
  Engage 285,128 B (archives, not linked size; budgets are measured by `check_size.sh`).
- **Release check**: the `ios-v*` release job requires the tag to equal `Clikgate.sdkVersion`,
  `ClikgateEngage.version` and the podspec version (core and Engage ship together), and attaches both
  XCFramework zips to the GitHub release.
- **Internal request context.** `@_spi(ClikgateEngage)`: `ClikgateRequestContext` (`installationId`, `sdkKey`,
  `environment` — server-reported when known, else the option —, `apiBaseUrl`, `identityToken`,
  `customerUserId`, `sdkVersion` = the exact `Clikgate-SDK-Version` value incl. a wrapper, `nativeSdkVersion`,
  `headers`), `Clikgate.shared.requestContext() async throws` (gates: `not_configured`, `opted_out`,
  `invalid_sdk_key`, `sdk_disabled`; `install_pending` straight away before the first `/install` — the iOS
  behaviour of the old feature calls; a pending identify is sent first) and
  `reportServerError(code:feature:)` (`feature_disabled` → feature off in memory synchronously + forced
  one-attempt config refresh; `invalid_sdk_key` / `sdk_disabled` → the core's gates; `installation_unknown` →
  re-run `/install` once). SPI keeps it out of normal `import Clikgate` (and out of autocompletion) but it is
  a stable-enough seam for the add-on. `ClikgateReferral.init?(apiJSON:)` is SPI too, so Engage decodes the
  referral of a redemption with the core's mapping.
- **Engage HTTP.** Own `URLSession` (ephemeral, no URL cache, 10 s timeouts), injectable host/transport/clock
  for tests. Order per call: argument validation → `isFeatureEnabled` (`feature_disabled`, no network, no
  context) → request context → `not_identified` (no user) for `createLink`, `myStats`, `me`, `aroundMe`,
  `setOptOut`, `hostedPageUrl` → cache (GETs `myStats`, `top`, `me`, `aroundMe`, 60 s, key = installation +
  user + token presence + URL; writes clear it; errors aren't cached) → send, one retry after 0.5 s only when the
  request didn't reach the server (URLSession error) → `200 feature_disabled` body reported to the core (body
  feature and method feature) → typed `ClikgateError` (backend code, status, param, request id, feature,
  offline touch id). `identity_required` is left to the server (Engage doesn't read program settings).
- **Retry change.** The v3 core calls retried 429/5xx (2 attempts, ≤ 5 s waits). Engage follows 17A.3: no HTTP
  retries at all, one network-error retry.
- **`hostedPageUrl(id:period:)`** = `GET /v1/sdk/leaderboards/{id}/me?period=…&embed=1` → `embed_url` (added by the
  backend in this edition), never cached; `hosted_page_unavailable` when the server sends none.
- **Share helpers** (`ClikgateEngage.share`, no network, no feature switch): `system(text:from:)` presents
  `UIActivityViewController`; `whatsApp(text:from:)` opens `whatsapp://send?text=` (RFC 3986 unreserved-only
  encoding) when `canOpenURL` + `open` succeed (`true`), else the share sheet (`false`); `share_unavailable` when
  there's nothing to present from. Hosts need `LSApplicationQueriesSchemes` → `whatsapp` for the direct path.
  The link placeholders of the old `shareToWhatsApp(message:)` are gone: the app builds the text from
  `createLink`'s result (17A.2).
- **Size work** (Engage budget 80 KB). First cut was 112 KB (`-Osize`). Changes: `EngageClient.call` made
  non-generic (it returns the JSON object; callers decode — the generic version was specialised per model with a
  full async state machine each), `@_semantics("optimize.sil.specialize.generic.never")` on the completion
  runner and decoder, models not `Equatable`, error-code constants as computed `static var`s, simpler retry and
  share-UI code (`UIApplication.open` async overload instead of a continuation). The completion-handler variants
  cost about 7 KB of the remainder.
- **Size measurement** (`scripts/check_size.sh`): each module compiled whole-module for `arm64-apple-ios13.0` into
  one object (`-Osize`, the podspec Release / XCFramework setting; `-O` for information); sum of all sections
  except zero-fill, `__LD,__compact_unwind` (becomes the much smaller `__unwind_info`) and `__LLVM`. No dead
  stripping, i.e. every public API in use. Results (Xcode 26.3):

  | | `-Osize` (budget) | `-O` |
  |---|---|---|
  | core `Clikgate` | **292.4 KB** (< 400 KB) | 468.6 KB |
  | `ClikgateEngage` | **75.6 KB** (< 80 KB) | 91.0 KB |

  The earlier "381 KB at `-O`" figure was a linker-map measurement of the sample app (dead-stripped to what the
  sample uses), so it isn't comparable. Note: SPM consumers compile packages with their own optimisation
  setting (Xcode Release = `-O`), where the all-API worst case of core exceeds 400 KB; dead stripping in a real
  app removes unused code. The budgets are enforced on the shipped `-Osize` configuration.
- **API snapshot** (`scripts/check_api.sh`): `swiftc -emit-module` for arm64 iOS, then
  `swift-symbolgraph-extract -minimum-access-level public -include-spi-symbols`; one line per public declaration
  (`[spi]` marked; Engage's `ClikgateError` extensions prefixed `Clikgate`) compared with `ios/api/*.api.txt`.
  Fails on forbidden tokens in the core listing (`leaderboard`, `createLink`, `myStats`, `ReferralLink`,
  `ReferralStats`, `redeem`, `Redemption`, `share` (not `shared`), `whatsapp`, `identitySignal`, `MyRank`,
  `hostedPage`), except the feature-key constants `ClikgateFeatures.leaderboards` / `.whatsappAttribution`
  (string keys for `isFeatureEnabled`). Dependency check: the `Clikgate` target has no dependencies,
  `Sources/Clikgate` never imports `ClikgateEngage`, the podspec's default subspec is `Core` and Core doesn't
  mention Engage. Chosen over `swift-api-digester` because the symbol graph is plain JSON, needs no build products
  and works on CI runners without a simulator.
- **Tests.** `ClikgateTests` (79): core, incl. request context (fields, wrapped versions, pending identify sent
  first, gates) and `reportServerError`. `ClikgateEngageTests` (18): fake host + transport — switches without
  network, context errors, `not_identified`, server `identity_required`, headers, endpoint shapes, hosted page URL,
  error mapping and reports, single network retry, 60 s cache (expiry, per-user keys, write invalidation,
  `clearCache`), main-thread completions, WhatsApp URL encoding and share fallbacks. Run on Mac Catalyst:
  `xcodebuild test -scheme Clikgate-Package -destination 'platform=macOS,variant=Mac Catalyst'`.
- **Sample.** `ios/Sample` links `ClikgateEngage` for "Share my invite link" (createLink → `share.whatsApp`) and
  "My stats"; `LSApplicationQueriesSchemes` = `whatsapp` added to `project.yml` (regenerated with xcodegen).

## Fraud signals (change 02, B.5.2; SDK 1.1.0)

`/install` sends `is_emulator` (`targetEnvironment(simulator)`, as before) and the new `is_rooted`
(jailbreak heuristic, `Jailbreak` in `Internal/Platform.swift`, computed in `SystemDeviceInfo.collect()`,
i.e. once per `/install` request).

- **Checks:** `FileManager.fileExists` on 11 jailbreak paths (Cydia / Sileo / Zebra, MobileSubstrate,
  `/usr/sbin/sshd`, `/bin/bash`, `/etc/apt`, `/private/var/lib/apt/`, rootless `/var/jb`, `/var/binpack`) and
  a write to `/private/clikgate-jb-probe.txt`, outside the container (a stock sandbox refuses it; if it
  succeeds the file is removed at once).
- **Not used:** URL-scheme probing (`canOpenURL("cydia://")` needs `LSApplicationQueriesSchemes`), `stat` /
  `lstat` (file-timestamp required-reason APIs, which would need a privacy-manifest entry), `dlopen` / dyld
  image scans (noisy, App Review risk). No privacy-manifest change: `fileExists` and a file write aren't
  required-reason APIs.
- **Where it can't be judged it's omitted (`nil`)**: the Simulator, Mac Catalyst and iOS apps on Apple
  silicon Macs (`isiOSAppOnMac`) see the Mac's file system, which has `/bin/bash` and `/usr/sbin/sshd`.
- **Opt-out:** `is_rooted` is only sent with `tracking_allowed: true`. (`is_emulator` keeps its earlier
  behaviour and is still sent in the opted-out body.)
- **Hints, not proof:** rootless jailbreaks with hiding tweaks defeat these checks; App Attest is the strong
  signal. The server only adds weight (`emulator_or_rooted`).

## Change 03 (SDK 1.2.0) — 2026-10-22

C3-S1 + C3-S2 for the iOS core: consent, click ids, version policy, fingerprint removal, DeviceCheck /
App Attest, clipboard opt-in, Firebase forwarding, `attributionMetadata`, Google on-device measurement.
Contract: shared/API_CONTRACT.md and shared/SDK_BEHAVIOUR.md "Change 03".

### Documentation checked (2026-10-22)

| Topic | Source | Finding |
|---|---|---|
| Fingerprinting | developer.apple.com/app-store/user-privacy-and-data-use (FAQ), fetched 2026-10-22 | "you may not derive data from a device for the purpose of uniquely identifying it". Examples: properties of the browser, "the user's device and its configuration", location, network connection. No ATT exception is stated; apps referencing SDKs that do it may be rejected. Fingerprint IDs used to join data with third parties count as tracking. |
| DeviceCheck | iOS 26.2 SDK header `DeviceCheck.framework/Headers/DCDevice.h` (Xcode 26.3). The developer.apple.com page body didn't render in the fetch | `DCDevice` iOS 11+, `currentDevice` (`DCDevice.current`), `isSupported`, `generateTokenWithCompletionHandler:` (`generateToken(completionHandler:)` / async). The token is ephemeral; the server talks to Apple. |
| App Attest | iOS 26.2 SDK header `DCAppAttestService.h` | iOS 14+ (unchanged from the 2026-10-20 finding). |
| Pasteboard prompt | 2026-10-20 finding above, re-checked against the iOS 26.2 `UIPasteboard.h` | Pattern detection / `hasStrings` never prompt; reading `string` prompts on iOS 16+; `UIPasteControl` pastes without a prompt. |
| Firebase Analytics | `FIRAnalytics.h` from FirebaseAnalytics 13.0.1 (dl.google.com tarball named by the firebase-ios-sdk podspec) | `+logEventWithName:parameters:`, `+setUserPropertyString:forName:`, `+(nullable NSString *)appInstanceID` ("nil if `ConsentType.analyticsStorage` has been set to `ConsentStatus.denied`"). Names 1–40 alphanumeric/underscore, start with a letter; `firebase_`, `google_`, `ga_` reserved; string values ≤ 100 (≤ 500 on GA360); user property names ≤ 24, values ≤ 36. GA4 limits page (support.google.com/analytics/answer/9267744): ≤ 25 parameters per event. |
| On-device measurement | `GoogleAdsOnDeviceConversion` 3.7.0 headers (`ODCConversionManager.h`, `ODCConversionTypes.h`, from the tarball the podspec names) + developers.google.com/app-conversion-tracking/api/integrated-conversion-measurement (last updated 2025-10-22) | `ODCConversionManager.sharedInstance` (class property), `versionString`, `setFirstLaunchTime:`, `fetchAggregateConversionInfoForInteraction:completion:` with `ODCInteractionTypeInstallation` (0) / `ODCInteractionTypeSessionStart`; the completion runs on a global queue; both nil = expired / not available. Google: fetch shortly after first launch and pass the string as the `odm_info` query parameter of the App Conversion API; the app must run in an approved region. The podspec says the pod is a plugin "for FirebaseAnalytics and Google's App Attribution Partner (AAP) SDKs". |

**Not verified:** whether Google's App Attribution Partner server-to-server API accepts `odm_info` from an
AAP for these installs (the partner spec isn't public; the backend keeps it behind `google_aap_mode`); the
exact paste-prompt wording per iOS version and language (the docs quote it approximately); whether Firebase
Analytics itself already calls `setFirstLaunchTime` when both SDKs are present (we call it with the SDK's own
first-launch date, which is the same moment for a fresh install).

### Decisions

- **No new dependency.** Firebase (`FIRAnalytics`) and Google on-device measurement (`ODCConversionManager`)
  are looked up with `NSClassFromString` and called through the Objective-C runtime (`perform`, and an IMP
  cast for the selector that takes an `NSInteger` and a block). DeviceCheck is a system framework, already
  weak-linked (podspec `weak_frameworks`). Each is behind an injectable protocol in `ClikgateDependencies`
  (`FirebaseAnalyticsBridging`, `DeviceCheckProviding`, `OnDeviceMeasurementProviding`, `vendorId`).
- **Fingerprint removal.** Removed `screen` and the jailbreak heuristics (see CHANGELOG "Privacy"). The
  jailbreak probes were a fraud hint, not a matching signal, but they inspect "the device and its
  configuration" and the spec (S.2, B.2) limits iOS identity checks to App Attest, DeviceCheck and IDFV.
  Kept: device model, OS version, locale, time zone (ordinary analytics, also sent by Apple's own
  frameworks' crash/analytics flows), and `is_emulator` (compile-time, reads nothing from the device).
- **IDFV** is new in 1.2.0, sent only for identity checks (feature `identity_checks` or App Attest in use)
  with `analytics` consent or the organisation's `fraud_prevention` basis. Privacy manifest unchanged:
  `NSPrivacyCollectedDataTypeDeviceID` already covers it (and the DeviceCheck token); no required-reason
  API. Firebase forwarding writes into the app's own Firebase project: Clikgate collects nothing new, so no
  manifest change either.
- **Clipboard opt-in.** `pasteboardMode` default `.off`. The server switch `pasteboard_matching` stays the
  per-app switch (off by default server-side). With consent buffering the token is read on the first launch
  (the landing page just copied it) but only sent after `attribution` is granted.
- **Consent gate in one place.** `ClikgateCore.request` and `installAttempt` refuse any call the gate or the
  blocked-version instructions don't allow (`consent_required`, `sdk_version_blocked`), so a new call can't
  bypass it. `/config` while not allowed and `/install-ping` go without `Clikgate-Installation-Id`. The very
  first `/config` of an installation (no cached config, no hint) can't know the mode yet and carries the id.
- **Synchronous getters.** `getConsent()` and `attributionMetadata()` read a lock-protected `SyncSnapshot`
  the actor updates (like `FeatureSwitches`). Calls before `configure` are kept on the facade and applied in
  `configure` before `start` (iOS used to drop pre-configure calls; consent must not be lost).
- **Buffer limits** reuse the event queue: while buffering its limit is `min(max_queue_events,
  buffer_max_events)`, and events older than `buffer_max_days` are dropped on every track / launch / grant.
- **Version policy.** The SDK's own version is the wrapper's when wrapped (`setWrapper`), compared with
  `min_supported_version` only when the server sent no `version_status`.
- **Firebase forwarding stays in core** instead of an optional module: measured cost about 9 KB at `-Osize`
  (Firebase limits/params, attribution event, mirroring, the runtime bridge, the ODM bridge); a separate
  product would need a new SPI seam for attribution and events, and Flutter / React Native would have to ship
  it anyway to call through to native.
- **Size** (`scripts/check_size.sh`, Xcode 26.3, all public API, no dead stripping):

  | | before (1.1.0) | after (1.2.0) |
  |---|---|---|
  | core `-Osize` (budget 400 KB) | 296.8 KB | **384.3 KB** |
  | core `-O` (info) | 473.9 KB | 513.7 KB |
  | Engage `-Osize` (budget 80 KB) | 75.6 KB | 75.6 KB |

  First cut was 392.7 KB; generic `split`/`Set`/sort specialisations were replaced with Foundation calls
  and arrays (−8.4 KB). Most of the growth is the actor's async state machines for the new gated calls.
  The margin is now ~16 KB: the next feature should look at moving JSON mapping out of the actor or
  `@_semantics("optimize.sil.specialize.generic.never")` on hot generics.
- **Tests** (Mac Catalyst): `Change03Tests` (28) and `PrivacyTests` (4, replacing the 1.1.0 jailbreak tests);
  117 in total with Engage (18), all passing.

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
- **iOS specifics**: two public overloads, `goal(_:value: Decimal?...)` and
  `goal(_:decimalString:...)` (wrappers). The queue entry keeps the wire item as `[String: JSONValue]` in
  `QueuedEvent.goal` (persisted in `events.json`; entry id `goal:<key>:<reference>`). Debug build =
  `#if DEBUG` (SPM / CocoaPods compile the SDK with the app's configuration). Like `track`, `goal` before
  `configure` fails with `not_configured`.
- **Size**: core `-Osize` 384.4 KB → 394.7 KB (budget 400 KB, ~5 KB headroom left). A first version was
  412 KB; trimmed by storing the wire JSON instead of a struct, folding goals into `flush()`'s single
  request site instead of a second `async` sender, regex-based normalisation instead of collection
  algorithms, a shared error reporter for `track` / `goal`, and logs without sorted code lists.

## Licence: Apache 2.0 (2026-10-26)

Owner chose Apache 2.0 for all mobile SDKs; clikgate_sdks stays MIT. The canonical text
(https://www.apache.org/licenses/LICENSE-2.0.txt, SHA-256 `cfc7749b…3d30`) is the root `LICENSE` and an
identical copy in each package directory that ships one (`ios/`, `flutter/`, `flutter_engage/`,
`react-native/`, `react-native-engage/`); metadata: POM (already Apache 2.0), podspecs
`{ :type => 'Apache-2.0', :file => 'LICENSE' }`, `package.json` `"license": "Apache-2.0"`, pubspec
packages read their `LICENSE`.

## Change 06 — shared-domain browser fallback (SDK 1.4.0, 2026-10-26)

- **Behaviour**: shared/SDK_BEHAVIOUR.md "Change 06 (SDK 1.4.0)". The four shared domains are one array in
  `SharedDomains` (Rules.swift); `SharedDomainFallbackTests` compares it with the shared fixture.
- **In-app browser**: `SFSafariViewController` presented from the key window's root view controller, walking
  `presentedViewController` to the top. Never `UIApplication.open`: for a Universal Link of this app it
  reopens the app (the loop the owner asked to avoid). SFSafariViewController doesn't route the
  initial URL back to the presenting app. No key window ⇒ nothing is shown and no notification is posted.
  `SafariServices` is a system framework (iOS 9+, also on Mac Catalyst), strongly linked.
- **Event = `NotificationCenter`**, not a handler API: a typed `onBrowserHandoff(_:)` handler plus a
  `ClikgateBrowserHandoff` model cost ~2 KB more than the notification and pushed the core to 400.3 KB
  (budget 400 KB). The notification carries the `URL` as `object`; the host is `url.host`. The Flutter and
  React Native plugins observe it and emit `{event: "browserHandoff", url, host}`, so their APIs match
  Android's. Not buffered on iOS (the wrappers buffer on their side).
- **Size work** (measured with `scripts/check_size.sh`, `-Osize`): first version 404.5 KB. Trimmed by keeping
  the deep-link dispatcher non-generic (a generic `Dispatcher<T>` cost ~2 KB), doing the hand-off in a
  synchronous main-queue helper on `DeepLinkDispatcher` instead of awaiting `MainActor.run` inside the
  `resolve` actor method, iterating `connectedScenes` as an `NSSet` instead of `compactMap`/`flatMap`, no
  retry loop for a missing window, no failure log, and the notification instead of a handler + model.
  Result **398.3 KB** (+3.6 KB; 1.7 KB headroom left).
- **Option**: `platformDomainBrowserFallback` (default true). The spec doesn't mention the fallback (owner
  request), so an off switch doesn't conflict with it. Named "platform domain" (the spec's term) because the
  core/Engage boundary checks of the other SDKs forbid `share` in public API names.
- **Flaky test seen**: `GoalsTests.testSameReferenceIsIdempotentRetriesAndPersistence` failed once in a full
  run (compares `"\($0)"` descriptions of dictionaries, whose key order can differ) and passed on reruns;
  pre-existing, not changed here.

## Size budget raised to 410 KB (1.5.0, owner decision 2026-10-28)

- The core grew to **400.8 KB** (`-Osize`, all public API) with the Change 09/10 work, over the 400 KB budget from
  spec 0.4. Size checks weren't run during those changes, so it was caught by the final full run.
- The owner chose to raise the core budget to **410 KB** rather than trim. Engage stays at < 80 KB (75.6 KB).
- `scripts/check_size.sh`, `docs/ios.md` and the podspec comment are updated.
- **410 KB is a hard ceiling** (owner, 2026-10-28): when the core grows past it, trim code (in the core or
  anywhere it helps) until it fits. Don't raise the budget again.

## One `goal()` method, Payment goals (2026-10-29)

- **`payment()` removed** (never released). Payment goals are reported with `goal(_:reference:provider:)`; the goal's
  kind lives only in the dashboard, never in the call. `/v1/sdk/payments` and the `payments` version-policy call are gone.
- **Result delivery.** `goal()`'s completion gets a `ClikgateGoalResult` once Clikgate answers, matched to the
  request by the `results[].index` of `POST /v1/sdk/goals`. Items without a result (an older answer) count. The
  completion lives on the queued item in memory only (`QueuedEvent.done`, never persisted): if the app quits first
  it is not called, but the goal is still sent on the next launch. Local refusals: `invalid_argument`,
  `not_configured`, `opted_out`, `consent_denied`, `feature_disabled`; batch drops pass the reason
  (`sdk_version_blocked`, `feature_disabled`, the error code of a final `4xx`); clearing the queue (opt-out, consent
  denied, deep-link-only) refuses what was queued. A second call with the same key and reference while the first is
  queued completes at once with `.waiting` / `already_queued` (keeping one completion per queued item keeps it small).
- **Names.** `ClikgateProvider`, `ClikgateGoalStatus`, `ClikgateGoalKind`, `ClikgateGoalResult`: every public type of
  this module has the `Clikgate` prefix. `ClikgateProvider` is a struct (not an enum) so `fromString(_:)` can return
  providers added after a release; it's generated by `scripts/generate_providers.py` (no `allCases`, for size).
  The status and kind enums have no raw values (`"\(status)"` prints `counted` / `waiting` / `refused`).
- **Wrappers** call `goal(_:decimalString:currency:reference:providerKey:isFirst:completion:)` with the provider
  key as a string; a malformed key is refused (`invalid_argument`).
- **Test mode** is a `cg_sdk_test_` SDK key: one warning-level line per Payment goal result that is waiting,
  ending "; its value was ignored" when a value was sent and dropped.
- **Size.** The first version was 416.0 KB (`-Osize`, budget 410 KB). Trimmed to **409.4 KB** by: validation moved
  into the core (no facade closure), no `Equatable` / raw values on the result types, no `allCases` /
  `CustomStringConvertible` on `ClikgateProvider`, results matched by index only (rejections appear in `results`),
  the completion stored on the queued item instead of a waiter list (a waiter list cost about 1.9 KB), a shorter
  test-mode line, one retry debug log without `String(format:)`, one hex helper for push-token hashes, and two
  shorter warnings (deep-link-only mode and private mode). Engage unchanged at 75.6 KB.
- **Published sources** carry no internal notes or references (change numbers, spec sections, contract files,
  real company domains); `Change03.swift` is `ConsentPolicy.swift`. The CocoaPods source zip ships `LICENSE`
  (the podspec needs it) and no longer ships this file.

## XCFrameworks ship without debug info (Change 12, S.4)

`scripts/build_xcframework.sh` runs `strip -S` on each static framework binary and drops the module's
`.abi.json` and `.swiftsourceinfo` files: all three carried the build machine's absolute source paths, which the
release scan (`scripts/scan_release_packages.py`) refuses. The symbol table and the `.swiftinterface` stay, so apps
link and crash reports symbolicate as before (checked by linking a small simulator app against the stripped
framework).

## Change 13: Engage `share.link` (2026-10-29)

- Design and wire format: `docs/DECISIONS.md` "Change 13" and `shared/SDK_BEHAVIOUR.md` "Change 13".
- **Size: Engage budget 80 → 95 KB** (-Osize, `scripts/check_size.sh`). Engage is 92.8 KB (was 75.6 KB); **core is
  unchanged at 409.4 KB** (no core file changed). The feature is about 10 KB of code plus Objective-C and Swift
  metadata for the `UIActivityItemSource` class and the async paths. Trimmed before raising (−8 KB): string-keyed
  tables instead of `[ClikgateShareApp: …]`, `shareUrls: [String: String]?` (the API's `share_urls` object as is),
  regex replacement instead of character-array parsing, one async entry point per link kind, no `CaseIterable`.
  Pending the owner's confirmation.
- `share.link` / `share.referralLink` are `async throws -> Bool` (`@discardableResult`); there is no completion
  variant (it would add another copy of the async machinery).
- Fixed in passing: `LinkDomainsTests` still used two real-looking domains next to the fictional ones from the
  Change 12 clean-up, and failed; now all fictional (`ybr.ng`, `go.yourbrand.com`).
