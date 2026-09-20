#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail
WORK="/storage/emulated/0/Download/WEAR5_PORT"
TOOLS="$WORK/tools"
REPORT="$WORK/report"
STOCK_OUT="$WORK/stock/images"
DONOR_OUT="$WORK/xiaomi_bt/images"
SUMMARY="$WORK/WEAR5_STAGE1_SUMMARY.txt"
REPORT_ZIP="$WORK/WEAR5_STAGE1_REPORT.zip"
mkdir -p "$TOOLS" "$REPORT" "$STOCK_OUT" "$DONOR_OUT"
rm -f "$SUMMARY" "$REPORT_ZIP"
say(){ printf '%s\n' "$*"; }
fail(){ printf '\nERRORE: %s\n' "$*" >&2; exit 1; }
say "[1/4] Preparo gli strumenti..."
pkg install -y curl unzip zip python file coreutils >/dev/null 2>&1 || fail "installazione pacchetti Termux"
RIP="$TOOLS/otaripper"
if [ ! -x "$RIP" ]; then
  API="https://api.github.com/repos/syedinsaf/otaripper/releases/latest"
  JSON="$TOOLS/otaripper_release.json"
  curl -fsSL "$API" -o "$JSON" || fail "download metadati otaripper"
  URL="$(python - "$JSON" <<'PY'
import json,sys
d=json.load(open(sys.argv[1],encoding="utf-8"))
xs=[]
for a in d.get("assets",[]):
    n=a.get("name","").lower()
    if "android-arm64" in n and n.endswith(".zip"):
        xs.append((0 if "lite" not in n else 1,a["browser_download_url"]))
if not xs: raise SystemExit(2)
print(sorted(xs)[0][1])
PY
)" || fail "release Android ARM64 di otaripper non trovata"
  curl -fL "$URL" -o "$TOOLS/otaripper_android_arm64.zip" >/dev/null 2>&1 || fail "download otaripper"
  rm -rf "$TOOLS/otaripper_unpack"; mkdir -p "$TOOLS/otaripper_unpack"
  unzip -oq "$TOOLS/otaripper_android_arm64.zip" -d "$TOOLS/otaripper_unpack" || fail "estrazione otaripper"
  SRC="$(find "$TOOLS/otaripper_unpack" -type f -name otaripper -print -quit)"
  [ -n "$SRC" ] || fail "binario otaripper non trovato"
  cp -f "$SRC" "$RIP"; chmod 755 "$RIP"
fi
"$RIP" --version > "$REPORT/otaripper_version.txt" 2>&1 || true
say "[2/4] Identifico OTA TicWatch e Xiaomi BT..."
mapfile -d '' ALL_ZIPS < <(find /storage/emulated/0/Download /storage/emulated/0/Telegram -type f -iname '*.zip' -size +500M -print0 2>/dev/null | sort -z -u)
[ "${#ALL_ZIPS[@]}" -gt 0 ] || fail "nessun OTA ZIP grande trovato"
STOCK=""; DONOR=""; PAYLOAD_ZIPS=()
for Z in "${ALL_ZIPS[@]}"; do
  unzip -l "$Z" 2>/dev/null | grep -q 'payload\.bin' || continue
  PAYLOAD_ZIPS+=("$Z")
  META="$(unzip -p "$Z" META-INF/com/android/metadata 2>/dev/null || true)"
  BASE="$(basename "$Z")"
  if printf '%s\n%s\n' "$BASE" "$META" | grep -Eqi '(^|[^a-z])dace([^a-z]|$)|TMDB\.240925\.002|ticwatch|2269bd24a774cae37adc720d3d97bd1b76846e2b'; then STOCK="$Z"; fi
  if printf '%s\n%s\n' "$BASE" "$META" | grep -Eqi '(^|[^a-z])axolotl([^a-z]|$)|M2234W1|Xiaomi Watch 2 Pro'; then
    if ! printf '%s\n%s\n' "$BASE" "$META" | grep -Eqi 'axolotlte|M2233W1'; then DONOR="$Z"; fi
  fi
done
if [ -z "$STOCK" ]; then
  for Z in "${PAYLOAD_ZIPS[@]}"; do
    case "$(basename "$Z")" in 2269bd24a774cae37adc720d3d97bd1b76846e2b.zip|OTA_WEAR4_379*.zip) STOCK="$Z"; break;; esac
  done
fi
if [ -z "$DONOR" ] && [ -n "$STOCK" ]; then
  OTHER=()
  for Z in "${PAYLOAD_ZIPS[@]}"; do [ "$Z" = "$STOCK" ] || OTHER+=("$Z"); done
  if [ "${#OTHER[@]}" -eq 1 ]; then DONOR="${OTHER[0]}"; fi
fi
[ -n "$STOCK" ] || fail "OTA TicWatch non identificato automaticamente"
[ -n "$DONOR" ] || fail "OTA Xiaomi Watch 2 Pro Bluetooth non identificato automaticamente"
[ "$STOCK" != "$DONOR" ] || fail "stock e donor risultano lo stesso file"
unzip -p "$STOCK" META-INF/com/android/metadata > "$REPORT/stock_metadata.txt" 2>/dev/null || true
unzip -p "$DONOR" META-INF/com/android/metadata > "$REPORT/xiaomi_metadata.txt" 2>/dev/null || true
unzip -p "$STOCK" payload_properties.txt > "$REPORT/stock_payload_properties.txt" 2>/dev/null || true
unzip -p "$DONOR" payload_properties.txt > "$REPORT/xiaomi_payload_properties.txt" 2>/dev/null || true
"$RIP" -l "$STOCK" -n > "$REPORT/stock_partitions.txt" 2>&1 || fail "lettura payload TicWatch"
"$RIP" -l "$DONOR" -n > "$REPORT/xiaomi_partitions.txt" 2>&1 || fail "lettura payload Xiaomi"
candidate_parts=(boot init_boot vendor_boot dtbo vbmeta vbmeta_system vbmeta_vendor system system_ext product vendor odm vendor_dlkm odm_dlkm system_dlkm)
select_parts(){ local LIST="$1"; local found=(); local p; for p in "${candidate_parts[@]}"; do if grep -Eq "(^|[^[:alnum:]_])${p}([^[:alnum:]_]|$)" "$LIST"; then found+=("$p"); fi; done; local IFS=,; printf '%s' "${found[*]}"; }
STOCK_PARTS="$(select_parts "$REPORT/stock_partitions.txt")"
DONOR_PARTS="$(select_parts "$REPORT/xiaomi_partitions.txt")"
[ -n "$STOCK_PARTS" ] || fail "nessuna partizione target utile trovata nel payload TicWatch"
[ -n "$DONOR_PARTS" ] || fail "nessuna partizione donor utile trovata nel payload Xiaomi"
say "[3/4] Estraggo le partizioni necessarie..."
rm -rf "$STOCK_OUT" "$DONOR_OUT"; mkdir -p "$STOCK_OUT" "$DONOR_OUT"
"$RIP" "$STOCK" -p "$STOCK_PARTS" -o "$STOCK_OUT" -n --sanity >"$REPORT/stock_extract.log" 2>&1 || { tail -n 20 "$REPORT/stock_extract.log" >&2; fail "estrazione OTA TicWatch fallita"; }
"$RIP" "$DONOR" -p "$DONOR_PARTS" -o "$DONOR_OUT" -n --sanity >"$REPORT/xiaomi_extract.log" 2>&1 || { tail -n 20 "$REPORT/xiaomi_extract.log" >&2; fail "estrazione OTA Xiaomi fallita; se è incrementale useremo il full OTA"; }
say "[4/4] Creo riepilogo compatto..."
{
 echo "=== WEAR5 STAGE1 ==="; echo "STOCK=$STOCK"; echo "DONOR=$DONOR"; echo
 echo "=== STOCK META ==="; grep -E '^(ota-type|pre-device|post-build|post-build-incremental|post-sdk-level|post-security-patch-level|security-patch-level)=' "$REPORT/stock_metadata.txt" 2>/dev/null || cat "$REPORT/stock_metadata.txt"; echo
 echo "=== XIAOMI META ==="; grep -E '^(ota-type|pre-device|post-build|post-build-incremental|post-sdk-level|post-security-patch-level|security-patch-level)=' "$REPORT/xiaomi_metadata.txt" 2>/dev/null || cat "$REPORT/xiaomi_metadata.txt"; echo
 echo "STOCK_PARTS=$STOCK_PARTS"; echo "DONOR_PARTS=$DONOR_PARTS"; echo
 echo "=== EXTRACTED TICWATCH ==="
 for F in "$STOCK_OUT"/*.img; do [ -e "$F" ] || continue; printf '%s | ' "$(basename "$F")"; stat -c '%s bytes' "$F" 2>/dev/null || true; file -b "$F" 2>/dev/null | head -c 220; echo; echo "SHA256=$(sha256sum "$F" | awk '{print $1}')"; done
 echo; echo "=== EXTRACTED XIAOMI BT ==="
 for F in "$DONOR_OUT"/*.img; do [ -e "$F" ] || continue; printf '%s | ' "$(basename "$F")"; stat -c '%s bytes' "$F" 2>/dev/null || true; file -b "$F" 2>/dev/null | head -c 220; echo; echo "SHA256=$(sha256sum "$F" | awk '{print $1}')"; done
 echo; echo "WORK=$WORK"
} > "$SUMMARY"
(cd "$WORK"; zip -q -j "$REPORT_ZIP" "$SUMMARY" "$REPORT/stock_metadata.txt" "$REPORT/xiaomi_metadata.txt" "$REPORT/stock_payload_properties.txt" "$REPORT/xiaomi_payload_properties.txt" "$REPORT/stock_partitions.txt" "$REPORT/xiaomi_partitions.txt" "$REPORT/otaripper_version.txt")
cat "$SUMMARY"; echo; echo "OK_REPORT=$REPORT_ZIP"
