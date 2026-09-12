#!/usr/bin/env bash
set -Eeuo pipefail

K="${1:-.ticwatch-preflight/common}"
CFG="${2:-$K/out/.config}"
[ -d "$K" ] || { echo "FAIL: kernel tree missing: $K" >&2; exit 1; }
[ -f "$CFG" ] || { echo "FAIL: kernel config missing: $CFG" >&2; exit 1; }

SC="$K/scripts/config"
[ -x "$SC" ] || chmod +x "$SC"

# Rescue / bring-up capability. Classic kexec is deliberate: keep the
# narrower, proven interface and avoid extra KEXEC_FILE/SIG complexity.
"$SC" --file "$CFG" -e KEXEC -d KEXEC_FILE -d KEXEC_SIG -d CRASH_DUMP

# Required for the TicWatch ARM32 vendor/userspace compatibility model.
"$SC" --file "$CFG" -e COMPAT

# Proven performance/memory/network baseline already used on MAX-LTS.
"$SC" --file "$CFG" -e LRU_GEN -e LRU_GEN_ENABLED -d LRU_GEN_STATS
"$SC" --file "$CFG" -e TCP_CONG_ADVANCED -e TCP_CONG_CUBIC -e TCP_CONG_BBR -e DEFAULT_BBR -d DEFAULT_CUBIC -e NET_SCH_FQ

# Persistent diagnostics are more valuable than benchmark-oriented tweaks
# for recovery and Wear OS bring-up. The dace DT already has a ramoops
# reserved-memory node in stock recovery; if the boot DT exposes it too,
# these make panic/console/userspace pmsg records available after reboot.
"$SC" --file "$CFG" -e PSTORE -e PSTORE_RAM -e PSTORE_CONSOLE -e PSTORE_PMSG -d PSTORE_FTRACE

# Do NOT change zRAM compressor/size here: Wear OS userspace owns the policy.
# Keep the proven Android mechanisms available and fail if an uplift drops them.

printf '%s\n' 'Wear7 kernel profile staged; run olddefconfig before verification.'
