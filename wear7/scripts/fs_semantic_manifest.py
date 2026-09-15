#!/usr/bin/env python3
import hashlib
import os
import stat
import sys


def get_xattr_hex(path: str, name: str) -> str:
    try:
        return os.getxattr(path, name, follow_symlinks=False).hex()
    except OSError:
        return "-"


def sha256_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(8 * 1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def main() -> int:
    if len(sys.argv) != 3:
        print(f"usage: {sys.argv[0]} ROOT OUTPUT", file=sys.stderr)
        return 2
    root, output = sys.argv[1:]
    root = os.path.abspath(root)
    rows = []
    for base, dirs, files in os.walk(root, topdown=True, followlinks=False):
        for name in dirs + files:
            path = os.path.join(base, name)
            rel = os.path.relpath(path, root)
            st = os.lstat(path)
            target = "-"
            digest = "-"
            if stat.S_ISREG(st.st_mode):
                kind = "f"
                digest = sha256_file(path)
            elif stat.S_ISLNK(st.st_mode):
                kind = "l"
                target = os.readlink(path)
            elif stat.S_ISDIR(st.st_mode):
                kind = "d"
            else:
                kind = "o"
            rows.append((
                rel,
                kind,
                st.st_uid,
                st.st_gid,
                f"{stat.S_IMODE(st.st_mode):04o}",
                digest,
                target,
                get_xattr_hex(path, "security.selinux"),
                get_xattr_hex(path, "security.capability"),
            ))
    with open(output, "w", encoding="utf-8") as f:
        f.write("path\ttype\tuid\tgid\tmode\tsha256\ttarget\tselinux_hex\tcapability_hex\n")
        for row in sorted(rows):
            f.write("\t".join(map(str, row)) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
