#!/bin/sh
# Flutter boundary checks (spec 20): public-API snapshots of clikgate_flutter (core) and of its Engage
# features (lib/engage.dart, one package since 2.1.0), "core has no Engage API" and "core code never uses
# Engage". No device, no build.
#   flutter/tool/check_api.sh            check
#   flutter/tool/check_api.sh --update   rewrite test/api_snapshot.txt and test/engage_api_snapshot.txt
# FLUTTER (env) overrides the flutter binary (default: flutter on PATH, else ~/fvm/versions/3.35.4).
set -eu
here="$(cd "$(dirname "$0")/.." && pwd)"
FLUTTER="${FLUTTER:-$(command -v flutter || echo "$HOME/fvm/versions/3.35.4/bin/flutter")}"
if [ "${1:-}" = "--update" ]; then export UPDATE_API_SNAPSHOT=1; fi

echo "== clikgate_flutter: API snapshots (core + Engage)"
(cd "$here" && "$FLUTTER" pub get >/dev/null && "$FLUTTER" test --reporter=compact test/api_snapshot_test.dart test/engage_api_snapshot_test.dart)
echo "Flutter API checks passed."
