#!/usr/bin/env bash
set -Eeuo pipefail

WS="${GITHUB_WORKSPACE:-$PWD}"
K="$WS/.ticwatch-preflight/common"
KSUN="$K/KernelSU-Next"
SUSROOT="$WS/.ticwatch-preflight/susfs4ksu-v230"
AUDIT="$WS/ksun340-susfs230-audit"

: "${KSUN_CORE_SHA:=1a879d6a866f80b1fa1c1009a2ffa747873cbb5e}"
: "${SUSFS_KSU_INTEGRATION_SHA:=34d71c4d10a53cecb9759b4787944a2a65bb3d8d}"
: "${SUSFS_CORE_SHA:=687d2d18d94cb2e3e72d1074778d58384d58e379}"

fail() { echo "FAIL: $*" >&2; exit 1; }

[ -d "$K/.git" ] || fail "verified 5.15.220 common tree missing"
[ "$(make -s -C "$K" kernelversion)" = "5.15.220" ] || fail "common tree is not Linux 5.15.220"

rm -rf "$AUDIT"
mkdir -p "$AUDIT"

echo "=== RESET TO VERIFIED LINUX 5.15.220 SOURCE ==="
git -C "$K" reset --hard HEAD
# KernelSU-Next is a nested Git repository, so git clean -fdx deliberately
# does not remove it. Delete only that old KSU 3.3 source tree explicitly;
# the exact v3.4.0 tree is fetched immediately below.
rm -rf "$KSUN"
git -C "$K" clean -fdx
test -z "$(git -C "$K" status --porcelain)"

echo "=== EXACT KERNELSU NEXT v3.4.0 ==="
git init -q "$KSUN"
git -C "$KSUN" remote add origin https://github.com/KernelSU-Next/KernelSU-Next.git
git -C "$KSUN" fetch -q --depth=1 origin "$KSUN_CORE_SHA"
git -C "$KSUN" checkout -q --detach FETCH_HEAD
[ "$(git -C "$KSUN" rev-parse HEAD)" = "$KSUN_CORE_SHA" ] || fail "KSU 3.4 source mismatch"
git -C "$KSUN" remote add pershoot https://github.com/pershoot/KernelSU-Next.git
git -C "$KSUN" fetch -q --no-tags pershoot "$SUSFS_KSU_INTEGRATION_SHA"

echo "=== PORT PERSHOOT SUSFS 2.3 INTEGRATION ON TOP OF EXACT v3.4.0 ==="
set +e
git -C "$KSUN" cherry-pick -n "$SUSFS_KSU_INTEGRATION_SHA" >"$AUDIT/cherry-pick.log" 2>&1
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "expected three audited conflicts disappeared; re-audit integration"

mapfile -t U < <(git -C "$KSUN" diff --name-only --diff-filter=U)
printf '%s\n' "${U[@]}" > "$AUDIT/unmerged-before.txt"
[ "${#U[@]}" -eq 3 ] || fail "unexpected SuSFS conflict count: ${#U[@]}"
printf '%s\n' "${U[@]}" | grep -Fxq 'kernel/Kbuild'
printf '%s\n' "${U[@]}" | grep -Fxq 'kernel/hook/syscall_event_bridge.c'
printf '%s\n' "${U[@]}" | grep -Fxq 'kernel/runtime/ksud_integration.c'

python3 - "$KSUN" <<'PY'
from pathlib import Path
import sys
root=Path(sys.argv[1])

def resolve(rel, old, new):
    p=root/rel
    s=p.read_text()
    if s.count(old) != 1:
        raise SystemExit(f"{rel}: audited conflict anchor count={s.count(old)}")
    p.write_text(s.replace(old,new,1))

resolve("kernel/Kbuild",
"""<<<<<<< HEAD
ifeq ($(CONFIG_ARM64),y)
kernelsu-objs += hook/arm64/patch_memory.o
kernelsu-objs += hook/arm64/syscall_hook.o
else ifeq ($(CONFIG_X86_64),y)
kernelsu-objs += hook/x86_64/patch_memory.o
kernelsu-objs += hook/x86_64/syscall_hook.o
=======
ifdef KSU_ARCH
kernelsu-objs += hook/$(KSU_ARCH)/syscall_hook.o
>>>>>>> 34d71c4d (kernel: susfs (v2.3.0): Introduce SuSFS)
""",
"""ifdef KSU_ARCH
kernelsu-objs += hook/$(KSU_ARCH)/syscall_hook.o
""")

resolve("kernel/hook/syscall_event_bridge.c",
"""<<<<<<< HEAD
    const char __user **filename_user =
        execveat ? (const char __user **)&PT_REGS_PARM2(regs) : (const char __user **)&PT_REGS_PARM1(regs);
    const char __user *const __user *argv_user = execveat ? (const char __user *const __user *)PT_REGS_PARM3(regs) :
                                                            (const char __user *const __user *)PT_REGS_PARM2(regs);
    bool current_is_init = is_init(current_cred());
    struct ksu_sulog_pending_event *pending_root_execve = NULL;
    long ret;
=======
\tconst char __user **filename_user =
\t\texecveat ? (const char __user **)&PT_REGS_PARM2(regs) : (const char __user **)&PT_REGS_SYSCALL_PARM1(regs);
\tconst char __user *const __user *argv_user = execveat ? (const char __user *const __user *)PT_REGS_PARM3(regs) :
\t\t\t\t\t\t\t\t(const char __user *const __user *)PT_REGS_PARM2(regs);
\tbool current_is_init = is_init(current_cred());
\tstruct ksu_sulog_pending_event *pending_root_execve = NULL;
\tlong ret;
>>>>>>> 34d71c4d (kernel: susfs (v2.3.0): Introduce SuSFS)
""",
"""\tconst char __user **filename_user =
\t\texecveat ? (const char __user **)&PT_REGS_PARM2(regs) : (const char __user **)&PT_REGS_SYSCALL_PARM1(regs);
\tconst char __user *const __user *argv_user = execveat ? (const char __user *const __user *)PT_REGS_PARM3(regs) :
\t\t\t\t\t\t\t\t(const char __user *const __user *)PT_REGS_PARM2(regs);
\tbool current_is_init = is_init(current_cred());
\tstruct ksu_sulog_pending_event *pending_root_execve = NULL;
\tlong ret;
""")

resolve("kernel/runtime/ksud_integration.c",
"""<<<<<<< HEAD
    unsigned int fd = PT_REGS_PARM1(regs);
    char __user **buf_ptr = (char __user **)&PT_REGS_PARM2(regs);
    size_t *count_ptr = (size_t *)&PT_REGS_PARM3(regs);
=======
    unsigned int fd = PT_REGS_SYSCALL_PARM1(regs);
>>>>>>> 34d71c4d (kernel: susfs (v2.3.0): Introduce SuSFS)
""",
"""    unsigned int fd = PT_REGS_SYSCALL_PARM1(regs);
""")
PY

! grep -R -nE '^(<<<<<<<|=======|>>>>>>>)' "$KSUN/kernel"
git -C "$KSUN" add kernel/Kbuild kernel/hook/syscall_event_bridge.c kernel/runtime/ksud_integration.c
[ -z "$(git -C "$KSUN" diff --name-only --diff-filter=U)" ] || fail "unmerged KSU files remain"
git -C "$KSUN" cherry-pick --quit

# Normalize only whitespace introduced by the upstream integration commit.
sed -i 's/[[:space:]]\+$//' "$KSUN/kernel/selinux/selinux.c" "$KSUN/kernel/supercall/dispatch.c"
python3 - "$KSUN/kernel/Kbuild" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); p.write_text(p.read_text().rstrip()+"\n")
PY
git -C "$KSUN" add -A
git -C "$KSUN" diff --cached --check

grep -Fq 'ifneq ($(strip $(CONFIG_KSU_SUSFS)),y)' "$KSUN/kernel/Kbuild"
grep -Fq 'kernelsu-objs += hook/$(KSU_ARCH)/syscall_hook.o' "$KSUN/kernel/Kbuild"
grep -Fq 'static_branch_likely(&ksu_su_compat_enabled)' "$KSUN/kernel/hook/syscall_event_bridge.c"
grep -Fq 'PT_REGS_SYSCALL_PARM1(regs)' "$KSUN/kernel/runtime/ksud_integration.c"
grep -Fq 'ksu_handle_sys_read(fd, NULL, NULL);' "$KSUN/kernel/runtime/ksud_integration.c"
grep -Fq 'DEFINE_STATIC_KEY_TRUE(is_first_zygote);' "$KSUN/kernel/runtime/ksud_integration.c"
grep -Fq 'static_branch_disable(&is_first_zygote);' "$KSUN/kernel/runtime/ksud_integration.c"
grep -Fq 'config KSU_SUSFS' "$KSUN/kernel/Kconfig"

echo "=== EXACT CURRENT ANDROID13-5.15 SUSFS 2.3 KERNEL SIDE ==="
rm -rf "$SUSROOT"
git init -q "$SUSROOT"
git -C "$SUSROOT" remote add origin https://github.com/ShirkNeko/susfs4ksu.git
git -C "$SUSROOT" fetch -q --depth=1 origin "$SUSFS_CORE_SHA"
git -C "$SUSROOT" checkout -q --detach FETCH_HEAD
[ "$(git -C "$SUSROOT" rev-parse HEAD)" = "$SUSFS_CORE_SHA" ] || fail "SuSFS source mismatch"
susver="$(grep '#define SUSFS_VERSION' "$SUSROOT/kernel_patches/include/linux/susfs.h" | awk -F'"' '{print $2}')"
[ "$susver" = "v2.3.0" ] || fail "expected SuSFS v2.3.0, got $susver"

echo "=== LINK KSU 3.4 INTO TICWATCH KERNEL ==="
cd "$K"
ln -sfn "../KernelSU-Next/kernel" drivers/kernelsu
grep -qF 'obj-$(CONFIG_KSU) += kernelsu/' drivers/Makefile || printf '\nobj-$(CONFIG_KSU) += kernelsu/\n' >> drivers/Makefile
grep -qF 'source "drivers/kernelsu/Kconfig"' drivers/Kconfig || sed -i '/endmenu/i\source "drivers/kernelsu/Kconfig"' drivers/Kconfig
[ -f drivers/kernelsu/Kconfig ] || fail "KernelSU symlink invalid"

echo "=== NORMALIZE KNOWN TICWATCH 5.15.220 PATCH CONTEXT ==="
python3 - <<'PY'
from pathlib import Path

p=Path("fs/proc/task_mmu.c"); s=p.read_text()
old="#include <linux/pkeys.h>\n#include <trace/hooks/mm.h>\n\n#include <asm/elf.h>"
new="#include <linux/pkeys.h>\n\n#include <asm/elf.h>"
if s.count(old)!=1: raise SystemExit("task_mmu vendor hook context changed")
p.write_text(s.replace(old,new,1))

p=Path("fs/namespace.c"); s=p.read_text()
hook="#include <trace/hooks/blk.h>\n"
marker=Path("../.restore_namespace_blk_trace_hook")
if marker.exists(): marker.unlink()
if s.count(hook)>1: raise SystemExit("namespace blk trace hook count changed")
if s.count(hook)==1:
    p.write_text(s.replace(hook,"",1)); marker.write_text("1\n")

p=Path("kernel/reboot.c"); s=p.read_text()
decl="#ifdef CONFIG_KSU_MANUAL_HOOK\nextern int ksu_handle_sys_reboot(int magic1, int magic2, unsigned int cmd, void __user **arg);\n#endif\n\n"
call="#ifdef CONFIG_KSU_MANUAL_HOOK\n\tksu_handle_sys_reboot(magic1, magic2, cmd, &arg);\n#endif\n"
if s.count(decl)!=1 or s.count(call)!=1: raise SystemExit("legacy reboot hook context changed")
p.write_text(s.replace(decl,"",1).replace(call,"",1))
PY

PATCH="$SUSROOT/kernel_patches/50_add_susfs_in_gki-android13-5.15.patch"
git apply --check "$PATCH"
git apply "$PATCH"
cp -a "$SUSROOT/kernel_patches/fs/." fs/
cp -a "$SUSROOT/kernel_patches/include/linux/." include/linux/
[ -f fs/susfs.c ] || fail "fs/susfs.c missing"
[ -f include/linux/susfs.h ] || fail "include/linux/susfs.h missing"

python3 - <<'PY'
from pathlib import Path

p=Path("fs/proc/task_mmu.c"); s=p.read_text()
if "#include <trace/hooks/mm.h>" in s: raise SystemExit("task_mmu vendor hook already present")
anchor="\n#include <asm/elf.h>"
if s.count(anchor)!=1: raise SystemExit("cannot restore mm vendor hook")
p.write_text(s.replace(anchor,"\n#include <trace/hooks/mm.h>\n\n#include <asm/elf.h>",1))

marker=Path("../.restore_namespace_blk_trace_hook")
if marker.exists():
    p=Path("fs/namespace.c"); s=p.read_text()
    hook="#include <trace/hooks/blk.h>"
    if hook in s: raise SystemExit("namespace blk hook already present")
    anchor='#include "internal.h"\n'
    if s.count(anchor)!=1: raise SystemExit("cannot restore namespace blk hook")
    p.write_text(s.replace(anchor,anchor+"#include <trace/hooks/blk.h>\n",1))
    marker.unlink()

# Retain the old manual-hook source only as a disabled fallback.
p=Path("kernel/reboot.c"); s=p.read_text()
decl="#ifdef CONFIG_KSU_MANUAL_HOOK\nextern int ksu_handle_sys_reboot(int magic1, int magic2, unsigned int cmd, void __user **arg);\n#endif\n\n"
mutex="DEFINE_MUTEX(system_transition_mutex);\n\n"
if s.count(mutex)!=1: raise SystemExit("reboot declaration anchor changed")
s=s.replace(mutex,mutex+decl,1)
call="#ifdef CONFIG_KSU_MANUAL_HOOK\n\tksu_handle_sys_reboot(magic1, magic2, cmd, &arg);\n#endif\n"
flow="\n\t/* We only trust the superuser with rebooting the system. */"
if s.count(flow)!=1: raise SystemExit("reboot flow anchor changed")
p.write_text(s.replace(flow,"\n"+call+flow,1))
PY

grep -qF '#include <trace/hooks/mm.h>' fs/proc/task_mmu.c

echo "=== TICWATCH-SPECIFIC KSU HARDENING ==="
python3 - "$KSUN/kernel/runtime/ksud_integration.c" "$KSUN/kernel/hook/setuid_hook.c" "$KSUN/userspace/ksud/src/susfsd.rs" <<'PY'
from pathlib import Path
import sys
runtime=Path(sys.argv[1]); setuid=Path(sys.argv[2]); susfsd=Path(sys.argv[3])

s=runtime.read_text()
a='if (*type == EV_KEY && *code == KEY_VOLUMEDOWN) {'
b='if (*type == EV_KEY && (*code == KEY_VOLUMEDOWN || *code == KEY_MENU)) {'
if s.count(a)!=1: raise SystemExit("safe-key keycode anchor changed")
s=s.replace(a,b,1)
a='pr_info("KEY_VOLUMEDOWN val: %d\\n", val);'
b='pr_info("KSU safe key code=%u val=%d\\n", *code, val);'
if s.count(a)!=1: raise SystemExit("safe-key log anchor changed")
s=s.replace(a,b,1)
# Limit this change to the safe-key handler before ksu_is_safe_mode().
prefix,sep,suffix=s.partition('bool ksu_is_safe_mode()')
if not sep: raise SystemExit("safe-key function boundary changed")
if prefix.count('if (val) {')!=1: raise SystemExit("safe-key value anchor changed")
prefix=prefix.replace('if (val) {','if (val == 1) {',1)
runtime.write_text(prefix+sep+suffix)

s=setuid.read_text()
old='''    if (likely(ksu_is_manager_appid_valid()) && unlikely(is_uid_manager(ruid))) {
        disable_seccomp();
        pr_info("install fd for manager: %d\\n", ruid);
        ksu_install_fd();
        return 0;
    }
'''
new='''    if (likely(ksu_is_manager_appid_valid()) && unlikely(is_uid_manager(ruid))) {
        /* Preserve Android seccomp FILTER; permit only the KSU reboot supercall. */
        if (current->seccomp.mode == SECCOMP_MODE_FILTER && current->seccomp.filter) {
            spin_lock_irq(&current->sighand->siglock);
            ksu_seccomp_allow_cache(current->seccomp.filter, __NR_reboot);
            spin_unlock_irq(&current->sighand->siglock);
        }
        pr_info("install fd for manager: %d\\n", ruid);
        ksu_install_fd();
        return 0;
    }
'''
if s.count(old)!=2: raise SystemExit(f"manager seccomp anchor count changed: {s.count(old)}")
s=s.replace(old,new)
setuid.write_text(s)

s=susfsd.read_text()
old='use libc::{syscall, SYS_reboot, c_char};'
if s.count(old)!=1: raise SystemExit("ARM32 susfs import anchor changed")
s=s.replace(old,'use libc::{syscall, SYS_reboot, c_char, c_long};',1)
repl={
 'syscall(SYS_reboot, KSU_INSTALL_MAGIC1, SUSFS_MAGIC, CMD_SUSFS_SHOW_VERSION, &mut cmd as *mut _);':
 'syscall(SYS_reboot as c_long, KSU_INSTALL_MAGIC1 as c_long, SUSFS_MAGIC as c_long, CMD_SUSFS_SHOW_VERSION as c_long, &mut cmd as *mut _);',
 'syscall(SYS_reboot, KSU_INSTALL_MAGIC1, SUSFS_MAGIC, CMD_SUSFS_SHOW_VARIANT, &mut cmd as *mut _);':
 'syscall(SYS_reboot as c_long, KSU_INSTALL_MAGIC1 as c_long, SUSFS_MAGIC as c_long, CMD_SUSFS_SHOW_VARIANT as c_long, &mut cmd as *mut _);',
 'syscall(SYS_reboot, KSU_INSTALL_MAGIC1, SUSFS_MAGIC, CMD_SUSFS_SHOW_ENABLED_FEATURES, &mut cmd as *mut _);':
 'syscall(SYS_reboot as c_long, KSU_INSTALL_MAGIC1 as c_long, SUSFS_MAGIC as c_long, CMD_SUSFS_SHOW_ENABLED_FEATURES as c_long, &mut cmd as *mut _);'
}
for a,b in repl.items():
    if s.count(a)!=1: raise SystemExit("ARM32 susfs syscall anchor changed")
    s=s.replace(a,b,1)
susfsd.write_text(s)
PY

grep -Fq '(*code == KEY_VOLUMEDOWN || *code == KEY_MENU)' "$KSUN/kernel/runtime/ksud_integration.c"
grep -Fq 'if (val == 1)' "$KSUN/kernel/runtime/ksud_integration.c"
[ "$(grep -Fc 'Preserve Android seccomp FILTER' "$KSUN/kernel/hook/setuid_hook.c")" -eq 2 ]
grep -Fq 'SYS_reboot as c_long' "$KSUN/userspace/ksud/src/susfsd.rs"

echo "=== KCONFIG REQUEST ==="
CFG="$K/arch/arm64/configs/gki_defconfig"
scripts/config --file "$CFG" -e KSU
scripts/config --file "$CFG" -d KSU_DEBUG
scripts/config --file "$CFG" -d KSU_DISABLE_MANAGER
scripts/config --file "$CFG" -d KSU_DISABLE_POLICY
scripts/config --file "$CFG" -e KSU_SUSFS
scripts/config --file "$CFG" -d KSU_SUSFS_ENABLE_LOG
scripts/config --file "$CFG" -d KSU_MANUAL_HOOK
scripts/config --file "$CFG" -d KSU_TRACEPOINT_HOOK

# Provenance: HEAD stays exact official v3.4.0; SuSFS integration remains a staged source delta.
[ "$(git -C "$KSUN" rev-parse HEAD)" = "$KSUN_CORE_SHA" ] || fail "KSU HEAD moved off official v3.4.0"
git -C "$KSUN" diff HEAD > "$AUDIT/ksun340-plus-susfs230.patch"
git -C "$K" diff > "$AUDIT/ticwatch-kernel-susfs230.patch"
test -s "$AUDIT/ksun340-plus-susfs230.patch"
test -s "$AUDIT/ticwatch-kernel-susfs230.patch"

{
  echo "LINUX=5.15.220"
  echo "KSUN_BASE=$KSUN_CORE_SHA"
  echo "KSUN_TAG=v3.4.0"
  echo "SUSFS_INTEGRATION=$SUSFS_KSU_INTEGRATION_SHA"
  echo "SUSFS_KERNEL_SOURCE=$SUSFS_CORE_SHA"
  echo "SUSFS_VERSION=$susver"
  echo "SAFEKEY=VOLUMEDOWN_OR_KEY_MENU_REAL_DOWN_ONLY"
  echo "MANAGER_SECCOMP=FILTER_PRESERVED_REBOOT_SUPERCALL_ALLOWED"
  echo "ARM32_SUSFS_C_LONG_FIX=YES"
  echo "RESULT=PASS"
} | tee "$AUDIT/PROVENANCE.txt"

sha256sum "$AUDIT/"*.patch "$AUDIT/PROVENANCE.txt" > "$AUDIT/SHA256SUMS.txt"
echo "KSU340_SUSFS230_INTEGRATION=PASS"
