#!/data/data/com.termux/files/usr/bin/bash
set -u

OUT="/storage/emulated/0/Download/WEAR5_INPUT_AUDIT.txt"
STOCK="/storage/emulated/0/Download/Telegram/Watch/ota/2269bd24a774cae37adc720d3d97bd1b76846e2b.zip"

command -v unzip >/dev/null 2>&1 || {
  echo "ERRORE: manca unzip in Termux. Esegui: pkg install unzip -y"
  exit 1
}

: > "$OUT"
{
  echo "=== WEAR5 INPUT AUDIT ==="
  date
  echo

  echo "=== TICWATCH STOCK ==="
  if [ -f "$STOCK" ]; then
    echo "PATH=$STOCK"
    ls -l "$STOCK"
    echo "-- META --"
    unzip -p "$STOCK" META-INF/com/android/metadata 2>/dev/null || true
    echo
    echo "-- PAYLOAD PROPERTIES --"
    unzip -p "$STOCK" payload_properties.txt 2>/dev/null || true
    echo
    echo "-- RELEVANT ENTRIES --"
    unzip -l "$STOCK" 2>/dev/null | grep -Ei 'payload\.bin|\.img$|\.new\.dat|\.transfer\.list|vbmeta|vendor|odm|system|product|system_ext|init_boot|vendor_boot|dtbo' | head -n 160 || true
  else
    echo "MISSING_STOCK=$STOCK"
  fi

  echo
  echo "=== SEARCH XIAOMI WATCH 2 PRO OTA ==="
} >> "$OUT"

XIAOMI=""
while IFS= read -r z; do
  [ "$z" = "$STOCK" ] && continue
  META="$(unzip -p "$z" META-INF/com/android/metadata 2>/dev/null | head -c 20000 || true)"
  NAME="$(basename "$z")"
  if printf '%s\n%s\n' "$NAME" "$META" | grep -Eqi 'axolotl|axolotlte|M2234W1|M2233W1|Xiaomi Watch 2 Pro'; then
    XIAOMI="$z"
    break
  fi
done < <(find /storage/emulated/0/Download /storage/emulated/0/Telegram -type f -iname '*.zip' -size +500M 2>/dev/null | sort -u)

{
  if [ -n "$XIAOMI" ]; then
    echo "XIAOMI_PATH=$XIAOMI"
    ls -l "$XIAOMI"
    echo
    echo "-- META --"
    unzip -p "$XIAOMI" META-INF/com/android/metadata 2>/dev/null || true
    echo
    echo "-- PAYLOAD PROPERTIES --"
    unzip -p "$XIAOMI" payload_properties.txt 2>/dev/null || true
    echo
    echo "-- RELEVANT ENTRIES --"
    unzip -l "$XIAOMI" 2>/dev/null | grep -Ei 'payload\.bin|\.img$|\.new\.dat|\.transfer\.list|vbmeta|vendor|odm|system|product|system_ext|init_boot|vendor_boot|dtbo' | head -n 200 || true
  else
    echo "XIAOMI_NOT_AUTOIDENTIFIED"
    echo "-- LARGE ZIP CANDIDATES --"
    find /storage/emulated/0/Download /storage/emulated/0/Telegram -type f -iname '*.zip' -size +500M 2>/dev/null -print | sort -u
  fi

  echo
  echo "=== LOCAL KNOWN-GOOD ARTIFACTS ==="
  find /storage/emulated/0/Download /storage/emulated/0/Telegram -type f \( \
    -iname 'boot_CURRENT_WORKING_5.15.220.img' -o \
    -iname 'TicWatch-RECOVERY-FINAL-VAULT-V2-20260918.zip' -o \
    -iname 'OTA_WEAR4_379*.zip' \
  \) -print 2>/dev/null | sort -u

  echo
  echo "=== END ==="
} >> "$OUT"

cat "$OUT"
echo
echo "AUDIT_SAVED=$OUT"
