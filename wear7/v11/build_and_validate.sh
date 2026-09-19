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
  for p in final-system_ext system system_ext product vendor; do
    umount "$W/mnt/$p" 2>/dev/null || true
  done
}
trap cleanup EXIT

for p in system system_ext product vendor; do
  mkdir -p "$W/mnt/$p"
  mount -o loop,ro,noload "$W/parts/$p.img" "$W/mnt/$p"
done

# Stage ONLY system_ext: audit proved the sole collision is system_ext vs vendor.
mkdir -p "$W/stage-system_ext"
cp -a "$W/mnt/system_ext/." "$W/stage-system_ext/"

# Preserve exact V7 native/APEX lock evidence. No ELF or APEX payload is changed.
test -f "$W/prior-report/VNDK33_PAYLOAD_SHA256.json"
cp "$W/prior-report/VNDK33_PAYLOAD_SHA256.json" "$REP/VNDK33_PAYLOAD_SHA256.json"
if test -f "$W/prior-report/NATIVE_STOCK32_COMPAT.json"; then
  cp "$W/prior-report/NATIVE_STOCK32_COMPAT.json" "$REP/NATIVE_STOCK32_COMPAT_V7.json"
fi

python3 wear7/v11/fix_property_context_collision.py \
  --system-root "$W/mnt/system/system" \
  --system-ext-root "$W/stage-system_ext" \
  --product-root "$W/mnt/product" \
  --vendor-root "$W/mnt/vendor" \
  --report "$REP"

# V11-DIAG2: SELinux-valid persistent init milestones.
# Recovery pre-creates /metadata/vold/wear7diag/* as vold_metadata_file directories, mode 0700.
# Each trigger only chmods its own marker to 0777. Exact V11 policy grants init setattr/search on vold_metadata_file dirs.
cat > "$W/stage-system_ext/etc/init/wear7-v11-stage-marker.rc" <<'EOF'
on early-init
    chmod 0777 /metadata/vold/wear7diag/00_EARLY_INIT
    chmod 0777 /metadata/vold/wear7diag/BM_${ro.bootmode:-unset}

on init
    chmod 0777 /metadata/vold/wear7diag/01_INIT

on late-init
    chmod 0777 /metadata/vold/wear7diag/02_LATE_INIT

on property:init.svc.apexd-bootstrap=running
    chmod 0777 /metadata/vold/wear7diag/03_APEXD_BOOTSTRAP_RUNNING

on property:init.svc.apexd-bootstrap=stopped
    chmod 0777 /metadata/vold/wear7diag/04_APEXD_BOOTSTRAP_STOPPED

on property:init.svc.apexd=running
    chmod 0777 /metadata/vold/wear7diag/05_APEXD_RUNNING

on property:apexd.status=ready
    chmod 0777 /metadata/vold/wear7diag/06_APEXD_READY

on property:init.svc.vold=running
    chmod 0777 /metadata/vold/wear7diag/07_VOLD_RUNNING

on post-fs
    chmod 0777 /metadata/vold/wear7diag/08_POST_FS

on post-fs-data
    chmod 0777 /metadata/vold/wear7diag/09_POST_FS_DATA

on property:init.svc.bpfloader=running
    chmod 0777 /metadata/vold/wear7diag/10_BPFLOADER_RUNNING

on bpf-progs-loaded
    chmod 0777 /metadata/vold/wear7diag/11_BPF_PROGS_LOADED

on property:init.svc.netd=running
    chmod 0777 /metadata/vold/wear7diag/12_NETD_RUNNING

on zygote-start
    chmod 0777 /metadata/vold/wear7diag/13_ZYGOTE_START

on property:init.svc.zygote=running
    chmod 0777 /metadata/vold/wear7diag/14_ZYGOTE_RUNNING

on early-boot
    chmod 0777 /metadata/vold/wear7diag/15_EARLY_BOOT

on boot
    chmod 0777 /metadata/vold/wear7diag/16_BOOT

on property:sys.boot_completed=1
    chmod 0777 /metadata/vold/wear7diag/17_BOOT_COMPLETED
EOF
cp "$W/stage-system_ext/etc/init/wear7-v11-stage-marker.rc" "$REP/WEAR7_V11_STAGE_MARKER.rc"
python3 - "$W/stage-system_ext/etc/init/wear7-v11-stage-marker.rc" <<'PY'
import os,sys
os.setxattr(sys.argv[1], 'security.selinux', b'u:object_r:system_file:s0\x00')
PY

# Audit exact init-event actions/imports before any further rebuild.
python3 wear7/v11/audit_init_actions.py \
  "$W/mnt/system/system" \
  "$W/stage-system_ext" \
  "$W/mnt/product" \
  "$W/mnt/vendor" \
  "$REP"

run_host_init_gate() {
  local tag="$1" sx="$2"
  local H="$T/bin/host_init_verifier"
  local SYS="$W/mnt/system/system"
  local -a cmd=("$H"
    --out_system "$SYS"
    --out_system_ext "$sx"
    --out_product "$W/mnt/product"
    --out_vendor "$W/mnt/vendor")

  local p
  for p in \
    "$SYS/etc/selinux/plat_property_contexts" \
    "$sx/etc/selinux/system_ext_property_contexts" \
    "$W/mnt/product/etc/selinux/product_property_contexts" \
    "$W/mnt/vendor/etc/selinux/vendor_property_contexts"; do
    test ! -f "$p" || cmd+=("--property-contexts=$p")
  done
  for p in \
    "$SYS/etc/passwd" \
    "$sx/etc/passwd" \
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
lines=pathlib.Path(sys.argv[1]).read_text(errors='replace').splitlines()
forbidden=(
  'Unable to serialize property contexts',
  'Duplicate exact match detected',
  'Failed to load serialized property info file',
)
for x in forbidden:
    if any(x in line for line in lines):
        raise SystemExit('fatal host-init property failure remains: '+x)

# host_init_verifier Android17 treats some Android13 Dace service declarations
# as errors solely because they omit an explicit "user"; those same definitions
# are present in stock379, which boots. Reject every OTHER parser error.
errs=[]
for line in lines:
    if not line.startswith('host_init_verifier: '):
        continue
    if re.search(r'Failed to parse init scripts with \d+ error\(s\)\.$',line):
        continue
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

# This is the key new gate that V7 never ran successfully.
run_host_init_gate STAGED "$W/stage-system_ext"

# Re-run V7 Android17 structural gates against the corrected staged system_ext.
python3 wear7/v6/validate-images.py \
  --system "$W/mnt/system/system" \
  --system-ext "$W/stage-system_ext" \
  --product "$W/mnt/product" \
  --vendor "$W/mnt/vendor" \
  --tools "$T" --work "$W/prebuild-validation" --report "$REP"

# Rebuild ONLY system_ext, regenerate vbmeta pair and super, and hard-verify that
# every other logical partition is byte-for-byte canonical V7.
python3 wear7/v11/rebuild_system_ext.py \
  --work "$W" --tools "$T" --report "$REP" --output "$OUT"

# Validate the exact system_ext extracted back out of the final super.
mkdir -p "$W/mnt/final-system_ext"
mount -o loop,ro,noload "$W/final-parts/system_ext.img" "$W/mnt/final-system_ext"
run_host_init_gate SHIPPED "$W/mnt/final-system_ext"

mkdir -p "$REP/final"
cp "$REP/VNDK33_PAYLOAD_SHA256.json" "$REP/final/VNDK33_PAYLOAD_SHA256.json"
python3 wear7/v6/validate-images.py \
  --system "$W/mnt/system/system" \
  --system-ext "$W/mnt/final-system_ext" \
  --product "$W/mnt/product" \
  --vendor "$W/mnt/vendor" \
  --tools "$T" --work "$W/final-validation" --report "$REP/final"

umount "$W/mnt/final-system_ext"

python3 - "$OUT" "$REP" <<'PY'
import hashlib,json,pathlib,sys
out=pathlib.Path(sys.argv[1]); rep=pathlib.Path(sys.argv[2])
m=json.loads((out/'CANDIDATE.json').read_text())
m['rootcause_fix'].update({
  'evidence':'exact V7 audit: the only duplicate exact property context is ro.charger_mode_autoboot, system_ext:92 vs vendor:20, with identical SELinux label/type',
  'policy':'preserve exact stock Dace vendor mapping; remove only duplicate donor system_ext declaration',
  'host_init_staged':'PASS_DIFFERENTIAL',
  'host_init_shipped':'PASS_DIFFERENTIAL',
})
m['offline_gates']=json.loads((rep/'final/GATES.json').read_text())
m['flash_authorized']=False
(out/'CANDIDATE.json').write_text(json.dumps(m,indent=2)+'\n')
(rep/'FINAL_CANDIDATE_V11.json').write_text(json.dumps(m,indent=2)+'\n')
def sha(p):
    with p.open('rb') as f: return hashlib.file_digest(f,'sha256').hexdigest()
files=sorted(p for p in out.iterdir() if p.is_file() and p.name!='SHA256SUMS.txt')
(out/'SHA256SUMS.txt').write_text('\n'.join(f'{sha(p)}  {p.name}' for p in files)+'\n')
PY

python3 wear7/v6/recovery-preflight.py \
  --package "$OUT" --report "$REP/PACKAGE_PREFLIGHT_V11.json"

echo 'WEAR7_V11_PROPERTY_FATAL_FIX=PASS'
echo 'V11_CHANGED_LOGICAL_PARTITION=system_ext_ONLY'
echo 'BOOTCHAIN_BASE=V7_CANONICAL'
echo 'FLASH_AUTHORIZED=NO'
