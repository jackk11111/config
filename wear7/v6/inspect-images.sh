#!/usr/bin/env bash
set -Eeuo pipefail
W="$RUNNER_TEMP/v6"
REP="$GITHUB_WORKSPACE/wear7-v6-report"
exec > >(tee "$REP/inspection.log") 2>&1
python3 - "$W/input" <<'PY'
import hashlib,pathlib,sys
p=pathlib.Path(sys.argv[1]); seen=set()
for row in (p/'SHA256SUMS.txt').read_text().splitlines():
    digest,name=row.split(maxsplit=1); name=pathlib.PurePosixPath(name.lstrip('*')).name
    if name in seen: raise SystemExit('duplicate checksum entry')
    seen.add(name); f=p/name
    if not f.is_file(): raise SystemExit('missing '+name)
    with f.open('rb') as h: actual=hashlib.file_digest(h,'sha256').hexdigest()
    if actual!=digest: raise SystemExit('checksum mismatch '+name)
    pinned={
        'boot.img':'f5173a192b1d1e335198aa04ef8f47928d87b26d793fd9621737f211143c8353',
        'init_boot.img':'c128f41b1e1fe4a2062b1b8464bf8e01650419f158ab7d412a3bf1f0099c9884',
        'vendor_boot.img':'9d7cd2a5f7a21e9554552e94aaf89c2fdc6d036f59c8e8abe355456f8a5f18cf',
        'dtbo.img':'eb2a8d0028b6e22898b26e4bc71419190a4ea3431a2b66c6c57d9e280ade4c96',
        'vbmeta.img':'74c55a89f6158f95b01fe4b02e07b8ad2343b63df26951a3ed778eec8a5f51e4',
        'vbmeta_system.img':'b9189593ed8a1e7d0d0e2fbcf97d5b3edd575928c84e175dd007120473d2343e',
        'super.img':'054c4abc0d25fe7c1a3873c34b647f439674deb7ae1dc8526dface7b436d82a6',
        'CANDIDATE_MANIFEST.txt':'f1c7dd05953ff9d6ebd944a24bcad5af5a0d2999d7d798f36a1f3e8a4c9698d9'}
    if pinned.get(name)!=actual: raise SystemExit('input differs from audited V5B '+name)
    print('INPUT_SHA256',name,actual)
required={'boot.img','init_boot.img','vendor_boot.img','dtbo.img','vbmeta.img','vbmeta_system.img','super.img','CANDIDATE_MANIFEST.txt'}
if seen!=required: raise SystemExit('unexpected candidate file set: '+repr(seen))
print('EXACT_V5B_INPUT_HASHES=PASS')
PY
cp "$W/input/CANDIDATE_MANIFEST.txt" "$REP/INPUT_MANIFEST.txt"
cat "$REP/INPUT_MANIFEST.txt"
ZIP="$W/tools/otatools.zip"
curl -fL --retry 2 -sS -o "$ZIP" https://ci.android.com/builds/submitted/16102939/aosp_cf_x86_64_only_phone-userdebug/latest/raw/otatools.zip
echo "f1da1fb14ad810835679abd5f8a30c0e4f4c5b6210d355b7e1995bc51d739d84  $ZIP" | sha256sum -c -
unzip -Z1 "$ZIP" > "$REP/OTATOOLS_FILES.txt"
python3 - "$ZIP" "$W/tools/extracted" <<'PY'
import pathlib,sys,zipfile
z=zipfile.ZipFile(sys.argv[1]); out=pathlib.Path(sys.argv[2])
for n in z.namelist():
    if n.startswith(('bin/','lib64/','lib/','framework/')):
        q=(out/n).resolve()
        if not q.is_relative_to(out.resolve()): raise SystemExit('unsafe zip path')
        z.extract(n,out)
PY
T="$W/tools/extracted"; chmod +x "$T/bin/"*
export PATH="$T/bin:$PATH" LD_LIBRARY_PATH="$T/lib64:$T/lib"
for t in lpunpack checkvintf apexd_host apexer avbtool signapk secilc idmap2 aapt2 debugfs_static fsck.erofs mkuserimg_mke2fs e2fsdroid tune2fs lpmake; do
    command -v "$t" || true
done
test -e "$T/bin/debugfs" || ln -s debugfs_static "$T/bin/debugfs"
simg2img "$W/input/super.img" "$W/super.raw"
test "$(stat -c %s "$W/super.raw")" = 4294967296
lpunpack "$W/super.raw" "$W/parts"
rm "$W/super.raw"
for p in system system_ext product vendor; do
    mkdir -p "$W/mnt/$p"
    sudo mount -o loop,ro "$W/parts/$p.img" "$W/mnt/$p"
done
cleanup() { for p in vendor product system_ext system; do sudo umount "$W/mnt/$p" 2>/dev/null || true; done; }
trap cleanup EXIT
S="$W/mnt/system/system"; SX="$W/mnt/system_ext"; P="$W/mnt/product"; V="$W/mnt/vendor"
test -f "$S/build.prop"
echo '--- APEX configuration and entries ---'
for f in "$S/build.prop" "$SX/build.prop" "$P/build.prop" "$V/build.prop"; do
    grep -E '^(ro\.(apex|vndk|product\.vndk|build\.version|product\.cpu)|apex\.)' "$f" || true
done
find "$S/apex" "$SX/apex" "$P/apex" "$V/apex" -mindepth 1 -maxdepth 1 -printf '%y %p\n' 2>/dev/null || true
echo '--- SELinux policy inputs ---'
for r in "$S" "$SX" "$P" "$V"; do
    find "$r/etc/selinux" -maxdepth 2 -type f -printf '%P\n' 2>/dev/null | sort
done
cat "$V/etc/selinux/plat_sepolicy_vers.txt"
for r in "$S" "$SX" "$P"; do
    find "$r/etc/selinux/mapping" -maxdepth 1 -name '33.0*' -print 2>/dev/null || true
done
echo '--- idmap2 binaries and companion overlay ---'
file "$S/bin/idmap2" "$S/bin/linker" "$S/bin/linker64" 2>/dev/null || true
find "$P" "$S" "$SX" -type f \( -iname '*SetupWizard*.apk' -o -name 'DaceEnduroFastPairOverlay.apk' \) -print
echo '--- Prior gate reports ---'
for f in FINAL_OFFLINE_VERDICT.txt VINTF_STATIC_CONTRACT.txt KERNEL_SOURCE_REPORT.txt FASTPAIR_STATIC_VERDICT.txt; do
    if test -f "$W/prior-report/$f"; then cat "$W/prior-report/$f"; fi
done
echo 'INSPECTION_COMPLETE=YES'
echo '--- Official apexer interface ---'
apexer --help > "$REP/APEXER_HELP.txt"
cat "$REP/APEXER_HELP.txt"
mkdir -p "$W/stage-system"
cp -a "$W/mnt/system/." "$W/stage-system/"
bridge_rc=0; gates_rc=0
python3 wear7/v6/build-bridge.py --source "$S/apex/com.android.vndk.current" --system "$W/stage-system/system" --tools "$T" --work "$W/bridge" --report "$REP" || bridge_rc=$?
python3 wear7/v6/validate-images.py --system "$W/stage-system/system" --system-ext "$SX" --product "$P" --vendor "$V" --tools "$T" --work "$W/validation" --report "$REP" || gates_rc=$?
if (( bridge_rc != 0 || gates_rc != 0 )); then exit 1; fi
python3 wear7/v6/rebuild-final.py --work "$W" --tools "$T" --report "$REP" --output "$GITHUB_WORKSPACE/wear7-v6-candidate"
python3 wear7/v6/recovery-preflight.py --package "$GITHUB_WORKSPACE/wear7-v6-candidate" --report "$REP/PACKAGE_PREFLIGHT.json"

echo 'FLASH_AUTHORIZED=NO'
