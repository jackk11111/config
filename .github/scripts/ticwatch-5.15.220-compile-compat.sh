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
import sys

root = Path(sys.argv[1])

p = root / 'fs/f2fs/data.c'
s = p.read_text()
for old, new in (
    ('down_write(&io->bio_list_lock);', 'f2fs_down_write(&io->bio_list_lock);'),
    ('up_write(&io->bio_list_lock);', 'f2fs_up_write(&io->bio_list_lock);'),
):
    old_n = s.count(old)
    new_n = s.count(new)
    if old_n == 1 and new_n == 0:
        s = s.replace(old, new, 1)
    elif old_n == 0 and new_n == 1:
        pass
    else:
        raise SystemExit(f'F2FS anchor state invalid: {old!r} old={old_n} new={new_n}')
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
