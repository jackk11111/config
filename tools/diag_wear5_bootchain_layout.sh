#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail

WORK="$HOME/WEAR5"
BUILD="/storage/emulated/0/Download/WEAR5_FIRST_BUILD"
SUPER="$BUILD/images/super.img"
STOCK_VENDOR="$WORK/stock/vendor.img"
ADB_HOST="10.82.56.57"
ADB_PORT="5037"
TARGET="${1:-C121X44260991}"

die(){ echo; echo "BLOCKER=$*"; exit 2; }

ADB=(adb -H "$ADB_HOST" -P "$ADB_PORT" -s "$TARGET")
STATE="$(adb -H "$ADB_HOST" -P "$ADB_PORT" devices 2>/dev/null | awk -v s="$TARGET" '$1==s{print $2; exit}')"
case "$STATE" in recovery|device|rescue) ;; *) die "adb_state_${STATE:-vuoto}";; esac

PRODUCT="$("${ADB[@]}" shell getprop ro.product.device 2>/dev/null | tr -d '\r' | tail -1)"
[ "$PRODUCT" = "dace" ] || die "device_${PRODUCT:-vuoto}"

SLOT_SUFFIX="$("${ADB[@]}" shell getprop ro.boot.slot_suffix 2>/dev/null | tr -d '\r' | tail -1)"
SLOT="$("${ADB[@]}" shell getprop ro.boot.slot 2>/dev/null | tr -d '\r' | tail -1)"
CMDLINE="$("${ADB[@]}" shell cat /proc/cmdline 2>/dev/null | tr -d '\r' || true)"
BYNAME="$("${ADB[@]}" shell 'ls -1 /dev/block/by-name 2>/dev/null' | tr -d '\r' || true)"
AB_COUNT="$(printf '%s\n' "$BYNAME" | grep -Ec '_(a|b)$' || true)"

BOOTCTL=""
if "${ADB[@]}" shell 'command -v bootctl >/dev/null 2>&1'; then
  BOOTCTL="$("${ADB[@]}" shell 'bootctl get-current-slot 2>/dev/null' | tr -d '\r' | tail -1 || true)"
fi

command -v lpdump >/dev/null 2>&1 || die "lpdump_non_disponibile_termux"
[ -f "$SUPER" ] || die "super_locale_mancante"
LP="$(lpdump "$SUPER" 2>/dev/null || true)"
[ -n "$LP" ] || die "lpdump_super_locale_fallito"

LP_NAMES="$(printf '%s\n' "$LP" | sed -n -E 's/^[[:space:]]*(Name|Partition name):[[:space:]]+([^[:space:]]+).*/\2/p' | sort -u)"
LP_AB_COUNT="$(printf '%s\n' "$LP_NAMES" | grep -Ec '_(a|b)$' || true)"

FSTAB_TEXT=""
if [ -f "$STOCK_VENDOR" ] && command -v debugfs >/dev/null 2>&1; then
  ETC_LIST="$(debugfs -R 'ls -p /etc' "$STOCK_VENDOR" 2>/dev/null || true)"
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    txt="$(debugfs -R "cat /etc/$name" "$STOCK_VENDOR" 2>/dev/null || true)"
    [ -n "$txt" ] && FSTAB_TEXT="$FSTAB_TEXT
### /etc/$name
$txt"
  done < <(printf '%s\n' "$ETC_LIST" | tr '/' '\n' | grep '^fstab' | sort -u)
fi

FSTAB_SLOTSELECT=0
printf '%s\n' "$FSTAB_TEXT" | grep -Eq '(^|,|[[:space:]])slotselect(_other)?([,[:space:]]|$)' && FSTAB_SLOTSELECT=1 || true

TARGET_AB=NO
[ -n "$SLOT_SUFFIX" ] && TARGET_AB=YES
[ -n "$SLOT" ] && TARGET_AB=YES
[ "$AB_COUNT" -gt 0 ] && TARGET_AB=YES
[ -n "$BOOTCTL" ] && TARGET_AB=YES
[ "$FSTAB_SLOTSELECT" -eq 1 ] && TARGET_AB=YES

SUPER_AB=NO
[ "$LP_AB_COUNT" -gt 0 ] && SUPER_AB=YES

echo "DIAG=PASS"
echo "ADB_STATE=$STATE"
echo "PRODUCT=$PRODUCT"
echo "RO_BOOT_SLOT_SUFFIX=${SLOT_SUFFIX:-EMPTY}"
echo "RO_BOOT_SLOT=${SLOT:-EMPTY}"
echo "BOOTCTL_SLOT=${BOOTCTL:-EMPTY}"
echo "BYNAME_AB_COUNT=$AB_COUNT"
echo "STOCK_FSTAB_SLOTSELECT=$FSTAB_SLOTSELECT"
echo "TARGET_AB=$TARGET_AB"
echo "SUPER_AB_NAMES=$SUPER_AB"
echo "SUPER_PARTITION_NAMES=$(printf '%s ' $LP_NAMES | sed 's/[[:space:]]$//')"
echo "CMDLINE_SLOT_TOKENS=$(printf '%s\n' "$CMDLINE" | grep -oE 'androidboot\.slot(_suffix)?=[^ ]+' | tr '\n' ',' | sed 's/,$//' || true)"

if [ "$TARGET_AB" = YES ] && [ "$SUPER_AB" = NO ]; then
  echo "FINDING=SUPER_SLOT_LAYOUT_MISMATCH"
elif [ "$TARGET_AB" = NO ] && [ "$SUPER_AB" = NO ]; then
  echo "FINDING=SUPER_SLOT_LAYOUT_CONSISTENT_NON_AB"
else
  echo "FINDING=NEEDS_MANUAL_REVIEW"
fi

if [ -n "$FSTAB_TEXT" ]; then
  echo
  echo "=== STOCK VENDOR FSTAB logical/slot lines ==="
  printf '%s\n' "$FSTAB_TEXT" | grep -E '(^#| /system| /vendor| /product| /system_ext|logical|slotselect|first_stage_mount)' | head -n 80 || true
fi
