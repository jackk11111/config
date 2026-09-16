#!/usr/bin/env python3
"""Wear7 V6 installer development kit. Hardware writes remain gated.

plan is entirely offline. probe/snapshot read the watch without modifying it.
apply/rollback require a recovery profile backed by a physical transport and
rollback test. The profile registry is intentionally empty until that happens.
No command in this program wipes data, unmounts partitions or reboots the watch.
"""
import argparse
import importlib.util
import json
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import uuid

from transport import (BLOCK, CHUNK, ORDER, Image, atomic_json, canonical,
                       describe, digest, file_digest, session_lock, transfer)

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location(
    "v6_preflight", HERE.parent / "v6" / "recovery-preflight.py")
preflight = importlib.util.module_from_spec(spec)
spec.loader.exec_module(preflight)

NODE = re.compile(r"/dev/block/(?:mmcblk[0-9]+p[0-9]+|sd[a-z]+[0-9]+|nvme[0-9]+n[0-9]+p[0-9]+)")
HEX = re.compile(r"[0-9a-f]{64}")
RAM = "/tmp/wear7-v6-transfer"


def reference():
    return json.loads((HERE / "candidate-v6.json").read_text())


def candidate_images(package):
    package = Path(package).resolve()
    manifest = preflight.verify_package(package)
    if manifest != reference():
        raise ValueError("package differs from the frozen V6 run 35146642220")
    images = {}
    for name in ORDER:
        item = manifest["images"][name + ".img"]
        size = manifest["super_expanded_bytes"] if name == "super" else item["bytes"]
        checksum = manifest["super_expanded_sha256"] if name == "super" else item["sha256"]
        images[name] = Image(name, package / (name + ".img"), size, checksum, name == "super")
    return manifest, images


def require_validated_profile(recovery_hash):
    registry = json.loads((HERE / "validated-recoveries.json").read_text())
    profile = registry.get("profiles", {}).get(recovery_hash)
    required = ("authenticated_wifi_root", "transport_with_super_inactive",
                "scratch_is_ram", "watchdog_safe", "interruption_and_readback",
                "stock_rollback", "physical_reentry")
    if not profile or any(profile.get(key) != "PASS" for key in required):
        raise RuntimeError("HARDWARE_WRITES_BLOCKED: this recovery transport/rollback is not validated")
    if not profile.get("evidence"):
        raise RuntimeError("HARDWARE_WRITES_BLOCKED: recovery profile has no evidence")
    hashes = profile.get("rollback_image_sha256", {})
    if set(hashes) != set(ORDER) or any(not HEX.fullmatch(str(h)) for h in hashes.values()):
        raise RuntimeError("HARDWARE_WRITES_BLOCKED: verified rollback image hashes are missing")
    return profile


class AdbDevice:
    def __init__(self, serial, manifest):
        self.serial = serial
        self.manifest = manifest
        report = preflight.probe_recovery(serial, manifest)
        if report["read_only_probe"] != "PASS":
            raise RuntimeError("recovery not ready: " + "; ".join(report["errors"]))
        props = report["properties"]
        self.nodes = {name: props[f"partition.{name}.path"] for name in ORDER}
        self.sizes = {name: int(props[f"partition.{name}.bytes"]) for name in ORDER}
        if any(not NODE.fullmatch(path) for path in self.nodes.values()):
            raise ValueError("target is not a resolved physical partition")
        serialno = self.shell("getprop ro.boot.serialno").strip()
        if not serialno:
            serialno = self.shell("getprop ro.serialno").strip()
        if not re.fullmatch(r"[A-Za-z0-9._-]{4,128}", serialno):
            raise ValueError("stable hardware serial not confirmed")
        self.boot_id = self.shell("cat /proc/sys/kernel/random/boot_id").strip()
        if not re.fullmatch(r"[0-9a-f-]{36}", self.boot_id):
            raise ValueError("invalid recovery boot ID")
        recovery_node = props["partition.recovery.path"]
        if not NODE.fullmatch(recovery_node):
            raise ValueError("invalid recovery partition")
        recovery_hash = self.hash_output(self.shell("sha256sum " + shlex.quote(recovery_node)))
        self.identity = {"serial": serialno, "device": "dace", "platform": "monaco",
                         "recovery_sha256": recovery_hash, "nodes": self.nodes, "sizes": self.sizes}
        self.assert_ready({"images": {name: {"bytes": size} for name, size in self.sizes.items()}})

    def shell(self, script, timeout=120):
        proc = subprocess.run(["adb", "-s", self.serial, "shell", "sh", "-s"],
                              input="set -eu\n" + script + "\n", text=True,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)
        if proc.returncode:
            raise RuntimeError("ADB command failed: " + proc.stderr.strip() + " " + proc.stdout.strip())
        return proc.stdout.replace("\r", "")

    @staticmethod
    def hash_output(text):
        fields = text.strip().split()
        if not fields or not HEX.fullmatch(fields[0]):
            raise ValueError("missing/invalid device checksum")
        return fields[0]

    def assert_ready(self, description):
        if set(description["images"]) != set(ORDER):
            raise ValueError("incomplete target set")
        script = [
            'test "$(id -u)" = 0',
            f'test "$(cat /proc/sys/kernel/random/boot_id)" = {shlex.quote(self.boot_id)}',
            'test "$(getprop ro.adb.secure)" = 1',
            'for tool in dd sha256sum sync stat blockdev readlink; do command -v "$tool" >/dev/null; done',
        ]
        # Reject all active holders of super, not just familiar mount points:
        # mounted dm-linear/vendor_dlkm aliases must not escape the old preflight.
        for name in ORDER:
            node = self.nodes[name]
            size = description["images"][name]["bytes"]
            if size <= 0 or size % BLOCK or size > self.sizes[name]:
                raise ValueError("image/partition size mismatch: " + name)
            script.extend([
                f'test -b {node}',
                f'test "$(readlink -f /dev/block/by-name/{name})" = {node}',
                f'test "$(blockdev --getsize64 {node})" = {self.sizes[name]}',
                f'test -d /sys/class/block/{Path(node).name}/holders',
                f'for holder in /sys/class/block/{Path(node).name}/holders/*; do '
                'test ! -e "$holder" || { echo "active block-device holder: $holder" >&2; exit 1; }; done',
            ])
        targets = "|".join(self.nodes.values())
        script.extend([
            'for protected in recovery userdata metadata misc persist; do',
            '  p="$(readlink -f "/dev/block/by-name/$protected" 2>/dev/null || true)"',
            f'  case "$p" in {targets}) echo "protected partition alias overlap" >&2; exit 1;; esac',
            'done',
            'while read -r source mountpoint rest; do',
            f'  case "$source" in {targets}) echo "target mounted" >&2; exit 1;; esac',
            '  case "$mountpoint" in /system|/system_root|/vendor|/product|/system_ext|/vendor_dlkm|/system_dlkm)',
            '    echo "logical partition mounted" >&2; exit 1;; esac',
            'done < /proc/mounts',
        ])
        self.shell("\n".join(script))
        self.write_guard = "\n".join(script)

    def check_range(self, name, offset, size):
        if name not in ORDER or offset < 0 or size <= 0 or offset % BLOCK or size % BLOCK:
            raise ValueError("invalid device range")
        if offset + size > self.sizes[name]:
            raise ValueError("device range exceeds partition")
        return self.nodes[name]

    def chunk_hash(self, name, offset, size):
        node = self.check_range(name, offset, size)
        # An unreadable/truncated range cannot equal the expected SHA256, even if
        # a shell without pipefail returns the final sha256sum exit code.
        command = f"dd if={node} bs={BLOCK} skip={offset // BLOCK} count={size // BLOCK} 2>/dev/null | sha256sum"
        return self.hash_output(self.shell(command, timeout=300))

    def begin(self, session):
        require_validated_profile(self.identity["recovery_sha256"])
        self.session = Path(session)
        session_id = self.session / "SESSION_ID"
        if session_id.is_symlink():
            raise ValueError("symlink session identity")
        if not session_id.exists():
            with session_id.open("x") as stream:
                stream.write(uuid.uuid4().hex + "\n")
        nonce = session_id.read_text().strip()
        if not re.fullmatch(r"[0-9a-f]{32}", nonce):
            raise ValueError("invalid session identity")
        self.owner = digest(canonical({"device": self.identity, "nonce": nonce}))
        self.shell(f'''
case "$(stat -f -c %T /tmp)" in tmpfs|ramfs) ;; *) echo 'scratch is not RAM' >&2; exit 1;; esac
test ! -L {RAM}
if mkdir {RAM} 2>/dev/null; then
    echo {self.owner} > {RAM}/owner
fi
test -d {RAM}
test ! -L {RAM}/owner
test "$(cat {RAM}/owner)" = {self.owner}
test ! -L {RAM}/block
''')

    def write_chunk(self, name, offset, data, checksum):
        require_validated_profile(self.identity["recovery_sha256"])
        node = self.check_range(name, offset, len(data))
        if len(data) > CHUNK or digest(data) != checksum:
            raise ValueError("invalid transfer block")
        local = self.session / "transfer-block.bin"
        if local.is_symlink():
            raise ValueError("symlink transfer block")
        local.write_bytes(data)
        try:
            subprocess.run(["adb", "-s", self.serial, "push", str(local), RAM + "/block"],
                           check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=300)
            self.shell(self.write_guard + f'''
test "$(cat /proc/sys/kernel/random/boot_id)" = {shlex.quote(self.boot_id)}
test ! -L {RAM}/block
test -f {RAM}/block
test "$(cat {RAM}/owner)" = {self.owner}
test "$(stat -c %s {RAM}/block)" = {len(data)}
actual="$(sha256sum {RAM}/block)"
test "${{actual%% *}}" = {checksum}
test "$(readlink -f /dev/block/by-name/{name})" = {node}
dd if={RAM}/block of={node} bs={BLOCK} seek={offset // BLOCK} count={len(data) // BLOCK} conv=notrunc
sync
''', timeout=300)
        finally:
            local.unlink(missing_ok=True)

    def finish(self):
        self.shell(f'test "$(cat {RAM}/owner)" = {self.owner}\n'
                   f'rm -f {RAM}/block {RAM}/owner\nrmdir {RAM}')

    def read_image(self, name, destination):
        size = self.sizes[name]
        node = self.check_range(name, 0, size)
        # Explicit remote shell quoting: adb joins the remote argument vector.
        script = f"exec dd if={node} bs={BLOCK} count={size // BLOCK} 2>/dev/null"
        with Path(destination).open("xb") as stream:
            subprocess.run(["adb", "-s", self.serial, "exec-out", "sh", "-c", shlex.quote(script)],
                           stdout=stream, stderr=subprocess.PIPE, check=True, timeout=3600)
            stream.flush()
            import os
            os.fsync(stream.fileno())
        if Path(destination).stat().st_size != size:
            raise RuntimeError("incomplete backup: " + name)
        checksum = file_digest(destination)
        if self.chunk_hash(name, 0, size) != checksum:
            raise RuntimeError("backup differs from device: " + name)
        return checksum


def snapshot(device, directory):
    directory = Path(directory)
    if directory.exists() or directory.is_symlink():
        raise ValueError("snapshot directory must be new; existing backups are not overwritten")
    need = sum(device.sizes.values()) + CHUNK * 2
    if shutil.disk_usage(directory.parent).free < need:
        raise ValueError("not enough phone storage for a complete image rollback snapshot")
    directory.mkdir()
    result = {"format": 1, "scope": "rom-image-partitions-only", "identity": device.identity,
              "images": {}, "origin": "NOT_CLASSIFIED",
              "userdata_backed_up": False, "metadata_backed_up": False}
    for name in ORDER:
        temp = directory / (name + ".img.partial")
        checksum = device.read_image(name, temp)
        temp.rename(directory / (name + ".img"))
        result["images"][name] = {"bytes": device.sizes[name], "sha256": checksum}
        atomic_json(directory / "snapshot-progress.json", result)
    # Only the completed manifest can be supplied to apply/rollback.
    atomic_json(directory / "SNAPSHOT.json", result)
    return result


def backup_images(directory, device):
    directory = Path(directory)
    path = directory / "SNAPSHOT.json"
    if path.is_symlink():
        raise ValueError("symlink snapshot manifest")
    data = json.loads(path.read_text())
    identity = data.get("identity", {})
    if data.get("format") != 1 or data.get("scope") != "rom-image-partitions-only":
        raise ValueError("unsupported backup manifest")
    if identity.get("serial") != device.identity["serial"] or identity.get("device") != "dace":
        raise ValueError("backup belongs to another watch")
    if set(data.get("images", {})) != set(ORDER):
        raise ValueError("incomplete rollback backup")
    result = {}
    for name in ORDER:
        item = data["images"][name]
        if item["bytes"] != device.sizes[name]:
            raise ValueError("rollback backup does not cover the full partition: " + name)
        result[name] = Image(name, directory / (name + ".img"), item["bytes"], item["sha256"])
    return result


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    plan = commands.add_parser("plan", help="verify existing V6 files and prepare bounded transfer plan")
    plan.add_argument("--package", type=Path, required=True)
    plan.add_argument("--session", type=Path, required=True)
    probe = commands.add_parser("probe", help="read-only device readiness; no mount/unmount")
    probe.add_argument("--serial", required=True)
    probe.add_argument("--report", type=Path, required=True)
    snap = commands.add_parser("snapshot", help="read-only capture of the seven image partitions")
    snap.add_argument("--serial", required=True)
    snap.add_argument("--directory", type=Path, required=True)
    for operation in ("apply", "rollback"):
        child = commands.add_parser(operation, help="blocked until the recovery integration is validated")
        child.add_argument("--serial", required=True)
        child.add_argument("--session", type=Path, required=True)
        child.add_argument("--backup", type=Path, required=True)
        if operation == "apply":
            child.add_argument("--package", type=Path, required=True)
    args = parser.parse_args(argv)
    if args.command in ("apply", "rollback"):
        registry = json.loads((HERE / "validated-recoveries.json").read_text())
        if not registry.get("profiles"):
            raise RuntimeError("HARDWARE_WRITES_BLOCKED: no physically validated recovery profile yet")
    if args.command == "plan":
        manifest, images = candidate_images(args.package)
        result = describe(images)
        result.update({"candidate": manifest["candidate"], "source_commit": manifest["source_commit"],
                       "userdata_action": "UNTOUCHED", "metadata_action": "UNTOUCHED",
                       "first_boot_data_decision": "PENDING", "automatic_reboot": False,
                       "hardware_install_validated": False})
        if args.session.exists() or args.session.is_symlink():
            raise ValueError("use a new session directory")
        args.session.mkdir(parents=True)
        atomic_json(args.session / "PLAN.json", result)
        print("PLAN_READY; HARDWARE_INSTALL_VALIDATED=NO; FIRST_BOOT_DATA_DECISION=PENDING")
        return 0
    device = AdbDevice(args.serial, reference())
    if args.command == "probe":
        if args.report.exists() or args.report.is_symlink():
            raise ValueError("report already exists")
        result = {"read_only_probe": "PASS", "identity": device.identity,
                  "hardware_install_validated": False, "userdata_action": "UNTOUCHED"}
        atomic_json(args.report, result)
        print("READ_ONLY_PROBE=PASS; HARDWARE_INSTALL_VALIDATED=NO")
        return 0
    if args.command == "snapshot":
        snapshot(device, args.directory)
        print("ROM_IMAGE_BACKUP=VERIFIED; USERDATA_BACKUP=NO; METADATA_BACKUP=NO")
        return 0
    profile = require_validated_profile(device.identity["recovery_sha256"])
    rollback = backup_images(args.backup, device)
    if any(rollback[name].sha256 != profile["rollback_image_sha256"][name] for name in ORDER):
        raise ValueError("backup does not match the images used for the validated stock rollback")
    rollback_description = describe(rollback)
    if args.command == "apply":
        _, images = candidate_images(args.package)
        description = describe(images)
        operation = "install"
    else:
        images, description, operation = rollback, rollback_description, "rollback"
    # No assumption that restoring images restores encrypted data after Android ran.
    result = transfer(images, description, device, args.session, operation)
    print(result["status"] + "; USERDATA_UNTOUCHED; METADATA_UNTOUCHED; NO_AUTOMATIC_REBOOT")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (Exception, KeyboardInterrupt) as exc:
        print(str(exc), file=sys.stderr)
        raise SystemExit(1)
