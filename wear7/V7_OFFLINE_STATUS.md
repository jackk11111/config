# Wear7 V7 — final offline readiness checkpoint

Date: 2026-09-17

## Result

**Wear7-V7 is the frozen software-side candidate for the first controlled boot.**
The known software work that can be completed without a physically qualified
recovery is closed. Flash remains blocked because recovery transport/reset/
persistence/rollback qualification is intentionally still open.

This is not a claim that every hardware feature already works at runtime. Those
checks necessarily start after the first Wear7 boot.

## Frozen candidate

- V7 build/gate run: `35198609607` — SUCCESS.
- Candidate source commit: `6125c80f798994ee53749f85a833c24da5940765`.
- Kernel: `5.15.220-Xinran_StarBai-Test+`.
- Device/platform: `dace` / `monaco`, single slot.
- Stock hardware base: TicWatch OTA 379 (`TMDB.240925.002/379`).
- Wear7 donor base: Pixel Watch 3 `solios`, Wear OS 7 / Android 17.

V7 artifacts:

| Artifact | ID | GitHub artifact SHA256 digest |
| --- | ---: | --- |
| Wear7-V7-Bootchain | `10487365357` | `8182d3de6d3d655f8db0884a80bdcd2644e38ad02d810f6781d17a55d35d1cee` |
| Wear7-V7-Super | `10487078616` | `54530a813d2df348c1dce2cd632e91e261e0989691a4657a1f436a771f483950` |
| Wear7-V7-Offline-Analysis | `10486949127` | `ce6b020c76da5378446764ab0dbf094fe6f23908967e0130472baffd8b0c4d5e` |

Current expiry: 2026-12-16 08:14 UTC.

Important image hashes from `CANDIDATE.json`:

- `super.img` sparse: `2a73517c4356dce6995641b4cf2ac82b50e1c0b0fec7ee46decbd4fe122399f6`
- expanded super (4 GiB): `f8fd0557983de6f5f9806ac1582bfc7d0e9fce59bfcbc7793b8af83884ac76bd`
- `boot.img`: `f5173a192b1d1e335198aa04ef8f47928d87b26d793fd9621737f211143c8353`
- `vendor_boot.img`: `9d7cd2a5f7a21e9554552e94aaf89c2fdc6d036f59c8e8abe355456f8a5f18cf`
- `init_boot.img`: `c128f41b1e1fe4a2062b1b8464bf8e01650419f158ab7d412a3bf1f0099c9884`
- `dtbo.img`: `eb2a8d0028b6e22898b26e4bc71419190a4ea3431a2b66c6c57d9e280ade4c96`
- `vbmeta_system.img`: `22f24ebea86ea2dac15723449b477870133fac0703d9c07be32d89f2b7fe7a76`
- `vbmeta.img`: `384106d0f635631f5e4ddd96cd7847965af4e0687fb517ecee1cb4096c007259`

## What V7 closed

V7 starts from the exact already-gated V6 images and adds only the ARM32
compatibility libraries missing for the retained TicWatch Android-13-era vendor
services. Eleven libraries are copied from the pinned stock 379 system only when
the donor path is absent; overwriting donor files is refused.

`NATIVE_STOCK32_COMPAT=PASS`:

- 2,628 ARM32 ELF records inspected.
- 11 stock379 compatibility libraries pinned by SHA256 and SELinux label.
- 20 critical TicWatch native targets audited.
- Zero recursive `DT_NEEDED` gaps on those targets.
- Zero unresolved strong imports on those targets.

The audited targets cover Wi-Fi, Bluetooth, Bluetooth audio, audio,
SoundTrigger, NFC, KeyMint, secure element, GNSS, sensors, health, power,
vibrator and related QTI native services.

After rebuilding, `system_ext`, `product`, `vendor`, `vendor_dlkm` and
`system_dlkm` are required by the build code to remain byte-for-byte identical
to the V6 inputs after extracting the final shipped `super.img`. The rebuilt
`system` is compared semantically for contents, ownership, modes, symlinks,
capabilities and SELinux xattrs, then the offline gates are repeated on the
system actually extracted from the final super.

## Closed static gates

The final V7 evidence has PASS for:

- signed VNDK33 bridge and active `com.android.vndk.v33` APEX;
- official VINTF compatibility;
- combined SELinux policy compilation;
- Enduro Fast Pair RRO + real `idmap2` mapping (`3D558B`);
- final system filesystem semantics;
- AVB/vbmeta reconstruction and dynamic-partition round trip;
- native ARM32 dependency closure for the retained TicWatch hardware stack;
- package preflight and checksums.

The V7 final filesystem still contains the pinned Wear7 components used by the
project requirements, including:

- `AssistantWearPrebuilt.apk` and its Pixel Wear7 privileged policy;
- `WearServicesGoogle.apk`;
- `WearHealthServicesPrebuilt.apk`;
- `ClockworkSetupWizard.apk`;
- `com.google.android.wearable.jar` and `wear-service.jar`;
- stock `TicCompanionWear.apk`;
- `PrebuiltTapAndPayWearable.apk`.

The Pixel GMS Wear/product lineage and Chimera base were already validated in
the donor/V6 path. V7 does not rebuild those non-system logical partitions; the
final-super round-trip requires them to remain identical to V6.

## Installer V7

The installer is now frozen to the exact V7 manifest in
`installer/candidate-v7.json`; `installer/wear7_installer_v7.py` reuses the
bounded transport/rollback backend without weakening any recovery gate.

Final installer/readiness run: `35204005190` — SUCCESS.

That run:

1. downloaded the real V7 Bootchain, Super and Offline-Analysis artifacts;
2. verified every `SHA256SUMS.txt` entry;
3. compared the artifact manifest with the frozen installer manifest;
4. re-ran the transport regression tests;
5. executed `plan` against the real V7 images, including streaming and hashing
   the sparse super as exactly 4 GiB expanded data;
6. ran the final software-side readiness gate;
7. produced `Wear7-V7-Final-Offline-Readiness` artifact ID `10489645436`,
   digest `8664972167c46d9fc85cc94d03f32d8242e1e0987c728ec53f3e247a454f8fd8`.

The generated transfer plan is fixed to:

`super -> vendor_boot -> init_boot -> dtbo -> boot -> vbmeta_system -> vbmeta`

with 16 MiB chunks. The 4 GiB expanded super is 256 chunks. Userdata,
metadata, recovery, misc and persist remain outside the image transport; there
is no automatic reboot.

Clean setup remains the selected first-bring-up strategy. User reset consent is
already recorded. The actual reset implementation remains deliberately pending
because it must match the final recovery fstab/encryption behavior.

## Only known blocker before first Wear7 boot

`FINAL_READINESS.json` reports:

`known_pre_first_boot_blockers = [RECOVERY_INTEGRATION_AND_ROLLBACK_QUALIFICATION]`

This recovery work includes the parts that cannot honestly be closed offline:

- authenticated Wi-Fi/ADB root transport on the final recovery;
- ability to keep `super` and its logical partitions inactive during writing;
- RAM scratch/watchdog behavior during the long transfer;
- correct clean-reset handling for F2FS/data + metadata/encryption;
- preservation/restoration of rescue Wi-Fi/ADB configuration through reset;
- recovery persistence/protection after the clean wipe;
- interruption handling, physical re-entry and verified stock rollback using
  the actual watch and the final recovery image.

`installer/validated-recoveries.json` therefore remains intentionally empty and
hardware writes remain blocked. No force bypass exists.

## What remains after recovery is qualified

These are **first-boot/runtime tests**, not additional offline build blockers:

- boot completion and SetupWizard;
- companion pairing / Fast Pair;
- Google Play and GMS runtime behavior;
- native Gemini setup, invocation and real response;
- NFC / Tap & Pay runtime behavior;
- Wi-Fi and Bluetooth;
- audio and SoundTrigger;
- display/touch, sensors, GNSS, haptics, health, power, charging and suspend;
- persistent ADB/root and recovery behavior after reboot.

Static presence and dependency closure reduce risk but cannot prove those
runtime behaviors before booting the real hardware.

## Current decision

**Software-side pre-first-boot readiness: PASS.**

**Flash authorization: NO**, solely because the final recovery/rollback path is
not yet physically qualified. Do not replace or rebuild the frozen V7 images
unless recovery findings expose a real ROM-side requirement or new contrary
evidence appears.
