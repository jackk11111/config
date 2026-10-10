#!/usr/bin/env python3
"""Verify actual Git LFS payload bytes for ALL 11 original ArcSoft files.

Read-only. Requires a pinned vendor checkout, and downloaded LFS objects.
Never copies/uploads binary blobs. NOT proof of Android 17 runtime correctness.
"""
from __future__ import annotations
import argparse
import hashlib
import re
import subprocess
from pathlib import Path

VENDOR_SHA = "f34647e4a03e376251b8ff32e650ceb9d9c13885"
PATTERN = re.compile(
    rb"\Aversion https://git-lfs.github.com/spec/v1\r?\n"
    rb"oid sha256:([a-f0-9]{64})\r?\nsize ([1-9][0-9]*)\r?\n?\Z"
)

def git(root: Path, *args: str) -> bytes:
    return subprocess.check_output(
        ["git", "-C", str(root), *args], stderr=subprocess.PIPE)

def file_sha256(path: Path) -> tuple[str, int]:
    h = hashlib.sha256()
    size = 0
    with path.open("rb") as stream:
        while True:
            chunk = stream.read(4 * 1024 * 1024)
            if not chunk:
                break
            h.update(chunk)
            size += len(chunk)
    return h.hexdigest(), size

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--vendor", type=Path, required=True)
    a = parser.parse_args()
    root = a.vendor.resolve()
    head = git(root, "rev-parse", "HEAD").decode().strip()
    if head != VENDOR_SHA:
        raise SystemExit("FAIL: unexpected vendor commit: " + head)
    listing = git(root, "ls-tree", "-r", "--name-only", "HEAD", "proprietary").decode().splitlines()
    arcsoft = sorted(p for p in listing if Path(p).name.startswith("libarcsoft"))
    if len(arcsoft) != 11:
        raise SystemExit(f"FAIL: expected 11 ArcSoft tracked file paths, got {len(arcsoft)}")
    errors = []
    total = 0
    for name in arcsoft:
        pointer = git(root, "show", "HEAD:" + name)
        match = PATTERN.fullmatch(pointer)
        if not match:
            errors.append(f"{name}: malformed/absent LFS pointer")
            continue
        expected_sha = match.group(1).decode()
        expected_size = int(match.group(2))
        path = root / name
        if not path.is_file():
            errors.append(f"{name}: actual file missing")
            continue
        if path.stat().st_size != expected_size:
            errors.append(f"{name}: size {path.stat().st_size} != {expected_size} (still pointer or incomplete)")
            continue
        actual_sha, actual_size = file_sha256(path)
        if actual_sha != expected_sha or actual_size != expected_size:
            errors.append(f"{name}: SHA256 mismatch (actual {actual_sha})")
            continue
        print(f"PASS {name} bytes={expected_size} sha256={actual_sha}")
        total += expected_size
    for error in errors:
        print("FAIL", error)
    print(f"CHECKED_FILES={len(arcsoft)}")
    print(f"VERIFIED_BYTES={total}")
    print(f"FAILURES={len(errors)}")
    print("NOT_CHECKED=five rebuilt ArcSoft files, ABI at runtime, firmware provenance, ROM build")
    print("RESULT=" + ("FAIL" if errors else "PASS_11_ORIGINAL_VENDOR_LFS_PAYLOAD_BYTES"))
    return 2 if errors else 0

if __name__ == "__main__":
    raise SystemExit(main())
