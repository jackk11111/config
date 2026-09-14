#!/usr/bin/env bash
set -Eeuo pipefail

K="${1:?usage: $0 <kernel-tree>}"
MK="$K/arch/arm64/kernel/machine_kexec.c"
CR="$K/arch/arm64/kernel/cpu-reset.h"
RS="$K/arch/arm64/kernel/cpu-reset.S"
RK="$K/arch/arm64/kernel/relocate_kernel.S"
AK="$K/arch/arm64/include/asm/kexec.h"

for f in "$MK" "$CR" "$RS" "$RK" "$AK"; do
  [ -f "$f" ] || { echo "missing $f" >&2; exit 2; }
done

python3 - "$MK" "$CR" <<'PY'
from pathlib import Path
import sys

mk = Path(sys.argv[1])
cr = Path(sys.argv[2])
ms = mk.read_text()
cs = cr.read_text()

def once(src, old, new, label):
    n = src.count(old)
    if n != 1:
        raise SystemExit(f'{label} anchor mismatch: {n}')
    return src.replace(old, new, 1)

ms = once(ms,
'''\tbool stuck_cpus = cpus_are_stuck_in_kernel();\n''',
'''\tbool stuck_cpus = cpus_are_stuck_in_kernel();\n\n\tpr_emerg("TWKEXEC_ARM64: MACHINE_KEXEC ENTER crash=%d stuck=%d online=%u head=%lx start=%lx reloc=%lx dtb=%lx\\n",\n\t\t in_kexec_crash, stuck_cpus, num_online_cpus(), kimage->head,\n\t\t kimage->start, kimage->arch.kern_reloc, kimage->arch.dtb_mem);\n''',
'machine-enter')

ms = once(ms,
'''\t/* Flush the kimage list and its buffers. */\n\tkexec_list_flush(kimage);\n''',
'''\t/* Flush the kimage list and its buffers. */\n\tpr_emerg("TWKEXEC_ARM64: KEXEC_LIST_FLUSH BEFORE\\n");\n\tkexec_list_flush(kimage);\n\tpr_emerg("TWKEXEC_ARM64: KEXEC_LIST_FLUSH AFTER\\n");\n''',
'list-flush')

ms = once(ms,
'''\t/* Flush the new image if already in place. */\n\tif ((kimage != kexec_crash_image) && (kimage->head & IND_DONE))\n\t\tkexec_segment_flush(kimage);\n''',
'''\t/* Flush the new image if already in place. */\n\tpr_emerg("TWKEXEC_ARM64: SEGMENT_FLUSH CHECK ind_done=%d\\n", !!(kimage->head & IND_DONE));\n\tif ((kimage != kexec_crash_image) && (kimage->head & IND_DONE)) {\n\t\tpr_emerg("TWKEXEC_ARM64: SEGMENT_FLUSH BEFORE\\n");\n\t\tkexec_segment_flush(kimage);\n\t\tpr_emerg("TWKEXEC_ARM64: SEGMENT_FLUSH AFTER\\n");\n\t}\n''',
'segment-flush')

ms = once(ms,
'''\tpr_info("Bye!\\n");\n\n\tlocal_daif_mask();\n''',
'''\tpr_emerg("TWKEXEC_ARM64: BYE BEFORE\\n");\n\tpr_info("Bye!\\n");\n\tpr_emerg("TWKEXEC_ARM64: BYE AFTER\\n");\n\n\tpr_emerg("TWKEXEC_ARM64: DAIF BEFORE\\n");\n\tlocal_daif_mask();\n\tpr_emerg("TWKEXEC_ARM64: DAIF AFTER\\n");\n''',
'bye-daif')

ms = once(ms,
'''\tcpu_soft_restart(kimage->arch.kern_reloc, kimage->head, kimage->start,\n\t\t\t kimage->arch.dtb_mem);\n\n\tBUG(); /* Should never get here. */\n''',
'''\tpr_emerg("TWKEXEC_ARM64: CPU_SOFT_RESTART CALL BEFORE reloc=%lx head=%lx start=%lx dtb=%lx\\n",\n\t\t kimage->arch.kern_reloc, kimage->head, kimage->start, kimage->arch.dtb_mem);\n\tcpu_soft_restart(kimage->arch.kern_reloc, kimage->head, kimage->start,\n\t\t\t kimage->arch.dtb_mem);\n\tpr_emerg("TWKEXEC_ARM64: CPU_SOFT_RESTART RETURNED\\n");\n\n\tBUG(); /* Should never get here. */\n''',
'soft-restart-call')

cs = once(cs,
'''\ttypeof(__cpu_soft_restart) *restart;\n''',
'''\ttypeof(__cpu_soft_restart) *restart;\n\n\tpr_emerg("TWKEXEC_ARM64: CPU_RESET ENTER entry=%lx arg0=%lx arg1=%lx arg2=%lx\\n",\n\t\t entry, arg0, arg1, arg2);\n''',
'cpu-reset-enter')

needle = None
for cand in (
    '\trestart = (void *)__pa_symbol(function_nocfi(__cpu_soft_restart));\n',
    '\trestart = (void *)__pa_function(__cpu_soft_restart);\n',
    '\trestart = (void *)__pa_symbol(__cpu_soft_restart);\n',
):
    if cs.count(cand) == 1:
        needle = cand
        break
if needle is None:
    raise SystemExit('restart assignment anchor mismatch')
cs = cs.replace(needle, needle + '\tpr_emerg("TWKEXEC_ARM64: CPU_RESET RESTART_PTR=%px\\n", restart);\n', 1)

cs = once(cs,
'''\tcpu_install_idmap();\n''',
'''\tpr_emerg("TWKEXEC_ARM64: IDMAP BEFORE\\n");\n\tcpu_install_idmap();\n\tpr_emerg("TWKEXEC_ARM64: IDMAP AFTER\\n");\n''',
'idmap')

if cs.count('\trestart(el2_switch, entry, arg0, arg1, arg2);\n') == 1:
    cs = cs.replace(
        '\trestart(el2_switch, entry, arg0, arg1, arg2);\n',
        '\tpr_emerg("TWKEXEC_ARM64: PHYS_RESTART BEFORE el2=%lx entry=%lx\\n", el2_switch, entry);\n\trestart(el2_switch, entry, arg0, arg1, arg2);\n\tpr_emerg("TWKEXEC_ARM64: PHYS_RESTART RETURNED\\n");\n', 1)
elif cs.count('\trestart(0, entry, arg0, arg1, arg2);\n') == 1:
    cs = cs.replace(
        '\trestart(0, entry, arg0, arg1, arg2);\n',
        '\tpr_emerg("TWKEXEC_ARM64: PHYS_RESTART BEFORE el2=0 entry=%lx\\n", entry);\n\trestart(0, entry, arg0, arg1, arg2);\n\tpr_emerg("TWKEXEC_ARM64: PHYS_RESTART RETURNED\\n");\n', 1)
else:
    raise SystemExit('restart call anchor mismatch')

mk.write_text(ms)
cr.write_text(cs)

print('TICWATCH_KEXEC_ARM64_PATH_DIAGNOSTICS=APPLIED')
print('TICWATCH_KEXEC_ARM64_MACHINE_KEXEC=INSTRUMENTED')
print('TICWATCH_KEXEC_ARM64_CPU_RESET=INSTRUMENTED')
print('TICWATCH_KEXEC_ARM64_BEHAVIOR_CHANGE=NONE')
PY

echo '=== TWKEXEC EXACT CPU-RESET.S BEGIN ==='
cat "$RS"
echo '=== TWKEXEC EXACT CPU-RESET.S END ==='
echo '=== TWKEXEC EXACT RELOCATE_KERNEL.S BEGIN ==='
cat "$RK"
echo '=== TWKEXEC EXACT RELOCATE_KERNEL.S END ==='
echo '=== TWKEXEC EXACT ASM-KEXEC.H BEGIN ==='
cat "$AK"
echo '=== TWKEXEC EXACT ASM-KEXEC.H END ==='
echo '=== TWKEXEC EXACT MACHINE_KEXEC RELEVANT BEGIN ==='
sed -n '/int machine_kexec_prepare/,/void machine_crash_shutdown/p' "$MK"
echo '=== TWKEXEC EXACT MACHINE_KEXEC RELEVANT END ==='
