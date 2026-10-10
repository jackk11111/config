#!/usr/bin/env python3
"""Read-only audit of a real Git checkout of the pinned annibale vendor.

Checks actual presence of 3914 tracked proprietary files and 11 LFS pointers.
Five missing ArcSoft .so will be supplied separately at final build time.
No binary upload, no compilation, no phone modification.
"""
import argparse
import os
from pathlib import Path
import re
import subprocess

SHA = "f34647e4a03e376251b8ff32e650ceb9d9c13885"
MISSING = {
    "proprietary/odm/lib64/libarcsoft_dark_vision.so",
    "proprietary/odm/lib64/libarcsoft_raw_sr.so",
    "proprietary/odm/lib64/libarcsoft_turbo_fusion_mfnr.so",
    "proprietary/odm/lib64/libarcsoft_turbo_fusion_raw_super_night.so",
    "proprietary/odm/lib64/libarcsoft_turbo_hdr_raw.so",
}
LFS_POINTER = re.compile(
    rb"\Aversion https://git-lfs\.github\.com/spec/v1\r?\n"
    rb"oid sha256:[a-f0-9]{64}\r?\nsize ([1-9][0-9]*)\r?\n?\Z"
)

def out(*args):
    return subprocess.check_output(args, text=True).strip()

def check(args):
    root = args.vendor.resolve()
    assert (root / ".git").exists(), "No Git checkout"
    commit = out("git", "-C", str(root), "rev-parse", "HEAD")
    assert commit == SHA, f"Unexpected vendor revision: {commit}"
    ref = args.proprietary_files.read_text(encoding="utf-8")
    entries = []
    for item in ref.splitlines():
        item = item.strip()
        if not item or item.startswith("#"):
            continue
        dst = item.split(";", 1)[0].split(":")[-1].split("|", 1)[0]
        assert dst and not dst.startswith("/") and ".." not in Path(dst).parts, f"Unsafe target: {dst}"
        entries.append("proprietary/" + dst)
    unique = set(entries)
    assert len(entries) == 3927 and len(unique) == 3919, (len(entries), len(unique))
    observed = set(out("git", "-C", str(root), "ls-tree", "-r", "--name-only", "HEAD", "proprietary").splitlines())
    actual_missing = unique - observed
    assert actual_missing == MISSING, f"Unexpected tracked-file gap: {sorted(actual_missing ^ MISSING)}"
    assert len(unique & observed) == 3914, "Unexpected tracked-file inventory change"
    checkout_missing, empty = [], []
    lfs_count, checked_bytes = 0, 0
    for item in sorted(unique & observed):
        path = root / item
        if not os.path.lexists(path):
            checkout_missing.append(item)
            continue
        size = path.lstat().st_size
        if size == 0:
            empty.append(item)
        checked_bytes += size
        if Path(item).name.startswith("libarcsoft"):
            if not path.is_file():
                raise AssertionError("Invalid ArcSoft file type: " + item)
            if not LFS_POINTER.fullmatch(path.read_bytes()):
                raise AssertionError("Invalid LFS pointer or unexpectedly smudged binary: " + item)
            lfs_count += 1
    assert not checkout_missing, f"Checkout missing files: {checkout_missing[:10]}, total={len(checkout_missing)}"
    assert lfs_count == 11, f"Expected 11 ArcSoft LFS pointers, got {lfs_count}"
    for rootfile in ("Android.bp", "Android.mk", "annibale-vendor.mk", "BoardConfigVendor.mk"):
        assert (root / rootfile).is_file(), "Missing vendor Makefile: " + rootfile
    print("VENDOR_CHECKOUT_SHA=", commit)
    print("EXPECTED_PROPRIETARY_PATHS=", len(unique))
    print("ACTUAL_FILES_CHECKED=", len(unique & observed))
    print("INTENTIONALLY_MISSING_ARCSOFT=", len(actual_missing))
    print("ACTUAL_ARCSOFT_LFS_POINTERS=", lfs_count)
    print("ZERO_LENGTH_TRACKED_FILES=", len(empty))
    print("CHECKOUT_FILE_SIZES_TOTAL=", checked_bytes)
    print("PASS: real Git checkout materialized 3914 expected vendor paths; 11 LFS pointers valid.")
    print("NOT CHECKED: LFS payloads, rebuilt 5 libraries on runner, Android full sync, Soong or ROM runtime")

def main():
    p = argparse.ArgumentParser()
    p.add_argument("--vendor", type=Path, required=True)
    p.add_argument("--proprietary-files", type=Path, required=True)
    check(p.parse_args())

if __name__ == "__main__":
    main()
