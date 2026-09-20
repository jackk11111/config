#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail

WORK="$HOME/WEAR5"
SYS="$WORK/xiaomi/system.img"
SYSEXT="$WORK/xiaomi/system_ext.img"
PROD="$WORK/xiaomi/product.img"
VENDOR="$WORK/stock/vendor.img"
LOCAL="$WORK/SEPOLICY_RECOVERY_TEST"
REMOTE="/cache/wear5_sepolicy_test"
ADB_HOST="10.82.56.57"
ADB_PORT="5037"
TARGET="${1:-C121X44260991}"
VER="33.0"

die(){ echo; echo "BLOCKER=$*"; exit 2; }

for f in "$SYS" "$SYSEXT" "$PROD" "$VENDOR"; do
  [ -f "$f" ] || die "immagine_mancante_$f"
done
command -v debugfs >/dev/null 2>&1 || die "debugfs_non_disponibile"

rm -rf "$LOCAL"
mkdir -p "$LOCAL"

dump_req(){
  local img="$1" src="$2" dst="$3"
  debugfs -R "dump $src $dst" "$img" >/dev/null 2>&1 || die "manca_${src//\//_}"
  [ -s "$dst" ] || die "vuoto_${src//\//_}"
}
dump_opt(){
  local img="$1" src="$2" dst="$3"
  if debugfs -R "dump $src $dst" "$img" >/dev/null 2>&1 && [ -s "$dst" ]; then
    return 0
  fi
  rm -f "$dst"
  return 1
}

dump_req "$SYS" /etc/selinux/plat_sepolicy.cil "$LOCAL/plat_sepolicy.cil"
dump_req "$SYS" /etc/selinux/mapping/$VER.cil "$LOCAL/plat_mapping.cil"
dump_req "$VENDOR" /etc/selinux/plat_pub_versioned.cil "$LOCAL/plat_pub_versioned.cil"
dump_req "$VENDOR" /etc/selinux/vendor_sepolicy.cil "$LOCAL/vendor_sepolicy.cil"
dump_req "$SYS" /bin/secilc "$LOCAL/donor_secilc"
chmod 755 "$LOCAL/donor_secilc"

dump_opt "$SYS" /etc/selinux/mapping/$VER.compat.cil "$LOCAL/plat_compat.cil" || true
dump_opt "$SYSEXT" /etc/selinux/system_ext_sepolicy.cil "$LOCAL/system_ext_sepolicy.cil" || true
dump_opt "$SYSEXT" /etc/selinux/mapping/$VER.cil "$LOCAL/system_ext_mapping.cil" || true
dump_opt "$SYSEXT" /etc/selinux/mapping/$VER.compat.cil "$LOCAL/system_ext_compat.cil" || true
dump_opt "$PROD" /etc/selinux/product_sepolicy.cil "$LOCAL/product_sepolicy.cil" || true
dump_opt "$PROD" /etc/selinux/mapping/$VER.cil "$LOCAL/product_mapping.cil" || true

ADB=(adb -H "$ADB_HOST" -P "$ADB_PORT" -s "$TARGET")
STATE="$(adb -H "$ADB_HOST" -P "$ADB_PORT" devices 2>/dev/null | awk -v s="$TARGET" '$1==s{print $2; exit}')"
case "$STATE" in recovery|device|rescue) ;; *) die "adb_state_${STATE:-vuoto}";; esac

PRODUCT="$("${ADB[@]}" shell getprop ro.product.device 2>/dev/null | tr -d '\r' | tail -1)"
[ "$PRODUCT" = "dace" ] || die "device_${PRODUCT:-vuoto}"

REMOTE_UID="$("${ADB[@]}" shell id -u 2>/dev/null | tr -d '\r' | tail -1)"
[ "$REMOTE_UID" = "0" ] || die "adb_non_root_uid_${REMOTE_UID:-vuoto}"

echo "PREFLIGHT=PASS"
echo "ADB_STATE=$STATE"
echo "PRODUCT=$PRODUCT"
echo "DONOR_SECILC_FILE=$(file -b "$LOCAL/donor_secilc" 2>/dev/null || true)"

"${ADB[@]}" shell "rm -rf '$REMOTE' && mkdir -p '$REMOTE'" >/dev/null || die "remote_dir_fallita"
"${ADB[@]}" push "$LOCAL/." "$REMOTE/" >/dev/null || die "push_test_files_fallito"
"${ADB[@]}" shell "chmod 755 '$REMOTE/donor_secilc'" >/dev/null 2>&1 || true

POLICYVERS="$("${ADB[@]}" shell 'cat /sys/fs/selinux/policyvers 2>/dev/null || cat /sys/fs/selinux/policyvers 2>/dev/null || echo 30' | tr -d '\r' | grep -E '^[0-9]+$' | tail -1)"
[ -n "$POLICYVERS" ] || POLICYVERS=30
echo "KERNEL_POLICYVERS=$POLICYVERS"

# Prefer an already-runnable secilc from recovery. If absent, try the
# Android 14 donor binary directly and then through any 32-bit linker
# exposed by recovery. ENOENT on a present ELF usually means its PT_INTERP
# (/system/bin/bootstrap/linker) is missing, not that the ELF itself is missing.
COMPILER=""
COMPILER_KIND=""

probe_cmd(){
  local cmd="$1" out rc
  set +e
  out="$("${ADB[@]}" shell "$cmd -h" 2>&1)"
  rc=$?
  set -e
  if printf '%s\n' "$out" | grep -qiE 'usage:.*secilc|secilc.*usage|options:' \
     && ! printf '%s\n' "$out" | grep -qiE 'No such file|not found|Exec format'; then
    return 0
  fi
  return 1
}

for CAND in /system/bin/secilc /sbin/secilc /vendor/bin/secilc; do
  if "${ADB[@]}" shell "[ -x '$CAND' ]" >/dev/null 2>&1 && probe_cmd "'$CAND'"; then
    COMPILER="'$CAND'"
    COMPILER_KIND="RECOVERY_SECILC"
    break
  fi
done

DONOR_DIRECT_OUT="$("${ADB[@]}" shell "'$REMOTE/donor_secilc' -h" 2>&1 || true)"
if [ -z "$COMPILER" ] && probe_cmd "'$REMOTE/donor_secilc'"; then
  COMPILER="'$REMOTE/donor_secilc'"
  COMPILER_KIND="DONOR_DIRECT"
fi

if [ -z "$COMPILER" ]; then
  for LINKER in /system/bin/bootstrap/linker /system/bin/linker /apex/com.android.runtime/bin/linker; do
    if "${ADB[@]}" shell "[ -x '$LINKER' ]" >/dev/null 2>&1; then
      if probe_cmd "'$LINKER' '$REMOTE/donor_secilc'"; then
        COMPILER="'$LINKER' '$REMOTE/donor_secilc'"
        COMPILER_KIND="DONOR_VIA_$LINKER"
        break
      fi
    fi
  done
fi

if [ -n "$COMPILER" ]; then
  echo "COMPILER=$COMPILER_KIND"
fi

if [ -z "$COMPILER" ]; then
  echo "DONOR_DIRECT_PROBE=$(printf '%s' "$DONOR_DIRECT_OUT" | tr '\n' ' ' | head -c 300)"
  echo "RECOVERY_SECILC_PATHS=$("${ADB[@]}" shell 'for x in /system/bin/secilc /sbin/secilc /vendor/bin/secilc; do [ -x "$x" ] && printf "%s," "$x"; done' 2>/dev/null | tr -d '\r' | sed 's/,$//')"
  echo "RECOVERY_LINKERS=$("${ADB[@]}" shell 'for x in /system/bin/bootstrap/linker /system/bin/linker /system/bin/linker64 /apex/com.android.runtime/bin/linker /apex/com.android.runtime/bin/linker64; do [ -x "$x" ] && printf "%s," "$x"; done' 2>/dev/null | tr -d '\r' | sed 's/,$//')"
  echo "FINDING=NO_EXECUTABLE_SECILC_IN_RECOVERY"
  exit 0
fi

ARGS="'$REMOTE/plat_sepolicy.cil' -m -M true -G -N -c '$POLICYVERS' '$REMOTE/plat_mapping.cil' -o '$REMOTE/compiled_sepolicy' -f /dev/null"
[ -f "$LOCAL/plat_compat.cil" ] && ARGS="$ARGS '$REMOTE/plat_compat.cil'"
[ -f "$LOCAL/system_ext_sepolicy.cil" ] && ARGS="$ARGS '$REMOTE/system_ext_sepolicy.cil'"
[ -f "$LOCAL/system_ext_mapping.cil" ] && ARGS="$ARGS '$REMOTE/system_ext_mapping.cil'"
[ -f "$LOCAL/system_ext_compat.cil" ] && ARGS="$ARGS '$REMOTE/system_ext_compat.cil'"
[ -f "$LOCAL/product_sepolicy.cil" ] && ARGS="$ARGS '$REMOTE/product_sepolicy.cil'"
[ -f "$LOCAL/product_mapping.cil" ] && ARGS="$ARGS '$REMOTE/product_mapping.cil'"
ARGS="$ARGS '$REMOTE/plat_pub_versioned.cil' '$REMOTE/vendor_sepolicy.cil'"

set +e
OUT="$("${ADB[@]}" shell "$COMPILER $ARGS" 2>&1)"
RC=$?
set -e

echo "SECILC_RC=$RC"
if [ "$RC" -eq 0 ]; then
  COMPILED_SIZE="$("${ADB[@]}" shell "stat -c %s '$REMOTE/compiled_sepolicy' 2>/dev/null" | tr -d '\r' | tail -1)"
  echo "COMPILED_SIZE=${COMPILED_SIZE:-UNKNOWN}"
  echo "FINDING=HYBRID_SPLIT_SEPOLICY_COMPILES_ON_WATCH"
else
  echo "=== SECILC ERROR ==="
  printf '%s\n' "$OUT" | sed -n '1,120p'
  echo "FINDING=HYBRID_SPLIT_SEPOLICY_COMPILE_FAIL_ON_WATCH"
fi
