#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail

BUILD="/storage/emulated/0/Download/WEAR5_FIRST_BUILD/images"
BOOT_SRC="/storage/emulated/0/Download/Telegram/Watch/kernel e recovery/boot_CURRENT_WORKING_5.15.220.img"
ADB_HOST="10.82.56.57"
ADB_PORT="5037"
TARGET="${1:-C121X44260991}"

die(){ echo; echo "BLOCKER=$*"; exit 2; }
for f in "$BUILD/boot.img" "$BUILD/vbmeta.img" "$BUILD/vbmeta_system.img" "$BOOT_SRC"; do
  [ -f "$f" ] || die "file_mancante_$f"
done

ADB=(adb -H "$ADB_HOST" -P "$ADB_PORT" -s "$TARGET")
STATE="$(adb -H "$ADB_HOST" -P "$ADB_PORT" devices 2>/dev/null | awk -v s="$TARGET" '$1==s{print $2; exit}')"
case "$STATE" in recovery|device|rescue) ;; *) die "adb_state_${STATE:-vuoto}";; esac

PRODUCT="$("${ADB[@]}" shell getprop ro.product.device 2>/dev/null | tr -d '\r' | tail -1)"
[ "$PRODUCT" = "dace" ] || die "device_${PRODUCT:-vuoto}"
REMOTE_UID="$("${ADB[@]}" shell id -u 2>/dev/null | tr -d '\r' | tail -1)"
[ "$REMOTE_UID" = "0" ] || die "adb_non_root_uid_${REMOTE_UID:-vuoto}"

getdev(){ "${ADB[@]}" shell "readlink -f /dev/block/by-name/$1 2>/dev/null" | tr -d '\r' | tail -1; }
BOOT_DEV="$(getdev boot)"
VBMETA_DEV="$(getdev vbmeta)"
VBMETA_SYSTEM_DEV="$(getdev vbmeta_system)"
[ -n "$BOOT_DEV" ] || die "boot_dev_mancante"
[ -n "$VBMETA_DEV" ] || die "vbmeta_dev_mancante"
[ -n "$VBMETA_SYSTEM_DEV" ] || die "vbmeta_system_dev_mancante"

hash_remote_prefix(){
  local dev="$1" bytes="$2" bs count
  if (( bytes % 1048576 == 0 )); then
    bs=1048576
    count=$((bytes / 1048576))
  elif (( bytes % 4096 == 0 )); then
    bs=4096
    count=$((bytes / 4096))
  else
    bs=512
    count=$((bytes / 512))
  fi
  "${ADB[@]}" shell "dd if='$dev' bs='$bs' count='$count' 2>/dev/null | sha256sum" \
    | tr -d '\r' | awk '{print $1}' | tail -1
}

BOOT_SIZE="$(stat -c %s "$BUILD/boot.img")"
VBMETA_SIZE="$(stat -c %s "$BUILD/vbmeta.img")"
VBMETA_SYSTEM_SIZE="$(stat -c %s "$BUILD/vbmeta_system.img")"

BOOT_SRC_SHA="$(sha256sum "$BOOT_SRC" | awk '{print $1}')"
BOOT_BUILD_SHA="$(sha256sum "$BUILD/boot.img" | awk '{print $1}')"
VBMETA_BUILD_SHA="$(sha256sum "$BUILD/vbmeta.img" | awk '{print $1}')"
VBMETA_SYSTEM_BUILD_SHA="$(sha256sum "$BUILD/vbmeta_system.img" | awk '{print $1}')"

echo "READING_REMOTE_HASHES=YES"
BOOT_REMOTE_SHA="$(hash_remote_prefix "$BOOT_DEV" "$BOOT_SIZE")"
VBMETA_REMOTE_SHA="$(hash_remote_prefix "$VBMETA_DEV" "$VBMETA_SIZE")"
VBMETA_SYSTEM_REMOTE_SHA="$(hash_remote_prefix "$VBMETA_SYSTEM_DEV" "$VBMETA_SYSTEM_SIZE")"

echo "DIAG=PASS"
echo "ADB_STATE=$STATE"
echo "PRODUCT=$PRODUCT"
echo "BOOT_SOURCE=$BOOT_SRC"
echo "BOOT_IMAGE_SIZE=$BOOT_SIZE"
echo "BOOT_SOURCE_SHA256=$BOOT_SRC_SHA"
echo "BOOT_BUILD_SHA256=$BOOT_BUILD_SHA"
echo "BOOT_REMOTE_SHA256=$BOOT_REMOTE_SHA"
echo "VBMETA_IMAGE_SIZE=$VBMETA_SIZE"
echo "VBMETA_BUILD_SHA256=$VBMETA_BUILD_SHA"
echo "VBMETA_REMOTE_SHA256=$VBMETA_REMOTE_SHA"
echo "VBMETA_SYSTEM_IMAGE_SIZE=$VBMETA_SYSTEM_SIZE"
echo "VBMETA_SYSTEM_BUILD_SHA256=$VBMETA_SYSTEM_BUILD_SHA"
echo "VBMETA_SYSTEM_REMOTE_SHA256=$VBMETA_SYSTEM_REMOTE_SHA"

ISSUES=()
[ "$BOOT_SRC_SHA" = "$BOOT_BUILD_SHA" ] || ISSUES+=("BUILD_BOOT_NOT_SOURCE_220")
[ "$BOOT_BUILD_SHA" = "$BOOT_REMOTE_SHA" ] || ISSUES+=("REMOTE_BOOT_MISMATCH")
[ "$VBMETA_BUILD_SHA" = "$VBMETA_REMOTE_SHA" ] || ISSUES+=("REMOTE_VBMETA_MISMATCH")
[ "$VBMETA_SYSTEM_BUILD_SHA" = "$VBMETA_SYSTEM_REMOTE_SHA" ] || ISSUES+=("REMOTE_VBMETA_SYSTEM_MISMATCH")

if [ "${#ISSUES[@]}" -eq 0 ]; then
  echo "FINDING=BOOTCHAIN_HASHES_MATCH"
else
  printf 'FINDING=%s\n' "$(IFS=,; echo "${ISSUES[*]}")"
fi
