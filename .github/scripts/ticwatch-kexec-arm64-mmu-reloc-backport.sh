#!/usr/bin/env bash
set -Eeuo pipefail

K="${1:?usage: $0 <kernel-tree>}"
[ -d "$K/.git" ] || { echo "missing kernel git tree: $K" >&2; exit 2; }

# Linux v5.16 ARM64 kexec relocation series, Pasha/Pavel Tatashin.
# Apply the exact 15 upstream commits as one coherent ordered series.
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

# The verified precompile checkpoint intentionally contains tracked source
# changes relative to its historical Git HEAD. Freeze that exact state in an
# ephemeral runner-only commit; never reset/stash/drop checkpoint content.
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

# Fetch patch payloads, not Linux git trees. This avoids repeatedly downloading
# large upstream object graphs while preserving the exact commit deltas.
for sha in "${SERIES[@]}"; do
  url="https://github.com/torvalds/linux/commit/${sha}.patch"
  echo "Downloading exact upstream patch $sha"
  curl -fsSL --retry 3 --retry-delay 1 --connect-timeout 20 "$url" -o "$WORK/$sha.patch"
  test -s "$WORK/$sha.patch"
  grep -Fq "From $sha " "$WORK/$sha.patch" || {
    echo "upstream patch identity mismatch: $sha" >&2
    exit 19
  }
done

capture_conflict() {
  local sha="$1" patch="$2"
  local root="${GITHUB_WORKSPACE:-$PWD}/backport-failure"
  local path safe
  rm -rf "$root"
  mkdir -p "$root/files"

  cp "$patch" "$root/failed-upstream.patch"
  {
    echo "ARM64_KEXEC_BACKPORT_CONFLICT_SHA=$sha"
    echo "ORIGINAL_HEAD=$ORIGINAL_HEAD"
    echo "BASE_HEAD=$BASE_HEAD"
    echo "BASELINE_TRACKED_DIRTY=$BASELINE_TRACKED_DIRTY"
    echo
    echo 'STATUS_SHORT_BEFORE_REJECT:'
    git -C "$K" status --short || true
    echo
    echo 'FAILED_PATCH_FILES:'
    grep '^diff --git a/' "$patch" || true
    echo
    echo 'GIT_APPLY_CHECK_VERBOSE:'
    git -C "$K" apply --check --verbose --whitespace=nowarn "$patch" || true
    echo
    echo 'ALREADY_APPLIED_SERIES_INDEX_DIFF_STAT:'
    git -C "$K" diff --cached --stat || true
  } > "$root/summary.txt" 2>&1

  while IFS= read -r path; do
    [ -n "$path" ] || continue
    safe="$(printf '%s' "$path" | sha256sum | awk '{print $1}')"
    printf '%s\n' "$path" > "$root/files/$safe.path"
    if [ -e "$K/$path" ]; then
      cp "$K/$path" "$root/files/$safe.vendor-before"
    fi
  done < <(sed -n 's#^diff --git a/\(.*\) b/.*#\1#p' "$patch" | sort -u)

  find "$K" -type f -name '*.rej' -delete 2>/dev/null || true
  git -C "$K" apply --reject --whitespace=nowarn "$patch" > "$root/reject-apply.txt" 2>&1 || true
  while IFS= read -r rej; do
    [ -n "$rej" ] || continue
    path="${rej#"$K"/}"
    safe="$(printf '%s' "$path" | sha256sum | awk '{print $1}')"
    printf '%s\n' "$path" > "$root/files/$safe.reject-path"
    cp "$rej" "$root/files/$safe.rej"
  done < <(find "$K" -type f -name '*.rej' -print | sort)

  cat "$root/summary.txt" >&2
  cat "$root/reject-apply.txt" >&2 || true
}

# git apply --3way can merge an upstream delta with Qualcomm/vendor edits, but
# only when the upstream preimage blobs named by the patch exist in the local
# object database. Prime exactly those blobs from the commit's real parent.
prime_preimage_blobs() {
  local parent="$1" patch="$2" current='' line old path tmp full
  while IFS= read -r line; do
    case "$line" in
      'diff --git a/'*)
        current="${line#diff --git a/}"
        current="${current%% b/*}"
        ;;
      'index '*)
        [ -n "$current" ] || continue
        old="${line#index }"
        old="${old%%..*}"
        if [[ "$old" =~ ^0+$ ]]; then
          continue
        fi
        path="$current"
        tmp="$WORK/base-blobs/${parent}-${old}"
        if [ ! -s "$tmp" ]; then
          curl -fsSL --retry 3 --retry-delay 1 --connect-timeout 20 \
            "https://raw.githubusercontent.com/torvalds/linux/${parent}/${path}" -o "$tmp"
        fi
        full="$(git -C "$K" hash-object -w "$tmp")"
        case "$full" in
          "$old"*) ;;
          *)
            echo "preimage blob identity mismatch: parent=$parent path=$path expected=$old got=$full" >&2
            exit 18
            ;;
        esac
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
      # Restore the exact state after prior successful commits before producing
      # diagnostics. Never let a failed three-way merge contaminate the tree.
      git -C "$K" read-tree --reset -u "$PRE_TREE"
      capture_conflict "$sha" "$patch"
      exit 20
    fi
  fi
  parent="$sha"
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
  echo 'PATCH_SOURCE=EXACT_GITHUB_COMMIT_PATCH'
  echo "THREEWAY_ADAPT_COUNT=${#THREEWAY_COMMITS[@]}"
  if [ "${#THREEWAY_COMMITS[@]}" -gt 0 ]; then
    printf 'THREEWAY_ADAPTED_COMMIT=%s\n' "${THREEWAY_COMMITS[@]}"
  fi
  echo 'MMU_ENABLED_DURING_RELOCATION=YES'
  echo 'LEGACY_CPU_RESET_H_REMOVED=YES'
  echo 'BACKPORT_STRUCTURAL_GATES=PASS'
  echo
  git -C "$K" diff --cached --stat
} > "$REPORT"

cat "$REPORT"
echo 'TICWATCH_ARM64_MMU_RELOC_BACKPORT=APPLIED'
