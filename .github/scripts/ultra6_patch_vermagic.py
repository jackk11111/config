#!/usr/bin/env python3
import sys

if len(sys.argv) != 3:
    raise SystemExit("usage: ultra6_patch_vermagic.py <release> <module.ko>")

release = sys.argv[1]
path = sys.argv[2]
data = bytearray(open(path, "rb").read())
key = b"vermagic="
i = data.find(key)
if i < 0:
    raise SystemExit("vermagic key not found")
j = data.find(b"\0", i)
if j < 0:
    raise SystemExit("vermagic terminator not found")

old = bytes(data[i:j])
text = old.decode("ascii")
parts = text.split(" ", 1)
if len(parts) != 2:
    raise SystemExit(f"unexpected vermagic: {text}")

new = ("vermagic=" + release + " " + parts[1]).encode()
if len(new) > len(old):
    raise SystemExit(f"target vermagic too long old={len(old)} new={len(new)} oldstr={text}")

data[i:i+len(old)] = new + b"\0" * (len(old) - len(new))
open(path, "wb").write(data)

print("OLD_" + text)
print("NEW_" + new.decode())
