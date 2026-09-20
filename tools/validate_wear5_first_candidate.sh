#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail

BUILD="/storage/emulated/0/Download/WEAR5_FIRST_BUILD"
IMG="$BUILD/images"
SUPER="$IMG/super.img"
REPORT="$BUILD/VALIDATION.txt"

die(){ echo; echo "BLOCKER=$*"; exit 2; }

[ -f "$SUPER" ] || die "super.img_mancante"
[ "$(stat -c %s "$SUPER")" = "4294967296" ] || die "super.img_dimensione_errata"

command -v lpdump >/dev/null 2>&1 || pkg install -y android-tools >/dev/null
command -v lpdump >/dev/null 2>&1 || die "lpdump_non_disponibile"

LP="$BUILD/SUPER_LPDUMP.txt"
lpdump "$SUPER" > "$LP" 2>&1 || die "lpdump_non_riesce_a_leggere_super"

for P in system vendor product system_ext vendor_dlkm system_dlkm; do
  grep -Eq "(^|[[:space:]])Name:[[:space:]]+$P$|(^|[[:space:]])$P([[:space:]]|$)" "$LP" || die "partizione_${P}_non_trovata_nei_metadata_super"
done

python - "$IMG/vbmeta.img" "$IMG/vbmeta_system.img" > "$BUILD/AVB_FLAGS.txt" <<\'PY\'
import struct,sys,os
for p in sys.argv[1:]:
    if not os.path.exists(p):
        print(os.path.basename(p)+":MISSING")
        continue
    with open(p,"rb") as f:
        magic=f.read(4)
        f.seek(120)
        flags=struct.unpack(">I",f.read(4))[0]
    print(f"{os.path.basename(p)}:magic={magic.decode(errors=\'replace\')}:flags={flags}")
    if magic != b"AVB0" or flags != 3:
        raise SystemExit(2)
PY

EXPECTED="$(cut -d\' \' -f1 "$BUILD/SUPER_SHA256.txt" 2>/dev/null || true)"
ACTUAL="$(sha256sum "$SUPER" | awk \'{print $1}\')"
[ -n "$EXPECTED" ] || die "SUPER_SHA256.txt_mancante"
[ "$EXPECTED" = "$ACTUAL" ] || die "sha256_super_non_coincide"

{
  echo "VALIDATION=PASS"
  echo "SUPER_SIZE=$(stat -c %s "$SUPER")"
  echo "SUPER_SHA256=$ACTUAL"
  echo "PARTITIONS=system vendor product system_ext vendor_dlkm system_dlkm"
  echo "VBMETA_FLAGS=3"
  echo "RECOVERY_INCLUDED=NO"
  echo
  echo "=== LPDUMP KEY LINES ==="
  grep -E \'Metadata version|Metadata size|Metadata max size|Metadata slot count|Header flags|Name:|Group:|Maximum size\' "$LP" | head -n 80
} | tee "$REPORT"

echo
echo "VALIDATION_REPORT=$REPORT"
