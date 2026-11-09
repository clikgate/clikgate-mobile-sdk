#!/bin/sh
# After `assembleDebug assembleRelease` (or flutter build apk --debug/--release): every merged
# debug manifest must have a verified filter for the test domain and the live domains; every
# merged release manifest must have the live domains and never the test domain. With product
# flavours there is one of each per flavour (freeDebug, paidRelease, ...): all are checked.
# Usage: check-merged-manifests.sh <app-module-build-dir> <live-host>[,<live-host>] [test-host]
# (Flutter puts the module's build dir at <project>/build/app.)
set -eu
build=$1
live=$2
test=${3:-dev.ciz.to}
find_manifests() {
  # AGP writes intermediates/merged_manifests/<variant>/... or merged_manifest/<variant>/...;
  # the variant name may carry a flavour prefix (freeDebug), hence the case-insensitive match.
  find "$build/intermediates" -path "*merged_manifest*" -ipath "*$1*" -name AndroidManifest.xml | grep -iv "test" | sort
}
debugs=$(find_manifests debug)
releases=$(find_manifests release)
[ -n "$debugs" ] || { echo "no merged debug manifest under $build"; exit 1; }
[ -n "$releases" ] || { echo "no merged release manifest under $build"; exit 1; }
status=0
for debug in $debugs; do
  for h in $(echo "$live" | tr ',' ' '); do
    grep -q "android:host=\"$h\"" "$debug" || { echo "✗ $debug misses $h"; status=1; }
  done
  grep -q "android:host=\"$test\"" "$debug" || { echo "✗ $debug misses $test"; status=1; }
done
for release in $releases; do
  for h in $(echo "$live" | tr ',' ' '); do
    grep -q "android:host=\"$h\"" "$release" || { echo "✗ $release misses $h"; status=1; }
  done
  if grep -q "android:host=\"$test\"" "$release"; then echo "✗ $release has $test"; status=1; fi
  grep -q 'android:autoVerify="true"' "$release" || { echo "✗ $release has no autoVerify filter"; status=1; }
done
[ $status -eq 0 ] && echo "✓ merged manifests: $live in debug and release; $test in debug only ($(echo $debugs $releases | wc -w | tr -d ' ') manifests)"
exit $status
