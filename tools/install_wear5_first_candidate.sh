#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail

BUILD="/storage/emulated/0/Download/WEAR5_FIRST_BUILD"
IMG="$BUILD/images"
ADB_HOST="10.82.56.57"
ADB_PORT="5037"
MODE="${1:-preflight}"
TARGET="${2:-}"

die(){ echo; echo "BLOCKER=$*"; exit 2; }

command -v adb >/dev/null 2>&1 || die "adb_non_disponibile"
ADB=(adb -H "$ADB_HOST" -P "$ADB_PORT")

for F in super.img boot.img vbmeta.img vbmeta_system.img; do
  [ -f "$IMG/$F" ] || die "file_mancante_$F"
done

EXPECTED_SUPER="7fe0e1ecc6bca9d22c15f3ae21a91034a3b21589c27a4dddc6a67d40aa6c9079"
ACTUAL_SUPER="$(sha256sum "$IMG/super.img" | awk '{print $1}')"
[ "$ACTUAL_SUPER" = "$EXPECTED_SUPER" ] || die "sha256_super_locale_errato"
[ "$(stat -c %s "$IMG/super.img")" = "4294967296" ] || die "super_locale_non_4GiB"

# Modalita cavo: usa direttamente il server ADB del PC.
# In recovery adb devices puo mostrare "recovery" invece di "device".
if [ -z "$TARGET" ]; then
  TARGET="$("${ADB[@]}" devices 2>/dev/null | awk 'NR>1 && $1!="" && $2!="offline" && $2!="unauthorized"{print $1; exit}')"
fi
[ -n "$TARGET" ] || die "nessun_transport_adb_utilizzabile_sul_server_PC"

ADB+=(-s "$TARGET")

LIST_STATE="$(adb -H "$ADB_HOST" -P "$ADB_PORT" devices 2>/dev/null | awk -v s="$TARGET" '$1==s{print $2; exit}')"
case "$LIST_STATE" in
  device|recovery|rescue|sideload) ;;
  *) die "transport_${TARGET}_stato_${LIST_STATE:-vuoto}" ;;
esac

"${ADB[@]}" shell 'echo WEAR5_ADB_OK' 2>/dev/null | tr -d "\r" | grep -qx 'WEAR5_ADB_OK' || die "adb_shell_non_operativa_su_${TARGET}"

PRODUCT="$("${ADB[@]}" shell getprop ro.product.device 2>/dev/null | tr -d "\r" | tail -1 || true)"
[ "$PRODUCT" = "dace" ] || die "device_inatteso_${PRODUCT:-vuoto}"

SHELL_UID="$("${ADB[@]}" shell id -u 2>/dev/null | tr -d "\r" | tail -1 || true)"
ROOT_UID="$SHELL_UID"
USE_SU=0
if [ "$SHELL_UID" != "0" ]; then
  ROOT_UID="$("${ADB[@]}" shell "su -c 'id -u'" 2>/dev/null | tr -d "\r" | tail -1 || true)"
  [ "$ROOT_UID" = "0" ] || die "root_non_disponibile_shell_uid_${SHELL_UID:-vuoto}"
  USE_SU=1
fi

rsh(){
  local cmd="$1"
  if [ "$USE_SU" = "1" ]; then
    "${ADB[@]}" shell "su -c \"$cmd\""
  else
    "${ADB[@]}" shell "$cmd"
  fi
}

SUPER_DEV="$(rsh "readlink -f /dev/block/by-name/super 2>/dev/null" | tr -d "\r" | tail -1)"
BOOT_DEV="$(rsh "readlink -f /dev/block/by-name/boot 2>/dev/null" | tr -d "\r" | tail -1)"
VBMETA_DEV="$(rsh "readlink -f /dev/block/by-name/vbmeta 2>/dev/null" | tr -d "\r" | tail -1)"
VBMETA_SYS_DEV="$(rsh "readlink -f /dev/block/by-name/vbmeta_system 2>/dev/null" | tr -d "\r" | tail -1)"

[ -n "$SUPER_DEV" ] || die "super_device_non_trovato"
[ -n "$BOOT_DEV" ] || die "boot_device_non_trovato"
[ -n "$VBMETA_DEV" ] || die "vbmeta_device_non_trovato"
[ -n "$VBMETA_SYS_DEV" ] || die "vbmeta_system_device_non_trovato"

REMOTE_SUPER_SIZE="$(rsh "blockdev --getsize64 $SUPER_DEV" 2>/dev/null | tr -d "\r" | grep -E '^[0-9]+$' | tail -1 || true)"
[ "$REMOTE_SUPER_SIZE" = "4294967296" ] || die "super_target_size_${REMOTE_SUPER_SIZE:-vuoto}"

echo "PREFLIGHT=PASS"
echo "TRANSPORT=CABLE_ADB_SERVER"
echo "SERIAL=$TARGET"
echo "ADB_LIST_STATE=$LIST_STATE"
echo "PRODUCT=$PRODUCT"
echo "SHELL_UID=$SHELL_UID"
echo "ROOT_UID=$ROOT_UID"
echo "SUPER_DEV=$SUPER_DEV"
echo "SUPER_SIZE=$REMOTE_SUPER_SIZE"
echo "BOOT_DEV=$BOOT_DEV"
echo "VBMETA_DEV=$VBMETA_DEV"
echo "VBMETA_SYSTEM_DEV=$VBMETA_SYS_DEV"
echo "RECOVERY_TOUCHED=NO"

[ "$MODE" = "preflight" ] && exit 0
[ "$MODE" = "flash" ] || die "modo_valido_preflight_o_flash"

# Guardie immediatamente prima di qualsiasi scrittura.
RECOVERY_DEV="$(rsh "readlink -f /dev/block/by-name/recovery 2>/dev/null" | tr -d "\r" | tail -1 || true)"
[ -n "$RECOVERY_DEV" ] || die "recovery_partition_non_trovata_non_flasho"
[ "$RECOVERY_DEV" != "$BOOT_DEV" ] || die "recovery_e_boot_coincidono_non_flasho"

# Blocca soltanto i filesystem logici realmente contenuti in super.
# Submount indipendenti come /vendor/firmware_mnt (modem/firmware partition)
# non rendono "vendor" montata e non devono fermare il flash di super.
BUSY_MOUNTS="$(rsh "cat /proc/mounts" 2>/dev/null | awk '
  ($2==\"/system\" || $2==\"/system_root\" || $2==\"/vendor\" ||
   $2==\"/product\" || $2==\"/system_ext\" ||
   $2==\"/system_dlkm\" || $2==\"/vendor_dlkm\") {print $2}
  $1 ~ /\/dev\/block\/(mapper\/)?(system|vendor|product|system_ext|system_dlkm|vendor_dlkm)(_[ab])?$/ {print $2}
' | sort -u | tr '\n' ',' || true)"
[ -z "$BUSY_MOUNTS" ] || die "partizioni_logiche_super_montate_${BUSY_MOUNTS}"

echo "FLASH_GUARD=PASS"
echo "RECOVERY_DEV=$RECOVERY_DEV"

write_image(){
  local src="$1" dev="$2" label="$3"
  echo "FLASHING=$label"
  if [ "$USE_SU" = "1" ]; then
    "${ADB[@]}" exec-in "su -c 'dd of=$dev bs=4194304 conv=fsync 2>/dev/null'" < "$src" || die "flash_${label}_fallito"
  else
    "${ADB[@]}" exec-in "dd of=$dev bs=4194304 conv=fsync 2>/dev/null" < "$src" || die "flash_${label}_fallito"
  fi
}

write_image "$IMG/super.img" "$SUPER_DEV" "super"
write_image "$IMG/vbmeta_system.img" "$VBMETA_SYS_DEV" "vbmeta_system"
write_image "$IMG/vbmeta.img" "$VBMETA_DEV" "vbmeta"
write_image "$IMG/boot.img" "$BOOT_DEV" "boot"

rsh "sync" >/dev/null || die "sync_fallito"
REMOTE_HASH="$(rsh "sha256sum $SUPER_DEV 2>/dev/null" | tr -d "\r" | awk '{print $1}' | tail -1)"
[ "$REMOTE_HASH" = "$EXPECTED_SUPER" ] || die "verifica_super_postflash_fallita_${REMOTE_HASH:-vuoto}"

echo "FLASH=PASS"
echo "SUPER_SHA256=$REMOTE_HASH"
echo "RECOVERY_TOUCHED=NO"
echo "NEXT=manual_reboot_when_ready"
