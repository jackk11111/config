#!/usr/bin/env python3
from pathlib import Path
import sys

if len(sys.argv) != 2:
    raise SystemExit("usage: ultra6_patch_seb.py <slate_events_bridge.c>")

p = Path(sys.argv[1])
s = p.read_text()
old = '\tpr_info("%s: glink channel state: %d\\n", __func__, state);\n\tdev->seb_rpmsg = state;\n}'
new = '\tpr_info("%s: glink channel state: %d\\n", __func__, state);\n\tdev->seb_rpmsg = state;\n\twake_up(&dev->link_state_wait);\n}'

if s.count(old) != 1:
    raise SystemExit("SEB wakeup patch anchor mismatch")

p.write_text(s.replace(old, new, 1))
print("ULTRA6_SEB_WAKEUP_PATCH=PASS")
