#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail

WORK="$HOME/WEAR5"
BASE="$WORK/xiaomi/system.img"
STOCK_SYS="$WORK/stock/system.img"
STOCK_VENDOR="$WORK/stock/vendor.img"
BUILD="/storage/emulated/0/Download/WEAR5_CANDIDATE2_SYSTEM_ONLY"
SUPER_IMG="$BUILD/images/super.img"
TMP="$WORK/WEAR5_MARKER_RAWPATCH"
REMOTE="/cache/wear5_marker_rawpatch"
ADB_HOST="10.82.56.57"
ADB_PORT="5037"
TARGET="${1:-C121X44260991}"
NAME="wear5diag_system"
META="/metadata/vold/wear5diag"

die(){ echo; echo "BLOCKER=$*"; exit 2; }

for F in "$BASE" "$STOCK_SYS" "$STOCK_VENDOR" "$SUPER_IMG"; do
  [ -f "$F" ] || die "file_mancante_$F"
done
for C in debugfs lpdump python sha256sum; do
  command -v "$C" >/dev/null 2>&1 || die "tool_mancante_$C"
done

rm -rf "$TMP"
mkdir -p "$TMP/vendor_init" "$TMP/patches"

# Build the exact marker rc from the donor system + actual TicWatch vendor service names.
debugfs -R "rdump /etc/init $TMP/vendor_init" "$STOCK_VENDOR" >/dev/null 2>&1 || true
grep -RhsE '^[[:space:]]*service[[:space:]]+' "$TMP/vendor_init" 2>/dev/null   | awk '{print $2}' | grep -Ei 'qsee|keymaster|keymint' | sort -u > "$TMP/secure_services.txt" || true

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
EOF

while IFS= read -r SVC; do
  [ -n "$SVC" ] || continue
  SAFE="$(printf '%s' "$SVC" | sed 's/[^A-Za-z0-9_.-]/_/g')"
  {
    echo
    echo "on property:init.svc.$SVC=running"
    echo "    chmod 0777 /metadata/vold/wear5diag/50_svc_$SAFE"
  } >> "$TMP/wear5diag.rc"
done < "$TMP/secure_services.txt"
echo '# WEAR5-DIAG-MARKERS-END' >> "$TMP/wear5diag.rc"
chmod 0644 "$TMP/wear5diag.rc"

# Prepare a local patched copy. This never touches the watch.
echo "LOCAL_PATCH_PREP=START"
cp --reflink=auto --sparse=always "$BASE" "$TMP/system.patched.img"

if debugfs -R "stat /system/etc/init/wear5diag.rc" "$TMP/system.patched.img" 2>/dev/null | grep -q 'Inode:'; then
  debugfs -w -R "rm /system/etc/init/wear5diag.rc" "$TMP/system.patched.img" >/dev/null 2>&1     || die "rimozione_vecchio_rc_fallita"
fi

debugfs -w -R "write $TMP/wear5diag.rc /system/etc/init/wear5diag.rc" "$TMP/system.patched.img" >/dev/null 2>&1   || die "debugfs_write_rc_fallito"

# Copy the SELinux xattr from Xiaomi's own main init rc so init can read the new rc normally.
debugfs -R "ea_get -f $TMP/selinux.xattr /system/etc/init/hw/init.rc security.selinux" "$TMP/system.patched.img" >/dev/null 2>&1   || die "lettura_selinux_xattr_fallita"
[ -s "$TMP/selinux.xattr" ] || die "selinux_xattr_vuoto"
debugfs -w -R "ea_set -f $TMP/selinux.xattr /system/etc/init/wear5diag.rc security.selinux" "$TMP/system.patched.img" >/dev/null 2>&1   || die "scrittura_selinux_xattr_fallita"

debugfs -R "cat /system/etc/init/wear5diag.rc" "$TMP/system.patched.img" > "$TMP/verify.rc" 2>/dev/null   || die "verifica_rc_locale_fallita"
cmp -s "$TMP/wear5diag.rc" "$TMP/verify.rc" || die "contenuto_rc_locale_non_corrisponde"

# Compute only the 4K blocks actually changed by debugfs. Abort if unexpectedly large.
python - "$BASE" "$TMP/system.patched.img" "$TMP/patches" "$TMP/patches.tsv" <<'PY'
import hashlib, os, sys
base, patched, outdir, manifest = sys.argv[1:]
BS=4096
if os.path.getsize(base)!=os.path.getsize(patched):
    raise SystemExit("SIZE_MISMATCH")
runs=[]
with open(base,'rb') as a, open(patched,'rb') as b:
    idx=0; start=None; chunks=[]
    while True:
        x=a.read(BS); y=b.read(BS)
        if not x and not y: break
        diff=x!=y
        if diff:
            if start is None:
                start=idx; chunks=[]
            chunks.append(y)
        elif start is not None:
            runs.append((start,chunks)); start=None; chunks=[]
        idx+=1
    if start is not None: runs.append((start,chunks))
total=sum(len(c) for _,cs in runs for c in cs)
if total==0: raise SystemExit("NO_CHANGED_BLOCKS")
if total > 32*1024*1024:
    raise SystemExit(f"PATCH_TOO_LARGE:{total}")
with open(manifest,'w') as m:
    for n,(start,cs) in enumerate(runs):
        p=os.path.join(outdir,f"patch_{n:03d}.bin")
        data=b''.join(cs)
        open(p,'wb').write(data)
        h=hashlib.sha256(data).hexdigest()
        m.write(f"{start}\t{len(cs)}\t{p}\t{h}\n")
print(f"PATCH_RUNS={len(runs)}")
print(f"PATCH_BYTES={total}")
PY

# Parse current super system extents for a temporary writable dm-linear mapping.
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
VBMETA_DEV="$("${ADB[@]}" shell 'readlink -f /dev/block/by-name/vbmeta 2>/dev/null' | tr -d '\r' | tail -1)"
VBMETA_SYS_DEV="$("${ADB[@]}" shell 'readlink -f /dev/block/by-name/vbmeta_system 2>/dev/null' | tr -d '\r' | tail -1)"
[ -n "$SUPER_DEV" ] || die "super_device_non_trovato"

TOP_FLAGS="$("${ADB[@]}" shell "dd if='$VBMETA_DEV' bs=1 skip=120 count=4 2>/dev/null | od -An -tx1" | tr -d ' \r\n')"
CHAIN_FLAGS="$("${ADB[@]}" shell "dd if='$VBMETA_SYS_DEV' bs=1 skip=120 count=4 2>/dev/null | od -An -tx1" | tr -d ' \r\n')"
[ "$TOP_FLAGS" = "00000003" ] || die "top_vbmeta_flags_$TOP_FLAGS"
[ "$CHAIN_FLAGS" = "00000000" ] || die "vbmeta_system_flags_$CHAIN_FLAGS"

# Prepare proven DIAG2-style sentinels under vold.
"${ADB[@]}" shell "[ -d /metadata/vold ]" >/dev/null 2>&1 || die "metadata_vold_non_esiste"
PARENT_Z="$("${ADB[@]}" shell "ls -Zd /metadata/vold 2>/dev/null" | tr -d '\r')"
printf '%s\n' "$PARENT_Z" | grep -q 'vold_metadata_file' || die "metadata_vold_label_non_corretto"

CORE=(01_early_init 02_init 03_late_init 04_fs 05_post_fs 06_late_fs 07_post_fs_data 08_early_boot 09_boot 20_vold_running 30_servicemanager_running 31_hwservicemanager_running 40_zygote_running 41_surfaceflinger_running 99_boot_completed)
MARKERS=("${CORE[@]}")
while IFS= read -r SVC; do
  [ -n "$SVC" ] || continue
  SAFE="$(printf '%s' "$SVC" | sed 's/[^A-Za-z0-9_.-]/_/g')"
  MARKERS+=("50_svc_$SAFE")
done < "$TMP/secure_services.txt"

"${ADB[@]}" shell "rm -rf '$META'; mkdir -p '$META'; chmod 0700 '$META'" >/dev/null || die "creazione_marker_root_fallita"
for M in "${MARKERS[@]}"; do
  "${ADB[@]}" shell "mkdir -p '$META/$M'; chmod 0700 '$META/$M'" >/dev/null || die "creazione_marker_$M"
done
for M in "__BASE__" "${MARKERS[@]}"; do
  [ "$M" = "__BASE__" ] && P="$META" || P="$META/$M"
  Z="$("${ADB[@]}" shell "ls -Zd '$P' 2>/dev/null" | tr -d '\r')"
  if ! printf '%s\n' "$Z" | grep -q 'vold_metadata_file'; then
    "${ADB[@]}" shell "chcon u:object_r:vold_metadata_file:s0 '$P'" >/dev/null 2>&1 || true
    Z="$("${ADB[@]}" shell "ls -Zd '$P' 2>/dev/null" | tr -d '\r')"
  fi
  printf '%s\n' "$Z" | grep -q 'vold_metadata_file' || die "label_marker_errata_$M"
done

# Create writable dm mapping (raw writes work even though ext4 itself refuses RW mount).
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
RO="$("${ADB[@]}" shell "blockdev --getro '$DEV' 2>/dev/null" | tr -d '\r' | tail -1)"
[ "$RO" = "0" ] || die "dm_device_readonly_$RO"

cleanup(){
  "${ADB[@]}" shell "umount /mnt/wear5diag_verify >/dev/null 2>&1 || true; $RUNNER delete '$NAME' >/dev/null 2>&1 || true" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# Stage + verify + write only changed 4K runs, then read back each run and hash it.
echo "RAW_PATCH=START"
while IFS=$'\t' read -r START BLOCKS FILE HASH; do
  BN="$(basename "$FILE")"
  "${ADB[@]}" push "$FILE" "$REMOTE/$BN" >/dev/null || die "push_$BN"
  RH="$("${ADB[@]}" shell "sha256sum '$REMOTE/$BN' 2>/dev/null" | tr -d '\r' | awk '{print $1}' | tail -1)"
  [ "$RH" = "$HASH" ] || die "stage_hash_$BN"
  "${ADB[@]}" shell "dd if='$REMOTE/$BN' of='$DEV' bs=4096 seek='$START' count='$BLOCKS' conv=notrunc,fsync 2>/dev/null"     || die "dd_patch_$BN"
  VH="$("${ADB[@]}" shell "dd if='$DEV' bs=4096 skip='$START' count='$BLOCKS' 2>/dev/null | sha256sum" | tr -d '\r' | awk '{print $1}' | tail -1)"
  [ "$VH" = "$HASH" ] || die "readback_hash_$BN"
done < "$TMP/patches.tsv"
"${ADB[@]}" shell sync >/dev/null 2>&1 || die "sync_fallito"

# Read-only mount must still work and the new rc must be visible.
"${ADB[@]}" shell "mkdir -p /mnt/wear5diag_verify; mount -t ext4 -o ro,noload '$DEV' /mnt/wear5diag_verify" >/dev/null   || die "verify_mount_ro_fallito"
ROOT=""
for R in /mnt/wear5diag_verify/system /mnt/wear5diag_verify; do
  if "${ADB[@]}" shell "[ -f '$R/etc/init/wear5diag.rc' ]" >/dev/null 2>&1; then ROOT="$R"; break; fi
done
[ -n "$ROOT" ] || die "wear5diag_rc_non_visibile"
REMOTE_RC="$("${ADB[@]}" shell "cat '$ROOT/etc/init/wear5diag.rc'" | tr -d '\r')"
LOCAL_RC="$(cat "$TMP/wear5diag.rc")"
[ "$REMOTE_RC" = "$LOCAL_RC" ] || die "wear5diag_rc_readback_mismatch"
"${ADB[@]}" shell "umount /mnt/wear5diag_verify" >/dev/null 2>&1 || true
cleanup
trap - EXIT

echo "MARKER_INSTALL=PASS"
echo "METHOD=RAW_4K_PATCH_NO_RW_MOUNT"
echo "VOLD_LABEL=VERIFIED"
echo "VBMETA_TOP_FLAGS=0x$TOP_FLAGS"
echo "VBMETA_SYSTEM_FLAGS=0x$CHAIN_FLAGS"
echo "SECURE_SERVICES=$(paste -sd, "$TMP/secure_services.txt" 2>/dev/null || true)"
echo "METADATA_DIR=$META"
echo "RECOVERY_TOUCHED=NO"
echo "NEXT=reboot_normal_once_then_read_markers"
