#!/usr/bin/env python3
from pathlib import Path
import sys

if len(sys.argv) != 2:
    raise SystemExit("usage: ticwatch-uplift-v3-mptcp-join.py /tmp/uplift.sh")

p = Path(sys.argv[1])
s = p.read_text()

anchor = '''    echo "FIRST_CONFLICT_TAG=$tag"
    echo "FIRST_CONFLICT_COMMIT=$c"
    echo "FIRST_CONFLICT_SUBJECT=$subject"'''

resolver = r'''              # v5.15.217: stable removes the old join-list flush from
              # mptcp_disconnect(). The stable parent also contains an unrelated
              # sk_wait_pending guard that is absent from the Android/TicWatch base.
              # Do not import parent-only context: resolve the single conflict by
              # applying only this commit's semantic delta (remove the flush call).
              if [ "$tag" = 'v5.15.217' ] && [ "$c" = '9d3b531b70d68dd2713cc2543182ec163d43bf2a' ]; then
                f='net/mptcp/protocol.c'
                [ "$subject" = 'mptcp: cleanup MPJ subflow list handling' ] || {
                  echo "FAIL_MPTCP_JOIN_SUBJECT=$subject" >&2
                  exit 57
                }
                conflicts="$(git diff --name-only --diff-filter=U)"
                [ "$conflicts" = "$f" ] || {
                  echo 'FAIL_MPTCP_JOIN_CONFLICT_FILES' >&2
                  printf 'EXPECTED:%s\nACTUAL_BEGIN\n%s\nACTUAL_END\n' "$f" "$conflicts" >&2
                  exit 57
                }

                python3 - "$f" <<'PYMPTCPJOIN'
from pathlib import Path
import re
import sys

p = Path(sys.argv[1])
s = p.read_text()

if s.count('<<<<<<< HEAD') != 1 or s.count('=======') != 1 or s.count('>>>>>>>') != 1:
    raise SystemExit('FAIL_MPTCP_JOIN_MARKER_COUNT')

pat = re.compile(
    r'^<<<<<<< HEAD\n'
    r'\tmptcp_do_flush_join_list\(msk\);\n'
    r'^=======\n'
    r'\t/\* Deny disconnect if other threads are blocked in sk_wait_event\(\)\n'
    r'\t \* or inet_wait_for_connect\(\)\.\n'
    r'\t \*/\n'
    r'\tif \(sk->sk_wait_pending\)\n'
    r'\t\treturn -EBUSY;\n'
    r'^>>>>>>> [^\n]+\n?',
    re.M,
)

s2, n = pat.subn('', s)
if n != 1:
    raise SystemExit(f'FAIL_MPTCP_JOIN_EXACT_HUNK={n}')
if any(m in s2 for m in ('<<<<<<<', '=======', '>>>>>>>')):
    raise SystemExit('FAIL_MPTCP_JOIN_MARKERS_REMAIN')

# This stable commit replaces the old flush machinery. All non-conflicting
# hunks were already merged by git; verify those semantics survived while the
# Android-only baseline is not augmented with unrelated stable-parent context.
if 'mptcp_do_flush_join_list' in s2:
    raise SystemExit('FAIL_MPTCP_JOIN_OLD_FLUSH_REMAINS')
if 'static bool __mptcp_finish_join(struct mptcp_sock *msk, struct sock *ssk)' not in s2:
    raise SystemExit('FAIL_MPTCP_JOIN_NEW_FINISH_HELPER')
if 'static void __mptcp_flush_join_list(struct sock *sk)' not in s2:
    raise SystemExit('FAIL_MPTCP_JOIN_NEW_FLUSH_HELPER')
if 'test_and_clear_bit(MPTCP_FLUSH_JOIN_LIST' not in s2:
    raise SystemExit('FAIL_MPTCP_JOIN_RELEASE_FLAG')

p.write_text(s2)
print('MPTCP_JOIN_ANDROID_PATCHED=1')
PYMPTCPJOIN

                git add -- "$f"
                [ -z "$(git diff --name-only --diff-filter=U)" ] || {
                  echo 'FAIL_MPTCP_JOIN_UNMERGED_REMAIN' >&2
                  git diff --name-only --diff-filter=U >&2
                  exit 57
                }
                git diff --cached --check || exit 57
                git -c user.name='TicWatch LTS CI' -c user.email='ci@local' cherry-pick --continue || exit 57
                ! grep -Fq 'mptcp_do_flush_join_list' "$f" || exit 57
                grep -Fq 'static bool __mptcp_finish_join(struct mptcp_sock *msk, struct sock *ssk)' "$f" || exit 57
                grep -Fq 'test_and_clear_bit(MPTCP_FLUSH_JOIN_LIST' "$f" || exit 57
                echo "ANDROID_TICWATCH_MPTCP_JOIN_RESOLVED=$c FILE=$f"
                continue
              fi

'''

if s.count(anchor) != 1:
    raise SystemExit(f"FAIL_MPTCP_JOIN_ANCHOR=count={s.count(anchor)}")
s = s.replace(anchor, resolver + anchor, 1)

p.write_text(s)
print("V3_MPTCP_JOIN_COMPAT_APPLIED=1")
