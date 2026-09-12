#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${1:-.ticwatch-preflight/common/KernelSU-Next/kernel}"
F="$ROOT/runtime/ksud_integration.c"
[ -f "$F" ] || { echo "FAIL: KSU runtime missing: $F" >&2; exit 1; }

python3 - "$F" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
s=p.read_text()
old='''    if (*type == EV_KEY && *code == KEY_VOLUMEDOWN) {\n        int val = *value;\n        pr_info("KEY_VOLUMEDOWN val: %d\\n", val);\n        if (val) {\n            // key pressed, count it\n            volumedown_pressed_count += 1;\n            if (is_volumedown_enough(volumedown_pressed_count)) {\n                ksu_stop_input_hook_runtime();\n            }\n        }\n    }\n'''
new='''    if (*type == EV_KEY && (*code == KEY_VOLUMEDOWN || *code == KEY_MENU)) {\n        int val = *value;\n        pr_info("KSU safe key code=%u val=%d\\n", *code, val);\n        if (val == 1) {\n            // Count real key-down events only. Ignore key-up (0) and autorepeat (2).\n            volumedown_pressed_count += 1;\n            if (is_volumedown_enough(volumedown_pressed_count)) {\n                ksu_stop_input_hook_runtime();\n            }\n        }\n    }\n'''
if old not in s:
    raise SystemExit('KSU safe-key anchor changed; re-audit before patching')
s=s.replace(old,new,1)
p.write_text(s)
PY

grep -Fq '(*code == KEY_VOLUMEDOWN || *code == KEY_MENU)' "$F"
grep -Fq 'if (val == 1)' "$F"
printf '%s\n' 'PASS: TicWatch KSU safe key = VolumeDown or crown(KEY_MENU), real key-down only'
