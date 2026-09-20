#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail

WORK="$HOME/WEAR5"
BUILD="/storage/emulated/0/Download/WEAR5_CANDIDATE2_SYSTEM_ONLY"
SUPER_IMG="$BUILD/images/super.img"
STOCK_SYS="$WORK/stock/system.img"
STOCK_VENDOR="$WORK/stock/vendor.img"
ADB_HOST="10.82.56.57"
ADB_PORT="5037"
TARGET="${1:-C121X44260991}"
TMP="$WORK/WEAR5_MARKER_TOOL"
REMOTE="/cache/wear5_marker_tool"
NAME="wear5diag_system"
META="/metadata/vold/wear5diag"

die(){ echo; echo "BLOCKER=$*"; exit 2; }

for F in "$SUPER_IMG" "$STOCK_SYS" "$STOCK_VENDOR"; do
  [ -f "$F" ] || die "file_mancante_$F"
done
command -v lpdump >/dev/null 2>&1 || die "lpdump_termux_mancante"
command -v debugfs >/dev/null 2>&1 || die "debugfs_termux_mancante"

rm -rf "$TMP"
mkdir -p "$TMP/vendor_init"
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
    for r in rows:
        f.write("%d %d %d\n"%r)
PY

DMCTL="$TMP/dmctl"
debugfs -R "dump /bin/dmctl $DMCTL" "$STOCK_SYS" >/dev/null 2>&1 || die "dmctl_non_estratto"
chmod 755 "$DMCTL"

# Discover the actual Qualcomm secure-world/key services from TicWatch vendor init.
debugfs -R "rdump /etc/init $TMP/vendor_init" "$STOCK_VENDOR" >/dev/null 2>&1 || true
grep -RhsE '^[[:space:]]*service[[:space:]]+' "$TMP/vendor_init" 2>/dev/null   | awk '{print $2}'   | grep -Ei 'qsee|keymaster|keymint'   | sort -u > "$TMP/secure_services.txt" || true

ADB=(adb -H "$ADB_HOST" -P "$ADB_PORT" -s "$TARGET")
STATE="$(adb -H "$ADB_HOST" -P "$ADB_PORT" devices 2>/dev/null | awk -v s="$TARGET" '$1==s{print $2; exit}')"
case "$STATE" in recovery|device|rescue) ;; *) die "adb_state_${STATE:-vuoto}";; esac
PRODUCT="$("${ADB[@]}" shell getprop ro.product.device 2>/dev/null | tr -d '\r' | tail -1)"
[ "$PRODUCT" = "dace" ] || die "device_${PRODUCT:-vuoto}"
UIDR="$("${ADB[@]}" shell id -u 2>/dev/null | tr -d '\r' | tail -1)"
[ "$UIDR" = "0" ] || die "adb_non_root_uid_${UIDR:-vuoto}"

SUPER_DEV="$("${ADB[@]}" shell 'readlink -f /dev/block/by-name/super 2>/dev/null' | tr -d '\r' | tail -1)"
VBMETA_DEV="$("${ADB[@]}" shell 'readlink -f /dev/block/by-name/vbmeta 2>/dev/null' | tr -d '\r' | tail -1)"
VBMETA_SYS_DEV="$("${ADB[@]}" shell 'readlink -f /dev/block/by-name/vbmeta_system 2>/dev/null' | tr -d '\r' | tail -1)"
[ -n "$SUPER_DEV" ] || die "super_device_non_trovato"
[ -n "$VBMETA_DEV" ] || die "vbmeta_device_non_trovato"
[ -n "$VBMETA_SYS_DEV" ] || die "vbmeta_system_device_non_trovato"

# AVB safety: top-level flags must be 0x00000003; chained vbmeta_system must stay 0.
TOP_FLAGS="$("${ADB[@]}" shell "dd if='$VBMETA_DEV' bs=1 skip=120 count=4 2>/dev/null | od -An -tx1" | tr -d ' \r\n')"
CHAIN_FLAGS="$("${ADB[@]}" shell "dd if='$VBMETA_SYS_DEV' bs=1 skip=120 count=4 2>/dev/null | od -An -tx1" | tr -d ' \r\n')"
[ "$TOP_FLAGS" = "00000003" ] || die "top_vbmeta_flags_$TOP_FLAGS_atteso_00000003"
[ "$CHAIN_FLAGS" = "00000000" ] || die "vbmeta_system_flags_$CHAIN_FLAGS_atteso_00000000"

# DIAG2-style persistent sentinels: pre-create directories under vold and verify SELinux label.
"${ADB[@]}" shell "[ -d /metadata/vold ]" >/dev/null 2>&1 || die "metadata_vold_non_esiste"
PARENT_Z="$("${ADB[@]}" shell "ls -Zd /metadata/vold 2>/dev/null" | tr -d '\r')"
printf '%s\n' "$PARENT_Z" | grep -q 'vold_metadata_file' || die "metadata_vold_label_non_corretto"

CORE_MARKERS=(
  01_early_init
  02_init
  03_late_init
  04_fs
  05_post_fs
  06_late_fs
  07_post_fs_data
  08_early_boot
  09_boot
  20_vold_running
  30_servicemanager_running
  31_hwservicemanager_running
  40_zygote_running
  41_surfaceflinger_running
  99_boot_completed
)

"${ADB[@]}" shell "rm -rf '$META'; mkdir -p '$META'; chmod 0700 '$META'" >/dev/null || die "creazione_metadata_markers_fallita"

MARKERS=("${CORE_MARKERS[@]}")
while IFS= read -r SVC; do
  [ -n "$SVC" ] || continue
  SAFE="$(printf '%s' "$SVC" | sed 's/[^A-Za-z0-9_.-]/_/g')"
  MARKERS+=("50_svc_$SAFE")
done < "$TMP/secure_services.txt"

for M in "${MARKERS[@]}"; do
  "${ADB[@]}" shell "mkdir -p '$META/$M'; chmod 0700 '$META/$M'" >/dev/null || die "marker_create_$M"
done

# If recovery creation did not inherit the proven vold label, try copying the parent's label.
BAD=0
for M in "__BASE__" "${MARKERS[@]}"; do
  [ "$M" = "__BASE__" ] && P="$META" || P="$META/$M"
  Z="$("${ADB[@]}" shell "ls -Zd '$P' 2>/dev/null" | tr -d '\r')"
  if ! printf '%s\n' "$Z" | grep -q 'vold_metadata_file'; then
    if "${ADB[@]}" shell 'command -v chcon >/dev/null 2>&1'; then
      "${ADB[@]}" shell "chcon u:object_r:vold_metadata_file:s0 '$P'" >/dev/null 2>&1 || true
      Z="$("${ADB[@]}" shell "ls -Zd '$P' 2>/dev/null" | tr -d '\r')"
    fi
  fi
  printf '%s\n' "$Z" | grep -q 'vold_metadata_file' || BAD=$((BAD+1))
done
[ "$BAD" -eq 0 ] || die "marker_selinux_label_non_corretto_count_$BAD"

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
cleanup(){
  "${ADB[@]}" shell "umount '$MNT' >/dev/null 2>&1 || true; $RUNNER delete '$NAME' >/dev/null 2>&1 || true" >/dev/null 2>&1 || true
}
trap cleanup EXIT

"${ADB[@]}" shell "mkdir -p '$MNT'; umount '$MNT' >/dev/null 2>&1 || true" >/dev/null 2>&1 || true
"${ADB[@]}" shell "mount -t ext4 -o rw '$DEV' '$MNT'" >/dev/null || die "system_mount_rw_fallito"

ROOT=""
for R in "$MNT/system" "$MNT"; do
  if "${ADB[@]}" shell "[ -f '$R/etc/init/hw/init.rc' ]" >/dev/null 2>&1; then ROOT="$R"; break; fi
done
[ -n "$ROOT" ] || die "init_rc_non_trovato"
RCFILE="$ROOT/etc/init/hw/init.rc"

if "${ADB[@]}" shell "grep -q 'WEAR5-DIAG-MARKERS-BEGIN' '$RCFILE'" >/dev/null 2>&1; then
  die "marker_block_gia_presente_rimuovere_prima"
fi

mkdir -p "$WORK/diag_backup"
"${ADB[@]}" pull "$RCFILE" "$WORK/diag_backup/init.rc.before_wear5_diag" >/dev/null || die "backup_init_rc_fallito"

cat > "$TMP/markers.rc" <<'EOF'
# WEAR5-DIAG-MARKERS-BEGIN
on early-init
    chmod 0777 /metadata/vold/wear5diag/01_early_init

on init
    chmod 0777 /metadata/vold/wear5diag/02_init

on late-init
    chmod 0777 /metadata/vold/wear5diag/03_late_init

on fs
    chmod 0777 /metadata/vold/wear5diag/04_fs

on post-fs
    chmod 0777 /metadata/vold/wear5diag/05_post_fs

on late-fs
    chmod 0777 /metadata/vold/wear5diag/06_late_fs

on post-fs-data
    chmod 0777 /metadata/vold/wear5diag/07_post_fs_data

on early-boot
    chmod 0777 /metadata/vold/wear5diag/08_early_boot

on boot
    chmod 0777 /metadata/vold/wear5diag/09_boot

on property:init.svc.vold=running
    chmod 0777 /metadata/vold/wear5diag/20_vold_running

on property:init.svc.servicemanager=running
    chmod 0777 /metadata/vold/wear5diag/30_servicemanager_running

on property:init.svc.hwservicemanager=running
    chmod 0777 /metadata/vold/wear5diag/31_hwservicemanager_running

on property:init.svc.zygote=running
    chmod 0777 /metadata/vold/wear5diag/40_zygote_running

on property:init.svc.surfaceflinger=running
    chmod 0777 /metadata/vold/wear5diag/41_surfaceflinger_running

on property:sys.boot_completed=1
    chmod 0777 /metadata/vold/wear5diag/99_boot_completed
EOF

while IFS= read -r SVC; do
  [ -n "$SVC" ] || continue
  SAFE="$(printf '%s' "$SVC" | sed 's/[^A-Za-z0-9_.-]/_/g')"
  {
    echo
    echo "on property:init.svc.$SVC=running"
    echo "    chmod 0777 /metadata/vold/wear5diag/50_svc_$SAFE"
  } >> "$TMP/markers.rc"
done < "$TMP/secure_services.txt"

cat >> "$TMP/markers.rc" <<'EOF'
# WEAR5-DIAG-MARKERS-END
EOF

"${ADB[@]}" push "$TMP/markers.rc" "$REMOTE/markers.rc" >/dev/null || die "push_markers_fallito"
"${ADB[@]}" shell "cat '$REMOTE/markers.rc' >> '$RCFILE'; sync" >/dev/null || die "append_markers_fallito"

# Confirm the block is physically readable from the modified system.
"${ADB[@]}" shell "grep -q 'WEAR5-DIAG-MARKERS-END' '$RCFILE'" >/dev/null || die "marker_verify_fallita"

cleanup
trap - EXIT

echo "MARKER_INSTALL=PASS"
echo "MARKER_METHOD=DIAG2_VOLD_CHMOD"
echo "VOLD_LABEL=VERIFIED"
echo "VBMETA_TOP_FLAGS=0x$TOP_FLAGS"
echo "VBMETA_SYSTEM_FLAGS=0x$CHAIN_FLAGS"
echo "SECURE_SERVICES=$(paste -sd, "$TMP/secure_services.txt" 2>/dev/null || true)"
echo "TARGET_FILE=$RCFILE"
echo "BACKUP_LOCAL=$WORK/diag_backup/init.rc.before_wear5_diag"
echo "METADATA_DIR=$META"
echo "RECOVERY_TOUCHED=NO"
echo "NEXT=reboot_normal_once_then_return_recovery_and_read_markers"
