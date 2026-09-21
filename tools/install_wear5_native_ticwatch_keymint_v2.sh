#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail

W="$HOME/WEAR5"
BUILD="$W/C1_DIAG_PC_BUILD"
SRC="$BUILD/vendor_diag_no_metadata_encryption.img"
FIX="$BUILD/vendor_diag_native_keymint_v2.img"
STOCK_SYS="$W/stock/system.img"
TMP="$W/NATIVE_KEYMINT_V2_ENABLE"
REMOTE="/cache/wear5_native_keymint_v2"

ADB_HOST="10.217.221.57"
ADB_PORT="5037"
TARGET="${1:-C121X44260991}"
NAME="wear5_vendor_native_keymint_v2"

RC_TARGET="/etc/init/hw/init.target.rc"
RC_KM="/etc/init/android.hardware.security.keymint-service-qti.rc"
XML_KM="/etc/vintf/manifest/android.hardware.security.keymint-service-qti.xml"

die(){ echo; echo "BLOCKER=$*"; exit 2; }

for C in debugfs python sha256sum timeout; do
  command -v "$C" >/dev/null 2>&1 || die "tool_mancante_$C"
done
[ -f "$SRC" ] || die "baseline_no_metadata_encryption_missing"
[ -f "$STOCK_SYS" ] || die "stock_system_missing"

rm -rf "$TMP"
mkdir -p "$TMP/patches"

echo "[1/10] BUILD_NATIVE_KEYMINT_V2_VENDOR"

for P in   /bin/hw/android.hardware.security.keymint-service-qti   /lib64/libqtikeymint.so   /lib64/android.hardware.security.keymint-V2-ndk.so   /lib64/android.hardware.security.secureclock-V1-ndk.so   /lib64/android.hardware.security.sharedsecret-V1-ndk.so
do
  debugfs -R "stat $P" "$SRC" >/dev/null 2>&1 || die "missing_$P"
done

POL="$TMP/vendor_sepolicy.cil"
debugfs -R "cat /etc/selinux/vendor_sepolicy.cil" "$SRC" > "$POL" 2>/dev/null || die "vendor_sepolicy_read_failed"
grep -q 'vendor_hal_keymint_qti' "$POL" || die "keymint_qti_domain_missing"

cat > "$TMP/keymint.rc" <<'EOF'
on init
    start vendor.keymint-qti

service vendor.keymint-qti /vendor/bin/hw/android.hardware.security.keymint-service-qti
    class early_hal
    user system
    group system drmrpc
EOF

cat > "$TMP/keymint.xml" <<'EOF'
<manifest version="8.0" type="device">
    <hal format="aidl">
        <name>android.hardware.security.keymint</name>
        <version>2</version>
        <fqname>IKeyMintDevice/default</fqname>
    </hal>
    <hal format="aidl">
        <name>android.hardware.security.keymint</name>
        <version>2</version>
        <fqname>IRemotelyProvisionedComponent/default</fqname>
    </hal>
    <hal format="aidl">
        <name>android.hardware.security.secureclock</name>
        <fqname>ISecureClock/default</fqname>
    </hal>
    <hal format="aidl">
        <name>android.hardware.security.sharedsecret</name>
        <fqname>ISharedSecret/default</fqname>
    </hal>
</manifest>
EOF

debugfs -R "cat $RC_TARGET" "$SRC" > "$TMP/init.target.old.rc" 2>/dev/null || die "read_init_target_failed"
python - "$TMP/init.target.old.rc" "$TMP/init.target.new.rc" <<'PY'
import sys
src,dst=sys.argv[1:]
lines=open(src,encoding='utf-8',errors='strict').read().splitlines()
owned={
    'start vendor.qseecomd',
    'start vendor.keymaster-4-1',
    'wait_for_prop init.svc.vendor.qseecomd running',
    'wait_for_prop init.svc.vendor.keymaster-4-1 running',
}
out=[]
i=0
removed=[]
while i < len(lines):
    if lines[i].strip() == 'on late-fs':
        j=i+1
        while j<len(lines) and not lines[j].strip().startswith(('on ','service ','import ')):
            j+=1
        body=lines[i+1:j]
        if any('mount_all /vendor/etc/fstab.${ro.hardware} --late' in x for x in body):
            out.append(lines[i])
            for x in body:
                if x.strip() in owned:
                    removed.append(x.strip())
                else:
                    out.append(x)
            i=j
            continue
    out.append(lines[i]); i+=1

missing=owned-set(removed)
if missing:
    print("NOTE_NOT_ALL_EXPERIMENTAL_LINES_PRESENT="+','.join(sorted(missing)))
open(dst,'w',encoding='utf-8',newline='\n').write('\n'.join(out)+'\n')
print("EXPERIMENTAL_KEYMASTER_WAIT_LINES_REMOVED="+str(len(removed)))
PY

cp --reflink=auto --sparse=always "$SRC" "$FIX"

RC_REF="/etc/init/android.hardware.keymaster@4.1-service-qti.rc"
XML_REF="/etc/vintf/manifest/android.hardware.keymaster@4.1-service-default-qti.xml"

for SPEC in   "$RC_TARGET:$TMP/init.target.new.rc:$RC_TARGET"   "$RC_REF:$TMP/keymint.rc:$RC_KM"   "$XML_REF:$TMP/keymint.xml:$XML_KM"
do
  REF="${SPEC%%:*}"
  REST="${SPEC#*:}"
  LOCAL="${REST%%:*}"
  DEST="${REST#*:}"
  XA="$TMP/$(basename "$DEST").selinux"

  rm -f "$XA"
  debugfs -R "ea_get -f $XA $REF security.selinux" "$SRC" >/dev/null 2>&1 || die "xattr_read_$REF"
  [ -s "$XA" ] || die "xattr_empty_$REF"

  debugfs -w -R "rm $DEST" "$FIX" >/dev/null 2>&1 || true
  debugfs -w -R "write $LOCAL $DEST" "$FIX" >/dev/null 2>&1 || die "write_$DEST"
  debugfs -w -R "set_inode_field $DEST mode 0100644" "$FIX" >/dev/null 2>&1 || true
  debugfs -w -R "set_inode_field $DEST uid 0" "$FIX" >/dev/null 2>&1 || true
  debugfs -w -R "set_inode_field $DEST gid 0" "$FIX" >/dev/null 2>&1 || true
  debugfs -w -R "ea_set -f $XA $DEST security.selinux" "$FIX" >/dev/null 2>&1 || die "xattr_write_$DEST"
done

for F in /etc/fstab.dace /etc/fstab.qcom; do
  T="$TMP/$(basename "$F")"
  debugfs -R "cat $F" "$FIX" > "$T" 2>/dev/null || die "read_$(basename "$F")"
  grep -q 'fileencryption=' "$T" || die "fileencryption_missing_$(basename "$F")"
  ! grep -q 'metadata_encryption=' "$T" || die "metadata_encryption_returned_$(basename "$F")"
  ! grep -q 'keydirectory=' "$T" || die "keydirectory_returned_$(basename "$F")"
done

debugfs -R "cat $RC_KM" "$FIX" > "$TMP/keymint.rc.verify" 2>/dev/null || die "verify_keymint_rc_read"
cmp -s "$TMP/keymint.rc" "$TMP/keymint.rc.verify" || die "verify_keymint_rc_mismatch"
debugfs -R "cat $XML_KM" "$FIX" > "$TMP/keymint.xml.verify" 2>/dev/null || die "verify_keymint_xml_read"
cmp -s "$TMP/keymint.xml" "$TMP/keymint.xml.verify" || die "verify_keymint_xml_mismatch"

LOCAL_OLD="$(sha256sum "$SRC" | awk '{print $1}')"
LOCAL_NEW="$(sha256sum "$FIX" | awk '{print $1}')"
echo "LOCAL_OLD_SHA=$LOCAL_OLD"
echo "LOCAL_NEW_SHA=$LOCAL_NEW"

echo "[2/10] BUILD_4K_DELTA"
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
if total>2*1024*1024: raise SystemExit(f"PATCH_TOO_LARGE:{total}")
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

echo "[3/10] PRECHECK"
STATE="$(timeout 5s "${ADB[@]}" get-state </dev/null 2>/dev/null | tr -d '\r' | tail -1)" || die "adb_state_timeout"
[ "$STATE" = recovery ] || die "not_in_recovery_$STATE"
PRE="$(timeout 5s "${ADB[@]}" shell 'printf "DEVICE="; getprop ro.product.device; printf "UID="; id -u' </dev/null 2>/dev/null | tr -d '\r')" || die "adb_shell_timeout"
printf '%s\n' "$PRE"
DEVICE="$(printf '%s\n' "$PRE" | sed -n 's/^DEVICE=//p' | tail -1)"
UIDR="$(printf '%s\n' "$PRE" | sed -n 's/^UID=//p' | tail -1)"
[ "$DEVICE" = dace ] || die "wrong_device_$DEVICE"
[ "$UIDR" = 0 ] || die "not_root_$UIDR"

echo "[4/10] LOAD_DMCTL"
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

echo "[5/10] CREATE_VENDOR_RW_MAP"
ARGS="linear 0 580784 '179:7' 3231744"
timeout 5s "${ADB[@]}" shell "$RUNNER delete '$NAME' >/dev/null 2>&1 || true" </dev/null >/dev/null 2>&1 || true
timeout 8s "${ADB[@]}" shell "$RUNNER create '$NAME' $ARGS" </dev/null >/dev/null || die "dm_create_failed"
DEV="$(timeout 5s "${ADB[@]}" shell "$RUNNER getpath '$NAME'" </dev/null 2>/dev/null | tr -d '\r' | tail -1)" || die "dm_getpath_timeout"
[ -n "$DEV" ] || die "dm_path_missing"

cleanup(){
  "${ADB[@]}" shell "umount /mnt/wear5_vendor_kmv2 >/dev/null 2>&1 || true; $RUNNER delete '$NAME' >/dev/null 2>&1 || true" </dev/null >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "[6/10] VERIFY_LIVE_BASELINE"
REMOTE_OLD="$(timeout 20s "${ADB[@]}" shell "sha256sum '$DEV'" </dev/null 2>/dev/null | tr -d '\r' | awk '{print $1}' | tail -1)" || die "remote_sha_timeout"
echo "REMOTE_OLD_SHA=$REMOTE_OLD"
[ "$REMOTE_OLD" = "$LOCAL_OLD" ] || die "live_vendor_not_fbe_only_baseline"

echo "[7/10] RAW_PATCH_WITH_READBACK"
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

echo "[8/10] READONLY_VERIFY"
"${ADB[@]}" shell "mkdir -p /mnt/wear5_vendor_kmv2; umount /mnt/wear5_vendor_kmv2 >/dev/null 2>&1 || true; mount -t ext4 -o ro,noload '$DEV' /mnt/wear5_vendor_kmv2" </dev/null >/dev/null || die "verify_mount_failed"
RRC="$("${ADB[@]}" shell "cat /mnt/wear5_vendor_kmv2$RC_KM" </dev/null | tr -d '\r')"
RXML="$("${ADB[@]}" shell "cat /mnt/wear5_vendor_kmv2$XML_KM" </dev/null | tr -d '\r')"
[ "$RRC" = "$(cat "$TMP/keymint.rc")" ] || die "remote_keymint_rc_mismatch"
[ "$RXML" = "$(cat "$TMP/keymint.xml")" ] || die "remote_keymint_xml_mismatch"
"${ADB[@]}" shell "umount /mnt/wear5_vendor_kmv2" </dev/null >/dev/null 2>&1 || true

echo "[9/10] RESET_EMPTY_USERDATA"
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

echo "[10/10] FINAL"
trap - EXIT
cleanup

echo
echo "NATIVE_TICWATCH_KEYMINT_V2_ENABLE=PASS"
echo "KEYMINT_BINARY_SOURCE=TICWATCH"
echo "KEYMINT_AIDL_VERSION=2"
echo "KEYMINT_RC_ADDED=YES"
echo "KEYMINT_VINTF_ADDED=YES"
echo "OLD_EXPERIMENTAL_KEYMASTER_WAITS_REMOVED=YES"
echo "FILE_BASED_ENCRYPTION=ENABLED"
echo "METADATA_ENCRYPTION=DISABLED_FOR_TEST"
echo "USERDATA_RESET=YES"
echo "RECOVERY_BOOT_SUPER_TOUCHED=NO"
echo "NEXT=ONE_NORMAL_BOOT"
