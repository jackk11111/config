#!/usr/bin/env python3
"""Read-only manifest and device preflight: passes ONLY checked criteria."""
import sys, re, subprocess
import xml.etree.ElementTree as ET
from pathlib import Path

PINS = {
    "device/xiaomi/annibale": "f72856e059954c73eb43c7ce529008ba9d3c36ca",
    "device/xiaomi/annibale-kernel": "1de1a259b485155670b1fba04b7445ff37a1ec52",
    "vendor/xiaomi/annibale": "f34647e4a03e376251b8ff32e650ceb9d9c13885",
    "hardware/xiaomi": "7dd87795288bf6713795f112056b1bf549355c81",
}
mode, arg = sys.argv[1:]
path = Path(arg)
if mode in ("manifest", "resolved"):
    xml = ET.parse(path).getroot()
    assert xml.tag == "manifest", "Invalid root element"
    projects = xml.findall("project")
    # repo manifest -o omits "path" when it equals "name" (repo manifest_xml.py).
    # Treat that omission as the documented default, NOT a duplicate None.
    paths = [p.get("path") or p.get("name") for p in projects]
    assert all(paths), "Project with neither path nor name"
    duplicates = sorted({p for p in paths if paths.count(p) > 1})
    assert not duplicates, f"Duplicate effective project paths: {duplicates[:20]}"
    for key, sha in PINS.items():
        hits = [p for p in projects if p.get("path") == key]
        assert len(hits) == 1, f"Missing project: {key}"
        assert hits[0].get("revision") == sha, f"Unexpected SHA: {key}"
        if mode == "manifest":
            assert hits[0].get("upstream") == "refs/heads/lineage-24.0", f"Missing upstream {key}"
    if mode == "manifest":
        assert len(projects) == 4, "Only four device-related projects expected"
        assert [r for r in xml.findall("remote") if r.get("name") == "annibale-gitlab"]
    if mode == "resolved":
        for essential in ["vendor/lineage", "hardware/nxp/keymint", "hardware/nxp/nfc",
                          "hardware/nxp/weaver", "hardware/lineage/interfaces",
                          "hardware/qcom-caf/sm8750/audio/primary-hal", "packages/apps/Aperture"]:
            assert essential in paths, f"EvoX base project missing: {essential}"
    print("PASS:", mode, "projects:", len(projects))
elif mode == "device":
    assert path.is_dir(), "Source checkout missing"
    req = {
       "device/xiaomi/annibale": ["BoardConfig.mk", "device.mk", "lineage_annibale.mk", "proprietary-files.txt"],
       "device/xiaomi/annibale-kernel": ["images/kernel", "images/dtbo.img", "modules/vendor_boot/modules.load",
          "modules/vendor_boot/modules.load.recovery", "modules/vendor_dlkm/modules.load"],
       "hardware/xiaomi": ["aidl/fingerprint/Android.bp"],
    }
    for d, files in req.items():
        root = path/d
        for f in files:
            assert (root/f).is_file(), f"Missing {d}/{f}"
        actual = subprocess.check_output(["git", "-C", str(root), "rev-parse", "HEAD"], text=True).strip()
        assert actual == PINS[d], f"SHA mismatch {d}: {actual}"
    kernel = path/"device/xiaomi/annibale-kernel/modules"
    for parent, filename in [("vendor_boot", "modules.load"), ("vendor_boot", "modules.load.recovery"),
                             ("vendor_dlkm", "modules.load"),
                             ("system_dlkm/6.6.118-android15-8-ge56cf6b09cca-ab15511674-4k","modules.load")]:
        file = kernel/parent/filename
        assert file.is_file(), f"Missing kernel load list: {file}"
        modules = [x.strip() for x in file.read_text().splitlines() if x.strip() and not x.lstrip().startswith("#")]
        bad = [m for m in modules if m.startswith("/") or ".." in Path(m).parts or not (file.parent/m).is_file()]
        assert not bad, f"Missing modules: {bad[:5]}"
        print("PASS kernel:", parent, filename, len(modules))
    print("PASS: source SHA + required files + kernel module inventory")
else:
    raise SystemExit("Valid phases: manifest, resolved, device")
