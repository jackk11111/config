#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail

WORK="$HOME/WEAR5"
SUPER_IMG="/storage/emulated/0/Download/WEAR5_FIRST_BUILD/images/super.img"
STOCK_SYS="$WORK/stock/system.img"
DONOR_SYS="$WORK/xiaomi/system.img"
ADB_HOST="10.82.56.57"
ADB_PORT="5037"
TARGET="${1:-C121X44260991}"
LOCAL="$WORK/DM_MAP_TEST"
REMOTE="/cache/wear5_dm_map_test"
PARTS=(system system_ext product vendor vendor_dlkm system_dlkm)

die(){ echo; echo "BLOCKER=$*"; exit 2; }

[ -f "$SUPER_IMG" ] || die "super_locale_mancante"
[ -f "$STOCK_SYS" ] || die "stock_system_mancante"
command -v lpdump >/dev/null 2>&1 || die "lpdump_termux_mancante"
command -v debugfs >/dev/null 2>&1 || die "debugfs_mancante"

rm -rf "$LOCAL"
mkdir -p "$LOCAL"
lpdump "$SUPER_IMG" > "$LOCAL/lpdump.txt" 2>/dev/null || die "lpdump_super_fallito"

# Parse exactly the dm-linear extents emitted by lpdump.
python - "$LOCAL/lpdump.txt" "$LOCAL/extents.tsv" <<'PY'
import re,sys
src,dst=sys.argv[1:3]
cur=None
rows=[]
for raw in open(src,encoding="utf-8",errors="ignore"):
    line=raw.rstrip("\n")
    m=re.match(r"\s*Name:\s+(\S+)\s*$", line)
    if m:
        cur=m.group(1); continue
    m=re.match(r"\s*(\d+)\s+\.\.\s+(\d+)\s+linear\s+(\S+)\s+(\d+)\s*$", line)
    if m and cur:
        lo,hi,dev,phys=m.groups()
        lo=int(lo); hi=int(hi); phys=int(phys)
        rows.append((cur,lo,hi-lo+1,dev,phys))
with open(dst,"w") as o:
    for r in rows:
        o.write("\t".join(map(str,r))+"\n")
if not rows:
    raise SystemExit("NO_LINEAR_EXTENTS")
PY

# Prefer stock Android 13 dmctl so its ABI matches this recovery; donor is fallback.
DMCTL_LOCAL="$LOCAL/dmctl"
if debugfs -R "dump /bin/dmctl $DMCTL_LOCAL" "$STOCK_SYS" >/dev/null 2>&1 && [ -s "$DMCTL_LOCAL" ]; then
  DMCTL_SOURCE="STOCK_ANDROID13"
elif [ -f "$DONOR_SYS" ] && debugfs -R "dump /bin/dmctl $DMCTL_LOCAL" "$DONOR_SYS" >/dev/null 2>&1 && [ -s "$DMCTL_LOCAL" ]; then
  DMCTL_SOURCE="DONOR_ANDROID14"
else
  die "dmctl_non_trovato_nelle_system_img"
fi
chmod 755 "$DMCTL_LOCAL"

ADB=(adb -H "$ADB_HOST" -P "$ADB_PORT" -s "$TARGET")
STATE="$(adb -H "$ADB_HOST" -P "$ADB_PORT" devices 2>/dev/null | awk -v s="$TARGET" '$1==s{print $2; exit}')"
case "$STATE" in recovery|device|rescue) ;; *) die "adb_state_${STATE:-vuoto}";; esac
PRODUCT="$("${ADB[@]}" shell getprop ro.product.device 2>/dev/null | tr -d "\r" | tail -1)"
[ "$PRODUCT" = "dace" ] || die "device_${PRODUCT:-vuoto}"
REMOTE_UID="$("${ADB[@]}" shell id -u 2>/dev/null | tr -d "\r" | tail -1)"
[ "$REMOTE_UID" = "0" ] || die "adb_non_root_uid_${REMOTE_UID:-vuoto}"
SUPER_DEV="$("${ADB[@]}" shell 'readlink -f /dev/block/by-name/super 2>/dev/null' | tr -d "\r" | tail -1)"
[ -n "$SUPER_DEV" ] || die "super_device_non_trovato"

echo "PREFLIGHT=PASS"
echo "ADB_STATE=$STATE"
echo "PRODUCT=$PRODUCT"
echo "SUPER_DEV=$SUPER_DEV"
echo "DMCTL_SOURCE=$DMCTL_SOURCE"
echo "DMCTL_FILE=$(file -b "$DMCTL_LOCAL" 2>/dev/null || true)"

"${ADB[@]}" shell "rm -rf '$REMOTE' && mkdir -p '$REMOTE'" >/dev/null || die "remote_dir_fallita"
"${ADB[@]}" push "$DMCTL_LOCAL" "$REMOTE/dmctl" >/dev/null || die "push_dmctl_fallito"
"${ADB[@]}" shell "chmod 755 '$REMOTE/dmctl'" >/dev/null 2>&1 || true

# Find a linker that can execute the 32-bit Android utility.
RUNNER=""
for LINKER in /system/bin/linker /system/bin/bootstrap/linker /apex/com.android.runtime/bin/linker; do
  if "${ADB[@]}" shell "[ -x '$LINKER' ]" >/dev/null 2>&1; then
    PROBE="$("${ADB[@]}" shell "'$LINKER' '$REMOTE/dmctl' help" 2>&1 || true)"
    if printf "%s\n" "$PROBE" | grep -qi "dmctl"; then
      RUNNER="'$LINKER' '$REMOTE/dmctl'"
      echo "DMCTL_RUNNER=$LINKER"
      break
    fi
  fi
done
if [ -z "$RUNNER" ]; then
  PROBE="$("${ADB[@]}" shell "'$REMOTE/dmctl' help" 2>&1 || true)"
  if printf "%s\n" "$PROBE" | grep -qi "dmctl"; then
    RUNNER="'$REMOTE/dmctl'"
    echo "DMCTL_RUNNER=DIRECT"
  fi
fi
[ -n "$RUNNER" ] || die "dmctl_non_eseguibile_in_recovery"

TARGETS="$("${ADB[@]}" shell "$RUNNER list targets" 2>&1 || true)"
printf "%s\n" "$TARGETS" | grep -qi "linear" || {
  echo "DM_TARGETS=$(printf "%s" "$TARGETS" | tr "\n" " " | head -c 400)"
  die "kernel_device_mapper_linear_non_disponibile"
}
echo "DM_LINEAR_TARGET=YES"

PASS=0
FAIL=0
for P in "${PARTS[@]}"; do
  echo
  echo "=== $P ==="
  mapfile -t ROWS < <(awk -F "\t" -v p="$P" '$1==p{print $2" "$3" "$5}' "$LOCAL/extents.tsv")
  if [ "${#ROWS[@]}" -eq 0 ]; then
    echo "EXTENTS=MISSING"
    FAIL=$((FAIL+1))
    continue
  fi

  NAME="wear5test_$P"
  "${ADB[@]}" shell "$RUNNER delete '$NAME' >/dev/null 2>&1 || true" >/dev/null 2>&1 || true
  ARGS=""
  for row in "${ROWS[@]}"; do
    read -r LOGSTART NUM PHYS <<<"$row"
    ARGS="$ARGS linear $LOGSTART $NUM '$SUPER_DEV' $PHYS"
  done

  set +e
  CREATE="$("${ADB[@]}" shell "$RUNNER create '$NAME' -ro $ARGS" 2>&1)"
  CRC=$?
  set -e
  if [ "$CRC" -ne 0 ]; then
    echo "DM_CREATE=FAIL"
    echo "ERROR=$(printf "%s" "$CREATE" | tr "\n" " " | head -c 400)"
    FAIL=$((FAIL+1))
    continue
  fi
  echo "DM_CREATE=PASS"

  DEV="$("${ADB[@]}" shell "$RUNNER getpath '$NAME'" 2>/dev/null | tr -d "\r" | tail -1)"
  if [ -z "$DEV" ]; then
    echo "GETPATH=FAIL"
    "${ADB[@]}" shell "$RUNNER delete '$NAME' >/dev/null 2>&1 || true" >/dev/null 2>&1 || true
    FAIL=$((FAIL+1))
    continue
  fi
  echo "DM_DEV=$DEV"

  MNT="/mnt/$NAME"
  "${ADB[@]}" shell "mkdir -p '$MNT'; umount '$MNT' >/dev/null 2>&1 || true" >/dev/null 2>&1 || true
  set +e
  MOUT="$("${ADB[@]}" shell "mount -t ext4 -o ro,noload '$DEV' '$MNT'" 2>&1)"
  MRC=$?
  set -e
  if [ "$MRC" -ne 0 ]; then
    echo "MOUNT=FAIL"
    echo "ERROR=$(printf "%s" "$MOUT" | tr "\n" " " | head -c 400)"
    FAIL=$((FAIL+1))
  else
    echo "MOUNT=PASS"
    case "$P" in
      system)
        "${ADB[@]}" shell "[ -x '$MNT/system/bin/init' -o -x '$MNT/bin/init' ] && echo INIT_PRESENT=YES || echo INIT_PRESENT=NO" | tr -d "\r"
        ;;
      vendor)
        "${ADB[@]}" shell "[ -f '$MNT/etc/fstab.dace' ] && echo FSTAB_DACE_PRESENT=YES || echo FSTAB_DACE_PRESENT=NO" | tr -d "\r"
        ;;
    esac
    "${ADB[@]}" shell "umount '$MNT'" >/dev/null 2>&1 || true
    PASS=$((PASS+1))
  fi
  "${ADB[@]}" shell "$RUNNER delete '$NAME' >/dev/null 2>&1 || true" >/dev/null 2>&1 || true
done

echo
echo "MOUNT_PASS=$PASS"
echo "MOUNT_FAIL=$FAIL"
if [ "$PASS" -eq "${#PARTS[@]}" ] && [ "$FAIL" -eq 0 ]; then
  echo "FINDING=ALL_LOGICAL_PARTITIONS_DM_MAP_AND_MOUNT"
else
  echo "FINDING=LOGICAL_DM_OR_MOUNT_FAILURE"
fi
