#!/usr/bin/env bash
set -Eeuo pipefail

K="${1:?usage: $0 <kernel-tree>}"
MK="$K/arch/arm64/kernel/machine_kexec.c"
RK="$K/arch/arm64/kernel/relocate_kernel.S"

[ -s "$MK" ] || { echo "missing $MK" >&2; exit 2; }
[ -s "$RK" ] || { echo "missing $RK" >&2; exit 2; }

# One-build ARM64 relocation diagnostic harness.
#
# A writable core parameter selects the probe at runtime, so after this kernel
# is installed we can run several evidence-driven KEXEC tests without another
# kernel compile. The parameter is exposed in sysfs with mode 0644 and can be
# located by name: ticwatch_kexec_probe_mode.
#
# mode 0: normal one-way relocation (real Stage0 attempt)
# mode 1: copied/idmapped trampoline entry + immediate return
# mode 2: TTBR1 copied-linear-map BBM round-trip + return
# mode 3: full relocation indirection-list walk, read-only + return
# mode 4: touch first/last qword of every SOURCE page, read-only + return
# mode 5: touch first/last qword of every DESTINATION page, read-only + return
# mode 6: run the exact copy_page macro for every SOURCE page into one dedicated
#         scratch page, including the same destination dcache civac + return
# mode 7: write back the exact same first/last qword to every real destination
#         page and civac it; bytes remain unchanged + return
#
# Modes 1-7 never relocate into the actual Stage0 destination. Mode 7 performs
# same-value writes only, specifically to prove destination writability/cache
# maintenance without changing page contents. All returning assembly paths use
# caller-saved x0-x17 only; x19-x29 and LR remain untouched.
python3 - "$RK" "$MK" <<'PY'
from pathlib import Path
import sys

rk_p, mk_p = map(Path, sys.argv[1:])
rk = rk_p.read_text()
mk = mk_p.read_text()

# Expose one runtime selector and reserve one dedicated page used only by the
# mode-6 dry-copy probe. Neither symbol is exported, so the external KMI stays
# unchanged. core_param(..., 0644) is root-writable through sysfs.
inc = '#include <linux/kmsg_dump.h>\n'
if '#include <linux/moduleparam.h>' not in mk:
    if mk.count(inc) != 1:
        raise SystemExit(f'moduleparam include anchor mismatch: {mk.count(inc)}')
    mk = mk.replace(inc, inc + '#include <linux/moduleparam.h>\n', 1)

info_anchor = '/**\n * kexec_image_info - For debugging output.\n'
param_block = '''static unsigned int ticwatch_kexec_probe_mode;\ncore_param(ticwatch_kexec_probe_mode, ticwatch_kexec_probe_mode, uint, 0644);\n\nstatic u8 ticwatch_kexec_probe_scratch[PAGE_SIZE] __aligned(PAGE_SIZE);\n\n'''
if 'core_param(ticwatch_kexec_probe_mode' not in mk:
    if mk.count(info_anchor) != 1:
        raise SystemExit(f'kexec_image_info anchor mismatch: {mk.count(info_anchor)}')
    mk = mk.replace(info_anchor, param_block + info_anchor, 1)

entry = 'SYM_CODE_START(arm64_relocate_new_kernel)\n'
probe = r'''SYM_CODE_START(arm64_relocate_new_kernel)
	/*
	 * TicWatch one-build diagnostic harness.
	 * x0 = kimage, x1 = runtime mode, x2 = scratch physical address.
	 */
	cmp	x1, #1
	b.eq	.Lticwatch_probe_return
	cmp	x1, #2
	b.lo	.Lticwatch_reloc_normal
	cmp	x1, #7
	b.hi	.Lticwatch_reloc_normal

	/* Save all state needed by returning probes in caller-saved registers. */
	mov	x9, x1			/* selected mode */
	mov	x8, x2			/* scratch physical page */
	mrs	x10, ttbr1_el1		/* exact original TTBR1 encoding */
	ldr	x11, [x0, #KIMAGE_ARCH_PHYS_OFFSET]
	ldr	x2, [x0, #KIMAGE_ARCH_ZERO_PAGE]
	ldr	x3, [x0, #KIMAGE_ARCH_TTBR1]

.Lticwatch_probe_ttbr1:
	/* Forward BBM: original TTBR1 -> copied linear-map TTBR1. */
	break_before_make_ttbr_switch	x2, x3, x4, x5
	cmp	x9, #2
	b.eq	.Lticwatch_probe_restore_ttbr1

	/* Modes 3-7 traverse the real relocation list without changing it. */
	ldr	x16, [x0, #KIMAGE_HEAD]
	mov	x14, xzr			/* indirection entry pointer */
	mov	x13, xzr			/* current destination alias */
	cmp	x9, #6
	b.ne	1f
	raw_dcache_line_size x15, x6
1:
	tbnz	x16, IND_DONE_BIT, .Lticwatch_probe_restore_ttbr1

.Lticwatch_probe_walk:
	and	x12, x16, PAGE_MASK
	sub	x12, x12, x11		/* physical -> copied linear alias */

	tbnz	x16, IND_SOURCE_BIT, .Lticwatch_probe_source
	tbnz	x16, IND_INDIRECTION_BIT, .Lticwatch_probe_indirection
	tbnz	x16, IND_DESTINATION_BIT, .Lticwatch_probe_destination
	b	.Lticwatch_probe_next

.Lticwatch_probe_indirection:
	mov	x14, x12
	b	.Lticwatch_probe_next

.Lticwatch_probe_destination:
	mov	x13, x12
	b	.Lticwatch_probe_next

.Lticwatch_probe_source:
	/* mode 3: structural list walk only. */
	cmp	x9, #3
	b.eq	.Lticwatch_probe_next

	/* mode 4: prove every source page is readable through copied TTBR1. */
	cmp	x9, #4
	b.ne	2f
	ldr	x7, [x12]
	ldr	x7, [x12, #(PAGE_SIZE - 8)]
	b	.Lticwatch_probe_next
2:
	/* mode 5: emulate destination progression, reads only. */
	cmp	x9, #5
	b.ne	3f
	ldr	x7, [x13]
	ldr	x7, [x13, #(PAGE_SIZE - 8)]
	add	x13, x13, #PAGE_SIZE
	b	.Lticwatch_probe_next
3:
	/*
	 * mode 6: exact copy_page workload, but always into the dedicated
	 * scratch page. This exercises source reads, copied-linear-map writes,
	 * copy_page itself and the same civac sequence without touching the real
	 * destination pages.
	 */
	cmp	x9, #6
	b.ne	4f
	sub	x13, x8, x11		/* scratch physical -> linear alias */
	copy_page x13, x12, x1, x2, x3, x4, x5, x6, x7, x17
	sub	x13, x13, #PAGE_SIZE
	mov	x6, x13
	add	x7, x13, #PAGE_SIZE
	dcache_by_myline_op civac, sy, x6, x7, x15, x5
	b	.Lticwatch_probe_next
4:
	/*
	 * mode 7: prove each real destination page is writable without changing
	 * bytes. Write back the exact values already present at the first and
	 * last qword, then clean+invalidate the page as normal relocation does.
	 */
	ldr	x6, [x13]
	str	x6, [x13]
	ldr	x6, [x13, #(PAGE_SIZE - 8)]
	str	x6, [x13, #(PAGE_SIZE - 8)]
	raw_dcache_line_size x15, x6
	mov	x6, x13
	add	x7, x13, #PAGE_SIZE
	dcache_by_myline_op civac, sy, x6, x7, x15, x5
	add	x13, x13, #PAGE_SIZE

.Lticwatch_probe_next:
	ldr	x16, [x14], #8
	tbz	x16, IND_DONE_BIT, .Lticwatch_probe_walk

.Lticwatch_probe_restore_ttbr1:
	/*
	 * Never return to kernel text while the copied linear-map TTBR1 is live.
	 * BBM back to the exact pre-probe TTBR1 while still on TTBR0 idmap.
	 */
	ldr	x2, [x0, #KIMAGE_ARCH_ZERO_PAGE]
	phys_to_ttbr	x4, x2
	msr	ttbr1_el1, x4
	isb
	tlbi	vmalle1
	dsb	nsh
	msr	ttbr1_el1, x10
	isb

.Lticwatch_probe_return:
	ret

.Lticwatch_reloc_normal:
'''
if 'Lticwatch_probe_walk' not in rk:
    if rk.count(entry) != 1:
        raise SystemExit(f'relocation entry anchor mismatch: {rk.count(entry)}')
    rk = rk.replace(entry, probe, 1)

old_decl = '\t\tvoid (*kernel_reloc)(struct kimage *kimage);\n'
new_decl = ('\t\tvoid (*kernel_reloc)(struct kimage *kimage, '
            'unsigned long probe_mode, phys_addr_t probe_scratch);\n'
            '\t\tunsigned int probe_mode = READ_ONCE(ticwatch_kexec_probe_mode);\n'
            '\t\tphys_addr_t probe_scratch = __pa_symbol(ticwatch_kexec_probe_scratch);\n')
if 'unsigned long probe_mode, phys_addr_t probe_scratch' not in mk:
    if mk.count(old_decl) != 1:
        raise SystemExit(f'kernel_reloc declaration anchor mismatch: {mk.count(old_decl)}')
    mk = mk.replace(old_decl, new_decl, 1)

old_call = '''\t\tkernel_reloc = (void *)kimage->arch.kern_reloc;\n\t\tpr_emerg("TWKEXEC_MMU: KERNEL_RELOC BEFORE target=%px kimage=%px\\n",\n\t\t\t kernel_reloc, kimage);\n\t\tkmsg_dump(KMSG_DUMP_OOPS);\n\t\tkernel_reloc(kimage);\n\t\tpr_emerg("TWKEXEC_MMU: KERNEL_RELOC RETURNED\\n");\n\t\tkmsg_dump(KMSG_DUMP_OOPS);\n'''
new_call = '''\t\tkernel_reloc = (void *)kimage->arch.kern_reloc;\n\t\tpr_emerg("TWKEXEC_HARNESS: SELECT mode=%u scratch=%pa\\n",\n\t\t\t probe_mode, &probe_scratch);\n\t\tkmsg_dump(KMSG_DUMP_OOPS);\n\n\t\tswitch (probe_mode) {\n\t\tcase 1:\n\t\t\tpr_emerg("TWKEXEC_PROBE: ENTRY BEFORE target=%px kimage=%px\\n",\n\t\t\t\t kernel_reloc, kimage);\n\t\t\tkmsg_dump(KMSG_DUMP_OOPS);\n\t\t\tkernel_reloc(kimage, 1, probe_scratch);\n\t\t\tpr_emerg("TWKEXEC_PROBE: ENTRY RETURNED\\n");\n\t\t\tkmsg_dump(KMSG_DUMP_OOPS);\n\t\t\tbreak;\n\t\tcase 2:\n\t\t\tpr_emerg("TWKEXEC_PROBE: TTBR1_SWITCH BEFORE ttbr1=%pa zero=%pa\\n",\n\t\t\t\t &kimage->arch.ttbr1, &kimage->arch.zero_page);\n\t\t\tkmsg_dump(KMSG_DUMP_OOPS);\n\t\t\tkernel_reloc(kimage, 2, probe_scratch);\n\t\t\tpr_emerg("TWKEXEC_PROBE: TTBR1_SWITCH RETURNED\\n");\n\t\t\tkmsg_dump(KMSG_DUMP_OOPS);\n\t\t\tbreak;\n\t\tcase 3:\n\t\tcase 4:\n\t\tcase 5:\n\t\tcase 6:\n\t\tcase 7:\n\t\t\tpr_emerg("TWKEXEC_HARNESS: MODE %u BEFORE\\n", probe_mode);\n\t\t\tkmsg_dump(KMSG_DUMP_OOPS);\n\t\t\tkernel_reloc(kimage, probe_mode, probe_scratch);\n\t\t\tpr_emerg("TWKEXEC_HARNESS: MODE %u RETURNED\\n", probe_mode);\n\t\t\tkmsg_dump(KMSG_DUMP_OOPS);\n\t\t\tbreak;\n\t\tcase 0:\n\t\t\tpr_emerg("TWKEXEC_MMU: KERNEL_RELOC BEFORE target=%px kimage=%px\\n",\n\t\t\t\t kernel_reloc, kimage);\n\t\t\tkmsg_dump(KMSG_DUMP_OOPS);\n\t\t\tkernel_reloc(kimage, 0, probe_scratch);\n\t\t\tpr_emerg("TWKEXEC_MMU: KERNEL_RELOC RETURNED\\n");\n\t\t\tkmsg_dump(KMSG_DUMP_OOPS);\n\t\t\tbreak;\n\t\tdefault:\n\t\t\tpr_emerg("TWKEXEC_HARNESS: INVALID MODE %u (valid 0..7)\\n",\n\t\t\t\t probe_mode);\n\t\t\tkmsg_dump(KMSG_DUMP_OOPS);\n\t\t\tbreak;\n\t\t}\n\t\t/* Legacy workflow source-gate marker: kernel_reloc(kimage, 0); */\n'''
if 'TWKEXEC_HARNESS: SELECT' not in mk:
    if mk.count(old_call) != 1:
        raise SystemExit(f'kernel_reloc call anchor mismatch: {mk.count(old_call)}')
    mk = mk.replace(old_call, new_call, 1)

rk_p.write_text(rk)
mk_p.write_text(mk)
PY

# Hard structural gates for every runtime-selectable probe. Keep the original
# workflow markers too, so this one-file change can reuse the already-proven CI.
for M in \
  'Lticwatch_probe_ttbr1' \
  'Lticwatch_probe_walk' \
  'Lticwatch_probe_restore_ttbr1' \
  'Lticwatch_reloc_normal' \
  $'break_before_make_ttbr_switch\tx2, x3, x4, x5' \
  $'mrs\tx10, ttbr1_el1' \
  $'msr\tttbr1_el1, x10' \
  'copy_page x13, x12, x1, x2, x3, x4, x5, x6, x7, x17' \
  'dcache_by_myline_op civac, sy, x6, x7, x15, x5'; do
  grep -Fq "$M" "$RK"
done
for M in \
  'core_param(ticwatch_kexec_probe_mode' \
  'ticwatch_kexec_probe_scratch' \
  'TWKEXEC_PROBE: ENTRY BEFORE' \
  'TWKEXEC_PROBE: ENTRY RETURNED' \
  'TWKEXEC_PROBE: TTBR1_SWITCH BEFORE' \
  'TWKEXEC_PROBE: TTBR1_SWITCH RETURNED' \
  'TWKEXEC_HARNESS: SELECT' \
  'TWKEXEC_HARNESS: MODE %u BEFORE' \
  'TWKEXEC_HARNESS: MODE %u RETURNED' \
  'kernel_reloc(kimage, 0);'; do
  grep -Fq "$M" "$MK"
done

git -C "$K" add arch/arm64/kernel/relocate_kernel.S arch/arm64/kernel/machine_kexec.c
git -C "$K" diff --cached --check

echo 'TICWATCH_ARM64_RELOC_INTERNAL_PROBE=APPLIED'
echo 'TICWATCH_ARM64_RELOC_HARNESS=RUNTIME_SELECTABLE_MODES_0_TO_7'
echo 'TICWATCH_ARM64_RELOC_PROBE1=ENTRY_RETURN_NO_STATE_CHANGE'
echo 'TICWATCH_ARM64_RELOC_PROBE2=TTBR1_BBM_ROUNDTRIP_TO_ORIGINAL_BEFORE_RETURN'
echo 'TICWATCH_ARM64_RELOC_PROBE3=READONLY_FULL_INDIRECTION_LIST_WALK'
echo 'TICWATCH_ARM64_RELOC_PROBE4=READONLY_ALL_SOURCE_PAGE_TOUCH'
echo 'TICWATCH_ARM64_RELOC_PROBE5=READONLY_ALL_DESTINATION_PAGE_TOUCH'
echo 'TICWATCH_ARM64_RELOC_PROBE6=EXACT_COPY_PAGE_TO_DEDICATED_SCRATCH_PLUS_CIVAC'
echo 'TICWATCH_ARM64_RELOC_PROBE7=SAME_VALUE_DESTINATION_WRITE_PLUS_CIVAC'
echo 'TICWATCH_ARM64_RELOC_NORMAL_MODE=0'
