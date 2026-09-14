#!/usr/bin/env bash
set -Eeuo pipefail

K="${1:?usage: $0 <kernel-tree>}"
PLATFORM="$K/drivers/base/platform.c"

[ -f "$PLATFORM" ] || { echo "missing $PLATFORM" >&2; exit 2; }

python3 - "$PLATFORM" <<'PY'
from pathlib import Path
import sys

p = Path(sys.argv[1])
s = p.read_text()
marker = 'TWKEXEC: GENI UART platform shutdown skipped'
if marker in s:
    print('GENI platform KEXEC skip already present')
    raise SystemExit(0)

old = '''static void platform_shutdown(struct device *_dev)\n{\n\tstruct platform_device *dev = to_platform_device(_dev);\n\tstruct platform_driver *drv;\n\n\tif (!_dev->driver)\n\t\treturn;\n\n\tdrv = to_platform_driver(_dev->driver);\n\tif (drv->shutdown)\n\t\tdrv->shutdown(dev);\n}\n'''

new = '''static void platform_shutdown(struct device *_dev)\n{\n\tstruct platform_device *dev = to_platform_device(_dev);\n\tstruct platform_driver *drv;\n\textern bool kexec_in_progress;\n\n\tif (!_dev->driver)\n\t\treturn;\n\n\t/*\n\t * TicWatch Pro 5 Enduro: the exact GENI UART platform device at\n\t * 0x04a94000 is proven to stall inside platform_shutdown() during\n\t * KEXEC before the serial-core low-level shutdown hook is reached.\n\t * Skip only this callback and only for KEXEC. Normal reboot/poweroff\n\t * behavior is unchanged.\n\t */\n\tif (kexec_in_progress && dev->num_resources > 0 &&\n\t    dev->resource[0].start == 0x04a94000) {\n\t\tpr_emerg("TWKEXEC: GENI UART platform shutdown skipped dev=%s\\n",\n\t\t\t dev_name(_dev));\n\t\treturn;\n\t}\n\n\tdrv = to_platform_driver(_dev->driver);\n\tif (drv->shutdown)\n\t\tdrv->shutdown(dev);\n}\n'''

if s.count(old) != 1:
    raise SystemExit(f'platform_shutdown anchor mismatch: {s.count(old)}')
s = s.replace(old, new, 1)
p.write_text(s)
PY

if grep -Fq '#include <linux/kexec.h>' "$PLATFORM"; then
  echo "unexpected linux/kexec.h include in $PLATFORM" >&2
  exit 3
fi

grep -Fq 'TWKEXEC: GENI UART platform shutdown skipped' "$PLATFORM"
grep -Fq 'dev->resource[0].start == 0x04a94000' "$PLATFORM"
grep -Fq 'extern bool kexec_in_progress;' "$PLATFORM"

echo 'TICWATCH_KEXEC_GENI_PLATFORM_SKIP=APPLIED'
echo 'TICWATCH_KEXEC_GENI_PLATFORM_SKIP_MMIO=0x04a94000'
echo 'TICWATCH_KEXEC_GENI_PLATFORM_SKIP_SCOPE=KEXEC_ONLY'
