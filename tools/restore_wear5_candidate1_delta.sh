#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail

OLD="/storage/emulated/0/Download/WEAR5_FIRST_BUILD/images/super.img"
CUR="/storage/emulated/0/Download/WEAR5_CANDIDATE2_SYSTEM_ONLY/images/super.img"
ADB_HOST="10.82.56.57"
ADB_PORT="5037"
TARGET="${1:-C121X44260991}"
BS=4194304
OLD_EXPECTED="7fe0e1ecc6bca9d22c15f3ae21a91034a3b21589c27a4dddc6a67d40aa6c9079"
CUR_EXPECTED="0ececf37ca5deee776f635c4b0fe89c3f6afb7e0ed1a233aba043d0e9d4cd595"
TMP="$HOME/WEAR5/DELTA_RESTORE_CANDIDATE1"

die(){ echo; echo "BLOCKER=$*"; exit 2; }

for F in "$OLD" "$CUR"; do
  [ -f "$F" ] || die "file_mancante_$F"
  [ "$(stat -c %s "$F")" = "4294967296" ] || die "size_errata_$F"
done

OLD_SHA="$(sha256sum "$OLD" | awk '{print $1}')"
CUR_SHA="$(sha256sum "$CUR" | awk '{print $1}')"
[ "$OLD_SHA" = "$OLD_EXPECTED" ] || die "candidate1_local_hash_$OLD_SHA"
[ "$CUR_SHA" = "$CUR_EXPECTED" ] || die "candidate2_local_hash_$CUR_SHA"

rm -rf "$TMP"; mkdir -p "$TMP"

# Compare only locally. Group adjacent changed 4 MiB chunks into ranges.
python - "$OLD" "$CUR" "$BS" "$TMP/ranges.tsv" <<'PY'
import os,sys
old,cur,bs,out=sys.argv[1],sys.argv[2],int(sys.argv[3]),sys.argv[4]
size=os.path.getsize(old)
if size!=os.path.getsize(cur): raise SystemExit("SIZE_MISMATCH")
diff=[]
with open(old,'rb',buffering=0) as a, open(cur,'rb',buffering=0) as b:
    i=0
    while i*bs < size:
        x=a.read(bs); y=b.read(bs)
        if x!=y: diff.append(i)
        i+=1
if not diff:
    raise SystemExit("NO_DIFFERENCES")
runs=[]
s=p=diff[0]
for i in diff[1:]:
    if i==p+1:
        p=i
    else:
        runs.append((s,p-s+1)); s=p=i
runs.append((s,p-s+1))
with open(out,'w') as f:
    for s,n in runs: f.write(f"{s}\t{n}\n")
print("DELTA_CHUNKS="+str(len(diff)))
print("DELTA_BYTES="+str(len(diff)*bs))
print("DELTA_MIB="+str((len(diff)*bs)//1048576))
print("DELTA_RUNS="+str(len(runs)))
PY

ADB=(adb -H "$ADB_HOST" -P "$ADB_PORT" -s "$TARGET")
STATE="$(adb -H "$ADB_HOST" -P "$ADB_PORT" devices 2>/dev/null | awk -v s="$TARGET" '$1==s{print $2; exit}')"
case "$STATE" in recovery|device|rescue) ;; *) die "adb_state_${STATE:-vuoto}";; esac
PRODUCT="$("${ADB[@]}" shell getprop ro.product.device 2>/dev/null | tr -d '\r' | tail -1)"
[ "$PRODUCT" = "dace" ] || die "device_${PRODUCT:-vuoto}"
UIDR="$("${ADB[@]}" shell id -u 2>/dev/null | tr -d '\r' | tail -1)"
[ "$UIDR" = "0" ] || die "adb_non_root_uid_${UIDR:-vuoto}"
SUPER_DEV="$("${ADB[@]}" shell 'readlink -f /dev/block/by-name/super 2>/dev/null' | tr -d '\r' | tail -1)"
[ -n "$SUPER_DEV" ] || die "super_device_non_trovato"
[ "$("${ADB[@]}" shell "blockdev --getsize64 '$SUPER_DEV'" | tr -d '\r' | tail -1)" = "4294967296" ] || die "target_super_size_errata"

echo "PREFLIGHT=PASS"
echo "RESTORE_TARGET=CANDIDATE1"
echo "SOURCE_SHA256=$OLD_SHA"
echo "CURRENT_REFERENCE_SHA256=$CUR_SHA"
echo "SUPER_DEV=$SUPER_DEV"
echo "RECOVERY_TOUCHED=NO"

mapfile -t RANGES < "$TMP/ranges.tsv"
N=0
for ROW in "${RANGES[@]}"; do
  IFS=$'\t' read -r START COUNT <<<"$ROW"
  N=$((N+1))
  BYTES=$((COUNT*BS))
  echo "DELTA_RUN=$N/${#RANGES[@]} START_CHUNK=$START CHUNKS=$COUNT BYTES=$BYTES"

  LOCAL_HASH="$(dd if="$OLD" bs="$BS" skip="$START" count="$COUNT" status=none | sha256sum | awk '{print $1}')"

  dd if="$OLD" bs="$BS" skip="$START" count="$COUNT" status=none |     "${ADB[@]}" exec-in "dd of='$SUPER_DEV' bs=$BS seek=$START count=$COUNT conv=notrunc,fsync 2>/dev/null"     || die "stream_run_$N"

  REMOTE_HASH="$("${ADB[@]}" shell "dd if='$SUPER_DEV' bs=$BS skip=$START count=$COUNT 2>/dev/null | sha256sum" </dev/null | tr -d '\r' | awk '{print $1}' | tail -1)"
  [ "$REMOTE_HASH" = "$LOCAL_HASH" ] || die "verify_run_$N_remote_$REMOTE_HASH"
  echo "DELTA_RUN_VERIFY=PASS"
done

"${ADB[@]}" shell sync >/dev/null 2>&1 || die "sync_fallito"

echo "DELTA_RESTORE=PASS"
echo "RESTORED_TO=CANDIDATE1"
echo "EXPECTED_FULL_SUPER_SHA256=$OLD_EXPECTED"
echo "FULL_HASH_SKIPPED=YES_PER_RANGE_VERIFIED"
echo "RECOVERY_TOUCHED=NO"
echo "NEXT=boot_candidate1_or_install_vendor_markers"
