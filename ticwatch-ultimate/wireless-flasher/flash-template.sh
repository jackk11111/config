#!/system/bin/sh
# TicWatch Pro 5 / Ultimate - KernelSU Next 3.3.0 paired kernel flasher
# Default: DRY RUN. Explicit --flash required to write boot. --restore restores the preserved original boot.
set -eu

SELF_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
BB="$SELF_DIR/busybox"
MB="$SELF_DIR/magiskboot"
IMG="$SELF_DIR/Image"
EXPECTED_IMAGE_SHA="__IMAGE_SHA256__"
EXPECTED_BUSYBOX_SHA="c629fce4b0dd3ba9775f851d0941e74582115f423258d3a79800f2bd11d30f5c"
EXPECTED_MAGISKBOOT_SHA="3936f1fd3a270f0f186b8327ef62145de91106c354eee7083518057ba6992d4b"
EXPECTED_RELEASE_PREFIX="5.15.202-Xinran_StarBai-Test"
WORK=/data/local/tmp/tw-ksun330-flash-work
MODE="${1:---check}"

fail() { echo "[FAIL] $*" >&2; exit 1; }
info() { echo "[INFO] $*"; }
pass() { echo "[PASS] $*"; }

case "$MODE" in
  check|--check) MODE="--check" ;;
  --flash|--restore) ;;
  *) fail "Modo sconosciuto: $MODE (usare --check, --flash o --restore)" ;;
esac

[ "$(id -u)" = "0" ] || fail "Eseguire come root (su -c)."
[ -x "$BB" ] || fail "busybox mancante/non eseguibile: $BB"
[ -x "$MB" ] || fail "magiskboot mancante/non eseguibile: $MB"

BB_SHA="$($BB sha256sum "$BB" | $BB awk '{print $1}')"
MB_SHA="$($BB sha256sum "$MB" | $BB awk '{print $1}')"
[ "$BB_SHA" = "$EXPECTED_BUSYBOX_SHA" ] || fail "busybox SHA256 inatteso: $BB_SHA"
[ "$MB_SHA" = "$EXPECTED_MAGISKBOOT_SHA" ] || fail "magiskboot SHA256 inatteso: $MB_SHA"
pass "Tool flasher verificati."

MODEL="$(getprop ro.product.model 2>/dev/null || true)"
DEVICE="$(getprop ro.product.device 2>/dev/null || true)"
PRODUCT="$(getprop ro.product.name 2>/dev/null || true)"
RELEASE="$(uname -r 2>/dev/null || true)"
info "Modello: ${MODEL:-?}  device: ${DEVICE:-?}  product: ${PRODUCT:-?}"
info "Kernel corrente: ${RELEASE:-?}"
if [ "$MODE" != "--restore" ]; then
  case "$RELEASE" in
    ${EXPECTED_RELEASE_PREFIX}*) pass "Baseline kernel attesa riconosciuta." ;;
    *) fail "Kernel baseline inatteso: '$RELEASE'. Nessuna scrittura eseguita." ;;
  esac
fi

SLOT="$(getprop ro.boot.slot_suffix 2>/dev/null || true)"
if [ -z "$SLOT" ]; then
  S="$(getprop ro.boot.slot 2>/dev/null || true)"
  case "$S" in a|b) SLOT="_$S";; esac
fi
case "$SLOT" in _a|_b) ;; *) fail "Slot attivo non determinabile in sicurezza: '$SLOT'";; esac
info "Slot attivo: $SLOT"

BOOT=""
for p in "/dev/block/by-name/boot$SLOT" "/dev/block/bootdevice/by-name/boot$SLOT"; do
  if [ -e "$p" ]; then BOOT="$p"; break; fi
done
if [ -z "$BOOT" ]; then
  for p in /dev/block/platform/*/by-name/boot"$SLOT"; do
    if [ -e "$p" ]; then BOOT="$p"; break; fi
  done
fi
[ -n "$BOOT" ] || fail "Partizione boot$SLOT non trovata. Nessuna scrittura eseguita."
BOOT_REAL="$($BB readlink -f "$BOOT" 2>/dev/null || echo "$BOOT")"
[ -b "$BOOT_REAL" ] || fail "Il target non è un block device: $BOOT_REAL"
pass "Target: $BOOT -> $BOOT_REAL"

BLOCK_SIZE="$($BB blockdev --getsize64 "$BOOT_REAL" 2>/dev/null || blockdev --getsize64 "$BOOT_REAL" 2>/dev/null || true)"
[ -n "$BLOCK_SIZE" ] || fail "Impossibile leggere la dimensione della partizione boot."
case "$BLOCK_SIZE" in *[!0-9]*|'') fail "Dimensione boot non valida: '$BLOCK_SIZE'";; esac
[ "$BLOCK_SIZE" -gt 0 ] || fail "Dimensione boot nulla."
info "Dimensione boot: $BLOCK_SIZE byte"

DOWNLOAD=/sdcard/Download
[ -d "$DOWNLOAD" ] || mkdir -p "$DOWNLOAD"
SAFE_BACKUP="$DOWNLOAD/TicWatch_boot${SLOT}_ORIGINAL_before_KSUN330.img"
SAFE_BACKUP_SHA_FILE="$SAFE_BACKUP.sha256"

rm -rf "$WORK"
mkdir -p "$WORK/split" "$WORK/verify"

backup_full_partition() {
  src="$1"; dst="$2"
  "$BB" dd if="$src" of="$dst" bs=1048576 2>&1
  [ -s "$dst" ] || fail "Backup boot non creato: $dst"
  size="$($BB stat -c %s "$dst")"
  [ "$size" = "$BLOCK_SIZE" ] || fail "Backup incompleto: $size / $BLOCK_SIZE byte"
}

verify_full_image() {
  f="$1"
  [ -s "$f" ] || fail "File assente/vuoto: $f"
  size="$($BB stat -c %s "$f")"
  [ "$size" = "$BLOCK_SIZE" ] || fail "Dimensione backup non valida: $size / $BLOCK_SIZE"
  "$BB" sha256sum "$f" | "$BB" awk '{print $1}'
}

if [ "$MODE" = "--restore" ]; then
  [ -f "$SAFE_BACKUP" ] || fail "Backup originale non trovato: $SAFE_BACKUP"
  SAFE_SHA="$(verify_full_image "$SAFE_BACKUP")"
  if [ -f "$SAFE_BACKUP_SHA_FILE" ]; then
    RECORDED_SHA="$($BB awk '{print $1}' "$SAFE_BACKUP_SHA_FILE" | $BB head -n1)"
    [ "$RECORDED_SHA" = "$SAFE_SHA" ] || fail "SHA del backup originale non coincide con il valore registrato."
  fi
  info "Ripristino boot originale $SLOT da $SAFE_BACKUP"
  "$BB" dd if="$SAFE_BACKUP" of="$BOOT_REAL" bs=1048576 conv=fsync 2>&1 || fail "Scrittura restore fallita"
  sync
  RESTORE_READBACK="$WORK/restore-readback.img"
  "$BB" dd if="$BOOT_REAL" of="$RESTORE_READBACK" bs=1048576 2>&1 || fail "Read-back restore fallito"
  RESTORE_SHA="$($BB sha256sum "$RESTORE_READBACK" | $BB awk '{print $1}')"
  [ "$RESTORE_SHA" = "$SAFE_SHA" ] || fail "Restore scritto ma read-back SHA non coincide: $RESTORE_SHA != $SAFE_SHA"
  pass "RESTORE verificato byte-per-byte: $RESTORE_SHA"
  echo "RESTORED_BOOT=$BOOT_REAL"
  echo "RESTORED_SHA=$RESTORE_SHA"
  echo "Riavvio NON automatico."
  exit 0
fi

[ -f "$IMG" ] || fail "Image mancante: $IMG"
ACTUAL_IMAGE_SHA="$($BB sha256sum "$IMG" | $BB awk '{print $1}')"
[ "$ACTUAL_IMAGE_SHA" = "$EXPECTED_IMAGE_SHA" ] || fail "SHA256 Image errato: $ACTUAL_IMAGE_SHA"
pass "Image SHA256 verificato: $ACTUAL_IMAGE_SHA"

if [ ! -e "$SAFE_BACKUP" ]; then
  info "Creo backup originale permanente -> $SAFE_BACKUP"
  backup_full_partition "$BOOT_REAL" "$SAFE_BACKUP"
  SAFE_SHA="$($BB sha256sum "$SAFE_BACKUP" | $BB awk '{print $1}')"
  printf '%s  %s\n' "$SAFE_SHA" "$(basename "$SAFE_BACKUP")" > "$SAFE_BACKUP_SHA_FILE"
  sync
  pass "Backup originale permanente creato: $SAFE_SHA"
else
  info "Backup originale permanente già presente; NON verrà sovrascritto."
  SAFE_SHA="$(verify_full_image "$SAFE_BACKUP")"
  if [ -f "$SAFE_BACKUP_SHA_FILE" ]; then
    RECORDED_SHA="$($BB awk '{print $1}' "$SAFE_BACKUP_SHA_FILE" | $BB head -n1)"
    [ "$RECORDED_SHA" = "$SAFE_SHA" ] || fail "Backup originale esistente con SHA diverso dal valore registrato."
  else
    printf '%s  %s\n' "$SAFE_SHA" "$(basename "$SAFE_BACKUP")" > "$SAFE_BACKUP_SHA_FILE"
  fi
  pass "Backup originale permanente verificato: $SAFE_SHA"
fi

STAMP="$(date +%Y%m%d-%H%M%S 2>/dev/null || echo now)"
CURRENT_BACKUP="$DOWNLOAD/TicWatch_boot${SLOT}_current_before_KSUN330_${STAMP}.img"
info "Backup dello stato boot corrente -> $CURRENT_BACKUP"
backup_full_partition "$BOOT_REAL" "$CURRENT_BACKUP"
CURRENT_SHA="$($BB sha256sum "$CURRENT_BACKUP" | $BB awk '{print $1}')"
pass "Backup boot corrente SHA256: $CURRENT_SHA"
cp -f "$CURRENT_BACKUP" "$WORK/boot.img"

info "Unpack boot corrente..."
cd "$WORK/split"
"$MB" unpack "$WORK/boot.img" >"$WORK/unpack.log" 2>&1 || { cat "$WORK/unpack.log"; fail "magiskboot unpack fallito"; }
[ -f kernel ] || fail "Kernel non estratto dal boot corrente."
OLD_KERNEL_SHA="$($BB sha256sum kernel | $BB awk '{print $1}')"
info "Kernel corrente SHA256: $OLD_KERNEL_SHA"
cp -f "$IMG" kernel

info "Repack preservando header/ramdisk del boot corrente..."
PATCHVBMETAFLAG=false "$MB" repack "$WORK/boot.img" "$WORK/boot-new.img" >"$WORK/repack.log" 2>&1 || { cat "$WORK/repack.log"; fail "magiskboot repack fallito"; }
[ -s "$WORK/boot-new.img" ] || fail "boot-new.img non creato."
NEW_SIZE="$($BB stat -c %s "$WORK/boot-new.img")"
[ "$NEW_SIZE" -le "$BLOCK_SIZE" ] || fail "Nuovo boot troppo grande: $NEW_SIZE > $BLOCK_SIZE"
NEW_SHA="$($BB sha256sum "$WORK/boot-new.img" | $BB awk '{print $1}')"
pass "Nuovo boot costruito: $NEW_SIZE byte, SHA256 $NEW_SHA"

info "Verifica del kernel dentro il boot ricostruito..."
cd "$WORK/verify"
"$MB" unpack "$WORK/boot-new.img" >"$WORK/verify.log" 2>&1 || { cat "$WORK/verify.log"; fail "Verifica unpack nuovo boot fallita"; }
[ -f kernel ] || fail "Kernel non trovato nel nuovo boot."
VERIFY_KERNEL_SHA="$($BB sha256sum kernel | $BB awk '{print $1}')"
[ "$VERIFY_KERNEL_SHA" = "$EXPECTED_IMAGE_SHA" ] || fail "Kernel nel boot nuovo non coincide con Image: $VERIFY_KERNEL_SHA"
pass "Kernel nel nuovo boot verificato byte-per-byte."

echo "TARGET_SLOT=$SLOT"
echo "TARGET_BOOT=$BOOT_REAL"
echo "SAFE_BACKUP=$SAFE_BACKUP"
echo "SAFE_BACKUP_SHA=$SAFE_SHA"
echo "CURRENT_BACKUP=$CURRENT_BACKUP"
echo "CURRENT_BACKUP_SHA=$CURRENT_SHA"
echo "NEW_BOOT=$WORK/boot-new.img"
echo "NEW_BOOT_SIZE=$NEW_SIZE"
echo "NEW_BOOT_SHA=$NEW_SHA"

if [ "$MODE" != "--flash" ]; then
  echo
  echo "[DRY RUN OK] Nessuna scrittura effettuata sulla partizione boot."
  echo "COPIA PRIMA SAFE_BACKUP FUORI DALL'OROLOGIO, poi usare --flash."
  exit 0
fi

info "FLASH richiesto: scrittura SOLO su boot$SLOT ($BOOT_REAL)"
"$BB" dd if="$WORK/boot-new.img" of="$BOOT_REAL" bs=1048576 conv=fsync 2>&1 || fail "Scrittura boot fallita"
sync

READBACK="$WORK/readback.img"
COUNT="$(( (NEW_SIZE + 1048575) / 1048576 ))"
"$BB" dd if="$BOOT_REAL" bs=1048576 count="$COUNT" 2>/dev/null | "$BB" head -c "$NEW_SIZE" > "$READBACK" || fail "Read-back boot fallito"
READBACK_SHA="$($BB sha256sum "$READBACK" | $BB awk '{print $1}')"
if [ "$READBACK_SHA" != "$NEW_SHA" ]; then
  echo "[FAIL] Read-back SHA mismatch: $READBACK_SHA != $NEW_SHA" >&2
  echo "[INFO] Ripristino immediato dal backup corrente..." >&2
  "$BB" dd if="$CURRENT_BACKUP" of="$BOOT_REAL" bs=1048576 conv=fsync 2>&1 || fail "FLASH fallito E restore automatico non riuscito: NON RIAVVIARE"
  sync
  RESTORE_READBACK="$WORK/restore-after-failure.img"
  "$BB" dd if="$BOOT_REAL" of="$RESTORE_READBACK" bs=1048576 2>&1 || fail "Restore eseguito ma read-back restore fallito: NON RIAVVIARE"
  RESTORE_SHA="$($BB sha256sum "$RESTORE_READBACK" | $BB awk '{print $1}')"
  [ "$RESTORE_SHA" = "$CURRENT_SHA" ] || fail "Restore post-errore NON verificato: $RESTORE_SHA != $CURRENT_SHA. NON RIAVVIARE"
  fail "Verifica post-flash fallita; boot corrente ripristinato e verificato. Nessun reboot automatico."
fi
pass "Read-back post-flash identico al boot costruito: $READBACK_SHA"
echo "FLASH_READBACK_SHA=$READBACK_SHA"
echo
pass "FLASH COMPLETATO E VERIFICATO."
echo "Backup originale permanente: $SAFE_BACKUP"
echo "Backup corrente pre-flash:   $CURRENT_BACKUP"
echo "Riavvio NON automatico."
