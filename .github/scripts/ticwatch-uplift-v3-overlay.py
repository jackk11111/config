#!/usr/bin/env python3
from pathlib import Path
import sys

if len(sys.argv) != 2:
    raise SystemExit("usage: ticwatch-uplift-v3-overlay.py /tmp/uplift.sh")

p = Path(sys.argv[1])
s = p.read_text()

# Resume from the last fully completed stable point release. Use exact string
# replacements only: regex replacement processing previously corrupted shell
# backslash escapes inside the generated uplift script.
old_prev = "prev='v5.15.211'"
new_prev = r'''resume_from="$(cat .git/ticwatch-last-complete 2>/dev/null || printf '%s\n' 211)"
case "$resume_from" in
  211|212|213|214|215|216|217|218|219|220) ;;
  *)
    echo "FAIL_RESUME_POINT=$resume_from" >&2
    exit 63
    ;;
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

resolver = r'''              # v5.15.217 7f125ea143d0: introduce kern_path_parent() for audit.
              # Only kernel/audit_fsnotify.c conflicts on the Android/TicWatch tree.
              # Preserve Android's existing fsnotify allow_dups argument and apply
              # only this commit's path-lookup/locking semantic delta.
              if [ "$tag" = 'v5.15.217' ] && [ "$c" = '7f125ea143d05393c107792aa862bb6ae0f09a85' ]; then
                f='kernel/audit_fsnotify.c'
                expected_subject='VFS/audit: introduce kern_path_parent() for audit'
                [ "$subject" = "$expected_subject" ] || {
                  echo "FAIL_AUDIT_PARENT_SUBJECT=$subject" >&2
                  exit 52
                }
                actual_conflicts="$(git diff --name-only --diff-filter=U)"
                [ "$actual_conflicts" = "$f" ] || {
                  echo 'FAIL_AUDIT_PARENT_CONFLICT_FILES' >&2
                  printf 'EXPECTED:%s\nACTUAL_BEGIN\n%s\nACTUAL_END\n' "$f" "$actual_conflicts" >&2
                  exit 52
                }
                expected_commit_files="$(printf '%s\n' \
                  'fs/namei.c' \
                  'include/linux/namei.h' \
                  'kernel/audit_fsnotify.c' \
                  'kernel/audit_watch.c' | sort)"
                commit_files="$(git diff-tree --no-commit-id --name-only -r "$c" | sort)"
                [ "$commit_files" = "$expected_commit_files" ] || {
                  echo 'FAIL_AUDIT_PARENT_COMMIT_FILES' >&2
                  printf 'EXPECTED_BEGIN\n%s\nEXPECTED_END\nACTUAL_BEGIN\n%s\nACTUAL_END\n' \
                    "$expected_commit_files" "$commit_files" >&2
                  exit 52
                }

                ours="$(mktemp)"
                theirs="$(mktemp)"
                git show ":2:$f" > "$ours" || { rm -f "$ours" "$theirs"; exit 52; }
                git show ":3:$f" > "$theirs" || { rm -f "$ours" "$theirs"; exit 52; }

                python3 - "$ours" "$theirs" <<'PYAUDITPARENT'
from pathlib import Path
import re
import sys

ours_p = Path(sys.argv[1])
theirs_p = Path(sys.argv[2])
ours = ours_p.read_text()
theirs = theirs_p.read_text()

old_lookup = "\tdentry = kern_path_locked(pathname, &path);\n"
if ours.count(old_lookup) != 1:
    raise SystemExit(f"FAIL_AUDIT_PARENT_OURS_LOOKUP=count={ours.count(old_lookup)}")
if "kern_path_parent(pathname, &path)" in ours:
    raise SystemExit("FAIL_AUDIT_PARENT_OURS_ALREADY_PARENT")
inode_decl = "\tstruct inode *inode;\n"
if ours.count(inode_decl) != 1:
    raise SystemExit(f"FAIL_AUDIT_PARENT_OURS_INODE_DECL=count={ours.count(inode_decl)}")
unlock = "\tinode = path.dentry->d_inode;\n\tinode_unlock(inode);\n"
if ours.count(unlock) != 1:
    raise SystemExit(f"FAIL_AUDIT_PARENT_OURS_UNLOCK=count={ours.count(unlock)}")

parent_lookup = "\tdentry = kern_path_parent(pathname, &path);\n"
if theirs.count(parent_lookup) != 1:
    raise SystemExit(f"FAIL_AUDIT_PARENT_THEIRS_LOOKUP=count={theirs.count(parent_lookup)}")
if "inode_unlock(inode);" in theirs:
    raise SystemExit("FAIL_AUDIT_PARENT_THEIRS_STILL_UNLOCKS")

helpers = [
    h for h in ("d_really_is_negative", "d_is_negative")
    if f"\tif ({h}(dentry)) {{\n" in theirs
]
if len(helpers) != 1:
    raise SystemExit(f"FAIL_AUDIT_PARENT_THEIRS_NEGATIVE_HELPER={helpers}")
helper = helpers[0]
negative_block = (
    f"\tif ({helper}(dentry)) {{\n"
    "\t\taudit_mark = ERR_PTR(-ENOENT);\n"
    "\t\tgoto out;\n"
    "\t}\n"
)
if theirs.count(negative_block) != 1:
    raise SystemExit("FAIL_AUDIT_PARENT_THEIRS_NEGATIVE_BLOCK")

pat = re.compile(
    r"^\tret = fsnotify_add_inode_mark\(&audit_mark->mark, inode, (true|0)\);$",
    re.M,
)
matches = pat.findall(ours)
if len(matches) != 1:
    raise SystemExit(f"FAIL_AUDIT_PARENT_OURS_ADD_MARK={matches}")
allow_dups = matches[0]

out = ours
out = out.replace(inode_decl, "", 1)
out = out.replace(old_lookup, parent_lookup, 1)
out = out.replace(unlock, negative_block, 1)
old_add = f"\tret = fsnotify_add_inode_mark(&audit_mark->mark, inode, {allow_dups});"
new_add = (
    "\tret = fsnotify_add_inode_mark(&audit_mark->mark, "
    f"path.dentry->d_inode, {allow_dups});"
)
if out.count(old_add) != 1:
    raise SystemExit(f"FAIL_AUDIT_PARENT_OURS_ADD_REPLACE=count={out.count(old_add)}")
out = out.replace(old_add, new_add, 1)

if any(x in out for x in ("<<<<<<<", "=======", ">>>>>>>")):
    raise SystemExit("FAIL_AUDIT_PARENT_MARKERS")
if out.count(parent_lookup) != 1 or old_lookup in out:
    raise SystemExit("FAIL_AUDIT_PARENT_POST_LOOKUP")
if "inode_unlock(inode);" in out or "\tstruct inode *inode;\n" in out:
    raise SystemExit("FAIL_AUDIT_PARENT_POST_INODE")
if out.count(negative_block) != 1:
    raise SystemExit("FAIL_AUDIT_PARENT_POST_NEGATIVE")
if out.count(new_add) != 1:
    raise SystemExit("FAIL_AUDIT_PARENT_POST_ADD_MARK")

ours_p.write_text(out)
print(f"AUDIT_PARENT_NEGATIVE_HELPER={helper}")
print(f"AUDIT_PARENT_PRESERVED_ALLOW_DUPS={allow_dups}")
PYAUDITPARENT

                cp "$ours" "$f"
                rm -f "$ours" "$theirs"
                git add -- "$f"

                staged="$(git diff --cached --name-only | sort)"
                unexpected="$(comm -23 <(printf '%s\n' "$staged") <(printf '%s\n' "$expected_commit_files"))"
                [ -z "$unexpected" ] || {
                  echo 'FAIL_AUDIT_PARENT_UNEXPECTED_STAGED_FILES' >&2
                  printf '%s\n' "$unexpected" >&2
                  exit 52
                }
                grep -Fxq "$f" <<< "$staged" || {
                  echo 'FAIL_AUDIT_PARENT_TARGET_NOT_STAGED' >&2
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
print("V3_RESUME_AND_NARROW_RESOLVERS_APPLIED=1")
