"""New installer failure tests. All targets are temporary ordinary files.

These do not rerun ROM validation and cannot establish hardware readiness.
"""
import copy
import json
from pathlib import Path
import struct
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import transport as t
import wear7_installer as cli


def sparse_bytes(raw, fill_blocks=1, zero_blocks=1):
    count = len(raw) // t.BLOCK
    header = struct.pack("<I4H4I", 0xED26FF3A, 1, 0, 28, 12, t.BLOCK,
                         count + fill_blocks + zero_blocks, 3, 0)
    return (header + struct.pack("<2H2I", 0xCAC1, 0, count, 12 + len(raw)) + raw
            + struct.pack("<2H2I", 0xCAC2, 0, fill_blocks, 16) + b"\x12\x34\x56\x78"
            + struct.pack("<2H2I", 0xCAC3, 0, zero_blocks, 12))


class FileDevice:
    def __init__(self, directory, sizes):
        self.directory = Path(directory)
        self.directory.mkdir()
        self.sizes = sizes
        self.identity = {"serial": "TEST-WATCH", "device": "dace"}
        self.writes = []
        self.failure = None
        self.corrupt = False
        self.final_corrupt = False
        self.mounted = False
        for name, size in sizes.items():
            (self.directory / name).write_bytes(b"Z" * size)
        for name in ("userdata", "metadata", "recovery", "persist", "misc"):
            (self.directory / name).write_bytes(b"MUST REMAIN UNTOUCHED")

    def assert_ready(self, description):
        if self.mounted:
            raise RuntimeError("active target mount")
        for name, value in description["images"].items():
            if name not in t.ORDER or value["bytes"] > self.sizes[name]:
                raise ValueError("invalid target")

    def begin(self, session):
        pass

    def chunk_hash(self, name, offset, size):
        with (self.directory / name).open("r+b") as stream:
            if self.final_corrupt and offset == 0 and size == self.sizes[name] and self.writes:
                stream.write(b"!")
                stream.flush()
                self.final_corrupt = False
            stream.seek(offset)
            return t.digest(stream.read(size))

    def write_chunk(self, name, offset, data, checksum):
        self.writes.append((name, offset))
        fail = self.failure == (name, offset)
        with (self.directory / name).open("r+b") as stream:
            stream.seek(offset)
            if fail:
                stream.write(data[:len(data) // 2])
            elif self.corrupt:
                stream.write(b"!" + data[1:])
            else:
                stream.write(data)
        if fail:
            self.failure = None
            raise ConnectionError("simulated lost Wi-Fi during device write")

    def finish(self):
        pass


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.sources = self.root / "sources"
        self.sources.mkdir()
        self.images = {}
        self.expected = {}
        for index, name in enumerate(t.ORDER):
            data = bytes([index + 65]) * (t.BLOCK * 3)
            if name == "super":
                raw = b"A" * t.BLOCK
                data = raw + b"\x12\x34\x56\x78" * (t.BLOCK // 4) + b"\0" * t.BLOCK
                encoded = sparse_bytes(raw)
            else:
                encoded = data
            path = self.sources / (name + ".img")
            path.write_bytes(encoded)
            self.expected[name] = data
            self.images[name] = t.Image(name, path, len(data), t.digest(data), name == "super")
        self.description = t.describe(self.images, chunk_size=t.BLOCK)
        self.target = FileDevice(self.root / "device", {k: len(v) for k, v in self.expected.items()})
        self.session = self.root / "session"

    def tearDown(self):
        self.temp.cleanup()

    def run_transfer(self, operation="install", images=None, description=None):
        return t.transfer(images or self.images, description or self.description,
                          self.target, self.session, operation)

    def assert_complete(self):
        for name, data in self.expected.items():
            self.assertEqual((self.target.directory / name).read_bytes(), data)
        for name in ("userdata", "metadata", "recovery", "persist", "misc"):
            self.assertEqual((self.target.directory / name).read_bytes(), b"MUST REMAIN UNTOUCHED")

    def test_sparse_cross_chunk_boundaries_and_explicit_zeroes(self):
        chunks = list(self.images["super"].chunks(2 * t.BLOCK))
        self.assertEqual([len(x) for x in chunks], [2 * t.BLOCK, t.BLOCK])
        self.assertEqual(b"".join(chunks), self.expected["super"])
        self.assertEqual(chunks[-1], b"\0" * t.BLOCK)

    def test_complete_transfer_preserves_protected_partitions(self):
        state = self.run_transfer()
        self.assertEqual(state["status"], "VERIFIED_NO_REBOOT")
        self.assertFalse(state["automatic_reboot"])
        self.assert_complete()

    def test_interruption_resume_reconciles_partial_chunk(self):
        self.target.failure = ("super", t.BLOCK)
        with self.assertRaises(ConnectionError):
            self.run_transfer()
        state = json.loads((self.session / "install-journal.json").read_text())
        self.assertEqual(state["status"], "INTERRUPTED_STAY_IN_RECOVERY")
        self.assertEqual(state["pending"]["offset"], t.BLOCK)
        self.run_transfer()
        self.assertEqual(self.target.writes.count(("super", 0)), 1)
        self.assertEqual(self.target.writes.count(("super", t.BLOCK)), 2)
        self.assertNotIn("error", json.loads((self.session / "install-journal.json").read_text()))
        self.assert_complete()

    def test_lost_ack_after_write_does_not_repeat_good_write(self):
        original = self.target.write_chunk
        def lost_ack(name, offset, data, checksum):
            original(name, offset, data, checksum)
            self.target.write_chunk = original
            raise ConnectionError("lost acknowledgement")
        self.target.write_chunk = lost_ack
        with self.assertRaises(ConnectionError):
            self.run_transfer()
        self.run_transfer()
        self.assertEqual(self.target.writes.count(("super", 0)), 1)
        self.assert_complete()

    def test_stale_journal_never_skips_corrupt_device_bytes(self):
        self.run_transfer()
        with (self.target.directory / "super").open("r+b") as stream:
            stream.seek(t.BLOCK)
            stream.write(b"BROKEN")
        count = len(self.target.writes)
        self.run_transfer()
        self.assertEqual(self.target.writes[count:], [("super", t.BLOCK)])
        self.assert_complete()

    def test_wrong_readback_aborts_before_next_partition(self):
        self.target.corrupt = True
        with self.assertRaisesRegex(RuntimeError, "readback mismatch"):
            self.run_transfer()
        self.assertEqual(self.target.writes, [("super", 0)])

    def test_final_partition_hash_detects_later_corruption(self):
        self.target.final_corrupt = True
        with self.assertRaisesRegex(RuntimeError, "full partition-range"):
            self.run_transfer()
        self.assertTrue(all(name == "super" for name, offset in self.target.writes))

    def test_modified_source_is_rejected_before_its_write(self):
        self.images["super"].path.write_bytes(sparse_bytes(b"!" * t.BLOCK))
        with self.assertRaisesRegex(ValueError, "source changed"):
            self.run_transfer()
        self.assertEqual(self.target.writes, [])

    def test_bad_raw_checksum_is_rejected_during_planning(self):
        bad = dict(self.images)
        image = bad["boot"]
        bad["boot"] = t.Image("boot", image.path, image.size, "0" * 64)
        with self.assertRaisesRegex(ValueError, "checksum mismatch"):
            t.describe(bad)
        self.assertEqual(self.target.writes, [])

    def test_truncated_sparse_is_rejected_during_planning(self):
        path = self.images["super"].path
        path.write_bytes(path.read_bytes()[:-1])
        with self.assertRaisesRegex(ValueError, "truncated"):
            t.describe(self.images)

    def test_other_device_cannot_reuse_journal(self):
        self.run_transfer()
        count = len(self.target.writes)
        self.target.identity["serial"] = "ANOTHER-WATCH"
        with self.assertRaisesRegex(ValueError, "another plan or device"):
            self.run_transfer()
        self.assertEqual(len(self.target.writes), count)

    def test_concurrent_session_is_rejected(self):
        with t.session_lock(self.session):
            with self.assertRaises(BlockingIOError):
                self.run_transfer()
        self.assertEqual(self.target.writes, [])

    def test_mounted_target_rejected_before_begin(self):
        self.target.mounted = True
        with self.assertRaisesRegex(RuntimeError, "active target"):
            self.run_transfer()
        self.assertEqual(self.target.writes, [])

    def test_target_activated_mid_transfer_blocks_next_write(self):
        original = self.target.write_chunk
        def remount_after_first(name, offset, data, checksum):
            original(name, offset, data, checksum)
            self.target.mounted = True
        self.target.write_chunk = remount_after_first
        with self.assertRaisesRegex(RuntimeError, "active target"):
            self.run_transfer()
        self.assertEqual(self.target.writes, [("super", 0)])

    def test_no_image_can_target_protected_partitions(self):
        for name in ("userdata", "metadata", "recovery", "persist", "misc", "bootloader", "../boot"):
            with self.subTest(name=name), self.assertRaises(ValueError):
                t.Image(name, self.images["boot"].path, t.BLOCK, "0" * 64)

    def test_full_image_rollback_uses_same_verified_engine(self):
        originals = {}
        for name in t.ORDER:
            path = self.root / (name + "-backup.img")
            path.write_bytes((self.target.directory / name).read_bytes())
            originals[name] = t.Image(name, path, path.stat().st_size, t.file_digest(path))
        self.run_transfer()
        description = t.describe(originals, t.BLOCK)
        self.run_transfer("rollback", originals, description)
        for name in t.ORDER:
            self.assertEqual((self.target.directory / name).read_bytes(), b"Z" * self.target.sizes[name])
        self.assertEqual((self.target.directory / "metadata").read_bytes(), b"MUST REMAIN UNTOUCHED")

    def test_last_4k_of_4gib_range_uses_full_width_offset(self):
        device = cli.AdbDevice.__new__(cli.AdbDevice)
        device.nodes = {"super": "/dev/block/mmcblk0p40"}
        device.sizes = {"super": 4 * 1024 ** 3}
        with patch.object(device, "shell", return_value="0" * 64 + "  -\n") as shell:
            device.chunk_hash("super", 4 * 1024 ** 3 - t.BLOCK, t.BLOCK)
        self.assertIn("skip=1048575 count=1", shell.call_args.args[0])
        with self.assertRaisesRegex(ValueError, "exceeds"):
            device.chunk_hash("super", 4 * 1024 ** 3, t.BLOCK)

    def test_cli_hardware_writes_blocked_before_adb(self):
        for command in ("apply", "rollback"):
            args = [command, "--serial", "test:5555", "--session", str(self.session),
                    "--backup", str(self.root / "backup")]
            if command == "apply":
                args += ["--package", str(self.sources)]
            with self.subTest(command=command), patch.object(cli, "AdbDevice") as device:
                with self.assertRaisesRegex(RuntimeError, "HARDWARE_WRITES_BLOCKED"):
                    cli.main(args)
                device.assert_not_called()

    def test_complete_same_watch_backups_required(self):
        backup = self.root / "backup"
        backup.mkdir()
        with self.assertRaises(FileNotFoundError):
            cli.backup_images(backup, self.target)
        manifest = {"format": 1, "scope": "rom-image-partitions-only",
                    "identity": {"serial": "OTHER-WATCH", "device": "dace"}, "images": {}}
        (backup / "SNAPSHOT.json").write_text(json.dumps(manifest))
        with self.assertRaisesRegex(ValueError, "another watch"):
            cli.backup_images(backup, self.target)
        manifest["identity"]["serial"] = "TEST-WATCH"
        (backup / "SNAPSHOT.json").write_text(json.dumps(manifest))
        with self.assertRaisesRegex(ValueError, "incomplete"):
            cli.backup_images(backup, self.target)

    def test_corrupted_backup_aborts_cli_before_any_write(self):
        backup = self.root / "backup"
        backup.mkdir()
        hashes = {}
        manifest = {"format": 1, "scope": "rom-image-partitions-only",
                    "identity": copy.deepcopy(self.target.identity), "images": {}}
        for name in t.ORDER:
            path = backup / (name + ".img")
            path.write_bytes((self.target.directory / name).read_bytes())
            hashes[name] = t.file_digest(path)
            manifest["images"][name] = {"bytes": path.stat().st_size, "sha256": hashes[name]}
        (backup / "SNAPSHOT.json").write_text(json.dumps(manifest))
        (backup / "boot.img").write_bytes(b"?" * self.target.sizes["boot"])
        registry = self.root / "registry"
        registry.mkdir()
        (registry / "validated-recoveries.json").write_text(json.dumps({"profiles": {"fake": {}}}))
        self.target.identity["recovery_sha256"] = "f" * 64
        args = ["apply", "--serial", "test:5555", "--session", str(self.session),
                "--backup", str(backup), "--package", str(self.sources)]
        with (patch.object(cli, "HERE", registry), patch.object(cli, "reference", return_value={}),
              patch.object(cli, "AdbDevice", return_value=self.target),
              patch.object(cli, "require_validated_profile", return_value={"rollback_image_sha256": hashes}),
              patch.object(self.target, "begin") as begin):
            with self.assertRaisesRegex(ValueError, "checksum mismatch: boot"):
                cli.main(args)
            begin.assert_not_called()
        self.assertEqual(self.target.writes, [])

    def test_failed_adb_push_cannot_reach_partition_write(self):
        device = cli.AdbDevice.__new__(cli.AdbDevice)
        device.serial = "test:5555"
        device.identity = {"recovery_sha256": "f" * 64}
        device.nodes = {"super": "/dev/block/mmcblk0p40"}
        device.sizes = {"super": 4 * 1024 ** 3}
        device.session = self.root
        data = b"A" * t.BLOCK
        with (patch.object(cli, "require_validated_profile", return_value={}),
              patch.object(cli.subprocess, "run", side_effect=subprocess.CalledProcessError(1, "adb")),
              patch.object(device, "shell") as shell):
            with self.assertRaises(subprocess.CalledProcessError):
                device.write_chunk("super", 0, data, t.digest(data))
            shell.assert_not_called()
        self.assertFalse((self.root / "transfer-block.bin").exists())


if __name__ == "__main__":
    unittest.main()
