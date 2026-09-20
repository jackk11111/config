#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail
ADB_HOST="10.82.56.57"
ADB_PORT="5037"
TARGET="${1:-C121X44260991}"
ADB=(adb -H "$ADB_HOST" -P "$ADB_PORT" -s "$TARGET")

STATE="$(adb -H "$ADB_HOST" -P "$ADB_PORT" devices 2>/dev/null | awk -v s="$TARGET" '$1==s{print $2; exit}')"
case "$STATE" in recovery|device|rescue) ;; *) echo "BLOCKER=adb_state_${STATE:-vuoto}"; exit 2;; esac

echo "ADB_STATE=$STATE"
echo "=== WEAR5 PERSISTENT MARKERS ==="
OUT="$("${ADB[@]}" shell 'for f in /metadata/wear5-diag/*; do [ -f "$f" ] && echo "$(basename "$f")=$(cat "$f" 2>/dev/null)"; done' 2>/dev/null | tr -d '\r')"
if [ -z "$OUT" ]; then
  echo "MARKERS=NONE"
  echo "FINDING=FAILURE_BEFORE_SECOND_STAGE_EARLY_INIT_OR_METADATA_WRITE"
else
  printf '%s\n' "$OUT"
  LAST="$(printf '%s\n' "$OUT" | tail -1 | cut -d= -f1)"
  echo "LAST_MARKER=$LAST"
  case "$LAST" in
    11_boot_completed) echo "FINDING=ANDROID_BOOT_COMPLETED" ;;
    10_surfaceflinger) echo "FINDING=AFTER_SURFACEFLINGER_BEFORE_BOOT_COMPLETED" ;;
    09_zygote) echo "FINDING=AFTER_ZYGOTE_BEFORE_SURFACEFLINGER" ;;
    08_hwservicemanager|07_servicemanager) echo "FINDING=NATIVE_SERVICES_STAGE" ;;
    06_boot_action|05_post_fs_data|04_post_fs|03_late_init|02_init|01_early_init) echo "FINDING=SECOND_STAGE_INIT_REACHED" ;;
    *) echo "FINDING=MARKERS_PRESENT_NEEDS_REVIEW" ;;
  esac
fi
