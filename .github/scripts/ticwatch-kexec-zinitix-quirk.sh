#!/usr/bin/env bash
set -Eeuo pipefail

K="${1:?usage: $0 <kernel-tree>}"
F="$K/drivers/i2c/i2c-core-base.c"

[ -f "$F" ] || { echo "missing $F" >&2; exit 2; }

python3 - "$F" <<'PY'
from pathlib import Path
import sys

p = Path(sys.argv[1])
s = p.read_text()

include_anchor = '#include <linux/kernel.h>\n'
if '#include <linux/kexec.h>\n' not in s:
    if s.count(include_anchor) != 1:
        raise SystemExit('kexec include anchor mismatch')
    s = s.replace(include_anchor, include_anchor + '#include <linux/kexec.h>\n', 1)

old = '''static void i2c_device_shutdown(struct device *dev)\n{\n\tstruct i2c_client *client = i2c_verify_client(dev);\n\tstruct i2c_driver *driver;\n\n\tif (!client || !dev->driver)\n\t\treturn;\n\tdriver = to_i2c_driver(dev->driver);\n\tif (driver->shutdown)\n\t\tdriver->shutdown(client);\n\telse if (client->irq > 0)\n\t\tdisable_irq(client->irq);\n}\n'''

new = '''static void i2c_device_shutdown(struct device *dev)\n{\n\tstruct i2c_client *client = i2c_verify_client(dev);\n\tstruct i2c_driver *driver;\n\n\tif (!client || !dev->driver)\n\t\treturn;\n\n\t/*\n\t * TicWatch Pro 5 Enduro (dace/monaco): the stock BT541/Zinitix\n\t * shutdown callback force-disables the touch regulators. During the\n\t * KEXEC path this is followed by a synchronous external abort before\n\t * machine_shutdown()/machine_kexec() can be reached. Keep ordinary\n\t * reboot/poweroff behaviour unchanged and skip only this exact I2C\n\t * client's shutdown callback while a KEXEC reboot is in progress.\n\t * The next kernel reinitializes the controller from its own probe path.\n\t */\n\tif (kexec_in_progress && client->adapter && client->adapter->nr == 1 &&\n\t    client->addr == 0x20 &&\n\t    !strcmp(dev->driver->name, "bt541_ts_device")) {\n\t\tdev_info(dev, "TicWatch KEXEC: skipping BT541 shutdown callback\\n");\n\t\treturn;\n\t}\n\n\tdriver = to_i2c_driver(dev->driver);\n\tif (driver->shutdown)\n\t\tdriver->shutdown(client);\n\telse if (client->irq > 0)\n\t\tdisable_irq(client->irq);\n}\n'''

if old not in s:
    if 'TicWatch KEXEC: skipping BT541 shutdown callback' in s:
        print('TicWatch KEXEC Zinitix quirk already present')
        raise SystemExit(0)
    raise SystemExit('i2c_device_shutdown anchor mismatch')

p.write_text(s.replace(old, new, 1))
PY

grep -Fq '#include <linux/kexec.h>' "$F"
grep -Fq 'TicWatch KEXEC: skipping BT541 shutdown callback' "$F"
grep -Fq 'client->adapter->nr == 1' "$F"
grep -Fq 'client->addr == 0x20' "$F"
grep -Fq 'bt541_ts_device' "$F"

echo 'TICWATCH_KEXEC_ZINITIX_QUIRK=APPLIED'
