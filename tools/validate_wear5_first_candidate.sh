#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail

BUILD="/storage/emulated/0/Download/WEAR5_FIRST_BUILD"
IMG="$BUILD/images"
SUPER="$IMG/super.img"
REPORT="$BUILD/VALIDATION.txt"
LP="$BUILD/SUPER_LPDUMP.txt"

die(){ echo; echo "BLOCKER=$*"; exit 2; }

[ -f "$SUPER" ] || die "super.img_mancante"
[ "$(stat -c %s "$SUPER")" = "4294967296" ] || die "super.img_dimensione_errata"

command -v lpdump >/dev/null 2>&1 || pkg install -y android-tools >/dev/null
command -v lpdump >/dev/null 2>&1 || die "lpdump_non_disponibile"

lpdump "$SUPER" > "$LP" 2>&1 || die "lpdump_non_riesce_a_leggere_super"

for P in system vendor product system_ext vendor_dlkm system_dlkm; do
  grep -Eq "Name:[[:space:]]+$P$|Partition name:[[:space:]]+$P$|^[[:space:]]*$P[[:space:]]" "$LP" || die "partizione_${P}_non_trovata_nei_metadata_super"
done

python - "$IMG/vbmeta.img" "$IMG/vbmeta_system.img" > "$BUILD/AVB_FLAGS.txt" <<'PY'
import os
import struct
import sys

for p in sys.argv[1:]:
    if not os.path.exists(p):
        raise SystemExit("MISSING:" + p)
    with open(p, "rb") as f:
        magic = f.read(4)
        f.seek(120)
        raw = f.read(4)
    if len(raw) != 4:
        raise SystemExit("SHORT_AVB:" + p)
    flags = struct.unpack(">I", raw)[0]
    print("{}:magic={}:flags={}".format(os.path.basename(p), magic.decode(errors="replace"), flags))
    if magic != b"AVB0" or flags != 3:
        raise SystemExit("BAD_AVB_FLAGS:" + p)
PY

EXPECTED="$(awk '{print $1; exit}' "$BUILD/SUPER_SHA256.txt" 2>/dev/null || true)"
ACTUAL="$(sha256sum "$SUPER" | awk '{print $1}')"
[ -n "$EXPECTED" ] || die "SUPER_SHA256.txt_mancante"
[ "$EXPECTED" = "$ACTUAL" ] || die "sha256_super_non_coincide"

{
  echo "VALIDATION=PASS"
  echo "SUPER_SIZE=$(stat -c %s "$SUPER")"
  echo "SUPER_SHA256=$ACTUAL"
  echo "PARTITIONS=system vendor product system_ext vendor_dlkm system_dlkm"
  echo "VBMETA_FLAGS=3"
  echo "RECOVERY_INCLUDED=NO"
} | tee "$REPORT"

echo "VALIDATION_REPORT=$REPORT"
