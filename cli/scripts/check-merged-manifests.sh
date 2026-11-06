#!/bin/sh
# After `assembleDebug assembleRelease` (or flutter build apk --debug/--release): the merged
# debug manifest must have a verified filter for the test domain and the live domains; the
# merged release manifest must have the live domains and never the test domain.
# Usage: check-merged-manifests.sh <app-module-build-dir> <live-host>[,<live-host>] [test-host]
# (Flutter puts the module's build dir at <project>/build/app.)
set -eu
build=$1
live=$2
test=${3:-dev.ciz.to}
find_manifest() {
  # AGP writes intermediates/merged_manifests/<variant>/... or merged_manifest/<variant>/...
  find "$build/intermediates" -path "*merged_manifest*" -path "*$1*" -name AndroidManifest.xml | grep -iv "test" | head -n 1
}
debug=$(find_manifest debug)
release=$(find_manifest release)
[ -n "$debug" ] || { echo "no merged debug manifest under $build"; exit 1; }
[ -n "$release" ] || { echo "no merged release manifest under $build"; exit 1; }
status=0
for h in $(echo "$live" | tr ',' ' '); do
  grep -q "android:host=\"$h\"" "$debug" || { echo "✗ debug misses $h"; status=1; }
  grep -q "android:host=\"$h\"" "$release" || { echo "✗ release misses $h"; status=1; }
done
grep -q "android:host=\"$test\"" "$debug" || { echo "✗ debug misses $test"; status=1; }
if grep -q "android:host=\"$test\"" "$release"; then echo "✗ release has $test"; status=1; fi
grep -q 'android:autoVerify="true"' "$release" || { echo "✗ release has no autoVerify filter"; status=1; }
[ $status -eq 0 ] && echo "✓ merged manifests: $live in debug and release; $test in debug only ($debug, $release)"
exit $status
