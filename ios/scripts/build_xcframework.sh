#!/usr/bin/env bash
# Builds Clikgate.xcframework (core) and ClikgateEngage.xcframework (optional Engage add-on,
# spec 17A.1) — static, library evolution enabled — from the Swift package.
#
#   ios/scripts/build_xcframework.sh [output-dir]      # default: ios/build/xcframework
#
# Steps per module: `xcodebuild archive` its package scheme for iOS devices and the simulator
# with BUILD_LIBRARY_FOR_DISTRIBUTION=YES, wrap the module's own object file + .swiftinterface
# into a static <Module>.framework, then `xcodebuild -create-xcframework`. The core framework
# carries PrivacyInfo.xcprivacy. ClikgateEngage.framework contains only Engage's code (the
# ClikgateEngage scheme also compiles the core, whose object is not copied): apps link both
# XCFrameworks, and installing the core alone never brings Engage in.
# Each module and its main type share a name (`Clikgate`, `ClikgateEngage`);
# `-alias-module-names-in-module-interface` keeps the emitted .swiftinterface files buildable
# (swiftlang/swift#56573).
# Outputs: Clikgate.xcframework, ClikgateEngage.xcframework, a zip + SwiftPM checksum of each
# (Clikgate-<version>.xcframework.zip, ClikgateEngage-<engage version>.xcframework.zip).
# Prints the size of each device binary (arm64 slice) at the end.
set -euo pipefail

IOS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$IOS_DIR/build/xcframework}"
WORK="$OUT/work"
DERIVED="$WORK/DerivedData"
VERSION="$(sed -n 's/.*sdkVersion = "\(.*\)".*/\1/p' "$IOS_DIR/Sources/Clikgate/Public/Clikgate.swift" | head -1)"
ENGAGE_VERSION="$(sed -n 's/.*static var version: String { "\(.*\)" }.*/\1/p' "$IOS_DIR/Sources/ClikgateEngage/ClikgateEngage.swift" | head -1)"
[ -n "$VERSION" ] && [ -n "$ENGAGE_VERSION" ] || { echo "could not read the core / Engage versions" >&2; exit 1; }

rm -rf "$OUT"
mkdir -p "$WORK"

archive() { # $1 = scheme, $2 = destination, $3 = archive name
  local scheme="$1"; shift
  xcodebuild archive \
    -scheme "$scheme" \
    -destination "$1" \
    -archivePath "$WORK/$2.xcarchive" \
    -derivedDataPath "$DERIVED/$2" \
    -configuration Release \
    SKIP_INSTALL=NO \
    SWIFT_OPTIMIZATION_LEVEL=-Osize \
    DEAD_CODE_STRIPPING=YES \
    BUILD_LIBRARY_FOR_DISTRIBUTION=YES \
    SWIFT_SERIALIZE_DEBUGGING_OPTIONS=NO \
    OTHER_SWIFT_FLAGS="-Xfrontend -alias-module-names-in-module-interface" \
    -quiet
}

make_framework() { # $1 = module, $2 = archive name, $3 = platform dir (Release-iphoneos / -iphonesimulator), $4 = version
  local name="$1" arch="$2" platform="$3" version="$4"
  local fw="$WORK/$arch/$name.framework"
  local obj
  obj="$(find "$WORK/$arch.xcarchive" -name "$name.o" | head -1)"
  [ -n "$obj" ] || { echo "$name.o not found in $arch archive" >&2; exit 1; }
  local module
  module="$(find "$DERIVED/$arch/Build/Intermediates.noindex/ArchiveIntermediates/$name/BuildProductsPath/$platform" -maxdepth 1 -name "$name.swiftmodule" -type d | head -1)"
  [ -n "$module" ] || { echo "$name.swiftmodule not found for $platform" >&2; exit 1; }

  mkdir -p "$fw/Modules"
  libtool -static -o "$fw/$name" "$obj"
  # No debug info in what ships: it carries the build machine's source paths (release scan,
  # scripts/scan_release_packages.py). The symbol table stays, so crash reports still symbolicate.
  strip -S "$fw/$name"
  cp -R "$module" "$fw/Modules/"
  # Only the textual interfaces are needed with library evolution; drop compiled modules, and the
  # API digester's .abi.json / source info, which list the build machine's source paths.
  find "$fw/Modules/$name.swiftmodule" \( -name '*.swiftmodule' -o -name '*.abi.json' -o -name '*.swiftsourceinfo' \) -type f -delete
  if [ "$name" = Clikgate ]; then
    cp "$IOS_DIR/Sources/Clikgate/Resources/PrivacyInfo.xcprivacy" "$fw/PrivacyInfo.xcprivacy"
  fi
  local bundle_id="com.clikgate.sdk"
  [ "$name" = Clikgate ] || bundle_id="com.clikgate.engage"
  cat > "$fw/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>${name}</string>
  <key>CFBundleIdentifier</key><string>${bundle_id}</string>
  <key>CFBundleName</key><string>${name}</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleShortVersionString</key><string>${version}</string>
  <key>CFBundleVersion</key><string>${version}</string>
  <key>MinimumOSVersion</key><string>13.0</string>
</dict>
</plist>
PLIST
}

build_module() { # $1 = module (= package scheme), $2 = version
  local name="$1" version="$2"
  echo "==> $name: archiving for iOS devices"
  archive "$name" "generic/platform=iOS" "$name-ios"
  echo "==> $name: archiving for iOS Simulator"
  archive "$name" "generic/platform=iOS Simulator" "$name-ios-simulator"

  make_framework "$name" "$name-ios" Release-iphoneos "$version"
  make_framework "$name" "$name-ios-simulator" Release-iphonesimulator "$version"

  echo "==> $name: creating XCFramework"
  xcodebuild -create-xcframework \
    -framework "$WORK/$name-ios/$name.framework" \
    -framework "$WORK/$name-ios-simulator/$name.framework" \
    -output "$OUT/$name.xcframework"

  (cd "$OUT" && zip -qry "$name-${version}.xcframework.zip" "$name.xcframework")
  swift package compute-checksum "$OUT/$name-${version}.xcframework.zip" > "$OUT/$name-${version}.xcframework.zip.sha256" 2>/dev/null || true
}

report_size() { # $1 = module
  local bin="$OUT/$1.xcframework/ios-arm64/$1.framework/$1"
  [ -f "$bin" ] || return 0
  echo "$1 device static library (arm64): $(stat -f%z "$bin") bytes"
  local stripped="$WORK/$1.stripped"
  cp "$bin" "$stripped" && strip -S -x "$stripped" 2>/dev/null || true
  echo "$1 device static library without debug symbols: $(stat -f%z "$stripped") bytes"
  echo "$1 text+data linked into an app:"
  size -m "$bin" | awk '/Section __text|Section __const|Section __data|Section __cstring/ {print "  " $0}' | head -8 || true
}

build_module Clikgate "$VERSION"
build_module ClikgateEngage "$ENGAGE_VERSION"

echo "==> Done: $OUT/Clikgate.xcframework, $OUT/ClikgateEngage.xcframework"
report_size Clikgate
report_size ClikgateEngage
rm -rf "$WORK/DerivedData"
