#!/usr/bin/env bash
set -Eeuo pipefail

K="${1:?usage: $0 <kernel-tree>}"
MK="$K/arch/arm64/kernel/machine_kexec.c"

[ -f "$MK" ] || { echo "missing $MK" >&2; exit 2; }

python3 - "$MK" <<'PY'
from pathlib import Path
import sys

p = Path(sys.argv[1])
s = p.read_text()

if 'TWKEXEC_ARM64: ENTER' in s:
    print('ARM64 machine_kexec diagnostics already present')
    raise SystemExit(0)

old = '''void machine_kexec(struct kimage *kimage)\n{\n\tbool in_kexec_crash = (kimage == kexec_crash_image);\n\tbool stuck_cpus = cpus_are_stuck_in_kernel();\n'''
new = '''void machine_kexec(struct kimage *kimage)\n{\n\tbool in_kexec_crash = (kimage == kexec_crash_image);\n\tbool stuck_cpus = cpus_are_stuck_in_kernel();\n\n\tpr_emerg("TWKEXEC_ARM64: ENTER head=%lx start=%lx dtb=%pa online=%u stuck=%d crash=%d\\n",\n\t\t kimage->head, kimage->start, &kimage->arch.dtb_mem,\n\t\t num_online_cpus(), stuck_cpus, in_kexec_crash);\n'''
if s.count(old) != 1:
    raise SystemExit(f'machine_kexec entry anchor mismatch: {s.count(old)}')
s = s.replace(old, new, 1)

old = '''\tWARN(in_kexec_crash && (stuck_cpus || smp_crash_stop_failed()),\n\t\t"Some CPUs may be stale, kdump will be unreliable.\\n");\n\n\tpr_info("Bye!\\n");\n\n\tlocal_daif_mask();\n'''
new = '''\tWARN(in_kexec_crash && (stuck_cpus || smp_crash_stop_failed()),\n\t\t"Some CPUs may be stale, kdump will be unreliable.\\n");\n\n\tpr_emerg("TWKEXEC_ARM64: CPU_CHECKS PASSED\\n");\n\tpr_info("Bye!\\n");\n\tpr_emerg("TWKEXEC_ARM64: DAIF_MASK BEFORE\\n");\n\n\tlocal_daif_mask();\n\tpr_emerg("TWKEXEC_ARM64: DAIF_MASK AFTER\\n");\n'''
if s.count(old) != 1:
    raise SystemExit(f'cpu-check/DAIF anchor mismatch: {s.count(old)}')
s = s.replace(old, new, 1)

old = '''\tif (kimage->head & IND_DONE) {\n\t\ttypeof(cpu_soft_restart) *restart;\n\n\t\tcpu_install_idmap();\n\t\trestart = (void *)__pa_symbol(cpu_soft_restart);\n\t\trestart(is_hyp_nvhe(), kimage->start, kimage->arch.dtb_mem,\n\t\t\t0, 0);\n\t} else {\n'''
new = '''\tif (kimage->head & IND_DONE) {\n\t\ttypeof(cpu_soft_restart) *restart;\n\n\t\tpr_emerg("TWKEXEC_ARM64: BRANCH IND_DONE\\n");\n\t\tpr_emerg("TWKEXEC_ARM64: INSTALL_IDMAP BEFORE\\n");\n\t\tcpu_install_idmap();\n\t\tpr_emerg("TWKEXEC_ARM64: INSTALL_IDMAP AFTER\\n");\n\t\trestart = (void *)__pa_symbol(cpu_soft_restart);\n\t\tpr_emerg("TWKEXEC_ARM64: SOFT_RESTART BEFORE hyp=%d start=%lx dtb=%pa\\n",\n\t\t\t is_hyp_nvhe(), kimage->start, &kimage->arch.dtb_mem);\n\t\trestart(is_hyp_nvhe(), kimage->start, kimage->arch.dtb_mem,\n\t\t\t0, 0);\n\t\tpr_emerg("TWKEXEC_ARM64: SOFT_RESTART RETURNED\\n");\n\t} else {\n'''
if s.count(old) != 1:
    raise SystemExit(f'IND_DONE branch anchor mismatch: {s.count(old)}')
s = s.replace(old, new, 1)

old = '''\t\tvoid (*kernel_reloc)(struct kimage *kimage);\n\n\t\tif (is_hyp_nvhe())\n\t\t\t__hyp_set_vectors(kimage->arch.el2_vectors);\n\t\tcpu_install_ttbr0(kimage->arch.ttbr0, kimage->arch.t0sz);\n\t\tkernel_reloc = (void *)kimage->arch.kern_reloc;\n\t\tkernel_reloc(kimage);\n\t}\n\n\tBUG(); /* Should never get here. */\n'''
new = '''\t\tvoid (*kernel_reloc)(struct kimage *kimage);\n\n\t\tpr_emerg("TWKEXEC_ARM64: BRANCH RELOC\\n");\n\t\tif (is_hyp_nvhe()) {\n\t\t\tpr_emerg("TWKEXEC_ARM64: HYP_VECTORS BEFORE\\n");\n\t\t\t__hyp_set_vectors(kimage->arch.el2_vectors);\n\t\t\tpr_emerg("TWKEXEC_ARM64: HYP_VECTORS AFTER\\n");\n\t\t}\n\t\tpr_emerg("TWKEXEC_ARM64: INSTALL_TTBR0 BEFORE ttbr0=%pa t0sz=%lu\\n",\n\t\t\t &kimage->arch.ttbr0, (unsigned long)kimage->arch.t0sz);\n\t\tcpu_install_ttbr0(kimage->arch.ttbr0, kimage->arch.t0sz);\n\t\tpr_emerg("TWKEXEC_ARM64: INSTALL_TTBR0 AFTER\\n");\n\t\tkernel_reloc = (void *)kimage->arch.kern_reloc;\n\t\tpr_emerg("TWKEXEC_ARM64: KERNEL_RELOC BEFORE phys=%pa\\n", &kimage->arch.kern_reloc);\n\t\tkernel_reloc(kimage);\n\t\tpr_emerg("TWKEXEC_ARM64: KERNEL_RELOC RETURNED\\n");\n\t}\n\n\tpr_emerg("TWKEXEC_ARM64: BUG FALLTHROUGH\\n");\n\tBUG(); /* Should never get here. */\n'''
if s.count(old) != 1:
    raise SystemExit(f'RELOC branch anchor mismatch: {s.count(old)}')
s = s.replace(old, new, 1)

p.write_text(s)
PY

for M in \
  'TWKEXEC_ARM64: ENTER' \
  'TWKEXEC_ARM64: CPU_CHECKS PASSED' \
  'TWKEXEC_ARM64: DAIF_MASK BEFORE' \
  'TWKEXEC_ARM64: DAIF_MASK AFTER' \
  'TWKEXEC_ARM64: BRANCH IND_DONE' \
  'TWKEXEC_ARM64: INSTALL_IDMAP BEFORE' \
  'TWKEXEC_ARM64: INSTALL_IDMAP AFTER' \
  'TWKEXEC_ARM64: SOFT_RESTART BEFORE' \
  'TWKEXEC_ARM64: SOFT_RESTART RETURNED' \
  'TWKEXEC_ARM64: BRANCH RELOC' \
  'TWKEXEC_ARM64: INSTALL_TTBR0 BEFORE' \
  'TWKEXEC_ARM64: INSTALL_TTBR0 AFTER' \
  'TWKEXEC_ARM64: KERNEL_RELOC BEFORE' \
  'TWKEXEC_ARM64: KERNEL_RELOC RETURNED'; do
  grep -Fq "$M" "$MK"
done

echo 'TICWATCH_KEXEC_ARM64_PATH_DIAGNOSTICS=APPLIED'
echo 'TICWATCH_KEXEC_ARM64_PATH_BEHAVIOR_CHANGE=NONE'
