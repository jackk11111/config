#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail

WORK="$HOME/WEAR5"
SRC="$WORK/C1_DIAG_PC_BUILD/vendor_diag_pathfix.img"
FIX="$WORK/C1_DIAG_PC_BUILD/vendor_diag_latefs_probe.img"
STOCK_SYS="$WORK/stock/system.img"
TMP="$WORK/VENDOR_LATEFS_PROBE"
REMOTE="/cache/wear5_latefs_probe"

ADB_HOST="10.82.56.57"
ADB_PORT="5037"
TARGET="${1:-C121X44260991}"
NAME="wear5_vendor_latefs_probe"
RC="/etc/init/init.target.rc"
META="/metadata/diag/wear5diag"

die(){ echo; echo "BLOCKER=$*"; exit 2; }

for C in debugfs python sha256sum; do
  command -v "$C" >/dev/null 2>&1 || die "tool_mancante_$C"
done
[ -f "$SRC" ] || die "vendor_pathfix_locale_mancante"
[ -f "$STOCK_SYS" ] || die "stock_system_mancante"

rm -rf "$TMP"
mkdir -p "$TMP/patches"

echo "[1/8] RESOLVE_AND_PATCH_REAL_LATEFS_RC"

rm -rf "$TMP/vendor_init_live"
mkdir -p "$TMP/vendor_init_live"
debugfs -R "rdump /etc/init $TMP/vendor_init_live" "$SRC" >/dev/null 2>&1 \
  || die "rdump_vendor_init_fallito"

python - "$TMP/vendor_init_live" "$TMP/target.rel" "$TMP/init.target.old.rc" "$TMP/init.target.new.rc" <<'PY'
import os,sys,re,shutil
root,relout,oldout,newout=sys.argv[1:]
root=os.path.realpath(root)

def find_action(lines):
    hits=[]
    i=0
    while i < len(lines):
        if re.fullmatch(r'\s*on\s+late-fs\s*', lines[i]):
            j=i+1
            while j < len(lines):
                s=lines[j].strip()
                if re.match(r'^(on|service|import)\b', s):
                    break
                j+=1
            body=lines[i+1:j]
            has_wait=any(re.fullmatch(r'\s*wait_for_prop\s+hwservicemanager\.ready\s+true\s*', x) for x in body)
            has_mount=any(re.fullmatch(r'\s*mount_all\s+/vendor/etc/fstab\.\$\{ro\.hardware\}\s+--late\s*', x) for x in body)
            if has_wait and has_mount:
                hits.append((i,j))
            i=j
        else:
            i+=1
    return hits

matches=[]
for dp,dirs,files in os.walk(root, followlinks=True):
    for fn in files:
        if not fn.endswith('.rc'):
            continue
        p=os.path.join(dp,fn)
        try:
            data=open(p,'r',encoding='utf-8',errors='strict').read()
        except Exception:
            continue
        lines=data.splitlines()
        hits=find_action(lines)
        for h in hits:
            matches.append((p,lines,h))

if len(matches)!=1:
    print("TARGET_LATE_FS_MATCHES="+str(len(matches)))
    for p,lines,(i,j) in matches:
        print("MATCH="+p)
        for x in lines[i:j]:
            print(x)
    raise SystemExit(3)

p,lines,(start,end)=matches[0]
real=os.path.realpath(p)
if not (real==root or real.startswith(root+os.sep)):
    raise SystemExit("TARGET_ESCAPES_RDUMP_ROOT")
rel=os.path.relpath(real,root)
open(relout,'w').write(rel+'\n')
shutil.copyfile(real,oldout)

out=[]
iw=im=0
for i,line in enumerate(lines):
    if start < i < end and re.fullmatch(r'\s*wait_for_prop\s+hwservicemanager\.ready\s+true\s*', line):
        ind=line[:len(line)-len(line.lstrip())]
        out.append(ind+'chmod 0777 /metadata/diag/wear5diag/05a_before_hwsm_wait')
        out.append(line)
        out.append(ind+'chmod 0777 /metadata/diag/wear5diag/05b_after_hwsm_wait')
        iw+=1
    elif start < i < end and re.fullmatch(r'\s*mount_all\s+/vendor/etc/fstab\.\$\{ro\.hardware\}\s+--late\s*', line):
        ind=line[:len(line)-len(line.lstrip())]
        out.append(line)
        out.append(ind+'chmod 0777 /metadata/diag/wear5diag/05c_after_mount_all')
        im+=1
    else:
        out.append(line)

if iw!=1 or im!=1:
    raise SystemExit(f"INSERT_COUNTS_wait={iw}_mount={im}")

open(newout,'w',encoding='utf-8',newline='\n').write('\n'.join(out)+'\n')
print("LATEFS_TARGET_MATCH=PASS")
print("RDUMP_REAL_REL="+rel)
PY

REL="$(cat "$TMP/target.rel")"
OLD_SHA_FILE="$(sha256sum "$TMP/init.target.old.rc" | awk '{print $1}')"
RC=""

# Resolve the rdump path back to the exact ext4 path by content, not by assumption.
for CAND in \
  "/etc/init/$REL" \
  "/etc/$REL" \
  "/$REL" \
  "/etc/init/$(basename "$REL")"
do
  rm -f "$TMP/candidate.rc"
  if debugfs -R "cat $CAND" "$SRC" > "$TMP/candidate.rc" 2>/dev/null; then
    H="$(sha256sum "$TMP/candidate.rc" | awk '{print $1}')"
    if [ "$H" = "$OLD_SHA_FILE" ]; then
      [ -z "$RC" ] || [ "$RC" = "$CAND" ] || die "multiple_image_paths_for_target"
      RC="$CAND"
    fi
  fi
done

[ -n "$RC" ] || die "real_latefs_rc_image_path_non_risolto"
echo "REAL_LATEFS_RC=$RC"

cp --reflink=auto --sparse=always "$SRC" "$FIX"
rm -f "$TMP/selinux.xattr"
debugfs -R "ea_get -f $TMP/selinux.xattr $RC security.selinux" "$SRC" >/dev/null 2>&1 \
  || die "xattr_read_fallito"
[ -s "$TMP/selinux.xattr" ] || die "xattr_vuoto"

debugfs -w -R "rm $RC" "$FIX" >/dev/null 2>&1 || die "rm_target_rc_fallito"
debugfs -w -R "write $TMP/init.target.new.rc $RC" "$FIX" >/dev/null 2>&1 || die "write_target_rc_fallito"
debugfs -w -R "set_inode_field $RC mode 0100644" "$FIX" >/dev/null 2>&1 || true
debugfs -w -R "set_inode_field $RC uid 0" "$FIX" >/dev/null 2>&1 || true
debugfs -w -R "set_inode_field $RC gid 0" "$FIX" >/dev/null 2>&1 || true
debugfs -w -R "ea_set -f $TMP/selinux.xattr $RC security.selinux" "$FIX" >/dev/null 2>&1 \
  || die "xattr_write_fallito"

debugfs -R "cat $RC" "$FIX" > "$TMP/init.target.verify.rc" 2>/dev/null || die "verify_rc_read_fallito"
cmp -s "$TMP/init.target.new.rc" "$TMP/init.target.verify.rc" || die "verify_rc_mismatch"

LOCAL_OLD="$(sha256sum "$SRC" | awk '{print $1}')"
LOCAL_NEW="$(sha256sum "$FIX" | awk '{print $1}')"
echo "LOCAL_OLD_SHA=$LOCAL_OLD"
echo "LOCAL_NEW_SHA=$LOCAL_NEW"

echo "[2/8] BUILD_4K_DELTA"
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
if total > 2*1024*1024: raise SystemExit(f"PATCH_TOO_LARGE:{total}")
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
STATE="$(adb -H "$ADB_HOST" -P "$ADB_PORT" devices 2>/dev/null | awk -v s="$TARGET" '$1==s{print $2; exit}')"
case "$STATE" in recovery|device|rescue) ;; *) die "adb_state_${STATE:-vuoto}";; esac
PRODUCT="$("${ADB[@]}" shell getprop ro.product.device </dev/null 2>/dev/null | tr -d '\r' | tail -1)"
[ "$PRODUCT" = "dace" ] || die "device_${PRODUCT:-vuoto}"
UIDR="$("${ADB[@]}" shell id -u </dev/null 2>/dev/null | tr -d '\r' | tail -1)"
[ "$UIDR" = "0" ] || die "adb_non_root_uid_${UIDR:-vuoto}"

echo "[3/8] LOAD_DMCTL"
DMCTL="$TMP/dmctl"
debugfs -R "dump /bin/dmctl $DMCTL" "$STOCK_SYS" >/dev/null 2>&1 || die "dmctl_non_estratto"
chmod 755 "$DMCTL"
"${ADB[@]}" shell "rm -rf '$REMOTE'; mkdir -p '$REMOTE'" </dev/null >/dev/null || die "remote_dir_fallita"
"${ADB[@]}" push "$DMCTL" "$REMOTE/dmctl" </dev/null >/dev/null || die "push_dmctl_fallito"
"${ADB[@]}" shell "chmod 755 '$REMOTE/dmctl'" </dev/null >/dev/null || die "chmod_dmctl_fallito"

RUNNER=""
for L in /system/bin/linker /system/bin/bootstrap/linker /apex/com.android.runtime/bin/linker; do
  P="$("${ADB[@]}" shell "[ -x '$L' ] && '$L' '$REMOTE/dmctl' help" </dev/null 2>&1 || true)"
  if printf '%s\n' "$P" | grep -qi dmctl; then RUNNER="'$L' '$REMOTE/dmctl'"; break; fi
done
[ -n "$RUNNER" ] || die "dmctl_non_eseguibile"
echo "DMCTL_RUNNER=$RUNNER"

echo "[4/8] CLONE_LIVE_VENDOR_RW"
TAB="$("${ADB[@]}" shell "$RUNNER table vendor" </dev/null 2>/dev/null | tr -d '\r')"
printf '%s\n' "$TAB"
printf '%s\n' "$TAB" | sed -n 's/^\([0-9][0-9]*\)-\([0-9][0-9]*\): linear, \([^ ]*\) \([0-9][0-9]*\)$/\1 \2 \3 \4/p' > "$TMP/vendor.table"
[ -s "$TMP/vendor.table" ] || die "vendor_table_non_parsabile"

ARGS=""
while read -r START END BASE OFF; do
  LEN=$((END-START))
  ARGS="$ARGS linear $START $LEN '$BASE' $OFF"
done < "$TMP/vendor.table"

"${ADB[@]}" shell "$RUNNER delete '$NAME' >/dev/null 2>&1 || true" </dev/null >/dev/null 2>&1 || true
"${ADB[@]}" shell "$RUNNER create '$NAME' $ARGS" </dev/null >/dev/null || die "dm_create_fallito"
DEV="$("${ADB[@]}" shell "$RUNNER getpath '$NAME'" </dev/null 2>/dev/null | tr -d '\r' | tail -1)"
[ -n "$DEV" ] || die "dm_getpath_fallito"
RO="$("${ADB[@]}" shell "blockdev --getro '$DEV'" </dev/null 2>/dev/null | tr -d '\r' | tail -1)"
[ "$RO" = "0" ] || die "dm_device_readonly_$RO"

cleanup(){
  "${ADB[@]}" shell "umount /mnt/wear5_vendor_probe >/dev/null 2>&1 || true; $RUNNER delete '$NAME' >/dev/null 2>&1 || true" </dev/null >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "[5/8] VERIFY_LIVE_BASELINE"
REMOTE_OLD="$("${ADB[@]}" shell "sha256sum '$DEV'" </dev/null 2>/dev/null | tr -d '\r' | awk '{print $1}' | tail -1)"
echo "REMOTE_OLD_SHA=$REMOTE_OLD"
[ "$REMOTE_OLD" = "$LOCAL_OLD" ] || die "live_vendor_non_corrisponde_baseline"

echo "[6/8] RAW_PATCH_WITH_READBACK"
mapfile -t ROWS < "$TMP/patches.tsv"
[ "${#ROWS[@]}" -gt 0 ] || die "manifest_vuoto"
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
  [ "$("${ADB[@]}" shell "sha256sum '$REMOTE/$OBN'" </dev/null 2>/dev/null | tr -d '\r' | awk '{print $1}' | tail -1)" = "$OH" ] || die "old_stage_hash"
  [ "$("${ADB[@]}" shell "sha256sum '$REMOTE/$NBN'" </dev/null 2>/dev/null | tr -d '\r' | awk '{print $1}' | tail -1)" = "$NH" ] || die "new_stage_hash"
  CUR="$("${ADB[@]}" shell "dd if='$DEV' bs=4096 skip='$START' count='$BLOCKS' 2>/dev/null | sha256sum" </dev/null | tr -d '\r' | awk '{print $1}' | tail -1)"
  [ "$CUR" = "$OH" ] || die "prewrite_hash_$START"
  "${ADB[@]}" shell "dd if='$REMOTE/$NBN' of='$DEV' bs=4096 seek='$START' count='$BLOCKS' conv=notrunc,fsync 2>/dev/null" </dev/null >/dev/null || die "dd_patch_$START"
  APPLIED=$((APPLIED+1))
  GOT="$("${ADB[@]}" shell "dd if='$DEV' bs=4096 skip='$START' count='$BLOCKS' 2>/dev/null | sha256sum" </dev/null | tr -d '\r' | awk '{print $1}' | tail -1)"
  [ "$GOT" = "$NH" ] || die "readback_hash_$START"
  echo "PATCH_APPLIED=$APPLIED/${#ROWS[@]}"
done
"${ADB[@]}" shell sync </dev/null >/dev/null || die "sync_fallito"
REMOTE_NEW="$("${ADB[@]}" shell "sha256sum '$DEV'" </dev/null 2>/dev/null | tr -d '\r' | awk '{print $1}' | tail -1)"
echo "REMOTE_NEW_SHA=$REMOTE_NEW"
[ "$REMOTE_NEW" = "$LOCAL_NEW" ] || die "full_vendor_hash_mismatch"

echo "[7/8] READONLY_VERIFY"
"${ADB[@]}" shell "mkdir -p /mnt/wear5_vendor_probe; umount /mnt/wear5_vendor_probe >/dev/null 2>&1 || true; mount -t ext4 -o ro,noload '$DEV' /mnt/wear5_vendor_probe" </dev/null >/dev/null || die "verify_mount_ro_fallito"
REMOTE_RC="$("${ADB[@]}" shell "cat /mnt/wear5_vendor_probe$RC" </dev/null | tr -d '\r')"
LOCAL_RC="$(cat "$TMP/init.target.new.rc")"
[ "$REMOTE_RC" = "$LOCAL_RC" ] || die "remote_rc_mismatch"
"${ADB[@]}" shell "umount /mnt/wear5_vendor_probe" </dev/null >/dev/null 2>&1 || true

echo "[8/8] PREPARE_PROBE_MARKERS"
"${ADB[@]}" shell '
for d in 05a_before_hwsm_wait 05b_after_hwsm_wait 05c_after_mount_all; do
  rm -rf "/metadata/diag/wear5diag/$d"
  mkdir -p "/metadata/diag/wear5diag/$d"
  chmod 0700 "/metadata/diag/wear5diag/$d"
  chcon u:object_r:vendor_data_file:s0 "/metadata/diag/wear5diag/$d"
done
sync
' </dev/null >/dev/null || die "probe_marker_prepare_fallito"

trap - EXIT
cleanup

echo
echo "LATEFS_PROBE_PATCH=PASS"
echo "RECOVERY_TOUCHED=NO"
echo "NEXT=ONE_NORMAL_BOOT"
