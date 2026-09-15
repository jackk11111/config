#!/usr/bin/env python3
"""Add the TicWatch dace wireless maintenance contract to staged Wear7 trees.

This is the first-bringup contract for a CLEAN userdata flash:
  * authenticated adbd listens on TCP/5555;
  * the exact kernel-paired KernelSU Next manager survives factory reset as a
    system app;
  * the exact ARMv7 ksud is stored read-only in system_ext and copied to
    /data/adb/ksud during post-fs-data BEFORE KernelSU's runtime-appended
    post-fs-data action is parsed later in /system/etc/init/hw/init.rc;
  * service.d is seeded before KernelSU's services stage, so persistent Wi-Fi
    and ADB behavior is available on the first Wear7 boot after a wipe.

adbd itself is not made UID0 and ADB authentication is not disabled. The kernel
first-bringup build deliberately grants uid 2000 (authenticated adb shell) KSU
su access, so Termux can use `adb shell` -> `su -c` without a cable or a fresh
Manager approval prompt.
"""
from __future__ import annotations

import argparse
import hashlib
import os
import shutil
from pathlib import Path

ADB_PROPS = {
    "persist.adb.tcp.port": "5555",
    "persist.adb.tls_server.enable": "1",
}
EXPECTED_MANAGER_SHA256 = "8310faebd2b592ccddd6a15a6d996c70d89cd679eb51835e84d18f531471357b"
EXPECTED_KSUD_SHA256 = "c196de59c82030cf14f19c0b170d0ef09203370b533fcbf57dd0d3725d477dca"
MAIN_MARK_BEGIN = "# BEGIN TICWATCH_WEAR7_CLEAN_WIPE_KSU_BOOTSTRAP"
MAIN_MARK_END = "# END TICWATCH_WEAR7_CLEAN_WIPE_KSU_BOOTSTRAP"

MAIN_INIT_BLOCK = r'''# BEGIN TICWATCH_WEAR7_CLEAN_WIPE_KSU_BOOTSTRAP
# This block intentionally lives in the main init.rc. KernelSU Next's built-in
# runtime appends its own post-fs-data action after the original init.rc EOF,
# so this action is parsed first and seeds /data/adb/ksud after a factory reset.
on post-fs-data
    mkdir /data/adb 0700 root root
    mkdir /data/adb/service.d 0700 root root
    copy /system_ext/bin/ksud /data/adb/ksud
    chown root root /data/adb/ksud
    chmod 0755 /data/adb/ksud
    copy /system_ext/etc/wear7/96-wifi-adb-persistent.sh /data/adb/service.d/96-wifi-adb-persistent.sh
    chown root root /data/adb/service.d/96-wifi-adb-persistent.sh
    chmod 0755 /data/adb/service.d/96-wifi-adb-persistent.sh
    restorecon_recursive /data/adb
# END TICWATCH_WEAR7_CLEAN_WIPE_KSU_BOOTSTRAP
'''

INIT_RC = r'''# TicWatch Pro 5 Enduro Wear7 wireless maintenance bootstrap.
# Authentication is intentionally retained; this only makes adbd listen on TCP/5555.
on boot
    setprop persist.adb.tcp.port 5555
    setprop service.adb.tcp.port 5555
    setprop persist.adb.tls_server.enable 1
    start adbd

on property:sys.boot_completed=1
    setprop persist.adb.tcp.port 5555
    setprop service.adb.tcp.port 5555
    setprop persist.adb.tls_server.enable 1
    restart adbd
'''

# This consolidates the already verified Wear4 behavior into one Android shell
# script. It is placed in service.d during post-fs-data, before KernelSU reaches
# its userspace services stage on the same clean first boot.
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

    # Proven Wear4 no-suspend resource override. Wear7 may already expose an
    # equivalent resource; failures are non-fatal and logged for first boot.
    cmd overlay fabricate --user 0 --target-name WifiCustomization \
        --target com.android.wifi.resources --name WifiNoSuspend \
        com.android.wifi.resources:bool/config_wifiSuspendOptimizationsEnabled \
        0x12 0x0 || true
    cmd overlay enable --user 0 com.android.shell:WifiNoSuspend || true
    cmd wifi reload-resources || true

    setprop ctl.restart adbd
    echo "ADB_TCP=$(getprop service.adb.tcp.port)"
    echo "ADB_TLS=$(getprop persist.adb.tls_server.enable)"
    echo "KSUD=$(ls -lZ /data/adb/ksud 2>/dev/null || true)"
    echo "WIRELESS_BOOT_DONE $(date)"
) &
exit 0
'''


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


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
    os.chmod(path, 0o644)
    return [f"{k}={v}" for k, v in ADB_PROPS.items()]


def write_exact(path: Path, content: str, mode: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")
    os.chmod(path, mode)


def copy_exact(src: Path, dst: Path, expected: str, mode: int) -> str:
    if not src.is_file():
        raise RuntimeError(f"missing input: {src}")
    got = sha256(src)
    if got != expected:
        raise RuntimeError(f"hash mismatch for {src}: {got} != {expected}")
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(src, dst)
    os.chmod(dst, mode)
    got2 = sha256(dst)
    if got2 != expected:
        raise RuntimeError(f"post-copy hash mismatch for {dst}: {got2} != {expected}")
    return got2


def append_main_init_bootstrap(path: Path) -> None:
    if not path.is_file():
        raise RuntimeError(f"main Android init.rc missing: {path}")
    text = path.read_text(encoding="utf-8", errors="strict")
    if MAIN_MARK_BEGIN in text or MAIN_MARK_END in text:
        if text.count(MAIN_MARK_BEGIN) != 1 or text.count(MAIN_MARK_END) != 1:
            raise RuntimeError("corrupt/duplicate Wear7 KSU bootstrap markers in main init.rc")
        before, tail = text.split(MAIN_MARK_BEGIN, 1)
        _, after = tail.split(MAIN_MARK_END, 1)
        text = before.rstrip() + "\n" + after.lstrip("\n")
    # Deliberately append at the original EOF. The built-in KernelSU read hook
    # appends its generated rc only at runtime after these bytes.
    text = text.rstrip() + "\n\n" + MAIN_INIT_BLOCK.rstrip() + "\n"
    path.write_text(text, encoding="utf-8")
    os.chmod(path, 0o644)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--system-root", required=True, type=Path)
    ap.add_argument("--system-ext-root", required=True, type=Path)
    ap.add_argument("--ksu-manager-apk", required=True, type=Path)
    ap.add_argument("--ksud", required=True, type=Path)
    ap.add_argument("--report", type=Path)
    args = ap.parse_args()

    system = args.system_root.resolve()
    system_ext = args.system_ext_root.resolve()
    if not (system / "system/build.prop").is_file():
        raise RuntimeError("unexpected Pixel system tree")
    if not (system_ext / "etc/init").is_dir():
        raise RuntimeError("unexpected Pixel system_ext tree: etc/init missing")

    props = set_props(system / "system/build.prop")
    main_init = system / "system/etc/init/hw/init.rc"
    append_main_init_bootstrap(main_init)

    rc = system_ext / "etc/init/wear7-dace-wireless-bootstrap.rc"
    svc = system_ext / "etc/wear7/96-wifi-adb-persistent.sh"
    ksud_dst = system_ext / "bin/ksud"
    manager_dst = system / "system/app/KernelSUNextManager/KernelSUNextManager.apk"
    write_exact(rc, INIT_RC, 0o644)
    write_exact(svc, KSU_SERVICE, 0o755)
    ksud_hash = copy_exact(args.ksud.resolve(), ksud_dst, EXPECTED_KSUD_SHA256, 0o755)
    manager_hash = copy_exact(args.ksu_manager_apk.resolve(), manager_dst, EXPECTED_MANAGER_SHA256, 0o644)

    # Fail closed on accidental security weakening.
    text = (system / "system/build.prop").read_text(encoding="utf-8")
    forbidden = ("ro.adb.secure=0", "ro.secure=0", "ro.debuggable=1")
    for marker in forbidden:
        if marker in text:
            raise RuntimeError(f"forbidden debug weakening present: {marker}")
    main_text = main_init.read_text(encoding="utf-8")
    if main_text.count(MAIN_MARK_BEGIN) != 1 or main_text.count(MAIN_MARK_END) != 1:
        raise RuntimeError("main init clean-wipe bootstrap marker invariant lost")
    required_main = (
        "on post-fs-data",
        "copy /system_ext/bin/ksud /data/adb/ksud",
        "copy /system_ext/etc/wear7/96-wifi-adb-persistent.sh /data/adb/service.d/96-wifi-adb-persistent.sh",
        "restorecon_recursive /data/adb",
    )
    for marker in required_main:
        if marker not in main_text:
            raise RuntimeError(f"main init invariant lost: {marker}")
    if "5555" not in INIT_RC or "5555" not in KSU_SERVICE:
        raise RuntimeError("TCP/5555 invariant lost")
    if "setprop ctl.restart adbd" not in KSU_SERVICE:
        raise RuntimeError("persistent adbd restart invariant lost")
    if "config_wifiSuspendOptimizationsEnabled" not in KSU_SERVICE:
        raise RuntimeError("WifiNoSuspend invariant lost")

    rows = [
        "WEAR7_DACE_WIRELESS_BOOTSTRAP=PASS",
        "KERNELSU_CLEAN_WIPE_USERSPACE_BOOTSTRAP=PASS",
        "ADB_AUTHENTICATION_DISABLED=NO",
        "ADB_TCP_PORT=5555",
        "ROOT_PATH=authenticated_adb_shell_then_KernelSU_su_c",
        "KSU_SHELL_UID2000_KERNEL_REQUIREMENT=YES",
        "FIRST_BOOT_INIT_ADBD=YES",
        "KSU_SERVICE_D_SEEDED_AT_POST_FS_DATA=YES",
        "WIFI_NOSUSPEND_BEST_EFFORT=YES",
        f"KSU_MANAGER_SHA256={manager_hash}",
        f"KSUD_ARMV7_SHA256={ksud_hash}",
        f"MAIN_INIT={main_init}",
        f"INIT_RC={rc}",
        f"KSU_SERVICE={svc}",
        f"KSUD_SYSTEM_COPY={ksud_dst}",
        f"KSU_MANAGER_SYSTEM_APP={manager_dst}",
    ] + [f"PROP {p}" for p in props]
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text("\n".join(rows) + "\n", encoding="utf-8")
    print("\n".join(rows))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
