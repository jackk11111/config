#!/usr/bin/env bash
set -Eeuo pipefail

K="${1:?usage: $0 <kernel-tree>}"
[ -d "$K/.git" ] || { echo "missing kernel git tree: $K" >&2; exit 2; }

# Linux v5.16 ARM64 MMU-enabled kexec relocation series.
SERIES=(
  094a3684b9b67758ccedf0e6068d90f22f2942d9
  788bfdd97434982b6d575062581e8e72eea755af
  a347f601452ff3e7cc15bc31307915cea3b3f3f5
  0d8732e461d6b4dc2c625a69225f20e24da4dd79
  5bb6834fc2900052a377df79b9ab065a698bf70b
  3036ec599332cdfb406249270e50ad3f1a5c5940
  878fdbd704864352b9b11e29805e92ffa182904e
  08eae0ef618f34a813c1478200eb351d4416f3ca
  ba959fe96a1bbb98765762da20ecb3a6eb9c9d39
  19a046f07ce5a5c34ebb6432192d98cfdb38444f
  3744b5280e67f54579abe92576deec0079242323
  efc2d0f20a9dab2d0e92a271dc4b8e3496377739
  939f1b9564c6aa2bd0f4e4e336ac74379692c38b
  7a2512fa649397c68127a480ef8fdd9dcf323045
  6091dd9eaf8e77311548b616281c1a9c67e6ca40
)
FIRST_PARENT=5816b3e6577eaa676ceb00a848f0fd65fe2adc29

# Critical post-series bugfixes for the exact relocation design above.
# ZERO_PAGE_FIX fixes 3744b5280e67 (commit 11 in SERIES).
# KIMAGE_CLOBBER_FIX fixes 878fdbd70486 (commit 7 in SERIES).
ZERO_PAGE_FIX=2f2183243f52a8ee77eecba4796316606701d101
KIMAGE_CLOBBER_FIX=eb3d8ea3e1f03f4b0b72d8f5ed9eb7c3165862e8

ORIGINAL_HEAD="$(git -C "$K" rev-parse HEAD)"
BASELINE_TRACKED_DIRTY=NO
if ! git -C "$K" diff --quiet || ! git -C "$K" diff --cached --quiet; then
  BASELINE_TRACKED_DIRTY=YES
  git -C "$K" config user.name 'TicWatch CI Baseline Snapshot'
  git -C "$K" config user.email 'ticwatch-ci-baseline@invalid.local'
  git -C "$K" add -u
  git -C "$K" commit -m 'ci: snapshot verified TicWatch precompile source state'
fi
BASE_HEAD="$(git -C "$K" rev-parse HEAD)"
echo "TICWATCH_ARM64_MMU_RELOC_ORIGINAL_HEAD=$ORIGINAL_HEAD"
echo "TICWATCH_ARM64_MMU_RELOC_BASE_HEAD=$BASE_HEAD"
echo "TICWATCH_ARM64_MMU_RELOC_BASELINE_TRACKED_DIRTY=$BASELINE_TRACKED_DIRTY"
git -C "$K" diff --quiet || { echo 'tracked unstaged changes remain after baseline snapshot' >&2; exit 3; }
git -C "$K" diff --cached --quiet || { echo 'tracked staged changes remain after baseline snapshot' >&2; exit 3; }

WORK="${GITHUB_WORKSPACE:-$PWD}/arm64-kexec-upstream-patches"
rm -rf "$WORK"
mkdir -p "$WORK/base-blobs"

for sha in "${SERIES[@]}" "$ZERO_PAGE_FIX" "$KIMAGE_CLOBBER_FIX"; do
  patch="$WORK/$sha.patch"
  echo "Downloading exact upstream patch $sha"
  curl -fsSL --retry 3 --retry-delay 1 --connect-timeout 20 \
    "https://github.com/torvalds/linux/commit/${sha}.patch" -o "$patch"
  test -s "$patch"
  grep -Fq "From $sha " "$patch" || { echo "upstream patch identity mismatch: $sha" >&2; exit 19; }
done

capture_conflict() {
  local sha="$1" patch="$2" root="${GITHUB_WORKSPACE:-$PWD}/backport-failure"
  rm -rf "$root"; mkdir -p "$root"
  cp "$patch" "$root/failed-upstream.patch"
  {
    echo "ARM64_KEXEC_BACKPORT_CONFLICT_SHA=$sha"
    echo "ORIGINAL_HEAD=$ORIGINAL_HEAD"
    echo "BASE_HEAD=$BASE_HEAD"
    echo 'STATUS:'
    git -C "$K" status --short || true
    echo 'CHECK:'
    git -C "$K" apply --check --verbose --whitespace=nowarn "$patch" || true
  } > "$root/summary.txt" 2>&1
  cat "$root/summary.txt" >&2
}

prime_preimage_blobs() {
  local parent="$1" patch="$2" current='' line old path tmp full
  while IFS= read -r line; do
    case "$line" in
      'diff --git a/'*)
        current="${line#diff --git a/}"; current="${current%% b/*}" ;;
      'index '*)
        [ -n "$current" ] || continue
        old="${line#index }"; old="${old%%..*}"
        [[ "$old" =~ ^0+$ ]] && continue
        path="$current"; tmp="$WORK/base-blobs/${parent}-${old}"
        if [ ! -s "$tmp" ]; then
          curl -fsSL --retry 3 --retry-delay 1 --connect-timeout 20 \
            "https://raw.githubusercontent.com/torvalds/linux/${parent}/${path}" -o "$tmp"
        fi
        full="$(git -C "$K" hash-object -w "$tmp")"
        case "$full" in "$old"*) ;; *) echo "preimage blob mismatch: $path" >&2; exit 18;; esac
        ;;
    esac
  done < "$patch"
}

THREEWAY_COMMITS=()
parent="$FIRST_PARENT"
for sha in "${SERIES[@]}"; do
  patch="$WORK/$sha.patch"
  echo "Applying upstream ARM64 kexec commit $sha"
  if git -C "$K" apply --check --whitespace=nowarn "$patch"; then
    git -C "$K" apply --index --whitespace=nowarn "$patch"
  else
    echo "Direct context mismatch for $sha; using exact-parent three-way adaptation"
    prime_preimage_blobs "$parent" "$patch"
    PRE_TREE="$(git -C "$K" write-tree)"
    if git -C "$K" apply --3way --index --whitespace=nowarn "$patch"; then
      THREEWAY_COMMITS+=("$sha")
      echo "ARM64_KEXEC_THREEWAY_ADAPTED=$sha"
    else
      git -C "$K" read-tree --reset -u "$PRE_TREE"
      capture_conflict "$sha" "$patch"
      exit 20
    fi
  fi
  parent="$sha"
done

MK="$K/arch/arm64/kernel/machine_kexec.c"
RK="$K/arch/arm64/kernel/relocate_kernel.S"
MMU="$K/arch/arm64/include/asm/mmu_context.h"
TPH="$K/arch/arm64/include/asm/trans_pgd.h"
TPC="$K/arch/arm64/mm/trans_pgd.c"
KCFG="$K/arch/arm64/Kconfig"
for f in "$MK" "$RK" "$MMU" "$TPH" "$TPC" "$KCFG"; do
  [ -s "$f" ] || { echo "missing expected backport file: $f" >&2; exit 21; }
done

# Upstream v5.16-rc fix: empty_zero_page is a kernel-image symbol, not a
# linear-map address. __pa() is therefore incorrect; __pa_symbol() must be
# used for the physical zero-page consumed by the relocation TTBR1 switch.
# This directly fixes 3744b5280e67 from SERIES and matters with
# CONFIG_RELOCATABLE=y / CONFIG_RANDOMIZE_BASE=y on this TicWatch build.
patch="$WORK/$ZERO_PAGE_FIX.patch"
echo "Applying upstream zero-page physical-address fix $ZERO_PAGE_FIX"
if git -C "$K" apply --check --whitespace=nowarn "$patch"; then
  git -C "$K" apply --index --whitespace=nowarn "$patch"
else
  capture_conflict "$ZERO_PAGE_FIX" "$patch"
  exit 24
fi
grep -Fq 'kimage->arch.zero_page = __pa_symbol(empty_zero_page);' "$MK"
! grep -Fq 'kimage->arch.zero_page = __pa(empty_zero_page);' "$MK"
echo 'TICWATCH_ARM64_KEXEC_ZERO_PAGE_PA_SYMBOL_FIX=APPLIED'

# Upstream post-v5.16 fix: load every kimage value before the relocation loop
# can overwrite the kimage allocation itself. This is a direct upstream patch
# specifically tested atop v5.16.
patch="$WORK/$KIMAGE_CLOBBER_FIX.patch"
echo "Applying upstream post-v5.16 kimage-clobber fix $KIMAGE_CLOBBER_FIX"
if git -C "$K" apply --check --whitespace=nowarn "$patch"; then
  git -C "$K" apply --index --whitespace=nowarn "$patch"
else
  capture_conflict "$KIMAGE_CLOBBER_FIX" "$patch"
  exit 23
fi

grep -Fq $'ldr\tx28, [x0, #KIMAGE_START]' "$RK"
grep -Fq $'ldr\tx27, [x0, #KIMAGE_ARCH_EL2_VECTORS]' "$RK"
grep -Fq $'ldr\tx26, [x0, #KIMAGE_ARCH_DTB_MEM]' "$RK"
grep -Fq $'br\tx28' "$RK"
! grep -Fq $'ldr\tx4, [x0, #KIMAGE_START]' "$RK"
echo 'TICWATCH_ARM64_KEXEC_KIMAGE_CLOBBER_FIX=APPLIED'

# Upstream 2024 trans_pgd fix, adapted to the v5.16-era source context.
# The final upstream rule is: every non-none invalid direct-map PTE must be
# made valid/writable in the transitional copy. The v5.16 code only does this
# when debug_pagealloc is enabled, missing KFENCE-invalidated mappings.
# TicWatch final.config has CONFIG_KFENCE=y with active sampling.
python3 - "$TPC" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text()
old='} else if (debug_pagealloc_enabled() && !pte_none(pte)) {'
new='} else if (!pte_none(pte)) {'
if s.count(new) == 1 and old not in s:
    pass
elif s.count(old) == 1:
    s=s.replace(old,new,1)
    p.write_text(s)
else:
    raise SystemExit('trans_pgd invalid-PTE compatibility anchor mismatch')
PY
git -C "$K" add arch/arm64/mm/trans_pgd.c
grep -Fq '} else if (!pte_none(pte)) {' "$TPC"
! grep -Fq 'debug_pagealloc_enabled() && !pte_none(pte)' "$TPC"
echo 'TICWATCH_ARM64_KEXEC_TRANS_PGD_INVALID_PTE_FIX=APPLIED'

# Structural gates for the completed v5.16 relocation design.
grep -Fq 'machine_kexec_post_load' "$MK"
grep -Fq 'trans_pgd_create_copy' "$MK"
grep -Fq 'trans_pgd_copy_el2_vectors' "$MK"
grep -Fq 'cpu_install_ttbr0' "$MMU"
grep -Fq 'trans_pgd_copy_el2_vectors' "$TPH"
grep -Fq 'trans_pgd_copy_el2_vectors' "$TPC"
grep -Fq 'turn_off_mmu' "$RK"
grep -Fq 'depends on HIBERNATION || KEXEC_CORE' "$KCFG"
[ ! -e "$K/arch/arm64/kernel/cpu-reset.h" ] || { echo 'legacy cpu-reset.h remains' >&2; exit 22; }

# Runtime evidence from TicWatch run 20260914_154007 showed:
#   Kernel panic - not syncing: CFI failure (target: copied relocation code)
#   machine_kexec+0x124
# The v5.16 design calls the copied assembly relocation trampoline indirectly.
# That copied code has no Clang CFI type metadata. Disable CFI instrumentation
# only for machine_kexec(), matching the upstream x86 fix for the same pattern.
python3 - "$MK" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text()
old='void machine_kexec(struct kimage *kimage)'
new='void __nocfi machine_kexec(struct kimage *kimage)'
if s.count(new) == 1:
    pass
elif s.count(old) == 1:
    s=s.replace(old,new,1)
    p.write_text(s)
else:
    raise SystemExit('machine_kexec CFI compatibility anchor mismatch')
PY
git -C "$K" add arch/arm64/kernel/machine_kexec.c
grep -Fq 'void __nocfi machine_kexec(struct kimage *kimage)' "$MK"
echo 'TICWATCH_ARM64_KEXEC_CFI_RELOC_FIX=APPLIED'

# Runtime-only boundary diagnostics for the remaining silent failure after
# MACHINE_KEXEC BEFORE. Persist each major boundary through kmsg_dump(OOPS)
# so ramoops keeps the last completed step even if TTBR/relocation goes dark.
# No ABI, exported symbol, page-table or relocation behavior is changed.
python3 - "$MK" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text()
inc='#include <linux/kexec.h>\n'
if '#include <linux/kmsg_dump.h>' not in s:
    if s.count(inc) != 1:
        raise SystemExit('machine_kexec kexec.h include anchor mismatch')
    s=s.replace(inc, inc+'#include <linux/kmsg_dump.h>\n', 1)

old='''\tpr_info("Bye!\\n");\n\n\tlocal_daif_mask();\n'''
new='''\tpr_emerg("TWKEXEC_MMU: ENTER head=%lx start=%lx dtb=%pa reloc=%pa ttbr0=%pa t0sz=%lx ttbr1=%pa zero=%pa el2=%pa hyp_nvhe=%d\\n",\n\t\t kimage->head, kimage->start, &kimage->arch.dtb_mem,\n\t\t &kimage->arch.kern_reloc, &kimage->arch.ttbr0,\n\t\t kimage->arch.t0sz, &kimage->arch.ttbr1,\n\t\t &kimage->arch.zero_page, &kimage->arch.el2_vectors,\n\t\t is_hyp_nvhe());\n\tkmsg_dump(KMSG_DUMP_OOPS);\n\tpr_info("Bye!\\n");\n\n\tlocal_daif_mask();\n\tpr_emerg("TWKEXEC_MMU: DAIF MASKED\\n");\n\tkmsg_dump(KMSG_DUMP_OOPS);\n'''
if 'TWKEXEC_MMU: ENTER' not in s:
    if s.count(old) != 1:
        raise SystemExit(f'machine_kexec entry anchor mismatch: {s.count(old)}')
    s=s.replace(old,new,1)

old2='''\t\tif (is_hyp_nvhe())\n\t\t\t__hyp_set_vectors(kimage->arch.el2_vectors);\n\t\tcpu_install_ttbr0(kimage->arch.ttbr0, kimage->arch.t0sz);\n\t\tkernel_reloc = (void *)kimage->arch.kern_reloc;\n\t\tkernel_reloc(kimage);\n'''
new2='''\t\tif (is_hyp_nvhe()) {\n\t\t\tpr_emerg("TWKEXEC_MMU: EL2_VECTORS BEFORE pa=%pa\\n",\n\t\t\t\t &kimage->arch.el2_vectors);\n\t\t\tkmsg_dump(KMSG_DUMP_OOPS);\n\t\t\t__hyp_set_vectors(kimage->arch.el2_vectors);\n\t\t\tpr_emerg("TWKEXEC_MMU: EL2_VECTORS AFTER\\n");\n\t\t\tkmsg_dump(KMSG_DUMP_OOPS);\n\t\t}\n\t\tpr_emerg("TWKEXEC_MMU: TTBR0 BEFORE pa=%pa t0sz=%lx\\n",\n\t\t\t &kimage->arch.ttbr0, kimage->arch.t0sz);\n\t\tkmsg_dump(KMSG_DUMP_OOPS);\n\t\tcpu_install_ttbr0(kimage->arch.ttbr0, kimage->arch.t0sz);\n\t\tpr_emerg("TWKEXEC_MMU: TTBR0 AFTER\\n");\n\t\tkmsg_dump(KMSG_DUMP_OOPS);\n\t\tkernel_reloc = (void *)kimage->arch.kern_reloc;\n\t\tpr_emerg("TWKEXEC_MMU: KERNEL_RELOC BEFORE target=%px kimage=%px\\n",\n\t\t\t kernel_reloc, kimage);\n\t\tkmsg_dump(KMSG_DUMP_OOPS);\n\t\tkernel_reloc(kimage);\n\t\tpr_emerg("TWKEXEC_MMU: KERNEL_RELOC RETURNED\\n");\n\t\tkmsg_dump(KMSG_DUMP_OOPS);\n'''
if 'TWKEXEC_MMU: TTBR0 BEFORE' not in s:
    if s.count(old2) != 1:
        raise SystemExit(f'machine_kexec MMU branch anchor mismatch: {s.count(old2)}')
    s=s.replace(old2,new2,1)
p.write_text(s)
PY
git -C "$K" add arch/arm64/kernel/machine_kexec.c
for M in \
  'TWKEXEC_MMU: ENTER' \
  'TWKEXEC_MMU: DAIF MASKED' \
  'TWKEXEC_MMU: TTBR0 BEFORE' \
  'TWKEXEC_MMU: TTBR0 AFTER' \
  'TWKEXEC_MMU: KERNEL_RELOC BEFORE' \
  'TWKEXEC_MMU: KERNEL_RELOC RETURNED'; do
  grep -Fq "$M" "$MK"
done
grep -Fq '#include <linux/kmsg_dump.h>' "$MK"
echo 'TICWATCH_ARM64_KEXEC_MMU_BOUNDARY_DIAGNOSTICS=APPLIED'

git -C "$K" diff --cached --check
REPORT="${GITHUB_WORKSPACE:-$PWD}/kexec-arm64-mmu-reloc-backport.txt"
{
  echo 'TICWATCH_ARM64_KEXEC_BACKPORT=LINUX_V5.16_COHERENT_SERIES_PLUS_RUNTIME_FIXES'
  echo "ORIGINAL_HEAD=$ORIGINAL_HEAD"
  echo "BASE_HEAD=$BASE_HEAD"
  echo "BASELINE_TRACKED_DIRTY=$BASELINE_TRACKED_DIRTY"
  echo "COMMIT_COUNT=${#SERIES[@]}"
  printf 'UPSTREAM_COMMIT=%s\n' "${SERIES[@]}"
  echo 'PATCH_SOURCE=EXACT_GITHUB_COMMIT_PATCH'
  echo "THREEWAY_ADAPT_COUNT=${#THREEWAY_COMMITS[@]}"
  if [ "${#THREEWAY_COMMITS[@]}" -gt 0 ]; then printf 'THREEWAY_ADAPTED_COMMIT=%s\n' "${THREEWAY_COMMITS[@]}"; fi
  echo 'MMU_ENABLED_DURING_RELOCATION=YES'
  echo 'LEGACY_CPU_RESET_H_REMOVED=YES'
  echo "ZERO_PAGE_UPSTREAM_FIX=$ZERO_PAGE_FIX"
  echo 'ZERO_PAGE_FIX_STATUS=APPLIED_EXACT_UPSTREAM_PATCH'
  echo 'ZERO_PAGE_FIX_REASON=KERNEL_IMAGE_SYMBOL_REQUIRES_PA_SYMBOL_WITH_RELOCATABLE_RANDOMIZE_BASE'
  echo "KIMAGE_CLOBBER_UPSTREAM_FIX=$KIMAGE_CLOBBER_FIX"
  echo 'KIMAGE_CLOBBER_FIX_STATUS=APPLIED_EXACT_UPSTREAM_PATCH'
  echo 'TRANS_PGD_INVALID_PTE_UPSTREAM_REFERENCE=7eced90b202d63cdc1b9b11b1353adb1389830f9'
  echo 'TRANS_PGD_INVALID_PTE_FIX_STATUS=APPLIED_V5.16_CONTEXT_EQUIVALENT'
  echo 'TRANS_PGD_FIX_REASON=TICWATCH_CONFIG_KFENCE_Y_ACTIVE_SAMPLE_500MS'
  echo 'FUNCTION_ALIGNMENT_PADDING_FIX_NEEDED=NO_CURRENT_CONFIG_FUNCTION_ALIGNMENT_0'
  echo 'CFI_CLANG_COPIED_RELOC_TRAMPOLINE_FIX=MACHINE_KEXEC_NOCFI'
  echo 'CFI_FIX_RUNTIME_EVIDENCE=PSTORE_20260914_154007_MACHINE_KEXEC_PLUS_0X124'
  echo 'POST_CFI_RUNTIME_EVIDENCE=NO_FRESH_PANIC_RESCUE_NOT_REACHED_THROUGH_20260914_175316'
  echo 'MMU_RUNTIME_BOUNDARY_DIAGNOSTICS=ENTER_DAIF_EL2_TTBR0_RELOC_WITH_PSTORE_DUMPS'
  echo 'BACKPORT_STRUCTURAL_GATES=PASS'
  echo
  git -C "$K" diff --cached --stat
} > "$REPORT"
cat "$REPORT"
echo 'TICWATCH_ARM64_MMU_RELOC_BACKPORT=APPLIED'
