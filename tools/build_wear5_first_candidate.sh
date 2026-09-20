#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail

STOCK_OTA="/storage/emulated/0/Download/Telegram/Watch/ota/2269bd24a774cae37adc720d3d97bd1b76846e2b.zip"
WORK="$HOME/WEAR5"
STOCK="$WORK/stock"
XIAOMI="$WORK/xiaomi"
STAGE2="$WORK/STAGE2"
OUT="/storage/emulated/0/Download/WEAR5_FIRST_BUILD"
IMG="$OUT/images"
META="$OUT/meta"
SUPER="$IMG/super.img"

die(){ echo; echo "BLOCKER=$*"; exit 2; }
kv(){ awk -F= -v k="$1" '$1==k{print substr($0,index($0,"=")+1);exit}' "$META/target_dynamic_info.txt"; }

echo "[1/6] Toolchain"
pkg install -y android-tools e2fsprogs python unzip coreutils file >/dev/null
command -v lpmake >/dev/null || die "lpmake_non_disponibile_in_Termux"

rm -rf "$OUT"
mkdir -p "$IMG/logical" "$META"

echo "[2/6] VINTF"
TARGET_FCM="$(
  grep -RhoE 'target-level="[0-9]+"' "$STAGE2/stock/vendor/vintf_root" 2>/dev/null \
    | grep -oE '[0-9]+' | sort -n | tail -1 || true
)"
if [ -z "$TARGET_FCM" ]; then
  TARGET_FCM="$(
    find "$STAGE2/stock/system" -type f -name 'compatibility_matrix.*.xml' 2>/dev/null \
      | sed -n 's/.*compatibility_matrix\.\([0-9][0-9]*\)\.xml$/\1/p' \
      | sort -n | tail -1
  )"
fi
[ -n "$TARGET_FCM" ] || die "target_FCM_stock_non_rilevato"

DONOR_MATRIX="$STAGE2/xiaomi/system/vintf_root/vintf/compatibility_matrix.$TARGET_FCM.xml"
[ -f "$DONOR_MATRIX" ] || DONOR_MATRIX="$STAGE2/xiaomi/system/vintf_system/vintf/compatibility_matrix.$TARGET_FCM.xml"
[ -f "$DONOR_MATRIX" ] || die "donor_Wear5_non_contiene_FCM_${TARGET_FCM}"
echo "TARGET_FCM=$TARGET_FCM"

echo "[3/6] Layout dinamico offline"
: > "$META/target_dynamic_info.txt"
OP_ENTRY="$(unzip -Z1 "$STOCK_OTA" | grep -E '(^|/)dynamic_partitions_op_list$' | head -1 || true)"
[ -n "$OP_ENTRY" ] || die "dynamic_partitions_op_list_non_trovato"
unzip -p "$STOCK_OTA" "$OP_ENTRY" > "$META/dynamic_partitions_op_list"

python - "$META/dynamic_partitions_op_list" "$META/target_dynamic_info.txt" <<'PY'
import sys
src,dst=sys.argv[1:3]
groups={}
parts={}
for raw in open(src,encoding='utf-8',errors='ignore'):
    line=raw.strip()
    if not line or line.startswith('#'):
        continue
    t=line.split()
    op=t[0]
    if op=="remove_all_groups":
        groups.clear(); parts.clear()
    elif op in ("add_group","resize_group") and len(t)>=3:
        groups[t[1]]=int(t[2])
    elif op=="remove_group" and len(t)>=2:
        g=t[1]; groups.pop(g,None)
        parts={p:pg for p,pg in parts.items() if pg!=g}
    elif op in ("add","move") and len(t)>=3:
        parts[t[1]]=t[2]
    elif op=="remove" and len(t)>=2:
        parts.pop(t[1],None)

if not groups or not parts:
    raise SystemExit("cannot reconstruct dynamic layout")

with open(dst,'w',encoding='utf-8') as o:
    o.write("super_partition_groups="+" ".join(groups)+"\n")
    o.write("dynamic_partition_list="+" ".join(parts)+"\n")
    for g,size in groups.items():
        plist=[p for p,pg in parts.items() if pg==g]
        o.write(f"{g}_size={size}\n")
        o.write(f"{g}_partition_list={' '.join(plist)}\n")
PY

LP_GROUPS="$(kv super_partition_groups || true)"
DYNAMIC_LIST="$(kv dynamic_partition_list || true)"
[ -n "$LP_GROUPS" ] || die "super_partition_groups_non_rilevato"
[ -n "$DYNAMIC_LIST" ] || die "lista_partizioni_dinamiche_vuota"

# Cerca la dimensione fisica esatta di super solo nei metadata GPT/rawprogram dell'OTA.
# Se non c'?, non inventa nulla: completa comunque tutto tranne super.img.
cat > "$META/find_super_size.py" <<'PY'
import os,struct,sys,zipfile,xml.etree.ElementTree as ET
ota=sys.argv[1]
found=[]
def add(v,src):
    try:v=int(v)
    except:return
    if v>0 and v%512==0: found.append((v,src))
with zipfile.ZipFile(ota) as z:
    for n in z.namelist():
        low=n.lower()
        if low.endswith(".xml") and ("rawprogram" in low or "partition" in low):
            try:r=ET.fromstring(z.read(n))
            except:continue
            for e in r.iter():
                a={str(k).lower():str(v) for k,v in e.attrib.items()}
                label=(a.get("label") or a.get("name") or a.get("partition_name") or "").lower()
                if label!="super": continue
                secs=a.get("num_partition_sectors") or a.get("sectors")
                ss=a.get("sector_size_in_bytes") or a.get("sector_size") or "512"
                if secs:
                    try:add(int(secs,0)*int(ss,0),n)
                    except:pass
                for k in ("size_in_bytes","partition_size","size"):
                    if k in a:
                        try:add(int(a[k],0),n)
                        except:pass
    # Parse ordinary GPT images if present.
    for n in z.namelist():
        b=os.path.basename(n).lower()
        if not (b.endswith(".bin") and "gpt" in b): continue
        try:data=z.read(n)
        except:continue
        pos=0
        while True:
            h=data.find(b"EFI PART",pos)
            if h<0: break
            pos=h+1
            if h+92>len(data): continue
            cur=struct.unpack_from("<Q",data,h+24)[0]
            pelba=struct.unpack_from("<Q",data,h+72)[0]
            nent=struct.unpack_from("<I",data,h+80)[0]
            esz=struct.unpack_from("<I",data,h+84)[0]
            if not cur or esz<128 or nent==0 or nent>4096: continue
            sector=None
            if h%cur==0 and h//cur in (512,1024,2048,4096):
                sector=h//cur
            if not sector: continue
            off=pelba*sector
            if off+min(nent,256)*esz>len(data): continue
            for i in range(nent):
                e=data[off+i*esz:off+(i+1)*esz]
                if len(e)<128 or e[:16]==b"\0"*16: continue
                first,last=struct.unpack_from("<QQ",e,32)
                name=e[56:128].decode("utf-16le","ignore").split("\0",1)[0]
                if name.lower()=="super" and last>=first:
                    add((last-first+1)*sector,n)
if found:
    counts={}
    for size,src in found: counts.setdefault(size,[]).append(src)
    best=sorted(counts.items(),key=lambda x:(len(x[1]),x[0]),reverse=True)[0]
    print(best[0])
PY

SUPER_SIZE="$(python "$META/find_super_size.py" "$STOCK_OTA" 2>/dev/null | grep -E '^[0-9]+$' | tail -1 || true)"
if [ -n "$SUPER_SIZE" ]; then
  echo "super_partition_size=$SUPER_SIZE" >> "$META/target_dynamic_info.txt"
  echo "SUPER_SIZE_SOURCE=OTA"
else
  echo "SUPER_SIZE_SOURCE=PENDING_RECOVERY"
fi

echo "[4/6] Preparo immagini ibride"
for P in $DYNAMIC_LIST; do
  case "$P" in
    system|system_ext|product) SRC="$XIAOMI/$P.img" ;;
    *) SRC="$STOCK/$P.img" ;;
  esac
  [ -f "$SRC" ] || die "immagine_mancante_${P}"
  cp -f "$SRC" "$IMG/logical/$P.img"
done

group_for_part(){
  local p="$1" g list q
  for g in $LP_GROUPS; do
    list="$(kv "${g}_partition_list" || true)"
    for q in $list; do
      [ "$q" = "$p" ] && { echo "$g"; return 0; }
    done
  done
  return 1
}

# Riduce solo lo spazio libero ext4 se il set ibrido supera il group max.
NEED_SHRINK=0
for G in $LP_GROUPS; do
  GS="$(kv "${G}_size" || true)"
  [ -n "$GS" ] || die "dimensione_gruppo_${G}_non_rilevata"
  SUM=0
  LIST="$(kv "${G}_partition_list" || true)"
  for P in $LIST; do
    [ -f "$IMG/logical/$P.img" ] || continue
    SUM=$((SUM + $(stat -c %s "$IMG/logical/$P.img")))
  done
  [ "$SUM" -le "$GS" ] || NEED_SHRINK=1
done

if [ "$NEED_SHRINK" -eq 1 ]; then
  echo "SHRINK=YES"
  for P in $DYNAMIC_LIST; do
    F="$IMG/logical/$P.img"
    file -b "$F" | grep -qi 'ext[234] filesystem' || continue
    e2fsck -fy "$F" >/dev/null 2>&1 || true
    resize2fs -M "$F" >/dev/null 2>&1 || die "resize2fs_fallito_${P}"
  done
else
  echo "SHRINK=NO"
fi

for G in $LP_GROUPS; do
  GS="$(kv "${G}_size")"
  SUM=0
  LIST="$(kv "${G}_partition_list" || true)"
  for P in $LIST; do
    [ -f "$IMG/logical/$P.img" ] || continue
    SUM=$((SUM + $(stat -c %s "$IMG/logical/$P.img")))
  done
  [ "$SUM" -le "$GS" ] || die "spazio_gruppo_insufficiente_${G}_need_${SUM}_max_${GS}"
done

echo "[5/6] Super"
if [ -n "$SUPER_SIZE" ]; then
  META_SIZE=65536
  META_SLOTS=2
  LPM_ARGS=()
  for G in $LP_GROUPS; do
    GS="$(kv "${G}_size")"
    LPM_ARGS+=(--group "${G}:${GS}")
  done
  for P in $DYNAMIC_LIST; do
    F="$IMG/logical/$P.img"
    SZ="$(stat -c %s "$F")"
    G="$(group_for_part "$P")"
    LPM_ARGS+=(--partition "${P}:readonly:${SZ}:${G}" --image "${P}=${F}")
  done

  lpmake \
    --metadata-size "$META_SIZE" \
    --metadata-slots "$META_SLOTS" \
    --super-name super \
    --device "super:$SUPER_SIZE" \
    "${LPM_ARGS[@]}" \
    --output "$SUPER" >/dev/null || die "lpmake_fallito"
  [ "$(stat -c %s "$SUPER")" -eq "$SUPER_SIZE" ] || die "dimensione_super_generata_non_coerente"
  SUPER_STATUS="BUILT"
else
  SUPER_STATUS="WAITING_EXACT_SIZE"
fi

echo "[6/6] Boot chain"
KERNEL="$(find /storage/emulated/0/Download /storage/emulated/0/Telegram -type f -name 'boot_CURRENT_WORKING_5.15.220.img' -print -quit 2>/dev/null || true)"
if [ -z "$KERNEL" ]; then
  KERNEL="$(find /storage/emulated/0/Download /storage/emulated/0/Telegram -type f -iname '*5.15.220*.img' -print -quit 2>/dev/null || true)"
fi
if [ -n "$KERNEL" ]; then
  cp -f "$KERNEL" "$IMG/boot.img"
  BOOT_SOURCE="$KERNEL"
else
  cp -f "$STOCK/boot.img" "$IMG/boot.img"
  BOOT_SOURCE="stock_boot_fallback"
fi

for P in init_boot vendor_boot dtbo; do
  [ -f "$STOCK/$P.img" ] && cp -f "$STOCK/$P.img" "$IMG/$P.img"
done

# AVB: disabilitazione solo sul vbmeta top-level.
# vbmeta_system e' chained e deve mantenere flags=0.
for P in vbmeta vbmeta_system; do
  [ -f "$STOCK/$P.img" ] || continue
  cp -f "$STOCK/$P.img" "$IMG/$P.img"
done
python - "$IMG/vbmeta.img" <<'PY'
import struct,sys
p=sys.argv[1]
with open(p,'r+b') as f:
    if f.read(4)!=b'AVB0': raise SystemExit("NOT_AVB:"+p)
    f.seek(120)
    f.write(struct.pack(">I",3))
PY

cat > "$OUT/BUILD_INFO.txt" <<EOF
TARGET=dace
DONOR=axolotl
DONOR_BUILD=AW2A.240903.001.XM118S
TARGET_FCM=$TARGET_FCM
DYNAMIC_PARTITIONS=$DYNAMIC_LIST
SUPER_STATUS=$SUPER_STATUS
SUPER_SIZE=${SUPER_SIZE:-PENDING}
BOOT_SOURCE=$BOOT_SOURCE
RECOVERY_INCLUDED=NO
EOF

(
  cd "$IMG"
  find . -maxdepth 1 -type f -name '*.img' -print0 | sort -z | xargs -0 -r sha256sum
) > "$OUT/SHA256SUMS.txt"

cat > "$OUT/install_note.txt" <<'EOF'
NON FLASHARE ANCORA.
Recovery non inclusa.
Se SUPER_STATUS=WAITING_EXACT_SIZE, manca soltanto la dimensione fisica esatta
di /dev/block/by-name/super; non viene inventata per evitare metadata liblp errati.
EOF

echo
echo "BUILD_READY=$OUT"
echo "SUPER_STATUS=$SUPER_STATUS"
echo "SUPER_SIZE=${SUPER_SIZE:-PENDING}"
echo "BOOT_SOURCE=$BOOT_SOURCE"
echo "RECOVERY_INCLUDED=NO"
