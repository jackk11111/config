#!/data/data/com.termux/files/usr/bin/bash
# Phone-side helper: Termux -> wireless ADB -> TicWatch. Default: dry-run only.
set -euo pipefail

BASE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
FL_DIR="$BASE_DIR/wireless-flasher"
MANAGER="$BASE_DIR/KernelSU_Next_v3.3.0-spoofed-TicWatch-armeabi-v7a-release.apk"
REMOTE_DIR=/data/local/tmp/tw-ksun330-flasher
BACKUP_DIR="$BASE_DIR/backups"
MODE="${1:---check}"
ADB_BIN="${ADB_BIN:-adb}"

fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }
info() { printf '[INFO] %s\n' "$*"; }
pass() { printf '[PASS] %s\n' "$*"; }

case "$MODE" in
  check|--check) MODE="--check" ;;
  --flash|--restore|--install-manager) ;;
  *) fail "Uso: bash TERMUX-ADB.sh [--check|--flash|--restore|--install-manager]" ;;
esac

command -v "$ADB_BIN" >/dev/null 2>&1 || fail "adb non trovato. In Termux: pkg install android-tools"
[ -d "$FL_DIR" ] || fail "Cartella wireless-flasher mancante: $FL_DIR"
[ -f "$MANAGER" ] || fail "Manager APK mancante: $MANAGER"
[ -f "$FL_DIR/SHA256SUMS" ] || fail "Manifest hash flasher mancante."

info "Verifica integrità locale flasher..."
( cd "$FL_DIR" && sha256sum -c SHA256SUMS ) || fail "Hash locali del flasher non validi."
pass "Hash locali validi."

if [ -n "${ADB_SERIAL:-}" ]; then
  SERIAL="$ADB_SERIAL"
else
  mapfile -t DEVICES < <("$ADB_BIN" devices | awk 'NR>1 && $2=="device" {print $1}')
  [ "${#DEVICES[@]}" -gt 0 ] || fail "Nessun dispositivo ADB collegato. Eseguire prima adb pair / adb connect."
  [ "${#DEVICES[@]}" -eq 1 ] || fail "Più dispositivi ADB trovati. Impostare: export ADB_SERIAL=IP:PORT"
  SERIAL="${DEVICES[0]}"
fi
ADB=("$ADB_BIN" -s "$SERIAL")
info "Target ADB: $SERIAL"
"${ADB[@]}" get-state | grep -qx device || fail "Target ADB non pronto."

UID0="$("${ADB[@]}" shell "su -c 'id -u'" 2>/dev/null | tr -d '\r' | tail -n1 || true)"
[ "$UID0" = "0" ] || fail "Root non disponibile via su sul TicWatch. Non posso flashare in sicurezza da Android."
pass "Root sul TicWatch disponibile."

push_flasher() {
  info "Trasferisco il flasher verificato sul TicWatch..."
  "${ADB[@]}" shell "rm -rf '$REMOTE_DIR' && mkdir -p '$REMOTE_DIR'"
  "${ADB[@]}" push "$FL_DIR/." "$REMOTE_DIR/" >/dev/null
  "${ADB[@]}" shell "su -c 'chmod 0755 $REMOTE_DIR/flash.sh $REMOTE_DIR/busybox $REMOTE_DIR/magiskboot'"
  pass "Flasher trasferito."
}

pull_safe_backup() {
  mkdir -p "$BACKUP_DIR"
  info "Copio sul telefono il backup originale della boot..."
  mapfile -t REMOTES < <("${ADB[@]}" shell "ls -1 /sdcard/Download/TicWatch_boot*_ORIGINAL_before_KSUN330.img /sdcard/Download/TicWatch_boot*_ORIGINAL_before_KSUN330.img.sha256 2>/dev/null" | tr -d '\r' || true)
  [ "${#REMOTES[@]}" -gt 0 ] || fail "Backup originale non trovato sul TicWatch dopo il dry-run."
  for r in "${REMOTES[@]}"; do
    [ -n "$r" ] || continue
    "${ADB[@]}" pull "$r" "$BACKUP_DIR/" >/dev/null
  done
  shopt -s nullglob
  local sfs=("$BACKUP_DIR"/*.img.sha256)
  [ "${#sfs[@]}" -gt 0 ] || fail "File SHA256 del backup non copiato sul telefono."
  for sf in "${sfs[@]}"; do
    (cd "$BACKUP_DIR" && sha256sum -c "$(basename "$sf")") || fail "Verifica backup sul telefono fallita."
  done
  shopt -u nullglob
  pass "Backup originale presente e verificato sul telefono: $BACKUP_DIR"
}

run_watch() {
  local m="$1"
  "${ADB[@]}" shell "su -c '$REMOTE_DIR/flash.sh $m'"
}

if [ "$MODE" = "--install-manager" ]; then
  info "Installo il Manager KSU Next 3.3.0 spoofed ARMv7 paired..."
  "${ADB[@]}" install -r "$MANAGER"
  pass "Manager installato. Nessun kernel modificato."
  exit 0
fi

push_flasher

if [ "$MODE" = "--restore" ]; then
  run_watch --restore
  pass "Restore completato e verificato. Riavvio NON automatico."
  exit 0
fi

info "Eseguo il dry-run completo sul TicWatch..."
run_watch --check
pull_safe_backup

if [ "$MODE" = "--check" ]; then
  echo
  pass "DRY-RUN COMPLETATO. Nessuna scrittura della boot è stata eseguita."
  echo "Per procedere: bash TERMUX-ADB.sh --flash"
  exit 0
fi

info "Installo prima il Manager paired, così sarà già presente al primo boot del nuovo kernel..."
"${ADB[@]}" install -r "$MANAGER"
pass "Manager paired installato."

info "Avvio il flash della SOLA boot attiva. Il flasher farà read-back e verifica SHA."
run_watch --flash

echo
pass "FLASH COMPLETATO E VERIFICATO; backup esterno già salvato sul telefono."
echo "Il riavvio NON è automatico. Quando vuoi testare il nuovo kernel:"
echo "  $ADB_BIN -s '$SERIAL' reboot"
