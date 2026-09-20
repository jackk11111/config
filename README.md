# TicWatch Pro 5 Enduro — Wear OS 5 Port

Target: TicWatch Pro 5 Enduro (Snapdragon W5+ Gen 1, 2 GB / 32 GB, 466x466).
Donor: Xiaomi Watch 2 Pro Wear OS 5 / Android 14 OTA.
Kernel: keep the known-good TicWatch updated kernel branch (ticwatch-max-lts-220).
Recovery: keep the wireless rescue-recovery work separate (ticwatch-recovery-v1).

## Port rule

Do NOT flash the Xiaomi image wholesale.

Use Xiaomi primarily as the Wear OS 5 / Android 14 system-framework donor.
Preserve/adapt TicWatch hardware-specific components: vendor/odm stack, device tree, vendor_boot/init_boot as required, kernel modules, display/AON/ULP stack, sensors, power/charging, buttons/crown, NFC, audio, Wi-Fi/Bluetooth/GNSS and Mobvoi-specific services needed by the hardware.

## Fast-path gates

1. Identify exact Xiaomi OTA variant (BT axolotl vs LTE axolotlte), build fingerprint, SPL and partition list.
2. Extract both OTAs and compare super layout, VINTF manifests/matrices, vendor API/VNDK levels, init rc, SELinux policy, fstab, kernel modules and firmware.
3. Establish the smallest first-boot transplant set.
4. Build one candidate only after static compatibility checks pass.
5. First boot goal: adb + SystemUI + launcher + touch/crown + Wi-Fi/Bluetooth. Add sensors/NFC/ULP display only after basic boot is stable.
6. Stop a path after repeated identical failure signatures; change the hypothesis instead of version-churning.

## Do not mix in

Wear OS 7 / Android 16/17 experiments, old V6–V11 diagnostic super images, or Wear 7 charger/init bypasses.
