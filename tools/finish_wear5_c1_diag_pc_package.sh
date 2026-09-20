#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail

OUT="/storage/emulated/0/Download/WEAR5_C1_DIAG_PC"
SUPER="$OUT/super_C1_DIAG.img"
META="/metadata/vold/wear5diag"

die(){ echo; echo "BLOCKER=$*"; exit 2; }

[ -f "$SUPER" ] || die "super_gia_costruito_non_trovato"
[ "$(stat -c %s "$SUPER")" = "4294967296" ] || die "super_size_errata"

SHA="$(sha256sum "$SUPER" | awk '{print $1}')"
printf '%s  %s\n' "$SHA" "$(basename "$SUPER")" > "$OUT/SHA256.txt"

[ -f "$OUT/secure_services.txt" ] || : > "$OUT/secure_services.txt"
CORE_MARKERS="01_early_init 02_init 03_late_init 04_fs 05_post_fs 06_late_fs 07_post_fs_data 08_early_boot 09_boot 10_apexd_running 20_vold_running 30_servicemanager_running 31_hwservicemanager_running 35_keystore2_running 40_zygote_running 41_surfaceflinger_running 42_bootanim_running 99_boot_completed"
SEC_MARKERS=""
while IFS= read -r SVC; do
  [ -n "$SVC" ] || continue
  SAFE="$(printf '%s' "$SVC" | sed 's/[^A-Za-z0-9_.-]/_/g')"
  SEC_MARKERS="$SEC_MARKERS 50_svc_$SAFE"
done < "$OUT/secure_services.txt"

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
adb -s %SERIAL% shell "rm -rf $META; mkdir -p $META; chmod 0700 $META; for d in $CORE_MARKERS$SEC_MARKERS; do mkdir -p $META/\$d; chmod 0700 $META/\$d; chcon u:object_r:vold_metadata_file:s0 $META/\$d 2>/dev/null || true; done; chcon u:object_r:vold_metadata_file:s0 $META 2>/dev/null || true; sync" || goto :fail
adb -s %SERIAL% shell "ls -Zd $META" | findstr /C:"vold_metadata_file" >nul || (echo ERROR: label marker non corretto & goto :fail)

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
The 4 GiB super image was already built successfully before packaging stopped.

1) Copy this ENTIRE folder to the PC by USB/MTP.
2) Keep TicWatch in recovery and connected DIRECTLY to PC by USB.
3) Run FLASH_AND_BOOT_C1_DIAG.bat.
4) The script flashes super once, verifies the FULL SHA256, and reboots only on exact match.
5) If boot stalls, return to recovery and run READ_MARKERS_PC.bat.

Expected super SHA256:
$SHA

Only super is flashed. recovery, boot, init_boot, vbmeta and vbmeta_system are untouched.
EOF

echo "PACKAGE_FINISH=PASS"
echo "REUSED_EXISTING_SUPER=YES"
echo "SUPER=$SUPER"
echo "SUPER_SHA256=$SHA"
echo "FLASH_SCRIPT=$OUT/FLASH_AND_BOOT_C1_DIAG.bat"
echo "READ_SCRIPT=$OUT/READ_MARKERS_PC.bat"
echo "WATCH_TOUCHED=NO"
