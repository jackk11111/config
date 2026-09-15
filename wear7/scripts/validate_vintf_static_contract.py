#!/usr/bin/env python3
"""Fail-closed XML validation for the frozen dace vendor/Wear7 framework contract.

This is not a replacement for Google's checkvintf binary. It validates the exact
hard HIDL requirements already extracted from stock379 plus the deliberate
DisplayOffload/WristOrientation policy for the ACTIVE Wear FCM level 7.
"""
from __future__ import annotations

import argparse
import re
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
FQ = re.compile(r"^@(\d+)\.(\d+)::([^/]+)/(.+)$")


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
            if lname(hal.tag) != "hal" or hal.attrib.get("format", "hidl") != "hidl":
                continue
            name = next(((n.text or "").strip() for n in hal if lname(n.tag) == "name"), "")

            # Modern framework manifests normally use <fqname>@1.x::I/instance</fqname>.
            for node in hal:
                if lname(node.tag) != "fqname":
                    continue
                m = FQ.match((node.text or "").strip())
                if m:
                    major, minor, iface, instance = m.groups()
                    got.add((name, f"{major}.{minor}", iface, instance))

            # Keep support for the older structured <version>/<interface> encoding.
            versions = [(n.text or "").strip() for n in hal if lname(n.tag) == "version"]
            for iface in hal:
                if lname(iface.tag) != "interface":
                    continue
                iname = next(((n.text or "").strip() for n in iface if lname(n.tag) == "name"), "")
                instances = [(n.text or "").strip() for n in iface if lname(n.tag) == "instance"]
                for version in versions:
                    for instance in instances:
                        got.add((name, version, iname, instance))
    return got


def version_satisfies(provided: str, required: str) -> bool:
    try:
        pmaj, pmin = map(int, provided.split(".", 1))
        rmaj, rmin = map(int, required.split(".", 1))
    except ValueError:
        return provided == required
    return pmaj == rmaj and pmin >= rmin


def contract_present(instances: set[tuple[str, str, str, str]], req: tuple[str, str, str, str]) -> bool:
    rn, rv, ri, rx = req
    return any(n == rn and i == ri and x == rx and version_satisfies(v, rv)
               for n, v, i, x in instances)


def matrix_hal_names(path: Path) -> list[tuple[str, list[str]]]:
    root = ET.parse(path).getroot()
    if lname(root.tag) != "compatibility-matrix":
        raise RuntimeError(f"not a compatibility matrix: {path}")
    rows = []
    for hal in root.iter():
        if lname(hal.tag) != "hal":
            continue
        names = [(n.text or "").strip() for n in hal if lname(n.tag) == "name"]
        instances = [(n.text or "").strip() for n in hal.iter() if lname(n.tag) == "instance"]
        for name in names:
            rows.append((name, instances))
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
    missing = sorted(req for req in REQUIRED if not contract_present(instances, req))
    if missing:
        raise RuntimeError("missing frozen vendor HIDL contracts: " + repr(missing))

    # Stock dace advertises target-level 7. Only the deliberately selected Wear
    # FCM7 file is patched for first bringup; later FCM8/yearly matrices are kept
    # intact and are not treated as the active target contract.
    fcm7 = s / "system/etc/vintf/wear_compatibility_matrix.7.xml"
    if not fcm7.is_file():
        raise RuntimeError("active Wear FCM7 matrix missing")
    rows = matrix_hal_names(fcm7)
    display = [inst for name, inst in rows if name == "vendor.google_clockwork.displayoffload"]
    if display:
        raise RuntimeError(f"Pixel DisplayOffload remains in active Wear FCM7: {display}")
    wrist = [inst for name, inst in rows if name == "vendor.google_clockwork.wristorientation"]
    if not wrist or not any("default" in inst for inst in wrist):
        raise RuntimeError("wristorientation/default is not retained in active Wear FCM7")

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
        "ACTIVE_WEAR_FCM=7",
        "PIXEL_DISPLAYOFFLOAD_REQUIREMENT_ACTIVE_FCM7=ABSENT",
        "WRISTORIENTATION_DEFAULT_ACTIVE_FCM7=RETAINED",
        "STOCK_FSTAB_DACE=PASS",
    ]
    for req in sorted(REQUIRED):
        candidates = sorted(x for x in instances if x[0] == req[0] and x[2:] == req[2:] and version_satisfies(x[1], req[1]))
        lines.append(f"HIDL_REQUIRED {req[0]}@{req[1]}::{req[2]}/{req[3]} PROVIDED={candidates} PASS")
    for p, level in vendor_levels:
        lines.append(f"VENDOR_TARGET_LEVEL {p}={level}")
    if a.report:
        a.report.parent.mkdir(parents=True, exist_ok=True)
        a.report.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print("\n".join(lines))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
