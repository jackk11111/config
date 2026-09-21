#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail

ADB_HOST="10.82.56.57"
ADB_PORT="5037"
TARGET="${1:-C121X44260991}"
ADB=(adb -H "$ADB_HOST" -P "$ADB_PORT" -s "$TARGET")

die(){ echo; echo "BLOCKER=$*"; exit 2; }

echo "[1/7] PRECHECK"
STATE="$(timeout 5s "${ADB[@]}" get-state </dev/null 2>/dev/null | tr -d '\r' | tail -1)" || die "adb_timeout"
[ "$STATE" = "recovery" ] || die "not_in_recovery_$STATE"

PRE="$(timeout 5s "${ADB[@]}" shell 'printf "DEVICE="; getprop ro.product.device; printf "UID="; id -u' </dev/null 2>/dev/null | tr -d '\r')" || die "adb_shell_timeout"
printf '%s\n' "$PRE"
DEVICE="$(printf '%s\n' "$PRE" | sed -n 's/^DEVICE=//p' | tail -1)"
UIDR="$(printf '%s\n' "$PRE" | sed -n 's/^UID=//p' | tail -1)"
[ "$DEVICE" = "dace" ] || die "wrong_device_$DEVICE"
[ "$UIDR" = "0" ] || die "not_root_$UIDR"

echo "[2/7] VERIFY_USERDATA_BLOCK"
BLK="$(timeout 5s "${ADB[@]}" shell 'readlink -f /dev/block/bootdevice/by-name/userdata' </dev/null 2>/dev/null | tr -d '\r' | tail -1)" || die "userdata_resolve_timeout"
[ -n "$BLK" ] || die "userdata_block_missing"
case "$BLK" in
  /dev/block/*) ;;
  *) die "unexpected_userdata_path_$BLK" ;;
esac
echo "USERDATA_BLOCK=$BLK"

SIZE="$(timeout 5s "${ADB[@]}" shell "blockdev --getsize64 '$BLK'" </dev/null 2>/dev/null | tr -d '\r' | tail -1)" || die "userdata_size_timeout"
case "$SIZE" in
  ''|*[!0-9]*) die "invalid_userdata_size_$SIZE" ;;
esac
[ "$SIZE" -gt 1073741824 ] || die "userdata_too_small_$SIZE"
echo "USERDATA_SIZE=$SIZE"

echo "[3/7] PRESERVE_RESCUE_METADATA"
RESCUE="$("${ADB[@]}" shell '[ -d /metadata/ticwatch-rescue ] && echo PRESENT || echo ABSENT' </dev/null 2>/dev/null | tr -d '\r' | tail -1)"
echo "TICWATCH_RESCUE=$RESCUE"

echo "[4/7] UNMOUNT_DATA"
timeout 8s "${ADB[@]}" shell '
umount /data >/dev/null 2>&1 || true
for m in /mnt/userdata /mnt/data; do umount "$m" >/dev/null 2>&1 || true; done
' </dev/null >/dev/null || die "unmount_timeout"

echo "[5/7] REMOVE_OLD_METADATA_ENCRYPTION_KEY"
timeout 8s "${ADB[@]}" shell '
set -e
rm -rf /metadata/vold/metadata_encryption
sync
[ ! -e /metadata/vold/metadata_encryption ]
' </dev/null >/dev/null || die "metadata_key_remove_failed"
echo "METADATA_KEY_REMOVED=YES"

echo "[6/7] ERASE_USERDATA"
# Prefer blkdiscard: fast and leaves userdata unmistakably blank.
# If unsupported by this storage/recovery, fall back to zeroing both ends
# so no valid F2FS superblock/checkpoint survives and fs_mgr formattable
# can recreate userdata on the next normal boot.
if timeout 30s "${ADB[@]}" shell "blkdiscard -f '$BLK'" </dev/null >/dev/null 2>&1; then
  timeout 12s "${ADB[@]}" shell "dd if=/dev/zero of='$BLK' bs=1M count=16 conv=fsync 2>/dev/null" </dev/null >/dev/null || die "userdata_head_zero_after_discard_failed"
  echo "ERASE_METHOD=blkdiscard_plus_zero_head"
else
  echo "BLKDISCARD_UNAVAILABLE=YES"
  timeout 20s "${ADB[@]}" shell "
    set -e
    SZ=\$(blockdev --getsize64 '$BLK')
    dd if=/dev/zero of='$BLK' bs=1M count=16 conv=fsync 2>/dev/null
    OFF=\$((SZ/1048576-16))
    [ \$OFF -gt 0 ]
    dd if=/dev/zero of='$BLK' bs=1M seek=\$OFF count=16 conv=fsync 2>/dev/null
    sync
  " </dev/null >/dev/null || die "userdata_zero_failed"
  echo "ERASE_METHOD=zero_edges"
fi

echo "[7/7] VERIFY_BLANK_AND_RESCUE"
HEAD="$(timeout 8s "${ADB[@]}" shell "dd if='$BLK' bs=4096 count=1 2>/dev/null | sha256sum" </dev/null 2>/dev/null | tr -d '\r' | awk '{print $1}' | tail -1)" || die "blank_verify_timeout"
ZERO4K="$(printf '\0%.0s' {1..4096} | sha256sum | awk '{print $1}')"
[ "$HEAD" = "$ZERO4K" ] || die "userdata_head_not_blank"

if [ "$RESCUE" = "PRESENT" ]; then
  R2="$("${ADB[@]}" shell '[ -d /metadata/ticwatch-rescue ] && echo PRESENT || echo ABSENT' </dev/null 2>/dev/null | tr -d '\r' | tail -1)"
  [ "$R2" = "PRESENT" ] || die "rescue_metadata_lost"
fi

echo
echo "CLEAN_DATA_FIX=PASS"
echo "USERDATA_ERASED=YES"
echo "OLD_METADATA_KEY_REMOVED=YES"
echo "TICWATCH_RESCUE_PRESERVED=$RESCUE"
echo "BOOT_SUPER_RECOVERY_TOUCHED=NO"
echo "NEXT=ONE_NORMAL_BOOT"
