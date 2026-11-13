#!/usr/bin/env bash
# Size budgets (spec 0.4): core Android < 150 KB, Engage Android < 44 KB (40 KB until Change 13 share.link; see DECISIONS.md).
#
# Builds the release AAR (unminified, as published; since 2.1.0 one artifact with the Engage features under
# com.clikgate.engage) and reports, for the core classes and the Engage classes separately:
#   jar      the part's classes, zipped (as in the AAR's classes.jar)
#   classes  sum of the uncompressed .class files
#   d8       DEX of the library's own classes, no shrinking (d8 --release --min-api 21)
#   r8       DEX after R8 with the whole public API kept (what an app that calls every public
#            method ships; apps shrink with R8, so this is the app-size contribution). Kotlin
#            @Metadata annotations are not kept: R8 drops them in apps unless kotlin.Metadata is
#            kept explicitly (AGP's default rules don't), and they'd be ~1/3 of the Engage number.
# The budget is enforced on the R8 number (see android/DECISIONS.md "Engage split" / Size).
#
# Usage: android/scripts/check_size.sh [--no-build]
# Env: ANDROID_HOME / ANDROID_SDK_ROOT (else local.properties sdk.dir), BUILD_TOOLS (version dir).
set -euo pipefail
cd "$(dirname "$0")/.."

CORE_BUDGET_KB=150
ENGAGE_BUDGET_KB=44

if [ "${1:-}" != "--no-build" ]; then
  ./gradlew :clikgate:assembleRelease -q --console=plain
fi

SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
if [ -z "$SDK" ] && [ -f local.properties ]; then SDK="$(grep '^sdk.dir=' local.properties | cut -d= -f2-)"; fi
[ -n "$SDK" ] || { echo "Android SDK not found (set ANDROID_HOME)"; exit 2; }
BT="$SDK/build-tools/${BUILD_TOOLS:-$(ls "$SDK/build-tools" | sort -V | tail -1)}"
D8JAR="$BT/lib/d8.jar"
ANDROID_JAR="$(ls -d "$SDK"/platforms/android-* | sort -V | tail -1)/android.jar"
[ -f "$D8JAR" ] || { echo "d8.jar not found in $BT"; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

kb() { awk "BEGIN { printf \"%.1f\", $1 / 1024 }"; }

measure() { # name classes-jar keep-package classpath-jar consumer-rules
  local name="$1" src="$2" pkg="$3" cp="${4:-}"
  local dir="$WORK/$name"
  mkdir -p "$dir/x" "$dir/d8" "$dir/r8"
  cp "$src" "$dir/classes.jar"
  local jar=$(stat -f%z "$dir/classes.jar" 2>/dev/null || stat -c%s "$dir/classes.jar")
  (cd "$dir/x" && unzip -q -o ../classes.jar)
  local classes=$(find "$dir/x" -name '*.class' -exec cat {} + | wc -c | tr -d ' ')
  local cparg=()
  [ -n "$cp" ] && cparg=(--classpath "$cp")
  java -cp "$D8JAR" com.android.tools.r8.D8 --release --min-api 21 --lib "$ANDROID_JAR" ${cparg[@]+"${cparg[@]}"} \
    --output "$dir/d8" "$dir/classes.jar" 2>/dev/null
  local d8=$(stat -f%z "$dir/d8/classes.dex" 2>/dev/null || stat -c%s "$dir/d8/classes.dex")
  cat > "$dir/keep.pro" <<PRO
-keep public class $pkg.* { public protected *; }
-keepattributes Signature,InnerClasses,EnclosingMethod
-dontwarn **
-ignorewarnings
PRO
  java -cp "$D8JAR" com.android.tools.r8.R8 --release --min-api 21 --dex --lib "$ANDROID_JAR" ${cparg[@]+"${cparg[@]}"} \
    --pg-conf "$dir/keep.pro" --pg-conf "$5" --output "$dir/r8" "$dir/classes.jar" 2>/dev/null
  local r8=$(stat -f%z "$dir/r8/classes.dex" 2>/dev/null || stat -c%s "$dir/r8/classes.dex")
  printf "%-8s jar %7s KB | classes %7s KB | d8 %7s KB | r8 (public API kept) %7s KB\n" \
    "$name" "$(kb "$jar")" "$(kb "$classes")" "$(kb "$d8")" "$(kb "$r8")"
  echo "$r8" > "$WORK/$name.r8"
}

AAR=clikgate/build/outputs/aar/clikgate-release.aar
# Split the one classes.jar: core = everything outside com/clikgate/engage, Engage = that package.
mkdir -p "$WORK/all" "$WORK/split"
unzip -q -o "$AAR" classes.jar -d "$WORK/split"
(cd "$WORK/all" && unzip -q -o ../split/classes.jar)
(cd "$WORK/all" && find . -type f ! -path './com/clikgate/engage/*' | sed 's#^\./##' | zip -q -@ "$WORK/split/core.jar")
(cd "$WORK/all" && find ./com/clikgate/engage -type f | sed 's#^\./##' | zip -q -@ "$WORK/split/engage.jar")
printf -- '-dontwarn **\n' > "$WORK/engage-rules.pro"
measure core "$WORK/split/core.jar" com.clikgate "" clikgate/consumer-rules.pro
measure engage "$WORK/split/engage.jar" com.clikgate.engage "$WORK/split/core.jar" "$WORK/engage-rules.pro"

fail=0
core_kb=$(( $(cat "$WORK/core.r8") / 1024 ))
engage_kb=$(( $(cat "$WORK/engage.r8") / 1024 ))
[ "$core_kb" -lt "$CORE_BUDGET_KB" ] || { echo "FAIL: core R8 dex ${core_kb} KB >= ${CORE_BUDGET_KB} KB"; fail=1; }
[ "$engage_kb" -lt "$ENGAGE_BUDGET_KB" ] || { echo "FAIL: engage R8 dex ${engage_kb} KB >= ${ENGAGE_BUDGET_KB} KB"; fail=1; }
[ $fail -eq 0 ] && echo "Size budgets OK (core < ${CORE_BUDGET_KB} KB, engage < ${ENGAGE_BUDGET_KB} KB, R8 dex with public API kept)"
exit $fail
