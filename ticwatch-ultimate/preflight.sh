#!/usr/bin/env bash
set -Eeuo pipefail

BASE_REPO="https://github.com/Winkmoon/android_kernel_TicWatch-Pro5.git"
BASE_SHA="3929c55fbc7559af6df290d2c0f66dc551af161a"
RESUKI_REPO="https://github.com/ReSukiSU/ReSukiSU.git"
RESUKI_SHA="246d3e52e667cb72ce8f70c93b70d3b42b100b76"
SUSFS_REPO="https://github.com/ShirkNeko/susfs4ksu.git"
SUSFS_BRANCH="gki-android13-5.15"
SUSFS_SHA="415e4143ee1dd557c54d2b3d94ef098e5d1236f4"
EXPECTED_LOCALVERSION='CONFIG_LOCALVERSION="-Xinran_StarBai-Test"'

ROOT="${GITHUB_WORKSPACE:-$PWD}/.ticwatch-preflight"
REPORT="${GITHUB_WORKSPACE:-$PWD}/ticwatch-ultimate-results/preflight.txt"
mkdir -p "$(dirname "$REPORT")"
rm -rf "$ROOT"
mkdir -p "$ROOT"
: > "$REPORT"

log() { printf '%s\n' "$*" | tee -a "$REPORT"; }
fail() { log "FAIL: $*"; exit 1; }
pass() { log "PASS: $*"; }

trap 'rc=$?; if [ "$rc" -ne 0 ]; then printf "\nRESULT=FAIL rc=%s\n" "$rc" | tee -a "$REPORT"; fi' EXIT

log "TicWatch Ultimate 5.15 integration preflight"
log "BASE_SHA=$BASE_SHA"
log "RESUKI_SHA=$RESUKI_SHA"
log "SUSFS_SHA=$SUSFS_SHA"
log ""

log "[1/7] Fetch exact TicWatch source"
git clone --filter=blob:none --no-checkout "$BASE_REPO" "$ROOT/common" >>"$REPORT" 2>&1
git -C "$ROOT/common" checkout --detach "$BASE_SHA" >>"$REPORT" 2>&1
actual="$(git -C "$ROOT/common" rev-parse HEAD)"
[ "$actual" = "$BASE_SHA" ] || fail "base SHA mismatch: $actual"
pass "exact base source"

CFG="$ROOT/common/arch/arm64/configs/gki_defconfig"
grep -Fxq "$EXPECTED_LOCALVERSION" "$CFG" || fail "expected TicWatch LOCALVERSION not found"
pass "LOCALVERSION matches installed Xinran_StarBai-Test baseline"

log "[2/7] Integrate exact ReSukiSU revision"
cd "$ROOT/common"
git clone --filter=blob:none "$RESUKI_REPO" KernelSU >>"$REPORT" 2>&1
git -C KernelSU checkout --detach "$RESUKI_SHA" >>"$REPORT" 2>&1
actual="$(git -C KernelSU rev-parse HEAD)"
[ "$actual" = "$RESUKI_SHA" ] || fail "ReSukiSU SHA mismatch: $actual"

ln -sfn "../../KernelSU/kernel" drivers/kernelsu
if ! grep -qF 'obj-$(CONFIG_KSU) += kernelsu/' drivers/Makefile; then
  printf '\nobj-$(CONFIG_KSU) += kernelsu/\n' >> drivers/Makefile
fi
if ! grep -qF 'source "drivers/kernelsu/Kconfig"' drivers/Kconfig; then
  sed -i '/endmenu/i\source "drivers/kernelsu/Kconfig"' drivers/Kconfig
fi
pass "ReSukiSU pinned and linked"

log "[3/7] Fetch exact SuSFS Android 13 / Linux 5.15 revision"
git clone --filter=blob:none --branch "$SUSFS_BRANCH" --single-branch "$SUSFS_REPO" "$ROOT/susfs4ksu" >>"$REPORT" 2>&1
git -C "$ROOT/susfs4ksu" checkout --detach "$SUSFS_SHA" >>"$REPORT" 2>&1
actual="$(git -C "$ROOT/susfs4ksu" rev-parse HEAD)"
[ "$actual" = "$SUSFS_SHA" ] || fail "SuSFS SHA mismatch: $actual"
pass "SuSFS pinned"

log "[4/7] Strict kernel-side SuSFS patch compatibility check"
PATCH="$ROOT/susfs4ksu/kernel_patches/50_add_susfs_in_gki-android13-5.15.patch"
[ -f "$PATCH" ] || fail "SuSFS 5.15 kernel patch missing"
if ! git apply --check "$PATCH" >>"$REPORT" 2>&1; then
  fail "SuSFS kernel patch does not apply cleanly to exact TicWatch source"
fi
pass "SuSFS kernel patch applies cleanly"

git apply "$PATCH" >>"$REPORT" 2>&1
cp -a "$ROOT/susfs4ksu/kernel_patches/fs/." fs/
cp -a "$ROOT/susfs4ksu/kernel_patches/include/linux/." include/linux/
[ -f fs/susfs.c ] || fail "fs/susfs.c missing after integration"
[ -f include/linux/susfs.h ] || fail "include/linux/susfs.h missing after integration"
pass "SuSFS kernel files installed"

log "[5/7] Select ReSukiSU SuSFS inline hook, not Manual Hook"
scripts/config --file "$CFG" -e KSU
scripts/config --file "$CFG" -d KSU_TRACEPOINT_HOOK
scripts/config --file "$CFG" -d KSU_MANUAL_HOOK
scripts/config --file "$CFG" -e KSU_SUSFS
# Keep capability but disable permanent SuSFS kernel logging for a daily-use watch.
scripts/config --file "$CFG" -d KSU_SUSFS_ENABLE_LOG
pass "requested KSU/SuSFS config written"

log "[6/7] Resolve Kconfig"
make ARCH=arm64 O=out gki_defconfig >>"$REPORT" 2>&1
OUTCFG="$ROOT/common/out/.config"
grep -Fxq 'CONFIG_KSU=y' "$OUTCFG" || fail "CONFIG_KSU did not resolve to y"
grep -Fxq 'CONFIG_KSU_SUSFS=y' "$OUTCFG" || fail "CONFIG_KSU_SUSFS did not resolve to y"
if grep -Fxq 'CONFIG_KSU_MANUAL_HOOK=y' "$OUTCFG"; then
  fail "Manual Hook remained enabled together with SuSFS"
fi
if grep -Fxq 'CONFIG_KSU_TRACEPOINT_HOOK=y' "$OUTCFG"; then
  fail "Tracepoint Hook remained enabled together with SuSFS"
fi
grep -Fxq "$EXPECTED_LOCALVERSION" "$OUTCFG" || fail "LOCALVERSION changed after Kconfig resolution"
pass "exclusive SuSFS hook configuration resolved correctly"

log "[7/7] Prepare kernel tree"
make ARCH=arm64 O=out prepare >>"$REPORT" 2>&1
pass "kernel prepare completed"

log ""
log "Resolved key config:"
grep -E '^(CONFIG_LOCALVERSION=|CONFIG_KSU=|CONFIG_KSU_(SUSFS|MANUAL_HOOK|TRACEPOINT_HOOK)=|# CONFIG_KSU_(SUSFS_ENABLE_LOG|MANUAL_HOOK|TRACEPOINT_HOOK) is not set)' "$OUTCFG" | tee -a "$REPORT" || true
log ""
log "RESULT=PASS"
