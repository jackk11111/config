#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${GITHUB_WORKSPACE:-$PWD}/.ticwatch-preflight/common/KernelSU-Next/kernel"
RUNTIME="$ROOT/runtime/ksud_integration.c"
SUCOMPAT="$ROOT/feature/sucompat.c"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

[ -f "$RUNTIME" ] || fail "patched KSU runtime not found: $RUNTIME"
[ -f "$SUCOMPAT" ] || fail "patched KSU sucompat not found: $SUCOMPAT"

grep -Fq 'extern struct static_key_true is_first_zygote;' "$SUCOMPAT" || \
  fail "SuSFS compatibility caller does not reference is_first_zygote as expected"
grep -Fq 'static_branch_unlikely(&is_first_zygote)' "$SUCOMPAT" || \
  fail "SuSFS compatibility caller does not gate ksud on is_first_zygote"

if grep -Fq 'DEFINE_STATIC_KEY_TRUE(is_first_zygote);' "$RUNTIME"; then
  fail "is_first_zygote is already defined; pinned patch state changed, re-audit required"
fi

[ "$(grep -Fxc 'DEFINE_STATIC_KEY_TRUE(ksu_is_input_hook_enabled);' "$RUNTIME")" -eq 1 ] || \
  fail "unexpected KSU runtime static-key anchor"
[ "$(grep -Fxc '    static bool first_zygote = true;' "$RUNTIME")" -eq 1 ] || \
  fail "unexpected first_zygote state layout"
[ "$(grep -Fxc '            first_zygote = false;' "$RUNTIME")" -eq 1 ] || \
  fail "unexpected first_zygote transition layout"

python3 - "$RUNTIME" <<'PY'
from pathlib import Path
import sys

p = Path(sys.argv[1])
s = p.read_text()

anchor = 'DEFINE_STATIC_KEY_TRUE(ksu_is_input_hook_enabled);\n'
definition = anchor + 'DEFINE_STATIC_KEY_TRUE(is_first_zygote);\n'
if s.count(anchor) != 1:
    raise SystemExit('unexpected static-key insertion anchor count')
s = s.replace(anchor, definition, 1)

old = '            first_zygote = false;\n'
new = old + '            static_branch_disable(&is_first_zygote);\n'
if s.count(old) != 1:
    raise SystemExit('unexpected first_zygote disable anchor count')
s = s.replace(old, new, 1)

p.write_text(s)
PY

grep -Fq 'DEFINE_STATIC_KEY_TRUE(is_first_zygote);' "$RUNTIME" || \
  fail "is_first_zygote definition was not inserted"
grep -Fq 'static_branch_disable(&is_first_zygote);' "$RUNTIME" || \
  fail "is_first_zygote disable transition was not inserted"

printf '%s\n' 'PASS: repaired KSUN 3.3.0 / SuSFS 2.2.0 first-zygote static-key mismatch'
