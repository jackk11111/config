#!/usr/bin/env python3
import os
import stat
import struct
import sys


def capmask(path: str) -> int:
    try:
        data = os.getxattr(path, "security.capability", follow_symlinks=False)
    except OSError:
        return 0
    if len(data) < 12:
        return 0
    permitted_lo = struct.unpack_from("<I", data, 4)[0]
    permitted_hi = struct.unpack_from("<I", data, 12)[0] if len(data) >= 20 else 0
    return permitted_lo | (permitted_hi << 32)


def main() -> int:
    if len(sys.argv) != 4:
        print(f"usage: {sys.argv[0]} ROOT LOGICAL_PREFIX OUTPUT", file=sys.stderr)
        return 2
    root, prefix, output = sys.argv[1:]
    root = os.path.abspath(root)
    rows = []

    root_st = os.lstat(root)
    rows.append((prefix, root_st, capmask(root)))

    for base, dirs, files in os.walk(root, topdown=True, followlinks=False):
        for name in dirs + files:
            path = os.path.join(base, name)
            rel = os.path.relpath(path, root)
            logical = prefix + "/" + rel
            rows.append((logical, os.lstat(path), capmask(path)))

    with open(output, "w", encoding="utf-8") as f:
        for logical, st, cap in sorted(rows, key=lambda x: x[0]):
            mode = stat.S_IMODE(st.st_mode)
            extra = f" capabilities=0x{cap:x}" if cap else ""
            f.write(f"{logical} {st.st_uid} {st.st_gid} {mode:04o}{extra}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
