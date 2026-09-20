#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail

WORK="$HOME/WEAR5"
VENDOR="$WORK/stock/vendor.img"
PRODUCT="$WORK/xiaomi/product.img"
TMP="$WORK/POSTFS_AFTER_MARKER_AUDIT"

die(){ echo; echo "BLOCKER=$*"; exit 2; }

command -v debugfs >/dev/null 2>&1 || die "debugfs_mancante"
command -v python >/dev/null 2>&1 || die "python_mancante"
[ -f "$VENDOR" ] || die "vendor_stock_mancante"
[ -f "$PRODUCT" ] || die "product_xiaomi_mancante"

rm -rf "$TMP"
mkdir -p "$TMP/vendor" "$TMP/product"

extract_init_dir() {
  local img="$1" out="$2" label="$3"
  local p
  for p in /etc/init /product/etc/init /vendor/etc/init; do
    rm -rf "$out"/*
    if debugfs -R "rdump $p $out" "$img" >/dev/null 2>&1; then
      if find "$out" -type f -name '*.rc' -print -quit | grep -q .; then
        echo "$label INIT_PATH=$p"
        return 0
      fi
    fi
  done
  die "${label}_init_dir_non_trovata"
}

echo "[1/3] EXTRACT_INIT_RC"
extract_init_dir "$VENDOR" "$TMP/vendor" "VENDOR"
extract_init_dir "$PRODUCT" "$TMP/product" "PRODUCT"

echo "[2/3] PARSE_ONLY_POST_FS_ACTIONS_AFTER_VENDOR_MARKER"
python - "$TMP/vendor" "$TMP/product" <<'PY'
import os,sys,re
vendor,product=sys.argv[1:]

def sections(path):
    lines=open(path,encoding='utf-8',errors='replace').read().splitlines()
    out=[]
    i=0
    while i<len(lines):
        s=lines[i].strip()
        if s.startswith('on '):
            trig=s[3:].strip()
            body=[]
            j=i+1
            while j<len(lines):
                t=lines[j].strip()
                if t.startswith('on ') or t.startswith('service ') or t.startswith('import '):
                    break
                if t and not t.startswith('#'):
                    body.append(lines[j].rstrip())
                j+=1
            out.append((i+1,trig,body))
            i=j
        else:
            i+=1
    return out

def is_postfs(trig):
    parts=[p.strip() for p in trig.split('&&')]
    return 'post-fs' in parts

rows=[]
for root,label,filter_after in [(vendor,'VENDOR_AFTER_MARKER',True),(product,'PRODUCT',False)]:
    files=[]
    for dp,_,fn in os.walk(root):
        for f in fn:
            if f.endswith('.rc'):
                files.append(os.path.join(dp,f))
    files.sort(key=lambda p:(os.path.basename(p),p))
    for p in files:
        bn=os.path.basename(p)
        if filter_after and bn <= 'wear5diag.rc':
            continue
        for line,trig,body in sections(p):
            if is_postfs(trig):
                rows.append((label,bn,line,trig,body))

print(f"POST_FS_ACTIONS_AFTER_MARKER={len(rows)}")
for n,(label,bn,line,trig,body) in enumerate(rows,1):
    print()
    print(f"=== ACTION {n}: {label}/{bn}:{line} ===")
    print("on "+trig)
    for x in body:
        print(x)

blocking=[]
pat=re.compile(r'^\s*(exec(?:_start)?|wait(?:_for_prop)?|mount_all|mount|umount|restorecon_recursive|restorecon\s+--recursive)\b')
for label,bn,line,trig,body in rows:
    for x in body:
        if pat.match(x):
            blocking.append((label,bn,line,x.strip()))

print()
print(f"SYNCHRONOUS_OR_POTENTIALLY_BLOCKING_COMMANDS={len(blocking)}")
for label,bn,line,x in blocking:
    print(f"{label}/{bn}:{line}: {x}")
PY

echo
echo "[3/3] RESULT"
echo "AUDIT=PASS"
echo "WATCH_TOUCHED=NO"
