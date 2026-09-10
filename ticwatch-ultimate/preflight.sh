#!/usr/bin/env bash
set -Eeuo pipefail

BASE_REPO="https://github.com/Winkmoon/android_kernel_TicWatch-Pro5.git"
BASE_SHA="3929c55fbc7559af6df290d2c0f66dc551af161a"
RESUKI_REPO="https://github.com/ReSukiSU/ReSukiSU.git"
RESUKI_SHA="246d3e52e667cb72ce8f70c93b70d3b42b100b76"
SUSFS_REPO="https://github.com/ShirkNeko/susfs4ksu.git"
SUSFS_BRANCH="gki-android13-5.15"
SUSFS_SHA="415e4143ee1dd557c54d2b3d94ef098e5d1236f4"
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

log "TicWatch Ultimate 5.15 integration preflight"
log "BASE_SHA=$BASE_SHA"
log "RESUKI_SHA=$RESUKI_SHA"
log "SUSFS_SHA=$SUSFS_SHA"
log ""

log "[1/8] Fetch exact TicWatch source"
fetch_exact "$BASE_REPO" "$BASE_SHA" "$ROOT/common" >>"$REPORT" 2>&1
pass "exact base source"

CFG="$ROOT/common/arch/arm64/configs/gki_defconfig"
grep -Fxq "$EXPECTED_LOCALVERSION" "$CFG" || fail "expected TicWatch LOCALVERSION not found"
pass "LOCALVERSION matches installed Xinran_StarBai-Test baseline"

log "[2/8] Integrate exact ReSukiSU revision"
cd "$ROOT/common"
fetch_exact "$RESUKI_REPO" "$RESUKI_SHA" "$ROOT/common/KernelSU" >>"$REPORT" 2>&1

ln -sfn "../KernelSU/kernel" drivers/kernelsu
if ! grep -qF 'obj-$(CONFIG_KSU) += kernelsu/' drivers/Makefile; then
  printf '\nobj-$(CONFIG_KSU) += kernelsu/\n' >> drivers/Makefile
fi
if ! grep -qF 'source "drivers/kernelsu/Kconfig"' drivers/Kconfig; then
  sed -i '/endmenu/i\source "drivers/kernelsu/Kconfig"' drivers/Kconfig
fi
pass "ReSukiSU pinned and linked"

log "[3/8] Fetch exact SuSFS Android 13 / Linux 5.15 revision"
fetch_exact "$SUSFS_REPO" "$SUSFS_SHA" "$ROOT/susfs4ksu" >>"$REPORT" 2>&1
branch_contains="$(git -C "$ROOT/susfs4ksu" branch -r --contains "$SUSFS_SHA" 2>/dev/null || true)"
# The SHA is authoritative; branch name is documented for provenance only.
pass "SuSFS pinned ($SUSFS_BRANCH @ $SUSFS_SHA)"

log "[4/8] Normalize two known TicWatch-local hook collisions"
python3 - <<'PY'
from pathlib import Path

# TicWatch carries an Android trace hook between pkeys.h and asm/elf.h.
# Remove it only temporarily so the canonical SuSFS hunk can be verified/applied;
# it is restored immediately afterwards.
p = Path("fs/proc/task_mmu.c")
s = p.read_text()
old = "#include <linux/pkeys.h>\n#include <trace/hooks/mm.h>\n\n#include <asm/elf.h>"
new = "#include <linux/pkeys.h>\n\n#include <asm/elf.h>"
if s.count(old) != 1:
    raise SystemExit("unexpected task_mmu trace-hook context")
p.write_text(s.replace(old, new, 1))

# The working TicWatch tree already carries ReSukiSU's legacy manual reboot hook.
# SuSFS 2.x patches the same location. Temporarily remove only those exact guarded
# blocks, then restore them after patching so manual-hook remains an alternate build mode.
p = Path("kernel/reboot.c")
s = p.read_text()
decl = "#ifdef CONFIG_KSU_MANUAL_HOOK\nextern int ksu_handle_sys_reboot(int magic1, int magic2, unsigned int cmd, void __user **arg);\n#endif\n\n"
call = "#ifdef CONFIG_KSU_MANUAL_HOOK\n\tksu_handle_sys_reboot(magic1, magic2, cmd, &arg);\n#endif\n"
if s.count(decl) != 1 or s.count(call) != 1:
    raise SystemExit("unexpected reboot manual-hook context")
s = s.replace(decl, "", 1).replace(call, "", 1)
p.write_text(s)
PY
pass "known local collisions normalized without deleting their functionality"

log "[5/8] Strict kernel-side SuSFS patch compatibility check"
PATCH="$ROOT/susfs4ksu/kernel_patches/50_add_susfs_in_gki-android13-5.15.patch"
[ -f "$PATCH" ] || fail "SuSFS 5.15 kernel patch missing"
if ! git apply --check "$PATCH" >>"$REPORT" 2>&1; then
  fail "SuSFS kernel patch still has unaccounted conflicts after exact local normalization"
fi
pass "canonical SuSFS kernel patch applies after two explicit TicWatch adaptations"

git apply "$PATCH" >>"$REPORT" 2>&1
cp -a "$ROOT/susfs4ksu/kernel_patches/fs/." fs/
cp -a "$ROOT/susfs4ksu/kernel_patches/include/linux/." include/linux/
[ -f fs/susfs.c ] || fail "fs/susfs.c missing after integration"
[ -f include/linux/susfs.h ] || fail "include/linux/susfs.h missing after integration"

python3 - <<'PY'
from pathlib import Path

# Restore the TicWatch Android trace hook, now adjacent to (not replacing) SuSFS includes.
p = Path("fs/proc/task_mmu.c")
s = p.read_text()
if "#include <trace/hooks/mm.h>" in s:
    raise SystemExit("task_mmu trace hook unexpectedly already present")
anchor = "\n#include <asm/elf.h>"
if s.count(anchor) != 1:
    raise SystemExit("cannot restore task_mmu trace hook safely")
s = s.replace(anchor, "\n#include <trace/hooks/mm.h>\n\n#include <asm/elf.h>", 1)
p.write_text(s)

# Restore the legacy manual reboot hook behind CONFIG_KSU_MANUAL_HOOK.
# It is compiled out in the SuSFS daily build, but retained for a controlled fallback build.
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
grep -qF '#ifdef CONFIG_KSU_MANUAL_HOOK' kernel/reboot.c || fail "manual reboot fallback not restored"
pass "SuSFS installed; TicWatch vendor trace hook and manual fallback preserved"

log "[6/8] Select ReSukiSU SuSFS inline hook, not Manual Hook"
scripts/config --file "$CFG" -e KSU
scripts/config --file "$CFG" -d KSU_TRACEPOINT_HOOK
scripts/config --file "$CFG" -d KSU_MANUAL_HOOK
scripts/config --file "$CFG" -e KSU_SUSFS
# Daily-use policy: no permanent SuSFS kernel log.
scripts/config --file "$CFG" -d KSU_SUSFS_ENABLE_LOG
pass "requested KSU/SuSFS config written"

log "[7/8] Resolve Kconfig"
make LLVM=1 LLVM_IAS=1 ARCH=arm64 O=out gki_defconfig >>"$REPORT" 2>&1
OUTCFG="$ROOT/common/out/.config"
grep -Fxq 'CONFIG_KSU=y' "$OUTCFG" || fail "CONFIG_KSU did not resolve to y"
grep -Fxq 'CONFIG_KSU_SUSFS=y' "$OUTCFG" || fail "CONFIG_KSU_SUSFS did not resolve to y"
if grep -Fxq 'CONFIG_KSU_MANUAL_HOOK=y' "$OUTCFG"; then
  fail "Manual Hook remained enabled together with SuSFS"
fi
if grep -Fxq 'CONFIG_KSU_TRACEPOINT_HOOK=y' "$OUTCFG"; then
  fail "Tracepoint Hook remained enabled together with SuSFS"
fi
grep -Fxq "$EXPECTED_LOCALVERSION" "$OUTCFG" || fail "LOCALVERSION changed after Kconfig resolution"
pass "exclusive SuSFS hook configuration resolved correctly"

log "[8/8] Prepare kernel tree with LLVM"
make LLVM=1 LLVM_IAS=1 ARCH=arm64 O=out prepare >>"$REPORT" 2>&1
pass "kernel prepare completed"

log ""
log "Resolved key config:"
grep -E '^(CONFIG_LOCALVERSION=|CONFIG_KSU=|CONFIG_KSU_(SUSFS|MANUAL_HOOK|TRACEPOINT_HOOK)=|# CONFIG_KSU_(SUSFS_ENABLE_LOG|MANUAL_HOOK|TRACEPOINT_HOOK) is not set)' "$OUTCFG" | tee -a "$REPORT" || true
log ""
log "RESULT=PASS"