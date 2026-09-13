#!/usr/bin/env python3
from pathlib import Path
import sys

if len(sys.argv) != 2:
    raise SystemExit("usage: ticwatch-uplift-v3-lsm-default.py /tmp/uplift.sh")

p = Path(sys.argv[1])
s = p.read_text()

anchor = '''    echo "FIRST_CONFLICT_TAG=$tag"
    echo "FIRST_CONFLICT_COMMIT=$c"
    echo "FIRST_CONFLICT_SUBJECT=$subject"'''

resolver = r'''              # v5.15.217: b03e46bf changes call_int_hook() to use each
              # hook's LSM_RET_DEFAULT() as the continue value. Android/TicWatch
              # carries local security.c API/layout differences, so do not take the
              # whole stable file. Preserve Android's file and apply the semantic
              # change mechanically. Explicit non-default initial return values use
              # a local call_int_hook_init() compatibility macro with the same new
              # stop condition; this is equivalent to stable's open-coded loops and
              # avoids deleting Android-only arguments/functions.
              if [ "$tag" = 'v5.15.217' ] && [ "$c" = 'b03e46bf01d03163a92acb260679d3ac0e767e47' ]; then
                f='security/security.c'
                [ "$subject" = 'lsm: use default hook return value in call_int_hook()' ] || {
                  echo "FAIL_LSM_DEFAULT_SUBJECT=$subject" >&2
                  exit 55
                }
                conflicts="$(git diff --name-only --diff-filter=U)"
                [ "$conflicts" = "$f" ] || {
                  echo 'FAIL_LSM_DEFAULT_CONFLICT_FILES' >&2
                  printf 'EXPECTED:%s\nACTUAL_BEGIN\n%s\nACTUAL_END\n' "$f" "$conflicts" >&2
                  exit 55
                }

                git checkout --ours -- "$f"
                python3 - "$f" <<'PYLSMDEFAULT'
from pathlib import Path
import sys

p = Path(sys.argv[1])
s = p.read_text()

if s.count('#define LSM_RET_DEFAULT(NAME) (NAME##_default)') != 1:
    raise SystemExit('FAIL_LSM_DEFAULT_INFRA')
if s.count('#define call_int_hook(FUNC, IRC, ...)') != 1:
    raise SystemExit(f'FAIL_LSM_DEFAULT_OLD_MACRO=count={s.count("#define call_int_hook(FUNC, IRC, ...)")}')
if '#define call_int_hook_init(FUNC, IRC, ...)' in s:
    raise SystemExit('FAIL_LSM_DEFAULT_INIT_ALREADY_PRESENT')

old_macro_start = s.index('#define call_int_hook(FUNC, IRC, ...)')
security_ops = s.index('\n/* Security operations */', old_macro_start)
old_macro = s[old_macro_start:security_ops]

if 'int RC = IRC;' not in old_macro:
    raise SystemExit('FAIL_LSM_DEFAULT_OLD_RC_INIT')
if 'if (RC != 0)' not in old_macro:
    raise SystemExit('FAIL_LSM_DEFAULT_OLD_STOP')
if old_macro.count('RC = P->hook.FUNC(__VA_ARGS__);') != 1:
    raise SystemExit('FAIL_LSM_DEFAULT_OLD_HOOK_CALL')

new_macro = old_macro
new_macro = new_macro.replace('#define call_int_hook(FUNC, IRC, ...)',
                              '#define call_int_hook(FUNC, ...)', 1)
new_macro = new_macro.replace('int RC = IRC;',
                              'int RC = LSM_RET_DEFAULT(FUNC);', 1)
new_macro = new_macro.replace('if (RC != 0)',
                              'if (RC != LSM_RET_DEFAULT(FUNC))', 1)

init_macro = old_macro
init_macro = init_macro.replace('#define call_int_hook(FUNC, IRC, ...)',
                                '#define call_int_hook_init(FUNC, IRC, ...)', 1)
init_macro = init_macro.replace('if (RC != 0)',
                                'if (RC != LSM_RET_DEFAULT(FUNC))', 1)

s = s[:old_macro_start] + new_macro + init_macro + s[security_ops:]

ops = s.index('\n/* Security operations */')
tail = s[ops:]
needle = 'call_int_hook('

def top_level_commas(text, open_pos):
    depth = 1
    commas = []
    i = open_pos + 1
    quote = None
    escape = False
    while i < len(text):
        ch = text[i]
        if quote is not None:
            if escape:
                escape = False
            elif ch == '\\':
                escape = True
            elif ch == quote:
                quote = None
            i += 1
            continue
        if ch in ('"', "'"):
            quote = ch
        elif ch == '(':
            depth += 1
        elif ch == ')':
            depth -= 1
            if depth == 0:
                return commas, i
        elif ch == ',' and depth == 1:
            commas.append(i)
        i += 1
    raise SystemExit('FAIL_LSM_DEFAULT_UNBALANCED_CALL')

edits = []
pos = 0
zero_calls = 0
init_calls = 0
all_calls = 0
zero_arg_hooks = 0
while True:
    pos = tail.find(needle, pos)
    if pos < 0:
        break
    open_pos = pos + len('call_int_hook')
    commas, close_pos = top_level_commas(tail, open_pos)
    if len(commas) < 1:
        raise SystemExit(f'FAIL_LSM_DEFAULT_CALL_ARGS_AT={pos}')

    # Old form is call_int_hook(FUNC, IRC[, hook args...]). Some LSM hooks
    # take no arguments, so a valid old invocation can have only one comma.
    arg2_end = commas[1] if len(commas) >= 2 else close_pos
    arg2 = tail[commas[0] + 1:arg2_end].strip()
    all_calls += 1
    if arg2 == '0':
        if len(commas) >= 2:
            edits.append((commas[0], commas[1] + 1, ','))
        else:
            # call_int_hook(foo, 0) -> call_int_hook(foo)
            edits.append((commas[0], close_pos, ''))
            zero_arg_hooks += 1
        zero_calls += 1
    else:
        edits.append((pos, pos + len('call_int_hook'), 'call_int_hook_init'))
        init_calls += 1
    pos = close_pos + 1

if all_calls < 20:
    raise SystemExit(f'FAIL_LSM_DEFAULT_TOO_FEW_CALLS={all_calls}')
if zero_calls < 10:
    raise SystemExit(f'FAIL_LSM_DEFAULT_TOO_FEW_ZERO_CALLS={zero_calls}')
if init_calls < 1:
    raise SystemExit('FAIL_LSM_DEFAULT_NO_EXPLICIT_INIT_CALLS')

for a, b, repl in reversed(edits):
    tail = tail[:a] + repl + tail[b:]
s = s[:ops] + tail

if '#define call_int_hook(FUNC, IRC, ...)' in s:
    raise SystemExit('FAIL_LSM_DEFAULT_OLD_MACRO_REMAINS')
if s.count('#define call_int_hook(FUNC, ...)') != 1:
    raise SystemExit('FAIL_LSM_DEFAULT_NEW_MACRO_COUNT')
if s.count('#define call_int_hook_init(FUNC, IRC, ...)') != 1:
    raise SystemExit('FAIL_LSM_DEFAULT_INIT_MACRO_COUNT')
if s.count('if (RC != LSM_RET_DEFAULT(FUNC))') < 2:
    raise SystemExit('FAIL_LSM_DEFAULT_STOP_CONDITION')
if any(m in s for m in ('<<<<<<<', '=======', '>>>>>>>')):
    raise SystemExit('FAIL_LSM_DEFAULT_MARKERS')

if 'const char **xattr_name' not in s:
    raise SystemExit('FAIL_LSM_DEFAULT_ANDROID_DENTRY_API_LOST')
if 'call_int_hook_init(sb_add_mnt_opt,' not in s or '-EINVAL' not in s:
    raise SystemExit('FAIL_LSM_DEFAULT_SB_ADD_MNT_OPT')
if 'call_int_hook_init(inode_init_security,' not in s:
    raise SystemExit('FAIL_LSM_DEFAULT_INODE_INIT_COMPAT')

p.write_text(s)
print(f'LSM_DEFAULT_ANDROID_PATCHED=1 CALLS={all_calls} DEFAULT={zero_calls} EXPLICIT_INIT={init_calls} ZERO_ARG_HOOKS={zero_arg_hooks}')
PYLSMDEFAULT

                git add -- "$f"
                [ -z "$(git diff --name-only --diff-filter=U)" ] || {
                  echo 'FAIL_LSM_DEFAULT_UNMERGED_REMAIN' >&2
                  git diff --name-only --diff-filter=U >&2
                  exit 55
                }
                git diff --cached --check || exit 55
                git -c user.name='TicWatch LTS CI' -c user.email='ci@local' cherry-pick --continue || exit 55
                grep -Fq '#define call_int_hook(FUNC, ...)' "$f" || exit 55
                grep -Fq '#define call_int_hook_init(FUNC, IRC, ...)' "$f" || exit 55
                grep -Fq 'if (RC != LSM_RET_DEFAULT(FUNC))' "$f" || exit 55
                ! grep -Fq '#define call_int_hook(FUNC, IRC, ...)' "$f" || exit 55
                echo "ANDROID_TICWATCH_LSM_DEFAULT_RESOLVED=$c FILE=$f"
                continue
              fi

'''

if s.count(anchor) != 1:
    raise SystemExit(f"FAIL_LSM_DEFAULT_ANCHOR=count={s.count(anchor)}")
s = s.replace(anchor, resolver + anchor, 1)

p.write_text(s)
print("V3_LSM_DEFAULT_COMPAT_APPLIED=1")
