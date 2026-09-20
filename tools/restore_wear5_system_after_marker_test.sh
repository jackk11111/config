#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail

WORK="$HOME/WEAR5"
BASE="$WORK/xiaomi/system.img"
STOCK_SYS="$WORK/stock/system.img"
BUILD="/storage/emulated/0/Download/WEAR5_CANDIDATE2_SYSTEM_ONLY"
SUPER_IMG="$BUILD/images/super.img"
TMP="$WORK/WEAR5_MARKER_RESTORE"
REMOTE="/cache/wear5_marker_restore"
ADB_HOST="10.82.56.57"
ADB_PORT="5037"
TARGET="${1:-C121X44260991}"
NAME="wear5restore_system"

die(){ echo; echo "BLOCKER=$*"; exit 2; }

for F in "$BASE" "$STOCK_SYS" "$SUPER_IMG"; do
  [ -f "$F" ] || die "file_mancante_$F"
done
for C in debugfs lpdump python sha256sum; do
  command -v "$C" >/dev/null 2>&1 || die "tool_mancante_$C"
done

rm -rf "$TMP"
mkdir -p "$TMP/revert"

# Recreate exactly the same local diagnostic modification only to discover
# which 4K blocks were changed. Then extract ORIGINAL bytes from Xiaomi base.
cp --reflink=auto --sparse=always "$BASE" "$TMP/system.patched.img"

cat > "$TMP/wear5diag.rc" <<'EOF'
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
# WEAR5-DIAG-MARKERS-END
EOF
chmod 0644 "$TMP/wear5diag.rc"

# Discover whether the actual installed marker file exists locally in the prior tool dir.
# If available, use it so secure-service dynamic additions are reproduced exactly.
if [ -f "$WORK/WEAR5_MARKER_RAWPATCH/wear5diag.rc" ]; then
  cp -f "$WORK/WEAR5_MARKER_RAWPATCH/wear5diag.rc" "$TMP/wear5diag.rc"
fi

debugfs -w -R "write $TMP/wear5diag.rc /system/etc/init/wear5diag.rc" "$TMP/system.patched.img" >/dev/null 2>&1   || die "debugfs_write_rc_fallito"
debugfs -R "ea_get -f $TMP/selinux.xattr /system/etc/init/hw/init.rc security.selinux" "$TMP/system.patched.img" >/dev/null 2>&1   || die "lettura_selinux_xattr_fallita"
debugfs -w -R "ea_set -f $TMP/selinux.xattr /system/etc/init/wear5diag.rc security.selinux" "$TMP/system.patched.img" >/dev/null 2>&1   || die "scrittura_selinux_xattr_fallita"

python - "$BASE" "$TMP/system.patched.img" "$TMP/revert" "$TMP/revert.tsv" <<'PY'
import hashlib, os, sys
base, patched, outdir, manifest = sys.argv[1:]
BS=4096
runs=[]
with open(base,'rb') as a, open(patched,'rb') as b:
    idx=0; start=None; orig=[]
    while True:
        x=a.read(BS); y=b.read(BS)
        if not x and not y: break
        if x!=y:
            if start is None:
                start=idx; orig=[]
            orig.append(x)
        elif start is not None:
            runs.append((start,orig)); start=None; orig=[]
        idx+=1
    if start is not None: runs.append((start,orig))
if not runs: raise SystemExit("NO_DIFF_RUNS")
total=0
with open(manifest,'w') as m:
    for n,(start,chunks) in enumerate(runs):
        data=b''.join(chunks); total += len(data)
        p=os.path.join(outdir,f"restore_{n:03d}.bin")
        open(p,'wb').write(data)
        m.write(f"{start}\t{len(chunks)}\t{p}\t{hashlib.sha256(data).hexdigest()}\n")
print(f"RESTORE_RUNS={len(runs)}")
print(f"RESTORE_BYTES={total}")
PY

BASE_SHA="$(sha256sum "$BASE" | awk '{print $1}')"
BASE_SIZE="$(stat -c %s "$BASE")"
echo "BASE_SYSTEM_SIZE=$BASE_SIZE"
echo "BASE_SYSTEM_SHA256=$BASE_SHA"

# Parse system extents from Candidate 2 super.
lpdump "$SUPER_IMG" > "$TMP/lpdump.txt" 2>/dev/null || die "lpdump_fallito"
python - "$TMP/lpdump.txt" "$TMP/system.extents" <<'PY'
import re,sys
src,dst=sys.argv[1:3]
cur=None; rows=[]
for raw in open(src,encoding="utf-8",errors="ignore"):
    s=raw.rstrip("\n")
    m=re.match(r"\s*Name:\s+(\S+)\s*$",s)
    if m: cur=m.group(1); continue
    m=re.match(r"\s*(\d+)\s+\.\.\s+(\d+)\s+linear\s+(\S+)\s+(\d+)\s*$",s)
    if m and cur=="system":
        lo,hi,dev,phys=m.groups(); lo=int(lo); hi=int(hi); phys=int(phys)
        rows.append((lo,hi-lo+1,phys))
if not rows: raise SystemExit("NO_SYSTEM_EXTENTS")
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
while read -r LOG NUM PHYS; do ARGS="$ARGS linear $LOG $NUM '$SUPER_DEV' $PHYS"; done < "$TMP/system.extents"
"${ADB[@]}" shell "$RUNNER delete '$NAME' >/dev/null 2>&1 || true" >/dev/null 2>&1 || true
"${ADB[@]}" shell "$RUNNER create '$NAME' $ARGS" >/dev/null || die "dm_create_fallito"
DEV="$("${ADB[@]}" shell "$RUNNER getpath '$NAME'" 2>/dev/null | tr -d '\r' | tail -1)"
[ -n "$DEV" ] || die "dm_getpath_fallito"

cleanup(){
  "${ADB[@]}" shell "umount /mnt/wear5restore_verify >/dev/null 2>&1 || true; $RUNNER delete '$NAME' >/dev/null 2>&1 || true" >/dev/null 2>&1 || true
}
trap cleanup EXIT

DEV_SIZE="$("${ADB[@]}" shell "blockdev --getsize64 '$DEV' 2>/dev/null" | tr -d '\r' | tail -1)"
[ "$DEV_SIZE" = "$BASE_SIZE" ] || die "logical_system_size_$DEV_SIZE_atteso_$BASE_SIZE"

echo "RESTORE_RAW=START"
mapfile -t ROWS < "$TMP/revert.tsv"
APPLIED=0
for ROW in "${ROWS[@]}"; do
  IFS=$'\t' read -r START BLOCKS FILE HASH <<<"$ROW"
  BN="$(basename "$FILE")"
  "${ADB[@]}" push "$FILE" "$REMOTE/$BN" </dev/null >/dev/null || die "push_$BN"
  RH="$("${ADB[@]}" shell "sha256sum '$REMOTE/$BN' 2>/dev/null" </dev/null | tr -d '\r' | awk '{print $1}' | tail -1)"
  [ "$RH" = "$HASH" ] || die "stage_hash_$BN"
  "${ADB[@]}" shell "dd if='$REMOTE/$BN' of='$DEV' bs=4096 seek='$START' count='$BLOCKS' conv=notrunc,fsync 2>/dev/null" </dev/null     || die "restore_dd_$BN"
  VH="$("${ADB[@]}" shell "dd if='$DEV' bs=4096 skip='$START' count='$BLOCKS' 2>/dev/null | sha256sum" </dev/null | tr -d '\r' | awk '{print $1}' | tail -1)"
  [ "$VH" = "$HASH" ] || die "restore_readback_$BN"
  APPLIED=$((APPLIED+1))
  echo "RESTORE_APPLIED=$APPLIED/${#ROWS[@]}:$BN"
done
"${ADB[@]}" shell sync </dev/null >/dev/null 2>&1 || die "sync_fallito"

# Exact whole-logical-partition proof that Candidate 2 system is back to pristine Xiaomi image.
echo "VERIFYING=full_logical_system_sha256"
REMOTE_SHA="$("${ADB[@]}" shell "sha256sum '$DEV' 2>/dev/null" </dev/null | tr -d '\r' | awk '{print $1}' | tail -1)"
[ "$REMOTE_SHA" = "$BASE_SHA" ] || die "remote_system_sha_$REMOTE_SHA"

# Read-only mount sanity.
"${ADB[@]}" shell "mkdir -p /mnt/wear5restore_verify; mount -t ext4 -o ro,noload '$DEV' /mnt/wear5restore_verify" >/dev/null   || die "verify_mount_ro_fallito"
ROOT=""
for R in /mnt/wear5restore_verify/system /mnt/wear5restore_verify; do
  if "${ADB[@]}" shell "[ -x '$R/bin/init' ]" >/dev/null 2>&1; then ROOT="$R"; break; fi
done
[ -n "$ROOT" ] || die "system_init_non_visibile"
if "${ADB[@]}" shell "[ -e '$ROOT/etc/init/wear5diag.rc' ]" >/dev/null 2>&1; then
  die "wear5diag_rc_ancora_presente"
fi
"${ADB[@]}" shell "umount /mnt/wear5restore_verify" >/dev/null 2>&1 || true
cleanup
trap - EXIT

echo "RESTORE=PASS"
echo "SYSTEM_SHA256=$REMOTE_SHA"
echo "MATCHES_PRISTINE_XIAOMI_SYSTEM=YES"
echo "MARKER_RC_PRESENT=NO"
echo "SUPER_OTHER_PARTITIONS_UNCHANGED=YES"
echo "RECOVERY_TOUCHED=NO"
echo "NEXT=boot_candidate2_without_markers"
