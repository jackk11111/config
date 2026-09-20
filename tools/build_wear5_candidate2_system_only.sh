#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail

WORK="$HOME/WEAR5"
STOCK="$WORK/stock"
XIAOMI="$WORK/xiaomi"
OUT="/storage/emulated/0/Download/WEAR5_CANDIDATE2_SYSTEM_ONLY"
IMG="$OUT/images"
LOGICAL="$IMG/logical"
SUPER="$IMG/super.img"
SUPER_SIZE=4294967296
GROUP="qti_dynamic_partitions"
GROUP_SIZE=4284481536
PARTS=(system vendor product system_ext vendor_dlkm system_dlkm)

die(){ echo; echo "BLOCKER=$*"; exit 2; }

command -v lpmake >/dev/null 2>&1 || die "lpmake_non_disponibile"
command -v lpdump >/dev/null 2>&1 || die "lpdump_non_disponibile"

rm -rf "$OUT"
mkdir -p "$LOGICAL"

echo "[1/4] Logical images"
for P in "${PARTS[@]}"; do
  case "$P" in
    system) SRC="$XIAOMI/system.img" ;;
    *) SRC="$STOCK/$P.img" ;;
  esac
  [ -f "$SRC" ] || die "immagine_mancante_$SRC"
  cp -f "$SRC" "$LOGICAL/$P.img"
  echo "$P <- $SRC"
done

SUM=0
for P in "${PARTS[@]}"; do
  SZ="$(stat -c %s "$LOGICAL/$P.img")"
  SUM=$((SUM + SZ))
done
[ "$SUM" -le "$GROUP_SIZE" ] || die "immagini_$SUM_superano_group_$GROUP_SIZE"
echo "IMAGES_TOTAL=$SUM"
echo "GROUP_HEADROOM=$((GROUP_SIZE-SUM))"

echo "[2/4] Build super"
ARGS=(--group "$GROUP:$GROUP_SIZE")
for P in "${PARTS[@]}"; do
  F="$LOGICAL/$P.img"
  SZ="$(stat -c %s "$F")"
  ARGS+=(--partition "$P:readonly:$SZ:$GROUP" --image "$P=$F")
done

lpmake   --metadata-size 65536   --metadata-slots 2   --super-name super   --device "super:$SUPER_SIZE"   "${ARGS[@]}"   --output "$SUPER" >/dev/null || die "lpmake_fallito"

[ "$(stat -c %s "$SUPER")" = "$SUPER_SIZE" ] || die "super_size_errata"
lpdump "$SUPER" > "$OUT/SUPER_LPDUMP.txt" 2>&1 || die "lpdump_fallito"

for P in "${PARTS[@]}"; do
  grep -Eq "Name:[[:space:]]+$P$|Partition name:[[:space:]]+$P$|^[[:space:]]*$P[[:space:]]" "$OUT/SUPER_LPDUMP.txt"     || die "partizione_$P_non_trovata"
done

echo "[3/4] Boot-chain references"
KERNEL="/storage/emulated/0/Download/Telegram/Watch/kernel e recovery/boot_CURRENT_WORKING_5.15.220.img"
[ -f "$KERNEL" ] || die "kernel_220_mancante"
cp -f "$KERNEL" "$IMG/boot.img"
for P in init_boot vendor_boot dtbo vbmeta vbmeta_system; do
  [ -f "$STOCK/$P.img" ] || die "stock_$P_mancante"
  cp -f "$STOCK/$P.img" "$IMG/$P.img"
done

# Only top-level vbmeta may carry verification/hashtree-disabled flags.
python - "$IMG/vbmeta.img" <<'PY'
import struct,sys
p=sys.argv[1]
with open(p,'r+b') as f:
    if f.read(4)!=b'AVB0':
        raise SystemExit("NOT_AVB")
    f.seek(120)
    f.write(struct.pack(">I",3))
PY

python - "$IMG/vbmeta_system.img" <<'PY'
import struct,sys
p=sys.argv[1]
b=open(p,'rb').read(124)
if b[:4]!=b'AVB0' or struct.unpack(">I",b[120:124])[0] != 0:
    raise SystemExit("BAD_CHAINED_VBMETA_SYSTEM")
PY

echo "[4/4] Hashes"
sha256sum "$SUPER" > "$OUT/SUPER_SHA256.txt"
(
  cd "$IMG"
  find . -maxdepth 1 -type f -name '*.img' -print0 | sort -z | xargs -0 -r sha256sum
) > "$OUT/SHA256SUMS.txt"

cat > "$OUT/BUILD_INFO.txt" <<EOF
CANDIDATE=2
STRATEGY=SYSTEM_ONLY_DONOR
TARGET=dace
TARGET_ANDROID_BASE=13
DONOR=axolotl
DONOR_ANDROID=14
DONOR_PARTITIONS=system
TARGET_PARTITIONS=vendor product system_ext vendor_dlkm system_dlkm
BOOT_SOURCE=$KERNEL
SUPER_SIZE=$SUPER_SIZE
GROUP_SIZE=$GROUP_SIZE
RECOVERY_INCLUDED=NO
EOF

echo
echo "BUILD=PASS"
echo "CANDIDATE=2_SYSTEM_ONLY"
echo "SUPER=$SUPER"
echo "SUPER_SHA256=$(awk '{print $1}' "$OUT/SUPER_SHA256.txt")"
echo "BOOT_220_SHA256=$(sha256sum "$IMG/boot.img" | awk '{print $1}')"
echo "RECOVERY_INCLUDED=NO"
