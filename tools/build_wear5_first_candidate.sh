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

echo "[2/6] VINTF gate"

# Alcuni firmware Qualcomm dividono il device manifest in frammenti e non
# hanno /vendor/etc/vintf/manifest.xml. Prima cerca target-level in tutti i
# manifest vendor; se non è esplicitato, ricava il livello FCM massimo
# supportato dal framework stock (Android 13 => tipicamente FCM 7).
TARGET_FCM="$(
  grep -RhoE 'target-level="[0-9]+"' "$STAGE2/stock/vendor/vintf_root" 2>/dev/null     | grep -oE '[0-9]+' | sort -n | tail -1 || true
)"

if [ -z "$TARGET_FCM" ]; then
  TARGET_FCM="$(
    find "$STAGE2/stock/system" -type f -name 'compatibility_matrix.*.xml' 2>/dev/null       | sed -n 's/.*compatibility_matrix\.\([0-9][0-9]*\)\.xml$/\1/p'       | sort -n | tail -1
  )"
fi

[ -n "$TARGET_FCM" ] || die "target_FCM_stock_non_rilevato"

DONOR_MATRIX="$STAGE2/xiaomi/system/vintf_root/vintf/compatibility_matrix.$TARGET_FCM.xml"
[ -f "$DONOR_MATRIX" ] || DONOR_MATRIX="$STAGE2/xiaomi/system/vintf_system/vintf/compatibility_matrix.$TARGET_FCM.xml"
[ -f "$DONOR_MATRIX" ] || die "donor_Wear5_non_contiene_FCM_${TARGET_FCM}"

echo "TARGET_FCM=$TARGET_FCM"

echo "[3/6] Leggo geometria super TicWatch"
: > "$META/target_dynamic_info.txt"

# Primo tentativo: metadata build-style, quando presenti.
while IFS= read -r E; do
  unzip -p "$STOCK_OTA" "$E" >> "$META/target_dynamic_info.txt" 2>/dev/null || true
  echo >> "$META/target_dynamic_info.txt"
done < <(unzip -Z1 "$STOCK_OTA" | grep -E '(^|/)(dynamic_partitions_info|misc_info)\\.txt$' || true)

# Block OTA Mobvoi: se i metadata build-style non ci sono, ricostruisce lo
# stato finale delle dynamic partitions da dynamic_partitions_op_list.
if ! grep -q '^super_partition_groups=' "$META/target_dynamic_info.txt" 2>/dev/null; then
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
    elif op=="add_group" and len(t)>=3:
        groups[t[1]]=int(t[2])
    elif op=="resize_group" and len(t)>=3:
        groups[t[1]]=int(t[2])
    elif op=="remove_group" and len(t)>=2:
        g=t[1]; groups.pop(g,None)
        parts={p:pg for p,pg in parts.items() if pg!=g}
    elif op=="add" and len(t)>=3:
        parts[t[1]]=t[2]
    elif op=="move" and len(t)>=3:
        parts[t[1]]=t[2]
    elif op=="remove" and len(t)>=2:
        parts.pop(t[1],None)
# resize partition is intentionally irrelevant here; image sizes come from files.

if not groups or not parts:
    raise SystemExit("cannot reconstruct dynamic layout")

with open(dst,'a',encoding='utf-8') as o:
    o.write("super_partition_groups="+" ".join(groups)+"\n")
    o.write("dynamic_partition_list="+" ".join(parts)+"\n")
    for g,size in groups.items():
        plist=[p for p,pg in parts.items() if pg==g]
        o.write(f"{g}_size={size}\n")
        o.write(f"{g}_partition_list={' '.join(plist)}\n")
PY
fi

# Prima ricaviamo la dimensione fisica esatta di super OFFLINE dall'OTA.
# Qualcomm spesso include rawprogram*.xml o gpt*.bin anche quando manca misc_info.
SUPER_SIZE="$(kv super_partition_size || true)"
if [ -z "$SUPER_SIZE" ]; then
  python - "$STOCK_OTA" "$META/super_size_source.txt" <<'PY' > "$META/super_size.txt"
import io, os, re, struct, sys, zipfile, xml.etree.ElementTree as ET

ota, source_out = sys.argv[1:3]
results=[]

def add(size, src):
    try: size=int(size)
    except: return
    if size > 0 and size % 512 == 0:
        results.append((size,src))

with zipfile.ZipFile(ota) as z:
    names=z.namelist()

    # Qualcomm rawprogram XML: exact number of sectors for the physical GPT partition.
    for n in names:
        low=n.lower()
        if not (low.endswith(".xml") and ("rawprogram" in low or "partition" in low)):
            continue
        try:
            data=z.read(n)
            root=ET.fromstring(data)
        except Exception:
            continue
        for e in root.iter():
            a={str(k).lower():str(v) for k,v in e.attrib.items()}
            label=(a.get("label") or a.get("name") or a.get("partition_name") or "").lower()
            if label != "super":
                continue
            secs=a.get("num_partition_sectors") or a.get("sectors")
            ss=a.get("sector_size_in_bytes") or a.get("sector_size") or "512"
            if secs:
                try: add(int(secs,0)*int(ss,0), n+":xml")
                except Exception: pass
            for key in ("size_in_bytes","partition_size","size"):
                if key in a:
                    try: add(int(a[key],0), n+":xml:"+key)
                    except Exception: pass

    # Standard GPT images (gpt_main*.bin/gpt_both*.bin).
    for n in names:
        low=os.path.basename(n).lower()
        if not (low.endswith(".bin") and "gpt" in low):
            continue
        try: data=z.read(n)
        except Exception: continue
        pos=0
        while True:
            h=data.find(b"EFI PART", pos)
            if h < 0: break
            pos=h+1
            if h+92 > len(data): continue
            try:
                cur_lba=struct.unpack_from("<Q",data,h+24)[0]
                pe_lba=struct.unpack_from("<Q",data,h+72)[0]
                nent=struct.unpack_from("<I",data,h+80)[0]
                esz=struct.unpack_from("<I",data,h+84)[0]
            except Exception:
                continue
            if esz < 128 or nent == 0 or nent > 4096: continue

            sector=None
            if cur_lba:
                q,r=divmod(h,cur_lba)
                if r==0 and q in (512,1024,2048,4096):
                    sector=q
            if sector is None:
                for s in (512,4096):
                    if h == cur_lba*s:
                        sector=s; break
            if sector is None: continue

            off=pe_lba*sector
            if off + min(nent,256)*esz > len(data):
                continue
            for i in range(nent):
                eoff=off+i*esz
                ent=data[eoff:eoff+esz]
                if len(ent)<128: break
                if ent[:16] == b"\0"*16: continue
                first,last=struct.unpack_from("<QQ",ent,32)
                raw=ent[56:min(len(ent),128)]
                try: name=raw.decode("utf-16le","ignore").split("\0",1)[0]
                except Exception: name=""
                if name.lower()=="super" and last>=first:
                    add((last-first+1)*sector, n+":gpt")

if not results:
    sys.exit(3)

sizes={}
for size,src in results:
    sizes.setdefault(size,[]).append(src)

# Se più fonti concordano, preferisci il valore con più evidenza.
best=sorted(sizes.items(), key=lambda kv:(len(kv[1]),kv[0]), reverse=True)[0]
size,sources=best
with open(source_out,"w",encoding="utf-8") as f:
    f.write("SUPER_SIZE="+str(size)+"\n")
    f.write("SOURCE="+";".join(sources)+"\n")
print(size)
PY
  SUPER_SIZE="$(cat "$META/super_size.txt" 2>/dev/null | grep -E '^[0-9]+

GROUPS="$(kv super_partition_groups || true)"
[ -n "$GROUPS" ] || die "super_partition_groups_non_rilevato"

META_SIZE="$(kv super_metadata_size || true)"
[ -n "$META_SIZE" ] || META_SIZE=65536
META_SLOTS="$(kv super_metadata_slots || true)"
[ -n "$META_SLOTS" ] || META_SLOTS=2

DYNAMIC_LIST="$(kv dynamic_partition_list || true)"
[ -n "$DYNAMIC_LIST" ] || {
  DYNAMIC_LIST=""
  for G in $GROUPS; do
    L="$(kv "${G}_partition_list" || true)"
    DYNAMIC_LIST="$DYNAMIC_LIST $L"
  done
}
DYNAMIC_LIST="$(echo "$DYNAMIC_LIST" | xargs)"
[ -n "$DYNAMIC_LIST" ] || die "lista_partizioni_dinamiche_vuota"

echo "SUPER_SIZE=$SUPER_SIZE"
echo "GROUPS=$GROUPS"
echo "PARTITIONS=$DYNAMIC_LIST"

echo "[4/6] Preparo immagini ibride"
for P in $DYNAMIC_LIST; do
  case "$P" in
    system|system_ext|product)
      SRC="$XIAOMI/$P.img"
      ;;
    *)
      SRC="$STOCK/$P.img"
      ;;
  esac
  [ -f "$SRC" ] || die "immagine_mancante_${P}"
  cp -f "$SRC" "$IMG/logical/$P.img"
done

LPM_ARGS=()
for G in $GROUPS; do
  GS="$(kv "${G}_size" || true)"
  [ -n "$GS" ] || die "dimensione_gruppo_${G}_non_rilevata"
  LPM_ARGS+=(--group "${G}:${GS}")
done

group_for_part(){
  local p="$1" g list q
  for g in $GROUPS; do
    list="$(kv "${g}_partition_list" || true)"
    for q in $list; do
      [ "$q" = "$p" ] && { echo "$g"; return 0; }
    done
  done
  return 1
}

for P in $DYNAMIC_LIST; do
  F="$IMG/logical/$P.img"
  SZ="$(stat -c %s "$F")"
  G="$(group_for_part "$P" || true)"
  [ -n "$G" ] || die "gruppo_non_trovato_per_${P}"
  LPM_ARGS+=(--partition "${P}:readonly:${SZ}:${G}" --image "${P}=${F}")
done

NEED_SHRINK=0
for G in $GROUPS; do
  GS="$(kv "${G}_size")"
  SUM=0
  LIST="$(kv "${G}_partition_list" || true)"
  for P in $LIST; do
    [ -f "$IMG/logical/$P.img" ] || continue
    SUM=$((SUM + $(stat -c %s "$IMG/logical/$P.img")))
  done
  [ "$SUM" -le "$GS" ] || NEED_SHRINK=1
done

if [ "$NEED_SHRINK" -eq 1 ]; then
  echo "Riduzione filesystem al minimo necessario per entrare nel super..."
  for P in $DYNAMIC_LIST; do
    F="$IMG/logical/$P.img"
    file -b "$F" | grep -qi 'ext[234] filesystem' || continue
    e2fsck -fy "$F" >/dev/null 2>&1 || true
    resize2fs -M "$F" >/dev/null 2>&1 || die "resize2fs_fallito_${P}"
  done

  LPM_ARGS=()
  for G in $GROUPS; do
    GS="$(kv "${G}_size")"
    LPM_ARGS+=(--group "${G}:${GS}")
    SUM=0
    LIST="$(kv "${G}_partition_list" || true)"
    for P in $LIST; do
      [ -f "$IMG/logical/$P.img" ] || continue
      SUM=$((SUM + $(stat -c %s "$IMG/logical/$P.img")))
    done
    [ "$SUM" -le "$GS" ] || die "spazio_super_insufficiente_gruppo_${G}_need_${SUM}_max_${GS}"
  done
  for P in $DYNAMIC_LIST; do
    F="$IMG/logical/$P.img"
    SZ="$(stat -c %s "$F")"
    G="$(group_for_part "$P")"
    LPM_ARGS+=(--partition "${P}:readonly:${SZ}:${G}" --image "${P}=${F}")
  done
fi

echo "[5/6] Costruisco super.img"
lpmake \
  --metadata-size "$META_SIZE" \
  --metadata-slots "$META_SLOTS" \
  --super-name super \
  --device "super:$SUPER_SIZE" \
  "${LPM_ARGS[@]}" \
  --output "$SUPER" >/dev/null || die "lpmake_fallito"

[ "$(stat -c %s "$SUPER")" -eq "$SUPER_SIZE" ] || die "dimensione_super_generata_non_coerente"

echo "[6/6] Preparo boot chain e AVB per bootloader sbloccato"

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

for P in vbmeta vbmeta_system; do
  [ -f "$STOCK/$P.img" ] || continue
  cp -f "$STOCK/$P.img" "$IMG/$P.img"
  python - "$IMG/$P.img" <<'PY'
import struct,sys
p=sys.argv[1]
with open(p,'r+b') as f:
    if f.read(4)!=b'AVB0':
        raise SystemExit("NOT_AVB:"+p)
    f.seek(120)
    f.write(struct.pack(">I",3))
PY
done

cat > "$OUT/BUILD_INFO.txt" <<EOF
TARGET=dace
DONOR=axolotl
DONOR_BUILD=AW2A.240903.001.XM118S
TARGET_FCM=$TARGET_FCM
SUPER_SIZE=$SUPER_SIZE
DYNAMIC_PARTITIONS=$DYNAMIC_LIST
BOOT_SOURCE=$BOOT_SOURCE
RECOVERY_INCLUDED=NO
AVB_FLAGS=verification_disabled+hashtree_disabled
EOF

(
  cd "$IMG"
  sha256sum *.img > "$OUT/SHA256SUMS.txt"
)

cat > "$OUT/install_note.txt" <<'EOF'
NON FLASHARE ANCORA.
Questo è il primo candidato di build Wear 5.
La procedura di flash definitiva verrà generata dopo l'handoff finale della recovery wireless.
La recovery non è inclusa e non deve essere sovrascritta.
EOF

echo
echo "BUILD_READY=$OUT"
echo "SUPER=$(stat -c %s "$SUPER") bytes"
echo "BOOT_SOURCE=$BOOT_SOURCE"
echo "RECOVERY_INCLUDED=NO"
 | tail -1 || true)"
  if [ -n "$SUPER_SIZE" ]; then
    echo "super_partition_size=$SUPER_SIZE" >> "$META/target_dynamic_info.txt"
    echo "SUPER_SIZE_SOURCE=OTA_GPT"
  fi
fi

# Nessun accesso al watch durante il bootloop/recovery work.
[ -n "$SUPER_SIZE" ] || die "super_size_non_presente_offline_nell_OTA_attendere_solo_il_valore_dalla_recovery"

GROUPS="$(kv super_partition_groups || true)"
[ -n "$GROUPS" ] || die "super_partition_groups_non_rilevato"

META_SIZE="$(kv super_metadata_size || true)"
[ -n "$META_SIZE" ] || META_SIZE=65536
META_SLOTS="$(kv super_metadata_slots || true)"
[ -n "$META_SLOTS" ] || META_SLOTS=2

DYNAMIC_LIST="$(kv dynamic_partition_list || true)"
[ -n "$DYNAMIC_LIST" ] || {
  DYNAMIC_LIST=""
  for G in $GROUPS; do
    L="$(kv "${G}_partition_list" || true)"
    DYNAMIC_LIST="$DYNAMIC_LIST $L"
  done
}
DYNAMIC_LIST="$(echo "$DYNAMIC_LIST" | xargs)"
[ -n "$DYNAMIC_LIST" ] || die "lista_partizioni_dinamiche_vuota"

echo "SUPER_SIZE=$SUPER_SIZE"
echo "GROUPS=$GROUPS"
echo "PARTITIONS=$DYNAMIC_LIST"

echo "[4/6] Preparo immagini ibride"
for P in $DYNAMIC_LIST; do
  case "$P" in
    system|system_ext|product)
      SRC="$XIAOMI/$P.img"
      ;;
    *)
      SRC="$STOCK/$P.img"
      ;;
  esac
  [ -f "$SRC" ] || die "immagine_mancante_${P}"
  cp -f "$SRC" "$IMG/logical/$P.img"
done

LPM_ARGS=()
for G in $GROUPS; do
  GS="$(kv "${G}_size" || true)"
  [ -n "$GS" ] || die "dimensione_gruppo_${G}_non_rilevata"
  LPM_ARGS+=(--group "${G}:${GS}")
done

group_for_part(){
  local p="$1" g list q
  for g in $GROUPS; do
    list="$(kv "${g}_partition_list" || true)"
    for q in $list; do
      [ "$q" = "$p" ] && { echo "$g"; return 0; }
    done
  done
  return 1
}

for P in $DYNAMIC_LIST; do
  F="$IMG/logical/$P.img"
  SZ="$(stat -c %s "$F")"
  G="$(group_for_part "$P" || true)"
  [ -n "$G" ] || die "gruppo_non_trovato_per_${P}"
  LPM_ARGS+=(--partition "${P}:readonly:${SZ}:${G}" --image "${P}=${F}")
done

NEED_SHRINK=0
for G in $GROUPS; do
  GS="$(kv "${G}_size")"
  SUM=0
  LIST="$(kv "${G}_partition_list" || true)"
  for P in $LIST; do
    [ -f "$IMG/logical/$P.img" ] || continue
    SUM=$((SUM + $(stat -c %s "$IMG/logical/$P.img")))
  done
  [ "$SUM" -le "$GS" ] || NEED_SHRINK=1
done

if [ "$NEED_SHRINK" -eq 1 ]; then
  echo "Riduzione filesystem al minimo necessario per entrare nel super..."
  for P in $DYNAMIC_LIST; do
    F="$IMG/logical/$P.img"
    file -b "$F" | grep -qi 'ext[234] filesystem' || continue
    e2fsck -fy "$F" >/dev/null 2>&1 || true
    resize2fs -M "$F" >/dev/null 2>&1 || die "resize2fs_fallito_${P}"
  done

  LPM_ARGS=()
  for G in $GROUPS; do
    GS="$(kv "${G}_size")"
    LPM_ARGS+=(--group "${G}:${GS}")
    SUM=0
    LIST="$(kv "${G}_partition_list" || true)"
    for P in $LIST; do
      [ -f "$IMG/logical/$P.img" ] || continue
      SUM=$((SUM + $(stat -c %s "$IMG/logical/$P.img")))
    done
    [ "$SUM" -le "$GS" ] || die "spazio_super_insufficiente_gruppo_${G}_need_${SUM}_max_${GS}"
  done
  for P in $DYNAMIC_LIST; do
    F="$IMG/logical/$P.img"
    SZ="$(stat -c %s "$F")"
    G="$(group_for_part "$P")"
    LPM_ARGS+=(--partition "${P}:readonly:${SZ}:${G}" --image "${P}=${F}")
  done
fi

echo "[5/6] Costruisco super.img"
lpmake \
  --metadata-size "$META_SIZE" \
  --metadata-slots "$META_SLOTS" \
  --super-name super \
  --device "super:$SUPER_SIZE" \
  "${LPM_ARGS[@]}" \
  --output "$SUPER" >/dev/null || die "lpmake_fallito"

[ "$(stat -c %s "$SUPER")" -eq "$SUPER_SIZE" ] || die "dimensione_super_generata_non_coerente"

echo "[6/6] Preparo boot chain e AVB per bootloader sbloccato"

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

for P in vbmeta vbmeta_system; do
  [ -f "$STOCK/$P.img" ] || continue
  cp -f "$STOCK/$P.img" "$IMG/$P.img"
  python - "$IMG/$P.img" <<'PY'
import struct,sys
p=sys.argv[1]
with open(p,'r+b') as f:
    if f.read(4)!=b'AVB0':
        raise SystemExit("NOT_AVB:"+p)
    f.seek(120)
    f.write(struct.pack(">I",3))
PY
done

cat > "$OUT/BUILD_INFO.txt" <<EOF
TARGET=dace
DONOR=axolotl
DONOR_BUILD=AW2A.240903.001.XM118S
TARGET_FCM=$TARGET_FCM
SUPER_SIZE=$SUPER_SIZE
DYNAMIC_PARTITIONS=$DYNAMIC_LIST
BOOT_SOURCE=$BOOT_SOURCE
RECOVERY_INCLUDED=NO
AVB_FLAGS=verification_disabled+hashtree_disabled
EOF

(
  cd "$IMG"
  sha256sum *.img > "$OUT/SHA256SUMS.txt"
)

cat > "$OUT/install_note.txt" <<'EOF'
NON FLASHARE ANCORA.
Questo è il primo candidato di build Wear 5.
La procedura di flash definitiva verrà generata dopo l'handoff finale della recovery wireless.
La recovery non è inclusa e non deve essere sovrascritta.
EOF

echo
echo "BUILD_READY=$OUT"
echo "SUPER=$(stat -c %s "$SUPER") bytes"
echo "BOOT_SOURCE=$BOOT_SOURCE"
echo "RECOVERY_INCLUDED=NO"
