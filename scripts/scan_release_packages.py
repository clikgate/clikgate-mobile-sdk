#!/usr/bin/env python3
"""
Scans release packages for things that must not ship (spec Change 12, S.4): TODO / FIXME notes,
internal-document references, internal or staff URLs and hosts, local paths, staff-only references
and debug code. Exits 1 when anything is found, so a release job fails before it publishes.

    python3 scripts/scan_release_packages.py PATH...            # .aar .jar .zip .tgz .tar.gz files, or directories
    python3 scripts/scan_release_packages.py --pub flutter      # the files `dart pub publish` would upload
    python3 scripts/scan_release_packages.py --npm react-native # the files `npm pack` would include
    python3 scripts/scan_release_packages.py --pod ios          # the CocoaPods source zip's files (ios.yml)
    python3 scripts/scan_release_packages.py --spm              # the SPM mirror's files (scripts/spm_mirror.py)
    python3 scripts/scan_release_packages.py --cli cli          # the setup command's npm package (dist/cli.cjs bundle)

Archives are opened recursively (an AAR's classes.jar, an XCFramework zip). Text entries are checked
against every rule; binary entries (class files, Mach-O, .so) through their printable strings,
against every rule but the debug-code ones. Matching, scoring and attribution logic stays on the
server; this scan only keeps notes, internal references and debug code out of what customers get.

The setup command (--cli) is one esbuild bundle. Two exact rules apply to it, and only to it:
  * Third-party code: esbuild starts every bundled module with a `// <path>` line at column 0. A section that
    starts with `// node_modules/<package>/` and runs to the next such marker is a bundled dependency (yaml,
    plist, diff, ...): it isn't ours to edit, so it isn't scanned. Our own sections (`// src/...`) and the
    esbuild helpers before the first marker are.
  * CLI_ALLOWED_LINES: exact lines of the code the setup command writes into the customer's own app.
"""

from __future__ import annotations

import argparse
import io
import json
import re
import subprocess
import sys
import tarfile
import zipfile
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

I = re.IGNORECASE
RULES: list[tuple[str, re.Pattern[str], bool]] = [
    # (name, pattern, applies to binary strings too)
    ("note", re.compile(r"\b(TODO|FIXME|XXX|HACK)\b"), True),
    ("internal doc", re.compile(
        r"API_CONTRACT|SDK_BEHAVIOUR|PLATFORM_CHANNEL|DECISIONS\.md|RELEASING\.md|PROGRESS\.md|docs/spec"
        r"|backend contract|\bspec (v3|0\.\d|1?\d+[A-Z]?\.\d|section)|\bchange[ -]?\d{2}\b|\bC1\d-[A-Z]\d", I), True),
    ("internal host", re.compile(
        r"localhost|127\.0\.0\.1|10\.0\.2\.2|0\.0\.0\.0|ngrok"
        r"|(staff|admin|console|staging|internal)\.clikgate\.|/v1/staff\b", I), True),
    ("local path", re.compile(r"/Users/[A-Za-z]|/home/runner|/private/tmp|scratchpad|C:\\\\Users", I), True),
    ("staff only", re.compile(r"\bstaff\b|\bdistyla\b|\bdstl\.ng\b|\bcoordinator\b|owner (item|action)s?\b", I), True),
    ("debug code", re.compile(
        r"console\.log\(|\bdebugger;|System\.out\.print|\.printStackTrace\(\)|\bdebugPrint\(|\bNSLog\("
        r"|(^|[^\w.])print\(|(^|[^\w.])dump\("), False),
]

# The deep-link handler the setup command adds to the customer's app (cli/src/edit/source.ts) logs the link so
# the developer sees it arrive when testing the first link, next to a comment telling them to open the right
# screen instead. It runs in their app, not in the CLI, and is theirs to change. Exact text as bundled.
CLI_ALLOWED_LINES = {
    "\"      console.log('Clikgate deep link', link.path);\",",
    '`${unit}print("Clikgate deep link:", link.path ?? "/")`,',
}
VENDOR_MARKER = re.compile(r"^// (node_modules|src)/")

TEXT_SUFFIXES = {
    ".kt", ".java", ".swift", ".m", ".mm", ".h", ".c", ".cpp", ".dart", ".ts", ".tsx", ".js", ".mjs", ".cjs",
    ".json", ".xml", ".plist", ".xcprivacy", ".md", ".txt", ".yaml", ".yml", ".gradle", ".kts", ".pro",
    ".podspec", ".rb", ".swiftinterface", ".modulemap", ".properties", ".map", ".d.ts", ".sh", ".cfg",
}
TEXT_NAMES = {"LICENSE", "NOTICE", "Podfile", "Package.swift", "CMakeLists.txt", "proguard.txt", "R.txt"}
ARCHIVE_SUFFIXES = (".aar", ".jar", ".zip", ".tgz", ".tar.gz", ".xcframework.zip")
SKIP_SUFFIXES = {".png", ".jpg", ".jpeg", ".gif", ".webp", ".ttf", ".otf", ".car", ".nib"}
STRINGS = re.compile(rb"[\x20-\x7e]{6,}")


@dataclass
class Finding:
    where: str
    line: int
    rule: str
    text: str


findings: list[Finding] = []
scanned = 0


def is_text(name: str) -> bool:
    n = name.rsplit("/", 1)[-1]
    return n in TEXT_NAMES or any(n.endswith(s) for s in TEXT_SUFFIXES)


def scan_text(where: str, text: str, binary: bool) -> None:
    for no, line in enumerate(text.splitlines(), 1):
        for rule, pat, in_binary in RULES:
            if binary and not in_binary:
                continue
            if pat.search(line):
                findings.append(Finding(where, no, rule, line.strip()[:160]))


def scan_bytes(where: str, data: bytes) -> None:
    global scanned
    scanned += 1
    name = where.rsplit("!", 1)[-1]
    lower = name.lower()
    if any(lower.endswith(s) for s in ARCHIVE_SUFFIXES):
        return scan_archive(where, data)
    if any(lower.endswith(s) for s in SKIP_SUFFIXES):
        return
    if is_text(name):
        try:
            return scan_text(where, data.decode("utf-8"), binary=False)
        except UnicodeDecodeError:
            pass
    strings = "\n".join(s.decode("ascii") for s in STRINGS.findall(data))
    scan_text(where, strings, binary=True)


def scan_archive(where: str, data: bytes) -> None:
    buf = io.BytesIO(data)
    if zipfile.is_zipfile(buf):
        with zipfile.ZipFile(buf) as z:
            for info in z.infolist():
                if not info.is_dir():
                    scan_bytes(f"{where}!{info.filename}", z.read(info))
        return
    buf.seek(0)
    try:
        with tarfile.open(fileobj=buf, mode="r:*") as t:
            for m in t.getmembers():
                f = t.extractfile(m) if m.isfile() else None
                if f is not None:
                    scan_bytes(f"{where}!{m.name}", f.read())
    except tarfile.TarError:
        sys.exit(f"error: {where} is not a zip or tar archive")


def scan_path(path: Path, label: str | None = None) -> None:
    if path.is_dir():
        for p in sorted(path.rglob("*")):
            if p.is_file():
                scan_bytes(str(p.relative_to(ROOT) if p.is_relative_to(ROOT) else p), p.read_bytes())
    elif path.is_file():
        scan_bytes(label or str(path), path.read_bytes())
    else:
        sys.exit(f"error: {path} doesn't exist")


def scan_cli(directory: Path) -> None:
    """The setup command's npm package; dist/cli.cjs without its bundled dependencies (module docstring)."""
    global scanned
    for f in npm_files(directory):
        label = f"npm:{directory.name}/{f.relative_to(directory)}"
        if f.name != "cli.cjs":
            scan_path(f, label)
            continue
        scanned += 1
        vendored = False
        for no, line in enumerate(f.read_text().splitlines(), 1):
            m = VENDOR_MARKER.match(line)
            if m:
                vendored = m.group(1) == "node_modules"
            if vendored or line.strip() in CLI_ALLOWED_LINES:
                continue
            for rule, pat, _ in RULES:
                if pat.search(line):
                    findings.append(Finding(label, no, rule, line.strip()[:160]))


def git_files(directory: Path, extra_excludes: list[str]) -> list[Path]:
    cmd = ["git", "-C", str(directory), "ls-files", "-co", "--exclude-standard", "--full-name"]
    for e in extra_excludes:
        cmd.append(f"--exclude-per-directory={e}")
    cmd += ["--", "."]
    out = subprocess.run(cmd, check=True, capture_output=True, text=True).stdout.splitlines()
    top = Path(subprocess.run(["git", "-C", str(directory), "rev-parse", "--show-toplevel"],
                              check=True, capture_output=True, text=True).stdout.strip())
    return [top / f for f in out]


def pub_files(directory: Path) -> list[Path]:
    """What `dart pub publish` uploads: files not ignored by .gitignore nor .pubignore (each read per directory,
    so anchored patterns work), no dotfiles."""
    files = set(git_files(directory, []))
    if any(directory.rglob(".pubignore")):
        out = subprocess.run(["git", "-C", str(directory), "ls-files", "-co", "--full-name",
                              "--exclude-per-directory=.pubignore", "--", "."],
                             check=True, capture_output=True, text=True).stdout.splitlines()
        top = Path(subprocess.run(["git", "-C", str(directory), "rev-parse", "--show-toplevel"],
                                  check=True, capture_output=True, text=True).stdout.strip())
        files &= {top / f for f in out}
        # `ls-files -c` lists tracked files whatever the excludes say; take out the tracked files .pubignore drops
        ignored = subprocess.run(["git", "-C", str(directory), "ls-files", "-ci", "--full-name",
                                  "--exclude-per-directory=.pubignore", "--", "."],
                                 check=True, capture_output=True, text=True).stdout.splitlines()
        files -= {top / f for f in ignored}
    root = directory.resolve()
    keep = []
    for f in sorted(files):
        rel = f.resolve().relative_to(root)
        if any(part.startswith(".") for part in rel.parts) or not f.is_file():
            continue
        keep.append(f)
    return keep


def npm_files(directory: Path) -> list[Path]:
    """What `npm pack` includes (scripts not run)."""
    out = subprocess.run(["npm", "pack", "--dry-run", "--json", "--ignore-scripts"], cwd=directory,
                         check=True, capture_output=True, text=True).stdout
    return [directory / f["path"] for f in json.loads(out)[0]["files"]]


def pod_files(directory: Path) -> list[Path]:
    """The CocoaPods source zip of ios.yml (`zip -r ... <entries>`), from POD_ZIP_ENTRIES there."""
    workflow = (ROOT / ".github/workflows/ios.yml").read_text()
    m = re.search(r'zip -qry "[^"]+" ([^\n]+)', workflow)
    if not m:
        sys.exit("error: can't find the CocoaPods zip command in .github/workflows/ios.yml")
    out = []
    for entry in m.group(1).split():
        p = directory / entry
        out.extend(sorted(x for x in p.rglob("*") if x.is_file()) if p.is_dir() else [p])
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("paths", nargs="*", type=Path)
    ap.add_argument("--pub", action="append", type=Path, default=[], help="a Dart package directory")
    ap.add_argument("--npm", action="append", type=Path, default=[], help="an npm package directory")
    ap.add_argument("--pod", action="append", type=Path, default=[], help="the iOS directory (CocoaPods source zip)")
    ap.add_argument("--spm", action="store_true", help="the SPM mirror's files (scripts/spm_mirror.py)")
    ap.add_argument("--cli", action="append", type=Path, default=[], help="the setup command's package directory")
    args = ap.parse_args()
    if not (args.paths or args.pub or args.npm or args.pod or args.spm or args.cli):
        ap.error("nothing to scan")

    for d in args.pub:
        for f in pub_files(d):
            scan_path(f, f"pub:{d.name}/{f.resolve().relative_to(d.resolve())}")
    for d in args.npm:
        for f in npm_files(d):
            scan_path(f, f"npm:{d.name}/{f.relative_to(d)}")
    for d in args.pod:
        for f in pod_files(d):
            scan_path(f, f"pod:{f.resolve().relative_to(d.resolve())}")
    if args.spm:
        sys.path.insert(0, str(ROOT / "scripts"))
        import spm_mirror
        for rel, src in spm_mirror.files().items():
            if isinstance(src, str):
                scan_bytes(f"spm:{rel}", src.encode())
            else:
                scan_path(src, f"spm:{rel}")
    for d in args.cli:
        scan_cli(d)
    for p in args.paths:
        scan_path(p)

    for f in findings:
        print(f"{f.where}:{f.line}: [{f.rule}] {f.text}")
    print(f"scanned {scanned} files: {len(findings)} finding(s)", file=sys.stderr)
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
