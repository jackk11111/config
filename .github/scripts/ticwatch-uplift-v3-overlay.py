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

resolver = r'''              # v5.15.217: VFS/audit kern_path_parent() Android conflict.
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

                theirs="$(mktemp)"
                git show ":3:$f" > "$theirs" || { rm -f "$theirs"; exit 52; }
                git checkout --ours -- "$f"

                python3 - "$f" "$theirs" <<'PYAUDIT'
from pathlib import Path
import re
import sys

p = Path(sys.argv[1])
theirs = Path(sys.argv[2]).read_text()
s = p.read_text()

old_lookup = "\tdentry = kern_path_locked(pathname, &path);\n"
parent_lookup = "\tdentry = kern_path_parent(pathname, &path);\n"
inode_decl = "\tstruct inode *inode;\n"
unlock = "\tinode = path.dentry->d_inode;\n\tinode_unlock(inode);\n"

if s.count(old_lookup) != 1 or s.count(inode_decl) != 1 or s.count(unlock) != 1:
    raise SystemExit('FAIL_AUDIT_PARENT_OURS_LAYOUT')
if parent_lookup in s:
    raise SystemExit('FAIL_AUDIT_PARENT_ALREADY_APPLIED')
if theirs.count(parent_lookup) != 1:
    raise SystemExit('FAIL_AUDIT_PARENT_THEIRS_LOOKUP')

helpers = [h for h in ('d_really_is_negative', 'd_is_negative')
           if f"\tif ({h}(dentry)) {{\n" in theirs]
if len(helpers) != 1:
    raise SystemExit(f'FAIL_AUDIT_PARENT_NEGATIVE_HELPER={helpers}')
helper = helpers[0]
negative = (
    f"\tif ({helper}(dentry)) {{\n"
    "\t\taudit_mark = ERR_PTR(-ENOENT);\n"
    "\t\tgoto out;\n"
    "\t}\n"
)

m = re.findall(r'^\tret = fsnotify_add_inode_mark\(&audit_mark->mark, inode, (true|0)\);$', s, re.M)
if len(m) != 1:
    raise SystemExit(f'FAIL_AUDIT_PARENT_ADD_MARK={m}')
allow_dups = m[0]

s = s.replace(inode_decl, '', 1)
s = s.replace(old_lookup, parent_lookup, 1)
s = s.replace(unlock, negative, 1)
old_add = f"\tret = fsnotify_add_inode_mark(&audit_mark->mark, inode, {allow_dups});"
new_add = f"\tret = fsnotify_add_inode_mark(&audit_mark->mark, path.dentry->d_inode, {allow_dups});"
if s.count(old_add) != 1:
    raise SystemExit('FAIL_AUDIT_PARENT_ADD_REPLACE')
s = s.replace(old_add, new_add, 1)

if any(x in s for x in ('<<<<<<<', '=======', '>>>>>>>')):
    raise SystemExit('FAIL_AUDIT_PARENT_MARKERS')
if s.count(parent_lookup) != 1 or old_lookup in s or 'inode_unlock(inode);' in s:
    raise SystemExit('FAIL_AUDIT_PARENT_POST')
if s.count(new_add) != 1:
    raise SystemExit('FAIL_AUDIT_PARENT_POST_ADD_MARK')

p.write_text(s)
print(f'AUDIT_PARENT_PRESERVED_ALLOW_DUPS={allow_dups}')
print(f'AUDIT_PARENT_NEGATIVE_HELPER={helper}')
PYAUDIT
                rm -f "$theirs"
                git add -- "$f"
                [ -z "$(git diff --name-only --diff-filter=U)" ] || {
                  echo 'FAIL_AUDIT_PARENT_UNMERGED_REMAIN' >&2
                  git diff --name-only --diff-filter=U >&2
                  exit 52
                }
                git diff --cached --check || exit 52
                git -c user.name='TicWatch LTS CI' -c user.email='ci@local' cherry-pick --continue || exit 52
                grep -Fq 'kern_path_parent(pathname, &path);' "$f" || exit 52
                ! grep -Fq 'kern_path_locked(pathname, &path);' "$f" || exit 52
                ! grep -Fq 'inode_unlock(inode);' "$f" || exit 52
                echo "ANDROID_TICWATCH_AUDIT_PARENT_RESOLVED=$c FILE=$f"
                continue
              fi

'''

if s.count(anchor) != 1:
    raise SystemExit(f"FAIL_V3_RESOLVER_ANCHOR=count={s.count(anchor)}")
s = s.replace(anchor, resolver + anchor, 1)

p.write_text(s)
print("V3_SIMPLE_RESUME_RESOLVER_APPLIED=1")
