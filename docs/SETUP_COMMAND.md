# Setup command (`npx @clikgate/setup`)

Source: `cli/` in this repository (`clikgate_mobile_sdk`; it moved here from `clikgate_sdks` on 2026-10-26, see [`cli/DECISIONS.md`](../cli/DECISIONS.md)). Change 06 S.1–S.6 and S.8 (milestones C6-S1 and C6-S2). Licence: **MIT** (`cli/LICENSE`), unlike the mobile SDKs in this repository, which are Apache 2.0.

The command sets up Clikgate in a Flutter, React Native, Expo, native Android or native iOS app project. It shows every change as a diff and asks once before writing anything. It only ever uses the **test** SDK key. App links use the app's own **link subdomain** (`yourapp.ciz.to`, or `yourapp.clk.ng` on the Free plan, and `yourapp.dev.ciz.to` in **debug builds only**) plus the organisation's verified custom domains, never a shared domain (change 09 N.1).

- npm package: **`@clikgate/setup`**, bin **`clikgate-setup`**. The documented command is always `npx @clikgate/setup`.
- Node 18 or newer. One bundled file (`dist/cli.cjs`, built with tsup) with no runtime dependencies to install.
- No telemetry. The only network calls go to the Clikgate API (`https://api.clikgate.com`, or `--api-url`), and only after the person signs in. Offline mode makes none.

## Commands, flags, exit codes

```
npx @clikgate/setup                 # interactive setup
npx @clikgate/setup doctor          # checks only, changes nothing
npx @clikgate/setup website         # a website: the web script and, with its own server, the /cg/keep route
Flags:
  --dry-run          show the plan and diffs, change nothing
  --yes              apply without the confirmation prompt (diffs are still printed)
  --cwd <path>       project folder (default: current)
  --platform <flutter|react-native|expo|android|ios>   skip detection
  --app <app_id>     use this Clikgate app
  --sdk-key <cg_sdk_test_…> --domain <host>[,<host>]   offline mode (app subdomain + custom domains)
  --json             machine-readable output (doctor only)
  --api-url <url>    for Clikgate's own development
  --no-install       don't run the package manager (you run it yourself)   [extra]
  --no-wait          doctor: don't wait for the first event               [extra]
  --no-color, --verbose, --version, --help
```

`--no-install` and `--no-wait` are additions to S.2. They are needed for CI, for AI assistants, and while the SDK packages aren't on the registries yet. `--domain` is also accepted by `doctor`, where it gives the live domains every release build must cover.

The device sign-in prints "If your account uses two-factor sign-in, the page also asks for your authenticator code (or a recovery code)." The code is entered on the browser approval page (contract B4: `POST /v1/cli/device-codes/{user_code}/approve` takes `two_factor_code` or `recovery_code`); polling `/v1/cli/token` is unchanged, and after a minute of `authorization_pending` the command reminds the person to approve in the browser.

| Exit code | Meaning |
|---|---|
| 0 | success (doctor: no check failed; warnings allowed) |
| 1 | problems found, or a step failed (including bad flags, no project, a live key in offline mode) |
| 2 | cancelled (answered no, or no `--yes` in a non-interactive shell) |
| 3 | sign-in failed (denied, expired, or rejected) |

## What it does (S.3)

1. **Detect** the project. `pubspec.yaml` with Flutter → Flutter. `package.json` with `expo` and an app config → Expo; when `android/` and `ios/` exist, their native files are edited too. `package.json` with `react-native` and no `expo` → React Native. A Gradle app module with no `package.json`/`pubspec.yaml` → Android. An Xcode project with neither → iOS.
   - When the folder has none of these, it looks up to three folders down (monorepos such as `apps/mobile`).
   - Several candidates → it asks which one. Nothing found → it explains and exits 1.
   - The package manager comes from the lockfile, found up to the repository root: bun, pnpm, yarn, or npm.
2. **Working tree.** Uncommitted git changes → it warns and asks ("Continue anyway?", default no). Outside a git repository, every file about to change is first copied to `.clikgate-setup-backup/<timestamp>/`, with a `README.txt` that lists the new files to delete.
3. **Sign in** with the RFC 8628 device flow. It prints the URL and code, opens the browser when it can (never in CI or over SSH), and polls `/v1/cli/token` at `interval`, adding 5 seconds on each `slow_down`.
   - The `cg_cli_` token stays in memory only: never printed, logged or written.
4. **Apps.** It reads the Android `applicationId` (Expo: `android.package`) and the iOS `PRODUCT_BUNDLE_IDENTIFIER`/`DEVELOPMENT_TEAM` (Expo: `ios.bundleIdentifier`/`appleTeamId`), and asks when there are several (flavours, configurations).
   - It matches existing apps or offers to create them. Android needs a signing SHA-256 to be created; iOS needs the Team ID.
5. **Signing details.** It reads the debug keystore SHA-256 with `keytool`: the module's own keystore (React Native templates ship one), else `~/.android/debug.keystore`.
   - It asks for the Play App Signing SHA-256 (Play Console › Release › Setup › App signing), or adds a reminder.
   - Fingerprints are sent with `PATCH /v1/apps/{id}`, add-only (existing + new). The Team ID is sent when Clikgate doesn't have it.
6. **Link domains** (change 09 N.1). Each app's hosts come from `GET /v1/apps/{id}` `app_link_domains`: `release` is the app's live subdomain (`yourapp.ciz.to`; on the Free plan `yourapp.clk.ng`, change 10) plus the organisation's active custom domains, `debug` the test subdomain (`yourapp.dev.ciz.to`, every plan). An app subdomain under `clk.ng` is not a shared domain: the shared-domain check is an exact match on the four hosts. They never contain a shared domain (`ciz.to`, `clk.ng`, `clkg.to`, `dev.ciz.to`), and the command filters them out anyway.
   - **Unconfirmed subdomain** (apps created before change 09 carry a suggestion, `link_subdomain_confirmed: false`): it asks `Use "<name>"?`. No → it asks for another name, checks it with `GET /v1/link-subdomains/availability` (showing the reason and a suggestion), and confirms with `PATCH /v1/apps/{id} {"link_subdomain": "<name>"}`. `--yes` confirms the suggestion. Skipping it leaves a manual step and no app links for that app. `--dry-run` uses the suggestion without confirming.
   - Each platform's files get only its own app's hosts (the Android and iOS apps may have different subdomains; one app's subdomain files don't list the other). The start-up code's `linkDomains` lists every platform's release hosts and the first test subdomain; the SDKs add the rest from `/v1/sdk/config`.
   - With two or more custom domains it lets the person deselect some (release builds). The app subdomain always stays.
   - The old shared-domain opt-in (`sdk-settings` `shared_domain_app_links` / `test_domain_app_links`) is gone: the backend ignores those settings.
   - Shared domains already in the project (older setups) are never removed by the command: each becomes a manual step "remove this: shared domains can't open your app", and doctor warns about them.
7. **Plan, diff, confirm.** Steps already done show `✓ already set up`. Then it asks "Show full diff? (Y/n)" and "Apply? (y/N)". `--dry-run` prints the plan and the diffs and exits 0. `--yes` prints the diffs and applies.
8. **Apply,** then run the package install:
   - `flutter pub get`, or `npm`/`yarn`/`pnpm`/`bun install`;
   - `pod install` (or `bundle exec pod install` with a Gemfile), asking first, when CocoaPods is on PATH.
   - On failure it stops, lists the changed and new files, and prints how to undo: `git checkout -- …` or the backup folder, plus the new files to delete. Exit 1.
9. **Verify** with `doctor` (and Clikgate's setup check when signed in). Then it waits for the first test event ("Waiting for the first event from your app… (up to 5 minutes, press Enter to skip)").
10. **Summary:** what changed, what was already set up, the manual steps with snippets, reminders, and next steps.
    - Next steps: create a link; go live by replacing the test key at `<file>:<line>` with the live key for release builds (the command never handles the live key); send goals with the one `goal()` method, for example `Clikgate.goal("purchase", reference = "T123456", provider = Provider.PAYSTACK)` on Android (a Payment goal waits until the payment provider or the business's server confirms it); identify signed-in users (optional, Change 22): Path A by default (a token from the server's `createIdentityToken(user.id)` passed to `identifyUser(...)`), Path B mentioned (send the installation ID from `getInstallationId()` to the server), with the link https://clikgate.com/docs/identify-users. Step 4 of the summary prints it.
    - The last line is **"Clikgate sees every click. Setup complete."**

### Dependencies

The command writes the dependency into the manifest itself, so the diff shows it and a re-run sees it. Then it runs the package manager to resolve it:

- `pubspec.yaml`: `clikgate_flutter: ^2.0.0`, then `flutter pub get`;
- `package.json`: `@clikgate/react-native: ^2.0.0`, in alphabetical position, then `<pm> install`. Expo uses the same path (see [cli/DECISIONS.md](../cli/DECISIONS.md): `npx expo install` adds nothing for packages outside Expo's bundled list);
- Gradle: `implementation("com.clikgate:clikgate-android:2.0.0")` (Kotlin DSL), `implementation 'com.clikgate:clikgate-android:2.0.0'` (Groovy), or a version-catalog entry `clikgate-android` plus `implementation(libs.clikgate.android)`;
- Podfile: `pod 'Clikgate', '~> 2.0'` in the app target.
- An existing, older constraint is never rewritten: setup lists it as a manual step ("Update clikgate_flutter … to ^1.5.1") and doctor warns (`sdk.version`, minimums Flutter 1.5.1, RN 1.6.1, Android 1.5.1, iOS 1.5.1).
- The SDKs' `platformDomainBrowserFallback` option (default on) is never written.
  - Without a Podfile it prints the Xcode "Add Package Dependencies" steps for `https://github.com/clikgate/clikgate-ios-sdk` as a manual step. It doesn't edit Swift package references in `project.pbxproj`: they are several linked objects, and a partial edit breaks the project.

## Websites: `npx @clikgate/setup website` (Change 16)

Adds the Clikgate web script to a website and, when the site has its own server, the `/cg/keep` route that saves
the click ID from that server. Safari, and every browser on iPhone, keeps a click ID saved by a script for up to
7 days (sometimes less); when the server saves it, it lasts as long as the business chooses, up to the
browser's limit.

- **Script tag:** finds the existing Clikgate script tag, or adds one to the site's layout, and adds
  `data-server-endpoint="/cg/keep"` when a keep route is added. `--web-key cgw_test_…` sets the publishable key
  for a new tag.
- **Server detection** from the project's files: Next.js and Express (`package.json`), Laravel (`composer.json`
  requiring `laravel/framework`, or `artisan`), Django (`manage.py`, or `django` in `requirements.txt`,
  `pyproject.toml` or `Pipfile`), Spring Boot, ASP.NET Core (`*.csproj`), WordPress (`wp-config.php` or
  `wp-content/`) and Shopify themes (`config/settings_schema.json` with `layout/theme.liquid`). When it can't tell,
  it asks "Does your website have its own server?".
- **Keep route:** added for Next.js, Express, Laravel, Django, Spring Boot and ASP.NET Core, using the server SDK's
  keep route. WordPress and Shopify get no route: the Clikgate plugin and app keep the click ID themselves.
- `--website-server <nextjs|express|laravel|django|spring-boot|aspnet-core|wordpress|shopify|none>` skips detection
  and the question (`none`: script only, no route).
- As everywhere else, every edit is shown as a diff first; `--dry-run` and `--yes` work the same way.

## What gets changed (S.4)

All edits use real parsers (see [cli/DECISIONS.md](../cli/DECISIONS.md)). Inserted code sits between `// clikgate-setup:start` and `// clikgate-setup:end`; manifests use `<!-- … -->` and Podfile/Gradle use their own comment syntax. Existing code, intent filters and entitlements are never removed or reordered. Source files are edited only in recognised template shapes; anything else becomes a manual step with the exact snippet.

| Platform | App links | Start-up code |
|---|---|---|
| Flutter | `android/app/src/main/AndroidManifest.xml`: a verified `https` filter on the launcher activity for the live domains, plus `flutter_deeplinking_enabled=false` so Flutter's own router doesn't also push the link. `src/debug/AndroidManifest.xml`: the test subdomain (`yourapp.dev.ciz.to`). `ios/Runner/Runner.entitlements` (Release, Profile) and `RunnerDebug.entitlements` (Debug, which adds the test subdomain), each linked with `CODE_SIGN_ENTITLEMENTS`. `Info.plist`: `FlutterDeepLinkingEnabled=false` | `lib/main.dart`: imports, `main` made `Future<void> … async`, `WidgetsFlutterBinding.ensureInitialized()` (unless already there) and `await Clikgate.configure(...)` before `runApp` |
| React Native | the same native edits in `android/` and `ios/`. iOS link forwarding is checked: the RN 0.88 template's `SceneDelegate` forwards to `RCTLinkingManager`, which the module observes; otherwise a manual step | `App.tsx`/`App.js`: `Clikgate.configure(...)` after the imports and an `onDeepLink` listener in a `useEffect` |
| Expo | `app.json`: `["@clikgate/react-native", {"linkDomains": ["yourapp.ciz.to", ...], "testLinkDomain": "yourapp.dev.ciz.to"}]`. `app.config.js/ts` is code: the entry is shown as a manual step. With `android/`/`ios/` present, the native files are edited as for React Native. A reminder says to make a new development build | `src/app/_layout.tsx` / `app/_layout.tsx` (Expo Router) or `App.tsx` |
| Android | main manifest (live) and debug manifest (the test subdomain). Other existing debug-based source sets (e.g. React Native's `debugOptimized`) get it too | `Application.onCreate` after `super.onCreate()`. Without an `Application`, it creates `ClikgateApplication.kt` and registers it in the manifest. `MainActivity`: `Clikgate.handleIntent` in `onCreate` and a new `onNewIntent` |
| iOS | Release and Debug entitlements as above | SwiftUI `@main App`: `init()` with `Clikgate.configure`, and `.onOpenURL` / `.onContinueUserActivity` on the root view. UIKit: `didFinishLaunching`, plus `SceneDelegate` forwarding (launch options, `scene(_:continue:)`, `scene(_:openURLContexts:)`), or the AppDelegate URL methods without scenes |

The SDK's own `linkDomains` include the test subdomain only in debug builds too: Dart `kDebugMode`, JS `__DEV__`, Android `FLAG_DEBUGGABLE`, Swift `#if DEBUG`. When a project has separate Android and iOS apps with different test keys, the code picks the key per platform (`defaultTargetPlatform` / `Platform.OS`).

## doctor (S.5)

`npx @clikgate/setup doctor [--json] [--domain …] [--app …] [--no-wait]` changes nothing.

- **Project checks:**
  - the SDK dependency and its version against the minimum;
  - the start-up code;
  - the SDK key in use, test or live, masked as `cg_sdk_test_abcd…`;
  - every release manifest and release entitlements file covers every live domain;
  - the app's test subdomain (`*.dev.ciz.to`) is in debug builds and never in release builds (it fails if it is);
  - no shared domain (`ciz.to`, `clk.ng`, `clkg.to`, `dev.ciz.to`) in any manifest, entitlements file or Expo plugin entry: `android.shared_domains`, `ios.shared_domains`, `expo.shared_domains` warn "remove this: shared domains can't open your app";
  - a Free plan app subdomain (`yourapp.clk.ng`, change 10) passes like `yourapp.ciz.to`: only the bare shared hosts warn;
  - every configuration's `CODE_SIGN_ENTITLEMENTS` file exists and parses;
  - the Expo plugin entry.
- **Clikgate:** in a terminal it offers to sign in. It then reads `GET /v1/cli/setup-check` per app and shows a ✓/✗ and a fix for each domain's AASA/assetlinks.
  - Only the file that applies to the app's platform is judged (`applies: true`).
  - `domains[]` holds the app's live and test subdomains plus the custom domains (shared domains are no longer checked), so doctor checks that the app subdomain's AASA / assetlinks contain the app.
  - `clikgate.<platform>.link_subdomain` passes for a confirmed subdomain and fails with `link_subdomain_not_confirmed` (fix: confirm it in the dashboard or rerun setup).
  - It also shows the fingerprints and Team ID, SDK warnings, and `next_steps`.
- **Live test:** it waits up to 5 minutes for the first test-mode SDK request: "Clikgate is receiving events from <platform> ✓".
- `--json` prints one document to stdout, with human text on stderr. It never signs in, so it runs local checks only. Schema: `cli/schema/doctor-report.schema.json` (`schema_version: 1`, shipped in the npm package). The exit code is 0 when `ok`, else 1.

## Offline mode (S.6)

`npx @clikgate/setup --sdk-key cg_sdk_test_… --domain yourapp.ciz.to,go.acme.com` configures the project without signing in: no app creation, no fingerprints sent, no server checks. The debug host is derived from the app subdomain (`yourapp.ciz.to` or, on Free, `yourapp.clk.ng` → `yourapp.dev.ciz.to`) and added to debug builds; test hosts given in `--domain` are moved to debug builds.

- A live key is refused: "Use the test key; switch to live for release builds." (exit 1).
- A shared domain in `--domain` is refused (exit 1): "ciz.to: remove this: shared domains can't open your app. Pass your app's link subdomain instead…".
- Without an app subdomain in `--domain`, debug builds get no test host and a manual step says so.
- Signing details become a manual step.

## Undoing

- In a git repository: `git checkout -- <files>` and delete the new files the summary lists.
- Outside git: copy the files back from `.clikgate-setup-backup/<timestamp>/` (its `README.txt` lists new files to delete).
- The marked blocks (`clikgate-setup:start` … `end`) are what the SDK removal guide looks for.

## Versions it writes (kept in step with the SDKs)

`cli/src/constants.ts` (`SDK`) holds the package names, versions and constraints the command writes and doctor's `sdk.version` minimums. They must equal the SDKs in this repository:

| `SDK.*` | Must equal |
|---|---|
| `android` `group` / `artifact` / `version` | `android/gradle.properties` `GROUP` / `POM_ARTIFACT_ID` / `VERSION_NAME` |
| `ios` `pod` / `version` / `podConstraint` (`~> major.minor`) | `ios/Clikgate.podspec` `s.name` / `s.version` |
| `flutter` `package` / `minimum` / `constraint` (`^version`) | `flutter/pubspec.yaml` `name` / `version` |
| `reactNative` `package` / `minimum` / `constraint` (`^version`) | `react-native/package.json` `name` / `version` |

`node scripts/check_cli_sdk_versions.mjs` (or `cd cli && npm run check:sdk-versions`) fails when they drift; it also checks `CLI_VERSION` against `cli/package.json`. CI runs it (`cli.yml` › `sdk-versions`, and before every `cli-release.yml` publish). So an SDK release that bumps a version bumps `cli/src/constants.ts`, the CLI's snapshots (`cd cli && npm run test:update`, then review), this page, and the CLI changelog in the same change. The AI guides in `clikgate_sdks` (`ai-guides/versions.json`) are checked against the same constants there.

## Tests and CI

- `cd cli && npm ci && npm test`. This runs vitest:
  - snapshot diffs of every fixture, and a second run that changes nothing;
  - the app's test subdomain (`acme.dev.ciz.to`) only in debug manifests and Debug entitlements, and no shared domain anywhere;
  - edits on unrecognised shapes become manual steps;
  - the dirty-tree prompt, backups, and undo after a failed write or a failed install;
  - the device flow against a mock server, including RFC-style 400 errors;
  - a signed-in run (app creation, fingerprints, app subdomains from `app_link_domains`, per-platform keys), confirming an unconfirmed subdomain (availability check, another name, `--yes`, skipping);
  - offline refusals (a live key, a shared domain in `--domain`);
  - every doctor failure type, validated against the JSON schema.
- `.github/workflows/cli.yml` runs on changes to `cli/` and to the SDK sources the command depends on (the version files above, and the configure APIs and Expo plugin its snippets call):
  - the SDK version check (`scripts/check_cli_sdk_versions.mjs`);
  - unit tests;
  - a Node 18 smoke run over all fixtures;
  - **iOS project-file validation on Linux** (`scripts/validate-ios.mjs` plus `swiftc -parse`);
  - **end-to-end jobs** from fresh `flutter create`, React Native CLI and `create-expo-app` (blank and router) projects, plus the Android Studio fixtures. Each job runs `setup --sdk-key … --domain … --yes`, checks that a second run changes nothing, builds Android debug **and release** against the SDKs built from this checkout (Android to Maven local, Flutter by path, React Native by `--install-links`), checks the merged manifests (`scripts/check-merged-manifests.sh`), and runs `doctor --json`.
  - iOS is never built in CI.
- `.github/workflows/cli-release.yml`: publishes to npm with trusted publishing and provenance on a `cli-v<version>` tag.

## Fixtures (`cli/test/fixtures/`)

| Fixture | Made with |
|---|---|
| `flutter` | `flutter create --org com.example --platforms android,ios` (Flutter 3.41.8) |
| `react-native` | `npx @react-native-community/cli@20.2.0 init RnApp` (React Native 0.88.0) |
| `expo-blank` | `npx create-expo-app@5.0.0 --template blank-typescript` (Expo SDK 58) |
| `expo-router` | `npx create-expo-app@5.0.0` (default Expo Router template, SDK 58) |
| `expo-native` | `expo-blank` + `npx expo prebuild` (real `android/` and `ios/`) |
| `android-compose` | hand-made from Android Studio 2025.2's "Empty Activity" template sources (Kotlin DSL, version catalog) |
| `android-views` | hand-made from Android Studio 2025.2's "Empty Views Activity" template sources (Groovy DSL, two product flavours) |
| `ios-swiftui` | hand-made from Xcode 26.3's iOS App template, SwiftUI (objectVersion 77, synchronized folders); checked with `xcodebuild -list` |
| `ios-uikit` | hand-made from Xcode 26.3's iOS App template, Storyboard/UIKit, with a Podfile; checked with `xcodebuild -list` |
| `monorepo` | hand-made pnpm workspace whose `apps/mobile` is a copy of `react-native` |

Fixtures are trimmed to the files the command reads or edits: no build outputs, `node_modules`, images or Gradle wrappers.

## Publishing (owner actions)

**One-time first publish.** npm configures a trusted publisher on the package's settings page, so the package must exist first. A new trusted-publisher configuration must complete a successful publish within 2 days.

1. Create the npm organisation **`clikgate`** (the `@clikgate` scope doesn't exist on npm yet, as of 2026-10-26). Enable 2FA for publishing.
2. From a clean checkout of this repository, with an owner account: `node scripts/check_cli_sdk_versions.mjs && cd cli && npm ci && npm test && npm run build && npm publish --access public` (version `1.0.0`). This first publish has no provenance; every later one does.
3. On npmjs.com › `@clikgate/setup` › Settings › Trusted publishing, add GitHub Actions with organisation `clikgate`, repository **`clikgate-mobile-sdk`**, workflow `cli-release.yml` and environment `npm`. The `npm` environment already exists in this repository for the React Native releases; add required reviewers if wanted.
4. Then set "Publishing access" to "Require two-factor authentication and disallow tokens", so only the workflow can publish.
5. Later releases: bump `cli/package.json` `version` and `CLI_VERSION` in `cli/src/constants.ts`, update the changelog, run `node scripts/check_cli_sdk_versions.mjs`, then tag `cli-v<version>` and push it. Release the SDK versions the command writes first (see [RELEASING.md](RELEASING.md)), so `npx @clikgate/setup` never installs an unpublished version.

**Look-alike names to reserve** (S.1). Publish a placeholder `0.0.1` under each, with a README that says "Use `npx @clikgate/setup`" and points to the docs, then deprecate it with `npm deprecate <name> "Use npx @clikgate/setup"`:

- `clikgate-setup` (unscoped; same as the bin name);
- `@clikgate/cli`;
- `clikgate` (unscoped);
- optionally `@clikgate/init` and `create-clikgate`, the usual "npm init" names.

All five were free on 2026-10-26. Don't publish the `@clikgate/react-native` placeholder here: it belongs to the mobile SDK release.

**Also before launch:**

- The packages the command installs must be live: `clikgate_flutter` on pub.dev, `clikgate_flutter` 1.5.1 / `@clikgate/react-native` 1.6.1 on npm, `com.clikgate:clikgate-android` 1.5.1 on Maven Central, `Clikgate` 1.5.1, and the `Clikgate` pod / SPM mirror. Until then, use `--no-install` in demos.
- Run the command once on a real iOS project on a Mac (S.8: iOS isn't build-tested in CI), and once on a device for the "first event" check.
