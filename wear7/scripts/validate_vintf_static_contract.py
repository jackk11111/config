#!/usr/bin/env python3
"""Fail-closed XML validation for the frozen dace vendor/Wear7 framework contract.

This is not a replacement for Google's checkvintf binary. It validates the exact
hard HIDL requirements already extracted from stock379 plus the deliberate
DisplayOffload/WristOrientation first-bringup policy on the staged trees.
"""
from __future__ import annotations

import argparse
import xml.etree.ElementTree as ET
from pathlib import Path

REQUIRED = {
    ("android.frameworks.sensorservice", "1.0", "ISensorManager", "default"),
    ("android.hidl.allocator", "1.0", "IAllocator", "ashmem"),
    ("android.hidl.manager", "1.0", "IServiceManager", "default"),
    ("android.hidl.memory", "1.0", "IMapper", "ashmem"),
    ("android.hidl.token", "1.0", "ITokenManager", "default"),
    ("android.system.wifi.keystore", "1.0", "IKeystore", "default"),
}


def lname(tag: str) -> str:
    return tag.rsplit("}", 1)[-1]


def xml_files(root: Path, rel: str) -> list[Path]:
    d = root / rel
    if not d.is_dir():
        return []
    return sorted(p for p in d.glob("*.xml") if p.is_file())


def manifest_instances(paths: list[Path]) -> set[tuple[str, str, str, str]]:
    got: set[tuple[str, str, str, str]] = set()
    for p in paths:
        try:
            root = ET.parse(p).getroot()
        except ET.ParseError as e:
            raise RuntimeError(f"bad VINTF XML {p}: {e}") from e
        if lname(root.tag) != "manifest":
            continue
        for hal in root.iter():
            if lname(hal.tag) != "hal":
                continue
            name = next(((n.text or "").strip() for n in hal if lname(n.tag) == "name"), "")
            versions = [(n.text or "").strip() for n in hal if lname(n.tag) == "version"]
            if not versions:
                versions = [""]
            for iface in hal:
                if lname(iface.tag) != "interface":
                    continue
                iname = next(((n.text or "").strip() for n in iface if lname(n.tag) == "name"), "")
                instances = [(n.text or "").strip() for n in iface if lname(n.tag) == "instance"]
                for version in versions:
                    for instance in instances:
                        got.add((name, version, iname, instance))
    return got


def matrix_hal_names(paths: list[Path]) -> list[tuple[Path, str, list[str]]]:
    rows = []
    for p in paths:
        root = ET.parse(p).getroot()
        if lname(root.tag) != "compatibility-matrix":
            continue
        for hal in root.iter():
            if lname(hal.tag) != "hal":
                continue
            names = [(n.text or "").strip() for n in hal if lname(n.tag) == "name"]
            instances = [(n.text or "").strip() for n in hal.iter() if lname(n.tag) == "instance"]
            for name in names:
                rows.append((p, name, instances))
    return rows


def main() -> int:
    ap = argparse.ArgumentParser()
    for n in ("system", "system_ext", "product", "vendor"):
        ap.add_argument(f"--{n.replace('_','-')}-root", required=True, type=Path)
    ap.add_argument("--report", type=Path)
    a = ap.parse_args()

    s, sx, prod, ven = (a.system_root, a.system_ext_root, a.product_root, a.vendor_root)
    framework_manifests = (
        xml_files(s, "system/etc/vintf") +
        xml_files(sx, "etc/vintf") +
        xml_files(prod, "etc/vintf")
    )
    instances = manifest_instances(framework_manifests)
    missing = sorted(REQUIRED - instances)
    if missing:
        raise RuntimeError("missing frozen vendor HIDL contracts: " + repr(missing))

    framework_matrices = (
        xml_files(s, "system/etc/vintf") +
        xml_files(sx, "etc/vintf") +
        xml_files(prod, "etc/vintf")
    )
    rows = matrix_hal_names(framework_matrices)
    display = [(str(p), inst) for p, name, inst in rows if name == "vendor.google_clockwork.displayoffload"]
    if display:
        raise RuntimeError(f"Pixel DisplayOffload requirement remains: {display}")
    wrist = [(str(p), inst) for p, name, inst in rows if name == "vendor.google_clockwork.wristorientation"]
    if not wrist or not any("default" in inst for _, inst in wrist):
        raise RuntimeError("wristorientation/default requirement is not retained")

    forbidden = [
        sx / "etc/permissions/display_offload_feature.xml",
        sx / "etc/vintf/compatibility_matrix_google_battery.xml",
        sx / "etc/vintf/compatibility_matrix_wac_management.xml",
        sx / "etc/vintf/compatibility_matrix_watch_charger.xml",
        s / "system/etc/vintf/compatibility_matrix.device.xml",
    ]
    remain = [str(p) for p in forbidden if p.exists()]
    if remain:
        raise RuntimeError(f"forbidden Pixel device contracts remain: {remain}")

    fstab = ven / "etc/fstab.dace"
    if not fstab.is_file():
        raise RuntimeError("stock vendor fstab.dace missing")
    fstab_text = fstab.read_text(encoding="utf-8", errors="replace")
    for mount in ("/system ", "/system_ext ", "/product ", "/vendor ", "/vendor_dlkm ", "/system_dlkm "):
        if mount not in fstab_text:
            raise RuntimeError(f"fstab.dace logical mount missing: {mount.strip()}")

    vendor_manifest_files = xml_files(ven, "etc/vintf")
    vendor_levels = []
    for p in vendor_manifest_files:
        root = ET.parse(p).getroot()
        if lname(root.tag) == "manifest" and root.attrib.get("target-level"):
            vendor_levels.append((str(p), root.attrib["target-level"]))
    if vendor_levels and not any(level == "7" for _, level in vendor_levels):
        raise RuntimeError(f"stock vendor target-level 7 not found: {vendor_levels}")

    lines = [
        "VINTF_STATIC_EXACT_CONTRACT=PASS",
        "OFFICIAL_CHECKVINTF_HOST=UNAVAILABLE_IN_PINNED_TOOLSET",
        "FROZEN_VENDOR_HIDL=6/6",
        "PIXEL_DISPLAYOFFLOAD_REQUIREMENT=ABSENT",
        "WRISTORIENTATION_DEFAULT=RETAINED",
        "STOCK_FSTAB_DACE=PASS",
    ]
    for x in sorted(REQUIRED):
        lines.append("HIDL " + "@".join((x[0], x[1])) + f"::{x[2]}/{x[3]} PASS")
    for p, level in vendor_levels:
        lines.append(f"VENDOR_TARGET_LEVEL {p}={level}")
    if a.report:
        a.report.parent.mkdir(parents=True, exist_ok=True)
        a.report.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print("\n".join(lines))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
