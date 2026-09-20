#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail

BUILD="/storage/emulated/0/Download/WEAR5_CANDIDATE2_SYSTEM_ONLY"
SUPER="$BUILD/images/super.img"
HASHFILE="$BUILD/SUPER_SHA256.txt"
ADB_HOST="10.82.56.57"
ADB_PORT="5037"
TARGET="${1:-C121X44260991}"

die(){ echo; echo "BLOCKER=$*"; exit 2; }

[ -f "$SUPER" ] || die "candidate2_super_mancante"
[ -f "$HASHFILE" ] || die "candidate2_hash_mancante"
[ "$(stat -c %s "$SUPER")" = "4294967296" ] || die "candidate2_super_size_errata"

EXPECTED="$(awk '{print $1; exit}' "$HASHFILE")"
ACTUAL="$(sha256sum "$SUPER" | awk '{print $1}')"
[ "$EXPECTED" = "$ACTUAL" ] || die "candidate2_super_hash_locale_errato"

ADB=(adb -H "$ADB_HOST" -P "$ADB_PORT" -s "$TARGET")
STATE="$(adb -H "$ADB_HOST" -P "$ADB_PORT" devices 2>/dev/null | awk -v s="$TARGET" '$1==s{print $2; exit}')"
case "$STATE" in recovery|device|rescue) ;; *) die "adb_state_${STATE:-vuoto}";; esac

PRODUCT="$("${ADB[@]}" shell getprop ro.product.device 2>/dev/null | tr -d '\r' | tail -1)"
[ "$PRODUCT" = "dace" ] || die "device_${PRODUCT:-vuoto}"
REMOTE_UID="$("${ADB[@]}" shell id -u 2>/dev/null | tr -d '\r' | tail -1)"
[ "$REMOTE_UID" = "0" ] || die "adb_non_root_uid_${REMOTE_UID:-vuoto}"

SUPER_DEV="$("${ADB[@]}" shell 'readlink -f /dev/block/by-name/super 2>/dev/null' | tr -d '\r' | tail -1)"
RECOVERY_DEV="$("${ADB[@]}" shell 'readlink -f /dev/block/by-name/recovery 2>/dev/null' | tr -d '\r' | tail -1)"
[ -n "$SUPER_DEV" ] || die "super_device_non_trovato"
[ -n "$RECOVERY_DEV" ] || die "recovery_device_non_trovato"

SUPER_SIZE="$("${ADB[@]}" shell "blockdev --getsize64 '$SUPER_DEV'" 2>/dev/null | tr -d '\r' | grep -E '^[0-9]+$' | tail -1)"
[ "$SUPER_SIZE" = "4294967296" ] || die "target_super_size_$SUPER_SIZE"

echo "PREFLIGHT=PASS"
echo "CANDIDATE=2_SYSTEM_ONLY"
echo "ADB_STATE=$STATE"
echo "PRODUCT=$PRODUCT"
echo "SUPER_DEV=$SUPER_DEV"
echo "SUPER_SIZE=$SUPER_SIZE"
echo "EXPECTED_SHA256=$EXPECTED"
echo "RECOVERY_DEV=$RECOVERY_DEV"
echo "RECOVERY_TOUCHED=NO"
echo "FLASHING=super_candidate2"

"${ADB[@]}" exec-in "dd of='$SUPER_DEV' bs=4194304 conv=fsync 2>/dev/null" < "$SUPER"   || die "flash_super_candidate2_fallito"

"${ADB[@]}" shell sync >/dev/null 2>&1 || die "sync_fallito"

echo "VERIFYING=super_candidate2_full_sha256"
REMOTE="$("${ADB[@]}" shell "sha256sum '$SUPER_DEV' 2>/dev/null" | tr -d '\r' | awk '{print $1}' | tail -1)"
[ "$REMOTE" = "$EXPECTED" ] || die "remote_super_hash_$REMOTE"

echo "FLASH=PASS"
echo "REMOTE_SHA256=$REMOTE"
echo "BOOT_UNCHANGED=YES"
echo "INIT_BOOT_UNCHANGED=YES"
echo "VBMETA_UNCHANGED=YES"
echo "VBMETA_SYSTEM_UNCHANGED=YES"
echo "RECOVERY_TOUCHED=NO"
echo "NEXT=manual_reboot_test"
