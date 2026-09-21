#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail

WORK="$HOME/WEAR5"
BUILD="$WORK/C1_DIAG_PC_BUILD"
STOCK_SYS="$WORK/stock/system.img"
TMP="$WORK/VENDOR_NO_METADATA_ENCRYPTION"
REMOTE="/cache/wear5_no_metaenc"

ADB_HOST="10.82.56.57"
ADB_PORT="5037"
TARGET="${1:-C121X44260991}"
NAME="wear5_vendor_no_metaenc"
FSTABS=(/etc/fstab.dace /etc/fstab.qcom)

die(){ echo; echo "BLOCKER=$*"; exit 2; }

for C in debugfs python sha256sum timeout; do
  command -v "$C" >/dev/null 2>&1 || die "tool_mancante_$C"
done
[ -f "$STOCK_SYS" ] || die "stock_system_mancante"

rm -rf "$TMP"
mkdir -p "$TMP/patches"

ADB=(adb -H "$ADB_HOST" -P "$ADB_PORT" -s "$TARGET")

echo "[1/10] PRECHECK"
STATE="$(timeout 5s "${ADB[@]}" get-state </dev/null 2>/dev/null | tr -d '\r' | tail -1)" || die "adb_state_timeout"
[ "$STATE" = "recovery" ] || die "not_in_recovery_$STATE"
PRE="$(timeout 5s "${ADB[@]}" shell 'printf "DEVICE="; getprop ro.product.device; printf "UID="; id -u' </dev/null 2>/dev/null | tr -d '\r')" || die "adb_shell_timeout"
printf '%s\n' "$PRE"
DEVICE="$(printf '%s\n' "$PRE" | sed -n 's/^DEVICE=//p' | tail -1)"
UIDR="$(printf '%s\n' "$PRE" | sed -n 's/^UID=//p' | tail -1)"
[ "$DEVICE" = "dace" ] || die "wrong_device_$DEVICE"
[ "$UIDR" = "0" ] || die "not_root_$UIDR"

echo "[2/10] LOAD_DMCTL"
DMCTL="$TMP/dmctl"
debugfs -R "dump /bin/dmctl $DMCTL" "$STOCK_SYS" >/dev/null 2>&1 || die "dmctl_extract_failed"
chmod 755 "$DMCTL"
"${ADB[@]}" shell "rm -rf '$REMOTE'; mkdir -p '$REMOTE'" </dev/null >/dev/null || die "remote_dir_failed"
"${ADB[@]}" push "$DMCTL" "$REMOTE/dmctl" </dev/null >/dev/null || die "push_dmctl_failed"
"${ADB[@]}" shell "chmod 755 '$REMOTE/dmctl'" </dev/null >/dev/null || die "chmod_dmctl_failed"

RUNNER=""
for L in /system/bin/linker /system/bin/bootstrap/linker /apex/com.android.runtime/bin/linker; do
  P="$("${ADB[@]}" shell "[ -x '$L' ] && '$L' '$REMOTE/dmctl' help" </dev/null 2>&1 || true)"
  if printf '%s\n' "$P" | grep -qi dmctl; then RUNNER="'$L' '$REMOTE/dmctl'"; break; fi
done
[ -n "$RUNNER" ] || die "dmctl_runner_missing"
echo "DMCTL_RUNNER=$RUNNER"

echo "[3/10] CREATE_VENDOR_RW_MAP"
ARGS="linear 0 580784 '179:7' 3231744"
timeout 5s "${ADB[@]}" shell "$RUNNER delete '$NAME' >/dev/null 2>&1 || true" </dev/null >/dev/null 2>&1 || true
timeout 8s "${ADB[@]}" shell "$RUNNER create '$NAME' $ARGS" </dev/null >/dev/null || die "dm_create_failed"
DEV="$(timeout 5s "${ADB[@]}" shell "$RUNNER getpath '$NAME'" </dev/null 2>/dev/null | tr -d '\r' | tail -1)" || die "dm_getpath_timeout"
[ -n "$DEV" ] || die "dm_path_missing"
echo "DM_PATH=$DEV"
RO="$(timeout 5s "${ADB[@]}" shell "blockdev --getro '$DEV'" </dev/null 2>/dev/null | tr -d '\r' | tail -1)" || die "dm_getro_timeout"
[ "$RO" = "0" ] || die "dm_readonly_$RO"

cleanup(){
  "${ADB[@]}" shell "umount /mnt/wear5_vendor_nometa >/dev/null 2>&1 || true; $RUNNER delete '$NAME' >/dev/null 2>&1 || true" </dev/null >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "[4/10] IDENTIFY_EXACT_LOCAL_BASELINE"
REMOTE_OLD="$(timeout 20s "${ADB[@]}" shell "sha256sum '$DEV'" </dev/null 2>/dev/null | tr -d '\r' | awk '{print $1}' | tail -1)" || die "remote_sha_timeout"
echo "REMOTE_VENDOR_SHA=$REMOTE_OLD"

SRC=""
for CAND in   "$BUILD/vendor_diag_keymaster_ready.img"   "$BUILD/vendor_diag_no_wrappedkey.img"   "$BUILD/vendor_diag_latefs_probe.img"   "$BUILD/vendor_diag_pathfix.img"   "$BUILD/vendor_diag.img"
do
  [ -f "$CAND" ] || continue
  H="$(sha256sum "$CAND" | awk '{print $1}')"
  echo "CANDIDATE=$(basename "$CAND") SHA=$H"
  if [ "$H" = "$REMOTE_OLD" ]; then
    SRC="$CAND"
    break
  fi
done
[ -n "$SRC" ] || die "no_local_vendor_matches_live_sha"
echo "BASELINE_FILE=$SRC"

echo "[5/10] PATCH_FSTABS_DISABLE_METADATA_ENCRYPTION"
FIX="$BUILD/vendor_diag_no_metadata_encryption.img"
cp --reflink=auto --sparse=always "$SRC" "$FIX"

for RC in "${FSTABS[@]}"; do
  BN="$(basename "$RC")"
  OLD="$TMP/$BN.old"
  NEW="$TMP/$BN.new"
  XATTR="$TMP/$BN.selinux"

  debugfs -R "cat $RC" "$SRC" > "$OLD" 2>/dev/null || die "read_${BN}_failed"

  python - "$OLD" "$NEW" "$BN" <<'PY'
import sys,re
src,dst,name=sys.argv[1:]
lines=open(src,encoding='utf-8',errors='strict').read().splitlines()
out=[]
patched=0
for line in lines:
    s=line.strip()
    if not s or s.startswith('#'):
        out.append(line); continue
    cols=re.split(r'\s+',s)
    if len(cols) >= 5 and cols[1] == '/data':
        # fs_mgr flags are the final whitespace-separated column.
        flags=cols[-1].split(',')
        before=list(flags)
        flags=[f for f in flags if not (f.startswith('keydirectory=') or f.startswith('metadata_encryption='))]
        if not any(f.startswith('fileencryption=') or f=='fileencryption' for f in flags):
            raise SystemExit(f"{name}_FILEENCRYPTION_MISSING")
        if flags == before:
            raise SystemExit(f"{name}_NO_METADATA_FLAGS_FOUND")
        # Preserve original spacing between all earlier columns by replacing only final token.
        oldtail=cols[-1]
        newtail=','.join(flags)
        pos=line.rfind(oldtail)
        line=line[:pos]+newtail+line[pos+len(oldtail):]
        patched += 1
    out.append(line)
if patched != 1:
    raise SystemExit(f"{name}_DATA_LINES_PATCHED_{patched}")
text='\n'.join(out)+'\n'
if 'keydirectory=/metadata/vold/metadata_encryption' in text:
    raise SystemExit(f"{name}_KEYDIRECTORY_REMAINS")
if 'metadata_encryption=' in text:
    raise SystemExit(f"{name}_METADATA_ENCRYPTION_REMAINS")
open(dst,'w',encoding='utf-8',newline='\n').write(text)
print(f"{name}_PATCH=PASS")
PY

  rm -f "$XATTR"
  debugfs -R "ea_get -f $XATTR $RC security.selinux" "$SRC" >/dev/null 2>&1 || die "xattr_read_${BN}"
  [ -s "$XATTR" ] || die "xattr_empty_${BN}"

  debugfs -w -R "rm $RC" "$FIX" >/dev/null 2>&1 || die "rm_${BN}"
  debugfs -w -R "write $NEW $RC" "$FIX" >/dev/null 2>&1 || die "write_${BN}"
  debugfs -w -R "set_inode_field $RC mode 0100644" "$FIX" >/dev/null 2>&1 || true
  debugfs -w -R "set_inode_field $RC uid 0" "$FIX" >/dev/null 2>&1 || true
  debugfs -w -R "set_inode_field $RC gid 0" "$FIX" >/dev/null 2>&1 || true
  debugfs -w -R "ea_set -f $XATTR $RC security.selinux" "$FIX" >/dev/null 2>&1 || die "xattr_write_${BN}"

  debugfs -R "cat $RC" "$FIX" > "$TMP/$BN.verify" 2>/dev/null || die "verify_read_${BN}"
  cmp -s "$NEW" "$TMP/$BN.verify" || die "verify_mismatch_${BN}"
done

LOCAL_OLD="$(sha256sum "$SRC" | awk '{print $1}')"
LOCAL_NEW="$(sha256sum "$FIX" | awk '{print $1}')"
echo "LOCAL_OLD_SHA=$LOCAL_OLD"
echo "LOCAL_NEW_SHA=$LOCAL_NEW"

echo "[6/10] BUILD_4K_DELTA"
python - "$SRC" "$FIX" "$TMP/patches" "$TMP/patches.tsv" <<'PY'
import hashlib,os,sys
a,b,out,manifest=sys.argv[1:]
BS=4096
if os.path.getsize(a)!=os.path.getsize(b): raise SystemExit("SIZE_MISMATCH")
rows=[]
with open(a,'rb') as fa, open(b,'rb') as fb:
    idx=0; start=None; old=[]; new=[]
    while True:
        x=fa.read(BS); y=fb.read(BS)
        if not x and not y: break
        if x!=y:
            if start is None: start=idx; old=[]; new=[]
            old.append(x); new.append(y)
        elif start is not None:
            rows.append((start,old,new)); start=None; old=[]; new=[]
        idx+=1
    if start is not None: rows.append((start,old,new))
total=sum(len(b''.join(n)) for _,_,n in rows)
if not rows: raise SystemExit("NO_CHANGED_BLOCKS")
if total>1024*1024: raise SystemExit(f"PATCH_TOO_LARGE:{total}")
with open(manifest,'w') as m:
    for i,(start,olds,news) in enumerate(rows):
        op=os.path.join(out,f"old_{i:03d}.bin")
        np=os.path.join(out,f"new_{i:03d}.bin")
        od=b''.join(olds); nd=b''.join(news)
        open(op,'wb').write(od); open(np,'wb').write(nd)
        m.write(f"{start}\t{len(news)}\t{op}\t{np}\t{hashlib.sha256(od).hexdigest()}\t{hashlib.sha256(nd).hexdigest()}\n")
print(f"PATCH_RUNS={len(rows)}")
print(f"PATCH_BYTES={total}")
PY

echo "[7/10] VERIFY_BASELINE_AND_RAW_PATCH"
[ "$LOCAL_OLD" = "$REMOTE_OLD" ] || die "baseline_changed_before_write"
mapfile -t ROWS < "$TMP/patches.tsv"
APPLIED=0

rollback(){
  if [ "$APPLIED" -gt 0 ]; then
    echo "ROLLBACK=START"
    for ((i=0;i<APPLIED;i++)); do
      IFS=$'\t' read -r START BLOCKS OF NF OH NH <<<"${ROWS[$i]}"
      BN="$(basename "$OF")"
      "${ADB[@]}" shell "dd if='$REMOTE/$BN' of='$DEV' bs=4096 seek='$START' count='$BLOCKS' conv=notrunc,fsync 2>/dev/null" </dev/null >/dev/null 2>&1 || true
    done
    "${ADB[@]}" shell sync </dev/null >/dev/null 2>&1 || true
  fi
}
trap 'rc=$?; if [ $rc -ne 0 ]; then rollback; fi; cleanup; exit $rc' EXIT

for ROW in "${ROWS[@]}"; do
  IFS=$'\t' read -r START BLOCKS OF NF OH NH <<<"$ROW"
  OBN="$(basename "$OF")"; NBN="$(basename "$NF")"
  "${ADB[@]}" push "$OF" "$REMOTE/$OBN" </dev/null >/dev/null || die "push_old_$OBN"
  "${ADB[@]}" push "$NF" "$REMOTE/$NBN" </dev/null >/dev/null || die "push_new_$NBN"
  [ "$("${ADB[@]}" shell "sha256sum '$REMOTE/$OBN'" </dev/null 2>/dev/null | tr -d '\r' | awk '{print $1}' | tail -1)" = "$OH" ] || die "old_stage_hash_$START"
  [ "$("${ADB[@]}" shell "sha256sum '$REMOTE/$NBN'" </dev/null 2>/dev/null | tr -d '\r' | awk '{print $1}' | tail -1)" = "$NH" ] || die "new_stage_hash_$START"
  CUR="$("${ADB[@]}" shell "dd if='$DEV' bs=4096 skip='$START' count='$BLOCKS' 2>/dev/null | sha256sum" </dev/null | tr -d '\r' | awk '{print $1}' | tail -1)"
  [ "$CUR" = "$OH" ] || die "prewrite_hash_$START"
  "${ADB[@]}" shell "dd if='$REMOTE/$NBN' of='$DEV' bs=4096 seek='$START' count='$BLOCKS' conv=notrunc,fsync 2>/dev/null" </dev/null >/dev/null || die "dd_patch_$START"
  APPLIED=$((APPLIED+1))
  GOT="$("${ADB[@]}" shell "dd if='$DEV' bs=4096 skip='$START' count='$BLOCKS' 2>/dev/null | sha256sum" </dev/null | tr -d '\r' | awk '{print $1}' | tail -1)"
  [ "$GOT" = "$NH" ] || die "readback_hash_$START"
  echo "PATCH_APPLIED=$APPLIED/${#ROWS[@]}"
done
"${ADB[@]}" shell sync </dev/null >/dev/null || die "sync_failed"
REMOTE_NEW="$("${ADB[@]}" shell "sha256sum '$DEV'" </dev/null 2>/dev/null | tr -d '\r' | awk '{print $1}' | tail -1)"
echo "REMOTE_NEW_SHA=$REMOTE_NEW"
[ "$REMOTE_NEW" = "$LOCAL_NEW" ] || die "full_vendor_hash_mismatch"

echo "[8/10] READONLY_VERIFY_FSTABS"
"${ADB[@]}" shell "mkdir -p /mnt/wear5_vendor_nometa; umount /mnt/wear5_vendor_nometa >/dev/null 2>&1 || true; mount -t ext4 -o ro,noload '$DEV' /mnt/wear5_vendor_nometa" </dev/null >/dev/null || die "verify_mount_failed"
for RC in "${FSTABS[@]}"; do
  TXT="$("${ADB[@]}" shell "cat /mnt/wear5_vendor_nometa$RC" </dev/null | tr -d '\r')"
  printf '%s\n' "$TXT" | grep -q 'fileencryption=' || die "fileencryption_missing_$(basename "$RC")"
  if printf '%s\n' "$TXT" | grep -q 'keydirectory='; then die "keydirectory_remains_$(basename "$RC")"; fi
  if printf '%s\n' "$TXT" | grep -q 'metadata_encryption='; then die "metadata_encryption_remains_$(basename "$RC")"; fi
  echo "$(basename "$RC")=FBE_ONLY"
done
"${ADB[@]}" shell "umount /mnt/wear5_vendor_nometa" </dev/null >/dev/null 2>&1 || true

echo "[9/10] RESET_EMPTY_USERDATA_AND_OLD_METAKEY"
timeout 12s "${ADB[@]}" shell '
set -e
umount /data >/dev/null 2>&1 || true
rm -rf /metadata/vold/metadata_encryption
BLK=/dev/block/bootdevice/by-name/userdata
SZ=$(blockdev --getsize64 "$BLK")
dd if=/dev/zero of="$BLK" bs=1M count=16 conv=fsync 2>/dev/null
OFF=$((SZ/1048576-16))
[ "$OFF" -gt 0 ]
dd if=/dev/zero of="$BLK" bs=1M seek="$OFF" count=16 conv=fsync 2>/dev/null
sync
' </dev/null >/dev/null || die "userdata_reset_failed"

echo "[10/10] FINAL_VERIFY"
KEY="$("${ADB[@]}" shell '[ -e /metadata/vold/metadata_encryption ] && echo PRESENT || echo ABSENT' </dev/null 2>/dev/null | tr -d '\r' | tail -1)"
[ "$KEY" = "ABSENT" ] || die "metadata_keydir_not_removed"
HEAD="$("${ADB[@]}" shell 'dd if=/dev/block/bootdevice/by-name/userdata bs=4096 count=1 2>/dev/null | sha256sum' </dev/null | tr -d '\r' | awk '{print $1}' | tail -1)"
ZERO="$(printf '\0%.0s' {1..4096} | sha256sum | awk '{print $1}')"
[ "$HEAD" = "$ZERO" ] || die "userdata_head_not_zero"

trap - EXIT
cleanup

echo
echo "NO_METADATA_ENCRYPTION_FIX=PASS"
echo "FILE_BASED_ENCRYPTION=ENABLED"
echo "METADATA_ENCRYPTION=DISABLED_FOR_BOOT_TEST"
echo "USERDATA_RESET=YES"
echo "RECOVERY_BOOT_SUPER_TOUCHED=NO"
echo "NEXT=ONE_NORMAL_BOOT"
