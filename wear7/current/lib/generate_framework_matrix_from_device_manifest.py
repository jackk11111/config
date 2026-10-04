#!/usr/bin/env python3
"""Generate a supplemental framework compatibility matrix from device manifests.

This is intentionally narrow: it converts HAL declarations present in the selected
stock device manifest + manifest fragments into framework-matrix HAL entries, and
adds the exact device SELinux compatibility version. It does not invent HALs.
"""

import argparse
import copy
import pathlib
import re
import xml.etree.ElementTree as ET


def text(el, name):
    c = el.find(name)
    return None if c is None or c.text is None else c.text.strip()


def add_interface(dst_hal, iface_name, instance):
    for iface in dst_hal.findall("interface"):
        if text(iface, "name") == iface_name:
            existing = {i.text.strip() for i in iface.findall("instance") if i.text}
            if instance not in existing:
                ET.SubElement(iface, "instance").text = instance
            return
    iface = ET.SubElement(dst_hal, "interface")
    ET.SubElement(iface, "name").text = iface_name
    ET.SubElement(iface, "instance").text = instance


def parse_fqname(fmt, fq):
    fq = fq.strip()
    if fmt == "hidl":
        m = re.fullmatch(r"@([^:]+)::([^/]+)/(.+)", fq)
        if not m:
            raise ValueError(f"bad HIDL fqname: {fq}")
        return m.group(1), m.group(2), m.group(3)
    if fmt == "aidl":
        m = re.fullmatch(r"([^/]+)/(.+)", fq)
        if not m:
            raise ValueError(f"bad AIDL fqname: {fq}")
        return None, m.group(1), m.group(2)
    raise ValueError(f"unsupported HAL format: {fmt}")


def canonical_hal(src):
    fmt = src.attrib.get("format", "hidl")
    name = text(src, "name")
    if not name:
        raise ValueError("HAL without <name>")
    dst = ET.Element("hal", {"format": fmt, "optional": "true"})
    ET.SubElement(dst, "name").text = name

    versions = []
    for v in src.findall("version"):
        if v.text and v.text.strip() not in versions:
            versions.append(v.text.strip())

    interfaces = []
    for iface in src.findall("interface"):
        iname = text(iface, "name")
        if not iname:
            continue
        for inst in iface.findall("instance"):
            if inst.text:
                interfaces.append((iname, inst.text.strip()))
        for inst in iface.findall("regex-instance"):
            if inst.text:
                # Preserve regex-instance form separately below.
                interfaces.append((iname, ("REGEX", inst.text.strip())))

    for fq in src.findall("fqname"):
        if not fq.text:
            continue
        ver, iname, inst = parse_fqname(fmt, fq.text)
        if ver and ver not in versions:
            versions.append(ver)
        if (iname, inst) not in interfaces:
            interfaces.append((iname, inst))

    for v in versions:
        ET.SubElement(dst, "version").text = v

    # Group normal + regex instances by interface.
    by_iface = {}
    for iname, inst in interfaces:
        by_iface.setdefault(iname, []).append(inst)
    for iname in sorted(by_iface):
        iface = ET.SubElement(dst, "interface")
        ET.SubElement(iface, "name").text = iname
        seen = set()
        for inst in by_iface[iname]:
            key = inst if isinstance(inst, str) else tuple(inst)
            if key in seen:
                continue
            seen.add(key)
            if isinstance(inst, tuple) and inst[0] == "REGEX":
                ET.SubElement(iface, "regex-instance").text = inst[1]
            else:
                ET.SubElement(iface, "instance").text = inst

    if not by_iface:
        raise ValueError(f"HAL {name} has no interface/instance")
    return dst


def hal_key(hal):
    return ET.tostring(hal, encoding="unicode")


def indent(elem, level=0):
    pad = "    "
    i = "\n" + level * pad
    if len(elem):
        if not elem.text or not elem.text.strip():
            elem.text = i + pad
        for child in elem:
            indent(child, level + 1)
        if not elem[-1].tail or not elem[-1].tail.strip():
            elem[-1].tail = i
    if level and (not elem.tail or not elem.tail.strip()):
        elem.tail = i


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--main", required=True, type=pathlib.Path)
    ap.add_argument("--fragments", type=pathlib.Path)
    ap.add_argument("--out", required=True, type=pathlib.Path)
    ap.add_argument("--sepolicy-version", default="33.0")
    ap.add_argument("--kernel-sepolicy-version", default="30")
    ap.add_argument("--matrix-version", default="9.0")
    args = ap.parse_args()

    paths = [args.main]
    if args.fragments and args.fragments.is_dir():
        paths += sorted(args.fragments.glob("*.xml"))

    hals = []
    seen = set()
    main_target = None
    source_summary = []
    for p in paths:
        root = ET.parse(p).getroot()
        if root.tag != "manifest" or root.attrib.get("type") != "device":
            raise SystemExit(f"not a device manifest: {p}")
        if p == args.main:
            main_target = root.attrib.get("target-level")
        count = 0
        for src in root.findall("hal"):
            dst = canonical_hal(src)
            key = hal_key(dst)
            if key not in seen:
                seen.add(key)
                hals.append(dst)
            count += 1
        source_summary.append((str(p), count))

    root = ET.Element("compatibility-matrix", {"version": args.matrix_version, "type": "framework"})
    for h in sorted(hals, key=lambda x: (text(x, "name") or "", x.attrib.get("format", ""), hal_key(x))):
        root.append(copy.deepcopy(h))

    sepolicy = ET.SubElement(root, "sepolicy")
    ET.SubElement(sepolicy, "kernel-sepolicy-version").text = args.kernel_sepolicy_version
    ET.SubElement(sepolicy, "sepolicy-version").text = args.sepolicy_version

    indent(root)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    ET.ElementTree(root).write(args.out, encoding="utf-8", xml_declaration=True)
    with args.out.open("a", encoding="utf-8") as f:
        f.write("\n")

    print(f"DACE_FRAMEWORK_MATRIX_GENERATED=YES")
    print(f"MAIN_TARGET_LEVEL={main_target or ''}")
    print(f"SOURCE_FILES={len(paths)}")
    print(f"UNIQUE_HAL_ENTRIES={len(hals)}")
    print(f"SEPOLICY_VERSION={args.sepolicy_version}")
    for p, n in source_summary:
        print(f"SOURCE\t{p}\tHALS={n}")


if __name__ == "__main__":
    main()
