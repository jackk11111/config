#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail

ADB_HOST="10.82.56.57"
ADB_PORT="5037"
TARGET="${1:-C121X44260991}"
META="/metadata/vold/wear5diag"
ADB=(adb -H "$ADB_HOST" -P "$ADB_PORT" -s "$TARGET")

STATE="$(adb -H "$ADB_HOST" -P "$ADB_PORT" devices 2>/dev/null | awk -v s="$TARGET" '$1==s{print $2; exit}')"
case "$STATE" in recovery|device|rescue) ;; *) echo "BLOCKER=adb_state_${STATE:-vuoto}"; exit 2;; esac

echo "ADB_STATE=$STATE"
[ "$("${ADB[@]}" shell "[ -d '$META' ]; echo $?" 2>/dev/null | tr -d '\r' | tail -1)" = "0" ] || { echo "BLOCKER=marker_dir_missing"; exit 2; }

LABEL="$("${ADB[@]}" shell "ls -Zd '$META' 2>/dev/null" | tr -d '\r')"
echo "MARKER_LABEL=$LABEL"
LABEL_OK=NO
printf '%s\n' "$LABEL" | grep -q 'vold_metadata_file' && LABEL_OK=YES
echo "LABEL_OK=$LABEL_OK"

CORE=(
  01_early_init
  02_init
  03_late_init
  04_fs
  05_post_fs
  06_late_fs
  07_post_fs_data
  08_early_boot
  09_boot
  10_apexd_running
  20_vold_running
  30_servicemanager_running
  31_hwservicemanager_running
  35_keystore2_running
  40_zygote_running
  41_surfaceflinger_running
  42_bootanim_running
  99_boot_completed
)

echo "=== CORE MARKERS ==="
REACHED=0
FIRST_NOT=""
LAST=""
for M in "${CORE[@]}"; do
  MODE="$("${ADB[@]}" shell "stat -c %a '$META/$M' 2>/dev/null" | tr -d '\r' | tail -1)"
  [ -n "$MODE" ] || MODE=MISSING
  case "$MODE" in
    777) STATUS=REACHED; REACHED=$((REACHED+1)); LAST="$M" ;;
    700) STATUS=NOT_REACHED; [ -n "$FIRST_NOT" ] || FIRST_NOT="$M" ;;
    *) STATUS=UNKNOWN ;;
  esac
  echo "$M=$MODE:$STATUS"
done

echo "=== QSEE / KEYMASTER / KEYMINT MARKERS ==="
"${ADB[@]}" shell "for d in '$META'/50_svc_*; do [ -d \"$d\" ] || continue; printf '%s=' \"$(basename \"$d\")\"; stat -c %a \"$d\" 2>/dev/null; done" 2>/dev/null | tr -d '\r' || true

echo "CORE_REACHED=$REACHED"
echo "CORE_LAST_REACHED=${LAST:-NONE}"
echo "CORE_FIRST_NOT_REACHED=${FIRST_NOT:-NONE}"

if [ "$LABEL_OK" != YES ]; then
  echo "FINDING=MARKER_LABEL_INVALID_RESULT_UNTRUSTWORTHY"
elif [ "$REACHED" -eq 0 ]; then
  echo "FINDING=NO_MARKER_REACHED_EARLY_INIT_NOT_PROVEN"
elif [ "$LAST" = "99_boot_completed" ]; then
  echo "FINDING=ANDROID_BOOT_COMPLETED"
elif [ "$LAST" = "42_bootanim_running" ]; then
  echo "FINDING=BOOTANIM_REACHED_BEFORE_BOOT_COMPLETE"
elif [ "$LAST" = "41_surfaceflinger_running" ]; then
  echo "FINDING=SURFACEFLINGER_REACHED_BEFORE_BOOTANIM"
elif [ "$LAST" = "40_zygote_running" ]; then
  echo "FINDING=ZYGOTE_REACHED_BEFORE_SURFACEFLINGER"
elif [ "$LAST" = "35_keystore2_running" ]; then
  echo "FINDING=KEYSTORE2_REACHED_BEFORE_ZYGOTE"
elif [ "$LAST" = "31_hwservicemanager_running" ] || [ "$LAST" = "30_servicemanager_running" ]; then
  echo "FINDING=NATIVE_SERVICE_MANAGERS_REACHED"
elif [ "$LAST" = "20_vold_running" ]; then
  echo "FINDING=VOLD_REACHED_BEFORE_SERVICE_MANAGERS"
elif [ "$LAST" = "10_apexd_running" ]; then
  echo "FINDING=APEXD_REACHED_BEFORE_VOLD"
else
  echo "FINDING=SECOND_STAGE_INIT_PROGRESS_LOCALIZED"
fi
