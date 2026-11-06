# Decisions: setup command (`cli/`, `@clikgate/setup`)

Dated decisions and documentation findings for the setup command. It moved here from `clikgate_sdks` (where these sections were in `docs/DECISIONS.md`); the history below is kept as written, with notes where the move changed something. Usage, flags and the owner's publishing steps: [`docs/SETUP_COMMAND.md`](../docs/SETUP_COMMAND.md).

## Move to `clikgate_mobile_sdk` (2026-10-26)

- **Setup command moved from clikgate_sdks to clikgate_mobile_sdk (owner decision); keeps MIT.**
  - *Reason:* the command is tightly coupled to the mobile SDKs' versions, configure APIs and snippets, so a change to an SDK and to the command should land together in one PR.
  - **Layout:** `cli/` at the root of this repository, moved wholesale (src, test and fixtures, schema, scripts, config, lockfile). Workflows `.github/workflows/cli.yml` and `cli-release.yml`.
  - **Licence:** mixed repository. `cli/` keeps its own MIT `LICENSE` and `"license": "MIT"` in `cli/package.json`; every mobile SDK stays Apache 2.0 (root `LICENSE`).
  - **Version coupling:** `scripts/check_cli_sdk_versions.mjs` fails when `cli/src/constants.ts` (`SDK`, `CLI_VERSION`) drifts from `android/gradle.properties`, `ios/Clikgate.podspec`, `flutter/pubspec.yaml`, `react-native/package.json` or `cli/package.json`. It runs in `cli.yml` (job `sdk-versions`) and before publishing in `cli-release.yml`. The check requires equality (the command always writes the current SDK release), so an SDK version bump must bump the constants and the CLI snapshots in the same change.
  - **CI:** `cli.yml` runs on `cli/**` and on the SDK files the command depends on (the four version files, `android/clikgate/src/main`, `ios/Sources/Clikgate/Public`, `flutter/lib` and `flutter/android`, `react-native/src`, `plugin`, `app.plugin.js` and `android`). The e2e jobs build the SDKs from the same checkout: the second checkout and `MOBILE_SDK_READ_TOKEN` are gone. Actions stay pinned to commit SHAs. `sdk-boundaries.yml` ignores changes that touch only `cli/` and its workflows.
  - **Release:** tags stay `cli-v*`. The npm trusted publisher must now name repository `clikgate-mobile-sdk`, workflow `cli-release.yml`, environment `npm`. `cli/package.json` `repository`/`bugs` point at `clikgate/clikgate-mobile-sdk` (npm provenance checks the repository URL).
  - **AI guides stay in `clikgate_sdks`:** `ai-guides/scripts/check.mjs` and the QA harness read the command from `CLIKGATE_CLI_DIR` (default `../clikgate_mobile_sdk/cli`), and `ai-guides.yml` checks out `clikgate/clikgate-mobile-sdk` for it.
  - Verified after the move: `npm ci`, `npm test` (88 passed), `npm run typecheck`, `npm run build`, the Node 18.20.8 smoke run over every fixture, `validate-ios.mjs` on the edited iOS fixtures, and a YAML parse and `bash -n` of the workflows. The workflows have not been run on GitHub.

## Setup command (`cli/`), C6-S1 and C6-S2 (written in `clikgate_sdks`)

### Workspace decisions applied (2026-10-26)

- **Location:** `cli/` at the root of `clikgate_sdks`, the owner's repo choice, instead of the spec's `sdks/cli/`. *Superseded on 2026-10-26: moved to `clikgate_mobile_sdk/cli/` (above).*
- **Licence:** MIT. The `clikgate_sdks` root `LICENSE` (MIT) is copied into `cli/` so it ships in the npm tarball; it stays there after the move.
- **Domains:** `ciz.to` (paid), `clk.ng` (free) and `dev.ciz.to` (test). `dev.ciz.to` goes only into debug manifests and Debug entitlements, and into code behind `kDebugMode` / `__DEV__` / `FLAG_DEBUGGABLE` / `#if DEBUG`.
- **Package:** `@clikgate/setup`, bin `clikgate-setup`, version 1.0.0, Node ≥ 18.
- **Bundle:** tsup 8.5.1 builds one CommonJS file, `dist/cli.cjs`, with a shebang. Every dependency is bundled, so the published package has **no runtime dependencies**. All devDependencies are pinned exactly.
- **No telemetry.** The only network calls go to the Clikgate API, after sign-in.

### Backend shapes (confirmed by the backend agent on 2026-10-26; tested against `cli/test/mockServer.ts`)

- `POST /v1/cli/device-codes` returns `{device_code, user_code, verification_uri, verification_uri_complete, expires_in, interval}`, or 429 when rate-limited.
- `POST /v1/cli/token` returns `{access_token, token_type: "bearer", expires_in, organization: {id, name}}`.
  - Errors use the envelope with these codes: `authorization_pending` (428), `slow_down` (429, with `error.interval` and `Retry-After`), `access_denied` (403), `expired_token` (410, which also covers an already-used code) and `invalid_device_code` (422).
  - A 400 with the same codes is also accepted, which is the RFC 8628 style.
  - On `slow_down` the CLI waits max(previous + 5 s, `error.interval`, `Retry-After`).
- **Apps:** the CLI token gets `sdk_key: null`. The CLI only reads `sdk_key_test`; when that's missing it writes a placeholder plus a manual step.
- **Signing details:**
  - `PATCH /v1/apps/{id}` sends `sha256_cert_fingerprints` as existing plus new (add-only) and `team_id`.
  - `PATCH /v1/apps/{id}/sdk-settings` sends `shared_domain_app_links` / `test_domain_app_links` only.
- **Domains:** in `GET /v1/domains`, `mode` is `live`/`test`. Live = `status == "active"`, not test, and `eligible_for_new_links !== false` (`true` only for the organisation's current platform domain; `null` for custom domains). The test domain is `mode == "test"` (also accepted: `platform_tier == "test"` or the hostname `dev.ciz.to`).
- **Setup check:** `GET /v1/cli/setup-check?app_id=` returns `{app, domains[{hostname, mode, aasa, assetlinks}], sdk, next_steps}`.
  - Each file entry is `{applies, served, contains_app, problem}`, and doctor judges only `applies: true`.
  - Problem codes have plain-language fixes. The code is kept in the check's `code` field for `--json`:
    - domain problems: `domain_not_active`, `unreachable`, `not_served`, `redirected`, `invalid_json`;
    - app problems: `missing_team_id`, `missing_fingerprints`, `app_not_listed`, `wrong_fingerprint`;
    - shared-domain problems: `not_listed_on_shared_domain`, `shared_domain_file_full`.
- `403 cli_scope` is shown as "This needs the dashboard: https://app.clikgate.com".
- **Shared platform domains:** `ciz.to`, `clk.ng` and `clkg.to` list an app only on opt-in. The CLI asks, with the privacy note, and PATCHes on yes. On no, it leaves that domain out of the manifest and entitlement edits: on Android 11 and lower, one unverifiable host fails verification for the whole app. Offline mode prints the dashboard step instead.

### Parsers (S.1)

| File | Parser | How it's edited |
|---|---|---|
| AndroidManifest.xml, entitlements and Info.plist edits | **saxes 6.0.0**, a strict XML parser with source positions | Elements are located with their offsets and new lines are spliced into the original text, so existing bytes (attribute order, multi-line attributes, comments) never change. The result is parsed again. `@xmldom/xmldom` and xml2js were rejected because they re-serialise the whole file. |
| Plist values (entitlements, Info.plist) | **plist 5.0.0** | Reading and validating values. New entitlements files are written in Xcode's own format, with tabs. |
| project.pbxproj | **@bacons/xcode 1.0.0-alpha.33**, only its `json` parser (no xmldom in the bundle) | Build configurations are found by parsing. One `CODE_SIGN_ENTITLEMENTS = …;` line is inserted in Xcode's alphabetical position (or replaced when Debug must stop sharing the Release file), then the file is parsed again. The `xcode` (Cordova) package was rejected: its `writeSync` re-serialises the whole file, and 4.0.0 was 6 days old. |
| pubspec.yaml | **yaml 2.9.1**, which keeps comments and source ranges | The dependency line is inserted after the last `dependencies:` entry using the node's source range, so comments, blank lines and quoting stay as they were. |
| package.json, app.json | **jsonc-parser 3.3.1** | `modify` makes minimal edits. Dependencies go in alphabetical position. |
| Gradle (Groovy/KTS), libs.versions.toml, Podfile | none exists for Node | A brace scanner that skips strings and comments, plus well-known statements only. Anything else becomes a manual step. |
| Kotlin, Swift, Dart, TS/JS | none | Recognised template shapes only (regex plus brace matching). Anything else becomes a manual step with the snippet. |

Diffs use `diff` 9.0.0 (8.0.2 had GHSA-73rr-hh4g-fpgx). Tests use vitest **4.1.12**, 11 days old, chosen over 4.1.11 for its advisory fix (GHSA-qxg6-89mg-rqv8), and ajv 8.20.0 for the doctor JSON schema. `@xmldom/xmldom` is overridden to 0.8.15 for `@bacons/xcode`'s unused plist dependency (dev only). esbuild 0.27.7, through tsup, has a Windows dev-server advisory that doesn't apply: there's no dev server.

### Documentation findings (checked 2026-10-26)

- **RFC 8628** (rfc-editor.org):
  - The default `interval` is 5 s. `authorization_pending` → keep polling. `slow_down` → add 5 s "for this and all subsequent requests". `access_denied` / `expired_token` → stop.
  - The client MUST show `user_code` and SHOULD show the textual URI even when it opens `verification_uri_complete`.
  - The RFC defines no status code beyond RFC 6749 §5.2 (400), hence the 400 tolerance.
  - The CLI prints the URL and code, and opens the browser except in CI or over SSH. The token is kept in memory only.
- **Expo config plugins and build variants** (docs.expo.dev, pages modified 2026-10-13):
  - Variants use `APP_VARIANT`, set per profile in `eas.json` `build.<profile>.env`. EAS also sets `EAS_BUILD_PROFILE`; the docs say built-in variables reach "any build step", but not when evaluating the config locally.
  - "Dangerous mods run first." `withFinalizedMod` isn't documented. Its ordering ("finalized" last) was read from the `@expo/config-plugins` 57.0.10 source (`mod-compiler.js`).
  - The entitlements base mod writes the **Release** configuration's file (`getEntitlementsPath(..., buildConfiguration = 'Release')`).
  - The plugin therefore adds `testLinkDomain` with finalized mods: the Android debug-based manifests, and a `<Target>Debug.entitlements` copy linked for Debug only. When `APP_VARIANT` (else `EAS_BUILD_PROFILE`) is in `testVariants` (default `development`, `preview`), it goes into every build, because EAS preview builds are Release builds.
  - Verified with a real `expo prebuild` (SDK 58): default variant → debug and Debug only; `APP_VARIANT=preview` → all builds; a re-run doesn't duplicate.
- **Expo install:** `npx expo install` pins versions only for packages in Expo's bundled list. `@clikgate/react-native` isn't in it, so the CLI writes `^1.4.0` into `package.json` itself, so the diff shows it and re-runs see it, and then runs the package manager. Flutter likewise writes `pubspec.yaml`, then `flutter pub get`, instead of `flutter pub add` (same result, and it works when Flutter isn't on PATH).
- **Android App Links** (developer.android.com, pages last updated 2026-10-23 / 2026-02-26):
  - `autoVerify="true"` on a VIEW + DEFAULT + BROWSABLE filter.
  - Several `<data android:host>` in one filter is fine. On Android 12+ each host is verified separately; on 11 and lower **all** hosts must verify.
  - Verification inspects filters with `http` **or** `https`. The "add App Links" page now says to include both schemes. The CLI writes `https` only, like the mobile SDK docs, because link domains are HTTPS-only with HSTS; the doc wording is noted here.
  - Manifest merge: the build-type manifest (`src/debug`) has priority over `src/main`. `<activity>` elements merge by `android:name`, and `<intent-filter>`s are always kept, so a debug-only filter on the same activity is the documented way.
  - With **Play App Signing** the local `keytool` fingerprint won't match users' devices; take it from Play Console › Release › Setup › App signing. The CLI says so and asks for it.
  - Check with `adb shell pm get-app-links <package>`.
  - React Native 0.88 / Expo 58 projects also have a `debugOptimized` build type. It gets the test domain too, and the doctor treats `debug*`/`*Debug*` source sets as debug-only.
- **Apple associated domains** (developer.apple.com, entitlement reference and "Supporting associated domains"):
  - `com.apple.developer.associated-domains` holds `applinks:<host>`, with optional `?mode=developer` (not used: dev.ciz.to is public).
  - The entitlements file is per target, chosen by the `CODE_SIGN_ENTITLEMENTS` build setting, which like every build setting is per configuration. Debug therefore points at `<Target>Debug.entitlements` (live + test) and Release/Profile at `<Target>.entitlements` (live only).
  - Checked locally with `xcodebuild -showBuildSettings -configuration Debug|Release` on the edited fixtures.
- **iOS link forwarding in current templates:**
  - Flutter 3.41's template uses `FlutterSceneDelegate` (UIScene). Its fallbacks (`sceneFallbackOpenURLContexts`, `sceneFallbackContinueUserActivity`) forward scene URL and user-activity events to plugins' app-delegate methods when the plugin hasn't adopted `FlutterSceneLifeCycleDelegate` (api.flutter.dev, iOS embedder). So `clikgate_flutter` needs no Swift edits; the CLI doesn't touch `SceneDelegate.swift`.
  - The RN 0.88 template's `SceneDelegate` forwards to `RCTLinkingManager`, which `@clikgate/react-native` observes. Expo 58's `ExpoAppSceneDelegate` does the same. Other shapes get a manual step.
  - *Owner to confirm on a device* (cold-start Universal Link through scenes).
- **Current templates** (generated on 2026-10-26 where the tool is installed):
  - `flutter create` (Flutter 3.41.8): `void main() { runApp(const MyApp()); }`, Kotlin DSL Gradle, `src/debug` and `src/profile` manifests, a UIScene `SceneDelegate.swift`, configurations Debug/Release/Profile.
  - `@react-native-community/cli@20.2.0 init` (React Native 0.88.0): `App.tsx` with `function App()` and `export default App`; Groovy Gradle; no `src/debug` manifest; Swift `AppDelegate` plus `SceneDelegate`; a Podfile.
  - `create-expo-app@5.0.0`, Expo SDK 58: blank-typescript gives `App.tsx` + `index.ts`, with no `android.package` / `ios.bundleIdentifier` in `app.json`. The default template is Expo Router with `src/app/_layout.tsx` (moved from `app/`; both are supported) and `main: "expo-router/entry"`.
  - **Android Studio 2025.2** "Empty Activity" (Compose) and "Empty Views Activity": hand-made. The activity sources come from the template strings in Android Studio's `plugins/android/lib/wizard-template.jar` (`composeActivityMaterial3`, `emptyActivity`); manifests and Gradle files follow the current module template. Compose uses Kotlin DSL + `libs.versions.toml`; Views is written in Groovy DSL with two product flavours, to cover both DSLs and flavours.
  - **Xcode 26.3** "App" (SwiftUI and Storyboard/UIKit): hand-made from the template definitions in `Xcode.app/…/Project Templates` (`SwiftUI App Base`, `Cocoa Touch App Base`, `UIScene Lifecycle`), with objectVersion 77 synchronized folders. The project files were checked with `xcodebuild -list`.
  - Neither IDE can generate a project headless, hence the hand-made fixtures.
- **npm trusted publishing** (docs.npmjs.com/trusted-publishers, last edited 2026-10-06):
  - It needs npm CLI ≥ 11.5.1 and Node ≥ 22.14.0, plus `permissions: id-token: write`.
  - Provenance is automatic for a public repository and package.
  - The workflow filename must match exactly. A new configuration expires unless it publishes within 2 days.
  - It is configured on an existing package's settings page, so the **first publish is manual** (`docs/SETUP_COMMAND.md`). Since the move the trusted publisher names repository `clikgate-mobile-sdk`.
  - `cli-release.yml` pins Node 24 and npm 11.21.0, checks that the tag matches the version, and checks the tarball's file list.

### Other decisions

- **Extra flags** `--no-install` and `--no-wait`. CI, AI assistants and demos need them while the SDK packages aren't published. `doctor` also accepts `--domain` for the live domains to require.
- **Dependencies are written by the CLI**, then the package manager runs. The diff shows the change and a second run sees it. Versions (moved 2026-10-26 to the shared-domain browser-fallback releases): `clikgate_flutter ^1.4.0`, `@clikgate/react-native ^1.5.0`, `com.clikgate:clikgate-android:1.4.0` (catalog `clikgate = "1.4.0"`), `pod 'Clikgate', '~> 1.4'`. Doctor's `sdk.version` minimums are the same; they match `ai-guides/versions.json` in `clikgate_sdks`, and its `ai-guides/scripts/check.mjs` passes. The new SDK option `platformDomainBrowserFallback` (default on) is deliberately never written. An existing older constraint is never rewritten (S.4: never remove or change existing lines): setup adds a manual "Update …" step and doctor warns. The coordinates were read from `clikgate_mobile_sdk`: `android/gradle.properties` `GROUP`/`POM_ARTIFACT_ID`/`VERSION_NAME`, `ios/Clikgate.podspec`, `flutter/pubspec.yaml`, `react-native/package.json`. Since the move (2026-10-26) `scripts/check_cli_sdk_versions.mjs` checks them in CI.
- **iOS without a Podfile:** the Swift package is a manual step with the Xcode steps. Adding `XCRemoteSwiftPackageReference` + `XCSwiftPackageProductDependency` + build-file links by text edit isn't reliable enough (S.4: "if the parser supports it reliably").
- **Native Android Application:** without an `Application` class the CLI creates `ClikgateApplication.kt` in the namespace's package and adds `android:name=".ClikgateApplication"`. `MainActivity` gets `Clikgate.handleIntent` in `onCreate` and a new `onNewIntent`, as the Android SDK requires; the Flutter and RN plugins forward intents themselves. Debug detection uses `ApplicationInfo.FLAG_DEBUGGABLE`, not `BuildConfig.DEBUG`, because AGP 8 doesn't generate BuildConfig by default.
- **Flutter:** adds `flutter_deeplinking_enabled=false` (Android) and `FlutterDeepLinkingEnabled=false` (iOS Info.plist) only when absent, as `docs/flutter.md` §7 says, so Flutter's own router doesn't also push Clikgate paths. No `onDeepLink` listener is inserted in `main`: the stream replays buffered links to the *first* subscriber, which should be the app's router. The summary reminds about this.
- **Per-platform keys:** Flutter/RN/Expo projects with two Clikgate apps get `defaultTargetPlatform == TargetPlatform.iOS ? … : …` / `Platform.OS === 'ios' ? … : …` when the test keys differ.
- **Debug entitlements when Debug and Release share one file** (e.g. after Expo prebuild): the Debug configuration's `CODE_SIGN_ENTITLEMENTS` is repointed to a copy plus `dev.ciz.to`. This is the one existing line the CLI changes, shown in the diff; nothing is removed.
- **Backups and undo:** backups are made only outside git; in git, `git checkout -- …` is the undo. The dirty-tree prompt defaults to "no".
- **iOS isn't build-tested in CI** (no Mac).
  - CI checks that the edited Info.plist, entitlements and project.pbxproj files parse, reference the right entitlements per configuration, and contain the expected `applinks:` entries (`cli/scripts/validate-ios.mjs`). It also runs `swiftc -parse` on the edited Swift.
  - Locally (2026-10-26), the edited SwiftUI and UIKit fixtures were type-checked with `swiftc -typecheck` for iOS against a `Clikgate` module built from `ios/Sources`.
- **Workflow validation:** actionlint isn't installable with npx (the npm `actionlint` package has no bin and dates from 2022). `cli.yml` and `cli-release.yml` were parsed with `yaml` (unique keys) and checked for `runs-on`, `needs`, step ids in expressions and SHA-pinned actions. Their `run:` blocks passed `bash -n`. The workflows have not been run.
- **End-to-end CI against unpublished SDKs:**
  - CI builds the SDKs from the same checkout (since the move; before it, CI checked out `clikgate/clikgate-mobile-sdk` with `MOBILE_SDK_READ_TOKEN`) and runs `publishToMavenLocal` in `android/`.
  - A Gradle init script (`cli/scripts/maven-local.init.gradle`) adds `mavenLocal()` for `com.clikgate` only. It handles `FAIL_ON_PROJECT_REPOS` (Android Studio templates).
  - The wrappers use their existing `clikgate.useMavenLocal=true`.
  - Flutter uses `pubspec_overrides.yaml` (path `flutter/`); RN/Expo use `npm install --install-links $GITHUB_WORKSPACE/react-native`.

## Change 09: app link subdomains and two-factor sign-in (2026-10-27)

Backend contract: the C9 contract B2.4 (app link subdomains) and the B4 answer (two-factor in the CLI device flow).

- **Hosts come from the server.** The command writes `app_link_domains.release` / `.debug` from
  `GET /v1/apps/{id}`. It never builds hostnames itself except in offline mode (`<sub>.ciz.to` →
  `<sub>.dev.ciz.to`) and as a fallback for a server without `app_link_domains` (the app's `link_hostnames`
  plus active `kind: custom` domains). Shared domains are filtered out whatever the server sends.
- **Explicit hosts, never `applinks:*.ciz.to`:** iOS and Android verify a wildcard against the apex file, which
  lists no customer apps (contract B2.4; Apple's associated-domains and Android's App Links verification
  findings recorded on 2026-10-26 above still apply).
- **Per platform.** Android and iOS apps may have different subdomains, and each subdomain's AASA / assetlinks
  list only its own app. On Android 11 and lower one unverifiable host fails the whole intent filter, so each
  platform's files get only its own app's hosts. The start-up code lists both platforms' hosts (harmless: it
  only tells the SDK which links are Clikgate's).
- **Confirming a subdomain** is a server-side change, so it is asked first. `--yes` confirms the suggestion:
  it can still be changed until the first link uses it.
- **Shared domains in a project are reported, not removed** (the command never removes lines); doctor warns
  (a warning, not a failure: links still redirect through the browser).
- **Two-factor:** the code is entered on the browser approval page; `POST /v1/cli/token` is unchanged, so the
  command only says so in the sign-in text.


## Change 16: websites, the "own server" question and the `/cg/keep` route (2026-10-30)

Spec: change 16 S (setup command) and R.1–R.2. Before this the command had no website support at all (the AI
guide said "the setup command doesn't do websites"), so the website flow is new, not an extension.

- **A separate command, `npx @clikgate/setup website`.** App setup signs in, matches apps and writes mobile SDKs;
  none of that applies to a website, and a Next.js or Express project would otherwise fall into "No app project
  found". That message now points to the `website` command. No sign-in: the web key is publishable, so it comes
  from `--web-key` or is asked for (Enter → `cgw_test_REPLACE_ME` plus a manual step). API keys and SDK keys
  (`cg_live_…`, `cg_test_…`, `cg_sdk_…`) are refused: never in a page.
- **Detection by package files (R.2)**, in the folder and, when nothing is there, up to three folders down
  (monorepos), like the app detection: `package.json` `next` → Next.js (wins over `express`), `express` → Express;
  `composer.json` requiring `laravel/framework` or `artisan` → Laravel; `manage.py`, or the package `django` in
  `requirements.txt` / `pyproject.toml` / `Pipfile` (not `django-environ`, `djangorestframework`) → Django;
  `spring-boot` in `pom.xml` / `build.gradle(.kts)` → Spring Boot; a `*.csproj` with `Sdk="Microsoft.NET.Sdk.Web"`
  → ASP.NET Core; `wp-config.php` or `wp-content/` → WordPress; `config/settings_schema.json` +
  `layout/theme.liquid` → Shopify theme. Several → it asks which. A detected server is announced ("Found a
  Django website (manage.py).") and never asked about.
- **The question.** Nothing detected, interactive, no `--yes`: "Does your website have its own server?" (default
  no), then "Which framework does it use?" (the six frameworks or "Something else", which is a manual step).
  Non-interactive or `--yes`: not asked, treated as no server, and the output names `--website-server`.
  `--website-server <nextjs|express|laravel|django|spring-boot|aspnet-core|wordpress|shopify|none>` skips both
  detection and the question; `none` means no route even when a framework is detected.
- **WordPress and Shopify: no edits.** The WordPress plugin keeps the click ID from the server itself (its REST keep
  route, R.2); the Shopify app keeps it in cart attributes, which covers visitors who create a cart in the same
  browser before the cookie expires (R.2). The command says so and exits 0 without a plan.
- **Keep route edits** (same rules as app setup: diff first, idempotent, an existing route or file is never
  overwritten, anything unrecognised is a manual step with the exact code):
  - Next.js App Router: a new `app/cg/keep/route.ts` (or `src/app/…`; `.js` without `tsconfig.json`) with
    `export const POST = clikgate.clickIds.keepRoute();`. An existing `route.*` there without `keepRoute` is left
    alone. Pages Router only: manual, because a Pages API route can't answer at `/cg/keep` (it lives under `/api`).
  - Express: in the file with exactly one top-level `const app = express()` (`package.json` `main`, then the usual
    `server|app|index.{js,ts,mjs}` and `src/…`), `app.post('/cg/keep', clikgate.clickIds.keepRoute().express);`
    right after it, so it runs before body parsers and catch-alls. An existing top-level `new Clikgate(` client is
    reused; otherwise an import (`require` in CommonJS files) and `const clikgate = new Clikgate();` are added.
  - Laravel: `Route::clikgateKeep('/cg/keep');` appended to `routes/web.php` (not when the file ends with `?>`).
  - Django: `path("cg/keep", clikgate.django.keep_view()),` as the first entry of the ROOT_URLCONF `urls.py`
    (found from `manage.py` → settings → `ROOT_URLCONF`, else the single `urls.py` that routes `admin.site.urls`),
    plus `import clikgate.django`. Needs `urlpatterns = [` on its own line and `path` imported.
  - Spring Boot: `clikgate.keep-route.enabled=true` appended to `application.properties` (created in
    `src/main/resources` when there's no config file), or a `clikgate: keep-route: enabled: true` block appended to
    `application.yml` when there's no top-level `clikgate:` and a single document. An explicit `=false` is left.
  - ASP.NET Core: `app.MapClikgateKeep("/cg/keep");` before the single top-level `app.Run();` in `Program.cs`
    (after `var app = builder.Build();`). The extension lives in `Microsoft.AspNetCore.Builder`, so no `using`.
- **Server SDK dependencies are not written.** The command only ever wrote mobile SDK dependencies; for server SDKs
  it prints the install command (`npm install @clikgate/node` / `pnpm|yarn|bun add`, `composer require
  clikgate/clikgate-laravel`, `pip install clikgate`, the `com.clikgate:clikgate-spring-boot-starter` dependency,
  `dotnet add package Clikgate.AspNetCore`), or reports it as already present. Package names are `SERVER_SDK` in
  `src/constants.ts`, with no versions: the keep-route APIs ship in each server SDK's next minor (after 1.1.0). If
  a minimum is ever written or checked, add it there and to `scripts/check_cli_sdk_versions.mjs`.
- **The script tag.** Every Clikgate script tag in the project (HTML, JSX, Blade, Razor, templates…) gets
  `data-server-endpoint="/cg/keep"` after `data-web-key` (else after `src`) only when the keep route was added or is
  already there, or the person says the route is already on their server after a manual step. Without a tag, a new
  one goes before `</head>` in the framework's layout files (`index.html`, `public/index.html`,
  `resources/views/layouts/*.blade.php`, `templates/base.html`, `Pages|Views/Shared/_Layout.cshtml`, Thymeleaf
  layouts), only when the file has exactly one `</head>`. Next.js layouts are JSX: the `next/script` snippet is a
  manual step. Nothing found: the tag is a manual step.
- **`data-days`.** The command never writes `data-days` (the script's default is now 30). An existing
  `data-days="7"` is the owner's choice and isn't changed; a reminder says the default is now 30 days.
- **Wording.** Every run with a server prints "Safari, and every browser on iPhone, keeps a click ID saved by a
  script for up to 7 days (sometimes less). When your server saves it, it lasts as long as you choose, up to the
  browser's limit." A test fails if `src/website.ts` or the output claims more.
- **Not checked here:** the route snippets follow the API names given for the server SDKs' next minor
  (`clickIds.keepRoute()`, `.express`, `Route::clikgateKeep`, `clikgate.django.keep_view`,
  `clikgate.keep-route.enabled`, `MapClikgateKeep`) and were not compiled or run against those SDKs. The
  framework adapters must exempt the route from CSRF protection (Laravel `web` middleware, Django, Spring Security)
  for the web script's same-origin POST to succeed.
