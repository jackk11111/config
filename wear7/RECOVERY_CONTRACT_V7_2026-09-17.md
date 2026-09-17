# Wear7 V7 — recovery integration contract

Date: 2026-09-17

This file is the handoff boundary between the frozen Wear7 V7 ROM candidate and
the custom-recovery workstream. It deliberately contains no recovery
implementation assumptions beyond what the installer actually requires.

## Frozen ROM side

Do not rebuild or change the Wear7 images merely to accommodate an unqualified
recovery. The current ROM candidate is the successful V7 from run `35198609607`
and its final software-side readiness gate is PASS.

The installer is bound to the exact V7 manifest in `installer/candidate-v7.json`.
Hardware writes remain blocked until a final recovery profile is added to
`installer/validated-recoveries.json` from real-watch evidence.

## Mandatory recovery properties

A recovery is acceptable for the Wear7 V7 install path only if all of the
following are demonstrated on the real TicWatch Pro 5 Enduro (`dace`/`monaco`).

### 1. Identity and entry

- device is `dace`, platform `monaco`, non-A/B/single-slot as expected;
- bootloader remains unlocked;
- physical re-entry to recovery is demonstrated independently of Android boot;
- exact recovery partition SHA256 is recorded.

### 2. Authenticated rescue transport

- Wi-Fi comes up reliably in recovery;
- ADB is authenticated (`ro.adb.secure=1`) and already UID 0;
- the transport remains available for the complete install/rollback session;
- recovery configuration/ADB keys are persistent or deterministically
  restorable after the clean reset.

### 3. Super must be writable while transport stays alive

The installer writes the physical `super` partition. Therefore, immediately
before and throughout every write:

- `/system`, `/system_root`, `/vendor`, `/product`, `/system_ext`,
  `/vendor_dlkm` and `/system_dlkm` are not mounted;
- the physical `super` block device has no active device-mapper holders;
- Wi-Fi/ADB must not depend at that moment on binaries, firmware or libraries
  that disappear when those mappings are removed;
- the recovery must not silently recreate those holders during transfer.

This is the principal incompatibility found in R7.2 and must be solved by the
recovery workstream, not bypassed in the ROM installer.

### 4. Transfer scratch and watchdog

- `/tmp` is verified as tmpfs/ramfs;
- enough working RAM exists for the installer's bounded 16 MiB transfer block
  plus recovery/network overhead;
- watchdog/health logic cannot reboot or kill the recovery during a long
  multi-gigabyte transfer;
- loss of the phone/ADB connection leaves the watch in recovery instead of
  automatically attempting Android boot.

### 5. Clean reset

The first controlled V7 bring-up uses the already-authorized CLEAN_SETUP path.
The recovery must provide a procedure that is correct for the actual dace
partition/fs/encryption configuration, including:

- `/data` F2FS handling;
- metadata/encryption handling consistent with the real device and final
  recovery fstab;
- no indiscriminate erase of unrelated partitions;
- preservation/restoration of the rescue Wi-Fi/ADB configuration before any
  reboot;
- no assumption that restoring only ROM images restores previously encrypted
  userdata.

The installer intentionally does not implement generic `mkfs`/erase commands.

### 6. Recovery persistence after wipe

A clean `/data` reset removes the old Wear4 `/data/adb` recovery guard. Before
Wear7 is first booted, demonstrate that the final recovery either does not need
such a guard or has an independent persistence/protection mechanism that
survives the clean setup. Do not rely on the old Wear4 module being present.

### 7. Interruption and rollback qualification

Before the V7 install is authorized, demonstrate with the final recovery:

- bounded transfer/readback on the real block devices;
- recovery after an intentionally interrupted transfer without automatic boot;
- physical re-entry after interruption;
- complete verified rollback of the seven ROM image partitions;
- SHA256 hashes of the exact rollback images used in that successful test.

The seven installer-managed partitions are:

`super`, `vendor_boot`, `init_boot`, `dtbo`, `boot`, `vbmeta_system`, `vbmeta`.

Rollback evidence must correspond to the same physical watch and recovery
identity. `userdata` and `metadata` are outside that ROM-image rollback scope.

## Profile needed by the installer

Once the above tests pass, add a profile keyed by the exact recovery SHA256 to
`installer/validated-recoveries.json` with all of these fields equal to `PASS`:

- `authenticated_wifi_root`
- `transport_with_super_inactive`
- `scratch_is_ram`
- `watchdog_safe`
- `interruption_and_readback`
- `stock_rollback`
- `physical_reentry`

The profile must also contain:

- non-empty `evidence` referencing the real test results;
- `rollback_image_sha256` containing one valid SHA256 for each of the seven
  installer-managed partitions.

The installer contains no `--force` path: absence of this evidence must continue
to block `apply` and `rollback`.

## Acceptance boundary

When this recovery contract is physically satisfied, there is no other known
offline ROM-side blocker before the first Wear7 boot.

At that point the remaining work moves to runtime validation after installation:
boot/SetupWizard, pairing/Fast Pair, GMS/Play, Gemini, NFC/Tap & Pay,
Wi-Fi/Bluetooth, audio/SoundTrigger, display/touch, sensors/GNSS/haptics/health,
power/charging/suspend, and persistence of ADB/root/recovery across reboot.

A failure in one of those runtime checks may require a later ROM fix, but it is
not evidence of a currently known missing pre-boot build component.
