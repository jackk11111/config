#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail

WORK="$HOME/WEAR5"
XIAOMI="$WORK/xiaomi"
STOCK="$WORK/stock"
OUT="/storage/emulated/0/Download/WEAR5_C1_DIAG_PC"
IMG="$OUT/images"
TMP="$WORK/C1_DIAG_PC_BUILD"
META="/metadata/diag/wear5diag"
SUPER="$OUT/super_C1_DIAG.img"
SUPER_SIZE=4294967296
GROUP="qti_dynamic_partitions"
GROUP_SIZE=4284481536
PARTS=(system vendor product system_ext vendor_dlkm system_dlkm)

die(){ echo; echo "BLOCKER=$*"; exit 2; }

for C in debugfs lpmake lpdump sha256sum; do
  command -v "$C" >/dev/null 2>&1 || die "tool_mancante_$C"
done
for F in   "$XIAOMI/system.img" "$XIAOMI/system_ext.img" "$XIAOMI/product.img"   "$STOCK/vendor.img" "$STOCK/vendor_dlkm.img" "$STOCK/system_dlkm.img"; do
  [ -f "$F" ] || die "file_mancante_$F"
done

rm -rf "$OUT" "$TMP"
mkdir -p "$OUT" "$IMG" "$TMP/vendor_init"

echo "[1/4] PATCH_VENDOR_LOCALLY"
cp --reflink=auto --sparse=always "$STOCK/vendor.img" "$TMP/vendor_diag.img"

debugfs -R "rdump /etc/init $TMP/vendor_init" "$STOCK/vendor.img" >/dev/null 2>&1 || true
grep -RhsE '^[[:space:]]*service[[:space:]]+' "$TMP/vendor_init" 2>/dev/null   | awk '{print $2}' | grep -Ei 'qsee|keymaster|keymint' | sort -u > "$TMP/secure_services.txt" || true

cat > "$TMP/wear5diag.rc" <<'EOF'
# WEAR5-DIAG2-BEGIN
on early-init
    chmod 0777 /metadata/diag/wear5diag/01_early_init
on init
    chmod 0777 /metadata/diag/wear5diag/02_init
on late-init
    chmod 0777 /metadata/diag/wear5diag/03_late_init
on fs
    chmod 0777 /metadata/diag/wear5diag/04_fs
on post-fs
    chmod 0777 /metadata/diag/wear5diag/05_post_fs
on late-fs
    chmod 0777 /metadata/diag/wear5diag/06_late_fs
on post-fs-data
    chmod 0777 /metadata/diag/wear5diag/07_post_fs_data
on early-boot
    chmod 0777 /metadata/diag/wear5diag/08_early_boot
on boot
    chmod 0777 /metadata/diag/wear5diag/09_boot
on property:init.svc.apexd=running
    chmod 0777 /metadata/diag/wear5diag/10_apexd_running
on property:init.svc.vold=running
    chmod 0777 /metadata/diag/wear5diag/20_vold_running
on property:init.svc.servicemanager=running
    chmod 0777 /metadata/diag/wear5diag/30_servicemanager_running
on property:init.svc.hwservicemanager=running
    chmod 0777 /metadata/diag/wear5diag/31_hwservicemanager_running
on property:init.svc.keystore2=running
    chmod 0777 /metadata/diag/wear5diag/35_keystore2_running
on property:init.svc.zygote=running
    chmod 0777 /metadata/diag/wear5diag/40_zygote_running
on property:init.svc.surfaceflinger=running
    chmod 0777 /metadata/diag/wear5diag/41_surfaceflinger_running
on property:init.svc.bootanim=running
    chmod 0777 /metadata/diag/wear5diag/42_bootanim_running
on property:sys.boot_completed=1
    chmod 0777 /metadata/diag/wear5diag/99_boot_completed
EOF

while IFS= read -r SVC; do
  [ -n "$SVC" ] || continue
  SAFE="$(printf '%s' "$SVC" | sed 's/[^A-Za-z0-9_.-]/_/g')"
  {
    echo
    echo "on property:init.svc.$SVC=running"
    echo "    chmod 0777 /metadata/diag/wear5diag/50_svc_$SAFE"
  } >> "$TMP/wear5diag.rc"
done < "$TMP/secure_services.txt"
echo '# WEAR5-DIAG2-END' >> "$TMP/wear5diag.rc"
chmod 0644 "$TMP/wear5diag.rc"

# Pick a real rc path directly from vendor.img. The previous version
# derived it from rdump output and could accidentally produce /etc/init/init/...
TEMPLATE=""
debugfs -R "ls -p /etc/init" "$STOCK/vendor.img" 2>/dev/null \
  | awk -F/ '$6 ~ /[.]rc$/ {print $6}' > "$TMP/vendor_rc_names.txt" || true

while IFS= read -r RCNAME; do
  [ -n "$RCNAME" ] || continue
  CAND="/etc/init/$RCNAME"
  rm -f "$TMP/vendor_selinux.xattr"
  if debugfs -R "ea_get -f $TMP/vendor_selinux.xattr $CAND security.selinux" "$STOCK/vendor.img" >/dev/null 2>&1 \
     && [ -s "$TMP/vendor_selinux.xattr" ]; then
    TEMPLATE="$CAND"
    break
  fi
done < "$TMP/vendor_rc_names.txt"

[ -n "$TEMPLATE" ] || die "vendor_init_selinux_xattr_non_trovato"

debugfs -w -R "rm /etc/init/wear5diag.rc" "$TMP/vendor_diag.img" >/dev/null 2>&1 || true
debugfs -w -R "write $TMP/wear5diag.rc /etc/init/wear5diag.rc" "$TMP/vendor_diag.img" >/dev/null 2>&1 \
  || die "vendor_diag_write_fallito"
debugfs -w -R "set_inode_field /etc/init/wear5diag.rc mode 0100644" "$TMP/vendor_diag.img" >/dev/null 2>&1 || true
debugfs -w -R "set_inode_field /etc/init/wear5diag.rc uid 0" "$TMP/vendor_diag.img" >/dev/null 2>&1 || true
debugfs -w -R "set_inode_field /etc/init/wear5diag.rc gid 0" "$TMP/vendor_diag.img" >/dev/null 2>&1 || true

debugfs -w -R "ea_set -f $TMP/vendor_selinux.xattr /etc/init/wear5diag.rc security.selinux" "$TMP/vendor_diag.img" >/dev/null 2>&1 \
  || die "vendor_diag_xattr_fallito"

echo "VENDOR_INIT_TEMPLATE=$TEMPLATE"

debugfs -R "cat /etc/init/wear5diag.rc" "$TMP/vendor_diag.img" > "$TMP/verify.rc" 2>/dev/null   || die "vendor_diag_verify_read_fallito"
cmp -s "$TMP/wear5diag.rc" "$TMP/verify.rc" || die "vendor_diag_verify_content_fallito"

echo "[2/4] BUILD_ONE_FINAL_SUPER"
declare -A SRC
SRC[system]="$XIAOMI/system.img"
SRC[system_ext]="$XIAOMI/system_ext.img"
SRC[product]="$XIAOMI/product.img"
SRC[vendor]="$TMP/vendor_diag.img"
SRC[vendor_dlkm]="$STOCK/vendor_dlkm.img"
SRC[system_dlkm]="$STOCK/system_dlkm.img"

SUM=0
ARGS=(--group "$GROUP:$GROUP_SIZE")
for P in "${PARTS[@]}"; do
  F="${SRC[$P]}"
  SZ="$(stat -c %s "$F")"
  SUM=$((SUM+SZ))
  ARGS+=(--partition "$P:readonly:$SZ:$GROUP" --image "$P=$F")
done
[ "$SUM" -le "$GROUP_SIZE" ] || die "logical_images_too_large"

lpmake   --metadata-size 65536   --metadata-slots 2   --super-name super   --device "super:$SUPER_SIZE"   "${ARGS[@]}"   --output "$SUPER" >/dev/null || die "lpmake_fallito"

[ "$(stat -c %s "$SUPER")" = "$SUPER_SIZE" ] || die "super_size_errata"
lpdump "$SUPER" > "$OUT/SUPER_LPDUMP.txt" 2>&1 || die "lpdump_fallito"

echo "[3/4] HASH_AND_PC_PACKAGE"
SHA="$(sha256sum "$SUPER" | awk '{print $1}')"
printf '%s  %s\n' "$SHA" "$(basename "$SUPER")" > "$OUT/SHA256.txt"
cp -f "$TMP/wear5diag.rc" "$OUT/wear5diag.rc"
cp -f "$TMP/secure_services.txt" "$OUT/secure_services.txt"

CORE_MARKERS="01_early_init 02_init 03_late_init 04_fs 05_post_fs 06_late_fs 07_post_fs_data 08_early_boot 09_boot 10_apexd_running 20_vold_running 30_servicemanager_running 31_hwservicemanager_running 35_keystore2_running 40_zygote_running 41_surfaceflinger_running 42_bootanim_running 99_boot_completed"
SEC_MARKERS=""
while IFS= read -r SVC; do
  [ -n "$SVC" ] || continue
  SAFE="$(printf '%s' "$SVC" | sed 's/[^A-Za-z0-9_.-]/_/g')"
  SEC_MARKERS="$SEC_MARKERS 50_svc_$SAFE"
done < "$TMP/secure_services.txt"

cat > "$OUT/FLASH_AND_BOOT_C1_DIAG.bat" <<EOF
@echo off
setlocal EnableExtensions EnableDelayedExpansion
cd /d "%~dp0"
set SERIAL=C121X44260991
set SUPER=super_C1_DIAG.img
set EXPECTED=$SHA

echo === TICWATCH C1 DIAG - DIRECT PC USB ===
where adb >nul 2>nul || (echo ERROR: adb non trovato nel PATH & pause & exit /b 1)
if not exist "%SUPER%" (echo ERROR: %SUPER% non trovato & pause & exit /b 1)

for /f "tokens=1" %%A in ('adb -s %SERIAL% get-state 2^>nul') do set STATE=%%A
if /I not "!STATE!"=="device" if /I not "!STATE!"=="recovery" (
  echo ERROR: watch non visto da ADB. Stato=!STATE!
  pause
  exit /b 1
)

for /f "delims=" %%A in ('adb -s %SERIAL% shell getprop ro.product.device 2^>nul') do set PRODUCT=%%A
if /I not "!PRODUCT!"=="dace" (
  echo ERROR: device=!PRODUCT! atteso dace
  pause
  exit /b 1
)

echo [1/4] Preparo marker persistenti...
adb -s %SERIAL% shell "rm -rf $META; mkdir -p $META; chmod 0700 $META; for d in $CORE_MARKERS$SEC_MARKERS; do mkdir -p $META/\$d; chmod 0700 $META/\$d; chcon u:object_r:vendor_data_file:s0 $META/\$d 2>/dev/null || true; done; chcon u:object_r:vendor_data_file:s0 /metadata/diag 2>/dev/null || true; chcon u:object_r:vendor_data_file:s0 $META 2>/dev/null || true; sync" || goto :fail
adb -s %SERIAL% shell "ls -Zd $META" | findstr /C:"vendor_data_file" >nul || (echo ERROR: label marker non corretto & goto :fail)

echo [2/4] Flash diretto USB 4GiB...
adb -s %SERIAL% exec-in "dd of=/dev/block/mmcblk0p7 bs=4194304 conv=fsync 2>/dev/null" < "%SUPER%" || goto :fail

echo [3/4] Verifica SHA256 completa...
for /f "tokens=1" %%H in ('adb -s %SERIAL% shell "sha256sum /dev/block/mmcblk0p7"') do set REMOTE=%%H
echo Expected: %EXPECTED%
echo Remote  : !REMOTE!
if /I not "!REMOTE!"=="%EXPECTED%" (
  echo ERROR: SHA256 NON coincide. NON RIAVVIO.
  pause
  exit /b 1
)

echo [4/4] PASS - riavvio diagnostico...
adb -s %SERIAL% shell sync
adb -s %SERIAL% reboot
echo.
echo FLASH+VERIFY+REBOOT=PASS
pause
exit /b 0

:fail
echo.
echo OPERAZIONE INTERROTTA. NON RIAVVIARE.
pause
exit /b 1
EOF

cat > "$OUT/READ_MARKERS_PC.bat" <<EOF
@echo off
setlocal
set SERIAL=C121X44260991
set META=$META
echo === WEAR5 DIAG MARKERS ===
adb -s %SERIAL% shell "for d in \$(ls -1 %META% 2>/dev/null); do m=\$(stat -c %%a %META%/\$d 2>/dev/null); echo \$d=\$m; done"
pause
EOF

cat > "$OUT/README_PC.txt" <<EOF
WEAR5 Candidate 1 diagnostic package
====================================
1) Copy this ENTIRE folder to the PC by USB/MTP.
2) Keep TicWatch in recovery and connected directly to PC by USB.
3) Run FLASH_AND_BOOT_C1_DIAG.bat from CMD/double-click.
4) If boot stalls, return to recovery and run READ_MARKERS_PC.bat.

Expected super SHA256:
$SHA

This package flashes ONLY super. It does not touch recovery, boot, init_boot, vbmeta or vbmeta_system.
EOF

echo "[4/4] DONE"
echo "BUILD=PASS"
echo "OUTPUT=$OUT"
echo "SUPER_SHA256=$SHA"
echo "PC_SCRIPT=$OUT/FLASH_AND_BOOT_C1_DIAG.bat"
echo "READ_SCRIPT=$OUT/READ_MARKERS_PC.bat"
echo "WATCH_TOUCHED=NO"
