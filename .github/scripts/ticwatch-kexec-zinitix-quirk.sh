#!/usr/bin/env bash
set -Eeuo pipefail

K="${1:?usage: $0 <kernel-tree>}"
F="$K/drivers/base/platform.c"

[ -f "$F" ] || { echo "missing $F" >&2; exit 2; }

python3 - "$F" <<'PY'
from pathlib import Path
import re
import sys

p = Path(sys.argv[1])
s = p.read_text()

# Root-cause correction after runtime opcode mapping of the KEXEC abort:
#   msm_geni_serial.ko:stop_tx_sequencer+0x48
#   ldr w20, [uport->membase + SE_GENI_STATUS]
# The previous BT541 correlation was temporal only; the crash instruction
# uniquely maps to the stock Qualcomm GENI UART module.  Keep the workaround
# in the kernel core so the stock vendor module remains untouched.
if '#include <linux/kexec.h>\n' not in s:
    m = re.search(r'(#include <linux/[^>]+>\n)', s)
    if not m:
        raise SystemExit('kexec include anchor mismatch')
    s = s[:m.end()] + '#include <linux/kexec.h>\n' + s[m.end():]

old = '''static void platform_shutdown(struct device *_dev)\n{\n\tstruct platform_device *dev = to_platform_device(_dev);\n\tstruct platform_driver *drv;\n\n\tif (!_dev->driver)\n\t\treturn;\n\n\tdrv = to_platform_driver(_dev->driver);\n\tif (drv->shutdown)\n\t\tdrv->shutdown(dev);\n}\n'''

new = '''static void platform_shutdown(struct device *_dev)\n{\n\tstruct platform_device *dev = to_platform_device(_dev);\n\tstruct platform_driver *drv;\n\n\tif (!_dev->driver)\n\t\treturn;\n\n\t/*\n\t * TicWatch Pro 5 Enduro (dace/monaco), KEXEC only.\n\t *\n\t * Runtime crash opcode mapping against the exact stock379 modules\n\t * identifies msm_geni_serial.ko:stop_tx_sequencer+0x48 as the\n\t * synchronous external abort.  The failing instruction is the first\n\t * MMIO read of SE_GENI_STATUS through uport->membase while shutting\n\t * down the only HS UART at 4a94000.  A normal reboot/poweroff reaches\n\t * this same driver's shutdown path successfully, so do not alter it.\n\t * During KEXEC, skip only this exact platform device callback; the\n\t * next kernel will reprobe/reinitialize the UART.\n\t */\n\tif (kexec_in_progress &&\n\t    !strcmp(_dev->driver->name, "msm_geni_serial") &&\n\t    !strcmp(dev_name(_dev), "4a94000.qcom,qup_uart")) {\n\t\tdev_info(_dev,\n\t\t\t "TicWatch KEXEC: skipping GENI UART shutdown callback\\n");\n\t\treturn;\n\t}\n\n\tdrv = to_platform_driver(_dev->driver);\n\tif (drv->shutdown)\n\t\tdrv->shutdown(dev);\n}\n'''

if old not in s:
    if 'TicWatch KEXEC: skipping GENI UART shutdown callback' in s:
        print('TicWatch KEXEC GENI UART quirk already present')
        raise SystemExit(0)
    raise SystemExit('platform_shutdown anchor mismatch')

p.write_text(s.replace(old, new, 1))
PY

grep -Fq '#include <linux/kexec.h>' "$F"
grep -Fq 'TicWatch KEXEC: skipping GENI UART shutdown callback' "$F"
grep -Fq 'msm_geni_serial' "$F"
grep -Fq '4a94000.qcom,qup_uart' "$F"

# The restored precompile checkpoint must not carry the superseded BT541
# workaround.  Fail closed if that old marker is unexpectedly present.
if grep -R -Fq 'TicWatch KEXEC: skipping BT541 shutdown callback' \
        "$K/drivers/i2c" "$K/drivers/base" 2>/dev/null; then
    echo 'superseded BT541 KEXEC quirk unexpectedly present' >&2
    exit 3
fi

echo 'TICWATCH_KEXEC_GENI_UART_QUIRK=APPLIED'
echo 'TICWATCH_KEXEC_BT541_QUIRK=NOT_APPLIED'
