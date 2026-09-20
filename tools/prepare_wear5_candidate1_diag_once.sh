#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail

WORK="$HOME/WEAR5"
C1="/storage/emulated/0/Download/WEAR5_FIRST_BUILD/images/super.img"
C2="/storage/emulated/0/Download/WEAR5_CANDIDATE2_SYSTEM_ONLY/images/super.img"
STOCK_VENDOR="$WORK/stock/vendor.img"
STOCK_SYSTEM="$WORK/stock/system.img"
ADB_HOST="10.82.56.57"
ADB_PORT="5037"
TARGET="${1:-C121X44260991}"
TMP="$WORK/CANDIDATE1_DIAG_ONCE"
REMOTE="/cache/wear5_c1diag"
REMOTE_STAGE="$REMOTE/stage.bin"
META="/metadata/vold/wear5diag"
BS=4194304
RAW_MAX_CHUNKS=64
C1_SHA="7fe0e1ecc6bca9d22c15f3ae21a91034a3b21589c27a4dddc6a67d40aa6c9079"
C2_SHA="0ececf37ca5deee776f635c4b0fe89c3f6afb7e0ed1a233aba043d0e9d4cd595"

die(){ echo; echo "BLOCKER=$*"; exit 2; }

for F in "$C1" "$C2" "$STOCK_VENDOR" "$STOCK_SYSTEM"; do
  [ -f "$F" ] || die "file_mancante_$F"
done
for C in debugfs lpdump python sha256sum gzip; do
  command -v "$C" >/dev/null 2>&1 || die "tool_mancante_$C"
done
[ "$(sha256sum "$C1" | awk '{print $1}')" = "$C1_SHA" ] || die "candidate1_hash_locale_errato"
[ "$(sha256sum "$C2" | awk '{print $1}')" = "$C2_SHA" ] || die "candidate2_hash_locale_errato"

rm -rf "$TMP"
mkdir -p "$TMP/vendor_tree" "$TMP/vendor_patch"

# ---------- Build marker rc inside a LOCAL COPY of stock TicWatch vendor ----------
echo "[1/6] PREPARE_VENDOR_DIAG"
cp --reflink=auto --sparse=always "$STOCK_VENDOR" "$TMP/vendor.patched.img"

debugfs -R "rdump /etc/init $TMP/vendor_tree" "$STOCK_VENDOR" >/dev/null 2>&1 || true
grep -RhsE '^[[:space:]]*service[[:space:]]+' "$TMP/vendor_tree" 2>/dev/null   | awk '{print $2}' | grep -Ei 'qsee|keymaster|keymint' | sort -u > "$TMP/secure_services.txt" || true

cat > "$TMP/wear5diag.rc" <<'EOF'
# WEAR5-DIAG2-BEGIN
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

on property:init.svc.apexd=running
    chmod 0777 /metadata/vold/wear5diag/10_apexd_running
on property:init.svc.vold=running
    chmod 0777 /metadata/vold/wear5diag/20_vold_running
on property:init.svc.servicemanager=running
    chmod 0777 /metadata/vold/wear5diag/30_servicemanager_running
on property:init.svc.hwservicemanager=running
    chmod 0777 /metadata/vold/wear5diag/31_hwservicemanager_running
on property:init.svc.keystore2=running
    chmod 0777 /metadata/vold/wear5diag/35_keystore2_running
on property:init.svc.zygote=running
    chmod 0777 /metadata/vold/wear5diag/40_zygote_running
on property:init.svc.surfaceflinger=running
    chmod 0777 /metadata/vold/wear5diag/41_surfaceflinger_running
on property:init.svc.bootanim=running
    chmod 0777 /metadata/vold/wear5diag/42_bootanim_running
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
echo '# WEAR5-DIAG2-END' >> "$TMP/wear5diag.rc"
chmod 0644 "$TMP/wear5diag.rc"

# Find an existing vendor init rc as SELinux xattr template.
TEMPLATE="$(debugfs -R "ls -p /etc/init" "$STOCK_VENDOR" 2>/dev/null | awk -F/ '$3 ~ /^100/ && $6 ~ /[.]rc$/ {print "/etc/init/"$6; exit}')"
if [ -z "$TEMPLATE" ]; then
  TEMPLATE="$(debugfs -R "ls -p /etc/init/hw" "$STOCK_VENDOR" 2>/dev/null | awk -F/ '$3 ~ /^100/ && $6 ~ /[.]rc$/ {print "/etc/init/hw/"$6; exit}')"
fi
[ -n "$TEMPLATE" ] || die "nessun_vendor_init_rc_template"

# Remove stale local diagnostic file only in the local copy.
debugfs -w -R "rm /etc/init/wear5diag.rc" "$TMP/vendor.patched.img" >/dev/null 2>&1 || true
debugfs -w -R "write $TMP/wear5diag.rc /etc/init/wear5diag.rc" "$TMP/vendor.patched.img" >/dev/null 2>&1   || die "scrittura_vendor_diag_rc_fallita"
debugfs -w -R "set_inode_field /etc/init/wear5diag.rc mode 0100644" "$TMP/vendor.patched.img" >/dev/null 2>&1 || true
debugfs -w -R "set_inode_field /etc/init/wear5diag.rc uid 0" "$TMP/vendor.patched.img" >/dev/null 2>&1 || true
debugfs -w -R "set_inode_field /etc/init/wear5diag.rc gid 0" "$TMP/vendor.patched.img" >/dev/null 2>&1 || true

if debugfs -R "ea_get -f $TMP/vendor_selinux.xattr $TEMPLATE security.selinux" "$STOCK_VENDOR" >/dev/null 2>&1    && [ -s "$TMP/vendor_selinux.xattr" ]; then
  debugfs -w -R "ea_set -f $TMP/vendor_selinux.xattr /etc/init/wear5diag.rc security.selinux" "$TMP/vendor.patched.img" >/dev/null 2>&1     || die "vendor_diag_selinux_xattr_fallita"
else
  die "vendor_template_selinux_xattr_non_disponibile"
fi

debugfs -R "cat /etc/init/wear5diag.rc" "$TMP/vendor.patched.img" > "$TMP/vendor_diag_verify.rc" 2>/dev/null   || die "vendor_diag_readback_locale_fallito"
cmp -s "$TMP/wear5diag.rc" "$TMP/vendor_diag_verify.rc" || die "vendor_diag_content_mismatch"

# Generate only changed 4K blocks for vendor.
python - "$STOCK_VENDOR" "$TMP/vendor.patched.img" "$TMP/vendor_patch" "$TMP/vendor_patch.tsv" <<'PY'
import hashlib,os,sys
base,patched,outdir,manifest=sys.argv[1:]
BS=4096
runs=[]
with open(base,'rb') as a, open(patched,'rb') as b:
    idx=0; start=None; chunks=[]
    while True:
        x=a.read(BS); y=b.read(BS)
        if not x and not y: break
        if x!=y:
            if start is None: start=idx; chunks=[]
            chunks.append(y)
        elif start is not None:
            runs.append((start,chunks)); start=None; chunks=[]
        idx+=1
    if start is not None: runs.append((start,chunks))
if not runs: raise SystemExit("NO_VENDOR_PATCH")
total=0
with open(manifest,'w') as m:
    for n,(start,chunks) in enumerate(runs):
        data=b''.join(chunks); total+=len(data)
        p=os.path.join(outdir,f"vendor_patch_{n:03d}.bin")
        open(p,'wb').write(data)
        m.write(f"{start}\t{len(chunks)}\t{p}\t{hashlib.sha256(data).hexdigest()}\n")
print("VENDOR_PATCH_RUNS="+str(len(runs)))
print("VENDOR_PATCH_BYTES="+str(total))
PY

# ---------- Local C1 vs C2 delta ----------
echo "[2/6] PREPARE_CANDIDATE1_DELTA"
python - "$C1" "$C2" "$BS" "$TMP/c1_delta.tsv" <<'PY'
import os,sys
a,b,bs,out=sys.argv[1],sys.argv[2],int(sys.argv[3]),sys.argv[4]
if os.path.getsize(a)!=os.path.getsize(b): raise SystemExit("SUPER_SIZE_MISMATCH")
diff=[]
with open(a,'rb',buffering=0) as x, open(b,'rb',buffering=0) as y:
    i=0
    while True:
        p=x.read(bs); q=y.read(bs)
        if not p and not q: break
        if p!=q: diff.append(i)
        i+=1
if not diff: raise SystemExit("NO_C1_C2_DIFF")
runs=[]; s=p=diff[0]
for i in diff[1:]:
    if i==p+1: p=i
    else: runs.append((s,p-s+1)); s=p=i
runs.append((s,p-s+1))
with open(out,'w') as f:
    for s,n in runs: f.write(f"{s}\t{n}\n")
print("DELTA_CHUNKS="+str(len(diff)))
print("DELTA_MIB="+str(len(diff)*bs//1048576))
print("DELTA_RUNS="+str(len(runs)))
PY

# ---------- Recovery preflight ----------
echo "[3/6] RECOVERY_PREFLIGHT"
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
[ "$("${ADB[@]}" shell "blockdev --getsize64 '$SUPER_DEV'" | tr -d '\r' | tail -1)" = "4294967296" ] || die "super_size_target_errata"

TOP_FLAGS="$("${ADB[@]}" shell "dd if='$VBMETA_DEV' bs=1 skip=120 count=4 2>/dev/null | od -An -tx1" | tr -d ' \r\n')"
CHAIN_FLAGS="$("${ADB[@]}" shell "dd if='$VBMETA_SYS_DEV' bs=1 skip=120 count=4 2>/dev/null | od -An -tx1" | tr -d ' \r\n')"
[ "$TOP_FLAGS" = "00000003" ] || die "top_vbmeta_flags_$TOP_FLAGS"
[ "$CHAIN_FLAGS" = "00000000" ] || die "vbmeta_system_flags_$CHAIN_FLAGS"

"${ADB[@]}" shell "rm -rf '$REMOTE'; mkdir -p '$REMOTE'" >/dev/null || die "remote_dir_fallita"

# ---------- Restore C1 in verified staged groups ----------
echo "[4/6] RESTORE_CANDIDATE1_DELTA_FAST"
# Bulk restore: up to 256 MiB raw per transfer, gzip-compressed locally,
# staged + hashed on watch, then decompressed locally into super.
# This reduces ~75 tiny network round-trips to only a handful.
mapfile -t RANGES < "$TMP/c1_delta.tsv"

# Locate a gzip-capable command in recovery.
GZIP_RUNNER=""
for CAND in "/system/bin/toybox gzip" "/system/bin/gzip" "/sbin/gzip" "toybox gzip" "gzip"; do
  OUT="$("${ADB[@]}" shell "$CAND --help" </dev/null 2>&1 || true)"
  if printf '%s\n' "$OUT" | grep -qiE 'gzip|compress|decompress'; then
    GZIP_RUNNER="$CAND"
    break
  fi
done
[ -n "$GZIP_RUNNER" ] || die "gzip_non_disponibile_in_recovery"
echo "REMOTE_GZIP=$GZIP_RUNNER"

CACHE_AVAIL_KB="$("${ADB[@]}" shell "df -k /cache 2>/dev/null | tail -1 | awk '{print \\$4}'" </dev/null | tr -d '\r' | tail -1)"
case "$CACHE_AVAIL_KB" in ''|*[!0-9]*) CACHE_AVAIL_KB=65536 ;; esac
CACHE_LIMIT=$((CACHE_AVAIL_KB*1024*70/100))
echo "CACHE_AVAILABLE_BYTES=$((CACHE_AVAIL_KB*1024))"
echo "CACHE_STAGE_LIMIT=$CACHE_LIMIT"

TOTAL_RAW=0
for ROW in "${RANGES[@]}"; do
  IFS=$'\t' read -r S N <<<"$ROW"
  TOTAL_RAW=$((TOTAL_RAW + N*BS))
done
echo "DELTA_RAW_BYTES=$TOTAL_RAW"

G=0
for ROW in "${RANGES[@]}"; do
  IFS=$'\t' read -r RUN_START RUN_COUNT <<<"$ROW"
  OFF=0
  while [ "$OFF" -lt "$RUN_COUNT" ]; do
    CNT=$RAW_MAX_CHUNKS
    REM=$((RUN_COUNT-OFF))
    [ "$REM" -lt "$CNT" ] && CNT=$REM
    START=$((RUN_START+OFF))

    # Build a compressed chunk. If it does not fit comfortably in /cache,
    # halve its raw size until it does.
    while :; do
      RAW_FILE="$TMP/c1_raw_chunk.bin"
      GZ_FILE="$TMP/c1_chunk.bin.gz"
      dd if="$C1" of="$RAW_FILE" bs="$BS" skip="$START" count="$CNT" status=none
      RAW_HASH="$(sha256sum "$RAW_FILE" | awk '{print $1}')"
      gzip -1 -c "$RAW_FILE" > "$GZ_FILE"
      GZ_SIZE="$(stat -c %s "$GZ_FILE")"
      if [ "$GZ_SIZE" -le "$CACHE_LIMIT" ] || [ "$CNT" -le 1 ]; then
        break
      fi
      CNT=$(( (CNT+1)/2 ))
    done

    G=$((G+1))
    RAW_BYTES=$((CNT*BS))
    echo "BULK=$G START=$START RAW_MIB=$((RAW_BYTES/1048576)) COMPRESSED_MIB=$((GZ_SIZE/1048576))"

    # Skip transfer if this exact target range already matches Candidate 1
    # (useful after an interrupted earlier restore).
    CURRENT_HASH="$("${ADB[@]}" shell "dd if='$SUPER_DEV' bs=$BS skip=$START count=$CNT 2>/dev/null | sha256sum" </dev/null | tr -d '\r' | awk '{print $1}' | tail -1)"
    if [ "$CURRENT_HASH" = "$RAW_HASH" ]; then
      echo "BULK_STATUS=ALREADY_CORRECT"
      OFF=$((OFF+CNT))
      continue
    fi

    GZ_HASH="$(sha256sum "$GZ_FILE" | awk '{print $1}')"
    "${ADB[@]}" push "$GZ_FILE" "$REMOTE_STAGE.gz" </dev/null >/dev/null || die "bulk_push_$G"
    STAGE_HASH="$("${ADB[@]}" shell "sha256sum '$REMOTE_STAGE.gz' 2>/dev/null" </dev/null | tr -d '\r' | awk '{print $1}' | tail -1)"
    [ "$STAGE_HASH" = "$GZ_HASH" ] || die "bulk_stage_hash_$G"

    "${ADB[@]}" shell "$GZIP_RUNNER -dc '$REMOTE_STAGE.gz' | dd of='$SUPER_DEV' bs=$BS seek=$START conv=notrunc,fsync 2>/dev/null" </dev/null       || die "bulk_write_$G"

    VERIFY_HASH="$("${ADB[@]}" shell "dd if='$SUPER_DEV' bs=$BS skip=$START count=$CNT 2>/dev/null | sha256sum" </dev/null | tr -d '\r' | awk '{print $1}' | tail -1)"
    [ "$VERIFY_HASH" = "$RAW_HASH" ] || die "bulk_verify_$G"
    echo "BULK_STATUS=PASS"

    OFF=$((OFF+CNT))
  done
done
"${ADB[@]}" shell "rm -f '$REMOTE_STAGE.gz'; sync" </dev/null >/dev/null 2>&1 || die "c1_sync_fallito"
echo "CANDIDATE1_DELTA=PASS"

# ---------- Prepare DIAG2 metadata sentinels ----------
echo "[5/6] PREPARE_DIAG2_MARKERS"
"${ADB[@]}" shell "[ -d /metadata/vold ]" >/dev/null 2>&1 || die "metadata_vold_non_esiste"
PARENT_Z="$("${ADB[@]}" shell "ls -Zd /metadata/vold 2>/dev/null" | tr -d '\r')"
printf '%s\n' "$PARENT_Z" | grep -q 'vold_metadata_file' || die "metadata_vold_label_errata"

CORE=(01_early_init 02_init 03_late_init 04_fs 05_post_fs 06_late_fs 07_post_fs_data 08_early_boot 09_boot 10_apexd_running 20_vold_running 30_servicemanager_running 31_hwservicemanager_running 35_keystore2_running 40_zygote_running 41_surfaceflinger_running 42_bootanim_running 99_boot_completed)
MARKERS=("${CORE[@]}")
while IFS= read -r SVC; do
  [ -n "$SVC" ] || continue
  SAFE="$(printf '%s' "$SVC" | sed 's/[^A-Za-z0-9_.-]/_/g')"
  MARKERS+=("50_svc_$SAFE")
done < "$TMP/secure_services.txt"

"${ADB[@]}" shell "rm -rf '$META'; mkdir -p '$META'; chmod 0700 '$META'" >/dev/null || die "marker_root_create"
for M in "${MARKERS[@]}"; do
  "${ADB[@]}" shell "mkdir -p '$META/$M'; chmod 0700 '$META/$M'" >/dev/null || die "marker_create_$M"
done
for M in "__BASE__" "${MARKERS[@]}"; do
  [ "$M" = "__BASE__" ] && P="$META" || P="$META/$M"
  Z="$("${ADB[@]}" shell "ls -Zd '$P' 2>/dev/null" | tr -d '\r')"
  if ! printf '%s\n' "$Z" | grep -q 'vold_metadata_file'; then
    "${ADB[@]}" shell "chcon u:object_r:vold_metadata_file:s0 '$P'" >/dev/null 2>&1 || true
    Z="$("${ADB[@]}" shell "ls -Zd '$P' 2>/dev/null" | tr -d '\r')"
  fi
  printf '%s\n' "$Z" | grep -q 'vold_metadata_file' || die "marker_label_$M"
done
echo "DIAG2_MARKERS=READY"

# ---------- Patch ONLY vendor logical partition with marker rc ----------
echo "[6/6] PATCH_VENDOR_DIAG"
lpdump "$C1" > "$TMP/c1_lpdump.txt" 2>/dev/null || die "c1_lpdump_fallito"
python - "$TMP/c1_lpdump.txt" "$TMP/vendor.extents" <<'PY'
import re,sys
src,dst=sys.argv[1:3]
cur=None; rows=[]
for raw in open(src,encoding="utf-8",errors="ignore"):
    s=raw.rstrip("\n")
    m=re.match(r"\s*Name:\s+(\S+)\s*$",s)
    if m: cur=m.group(1); continue
    m=re.match(r"\s*(\d+)\s+\.\.\s+(\d+)\s+linear\s+(\S+)\s+(\d+)\s*$",s)
    if m and cur=="vendor":
        lo,hi,dev,phys=m.groups(); lo=int(lo); hi=int(hi); phys=int(phys)
        rows.append((lo,hi-lo+1,phys))
if not rows: raise SystemExit("NO_VENDOR_EXTENTS")
with open(dst,"w") as f:
    for r in rows: f.write("%d %d %d\n"%r)
PY

DMCTL="$TMP/dmctl"
debugfs -R "dump /bin/dmctl $DMCTL" "$STOCK_SYSTEM" >/dev/null 2>&1 || die "dmctl_extract_fallito"
chmod 755 "$DMCTL"
"${ADB[@]}" push "$DMCTL" "$REMOTE/dmctl" </dev/null >/dev/null || die "dmctl_push_fallito"
"${ADB[@]}" shell "chmod 755 '$REMOTE/dmctl'" >/dev/null

RUNNER=""
for L in /system/bin/linker /system/bin/bootstrap/linker /apex/com.android.runtime/bin/linker; do
  if "${ADB[@]}" shell "[ -x '$L' ]" >/dev/null 2>&1; then
    P="$("${ADB[@]}" shell "'$L' '$REMOTE/dmctl' help" 2>&1 || true)"
    if printf '%s\n' "$P" | grep -qi dmctl; then RUNNER="'$L' '$REMOTE/dmctl'"; break; fi
  fi
done
[ -n "$RUNNER" ] || die "dmctl_non_eseguibile"

NAME="wear5diag_vendor"
"${ADB[@]}" shell "$RUNNER delete '$NAME' >/dev/null 2>&1 || true" >/dev/null 2>&1 || true
ARGS=""
while read -r LOG NUM PHYS; do ARGS="$ARGS linear $LOG $NUM '$SUPER_DEV' $PHYS"; done < "$TMP/vendor.extents"
"${ADB[@]}" shell "$RUNNER create '$NAME' $ARGS" >/dev/null || die "vendor_dm_create"
VDEV="$("${ADB[@]}" shell "$RUNNER getpath '$NAME'" | tr -d '\r' | tail -1)"
[ -n "$VDEV" ] || die "vendor_dm_getpath"

cleanup(){
  "${ADB[@]}" shell "umount /mnt/wear5diag_vendor >/dev/null 2>&1 || true; $RUNNER delete '$NAME' >/dev/null 2>&1 || true" >/dev/null 2>&1 || true
}
trap cleanup EXIT

mapfile -t VPATCH < "$TMP/vendor_patch.tsv"
V=0
for ROW in "${VPATCH[@]}"; do
  IFS=$'\t' read -r START BLOCKS FILE HASH <<<"$ROW"
  V=$((V+1))
  BN="$(basename "$FILE")"
  "${ADB[@]}" push "$FILE" "$REMOTE/$BN" </dev/null >/dev/null || die "vendor_patch_push_$V"
  SH="$("${ADB[@]}" shell "sha256sum '$REMOTE/$BN' 2>/dev/null" </dev/null | tr -d '\r' | awk '{print $1}' | tail -1)"
  [ "$SH" = "$HASH" ] || die "vendor_patch_stage_hash_$V"
  "${ADB[@]}" shell "dd if='$REMOTE/$BN' of='$VDEV' bs=4096 seek='$START' count='$BLOCKS' conv=notrunc,fsync 2>/dev/null" </dev/null     || die "vendor_patch_write_$V"
  RH="$("${ADB[@]}" shell "dd if='$VDEV' bs=4096 skip='$START' count='$BLOCKS' 2>/dev/null | sha256sum" </dev/null | tr -d '\r' | awk '{print $1}' | tail -1)"
  [ "$RH" = "$HASH" ] || die "vendor_patch_verify_$V"
done
"${ADB[@]}" shell sync >/dev/null 2>&1 || die "vendor_patch_sync"

"${ADB[@]}" shell "mkdir -p /mnt/wear5diag_vendor; mount -t ext4 -o ro,noload '$VDEV' /mnt/wear5diag_vendor" >/dev/null   || die "vendor_verify_mount"
[ "$("${ADB[@]}" shell "[ -f /mnt/wear5diag_vendor/etc/init/wear5diag.rc ]; echo $?" | tr -d '\r' | tail -1)" = "0" ]   || die "vendor_diag_rc_non_visibile"
REMOTE_RC="$("${ADB[@]}" shell "cat /mnt/wear5diag_vendor/etc/init/wear5diag.rc" | tr -d '\r')"
LOCAL_RC="$(cat "$TMP/wear5diag.rc")"
[ "$REMOTE_RC" = "$LOCAL_RC" ] || die "vendor_diag_rc_mismatch"
"${ADB[@]}" shell "umount /mnt/wear5diag_vendor" >/dev/null 2>&1 || true
cleanup
trap - EXIT

echo
echo "READY=PASS"
echo "BASE=CANDIDATE1"
echo "DIAGNOSTIC_LOCATION=VENDOR"
echo "SYSTEM_XIAOMI_UNMODIFIED=YES"
echo "PRODUCT_XIAOMI=YES"
echo "SYSTEM_EXT_XIAOMI=YES"
echo "VENDOR_TICWATCH_WITH_DIAG=YES"
echo "METADATA_MARKERS=READY"
echo "SECURE_SERVICES=$(paste -sd, "$TMP/secure_services.txt" 2>/dev/null || true)"
echo "VBMETA_TOP_FLAGS=0x$TOP_FLAGS"
echo "VBMETA_SYSTEM_FLAGS=0x$CHAIN_FLAGS"
echo "RECOVERY_TOUCHED=NO"
echo "RESTORE_METHOD=GZIP_BULK_STAGED_VERIFIED"
echo "REBOOTING=NOW"
"${ADB[@]}" shell sync >/dev/null 2>&1 || true
"${ADB[@]}" reboot
