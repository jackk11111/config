#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail

ADB_HOST="10.82.56.57"
ADB_PORT="5037"
TARGET="${1:-C121X44260991}"
PARTS=(system system_ext product vendor vendor_dlkm system_dlkm)

die(){ echo; echo "BLOCKER=$*"; exit 2; }
ADB=(adb -H "$ADB_HOST" -P "$ADB_PORT" -s "$TARGET")

STATE="$(adb -H "$ADB_HOST" -P "$ADB_PORT" devices 2>/dev/null | awk -v s="$TARGET" '$1==s{print $2; exit}')"
case "$STATE" in recovery|device|rescue) ;; *) die "adb_state_${STATE:-vuoto}";; esac
PRODUCT="$("${ADB[@]}" shell getprop ro.product.device 2>/dev/null | tr -d "\r" | tail -1)"
[ "$PRODUCT" = "dace" ] || die "device_${PRODUCT:-vuoto}"
REMOTE_UID="$("${ADB[@]}" shell id -u 2>/dev/null | tr -d "\r" | tail -1)"
[ "$REMOTE_UID" = "0" ] || die "adb_non_root_uid_${REMOTE_UID:-vuoto}"

echo "PREFLIGHT=PASS"
echo "ADB_STATE=$STATE"
echo "PRODUCT=$PRODUCT"

echo "=== AVAILABLE TOOLS ==="
"${ADB[@]}" shell 'for x in lpdump dmctl dmsetup mount e2fsck fsck.ext4; do p=$(command -v "$x" 2>/dev/null || true); [ -n "$p" ] && echo "$x=$p" || echo "$x=MISSING"; done' | tr -d "\r"

echo "=== MAPPER NODES ==="
"${ADB[@]}" shell 'ls -la /dev/block/mapper 2>/dev/null || echo NO_MAPPER_DIR' | tr -d "\r"

SUPER="$("${ADB[@]}" shell 'readlink -f /dev/block/by-name/super 2>/dev/null' | tr -d "\r" | tail -1)"
[ -n "$SUPER" ] || die "super_device_non_trovato"
echo "SUPER_DEV=$SUPER"

if "${ADB[@]}" shell 'command -v lpdump >/dev/null 2>&1'; then
  echo "=== LIVE SUPER METADATA ==="
  "${ADB[@]}" shell "lpdump '$SUPER' 2>/dev/null | grep -E '^[[:space:]]*(Name:|Partition name:|Group:|Extent|Linear extent|First sector:|Size:)' | head -n 160" | tr -d "\r" || true
fi

PASS=0
FAIL=0
MISSING=0

for P in "${PARTS[@]}"; do
  echo
  echo "=== $P ==="
  DEV="$("${ADB[@]}" shell "readlink -f /dev/block/mapper/$P 2>/dev/null || true" | tr -d "\r" | tail -1)"
  if [ -z "$DEV" ] || ! "${ADB[@]}" shell "[ -b '$DEV' ]" >/dev/null 2>&1; then
    echo "MAP=MISSING"
    MISSING=$((MISSING+1))
    continue
  fi
  echo "MAP=$DEV"
  SIZE="$("${ADB[@]}" shell "blockdev --getsize64 '$DEV' 2>/dev/null" | tr -d "\r" | tail -1)"
  echo "SIZE=${SIZE:-UNKNOWN}"

  MNT="/mnt/wear5_test_$P"
  "${ADB[@]}" shell "mkdir -p '$MNT'; umount '$MNT' >/dev/null 2>&1 || true" >/dev/null 2>&1 || true
  set +e
  MOUT="$("${ADB[@]}" shell "mount -t ext4 -o ro,noload '$DEV' '$MNT'" 2>&1)"
  RC=$?
  set -e
  if [ "$RC" -ne 0 ]; then
    echo "MOUNT=FAIL"
    echo "ERROR=$(printf "%s" "$MOUT" | tr "\n" " " | head -c 300)"
    FAIL=$((FAIL+1))
    continue
  fi
  echo "MOUNT=PASS"
  ROOT="$("${ADB[@]}" shell "ls -ld '$MNT' 2>/dev/null" | tr -d "\r" | tail -1)"
  echo "ROOT=${ROOT:-UNKNOWN}"
  case "$P" in
    system) "${ADB[@]}" shell "[ -x '$MNT/system/bin/init' ] && echo INIT_PRESENT=YES || echo INIT_PRESENT=NO" | tr -d "\r" ;;
    vendor) "${ADB[@]}" shell "[ -f '$MNT/etc/fstab.dace' ] && echo FSTAB_DACE_PRESENT=YES || echo FSTAB_DACE_PRESENT=NO" | tr -d "\r" ;;
  esac
  "${ADB[@]}" shell "umount '$MNT'" >/dev/null 2>&1 || true
  PASS=$((PASS+1))
done

echo
echo "MOUNT_PASS=$PASS"
echo "MOUNT_FAIL=$FAIL"
echo "MAP_MISSING=$MISSING"
if [ "$FAIL" -gt 0 ]; then
  echo "FINDING=LOGICAL_PARTITION_MOUNT_FAILURE"
elif [ "$MISSING" -eq 0 ] && [ "$PASS" -eq "${#PARTS[@]}" ]; then
  echo "FINDING=ALL_LOGICAL_PARTITIONS_MAP_AND_MOUNT"
else
  echo "FINDING=RECOVERY_DID_NOT_CREATE_ALL_LOGICAL_MAPPINGS"
fi
