#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail

BUILD_DIR="/storage/emulated/0/Download/WEAR5_FIRST_BUILD"
SRC="$BUILD_DIR/images/vbmeta.img"
ADB_HOST="10.82.56.57"
ADB_PORT="5037"
TARGET="${1:-C121X44260991}"
STAGE="/cache/wear5_vbmeta_fixed.img"

die(){ echo; echo "BLOCKER=$*"; exit 2; }

[ -f "$SRC" ] || die "vbmeta_build_mancante"
IMG_SIZE="$(stat -c %s "$SRC")"
[ "$IMG_SIZE" = "8192" ] || die "vbmeta_image_size_${IMG_SIZE:-vuoto}_atteso_8192"

python - "$SRC" <<'PY'
import struct,sys
p=sys.argv[1]
b=open(p,'rb').read()
if b[:4] != b'AVB0':
    raise SystemExit("BLOCKER=vbmeta_not_avb")
flags=struct.unpack(">I",b[120:124])[0]
if flags != 3:
    raise SystemExit("BLOCKER=vbmeta_flags_%d_atteso_3"%flags)
print("SOURCE_FLAGS=3")
PY

SRC_SHA="$(sha256sum "$SRC" | awk '{print $1}')"

ADB=(adb -H "$ADB_HOST" -P "$ADB_PORT" -s "$TARGET")
STATE="$(adb -H "$ADB_HOST" -P "$ADB_PORT" devices 2>/dev/null | awk -v s="$TARGET" '$1==s{print $2; exit}')"
case "$STATE" in recovery|device|rescue) ;; *) die "adb_state_${STATE:-vuoto}";; esac

PRODUCT="$("${ADB[@]}" shell getprop ro.product.device 2>/dev/null | tr -d '\r' | tail -1)"
[ "$PRODUCT" = "dace" ] || die "device_${PRODUCT:-vuoto}"

REMOTE_UID="$("${ADB[@]}" shell id -u 2>/dev/null | tr -d '\r' | tail -1)"
[ "$REMOTE_UID" = "0" ] || die "adb_non_root_uid_${REMOTE_UID:-vuoto}"

DEV="$("${ADB[@]}" shell 'readlink -f /dev/block/by-name/vbmeta 2>/dev/null' | tr -d '\r' | tail -1)"
[ -n "$DEV" ] || die "vbmeta_device_non_trovato"

PART_SIZE="$("${ADB[@]}" shell "blockdev --getsize64 '$DEV'" 2>/dev/null | tr -d '\r' | grep -E '^[0-9]+$' | tail -1)"
[ -n "$PART_SIZE" ] || die "vbmeta_partition_size_non_rilevata"
[ "$PART_SIZE" -ge "$IMG_SIZE" ] || die "vbmeta_partition_troppo_piccola_${PART_SIZE}"

echo "PREFLIGHT=PASS"
echo "ADB_STATE=$STATE"
echo "PRODUCT=$PRODUCT"
echo "VBMETA_DEV=$DEV"
echo "VBMETA_PARTITION_SIZE=$PART_SIZE"
echo "VBMETA_IMAGE_SIZE=$IMG_SIZE"
echo "SOURCE_SHA256=$SRC_SHA"

"${ADB[@]}" shell "rm -f '$STAGE'" >/dev/null 2>&1 || true
echo "STAGING=vbmeta_flags3"
"${ADB[@]}" push "$SRC" "$STAGE" >/dev/null || die "push_fallito"

STAGE_SHA="$("${ADB[@]}" shell "sha256sum '$STAGE' 2>/dev/null" | tr -d '\r' | awk '{print $1}' | tail -1)"
[ "$STAGE_SHA" = "$SRC_SHA" ] || die "stage_sha_fallita_${STAGE_SHA:-vuoto}"
echo "STAGE_SHA256=$STAGE_SHA"

echo "FLASHING=vbmeta_only"
"${ADB[@]}" shell "dd if='$STAGE' of='$DEV' bs=8192 count=1 conv=fsync 2>/dev/null && sync" >/dev/null || die "flash_fallito"

REMOTE_SHA="$("${ADB[@]}" shell "dd if='$DEV' bs=8192 count=1 2>/dev/null | sha256sum" | tr -d '\r' | awk '{print $1}' | tail -1)"
[ "$REMOTE_SHA" = "$SRC_SHA" ] || die "verifica_remota_fallita_${REMOTE_SHA:-vuoto}"

"${ADB[@]}" shell "rm -f '$STAGE'" >/dev/null 2>&1 || true

echo "VBMETA_FIX=PASS"
echo "REMOTE_SHA256=$REMOTE_SHA"
echo "SUPER_UNCHANGED=YES"
echo "BOOT_UNCHANGED=YES"
echo "VBMETA_SYSTEM_UNCHANGED=YES"
echo "RECOVERY_TOUCHED=NO"
echo "NEXT=manual_reboot_test"
