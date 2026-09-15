#!/usr/bin/env bash
set -Eeuo pipefail

K="${1:?usage: $0 <kernel-tree>}"
MK="$K/arch/arm64/kernel/machine_kexec.c"
RK="$K/arch/arm64/kernel/relocate_kernel.S"

[ -s "$MK" ] || { echo "missing $MK" >&2; exit 2; }
[ -s "$RK" ] || { echo "missing $RK" >&2; exit 2; }

# Runtime diagnostic only. The normal mode remains the existing relocation
# path; two non-destructive calls are made first:
#   mode 1: prove entry into the copied/idmapped relocation page and return.
#   mode 2: perform the exact TTBR1 break-before-make switch to the copied
#           linear map, then perform a second BBM back to the original TTBR1
#           before returning to C.
#
# Returning directly to C while the copied TTBR1 is active is invalid as a
# diagnostic: the transitional table is a copy of the linear map, while the C
# return PC lives in the kernel text mapping. A direct ret can therefore fault
# even when the forward TTBR1 switch completed correctly. The round-trip keeps
# execution on the TTBR0 idmap until the original TTBR1_EL1 value is restored.
#
# The probe path uses only caller-saved x0-x6 so returning to C obeys AArch64
# PCS. No stack or callee-saved register is touched by the assembly probe.
python3 - "$RK" "$MK" <<'PY'
from pathlib import Path
import sys

rk_p, mk_p = map(Path, sys.argv[1:])
rk = rk_p.read_text()
mk = mk_p.read_text()

entry = 'SYM_CODE_START(arm64_relocate_new_kernel)\n'
probe = '''SYM_CODE_START(arm64_relocate_new_kernel)\n\t/* TicWatch diagnostic modes: x1=1 entry-only, x1=2 TTBR1 round-trip. */\n\tcmp\tx1, #1\n\tb.eq\t.Lticwatch_probe_return\n\tcmp\tx1, #2\n\tb.eq\t.Lticwatch_probe_ttbr1\n\tb\t.Lticwatch_reloc_normal\n.Lticwatch_probe_ttbr1:\n\t/* Keep the exact pre-probe TTBR1 encoding (ASID/CnP included). */\n\tmrs\tx6, ttbr1_el1\n\tldr\tx2, [x0, #KIMAGE_ARCH_ZERO_PAGE]\n\tldr\tx3, [x0, #KIMAGE_ARCH_TTBR1]\n\t/* Forward BBM: original TTBR1 -> copied linear-map TTBR1. */\n\tbreak_before_make_ttbr_switch\tx2, x3, x4, x5\n\t/*\n\t * Do not ret while the copied linear-map TTBR1 is active: the return\n\t * address is kernel text, which is intentionally outside that copy.\n\t * Perform a BBM back to the exact original TTBR1 register value while\n\t * still executing entirely from the TTBR0 identity map.\n\t */\n\tphys_to_ttbr\tx4, x2\n\tmsr\tttbr1_el1, x4\n\tisb\n\ttlbi\tvmalle1\n\tdsb\tnsh\n\tmsr\tttbr1_el1, x6\n\tisb\n.Lticwatch_probe_return:\n\tret\n.Lticwatch_reloc_normal:\n'''
if 'Lticwatch_probe_ttbr1' not in rk:
    if rk.count(entry) != 1:
        raise SystemExit(f'relocation entry anchor mismatch: {rk.count(entry)}')
    rk = rk.replace(entry, probe, 1)

old_decl = '\t\tvoid (*kernel_reloc)(struct kimage *kimage);\n'
new_decl = '\t\tvoid (*kernel_reloc)(struct kimage *kimage, unsigned long probe_mode);\n'
if new_decl not in mk:
    if mk.count(old_decl) != 1:
        raise SystemExit(f'kernel_reloc declaration anchor mismatch: {mk.count(old_decl)}')
    mk = mk.replace(old_decl, new_decl, 1)

old_call = '''\t\tkernel_reloc = (void *)kimage->arch.kern_reloc;\n\t\tpr_emerg("TWKEXEC_MMU: KERNEL_RELOC BEFORE target=%px kimage=%px\\n",\n\t\t\t kernel_reloc, kimage);\n\t\tkmsg_dump(KMSG_DUMP_OOPS);\n\t\tkernel_reloc(kimage);\n\t\tpr_emerg("TWKEXEC_MMU: KERNEL_RELOC RETURNED\\n");\n\t\tkmsg_dump(KMSG_DUMP_OOPS);\n'''
new_call = '''\t\tkernel_reloc = (void *)kimage->arch.kern_reloc;\n\n\t\tpr_emerg("TWKEXEC_PROBE: ENTRY BEFORE target=%px kimage=%px\\n",\n\t\t\t kernel_reloc, kimage);\n\t\tkmsg_dump(KMSG_DUMP_OOPS);\n\t\tkernel_reloc(kimage, 1);\n\t\tpr_emerg("TWKEXEC_PROBE: ENTRY RETURNED\\n");\n\t\tkmsg_dump(KMSG_DUMP_OOPS);\n\n\t\tpr_emerg("TWKEXEC_PROBE: TTBR1_SWITCH BEFORE ttbr1=%pa zero=%pa\\n",\n\t\t\t &kimage->arch.ttbr1, &kimage->arch.zero_page);\n\t\tkmsg_dump(KMSG_DUMP_OOPS);\n\t\tkernel_reloc(kimage, 2);\n\t\tpr_emerg("TWKEXEC_PROBE: TTBR1_SWITCH RETURNED\\n");\n\t\tkmsg_dump(KMSG_DUMP_OOPS);\n\n\t\tpr_emerg("TWKEXEC_MMU: KERNEL_RELOC BEFORE target=%px kimage=%px\\n",\n\t\t\t kernel_reloc, kimage);\n\t\tkmsg_dump(KMSG_DUMP_OOPS);\n\t\tkernel_reloc(kimage, 0);\n\t\tpr_emerg("TWKEXEC_MMU: KERNEL_RELOC RETURNED\\n");\n\t\tkmsg_dump(KMSG_DUMP_OOPS);\n'''
if 'TWKEXEC_PROBE: ENTRY BEFORE' not in mk:
    if mk.count(old_call) != 1:
        raise SystemExit(f'kernel_reloc call anchor mismatch: {mk.count(old_call)}')
    mk = mk.replace(old_call, new_call, 1)

rk_p.write_text(rk)
mk_p.write_text(mk)
PY

for M in \
  'Lticwatch_probe_ttbr1' \
  'Lticwatch_probe_return' \
  'Lticwatch_reloc_normal' \
  $'break_before_make_ttbr_switch\tx2, x3, x4, x5' \
  $'mrs\tx6, ttbr1_el1' \
  $'msr\tttbr1_el1, x6'; do
  grep -Fq "$M" "$RK"
done
for M in \
  'TWKEXEC_PROBE: ENTRY BEFORE' \
  'TWKEXEC_PROBE: ENTRY RETURNED' \
  'TWKEXEC_PROBE: TTBR1_SWITCH BEFORE' \
  'TWKEXEC_PROBE: TTBR1_SWITCH RETURNED' \
  'kernel_reloc(kimage, 0);'; do
  grep -Fq "$M" "$MK"
done

git -C "$K" add arch/arm64/kernel/relocate_kernel.S arch/arm64/kernel/machine_kexec.c
git -C "$K" diff --cached --check

echo 'TICWATCH_ARM64_RELOC_INTERNAL_PROBE=APPLIED'
echo 'TICWATCH_ARM64_RELOC_PROBE1=ENTRY_RETURN_NO_STATE_CHANGE'
echo 'TICWATCH_ARM64_RELOC_PROBE2=TTBR1_BBM_ROUNDTRIP_TO_ORIGINAL_BEFORE_RETURN'
echo 'TICWATCH_ARM64_RELOC_NORMAL_MODE=0_UNCHANGED_AFTER_PROBES'
