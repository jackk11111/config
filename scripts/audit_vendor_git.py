#!/usr/bin/env python3
"""Audit public vendor Git tree without fetching binary payloads."""
import argparse
import json
from pathlib import Path
import re
import subprocess

VENDOR_SHA = "f34647e4a03e376251b8ff32e650ceb9d9c13885"
EXPECTED_MISSING = {
    "proprietary/odm/lib64/libarcsoft_dark_vision.so",
    "proprietary/odm/lib64/libarcsoft_raw_sr.so",
    "proprietary/odm/lib64/libarcsoft_turbo_fusion_mfnr.so",
    "proprietary/odm/lib64/libarcsoft_turbo_fusion_raw_super_night.so",
    "proprietary/odm/lib64/libarcsoft_turbo_hdr_raw.so",
}

def run(*command):
    return subprocess.check_output(command, stderr=subprocess.PIPE).decode()

def compare(paths, pft, root_files, pointer_fn):
    problems = []
    tracked = {p for p in paths if p.startswith("proprietary/")}
    expected = []
    for line in pft.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        target = line.split(";", 1)[0].split(":")[-1].split("|", 1)[0].strip()
        if target.startswith("/") or ".." in Path(target).parts or not target:
            problems.append("Invalid proprietary path: " + target)
            continue
        expected.append("proprietary/" + target)
    target_set = set(expected)
    missing = target_set - tracked
    unexpected = tracked - target_set
    print("EXPECTED_LIST_ENTRIES=", len(expected))
    print("EXPECTED_UNIQUE_DESTINATIONS=", len(target_set))
    print("GIT_VENDOR_BLOB_PATHS=", len(tracked))
    print("MATCHED_DESTINATIONS=", len(tracked & target_set))
    print("MISSING_DESTINATIONS=", json.dumps(sorted(missing)))
    print("EXTRA_GIT_VENDOR_BLOBS=", len(unexpected))
    if missing != EXPECTED_MISSING:
        problems.append(f"Unexpected missing destinations: {sorted(missing ^ EXPECTED_MISSING)}")
    if len(target_set) != 3919 or len(tracked) != 3914 or unexpected:
        problems.append("Vendor inventory changed from audited 2026-10-10 baseline")
    for name in ["Android.bp", "Android.mk", "annibale-vendor.mk", "BoardConfigVendor.mk", ".gitattributes"]:
        if not root_files.get(name):
            problems.append("Required vendor root file missing: " + name)
    for name in ["Android.bp", "annibale-vendor.mk"]:
        source = root_files.get(name, "")
        for item in EXPECTED_MISSING:
            marker = item if name == "Android.bp" else Path(item).name.removesuffix(".so")
            if marker not in source:
                problems.append(f"{name} does not declare overlay module {marker}")
    if "libarcsoft* filter=lfs" not in root_files.get(".gitattributes", ""):
        problems.append("Git LFS ArcSoft rule not present")
    lfs_found = sorted(p for p in tracked if Path(p).name.startswith("libarcsoft"))
    lfs_expected = {p for p in target_set if Path(p).name.startswith("libarcsoft")}
    if len(lfs_found) != 11 or len(lfs_expected) != 16:
        problems.append("ArcSoft inventory diverged from 11 present/5 absent")
    lfs_sizes = 0
    for item in lfs_found:
        match = re.fullmatch(
            r"version https://git-lfs.github.com/spec/v1\noid sha256:([a-f0-9]{64})\nsize ([0-9]+)\n?",
            pointer_fn(item),
        )
        if not match or int(match.group(2)) <= 0:
            problems.append("Invalid Git LFS pointer: " + item)
        else:
            lfs_sizes += int(match.group(2))
    print("ARC_SOFT_LFS_POINTERS_VALIDATED=", len(lfs_found))
    print("ARC_SOFT_LFS_DECLARED_BYTES=", lfs_sizes)
    print("NOT_CHECKED=Git LFS payload bytes, five reconstructed binaries, Soong, ROM runtime")
    return problems

def main():
    arg = argparse.ArgumentParser()
    arg.add_argument("--vendor-git", type=Path, required=True)
    arg.add_argument("--proprietary-files", type=Path, required=True)
    a = arg.parse_args()
    root = a.vendor_git
    sha = run("git", "-C", str(root), "rev-parse", "HEAD").strip()
    if sha != VENDOR_SHA:
        raise SystemExit("FAIL: wrong vendor commit " + sha)
    paths = run("git", "-C", str(root), "ls-tree", "-r", "--name-only", "HEAD", "proprietary").splitlines()
    roots = {}
    for name in ["Android.bp", "Android.mk", "annibale-vendor.mk", "BoardConfigVendor.mk", ".gitattributes"]:
        roots[name] = run("git", "-C", str(root), "show", "HEAD:" + name)
    problems = compare(
        paths, a.proprietary_files.read_text(), roots,
        lambda p: run("git", "-C", str(root), "show", "HEAD:" + p)
    )
    for issue in problems:
        print("FAIL:", issue)
    print("RESULT=", "FAIL" if problems else "PASS_VENDOR_GIT_TREE_5_KNOWN_OVERLAY_FILES_ONLY")
    return 2 if problems else 0

if __name__ == "__main__":
    raise SystemExit(main())
