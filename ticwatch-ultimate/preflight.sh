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
EXPECTED_LOCALVERSION='CONFIG_LOCALVERSION="-Xinran_StarBai-Test"'

ROOT="${GITHUB_WORKSPACE:-$PWD}/.ticwatch-preflight"
REPORT="${GITHUB_WORKSPACE:-$PWD}/ticwatch-ultimate-results/preflight.txt"
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

log "TicWatch Ultimate 5.15 / KernelSU Next v3.3.0 preflight"
log "BASE_SHA=$BASE_SHA"
log "KSUN_TAG=$KSUN_TAG"
log "KSUN_SHA=$KSUN_SHA"
log "KSUN_MANAGER=$KSUN_MANAGER"
log "KSUN_MANAGER_SHA256=$KSUN_MANAGER_SHA256"
log "SUSFS_SHA=$SUSFS_SHA"
log ""

log "[1/10] Fetch exact TicWatch source"
fetch_exact "$BASE_REPO" "$BASE_SHA" "$ROOT/common" >>"$REPORT" 2>&1
pass "exact TicWatch base source"

CFG="$ROOT/common/arch/arm64/configs/gki_defconfig"
grep -Fxq "$EXPECTED_LOCALVERSION" "$CFG" || fail "expected TicWatch LOCALVERSION not found"
pass "LOCALVERSION matches installed Xinran_StarBai-Test baseline"

log "[2/10] Fetch exact KernelSU Next v3.3.0 source"
fetch_exact "$KSUN_REPO" "$KSUN_SHA" "$ROOT/common/KernelSU-Next" >>"$REPORT" 2>&1
actual_tag_sha="$(git -C "$ROOT/common/KernelSU-Next" rev-parse HEAD)"
[ "$actual_tag_sha" = "$KSUN_SHA" ] || fail "KernelSU Next v3.3.0 SHA mismatch"
pass "KernelSU Next $KSUN_TAG pinned at $KSUN_SHA"

log "[3/10] Fetch SuSFS revision matched to KSU Next 3.3.0 era"
fetch_exact "$SUSFS_REPO" "$SUSFS_SHA" "$ROOT/susfs4ksu" >>"$REPORT" 2>&1
pass "SuSFS pinned ($SUSFS_BRANCH @ $SUSFS_SHA)"

log "[4/10] Verify and apply SuSFS KernelSU-side patch to KSU Next v3.3.0"
KSU_PATCH="$ROOT/susfs4ksu/kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch"
[ -f "$KSU_PATCH" ] || fail "SuSFS KernelSU-side patch missing"
if ! git -C "$ROOT/common/KernelSU-Next" apply --check "$KSU_PATCH" >>"$REPORT" 2>&1; then
  fail "SuSFS KernelSU-side patch is not cleanly compatible with KernelSU Next v3.3.0"
fi
git -C "$ROOT/common/KernelSU-Next" apply "$KSU_PATCH" >>"$REPORT" 2>&1
grep -qF 'config KSU_SUSFS' "$ROOT/common/KernelSU-Next/kernel/Kconfig" || fail "KSU_SUSFS Kconfig missing after KernelSU-side patch"
pass "SuSFS KernelSU-side patch applies cleanly to KSU Next v3.3.0"

log "[5/10] Link patched KernelSU Next into TicWatch kernel"
cd "$ROOT/common"
ln -sfn "../KernelSU-Next/kernel" drivers/kernelsu
if ! grep -qF 'obj-$(CONFIG_KSU) += kernelsu/' drivers/Makefile; then
  printf '\nobj-$(CONFIG_KSU) += kernelsu/\n' >> drivers/Makefile
fi
if ! grep -qF 'source "drivers/kernelsu/Kconfig"' drivers/Kconfig; then
  sed -i '/endmenu/i\source "drivers/kernelsu/Kconfig"' drivers/Kconfig
fi
[ -f drivers/kernelsu/Kconfig ] || fail "KernelSU Next symlink is invalid"
pass "patched KernelSU Next linked into TicWatch source"

log "[6/10] Normalize known TicWatch-local collisions before kernel-side SuSFS patch"
python3 - <<'PY'
from pathlib import Path

# Preserve the Android vendor trace hook. It collides only with patch context.
p = Path("fs/proc/task_mmu.c")
s = p.read_text()
old = "#include <linux/pkeys.h>\n#include <trace/hooks/mm.h>\n\n#include <asm/elf.h>"
new = "#include <linux/pkeys.h>\n\n#include <asm/elf.h>"
if s.count(old) != 1:
    raise SystemExit("unexpected task_mmu trace-hook context")
p.write_text(s.replace(old, new, 1))

# The TicWatch base contains the previous ReSukiSU manual reboot hook.
# Remove only that exact guarded code temporarily so SuSFS can patch the canonical location.
p = Path("kernel/reboot.c")
s = p.read_text()
decl = "#ifdef CONFIG_KSU_MANUAL_HOOK\nextern int ksu_handle_sys_reboot(int magic1, int magic2, unsigned int cmd, void __user **arg);\n#endif\n\n"
call = "#ifdef CONFIG_KSU_MANUAL_HOOK\n\tksu_handle_sys_reboot(magic1, magic2, cmd, &arg);\n#endif\n"
if s.count(decl) != 1 or s.count(call) != 1:
    raise SystemExit("unexpected reboot manual-hook context")
s = s.replace(decl, "", 1).replace(call, "", 1)
p.write_text(s)
PY
pass "known local collisions normalized"

log "[7/10] Verify and apply Android 13 / Linux 5.15 kernel-side SuSFS patch"
PATCH="$ROOT/susfs4ksu/kernel_patches/50_add_susfs_in_gki-android13-5.15.patch"
[ -f "$PATCH" ] || fail "SuSFS 5.15 kernel patch missing"
if ! git apply --check "$PATCH" >>"$REPORT" 2>&1; then
  fail "SuSFS kernel patch has unaccounted conflicts with the exact TicWatch source"
fi
git apply "$PATCH" >>"$REPORT" 2>&1
cp -a "$ROOT/susfs4ksu/kernel_patches/fs/." fs/
cp -a "$ROOT/susfs4ksu/kernel_patches/include/linux/." include/linux/
[ -f fs/susfs.c ] || fail "fs/susfs.c missing after integration"
[ -f include/linux/susfs.h ] || fail "include/linux/susfs.h missing after integration"

python3 - <<'PY'
from pathlib import Path

# Restore vendor Android trace hook alongside SuSFS includes.
p = Path("fs/proc/task_mmu.c")
s = p.read_text()
if "#include <trace/hooks/mm.h>" in s:
    raise SystemExit("task_mmu trace hook unexpectedly already present")
anchor = "\n#include <asm/elf.h>"
if s.count(anchor) != 1:
    raise SystemExit("cannot restore task_mmu trace hook safely")
s = s.replace(anchor, "\n#include <trace/hooks/mm.h>\n\n#include <asm/elf.h>", 1)
p.write_text(s)

# Keep the old manual reboot hook only as inert source fallback.
# CONFIG_KSU_MANUAL_HOOK is explicitly disabled for the KSU Next daily build.
p = Path("kernel/reboot.c")
s = p.read_text()
decl = "#ifdef CONFIG_KSU_MANUAL_HOOK\nextern int ksu_handle_sys_reboot(int magic1, int magic2, unsigned int cmd, void __user **arg);\n#endif\n\n"
mutex_anchor = "DEFINE_MUTEX(system_transition_mutex);\n\n"
if s.count(mutex_anchor) != 1:
    raise SystemExit("cannot restore reboot manual declaration safely")
s = s.replace(mutex_anchor, mutex_anchor + decl, 1)
call = "#ifdef CONFIG_KSU_MANUAL_HOOK\n\tksu_handle_sys_reboot(magic1, magic2, cmd, &arg);\n#endif\n"
flow_anchor = "\n\t/* We only trust the superuser with rebooting the system. */"
if s.count(flow_anchor) != 1:
    raise SystemExit("cannot restore reboot manual call safely")
s = s.replace(flow_anchor, "\n" + call + flow_anchor, 1)
p.write_text(s)
PY

grep -qF '#include <trace/hooks/mm.h>' fs/proc/task_mmu.c || fail "vendor trace hook not restored"
pass "SuSFS kernel side installed while preserving TicWatch vendor hook"

log "[8/10] Select KSU Next + SuSFS daily configuration"
scripts/config --file "$CFG" -e KSU
scripts/config --file "$CFG" -d KSU_DEBUG
scripts/config --file "$CFG" -d KSU_DISABLE_MANAGER
scripts/config --file "$CFG" -d KSU_DISABLE_POLICY
scripts/config --file "$CFG" -e KSU_SUSFS
scripts/config --file "$CFG" -d KSU_SUSFS_ENABLE_LOG
# Remove stale ReSukiSU-only build selectors from the previous TicWatch defconfig.
scripts/config --file "$CFG" -d KSU_MANUAL_HOOK
scripts/config --file "$CFG" -d KSU_TRACEPOINT_HOOK
pass "KernelSU Next v3.3.0 + SuSFS configuration requested"

log "[9/10] Resolve Kconfig"
make LLVM=1 LLVM_IAS=1 ARCH=arm64 O=out gki_defconfig >>"$REPORT" 2>&1
OUTCFG="$ROOT/common/out/.config"
grep -Fxq 'CONFIG_KSU=y' "$OUTCFG" || fail "CONFIG_KSU did not resolve to y"
grep -Fxq 'CONFIG_KSU_SUSFS=y' "$OUTCFG" || fail "CONFIG_KSU_SUSFS did not resolve to y"
grep -Fxq '# CONFIG_KSU_DEBUG is not set' "$OUTCFG" || fail "KSU debug unexpectedly enabled"
grep -Fxq '# CONFIG_KSU_DISABLE_MANAGER is not set' "$OUTCFG" || fail "manager integration unexpectedly disabled"
if grep -Fxq 'CONFIG_KSU_MANUAL_HOOK=y' "$OUTCFG"; then
  fail "stale ReSukiSU Manual Hook remained enabled"
fi
grep -Fxq "$EXPECTED_LOCALVERSION" "$OUTCFG" || fail "LOCALVERSION changed after Kconfig resolution"
pass "KSU Next/SuSFS config resolved correctly"

log "[10/10] Prepare kernel tree with LLVM"
make LLVM=1 LLVM_IAS=1 ARCH=arm64 O=out prepare >>"$REPORT" 2>&1
pass "kernel prepare completed"

log ""
log "Resolved key config:"
grep -E '^(CONFIG_LOCALVERSION=|CONFIG_KSU=|CONFIG_KSU_SUSFS=|# CONFIG_KSU_(DEBUG|DISABLE_MANAGER|DISABLE_POLICY|SUSFS_ENABLE_LOG|MANUAL_HOOK|TRACEPOINT_HOOK) is not set)' "$OUTCFG" | tee -a "$REPORT" || true
log ""
log "PAIR_MANAGER=$KSUN_MANAGER"
log "PAIR_MANAGER_SHA256=$KSUN_MANAGER_SHA256"
log "RESULT=PASS"