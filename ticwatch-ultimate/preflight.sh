#!/usr/bin/env bash
set -Eeuo pipefail

BASE_REPO="https://github.com/Winkmoon/android_kernel_TicWatch-Pro5.git"
BASE_SHA="3929c55fbc7559af6df290d2c0f66dc551af161a"
KSUN_REPO="https://github.com/KernelSU-Next/KernelSU-Next.git"
KSUN_TAG="v3.3.0"
KSUN_SHA="3b18216f71df189ab3d1b1ce0bdb21be1268e771"
KSUN_MANAGER="KernelSU_Next_v3.3.0-spoofed_33214-release.apk"
KSUN_MANAGER_SHA256="773d99e256563d36f8543235c96274021c59cf65efed783170bbc7effdf24ee3"
SUSFS_REPO="https://github.com/ShirkNeko/susfs4ksu.git"
SUSFS_BRANCH="gki-android13-5.15"
SUSFS_SHA="65ea8683c794cc309c3b0c4e6b57c1d972ca9a76"
WILD_PATCHES_REPO="https://github.com/WildKernels/kernel_patches.git"
WILD_PATCHES_SHA="4285cd1755f62a20269aa80757ecb4631908ec77"
EXPECTED_LOCALVERSION='CONFIG_LOCALVERSION="-Xinran_StarBai-Test"'

ROOT="${GITHUB_WORKSPACE:-$PWD}/.ticwatch-preflight"
REPORT="${GITHUB_WORKSPACE:-$PWD}/ticwatch-ultimate-results/preflight.txt"
CFG="$ROOT/common/arch/arm64/configs/gki_defconfig"
mkdir -p "$(dirname "$REPORT")"
rm -rf "$ROOT"
mkdir -p "$ROOT"
: > "$REPORT"

log() { printf '%s\n' "$*" | tee -a "$REPORT"; }
fail() { log "FAIL: $*"; exit 1; }
pass() { log "PASS: $*"; }

trap 'rc=$?; if [ "$rc" -ne 0 ]; then printf "\nRESULT=FAIL rc=%s\n" "$rc" | tee -a "$REPORT"; fi' EXIT

fetch_exact() {
  local repo="$1" sha="$2" dst="$3"
  git init -q "$dst"
  git -C "$dst" remote add origin "$repo"
  git -C "$dst" fetch -q --depth=1 origin "$sha"
  git -C "$dst" checkout -q --detach FETCH_HEAD
  local actual
  actual="$(git -C "$dst" rev-parse HEAD)"
  [ "$actual" = "$sha" ] || fail "SHA mismatch for $repo: $actual"
}

log "TicWatch Ultimate 5.15 / KernelSU Next v3.3.0 + SuSFS v2.2.0 preflight"
log "BASE_SHA=$BASE_SHA"
log "KSUN_TAG=$KSUN_TAG"
log "KSUN_SHA=$KSUN_SHA"
log "KSUN_MANAGER=$KSUN_MANAGER"
log "KSUN_MANAGER_SHA256=$KSUN_MANAGER_SHA256"
log "SUSFS_SHA=$SUSFS_SHA"
log "WILD_PATCHES_SHA=$WILD_PATCHES_SHA"
log ""

log "[1/11] Fetch exact TicWatch source"
fetch_exact "$BASE_REPO" "$BASE_SHA" "$ROOT/common" >>"$REPORT" 2>&1
pass "exact TicWatch base source"

grep -Fxq "$EXPECTED_LOCALVERSION" "$CFG" || fail "expected TicWatch LOCALVERSION not found"
pass "LOCALVERSION matches installed Xinran_StarBai-Test baseline"

log "[2/11] Fetch exact KernelSU Next v3.3.0 source"
fetch_exact "$KSUN_REPO" "$KSUN_SHA" "$ROOT/common/KernelSU-Next" >>"$REPORT" 2>&1
pass "KernelSU Next $KSUN_TAG pinned at $KSUN_SHA"

log "[3/11] Fetch exact SuSFS v2.2-era Android 13 / 5.15 source"
fetch_exact "$SUSFS_REPO" "$SUSFS_SHA" "$ROOT/susfs4ksu" >>"$REPORT" 2>&1
susver="$(grep '#define SUSFS_VERSION' "$ROOT/susfs4ksu/kernel_patches/include/linux/susfs.h" | awk -F'"' '{print $2}')"
[ "$susver" = "v2.2.0" ] || fail "expected SuSFS v2.2.0, got $susver"
pass "SuSFS $susver pinned ($SUSFS_BRANCH @ $SUSFS_SHA)"

log "[4/11] Fetch exact KernelSU Next / SuSFS v2.2 compatibility patchset"
fetch_exact "$WILD_PATCHES_REPO" "$WILD_PATCHES_SHA" "$ROOT/kernel_patches" >>"$REPORT" 2>&1
FIXDIR="$ROOT/kernel_patches/next/susfs_fix_patches/v2.2.0"
for p in fix_Kbuild.patch fix_init.c.patch fix_kernel_umount.c.patch fix_setuid_hook.c.patch fix_sucompat.c.patch fix_supercall.c.patch overwrite_hook_mode.patch ksu_toolkit.patch; do
  [ -f "$FIXDIR/$p" ] || fail "missing pinned compatibility patch: $p"
done
pass "KSUN v3.3.0 compatibility layer pinned at $WILD_PATCHES_SHA"

log "[5/11] Integrate SuSFS into KernelSU Next v3.3.0 with compatibility layer"
KSUN="$ROOT/common/KernelSU-Next"
KSU_PATCH="$ROOT/susfs4ksu/kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch"
[ -f "$KSU_PATCH" ] || fail "upstream SuSFS KernelSU patch missing"

cd "$KSUN"
filtered_susfs_patch="$(mktemp)"
awk '
  /^diff --git a\/kernel\/(Kbuild|Kconfig|core\/init\.c|feature\/kernel_umount\.c|feature\/sucompat\.c|hook\/setuid_hook\.c|supercall\/supercall\.c) b\// { skip = 1; next }
  /^diff --git / { skip = 0 }
  !skip { print }
' "$KSU_PATCH" > "$filtered_susfs_patch"
patch --dry-run -p1 < "$filtered_susfs_patch" >>"$REPORT" 2>&1 || fail "filtered upstream SuSFS patch does not match KSU Next v3.3.0"
patch -p1 --forward < "$filtered_susfs_patch" >>"$REPORT" 2>&1
rm -f "$filtered_susfs_patch"

# SuSFS v2.2.0 targets an older KSU Kconfig layout; insert only its SUSFS menu block.
if ! grep -q '^config KSU_SUSFS' ./kernel/Kconfig; then
  tail -n 1 ./kernel/Kconfig | grep -qx 'endmenu' || fail "KSU Next Kconfig has unexpected ending"
  susfs_kconfig_block="$(awk '
    /^\+menu "KernelSU - SUSFS"/ { active = 1 }
    active {
      print substr($0, 2)
      if ($0 ~ /^\+menu /) depth++
      else if ($0 ~ /^\+endmenu$/) {
        depth--
        if (depth == 0) exit
      }
    }
  ' "$KSU_PATCH")"
  [ -n "$susfs_kconfig_block" ] || fail "could not extract SuSFS Kconfig menu"
  tmp_kconfig="$(mktemp)"
  sed '$d' ./kernel/Kconfig > "$tmp_kconfig"
  printf '%s\n' "$susfs_kconfig_block" >> "$tmp_kconfig"
  printf '%s\n' 'endmenu' >> "$tmp_kconfig"
  mv "$tmp_kconfig" ./kernel/Kconfig
fi

# Restore the exact preimage expected by the v2.2.0 KSUN compatibility patches.
init_source=./kernel/core/init.c
[ "$(grep -Fxc '#if defined(__x86_64__)' "$init_source")" -eq 2 ] || fail "unexpected KSUN v3.3.0 x86 guard layout"
[ "$(grep -Fxc '    // If the kernel has the hardening patch, X86_FEATURE_INDIRECT_SAFE must be set ' "$init_source")" -eq 1 ] || fail "unexpected KSUN v3.3.0 init comment layout"
sed -i \
  -e 's|^#if defined(__x86_64__)$|#if defined(__x86_64__) \&\& !defined(CONFIG_KSU_X86_PATCH_SYSCALL_DISPATCHER)|' \
  -e 's|^    // If the kernel has the hardening patch, X86_FEATURE_INDIRECT_SAFE must be set $|    // If the kernel has the hardening patch, X86_FEATURE_INDIRECT_SAFE must be set|' \
  "$init_source"

for compatibility_patch in fix_Kbuild.patch fix_init.c.patch fix_kernel_umount.c.patch fix_setuid_hook.c.patch fix_sucompat.c.patch fix_supercall.c.patch; do
  patch --dry-run -p1 < "$FIXDIR/$compatibility_patch" >>"$REPORT" 2>&1 || fail "$compatibility_patch does not match KSUN v3.3.0 integration state"
  patch -p1 --forward < "$FIXDIR/$compatibility_patch" >>"$REPORT" 2>&1
done

# Dependencies deliberately skipped with the obsolete upstream chunks.
sucompat_source=./kernel/feature/sucompat.c
setuid_hook_source=./kernel/hook/setuid_hook.c
[ "$(grep -Fxc '#include <linux/ptrace.h>' "$sucompat_source")" -eq 1 ] || fail "unexpected sucompat include layout"
[ "$(grep -Fxc '#include <linux/uidgid.h>' "$setuid_hook_source")" -eq 1 ] || fail "unexpected setuid include layout"
[ "$(grep -Fxc 'static char __user *ksud_user_path(void)' "$sucompat_source")" -eq 1 ] || fail "unexpected ksud_user_path layout"
sed -i '/^#include <linux\/ptrace.h>$/a #include <linux/fs_struct.h>\n#include <linux/susfs_def.h>\n#include "selinux/selinux.h"' "$sucompat_source"
sed -i '/^#include <linux\/uidgid.h>$/a #include <linux/susfs_def.h>\n#include "selinux/selinux.h"' "$setuid_hook_source"
tmp_sucompat="$(mktemp)"
awk '
  /^static char __user \*ksud_user_path\(void\)$/ {
    print "static char __user *sh_user_path(void)"
    print "{"
    print "\tstatic const char sh_path[] = \"/system/bin/sh\";"
    print ""
    print "\treturn userspace_stack_buffer(sh_path, sizeof(sh_path));"
    print "}"
    print ""
  }
  { print }
' "$sucompat_source" > "$tmp_sucompat"
mv "$tmp_sucompat" "$sucompat_source"

for compatibility_patch in overwrite_hook_mode.patch ksu_toolkit.patch; do
  patch --dry-run -p1 < "$FIXDIR/$compatibility_patch" >>"$REPORT" 2>&1 || fail "$compatibility_patch does not match KSUN v3.3.0 integration state"
  patch -p1 --forward < "$FIXDIR/$compatibility_patch" >>"$REPORT" 2>&1
done

grep -q '^config KSU_SUSFS' ./kernel/Kconfig || fail "KSU_SUSFS missing after KSUN compatibility integration"
pass "KSU Next v3.3.0 + SuSFS v2.2.0 kernel-side framework integrated without forcing failed hunks"

log "[6/11] Link patched KernelSU Next into TicWatch kernel"
cd "$ROOT/common"
ln -sfn "../KernelSU-Next/kernel" drivers/kernelsu
if ! grep -qF 'obj-$(CONFIG_KSU) += kernelsu/' drivers/Makefile; then
  printf '\nobj-$(CONFIG_KSU) += kernelsu/\n' >> drivers/Makefile
fi
if ! grep -qF 'source "drivers/kernelsu/Kconfig"' drivers/Kconfig; then
  sed -i '/endmenu/i\source "drivers/kernelsu/Kconfig"' drivers/Kconfig
fi
[ -f drivers/kernelsu/Kconfig ] || fail "KernelSU Next symlink invalid"
pass "patched KernelSU Next linked into TicWatch source"

log "[7/11] Normalize known TicWatch-local collisions before kernel-side SuSFS patch"
python3 - <<'PY'
from pathlib import Path
p = Path("fs/proc/task_mmu.c")
s = p.read_text()
old = "#include <linux/pkeys.h>\n#include <trace/hooks/mm.h>\n\n#include <asm/elf.h>"
new = "#include <linux/pkeys.h>\n\n#include <asm/elf.h>"
if s.count(old) != 1:
    raise SystemExit("unexpected task_mmu vendor-hook context")
p.write_text(s.replace(old, new, 1))

p = Path("kernel/reboot.c")
s = p.read_text()
decl = "#ifdef CONFIG_KSU_MANUAL_HOOK\nextern int ksu_handle_sys_reboot(int magic1, int magic2, unsigned int cmd, void __user **arg);\n#endif\n\n"
call = "#ifdef CONFIG_KSU_MANUAL_HOOK\n\tksu_handle_sys_reboot(magic1, magic2, cmd, &arg);\n#endif\n"
if s.count(decl) != 1 or s.count(call) != 1:
    raise SystemExit("unexpected legacy manual reboot-hook context")
p.write_text(s.replace(decl, "", 1).replace(call, "", 1))

# Android-common 5.15 LTS may carry the blk vendor trace include at the
# exact insertion point used by the canonical SuSFS namespace patch.
# Remove it only temporarily and remember whether it must be restored.
p = Path("fs/namespace.c")
s = p.read_text()
hook = "#include <trace/hooks/blk.h>\n"
marker = Path("../.restore_namespace_blk_trace_hook")
if marker.exists():
    marker.unlink()
if s.count(hook) > 1:
    raise SystemExit("unexpected namespace blk trace-hook count")
if s.count(hook) == 1:
    p.write_text(s.replace(hook, "", 1))
    marker.write_text("1\n")
PY
pass "known TicWatch/LTS patch-context collisions normalized"

log "[8/11] Apply canonical Android 13 / Linux 5.15 SuSFS kernel patch"
PATCH="$ROOT/susfs4ksu/kernel_patches/50_add_susfs_in_gki-android13-5.15.patch"
[ -f "$PATCH" ] || fail "SuSFS Android13/5.15 kernel patch missing"
git apply --check "$PATCH" >>"$REPORT" 2>&1 || fail "SuSFS kernel patch has unaccounted TicWatch conflicts"
git apply "$PATCH" >>"$REPORT" 2>&1
cp -a "$ROOT/susfs4ksu/kernel_patches/fs/." fs/
cp -a "$ROOT/susfs4ksu/kernel_patches/include/linux/." include/linux/
[ -f fs/susfs.c ] || fail "fs/susfs.c missing"
[ -f include/linux/susfs.h ] || fail "include/linux/susfs.h missing"

python3 - <<'PY'
from pathlib import Path
p = Path("fs/proc/task_mmu.c")
s = p.read_text()
if "#include <trace/hooks/mm.h>" in s:
    raise SystemExit("vendor mm trace hook unexpectedly already present")
anchor = "\n#include <asm/elf.h>"
if s.count(anchor) != 1:
    raise SystemExit("cannot restore vendor mm trace hook")
p.write_text(s.replace(anchor, "\n#include <trace/hooks/mm.h>\n\n#include <asm/elf.h>", 1))

marker = Path("../.restore_namespace_blk_trace_hook")
if marker.exists():
    p = Path("fs/namespace.c")
    s = p.read_text()
    hook = "#include <trace/hooks/blk.h>"
    if hook in s:
        raise SystemExit("namespace blk trace hook unexpectedly already present")
    ns_anchor = '#include "internal.h"\n'
    if s.count(ns_anchor) != 1:
        raise SystemExit("cannot restore namespace blk trace hook")
    p.write_text(s.replace(ns_anchor, ns_anchor + "#include <trace/hooks/blk.h>\n", 1))
    marker.unlink()

# Retain previous manual-hook source only as a disabled fallback path.
p = Path("kernel/reboot.c")
s = p.read_text()
decl = "#ifdef CONFIG_KSU_MANUAL_HOOK\nextern int ksu_handle_sys_reboot(int magic1, int magic2, unsigned int cmd, void __user **arg);\n#endif\n\n"
mutex_anchor = "DEFINE_MUTEX(system_transition_mutex);\n\n"
if s.count(mutex_anchor) != 1:
    raise SystemExit("cannot restore legacy manual reboot declaration")
s = s.replace(mutex_anchor, mutex_anchor + decl, 1)
call = "#ifdef CONFIG_KSU_MANUAL_HOOK\n\tksu_handle_sys_reboot(magic1, magic2, cmd, &arg);\n#endif\n"
flow_anchor = "\n\t/* We only trust the superuser with rebooting the system. */"
if s.count(flow_anchor) != 1:
    raise SystemExit("cannot restore legacy manual reboot call")
p.write_text(s.replace(flow_anchor, "\n" + call + flow_anchor, 1))
PY

grep -qF '#include <trace/hooks/mm.h>' fs/proc/task_mmu.c || fail "TicWatch vendor trace hook not restored"
pass "canonical SuSFS kernel patch applied; vendor trace hook preserved"

log "[9/11] Select KSU Next v3.3.0 + SuSFS daily configuration"
scripts/config --file "$CFG" -e KSU
scripts/config --file "$CFG" -d KSU_DEBUG
scripts/config --file "$CFG" -d KSU_DISABLE_MANAGER
scripts/config --file "$CFG" -d KSU_DISABLE_POLICY
scripts/config --file "$CFG" -e KSU_SUSFS
scripts/config --file "$CFG" -d KSU_SUSFS_ENABLE_LOG
# Disable stale ReSukiSU-only selectors still present in the TicWatch base defconfig.
scripts/config --file "$CFG" -d KSU_MANUAL_HOOK
scripts/config --file "$CFG" -d KSU_TRACEPOINT_HOOK
pass "daily config requested"

log "[10/11] Resolve Kconfig"
make LLVM=1 LLVM_IAS=1 ARCH=arm64 O=out gki_defconfig >>"$REPORT" 2>&1
OUTCFG="$ROOT/common/out/.config"
grep -Fxq 'CONFIG_KSU=y' "$OUTCFG" || fail "CONFIG_KSU did not resolve to y"
grep -Fxq 'CONFIG_KSU_SUSFS=y' "$OUTCFG" || fail "CONFIG_KSU_SUSFS did not resolve to y"
grep -Fxq '# CONFIG_KSU_DEBUG is not set' "$OUTCFG" || fail "KSU debug unexpectedly enabled"
grep -Fxq '# CONFIG_KSU_DISABLE_MANAGER is not set' "$OUTCFG" || fail "manager integration unexpectedly disabled"
grep -Fxq '# CONFIG_KSU_DISABLE_POLICY is not set' "$OUTCFG" || fail "policy support unexpectedly disabled"
if grep -Fxq 'CONFIG_KSU_MANUAL_HOOK=y' "$OUTCFG"; then
  fail "stale ReSukiSU Manual Hook remained enabled"
fi
grep -Fxq "$EXPECTED_LOCALVERSION" "$OUTCFG" || fail "LOCALVERSION changed"
pass "KSU Next/SuSFS config resolved correctly with original TicWatch LOCALVERSION"

log "[11/11] Prepare kernel tree with LLVM"
make LLVM=1 LLVM_IAS=1 ARCH=arm64 O=out prepare >>"$REPORT" 2>&1
pass "kernel prepare completed"

log ""
log "Resolved key config:"
grep -E '^(CONFIG_LOCALVERSION=|CONFIG_KSU=|CONFIG_KSU_SUSFS=|# CONFIG_KSU_(DEBUG|DISABLE_MANAGER|DISABLE_POLICY|SUSFS_ENABLE_LOG|MANUAL_HOOK|TRACEPOINT_HOOK) is not set)' "$OUTCFG" | tee -a "$REPORT" || true
log ""
log "PAIR_MANAGER=$KSUN_MANAGER"
log "PAIR_MANAGER_SHA256=$KSUN_MANAGER_SHA256"
log "RESULT=PASS"