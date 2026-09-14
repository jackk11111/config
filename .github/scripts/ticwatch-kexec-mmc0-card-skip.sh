#!/usr/bin/env bash
set -Eeuo pipefail

K="${1:?usage: $0 <kernel-tree>}"
BUS="$K/drivers/mmc/core/bus.c"

[ -f "$BUS" ] || { echo "missing $BUS" >&2; exit 2; }

python3 - "$BUS" <<'PY'
from pathlib import Path
import sys

p = Path(sys.argv[1])
s = p.read_text()
marker = 'TWKEXEC: MMC0 card shutdown skipped'
if marker in s:
    print('MMC0 KEXEC shutdown skip already present')
    raise SystemExit(0)

sig = 'static void mmc_bus_shutdown(struct device *dev)\n{'
start = s.find(sig)
if start < 0:
    raise SystemExit('mmc_bus_shutdown signature not found')

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
    raise SystemExit('mmc_bus_shutdown end not found')

f = s[start:end]
anchor = '\tstruct mmc_card *card = mmc_dev_to_card(dev);\n'
if f.count(anchor) != 1:
    raise SystemExit(f'mmc card declaration anchor mismatch: {f.count(anchor)}')

repl = anchor + '''\textern bool kexec_in_progress;\n\n\t/*\n\t * TicWatch dace: the eMMC card bus shutdown for mmc0:0001 hangs\n\t * during kexec after all earlier device shutdown blockers are cleared.\n\t * Skip only this exact card and only while kexec is in progress.\n\t * Normal reboot/poweroff behavior remains unchanged.\n\t */\n\tif (kexec_in_progress && card && card->host &&\n\t    card->host->index == 0 && card->rca == 1) {\n\t\tpr_emerg("TWKEXEC: MMC0 card shutdown skipped dev=%s\\n", dev_name(dev));\n\t\treturn;\n\t}\n'''
f = f.replace(anchor, repl, 1)

s = s[:start] + f + s[end:]
p.write_text(s)
PY

if grep -Fq '#include <linux/kexec.h>' "$BUS"; then
  echo "unexpected linux/kexec.h include in $BUS" >&2
  exit 3
fi

grep -Fq 'TWKEXEC: MMC0 card shutdown skipped dev=%s' "$BUS"
grep -Fq 'card->host->index == 0 && card->rca == 1' "$BUS"
grep -Fq 'extern bool kexec_in_progress;' "$BUS"

echo 'TICWATCH_KEXEC_MMC0_CARD_SKIP=APPLIED'
echo 'TICWATCH_KEXEC_MMC0_CARD_SKIP_SCOPE=KEXEC_ONLY'
echo 'TICWATCH_KEXEC_MMC0_CARD_SKIP_MATCH=HOST0_RCA1'
echo 'TICWATCH_KEXEC_MMC0_CARD_SKIP_NORMAL_REBOOT=UNCHANGED'
