#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${1:-KSUN/manager}"
cd "$ROOT"

python3 - <<'PY'
from pathlib import Path
p = Path('build.gradle.kts')
s = p.read_text()
old1 = 'abiFilters("arm64-v8a", "x86_64")'
old2 = 'abiFilters += listOf("arm64-v8a", "x86_64")'
if s.count(old1) != 1 or s.count(old2) != 1:
    raise SystemExit('unexpected KernelSU Next v3.3.0 ABI-filter layout')
s = s.replace(old1, 'abiFilters("armeabi-v7a")', 1)
s = s.replace(old2, 'abiFilters += listOf("armeabi-v7a")', 1)
p.write_text(s)
PY

grep -F 'abiFilters("armeabi-v7a")' build.gradle.kts
grep -F 'abiFilters += listOf("armeabi-v7a")' build.gradle.kts
