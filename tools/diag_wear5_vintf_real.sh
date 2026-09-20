#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail

WORK="$HOME/WEAR5"
SYS="$WORK/xiaomi/system.img"
SYSEXT="$WORK/xiaomi/system_ext.img"
PROD="$WORK/xiaomi/product.img"
VENDOR="$WORK/stock/vendor.img"
LOCAL="$WORK/VINTF_REAL_TEST"
REMOTE="/cache/wear5_vintf_real_test"
ADB_HOST="10.82.56.57"
ADB_PORT="5037"
TARGET="${1:-C121X44260991}"

die(){ echo; echo "BLOCKER=$*"; exit 2; }

for f in "$SYS" "$SYSEXT" "$PROD" "$VENDOR"; do
  [ -f "$f" ] || die "immagine_mancante_$f"
done
command -v debugfs >/dev/null 2>&1 || die "debugfs_non_disponibile"

rm -rf "$LOCAL"
mkdir -p "$LOCAL/system/etc" "$LOCAL/system_ext/etc" "$LOCAL/product/etc" "$LOCAL/vendor/etc" "$LOCAL/odm/etc"

rdump_opt(){
  local img="$1" src="$2" dst="$3"
  mkdir -p "$dst"
  debugfs -R "rdump $src $dst" "$img" >/dev/null 2>&1 || true
}

rdump_opt "$SYS" /etc/vintf "$LOCAL/system/etc"
rdump_opt "$SYSEXT" /etc/vintf "$LOCAL/system_ext/etc"
rdump_opt "$PROD" /etc/vintf "$LOCAL/product/etc"
rdump_opt "$VENDOR" /etc/vintf "$LOCAL/vendor/etc"

# Extract donor checkvintf for fallback only.
debugfs -R "dump /bin/checkvintf $LOCAL/donor_checkvintf" "$SYS" >/dev/null 2>&1 || true
[ -f "$LOCAL/donor_checkvintf" ] && chmod 755 "$LOCAL/donor_checkvintf" || true

COUNT="$(find "$LOCAL" -type f | wc -l | tr -d " ")"
[ "$COUNT" -gt 0 ] || die "nessun_file_vintf_estratto"

ADB=(adb -H "$ADB_HOST" -P "$ADB_PORT" -s "$TARGET")
STATE="$(adb -H "$ADB_HOST" -P "$ADB_PORT" devices 2>/dev/null | awk -v s="$TARGET" '$1==s{print $2; exit}')"
case "$STATE" in recovery|device|rescue) ;; *) die "adb_state_${STATE:-vuoto}";; esac
PRODUCT_NAME="$("${ADB[@]}" shell getprop ro.product.device 2>/dev/null | tr -d "\r" | tail -1)"
[ "$PRODUCT_NAME" = "dace" ] || die "device_${PRODUCT_NAME:-vuoto}"
REMOTE_UID="$("${ADB[@]}" shell id -u 2>/dev/null | tr -d "\r" | tail -1)"
[ "$REMOTE_UID" = "0" ] || die "adb_non_root_uid_${REMOTE_UID:-vuoto}"

echo "PREFLIGHT=PASS"
echo "ADB_STATE=$STATE"
echo "PRODUCT=$PRODUCT_NAME"
echo "VINTF_FILES_LOCAL=$COUNT"

"${ADB[@]}" shell "rm -rf '$REMOTE' && mkdir -p '$REMOTE'" >/dev/null || die "remote_dir_fallita"
"${ADB[@]}" push "$LOCAL/." "$REMOTE/" >/dev/null || die "push_vintf_test_fallito"

# Prefer recovery checkvintf; fallback to donor through an available 32-bit linker.
CHECKER=""
KIND=""
for CAND in /system/bin/checkvintf /sbin/checkvintf /vendor/bin/checkvintf; do
  if "${ADB[@]}" shell "[ -x '$CAND' ]" >/dev/null 2>&1; then
    OUT="$("${ADB[@]}" shell "'$CAND' --help" 2>&1 || true)"
    if printf "%s\n" "$OUT" | grep -qi "check VINTF metadata"; then
      CHECKER="'$CAND'"
      KIND="RECOVERY_CHECKVINTF"
      break
    fi
  fi
done

if [ -z "$CHECKER" ] && [ -f "$LOCAL/donor_checkvintf" ]; then
  "${ADB[@]}" shell "chmod 755 '$REMOTE/donor_checkvintf'" >/dev/null 2>&1 || true
  for LINKER in /system/bin/bootstrap/linker /system/bin/linker /apex/com.android.runtime/bin/linker; do
    if "${ADB[@]}" shell "[ -x '$LINKER' ]" >/dev/null 2>&1; then
      OUT="$("${ADB[@]}" shell "'$LINKER' '$REMOTE/donor_checkvintf' --help" 2>&1 || true)"
      if printf "%s\n" "$OUT" | grep -qi "check VINTF metadata"; then
        CHECKER="'$LINKER' '$REMOTE/donor_checkvintf'"
        KIND="DONOR_CHECKVINTF_VIA_$LINKER"
        break
      fi
    fi
  done
fi

if [ -z "$CHECKER" ]; then
  echo "FINDING=NO_EXECUTABLE_CHECKVINTF_IN_RECOVERY"
  exit 0
fi
echo "CHECKER=$KIND"

CMD="$CHECKER --check-compat"
CMD="$CMD --dirmap /system:$REMOTE/system"
CMD="$CMD --dirmap /system_ext:$REMOTE/system_ext"
CMD="$CMD --dirmap /product:$REMOTE/product"
CMD="$CMD --dirmap /vendor:$REMOTE/vendor"
CMD="$CMD --dirmap /odm:$REMOTE/odm"
CMD="$CMD --property ro.product.first_api_level=30"

set +e
OUT="$("${ADB[@]}" shell "$CMD" 2>&1)"
RC=$?
set -e

echo "CHECKVINTF_RC=$RC"
echo "=== CHECKVINTF OUTPUT ==="
printf "%s\n" "$OUT" | sed -n "1,160p"

if [ "$RC" -eq 0 ] && printf "%s\n" "$OUT" | grep -q "COMPATIBLE"; then
  echo "FINDING=HYBRID_VINTF_COMPATIBLE"
elif printf "%s\n" "$OUT" | grep -q "INCOMPATIBLE"; then
  echo "FINDING=HYBRID_VINTF_INCOMPATIBLE"
else
  echo "FINDING=CHECKVINTF_EXECUTION_OR_INPUT_ERROR"
fi
