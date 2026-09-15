#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

# Run on the PHONE in Termux after the first Wear7 boot.
# Usage: bash TERMUX-WEAR7-FIRSTBOOT-VERIFY.sh WATCH_IP[:PORT]
# All user-facing output stays in shared Download storage.

DEV="${1:-}"
if [ -z "$DEV" ]; then
  echo "Uso: bash $0 IP_OROLOGIO[:PORTA]"
  exit 2
fi
case "$DEV" in *:*) ;; *) DEV="$DEV:5555" ;; esac

BASE="/storage/emulated/0/Download/TicWatch_Wear7_FirstBoot_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BASE"
LOG="$BASE/FIRSTBOOT_AUDIT.txt"
exec > >(tee -a "$LOG") 2>&1

echo "DEVICE=$DEV"
echo "OUTPUT=$BASE"
command -v adb >/dev/null || { echo 'FAIL: adb non presente in Termux'; exit 3; }

adb start-server >/dev/null
adb connect "$DEV" || true
adb -s "$DEV" wait-for-device

echo '===== BASIC ====='
adb -s "$DEV" shell 'getprop ro.product.device; getprop ro.build.version.release; getprop ro.build.version.sdk; getprop ro.build.fingerprint; getprop sys.boot_completed'

echo '===== ADB TCP ====='
adb -s "$DEV" shell 'echo service.adb.tcp.port=$(getprop service.adb.tcp.port); echo persist.adb.tcp.port=$(getprop persist.adb.tcp.port); echo adb_tls=$(getprop persist.adb.tls_server.enable)'

echo '===== ROOT ====='
adb -s "$DEV" shell 'id; su -c id; su -c "uname -a"'

echo '===== KERNELSU ====='
adb -s "$DEV" shell 'su -c "command -v ksud 2>/dev/null || true; /data/adb/ksu/bin/ksud -V 2>/dev/null || /data/adb/ksud -V 2>/dev/null || true"'

echo '===== INSTALL/REFRESH ROM WIRELESS PERSISTENCE SERVICE ====='
adb -s "$DEV" shell 'su -c "
set -e
SRC=/system_ext/etc/wear7/96-wifi-adb-persistent.sh
DST=/data/adb/service.d/96-wifi-adb-persistent.sh
test -f \$SRC
mkdir -p /data/adb/service.d
cp -f \$SRC \$DST
chown root:root \$DST
chmod 0755 \$DST
restorecon \$DST 2>/dev/null || true
sha256sum \$SRC \$DST
settings put global adb_enabled 1 || true
settings put global adb_wifi_enabled 1 || true
settings put global wifi_sleep_policy 2 || true
settings put global wifi_wakeup_enabled 1 || true
settings put global cw_disable_wifimediator 1 || true
settings put system clockwork_wifi_setting on || true
svc wifi enable || true
setprop persist.adb.tcp.port 5555
setprop service.adb.tcp.port 5555
setprop persist.adb.tls_server.enable 1
"'

echo '===== NETWORK ====='
adb -s "$DEV" shell 'su -c "ip -br addr show wlan0 2>/dev/null || ip addr show wlan0; dumpsys wifi | head -n 120"' || true

echo '===== PAIRING/SETUP PACKAGES ====='
adb -s "$DEV" shell 'pm list packages | grep -E "mobvoi|wearable.setupwizard|pixelwatch|wearable" | sort' || true
adb -s "$DEV" shell 'dumpsys package com.mobvoi.companion.aw 2>/dev/null | grep -E "Package \[|versionName|enabled=" | head -n 30' || true
adb -s "$DEV" shell 'dumpsys package com.google.android.wearable.setupwizard 2>/dev/null | grep -E "Package \[|versionName|enabled=" | head -n 30' || true

echo '===== SERVICES / HARDWARE QUICK ====='
adb -s "$DEV" shell 'su -c "service list | grep -Ei \"bluetooth|wifi|nfc|sensor|audio\" | head -n 100"' || true
adb -s "$DEV" shell 'getprop | grep -Ei "vendor|hardware|bluetooth|wifi|nfc|audio|sensor" | head -n 220' || true

echo '===== SELINUX ====='
adb -s "$DEV" shell 'getenforce; su -c "dmesg | grep -i avc | tail -n 120"' || true

echo '===== WIRELESS BOOTSTRAP LOG ====='
adb -s "$DEV" shell 'su -c "cat /data/local/tmp/wear7_dace_wireless.log 2>/dev/null || true; ls -laZ /data/adb/service.d/96-wifi-adb-persistent.sh 2>/dev/null || true"'

echo '===== FINAL ====='
BOOT=$(adb -s "$DEV" shell getprop sys.boot_completed | tr -d '\r')
ROOT=$(adb -s "$DEV" shell 'su -c id' 2>/dev/null | tr -d '\r' || true)
PORT=$(adb -s "$DEV" shell getprop service.adb.tcp.port | tr -d '\r')
[ "$BOOT" = 1 ] || { echo "FAIL_BOOT_COMPLETED=$BOOT"; exit 20; }
echo "$ROOT" | grep -q 'uid=0' || { echo "FAIL_ROOT=$ROOT"; exit 21; }
[ "$PORT" = 5555 ] || { echo "FAIL_ADB_TCP_PORT=$PORT"; exit 22; }

echo 'WEAR7_BOOT=PASS'
echo 'WEAR7_ROOT=PASS'
echo 'WEAR7_ADB_TCP_5555=PASS'
echo "LOG=$LOG"
