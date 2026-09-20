# TicWatch Pro 5 Enduro — Wear OS 5 Port

## Verified target baseline
- Device: TicWatch Pro 5 Enduro
- Codename: dace
- Stock build: TMDB.240925.002
- Stock OTA: OTA_WEAR4_379.zip / OTA_WEAR4_379_ORIGINALE.zip
- Known-good updated kernel: 5.15.220-Xinran_StarBai-Test+
- Known-good boot image: boot_CURRENT_WORKING_5.15.220.img
- Kernel branch: ticwatch-max-lts-220
- Rescue recovery package: TicWatch-RECOVERY-FINAL-VAULT-V2-20260918.zip
- Recovery branch: ticwatch-recovery-v1

## Donor
Xiaomi Watch 2 Pro Wear OS 5 / Android 14 OTA.

Before any build, identify whether the OTA is:
- axolotl / M2234W1 (Bluetooth)
- axolotlte / M2233W1 (LTE)

## Port rule
Do NOT flash the Xiaomi image wholesale.

Use Xiaomi primarily as the Wear OS 5 / Android 14 system/framework donor.
Preserve or adapt TicWatch hardware-specific components: vendor/odm stack, device tree, vendor_boot/init_boot as required, kernel modules, display/AON/ULP stack, sensors, power/charging, buttons/crown, NFC, audio, Wi-Fi/Bluetooth/GNSS and Mobvoi-specific services required by the target hardware.

## Fast-path gates
1. Read exact Xiaomi OTA metadata, fingerprint, SPL and partition list.
2. Extract both OTAs and compare super layout, VINTF manifests/matrices, vendor API/VNDK levels, init rc, SELinux policy, fstab, kernel modules and firmware.
3. Establish the smallest first-boot transplant set.
4. Verify KMI/module ABI before pairing the 5.15.220 kernel with target vendor_dlkm/odm_dlkm.
5. Build one candidate only after static compatibility checks pass.
6. First boot goal: kernel -> userspace -> adbd -> SystemUI/launcher -> touch/crown -> Wi-Fi/Bluetooth.
7. Add sensors, NFC and ULP display only after basic boot is stable.
8. Stop a path after repeated identical failure signatures; change the hypothesis instead of version-churning.

## Do not mix in
Wear OS 7 / Android 16/17 experiments, old V6–V11 diagnostic super images, or Wear 7 charger/init bypasses.
