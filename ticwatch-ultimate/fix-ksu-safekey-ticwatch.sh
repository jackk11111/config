#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${1:-.ticwatch-preflight/common/KernelSU-Next/kernel}"
F="$ROOT/runtime/ksud_integration.c"
[ -f "$F" ] || { echo "FAIL: KSU runtime missing: $F" >&2; exit 1; }

python3 - "$F" <<'PY'
from pathlib import Path
import sys

p = Path(sys.argv[1])
s = p.read_text()

old_cond = '    if (*type == EV_KEY && *code == KEY_VOLUMEDOWN) {\n'
new_cond = '    if (*type == EV_KEY && (*code == KEY_VOLUMEDOWN || *code == KEY_MENU)) {\n'
old_log = '        pr_info("KEY_VOLUMEDOWN val: %d\\n", val);\n'
new_log = '        pr_info("KSU safe key code=%u val=%d\\n", *code, val);\n'
old_val = '        if (val) {\n'
new_val = '        if (val == 1) {\n'

# Idempotent only for the exact policy we want.
if new_cond in s and new_val in s:
    print('PASS: TicWatch SafeKey already hardened')
else:
    if s.count(old_cond) != 1:
        raise SystemExit('KSU safe-key condition anchor changed; re-audit before patching')

    start = s.index(old_cond)
    end = min(len(s), start + 900)
    chunk = s[start:end]

    # The SuSFS compatibility patch changes the inner stop-hook logic below this
    # point.  Do not replace that whole block; change only the key condition,
    # diagnostic and real key-down test, preserving the integrated logic exactly.
    if chunk.count(old_log) != 1:
        raise SystemExit('KSU safe-key log anchor changed; re-audit before patching')
    if chunk.count(old_val) != 1:
        raise SystemExit('KSU safe-key value anchor changed; re-audit before patching')

    chunk = chunk.replace(old_cond, new_cond, 1)
    chunk = chunk.replace(old_log, new_log, 1)
    chunk = chunk.replace(old_val, new_val, 1)
    s = s[:start] + chunk + s[end:]
    p.write_text(s)

s = p.read_text()
if s.count(new_cond) != 1:
    raise SystemExit('SafeKey final key-condition verification failed')
if s.count(new_val) < 1:
    raise SystemExit('SafeKey final real-key-down verification failed')
PY

grep -Fq '(*code == KEY_VOLUMEDOWN || *code == KEY_MENU)' "$F"
grep -Fq 'if (val == 1)' "$F"
printf '%s\n' 'PASS: TicWatch KSU safe key = VolumeDown or crown(KEY_MENU), real key-down only; integrated stop-hook logic preserved'
