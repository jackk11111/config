#!/usr/bin/env bash
set -Eeuo pipefail

W="$RUNNER_TEMP/v7"
REP="$GITHUB_WORKSPACE/wear7-v7-report"
OUT="$GITHUB_WORKSPACE/wear7-v7-candidate"
mkdir -p "$REP" "$OUT" "$W/parts" "$W/mnt" "$W/tools"
exec > >(tee "$REP/repair.log") 2>&1

# V7 is deliberately derived from the already gated V6 run.  Refuse any
# substituted input before touching filesystems.
python3 - "$W/input" <<'PY'
import hashlib, pathlib, sys
root=pathlib.Path(sys.argv[1])
pinned={
 'boot.img':'f5173a192b1d1e335198aa04ef8f47928d87b26d793fd9621737f211143c8353',
 'init_boot.img':'c128f41b1e1fe4a2062b1b8464bf8e01650419f158ab7d412a3bf1f0099c9884',
 'vendor_boot.img':'9d7cd2a5f7a21e9554552e94aaf89c2fdc6d036f59c8e8abe355456f8a5f18cf',
 'dtbo.img':'eb2a8d0028b6e22898b26e4bc71419190a4ea3431a2b66c6c57d9e280ade4c96',
 'vbmeta.img':'fd3a0958bd758bbda5ce27df0de8dfff9ffef33e00daafb38cbb4173873c3392',
 'vbmeta_system.img':'28f5f460f686dc57df2671debd69bbee2ca41eafda9356102febb0224fce6eb1',
 'super.img':'91b73fc444e51d68db7bfaca77615f8be9103407cd92f3e67a74500a0a22a30e',
}
for name,want in pinned.items():
    p=root/name
    if not p.is_file(): raise SystemExit('missing V6 input '+name)
    with p.open('rb') as f: got=hashlib.file_digest(f,'sha256').hexdigest()
    if got!=want: raise SystemExit(f'V6 input hash mismatch {name}: {got}')
print('EXACT_V6_INPUT_HASHES=PASS')
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
  for p in final-system stock-system vendor product system_ext system; do
    sudo umount "$W/mnt/$p" 2>/dev/null || true
  done
}
trap cleanup EXIT
for p in system system_ext product vendor; do
  mkdir -p "$W/mnt/$p"
  mount -o loop,ro,noload "$W/parts/$p.img" "$W/mnt/$p"
done
mkdir -p "$W/stage-system"
cp -a "$W/mnt/system/." "$W/stage-system/"

# Reconstruct exactly the stock-379 system image.  The URL and archive hash are
# pinned; no binary comes from an unversioned host package or a different watch.
STOCK="$W/stock379.zip"
curl -fL --retry 2 -sS -o "$STOCK" https://android.googleapis.com/packages/data/ota-api/package/2269bd24a774cae37adc720d3d97bd1b76846e2b.zip
echo "ffa61d822a5c667c230ce2ba9426ce4eb282adcaa0891279ef002f65ca15a08d  $STOCK" | sha256sum -c -
python3 wear7/scripts/reconstruct_block_ota.py "$STOCK" system "$W/stock-system.img"
rm "$STOCK"
mkdir -p "$W/mnt/stock-system"
mount -o loop,ro,noload "$W/stock-system.img" "$W/mnt/stock-system"

COMPAT32=(
  android.hardware.audio.common-V1-ndk.so
  android.hardware.bluetooth.audio-V2-ndk.so
  android.hardware.security.keymint-V2-ndk.so
  android.hardware.soundtrigger@2.0-core.so
  android.hardware.soundtrigger@2.0.so
  android.media.audio.common.types-V1-ndk.so
  android.media.audio.common.types-V1-ndk_platform.so
  android.media.soundtrigger.types-V1-ndk.so
  android.media.soundtrigger.types-V1-ndk_platform.so
  libaudioroute.so
  libwifi-system-iface.so
)
: > "$REP/STOCK32_COMPAT_SHA256.txt"
for name in "${COMPAT32[@]}"; do
  src="$W/mnt/stock-system/system/lib/$name"
  dst="$W/stage-system/system/lib/$name"
  test -f "$src" || { echo "stock379 missing $name"; exit 1; }
  test ! -e "$dst" || { echo "refusing to overwrite donor file $dst"; exit 1; }
  cp -a --preserve=all "$src" "$dst"
  sha256sum "$dst" >> "$REP/STOCK32_COMPAT_SHA256.txt"
done

# Preserve the VNDK33 payload lock from the exact V6 run.  The bridge is not
# rebuilt or altered by this repair.
test -f "$W/prior-report/VNDK33_PAYLOAD_SHA256.json"
cp "$W/prior-report/VNDK33_PAYLOAD_SHA256.json" "$REP/VNDK33_PAYLOAD_SHA256.json"

# Expose final APEX contents for the native closure gate.
mkdir -p "$W/apex"
"$T/bin/apexd_host" --tool_path "$T" --apex_path "$W/apex" \
  --system_path "$W/stage-system/system" --system_ext_path "$W/mnt/system_ext" \
  --product_path "$W/mnt/product" --vendor_path "$W/mnt/vendor" \
  --odm_path "$W/mnt/vendor/odm" > "$REP/APEXD_NATIVE_COMPAT.log" 2>&1

python3 wear7/v7/validate_native_compat.py \
  --system "$W/stage-system/system" \
  --system-ext "$W/mnt/system_ext" \
  --product "$W/mnt/product" \
  --vendor "$W/mnt/vendor" \
  --apex "$W/apex" \
  --stock-system "$W/mnt/stock-system" \
  --report "$REP/NATIVE_STOCK32_COMPAT.json"

# Re-run every V6 structural gate against the modified system before rebuilding.
python3 wear7/v6/validate-images.py \
  --system "$W/stage-system/system" --system-ext "$W/mnt/system_ext" \
  --product "$W/mnt/product" --vendor "$W/mnt/vendor" \
  --tools "$T" --work "$W/prebuild-validation" --report "$REP"

umount "$W/mnt/stock-system"
rm "$W/stock-system.img"

# Existing rebuild code preserves exact ownership/modes/SELinux xattrs, rebuilds
# AVB/super, extracts the shipped super again and repeats the structural gates.
python3 wear7/v6/rebuild-final.py --work "$W" --tools "$T" --report "$REP" --output "$OUT"

# Promote the package identity and record the additional V7 gate.  Images are
# not modified here; only the JSON manifest/checksum list changes.
python3 - "$OUT" "$REP/NATIVE_STOCK32_COMPAT.json" <<'PY'
import hashlib,json,pathlib,sys
out=pathlib.Path(sys.argv[1]); native=json.loads(pathlib.Path(sys.argv[2]).read_text())
manifest=json.loads((out/'CANDIDATE.json').read_text())
manifest['candidate']='Wear7-V7'
manifest['input_run']=35146642220
manifest['native_compat']={
  'source':'TicWatch stock 379 system/lib ARM32',
  'stock_ota_sha256':'ffa61d822a5c667c230ce2ba9426ce4eb282adcaa0891279ef002f65ca15a08d',
  'libraries':native['injected_stock379'],
}
manifest.setdefault('offline_gates',{})['NATIVE_STOCK32_COMPAT']={'status':'PASS'}
(out/'CANDIDATE.json').write_text(json.dumps(manifest,indent=2)+'\n')
def sha(p):
    with p.open('rb') as f: return hashlib.file_digest(f,'sha256').hexdigest()
files=sorted(p for p in out.iterdir() if p.is_file() and p.name!='SHA256SUMS.txt')
(out/'SHA256SUMS.txt').write_text('\n'.join(f'{sha(p)}  {p.name}' for p in files)+'\n')
PY

python3 wear7/v6/recovery-preflight.py --package "$OUT" --report "$REP/PACKAGE_PREFLIGHT_V7.json"

echo 'WEAR7_V7_NATIVE_COMPAT=PASS'
echo 'FLASH_AUTHORIZED=NO'
