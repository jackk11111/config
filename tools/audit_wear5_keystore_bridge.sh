#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail

W="$HOME/WEAR5"
TV="$W/stock/vendor.img"
XS="$W/xiaomi/system.img"
XV="$W/xiaomi/vendor.img"
T="$W/KEYSTORE_BRIDGE_AUDIT"

die(){ echo "BLOCKER=$*"; exit 2; }
command -v debugfs >/dev/null 2>&1 || die "debugfs_missing"
[ -f "$TV" ] || die "ticwatch_vendor_missing"
[ -f "$XS" ] || die "xiaomi_system_missing"

rm -rf "$T"
mkdir -p "$T"

rdump(){
  local img="$1" path="$2" out="$3"
  mkdir -p "$out"
  debugfs -R "rdump $path $out" "$img" >/dev/null 2>&1 || true
}
catf(){
  local img="$1" path="$2"
  debugfs -R "cat $path" "$img" 2>/dev/null || true
}

echo "=== 1 TICWATCH VENDOR KEYMASTER / QSEE INIT ==="
rdump "$TV" /etc/init "$T/tv_init"
grep -RniE 'keymaster|keymint|qsee|gatekeeper|secureclock|sharedsecret' "$T/tv_init" 2>/dev/null | head -240 || true

echo
echo "=== 2 TICWATCH VENDOR VINTF SECURITY HALS ==="
rdump "$TV" /etc/vintf "$T/tv_vintf"
grep -RniE 'keymaster|keymint|gatekeeper|secureclock|sharedsecret' "$T/tv_vintf" 2>/dev/null | head -240 || true
for p in /manifest.xml /compatibility_matrix.xml; do
  x="$(catf "$TV" "$p")"
  [ -n "$x" ] && printf '%s\n' "$x" | grep -niE 'keymaster|keymint|gatekeeper|secureclock|sharedsecret' || true
done

echo
echo "=== 3 TICWATCH VENDOR SECURITY BINARIES ==="
debugfs -R "ls -p /bin" "$TV" 2>/dev/null | tr '/' '\n' | grep -iE 'keymaster|keymint|qsee|gatekeeper' || true
debugfs -R "ls -p /lib64/hw" "$TV" 2>/dev/null | tr '/' '\n' | grep -iE 'keymaster|keymint|gatekeeper' || true

echo
echo "=== 4 XIAOMI ANDROID14 SYSTEM KEYSTORE2 INIT ==="
rdump "$XS" /etc/init "$T/xs_init"
grep -RniE '(^|[^a-z])keystore2([^a-z]|$)|android\.security\.compat|keymint|keymaster' "$T/xs_init" 2>/dev/null | head -240 || true

echo
echo "=== 5 XIAOMI ANDROID14 SYSTEM KEYSTORE2 FILES ==="
for p in  /bin/keystore2  /lib64/libkm_compat.so  /lib64/libkm_compat_service.so  /lib64/libkeystore2_crypto.so  /lib64/android.security.compat-V1-ndk.so
do
  if debugfs -R "stat $p" "$XS" >/dev/null 2>&1; then
    echo "$p=PRESENT"
  else
    echo "$p=ABSENT"
  fi
done

echo
echo "=== 6 XIAOMI SYSTEM VINTF SECURITY EXPECTATIONS ==="
rdump "$XS" /etc/vintf "$T/xs_vintf"
grep -RniE 'keymaster|keymint|gatekeeper|secureclock|sharedsecret' "$T/xs_vintf" 2>/dev/null | head -240 || true

if [ -f "$XV" ]; then
  echo
  echo "=== 7 XIAOMI VENDOR SECURITY HAL REFERENCE ==="
  rdump "$XV" /etc/init "$T/xv_init"
  rdump "$XV" /etc/vintf "$T/xv_vintf"
  grep -RniE 'keymaster|keymint|qsee|gatekeeper|secureclock|sharedsecret' "$T/xv_init" "$T/xv_vintf" 2>/dev/null | head -320 || true
else
  echo
  echo "=== 7 XIAOMI VENDOR SECURITY HAL REFERENCE ==="
  echo "XIAOMI_VENDOR_IMG=ABSENT"
fi

echo
echo "=== 8 SUMMARY ==="
KM41="$(grep -RilE 'android\.hardware\.keymaster.*4\.1|<version>4\.1</version>|@4\.1::IKeymasterDevice' "$T/tv_vintf" "$T/tv_init" 2>/dev/null | wc -l | tr -d ' ')"
KM40="$(grep -RilE 'android\.hardware\.keymaster.*4\.0|<version>4\.0</version>|@4\.0::IKeymasterDevice' "$T/tv_vintf" "$T/tv_init" 2>/dev/null | wc -l | tr -d ' ')"
DEF="$(grep -RniE 'IKeymasterDevice/default|<instance>default</instance>' "$T/tv_vintf" 2>/dev/null | head -1 || true)"
K2=NO
debugfs -R "stat /bin/keystore2" "$XS" >/dev/null 2>&1 && K2=YES || true

echo "TICWATCH_KEYMASTER_4_1_REFERENCES=$KM41"
echo "TICWATCH_KEYMASTER_4_0_REFERENCES=$KM40"
echo "TICWATCH_KEYMASTER_DEFAULT_INSTANCE=${DEF:-NOT_FOUND}"
echo "DONOR_KEYSTORE2_BINARY=$K2"

if [ "$K2" = YES ] && { [ "$KM41" -gt 0 ] || [ "$KM40" -gt 0 ]; }; then
  echo "STATIC_BRIDGE_POSSIBLE=YES"
  echo "NEXT_IF_BOOT_FAIL=VERIFY_LIVE_HAL_REGISTRATION_OR_SELINUX"
else
  echo "STATIC_BRIDGE_POSSIBLE=NO_OR_INCOMPLETE"
  echo "NEXT=FIX_STATIC_KEYSTORE_KEYMASTER_BRIDGE"
fi
