#!/usr/bin/env bash
set -Eeuo pipefail

K="${1:?usage: $0 <kernel-tree>}"
[ -d "$K/.git" ] || { echo "missing kernel git tree: $K" >&2; exit 2; }

# Preserve the already runtime-validated backport exactly as it existed at the
# MMU-boundary diagnostic commit, then add Android/downstream compatibility
# fixes. Keeping the prior script byte-identical avoids changing unrelated
# kexec backport logic while the localized relocation failure is tested.
BASE_SCRIPT_COMMIT='517084ef0231d7865eec8fcd3101c764b1310e85'
BASE_SCRIPT_SHA256='ad237777947a810a06f0dffbae228683b9c02d27f43c38a41f76efa0136387a3'
TMP="${GITHUB_WORKSPACE:-$PWD}/ticwatch-kexec-arm64-mmu-reloc-backport.base.sh"
URL="https://raw.githubusercontent.com/jackk11111/config/${BASE_SCRIPT_COMMIT}/.github/scripts/ticwatch-kexec-arm64-mmu-reloc-backport.sh"

curl -fsSL --retry 3 --retry-delay 1 --connect-timeout 20 "$URL" -o "$TMP"
echo "$BASE_SCRIPT_SHA256  $TMP" | sha256sum -c -
chmod 0755 "$TMP"
bash "$TMP" "$K"

TPC="$K/arch/arm64/mm/trans_pgd.c"
PGT="$K/arch/arm64/include/asm/pgtable.h"
PGP="$K/arch/arm64/include/asm/pgtable-prot.h"
[ -s "$TPC" ] || { echo "missing trans_pgd.c: $TPC" >&2; exit 31; }
[ -s "$PGT" ] || { echo "missing pgtable.h: $PGT" >&2; exit 31; }
[ -s "$PGP" ] || { echo "missing pgtable-prot.h: $PGP" >&2; exit 31; }

# Android 5.15 compatibility fix for the temporary linear-map copy.
#
# The imported Linux v5.16 trans_pgd code assumes its contemporary
# pte_mkwrite() semantics, where PTE_RDONLY is always cleared. This Android
# 5.15 tree instead has downstream semantics where PTE_RDONLY is cleared only
# when PTE_DIRTY is set. A clean copied PTE can therefore remain read-only in
# the transitional page tables while arm64_relocate_new_kernel() needs to copy
# destination pages through them.
#
# Keep the reviewed remedy: dirty the copied PTE before pte_mkwrite(). This
# changes only the temporary trans_pgd and does not modify the live page table.
python3 - "$PGT" "$TPC" <<'PY'
from pathlib import Path
import re, sys
pg = Path(sys.argv[1]).read_text()
p = Path(sys.argv[2])
s = p.read_text()

m = re.search(r'static inline pte_t pte_mkwrite\(pte_t pte\)\s*\{(?P<body>.*?)\n\}', pg, re.S)
if not m:
    raise SystemExit('cannot locate pte_mkwrite() in Android pgtable.h')
body = m.group('body')
if 'PTE_WRITE' not in body or 'pte_sw_dirty(pte)' not in body or 'PTE_RDONLY' not in body:
    raise SystemExit('Android pte_mkwrite() semantics no longer match the diagnosed conditional-RDONLY case')

old1 = 'set_pte(dst_ptep, pte_mkwrite(pte));'
new1 = 'set_pte(dst_ptep, pte_mkwrite(pte_mkdirty(pte)));'
old2 = 'set_pte(dst_ptep, pte_mkpresent(pte_mkwrite(pte)));'
new2 = 'set_pte(dst_ptep, pte_mkpresent(pte_mkwrite(pte_mkdirty(pte))));'

if s.count(new1) == 1 and s.count(new2) == 1 and old1 not in s and old2 not in s:
    pass
elif s.count(old1) == 1 and s.count(old2) == 1:
    s = s.replace(old1, new1, 1).replace(old2, new2, 1)
    p.write_text(s)
else:
    raise SystemExit(
        'trans_pgd writable-copy anchors mismatch: '
        f'old1={s.count(old1)} old2={s.count(old2)} new1={s.count(new1)} new2={s.count(new2)}'
    )
PY

grep -Fq 'set_pte(dst_ptep, pte_mkwrite(pte_mkdirty(pte)));' "$TPC"
grep -Fq 'set_pte(dst_ptep, pte_mkpresent(pte_mkwrite(pte_mkdirty(pte))));' "$TPC"
! grep -Fq 'set_pte(dst_ptep, pte_mkwrite(pte));' "$TPC"
! grep -Fq 'set_pte(dst_ptep, pte_mkpresent(pte_mkwrite(pte)));' "$TPC"
echo 'TICWATCH_ARM64_KEXEC_TRANS_PGD_FORCE_WRITABLE_FIX=APPLIED'
echo 'TICWATCH_ARM64_KEXEC_TRANS_PGD_FORCE_WRITABLE_REASON=ANDROID_PTE_MKWRITE_CONDITIONAL_RDONLY_BREAKS_V5.16_TRANSITIONAL_COPY'

# Exact source-equivalent backport of upstream commit
# 01142791b0d11f20becccd0b30ed5e8fbb3822b6:
#   arm64: mm: avoid writable executable mappings in kexec/hibernate code
#
# Linux v5.16 mapped the copied relocation trampoline with PAGE_KERNEL_EXEC,
# which is writable+executable. Upstream changed this one mapping to
# PAGE_KERNEL_ROX. On the TicWatch failure path machine_kexec reaches TTBR0
# installation and the indirect branch target, then disappears before any
# later observable boundary. Keep the change isolated to that idmap PTE.
python3 - "$TPC" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text()
old = 'prev_level_entry = pte_val(pfn_pte(pfn, PAGE_KERNEL_EXEC));'
new = 'prev_level_entry = pte_val(pfn_pte(pfn, PAGE_KERNEL_ROX));'
if s.count(new) == 1 and old not in s:
    pass
elif s.count(old) == 1 and new not in s:
    s = s.replace(old, new, 1)
    p.write_text(s)
else:
    raise SystemExit(
        'trans_pgd relocation-idmap permission anchor mismatch: '
        f'EXEC={s.count(old)} ROX={s.count(new)}'
    )
PY

grep -Fq 'prev_level_entry = pte_val(pfn_pte(pfn, PAGE_KERNEL_ROX));' "$TPC"
! grep -Fq 'prev_level_entry = pte_val(pfn_pte(pfn, PAGE_KERNEL_EXEC));' "$TPC"
grep -Fq '#define PAGE_KERNEL_ROX' "$PGP" || {
  echo 'PAGE_KERNEL_ROX is not defined in arch/arm64/include/asm/pgtable-prot.h' >&2
  exit 32
}

git -C "$K" add arch/arm64/mm/trans_pgd.c
git -C "$K" diff --cached --check

echo 'TICWATCH_ARM64_KEXEC_RELOC_IDMAP_ROX_FIX=APPLIED'
echo 'TICWATCH_ARM64_KEXEC_RELOC_IDMAP_ROX_UPSTREAM=01142791b0d11f20becccd0b30ed5e8fbb3822b6'

REPORT="${GITHUB_WORKSPACE:-$PWD}/kexec-arm64-mmu-reloc-backport.txt"
{
  echo 'TRANS_PGD_FORCE_WRITABLE_FIX_STATUS=APPLIED_ANDROID_5.15_CONTEXT_EQUIVALENT'
  echo 'TRANS_PGD_FORCE_WRITABLE_METHOD=PTE_MKDIRTY_BEFORE_PTE_MKWRITE'
  echo 'TRANS_PGD_FORCE_WRITABLE_RUNTIME_EVIDENCE=20260915_NO_BOUNDARY_SHIFT_TTBR0_AFTER_KERNEL_RELOC_BEFORE_THEN_SILENT_RESET'
  echo 'TRANS_PGD_FORCE_WRITABLE_UPSTREAM_SYMPTOM=ARM64_KEXEC_HANG_AFTER_BYE_WITH_CLEAN_RDONLY_TRANSITIONAL_PTES'
  echo 'TRANS_PGD_FORCE_WRITABLE_TRIGGER_REFERENCE=143937ca51cc6ae2fccc61a1cb916abb24cd34f5_EQUIVALENT_SEMANTICS_ALREADY_PRESENT_DOWNSTREAM'
  echo 'RELOC_IDMAP_ROX_UPSTREAM_FIX=01142791b0d11f20becccd0b30ed5e8fbb3822b6'
  echo 'RELOC_IDMAP_ROX_FIX_STATUS=APPLIED_EXACT_SOURCE_EQUIVALENT'
  echo 'RELOC_IDMAP_ROX_CHANGE=PAGE_KERNEL_EXEC_TO_PAGE_KERNEL_ROX'
  echo 'RELOC_IDMAP_ROX_SCOPE=TRANS_PGD_IDMAP_PAGE_ONLY'
  echo 'RELOC_IDMAP_ROX_RUNTIME_RATIONALE=20260915_TTBR0_AFTER_KERNEL_RELOC_BEFORE_THEN_SILENT_RESET'
} >> "$REPORT"
cat "$REPORT"
