#!/usr/bin/env bash
set -Eeuo pipefail

K="${1:-.ticwatch-preflight/common}"
test -d "$K"
test -f "$K/fs/f2fs/data.c"
test -f "$K/fs/f2fs/f2fs.h"
test -f "$K/drivers/tty/serial/amba-pl011.c"

grep -Fq 'static inline void f2fs_down_write(struct f2fs_rwsem *sem)' "$K/fs/f2fs/f2fs.h"
grep -Fq 'static inline void f2fs_up_write(struct f2fs_rwsem *sem)' "$K/fs/f2fs/f2fs.h"

python3 - "$K" <<'PY'
from pathlib import Path
import re
import sys

root = Path(sys.argv[1])

p = root / 'fs/f2fs/data.c'
s = p.read_text()
for raw_name, new in (
    ('down_write', 'f2fs_down_write(&io->bio_list_lock);'),
    ('up_write', 'f2fs_up_write(&io->bio_list_lock);'),
):
    # Match only the raw rwsem call.  A plain str.count() is wrong here
    # because e.g. "down_write(...)" is also a substring of
    # "f2fs_down_write(...)" and makes an already-partially-converted tree
    # look invalid (old=4/new=3 when the real state is raw=1/wrapped=3).
    rx = re.compile(rf'(?<![A-Za-z0-9_]){raw_name}\(&io->bio_list_lock\);')
    raw_n = len(rx.findall(s))
    wrapped_n = s.count(new)

    if raw_n == 1:
        s, n = rx.subn(new, s, count=1)
        if n != 1:
            raise SystemExit(f'F2FS {raw_name} replacement count invalid: {n}')
    elif raw_n == 0 and wrapped_n >= 1:
        # Idempotent re-run: the compatibility fix is already present.
        pass
    else:
        raise SystemExit(
            f'F2FS anchor state invalid: {raw_name} raw={raw_n} wrapped={wrapped_n}'
        )

    if rx.search(s):
        raise SystemExit(f'F2FS raw {raw_name} call remains after compatibility fix')
    expected = wrapped_n + raw_n
    if s.count(new) != expected:
        raise SystemExit(
            f'F2FS wrapped {raw_name} count invalid after patch: '
            f'expected={expected} got={s.count(new)}'
        )
p.write_text(s)

p = root / 'drivers/tty/serial/amba-pl011.c'
s = p.read_text()
old = 'timer_delete_sync(&uap->dmarx.timer);'
new = 'del_timer_sync(&uap->dmarx.timer);'
old_n = s.count(old)
new_n = s.count(new)
if old_n == 1 and new_n == 0:
    s = s.replace(old, new, 1)
elif old_n == 0 and new_n == 1:
    pass
else:
    raise SystemExit(f'PL011 anchor state invalid: old={old_n} new={new_n}')
p.write_text(s)
PY

grep -Fq 'f2fs_down_write(&io->bio_list_lock);' "$K/fs/f2fs/data.c"
grep -Fq 'f2fs_up_write(&io->bio_list_lock);' "$K/fs/f2fs/data.c"
grep -Fq 'del_timer_sync(&uap->dmarx.timer);' "$K/drivers/tty/serial/amba-pl011.c"
! grep -Fq 'timer_delete_sync(&uap->dmarx.timer);' "$K/drivers/tty/serial/amba-pl011.c"

echo 'ACK_5_15_220_COMPILE_COMPAT=PASS'
