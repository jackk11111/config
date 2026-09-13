#!/usr/bin/env python3
from pathlib import Path
import sys

if len(sys.argv) != 2:
    raise SystemExit("usage: ticwatch-uplift-v3-overlay.py /tmp/uplift.sh")

p = Path(sys.argv[1])
s = p.read_text()

# Resume only from the last fully completed point release.
old_prev = "prev='v5.15.211'"
new_prev = r'''resume_from="$(cat .git/ticwatch-last-complete 2>/dev/null || printf '%s\n' 211)"
case "$resume_from" in
  211|212|213|214|215|216|217|218|219|220) ;;
  *) echo "FAIL_RESUME_POINT=$resume_from" >&2; exit 63 ;;
esac
prev="v5.15.$resume_from"
echo "UPLIFT_RESUME_AFTER=$prev"'''
if s.count(old_prev) != 1:
    raise SystemExit(f"FAIL_V3_RESUME_PREV=count={s.count(old_prev)}")
s = s.replace(old_prev, new_prev, 1)

old_loop = "for n in 212 213 214 215 216 217 218 219 220; do"
new_loop = 'for n in $(seq $((resume_from + 1)) 220); do'
if s.count(old_loop) != 1:
    raise SystemExit(f"FAIL_V3_RESUME_LOOP=count={s.count(old_loop)}")
s = s.replace(old_loop, new_loop, 1)

old_complete = '  echo "POINT_RELEASE_COMPLETE=$current"\n  prev="$tag"'
new_complete = (
    '  echo "POINT_RELEASE_COMPLETE=$current"\n'
    '  printf \'%s\\n\' "$n" > .git/ticwatch-last-complete\n'
    '  prev="$tag"'
)
if s.count(old_complete) != 1:
    raise SystemExit(f"FAIL_V3_RESUME_COMPLETE=count={s.count(old_complete)}")
s = s.replace(old_complete, new_complete, 1)

anchor = '''    echo "FIRST_CONFLICT_TAG=$tag"
    echo "FIRST_CONFLICT_COMMIT=$c"
    echo "FIRST_CONFLICT_SUBJECT=$subject"'''

resolver = r'''              # v5.15.217: resolve only the conflicted audit_alloc_mark() hunks.
              # Keep every already-auto-merged Android/TicWatch line outside the
              # conflicted function; select stable only inside the conflict hunks.
              if [ "$tag" = 'v5.15.217' ] && [ "$c" = '7f125ea143d05393c107792aa862bb6ae0f09a85' ]; then
                f='kernel/audit_fsnotify.c'
                [ "$subject" = 'VFS/audit: introduce kern_path_parent() for audit' ] || {
                  echo "FAIL_AUDIT_PARENT_SUBJECT=$subject" >&2
                  exit 52
                }
                conflicts="$(git diff --name-only --diff-filter=U)"
                [ "$conflicts" = "$f" ] || {
                  echo 'FAIL_AUDIT_PARENT_CONFLICT_FILES' >&2
                  printf 'EXPECTED:%s\nACTUAL_BEGIN\n%s\nACTUAL_END\n' "$f" "$conflicts" >&2
                  exit 52
                }

                python3 - "$f" <<'PYAUDIT'
from pathlib import Path
import re
import sys

p = Path(sys.argv[1])
s = p.read_text()

start = s.find('struct audit_fsnotify_mark *audit_alloc_mark(')
end = s.find('\nstatic void audit_mark_log_rule_change', start)
if start < 0 or end < 0:
    raise SystemExit('FAIL_AUDIT_PARENT_FUNCTION_BOUNDS')

outside = s[:start] + s[end:]
if any(m in outside for m in ('<<<<<<<', '=======', '>>>>>>>')):
    raise SystemExit('FAIL_AUDIT_PARENT_CONFLICT_OUTSIDE_FUNCTION')

body = s[start:end]
left = body.count('<<<<<<<')
mid = body.count('=======')
right = body.count('>>>>>>>')
if left < 1 or left != mid or left != right:
    raise SystemExit(f'FAIL_AUDIT_PARENT_MARKER_COUNTS={left},{mid},{right}')

pat = re.compile(r'^<<<<<<<[^\n]*\n(.*?)^=======\n(.*?)^>>>>>>>[^\n]*\n?', re.M | re.S)
resolved, n = pat.subn(lambda m: m.group(2), body)
if n != left:
    raise SystemExit(f'FAIL_AUDIT_PARENT_RESOLVED_HUNKS={n}/{left}')
if any(m in resolved for m in ('<<<<<<<', '=======', '>>>>>>>')):
    raise SystemExit('FAIL_AUDIT_PARENT_MARKERS_REMAIN')

if 'kern_path_parent(pathname, &path)' not in resolved:
    raise SystemExit('FAIL_AUDIT_PARENT_NO_KERN_PATH_PARENT')
if 'kern_path_locked(pathname, &path)' in resolved:
    raise SystemExit('FAIL_AUDIT_PARENT_OLD_LOOKUP_REMAINS')
if 'inode_unlock(' in resolved:
    raise SystemExit('FAIL_AUDIT_PARENT_UNLOCK_REMAINS')
if 'fsnotify_add_inode_mark(' not in resolved:
    raise SystemExit('FAIL_AUDIT_PARENT_NO_FSNOTIFY_MARK')

p.write_text(s[:start] + resolved + s[end:])
print(f'AUDIT_PARENT_STABLE_CONFLICT_HUNKS={n}')
PYAUDIT

                git add -- "$f"
                [ -z "$(git diff --name-only --diff-filter=U)" ] || {
                  echo 'FAIL_AUDIT_PARENT_UNMERGED_REMAIN' >&2
                  git diff --name-only --diff-filter=U >&2
                  exit 52
                }
                git diff --cached --check || exit 52
                git -c user.name='TicWatch LTS CI' -c user.email='ci@local' cherry-pick --continue || exit 52
                grep -Fq 'kern_path_parent(pathname, &path)' "$f" || exit 52
                ! grep -Fq 'kern_path_locked(pathname, &path)' "$f" || exit 52
                ! grep -Fq 'inode_unlock(' "$f" || exit 52
                echo "ANDROID_TICWATCH_AUDIT_PARENT_RESOLVED=$c FILE=$f"
                continue
              fi

              # v5.15.217: mechanical dst_dev conversion; only route.c conflicts.
              # Start from Android/TicWatch route.c and apply exactly the three
              # route.c semantic substitutions from the 5.15.y backport.
              if [ "$tag" = 'v5.15.217' ] && [ "$c" = 'db686880dcade127da4fb1a9462b669027469376' ]; then
                f='net/ipv4/route.c'
                [ "$subject" = 'ipv4: adopt dst_dev, skb_dst_dev and skb_dst_dev_net[_rcu]' ] || {
                  echo "FAIL_IPV4_DSTDEV_SUBJECT=$subject" >&2
                  exit 54
                }
                conflicts="$(git diff --name-only --diff-filter=U)"
                [ "$conflicts" = "$f" ] || {
                  echo 'FAIL_IPV4_DSTDEV_CONFLICT_FILES' >&2
                  printf 'EXPECTED:%s\nACTUAL_BEGIN\n%s\nACTUAL_END\n' "$f" "$conflicts" >&2
                  exit 54
                }

                git checkout --ours -- "$f"
                python3 - "$f" <<'PYIPV4DST'
from pathlib import Path
import sys

p = Path(sys.argv[1])
s = p.read_text()

old_dev = '\tstruct net_device *dev = dst->dev;\n'
new_dev = '\tstruct net_device *dev = dst_dev(dst);\n'
old_net = '\tnet = dev_net_rcu(dst->dev);\n'
new_net = '\tnet = dev_net_rcu(dst_dev(dst));\n'

# 5.15.y changes exactly two route.c dev declarations and one PMTU net lookup.
# Accept already-converted Android code, but require the final stable semantics.
dev_total = s.count(old_dev) + s.count(new_dev)
net_total = s.count(old_net) + s.count(new_net)
if dev_total != 2:
    raise SystemExit(f'FAIL_IPV4_DSTDEV_DEV_SITES={dev_total}')
if net_total != 1:
    raise SystemExit(f'FAIL_IPV4_DSTDEV_NET_SITES={net_total}')

s = s.replace(old_dev, new_dev)
s = s.replace(old_net, new_net)
if s.count(new_dev) != 2 or s.count(new_net) != 1:
    raise SystemExit('FAIL_IPV4_DSTDEV_POST')
if any(m in s for m in ('<<<<<<<', '=======', '>>>>>>>')):
    raise SystemExit('FAIL_IPV4_DSTDEV_MARKERS')

p.write_text(s)
print('IPV4_DSTDEV_ROUTE_PATCHED=1')
PYIPV4DST

                git add -- "$f"
                [ -z "$(git diff --name-only --diff-filter=U)" ] || {
                  echo 'FAIL_IPV4_DSTDEV_UNMERGED_REMAIN' >&2
                  git diff --name-only --diff-filter=U >&2
                  exit 54
                }
                git diff --cached --check || exit 54
                git -c user.name='TicWatch LTS CI' -c user.email='ci@local' cherry-pick --continue || exit 54
                grep -Fq 'struct net_device *dev = dst_dev(dst);' "$f" || exit 54
                grep -Fq 'net = dev_net_rcu(dst_dev(dst));' "$f" || exit 54
                echo "ANDROID_TICWATCH_IPV4_DSTDEV_RESOLVED=$c FILE=$f"
                continue
              fi

'''

if s.count(anchor) != 1:
    raise SystemExit(f"FAIL_V3_RESOLVER_ANCHOR=count={s.count(anchor)}")
s = s.replace(anchor, resolver + anchor, 1)

p.write_text(s)
print("V3_DIRECT_RESOLVERS_APPLIED=1")
