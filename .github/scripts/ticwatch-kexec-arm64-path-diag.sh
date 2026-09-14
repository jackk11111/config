#!/usr/bin/env bash
set -Eeuo pipefail

K="${1:?usage: $0 <kernel-tree>}"
MK="$K/arch/arm64/kernel/machine_kexec.c"

[ -f "$MK" ] || { echo "missing $MK" >&2; exit 2; }

python3 - "$MK" <<'PY'
from pathlib import Path
import re, sys

p = Path(sys.argv[1])
s = p.read_text()

if 'TWKEXEC_ARM64: ENTER' in s:
    print('ARM64 machine_kexec diagnostics already present')
    raise SystemExit(0)


def sub1(pattern, repl, label, flags=0):
    global s
    rx = re.compile(pattern, flags)
    m = list(rx.finditer(s))
    if len(m) != 1:
        raise SystemExit(f'{label} structural anchor mismatch: {len(m)}')
    s = rx.sub(repl, s, count=1)


def sub_optional(pattern, repl, label, flags=0):
    global s
    rx = re.compile(pattern, flags)
    m = list(rx.finditer(s))
    if len(m) > 1:
        raise SystemExit(f'{label} ambiguous structural anchor: {len(m)}')
    if not m:
        print(f'TICWATCH_ARM64_DIAG_OPTIONAL_{label}=NOT_PRESENT')
        return False
    s = rx.sub(repl, s, count=1)
    print(f'TICWATCH_ARM64_DIAG_OPTIONAL_{label}=APPLIED')
    return True

# Core path: these are mandatory and structurally unique inside machine_kexec().
sub1(
    r'(?m)^(\s*)bool\s+stuck_cpus\s*=\s*cpus_are_stuck_in_kernel\(\);\s*$',
    lambda m: m.group(0) + '\n\n' + m.group(1) +
        'pr_emerg("TWKEXEC_ARM64: ENTER head=%lx start=%lx dtb=%pa online=%u stuck=%d crash=%d\\n",\n' +
        m.group(1) + '\t kimage->head, kimage->start, &kimage->arch.dtb_mem,\n' +
        m.group(1) + '\t num_online_cpus(), stuck_cpus, in_kexec_crash);',
    'machine_kexec entry')

sub1(
    r'(?m)^(\s*)pr_info\("Bye!\\n"\);\s*$',
    lambda m: m.group(1) + 'pr_emerg("TWKEXEC_ARM64: CPU_CHECKS PASSED\\n");\n' +
              m.group(0) + '\n' +
              m.group(1) + 'pr_emerg("TWKEXEC_ARM64: DAIF_MASK BEFORE\\n");',
    'Bye marker')

sub1(
    r'(?m)^(\s*)local_daif_mask\(\);\s*$',
    lambda m: m.group(0) + '\n' + m.group(1) + 'pr_emerg("TWKEXEC_ARM64: DAIF_MASK AFTER\\n");',
    'DAIF mask')

# Do not depend on the exact spelling/spacing of the IND_DONE conditional.
# Entering this branch is proven by cpu_install_idmap(), which is its unique action.
sub_optional(
    r'(?m)^(\s*)cpu_install_idmap\(\);\s*$',
    lambda m: m.group(1) + 'pr_emerg("TWKEXEC_ARM64: BRANCH DIRECT/IND_DONE\\n");\n' +
              m.group(1) + 'pr_emerg("TWKEXEC_ARM64: INSTALL_IDMAP BEFORE\\n");\n' +
              m.group(0) + '\n' +
              m.group(1) + 'pr_emerg("TWKEXEC_ARM64: INSTALL_IDMAP AFTER\\n");',
    'INSTALL_IDMAP')

# Match the restart call independent of CFI wrapper used when assigning restart.
sub_optional(
    r'(?ms)^(\s*)restart\s*\(\s*is_hyp_nvhe\(\)\s*,\s*kimage->start\s*,\s*kimage->arch\.dtb_mem\s*,\s*0\s*,\s*0\s*\);\s*$',
    lambda m: m.group(1) +
        'pr_emerg("TWKEXEC_ARM64: SOFT_RESTART BEFORE hyp=%d start=%lx dtb=%pa\\n",\n' +
        m.group(1) + '\t is_hyp_nvhe(), kimage->start, &kimage->arch.dtb_mem);\n' +
        m.group(0) + '\n' +
        m.group(1) + 'pr_emerg("TWKEXEC_ARM64: SOFT_RESTART RETURNED\\n");',
    'SOFT_RESTART')

# Relocation branch markers are tied to unique operations rather than branch text.
sub_optional(
    r'(?m)^(\s*)void\s*\(\*kernel_reloc\)\s*\(struct\s+kimage\s*\*kimage\)\s*;\s*$',
    lambda m: m.group(0) + '\n' + m.group(1) + 'pr_emerg("TWKEXEC_ARM64: BRANCH RELOC\\n");',
    'RELOC_DECL')

sub_optional(
    r'(?m)^(\s*)__hyp_set_vectors\(kimage->arch\.el2_vectors\);\s*$',
    lambda m: m.group(1) + 'pr_emerg("TWKEXEC_ARM64: HYP_VECTORS BEFORE\\n");\n' +
              m.group(0) + '\n' +
              m.group(1) + 'pr_emerg("TWKEXEC_ARM64: HYP_VECTORS AFTER\\n");',
    'HYP_VECTORS')

sub_optional(
    r'(?m)^(\s*)cpu_install_ttbr0\(kimage->arch\.ttbr0\s*,\s*kimage->arch\.t0sz\);\s*$',
    lambda m: m.group(1) +
        'pr_emerg("TWKEXEC_ARM64: INSTALL_TTBR0 BEFORE ttbr0=%pa t0sz=%lu\\n",\n' +
        m.group(1) + '\t &kimage->arch.ttbr0, (unsigned long)kimage->arch.t0sz);\n' +
        m.group(0) + '\n' +
        m.group(1) + 'pr_emerg("TWKEXEC_ARM64: INSTALL_TTBR0 AFTER\\n");',
    'INSTALL_TTBR0')

sub_optional(
    r'(?m)^(\s*)kernel_reloc\(kimage\);\s*$',
    lambda m: m.group(1) +
        'pr_emerg("TWKEXEC_ARM64: KERNEL_RELOC BEFORE phys=%pa\\n", &kimage->arch.kern_reloc);\n' +
        m.group(0) + '\n' +
        m.group(1) + 'pr_emerg("TWKEXEC_ARM64: KERNEL_RELOC RETURNED\\n");',
    'KERNEL_RELOC')

sub1(
    r'(?m)^(\s*)BUG\(\);\s*/\*\s*Should never get here\.\s*\*/\s*$',
    lambda m: m.group(1) + 'pr_emerg("TWKEXEC_ARM64: BUG FALLTHROUGH\\n");\n' + m.group(0),
    'BUG fallthrough')

# Mandatory coverage: proves entry, CPU checks, DAIF transition and terminal fallthrough.
mandatory = [
    'TWKEXEC_ARM64: ENTER',
    'TWKEXEC_ARM64: CPU_CHECKS PASSED',
    'TWKEXEC_ARM64: DAIF_MASK BEFORE',
    'TWKEXEC_ARM64: DAIF_MASK AFTER',
    'TWKEXEC_ARM64: BUG FALLTHROUGH',
]
for marker in mandatory:
    if marker not in s:
        raise SystemExit(f'mandatory marker missing after patch: {marker}')

# Require at least one of the two actual transfer paths to have been instrumented.
if ('TWKEXEC_ARM64: SOFT_RESTART BEFORE' not in s and
    'TWKEXEC_ARM64: KERNEL_RELOC BEFORE' not in s):
    raise SystemExit('no ARM64 transfer path recognized; refusing to continue')

p.write_text(s)
PY

grep -Fq 'TWKEXEC_ARM64: ENTER' "$MK"
grep -Fq 'TWKEXEC_ARM64: CPU_CHECKS PASSED' "$MK"
grep -Fq 'TWKEXEC_ARM64: DAIF_MASK BEFORE' "$MK"
grep -Fq 'TWKEXEC_ARM64: DAIF_MASK AFTER' "$MK"
grep -Fq 'TWKEXEC_ARM64: BUG FALLTHROUGH' "$MK"
if ! grep -Fq 'TWKEXEC_ARM64: SOFT_RESTART BEFORE' "$MK" && \
   ! grep -Fq 'TWKEXEC_ARM64: KERNEL_RELOC BEFORE' "$MK"; then
  echo 'No recognized ARM64 transfer path after patch' >&2
  exit 3
fi

echo 'TICWATCH_KEXEC_ARM64_PATH_DIAGNOSTICS=APPLIED'
echo 'TICWATCH_KEXEC_ARM64_PATH_ANCHORS=STRUCTURAL_REGEX'
echo 'TICWATCH_KEXEC_ARM64_PATH_BEHAVIOR_CHANGE=NONE'
