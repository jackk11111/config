#!/usr/bin/env python3
from pathlib import Path
import sys

if len(sys.argv) != 2:
    raise SystemExit("usage: ticwatch-uplift-v3-bpf-fork.py /tmp/uplift.sh")

p = Path(sys.argv[1])
s = p.read_text()

anchor = '''    echo "FIRST_CONFLICT_TAG=$tag"
    echo "FIRST_CONFLICT_COMMIT=$c"
    echo "FIRST_CONFLICT_SUBJECT=$subject"'''

resolver = r'''              # v5.15.217: move BPF task-local-storage initialization into
              # dup_task_struct(), before copy_process() can bail out and free the
              # partially created task. Preserve Android vendor/OEM task hooks and
              # move only the two upstream assignments.
              if [ "$tag" = 'v5.15.217' ] && [ "$c" = '7df67a4799067a59e6a2d53f8059a6be6e73e678' ]; then
                f='kernel/fork.c'
                [ "$subject" = 'bpf,fork: wipe ->bpf_storage before bailouts that access it' ] || {
                  echo "FAIL_BPF_FORK_SUBJECT=$subject" >&2
                  exit 56
                }
                conflicts="$(git diff --name-only --diff-filter=U)"
                [ "$conflicts" = "$f" ] || {
                  echo 'FAIL_BPF_FORK_CONFLICT_FILES' >&2
                  printf 'EXPECTED:%s\nACTUAL_BEGIN\n%s\nACTUAL_END\n' "$f" "$conflicts" >&2
                  exit 56
                }

                git checkout --ours -- "$f"
                python3 - "$f" <<'PYBPFFORK'
from pathlib import Path
import sys

p = Path(sys.argv[1])
s = p.read_text()

old_late = """#ifdef CONFIG_BPF_SYSCALL
\tRCU_INIT_POINTER(p->bpf_storage, NULL);
\tp->bpf_ctx = NULL;
#endif
"""
new_early = """#ifdef CONFIG_BPF_SYSCALL
\tRCU_INIT_POINTER(tsk->bpf_storage, NULL);
\ttsk->bpf_ctx = NULL;
#endif
"""

if s.count(old_late) != 1:
    raise SystemExit(f'FAIL_BPF_FORK_LATE_BLOCK=count={s.count(old_late)}')
if s.count(new_early) != 0:
    raise SystemExit('FAIL_BPF_FORK_EARLY_ALREADY_PRESENT')

sig = 'static struct task_struct *dup_task_struct(struct task_struct *orig, int node)'
start = s.find(sig)
if start < 0:
    raise SystemExit('FAIL_BPF_FORK_DUP_FUNCTION')
ret = s.find('\n\treturn tsk;', start)
if ret < 0:
    raise SystemExit('FAIL_BPF_FORK_DUP_RETURN')
fn = s[start:ret]

memcg = """#ifdef CONFIG_MEMCG
\ttsk->active_memcg = NULL;
#endif
"""
if fn.count(memcg) != 1:
    raise SystemExit(f'FAIL_BPF_FORK_MEMCG_ANCHOR=count={fn.count(memcg)}')
if 'trace_android_vh_dup_task_struct(tsk, orig);' not in fn:
    raise SystemExit('FAIL_BPF_FORK_ANDROID_VENDOR_HOOK')
if '#ifdef CONFIG_ANDROID_VENDOR_OEM_DATA' not in fn:
    raise SystemExit('FAIL_BPF_FORK_ANDROID_VENDOR_DATA')

fn = fn.replace(memcg, memcg + '\n' + new_early, 1)
s = s[:start] + fn + s[ret:]
s = s.replace(old_late, '', 1)

if s.count(new_early) != 1:
    raise SystemExit('FAIL_BPF_FORK_EARLY_POST')
if s.count(old_late) != 0:
    raise SystemExit('FAIL_BPF_FORK_LATE_REMAINS')
if any(m in s for m in ('<<<<<<<', '=======', '>>>>>>>')):
    raise SystemExit('FAIL_BPF_FORK_MARKERS')

start = s.index(sig)
ret = s.index('\n\treturn tsk;', start)
fn = s[start:ret]
if not (fn.index('RCU_INIT_POINTER(tsk->bpf_storage, NULL);') <
        fn.index('#ifdef CONFIG_ANDROID_VENDOR_OEM_DATA') <
        fn.index('trace_android_vh_dup_task_struct(tsk, orig);')):
    raise SystemExit('FAIL_BPF_FORK_ORDER')

p.write_text(s)
print('BPF_FORK_ANDROID_PATCHED=1')
PYBPFFORK

                git add -- "$f"
                [ -z "$(git diff --name-only --diff-filter=U)" ] || {
                  echo 'FAIL_BPF_FORK_UNMERGED_REMAIN' >&2
                  git diff --name-only --diff-filter=U >&2
                  exit 56
                }
                git diff --cached --check || exit 56
                git -c user.name='TicWatch LTS CI' -c user.email='ci@local' cherry-pick --continue || exit 56
                grep -Fq 'RCU_INIT_POINTER(tsk->bpf_storage, NULL);' "$f" || exit 56
                ! grep -Fq 'RCU_INIT_POINTER(p->bpf_storage, NULL);' "$f" || exit 56
                grep -Fq 'trace_android_vh_dup_task_struct(tsk, orig);' "$f" || exit 56
                echo "ANDROID_TICWATCH_BPF_FORK_RESOLVED=$c FILE=$f"
                continue
              fi

'''

diagnostics = r'''    echo "CONFLICT_CC_DIFF_BEGIN"
    git diff --cc --unified=20 -- $conflicts || true
    echo "CONFLICT_CC_DIFF_END"
    for conflict_file in $conflicts; do
      echo "CONFLICT_MARKERS_FILE_BEGIN=$conflict_file"
      python3 - "$conflict_file" <<'PYCONFLICTDIAG'
from pathlib import Path
import sys

p = Path(sys.argv[1])
try:
    lines = p.read_text(errors='replace').splitlines()
except Exception as e:
    print(f'DIAG_READ_ERROR={e}')
    raise SystemExit(0)
markers = [i for i, line in enumerate(lines) if line.startswith('<<<<<<<')]
print(f'CONFLICT_HUNK_COUNT={len(markers)}')
for n, i in enumerate(markers, 1):
    lo = max(0, i - 20)
    j = i
    while j < len(lines) and not lines[j].startswith('>>>>>>>'):
        j += 1
    hi = min(len(lines), j + 21)
    print(f'--- CONFLICT_HUNK_{n}_LINES_{lo+1}_{hi} ---')
    for k in range(lo, hi):
        print(f'{k+1:06d}: {lines[k]}')
PYCONFLICTDIAG
      echo "CONFLICT_MARKERS_FILE_END=$conflict_file"
    done
'''

if s.count(anchor) != 1:
    raise SystemExit(f"FAIL_BPF_FORK_ANCHOR=count={s.count(anchor)}")
s = s.replace(anchor, resolver + diagnostics + anchor, 1)

p.write_text(s)
print("V3_BPF_FORK_COMPAT_APPLIED=1")
print("V3_CONFLICT_DIAGNOSTICS_APPLIED=1")
