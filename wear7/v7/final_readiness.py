#!/usr/bin/env python3
"""Final offline readiness gate for Wear7-V7.

This intentionally does not claim runtime hardware functionality. It answers a
narrower question: after the validated V7 build, is any known software-side
pre-first-boot blocker left other than recovery/rollback integration?
"""
import argparse
import json
from pathlib import Path

PASS_GATES = ("APEX_INTEGRATION", "OFFICIAL_VINTF", "SELINUX_POLICY", "FASTPAIR_IDMAP2")
CORE_SYSTEM_HASHES = {
    "system/priv-app/AssistantWearPrebuilt/AssistantWearPrebuilt.apk": "3434942e08ba875f53783ed4fbd2a2510bdcbc988430177df20247d23eeefecd",
    "system/etc/permissions/privapp-permissions-pixel-watch-assistant.xml": "b95661e7289689bcc6fd30f39f9aad6e9a32ff3b0b48880b281a717d6e5d8221",
    "system/priv-app/ClockworkSetupWizard/ClockworkSetupWizard.apk": "05280cd284cf409512f5a58d84fe639951337c16f95537a85fd9d20ab6efe0c7",
    "system/priv-app/WearServicesGoogle/WearServicesGoogle.apk": "12f8568683995f485e104100f57f8891d8e7ca0af905ee5180d2139a08b8ce52",
    "system/priv-app/WearHealthServicesPrebuilt/WearHealthServicesPrebuilt.apk": "55aa712ddbb6b34b85570cc400a04827fa6cd81bf2c076a092c1309e31ab28c1",
    "system/framework/com.google.android.wearable.jar": "cd50a687046811a21c867a5e8ed56cd958d747e04a5b5ac50643009b1a497c3e",
    "system/framework/wear-service.jar": "d912001d9f9c8b89f619db2454b4f9267dbe7831c4d36d3d7cb68b89d41c68fb",
    "system/priv-app/TicCompanionWear/TicCompanionWear.apk": "e3eb90b99cd170958d376f7d3b33f3af3bf257dcd025cddada79e1c1797fe8fe",
    "system/priv-app/PrebuiltTapAndPayWearable/PrebuiltTapAndPayWearable.apk": "afd63b87b0ed41cd21c4793369f1b6b5a237747241e65e0d85d3eea99f3bdc49",
}


def load(path):
    return json.loads(Path(path).read_text())


def filesystem_hashes(path):
    result = {}
    for line in Path(path).read_text().splitlines():
        fields = line.split("\t")
        if len(fields) >= 6 and fields[1] == "f":
            result[fields[0]] = fields[5]
    return result


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--package", type=Path, required=True)
    p.add_argument("--analysis", type=Path, required=True)
    p.add_argument("--reference", type=Path, required=True)
    p.add_argument("--output", type=Path, required=True)
    a = p.parse_args()

    candidate = load(a.package / "CANDIDATE.json")
    reference = load(a.reference)
    if candidate != reference:
        raise SystemExit("V7 artifact manifest differs from frozen installer reference")
    if candidate.get("candidate") != "Wear7-V7" or candidate.get("source_commit") != "6125c80f798994ee53749f85a833c24da5940765":
        raise SystemExit("unexpected V7 identity")
    if candidate.get("offline_gates", {}).get("NATIVE_STOCK32_COMPAT", {}).get("status") != "PASS":
        raise SystemExit("V7 native compatibility gate missing")

    gates = load(a.analysis / "GATES.json")
    for gate in PASS_GATES:
        if gates.get(gate, {}).get("status") != "PASS":
            raise SystemExit("offline gate failed: " + gate)

    package_preflight = load(a.analysis / "PACKAGE_PREFLIGHT_V7.json")
    if package_preflight.get("package") != "PASS" or package_preflight.get("candidate") != "Wear7-V7":
        raise SystemExit("V7 package preflight did not pass")

    native = load(a.analysis / "NATIVE_STOCK32_COMPAT.json")
    if native.get("status") != "PASS" or len(native.get("injected_stock379", {})) != 11:
        raise SystemExit("stock379 ARM32 compatibility repair not fully gated")
    critical = native.get("critical_targets", {})
    if len(critical) < 20:
        raise SystemExit("critical hardware target audit unexpectedly incomplete")
    bad = {
        name: row for name, row in critical.items()
        if row.get("missing_needed_recursive") or row.get("unresolved_strong_imports")
    }
    if bad:
        raise SystemExit("unresolved native hardware dependencies: " + ", ".join(sorted(bad)))

    fs = filesystem_hashes(a.analysis / "system_final.tsv")
    for path, expected in CORE_SYSTEM_HASHES.items():
        if fs.get(path) != expected:
            raise SystemExit("core Wear/Gemini/pairing component changed or missing: " + path)

    idmap = (a.analysis / "IDMAP_DUMP.log").read_text(errors="replace")
    overlay = (a.analysis / "DACE_OVERLAY_RESOURCES.log").read_text(errors="replace")
    if "0x7f11021a -> 0x7f010000" not in idmap or '"3D558B"' not in overlay:
        raise SystemExit("Enduro Fast Pair overlay mapping evidence missing")

    active_vndk = load(a.analysis / "ACTIVE_VNDK33.json")
    if len(active_vndk) != 1 or active_vndk[0].get("moduleName") != "com.android.vndk.v33" or active_vndk[0].get("isActive") != "true":
        raise SystemExit("VNDK33 active APEX evidence invalid")

    result = {
        "format": 1,
        "candidate": "Wear7-V7",
        "source_run": 35198609607,
        "source_commit": candidate["source_commit"],
        "offline_readiness": "PASS",
        "native_hardware_dependency_targets": len(critical),
        "native_hardware_dependency_closure": "PASS",
        "wear_framework_static": "PASS",
        "pairing_fastpair_static": "PASS",
        "gemini_native_static": "PASS",
        "tap_and_pay_component_static": "PASS",
        "gms_product_lineage": "PRESERVED_FROM_VALIDATED_V6_PIXEL_DONOR",
        "known_pre_first_boot_blockers": ["RECOVERY_INTEGRATION_AND_ROLLBACK_QUALIFICATION"],
        "runtime_tests_after_first_boot": [
            "boot_completion_and_setupwizard",
            "companion_pairing_and_fast_pair",
            "google_play_and_gms_runtime",
            "gemini_native_invocation_and_response",
            "nfc_and_tap_to_pay_runtime",
            "wifi_and_bluetooth_runtime",
            "audio_and_soundtrigger_runtime",
            "display_touch_sensors_gnss_haptics_health_power_charge_suspend",
            "adb_root_and_recovery_persistence_after_reboot"
        ],
        "flash_authorized": False,
        "reason_flash_blocked": "recovery transport, reset, persistence and rollback still require physical qualification"
    }
    if a.output.exists():
        raise SystemExit("refusing to overwrite readiness report")
    a.output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
