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
VM="$STAGE2/stock/vendor/vintf_root/vintf/manifest.xml"
[ -f "$VM" ] || die "manifest_VINTF_stock_non_trovato"

TARGET_FCM="$(grep -oE 'target-level="[0-9]+"' "$VM" | head -1 | grep -oE '[0-9]+' || true)"
[ -n "$TARGET_FCM" ] || die "target_FCM_stock_non_rilevato"

DONOR_MATRIX="$STAGE2/xiaomi/system/vintf_root/vintf/compatibility_matrix.$TARGET_FCM.xml"
[ -f "$DONOR_MATRIX" ] || die "donor_Wear5_non_contiene_FCM_${TARGET_FCM}"

echo "TARGET_FCM=$TARGET_FCM"

echo "[3/6] Leggo geometria super TicWatch"
: > "$META/target_dynamic_info.txt"
while IFS= read -r E; do
  unzip -p "$STOCK_OTA" "$E" >> "$META/target_dynamic_info.txt" 2>/dev/null || true
  echo >> "$META/target_dynamic_info.txt"
done < <(unzip -Z1 "$STOCK_OTA" | grep -E '(^|/)(dynamic_partitions_info|misc_info)\.txt$' || true)

[ -s "$META/target_dynamic_info.txt" ] || die "metadata_dynamic_partitions_non_present_nell_OTA"

AB="$(kv ab_update || true)"
VAB="$(kv virtual_ab || true)"
if [ "$AB" = "true" ] || [ "$VAB" = "true" ]; then
  die "layout_AB_o_VirtualAB_rilevato_da_gestire_specificamente"
fi

SUPER_SIZE="$(kv super_partition_size || true)"
BLOCK_DEVS="$(kv super_block_devices || true)"
if [ -z "$SUPER_SIZE" ] && [ -n "$BLOCK_DEVS" ]; then
  D="$(printf '%s' "$BLOCK_DEVS" | awk '{print $1}')"
  SUPER_SIZE="$(kv "super_${D}_device_size" || true)"
fi
[ -n "$SUPER_SIZE" ] || die "super_partition_size_non_rilevata"

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
