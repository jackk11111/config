#!/usr/bin/env bash
set -Eeuo pipefail

K="${1:?usage: $0 <kernel-tree>}"
I2C="$K/drivers/i2c/i2c-core-base.c"
SERIAL="$K/drivers/tty/serial/serial_core.c"
PLATFORM="$K/drivers/base/platform.c"

[ -f "$I2C" ] || { echo "missing $I2C" >&2; exit 2; }
[ -f "$SERIAL" ] || { echo "missing $SERIAL" >&2; exit 2; }
[ -f "$PLATFORM" ] || { echo "missing $PLATFORM" >&2; exit 2; }

python3 - "$I2C" "$SERIAL" <<'PY'
from pathlib import Path
import sys

i2c_p = Path(sys.argv[1])
serial_p = Path(sys.argv[2])
i2c = i2c_p.read_text()
serial = serial_p.read_text()

# ------------------------------------------------------------------
# 1) BT541/Zinitix KEXEC-only quirk.
#
# Runtime comparison showed that removing the historical exact BT541 skip
# changed the KEXEC failure mode from the immediate GENI abort to a several
# second touch/panel shutdown path that never reached Starting new kernel.
# Restore only the exact bus-1/address-0x20 shutdown skip, but do NOT include
# <linux/kexec.h>: use a function-local extern to preserve full genksyms/KMI.
# ------------------------------------------------------------------
i2c_old = '''static void i2c_device_shutdown(struct device *dev)\n{\n\tstruct i2c_client *client = i2c_verify_client(dev);\n\tstruct i2c_driver *driver;\n\n\tif (!client || !dev->driver)\n\t\treturn;\n\tdriver = to_i2c_driver(dev->driver);\n\tif (driver->shutdown)\n\t\tdriver->shutdown(client);\n\telse if (client->irq > 0)\n\t\tdisable_irq(client->irq);\n}\n'''

i2c_new = '''static void i2c_device_shutdown(struct device *dev)\n{\n\tstruct i2c_client *client = i2c_verify_client(dev);\n\tstruct i2c_driver *driver;\n\textern bool kexec_in_progress;\n\n\tif (!client || !dev->driver)\n\t\treturn;\n\n\t/* TicWatch Pro 5 Enduro: exact BT541 touch client, KEXEC only. */\n\tif (kexec_in_progress && client->adapter &&\n\t    client->adapter->nr == 1 && client->addr == 0x20) {\n\t\tdev_info(dev,\n\t\t\t "TicWatch KEXEC: skipping BT541 shutdown callback\\n");\n\t\treturn;\n\t}\n\n\tdriver = to_i2c_driver(dev->driver);\n\tif (driver->shutdown)\n\t\tdriver->shutdown(client);\n\telse if (client->irq > 0)\n\t\tdisable_irq(client->irq);\n}\n'''

if 'TicWatch KEXEC: skipping BT541 shutdown callback' not in i2c:
    if i2c.count(i2c_old) != 1:
        raise SystemExit('i2c_device_shutdown anchor mismatch')
    i2c = i2c.replace(i2c_old, i2c_new, 1)

# ------------------------------------------------------------------
# 2) GENI UART KEXEC-only quirk at the layer that actually calls the
#    vendor uart_ops->shutdown().
#
# The previous platform_bus quirk was at the wrong layer: msm_geni_serial's
# platform_driver has no .shutdown callback, while the runtime abort mapped
# uniquely to msm_geni_serial.ko:stop_tx_sequencer+0x48, reached from the
# serial core low-level uart_ops shutdown path. Skip only the UART whose
# physical mapbase is 0x04a94000, which is the failing dace/monaco HS UART.
# The existing synchronize_irq() remains in place; disable the IRQ without
# invoking the vendor MMIO shutdown sequence.
# ------------------------------------------------------------------
serial_call = '\t\tuport->ops->shutdown(uport);\n'
serial_marker = 'TicWatch KEXEC: skipping GENI UART port shutdown'
if serial_marker not in serial:
    if serial.count(serial_call) != 1:
        raise SystemExit(f'serial uart_ops shutdown anchor mismatch: {serial.count(serial_call)}')
    serial_repl = '''\t\t{\n\t\t\textern bool kexec_in_progress;\n\n\t\t\tif (kexec_in_progress && uport->mapbase == 0x04a94000) {\n\t\t\t\tdev_info(uport->dev,\n\t\t\t\t\t "TicWatch KEXEC: skipping GENI UART port shutdown\\n");\n\t\t\t\tdisable_irq_nosync(uport->irq);\n\t\t\t} else {\n\t\t\t\tuport->ops->shutdown(uport);\n\t\t\t}\n\t\t}\n'''
    serial = serial.replace(serial_call, serial_repl, 1)

i2c_p.write_text(i2c)
serial_p.write_text(serial)
PY

# Full-KMI guard: do not change preprocessor context of exported-symbol units.
if grep -Fq '#include <linux/kexec.h>' "$I2C"; then
    echo 'unexpected linux/kexec.h include in drivers/i2c/i2c-core-base.c' >&2
    exit 4
fi
if grep -Fq '#include <linux/kexec.h>' "$SERIAL"; then
    echo 'unexpected linux/kexec.h include in drivers/tty/serial/serial_core.c' >&2
    exit 4
fi

# Fail closed on the superseded platform-layer GENI workaround.
if grep -Fq 'TicWatch KEXEC: skipping GENI UART shutdown callback' "$PLATFORM"; then
    echo 'superseded platform-layer GENI quirk unexpectedly present' >&2
    exit 3
fi

grep -Fq 'extern bool kexec_in_progress;' "$I2C"
grep -Fq 'TicWatch KEXEC: skipping BT541 shutdown callback' "$I2C"
grep -Fq 'client->adapter->nr == 1 && client->addr == 0x20' "$I2C"

grep -Fq 'extern bool kexec_in_progress;' "$SERIAL"
grep -Fq 'TicWatch KEXEC: skipping GENI UART port shutdown' "$SERIAL"
grep -Fq 'uport->mapbase == 0x04a94000' "$SERIAL"
grep -Fq 'disable_irq_nosync(uport->irq);' "$SERIAL"

echo 'TICWATCH_KEXEC_BT541_QUIRK=APPLIED'
echo 'TICWATCH_KEXEC_GENI_UART_CORE_QUIRK=APPLIED'
echo 'TICWATCH_KEXEC_KMI_DECL=FUNCTION_LOCAL_EXTERN'
echo 'TICWATCH_KEXEC_GENI_PLATFORM_QUIRK=NOT_APPLIED'
