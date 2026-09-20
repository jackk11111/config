#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail

STOCK="/storage/emulated/0/Download/Telegram/Watch/ota/2269bd24a774cae37adc720d3d97bd1b76846e2b.zip"
XIAOMI="/storage/emulated/0/Download/Telegram/Watch/ota/45edfde154e93d5396c5d4902ff09bd28eab8b0a.zip"

WORK="$HOME/WEAR5"
OUT_STOCK="$WORK/stock"
OUT_XIAOMI="$WORK/xiaomi"
TMP="$WORK/tmp"

mkdir -p "$OUT_STOCK" "$OUT_XIAOMI" "$TMP"
pkg install -y python unzip brotli file coreutils >/dev/null

cat > "$WORK/sdat2img_min.py" <<'PY'
#!/usr/bin/env python3
import os, sys

BS=4096

def ranges(spec):
    n=[int(x) for x in spec.split(',')]
    if not n or n[0] != len(n)-1 or n[0] % 2:
        raise ValueError("bad rangeset: "+spec)
    return list(zip(n[1::2], n[2::2]))

def main(tl_path, dat_path, out_path):
    with open(tl_path, 'r', encoding='utf-8') as f:
        lines=[x.strip() for x in f if x.strip()]
    ver=int(lines[0]); total=int(lines[1])
    i=2
    if ver >= 2:
        i += 2

    cmds=[]
    bad=set()
    for line in lines[i:]:
        op,*rest=line.split()
        if op in ("new","zero","erase"):
            cmds.append((op,rest))
        else:
            bad.add(op)

    if bad:
        raise SystemExit("INCREMENTAL_UNSUPPORTED_OPS=" + ",".join(sorted(bad)))

    with open(dat_path,'rb') as src, open(out_path,'w+b') as out:
        out.truncate(total*BS)
        for op,rest in cmds:
            if not rest:
                continue
            for a,b in ranges(rest[0]):
                blocks=b-a
                if op=="new":
                    need=blocks*BS
                    data=src.read(need)
                    if len(data)!=need:
                        raise SystemExit(f"SHORT_NEW_DAT expected={need} got={len(data)}")
                    out.seek(a*BS)
                    out.write(data)
        extra=src.read(1)
        if extra:
            raise SystemExit("EXTRA_NEW_DAT_BYTES")
    print(f"OK {os.path.basename(out_path)} {total*BS}")

if __name__=="__main__":
    main(*sys.argv[1:4])
PY
chmod 755 "$WORK/sdat2img_min.py"

extract_logical () {
    ZIP="$1"; PART="$2"; OUTDIR="$3"; LABEL="$4"
    TL="$TMP/${LABEL}_${PART}.transfer.list"
    DAT="$TMP/${LABEL}_${PART}.new.dat"
    BR="$DAT.br"

    unzip -p "$ZIP" "$PART.transfer.list" > "$TL"

    if unzip -Z1 "$ZIP" | grep -qx "$PART.new.dat"; then
        unzip -p "$ZIP" "$PART.new.dat" > "$DAT"
    elif unzip -Z1 "$ZIP" | grep -qx "$PART.new.dat.br"; then
        unzip -p "$ZIP" "$PART.new.dat.br" > "$BR"
        brotli -d -f "$BR"
        rm -f "$BR"
    else
        echo "SKIP $LABEL/$PART (no new.dat)"
        return 0
    fi

    python "$WORK/sdat2img_min.py" "$TL" "$DAT" "$OUTDIR/$PART.img"
    rm -f "$TL" "$DAT"
}

extract_raw () {
    ZIP="$1"; ENTRY="$2"; DEST="$3"
    if unzip -Z1 "$ZIP" | grep -qx "$ENTRY"; then
        unzip -p "$ZIP" "$ENTRY" > "$DEST"
        echo "OK $(basename "$DEST") $(stat -c %s "$DEST")"
    fi
}

echo "[1/3] TicWatch logical images"
for p in system system_ext product vendor system_dlkm vendor_dlkm; do
    extract_logical "$STOCK" "$p" "$OUT_STOCK" stock
done

echo "[2/3] Xiaomi Wear5 logical images"
for p in system system_ext product vendor system_dlkm vendor_dlkm; do
    extract_logical "$XIAOMI" "$p" "$OUT_XIAOMI" xiaomi
done

echo "[3/3] Boot/AVB images"
for p in boot init_boot vendor_boot dtbo vbmeta vbmeta_system; do
    extract_raw "$STOCK" "$p.img" "$OUT_STOCK/$p.img"
done

extract_raw "$XIAOMI" "boot.img" "$OUT_XIAOMI/boot.img"
for p in init_boot vendor_boot dtbo vbmeta vbmeta_system; do
    extract_raw "$XIAOMI" "firmware-update/$p.img" "$OUT_XIAOMI/$p.img"
done

{
    echo "=== TICWATCH ==="
    for f in "$OUT_STOCK"/*.img; do
        [ -e "$f" ] || continue
        printf '%-24s %12s  ' "$(basename "$f")" "$(stat -c %s "$f")"
        file -b "$f" | head -c 120
        echo
    done
    echo
    echo "=== XIAOMI WEAR5 ==="
    for f in "$OUT_XIAOMI"/*.img; do
        [ -e "$f" ] || continue
        printf '%-24s %12s  ' "$(basename "$f")" "$(stat -c %s "$f")"
        file -b "$f" | head -c 120
        echo
    done
} | tee "$WORK/EXTRACT_RESULT.txt"

echo
echo "DONE=$WORK/EXTRACT_RESULT.txt"
