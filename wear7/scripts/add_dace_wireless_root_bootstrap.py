#!/usr/bin/env python3
"""Add the TicWatch dace wireless maintenance contract to staged Wear7 trees.

Offline-only. This does not disable ADB authentication and never touches a device.
It provides:
  * first-boot adbd TCP/5555 defaults through Android properties/init;
  * a KernelSU service.d payload seeded after boot for persistent Wi-Fi + ADB;
  * the already proven WifiNoSuspend fabricated overlay logic.

Runtime root remains KernelSU (`adb shell` -> `su -c`); adbd itself is not forced UID0.
"""
from __future__ import annotations

import argparse
import os
from pathlib import Path

ADB_PROPS = {
    "persist.adb.tcp.port": "5555",
    "persist.adb.tls_server.enable": "1",
}

INIT_RC = r'''# TicWatch Pro 5 Enduro Wear7 wireless maintenance bootstrap.
# Authentication is intentionally retained; this only makes adbd listen on TCP/5555.
on boot
    setprop service.adb.tcp.port 5555
    start adbd

on property:sys.boot_completed=1
    setprop persist.adb.tcp.port 5555
    setprop service.adb.tcp.port 5555
    setprop persist.adb.tls_server.enable 1
    restart adbd

    # KernelSU normally creates /data/adb. mkdir is idempotent and keeps root ownership.
    mkdir /data/adb 0700 root root
    mkdir /data/adb/service.d 0700 root root
    copy /system_ext/etc/wear7/96-wifi-adb-persistent.sh /data/adb/service.d/96-wifi-adb-persistent.sh
    chown root root /data/adb/service.d/96-wifi-adb-persistent.sh
    chmod 0755 /data/adb/service.d/96-wifi-adb-persistent.sh
'''

# This consolidates the already verified Wear4 semantics into one Android-shell script.
# It runs from KernelSU service.d on subsequent boots. Individual settings/overlay calls
# are best-effort so a renamed Wear7 setting cannot block adbd persistence.
KSU_SERVICE = r'''#!/system/bin/sh
(
    LOG=/data/local/tmp/wear7_dace_wireless.log
    exec >>"$LOG" 2>&1
    echo "WIRELESS_BOOT_START $(date)"

    i=0
    while [ "$(getprop sys.boot_completed)" != "1" ] && [ "$i" -lt 180 ]; do
        i=$((i+1))
        sleep 2
    done
    sleep 5

    settings put global wifi_sleep_policy 2 || true
    settings put global wifi_wakeup_enabled 1 || true
    settings put global wifi_scan_always_enabled 1 || true
    settings put global cw_disable_wifimediator 1 || true
    settings put system clockwork_wifi_setting on || true
    svc wifi enable || true
    svc bluetooth enable || true

    settings put global adb_enabled 1 || true
    settings put global adb_wifi_enabled 1 || true
    setprop persist.adb.tcp.port 5555
    setprop service.adb.tcp.port 5555
    setprop persist.adb.tls_server.enable 1

    # Proven Wear4 no-suspend resource override. Wear7 may already provide an
    # equivalent resource; failures are non-fatal and are logged for first boot.
    cmd overlay fabricate --user 0 --target-name WifiCustomization \
        --target com.android.wifi.resources --name WifiNoSuspend \
        com.android.wifi.resources:bool/config_wifiSuspendOptimizationsEnabled \
        0x12 0x0 || true
    cmd overlay enable --user 0 com.android.shell:WifiNoSuspend || true
    cmd wifi reload-resources || true

    setprop ctl.restart adbd
    echo "ADB_TCP=$(getprop service.adb.tcp.port)"
    echo "ADB_TLS=$(getprop persist.adb.tls_server.enable)"
    echo "WIRELESS_BOOT_DONE $(date)"
) &
exit 0
'''


def set_props(path: Path) -> list[str]:
    if not path.is_file():
        raise RuntimeError(f"missing build.prop: {path}")
    lines = path.read_text(encoding="utf-8", errors="strict").splitlines()
    seen: set[str] = set()
    out: list[str] = []
    for line in lines:
        if line.strip() and not line.lstrip().startswith("#") and "=" in line:
            key = line.split("=", 1)[0].strip()
            if key in ADB_PROPS:
                if key not in seen:
                    out.append(f"{key}={ADB_PROPS[key]}")
                    seen.add(key)
                continue
        out.append(line)
    for key, value in ADB_PROPS.items():
        if key not in seen:
            out.append(f"{key}={value}")
    path.write_text("\n".join(out) + "\n", encoding="utf-8")
    # Android build.prop is a root-owned, world-readable configuration file.
    # The staging script runs as root in CI, so explicitly restore the normal
    # 0644 mode instead of inheriting Python's create/write umask semantics.
    os.chmod(path, 0o644)
    return [f"{k}={v}" for k, v in ADB_PROPS.items()]


def write_exact(path: Path, content: str, mode: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")
    os.chmod(path, mode)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--system-root", required=True, type=Path)
    ap.add_argument("--system-ext-root", required=True, type=Path)
    ap.add_argument("--report", type=Path)
    args = ap.parse_args()

    system = args.system_root.resolve()
    system_ext = args.system_ext_root.resolve()
    if not (system / "system/build.prop").is_file():
        raise RuntimeError("unexpected Pixel system tree")
    if not (system_ext / "etc/init").is_dir():
        raise RuntimeError("unexpected Pixel system_ext tree: etc/init missing")

    props = set_props(system / "system/build.prop")
    rc = system_ext / "etc/init/wear7-dace-wireless-bootstrap.rc"
    svc = system_ext / "etc/wear7/96-wifi-adb-persistent.sh"
    write_exact(rc, INIT_RC, 0o644)
    write_exact(svc, KSU_SERVICE, 0o755)

    # Fail closed on accidental security weakening.
    text = (system / "system/build.prop").read_text(encoding="utf-8")
    forbidden = ("ro.adb.secure=0", "ro.secure=0", "ro.debuggable=1")
    for marker in forbidden:
        if marker in text:
            raise RuntimeError(f"forbidden debug weakening present: {marker}")
    if "5555" not in INIT_RC or "5555" not in KSU_SERVICE:
        raise RuntimeError("TCP/5555 invariant lost")
    if "setprop ctl.restart adbd" not in KSU_SERVICE:
        raise RuntimeError("persistent adbd restart invariant lost")
    if "config_wifiSuspendOptimizationsEnabled" not in KSU_SERVICE:
        raise RuntimeError("WifiNoSuspend invariant lost")

    rows = [
        "WEAR7_DACE_WIRELESS_BOOTSTRAP=PASS",
        "ADB_AUTHENTICATION_DISABLED=NO",
        "ADB_TCP_PORT=5555",
        "ROOT_PATH=adb_shell_then_KernelSU_su_c",
        "FIRST_BOOT_INIT_ADBD=YES",
        "KSU_SERVICE_D_SEED=YES",
        "WIFI_NOSUSPEND_BEST_EFFORT=YES",
        f"INIT_RC={rc}",
        f"KSU_SERVICE={svc}",
    ] + [f"PROP {p}" for p in props]
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text("\n".join(rows) + "\n", encoding="utf-8")
    print("\n".join(rows))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
