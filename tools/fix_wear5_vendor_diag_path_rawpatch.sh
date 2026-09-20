#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail

WORK="$HOME/WEAR5"
SRC="$WORK/C1_DIAG_PC_BUILD/vendor_diag.img"
FIX="$WORK/C1_DIAG_PC_BUILD/vendor_diag_pathfix.img"
TMP="$WORK/VENDOR_DIAG_PATHFIX"
STOCK_SYS="$WORK/stock/system.img"
REMOTE="/cache/wear5_vendor_pathfix"

ADB_HOST="10.82.56.57"
ADB_PORT="5037"
TARGET="${1:-C121X44260991}"
NAME="wear5_vendor_pathfix"

OLD="/metadata/vold/wear5diag"
NEW="/metadata/diag/wear5diag"
META="/metadata/diag/wear5diag"

die(){ echo; echo "BLOCKER=$*"; exit 2; }

cleanup_dm(){
  if [ -n "${RUNNER:-}" ]; then
    "${ADB[@]}" shell "$RUNNER delete '$NAME' >/dev/null 2>&1 || true" </dev/null >/dev/null 2>&1 || true
  fi
}

for C in debugfs python sha256sum; do
  command -v "$C" >/dev/null 2>&1 || die "tool_mancante_$C"
done
[ -f "$SRC" ] || die "vendor_diag_locale_mancante"
[ -f "$STOCK_SYS" ] || die "stock_system_mancante"

rm -rf "$TMP"
mkdir -p "$TMP/patches"

echo "[1/8] LOCAL_PATCH_PREP"
debugfs -R "cat /etc/init/wear5diag.rc" "$SRC" > "$TMP/old.rc" 2>/dev/null   || die "wear5diag_rc_non_leggibile"

OLD_COUNT="$(python - "$TMP/old.rc" "$OLD" <<'PY'
import sys
p,s=sys.argv[1:]
b=open(p,'rb').read()
print(b.count(s.encode()))
PY
)"
[ "$OLD_COUNT" -gt 0 ] || die "old_path_non_presente_nel_rc"

cp --reflink=auto --sparse=always "$SRC" "$FIX"
REPL_COUNT="$(python - "$FIX" "$OLD" "$NEW" <<'PY'
import mmap,sys
p,old,new=sys.argv[1:]
old=old.encode(); new=new.encode()
if len(old)!=len(new):
    raise SystemExit("PATH_LENGTH_MISMATCH")
with open(p,"r+b") as f:
    m=mmap.mmap(f.fileno(),0)
    n=m[:].count(old)
    pos=0
    while True:
        i=m.find(old,pos)
        if i<0: break
        m[i:i+len(old)]=new
        pos=i+len(old)
    m.flush(); m.close()
print(n)
PY
)"
[ "$REPL_COUNT" = "$OLD_COUNT" ] || die "replacement_count_${REPL_COUNT}_atteso_${OLD_COUNT}"

debugfs -R "cat /etc/init/wear5diag.rc" "$FIX" > "$TMP/new.rc" 2>/dev/null   || die "wear5diag_rc_patch_non_leggibile"
grep -Fq "$NEW/01_early_init" "$TMP/new.rc" || die "new_path_non_verificato"
if grep -Fq "$OLD" "$TMP/new.rc"; then die "old_path_ancora_presente"; fi

LOCAL_OLD="$(sha256sum "$SRC" | awk '{print $1}')"
LOCAL_NEW="$(sha256sum "$FIX" | awk '{print $1}')"
echo "RC_PATH_REPLACEMENTS=$REPL_COUNT"
echo "LOCAL_OLD_SHA=$LOCAL_OLD"
echo "LOCAL_NEW_SHA=$LOCAL_NEW"

echo "[2/8] BUILD_4K_DELTA"
python - "$SRC" "$FIX" "$TMP/patches" "$TMP/patches.tsv" <<'PY'
import hashlib,os,sys
a,b,out,manifest=sys.argv[1:]
BS=4096
if os.path.getsize(a)!=os.path.getsize(b):
    raise SystemExit("SIZE_MISMATCH")
rows=[]
with open(a,'rb') as fa, open(b,'rb') as fb:
    idx=0; start=None; old=[]; new=[]
    while True:
        x=fa.read(BS); y=fb.read(BS)
        if not x and not y: break
        if x!=y:
            if start is None:
                start=idx; old=[]; new=[]
            old.append(x); new.append(y)
        elif start is not None:
            rows.append((start,old,new)); start=None; old=[]; new=[]
        idx+=1
    if start is not None:
        rows.append((start,old,new))
total=sum(len(b''.join(n)) for _,_,n in rows)
if not rows: raise SystemExit("NO_CHANGED_BLOCKS")
if total > 1024*1024: raise SystemExit("PATCH_TOO_LARGE")
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
cat "$TMP/patches.tsv"

ADB=(adb -H "$ADB_HOST" -P "$ADB_PORT" -s "$TARGET")
STATE="$(adb -H "$ADB_HOST" -P "$ADB_PORT" devices 2>/dev/null | awk -v s="$TARGET" '$1==s{print $2; exit}')"   || die "adb_devices_fallito"
case "$STATE" in recovery|device|rescue) ;; *) die "adb_state_${STATE:-vuoto}";; esac
PRODUCT="$("${ADB[@]}" shell getprop ro.product.device </dev/null 2>/dev/null | tr -d '\r' | tail -1)"   || die "getprop_fallito"
[ "$PRODUCT" = "dace" ] || die "device_${PRODUCT:-vuoto}"
UIDR="$("${ADB[@]}" shell id -u </dev/null 2>/dev/null | tr -d '\r' | tail -1)"   || die "id_fallito"
[ "$UIDR" = "0" ] || die "adb_non_root_uid_${UIDR:-vuoto}"

echo "[3/8] LOAD_PROVEN_DMCTL"
DMCTL="$TMP/dmctl"
debugfs -R "dump /bin/dmctl $DMCTL" "$STOCK_SYS" >/dev/null 2>&1   || die "dmctl_non_estratto"
chmod 755 "$DMCTL"

"${ADB[@]}" shell "rm -rf '$REMOTE'; mkdir -p '$REMOTE'" </dev/null >/dev/null   || die "remote_dir_fallita"
"${ADB[@]}" push "$DMCTL" "$REMOTE/dmctl" </dev/null >/dev/null   || die "push_dmctl_fallito"
"${ADB[@]}" shell "chmod 755 '$REMOTE/dmctl'" </dev/null >/dev/null   || die "chmod_dmctl_fallito"

RUNNER=""
for L in /system/bin/linker /system/bin/bootstrap/linker /apex/com.android.runtime/bin/linker; do
  P="$("${ADB[@]}" shell "[ -x '$L' ] && '$L' '$REMOTE/dmctl' help" </dev/null 2>&1 || true)"
  if printf '%s\n' "$P" | grep -qi dmctl; then
    RUNNER="'$L' '$REMOTE/dmctl'"
    break
  fi
done
[ -n "$RUNNER" ] || die "dmctl_non_eseguibile"
echo "DMCTL_RUNNER=$RUNNER"

echo "[4/8] CLONE_LIVE_VENDOR_MAP_RW"
TAB="$("${ADB[@]}" shell "$RUNNER table vendor" </dev/null 2>/dev/null | tr -d '\r')"   || die "vendor_table_fallita"
printf '%s\n' "$TAB"

printf '%s\n' "$TAB" | sed -n   's/^\([0-9][0-9]*\)-\([0-9][0-9]*\): linear, \([^ ]*\) \([0-9][0-9]*\)$/\1 \2 \3 \4/p'   > "$TMP/vendor.table"

[ -s "$TMP/vendor.table" ] || die "vendor_table_non_parsabile"

ARGS=""
while read -r START END BASE OFF; do
  LEN=$((END-START))
  [ "$LEN" -gt 0 ] || die "vendor_extent_len_zero"
  ARGS="$ARGS linear $START $LEN '$BASE' $OFF"
done < "$TMP/vendor.table"

"${ADB[@]}" shell "$RUNNER delete '$NAME' >/dev/null 2>&1 || true" </dev/null >/dev/null 2>&1 || true
"${ADB[@]}" shell "$RUNNER create '$NAME' $ARGS" </dev/null >/dev/null   || die "dm_create_fallito"

DEV="$("${ADB[@]}" shell "$RUNNER getpath '$NAME'" </dev/null 2>/dev/null | tr -d '\r' | tail -1)"   || die "dm_getpath_fallito"
[ -n "$DEV" ] || die "dm_device_vuoto"

RO="$("${ADB[@]}" shell "blockdev --getro '$DEV'" </dev/null 2>/dev/null | tr -d '\r' | tail -1)"   || die "blockdev_getro_fallito"
[ "$RO" = "0" ] || die "dm_device_readonly_$RO"
trap cleanup_dm EXIT

echo "[5/8] PROVE_CURRENT_VENDOR_BASELINE"
REMOTE_OLD="$("${ADB[@]}" shell "sha256sum '$DEV'" </dev/null 2>/dev/null | tr -d '\r' | awk '{print $1}' | tail -1)"   || die "remote_vendor_hash_fallito"
echo "REMOTE_OLD_SHA=$REMOTE_OLD"
[ "$REMOTE_OLD" = "$LOCAL_OLD" ] || die "current_vendor_non_corrisponde_alla_baseline"

echo "[6/8] STAGE_AND_RAW_PATCH"
mapfile -t ROWS < "$TMP/patches.tsv"
[ "${#ROWS[@]}" -gt 0 ] || die "patch_manifest_vuoto"

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
    BACK="$("${ADB[@]}" shell "sha256sum '$DEV'" </dev/null 2>/dev/null | tr -d '\r' | awk '{print $1}' | tail -1 || true)"
    echo "ROLLBACK_SHA=$BACK"
  fi
}
trap 'rc=$?; if [ $rc -ne 0 ]; then rollback; fi; cleanup_dm; exit $rc' EXIT

for ROW in "${ROWS[@]}"; do
  IFS=$'\t' read -r START BLOCKS OF NF OH NH <<<"$ROW"
  OBN="$(basename "$OF")"
  NBN="$(basename "$NF")"

  "${ADB[@]}" push "$OF" "$REMOTE/$OBN" </dev/null >/dev/null || die "push_old_$OBN"
  "${ADB[@]}" push "$NF" "$REMOTE/$NBN" </dev/null >/dev/null || die "push_new_$NBN"

  ROH="$("${ADB[@]}" shell "sha256sum '$REMOTE/$OBN'" </dev/null 2>/dev/null | tr -d '\r' | awk '{print $1}' | tail -1)"
  RNH="$("${ADB[@]}" shell "sha256sum '$REMOTE/$NBN'" </dev/null 2>/dev/null | tr -d '\r' | awk '{print $1}' | tail -1)"
  [ "$ROH" = "$OH" ] || die "stage_old_hash_$OBN"
  [ "$RNH" = "$NH" ] || die "stage_new_hash_$NBN"

  CUR="$("${ADB[@]}" shell "dd if='$DEV' bs=4096 skip='$START' count='$BLOCKS' 2>/dev/null | sha256sum" </dev/null | tr -d '\r' | awk '{print $1}' | tail -1)"
  [ "$CUR" = "$OH" ] || die "prewrite_block_non_baseline_$START"

  "${ADB[@]}" shell "dd if='$REMOTE/$NBN' of='$DEV' bs=4096 seek='$START' count='$BLOCKS' conv=notrunc,fsync 2>/dev/null" </dev/null >/dev/null     || die "dd_patch_$START"

  APPLIED=$((APPLIED+1))

  GOT="$("${ADB[@]}" shell "dd if='$DEV' bs=4096 skip='$START' count='$BLOCKS' 2>/dev/null | sha256sum" </dev/null | tr -d '\r' | awk '{print $1}' | tail -1)"
  [ "$GOT" = "$NH" ] || die "readback_hash_$START"
  echo "PATCH_APPLIED=$APPLIED/${#ROWS[@]}"
done

"${ADB[@]}" shell sync </dev/null >/dev/null || die "sync_fallito"

REMOTE_NEW="$("${ADB[@]}" shell "sha256sum '$DEV'" </dev/null 2>/dev/null | tr -d '\r' | awk '{print $1}' | tail -1)"   || die "remote_new_hash_fallito"
echo "REMOTE_NEW_SHA=$REMOTE_NEW"
[ "$REMOTE_NEW" = "$LOCAL_NEW" ] || die "full_vendor_hash_postpatch_mismatch"

echo "[7/8] READONLY_VERIFY"
"${ADB[@]}" shell "mkdir -p /mnt/wear5_vendor_verify; umount /mnt/wear5_vendor_verify >/dev/null 2>&1 || true; mount -t ext4 -o ro,noload '$DEV' /mnt/wear5_vendor_verify" </dev/null >/dev/null   || die "verify_mount_ro_fallito"
REMOTE_RC="$("${ADB[@]}" shell "cat /mnt/wear5_vendor_verify/etc/init/wear5diag.rc" </dev/null | tr -d '\r')"   || die "remote_rc_read_fallito"
LOCAL_RC="$(cat "$TMP/new.rc")"
[ "$REMOTE_RC" = "$LOCAL_RC" ] || die "remote_rc_mismatch"
"${ADB[@]}" shell "umount /mnt/wear5_vendor_verify" </dev/null >/dev/null 2>&1 || true

echo "[8/8] PREPARE_VALID_MARKERS"
"${ADB[@]}" shell '
rm -rf /metadata/diag
mkdir -p /metadata/diag/wear5diag
chmod 0755 /metadata/diag /metadata/diag/wear5diag
chcon u:object_r:vendor_data_file:s0 /metadata/diag
chcon u:object_r:vendor_data_file:s0 /metadata/diag/wear5diag

for d in 01_early_init 02_init 03_late_init 04_fs 05_post_fs 06_late_fs 07_post_fs_data 08_early_boot 09_boot 10_apexd_running 20_vold_running 30_servicemanager_running 31_hwservicemanager_running 35_keystore2_running 40_zygote_running 41_surfaceflinger_running 42_bootanim_running 50_svc_qseecom-service 50_svc_qseeproxydaemon 50_svc_vendor.keymaster-4-1 50_svc_vendor.qseecomd 99_boot_completed
do
  mkdir -p "/metadata/diag/wear5diag/$d"
  chmod 0700 "/metadata/diag/wear5diag/$d"
  chcon u:object_r:vendor_data_file:s0 "/metadata/diag/wear5diag/$d"
done
sync
' </dev/null >/dev/null || die "marker_prepare_fallito"

Z="$("${ADB[@]}" shell "ls -Zd '$META' '$META/01_early_init'" </dev/null | tr -d '\r')"   || die "marker_label_read_fallito"
printf '%s\n' "$Z"
COUNT="$(printf '%s\n' "$Z" | grep -c vendor_data_file || true)"
[ "$COUNT" -eq 2 ] || die "marker_label_non_vendor_data_file"

trap - EXIT
cleanup_dm

echo
echo "PATHFIX=PASS"
echo "METHOD=PROVEN_RAW_4K_PATCH_NO_RW_MOUNT"
echo "RECOVERY_TOUCHED=NO"
echo "NEXT=ONE_NORMAL_BOOT"
