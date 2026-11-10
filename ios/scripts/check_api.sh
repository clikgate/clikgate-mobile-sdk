#!/usr/bin/env bash
# Public-API snapshot and core/Engage boundary checks for the iOS SDK (spec 0.4, section 20).
#
#   ios/scripts/check_api.sh            # compare with ios/api/*.api.txt, fail on any difference
#   ios/scripts/check_api.sh --update   # rewrite the snapshots
#
# How: compiles the `Clikgate` and `ClikgateEngage` modules for arm64 iOS with `swiftc
# -emit-module` (no Xcode project, no simulator), extracts their symbol graphs with
# `swift-symbolgraph-extract -minimum-access-level public -include-spi-symbols`, and prints one
# line per public declaration (`[spi] ` prefix for @_spi declarations). Then:
#   1. the listings must equal the checked-in snapshots;
#   2. the core listing must not contain Engage features (leaderboards, referral stats, link
#      creation, codes, share helpers, identity signals). The only allowed hits are the feature-key
#      constants `ClikgateFeatures.leaderboards` / `.whatsappAttribution` (string keys for
#      isFeatureEnabled; `whatsapp_attribution` is a server-side attribution feature);
#   3. core never depends on Engage: Package.swift's Clikgate target has no dependencies,
#      Sources/Clikgate never imports ClikgateEngage, and the podspec's default subspec is Core,
#      which doesn't depend on Engage.
set -euo pipefail

IOS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
UPDATE=0
[ "${1:-}" = "--update" ] && UPDATE=1
WORK="$(mktemp -d "${TMPDIR:-/tmp}/clikgate-api.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

SDK="$(xcrun -sdk iphoneos --show-sdk-path)"
TARGET="arm64-apple-ios13.0"
fail=0

echo "==> Emitting modules"
xcrun swiftc -sdk "$SDK" -target "$TARGET" -module-name Clikgate -parse-as-library \
  -emit-module -emit-module-path "$WORK/Clikgate.swiftmodule" $(find "$IOS_DIR/Sources/Clikgate" -name '*.swift' | sort)
xcrun swiftc -sdk "$SDK" -target "$TARGET" -module-name ClikgateEngage -parse-as-library -I "$WORK" \
  -emit-module -emit-module-path "$WORK/ClikgateEngage.swiftmodule" $(find "$IOS_DIR/Sources/ClikgateEngage" -name '*.swift' | sort)

listing() { # $1 = module
  local out="$WORK/sg-$1"
  mkdir -p "$out"
  xcrun swift-symbolgraph-extract -module-name "$1" -target "$TARGET" -sdk "$SDK" -I "$WORK" \
    -output-dir "$out" -minimum-access-level public -include-spi-symbols >/dev/null
  python3 - "$out" <<'PY'
import json, os, sys
lines = set()
d = sys.argv[1]
for f in sorted(os.listdir(d)):
    g = json.load(open(os.path.join(d, f)))
    for s in g.get("symbols", []):
        if s.get("accessLevel") not in ("public", "open"):
            continue
        decl = "".join(x["spelling"] for x in s.get("declarationFragments", []))
        path = ".".join(s.get("pathComponents", []))
        ext = f.split("@")[1].split(".")[0] + " " if "@" in f else ""
        decl = " ".join(decl.split())
        # Newer Swift (Xcode 26.4+) prints a main-actor function type as "@MainActor @Sendable";
        # it was already Sendable (SE-0434), so both spellings are the same API. Any other
        # @Sendable still shows up.
        decl = decl.replace("@MainActor @Sendable ", "@MainActor ")
        lines.add(("[spi] " if s.get("spi") else "") + ext + path + ": " + decl)
print("\n".join(sorted(lines)))
PY
}

check_snapshot() { # $1 = module
  local snap="$IOS_DIR/api/$1.api.txt" cur="$WORK/$1.api.txt"
  listing "$1" > "$cur"
  if [ "$UPDATE" = 1 ]; then
    cp "$cur" "$snap"; echo "updated $snap ($(wc -l < "$snap" | tr -d ' ') declarations)"
  elif ! diff -u "$snap" "$cur"; then
    echo "error: the public API of $1 changed. Review the diff and run ios/scripts/check_api.sh --update" >&2
    fail=1
  else
    echo "$1: public API matches the snapshot ($(wc -l < "$cur" | tr -d ' ') declarations)"
  fi
}

check_snapshot Clikgate
check_snapshot ClikgateEngage

echo "==> Core boundary"
FORBIDDEN='leaderboard|createLink|myStats|ReferralLink|ReferralStats|redeem|Redemption|RedeemedCode|share(?!d)|whatsapp|identitySignal|identity_signal|MyRank|hostedPage'
hits="$(python3 - "$WORK/Clikgate.api.txt" "$FORBIDDEN" <<'PY'
import re, sys
pat = re.compile(sys.argv[2], re.I)
allowed = re.compile(r'^ClikgateFeatures\.(leaderboards|whatsappAttribution): static let \w+: String$')
for line in open(sys.argv[1]):
    line = line.rstrip("\n")
    if pat.search(line) and not allowed.match(line):
        print(line)
PY
)"
if [ -n "$hits" ]; then
  echo "error: the core SDK's public API contains Engage features (spec 0.4):" >&2
  echo "$hits" >&2
  fail=1
else
  echo "core public API has no leaderboard / referral-stats / link-creation / code / share / identity-signal API"
fi

if grep -rnE '^\s*(@[_A-Za-z()]+\s+)*import\s+ClikgateEngage' "$IOS_DIR/Sources/Clikgate"; then
  echo "error: Sources/Clikgate imports ClikgateEngage" >&2; fail=1
fi
python3 - "$IOS_DIR/Package.swift" "$IOS_DIR/Clikgate.podspec" <<'PY' || fail=1
import re, sys
pkg = open(sys.argv[1]).read()
m = re.search(r'\.target\(\s*name:\s*"Clikgate"(.*?)\n\s*\),', pkg, re.S)
if not m or "dependencies" in m.group(1):
    sys.exit("error: Package.swift: the Clikgate target must have no dependencies")
pod = open(sys.argv[2]).read()
if not re.search(r"s\.default_subspecs?\s*=\s*\[?\s*'Core'\s*\]?\s*$", pod, re.M):
    sys.exit("error: Clikgate.podspec: the default subspec must be 'Core' only")
core = re.search(r"s\.subspec 'Core' do \|(\w+)\|(.*?)\n  end", pod, re.S)
if not core or "Engage" in core.group(2):
    sys.exit("error: Clikgate.podspec: the Core subspec must not reference Engage")
print("dependency check: core never depends on Engage (Package.swift, podspec, imports)")
PY

exit $fail
