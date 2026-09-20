#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail

WORK="$HOME/WEAR5"
K="/storage/emulated/0/Download/Telegram/Watch/kernel e recovery/boot_CURRENT_WORKING_5.15.220.img"

python - "$K" "$WORK/stock/boot.img" "$WORK/stock/init_boot.img" "$WORK/xiaomi/boot.img" "$WORK/xiaomi/init_boot.img" <<'PY'
import os,struct,sys

def u32(b,o):
    return struct.unpack_from("<I",b,o)[0]

def inspect(p):
    if not os.path.exists(p):
        return {"path":p,"missing":True}
    with open(p,"rb") as f:
        h=f.read(4096)
    d={"path":p,"size":os.path.getsize(p)}
    if h[:8]!=b"ANDROID!":
        d["magic"]=h[:8].hex()
        return d
    d["magic"]="ANDROID!"
    d["kernel_size"]=u32(h,8)
    d["ramdisk_size"]=u32(h,12)
    # header_version is at 40 for v3/v4 and also commonly for v1/v2.
    d["header_version"]=u32(h,40)
    # For v3/v4 header_size is at 20. Old layouts use page_size there,
    # so print it neutrally.
    d["field20"]=u32(h,20)
    return d

labels=["WORKING_220","TICWATCH_STOCK_BOOT","TICWATCH_STOCK_INIT_BOOT",
        "XIAOMI_A14_BOOT","XIAOMI_A14_INIT_BOOT"]
vals=[]
for label,p in zip(labels,sys.argv[1:]):
    d=inspect(p); vals.append((label,d))
    print("=== "+label+" ===")
    print("PATH="+p)
    if d.get("missing"):
        print("MISSING=YES"); continue
    print("FILE_SIZE="+str(d["size"]))
    print("MAGIC="+str(d.get("magic")))
    if d.get("magic")=="ANDROID!":
        print("HEADER_VERSION="+str(d["header_version"]))
        print("KERNEL_SIZE="+str(d["kernel_size"]))
        print("RAMDISK_SIZE="+str(d["ramdisk_size"]))
        print("FIELD20="+str(d["field20"]))

w=dict(vals)["WORKING_220"]
sb=dict(vals)["TICWATCH_STOCK_BOOT"]
si=dict(vals)["TICWATCH_STOCK_INIT_BOOT"]
xb=dict(vals)["XIAOMI_A14_BOOT"]
xi=dict(vals)["XIAOMI_A14_INIT_BOOT"]

print("=== CONCLUSION ===")
if w.get("magic")=="ANDROID!" and w.get("ramdisk_size",0)>0:
    print("WORKING_220_HAS_RAMDISK=YES")
    print("INIT_BOOT_ONLY_TEST_CAN_BE_INCOMPLETE=YES")
    print("FINDING=TARGET_BOOT_CONTAINS_FIRST_STAGE_RAMDISK")
elif w.get("magic")=="ANDROID!" and w.get("ramdisk_size",0)==0 and si.get("ramdisk_size",0)>0:
    print("WORKING_220_HAS_RAMDISK=NO")
    print("INIT_BOOT_ONLY_TEST_CAN_BE_INCOMPLETE=NO")
    print("FINDING=TARGET_USES_SEPARATE_INIT_BOOT_RAMDISK")
else:
    print("FINDING=BOOT_LAYOUT_NEEDS_REVIEW")
PY
