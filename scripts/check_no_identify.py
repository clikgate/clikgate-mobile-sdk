#!/usr/bin/env python3
"""
`identifyUser()` replaced `identify()` on every SDK. Fails when `identify(` (the old call) appears anywhere in the SDKs,
their samples, docs, READMEs or AI-facing text, except CHANGELOGs and the internal decision and progress records.

    python3 scripts/check_no_identify.py
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SKIP_DIRS = {"node_modules", "build", ".build", ".dart_tool", "Pods", ".gradle", "dist", ".venv", "DerivedData", "spec"}
BUILT = ("lib/module", "lib/typescript", "lib/commonjs")
SKIP_NAMES = {"CHANGELOG.md", "DECISIONS.md", "PROGRESS.md", "check_no_identify.py"}
SUFFIXES = {".md", ".kt", ".swift", ".dart", ".ts", ".tsx", ".js", ".py", ".mm", ".m", ".h", ".xml", ".xcprivacy"}
OLD = re.compile(r"(?<![A-Za-z_$])identify\(")


def main() -> int:
    hits = []
    for path in ROOT.rglob("*"):
        if not path.is_file() or path.suffix not in SUFFIXES or path.name in SKIP_NAMES:
            continue
        rel = path.relative_to(ROOT)
        if set(rel.parts[:-1]) & SKIP_DIRS or any(b in rel.as_posix() for b in BUILT):
            continue
        for n, line in enumerate(path.read_text(errors="ignore").splitlines(), 1):
            if OLD.search(line):
                hits.append(f"{rel}:{n}: {line.strip()[:120]}")
    if hits:
        print("identify() was replaced by identifyUser(); update these lines:", *hits, sep="\n  ", file=sys.stderr)
        return 1
    print("no identify() calls left")
    return 0


if __name__ == "__main__":
    sys.exit(main())
