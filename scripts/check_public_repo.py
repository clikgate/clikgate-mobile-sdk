#!/usr/bin/env python3
"""
This repository is public. Fails when internal build material is committed: design specs, decision logs, progress
notes, release runbooks, or references to internal change numbers and those documents. Run from the repository root:
`python3 scripts/check_public_repo.py`. Scans the files git tracks (or the paths given as arguments).
"""

import re
import subprocess
import sys
from pathlib import Path

FORBIDDEN_PATHS = [
    re.compile(p)
    for p in (
        r"(^|/)docs/spec/",
        r"(^|/)DECISIONS\.md$",
        r"(^|/)PROGRESS\.md$",
        r"(^|/)RELEASING\.md$",
        r"(^|/)SERVER_SDKS\.md$",
        r"(^|/)AI_GUIDES_QA\.md$",
        r"(^|/)ai-qa-runs/",
        r"(^|/)(API_CONTRACT|SDK_BEHAVIOUR|PLATFORM_CHANNEL)\.md$",
        r"(^|/)__pycache__/",
        r"\.pyc$",
        # Files named after internal change numbers (Change26Test.kt, change03_test.dart, change21.test.ts)
        r"(?i)(^|/)change[ _-]?\d{2}(?!\d)[^/]*$",
    )
]

FORBIDDEN_TEXT = [
    # "Change 26", "change-03", and names built on them: Change26Test, change03_test, withoutChange26
    ("internal change number", re.compile(r"\bchange[ _-]?\d{2}(?!\d)|[a-z_]change[ _-]?\d{2}(?!\d)", re.I)),
    ("internal spec id", re.compile(r"\bC\d{1,2}-[A-Z]{1,2}\d")),
    # Requirement and section codes of the internal build kit: KC.6, R.24, X.E15, TS.1, EX.3, RF.1, S.4
    ("internal requirement code", re.compile(r"\b(KC|ST|TS|DB|X|EX|RF|R|S)\.[A-Z]?\d+\b")),
    (
        "internal spec reference",
        re.compile(
            r"\b[Ss]pec (v\d|\d|section|deliverable|[A-Z]\.\d)|\bbackend spec\b|\bPart \d+ §|\bcontract [A-Z]\d+\b"
        ),
    ),
    (
        "internal document",
        re.compile(
            r"DECISIONS\.md|PROGRESS\.md|RELEASING\.md|SERVER_SDKS\.md|AI_GUIDES_QA|ai-qa-runs|docs/spec"
            r"|API_CONTRACT|SDK_BEHAVIOUR|PLATFORM_CHANNEL"
        ),
    ),
    (
        "internal process note",
        re.compile(
            r"owner decision|judge?ment call|build specification|\bcoordinator\b|\bowner,? 20\d{2}\b", re.I
        ),
    ),
    # Private repositories, by path or by name (a quoted "clikgate_api" in code is a sibling-checkout path, and
    # clikgate_api_key / clikgate_api_url are settings names)
    (
        "private repository",
        re.compile(
            r"\.\./clikgate_api|clikgate_api/|\bclikgate_api\b(?![_\"'])|clikgate_frontend|clikgate_website"
            r"|clikgate[-_]sdk[-_]internal"
        ),
    ),
]

# Files whose job is to list the patterns above (release scanners and this check)
SKIP = {
    "scripts/check_public_repo.py",
    "scripts/scan_release_packages.py",
    "server/scripts/scan-package.mjs",
    "scripts/scan-package.mjs",
}

IGNORE_FILES = {".gitignore", ".pubignore", ".npmignore", ".dockerignore", ".gitattributes"}

# Byte-for-byte copies of backend files, checked for drift against the backend. Their wording is fixed in the backend
# first, then copied here; until then only the path-based checks apply to them.
COPIES_OF_BACKEND_FILES = {
    "server/openapi/openapi-public.json",
    "server/conformance/vectors/payment-helper-vectors.json",
    "server/conformance/vectors/identity-token-vectors.json",
    "server/conformance/vectors/customer-id-vectors.json",
    "server/conformance/tools/build_identity_token_vectors.py",
    "server/conformance/tools/build_customer_id_vectors.py",
}


def tracked() -> list[str]:
    out = subprocess.run(["git", "ls-files", "-z"], check=True, capture_output=True).stdout
    return [p for p in out.decode().split("\0") if p]


def main(argv: list[str]) -> int:
    paths = argv or tracked()
    problems: list[str] = []
    for path in paths:
        if any(p.search(path) for p in FORBIDDEN_PATHS):
            problems.append(f"{path}: internal file in a public repository")
            continue
        # Ignore files name the internal files on purpose, to keep them out of git and out of published packages
        if path in SKIP or path in COPIES_OF_BACKEND_FILES or path.rsplit("/", 1)[-1] in IGNORE_FILES:
            continue
        file = Path(path)
        if not file.is_file():
            continue
        data = file.read_bytes()
        if b"\0" in data[:8192]:
            continue  # binary
        for number, line in enumerate(data.decode("utf-8", "replace").splitlines(), 1):
            for label, pattern in FORBIDDEN_TEXT:
                match = pattern.search(line)
                if match:
                    problems.append(f"{path}:{number}: {label}: {match.group(0)!r}")
    for problem in problems:
        print(problem)
    if problems:
        print(f"\n{len(problems)} problem(s). Internal material belongs in the private clikgate-sdk-internal repository.")
        return 1
    print(f"OK: {len(paths)} files, nothing internal.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
