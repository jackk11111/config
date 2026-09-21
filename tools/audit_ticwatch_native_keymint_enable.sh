#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail

W="$HOME/WEAR5"
TV="$W/stock/vendor.img"
XS="$W/xiaomi/system.img"
XV="$W/xiaomi/vendor.img"
T="$W/TICWATCH_KEYMINT_ENABLE_AUDIT"

die(){ echo; echo "BLOCKER=$*"; exit 2; }
command -v debugfs >/dev/null 2>&1 || die "debugfs_missing"
[ -f "$TV" ] || die "ticwatch_vendor_missing"
[ -f "$XS" ] || die "xiaomi_system_missing"

rm -rf "$T"
mkdir -p "$T"

BIN="/bin/hw/android.hardware.security.keymint-service-qti"
TB="$T/ticwatch_keymint"
debugfs -R "dump $BIN $TB" "$TV" >/dev/null 2>&1 || die "ticwatch_keymint_binary_missing"
chmod 755 "$TB"

echo "=== 1 KEYMINT BINARY LABEL ==="
debugfs -R "ea_get $BIN security.selinux" "$TV" 2>&1 || true

echo
echo "=== 2 ELF NEEDED ==="
READELF=""
for C in readelf llvm-readelf; do
  if command -v "$C" >/dev/null 2>&1; then READELF="$C"; break; fi
done
if [ -n "$READELF" ]; then
  "$READELF" -d "$TB" 2>/dev/null | grep 'NEEDED' || true
else
  echo "READELF=ABSENT"
  echo "FALLBACK_STRINGS_NEEDED"
  strings "$TB" | grep -E '(^|/)lib[^ /]+\.so$|android\.hardware\.security\..*\.so$' | sort -u
fi

echo
echo "=== 3 TICWATCH KEYMINT SEPOLICY REFERENCES ==="
for P in   /etc/selinux/vendor_sepolicy.cil   /etc/selinux/plat_pub_versioned.cil   /etc/selinux/vendor_file_contexts   /etc/selinux/vendor_service_contexts   /etc/selinux/vendor_hwservice_contexts   /etc/selinux/file_contexts   /etc/selinux/service_contexts   /etc/selinux/hwservice_contexts
do
  O="$T/$(basename "$P").txt"
  debugfs -R "cat $P" "$TV" > "$O" 2>/dev/null || { rm -f "$O"; continue; }
  echo "--- $P ---"
  grep -niE 'keymint|keymaster|secureclock|sharedsecret|remotely.?provision' "$O" | head -160 || echo "NO_MATCH"
done

echo
echo "=== 4 TICWATCH KEYMINT / AIDL LIBRARIES ==="
for D in /lib64 /lib64/hw /lib /lib/hw; do
  debugfs -R "ls -p $D" "$TV" 2>/dev/null |
    tr '/' '\n' |
    grep -E 'keymint|qtikeymint|security.*(keymint|secureclock|sharedsecret|rkp)' || true
done

echo
echo "=== 5 EXACT REQUIRED LIBRARY AVAILABILITY ==="
if [ -n "$READELF" ]; then
  "$READELF" -d "$TB" 2>/dev/null |
  sed -n 's/.*Shared library: \[\(.*\)\]/\1/p' |
  while IFS= read -r LIB; do
    [ -n "$LIB" ] || continue
    FOUND=""
    for SPEC in       "TV:/lib64/$LIB" "TV:/lib/$LIB"       "XS:/lib64/$LIB" "XS:/lib/$LIB"
    do
      SRC="${SPEC%%:*}"
      P="${SPEC#*:}"
      IMG="$TV"; [ "$SRC" = XS ] && IMG="$XS"
      if debugfs -R "stat $P" "$IMG" >/dev/null 2>&1; then
        FOUND="$FOUND $SRC$P"
      fi
    done
    echo "$LIB =>${FOUND:- MISSING}"
  done
fi

echo
echo "=== 6 XIAOMI REFERENCE LABEL/POLICY ==="
if [ -f "$XV" ]; then
  debugfs -R "ea_get $BIN security.selinux" "$XV" 2>&1 || true
  for P in     /etc/selinux/vendor_sepolicy.cil     /etc/selinux/vendor_file_contexts     /etc/selinux/vendor_service_contexts
  do
    O="$T/xiaomi_$(basename "$P").txt"
    debugfs -R "cat $P" "$XV" > "$O" 2>/dev/null || { rm -f "$O"; continue; }
    echo "--- XIAOMI $P ---"
    grep -niE 'keymint|secureclock|sharedsecret|remotely.?provision' "$O" | head -160 || echo "NO_MATCH"
  done
else
  echo "XIAOMI_VENDOR=ABSENT"
fi

echo
echo "=== 7 INTERFACE STRINGS IN TICWATCH BINARY ==="
strings "$TB" |
grep -E 'android\.hardware\.security\.(keymint|secureclock|sharedsecret|rkp)|IKeyMintDevice|ISecureClock|ISharedSecret|IRemotelyProvisionedComponent' |
sort -u | head -160 || true

echo
echo "AUDIT_DONE=YES"
echo "NEXT=DECIDE_NATIVE_TICWATCH_KEYMINT_ENABLE"
