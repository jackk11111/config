#!/usr/bin/env bash
set -Eeuo pipefail

W="$RUNNER_TEMP/v11"
REP="$GITHUB_WORKSPACE/wear7-v11-report"
OUT="$GITHUB_WORKSPACE/wear7-v11-candidate"
mkdir -p "$REP" "$OUT" "$W/parts" "$W/mnt" "$W/tools"
exec > >(tee "$REP/build.log") 2>&1

python3 - "$W/input" <<'PY'
import hashlib,pathlib,sys
root=pathlib.Path(sys.argv[1])
pinned={
 'boot.img':'f5173a192b1d1e335198aa04ef8f47928d87b26d793fd9621737f211143c8353',
 'init_boot.img':'c128f41b1e1fe4a2062b1b8464bf8e01650419f158ab7d412a3bf1f0099c9884',
 'vendor_boot.img':'9d7cd2a5f7a21e9554552e94aaf89c2fdc6d036f59c8e8abe355456f8a5f18cf',
 'dtbo.img':'eb2a8d0028b6e22898b26e4bc71419190a4ea3431a2b66c6c57d9e280ade4c96',
 'vbmeta.img':'384106d0f635631f5e4ddd96cd7847965af4e0687fb517ecee1cb4096c007259',
 'vbmeta_system.img':'22f24ebea86ea2dac15723449b477870133fac0703d9c07be32d89f2b7fe7a76',
 'super.img':'2a73517c4356dce6995641b4cf2ac82b50e1c0b0fec7ee46decbd4fe122399f6',
}
for n,w in pinned.items():
    p=root/n
    if not p.is_file(): raise SystemExit('missing exact V7 input '+n)
    with p.open('rb') as f: g=hashlib.file_digest(f,'sha256').hexdigest()
    if g!=w: raise SystemExit(f'V7 input mismatch {n}: {g}')
print('EXACT_V7_INPUT_HASHES=PASS')
PY

ZIP="$W/tools/otatools.zip"
curl -fL --retry 2 -sS -o "$ZIP" https://ci.android.com/builds/submitted/16102939/aosp_cf_x86_64_only_phone-userdebug/latest/raw/otatools.zip
echo "f1da1fb14ad810835679abd5f8a30c0e4f4c5b6210d355b7e1995bc51d739d84  $ZIP" | sha256sum -c -
python3 - "$ZIP" "$W/tools/extracted" <<'PY'
import pathlib,sys,zipfile
out=pathlib.Path(sys.argv[2]).resolve()
with zipfile.ZipFile(sys.argv[1]) as z:
    for name in z.namelist():
        if name.startswith(('bin/','lib64/','lib/','framework/')):
            dst=(out/name).resolve()
            if not dst.is_relative_to(out): raise SystemExit('unsafe otatools path')
            z.extract(name,out)
PY
rm "$ZIP"
T="$W/tools/extracted"
chmod +x "$T/bin/"*
export PATH="$T/bin:$PATH" LD_LIBRARY_PATH="$T/lib64:$T/lib"
test -e "$T/bin/debugfs" || ln -s debugfs_static "$T/bin/debugfs"

simg2img "$W/input/super.img" "$W/super.raw"
test "$(stat -c %s "$W/super.raw")" = 4294967296
lpunpack "$W/super.raw" "$W/parts"
rm "$W/super.raw"

cleanup() {
  for p in final-system system system_ext product vendor; do
    sudo umount "$W/mnt/$p" 2>/dev/null || true
  done
}
trap cleanup EXIT

for p in system system_ext product vendor; do
  mkdir -p "$W/mnt/$p"
  sudo mount -o loop,ro,noload "$W/parts/$p.img" "$W/mnt/$p"
done
mkdir -p "$W/stage-system"
sudo cp -a "$W/mnt/system/." "$W/stage-system/"
sudo chown -R "$(id -u):$(id -g)" "$W/stage-system"

# Preserve the exact V7 native/APEX lock evidence. This V11 changes property
# metadata only; no ELF/APEX payload is changed.
test -f "$W/prior-report/VNDK33_PAYLOAD_SHA256.json"
cp "$W/prior-report/VNDK33_PAYLOAD_SHA256.json" "$REP/VNDK33_PAYLOAD_SHA256.json"
if test -f "$W/prior-report/NATIVE_STOCK32_COMPAT.json"; then
  cp "$W/prior-report/NATIVE_STOCK32_COMPAT.json" "$REP/NATIVE_STOCK32_COMPAT_V7.json"
fi

python3 wear7/v11/fix_property_context_collision.py \
  --system-root "$W/stage-system/system" \
  --system-ext-root "$W/mnt/system_ext" \
  --product-root "$W/mnt/product" \
  --vendor-root "$W/mnt/vendor" \
  --report "$REP"

run_host_init_gate() {
  local tag="$1" sys="$2"
  local H="$T/bin/host_init_verifier"
  local -a cmd=("$H"
    --out_system "$sys"
    --out_system_ext "$W/mnt/system_ext"
    --out_product "$W/mnt/product"
    --out_vendor "$W/mnt/vendor")

  local p
  for p in \
    "$sys/etc/selinux/plat_property_contexts" \
    "$W/mnt/system_ext/etc/selinux/system_ext_property_contexts" \
    "$W/mnt/product/etc/selinux/product_property_contexts" \
    "$W/mnt/vendor/etc/selinux/vendor_property_contexts"; do
    test ! -f "$p" || cmd+=("--property-contexts=$p")
  done
  for p in \
    "$sys/etc/passwd" \
    "$W/mnt/system_ext/etc/passwd" \
    "$W/mnt/product/etc/passwd" \
    "$W/mnt/vendor/etc/passwd"; do
    test ! -f "$p" || cmd+=(-p "$p")
  done

  set +e
  "${cmd[@]}" > "$REP/HOST_INIT_${tag}.log" 2>&1
  local rc=$?
  set -e
  echo "$rc" > "$REP/HOST_INIT_${tag}_RC.txt"
  cat "$REP/HOST_INIT_${tag}.log"

  python3 - "$REP/HOST_INIT_${tag}.log" <<'PY'
import pathlib,sys,re
p=pathlib.Path(sys.argv[1]); lines=p.read_text(errors='replace').splitlines()
forbidden=('Unable to serialize property contexts','Duplicate exact match detected',
           'Failed to load serialized property info file')
for x in forbidden:
    if any(x in line for line in lines):
        raise SystemExit('fatal host-init property failure remains: '+x)
errs=[]
for line in lines:
    if not line.startswith('host_init_verifier: '): continue
    if re.search(r'Failed to parse init scripts with \d+ error\(s\)\.$',line): continue
    # Android13 Dace vendor legacy definitions are known to boot stock and are
    # the only verifier errors allowed in the Android17 parser differential.
    allowed=(
      '/vendor/etc/init/android.hardware.wifi.supplicant-service.rc:' in line or
      '/vendor/etc/init/boringssl_self_test.rc:' in line or
      '/vendor/etc/init/vendor_flash_recovery.rc:' in line
    ) and "No user specified for service '" in line
    if not allowed:
        errs.append(line)
if errs:
    raise SystemExit('new V11 host-init error(s):\n'+'\n'.join(errs))
print('HOST_INIT_DIFFERENTIAL_GATE=PASS')
PY
}

run_host_init_gate STAGED "$W/stage-system/system"

# Re-run the complete V7 structural gates before filesystem rebuild.
python3 wear7/v6/validate-images.py \
  --system "$W/stage-system/system" \
  --system-ext "$W/mnt/system_ext" \
  --product "$W/mnt/product" \
  --vendor "$W/mnt/vendor" \
  --tools "$T" --work "$W/prebuild-validation" --report "$REP"

# Rebuild only system, regenerate vbmeta pair and super, then re-extract and
# revalidate all unchanged logical partitions byte-for-byte.
python3 wear7/v6/rebuild-final.py \
  --work "$W" --tools "$T" --report "$REP" --output "$OUT"

mkdir -p "$W/mnt/final-system"
sudo mount -o loop,ro,noload "$W/final-parts/system.img" "$W/mnt/final-system"
run_host_init_gate SHIPPED "$W/mnt/final-system/system"
sudo umount "$W/mnt/final-system"

python3 - "$OUT" "$REP" <<'PY'
import hashlib,json,pathlib,sys
out=pathlib.Path(sys.argv[1]); rep=pathlib.Path(sys.argv[2])
m=json.loads((out/'CANDIDATE.json').read_text())
m['candidate']='Wear7-V11'
m['input_run']=35198609607
m['rootcause_fix']={
  'class':'PID1_PROPERTY_CONTEXT_SERIALIZATION_FATAL',
  'evidence':'Android17 host_init_verifier found exact duplicate ro.charger_mode_autoboot in V7 composition',
  'policy':'preserve stock Dace vendor mapping and remove semantically identical donor system duplicate',
  'host_init_staged':'PASS_DIFFERENTIAL',
  'host_init_shipped':'PASS_DIFFERENTIAL',
}
m['flash_authorized']=False
(out/'CANDIDATE.json').write_text(json.dumps(m,indent=2)+'\n')
def sha(p):
    with p.open('rb') as f: return hashlib.file_digest(f,'sha256').hexdigest()
files=sorted(p for p in out.iterdir() if p.is_file() and p.name!='SHA256SUMS.txt')
(out/'SHA256SUMS.txt').write_text('\n'.join(f'{sha(p)}  {p.name}' for p in files)+'\n')
(rep/'FINAL_CANDIDATE_V11.json').write_text(json.dumps(m,indent=2)+'\n')
PY

python3 wear7/v6/recovery-preflight.py --package "$OUT" --report "$REP/PACKAGE_PREFLIGHT_V11.json"

echo 'WEAR7_V11_PROPERTY_FATAL_FIX=PASS'
echo 'BOOTCHAIN_BASE=V7_CANONICAL'
echo 'FLASH_AUTHORIZED=NO'
