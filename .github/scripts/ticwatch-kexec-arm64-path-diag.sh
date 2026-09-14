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

def once(old, new, label):
    global s
    n = s.count(old)
    if n != 1:
        raise SystemExit(f'{label} anchor mismatch: {n}')
    s = s.replace(old, new, 1)

# Use small, structurally unique anchors instead of matching whole vendor blocks.
# Every insertion remains fail-closed: exactly one source occurrence is required.
once(
    '\tbool stuck_cpus = cpus_are_stuck_in_kernel();\n',
    '\tbool stuck_cpus = cpus_are_stuck_in_kernel();\n\n'
    '\tpr_emerg("TWKEXEC_ARM64: ENTER head=%lx start=%lx dtb=%pa online=%u stuck=%d crash=%d\\n",\n'
    '\t\t kimage->head, kimage->start, &kimage->arch.dtb_mem,\n'
    '\t\t num_online_cpus(), stuck_cpus, in_kexec_crash);\n',
    'machine_kexec entry')

once(
    '\tpr_info("Bye!\\n");\n',
    '\tpr_emerg("TWKEXEC_ARM64: CPU_CHECKS PASSED\\n");\n'
    '\tpr_info("Bye!\\n");\n'
    '\tpr_emerg("TWKEXEC_ARM64: DAIF_MASK BEFORE\\n");\n',
    'Bye/DAIF-before')

once(
    '\tlocal_daif_mask();\n',
    '\tlocal_daif_mask();\n'
    '\tpr_emerg("TWKEXEC_ARM64: DAIF_MASK AFTER\\n");\n',
    'DAIF-after')

once(
    '\tif (kimage->head & IND_DONE) {\n',
    '\tif (kimage->head & IND_DONE) {\n'
    '\t\tpr_emerg("TWKEXEC_ARM64: BRANCH IND_DONE\\n");\n',
    'IND_DONE branch')

once(
    '\t\tcpu_install_idmap();\n',
    '\t\tpr_emerg("TWKEXEC_ARM64: INSTALL_IDMAP BEFORE\\n");\n'
    '\t\tcpu_install_idmap();\n'
    '\t\tpr_emerg("TWKEXEC_ARM64: INSTALL_IDMAP AFTER\\n");\n',
    'cpu_install_idmap')

once(
    '\t\trestart(is_hyp_nvhe(), kimage->start, kimage->arch.dtb_mem,\n',
    '\t\tpr_emerg("TWKEXEC_ARM64: SOFT_RESTART BEFORE hyp=%d start=%lx dtb=%pa\\n",\n'
    '\t\t\t is_hyp_nvhe(), kimage->start, &kimage->arch.dtb_mem);\n'
    '\t\trestart(is_hyp_nvhe(), kimage->start, kimage->arch.dtb_mem,\n',
    'cpu_soft_restart call')

# If cpu_soft_restart unexpectedly returns, record that fact without altering flow.
once(
    '\t\t\t0, 0);\n',
    '\t\t\t0, 0);\n'
    '\t\tpr_emerg("TWKEXEC_ARM64: SOFT_RESTART RETURNED\\n");\n',
    'cpu_soft_restart tail')

# kern_reloc is unique to the relocation branch, so its declaration is a robust
# marker for entering that branch regardless of surrounding vendor formatting.
once(
    '\t\tvoid (*kernel_reloc)(struct kimage *kimage);\n',
    '\t\tvoid (*kernel_reloc)(struct kimage *kimage);\n'
    '\t\tpr_emerg("TWKEXEC_ARM64: BRANCH RELOC\\n");\n',
    'RELOC branch')

# Preserve the vendor if statement exactly; only bracket the actual call.
once(
    '\t\t\t__hyp_set_vectors(kimage->arch.el2_vectors);\n',
    '\t\t\tpr_emerg("TWKEXEC_ARM64: HYP_VECTORS BEFORE\\n");\n'
    '\t\t\t__hyp_set_vectors(kimage->arch.el2_vectors);\n'
    '\t\t\tpr_emerg("TWKEXEC_ARM64: HYP_VECTORS AFTER\\n");\n',
    '__hyp_set_vectors')

once(
    '\t\tcpu_install_ttbr0(kimage->arch.ttbr0, kimage->arch.t0sz);\n',
    '\t\tpr_emerg("TWKEXEC_ARM64: INSTALL_TTBR0 BEFORE ttbr0=%pa t0sz=%lu\\n",\n'
    '\t\t\t &kimage->arch.ttbr0, (unsigned long)kimage->arch.t0sz);\n'
    '\t\tcpu_install_ttbr0(kimage->arch.ttbr0, kimage->arch.t0sz);\n'
    '\t\tpr_emerg("TWKEXEC_ARM64: INSTALL_TTBR0 AFTER\\n");\n',
    'cpu_install_ttbr0')

once(
    '\t\tkernel_reloc(kimage);\n',
    '\t\tpr_emerg("TWKEXEC_ARM64: KERNEL_RELOC BEFORE phys=%pa\\n", &kimage->arch.kern_reloc);\n'
    '\t\tkernel_reloc(kimage);\n'
    '\t\tpr_emerg("TWKEXEC_ARM64: KERNEL_RELOC RETURNED\\n");\n',
    'kernel_reloc call')

once(
    '\tBUG(); /* Should never get here. */\n',
    '\tpr_emerg("TWKEXEC_ARM64: BUG FALLTHROUGH\\n");\n'
    '\tBUG(); /* Should never get here. */\n',
    'BUG fallthrough')

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
  'TWKEXEC_ARM64: HYP_VECTORS BEFORE' \
  'TWKEXEC_ARM64: HYP_VECTORS AFTER' \
  'TWKEXEC_ARM64: INSTALL_TTBR0 BEFORE' \
  'TWKEXEC_ARM64: INSTALL_TTBR0 AFTER' \
  'TWKEXEC_ARM64: KERNEL_RELOC BEFORE' \
  'TWKEXEC_ARM64: KERNEL_RELOC RETURNED' \
  'TWKEXEC_ARM64: BUG FALLTHROUGH'; do
  grep -Fq "$M" "$MK"
done

echo 'TICWATCH_KEXEC_ARM64_PATH_DIAGNOSTICS=APPLIED'
echo 'TICWATCH_KEXEC_ARM64_PATH_BEHAVIOR_CHANGE=NONE'
