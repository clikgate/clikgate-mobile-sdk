#!/usr/bin/env bash
# Builds the setup command (cli/, the same code as `npx @clikgate/setup`) as self-contained executables
# for `dart run clikgate_flutter:setup` (Flutter developers don't need Node.js). One codebase: the cli's
# own bundle (cli/dist/cli.cjs, built with tsup) is compiled with Bun's --compile, which embeds the Bun
# runtime. Nothing is installed globally: Bun runs through `npx --yes bun@<BUN_VERSION>`.
#
#   scripts/build_setup_binaries.sh                          all five platforms
#   scripts/build_setup_binaries.sh --only darwin-arm64      one platform (quick local check)
#
# Writes
#   cli/dist/bin/clikgate-setup-<version>-<os>-<arch>[.exe]      the binary (version = cli/package.json)
#   cli/dist/bin/clikgate-setup-<version>-<os>-<arch>[.exe].gz   the release asset (gzip -9n: no name or
#                                                                time stamp, so the same binary gives the same .gz)
#   cli/dist/bin/SHA256SUMS                                        (sha256sum format, binaries and .gz files)
#   flutter/lib/src/setup_runner/setup_binaries.g.dart             (version + both sha256 per platform)
#
# The Dart file is what the pub package verifies downloads against (the .gz, then the unpacked binary), so the
# release order is: build → GitHub release `setup-v<version>` with the .gz files and SHA256SUMS →
# `flutter pub publish` (docs/RELEASING.md).
# Builds are reproducible (same inputs and Bun version → same bytes), but upload exactly the files whose
# hashes are in the Dart file. `npm run build` in cli/ cleans cli/dist (tsup clean), which removes
# cli/dist/bin too; this script keeps it. scripts/check_cli_sdk_versions.mjs checks the Dart file
# against the CLI version and, when the binaries are present, against their hashes.
#
# Needs Node 18+ and the cli's devDependencies (`cd cli && npm ci`). Builds run one at a time (shared
# 16 GB machine); each target's Bun runtime is downloaded once and cached by Bun.
set -euo pipefail

# Pinned: a released Bun at least two weeks older than the build. Changing it changes every binary.
BUN_VERSION=1.4.4

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLI="$ROOT/cli"
OUT="$CLI/dist/bin"
GEN="$ROOT/flutter/lib/src/setup_runner/setup_binaries.g.dart"
# <asset platform>:<bun target>. x64 targets use Bun's "baseline" build (no AVX2 needed: older Intel
# Macs, VMs and CI runners). Linux builds are glibc (not Alpine/musl).
ALL_TARGETS="darwin-arm64:bun-darwin-arm64 darwin-x64:bun-darwin-x64-baseline linux-x64:bun-linux-x64-baseline linux-arm64:bun-linux-arm64 windows-x64:bun-windows-x64-baseline"

ONLY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --only) ONLY="$2"; shift 2 ;;
    -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

VERSION="$(node -p "require('$CLI/package.json').version")"
[ -d "$CLI/node_modules" ] || { echo "cli/node_modules is missing: run \`cd cli && npm ci\` first." >&2; exit 1; }

echo "== cli: build dist/cli.cjs ($VERSION)"
# tsup cleans cli/dist; keep binaries built earlier (an --only build adds to them).
STASH="$(mktemp -d)"
[ -d "$OUT" ] && mv "$OUT" "$STASH/bin"
(cd "$CLI" && npm run --silent build >/dev/null) || { [ -d "$STASH/bin" ] && mkdir -p "$CLI/dist" && mv "$STASH/bin" "$OUT"; exit 1; }
[ -d "$STASH/bin" ] && mv "$STASH/bin" "$OUT"
rmdir "$STASH" 2>/dev/null || true
mkdir -p "$OUT" "$(dirname "$GEN")"

sha256() { shasum -a 256 "$1" 2>/dev/null | cut -d' ' -f1 || sha256sum "$1" | cut -d' ' -f1; }

built=0
for t in $ALL_TARGETS; do
  platform="${t%%:*}"; target="${t#*:}"
  if [ -n "$ONLY" ] && [ "$ONLY" != "$platform" ]; then continue; fi
  ext=""; case "$platform" in windows-*) ext=".exe" ;; esac
  asset="clikgate-setup-$VERSION-$platform$ext"
  echo "== bun $BUN_VERSION: $asset ($target)"
  (cd "$CLI" && npx --yes "bun@$BUN_VERSION" build --compile --target="$target" dist/cli.cjs --outfile "$OUT/$asset" >/dev/null)
  # Apple silicon only runs signed code. Bun ad-hoc signs darwin outputs; sign again on a Mac if not.
  case "$platform" in darwin-*)
    if command -v codesign >/dev/null && ! codesign -v "$OUT/$asset" 2>/dev/null; then
      codesign --sign - --force "$OUT/$asset"
    fi ;;
  esac
  gzip -9n -c "$OUT/$asset" > "$OUT/$asset.gz"
  built=$((built + 1))
done
[ "$built" -gt 0 ] || { echo "no target matches --only $ONLY (have: darwin-arm64 darwin-x64 linux-x64 linux-arm64 windows-x64)" >&2; exit 2; }

# SHA256SUMS lists every binary and .gz of this version in cli/dist/bin (earlier --only builds included).
(
  cd "$OUT"
  rm -f SHA256SUMS
  for f in clikgate-setup-"$VERSION"-*; do
    [ -f "$f" ] && printf '%s  %s\n' "$(sha256 "$f")" "$f"
  done > SHA256SUMS
)

# Generated Dart: version + sha256 per platform (binary and .gz), read from SHA256SUMS.
dart_map() { # $1: '' for binaries, '.gz' for the archives
  while read -r hash file; do
    case "$file" in *.gz) [ "$1" = .gz ] || continue ;; *) [ -z "$1" ] || continue ;; esac
    platform="${file#clikgate-setup-$VERSION-}"; platform="${platform%.gz}"; platform="${platform%.exe}"
    echo "  '$platform': '$hash',"
  done < "$OUT/SHA256SUMS"
}
{
  echo "// GENERATED by scripts/build_setup_binaries.sh from cli/dist/bin/SHA256SUMS. Do not edit."
  echo "// scripts/check_cli_sdk_versions.mjs checks setupVersion against cli/package.json and, when the"
  echo "// files are present, these hashes against them."
  echo ""
  echo "/// Version of the setup command (cli/package.json) that \`dart run clikgate_flutter\` runs."
  echo "const String setupVersion = '$VERSION';"
  echo ""
  echo "/// SHA-256 of each binary \`clikgate-setup-<setupVersion>-<platform>[.exe]\`, by platform (checked after"
  echo "/// unpacking, and again before a cached copy is reused)."
  echo "const Map<String, String> setupBinarySha256 = {"
  dart_map ""
  echo "};"
  echo ""
  echo "/// SHA-256 of each release asset \`clikgate-setup-<setupVersion>-<platform>[.exe].gz\` (checked before unpacking)."
  echo "const Map<String, String> setupArchiveSha256 = {"
  dart_map .gz
  echo "};"
} > "$GEN"

echo "== done: $OUT"
(cd "$OUT" && for f in clikgate-setup-"$VERSION"-*; do printf '  %-52s %5s MB\n' "$f" "$(( $(wc -c < "$f") / 1048576 ))"; done)
echo "  SHA256SUMS and ${GEN#$ROOT/} updated."
