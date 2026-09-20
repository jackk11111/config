#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail

WORK="$HOME/WEAR5"
SYS="$WORK/xiaomi/system.img"
SYSEXT="$WORK/xiaomi/system_ext.img"
PROD="$WORK/xiaomi/product.img"
VENDOR="$WORK/stock/vendor.img"
ODM="$WORK/stock/odm.img"
OUT="$WORK/SEPOLICY_COMPILE_TEST"
VER="33.0"
POLICYVERS="30"

die(){ echo; echo "BLOCKER=$*"; exit 2; }

for f in "$SYS" "$SYSEXT" "$PROD" "$VENDOR"; do
  [ -f "$f" ] || die "immagine_mancante_$f"
done
command -v debugfs >/dev/null 2>&1 || die "debugfs_non_disponibile"

rm -rf "$OUT"
mkdir -p "$OUT"

dump_req(){
  local img="$1" src="$2" dst="$3"
  debugfs -R "dump $src $dst" "$img" >/dev/null 2>&1 || die "manca_${src//\//_}"
  [ -s "$dst" ] || die "vuoto_${src//\//_}"
}
dump_opt(){
  local img="$1" src="$2" dst="$3"
  if debugfs -R "dump $src $dst" "$img" >/dev/null 2>&1 && [ -s "$dst" ]; then
    echo "$dst"
  else
    rm -f "$dst"
  fi
}

dump_req "$SYS" /etc/selinux/plat_sepolicy.cil "$OUT/plat_sepolicy.cil"
dump_req "$SYS" /etc/selinux/mapping/$VER.cil "$OUT/plat_mapping.cil"
dump_req "$VENDOR" /etc/selinux/plat_pub_versioned.cil "$OUT/plat_pub_versioned.cil"
dump_req "$VENDOR" /etc/selinux/vendor_sepolicy.cil "$OUT/vendor_sepolicy.cil"

SYS_COMPAT="$(dump_opt "$SYS" /etc/selinux/mapping/$VER.compat.cil "$OUT/plat_compat.cil")"
SE_POLICY="$(dump_opt "$SYSEXT" /etc/selinux/system_ext_sepolicy.cil "$OUT/system_ext_sepolicy.cil")"
SE_MAP="$(dump_opt "$SYSEXT" /etc/selinux/mapping/$VER.cil "$OUT/system_ext_mapping.cil")"
SE_COMPAT="$(dump_opt "$SYSEXT" /etc/selinux/mapping/$VER.compat.cil "$OUT/system_ext_compat.cil")"
PROD_POLICY="$(dump_opt "$PROD" /etc/selinux/product_sepolicy.cil "$OUT/product_sepolicy.cil")"
PROD_MAP="$(dump_opt "$PROD" /etc/selinux/mapping/$VER.cil "$OUT/product_mapping.cil")"
ODM_POLICY=""
if [ -f "$ODM" ]; then
  ODM_POLICY="$(dump_opt "$ODM" /etc/selinux/odm_sepolicy.cil "$OUT/odm_sepolicy.cil")"
fi

SECILC="$OUT/secilc"
dump_req "$SYS" /bin/secilc "$SECILC"
chmod 700 "$SECILC"

echo "SEPOLICY_VENDOR_MAPPING=$VER"
echo "SEPOLICY_BINARY_VERSION=$POLICYVERS"
echo "SYSTEM_COMPAT=$([ -n "$SYS_COMPAT" ] && echo YES || echo NO)"
echo "SYSTEM_EXT_POLICY=$([ -n "$SE_POLICY" ] && echo YES || echo NO)"
echo "SYSTEM_EXT_MAPPING=$([ -n "$SE_MAP" ] && echo YES || echo NO)"
echo "SYSTEM_EXT_COMPAT=$([ -n "$SE_COMPAT" ] && echo YES || echo NO)"
echo "PRODUCT_POLICY=$([ -n "$PROD_POLICY" ] && echo YES || echo NO)"
echo "PRODUCT_MAPPING=$([ -n "$PROD_MAP" ] && echo YES || echo NO)"
echo "ODM_POLICY_LOCAL=$([ -n "$ODM_POLICY" ] && echo YES || echo NO)"

set +e
SECILC_PROBE="$("$SECILC" -h 2>&1)"
PROBE_RC=$?
set -e
if [ "$PROBE_RC" -ne 0 ] && ! printf "%s\n" "$SECILC_PROBE" | grep -qiE "usage|secilc|option"; then
  echo "SECILC_EXEC=FAIL"
  printf "%s\n" "$SECILC_PROBE" | head -n 20
  echo "FINDING=SECILC_CANNOT_RUN_IN_TERMUX"
  exit 0
fi
echo "SECILC_EXEC=PASS"

ARGS=(
  "$OUT/plat_sepolicy.cil"
  -m -M true -G -N
  -c "$POLICYVERS"
  "$OUT/plat_mapping.cil"
  -o "$OUT/compiled_sepolicy"
  -f /dev/null
)
[ -n "$SYS_COMPAT" ] && ARGS+=("$SYS_COMPAT")
[ -n "$SE_POLICY" ] && ARGS+=("$SE_POLICY")
[ -n "$SE_MAP" ] && ARGS+=("$SE_MAP")
[ -n "$SE_COMPAT" ] && ARGS+=("$SE_COMPAT")
[ -n "$PROD_POLICY" ] && ARGS+=("$PROD_POLICY")
[ -n "$PROD_MAP" ] && ARGS+=("$PROD_MAP")
ARGS+=("$OUT/plat_pub_versioned.cil" "$OUT/vendor_sepolicy.cil")
[ -n "$ODM_POLICY" ] && ARGS+=("$ODM_POLICY")

set +e
"$SECILC" "${ARGS[@]}" >"$OUT/secilc.stdout" 2>"$OUT/secilc.stderr"
RC=$?
set -e

echo "SECILC_RC=$RC"
if [ "$RC" -eq 0 ] && [ -s "$OUT/compiled_sepolicy" ]; then
  echo "COMPILED_SIZE=$(stat -c %s "$OUT/compiled_sepolicy")"
  echo "FINDING=HYBRID_SPLIT_SEPOLICY_COMPILES"
else
  echo "=== SECILC ERROR ==="
  sed -n "1,120p" "$OUT/secilc.stderr"
  echo "FINDING=HYBRID_SPLIT_SEPOLICY_COMPILE_FAIL"
fi
echo "REPORT_DIR=$OUT"
