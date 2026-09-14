#!/usr/bin/env bash
set -Eeuo pipefail

K="${1:?usage: $0 <kernel-tree>}"
MK="$K/arch/arm64/kernel/machine_kexec.c"

[ -f "$MK" ] || { echo "missing $MK" >&2; exit 2; }

python3 - "$K" "$MK" <<'PY'
from pathlib import Path
import re, sys

k = Path(sys.argv[1])
p = Path(sys.argv[2])
s = p.read_text(errors='replace')

print('=== TWKEXEC ARM64 SOURCE INTROSPECTION BEGIN ===')
print(f'FILE={p}')

# Print machine_kexec() exactly as restored in the build checkpoint.
start = re.search(r'(?m)^void\s+machine_kexec\s*\([^\n]*\)\s*\{', s)
if not start:
    print('ERROR: machine_kexec definition not found')
else:
    i = start.start()
    brace = s.find('{', start.start())
    depth = 0
    end = None
    in_str = False
    esc = False
    for j in range(brace, len(s)):
        c = s[j]
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
            continue
        if c == '{':
            depth += 1
        elif c == '}':
            depth -= 1
            if depth == 0:
                end = j + 1
                break
    if end:
        print('--- machine_kexec.c :: machine_kexec() ---')
        print(s[i:end])
    else:
        print('ERROR: could not structurally close machine_kexec()')

# Also print nearby helper declarations and all relevant symbol references across arm64.
terms = [
    'cpu_soft_restart', 'soft_restart', 'machine_kexec', 'relocate_new_kernel',
    'kexec_image', 'kimage->start', 'kimage->head', 'cpu_install_idmap',
    'cpu_install_ttbr0', 'IND_DONE', 'reboot_code_buffer', 'control_page',
]
print('--- ARM64 transfer-related references ---')
for f in sorted((k/'arch/arm64').rglob('*')):
    if not f.is_file() or f.suffix not in {'.c','.h','.S','.s'}:
        continue
    try:
        txt = f.read_text(errors='replace')
    except Exception:
        continue
    hits=[]
    for ln_no, line in enumerate(txt.splitlines(),1):
        if any(t in line for t in terms):
            hits.append((ln_no,line))
    if hits:
        print(f'### {f.relative_to(k)}')
        for ln_no,line in hits[:160]:
            print(f'{ln_no}: {line}')

print('=== TWKEXEC ARM64 SOURCE INTROSPECTION END ===')
raise SystemExit('ARM64 source captured; intentional fail-closed before compilation')
PY
