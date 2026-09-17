"""Bounded image transport; independent of recovery and testable on ordinary files.

Only the seven V6 image partitions are accepted. No userdata, metadata, recovery,
mount, reboot or formatting operation exists in this module.
"""
from contextlib import contextmanager
from dataclasses import dataclass
import fcntl
import hashlib
import json
import os
from pathlib import Path
import struct

BLOCK = 4096
CHUNK = 16 * 1024 * 1024
ORDER = ("super", "vendor_boot", "init_boot", "dtbo", "boot", "vbmeta_system", "vbmeta")


def digest(data):
    return hashlib.sha256(data).hexdigest()


def file_digest(path):
    with Path(path).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode()


def atomic_json(path, value):
    path = Path(path)
    temp = path.with_name(path.name + ".new")
    if path.is_symlink() or temp.is_symlink():
        raise ValueError("symlink state file")
    with temp.open("w") as stream:
        json.dump(value, stream, indent=2)
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temp, path)
    # File fsync is supported on Termux shared storage. Directory fsync may not be.
    try:
        fd = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)
    except OSError:
        pass


@contextmanager
def session_lock(directory):
    directory = Path(directory)
    if directory.is_symlink():
        raise ValueError("symlink session directory")
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / "session.lock"
    if path.is_symlink():
        raise ValueError("symlink session lock")
    with path.open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        try:
            yield
        finally:
            fcntl.flock(lock, fcntl.LOCK_UN)


def read_exact(stream, count):
    value = stream.read(count)
    if len(value) != count:
        raise ValueError("truncated image")
    return value


def sparse_pieces(path):
    """Decode only the exact Android sparse format used by the verified V6.

    DONT_CARE is explicitly zeroed. It must never leave old device data in place:
    the resulting bytes must match the raw-super checksum recorded by CI.
    """
    with Path(path).open("rb") as stream:
        magic, major, minor, fh, ch, block, blocks, chunks, _ = struct.unpack(
            "<I4H4I", read_exact(stream, 28))
        if (magic, major, minor, fh, ch, block) != (0xED26FF3A, 1, 0, 28, 12, BLOCK):
            raise ValueError("unsupported sparse format")
        if chunks > Path(path).stat().st_size // 12:
            raise ValueError("impossible sparse chunk count")
        seen = 0
        for _ in range(chunks):
            kind, reserved, count, length = struct.unpack("<2H2I", read_exact(stream, 12))
            size = count * block
            payload = {0xCAC1: size, 0xCAC2: 4, 0xCAC3: 0, 0xCAC4: 4}.get(kind)
            if reserved or payload is None or length != 12 + payload:
                raise ValueError("invalid sparse chunk")
            if kind == 0xCAC4:
                if count:
                    raise ValueError("invalid sparse CRC chunk")
                read_exact(stream, 4)
                continue
            seen += count
            if seen > blocks:
                raise ValueError("sparse image exceeds declared size")
            pattern = read_exact(stream, 4) if kind == 0xCAC2 else b"\0" * 4
            while size:
                length = min(size, 1024 * 1024)
                if kind == 0xCAC1:
                    yield read_exact(stream, length)
                else:
                    yield pattern * (length // 4)
                size -= length
        if seen != blocks or stream.read(1):
            raise ValueError("sparse size mismatch or trailing bytes")


@dataclass(frozen=True)
class Image:
    name: str
    path: Path
    size: int
    sha256: str
    sparse: bool = False

    def __post_init__(self):
        if self.name not in ORDER:
            raise ValueError("protected or unknown partition: " + self.name)
        if self.size <= 0 or self.size % BLOCK:
            raise ValueError("image size must be a positive multiple of 4096")
        if len(self.sha256) != 64 or any(c not in "0123456789abcdef" for c in self.sha256):
            raise ValueError("invalid image checksum")
        if self.sparse and self.name != "super":
            raise ValueError("only super may be sparse")

    def chunks(self, chunk_size=CHUNK):
        if chunk_size < BLOCK or chunk_size > CHUNK or chunk_size % BLOCK:
            raise ValueError("invalid transfer chunk size")
        if self.path.is_symlink() or not self.path.is_file():
            raise ValueError("image must be a regular non-symlink file")
        if self.sparse:
            pieces = sparse_pieces(self.path)
        else:
            def raw():
                with self.path.open("rb") as stream:
                    while data := stream.read(1024 * 1024):
                        yield data
            pieces = raw()
        buf = bytearray()
        emitted = 0
        for piece in pieces:
            buf.extend(piece)
            while len(buf) >= chunk_size:
                data = bytes(buf[:chunk_size])
                del buf[:chunk_size]
                emitted += len(data)
                if emitted > self.size:
                    raise ValueError("image exceeds expected size")
                yield data
        if buf:
            emitted += len(buf)
            if emitted > self.size:
                raise ValueError("image exceeds expected size")
            yield bytes(buf)
        if emitted != self.size:
            raise ValueError("image length differs from manifest")


def describe(images, chunk_size=CHUNK):
    """Validate every source before any device mutation; hash the expanded bytes."""
    if set(images) != set(ORDER):
        raise ValueError("all seven image partitions are required")
    descriptions = {}
    for name in ORDER:
        image = images[name]
        if name != image.name:
            raise ValueError("image/partition name mismatch")
        total_hash = hashlib.sha256()
        rows = []
        offset = 0
        for data in image.chunks(chunk_size):
            total_hash.update(data)
            rows.append({"offset": offset, "bytes": len(data), "sha256": digest(data)})
            offset += len(data)
        if total_hash.hexdigest() != image.sha256:
            raise ValueError("expanded/source checksum mismatch: " + name)
        descriptions[name] = {"bytes": image.size, "sha256": image.sha256, "chunks": rows}
    return {"format": 1, "chunk_bytes": chunk_size, "order": list(ORDER), "images": descriptions}


def transfer(images, description, target, session, operation):
    """Transfer or restore with readback and persistent local progress.

    target.assert_ready() must check identity, capacities and inactive targets.
    Journal entries never authorize skipping a read: on resume every existing
    chunk is compared with the requested bytes. A torn or stale chunk is resent.
    An error leaves the device in recovery; no automatic retries/reboots occur.
    """
    if operation not in ("install", "rollback"):
        raise ValueError("invalid operation")
    # The caller must have checked all source hashes, including rollback files.
    if set(images) != set(ORDER) or set(description.get("images", {})) != set(ORDER):
        raise ValueError("incomplete image set")
    if description.get("order") != list(ORDER):
        raise ValueError("unexpected partition order")
    token = digest(canonical({"description": description, "identity": target.identity,
                              "operation": operation}))
    session = Path(session)
    journal_path = session / (operation + "-journal.json")
    with session_lock(session):
        if journal_path.is_symlink():
            raise ValueError("symlink journal")
        if journal_path.exists():
            state = json.loads(journal_path.read_text())
            if state.get("token") != token:
                raise ValueError("journal belongs to another plan or device")
        else:
            state = {"token": token, "operation": operation, "identity": target.identity,
                     "completed_chunks": {}, "status": "PREPARED", "automatic_reboot": False}
        target.assert_ready(description)
        atomic_json(journal_path, state)
        try:
            target.begin(session)
            for name in ORDER:
                target.assert_ready(description)
                expected = description["images"][name]
                iterator = images[name].chunks(description["chunk_bytes"])
                offset = 0
                for index, row in enumerate(expected["chunks"]):
                    data = next(iterator)
                    if (row["offset"] != offset or row["bytes"] != len(data)
                            or row["sha256"] != digest(data)):
                        raise ValueError("source changed after planning: " + name)
                    key = f"{name}:{offset}"
                    # Reconcile physical bytes, never trust a previous acknowledgement.
                    if target.chunk_hash(name, offset, len(data)) != row["sha256"]:
                        target.assert_ready(description)
                        state["status"] = "WRITING"
                        state["pending"] = {"partition": name, **row}
                        atomic_json(journal_path, state)
                        target.write_chunk(name, offset, data, row["sha256"])
                        if target.chunk_hash(name, offset, len(data)) != row["sha256"]:
                            raise RuntimeError("device readback mismatch: " + key)
                    state["completed_chunks"][key] = row["sha256"]
                    state.pop("pending", None)
                    state["status"] = "TRANSFERRING"
                    atomic_json(journal_path, state)
                    offset += len(data)
                if next(iterator, None) is not None or offset != expected["bytes"]:
                    raise ValueError("image/plan length mismatch: " + name)
                if target.chunk_hash(name, 0, expected["bytes"]) != expected["sha256"]:
                    raise RuntimeError("full partition-range checksum mismatch: " + name)
            target.finish()
            state["status"] = "VERIFIED_NO_REBOOT"
            state.pop("error", None)
            atomic_json(journal_path, state)
        except BaseException as exc:
            state["status"] = "INTERRUPTED_STAY_IN_RECOVERY"
            state["error"] = str(exc)
            atomic_json(journal_path, state)
            raise
    return state
