#!/usr/bin/env python3
from pathlib import Path
import re
import sys

if len(sys.argv) != 2:
    raise SystemExit("usage: ticwatch-uplift-v3-overlay.py /tmp/uplift.sh")

p = Path(sys.argv[1])
s = p.read_text()

stable_url = "https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git"
old = f"git remote add stable {stable_url}"
new = f"""if git remote get-url stable >/dev/null 2>&1; then
  [ "$(git remote get-url stable)" = '{stable_url}' ] || {{
    echo 'FAIL_STABLE_REMOTE_URL' >&2
    exit 62
  }}
else
  git remote add stable {stable_url}
fi"""
if s.count(old) != 1:
    raise SystemExit(f"FAIL_OVERLAY_STABLE_REMOTE=count={s.count(old)}")
s = s.replace(old, new, 1)

pattern_prev = re.compile(r"(?m)^prev='v5\.15\.211'$")
replacement_prev = r"""resume_from="$(cat .git/ticwatch-last-complete 2>/dev/null || printf '%s\n' 211)"
case "$resume_from" in
  211|212|213|214|215|216|217|218|219|220) ;;
  *)
    echo "FAIL_RESUME_POINT=$resume_from" >&2
    exit 63
    ;;
esac
prev="v5.15.$resume_from"
echo "UPLIFT_RESUME_AFTER=$prev"""
s, n = pattern_prev.subn(lambda _m: replacement_prev, s, count=1)
if n != 1:
    raise SystemExit(f"FAIL_OVERLAY_PREV=count={n}")

old_loop = "for n in 212 213 214 215 216 217 218 219 220; do"
new_loop = 'for n in $(seq $((resume_from + 1)) 220); do'
if s.count(old_loop) != 1:
    raise SystemExit(f"FAIL_OVERLAY_LOOP=count={s.count(old_loop)}")
s = s.replace(old_loop, new_loop, 1)

old_complete = '  echo "POINT_RELEASE_COMPLETE=$current"\n  prev="$tag"'
new_complete = (
    '  echo "POINT_RELEASE_COMPLETE=$current"\n'
    '  printf \'%s\\n\' "$n" > .git/ticwatch-last-complete\n'
    '  prev="$tag"'
)
if s.count(old_complete) != 1:
    raise SystemExit(f"FAIL_OVERLAY_CHECKPOINT=count={s.count(old_complete)}")
s = s.replace(old_complete, new_complete, 1)

# Future narrow fail-closed resolvers go here before the canonical resolver call.
# Keep V2 frozen so resolver edits do not trigger the old non-resumable workflow.

p.write_text(s)
print("V3_RESUME_OVERLAY_APPLIED=1")
