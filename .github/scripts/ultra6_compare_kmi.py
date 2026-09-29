#!/usr/bin/env python3
import re
import subprocess
import sys

if len(sys.argv) != 3:
    raise SystemExit("usage: ultra6_compare_kmi.py <Module.symvers> <module.ko>")

symvers, ko = sys.argv[1:]
expected = {}
for line in open(symvers, errors="ignore"):
    f = line.split()
    if len(f) >= 4 and f[2] == "vmlinux":
        expected[f[1]] = f[0].lower().replace("0x", "")

out = subprocess.check_output(
    ["modprobe", "--dump-modversions", ko],
    text=True,
    stderr=subprocess.STDOUT,
)

got = {}
for line in out.splitlines():
    m = re.match(r"0x([0-9a-fA-F]+)\s+(\S+)", line)
    if m:
        got[m.group(2)] = m.group(1).lower()

checked = 0
bad = []
vendor = []
for sym, crc in got.items():
    if sym in expected:
        checked += 1
        if crc != expected[sym]:
            bad.append((sym, crc, expected[sym]))
    else:
        vendor.append((sym, crc))

print("VMLINUX_CRC_CHECKED", checked)
print("VMLINUX_CRC_MISMATCH", len(bad))
for row in bad:
    print("BAD", *row)
print("NON_VMLINUX_OR_VENDOR_SYMBOLS", len(vendor))
for row in vendor:
    print("VENDOR", *row)

if bad:
    raise SystemExit(2)
