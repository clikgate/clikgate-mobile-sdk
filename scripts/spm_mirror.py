#!/usr/bin/env python3
"""
Assembles what the Swift Package Manager mirror (clikgate/clikgate-ios-sdk) publishes: only what SPM needs.

    python3 scripts/spm_mirror.py OUT_DIR

OUT_DIR gets `Package.swift` (ios/Package.swift without its test targets, so it doesn't point at folders the
mirror leaves out), `Sources/` (every target's path and resources), `LICENSE` and `README.md`. Tests, the sample
app, scripts, the API snapshot, DECISIONS.md and build output stay in this repository. ios.yml publishes OUT_DIR,
and scripts/scan_release_packages.py --spm scans the same set.
"""

from __future__ import annotations

import re
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
IOS = ROOT / "ios"
FILES = ["LICENSE", "README.md"]
DIRS = ["Sources"]

# `.testTarget(` ... `),` blocks, at the indentation Package.swift uses for its targets.
TEST_TARGET = re.compile(r"^(?P<indent>[ \t]*)\.testTarget\(\n.*?^(?P=indent)\),\n", re.MULTILINE | re.DOTALL)


def release_manifest() -> str:
    text = (IOS / "Package.swift").read_text()
    out = TEST_TARGET.sub("", text)
    if ".testTarget" in out:
        sys.exit("error: couldn't remove every .testTarget from ios/Package.swift")
    # Every target path the manifest still names must be shipped.
    for path in re.findall(r'path:\s*"([^"]+)"', out):
        if not any(path == d or path.startswith(d + "/") for d in DIRS):
            sys.exit(f"error: ios/Package.swift target path {path!r} isn't in the mirror ({DIRS})")
    return out


def files() -> dict[str, Path | str]:
    """Published path -> source file (or the generated text for Package.swift)."""
    out: dict[str, Path | str] = {"Package.swift": release_manifest()}
    for f in FILES:
        if not (IOS / f).is_file():
            sys.exit(f"error: ios/{f} is missing")
        out[f] = IOS / f
    for d in DIRS:
        for p in sorted((IOS / d).rglob("*")):
            if p.is_file() and p.name != ".DS_Store":
                out[str(p.relative_to(IOS))] = p
    return out


def assemble(dest: Path) -> list[Path]:
    if dest.exists():
        shutil.rmtree(dest)
    written = []
    for rel, src in files().items():
        target = dest / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        if isinstance(src, str):
            target.write_text(src)
        else:
            shutil.copy2(src, target)
        written.append(target)
    return written


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    out = assemble(Path(sys.argv[1]))
    print(f"SPM mirror: {len(out)} files in {sys.argv[1]}")
