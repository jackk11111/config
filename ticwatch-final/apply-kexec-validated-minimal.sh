#!/usr/bin/env bash
set -Eeuo pipefail

K="${1:?usage: $0 <kernel-tree>}"
I2C="$K/drivers/i2c/i2c-core-base.c"
SERIAL="$K/drivers/tty/serial/serial_core.c"
PLATFORM="$K/drivers/base/platform.c"
MMC="$K/drivers/mmc/core/bus.c"

for F in "$I2C" "$SERIAL" "$PLATFORM" "$MMC"; do
  [ -f "$F" ] || { echo "missing $F" >&2; exit 2; }
done

python3 - "$I2C" "$SERIAL" "$PLATFORM" "$MMC" <<'PY'
from pathlib import Path
import sys
i2cp,serp,platp,mmcp=map(Path,sys.argv[1:])
i2c,ser,plat,mmc=(p.read_text() for p in (i2cp,serp,platp,mmcp))

old='''static void i2c_device_shutdown(struct device *dev)
{
\tstruct i2c_client *client = i2c_verify_client(dev);
\tstruct i2c_driver *driver;

\tif (!client || !dev->driver)
\t\treturn;
\tdriver = to_i2c_driver(dev->driver);
\tif (driver->shutdown)
\t\tdriver->shutdown(client);
\telse if (client->irq > 0)
\t\tdisable_irq(client->irq);
}
'''
new='''static void i2c_device_shutdown(struct device *dev)
{
\tstruct i2c_client *client = i2c_verify_client(dev);
\tstruct i2c_driver *driver;
\textern bool kexec_in_progress;

\tif (!client || !dev->driver)
\t\treturn;

\tif (kexec_in_progress && client->adapter &&
\t    client->adapter->nr == 1 && client->addr == 0x20) {
\t\tpr_emerg("TWKEXEC: BT541 I2C shutdown skipped\\n");
\t\treturn;
\t}

\tdriver = to_i2c_driver(dev->driver);
\tif (driver->shutdown)
\t\tdriver->shutdown(client);
\telse if (client->irq > 0)
\t\tdisable_irq(client->irq);
}
'''
if 'TWKEXEC: BT541 I2C shutdown skipped' not in i2c:
    if i2c.count(old)!=1: raise SystemExit('i2c anchor mismatch')
    i2c=i2c.replace(old,new,1)

call='\t\tuport->ops->shutdown(uport);\n'
if 'TWKEXEC: GENI UART core shutdown skipped' not in ser:
    if ser.count(call)!=1: raise SystemExit('serial anchor mismatch')
    repl='''\t\t{
\t\t\textern bool kexec_in_progress;

\t\t\tif (kexec_in_progress && uport->mapbase == 0x04a94000) {
\t\t\t\tpr_emerg("TWKEXEC: GENI UART core shutdown skipped\\n");
\t\t\t\tdisable_irq_nosync(uport->irq);
\t\t\t} else {
\t\t\t\tuport->ops->shutdown(uport);
\t\t\t}
\t\t}
'''
    ser=ser.replace(call,repl,1)

oldp='''static void platform_shutdown(struct device *_dev)
{
\tstruct platform_device *dev = to_platform_device(_dev);
\tstruct platform_driver *drv;

\tif (!_dev->driver)
\t\treturn;

\tdrv = to_platform_driver(_dev->driver);
\tif (drv->shutdown)
\t\tdrv->shutdown(dev);
}
'''
newp='''static void platform_shutdown(struct device *_dev)
{
\tstruct platform_device *dev = to_platform_device(_dev);
\tstruct platform_driver *drv;
\textern bool kexec_in_progress;

\tif (!_dev->driver)
\t\treturn;

\tif (kexec_in_progress && dev->num_resources > 0 &&
\t    dev->resource[0].start == 0x04a94000) {
\t\tpr_emerg("TWKEXEC: GENI UART platform shutdown skipped dev=%s\\n",
\t\t\t dev_name(_dev));
\t\treturn;
\t}

\tdrv = to_platform_driver(_dev->driver);
\tif (drv->shutdown)
\t\tdrv->shutdown(dev);
}
'''
if 'TWKEXEC: GENI UART platform shutdown skipped' not in plat:
    if plat.count(oldp)!=1: raise SystemExit('platform anchor mismatch')
    plat=plat.replace(oldp,newp,1)

marker='TWKEXEC: MMC0 card shutdown skipped'
if marker not in mmc:
    sig='static void mmc_bus_shutdown(struct device *dev)\n{'
    start=mmc.find(sig)
    if start<0: raise SystemExit('mmc_bus_shutdown not found')
    brace=mmc.find('{',start); depth=0; end=None; ins=False; esc=False
    for i in range(brace,len(mmc)):
        ch=mmc[i]
        if ins:
            if esc: esc=False
            elif ch=='\\': esc=True
            elif ch=='"': ins=False
            continue
        if ch=='"': ins=True
        elif ch=='{': depth+=1
        elif ch=='}':
            depth-=1
            if depth==0: end=i+1; break
    if end is None: raise SystemExit('mmc function end not found')
    f=mmc[start:end]
    a='\tstruct mmc_card *card = mmc_dev_to_card(dev);\n'
    if f.count(a)!=1: raise SystemExit('mmc anchor mismatch')
    rr=a+'''\textern bool kexec_in_progress;

\tif (kexec_in_progress && card && card->host &&
\t    card->host->index == 0 && card->rca == 1) {
\t\tpr_emerg("TWKEXEC: MMC0 card shutdown skipped dev=%s\\n", dev_name(dev));
\t\treturn;
\t}
'''
    f=f.replace(a,rr,1); mmc=mmc[:start]+f+mmc[end:]

i2cp.write_text(i2c); serp.write_text(ser); platp.write_text(plat); mmcp.write_text(mmc)
PY

for F in "$I2C" "$SERIAL" "$PLATFORM" "$MMC"; do
  if grep -Fq '#include <linux/kexec.h>' "$F"; then
    echo "unexpected linux/kexec.h in $F" >&2; exit 3
  fi
done

grep -Fq 'TWKEXEC: BT541 I2C shutdown skipped' "$I2C"
grep -Fq 'TWKEXEC: GENI UART core shutdown skipped' "$SERIAL"
grep -Fq 'TWKEXEC: GENI UART platform shutdown skipped' "$PLATFORM"
grep -Fq 'TWKEXEC: MMC0 card shutdown skipped' "$MMC"

echo 'KEXEC_VALIDATED_MINIMAL=BT541+GENI_CORE+GENI_PLATFORM+MMC0'
echo 'KEXEC_DIAGNOSTIC_PROBES=NOT_INCLUDED'
