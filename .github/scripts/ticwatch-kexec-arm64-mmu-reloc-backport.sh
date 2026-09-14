#!/usr/bin/env bash
set -Eeuo pipefail

K="${1:?usage: $0 <kernel-tree>}"
[ -d "$K/.git" ] || { echo "missing kernel git tree: $K" >&2; exit 2; }

# Linux v5.16 ARM64 kexec relocation series, Pasha/Pavel Tatashin.
# Apply as one coherent series: do not select individual commits.
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

# The verified precompile checkpoint intentionally contains tracked source
# changes relative to its historical Git HEAD. Preserve that exact state as
# an ephemeral local commit in the CI runner instead of resetting or stashing
# it. This makes subsequent upstream cherry-pick conflicts unambiguous while
# keeping every checkpoint byte used by the known-good build.
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

for sha in "${SERIES[@]}"; do
  if ! git -C "$K" cat-file -e "$sha^{commit}" 2>/dev/null; then
    echo "Fetching upstream ARM64 kexec commit $sha"
    git -C "$K" fetch --no-tags --depth=2 https://github.com/torvalds/linux.git "$sha"
  fi
done

capture_conflict() {
  local sha="$1"
  local root="${GITHUB_WORKSPACE:-$PWD}/backport-failure"
  local path safe
  rm -rf "$root"
  mkdir -p "$root/files"

  {
    echo "ARM64_KEXEC_BACKPORT_CONFLICT_SHA=$sha"
    echo "ORIGINAL_HEAD=$ORIGINAL_HEAD"
    echo "BASE_HEAD=$BASE_HEAD"
    echo "BASELINE_TRACKED_DIRTY=$BASELINE_TRACKED_DIRTY"
    echo
    echo 'STATUS_SHORT:'
    git -C "$K" status --short || true
    echo
    echo 'UNMERGED_PATHS:'
    git -C "$K" diff --name-only --diff-filter=U || true
    echo
    echo 'UNMERGED_INDEX:'
    git -C "$K" ls-files -u || true
    echo
    echo 'COMBINED_CONFLICT_DIFF:'
    git -C "$K" diff --cc || true
  } > "$root/summary.txt" 2>&1

  git -C "$K" show --format=fuller --stat "$sha" > "$root/upstream-commit-stat.txt" 2>&1 || true
  git -C "$K" show --format=fuller --binary "$sha" > "$root/upstream-commit.patch" 2>&1 || true
  git -C "$K" diff --cached --binary > "$root/index-after-failure.patch" 2>&1 || true

  while IFS= read -r path; do
    [ -n "$path" ] || continue
    safe="$(printf '%s' "$path" | sha256sum | awk '{print $1}')"
    printf '%s\n' "$path" > "$root/files/$safe.path"
    git -C "$K" ls-files -u -- "$path" > "$root/files/$safe.index" 2>&1 || true
    git -C "$K" show ":1:$path" > "$root/files/$safe.base" 2>/dev/null || true
    git -C "$K" show ":2:$path" > "$root/files/$safe.ours" 2>/dev/null || true
    git -C "$K" show ":3:$path" > "$root/files/$safe.theirs" 2>/dev/null || true
  done < <(git -C "$K" diff --name-only --diff-filter=U)

  cat "$root/summary.txt" >&2
}

for sha in "${SERIES[@]}"; do
  echo "Applying upstream ARM64 kexec commit $sha"
  if ! git -C "$K" cherry-pick -n "$sha"; then
    capture_conflict "$sha"
    exit 20
  fi
done

# Structural gates for the completed v5.16 relocation design.
MK="$K/arch/arm64/kernel/machine_kexec.c"
RK="$K/arch/arm64/kernel/relocate_kernel.S"
MMU="$K/arch/arm64/include/asm/mmu_context.h"
TPH="$K/arch/arm64/include/asm/trans_pgd.h"
TPC="$K/arch/arm64/mm/trans_pgd.c"
KCFG="$K/arch/arm64/Kconfig"

for f in "$MK" "$RK" "$MMU" "$TPH" "$TPC" "$KCFG"; do
  [ -s "$f" ] || { echo "missing expected backport file: $f" >&2; exit 21; }
done

grep -Fq 'machine_kexec_post_load' "$MK"
grep -Fq 'trans_pgd_create_copy' "$MK"
grep -Fq 'trans_pgd_copy_el2_vectors' "$MK"
grep -Fq 'cpu_install_ttbr0' "$MMU"
grep -Fq 'trans_pgd_copy_el2_vectors' "$TPH"
grep -Fq 'trans_pgd_copy_el2_vectors' "$TPC"
grep -Fq 'turn_off_mmu' "$RK"
grep -Fq 'depends on HIBERNATION || KEXEC_CORE' "$KCFG"
[ ! -e "$K/arch/arm64/kernel/cpu-reset.h" ] || {
  echo 'legacy cpu-reset.h unexpectedly remains after complete series' >&2
  exit 22
}

git -C "$K" diff --cached --check

REPORT="${GITHUB_WORKSPACE:-$PWD}/kexec-arm64-mmu-reloc-backport.txt"
{
  echo 'TICWATCH_ARM64_KEXEC_BACKPORT=LINUX_V5.16_COHERENT_SERIES'
  echo "ORIGINAL_HEAD=$ORIGINAL_HEAD"
  echo "BASE_HEAD=$BASE_HEAD"
  echo "BASELINE_TRACKED_DIRTY=$BASELINE_TRACKED_DIRTY"
  echo "COMMIT_COUNT=${#SERIES[@]}"
  printf 'UPSTREAM_COMMIT=%s\n' "${SERIES[@]}"
  echo 'MMU_ENABLED_DURING_RELOCATION=YES'
  echo 'LEGACY_CPU_RESET_H_REMOVED=YES'
  echo 'BACKPORT_STRUCTURAL_GATES=PASS'
  echo
  git -C "$K" diff --cached --stat
} > "$REPORT"

cat "$REPORT"
echo 'TICWATCH_ARM64_MMU_RELOC_BACKPORT=APPLIED'
