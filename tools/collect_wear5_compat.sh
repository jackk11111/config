#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail

WORK="$HOME/WEAR5"
S="$WORK/stock"
X="$WORK/xiaomi"
R="$WORK/STAGE2"
ZIP="/storage/emulated/0/Download/WEAR5_STAGE2_COMPAT.zip"

pkg install -y e2fsprogs zip >/dev/null
rm -rf "$R" "$ZIP"
mkdir -p "$R"/{stock,xiaomi}

dump_file() {
  IMG="$1"; PATHIN="$2"; OUT="$3"
  mkdir -p "$(dirname "$OUT")"
  debugfs -R "cat $PATHIN" "$IMG" > "$OUT" 2>/dev/null || rm -f "$OUT"
  [ -s "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
}

dump_dir() {
  IMG="$1"; PATHIN="$2"; OUT="$3"
  mkdir -p "$OUT"
  debugfs -R "rdump $PATHIN $OUT" "$IMG" >/dev/null 2>&1 || true
  find "$OUT" -type f -size 0 -delete 2>/dev/null || true
}

collect() {
  BASE="$1"; DEST="$2"

  for part in system system_ext product vendor; do
    IMG="$BASE/$part.img"
    [ -f "$IMG" ] || continue

    mkdir -p "$DEST/$part"
    debugfs -R "ls -p /" "$IMG" > "$DEST/$part/root.txt" 2>/dev/null || true
    dumpe2fs -h "$IMG" > "$DEST/$part/fs.txt" 2>/dev/null || true

    for p in \
      /build.prop \
      /system/build.prop \
      /etc/build.prop \
      /etc/prop.default \
      /system/etc/prop.default
    do
      NAME="$(printf '%s' "$p" | sed 's#^/##;s#/#_#g')"
      dump_file "$IMG" "$p" "$DEST/$part/$NAME"
    done

    dump_dir "$IMG" /etc/vintf "$DEST/$part/vintf_root"
    dump_dir "$IMG" /system/etc/vintf "$DEST/$part/vintf_system"

    if [ "$part" = "vendor" ]; then
      dump_file "$IMG" /manifest.xml "$DEST/vendor/manifest.xml"
      dump_file "$IMG" /compatibility_matrix.xml "$DEST/vendor/compatibility_matrix.xml"
      dump_dir "$IMG" /etc/init "$DEST/vendor/init"
      dump_file "$IMG" /etc/selinux/vendor_sepolicy.cil "$DEST/vendor/vendor_sepolicy.cil"
      dump_file "$IMG" /etc/selinux/plat_pub_versioned.cil "$DEST/vendor/plat_pub_versioned.cil"
    fi
  done
}

echo "[1/3] Estraggo configurazione TicWatch..."
collect "$S" "$R/stock"

echo "[2/3] Estraggo configurazione Xiaomi Wear 5..."
collect "$X" "$R/xiaomi"

echo "[3/3] Creo report compatto..."
{
  echo "=== TARGET / DONOR ==="
  echo "TARGET=dace / Android 13 / TMDB.240925.002"
  echo "DONOR=axolotl BT / Android 14 / AW2A.240903.001.XM118S"
  echo
  echo "=== IMPORTANT BUILD PROPERTIES ==="
  grep -RhsE \
    '^(ro\.(build\.version\.(sdk|release|security_patch)|product\.(first_api_level|vendor\.device|device)|vendor\.build\.version\.sdk|vndk\.version|treble\.enabled)|ro\.build\.fingerprint|ro\.vendor\.build\.fingerprint)=' \
    "$R" 2>/dev/null | sort -u
  echo
  echo "=== VINTF FILES ==="
  find "$R" -type f | grep -E '/vintf_|manifest\.xml$|compatibility_matrix\.xml$' | sed "s#$R/##" | sort
} > "$R/SUMMARY.txt"

cd "$R"
zip -qr "$ZIP" .
echo
cat "$R/SUMMARY.txt"
echo
echo "READY=$ZIP"
