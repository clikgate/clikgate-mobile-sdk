# Progress: Change 23 S (unknown goal names refused), 2026-11-08

Spec: `docs/spec/clikgate-change-23-unknown-goals-goal-groups.md` S, R.1, R.9. Decisions: [DECISIONS.md](DECISIONS.md)
"Change 23". Versions: no bump.

| Item | Status | Where |
|---|---|---|
| `refused` / `unknown_goal` and `goal_archived` final | already final; whole-request `422` result body now keeps the reason | `Http.kt` `failure`, `APIClient.swift` `decodeError` |
| Debug-build message | ``Goal `{name}` isn't set up in Clikgate``, name only | `Core.kt` `resolveGoal`, `Core.swift` `noteUnsetGoal` |
| Docs | reason lists on every platform, CHANGELOGs, contract | `Models.kt`, `ClikgateModels.swift`, `models.dart`, `models.ts` |
| Contract | `goals_response_refused_unknown_goal`, `goal_refusal` schema + 2 fixtures; 37 schemas, 74 fixtures valid | `shared/generate.py`, `API_CONTRACT.md`, `SDK_BEHAVIOUR.md` |
| Tests | Android `StrictGoalNamesTest` (5), iOS `StrictGoalNamesTests` (4), Flutter `strict_goal_names_test.dart` (3), RN `strictGoalNames.test.ts` (3) | |

# Progress: Change 22 C22-S (one method `goal()`, installation ID, `received`), 2026-11-08

Spec: `docs/spec/clikgate-change-22-goals-identity-uninstalls-banners-reports.md` S, I.6–I.8, R.5, R.6, R.9, R.26, R.44.
Decisions: [DECISIONS.md](DECISIONS.md) "Change 22". **Versions: no bump** (nothing is published; native 1.5.1,
Flutter 1.5.1, React Native 1.6.1, setup command 1.1.1; `check_cli_sdk_versions.mjs` passes). Public release jobs
stay behind `vars.PUBLIC_SDK_RELEASES_ENABLED == 'true'`.

| Item | Status | Where |
|---|---|---|
| S: `track()` removed | done on Android, iOS, Flutter, React Native (API, bridges, queue, samples, tests, docs); `ClikgateMoney`, Firebase `mirrorEvents`/`eventNameMap`, version-policy `allowed_events`/`strip_event_properties` removed with it | `Clikgate.kt`, `Core.kt`, `Clikgate.swift`, `Core.swift`, `clikgate.dart`, `Clikgate.ts`, plugins |
| Old queued app events | dropped on the next flush, no network call (tests on Android and iOS) | `Core.kt` `flush`, `Core.swift` `nextBatch` |
| R.5 no conversion values | iOS on-device SKAdNetwork / AdAttributionKit updates and `conversion_value_schema` removed | `Rules.swift`, `Platform.swift`, `Wire.swift` |
| R.9 `received` | new status on every platform, a success, never retried | `Models.kt`, `ClikgateModels.swift`, `models.dart`, `models.ts` |
| I.7 / R.26 installation ID | `Clikgate.getInstallationId()` (Android suspend + listener), `try await Clikgate.shared.installationId()` (iOS), `await Clikgate.getInstallationId()` (Flutter, RN); null when tracking is off | facades, `Core.installationIdForApp` |
| I.8 identity docs | `identifyUser()` Path A and Path B on every README and platform guide, link to https://clikgate.com/docs/identify-users | `README.md`, `docs/*.md`, platform READMEs |
| R.6 banner right screen | `deeplink_handled` in live mode when `/resolve` says `measure_right_screen` (with `click_id`) | `Core.kt` / `Core.swift` `reportHandled` |
| Setup command | step 4 "Identify signed-in users" (Path A, Path B, guide link); never generated `track()` | `cli/src/setup.ts`, `constants.ts`, `dist/cli.cjs` rebuilt |
| Contract | events schemas/fixtures removed; `received`, R.6 fields, `goals_response_received`, banner fixtures; install fixtures at 1.5.1; 36 schemas, 70 fixtures valid | `shared/generate.py`, `API_CONTRACT.md`, `SDK_BEHAVIOUR.md`, `PLATFORM_CHANNEL.md` |
| R.44 CI guard | `scripts/check_no_track.mjs` (+ `--self-test`) and `.github/workflows/no-track-guard.yml`: clean | |
| Sample backend | `POST /orders` sends the `purchase` goal through `POST /v1/goals/events` | `samples/backend` |
| iOS core ceiling | **385.3 KB** after the R.22 follow-up (382.9 KB before it; was 407.6 KB; budget 410 KB), Engage 92.4 KB | `check_size.sh` |
| R.22 identify `verified` / `reason` (follow-up, 2026-11-08) | Android and iOS: identify 200 with a token sent and `verified: false` logs a warning naming the reason in plain words (customer ID kept, unverified); absent fields = older server, its `422 identity_invalid` still handled; referral / feature calls refused with `403 identity_expired` or `422 identity_invalid` log a warning. Never the token, secret or customer ID. No public API change (identify returns nothing, so Flutter / RN bridges unchanged). Tests use `identify_response_token_expired` | `Core.kt` `sendIdentify` / `featureCall`, `Core.swift` `sendIdentify` / `featureCall`, `IdentityVerifyTest.kt` (6), `IdentityVerifyTests.swift` (5); iOS `Logger.testSink` is `#if DEBUG` only |
| AI guides API surface | regenerated in `clikgate_sdks` (`generate-api-surface.mjs --mobile`); `--check` up to date | `clikgate_sdks/ai-guides/clikgate-setup/references/api-surface.md` |

## Engage merged into the core packages, 2.1.0 (2026-11-12, one heavy build at a time)

Owner decision: one package per SDK, no separate Engage library (see docs/DECISIONS.md "One package per SDK").

- Android: `:clikgate` 286 unit tests (core + Engage) 0 failures; `apiCheck`, `checkNoEngageDependency`, `lintRelease`,
  `:sample:assembleDebug` pass; size core 124.6 KB (< 150), Engage 43.3 KB (< 44).
- iOS: scheme `Clikgate-Package` (Mac Catalyst): ClikgateTests 210 + ClikgateEngageTests 24, 0 failures; `check_api.sh`
  (290 + 141 declarations) and `check_size.sh` core 385.4 KB (< 410), Engage 92.4 KB (< 95); sample app builds;
  `build_xcframework.sh` builds both frameworks from one archive.
- Flutter 3.35.4: `flutter analyze` clean; 115 plugin tests (core + Engage) and 16 example tests pass.
- React Native: typecheck, lint clean; Jest 182 tests pass; `bob build` and `npm pack --dry-run` include `src/engage`.
- Setup command: 157 tests pass; `check_cli_sdk_versions.mjs` passes (2.1.0 everywhere).
- `scripts/check_sdk_boundaries.sh` (with size): all steps pass; `check_no_track.mjs`, `check_no_identify.py` clean.

## Test runs (2026-11-08, one heavy build at a time)

- Android `:clikgate:testDebugUnitTest :clikgate-engage:testDebugUnitTest :clikgate:apiCheck :sample:compileDebugKotlin`: 236 + 39 tests, 0 failures; `:clikgate:lintDebug` passes.
- iOS `xcodebuild test -scheme Clikgate-Package` (iPhone 15 simulator): 201 tests (ClikgateTests 177, ClikgateEngageTests 24), 0 failures; `check_api.sh` and `check_size.sh` pass.
- Flutter (fvm 3.35.4) `flutter test`: 79 passed; `flutter analyze` clean (plugin and example).
- React Native `npx jest`: 129 passed (17 suites); typecheck and lint clean.
- Setup command `vitest`: 142 passed; typecheck clean; `check_cli_sdk_versions.mjs` passes.
- Sample backend: 15 passed.
- `node scripts/check_no_track.mjs --self-test` and the repository scan: pass.
- R.22 follow-up: Android `:clikgate:testDebugUnitTest` 242 tests, 0 failures; iOS `xcodebuild test -scheme Clikgate-Package` (iPhone 15 Pro simulator) 230 tests (ClikgateTests 206, ClikgateEngageTests 24), 0 failures; `check_api.sh` passes (290 + 141 declarations), `check_size.sh` core 385.3 KB / Engage 92.4 KB; `check_no_track.mjs` clean; `check_cli_sdk_versions.mjs` passes.
- Not run: Gradle / Xcode builds of the Flutter and React Native wrappers' native code (the bridges changed: `track` removed, `getInstallationId` added), Flutter Engage and React Native Engage tests (unchanged), emulators, device tests.

# Progress: Change 21 C21-S (opens by existing users, one tap one click, X `twclid`)

Spec: `docs/spec/clikgate-change-21-opens-deeplinks-ai-site-ads-chat-staff.md` S, R.2-R.4, R.25, K.3. Decisions:
[DECISIONS.md](DECISIONS.md) "Change 21". **Versions: patch** (Android, iOS, Flutter 1.5.1, React Native 1.6.1, setup
command 1.1.1; `check_cli_sdk_versions.mjs` passes; `clikgate_sdks/ai-guides/versions.json` follows).

| Item | Status | Where |
|---|---|---|
| S.1 `install_id` and the click reference on direct and redirect opens | confirmed on every platform (URL as opened to `/resolve`, `cg_click_id` inside it, `Clikgate-Installation-Id` on every call, no URL on `/open`) | |
| R.2 one tap, one click | **fixed**: no second `/resolve` of a launch URL the install matched (`status: matched`); iOS resolves by `click_id` or delivers locally | iOS `Core.swift` `handleInstallResponse`, `resolve(url:clickId:)`, `Wire.swift` `launchMatched`; Android `Core.kt` `sendInstall` |
| R.25 `twclid` | travels unchanged like `li_fat_id` (no wire field); web script unchanged, test added | tests below; `clikgate_api/tests/js/clikgate_snippet.test.mjs` |
| S.2 tests | Android `Change21Test.kt` (8), iOS `Change21Tests.swift` (10), Flutter `change21_test.dart` (3), React Native `change21.test.ts` (3), web script (1 block) | |
| K.3 SDK docs | "Replacing Firebase Dynamic Links" in the four guides and the README; stale Change 10 plan paragraph updated for Change 20 basic attribution | `docs/*.md` |
| Contract | `API_CONTRACT.md` "Change 21 additions" (basic attribution, open payloads, `twclid`); `SDK_BEHAVIOUR.md`; privacy table | `shared/` |
| iOS core ceiling | **407.6 KB** (was 407.0 KB; budget 410 KB), Engage 92.4 KB (`check_size.sh`) | |

## Test runs (2026-11-05, one at a time; no emulator, only the simulator xcodebuild needs)

- Android `:clikgate:testDebugUnitTest :clikgate-engage:testDebugUnitTest`: 231 + 39 tests, 0 failures.
- iOS `xcodebuild test -scheme Clikgate-Package`: ClikgateTests 195, ClikgateEngageTests 24, 0 failures.
- Flutter `flutter test`: 79 passed. React Native `npx jest`: 129 passed (16 suites).
- Setup command `vitest`: 141 passed (8 snapshots updated for the new versions).
- Web script (`clikgate_api/webscript` `npm test`): all checks passed on the source and the minified build.

# Progress: Change 20 C20-S1 (`deeplink_handled` for the live check)

Spec: `clikgate_api/docs/spec/clikgate-change-20-activity-offers-billing-dashboards.md` S.1, S.2, F, R.40.
Decisions: [DECISIONS.md](DECISIONS.md) "Change 20". **Versions: no bump** (folded into the unreleased native 1.5.0,
Flutter 1.5.0, React Native 1.6.0, CLI 1.1.0; `check_cli_sdk_versions.mjs` passes unchanged).

| Item | Status | Where |
|---|---|---|
| S.1 / R.40 `deeplink_handled` after a matched direct or deferred deep link; test key or `debug_view: true` answer only; path cleaned on the device | done (Android, iOS; Flutter and React Native through the native SDKs) | Android `internal/DeepLinkPath.kt`, `Core.kt` `reportHandled`; iOS `Rules.swift` `DeepLinkPath`, `Core.swift` `reportHandled`, `Wire.swift` (`debugView`), `ConsentPolicy.swift` (call name) |
| Never queued, metered or an event | done: own call `POST /v1/sdk/deeplink-handled`, one retry | |
| Shared contract | `deeplink_handled_request` / `_response` schemas, `debug_view` on `/resolve` and `/install` answers, fixtures, path vectors `deeplink_path_cases`; 38 schemas, 71 fixtures valid | `shared/generate.py`, `API_CONTRACT.md`, `SDK_BEHAVIOUR.md` |
| Backend endpoint | **not in `clikgate_api` yet** (C20-B5 in parallel); lead to reconcile with the contract section | |
| S.2 changelog | four CHANGELOGs, privacy table | |
| iOS core ceiling | **407.0 KB** (416,813 bytes; was 403.9 KB), measured with `check_size.sh`'s compile-and-sum method (compiler only); the first `String`-based cleaner was 411.5 KB and was rewritten on bytes | `Rules.swift` |

## Test runs (2026-11-04)

- React Native: `npx jest`: 15 suites, 126 tests, all pass (new `change20.test.ts`, 5); `tsc --noEmit` clean;
  eslint clean on the new file (one existing prettier error in `change19.test.ts`, not touched).
- Flutter (fvm 3.35.4): 76 tests, all pass (new `change20_test.dart`, 5); `flutter analyze` clean.
- iOS: `xcrun swiftc -typecheck` of `Sources/Clikgate` with `Change20Tests.swift` and `TestSupport.swift`: clean.
  The byte-level `DeepLinkPath` compiled on its own against `deeplink_path_cases.json`: 23 of 23 match.
- Shared contract: `generate.py` with jsonschema: 38 schemas, 71 fixtures, all valid.
- Not run (no Xcode / Gradle builds here): iOS `Change20Tests` (10), Android `Change20Test` (10, Robolectric; not
  compiled: no Kotlin compiler outside Gradle), `ios/scripts/check_size.sh` itself (core measured the same way, Engage unchanged), `scripts/check_sdk_boundaries.sh`.

---

# Progress: Change 19 C19-S1 (Apple Ads token timing, LinkedIn / Snap click ids)

Spec: `clikgate_api/docs/spec/clikgate-change-19-ad-networks.md` R.20 (S.1, S.2, S.4), R.1, R.15. Decisions:
[DECISIONS.md](DECISIONS.md) "Change 19". Server SDK part (S.3): `clikgate_sdks/docs/PROGRESS.md`. **Versions: no
bump** (nothing is published; folded into the unreleased native 1.5.0, Flutter 1.5.0, React Native 1.6.0, CLI 1.1.0;
`check_cli_sdk_versions.mjs` passes unchanged).

| Item | Status | Where |
|---|---|---|
| S.1 AdServices token requested when `/install` is sent (also after consent buffering), renewed after 24 h, memory only, cleared after the answer / on denial; not with attribution denied or blocked | done (iOS) | `Core.swift` (`searchAdsTokenForInstall`, `InstallExtras.sendsSearchAds`), `Storage.swift` (field removed) |
| S.1 IDFV with the install when `apple_search_ads` is on (identity-check consent unchanged), for Redownload linking | done (iOS) | `Core.swift` `collectInstallExtras` |
| S.1 `enableAppleAdsAttribution()` | never existed; nothing to drop. The `apple_search_ads` setting stays the only switch | |
| S.2 `li_fat_id` / `ScCid` | no new wire field (the backend's `/install` and `/open` schemas forbid unknown keys and B2 reads the ids from `launch_url`, `/resolve` `url` and the Play referrer); tests prove they travel unchanged, incl. consent buffering | `Change19Tests.swift`, `Change19Test.kt`, RN `change19.test.ts`, Flutter `change19_test.dart` |
| Docs | contract, behaviour, privacy table, platform guides, CHANGELOGs, `ios/DECISIONS.md` | |
| iOS core ceiling | **not measured** (estimate +0.3 to +0.8 KB over 401.9 KB; ceiling 410 KB) | |

## Test runs (2026-11-04)

- React Native: `npx jest`: 14 suites, 121 tests, all pass (new `change19.test.ts`).
- iOS: `xcrun swiftc -typecheck` of `Sources/Clikgate` (no build): clean.
- Not run (no Xcode / Gradle / Flutter builds on this machine): iOS `ClikgateTests` (new `Change19Tests`, 8 tests;
  `TestSupport.swift` `FakeSearchAds` now counts calls), Android `Change19Test` (3 Robolectric tests), Flutter
  `change19_test.dart` (no Flutter SDK installed), `ios/scripts/check_size.sh` itself (core measured the same way, Engage unchanged), `scripts/check_sdk_boundaries.sh`.

# Progress: Change 17 R.2 (opening the app directly must not skip the link gates)

Spec: `clikgate_api/docs/spec/clikgate-change-17-ab-password-rewards.md` R.2 (R.1, R.3 for context). Decisions:
[DECISIONS.md](DECISIONS.md) "Change 17". **Versions: no bump** (folded into the unreleased versions; CHANGELOGs
under Unreleased; `check_cli_sdk_versions.mjs` passes unchanged).

| Item | Status | Where |
|---|---|---|
| Contract: `status`, `web_url`, `block_message` on `/resolve` (required; gated answers must have null click / deep link / link / referral, enforced with `if`/`then`) | done; fixtures `resolve_response_password_required`, `_blocked`, `_ab_variant`; matched / unmatched fixtures gained the fields; 36 schemas, 63 fixtures valid | `shared/generate.py`, `API_CONTRACT.md`, `SDK_BEHAVIOUR.md`, `PLATFORM_CHANNEL.md` |
| `password_required` → system browser, nothing delivered | done: Android `BrowserOpener.openExternal` (explicit browser package, no Custom Tabs); iOS `UIApplication.open`, once per URL per 30 s | `Core.kt`, `BrowserHandoff.kt`; `Core.swift`, `DeepLinkDispatcher.swift`, `Platform.swift` |
| `blocked` → deep-link result with `blockMessage`, no route | done on all four (`ClikgateDeepLink.blockMessage`, `ClikgateDeepLinkResult.blockMessage`, Dart, TS; bridge key `blockMessage`) | `Models.kt`, `Json.kt`, `ClikgateModels.swift`, `models.dart`, `models.ts`, both plugins, both RN modules |
| A/B variant path | passes through unchanged (server-assigned); tested | |
| Deferred / gated payloads never deliver a destination | done (`status` read first); tested with a gated answer that wrongly carries a deferred deep link, and the first-launch launch URL | |
| iOS core ceiling | **401.9 KB (411,528 bytes; was 409.7 KB / 419,505)**: +3.4 KB for the change, −11.4 KB from not inlining the JSON readers | `JSONValue.swift`, `Storage.swift` |
| Docs | platform guides, README, CHANGELOGs | |

## Test runs (2026-10-31, one at a time; no emulator or simulator)

- Shared contract: `python3 shared/generate.py` (with jsonschema): 36 schemas, 63 fixtures, all valid; a password
  answer with a deep link is rejected by the schema.
- iOS (`xcodebuild test`, Mac Catalyst host, no simulator): ClikgateTests 166 (155 + 11 in `LinkGateTests`),
  ClikgateEngageTests 24, 0 failures; `scripts/check_api.sh --update` (one line: `blockMessage`); `check_size.sh`:
  core 401.9 KB (< 410 KB), Engage 92.4 KB.
- Android (`:clikgate:testDebugUnitTest :clikgate-engage:testDebugUnitTest apiCheck :clikgate:checkNoEngageDependency`,
  JVM / Robolectric): core 206 (196 + 10 in `LinkGateTest`), Engage 39, 0 failures; `apiDump` (`blockMessage`).
- Flutter (fvm 3.35.4): 70 tests (65 + 5 in `test/change17_test.dart`), `flutter analyze` clean, API snapshot updated.
- React Native: 120 tests (114 + 6 in `change17.test.ts`), typecheck and lint clean; public API listing unchanged.
- Not run: Android size budget (release AAR build), the wrappers' native builds (Flutter plugin / RN module map
  one more key), emulators, simulators, `check_sdk_boundaries.sh` as a whole, Engage packages (unchanged).

## Open points

- iOS: check on a device that `UIApplication.open` of the app's own password link opens Safari (DECISIONS).
- Android first launch: a gated custom-domain launch URL delivers nothing and opens no password page (no leak);
  an install answer with `status` would fix it (backend, DECISIONS).

---

# Progress: Change 14 (C14-S1: identifyUser, goal labels)

Spec: Change 14 S.1 (copy in `clikgate_api/docs/spec/`). Decisions: [DECISIONS.md](DECISIONS.md) "Change 14".
**Versions: no bump** (folded into the unreleased versions).

| Item | Status | Where |
|---|---|---|
| `identifyUser(label?, customerId?, identityToken?)` replaces `identify()` | done on Android, iOS, Flutter (Dart + both plugins), React Native (TS + TurboModule on both OSes); "leave it out" keeps the customer ID, null clears it, nothing to send is a no-op | core SDKs, bridges |
| `goal()` gains `label` (`isFirst` existed) | done on every platform; dropped in private mode unless `allow_labels` | |
| Private mode / `allow_labels` / `label_ignored: "plan"` warnings | done | `Core.kt`, `Core.swift` |
| Shared contract | `identify_request` (`label`, optional `customer_user_id`), `identify_response` (`person_id`, `label_ignored`), goal item `label`, config `allow_labels`; new fixtures; 36 schemas, 60 fixtures valid | `shared/` |
| Web script | `clikgate.identifyUser()` + `goal({label})` | `clikgate_api/webscript` |
| Server SDKs (Node, Python sync + async, PHP, Java, .NET) | `identifyUser` → `POST /v1/people/identify`, goal `label`, guard (`identify` kind), conformance suite `people` (6 cases); generated layer regenerated from the current OpenAPI (people endpoints, removed app identify, **App banners rename**: `AppBannersApi`, `ID_PREFIX app_banner: 'jrn'`) | `clikgate_sdks/server` |
| Examples | Android sample, iOS sample, Flutter example (+ integration test), RN example | |
| Docs, AI guides | platform guides, READMEs, CHANGELOGs, `shared/*.md`, `scripts/check_no_identify.py` (boundary check); AI guides (`goals.md`, `web.md`, regenerated `api-surface.md`); website server SDK pages and web script page | |
| iOS core ceiling | **409.7 KB (< 410 KB)**: +1.8 KB for the change, −1.7 KB trimmed (DECISIONS) | |

## Test runs (2026-10-29)

- Android: core 196 tests (191 + 5), Engage 39, 0 failures; apiDump/apiCheck, lintRelease (0 errors), sample compile;
  sizes core 128.5 KB, Engage 42.2 KB. Fixed in passing: `LinkDomainsTest` (same half-done domain rename as iOS).
- iOS (Mac Catalyst): ClikgateTests 155 (151 + 4), ClikgateEngageTests 24, 0 failures; API snapshots updated; sizes
  core 409.7 KB, Engage 92.8 KB; sample `xcodebuild` generic iOS: succeeded.
- Flutter: core 65 tests, Engage 34, example 16; `flutter analyze` clean in all three (the integration test updated);
  `build apk --debug` and `build ios --debug --no-codesign`: built.
- React Native: core 114, Engage 50; typecheck and lint clean; example `:app:compileDebugKotlin`, `pod install` +
  `xcodebuild` generic iOS: succeeded.
- Web script: `npm test` (snippet, share, identify suites on source and build), `npm run check`, `typecheck`,
  published-code scan: pass; 5,894 bytes gzipped.
- Server SDKs: conformance node 459, python 454 (sync) + 454 (async), php 452, java 453, dotnet 452, all passing;
  unit: node 34, python 49, php 27, java 21 (+ starter), dotnet passed; typecheck/lint/mypy/ruff/phpstan/cs-fixer/
  `dotnet format`/`mvn verify` clean; `codegen --check` and `build-cases --check` pass; Node package scan clean.
- `scripts/check_sdk_boundaries.sh` (all platforms, sizes, scans, the new identify and share-targets checks): passes.

---

# Progress: Change 13 (share helpers: C13-S1, C13-S2)

Spec: [spec/clikgate-change-13-attribution-qr-sso.md](spec/clikgate-change-13-attribution-qr-sso.md) S.1, S.2 (the
spec copy lives in `clikgate_api/docs/spec/`). Decisions: [DECISIONS.md](DECISIONS.md) "Change 13". **Versions: no
bump** (nothing published; folded into native 1.5.0, Flutter Engage / RN Engage 1.0.0; CLI constants unchanged).

| Item | Status | Where |
|---|---|---|
| `ShareApp` on every platform | done: generated from `shared/share_targets.json` (backend `ShareApp` enum + endings, checked with `--check`) | `scripts/generate_share_targets.py` |
| Android `share.link` / `share.referralLink` | done: chooser + per-package texts + explicit mutable `IntentSender` callback (`ClikgateShareReceiver`), Android 15 chooser result, direct share with SMS / email fallbacks, no `<queries>`, share events | `clikgate-engage/…/EngageShare.kt` |
| iOS `share.link` / `share.referralLink` | done: `UIActivityItemSource` per activity type, bundle-ID prefix table, completion records "share started", direct WhatsApp / Telegram / X / Mail | `Sources/ClikgateEngage/EngageShare.swift` |
| Flutter | done: `engage.share.link` / `referralLink` over a new plugin in `clikgate_engage` (Android + iOS, CocoaPods and SPM) calling native Engage | `flutter_engage/` |
| React Native | done: `engage.share.link` / `referralLink` over a new TurboModule `ClikgateEngage` (codegen `RNClikgateEngageSpec`) in `@clikgate/react-native-engage` calling native Engage | `react-native-engage/` |
| Share events | done: `POST /v1/share-events {url, app}` with the SDK key; schemas and fixtures `share_event_request` / `share_event_response`; test vectors `share_cases` | `shared/` |
| Example apps | done: Android sample, iOS sample, Flutter example (Engage variant) and React Native example share the invite link with `share.referralLink` (and WhatsApp with `app`); the RN example links the Engage package natively (`react-native.config.js`), both examples substitute `clikgate-engage` in their Gradle composite builds | samples |
| C13-S2 web share buttons | done in `clikgate_api/webscript` (`clikgate.share.mount`) | `clikgate_api/docs/PROGRESS.md` |
| Docs, AI guides, snippets | done: platform guides, `engage.md`, `shared/*.md`, package READMEs and CHANGELOGs; website `docs/sdks/{android,ios,flutter,react-native,web}.mdx`; AI guides (`SKILL.md`, `references/web.md`, regenerated `api-surface.md`) | |
| Size budgets | **raised, owner to confirm**: Engage Android 40 → 44 KB (now 42.2), Engage iOS 80 → 95 KB (now 92.8); core unchanged (Android 128.5 KB, iOS 409.4 KB) | DECISIONS |

## Test runs (2026-10-29)

- Android: Engage 39 tests (28 + 11 new), 0 failures; `apiDump` / `apiCheck`, `checkNoEngageDependency`,
  `lintRelease` (no issues), sample `compileDebugKotlin`; sizes core 128.5 KB, Engage 42.2 KB (< 44). Release scan of
  the Engage AAR and sources jar: 0 findings. Core unchanged (not re-run).
- iOS (Mac Catalyst): ClikgateTests 151, ClikgateEngageTests 24 (18 + 6 new), 0 failures (after fixing
  `LinkDomainsTests`); `check_api.sh` (snapshots updated); sizes core 409.4 KB (< 410), Engage 92.8 KB (< 95);
  sample `xcodebuild` for generic iOS: succeeded. Release scan (pod + SPM): 0 findings.
- Flutter (fvm 3.35.4): clikgate_engage 34 tests (29 + 5 new), `flutter analyze` clean; example 16 tests, analyze
  clean; `flutter build apk --debug` and `flutter build ios --debug --no-codesign`: built.
- React Native: core 114 tests, typecheck and lint clean (the example included); Engage 50 tests, typecheck, lint
  and `bob build` clean; example `:app:compileDebugKotlin` (after `publishToMavenLocal` of both native modules) and
  `pod install` + `xcodebuild` generic iOS: succeeded.
- `scripts/check_sdk_boundaries.sh` (all platforms, sizes): passes (after the iOS snapshot update and removing
  internal references from shipped comments and CHANGELOG headings). `check_cli_sdk_versions.mjs`: passes.
  `shared/generate.py`: 36 schemas, 56 fixtures, all valid.

## Open points

- Owner: confirm the Engage size budgets (above) and that the SDKs / web script may carry the endings table (or
  ask the backend for an SDK/web-key `share_urls` route: DECISIONS).
- Owner launch checks (no devices here): the Android chooser callback on a Pixel and a Samsung (One UI) share
  sheet, replacement extras for Direct Share targets, Android 15's copy result; iOS activity types of each app's
  share extension (WhatsApp Business, Facebook, Messenger, X, LinkedIn, TikTok, Telegram, Gmail), and that every
  tagged link survives (spec "Before building").
- CI: `.github/workflows/react-native.yml` now also publishes `:clikgate-engage` to Maven Local for the RN example
  (not run here).
- Share events for a referral link are recorded by the referral URL that was shared (`/r/CODE-…`, `?ref=CODE-…`),
  which the backend now resolves (2026-10-29 follow-up; the `short_url` fallback is removed). Re-run: Android
  Engage 39 tests, iOS Engage 24, 0 failures; API checks pass; Engage 42.2 KB (Android) and 92.4 KB (iOS).

---

# Progress: Change 12 (one `goal()` method, Payment goals, enums, clean published code)

Spec: [spec/clikgate-change-12-goal-kinds-onboarding.md](spec/clikgate-change-12-goal-kinds-onboarding.md) S.1, S.4,
S.5 (workspace header first). Backend shapes: the C12 backend contract B2 and B3 (final).
**Versions: no bump.** Nothing is published, so the work folds into the unreleased versions: Android and iOS 1.5.0,
Flutter 1.5.0, React Native 1.6.0, setup command 1.1.0; Flutter Engage and React Native Engage 1.0.0 (comment and
packaging clean-up only, no API change). The Change 11 note "1.6.0 / RN 1.7.0 at release" is superseded: `payment()`
never shipped. If any of these had been published with `payment()`, the removal would need a major version.

| Item | Status | Where |
|---|---|---|
| `payment()` removed | done on every platform: public API, the `/v1/sdk/payments` flush path, the `payments` version-policy call, bridges (Flutter channel method, RN TurboModule method), tests, samples, docs; Android `GoalOptions` removed too | `Clikgate.kt`, `Clikgate.swift`, `clikgate.dart`, `Clikgate.ts`, plugins |
| One `goal(key, value?, currency?, reference?, provider?, isFirst?)` | done; returns `GoalResult {status: GoalStatus, reason, goalKind: GoalKind?, valueIgnored}` (Android listener, iOS completion, Flutter `Future`, RN `Promise`), from `/goals` `results[index]`; local refusals `invalid_argument`, `feature_disabled`, `opted_out`, `consent_denied` (iOS also `not_configured`) | `shared/SDK_BEHAVIOUR.md` "Change 12" |
| `Provider` enum | generated from the backend's committed OpenAPI `Provider` enum via `shared/providers.json` by `scripts/generate_providers.py` (`--check` in CI and the boundary checks; `--openapi` refreshes the snapshot); `fromString` on every platform. Android `Provider`, iOS / Flutter / RN `ClikgateProvider` (avoids clashes with package:provider and react-redux) | `scripts/generate_providers.py` |
| Test-mode lines | done: with a `cg_sdk_test_` key, "<key> is a Payment goal: waiting for confirmation" and the value-ignored line (iOS joins both in one line, for size) | `Core.kt`, `Core.swift` |
| Queueing and retries | unchanged | |
| Shared contract | `goals_request` item `provider`, `goals_response` `results` / `rejected[].index` / `missing`; fixtures `goals_request_payment`, `goals_response_results`; payments schemas and fixtures removed; checked against the backend's models (`SdkGoalsRequestSchema`, `SdkGoalsResponse`) | `shared/generate.py`, `API_CONTRACT.md`, `PLATFORM_CHANNEL.md` |
| S.4 release scan | `scripts/scan_release_packages.py` (AAR, sources jar, XCFramework zip, CocoaPods source files, pub package, npm pack): TODO/FIXME, internal-document references, internal hosts, local paths, staff references, debug code. In `.github/workflows/release-scan.yml`, before every release job's publish step, and in `scripts/check_sdk_boundaries.sh`. All packages clean after the clean-up (comments, CHANGELOG wording, `Change03` source files renamed, real company domains replaced with fictional ones, `flutter/.pubignore`, the CocoaPods zip ships `LICENSE` instead of `DECISIONS.md`) | |
| S.5 docs and snippets | README, platform guides, package READMEs, sample apps; the setup command's next steps show one `goal()` call per platform with the Provider enum | `cli/src/constants.ts` `GOAL_SNIPPET` |
| CLI docs links | every docs URL the CLI prints resolves on the website: `/docs/setup-command`, `#what-gets-changed`, `#app-link-subdomains` | `clikgate_website/content/docs/setup-command.mdx` |

## Test runs (2026-10-28/29)

- Android (heavy.sh): core 191 tests, Engage 28, 0 failures (one earlier run had a single unrelated
  `FeatureSwitchesTest` failure that passed on rerun); `apiCheck`, `checkNoEngageDependency`, `lintRelease`,
  release AARs, sources jars and the sample build pass. Size: core 128.5 KB (< 150 KB), Engage 33.4 KB (< 40 KB).
- iOS (heavy.sh, Mac Catalyst, no simulator): ClikgateTests 151, ClikgateEngageTests 18, 0 failures;
  `check_api.sh` passes. Size (-Osize): core 409.4 KB (< 410 KB; was 408.0 KB), Engage 75.6 KB (< 80 KB).
- Flutter (fvm 3.35.4): 65 tests, Flutter Engage 29; `flutter analyze` clean.
- React Native: 114 tests, React Native Engage 45; typecheck, lint and build clean.
- Setup command: 97 vitest tests, typecheck clean, `dist/cli.cjs` rebuilt, `check_cli_sdk_versions.mjs` passes.
- Shared contract: `shared/generate.py`: 34 schemas, 53 fixtures, all valid. `generate_providers.py --check` passes.
- Release scan: 0 findings for the Android AARs and sources jars, the CocoaPods source files, both pub packages
  and both npm packages.
- Bridges (heavy.sh, no emulator or simulator): Flutter example `build apk --debug` and `build ios --debug
  --no-codesign`, React Native example `:app:compileDebugKotlin` (needs `:clikgate:publishToMavenLocal`, as
  `react-native.yml` does) and `xcodebuild` for `generic/platform=iOS` after `pod install`: all pass.
- `scripts/check_sdk_boundaries.sh` (all platforms, sizes included): passes.
- XCFrameworks (`ios/scripts/build_xcframework.sh`): built; the release scan found the build machine's source
  paths in the debug info and `.abi.json` files, so the script now strips debug info and drops those files
  (ios/DECISIONS.md); the rescan has 0 findings and an app still links against the framework.
- SPM mirror: `scripts/spm_mirror.py` assembles only `Package.swift` (test targets removed), `Sources`, `LICENSE`
  and the new `ios/README.md` (31 files); `ios.yml` publishes that set instead of `git subtree split --prefix ios`
  (which shipped Tests, the sample app and DECISIONS.md). `swift package dump-package` and an `xcodebuild` iOS
  build of the assembled mirror pass; `scan_release_packages.py --spm` (release-scan.yml, ios.yml, the boundary
  checks) has 0 findings.
- Setup command package: `scan_release_packages.py --cli cli` (cli.yml, cli-release.yml) skips the bundled
  dependencies by esbuild's `// node_modules/<package>/` module markers (23,280 of 27,103 lines) and allowlists
  the two exact deep-link handler lines it writes into apps (`console.log('Clikgate deep link', …)`,
  `print("Clikgate deep link:", …)`: they show the developer the link arrived, next to "open the screen"). 0 findings.

## Open points

- Goal results are in memory only: a goal still queued when the app is killed is sent on a later launch without a
  result; an evicted goal (queue overflow) gets none.
- iOS headroom is about 0.6 KB under the 410 KB ceiling.

---

# Progress: Change 10 (deep links on every plan, D.5)

Spec: [spec/clikgate-change-10-platforms-marketplaces.md](spec/clikgate-change-10-platforms-marketplaces.md) D.5
(and D.1 / D.6 for the setup command). Backend shapes: the C10 backend contract, B3a.2 and B3a.3 (B3 final).
**Versions: no new bump.** The work is folded into the unreleased Change 09 versions: Android and iOS 1.5.0,
Flutter 1.5.0, React Native 1.6.0, setup command 1.1.0. Nothing in RELEASING.md requires a new number for
unreleased work, and the CLI constants stay equal to the SDKs.

| Item | Status | Where |
|---|---|---|
| `goal()` / `track()` in deep-link-only mode | done (Android, iOS; Flutter and React Native through the native SDKs): when `app_attribution` is off (cached config, or a `feature_disabled` answer since the last config fetch) they log one "attribution is switched off" warning per launch and return without queueing; no error | `Core.kt`, `Core.swift` |
| `feature_disabled` on `/events` and `/goals` | done: the batch is dropped, never retried, `app_attribution` is marked off, the config is refreshed, and the rest of the queue is dropped without a call. Before: both were dropped without retry already, but with no warning (iOS, Android events) or a warning on every batch (Android goals), and later calls kept going to the network | `Core.kt` `flush` / `flushGoals`, `Core.swift` `flush` |
| "No deferred link" at the cap | **already done**: `deep_link: null` with organic attribution is the normal empty install result (no callback, no error, no retry). Now covered by tests | `DeepLinkOnlyTest`, `DeepLinkOnlyTests` |
| `deep_linking` feature key | added to the catalogue defaults (on before the first config fetch and on older servers). No new public constant or method | `SdkConfig.kt`, `FeatureSwitches.swift` |
| Contract fixtures | `config_response_deep_link_only`, `events_response_feature_disabled`, `goals_response_feature_disabled`, `install_response_deep_link_only`, `install_response_deferred_cap` | `shared/generate.py`, `API_CONTRACT.md` / `SDK_BEHAVIOUR.md` "Change 10" |
| Setup command on Free | done: release builds get `app_link_domains.release` (`yourapp.clk.ng` on Free), debug builds `app_link_domains.debug` (`yourapp.dev.ciz.to`). `appSubdomainOf` accepts `<sub>.clk.ng`; prompts name the plan's parent from `link_hostnames`; offline `--domain yourapp.clk.ng` derives the debug host. The shared-domain check stays an exact host match | `cli/src/constants.ts`, `cli/src/setup.ts` |
| `doctor` on Free | done: `<sub>.clk.ng` passes `*.shared_domains`, the release-domain checks and the server link-subdomain check; fix texts mention `clk.ng` | `cli/src/doctor.ts`, `cli/test/doctor.test.ts` |
| Docs | platform guides (Android, iOS, Flutter, React Native), README, the Flutter and React Native READMEs, `SETUP_COMMAND.md`, CHANGELOGs | |

## Test runs (2026-10-27)

- Android (heavy.sh): `:clikgate:testDebugUnitTest :clikgate-engage:testDebugUnitTest apiCheck :clikgate:checkNoEngageDependency`: 209 tests, 0 failures (5 new in `DeepLinkOnlyTest`); the API dump is unchanged.
- iOS (heavy.sh, Mac Catalyst, no simulator): ClikgateTests 144 (6 new in `DeepLinkOnlyTests`), ClikgateEngageTests 18, 0 failures; `scripts/check_api.sh` passes.
- Flutter (fvm 3.35.4): 62 tests (4 new in `test/change10_test.dart`), `flutter analyze` clean.
- React Native: 111 tests (6 new in `change10.test.ts`), typecheck and lint clean.
- Setup command: 96 vitest tests (4 new), typecheck clean, `dist/cli.cjs` rebuilt, `check_cli_sdk_versions.mjs` passes.
- Shared contract: `python3 shared/generate.py`: 34 schemas, 51 fixtures, all valid.
- Not run: Flutter Engage and React Native Engage (unchanged), emulators, simulators, size budgets, Gradle and Xcode builds of the wrappers' native code.

## Owner actions

- `*.clk.ng` wildcard DNS and certificate (backend contract): until then `yourapp.clk.ng` doesn't resolve, so Free app links can't verify in production. Nothing was configured here.

---

# Progress: Change 09 (consistency fixes, app link subdomains)

Spec: [spec/clikgate-change-09-consistency-security.md](spec/clikgate-change-09-consistency-security.md). Backend
shapes: the C9 backend contract (B1 final, B2 final; B4's CLI answer in its "Questions from SDKs" section).
Versions: Android and iOS 1.5.0, Flutter 1.5.0, React Native 1.6.0, setup command 1.1.0 (Engage packages
unchanged: Flutter Engage and React Native Engage need no release; native Engage shares the 1.5.0 version).

| Item | Status | Where |
|---|---|---|
| N.4 `/v1/sdk/goals` | **already done**: every SDK sends goals to `/v1/sdk/goals` since 1.3.0 (contract B1.4: unchanged) | `shared/API_CONTRACT.md` "Change 06 additions" |
| X.E15 goal `Idempotency-Key` | **already done** (Android, iOS; Flutter and React Native use the native queue): one random UUIDv4 per request, reused by that request's retries. Contract text and tests added | `shared/API_CONTRACT.md` "Change 09 additions"; `GoalsTest`, `GoalsTests` |
| X.E10 `ClikgateMoney.ofMinor(...)` | done on all four platforms; the old constructors stay as deprecated aliases (Android, iOS, Flutter); React Native adds the value next to the type | `Models.kt`, `ClikgateModels.swift`, `models.dart`, `models.ts` |
| X.E17 iOS `Clikgate.shared.goal(...)` | **already done** (the API since 1.3.0; docs and AI guides use it) | `ios/Sources/Clikgate/Public/Clikgate.swift` |
| X.E23 `/v1/sdk/install` consent | done: the four-purpose object only, no `tracking_allowed`; the opted-out first install sends every purpose `denied` (fixture `install_request_opted_out.json`). The backend's opt-out parity for `attribution: denied` is in its C9-B5 milestone | Android `Core.kt`, iOS `Wire.swift` / `Core.swift`, `shared/generate.py` |
| X.E7 `cg_click_id` / `cg_link_id` | **already done**: `attributionMetadata()` returns those keys; the mobile SDKs read no cookie | `shared/SDK_BEHAVIOUR.md` "`attributionMetadata()`" |
| X.E13 pasteboard off by default | **already done**: iOS `pasteboardMode` defaults to `.off`; the Flutter and React Native bridges default to `off` | `ClikgateOptions.swift`, both plugins |
| D8 no trophy / challenge / progress data | **already done** (checked core and Engage on every platform); `docs/engage.md` now says they are server-only | `docs/engage.md` |
| N.1 setup command | done: release `app_link_domains.release`, debug `app_link_domains.debug`, per platform, never a shared domain; unconfirmed subdomains confirmed after asking; offline `--domain yourapp.ciz.to,…` | `cli/src/setup.ts`, `docs/SETUP_COMMAND.md`, `cli/DECISIONS.md` |
| N.1 `doctor` | done: `*.shared_domains` warnings ("remove this: shared domains can't open your app"), `*.dev.ciz.to` test-host checks, server checks of the app subdomain's AASA / assetlinks and `clikgate.<platform>.link_subdomain` | `cli/src/doctor.ts` |
| N.3 CLI device sign-in | done: the two-factor code is entered on the browser approval page (contract answer); the CLI says so and reminds after a minute of waiting | `cli/src/api/device.ts` |
| SDK docs | app link subdomain sections in every platform guide and the README; Expo plugin wording | `docs/*.md`, `react-native/plugin` |

## Test runs (2026-10-27)

- Android (heavy.sh): `:clikgate:testDebugUnitTest :clikgate-engage:testDebugUnitTest apiCheck :clikgate:checkNoEngageDependency`: 204 tests, 0 failures.
- iOS (heavy.sh, Mac Catalyst, no simulator): ClikgateTests 138, ClikgateEngageTests 18, 0 failures; `scripts/check_api.sh` passes.
- Flutter: 58 tests, `flutter analyze` clean; Flutter Engage tests pass.
- React Native: 105 tests (library and plugin); React Native Engage 45; typecheck and lint clean.
- Setup command: 92 vitest tests; `scripts/check_cli_sdk_versions.mjs` passes; `dist/cli.cjs` rebuilt.
- Shared contract: `python3 shared/generate.py`: 34 schemas, 46 fixtures, all valid.
- Not run: emulators, simulators, size budgets, Gradle and Xcode builds of the wrappers' native code.
