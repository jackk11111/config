#!/usr/bin/env python3
"""Validate the ARM32 stock-vendor/native compatibility layer for Wear7 V7.

This is an offline gate.  It proves that the retained dace/monaco vendor binaries
selected as first-boot critical have a complete DT_NEEDED graph and that their
strong undefined symbols are provided by that graph after adding the pinned
stock-379 compatibility libraries.  It does not claim that the HALs work on
hardware.
"""
import argparse
import hashlib
import json
import os
from collections import defaultdict
from pathlib import Path

from elftools.elf.elffile import ELFFile


COMPAT32 = (
    "android.hardware.audio.common-V1-ndk.so",
    "android.hardware.bluetooth.audio-V2-ndk.so",
    "android.hardware.security.keymint-V2-ndk.so",
    "android.hardware.soundtrigger@2.0-core.so",
    "android.hardware.soundtrigger@2.0.so",
    "android.media.audio.common.types-V1-ndk.so",
    "android.media.audio.common.types-V1-ndk_platform.so",
    "android.media.soundtrigger.types-V1-ndk.so",
    "android.media.soundtrigger.types-V1-ndk_platform.so",
    "libaudioroute.so",
    "libwifi-system-iface.so",
)

CRITICAL = (
    "/vendor/bin/hw/android.hardware.wifi@1.0-service",
    "/vendor/bin/hw/android.hardware.security.keymint-service-qti",
    "/vendor/bin/hw/android.hardware.nfc@1.2-service-st",
    "/vendor/bin/hw/android.hardware.gnss-aidl-service-qti",
    "/vendor/bin/hw/android.hardware.audio.service",
    "/vendor/bin/hw/android.hardware.bluetooth@1.0-service-qti",
    "/vendor/bin/hw/android.hardware.health-service.qti",
    "/vendor/bin/hw/android.hardware.power-service",
    "/vendor/bin/hw/vendor.qti.hardware.vibrator.service",
    "/vendor/bin/hw/vendor.qti.secure_element@1.2-service",
    "/vendor/bin/sensors.qti",
    "/vendor/lib/hw/android.hardware.soundtrigger@2.1-impl.so",
    "/vendor/lib/hw/android.hardware.soundtrigger@2.2-impl.so",
    "/vendor/lib/hw/android.hardware.soundtrigger@2.3-impl.so",
    "/vendor/lib/libbluetooth_audio_session_aidl.so",
    "/vendor/lib/hw/audio.bluetooth.default.so",
    "/vendor/lib/libagm.so",
    "/vendor/lib/libar-pal.so",
    "/vendor/lib/libhfp_pal.so",
    "/vendor/lib/libmcs.so",
)


def digest(path: Path) -> str:
    with path.open("rb") as f:
        return hashlib.file_digest(f, "sha256").hexdigest()


def elf_record(path: Path, virtual: str):
    try:
        with path.open("rb") as stream:
            if stream.read(4) != b"\x7fELF":
                return None
            stream.seek(0)
            elf = ELFFile(stream)
            if elf.elfclass != 32 or elf["e_machine"] != "EM_ARM":
                return None
            row = {
                "path": virtual,
                "needed": [],
                "exports": set(),
                "imports": set(),
                "weak_imports": set(),
                "soname": None,
            }
            dynamic = elf.get_section_by_name(".dynamic")
            if dynamic:
                for tag in dynamic.iter_tags():
                    if tag.entry.d_tag == "DT_NEEDED":
                        row["needed"].append(tag.needed)
                    elif tag.entry.d_tag == "DT_SONAME":
                        row["soname"] = tag.soname
            symbols = elf.get_section_by_name(".dynsym")
            if symbols:
                for symbol in symbols.iter_symbols():
                    name = symbol.name
                    if not name:
                        continue
                    binding = symbol["st_info"]["bind"]
                    if symbol["st_shndx"] == "SHN_UNDEF":
                        row["weak_imports" if binding == "STB_WEAK" else "imports"].add(name)
                    elif binding in ("STB_GLOBAL", "STB_WEAK") and symbol["st_other"]["visibility"] in ("STV_DEFAULT", "STV_PROTECTED"):
                        row["exports"].add(name)
            return row
    except (OSError, ValueError):
        return None


def scan(root: Path, prefix: str):
    rows = []
    for path in root.rglob("*"):
        if not path.is_file() or path.is_symlink():
            continue
        rel = path.relative_to(root).as_posix()
        row = elf_record(path, prefix.rstrip("/") + "/" + rel)
        if row:
            rows.append(row)
    return rows


def closure(root, providers):
    names = set()
    rows = []
    missing = set()
    stack = list(root["needed"])
    while stack:
        name = stack.pop()
        if name in names:
            continue
        names.add(name)
        matches = providers.get(name, [])
        if not matches:
            missing.add(name)
            continue
        for provider in matches:
            rows.append(provider)
            stack.extend(provider["needed"])
    exports = set()
    for row in rows:
        exports.update(row["exports"])
    unresolved = sorted(s for s in root["imports"] if s not in exports and not s.startswith("__cfi_"))
    return sorted(missing), unresolved


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--system", type=Path, required=True)
    p.add_argument("--system-ext", type=Path, required=True)
    p.add_argument("--product", type=Path, required=True)
    p.add_argument("--vendor", type=Path, required=True)
    p.add_argument("--apex", type=Path, required=True)
    p.add_argument("--stock-system", type=Path, required=True)
    p.add_argument("--report", type=Path, required=True)
    a = p.parse_args()

    rows = []
    for root, prefix in ((a.system, "/system"), (a.system_ext, "/system_ext"),
                         (a.product, "/product"), (a.vendor, "/vendor"), (a.apex, "/apex")):
        rows.extend(scan(root, prefix))
    by_path = {r["path"]: r for r in rows}
    providers = defaultdict(list)
    for row in rows:
        providers[Path(row["path"]).name].append(row)
        if row["soname"]:
            providers[row["soname"]].append(row)

    injected = {}
    errors = []
    for name in COMPAT32:
        dst = a.system / "lib" / name
        src = a.stock_system / "system" / "lib" / name
        if not dst.is_file() or not src.is_file():
            errors.append(f"missing compatibility library: {name}")
            continue
        dsha, ssha = digest(dst), digest(src)
        if dsha != ssha:
            errors.append(f"compatibility library differs from stock379: {name}")
        try:
            label = os.getxattr(dst, "security.selinux", follow_symlinks=False).rstrip(b"\0").decode()
        except OSError:
            label = "MISSING"
        if label != "u:object_r:system_lib_file:s0":
            errors.append(f"wrong SELinux label for {name}: {label}")
        injected[name] = {"sha256": dsha, "stock_sha256": ssha, "selinux": label}

    critical = {}
    for path in CRITICAL:
        row = by_path.get(path)
        if row is None:
            errors.append(f"critical ARM32 target absent: {path}")
            continue
        missing, unresolved = closure(row, providers)
        critical[path] = {"needed": row["needed"], "missing_needed_recursive": missing,
                          "unresolved_strong_imports": unresolved}
        if missing:
            errors.append(f"missing native providers for {path}: {', '.join(missing)}")
        if unresolved:
            errors.append(f"unresolved strong imports for {path}: {', '.join(unresolved[:12])}")

    # Inventory all remaining vendor orphan SONAMEs.  These are evidence only:
    # stock Qualcomm images contain optional/dead telephony and PASR blobs whose
    # dependencies are absent even before the Wear7 donor swap.  They are not
    # silently promoted into the compatibility layer.
    vendor_orphans = defaultdict(list)
    for row in rows:
        if not row["path"].startswith("/vendor/"):
            continue
        for name in row["needed"]:
            if name not in providers:
                vendor_orphans[name].append(row["path"])

    result = {
        "gate": "NATIVE_STOCK32_COMPAT",
        "status": "PASS" if not errors else "FAIL",
        "arm32_elf_records": len(rows),
        "injected_stock379": injected,
        "critical_targets": critical,
        "remaining_vendor_orphan_sonames_non_gating": {k: sorted(v) for k, v in sorted(vendor_orphans.items())},
        "errors": errors,
        "hardware_runtime": "UNTESTED",
    }
    a.report.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))
    if errors:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
