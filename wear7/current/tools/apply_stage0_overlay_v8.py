#!/usr/bin/env python3
"""Apply the frozen TicWatch Pro 5 Enduro Wear7 Stage0 policy to Pixel donor trees.

This tool is offline-only. It edits extracted filesystem trees; it never flashes a device.
It expects a Stage0 source bundle containing payload/ and manifests/SOURCE_HASHES.tsv.
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import os
import shutil
import xml.etree.ElementTree as ET
from pathlib import Path

EXPECTED_PAYLOAD = {
    "payload/system/priv-app/TicCompanionWear/TicCompanionWear.apk":
        "system/priv-app/TicCompanionWear/TicCompanionWear.apk",
    "payload/product/overlay/DaceEnduroFastPairOverlay/DaceEnduroFastPairOverlay.apk":
        "overlay/DaceEnduroFastPairOverlay/DaceEnduroFastPairOverlay.apk",
    "payload/system_ext/lib/libdisplayconfig.system.qti.so": "lib/libdisplayconfig.system.qti.so",
    "payload/system_ext/lib/libgralloc.system.qti.so": "lib/libgralloc.system.qti.so",
    "payload/system_ext/lib/vendor.display.config@2.0.so": "lib/vendor.display.config@2.0.so",
    "payload/system_ext/lib/android.hardware.radio@1.5.so": "lib/android.hardware.radio@1.5.so",
    "payload/system_ext/lib/android.hardware.radio@1.6.so": "lib/android.hardware.radio@1.6.so",
    "payload/system_ext/lib/vendor.google_clockwork.wristorientation@1.0.so":
        "lib/vendor.google_clockwork.wristorientation@1.0.so",
}

PROPS = {
    "ro.oem.home_package_names": "com.mobvoi.companion.aw",
    "ro.oem.key1": "TicWatchPro5Enduro",
    "config.enable_wristorientation": "1",
    "config.use_aidl_api_for_display_offload": "0",
    "ro.wear.comms.offload.enabled": "false",
}

REMOVE_SYSTEM = ["system/etc/vintf/compatibility_matrix.device.xml"]
REMOVE_SYSTEM_EXT = [
    "etc/permissions/display_offload_feature.xml",
    "etc/vintf/compatibility_matrix_google_battery.xml",
    "etc/vintf/compatibility_matrix_wac_management.xml",
    "etc/vintf/compatibility_matrix_watch_charger.xml",
]

PRIV_PERMISSIONS = [
    "android.permission.CHANGE_COMPONENT_ENABLED_STATE",
    "android.permission.LOCAL_MAC_ADDRESS",
    "com.google.android.wearable.healthservices.permission.READ_PROFILE_INFO",
    "com.google.android.wearable.healthservices.permission.WRITE_PROFILE_INFO",
]


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(8 * 1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def read_source_hashes(bundle: Path) -> dict[str, str]:
    path = bundle / "manifests/SOURCE_HASHES.tsv"
    if not path.is_file():
        raise RuntimeError(f"missing source hash manifest: {path}")
    with path.open(newline="", encoding="utf-8") as f:
        rows = list(csv.DictReader(f, delimiter="\t"))
    result = {row["bundle_path"]: row["sha256"] for row in rows}
    missing = sorted(set(EXPECTED_PAYLOAD) - set(result))
    extra = sorted(set(result) - set(EXPECTED_PAYLOAD))
    if missing or extra:
        raise RuntimeError(f"Stage0 manifest not exactly frozen: missing={missing} extra={extra}")
    return result


def copy_exact(src: Path, dst: Path, expected_hash: str) -> None:
    if not src.is_file():
        raise RuntimeError(f"missing frozen payload: {src}")
    got = sha256(src)
    if got != expected_hash:
        raise RuntimeError(f"payload SHA mismatch for {src}: {got} != {expected_hash}")
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(src, dst)
    os.chmod(dst, 0o644)
    if sha256(dst) != expected_hash:
        raise RuntimeError(f"post-copy SHA mismatch: {dst}")


def set_properties(build_prop: Path) -> None:
    if not build_prop.is_file():
        raise RuntimeError(f"missing Pixel build.prop: {build_prop}")
    lines = build_prop.read_text(encoding="utf-8", errors="strict").splitlines()
    seen: set[str] = set()
    out: list[str] = []
    for line in lines:
        stripped = line.strip()
        if stripped and not stripped.startswith("#") and "=" in line:
            key = line.split("=", 1)[0].strip()
            if key in PROPS:
                if key not in seen:
                    out.append(f"{key}={PROPS[key]}")
                    seen.add(key)
                continue
        out.append(line)
    for key, value in PROPS.items():
        if key not in seen:
            out.append(f"{key}={value}")
    build_prop.write_text("\n".join(out) + "\n", encoding="utf-8")
    os.chmod(build_prop, 0o600)


def local(tag: str) -> str:
    return tag.rsplit("}", 1)[-1]


def remove_displayoffload_hal(matrix: Path) -> None:
    if not matrix.is_file():
        raise RuntimeError(f"missing Wear FCM7 matrix: {matrix}")
    tree = ET.parse(matrix)
    root = tree.getroot()
    level_before = root.attrib.get("level")
    removed = 0
    for parent in root.iter():
        for child in list(parent):
            if local(child.tag) != "hal":
                continue
            names = [
                (n.text or "").strip()
                for n in child.iter()
                if local(n.tag) == "name"
            ]
            if "vendor.google_clockwork.displayoffload" in names:
                parent.remove(child)
                removed += 1
    if removed < 1:
        raise RuntimeError("displayoffload HAL requirement not found in donor FCM7 matrix")
    names = [
        (node.text or "").strip()
        for node in root.iter()
        if local(node.tag) == "name"
    ]
    if "vendor.google_clockwork.displayoffload" in names:
        raise RuntimeError("displayoffload HAL remains after edit")
    if "vendor.google_clockwork.wristorientation" not in names:
        raise RuntimeError("wristorientation HAL disappeared from FCM7 matrix")
    wrist_default = False
    for hal in root.iter():
        if local(hal.tag) != "hal":
            continue
        hal_names = [(x.text or "").strip() for x in hal if local(x.tag) == "name"]
        if "vendor.google_clockwork.wristorientation" not in hal_names:
            continue
        for node in hal.iter():
            if local(node.tag) == "instance" and (node.text or "").strip() == "default":
                wrist_default = True
    if not wrist_default:
        raise RuntimeError("wristorientation/default is not retained")
    if root.attrib.get("level") != level_before:
        raise RuntimeError("FCM level changed unexpectedly")
    tree.write(matrix, encoding="utf-8", xml_declaration=True)
    os.chmod(matrix, 0o644)


def write_privapp_allowlist(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    root = ET.Element("permissions")
    block = ET.SubElement(root, "privapp-permissions", {"package": "com.mobvoi.companion.aw"})
    for perm in PRIV_PERMISSIONS:
        ET.SubElement(block, "permission", {"name": perm})
    ET.indent(root, space="    ")
    ET.ElementTree(root).write(path, encoding="utf-8", xml_declaration=True)
    os.chmod(path, 0o644)


def remove_required(root: Path, relative_paths: list[str]) -> None:
    for rel in relative_paths:
        p = root / rel
        if not p.exists() and not p.is_symlink():
            raise RuntimeError(f"expected Pixel device-specific file not found: {p}")
        if p.is_dir() and not p.is_symlink():
            shutil.rmtree(p)
        else:
            p.unlink()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--system-root", required=True, type=Path,
                    help="Root of Pixel system partition; expected to contain system/")
    ap.add_argument("--system-ext-root", required=True, type=Path,
                    help="Root of Pixel system_ext partition")
    ap.add_argument("--product-root", required=True, type=Path,
                    help="Root of Pixel product partition")
    ap.add_argument("--stage0-bundle", required=True, type=Path)
    ap.add_argument("--report", type=Path)
    args = ap.parse_args()

    system_root = args.system_root.resolve()
    system_ext_root = args.system_ext_root.resolve()
    product_root = args.product_root.resolve()
    bundle = args.stage0_bundle.resolve()
    for p in (system_root, system_ext_root, product_root, bundle):
        if not p.is_dir():
            raise RuntimeError(f"directory missing: {p}")

    source_hashes = read_source_hashes(bundle)

    # Fail closed on donor layout before any edit.
    if not (system_root / "system/build.prop").is_file():
        raise RuntimeError("unexpected system partition layout")
    if not (system_ext_root / "lib").is_dir():
        raise RuntimeError("unexpected system_ext partition layout")
    if not (product_root / "overlay").is_dir():
        raise RuntimeError("unexpected product partition layout")

    remove_required(system_root, REMOVE_SYSTEM)
    remove_required(system_ext_root, REMOVE_SYSTEM_EXT)
    remove_displayoffload_hal(system_root / "system/etc/vintf/wear_compatibility_matrix.7.xml")
    set_properties(system_root / "system/build.prop")
    write_privapp_allowlist(
        system_root / "system/etc/permissions/privapp-permissions-mobvoi-companion.xml"
    )

    destinations: dict[str, Path] = {}
    for src_rel, dst_rel in EXPECTED_PAYLOAD.items():
        if src_rel.startswith("payload/system/"):
            dst = system_root / dst_rel
        elif src_rel.startswith("payload/system_ext/"):
            dst = system_ext_root / dst_rel
        elif src_rel.startswith("payload/product/"):
            dst = product_root / dst_rel
        else:
            raise RuntimeError(f"unhandled frozen payload path: {src_rel}")
        copy_exact(bundle / src_rel, dst, source_hashes[src_rel])
        destinations[src_rel] = dst

    # Directory modes for newly created compatibility islands.
    for d in [
        system_root / "system/priv-app/TicCompanionWear",
        product_root / "overlay/DaceEnduroFastPairOverlay",
    ]:
        os.chmod(d, 0o755)

    report_lines = ["WEAR7_STAGE0_APPLY=PASS"]
    for key, value in PROPS.items():
        report_lines.append(f"PROP {key}={value}")
    for src_rel in sorted(destinations):
        report_lines.append(
            f"PAYLOAD {src_rel} -> {destinations[src_rel]} sha256={source_hashes[src_rel]}"
        )
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text("\n".join(report_lines) + "\n", encoding="utf-8")
    print("\n".join(report_lines))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
