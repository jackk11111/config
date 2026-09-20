# Initial Wear 5 strategy

## Baseline assets
- Target stock TicWatch OTA: authoritative source for target partitions/blobs.
- Xiaomi Watch 2 Pro Wear OS 5 OTA: donor for Android 14 / Wear OS 5 framework and compatible userspace.
- ticwatch-max-lts-220: current updated TicWatch kernel line.
- ticwatch-recovery-v1: separate rescue path; do not modify while building the ROM.

## Compatibility decisions before flashing
- Exact donor SKU must be verified. Prefer Bluetooth axolotl for a non-LTE TicWatch target; never assume LTE and BT donor vendor stacks are interchangeable.
- Wear OS 5 is Android 14/API 34, so VINTF compatibility between Android 14 system and the TicWatch vendor stack must be checked before constructing super.
- Kernel replacement is not automatic: the new kernel is used only if its KMI/module ABI matches the target vendor_dlkm/odm_dlkm modules or those modules are rebuilt together.

## First candidate philosophy
Keep the TicWatch boot/hardware side as intact as possible and move only the Android/Wear userspace needed for Wear OS 5. Avoid donor vendor_boot/dtbo/vendor/odm unless a specific dependency proves necessary.

## First-boot success criteria
- kernel reaches userspace
- init completes enough to start adbd
- no VINTF fatal mismatch
- no SELinux boot-blocking denial loop
- SystemUI/launcher starts
- touch and crown input work
- Wi-Fi and Bluetooth can start

Everything else is second phase.
