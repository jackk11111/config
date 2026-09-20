#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail

WORK="$HOME/WEAR5"
DONOR="$WORK/xiaomi/init_boot.img"
BUILD="/storage/emulated/0/Download/WEAR5_FIRST_BUILD"
BACKUP_DIR="$BUILD/backup"
BACKUP="$BACKUP_DIR/init_boot_before_A14_test.img"
ADB_HOST="10.82.56.57"
ADB_PORT="5037"
MODE="${1:-preflight}"
TARGET="${2:-C121X44260991}"

die(){ echo; echo "BLOCKER=$*"; exit 2; }

[ -f "$DONOR" ] || die "donor_init_boot_mancante"
[ "$(stat -c %s "$DONOR")" = "8388608" ] || die "donor_init_boot_size_inattesa"

ADB=(adb -H "$ADB_HOST" -P "$ADB_PORT" -s "$TARGET")

STATE="$(adb -H "$ADB_HOST" -P "$ADB_PORT" devices 2>/dev/null | awk -v s="$TARGET" '$1==s{print $2; exit}')"
case "$STATE" in
  device|recovery|rescue) ;;
  *) die "transport_${TARGET}_stato_${STATE:-vuoto}" ;;
esac

"${ADB[@]}" shell 'echo OK' 2>/dev/null | tr -d '\r' | grep -qx OK || die "adb_shell_non_operativa"

PRODUCT="$("${ADB[@]}" shell getprop ro.product.device 2>/dev/null | tr -d '\r' | tail -1)"
[ "$PRODUCT" = "dace" ] || die "device_inatteso_${PRODUCT:-vuoto}"

REMOTE_UID="$("${ADB[@]}" shell id -u 2>/dev/null | tr -d '\r' | tail -1)"
[ "$REMOTE_UID" = "0" ] || die "adb_non_root_uid_${REMOTE_UID:-vuoto}"

INIT_DEV="$("${ADB[@]}" shell 'readlink -f /dev/block/by-name/init_boot 2>/dev/null' | tr -d '\r' | tail -1)"
[ -n "$INIT_DEV" ] || die "init_boot_device_non_trovato"

REMOTE_SIZE="$("${ADB[@]}" shell "blockdev --getsize64 '$INIT_DEV'" 2>/dev/null | tr -d '\r' | grep -E '^[0-9]+$' | tail -1)"
[ "$REMOTE_SIZE" = "8388608" ] || die "init_boot_target_size_${REMOTE_SIZE:-vuoto}"

DONOR_SHA="$(sha256sum "$DONOR" | awk '{print $1}')"

echo "PREFLIGHT=PASS"
echo "MODE=$MODE"
echo "PRODUCT=$PRODUCT"
echo "ADB_STATE=$STATE"
echo "UID=$REMOTE_UID"
echo "INIT_BOOT_DEV=$INIT_DEV"
echo "INIT_BOOT_SIZE=$REMOTE_SIZE"
echo "DONOR_SHA256=$DONOR_SHA"

[ "$MODE" = "preflight" ] && exit 0

mkdir -p "$BACKUP_DIR"

if [ ! -f "$BACKUP" ]; then
  echo "BACKUP=current_init_boot"
  "${ADB[@]}" exec-out "dd if='$INIT_DEV' bs=1048576 2>/dev/null" > "$BACKUP" || die "backup_init_boot_fallito"
  [ "$(stat -c %s "$BACKUP")" = "$REMOTE_SIZE" ] || die "backup_init_boot_size_errata"
fi

BACKUP_SHA="$(sha256sum "$BACKUP" | awk '{print $1}')"
echo "BACKUP_SHA256=$BACKUP_SHA"

case "$MODE" in
  flash)
    STAGE="/cache/wear5_init_boot_a14.img"
    echo "STAGING=donor_Android14_init_boot"
    "${ADB[@]}" shell "rm -f '$STAGE'" >/dev/null 2>&1 || true
    "${ADB[@]}" push "$DONOR" "$STAGE" >/dev/null || die "push_donor_init_boot_fallito"
    STAGE_SIZE="$("${ADB[@]}" shell "stat -c %s '$STAGE' 2>/dev/null" | tr -d '\r' | tail -1)"
    [ "$STAGE_SIZE" = "8388608" ] || die "stage_donor_size_${STAGE_SIZE:-vuoto}"
    STAGE_SHA="$("${ADB[@]}" shell "sha256sum '$STAGE' 2>/dev/null" | tr -d '\r' | awk '{print $1}' | tail -1)"
    [ "$STAGE_SHA" = "$DONOR_SHA" ] || die "stage_donor_sha_fallita_${STAGE_SHA:-vuoto}"
    echo "STAGE_SHA256=$STAGE_SHA"
    echo "FLASHING=donor_Android14_init_boot_only"
    "${ADB[@]}" shell "dd if='$STAGE' of='$INIT_DEV' bs=1048576 conv=fsync 2>/dev/null && sync" >/dev/null || die "flash_init_boot_fallito"
    REMOTE_SHA="$("${ADB[@]}" shell "sha256sum '$INIT_DEV' 2>/dev/null" | tr -d '\r' | awk '{print $1}' | tail -1)"
    [ "$REMOTE_SHA" = "$DONOR_SHA" ] || die "verifica_init_boot_donor_fallita_${REMOTE_SHA:-vuoto}"
    "${ADB[@]}" shell "rm -f '$STAGE'" >/dev/null 2>&1 || true
    echo "INIT_BOOT_TEST=FLASH_PASS"
    echo "REMOTE_SHA256=$REMOTE_SHA"
    echo "NEXT=reboot_normal_test"
    ;;
  restore)
    STAGE="/cache/wear5_init_boot_restore.img"
    echo "STAGING=init_boot_backup"
    "${ADB[@]}" shell "rm -f '$STAGE'" >/dev/null 2>&1 || true
    "${ADB[@]}" push "$BACKUP" "$STAGE" >/dev/null || die "push_backup_init_boot_fallito"
    STAGE_SIZE="$("${ADB[@]}" shell "stat -c %s '$STAGE' 2>/dev/null" | tr -d '\r' | tail -1)"
    [ "$STAGE_SIZE" = "8388608" ] || die "stage_backup_size_${STAGE_SIZE:-vuoto}"
    STAGE_SHA="$("${ADB[@]}" shell "sha256sum '$STAGE' 2>/dev/null" | tr -d '\r' | awk '{print $1}' | tail -1)"
    [ "$STAGE_SHA" = "$BACKUP_SHA" ] || die "stage_backup_sha_fallita_${STAGE_SHA:-vuoto}"
    echo "RESTORING=init_boot_backup"
    "${ADB[@]}" shell "dd if='$STAGE' of='$INIT_DEV' bs=1048576 conv=fsync 2>/dev/null && sync" >/dev/null || die "restore_init_boot_fallito"
    REMOTE_SHA="$("${ADB[@]}" shell "sha256sum '$INIT_DEV' 2>/dev/null" | tr -d '\r' | awk '{print $1}' | tail -1)"
    [ "$REMOTE_SHA" = "$BACKUP_SHA" ] || die "verifica_restore_init_boot_fallita_${REMOTE_SHA:-vuoto}"
    "${ADB[@]}" shell "rm -f '$STAGE'" >/dev/null 2>&1 || true
    echo "INIT_BOOT_TEST=RESTORE_PASS"
    echo "REMOTE_SHA256=$REMOTE_SHA"
    ;;
  *)
    die "modo_valido_preflight_flash_restore"
    ;;
esac
