#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail

WORK="$HOME/WEAR5"
STOCK="$WORK/stock/vbmeta_system.img"
BUILD_DIR="/storage/emulated/0/Download/WEAR5_FIRST_BUILD"
BUILD="$BUILD_DIR/images/vbmeta_system.img"
ADB_HOST="10.82.56.57"
ADB_PORT="5037"
TARGET="${1:-C121X44260991}"
STAGE="/cache/wear5_vbmeta_system_fixed.img"

die(){ echo; echo "BLOCKER=$*"; exit 2; }

[ -f "$STOCK" ] || die "stock_vbmeta_system_mancante"
[ "$(stat -c %s "$STOCK")" = "4096" ] || die "stock_vbmeta_system_size_inattesa"

python - "$STOCK" <<'PY'
import struct,sys
p=sys.argv[1]
b=open(p,'rb').read()
if b[:4] != b'AVB0':
    raise SystemExit("BLOCKER=stock_vbmeta_system_not_avb")
flags=struct.unpack(">I",b[120:124])[0]
if flags != 0:
    raise SystemExit("BLOCKER=stock_vbmeta_system_flags_nonzero_%d"%flags)
print("SOURCE_FLAGS=0")
PY

mkdir -p "$(dirname "$BUILD")"
cp -f "$STOCK" "$BUILD"
SOURCE_SHA="$(sha256sum "$STOCK" | awk '{print $1}')"
BUILD_SHA="$(sha256sum "$BUILD" | awk '{print $1}')"
[ "$SOURCE_SHA" = "$BUILD_SHA" ] || die "copia_locale_non_identica"

ADB=(adb -H "$ADB_HOST" -P "$ADB_PORT" -s "$TARGET")
STATE="$(adb -H "$ADB_HOST" -P "$ADB_PORT" devices 2>/dev/null | awk -v s="$TARGET" '$1==s{print $2; exit}')"
case "$STATE" in recovery|device|rescue) ;; *) die "adb_state_${STATE:-vuoto}";; esac

PRODUCT="$("${ADB[@]}" shell getprop ro.product.device 2>/dev/null | tr -d '\r' | tail -1)"
[ "$PRODUCT" = "dace" ] || die "device_${PRODUCT:-vuoto}"

REMOTE_UID="$("${ADB[@]}" shell id -u 2>/dev/null | tr -d '\r' | tail -1)"
[ "$REMOTE_UID" = "0" ] || die "adb_non_root_uid_${REMOTE_UID:-vuoto}"

DEV="$("${ADB[@]}" shell 'readlink -f /dev/block/by-name/vbmeta_system 2>/dev/null' | tr -d '\r' | tail -1)"
[ -n "$DEV" ] || die "vbmeta_system_device_non_trovato"
SIZE="$("${ADB[@]}" shell "blockdev --getsize64 '$DEV'" 2>/dev/null | tr -d '\r' | grep -E '^[0-9]+$' | tail -1)"
[ "$SIZE" = "65536" ] || die "vbmeta_system_target_size_${SIZE:-vuoto}_atteso_65536"

echo "PREFLIGHT=PASS"
echo "ADB_STATE=$STATE"
echo "PRODUCT=$PRODUCT"
echo "VBMETA_SYSTEM_DEV=$DEV"
echo "VBMETA_SYSTEM_PARTITION_SIZE=$SIZE"
echo "VBMETA_SYSTEM_IMAGE_SIZE=4096"
echo "SOURCE_SHA256=$SOURCE_SHA"
echo "LOCAL_BUILD_SHA256=$BUILD_SHA"

"${ADB[@]}" shell "rm -f '$STAGE'" >/dev/null 2>&1 || true
echo "STAGING=vbmeta_system_flags0"
"${ADB[@]}" push "$BUILD" "$STAGE" >/dev/null || die "push_fallito"

STAGE_SHA="$("${ADB[@]}" shell "sha256sum '$STAGE' 2>/dev/null" | tr -d '\r' | awk '{print $1}' | tail -1)"
[ "$STAGE_SHA" = "$SOURCE_SHA" ] || die "stage_sha_fallita_${STAGE_SHA:-vuoto}"
echo "STAGE_SHA256=$STAGE_SHA"

echo "FLASHING=vbmeta_system_only"
"${ADB[@]}" shell "dd if='$STAGE' of='$DEV' bs=4096 conv=fsync 2>/dev/null && sync" >/dev/null || die "flash_fallito"

REMOTE_SHA="$("${ADB[@]}" shell "dd if='$DEV' bs=4096 count=1 2>/dev/null | sha256sum" | tr -d '\r' | awk '{print $1}' | tail -1)"
[ "$REMOTE_SHA" = "$SOURCE_SHA" ] || die "verifica_remota_fallita_${REMOTE_SHA:-vuoto}"

"${ADB[@]}" shell "rm -f '$STAGE'" >/dev/null 2>&1 || true

(
  cd "$BUILD_DIR/images"
  find . -maxdepth 1 -type f -name '*.img' -print0 | sort -z | xargs -0 -r sha256sum
) > "$BUILD_DIR/SHA256SUMS.txt"

cat > "$BUILD_DIR/AVB_FLAGS.txt" <<EOF
vbmeta.img:flags=3
vbmeta_system.img:flags=0
EOF

echo "AVB_FIX=PASS"
echo "REMOTE_SHA256=$REMOTE_SHA"
echo "VBMETA_TOPLEVEL_UNCHANGED=YES"
echo "SUPER_UNCHANGED=YES"
echo "BOOT_UNCHANGED=YES"
echo "RECOVERY_TOUCHED=NO"
echo "NEXT=manual_reboot_test"
