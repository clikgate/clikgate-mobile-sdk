# Android SDK + Flutter plugin (Android side): decisions and platform research

> **2.1.0 (2026-11-12): the Engage add-on is merged into this package.** See [docs/DECISIONS.md](../docs/DECISIONS.md) "One package per SDK". Entries below that describe Engage as a separate package, module or subspec are history; the core/Engage boundary and the size budgets they describe still apply.

Research done on 2026-10-20 against official docs and the artifacts on Google Maven /
Maven Central. Where something was checked by inspecting a published artifact (e.g. `javap`
on the AAR), that is noted.

## Toolchain

| Item | Choice | Why |
|---|---|---|
| AGP | 8.9.1 | Same as the Flutter 3.35.4 plugin/app templates. The Flutter example includes `android/` as a composite build, and AGP refuses two different AGP versions in one build. |
| Kotlin | 2.1.0, `apiVersion`/`languageVersion` 1.9 | Same as the Flutter 3.35 templates; metadata emitted for 1.9 so apps still on Kotlin 1.9 can consume the AAR. |
| Gradle | 8.14 wrapper in `android/` | AGP 8.9 needs ≥ 8.11.1. The build scripts also run under the Flutter example's Gradle 8.12 (checked with `flutter build apk`). |
| compileSdk / minSdk | 36 / 21 | minSdk 21 per spec. `android.suppressUnsupportedCompileSdk=36` because AGP 8.9 is only tested to 35 (Flutter's template does the same). |
| JDK | 17 (bytecode target 11) | |
| Explicit API mode | on (library sources only) | Keeps the public surface intentional. |

## Dependencies (minSdk 21 constrains versions)

Checked the `minSdkVersion` in each AAR's manifest on Google Maven:

| Library | Version | Note |
|---|---|---|
| `com.android.installreferrer:installreferrer` | 2.2 (latest) | minSdk 8. |
| `androidx.work:work-runtime` | 2.10.5 | 2.11.0 needs minSdk 23, 2.12 needs 24. 2.10.x is the last line supporting 21. |
| `androidx.lifecycle:lifecycle-process` | 2.9.4 | 2.10.0 needs minSdk 23. |
| `androidx.core:core` | 1.16.0 | minSdk 21; needs compileSdk 35 (1.17 would force compileSdk 36 on apps). |
| `com.google.android.play:integrity` | 1.6.0, **compileOnly** | minSdk 23 (its manifest isn't merged because it's compileOnly). Used only when the app ships it, on API 23+, checked with `Class.forName`. `play-services-tasks` 18.2.0 is compileOnly too (its `Task` type). |

No Firebase dependency; no OkHttp, no coroutines (see below).

## HTTP: `HttpURLConnection`, not OkHttp

The SDK makes a handful of small JSON calls; OkHttp + Okio would add ~800 KB (before R8) and
can clash with an app's OkHttp version. `HttpURLConnection` (backed by OkHttp inside the
platform anyway) with 10 s connect/read timeouts, no redirects, fixed-length bodies is enough.
JSON is `org.json` (in the platform). MockWebServer 4.12 is used only in tests.

## Async API without kotlinx-coroutines

Callbacks use `fun interface`s (`ClikgateCallback<T>`, `DeepLinkListener`,
`AttributionListener`) so Kotlin trailing lambdas and Java lambdas both work. `suspend`
variants (`awaitAttribution`, `referrals.awaitLink` / `awaitApplyCode` / `awaitMyStats` /
`awaitReferredBy` / `awaitShareIntent`) are built on the stdlib's `suspendCoroutine`, so the
SDK doesn't depend on kotlinx-coroutines. Trade-off: cancelling the coroutine doesn't cancel
the underlying request (the result is discarded).

## Threading model

All mutable state lives on one serial `ScheduledThreadPoolExecutor` thread; HTTP runs on a
3-thread pool and continues on the serial thread. A single `pump()` inspects persisted +
in-memory state and starts whatever is due (install, opt-out, resolve, identify, push token,
open, re-attestation, flush). Retries are scheduled (never `Thread.sleep`). Every callback is
posted to the main looper. Calls made before `configure()` are queued (max 100) and applied
before the SDK starts, so `setTrackingEnabled(false)` / `setPushToken` / `identify` /
intents issued early are honoured on the very first `/install`.

## Play Install Referrer (verified)

- Docs: <https://developer.android.com/google/play/installreferrer/library> — call once
  after install, cache the result, call `endConnection()`; data is available for 90 days.
- `javap` on `installreferrer-2.2.aar`: `ReferrerDetails` has `getInstallReferrer()`,
  `getReferrerClickTimestampSeconds()`, `getInstallBeginTimestampSeconds()`,
  `getReferrerClickTimestampServerSeconds()`, `getInstallBeginTimestampServerSeconds()`,
  `getInstallVersion()`, `getGooglePlayInstantParam()` (the server-side timestamps and install
  version exist in 2.x although the reference page doesn't list them).
  `InstallReferrerResponse`: `OK`, `SERVICE_UNAVAILABLE`, `FEATURE_NOT_SUPPORTED`,
  `DEVELOPER_ERROR`, `SERVICE_DISCONNECTED`, `PERMISSION_ERROR`.
- Behaviour: `SERVICE_UNAVAILABLE`, `SERVICE_DISCONNECTED`, an exception from
  `getInstallReferrer()` and "no callback within 10 s" are transient → retried after 1 s,
  2 s, 4 s. `FEATURE_NOT_SUPPORTED` / `DEVELOPER_ERROR` / `PERMISSION_ERROR` / missing Play
  Store → done, no referrer. The "done" flag is stored only for final outcomes; if the
  service stays unavailable, `/install` is sent without it and a later first-launch attempt
  (only if `/install` hasn't succeeded yet) may query again.
- The `referrer` string is sent exactly as returned (still URL-encoded). Timestamps of `0`
  (Play's "unknown") are sent as `null`.
- `startConnection` is called on the main thread (the library binds a service and calls back
  on the main looper).

## Installer package

`PackageManager.getInstallSourceInfo(pkg).installingPackageName` on API 30+;
`getInstallerPackageName` (deprecated in API 30) below.

## Play Integrity

- Docs: <https://developer.android.com/google/play/integrity/classic> and the standard-request
  page. Standard requests need a warm-up (`prepareIntegrityToken`) and bind via
  `requestHash`; classic requests take a `nonce` (URL-safe Base64, 16–500 chars), are meant
  for infrequent high-value checks, and need `setCloudProjectNumber` only for apps distributed
  outside Play.
- Choice: **classic** request with the server nonce passed exactly as received from
  `/attest/challenge` (contract: "classic requests pass `nonce` as the nonce"). Install-time
  and weekly checks are exactly the "infrequent, one-off" case, and a classic request needs no
  warm-up on the first launch. `ClikgateOptions.cloudProjectNumber` is passed when set.
- Enabled only when `options.attestation == PLAY_INTEGRITY_IF_AVAILABLE`, the server config
  says `features.attestation.android_play_integrity != "off"`, the library is on the
  classpath, and API ≥ 23. Failures (no Play services, timeout 10 s) simply omit attestation.
- Challenges are single use with a 5-minute expiry: `/install` retries and polls drop the
  `attestation` object after the first attempt; the weekly re-attestation (`/attest`,
  `reattestation_interval_days`) then covers the installation. `/attest` is single-attempt.

## App Links and intents

- `handleIntent(activity, intent)` reads `intent.data`; it's a Clikgate URL when the host is in
  `options.linkDomains` ∪ cached `config.link_domains` (http/https), or it's a non-http scheme
  carrying `cg_click_id`. **Judgement call:** the SDK doesn't know the app's registered URI
  scheme (no option in the spec's Android API), so any custom scheme with `cg_click_id`
  counts.
- Connected domains (backend Part 3 §31.3): `config.link_domains` is optional (`[]` from older
  servers); non-string / empty items are dropped, and both sets are normalised the same way
  (trim, lowercase, scheme and path stripped). The configured domains always count. Each server
  domain missing from `options.linkDomains` is logged once per launch at **warn** level (not
  debug): Android opens the app only for hosts in its intent filters, so this is a
  misconfiguration the developer should see with the default log level.
- First launch with no cached config: only `options.linkDomains` are known synchronously;
  other http(s) URLs are re-checked when the config arrives (still delivered if they match,
  but `handleIntent` returned `false`). Apps should list their domains in options.
- Each intent is handled once (an extra `com.clikgate.handled` is put on the intent) so the
  app and the Flutter plugin can both forward it; intents re-delivered from Recents
  (`FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY`) are ignored.
- A URL received before `/install` was built goes in `launch_url`; afterwards via `/resolve`.
- `/resolve` results carry no `match_type`; the SDK reports `matchType = "app_link"` for them.
- Verification: `autoVerify="true"` intent filters + `/.well-known/assetlinks.json`; check
  with `adb shell pm verify-app-links --re-verify <pkg>` and `adb shell pm get-app-links <pkg>`
  (Android 12+ verifies each host independently).

## Opens and lifecycle

- **Judgement call:** the cold-start `/open` is sent on the process's first foreground
  (`ProcessLifecycleOwner` `ON_START`), not in `configure()`. Clikgate's own uninstall-check
  pushes (FCM data messages wake the process in the background) and WorkManager jobs would
  otherwise count as app opens and inflate `active_days` used by referral hold rules.
- Foreground after ≥ `session_timeout_minutes` (config, default 30) → `/open` with
  `is_cold_start: false`. The first launch's `/install` counts as that launch's open.
- Background (`ON_STOP`): flush; if events remain, a WorkManager one-off job with a
  `CONNECTED` constraint (unique, `KEEP`, exponential backoff 30 s) flushes them.
- The periodic 15 s flush (`flush_interval_seconds`) runs only while in foreground.

## Events queue

SQLite `clikgate_events.db` (one table, payload JSON + byte size); limits from config
(`max_queue_events` 1000, `max_queue_bytes` 1 MB) drop the oldest. Batches ≤ 100 with an
`Idempotency-Key`. Success removes the whole batch (accepted + duplicates + rejected —
rejected events are never retried); 422 drops the batch; other failures retry 5× in-process,
then WorkManager. Event id / `occurred_at` are assigned at `track()` time (UTC, ms, `Z`).

## Push tokens

Stored token + provider in prefs; `sha256(provider + token)` of the last successful send.
Sent in `/install` when known, else via `/push-token` whenever the hash differs (on every
launch and on `setPushToken`). Failed sends retry on the next launch. **Judgement call:** the
SDK never includes `push` in `/open` (it always uses `/push-token`); the contract allows both.

`isClikgateMessage` accepts `Map<String, *>` (so `RemoteMessage.data` works directly) and a
`Bundle`; it recognises `cg == "uc"`, a nested `{t: "uc"}` map and that object serialised as
a JSON string.

## Identify, opt-out, errors

- `identify` is persisted and sent once `/install` succeeded; retried on the next launch after
  5 failed attempts; `identity_invalid` keeps the user id (logged). Referral calls wait for a
  pending identify first and send `Clikgate-Identity-Token` when a token is stored.
  **Judgement call:** the SDK doesn't emit a `$identify` event; `/identify` itself satisfies
  `$identify` steps server-side (spec 8.3).
- Opt-out: per SDK_BEHAVIOUR. **Judgement call:** while opted out, Clikgate URLs passed to
  `handleIntent` are still delivered to the app as a local deep link (url, path, query
  parameters as `data`, no server call) so in-app routing keeps working.
- Global errors: `invalid_sdk_key` stops all calls until the next launch (also when it comes
  from `/config`); `sdk_disabled` backs off 1 h; `installation_unknown` resets the install
  state and re-runs `/install`; 409 `install_in_progress` honours `Retry-After`.
- Referral calls: up to 3 attempts for network/408/429/5xx; backend referral codes are never
  retried. A referral call before `/install` finished waits up to 10 s, then fails with
  `install_pending`.

## Backup

The library manifest sets `android:fullBackupContent` / `android:dataExtractionRules` to
resources excluding `clikgate.prefs.xml` and `clikgate_events.db` from cloud backup and device
transfer. Apps with their own rules get a manifest-merger conflict: the setup command
(`npx @clikgate/setup`) adds the excludes to the app's rules files (creating a missing file or
section) and lists the attributes in `tools:replace`, idempotently; `doctor` checks it
(`android.backup_rules`). By hand, the steps are in `docs/android.md`. The SDK keeps setting
both attributes, so apps without their own rules need nothing and the installation ID is never
restored by a backup or a device transfer.

## Emulator heuristics

Build-property heuristics (`generic*`/`unknown` fingerprints, `sdk_gphone*`, `goldfish`/
`ranchu`, Genymotion/vbox86). **Gap:** the spec says "heuristics in config" but the config
schema has no field for them, so they're hard-coded (`internal/DeviceInfo.kt`).

## Fraud signals (change 02, B.5.2; SDK 1.1.0)

`/install` sends `is_emulator` (the heuristics above) and `is_rooted`. The click / install-begin
times the spec asks for were already sent as `install_referrer.referrer_click_timestamp_seconds` /
`install_begin_timestamp_seconds` (straight from `ReferrerDetails`), so no new field for them.

- **Root heuristics** (`internal/DeviceInfo.kt`, `Root`): `Build.TAGS` contains `test-keys`; an
  `su` binary at one of 12 common paths (`File.exists()`, no permission); a known root-manager
  package (Magisk, SuperSU, Superuser, KingRoot, ...) via `PackageManager.getPackageInfo`, **only
  below API 30**. From Android 11, package visibility filtering hides other apps unless the
  manifest declares `<queries>` or holds `QUERY_ALL_PACKAGES`; we add neither, so on API 30+ the
  lookup would always say "not installed" and is skipped.
- **False positives:** `test-keys` also marks some custom ROMs and a few low-cost OEM builds that
  aren't rooted; Magisk with DenyList / hidden package name defeats every check here (false
  negatives). Both flags are hints for scoring (`emulator_or_rooted`, weight 40 of the 70
  threshold), never a verdict on their own. Play Integrity (`attestation`) is the strong signal.
- **Failure:** each check runs inside `Core.signal { }`; an exception leaves its field out of the
  body (the other signal and the install are unaffected). Computed once per request body
  (retries reuse it). Not sent in the opted-out install body.

## FCM

Data-only messages are delivered to `FirebaseMessagingService.onMessageReceived` in all app
states (notification messages are not, when backgrounded) — Clikgate's `{"cg":"uc"}` with
`android.priority=normal`, `ttl=0s` fits. The SDK never shows notifications or requests the
notification permission.

## Size (before the Engage split; see "Engage split" below for the current numbers)

| Measure | Size |
|---|---|
| `clikgate-release.aar` (unminified, as published) | ≈ 224 KB (`classes.jar` 237 KB uncompressed) |
| d8 dex of the library, no shrinking | ≈ 203 KB |
| R8 dex, whole public API kept (`-keep public class com.clikgate.* { public *; }`) | ≈ 105 KB |

The spec's "< 150 KB" is read as the app-size contribution (apps ship R8-processed code); the
worst case with every public API kept is ≈ 105 KB. The AAR itself isn't minified (library
R8 + Kotlin metadata rewriting is a source of consumer bugs).

## Publishing (Maven Central, Central Portal)

OSSRH was shut down in mid-2025; publishing goes through the Central Portal. The build uses
`com.vanniktech.maven.publish` 0.34.0 (`publishToMavenCentral(automaticRelease = false)`),
in-memory GPG signing from CI secrets (`signingInMemoryKey*`), coordinates
`com.clikgate:clikgate-android:<VERSION_NAME>` and the POM from `gradle.properties`.
`./gradlew :clikgate:publishToMavenLocal` publishes to `~/.m2` for local consumers.

## Flutter plugin ↔ native SDK

- The plugin depends on `com.clikgate:clikgate-android:1.1.0` (Maven Central for releases).
- Monorepo: `flutter/example/android/settings.gradle.kts` includes `../../../android` as a
  composite build and substitutes the module with `:clikgate`, so the example always builds
  the SDK from source (no publish step). `-Pclikgate.useLocalSdk=false` uses the published
  artifact instead. `android/settings.gradle.kts` skips `:sample` when included.
- Other apps against an unpublished SDK: `publishToMavenLocal` + `clikgate.useMavenLocal=true`
  in the app's `android/gradle.properties` (the plugin then adds `mavenLocal()` filtered to
  `com.clikgate`), or the same `includeBuild` block in the app's settings.
- The plugin calls `Clikgate.setWrapper("flutter", <plugin version>)` before `configure`
  (`@ClikgateInternalApi`, an opt-in-required annotation), handles the launch intent in
  `onAttachedToActivity` (kept by the SDK until Dart calls `configure`) and every
  `onNewIntent`. One static deep-link hub serves all engines and buffers the latest 10 links
  until a Dart `onListen`; the Dart side buffers again until the first app subscriber.
- App-defined maps (`data`, `metadata`, `properties`) cross the bridge verbatim (no
  camelCase conversion).

## Flutter example

- `firebase_core` 4.1.x / `firebase_messaging` 16.0.x / `share_plus` 12.0.x are pinned: they
  are contemporary with Flutter 3.35; later FlutterFire releases move to newer Kotlin/AGP and
  deprecate `getToken()`. Firebase is initialised only when `FIREBASE_*` `--dart-define`s are
  given (no `google-services.json`, no google-services Gradle plugin).
- Native sample: Firebase Messaging via BoM 35 (minSdk 24) without the google-services plugin;
  push registration is skipped when `FirebaseApp.getApps()` is empty.

## v3: feature switches, leaderboards, codes, WhatsApp (2026-10-21)

- **Feature switches.** `SdkConfig.features` keeps the boolean entries of `/config` `features`
  (null for the built-in default = no config yet). `isFeatureEnabled(key)` = server value, else
  the catalogue default (`referrals`, `leaderboards`, `offline_codes`, `app_attribution` on; the
  rest and unknown keys off). It's readable from any thread (volatile), loaded synchronously
  from the cached config in `Core.init`, so a relaunch knows the switches before any fetch.
  Non-boolean entries (`pasteboard_matching`, `attestation`) aren't switches and read as off.
- **Gating.** Every referral / leaderboard / code call goes through `Core.featureCall`: fail fast
  with `feature_disabled` (no network) before waiting for the install, and again after the
  install/identify wait (on a first launch the config is only known then). A `200` body with
  `accepted: false, reason: "feature_disabled"` maps to the same error (`ClikgateError.feature`
  from the body's `feature`, else the method's feature). **Judgement call:** that feature then
  reads as off in memory until the next successful config fetch, and a background `/config`
  refresh starts immediately (SDK_BEHAVIOUR "refresh the config in the background"); a fresh
  config is authoritative again (so re-enabling works without a relaunch).
- **Interactive calls.** Leaderboards and codes: `maxAttempts = 2`, and a retry is skipped when
  the wait would exceed 5 s (`Retry-After: 3600` from the 5/hour code limit is surfaced as
  `rate_limited` instead of hanging the callback). Referral calls keep their v1 behaviour
  (3 attempts).
- **Signatures** follow the bridge (period is a `String`: `LeaderboardPeriod.CURRENT` /
  `PREVIOUS` / a key). `me(id, period, cb)` and `aroundMe(id, radius, cb)` are the bridge forms;
  separate overloads take `period` / `segment` (the API accepts `segment` on `/me` and
  `period` + `segment` on `/around-me`, the bridge doesn't pass them). `aroundMe` returns a
  `LeaderboardPage` with `name`/`metric`/`segment` null. `setOptOut` has an optional
  `ClikgateCallback<Unit>`. Limits are clamped (`limit` 1..100, `radius` 1..25), not rejected.
- **`ClikgateError`** gained `feature` and `offlineTouchId` (the code endpoint's referral errors
  carry `offline_touch_id` inside the error object); the Flutter plugin puts both in the
  `PlatformException` details when set.
- **`codes.redeem`** validates 3–30 characters after trimming (schema `code_redeem_request`)
  and sends the trimmed input; normalisation (case, spaces, dashes) is the server's.
- **WhatsApp share** (client-only, needs only `referrals`): `ACTION_SEND` text/plain with
  `setPackage("com.whatsapp")`, then `com.whatsapp.w4b`, then the chooser. It starts the intent
  and catches `ActivityNotFoundException` instead of `resolveActivity`, so apps need no
  `<queries>` element (Android 11 package visibility). `true` = WhatsApp (or Business) opened.
  If even the chooser can't start: `share_unavailable` (SDK code, not in the contract).
- Not implemented here: `/v1/sdk/identity-signals` (no SDK method in the spec's SDK surface;
  only the `identity_checks` switch is readable) and `/me?embed=1` / `embed_token`.

## Engage split (spec v3 new edition, 2026-10-21)

Spec 0.4 / 17A: the core SDK only does what must happen on the device; referrer-side features
move to the optional add-on `com.clikgate:clikgate-engage` (Gradle module `:clikgate-engage`,
package `com.clikgate.engage`).

- **Core removed**: `referrals.createLink/awaitLink`, `myStats/awaitMyStats`,
  `shareIntent/awaitShareIntent`, `shareToWhatsApp/awaitShareToWhatsApp`, `Clikgate.leaderboards`,
  `Clikgate.codes`, their models and `ClikgateError.SHARE_UNAVAILABLE`. Core keeps `applyCode`,
  `referredBy`, `isFeatureEnabled` and `ClikgateError` (incl. `feature`, `offlineTouchId`, reused
  by Engage).
- **Request context** (`@ClikgateInternalApi`, now also allowed on classes):
  `Clikgate.requestContext(cb)` / `awaitRequestContext()` → `ClikgateRequestContext`
  (installationId, sdkKey, environment, apiBaseUrl, identityToken, customerUserId, sdkVersion and
  nativeSdkVersion header values, `headers()`). Same gates as the old referral calls: `opted_out`,
  `invalid_sdk_key`, `sdk_disabled`, waits ≤ 10 s for `/install` (`install_pending`), sends a
  pending identify first. `Clikgate.reportServerError(code, feature)` lets Engage feed back
  `feature_disabled` (feature off in memory + background `/config` refresh, as before) and the
  global codes `invalid_sdk_key` / `sdk_disabled` / `installation_unknown`.
- **Engage has its own ~150-line HTTP client** (HttpURLConnection + org.json, a 2-thread daemon
  pool) instead of a core HTTP helper: core stays small, and Engage's retry rules differ anyway.
- **Rules (17A.3)**: feature switch first (`feature_disabled`, no context fetch, no network);
  `not_identified` (no network) for user calls (`createLink`, `myStats`, `me`, `aroundMe`,
  `setOptOut`, `hostedPageUrl`) when the context has no `customerUserId`; `identity_required`
  is left to the server (core doesn't keep the programs' `require_identity_token`, and leaderboard
  ids don't name their program on the device). Read cache: successful `myStats` / `top` / `me` /
  `aroundMe` results, in memory, 60 s, key = installation id | user id | token present | method +
  path + query; writes (`createLink`, `setOptOut`, `redeem`) clear it before and after;
  `hostedPageUrl` (short-lived token) is never cached; `clearCache()` is public.
- **Retries — change from the old core calls**: one retry after 500 ms, for transport failures
  only (`IOException`, timeouts). HTTP errors (408/429/5xx) are returned at once. Previously
  leaderboards/codes made 2 attempts incl. 429/5xx and referral calls 3. Note: the platform HTTP
  stack itself may transparently re-send an idempotent request once on a dropped connection (JDK
  `HttpURLConnection` does for GET, observed in the tests; Android's OkHttp-backed one has
  `retryOnConnectionFailure`); that is outside the SDK's retry budget and only happens when the
  connection broke before a response. The tests count Engage's own attempts.
- **WhatsApp share** no longer creates the link: `share.whatsApp(context, text)` takes the final
  text (17A.2 shape), same intent chain as before (`com.whatsapp` → `com.whatsapp.w4b` → chooser,
  `share_unavailable` if even the chooser fails, no `<queries>`). `share.system(context, text,
  chooserTitle?)` throws `share_unavailable` likewise. Share helpers aren't feature-gated (no
  endpoint).
- **`hostedPageUrl`** = `GET /v1/sdk/leaderboards/{id}/me?period=…&embed=1` → `embed_url`;
  `hosted_page_unavailable` when the server sends none (servers before the `embed_url` field).
  `MyRank.embedUrl` is filled only on that call.
- **API shape**: callback functions plus `suspend` functions with the same names (overloads differ
  by the trailing callback parameter); `setOptOut`'s callback is nullable but not defaulted, so
  `setOptOut(p, true)` unambiguously means the suspend variant. Engage has **no `@JvmStatic` /
  `@JvmOverloads`** (Java: `ClikgateEngage.INSTANCE.getLeaderboards().top(id, "current", null, 50, cb)`)
  and its models are **plain classes, not data classes** (no `equals`/`copy`/`componentN`): both
  for the size budget (below). Engage compiles with `-Xno-param-assertions -Xno-call-assertions
  -Xno-receiver-assertions` (no generated null checks).
- **Tests**: `clikgate-engage` JVM tests (Robolectric + MockWebServer, shared fixtures) use a fake
  `ContextSource` (the internal seam between Engage and core) instead of the real core: the core
  side of the seam is covered by core's `RequestContextTest`. No end-to-end test with the real
  core (its test doubles, `Deps`, are internal to `:clikgate`).

### Boundary checks (spec 20)

- **Public-API snapshots**: Kotlin binary-compatibility-validator 0.17.0 at the root
  (`clikgate/api/clikgate.api`, `clikgate-engage/api/clikgate-engage.api`); `apiCheck` runs in
  `check` and CI, `apiDump` updates. `:sample` is ignored only when it is part of the build (the
  Flutter composite build doesn't include it).
- **`CoreBoundaryTest`** (core unit test) fails on Engage-only tokens in `clikgate.api`
  (leaderboard, createLink, myStats, referralLink, referralStats, redeem, redemption, share,
  whatsapp, identitySignal, myRank, hostedPage; the feature-key constants
  `ClikgateFeatures.LEADERBOARDS` / `WHATSAPP_ATTRIBUTION` are allowed) and asserts no
  `com.clikgate.engage` class is on core's classpath.
- **`:clikgate:checkNoEngageDependency`** (in `check`): no declared core dependency and no
  component of the resolved `releaseCompileClasspath` / `releaseRuntimeClasspath` mentions
  `engage`, and no core source references `com.clikgate.engage`. Engage's POM depends on
  `com.clikgate:clikgate-android` (compile scope) — installing core alone never pulls Engage.

### Size (spec 0.4 budgets: core < 150 KB, Engage < 40 KB)

`android/scripts/check_size.sh` (CI step; `--no-build` reuses the AARs) builds the release AARs
and reports four numbers per module, using d8/R8 from the newest build-tools (36.1.0 here):

| Module | AAR | `classes.jar` (compressed) | classes (uncompressed) | d8 dex, no shrinking | **R8 dex, public API kept** | R8, also Kotlin `@Metadata` kept |
|---|---|---|---|---|---|---|
| core `clikgate-android` | 225.5 KB | 238.4 KB | 482.7 KB | 200.6 KB | **87.7 KB** | 107.5 KB |
| Engage `clikgate-engage` | 46.4 KB | 48.4 KB | 103.3 KB | 52.6 KB | **33.4 KB** | 49.7 KB |

- **Budget metric = R8 dex with the whole public API kept** (`-keep public class com.clikgate.*
  { public protected *; }` / `com.clikgate.engage.*`, the consumer rules,
  `-keepattributes Signature,InnerClasses,EnclosingMethod`, android.jar as library, core's
  classes on Engage's classpath): the app-size contribution of an app that calls every public
  method (apps ship R8-processed code). Same metric as the pre-split "Size" section (≈ 105 KB then,
  with Kotlin metadata). The script enforces it (exit 1 when over).
- Kotlin `@Metadata` annotations are left out of the budget metric: R8 removes them in apps unless
  `kotlin.Metadata` is kept explicitly (not by AGP's default rules); the last column shows the
  numbers when an app does keep them (Engage would then be ~50 KB).
- Not the budget: the unminified AAR / `classes.jar` (core's is 238 KB; it was ≈ 237 KB before
  the split too — Kotlin class files are verbose) and plain d8 dex (no dead-code removal).
- Engage first measured 69.7 KB (R8 + metadata) / 45.3 KB (R8); it got under 40 KB by: dropping
  `@JvmStatic`/`@JvmOverloads` bridges, no Kotlin null-check intrinsics, one shared `Resume`
  continuation callback instead of a lambda + continuation class per suspend function, one parse
  dispatcher instead of a function-reference class per call site, no sealed response classes,
  and plain model classes. Margin: ~6.5 KB.

## Change 03 (SDK 1.2.0) — 2026-10-22

Contract: `shared/API_CONTRACT.md` and `shared/SDK_BEHAVIOUR.md` "Change 03" (the SDK contract led; the
backend for change 03 wasn't started).

### Documentation checked (2026-10-22)

| Topic | Source | Finding |
|---|---|---|
| Play Integrity standard requests | developer.android.com/google/play/integrity/standard (fetched); `javap` on `integrity-1.6.0.aar` | `IntegrityManagerFactory.createStandard(Context)` → `prepareIntegrityToken(PrepareIntegrityTokenRequest.builder().setCloudProjectNumber(long))` → `StandardIntegrityTokenProvider.request(StandardIntegrityTokenRequest.builder().setRequestHash(String))` → `StandardIntegrityToken.token()`. Every example sets the cloud project number for the warm-up; `requestHash` ≤ 500 bytes, included verbatim; "up to 5 times per minute" prepares; an expired provider fails with `INTEGRITY_TOKEN_PROVIDER_INVALID` → prepare again. Standard requests are protected against replay automatically. |
| Play Integrity setup | developer.android.com/google/play/integrity/setup (page "Last updated 2026-10-16") | Latest library `com.google.android.play:integrity:1.6.0` (as already pinned); quotas per Cloud project shared between classic and standard. The AAR's manifest says minSdk 23. |
| Classic requests | existing finding (2026-10-20, android DECISIONS "Play Integrity") | `setNonce` (URL-safe base64, 16–500 chars); cloud project number only needed outside Play. |
| Firebase Analytics (Android) | `javap` on `play-services-measurement-api-22.5.0.aar` (`com.google.firebase.analytics.FirebaseAnalytics`) | `static getInstance(Context)`, `logEvent(String, Bundle)`, `setUserProperty(String, String)`, `setConsent(Map<ConsentType, ConsentStatus>)`, `Task<String> getAppInstanceId()`. |
| Google Analytics limits | support.google.com/analytics/answer/9267744 (fetched); FIRAnalytics.h 13.0.1 | Event names ≤ 40, ≤ 25 parameters per event, parameter names ≤ 40, values ≤ 100 (GA4 standard), user property names ≤ 24, values ≤ 36; prefixes `firebase_`, `google_`, `ga_` reserved (header). |
| Apple / Google on-device measurement | see ios/DECISIONS.md | iOS only. |

Not verified: how Google treats Play Integrity verdicts from standard requests in Clikgate's backend (the
backend's job); whether `firebase-analytics` 24.x changes `getAppInstanceId` (24.0.0 was resolved by the BoM
for the sample but its Kotlin 2.4 metadata can't be compiled against with this build's Kotlin 2.1, so the
sample depends on it `runtimeOnly`; the signatures above are from 22.5.0).

### Decisions

- **Consent** lives in core (it gates every call). State: prefs `consent` (JSON), `consent_send_pending`,
  `consent_pending_since`, `install_ping_sent`. The gate runs in `pump()` before anything identifying;
  `track()` drops events while denied and buffers (rolling 7 days / 1,000, `EventQueue.dropOlderThan` /
  `trimTo`) while pending. URLs while pending are delivered locally and kept (latest 10) for a silent
  `/resolve` after grant; a launch URL becomes `launch_url` and the install response's non-deferred deep
  link isn't delivered a second time. Deny also clears the kept install referrer (and its "done" flag, so
  Play is asked again after a later grant: Play keeps it 90 days).
- **First `/config` without installation id** when the requirement is unknown (no cached `consent`, no
  hint) and attribution isn't granted: the SDK can't know yet whether the device is in a consent region.
  iOS does the same.
- **Feature calls / request context** fail with `consent_required` (gate not allowed) or
  `sdk_version_blocked` (call not allowed) without a network call, like iOS.
- **Play Integrity stays `compileOnly`** (checked again: the library is a normal `implementation`
  dependency in Google's setup guide, so shipping it would force it, its minSdk 23 and Play services on
  every app). Detected with `Class.forName`; consumer rules `-dontwarn` it. Standard requests when a
  project number is known (option first, then config), classic otherwise; the warmed-up provider is kept
  for the process and dropped after a failed request.
- **Firebase forwarding stays in core**, by reflection (`ReflectionFirebaseBridge`, injectable
  `FirebaseAnalyticsBridge` for tests): about 4 KB of R8 output, it needs the consent and attribution state
  that live in core, and Flutter / React Native call through to it anyway. A separate artifact would add
  an internal hook for little gain. Consumer R8 rules keep `FirebaseAnalytics.getInstance / logEvent /
  setUserProperty / getAppInstanceId` and the `Task` / `OnCompleteListener` members the reflection uses
  (checked in the minified sample APK: the names survive). `getAppInstanceId()`'s `Task` is observed through
  a `java.lang.reflect.Proxy` `OnCompleteListener`. The first `/open` of a process (and `/install`) waits
  at most 2 s for the id.
- **Mirroring** happens at `track()` time, before Clikgate's own consent buffering (Firebase has its own
  consent; the SDK only mirrors with `analytics` allowed). Revenue → `value` in major units (ISO 4217
  exponents 0 / 3 for the listed currencies, else 2) + `currency`.
- **Probabilistic signals**: only `screen` is probabilistic-only on Android; it's sent when
  `features.probabilistic_matching` and attribution consent allow it. Locale, time zone, OS version and
  model stay (analytics). No persistent hardware ids were ever collected.
- **Version policy**: the SDK compares the outermost version (wrapper's when wrapped) with
  `min_supported_version` only when the server sends no `version_status`. Blocked mode filters events at
  flush time (so a later unblock sends the rest).

### Tests

`Change03Test` (28 tests): consent object on every body (validated against the schemas), buffering
without identifying calls, grant flush without double routing, deny + install-ping (once, no installation
id), withdrawal `/consent`, buffer expiry and cap, region hint (+ `region_hint` query), not-required path,
invalid region, blocked / deprecated versions, version comparison, click-id parsing and precedence, `/open`
click ids, attribution metadata (install, latest deep link, opt-out, consent), Firebase present / absent /
not allowed / once per install / mirroring limits / app instance id on install and changed on open, Play
Integrity standard vs classic, identity-check consent, `consent_required` / `sdk_version_blocked`, first
anonymous config, region and limit logic. `FirstLaunchTest` reproduces the full
`install_request_android.json` fixture (consent, click ids from the referrer, standard Play Integrity,
`screen` with probabilistic matching). 146 core tests in total.

### Size (`android/scripts/check_size.sh`, R8 dex with the public API kept)

| | before (1.1.0) | after (1.2.0) | budget |
|---|---|---|---|
| core | 90.1 KB | 109.7 KB | 150 KB |
| Engage | 33.4 KB | 33.4 KB | 40 KB |

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
- **Android specifics**: `GoalOptions(value: BigDecimal?)` (data class, `@JvmOverloads`; `toString()`
  redacts value and reference). Goals live in the same SQLite table, with the `event_id` column holding
  `goal:` + SHA-256(`key:reference`) as the dedupe key. Debug build = `ApplicationInfo.FLAG_DEBUGGABLE`
  (injectable through `DeviceInfo.isDebuggableApp`). Calls before `configure` are validated, get their
  reference then, and are queued (like `track`). Wrappers use `goalFromWrapper(key, value: String?, ...)`.
- **Size**: core 110.4 KB → 118.5 KB (R8, public API kept; budget 150 KB).

## Licence: Apache 2.0 (2026-10-26)

Owner chose Apache 2.0 for all mobile SDKs; clikgate_sdks stays MIT. The canonical text
(https://www.apache.org/licenses/LICENSE-2.0.txt, SHA-256 `cfc7749b…3d30`) is the root `LICENSE` and an
identical copy in each package directory that ships one (`ios/`, `flutter/`, `flutter_engage/`,
`react-native/`, `react-native-engage/`); metadata: POM (already Apache 2.0), podspecs
`{ :type => 'Apache-2.0', :file => 'LICENSE' }`, `package.json` `"license": "Apache-2.0"`, pubspec
packages read their `LICENSE`.

## Change 06 — shared-domain browser fallback (SDK 1.4.0, 2026-10-26)

- **Behaviour**: shared/SDK_BEHAVIOUR.md "Change 06 (SDK 1.4.0)". One list, `SharedDomains.HOSTS` in
  `internal/BrowserHandoff.kt`, compared with `shared/fixtures/shared_link_domains.json` in tests.
- **Custom Tabs without `androidx.browser`**: a Custom Tab is an `ACTION_VIEW` intent carrying the
  `android.support.customtabs.extra.SESSION` extra (a null binder is allowed) sent to a browser that
  implements `android.support.customtabs.action.CustomTabsService`. Doing that directly avoids a dependency
  (and its minSdk/compileSdk constraints) for one intent. Browser choice: activities answering a generic
  `https://example.invalid/` `VIEW`/`BROWSABLE` probe (apps with App Links only match their own hosts),
  excluding this app; the default browser first; the first one with the Custom Tabs service gets a Custom
  Tab, else the first browser gets a plain view intent. Always `setPackage(...)`: an implicit `VIEW` intent
  for the link could resolve to this app's own verified App Link and loop. No browser ⇒ no event, warning.
- **Package visibility**: the library manifest declares `<queries>` for the `VIEW https BROWSABLE` intent
  and the Custom Tabs service (Android 11+); intent-based queries, not `QUERY_ALL_PACKAGES`.
- **Context**: started from the activity passed to the last `handleIntent` (weak reference) so the tab opens
  in the app's task, else the application context with `FLAG_ACTIVITY_NEW_TASK` (Flutter / RN pass their
  activity).
- **First launch**: `/install` consumes the launch URL; when it returns no `deep_link` (and isn't `pending`)
  for a shared-domain launch URL, the SDK now `/resolve`s it so the fallback applies (iOS already
  re-resolved unmatched launch URLs). Custom-domain launch URLs are untouched.
- **Event**: `onBrowserHandoff(BrowserHandoffListener?)`, `ClikgateBrowserHandoff(url, host)`, on the main
  thread, buffered latest 10 by a generic `Dispatcher<L, T>` now shared with deep links. The deep-link
  listener never fires for a handoff.
- **Option**: `ClikgateOptions.platformDomainBrowserFallback` (default true; appended to the data class, so
  existing named-argument and `@JvmOverloads` callers compile unchanged). The spec doesn't mention the
  fallback, so an off switch doesn't conflict with it. "platform domain" (spec term) rather than "shared":
  `CoreBoundaryTest` forbids `share` in core public API names.
- **Size**: core R8 (public API kept) 118.5 KB → 120.8 KB (budget 150 KB); Engage unchanged at 33.4 KB.
- **Version**: 1.3.0 → 1.4.0 (minor: new public API and behaviour; each change set has had its own minor).

## Change 12 — one `goal()` method, enums, clean published code (2026-10-28)

- **`goal()` takes named parameters** (`value`, `currency`, `reference`, `provider`, `isFirst`, `onResult`) with
  `@JvmOverloads`; `GoalOptions` and `goalValidated` are gone (nothing published), so there is exactly one goal
  entry point, matching the spec example `Clikgate.goal("purchase", reference = "T123456", provider = Provider.PAYSTACK)`.
  Java callers pass positional nulls.
- **Results are asynchronous** (`GoalResultListener`, main thread), because the goal's kind is only known to the
  server (the kind is never in the call) and goals are queued. Listeners live in memory keyed by the queue dedupe
  key `(goal, reference)`; a duplicate call joins the queued goal's listener list. Mapping: `results[]` item by
  `index`, else by goal + reference; a `rejected[]` item is `REFUSED` with its code; an older server without
  `results` counts the remaining items as `COUNTED`. Batch-level outcomes: 422 / 404 → `REFUSED` with the error
  code; feature disabled → `feature_disabled`; version blocked → `sdk_version_blocked`. On the device:
  `invalid_argument`, `feature_disabled` (deep-link-only), `opted_out`, `consent_denied`; clearing the queue
  (opt-out, consent denied, deep-link-only) refuses every waiting listener. A queue-overflow eviction or a process
  death leaves a listener unanswered (documented: the goal is sent later without a result). Retries are unchanged.
- **`Provider` is a class, not an enum class**, so `fromString` can return providers added after the release
  (`Provider.entries` lists the generated constants; equality by value). It's generated by
  `scripts/generate_providers.py` from `shared/providers.json` (the backend's OpenAPI `Provider` enum); never
  edit `Provider.kt` by hand. `fromString` trims, lower-cases and returns null for a value that isn't a provider
  key (`^[a-z][a-z0-9_]{1,29}$`); the wrapper entry point refuses such a string with `invalid_argument`.
- **Test mode** is a test SDK key (`cg_sdk_test_...`, the backend's key prefix). Then the two lines
  (`<key> is a Payment goal: waiting for confirmation`, `... the value was ignored ...`) are logged at warning level
  so they show with the default log level; never the reference or the value. Live keys don't log them.
- **Published code (S.4):** comments in `src/main` and `consumer-rules.pro` no longer cite internal documents or
  change numbers, the `apiBaseUrl` doc no longer mentions a local backend, the domain-alias example is fictional
  (`go.acme.com`), and `internal/Change03.kt` became `internal/ConsentAndPolicy.kt` (class files carry the source
  file name). `scripts/scan_release_packages.py` checks the release AAR and sources jar.

## Change 13: Engage `share.link` (2026-10-29)

- Design and wire format: `docs/DECISIONS.md` "Change 13" and `shared/SDK_BEHAVIOUR.md` "Change 13".
- **Size: Engage budget 40 → 44 KB** (R8 dex, public API kept; `scripts/check_size.sh`). Engage is 42.2 KB (was
  33.4 KB); core unchanged at 128.5 KB. Trimmed before raising: no helper class or companion tables (package arrays
  generated into `EngageShare.kt` between `<generated:packages>` markers), `java.util.regex` instead of Kotlin
  `Regex`, no `@JvmOverloads`, no `when` on the enum, tests observe the real share-event requests instead of a
  function-typed hook. Pending the owner's confirmation.
- `ShareApp` is a Kotlin enum (closed set, new values only by an SDK release, like the backend's) with an internal
  `ending`; there is no `fromString` on Android (use `ShareApp.entries`).
