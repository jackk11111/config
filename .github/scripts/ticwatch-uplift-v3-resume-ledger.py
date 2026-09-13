#!/usr/bin/env python3
from pathlib import Path
import sys

if len(sys.argv) != 2:
    raise SystemExit("usage: ticwatch-uplift-v3-resume-ledger.py /tmp/uplift.sh")

p = Path(sys.argv[1])
s = p.read_text()

# Disable automatic Git maintenance in the actual kernel repository and keep an
# exact ledger of upstream stable SHAs already processed. This is independent
# of patch-id, so conflict-resolved cherry-picks are not retried on resume.
old_kernel_start = '''cd kernel
git remote add stable https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git'''
new_kernel_start = r'''cd kernel
git config gc.auto 0
git config gc.autoDetach false
git config maintenance.auto false

ledger='.git/ticwatch-applied-stable'
touch "$ledger"

# Recover source SHAs from normal `git cherry-pick -x` commits already present
# in the checkpoint. This also recovers conflict-resolved cherry-picks whose
# patch-id differs from upstream stable.
git log --first-parent -n 4096 --format='%B' \
  | sed -nE 's/^\(cherry picked from commit ([0-9a-f]{40})\)$/\1/p' \
  >> "$ledger"

# Run #10 resolved 7f125... as commit 4d4bbfc25275... and then advanced to
# 8331774c626f. Seed the exact stable SHA only when that resolution commit is
# actually an ancestor of the restored checkpoint. The abbreviated object ID
# is sufficient and avoids inventing an unavailable full SHA.
audit_resolution_commit='4d4bbfc25275'
audit_stable_sha='7f125ea143d05393c107792aa862bb6ae0f09a85'
if git cat-file -e "${audit_resolution_commit}^{commit}" 2>/dev/null && \
   git merge-base --is-ancestor "$audit_resolution_commit" HEAD; then
  grep -Fqx "$audit_stable_sha" "$ledger" || printf '%s\n' "$audit_stable_sha" >> "$ledger"
  echo "LEDGER_BOOTSTRAP_AUDIT=$audit_stable_sha"
fi

sort -u "$ledger" -o "$ledger"
echo "STABLE_LEDGER_COUNT=$(sed '/^$/d' "$ledger" | wc -l | tr -d ' ')"

git remote add stable https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git'''
if s.count(old_kernel_start) != 1:
    raise SystemExit(f"FAIL_LEDGER_KERNEL_START=count={s.count(old_kernel_start)}")
s = s.replace(old_kernel_start, new_kernel_start, 1)

old_missing = '''    missing="$(git cherry HEAD "$tag" "$prev" | awk '$1=="+"{print $2}')"
    total="$(git rev-list --count "$prev..$tag")"
    missing_count="$(printf '%s\\n' "$missing" | sed '/^$/d' | wc -l)"
    echo "POINT_RELEASE=$tag TOTAL_COMMITS=$total MISSING_COMMITS=$missing_count"'''
new_missing = r'''    raw_missing="$(git cherry HEAD "$tag" "$prev" | awk '$1=="+"{print $2}')"
    if [ -s "$ledger" ]; then
      missing="$(printf '%s\n' "$raw_missing" | grep -Fvx -f "$ledger" || true)"
    else
      missing="$raw_missing"
    fi
    total="$(git rev-list --count "$prev..$tag")"
    raw_missing_count="$(printf '%s\n' "$raw_missing" | sed '/^$/d' | wc -l)"
    missing_count="$(printf '%s\n' "$missing" | sed '/^$/d' | wc -l)"
    ledger_filtered=$((raw_missing_count - missing_count))
    echo "POINT_RELEASE=$tag TOTAL_COMMITS=$total MISSING_COMMITS=$missing_count LEDGER_FILTERED=$ledger_filtered"'''
if s.count(old_missing) != 1:
    raise SystemExit(f"FAIL_LEDGER_MISSING_BLOCK=count={s.count(old_missing)}")
s = s.replace(old_missing, new_missing, 1)

old_clean = '''      if git -c user.name='TicWatch LTS CI' -c user.email='ci@local' cherry-pick -x "$c"; then
        continue
      fi'''
new_clean = r'''      if git -c user.name='TicWatch LTS CI' -c user.email='ci@local' cherry-pick -x "$c"; then
        grep -Fqx "$c" "$ledger" || printf '%s\n' "$c" >> "$ledger"
        continue
      fi'''
if s.count(old_clean) != 1:
    raise SystemExit(f"FAIL_LEDGER_CLEAN_PICK=count={s.count(old_clean)}")
s = s.replace(old_clean, new_clean, 1)

p.write_text(s)
print("V3_RESUME_LEDGER_APPLIED=1")
