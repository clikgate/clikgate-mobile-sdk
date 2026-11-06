#!/bin/sh
# Flutter boundary checks (spec 20): public-API snapshots of clikgate_flutter and clikgate_engage,
# "core has no Engage API" and "core never depends on Engage". No device, no build.
#   flutter/tool/check_api.sh            check
#   flutter/tool/check_api.sh --update   rewrite both test/api_snapshot.txt files
# FLUTTER (env) overrides the flutter binary (default: flutter on PATH, else ~/fvm/versions/3.35.4).
set -eu
here="$(cd "$(dirname "$0")/.." && pwd)"
root="$(cd "$here/.." && pwd)"
FLUTTER="${FLUTTER:-$(command -v flutter || echo "$HOME/fvm/versions/3.35.4/bin/flutter")}"
if [ "${1:-}" = "--update" ]; then export UPDATE_API_SNAPSHOT=1; fi

for pkg in "$here" "$root/flutter_engage"; do
  echo "== $(basename "$pkg"): API snapshot"
  (cd "$pkg" && "$FLUTTER" pub get >/dev/null && "$FLUTTER" test --reporter=compact test/api_snapshot_test.dart)
done
echo "Flutter API checks passed."
