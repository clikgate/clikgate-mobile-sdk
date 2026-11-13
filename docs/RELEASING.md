# Releasing the SDKs

Each package is released by pushing a tag; the matching workflow in `.github/workflows/` checks
that the tag equals the package version, runs the tests and publishes. None of the release jobs
has been run yet; the secrets each one needs are listed in its workflow.

| Tag | Workflow job | Publishes | Version checked against |
|---|---|---|---|
| `android-v<version>` | `android.yml` `release` | Maven Central `com.clikgate:clikgate-android` (core and Engage features) | `android/gradle.properties` `VERSION_NAME` |
| `ios-v<version>` | `ios.yml` `release` | GitHub release (CocoaPods source zip, `Clikgate` and `ClikgateEngage` XCFramework zips + checksums), SPM mirror tag, CocoaPods trunk `Clikgate` (one pod: core and Engage) | `Clikgate.sdkVersion`, `ClikgateEngage.version` and `Clikgate.podspec` `s.version` (all three must equal the tag) |
| `flutter-v<version>` | `flutter.yml` `release` | pub.dev `clikgate_flutter` | `flutter/pubspec.yaml` |
| `react-native-v<version>` | `react-native.yml` `release` | npm `@clikgate/react-native` | `react-native/package.json` |
| `setup-v<version>` | none (owner's Mac, see [Setup command binaries](#setup-command-binaries-dart-run-clikgate_flutter)) | GitHub release with the setup command binaries that `dart run clikgate_flutter` downloads | `cli/package.json`, and `flutter/lib/src/setup_runner/setup_binaries.g.dart` (`scripts/check_cli_sdk_versions.mjs`) |
| `cli-v<version>` | `cli-release.yml` `publish` | npm `@clikgate/setup` (trusted publishing, provenance; MIT) | `cli/package.json` (and `scripts/check_cli_sdk_versions.mjs`: the SDK versions it writes equal this repository's) |

## Order

Packages resolve their dependencies from the public registries, so release from the bottom of
the dependency graph up. Each step must be **live on its registry** (Maven Central sync, trunk
push, pub.dev / npm publish finished) before the next tag is pushed:

1. **Native SDKs** (each with its Engage features since 2.1.0), in either order:
   - `android-v<x>`;
   - `ios-v<x>` (the pod, the SPM mirror and both XCFrameworks together).
2. **Flutter** `flutter-v<x>`: its Android side depends on
   `com.clikgate:clikgate-android:<x>`, its podspec on `Clikgate ~> <x>`. The pub package carries the
   checksums of the setup command binaries, so the `setup-v<cli version>` GitHub release must exist
   **before** `flutter pub publish` ([below](#setup-command-binaries-dart-run-clikgate_flutter)).
3. **React Native** `react-native-v<x>`: depends on `com.clikgate:clikgate-android:<x>`
   and `Clikgate ~> <x>`.
4. **Setup command** `cli-v<z>`, only when the SDK versions in `cli/src/constants.ts` are live
   (`npx @clikgate/setup` installs them). Owner setup for npm trusted publishing:
   [SETUP_COMMAND.md](SETUP_COMMAND.md) "Publishing".

Steps 2-3 and 4-5 are independent of each other. An Engage-only fix (Dart or TypeScript) needs
only its own tag when the core version it requires is already published. A native Engage fix
needs a new `android-v` / `ios-v` release, because core and Engage share one version per
platform.

## One-time registry setup (publishing from tags without tokens)

- **npm** (`@clikgate/react-native`, `@clikgate/setup`): npmjs.com → the package → Settings → Trusted
  publishing → GitHub Actions: repository `clikgate/clikgate-mobile-sdk`, workflow `react-native.yml` /
  `cli-release.yml`, environment `npm`. The jobs install npm 11.21.0 (trusted publishing needs ≥ 11.5.1) and
  use no token.
- **pub.dev** (`clikgate_flutter`): pub.dev → Admin → Automated publishing → GitHub Actions: repository
  `clikgate/clikgate-mobile-sdk`, tag pattern `flutter-v{{version}}`, and (if offered) require the GitHub
  environment `pub-dev`.

Without this the release job fails before anything is published; publish from a Mac instead
(`flutter pub publish`, `npm publish --access public`).

## Setup command binaries (`dart run clikgate_flutter`)

`dart run clikgate_flutter` (and `:setup`, `:doctor`) downloads
`https://github.com/clikgate/clikgate-mobile-sdk/releases/download/setup-v<version>/clikgate-setup-<version>-<platform>[.exe].gz`
and refuses it unless the sha256 of the `.gz`, and of the binary after unpacking, equal the hashes in the
published `clikgate_flutter`. So the `.gz` files go up first, then the pub package. GitHub Actions is blocked on billing, so this runs on the owner's Mac (macOS is
needed for the ad-hoc signature of the darwin binaries), one build at a time:

1. `cd cli && npm ci && npm test && cd ..`, then `node scripts/check_cli_sdk_versions.mjs`.
2. `scripts/build_setup_binaries.sh` (all five platforms, no `--only`). It writes `cli/dist/bin/*` and
   `flutter/lib/src/setup_runner/setup_binaries.g.dart`. Check the binary: `cli/dist/bin/clikgate-setup-<version>-darwin-arm64 --version`.
3. Commit the regenerated `setup_binaries.g.dart`, then run `node scripts/check_cli_sdk_versions.mjs` again: it
   compares the committed hashes with the files you are about to upload. Upload exactly these files; don't rebuild
   in between. The builds are reproducible, but the check is what proves the files match.
4. `gh release create setup-v<version> cli/dist/bin/clikgate-setup-<version>-*.gz cli/dist/bin/SHA256SUMS --repo clikgate/clikgate-mobile-sdk --title "Setup command <version> binaries" --notes "Binaries for dart run clikgate_flutter (same program as npx @clikgate/setup <version>)."`
   (only the `.gz` files and `SHA256SUMS`, about 243 MB in all; the repository is public, so the assets
   download without a token). Check that one URL downloads.
5. Then publish the Flutter package (`cd flutter && flutter pub publish`, or the `flutter-v<x>` tag once Actions
   works again). A `clikgate_flutter` release whose CLI version is unchanged reuses the existing `setup-v` release.

Never move or replace the assets of a published `setup-v` release: every published `clikgate_flutter` that
names that version would then refuse its download.

## Checklist per release

- Bump the version in every file listed in the table for the tags you push (for iOS, all three:
  `Sources/Clikgate/Public/Clikgate.swift`, `Sources/ClikgateEngage/ClikgateEngage.swift`,
  `Clikgate.podspec`); bump the native dependency versions in the Flutter and RN podspecs /
  Gradle files when the wrappers need a new native release.
- Update each package's `CHANGELOG.md`.
- Run `scripts/check_sdk_boundaries.sh` (API snapshots, "no Engage in core", size budgets).
- A version bump in any of `android/gradle.properties`, `ios/Clikgate.podspec`, `flutter/pubspec.yaml`
  or `react-native/package.json` also bumps `cli/src/constants.ts` and the CLI snapshots
  (`cd cli && npm run test:update`, then review) in the same change: `node scripts/check_cli_sdk_versions.mjs`
  fails otherwise (CI: `cli.yml` › `sdk-versions`). Then the AI guides' `versions.json` in `clikgate_sdks`.
- Licence: Apache 2.0 for the SDKs (root `LICENSE`, copied into each package directory); keep the copies
  identical. The setup command in `cli/` is MIT (`cli/LICENSE`); don't replace it with the Apache text.
