#!/usr/bin/env bash
# Core / Engage boundary checks for every SDK (spec v3 new edition, 0.4 and section 20):
#   1. public-API snapshot of each core SDK (and each Engage package), checked in;
#   2. the core public API has no leaderboard, referral-stats, link-creation, code, share or
#      identity-signal API (forbidden-name check on the snapshot);
#   3. core never depends on Engage (build files, manifests, imports);
#   4. size budgets: core Android < 150 KB, Engage Android < 44 KB, core iOS < 410 KB,
#      Engage iOS < 95 KB (methods: android/DECISIONS.md and ios/DECISIONS.md, "Engage split");
#   5. Change 12: the generated Provider types match shared/providers.json
#      (scripts/generate_providers.py --check), and the published sources of each package pass the
#      release scan (scripts/scan_release_packages.py: no TODO/FIXME, internal references, internal
#      hosts, staff references or debug code). Built artefacts (AAR, XCFramework) are scanned in
#      .github/workflows/release-scan.yml and before every release.
#
# Usage:
#   scripts/check_sdk_boundaries.sh [--only android|ios|flutter|rn] [--skip-size] [--update]
#
#   --update     rewrite the API snapshots instead of comparing (then review the diff)
#   --skip-size  skip the size checks (they build release artifacts)
#
# Gradle and the size builds are heavy: on a shared machine set HEAVY=/path/to/lock-wrapper.sh to
# run them through a lock (e.g. HEAVY=$TMPDIR/heavy.sh). iOS checks need macOS + Xcode command-line
# tools; they're skipped elsewhere. Flutter: FLUTTER=<flutter binary> (default: flutter on PATH or
# ~/fvm/versions/3.35.4/bin/flutter). React Native: needs `npm ci` in react-native/ (done here if
# node_modules is missing).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ONLY=""
SIZE=1
UPDATE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --only) ONLY="$2"; shift 2 ;;
    --skip-size) SIZE=0; shift ;;
    --update) UPDATE=1; shift ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
HEAVY="${HEAVY:-}"
heavy() { if [ -n "$HEAVY" ]; then "$HEAVY" "$@"; else "$@"; fi; }
want() { [ -z "$ONLY" ] || [ "$ONLY" = "$1" ]; }
failures=()
step() {
  local name="$1"; shift
  echo
  echo "=== $name"
  if "$@"; then echo "--- ok: $name"; else echo "--- FAILED: $name"; failures+=("$name"); fi
}

# ------------------------------------------------------------------ Change 12
providers_check() { python3 "$ROOT/scripts/generate_providers.py" --check; }
share_targets_check() { python3 "$ROOT/scripts/generate_share_targets.py" --check; }
no_identify_check() { python3 "$ROOT/scripts/check_no_identify.py"; }
scan() { python3 "$ROOT/scripts/scan_release_packages.py" "$@"; }

# ------------------------------------------------------------------ Android
android_api() {
  cd "$ROOT/android"
  if [ $UPDATE = 1 ]; then
    heavy ./gradlew apiDump -q --console=plain
  else
    # apiCheck: BCV snapshots (clikgate/api/clikgate.api, clikgate-engage/api/clikgate-engage.api).
    # CoreBoundaryTest: forbidden names in the core snapshot, no com.clikgate.engage class on core's classpath.
    # checkNoEngageDependency: no core configuration / source references clikgate-engage.
    heavy ./gradlew apiCheck :clikgate:checkNoEngageDependency \
      :clikgate:testDebugUnitTest --tests com.clikgate.CoreBoundaryTest -q --console=plain
  fi
}
android_size() { cd "$ROOT/android" && heavy ./scripts/check_size.sh; }
android_stop() { cd "$ROOT/android" && ./gradlew --stop >/dev/null 2>&1 || true; }

# ------------------------------------------------------------------ iOS
ios_api() { "$ROOT/ios/scripts/check_api.sh" $([ $UPDATE = 1 ] && echo --update); }
ios_size() { heavy "$ROOT/ios/scripts/check_size.sh"; }

# ------------------------------------------------------------------ Flutter
flutter_api() { "$ROOT/flutter/tool/check_api.sh" $([ $UPDATE = 1 ] && echo --update); }

# ------------------------------------------------------------------ React Native
rn_api() {
  local upd=0
  [ $UPDATE = 1 ] && upd=1
  (cd "$ROOT/react-native" && { [ -d node_modules ] || npm ci --no-audit --no-fund; } \
    && UPDATE_API_SNAPSHOT=$upd npx jest publicApi --ci) &&
  (cd "$ROOT/react-native-engage" && npm run -s devlink && UPDATE_API_SNAPSHOT=$upd npx jest publicApi --ci)
}

[ $UPDATE = 1 ] || step "providers: generated Provider types match shared/providers.json" providers_check
[ $UPDATE = 1 ] || step "share targets: generated ShareApp and share tables match shared/share_targets.json" share_targets_check
[ $UPDATE = 1 ] || step "docs: no identify() left (identifyUser() replaced it)" no_identify_check
if want android; then
  step "android: API snapshots + no Engage in core + dependency check" android_api
  [ $SIZE = 1 ] && [ $UPDATE = 0 ] && step "android: size budgets" android_size
  android_stop
fi
if want ios; then
  if [ "$(uname)" = Darwin ] && command -v xcrun >/dev/null; then
    step "ios: API snapshots + no Engage in core + dependency check" ios_api
    [ $SIZE = 1 ] && [ $UPDATE = 0 ] && step "ios: size budgets" ios_size
    [ $UPDATE = 0 ] && step "ios: release scan (CocoaPods source zip and SPM mirror files)" scan --pod "$ROOT/ios" --spm
  else
    echo "=== ios: skipped (needs macOS + Xcode)"
  fi
fi
if want flutter; then
  step "flutter: API snapshots + no Engage in core + dependency check" flutter_api
  [ $UPDATE = 0 ] && step "flutter: release scan (pub packages)" scan --pub "$ROOT/flutter" --pub "$ROOT/flutter_engage"
fi
if want rn; then
  step "react-native: API snapshots + no Engage in core + dependency check" rn_api
  [ $UPDATE = 0 ] && step "react-native: release scan (npm pack)" scan --npm "$ROOT/react-native" --npm "$ROOT/react-native-engage"
fi

echo
if [ ${#failures[@]} -gt 0 ]; then
  printf 'Boundary checks FAILED:\n'; printf '  - %s\n' "${failures[@]}"
  exit 1
fi
echo "All SDK boundary checks passed."
