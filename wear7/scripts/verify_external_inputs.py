#!/usr/bin/env python3
"""Fail-closed verifier for external Wear7 build inputs.

This repository is public, so proprietary/factory payloads are kept outside it.
Pass any subset of known files with --input NAME=PATH. The script verifies only
recognized logical names and exits non-zero on a mismatch.
"""

from __future__ import annotations
import argparse
import hashlib
from pathlib import Path

EXPECTED = {
    "pixel_factory": "d203665c90bc06bf175dbb3cbd7fcc9d212c056a030f9c51b541129e8651fb7d",
    "pixel_preflight_capture": "1a17b1b55d589c26767fb101794667ee8819a7ce1f5f9af6a65c729505891ad2",
    "ticwatch_port_source_379": "68500e13d8edf2c863383118d0a5d2e0a1f7cdb82ac1af248e3473382d7ecb60",
    "ticwatch_stage0_rebuild": "d6c18d45c8fe6b9c0901555465f7fa353cb2f4947cd24dfeb3bec8de574d2072",
    "kernel_kexec_handoff_v2": "ac4383fcdc36a4671d84faaf31765cf567986e059f9c6e65ee5d617e5c0c3966",
    "kernel_recovery_status": "e358c274c24e301a70d79eec20c80cfe87769a5c3f816ef1bfb81153757351fe",
}


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda: f.read(8 * 1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument(
        "--input",
        action="append",
        default=[],
        metavar="NAME=PATH",
        help="logical input name and local file path; may be repeated",
    )
    ap.add_argument("--list", action="store_true", help="list recognized logical names")
    a = ap.parse_args()

    if a.list:
        for k, v in EXPECTED.items():
            print(f"{k}\t{v}")
        return 0

    if not a.input:
        ap.error("supply at least one --input NAME=PATH or use --list")

    failed = False
    for spec in a.input:
        if "=" not in spec:
            print(f"FAIL invalid input spec: {spec}")
            failed = True
            continue
        name, raw = spec.split("=", 1)
        if name not in EXPECTED:
            print(f"FAIL unknown logical name: {name}")
            failed = True
            continue
        p = Path(raw)
        if not p.is_file():
            print(f"FAIL missing file: {name}: {p}")
            failed = True
            continue
        got = sha256(p)
        exp = EXPECTED[name]
        if got != exp:
            print(f"FAIL {name}: expected {exp}, got {got}: {p}")
            failed = True
        else:
            print(f"PASS {name}: {got}: {p}")

    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
