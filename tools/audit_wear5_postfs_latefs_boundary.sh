#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail

WORK="$HOME/WEAR5"
SYS="$WORK/xiaomi/system.img"
SEXT="$WORK/xiaomi/system_ext.img"
VENDOR="$WORK/stock/vendor.img"
PRODUCT="$WORK/xiaomi/product.img"
ODM="$WORK/stock/odm.img"
TMP="$WORK/LATEFS_BOUNDARY_AUDIT"

die(){ echo; echo "BLOCKER=$*"; exit 2; }
command -v debugfs >/dev/null 2>&1 || die "debugfs_mancante"
command -v python >/dev/null 2>&1 || die "python_mancante"

for F in "$SYS" "$SEXT" "$VENDOR" "$PRODUCT"; do [ -f "$F" ] || die "file_mancante_$F"; done

rm -rf "$TMP"
mkdir -p "$TMP"/{system,system_ext,vendor,product,odm}

dump_init(){
  local img="$1" out="$2"
  rm -rf "$out"/*
  debugfs -R "rdump /etc/init $out" "$img" >/dev/null 2>&1 || true
}

echo "[1/2] EXTRACT"
dump_init "$SYS" "$TMP/system"
dump_init "$SEXT" "$TMP/system_ext"
dump_init "$VENDOR" "$TMP/vendor"
dump_init "$PRODUCT" "$TMP/product"
if [ -f "$ODM" ]; then
  dump_init "$ODM" "$TMP/odm"
  echo "ODM_SOURCE=stock/odm.img"
else
  # Some devices keep odm content under vendor/odm rather than a separate image.
  debugfs -R "rdump /odm/etc/init $TMP/odm" "$VENDOR" >/dev/null 2>&1 || true
  if find "$TMP/odm" -type f -name '*.rc' -print -quit | grep -q .; then
    echo "ODM_SOURCE=vendor.img:/odm/etc/init"
  else
    echo "ODM_SOURCE=none_found"
  fi
fi

echo "[2/2] EXACT_BOUNDARY"
python - "$TMP" <<'PY'
import os,sys,re
base=sys.argv[1]

def actions(root):
    rows=[]
    for dp,_,fs in os.walk(root):
        for fn in fs:
            if not fn.endswith('.rc'): continue
            p=os.path.join(dp,fn)
            lines=open(p,encoding='utf-8',errors='replace').read().splitlines()
            i=0
            while i<len(lines):
                s=lines[i].strip()
                if not s.startswith('on '):
                    i+=1; continue
                trig=s[3:].strip()
                body=[]
                j=i+1
                while j<len(lines):
                    t=lines[j].strip()
                    if t.startswith('on ') or t.startswith('service ') or t.startswith('import '):
                        break
                    if t and not t.startswith('#'): body.append(lines[j].rstrip())
                    j+=1
                rows.append((fn,p,i+1,trig,body))
                i=j
    return rows

def has_trigger(trig,name):
    return name in [x.strip() for x in trig.split('&&')]

groups={k:actions(os.path.join(base,k)) for k in ['system','system_ext','vendor','odm','product']}

# Actions that can execute BEFORE vendor/wear5diag.rc's late-fs marker.
before=[]
for part in ['system','system_ext']:
    for r in groups[part]:
        if has_trigger(r[3],'late-fs'): before.append((part,)+r)
for r in groups['vendor']:
    fn=r[0]
    if fn < 'wear5diag.rc' and has_trigger(r[3],'late-fs'):
        before.append(('vendor',)+r)

# Actions that can execute AFTER vendor/wear5diag.rc's post-fs marker.
after=[]
for r in groups['vendor']:
    if r[0] > 'wear5diag.rc' and has_trigger(r[3],'post-fs'):
        after.append(('vendor',)+r)
for part in ['odm','product']:
    for r in groups[part]:
        if has_trigger(r[3],'post-fs'): after.append((part,)+r)

pat=re.compile(r'^\s*(exec(?:_start)?|wait(?:_for_prop)?|mount_all|mount|umount|restorecon_recursive|restorecon\s+--recursive)\b')

def show(title,rows):
    print()
    print(title+"="+str(len(rows)))
    blockers=[]
    for n,(part,fn,p,line,trig,body) in enumerate(rows,1):
        print()
        print(f"=== {title} {n}: {part}/{fn}:{line} ===")
        print("on "+trig)
        for x in body:
            print(x)
            if pat.match(x):
                blockers.append((part,fn,line,x.strip()))
    print()
    print(title+"_BLOCKING_COMMANDS="+str(len(blockers)))
    for part,fn,line,x in blockers:
        print(f"{part}/{fn}:{line}: {x}")
    return blockers

b1=show("LATE_FS_BEFORE_MARKER",before)
b2=show("POST_FS_AFTER_MARKER",after)

print()
if b2:
    print("BOUNDARY_RESULT=POST_FS_AFTER_MARKER_HAS_BLOCKER")
elif b1:
    print("BOUNDARY_RESULT=LATE_FS_BEFORE_MARKER_HAS_BLOCKER")
else:
    print("BOUNDARY_RESULT=NO_STATIC_BLOCKING_COMMAND_FOUND")
print("AUDIT=PASS")
print("WATCH_TOUCHED=NO")
PY
