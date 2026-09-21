#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail

WORK="$HOME/WEAR5"
SRC="$WORK/C1_DIAG_PC_BUILD/vendor_diag_no_wrappedkey.img"
FIX="$WORK/C1_DIAG_PC_BUILD/vendor_diag_keymaster_ready.img"
STOCK_SYS="$WORK/stock/system.img"
TMP="$WORK/VENDOR_KEYMASTER_READY_FIX"
REMOTE="/cache/wear5_keymaster_ready"

ADB_HOST="10.82.56.57"
ADB_PORT="5037"
TARGET="${1:-C121X44260991}"
NAME="wear5_vendor_keymaster_ready"
RC="/etc/init/hw/init.target.rc"

die(){ echo; echo "BLOCKER=$*"; exit 2; }

for C in debugfs python sha256sum timeout; do
  command -v "$C" >/dev/null 2>&1 || die "tool_mancante_$C"
done
[ -f "$SRC" ] || die "vendor_no_wrappedkey_locale_mancante"
[ -f "$STOCK_SYS" ] || die "stock_system_mancante"

rm -rf "$TMP"
mkdir -p "$TMP/patches" "$TMP/init"

echo "[1/9] VERIFY_KEYMASTER_STACK_AND_PATCH_RC"
debugfs -R "rdump /etc/init $TMP/init" "$SRC" >/dev/null 2>&1 || die "rdump_init_failed"

grep -RqsE '^[[:space:]]*service[[:space:]]+vendor\.keymaster-4-1[[:space:]]' "$TMP/init"   || die "service_vendor_keymaster_4_1_not_defined"
grep -RqsE '^[[:space:]]*service[[:space:]]+vendor\.qseecomd[[:space:]]' "$TMP/init"   || die "service_vendor_qseecomd_not_defined"

debugfs -R "cat $RC" "$SRC" > "$TMP/init.target.old.rc" 2>/dev/null || die "read_init_target_failed"

python - "$TMP/init.target.old.rc" "$TMP/init.target.new.rc" <<'PY'
import sys,re
src,dst=sys.argv[1:]
lines=open(src,encoding='utf-8',errors='strict').read().splitlines()

start=end=None
for i,line in enumerate(lines):
    if re.fullmatch(r'\s*on\s+late-fs\s*', line):
        j=i+1
        while j<len(lines):
            s=lines[j].strip()
            if re.match(r'^(on|service|import)\b',s):
                break
            j+=1
        body=lines[i+1:j]
        if any('mount_all /vendor/etc/fstab.${ro.hardware} --late' in x for x in body):
            if start is not None:
                raise SystemExit("MULTIPLE_LATEFS_MOUNT_BLOCKS")
            start,end=i,j

if start is None:
    raise SystemExit("LATEFS_MOUNT_BLOCK_NOT_FOUND")

body=lines[start+1:end]
owned=[
    'start vendor.qseecomd',
    'start vendor.keymaster-4-1',
    'wait_for_prop init.svc.vendor.qseecomd running',
    'wait_for_prop init.svc.vendor.keymaster-4-1 running',
]
body=[x for x in body if x.strip() not in owned]

idx=None
for n,x in enumerate(body):
    if re.fullmatch(r'\s*wait_for_prop\s+hwservicemanager\.ready\s+true\s*',x):
        idx=n; break
if idx is None:
    for n,x in enumerate(body):
        if 'mount_all /vendor/etc/fstab.${ro.hardware} --late' in x:
            idx=n; break
if idx is None:
    raise SystemExit("INSERTION_POINT_NOT_FOUND")

ref=body[idx]
indent=ref[:len(ref)-len(ref.lstrip())] or '    '
inject=[
    indent+'start vendor.qseecomd',
    indent+'start vendor.keymaster-4-1',
    indent+'wait_for_prop init.svc.vendor.qseecomd running',
    indent+'wait_for_prop init.svc.vendor.keymaster-4-1 running',
]
newbody=body[:idx]+inject+body[idx:]
out=lines[:start+1]+newbody+lines[end:]

text='\n'.join(out)+'\n'
for cmd in owned:
    if text.count(cmd)!=1:
        raise SystemExit("INJECT_VERIFY_FAILED_"+cmd.replace(' ','_'))

open(dst,'w',encoding='utf-8',newline='\n').write(text)
print("KEYMASTER_READY_RC_PATCH=PASS")
PY

cp --reflink=auto --sparse=always "$SRC" "$FIX"
XATTR="$TMP/init_target.selinux"
rm -f "$XATTR"
debugfs -R "ea_get -f $XATTR $RC security.selinux" "$SRC" >/dev/null 2>&1 || die "xattr_read_failed"
[ -s "$XATTR" ] || die "xattr_empty"

debugfs -w -R "rm $RC" "$FIX" >/dev/null 2>&1 || die "rm_rc_failed"
debugfs -w -R "write $TMP/init.target.new.rc $RC" "$FIX" >/dev/null 2>&1 || die "write_rc_failed"
debugfs -w -R "set_inode_field $RC mode 0100644" "$FIX" >/dev/null 2>&1 || true
debugfs -w -R "set_inode_field $RC uid 0" "$FIX" >/dev/null 2>&1 || true
debugfs -w -R "set_inode_field $RC gid 0" "$FIX" >/dev/null 2>&1 || true
debugfs -w -R "ea_set -f $XATTR $RC security.selinux" "$FIX" >/dev/null 2>&1 || die "xattr_write_failed"

debugfs -R "cat $RC" "$FIX" > "$TMP/init.target.verify.rc" 2>/dev/null || die "verify_rc_read_failed"
cmp -s "$TMP/init.target.new.rc" "$TMP/init.target.verify.rc" || die "verify_rc_mismatch"

for F in /etc/fstab.dace /etc/fstab.qcom; do
  T="$TMP/$(basename "$F")"
  debugfs -R "cat $F" "$FIX" > "$T" 2>/dev/null || die "read_$(basename "$F")_failed"
  grep -q 'metadata_encryption=' "$T" || die "metadata_encryption_missing_$(basename "$F")"
  if grep -q 'wrappedkey_v0' "$T"; then die "wrappedkey_v0_still_present_$(basename "$F")"; fi
done

LOCAL_OLD="$(sha256sum "$SRC" | awk '{print $1}')"
LOCAL_NEW="$(sha256sum "$FIX" | awk '{print $1}')"
echo "LOCAL_OLD_SHA=$LOCAL_OLD"
echo "LOCAL_NEW_SHA=$LOCAL_NEW"

echo "[2/9] BUILD_4K_DELTA"
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

ADB=(adb -H "$ADB_HOST" -P "$ADB_PORT" -s "$TARGET")

echo "[3/9] PRECHECK"
STATE="$(timeout 5s "${ADB[@]}" get-state </dev/null 2>/dev/null | tr -d '\r' | tail -1)" || die "adb_state_timeout"
[ "$STATE" = "recovery" ] || die "not_in_recovery_$STATE"
PRE="$(timeout 5s "${ADB[@]}" shell 'printf "DEVICE="; getprop ro.product.device; printf "UID="; id -u' </dev/null 2>/dev/null | tr -d '\r')" || die "adb_shell_timeout"
printf '%s\n' "$PRE"
DEVICE="$(printf '%s\n' "$PRE" | sed -n 's/^DEVICE=//p' | tail -1)"
UIDR="$(printf '%s\n' "$PRE" | sed -n 's/^UID=//p' | tail -1)"
[ "$DEVICE" = "dace" ] || die "wrong_device_$DEVICE"
[ "$UIDR" = "0" ] || die "not_root_$UIDR"

echo "[4/9] LOAD_DMCTL"
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

echo "[5/9] CREATE_VENDOR_RW_MAP"
ARGS="linear 0 580784 '179:7' 3231744"
timeout 5s "${ADB[@]}" shell "$RUNNER delete '$NAME' >/dev/null 2>&1 || true" </dev/null >/dev/null 2>&1 || true
timeout 8s "${ADB[@]}" shell "$RUNNER create '$NAME' $ARGS" </dev/null >/dev/null || die "dm_create_failed"
DEV="$(timeout 5s "${ADB[@]}" shell "$RUNNER getpath '$NAME'" </dev/null 2>/dev/null | tr -d '\r' | tail -1)" || die "dm_getpath_timeout"
[ -n "$DEV" ] || die "dm_path_missing"
echo "DM_PATH=$DEV"

cleanup(){
  "${ADB[@]}" shell "umount /mnt/wear5_vendor_km >/dev/null 2>&1 || true; $RUNNER delete '$NAME' >/dev/null 2>&1 || true" </dev/null >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "[6/9] VERIFY_BASELINE_AND_PATCH"
REMOTE_OLD="$(timeout 20s "${ADB[@]}" shell "sha256sum '$DEV'" </dev/null 2>/dev/null | tr -d '\r' | awk '{print $1}' | tail -1)" || die "remote_sha_timeout"
echo "REMOTE_OLD_SHA=$REMOTE_OLD"
[ "$REMOTE_OLD" = "$LOCAL_OLD" ] || die "live_vendor_baseline_mismatch"

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

echo "[7/9] READONLY_VERIFY_RC"
"${ADB[@]}" shell "mkdir -p /mnt/wear5_vendor_km; umount /mnt/wear5_vendor_km >/dev/null 2>&1 || true; mount -t ext4 -o ro,noload '$DEV' /mnt/wear5_vendor_km" </dev/null >/dev/null || die "verify_mount_failed"
REMOTE_RC="$("${ADB[@]}" shell "cat /mnt/wear5_vendor_km$RC" </dev/null | tr -d '\r')"
LOCAL_RC="$(cat "$TMP/init.target.new.rc")"
[ "$REMOTE_RC" = "$LOCAL_RC" ] || die "remote_rc_mismatch"
"${ADB[@]}" shell "umount /mnt/wear5_vendor_km" </dev/null >/dev/null 2>&1 || true

echo "[8/9] RESET_EMPTY_DATA_KEY"
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
' </dev/null >/dev/null || die "data_reset_failed"

echo "[9/9] FINAL_VERIFY"
KEY="$("${ADB[@]}" shell '[ -e /metadata/vold/metadata_encryption ] && echo PRESENT || echo ABSENT' </dev/null 2>/dev/null | tr -d '\r' | tail -1)"
[ "$KEY" = "ABSENT" ] || die "metadata_key_not_reset"

trap - EXIT
cleanup

echo
echo "KEYMASTER_BEFORE_DATA_FIX=PASS"
echo "QSEECOM_START=EXPLICIT"
echo "KEYMASTER_4_1_START=EXPLICIT"
echo "WAIT_KEYMASTER_RUNNING=YES"
echo "NO_WRAPPEDKEY_FIX=PRESERVED"
echo "USERDATA_RESET=YES"
echo "RECOVERY_BOOT_SUPER_TOUCHED=NO"
echo "NEXT=ONE_NORMAL_BOOT"
