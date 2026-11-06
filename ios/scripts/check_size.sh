#!/usr/bin/env bash
# Size budgets of the iOS SDK (spec 0.4): core < 410 KB, Engage < 95 KB (80 KB until Change 13 share.link; see DECISIONS.md).
#
#   ios/scripts/check_size.sh
#
# Method (no Xcode project, no simulator): each module is compiled for arm64 iOS 13 the way it
# ships in release builds (whole-module, `-Osize` as the podspec's Release config and the
# XCFramework script use; `-O` reported for information) into one object file. The figure is the
# sum of that object's sections that end up in an app binary: everything except zero-fill
# (__bss/__common, no file size), __LD,__compact_unwind (the linker turns it into the much smaller
# __unwind_info) and the __LLVM marker. No dead stripping is applied, so it is the contribution
# with *every* public API in use (an app that uses less links less).
set -euo pipefail

IOS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/clikgate-size.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
SDK="$(xcrun -sdk iphoneos --show-sdk-path)"
TARGET="arm64-apple-ios13.0"
CORE_BUDGET=$((410 * 1024))
ENGAGE_BUDGET=$((95 * 1024))

linked_bytes() { # $1 = object file
  size -m "$1" | awk '/Section/ && !/zerofill/ && !/__LD, __compact_unwind/ && !/__LLVM/ && !/__DWARF/ { gsub(/[():,]/, " "); s += $NF } END { print s + 0 }'
}

build() { # $1 = opt flag; sets CORE / ENGAGE
  local dir="$WORK/$1"
  mkdir -p "$dir"
  xcrun swiftc -sdk "$SDK" -target "$TARGET" -module-name Clikgate -parse-as-library -wmo "$1" -c \
    -emit-module -emit-module-path "$dir/Clikgate.swiftmodule" -o "$dir/Clikgate.o" \
    $(find "$IOS_DIR/Sources/Clikgate" -name '*.swift' | sort)
  xcrun swiftc -sdk "$SDK" -target "$TARGET" -module-name ClikgateEngage -parse-as-library -wmo "$1" -c \
    -I "$dir" -o "$dir/ClikgateEngage.o" $(find "$IOS_DIR/Sources/ClikgateEngage" -name '*.swift' | sort)
  CORE=$(linked_bytes "$dir/Clikgate.o")
  ENGAGE=$(linked_bytes "$dir/ClikgateEngage.o")
}

kb() { awk -v b="$1" 'BEGIN { printf "%.1f KB", b / 1024 }'; }

build -O
echo "-O     (info):   core $(kb "$CORE"), Engage $(kb "$ENGAGE")"
build -Osize
echo "-Osize (budget): core $(kb "$CORE") (< 410 KB), Engage $(kb "$ENGAGE") (< 95 KB)"

fail=0
[ "$CORE" -lt "$CORE_BUDGET" ] || { echo "error: core iOS SDK is $(kb "$CORE"), budget 410 KB (a hard ceiling: trim, do not raise it; see DECISIONS)" >&2; fail=1; }
[ "$ENGAGE" -lt "$ENGAGE_BUDGET" ] || { echo "error: ClikgateEngage is $(kb "$ENGAGE"), budget 95 KB" >&2; fail=1; }
[ -z "${GITHUB_STEP_SUMMARY:-}" ] || echo "iOS sizes (-Osize, arm64): core $(kb "$CORE"), Engage $(kb "$ENGAGE")" >> "$GITHUB_STEP_SUMMARY"
exit $fail
