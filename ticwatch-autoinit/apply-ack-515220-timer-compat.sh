#!/usr/bin/env bash
set -Eeuo pipefail
WORKSPACE="${GITHUB_WORKSPACE:-$PWD}"
KERNEL="${1:-$WORKSPACE/.ticwatch-preflight/common}"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# Android 13 ACK 5.15 deliberately merged around the upstream timer shutdown
# API series because of KMI/ABI churn. Stable 5.15.217-220 later gained callers
# of timer_shutdown_sync(), so an incremental stable uplift can contain those
# callers without the ACK timer API. Adapt only the known callers when the real
# API is absent. Do not import the ABI-changing timer core series.
TIMER_H="$KERNEL/include/linux/timer.h"
PSI="$KERNEL/kernel/sched/psi.c"
BRIDGE="$KERNEL/net/bridge/br_if.c"
UCLOGIC="$KERNEL/drivers/hid/hid-uclogic-core.c"
for f in "$TIMER_H" "$PSI" "$BRIDGE" "$UCLOGIC"; do
  [ -f "$f" ] || fail "timer compatibility source missing: $f"
done

python3 - "$TIMER_H" "$PSI" "$BRIDGE" "$UCLOGIC" <<'PY'
from pathlib import Path
import re
import sys

timer_h = Path(sys.argv[1])
psi = Path(sys.argv[2])
bridge = Path(sys.argv[3])
uclogic = Path(sys.argv[4])
h = timer_h.read_text()

# A real declaration/definition means no compatibility surgery is needed.
if re.search(r'(?m)^\s*(?:extern\s+)?(?:int|void)\s+timer_shutdown_sync\s*\(', h):
    print('ACK_TIMER_COMPAT=NOT_NEEDED_REAL_API_PRESENT')
    raise SystemExit(0)

if re.search(r'\bdel_timer_sync\s*\(', h):
    sync_fn = 'del_timer_sync'
elif re.search(r'\btimer_delete_sync\s*\(', h):
    sync_fn = 'timer_delete_sync'
else:
    raise SystemExit('no synchronous timer deletion API available in ACK timer.h')

# 1) PSI: by psi_cgroup_free() nothing can arm poll_timer again. A synchronous
# delete therefore has the needed lifetime semantics without timer-core ABI
# changes. Require exactly the known stable caller.
s = psi.read_text()
needle = 'timer_shutdown_sync(&cgroup->psi.poll_timer);'
count = s.count(needle)
if count == 1:
    s = s.replace(needle, f'{sync_fn}(&cgroup->psi.poll_timer);', 1)
    psi.write_text(s)
    print(f'PSI_TIMER_COMPAT=APPLIED:{sync_fn}')
elif count == 0 and f'{sync_fn}(&cgroup->psi.poll_timer);' in s:
    print('PSI_TIMER_COMPAT=ALREADY_APPLIED')
else:
    raise SystemExit(f'PSI timer shutdown anchor count changed: {count}')

# 2) Bridge: br_dev_delete() is already past port/rx teardown and under RTNL;
# no legal re-arm remains. This is the ABI-safe backport used by older trees.
s = bridge.read_text()
bridge_needles = [
    'timer_shutdown_sync(&br->hello_timer);',
    'timer_shutdown_sync(&br->topology_change_timer);',
    'timer_shutdown_sync(&br->tcn_timer);',
]
present = sum(s.count(x) for x in bridge_needles)
if present == 3:
    for old in bridge_needles:
        s = s.replace(old, old.replace('timer_shutdown_sync', sync_fn), 1)
    bridge.write_text(s)
    print(f'BRIDGE_TIMER_COMPAT=APPLIED:{sync_fn}:3')
elif present == 0:
    print('BRIDGE_TIMER_COMPAT=NOT_PRESENT_OR_ALREADY_ADAPTED')
else:
    raise SystemExit(f'bridge timer shutdown anchors partially present: {present}/3')

# 3) UC-Logic: plain del_timer_sync is NOT equivalent because reports can race
# and re-arm the timer before hid_hw_stop(). Backport timer-shutdown semantics
# locally: serialize every re-arm with a private spinlock and set a permanent
# shutdown flag before the synchronous delete. This preserves the security fix
# without exporting/changing timer-core ABI.
s = uclogic.read_text()
shutdown_call = 'timer_shutdown_sync(&drvdata->inrange_timer);'
if shutdown_call in s:
    if s.count(shutdown_call) != 1:
        raise SystemExit('unexpected UC-Logic timer_shutdown_sync count')
    if s.count('mod_timer(&drvdata->inrange_timer,') != 1:
        raise SystemExit('unexpected UC-Logic inrange mod_timer count')

    inc = '#include <linux/module.h>\n'
    if s.count(inc) != 1:
        raise SystemExit('UC-Logic module include anchor changed')
    s = s.replace(inc, inc + '#include <linux/spinlock.h>\n', 1)

    field = '\tstruct timer_list inrange_timer;\n'
    if s.count(field) != 1:
        raise SystemExit('UC-Logic timer field anchor changed')
    s = s.replace(
        field,
        field + '\t/* ACK-local timer shutdown no-rearm state. */\n'
                '\tspinlock_t inrange_timer_lock;\n'
                '\tbool inrange_timer_shutdown;\n',
        1,
    )

    timeout_end = '''\tinput_report_key(input, BTN_TOOL_PEN, 0);\n\tinput_sync(input);\n}\n\n'''
    if s.count(timeout_end) != 1:
        raise SystemExit('UC-Logic timeout helper insertion anchor changed')
    helpers = '''\tinput_report_key(input, BTN_TOOL_PEN, 0);\n\tinput_sync(input);\n}\n\nstatic void uclogic_inrange_timer_mod(struct uclogic_drvdata *drvdata)\n{\n\tunsigned long flags;\n\n\tspin_lock_irqsave(&drvdata->inrange_timer_lock, flags);\n\tif (!drvdata->inrange_timer_shutdown)\n\t\tmod_timer(&drvdata->inrange_timer,\n\t\t\t  jiffies + msecs_to_jiffies(100));\n\tspin_unlock_irqrestore(&drvdata->inrange_timer_lock, flags);\n}\n\nstatic void uclogic_inrange_timer_shutdown(struct uclogic_drvdata *drvdata)\n{\n\tunsigned long flags;\n\n\tspin_lock_irqsave(&drvdata->inrange_timer_lock, flags);\n\tdrvdata->inrange_timer_shutdown = true;\n\tspin_unlock_irqrestore(&drvdata->inrange_timer_lock, flags);\n\tSYNC_FN(&drvdata->inrange_timer);\n}\n\n'''.replace('SYNC_FN', sync_fn)
    s = s.replace(timeout_end, helpers, 1)

    init = '\ttimer_setup(&drvdata->inrange_timer, uclogic_inrange_timeout, 0);\n'
    if s.count(init) != 1:
        raise SystemExit('UC-Logic timer init anchor changed')
    s = s.replace(init, init + '\tspin_lock_init(&drvdata->inrange_timer_lock);\n', 1)

    old_mod = '''\t\t\tmod_timer(&drvdata->inrange_timer,\n\t\t\t\t\tjiffies + msecs_to_jiffies(100));'''
    if s.count(old_mod) != 1:
        raise SystemExit('UC-Logic raw-event mod_timer anchor changed')
    s = s.replace(old_mod, '\t\t\tuclogic_inrange_timer_mod(drvdata);', 1)
    s = s.replace(shutdown_call, 'uclogic_inrange_timer_shutdown(drvdata);', 1)

    # Fail closed: the stable caller must be gone and the only remaining direct
    # mod_timer() must live inside our serialized helper.
    if shutdown_call in s:
        raise SystemExit('UC-Logic shutdown call still present')
    if s.count('mod_timer(&drvdata->inrange_timer,') != 1:
        raise SystemExit('UC-Logic mod_timer serialization invariant failed')
    uclogic.write_text(s)
    print(f'UCLOGIC_TIMER_COMPAT=APPLIED:LOCKED_NO_REARM+{sync_fn}')
else:
    print('UCLOGIC_TIMER_COMPAT=NOT_PRESENT_OR_ALREADY_ADAPTED')

# No unresolved executable 5.15.220 caller may remain in these compiled paths.
# Comments may legitimately mention the newer timer API; only a statement line counts.
for path in (psi, bridge, uclogic):
    text = path.read_text()
    if re.search(r'(?m)^\s*timer_shutdown_sync\s*\(', text):
        raise SystemExit(f'unresolved timer_shutdown_sync caller: {path}')
PY

printf '%s\n' 'PASS: repaired KSUN/SuSFS state and ACK-safe 5.15.220 timer callers'

