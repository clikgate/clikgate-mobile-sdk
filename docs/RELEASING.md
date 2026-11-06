# Releasing the SDKs

Each package is released by pushing a tag; the matching workflow in `.github/workflows/` checks
that the tag equals the package version, runs the tests and publishes. None of the release jobs
has been run yet; the secrets each one needs are listed in its workflow.

| Tag | Workflow job | Publishes | Version checked against |
|---|---|---|---|
| `android-v<version>` | `android.yml` `release` | Maven Central `com.clikgate:clikgate-android` **and** `com.clikgate:clikgate-engage` | `android/gradle.properties` `VERSION_NAME` (shared by both modules) |
| `ios-v<version>` | `ios.yml` `release` | GitHub release (CocoaPods source zip, `Clikgate` and `ClikgateEngage` XCFramework zips + checksums), SPM mirror tag, CocoaPods trunk `Clikgate` (subspecs `Core`, `Engage`) | `Clikgate.sdkVersion`, `ClikgateEngage.version` and `Clikgate.podspec` `s.version` (all three must equal the tag) |
| `flutter-v<version>` | `flutter.yml` `release` | pub.dev `clikgate_flutter` | `flutter/pubspec.yaml` |
| `flutter-engage-v<version>` | `flutter.yml` `release-engage` | pub.dev `clikgate_engage` | `flutter_engage/pubspec.yaml` |
| `react-native-v<version>` | `react-native.yml` `release` | npm `@clikgate/react-native` | `react-native/package.json` |
| `react-native-engage-v<version>` | `react-native.yml` `release-engage` | npm `@clikgate/react-native-engage` | `react-native-engage/package.json` |
| `cli-v<version>` | `cli-release.yml` `publish` | npm `@clikgate/setup` (trusted publishing, provenance; MIT) | `cli/package.json` (and `scripts/check_cli_sdk_versions.mjs`: the SDK versions it writes equal this repository's) |

## Order

Packages resolve their dependencies from the public registries, so release from the bottom of
the dependency graph up. Each step must be **live on its registry** (Maven Central sync, trunk
push, pub.dev / npm publish finished) before the next tag is pushed:

1. **Native core + Engage**, in either order:
   - `android-v<x>` (core and Engage modules together);
   - `ios-v<x>` (core, Engage subspec and both XCFrameworks together).
2. **Flutter core** `flutter-v<x>`: its Android side depends on
   `com.clikgate:clikgate-android:<x>`, its podspec on `Clikgate ~> <x>`.
3. **Flutter Engage** `flutter-engage-v<y>`: depends on `clikgate_flutter: ^<x>` from pub.dev.
   The job deletes `flutter_engage/pubspec_overrides.yaml` (the monorepo path override) before
   `pub get`, so it fails if the required `clikgate_flutter` isn't published yet.
4. **React Native core** `react-native-v<x>`: depends on `com.clikgate:clikgate-android:<x>`
   and `Clikgate ~> <x>`.
5. **React Native Engage** `react-native-engage-v<y>`: peer dependency
   `@clikgate/react-native: ^<x>`. (Its job builds the core's types from the repository, so it
   would publish without step 4, but users couldn't install a matching core.)

6. **Setup command** `cli-v<z>`, only when the SDK versions in `cli/src/constants.ts` are live
   (`npx @clikgate/setup` installs them). Owner setup for npm trusted publishing:
   [SETUP_COMMAND.md](SETUP_COMMAND.md) "Publishing".

Steps 2-3 and 4-5 are independent of each other. An Engage-only fix (Dart or TypeScript) needs
only its own tag when the core version it requires is already published. A native Engage fix
needs a new `android-v` / `ios-v` release, because core and Engage share one version per
platform.

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
