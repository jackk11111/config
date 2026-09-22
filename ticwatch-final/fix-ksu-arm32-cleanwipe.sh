#!/usr/bin/env bash
set -Eeuo pipefail

K="${1:?usage: $0 <kernel-tree>}"
KSUN="$K/KernelSU-Next"
C="$KSUN/kernel/infra/seccomp_cache.c"
H="$KSUN/kernel/infra/seccomp_cache.h"
S="$KSUN/kernel/hook/setuid_hook.c"
R="$KSUN/userspace/ksud/src/susfsd.rs"

for F in "$C" "$H" "$S" "$R"; do
  [ -f "$F" ] || { echo "missing $F" >&2; exit 2; }
done

python3 - "$C" "$H" "$S" "$R" <<'PY'
from pathlib import Path
import sys
cp,hp,sp,rp = map(Path, sys.argv[1:])
c,h,s,r = (p.read_text() for p in (cp,hp,sp,rp))

# KernelSU Next 3.3.0 uses the native syscall number for both native and
# compat seccomp caches. On arm64, reboot is 142 natively but 88 for AArch32.
# A 32-bit Manager helper therefore hits SIGSYS after a clean wipe.
decl='extern void ksu_seccomp_allow_cache(struct seccomp_filter *filter, int nr);\n'
newdecl=decl+'extern void ksu_seccomp_allow_cache_arch(struct seccomp_filter *filter, int native_nr, int compat_nr);\n'
if 'ksu_seccomp_allow_cache_arch' not in h:
    if h.count(decl) != 1:
        raise SystemExit('seccomp_cache.h anchor mismatch')
    h=h.replace(decl,newdecl,1)

anchor='''void ksu_seccomp_allow_cache(struct seccomp_filter *filter, int nr)
{
    if (!filter) {
        return;
    }

    if (nr >= 0 && nr < SECCOMP_ARCH_NATIVE_NR) {
        set_bit(nr, filter->cache.allow_native);
    }

#ifdef SECCOMP_ARCH_COMPAT
    if (nr >= 0 && nr < SECCOMP_ARCH_COMPAT_NR) {
        set_bit(nr, filter->cache.allow_compat);
    }
#endif
}
'''
helper=anchor+'''
void ksu_seccomp_allow_cache_arch(struct seccomp_filter *filter, int native_nr, int compat_nr)
{
    if (!filter) {
        return;
    }

    if (native_nr >= 0 && native_nr < SECCOMP_ARCH_NATIVE_NR) {
        set_bit(native_nr, filter->cache.allow_native);
    }

#ifdef SECCOMP_ARCH_COMPAT
    if (compat_nr >= 0 && compat_nr < SECCOMP_ARCH_COMPAT_NR) {
        set_bit(compat_nr, filter->cache.allow_compat);
    }
#endif
}
'''
if 'void ksu_seccomp_allow_cache_arch' not in c:
    if c.count(anchor) != 1:
        raise SystemExit('seccomp_cache.c anchor mismatch')
    c=c.replace(anchor,helper,1)

old='ksu_seccomp_allow_cache(current->seccomp.filter, __NR_reboot);'
new='''#if defined(CONFIG_ARM64) && defined(CONFIG_COMPAT)
            /* AArch64 reboot=142; AArch32 compat reboot=88. */
            ksu_seccomp_allow_cache_arch(current->seccomp.filter, __NR_reboot, 88);
#else
            ksu_seccomp_allow_cache(current->seccomp.filter, __NR_reboot);
#endif'''
count=s.count(old)
if count not in (0,2):
    raise SystemExit(f'unexpected reboot cache call count: {count}')
if count == 2:
    s=s.replace(old,new)

# ARM32 libc::syscall varargs must be c_long, not u64, for SuSFS commands.
if 'use libc::{syscall, SYS_reboot, c_char};' in r:
    r=r.replace('use libc::{syscall, SYS_reboot, c_char};',
                'use libc::{syscall, SYS_reboot, c_char, c_long};',1)
repl={
'syscall(SYS_reboot, KSU_INSTALL_MAGIC1, SUSFS_MAGIC, CMD_SUSFS_SHOW_VERSION, &mut cmd as *mut _);':
'syscall(SYS_reboot as c_long, KSU_INSTALL_MAGIC1 as c_long, SUSFS_MAGIC as c_long, CMD_SUSFS_SHOW_VERSION as c_long, &mut cmd as *mut _);',
'syscall(SYS_reboot, KSU_INSTALL_MAGIC1, SUSFS_MAGIC, CMD_SUSFS_SHOW_VARIANT, &mut cmd as *mut _);':
'syscall(SYS_reboot as c_long, KSU_INSTALL_MAGIC1 as c_long, SUSFS_MAGIC as c_long, CMD_SUSFS_SHOW_VARIANT as c_long, &mut cmd as *mut _);',
'syscall(SYS_reboot, KSU_INSTALL_MAGIC1, SUSFS_MAGIC, CMD_SUSFS_SHOW_ENABLED_FEATURES, &mut cmd as *mut _);':
'syscall(SYS_reboot as c_long, KSU_INSTALL_MAGIC1 as c_long, SUSFS_MAGIC as c_long, CMD_SUSFS_SHOW_ENABLED_FEATURES as c_long, &mut cmd as *mut _);'
}
for oldcall,newcall in repl.items():
    if oldcall in r:
        r=r.replace(oldcall,newcall,1)

cp.write_text(c); hp.write_text(h); sp.write_text(s); rp.write_text(r)
PY

grep -Fq 'ksu_seccomp_allow_cache_arch(current->seccomp.filter, __NR_reboot, 88);' "$S"
test "$(grep -Fc 'ksu_seccomp_allow_cache_arch(current->seccomp.filter, __NR_reboot, 88);' "$S")" -eq 2
grep -Fq 'void ksu_seccomp_allow_cache_arch' "$C"
grep -Fq 'extern void ksu_seccomp_allow_cache_arch' "$H"
grep -Fq 'c_long' "$R"
test "$(grep -Fc 'syscall(SYS_reboot as c_long' "$R")" -eq 3

echo 'KSU_ARM32_SECCOMP_REBOOT_COMPAT=FIXED_NATIVE142_COMPAT88'
echo 'KSU_SUSFS_ARM32_C_LONG=FIXED'
