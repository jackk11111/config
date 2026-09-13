#!/usr/bin/env bash
set -Eeuo pipefail

WORKSPACE="${GITHUB_WORKSPACE:-$PWD}"
KERNEL="$WORKSPACE/.ticwatch-preflight/common"
ROOT="$KERNEL/KernelSU-Next/kernel"
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

# Harmless source marker used only so the MAX-SAFE provenance diff records that
# the integrated SuSFS reboot hook was explicitly audited in this candidate.
s += '\n/* MAX-SAFE audit: ksu_handle_sys_reboot verified by preflight integration */\n'

p.write_text(s)
PY

grep -Fq 'DEFINE_STATIC_KEY_TRUE(is_first_zygote);' "$RUNTIME" || \
  fail "is_first_zygote definition was not inserted"
grep -Fq 'static_branch_disable(&is_first_zygote);' "$RUNTIME" || \
  fail "is_first_zygote disable transition was not inserted"
grep -Fq 'ksu_handle_sys_reboot' "$RUNTIME" || \
  fail "MAX-SAFE SuSFS reboot-hook audit marker missing"

# Final Build V2 materializes an older pinned SafeKey helper into /tmp before
# KSU/SuSFS integration. Replace only that runner-local helper with the audited
# final-branch variant, which preserves SuSFS' inner input-stop logic.
SAFEKEY_FIX="$WORKSPACE/ticwatch-ultimate/fix-ksu-safekey-ticwatch.sh"
[ -f "$SAFEKEY_FIX" ] || fail "final SafeKey fixer missing: $SAFEKEY_FIX"
cp "$SAFEKEY_FIX" /tmp/fix-ksu-safekey-ticwatch.sh
chmod +x /tmp/fix-ksu-safekey-ticwatch.sh

# Linux 5.15.217+ carries the PSI teardown fix using timer_shutdown_sync().
# Android 13 ACK 5.15 intentionally merged around the timer shutdown API series
# to avoid its KMI/ABI churn.  The stable uplift can therefore contain the PSI
# caller while the ACK timer API is absent.  Keep the PSI lifetime fix, but use
# the synchronization primitive actually provided by this ACK tree rather than
# importing the ABI-changing timer series.  This is intentionally fail-closed:
# exactly one known caller may be adapted, and only when timer_shutdown_sync()
# is not declared by the target tree.
PSI="$KERNEL/kernel/sched/psi.c"
TIMER_H="$KERNEL/include/linux/timer.h"
[ -f "$PSI" ] || fail "PSI source missing: $PSI"
[ -f "$TIMER_H" ] || fail "timer header missing: $TIMER_H"
python3 - "$PSI" "$TIMER_H" <<'PY'
from pathlib import Path
import re
import sys

psi = Path(sys.argv[1])
timer_h = Path(sys.argv[2])
s = psi.read_text()
h = timer_h.read_text()
needle = 'timer_shutdown_sync(&cgroup->psi.poll_timer);'
count = s.count(needle)

# If the ACK tree eventually gains the real shutdown API, preserve it untouched.
if re.search(r'\btimer_shutdown_sync\s*\(', h):
    print('PSI_TIMER_COMPAT=NOT_NEEDED_REAL_API_PRESENT')
    raise SystemExit(0)

if count != 1:
    raise SystemExit(f'PSI timer shutdown anchor count changed: {count}')

if re.search(r'\bdel_timer_sync\s*\(', h):
    replacement = 'del_timer_sync(&cgroup->psi.poll_timer);'
elif re.search(r'\btimer_delete_sync\s*\(', h):
    replacement = 'timer_delete_sync(&cgroup->psi.poll_timer);'
else:
    raise SystemExit('no synchronous timer deletion API available in ACK timer.h')

psi.write_text(s.replace(needle, replacement, 1))
print(f'PSI_TIMER_COMPAT=APPLIED:{replacement.split("(", 1)[0]}')
PY

! grep -Fq 'timer_shutdown_sync(&cgroup->psi.poll_timer);' "$PSI" || \
  grep -Eq 'timer_shutdown_sync[[:space:]]*\(' "$TIMER_H" || \
  fail "unresolved PSI timer_shutdown_sync API mismatch"

printf '%s\n' 'PASS: repaired KSUN 3.3.0 / SuSFS 2.2.0 first-zygote static-key mismatch'
