#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail

WORK="$HOME/WEAR5"
BUILD="/storage/emulated/0/Download/WEAR5_FIRST_BUILD/images"
STOCK="$WORK/stock"

die(){ echo; echo "BLOCKER=$*"; exit 2; }

for f in "$STOCK/vbmeta.img" "$STOCK/vbmeta_system.img" "$BUILD/vbmeta.img" "$BUILD/vbmeta_system.img"; do
  [ -f "$f" ] || die "manca_$f"
done

python - "$STOCK/vbmeta.img" "$STOCK/vbmeta_system.img" "$BUILD/vbmeta.img" "$BUILD/vbmeta_system.img" <<'PY'
import os,struct,sys

def info(p):
    b=open(p,'rb').read()
    if b[:4] != b'AVB0':
        raise SystemExit("NOT_AVB="+p)
    flags=struct.unpack(">I", b[120:124])[0]
    auth=struct.unpack(">Q", b[12:20])[0]
    aux=struct.unpack(">Q", b[20:28])[0]
    desc_off=struct.unpack(">Q", b[96:104])[0]
    desc_sz=struct.unpack(">Q", b[104:112])[0]
    aux_base=256+auth
    desc=b[aux_base+desc_off:aux_base+desc_off+desc_sz]
    return b,flags,desc

paths=sys.argv[1:]
labels=["STOCK_VBMETA","STOCK_VBMETA_SYSTEM","BUILD_VBMETA","BUILD_VBMETA_SYSTEM"]
vals={}
for label,p in zip(labels,paths):
    b,flags,desc=info(p)
    vals[label]=(flags,desc)
    print(f"{label}_FLAGS={flags}")
    print(f"{label}_SIZE={len(b)}")

stock_chain = b"vbmeta_system" in vals["STOCK_VBMETA"][1]
build_chain = b"vbmeta_system" in vals["BUILD_VBMETA"][1]
print("STOCK_TOPLEVEL_REFERENCES_VBMETA_SYSTEM="+("YES" if stock_chain else "NO"))
print("BUILD_TOPLEVEL_REFERENCES_VBMETA_SYSTEM="+("YES" if build_chain else "NO"))

if stock_chain and vals["BUILD_VBMETA_SYSTEM"][0] != 0:
    print("FINDING=INVALID_CHAINED_VBMETA_SYSTEM_FLAGS")
elif vals["BUILD_VBMETA"][0] == 3 and vals["BUILD_VBMETA_SYSTEM"][0] == 0:
    print("FINDING=FLAGS_LAYOUT_OK_FOR_DISABLED_TOPLEVEL")
else:
    print("FINDING=NEEDS_REVIEW")
PY
