#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail

WORK="$HOME/WEAR5"
BUILD="/storage/emulated/0/Download/WEAR5_CANDIDATE2_SYSTEM_ONLY"
SUPER_IMG="$BUILD/images/super.img"
STOCK_SYS="$WORK/stock/system.img"
ADB_HOST="10.82.56.57"
ADB_PORT="5037"
TARGET="${1:-C121X44260991}"
TMP="$WORK/WEAR5_MARKER_TOOL"
REMOTE="/cache/wear5_marker_tool"
NAME="wear5diag_system"
META="/metadata/wear5-diag"

die(){ echo; echo "BLOCKER=$*"; exit 2; }

[ -f "$SUPER_IMG" ] || die "candidate2_super_mancante"
[ -f "$STOCK_SYS" ] || die "stock_system_mancante"
command -v lpdump >/dev/null 2>&1 || die "lpdump_termux_mancante"
command -v debugfs >/dev/null 2>&1 || die "debugfs_termux_mancante"

rm -rf "$TMP"; mkdir -p "$TMP"
lpdump "$SUPER_IMG" > "$TMP/lpdump.txt" 2>/dev/null || die "lpdump_fallito"

python - "$TMP/lpdump.txt" "$TMP/system.extents" <<'PY'
import re,sys
src,dst=sys.argv[1:3]
cur=None; rows=[]
for raw in open(src,encoding="utf-8",errors="ignore"):
    s=raw.rstrip("\n")
    m=re.match(r"\s*Name:\s+(\S+)\s*$",s)
    if m:
        cur=m.group(1); continue
    m=re.match(r"\s*(\d+)\s+\.\.\s+(\d+)\s+linear\s+(\S+)\s+(\d+)\s*$",s)
    if m and cur=="system":
        lo,hi,dev,phys=m.groups()
        lo=int(lo); hi=int(hi); phys=int(phys)
        rows.append((lo,hi-lo+1,phys))
if not rows:
    raise SystemExit("NO_SYSTEM_EXTENTS")
with open(dst,"w") as f:
    for r in rows: f.write("%d %d %d\n"%r)
PY

DMCTL="$TMP/dmctl"
debugfs -R "dump /bin/dmctl $DMCTL" "$STOCK_SYS" >/dev/null 2>&1 || die "dmctl_non_estratto"
chmod 755 "$DMCTL"

ADB=(adb -H "$ADB_HOST" -P "$ADB_PORT" -s "$TARGET")
STATE="$(adb -H "$ADB_HOST" -P "$ADB_PORT" devices 2>/dev/null | awk -v s="$TARGET" '$1==s{print $2; exit}')"
case "$STATE" in recovery|device|rescue) ;; *) die "adb_state_${STATE:-vuoto}";; esac
PRODUCT="$("${ADB[@]}" shell getprop ro.product.device 2>/dev/null | tr -d '\r' | tail -1)"
[ "$PRODUCT" = "dace" ] || die "device_${PRODUCT:-vuoto}"
UIDR="$("${ADB[@]}" shell id -u 2>/dev/null | tr -d '\r' | tail -1)"
[ "$UIDR" = "0" ] || die "adb_non_root_uid_${UIDR:-vuoto}"
SUPER_DEV="$("${ADB[@]}" shell 'readlink -f /dev/block/by-name/super 2>/dev/null' | tr -d '\r' | tail -1)"
[ -n "$SUPER_DEV" ] || die "super_device_non_trovato"

"${ADB[@]}" shell "rm -rf '$REMOTE'; mkdir -p '$REMOTE'" >/dev/null
"${ADB[@]}" push "$DMCTL" "$REMOTE/dmctl" >/dev/null
"${ADB[@]}" shell "chmod 755 '$REMOTE/dmctl'" >/dev/null

RUNNER=""
for L in /system/bin/linker /system/bin/bootstrap/linker /apex/com.android.runtime/bin/linker; do
  if "${ADB[@]}" shell "[ -x '$L' ]" >/dev/null 2>&1; then
    P="$("${ADB[@]}" shell "'$L' '$REMOTE/dmctl' help" 2>&1 || true)"
    if printf '%s\n' "$P" | grep -qi dmctl; then RUNNER="'$L' '$REMOTE/dmctl'"; break; fi
  fi
done
[ -n "$RUNNER" ] || die "dmctl_non_eseguibile"

ARGS=""
while read -r LOG NUM PHYS; do
  ARGS="$ARGS linear $LOG $NUM '$SUPER_DEV' $PHYS"
done < "$TMP/system.extents"

"${ADB[@]}" shell "$RUNNER delete '$NAME' >/dev/null 2>&1 || true" >/dev/null 2>&1 || true
"${ADB[@]}" shell "$RUNNER create '$NAME' $ARGS" >/dev/null || die "dm_create_fallito"
DEV="$("${ADB[@]}" shell "$RUNNER getpath '$NAME'" 2>/dev/null | tr -d '\r' | tail -1)"
[ -n "$DEV" ] || die "dm_getpath_fallito"

MNT="/mnt/$NAME"
"${ADB[@]}" shell "mkdir -p '$MNT'; umount '$MNT' >/dev/null 2>&1 || true" >/dev/null 2>&1 || true
"${ADB[@]}" shell "mount -t ext4 -o rw '$DEV' '$MNT'" >/dev/null || {
  "${ADB[@]}" shell "$RUNNER delete '$NAME' >/dev/null 2>&1 || true" >/dev/null 2>&1 || true
  die "system_mount_rw_fallito"
}

ROOT=""
for R in "$MNT/system" "$MNT"; do
  if "${ADB[@]}" shell "[ -f '$R/etc/init/hw/init.rc' ]" >/dev/null 2>&1; then ROOT="$R"; break; fi
done
[ -n "$ROOT" ] || die "init_rc_non_trovato"
RCFILE="$ROOT/etc/init/hw/init.rc"

if "${ADB[@]}" shell "grep -q 'WEAR5-DIAG-MARKERS-BEGIN' '$RCFILE'" >/dev/null 2>&1; then
  echo "MARKERS_ALREADY_INSTALLED=YES"
else
  mkdir -p "$WORK/diag_backup"
  "${ADB[@]}" pull "$RCFILE" "$WORK/diag_backup/init.rc.before_wear5_diag" >/dev/null || die "backup_init_rc_fallito"

  cat > "$TMP/markers.rc" <<'EOF'
# WEAR5-DIAG-MARKERS-BEGIN
on early-init
    mkdir /metadata/wear5-diag 0771 root root
    write /metadata/wear5-diag/01_early_init reached

on init
    mkdir /metadata/wear5-diag 0771 root root
    write /metadata/wear5-diag/02_init reached

on late-init
    write /metadata/wear5-diag/03_late_init reached

on post-fs
    write /metadata/wear5-diag/04_post_fs reached

on post-fs-data
    write /metadata/wear5-diag/05_post_fs_data reached

on boot
    write /metadata/wear5-diag/06_boot_action reached

on property:init.svc.servicemanager=running
    write /metadata/wear5-diag/07_servicemanager reached

on property:init.svc.hwservicemanager=running
    write /metadata/wear5-diag/08_hwservicemanager reached

on property:init.svc.zygote=running
    write /metadata/wear5-diag/09_zygote reached

on property:init.svc.surfaceflinger=running
    write /metadata/wear5-diag/10_surfaceflinger reached

on property:sys.boot_completed=1
    write /metadata/wear5-diag/11_boot_completed reached
# WEAR5-DIAG-MARKERS-END
EOF
  "${ADB[@]}" push "$TMP/markers.rc" "$REMOTE/markers.rc" >/dev/null || die "push_markers_fallito"
  "${ADB[@]}" shell "cat '$REMOTE/markers.rc' >> '$RCFILE'; sync" >/dev/null || die "append_markers_fallito"
fi

"${ADB[@]}" shell "mkdir -p '$META'; rm -f '$META'/*; sync" >/dev/null 2>&1 || true
"${ADB[@]}" shell "umount '$MNT'; $RUNNER delete '$NAME'; sync" >/dev/null 2>&1 || die "cleanup_fallito"

echo "MARKER_INSTALL=PASS"
echo "TARGET_FILE=$RCFILE"
echo "BACKUP_LOCAL=$WORK/diag_backup/init.rc.before_wear5_diag"
echo "METADATA_DIR=$META"
echo "RECOVERY_TOUCHED=NO"
echo "NEXT=reboot_normal_then_return_recovery_and_read_markers"
