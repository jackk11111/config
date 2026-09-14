#!/usr/bin/env bash
set -Eeuo pipefail

K="${1:?usage: $0 <kernel-tree>}"
I2C="$K/drivers/i2c/i2c-core-base.c"
SERIAL="$K/drivers/tty/serial/serial_core.c"
PLATFORM="$K/drivers/base/platform.c"
REBOOT="$K/kernel/reboot.c"
NOTIFIER="$K/kernel/notifier.c"

for F in "$I2C" "$SERIAL" "$PLATFORM" "$REBOOT" "$NOTIFIER"; do
  [ -f "$F" ] || { echo "missing $F" >&2; exit 2; }
done

python3 - "$I2C" "$SERIAL" "$REBOOT" "$NOTIFIER" <<'PY'
from pathlib import Path
import sys

i2c_p, serial_p, reboot_p, notifier_p = map(Path, sys.argv[1:])
i2c = i2c_p.read_text()
serial = serial_p.read_text()
reboot = reboot_p.read_text()
notifier = notifier_p.read_text()

i2c_old = '''static void i2c_device_shutdown(struct device *dev)\n{\n\tstruct i2c_client *client = i2c_verify_client(dev);\n\tstruct i2c_driver *driver;\n\n\tif (!client || !dev->driver)\n\t\treturn;\n\tdriver = to_i2c_driver(dev->driver);\n\tif (driver->shutdown)\n\t\tdriver->shutdown(client);\n\telse if (client->irq > 0)\n\t\tdisable_irq(client->irq);\n}\n'''

i2c_new = '''static void i2c_device_shutdown(struct device *dev)\n{\n\tstruct i2c_client *client = i2c_verify_client(dev);\n\tstruct i2c_driver *driver;\n\textern bool kexec_in_progress;\n\n\tif (!client || !dev->driver)\n\t\treturn;\n\n\tif (kexec_in_progress && client->adapter &&\n\t    client->adapter->nr == 1 && client->addr == 0x20) {\n\t\tpr_emerg("TWKEXEC: BT541 I2C shutdown skipped\\n");\n\t\treturn;\n\t}\n\n\tdriver = to_i2c_driver(dev->driver);\n\tif (driver->shutdown)\n\t\tdriver->shutdown(client);\n\telse if (client->irq > 0)\n\t\tdisable_irq(client->irq);\n}\n'''

if 'TWKEXEC: BT541 I2C shutdown skipped' not in i2c:
    if 'TicWatch KEXEC: skipping BT541 shutdown callback' in i2c:
        i2c = i2c.replace('dev_info(dev,\n\t\t\t "TicWatch KEXEC: skipping BT541 shutdown callback\\n");',
                          'pr_emerg("TWKEXEC: BT541 I2C shutdown skipped\\n");', 1)
    else:
        if i2c.count(i2c_old) != 1:
            raise SystemExit('i2c_device_shutdown anchor mismatch')
        i2c = i2c.replace(i2c_old, i2c_new, 1)

serial_call = '\t\tuport->ops->shutdown(uport);\n'
if 'TWKEXEC: GENI UART core shutdown skipped' not in serial:
    if 'TicWatch KEXEC: skipping GENI UART port shutdown' in serial:
        serial = serial.replace('dev_info(uport->dev,\n\t\t\t\t\t "TicWatch KEXEC: skipping GENI UART port shutdown\\n");',
                                'pr_emerg("TWKEXEC: GENI UART core shutdown skipped\\n");', 1)
    else:
        if serial.count(serial_call) != 1:
            raise SystemExit(f'serial uart_ops shutdown anchor mismatch: {serial.count(serial_call)}')
        serial_repl = '''\t\t{\n\t\t\textern bool kexec_in_progress;\n\n\t\t\tif (kexec_in_progress && uport->mapbase == 0x04a94000) {\n\t\t\t\tpr_emerg("TWKEXEC: GENI UART core shutdown skipped\\n");\n\t\t\t\tdisable_irq_nosync(uport->irq);\n\t\t\t} else {\n\t\t\t\tuport->ops->shutdown(uport);\n\t\t\t}\n\t\t}\n'''
        serial = serial.replace(serial_call, serial_repl, 1)

reboot_old = '''void kernel_restart_prepare(char *cmd)\n{\n\tblocking_notifier_call_chain(&reboot_notifier_list, SYS_RESTART, cmd);\n\tsystem_state = SYSTEM_RESTART;\n\tusermodehelper_disable();\n\tdevice_shutdown();\n}\n'''
reboot_new = '''void kernel_restart_prepare(char *cmd)\n{\n\textern bool kexec_in_progress;\n\n\tif (kexec_in_progress)\n\t\tpr_emerg("TWKEXEC_DIAG: restart_prepare ENTER cmd=%s\\n", cmd ?: "<null>");\n\tif (kexec_in_progress)\n\t\tpr_emerg("TWKEXEC_DIAG: reboot_notifier_chain BEFORE\\n");\n\tblocking_notifier_call_chain(&reboot_notifier_list, SYS_RESTART, cmd);\n\tif (kexec_in_progress)\n\t\tpr_emerg("TWKEXEC_DIAG: reboot_notifier_chain AFTER\\n");\n\tsystem_state = SYSTEM_RESTART;\n\tif (kexec_in_progress)\n\t\tpr_emerg("TWKEXEC_DIAG: usermodehelper_disable BEFORE\\n");\n\tusermodehelper_disable();\n\tif (kexec_in_progress)\n\t\tpr_emerg("TWKEXEC_DIAG: usermodehelper_disable AFTER\\n");\n\tif (kexec_in_progress)\n\t\tpr_emerg("TWKEXEC_DIAG: device_shutdown BEFORE\\n");\n\tdevice_shutdown();\n\tif (kexec_in_progress)\n\t\tpr_emerg("TWKEXEC_DIAG: device_shutdown AFTER\\n");\n}\n'''
if 'TWKEXEC_DIAG: restart_prepare ENTER' not in reboot:
    if reboot.count(reboot_old) != 1:
        raise SystemExit('kernel_restart_prepare anchor mismatch')
    reboot = reboot.replace(reboot_old, reboot_new, 1)

call = '\t\tret = nb->notifier_call(nb, val, v);\n'
if 'TWKEXEC_DIAG: notifier BEFORE' not in notifier:
    if notifier.count(call) != 1:
        raise SystemExit(f'notifier_call_chain callback anchor mismatch: {notifier.count(call)}')
    repl = '''\t\t{\n\t\t\textern bool kexec_in_progress;\n\n\t\t\tif (kexec_in_progress)\n\t\t\t\tpr_emerg("TWKEXEC_DIAG: notifier BEFORE fn=%ps val=%lu\\n",\n\t\t\t\t\t nb->notifier_call, val);\n\t\t\tret = nb->notifier_call(nb, val, v);\n\t\t\tif (kexec_in_progress)\n\t\t\t\tpr_emerg("TWKEXEC_DIAG: notifier AFTER fn=%ps ret=0x%x\\n",\n\t\t\t\t\t nb->notifier_call, ret);\n\t\t}\n'''
    notifier = notifier.replace(call, repl, 1)

i2c_p.write_text(i2c)
serial_p.write_text(serial)
reboot_p.write_text(reboot)
notifier_p.write_text(notifier)
PY

for F in "$I2C" "$SERIAL" "$NOTIFIER"; do
  if grep -Fq '#include <linux/kexec.h>' "$F"; then
    echo "unexpected linux/kexec.h include in $F" >&2
    exit 4
  fi
done

if grep -Fq 'TicWatch KEXEC: skipping GENI UART shutdown callback' "$PLATFORM"; then
  echo 'superseded platform-layer GENI quirk unexpectedly present' >&2
  exit 3
fi

grep -Fq 'TWKEXEC: BT541 I2C shutdown skipped' "$I2C"
grep -Fq 'client->adapter->nr == 1 && client->addr == 0x20' "$I2C"
grep -Fq 'TWKEXEC: GENI UART core shutdown skipped' "$SERIAL"
grep -Fq 'uport->mapbase == 0x04a94000' "$SERIAL"
grep -Fq 'disable_irq_nosync(uport->irq);' "$SERIAL"
grep -Fq 'TWKEXEC_DIAG: restart_prepare ENTER' "$REBOOT"
grep -Fq 'TWKEXEC_DIAG: device_shutdown BEFORE' "$REBOOT"
grep -Fq 'TWKEXEC_DIAG: notifier BEFORE' "$NOTIFIER"
grep -Fq 'TWKEXEC_DIAG: notifier AFTER' "$NOTIFIER"

echo 'TICWATCH_KEXEC_BT541_QUIRK=APPLIED'
echo 'TICWATCH_KEXEC_GENI_UART_CORE_QUIRK=APPLIED'
echo 'TICWATCH_KEXEC_REBOOT_PATH_DIAGNOSTICS=APPLIED'
echo 'TICWATCH_KEXEC_KMI_DECL=FUNCTION_LOCAL_EXTERN'
echo 'TICWATCH_KEXEC_GENI_PLATFORM_LEGACY_QUIRK=NOT_APPLIED'

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
bash "$SCRIPT_DIR/ticwatch-kexec-geni-platform-skip.sh" "$K"
bash "$SCRIPT_DIR/ticwatch-kexec-mmc0-card-skip.sh" "$K"
bash "$SCRIPT_DIR/ticwatch-kexec-device-shutdown-diag.sh" "$K"
bash "$SCRIPT_DIR/ticwatch-kexec-core-path-diag.sh" "$K"
