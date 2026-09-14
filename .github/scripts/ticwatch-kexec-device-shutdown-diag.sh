#!/usr/bin/env bash
set -Eeuo pipefail

K="${1:?usage: $0 <kernel-tree>}"
CORE="$K/drivers/base/core.c"

[ -f "$CORE" ] || { echo "missing $CORE" >&2; exit 2; }

python3 - "$CORE" <<'PY'
from pathlib import Path
import sys

p = Path(sys.argv[1])
s = p.read_text()
marker = 'TWKEXEC_DEV: WAIT_PROBE BEFORE'
if marker in s:
    print('device_shutdown diagnostics already present')
    raise SystemExit(0)

sig = 'void device_shutdown(void)\n{'
start = s.find(sig)
if start < 0:
    raise SystemExit('device_shutdown signature not found')

# Isolate the exact function by brace balancing, then apply only unique,
# behavior-preserving logging insertions inside it.
brace = s.find('{', start)
depth = 0
end = None
in_str = False
esc = False
for i in range(brace, len(s)):
    c = s[i]
    if in_str:
        if esc:
            esc = False
        elif c == '\\':
            esc = True
        elif c == '"':
            in_str = False
        continue
    if c == '"':
        in_str = True
    elif c == '{':
        depth += 1
    elif c == '}':
        depth -= 1
        if depth == 0:
            end = i + 1
            break
if end is None:
    raise SystemExit('device_shutdown end not found')

f = s[start:end]

def once(old, new, label):
    global f
    n = f.count(old)
    if n != 1:
        raise SystemExit(f'{label} anchor mismatch: {n}')
    f = f.replace(old, new, 1)

once('void device_shutdown(void)\n{\n',
     'void device_shutdown(void)\n{\n\textern bool kexec_in_progress;\n',
     'function prologue')

once('\twait_for_device_probe();\n',
     '\tif (kexec_in_progress)\n\t\tpr_emerg("TWKEXEC_DEV: WAIT_PROBE BEFORE\\n");\n'
     '\twait_for_device_probe();\n'
     '\tif (kexec_in_progress)\n\t\tpr_emerg("TWKEXEC_DEV: WAIT_PROBE AFTER\\n");\n',
     'wait_for_device_probe')

once('\tdevice_block_probing();\n',
     '\tif (kexec_in_progress)\n\t\tpr_emerg("TWKEXEC_DEV: BLOCK_PROBING BEFORE\\n");\n'
     '\tdevice_block_probing();\n'
     '\tif (kexec_in_progress)\n\t\tpr_emerg("TWKEXEC_DEV: BLOCK_PROBING AFTER\\n");\n',
     'device_block_probing')

once('\tcpufreq_suspend();\n',
     '\tif (kexec_in_progress)\n\t\tpr_emerg("TWKEXEC_DEV: CPUFREQ BEFORE\\n");\n'
     '\tcpufreq_suspend();\n'
     '\tif (kexec_in_progress)\n\t\tpr_emerg("TWKEXEC_DEV: CPUFREQ AFTER\\n");\n',
     'cpufreq_suspend')

# The two-tab unlock is the loop-body unlock; the final unlock has one tab.
once('\t\tspin_unlock(&devices_kset->list_lock);\n',
     '\t\tspin_unlock(&devices_kset->list_lock);\n\n'
     '\t\tif (kexec_in_progress)\n'
     '\t\t\tpr_emerg("TWKEXEC_DEV: BEGIN dev=%s\\n", dev_name(dev));\n',
     'loop spin_unlock')

once('\t\tdevice_lock(dev);\n',
     '\t\tdevice_lock(dev);\n'
     '\t\tif (kexec_in_progress)\n'
     '\t\t\tpr_emerg("TWKEXEC_DEV: LOCKED dev=%s\\n", dev_name(dev));\n',
     'device_lock')

once('\t\tpm_runtime_barrier(dev);\n',
     '\t\tpm_runtime_barrier(dev);\n'
     '\t\tif (kexec_in_progress)\n'
     '\t\t\tpr_emerg("TWKEXEC_DEV: PM_DONE dev=%s\\n", dev_name(dev));\n',
     'pm_runtime_barrier')

once('\t\t\tdev->class->shutdown_pre(dev);\n',
     '\t\t\tif (kexec_in_progress)\n'
     '\t\t\t\tpr_emerg("TWKEXEC_DEV: CLASS_BEFORE dev=%s class=%s fn=%ps\\n",\n'
     '\t\t\t\t\t dev_name(dev), dev->class->name, dev->class->shutdown_pre);\n'
     '\t\t\tdev->class->shutdown_pre(dev);\n'
     '\t\t\tif (kexec_in_progress)\n'
     '\t\t\t\tpr_emerg("TWKEXEC_DEV: CLASS_AFTER dev=%s\\n", dev_name(dev));\n',
     'class shutdown_pre')

once('\t\t\tdev->bus->shutdown(dev);\n',
     '\t\t\tif (kexec_in_progress)\n'
     '\t\t\t\tpr_emerg("TWKEXEC_DEV: BUS_BEFORE dev=%s bus=%s fn=%ps\\n",\n'
     '\t\t\t\t\t dev_name(dev), dev->bus->name, dev->bus->shutdown);\n'
     '\t\t\tdev->bus->shutdown(dev);\n'
     '\t\t\tif (kexec_in_progress)\n'
     '\t\t\t\tpr_emerg("TWKEXEC_DEV: BUS_AFTER dev=%s\\n", dev_name(dev));\n',
     'bus shutdown')

once('\t\t\tdev->driver->shutdown(dev);\n',
     '\t\t\tif (kexec_in_progress)\n'
     '\t\t\t\tpr_emerg("TWKEXEC_DEV: DRIVER_BEFORE dev=%s driver=%s fn=%ps\\n",\n'
     '\t\t\t\t\t dev_name(dev), dev->driver->name, dev->driver->shutdown);\n'
     '\t\t\tdev->driver->shutdown(dev);\n'
     '\t\t\tif (kexec_in_progress)\n'
     '\t\t\t\tpr_emerg("TWKEXEC_DEV: DRIVER_AFTER dev=%s\\n", dev_name(dev));\n',
     'driver shutdown')

once('\t\tdevice_unlock(dev);\n',
     '\t\tif (kexec_in_progress)\n'
     '\t\t\tpr_emerg("TWKEXEC_DEV: CALLBACKS_DONE dev=%s\\n", dev_name(dev));\n'
     '\t\tdevice_unlock(dev);\n',
     'device_unlock')

s = s[:start] + f + s[end:]
p.write_text(s)
PY

# Do not perturb genksyms preprocessing with a new kexec header include.
if grep -Fq '#include <linux/kexec.h>' "$CORE"; then
  echo "unexpected linux/kexec.h include in $CORE" >&2
  exit 3
fi

for M in \
  'TWKEXEC_DEV: WAIT_PROBE BEFORE' \
  'TWKEXEC_DEV: WAIT_PROBE AFTER' \
  'TWKEXEC_DEV: BLOCK_PROBING BEFORE' \
  'TWKEXEC_DEV: BLOCK_PROBING AFTER' \
  'TWKEXEC_DEV: CPUFREQ BEFORE' \
  'TWKEXEC_DEV: CPUFREQ AFTER' \
  'TWKEXEC_DEV: BEGIN dev=%s' \
  'TWKEXEC_DEV: LOCKED dev=%s' \
  'TWKEXEC_DEV: PM_DONE dev=%s' \
  'TWKEXEC_DEV: CLASS_BEFORE' \
  'TWKEXEC_DEV: CLASS_AFTER' \
  'TWKEXEC_DEV: BUS_BEFORE' \
  'TWKEXEC_DEV: BUS_AFTER' \
  'TWKEXEC_DEV: DRIVER_BEFORE' \
  'TWKEXEC_DEV: DRIVER_AFTER' \
  'TWKEXEC_DEV: CALLBACKS_DONE'; do
  grep -Fq "$M" "$CORE"
done

echo 'TICWATCH_KEXEC_DEVICE_SHUTDOWN_DIAGNOSTICS=APPLIED'
echo 'TICWATCH_KEXEC_DEVICE_SHUTDOWN_BEHAVIOR_CHANGE=NONE'
echo 'TICWATCH_KEXEC_DEVICE_SHUTDOWN_KMI_DECL=FUNCTION_LOCAL_EXTERN'
