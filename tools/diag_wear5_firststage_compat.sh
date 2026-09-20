#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail

WORK="$HOME/WEAR5"
VENDOR="$WORK/stock/vendor.img"
SYSTEM="$WORK/xiaomi/system.img"
SYSTEM_EXT="$WORK/xiaomi/system_ext.img"
PRODUCT="$WORK/xiaomi/product.img"

die(){ echo; echo "BLOCKER=$*"; exit 2; }

for f in "$VENDOR" "$SYSTEM" "$SYSTEM_EXT" "$PRODUCT"; do
  [ -f "$f" ] || die "immagine_mancante_$f"
done
command -v debugfs >/dev/null 2>&1 || die "debugfs_non_disponibile_installa_e2fsprogs"

catimg(){
  local img="$1" path="$2"
  debugfs -R "cat $path" "$img" 2>/dev/null || true
}
lsimg(){
  local img="$1" path="$2"
  debugfs -R "ls -p $path" "$img" 2>/dev/null || true
}
existsimg(){
  local img="$1" path="$2"
  debugfs -R "stat $path" "$img" >/dev/null 2>&1
}

VENDOR_POLICY_VER="$(catimg "$VENDOR" /etc/selinux/plat_sepolicy_vers.txt | tr -d '\r\n ')"
[ -n "$VENDOR_POLICY_VER" ] || VENDOR_POLICY_VER="UNKNOWN"

MAP_LIST="$(lsimg "$SYSTEM" /etc/selinux/mapping)"
HAS_MAPPING=NO
if [ "$VENDOR_POLICY_VER" != UNKNOWN ]; then
  printf '%s\n' "$MAP_LIST" | grep -Fq "/${VENDOR_POLICY_VER}.cil/" && HAS_MAPPING=YES || true
  printf '%s\n' "$MAP_LIST" | grep -Eq "(^|/|[[:space:]])${VENDOR_POLICY_VER//./\\.}\\.cil([/[:space:]]|$)" && HAS_MAPPING=YES || true
fi

PLAT=NO
VENDOR_CIL=NO
MAPPING_DIR=NO
existsimg "$SYSTEM" /etc/selinux/plat_sepolicy.cil && PLAT=YES || true
existsimg "$VENDOR" /etc/selinux/vendor_sepolicy.cil && VENDOR_CIL=YES || true
existsimg "$SYSTEM" /etc/selinux/mapping && MAPPING_DIR=YES || true

echo "DIAG=PASS"
echo "VENDOR_PLAT_SEPOLICY_VERSION=$VENDOR_POLICY_VER"
echo "DONOR_SYSTEM_PLAT_SEPOLICY_CIL=$PLAT"
echo "STOCK_VENDOR_SEPOLICY_CIL=$VENDOR_CIL"
echo "DONOR_MAPPING_DIR=$MAPPING_DIR"
echo "DONOR_HAS_VENDOR_MAPPING=$HAS_MAPPING"
echo "DONOR_MAPPING_FILES=$(printf '%s\n' "$MAP_LIST" | grep -oE '[0-9]+\.[0-9]+\.cil' | sort -Vu | tr '\n' ',' | sed 's/,$//' || true)"

BAD_FS=()
for pair in "system:$SYSTEM" "system_ext:$SYSTEM_EXT" "product:$PRODUCT" "vendor:$VENDOR"; do
  name="${pair%%:*}"
  img="${pair#*:}"
  if ! debugfs -R 'stat /' "$img" >/dev/null 2>&1; then
    BAD_FS+=("$name")
  fi
done
if [ "${#BAD_FS[@]}" -eq 0 ]; then
  echo "LOGICAL_FILESYSTEMS_READABLE=YES"
else
  echo "LOGICAL_FILESYSTEMS_READABLE=NO"
  echo "BAD_FILESYSTEMS=$(IFS=,; echo "${BAD_FS[*]}")"
fi

if [ "$VENDOR_POLICY_VER" != UNKNOWN ] && [ "$HAS_MAPPING" = NO ]; then
  echo "FINDING=MISSING_SEPOLICY_MAPPING"
elif [ "$PLAT" = YES ] && [ "$VENDOR_CIL" = YES ] && [ "$HAS_MAPPING" = YES ] && [ "${#BAD_FS[@]}" -eq 0 ]; then
  echo "FINDING=SEPOLICY_MAPPING_PRESENT_FILESYSTEMS_READABLE"
else
  echo "FINDING=NEEDS_REVIEW"
fi
