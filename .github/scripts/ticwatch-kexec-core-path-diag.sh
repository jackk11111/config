#!/usr/bin/env bash
set -Eeuo pipefail

K="${1:?usage: $0 <kernel-tree>}"
KC="$K/kernel/kexec_core.c"

[ -f "$KC" ] || { echo "missing $KC" >&2; exit 2; }

python3 - "$KC" <<'PY'
from pathlib import Path
import sys

p = Path(sys.argv[1])
s = p.read_text()
if 'TWKEXEC_PATH: RESTART_PREPARE BEFORE' in s:
    print('KEXEC core path diagnostics already present')
else:
    old = '''\t\tkexec_in_progress = true;\n\t\tkernel_restart_prepare("kexec reboot");\n\t\tmigrate_to_reboot_cpu();\n'''
    new = '''\t\tkexec_in_progress = true;\n\t\tpr_emerg("TWKEXEC_PATH: RESTART_PREPARE BEFORE\\n");\n\t\tkernel_restart_prepare("kexec reboot");\n\t\tpr_emerg("TWKEXEC_PATH: RESTART_PREPARE AFTER\\n");\n\t\tpr_emerg("TWKEXEC_PATH: MIGRATE BEFORE\\n");\n\t\tmigrate_to_reboot_cpu();\n\t\tpr_emerg("TWKEXEC_PATH: MIGRATE AFTER\\n");\n'''
    if s.count(old) != 1:
        raise SystemExit(f'kexec restart/migrate anchor mismatch: {s.count(old)}')
    s = s.replace(old, new, 1)

    old2 = '''\t\tcpu_hotplug_enable();\n\t\tpr_notice("Starting new kernel\\n");\n\t\tmachine_shutdown();\n'''
    new2 = '''\t\tpr_emerg("TWKEXEC_PATH: CPU_HOTPLUG_ENABLE BEFORE\\n");\n\t\tcpu_hotplug_enable();\n\t\tpr_emerg("TWKEXEC_PATH: CPU_HOTPLUG_ENABLE AFTER\\n");\n\t\tpr_emerg("TWKEXEC_PATH: STARTING_NEW_KERNEL BEFORE\\n");\n\t\tpr_notice("Starting new kernel\\n");\n\t\tpr_emerg("TWKEXEC_PATH: MACHINE_SHUTDOWN BEFORE\\n");\n\t\tmachine_shutdown();\n\t\tpr_emerg("TWKEXEC_PATH: MACHINE_SHUTDOWN AFTER\\n");\n'''
    if s.count(old2) != 1:
        raise SystemExit(f'kexec hotplug/machine_shutdown anchor mismatch: {s.count(old2)}')
    s = s.replace(old2, new2, 1)

    old3 = '''\tkmsg_dump(KMSG_DUMP_SHUTDOWN);\n\tmachine_kexec(kexec_image);\n'''
    new3 = '''\tpr_emerg("TWKEXEC_PATH: KMSG_DUMP BEFORE\\n");\n\tkmsg_dump(KMSG_DUMP_SHUTDOWN);\n\tpr_emerg("TWKEXEC_PATH: KMSG_DUMP AFTER\\n");\n\tpr_emerg("TWKEXEC_PATH: MACHINE_KEXEC BEFORE\\n");\n\tmachine_kexec(kexec_image);\n\tpr_emerg("TWKEXEC_PATH: MACHINE_KEXEC RETURNED\\n");\n'''
    if s.count(old3) != 1:
        raise SystemExit(f'kexec machine_kexec anchor mismatch: {s.count(old3)}')
    s = s.replace(old3, new3, 1)

    p.write_text(s)
PY

for M in \
  'TWKEXEC_PATH: RESTART_PREPARE BEFORE' \
  'TWKEXEC_PATH: RESTART_PREPARE AFTER' \
  'TWKEXEC_PATH: MIGRATE BEFORE' \
  'TWKEXEC_PATH: MIGRATE AFTER' \
  'TWKEXEC_PATH: CPU_HOTPLUG_ENABLE BEFORE' \
  'TWKEXEC_PATH: CPU_HOTPLUG_ENABLE AFTER' \
  'TWKEXEC_PATH: STARTING_NEW_KERNEL BEFORE' \
  'TWKEXEC_PATH: MACHINE_SHUTDOWN BEFORE' \
  'TWKEXEC_PATH: MACHINE_SHUTDOWN AFTER' \
  'TWKEXEC_PATH: KMSG_DUMP BEFORE' \
  'TWKEXEC_PATH: KMSG_DUMP AFTER' \
  'TWKEXEC_PATH: MACHINE_KEXEC BEFORE' \
  'TWKEXEC_PATH: MACHINE_KEXEC RETURNED'; do
  grep -Fq "$M" "$KC"
done

echo 'TICWATCH_KEXEC_CORE_PATH_DIAGNOSTICS=APPLIED'
echo 'TICWATCH_KEXEC_CORE_PATH_BEHAVIOR_CHANGE=NONE'

# The original cpu_soft_restart()/cpu-reset.S path has already been localized
# on real hardware through PHYS_RESTART BEFORE without reaching the rescue
# kernel. Replace that legacy transition with the coherent upstream arm64
# v5.16 MMU-enabled relocation series plus its known runtime fixes. This script
# snapshots all TicWatch KEXEC-only quirks above before applying the series.
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
bash "$SCRIPT_DIR/ticwatch-kexec-arm64-mmu-reloc-backport.sh" "$K"
echo 'TICWATCH_KEXEC_LEGACY_ARM64_PATH=SUPERSEDED_BY_MMU_RELOC_BACKPORT'
