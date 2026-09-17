# TicWatch Pro 5 Enduro — Wear OS 7 ROM staging

Software-side staging branch for `dace` / `monaco`.

## Current checkpoint — frozen Wear7 V7, 2026-09-17

**Wear7 V7 is the current frozen software-side candidate for the first controlled boot.**
The known work that can be completed without the final physically-qualified
recovery is closed. The only known blocker before installation/first boot is
`RECOVERY_INTEGRATION_AND_ROLLBACK_QUALIFICATION`.

- V7 build/gate run: `35198609607` — SUCCESS.
- V7 source commit: `6125c80f798994ee53749f85a833c24da5940765`.
- Final offline-readiness run: `35204005190` — SUCCESS.
- [Frozen V7 result, hashes, installer state and remaining runtime checks](V7_OFFLINE_STATUS.md).
- [Recovery/installer integration findings](PREINSTALL_REVIEW_2026-09-17.md).
- Wear7 kernel remains `5.15.220-Xinran_StarBai-Test+`.
- Recovery development is a separate workstream and remains the sole pre-first-boot blocker.

### V7 closes the remaining known software-side compatibility gap

V7 derives from the already validated V6 images and injects eleven exact ARM32
compatibility libraries from the pinned TicWatch stock 379 system only where
the Pixel Wear7 donor does not provide them. It then rebuilds `system`, rebuilds
AVB/super, extracts the shipped super again and repeats the structural gates.

`NATIVE_STOCK32_COMPAT=PASS` covers 20 critical TicWatch native targets across
Wi-Fi, Bluetooth/Bluetooth Audio, audio/SoundTrigger, NFC, KeyMint, secure
element, GNSS, sensors, health, power and vibrator, with no recursive native
library gaps or unresolved strong imports in the audited closure.

The final V7 candidate also retains the previously closed gates:

- signed VNDK33 bridge and active VNDK33 APEX;
- official VINTF compatibility;
- combined Android17/TicWatch SELinux policy;
- Enduro Fast Pair RRO with real idmap2 mapping;
- filesystem ownership/modes/symlinks/capabilities/SELinux semantics;
- AVB/vbmeta and stock dynamic-partition topology;
- Pixel Wear/GMS framework lineage, native Assistant/Gemini base, TicCompanionWear
  and Tap & Pay components required by the first-boot candidate.

The code requires `system_ext`, `product`, `vendor`, `vendor_dlkm` and
`system_dlkm` extracted from the final V7 super to remain byte-for-byte identical
to the validated V6 inputs. Only `system` is rebuilt for the V7 ARM32 repair.

### Installer V7

`installer/candidate-v7.json` freezes the exact V7 manifest and
`installer/wear7_installer_v7.py` binds the existing bounded transport/rollback
backend to that candidate without weakening its safety gates.

The final-readiness run downloaded the real V7 Bootchain, Super and analysis
artifacts, verified their checksums and frozen manifest, re-ran the transport
regression tests, and generated a transfer plan against the actual V7 images.
The order is:

`super -> vendor_boot -> init_boot -> dtbo -> boot -> vbmeta_system -> vbmeta`

Super is streamed as 256 raw-equivalent chunks of 16 MiB; userdata, metadata,
recovery, misc and persist are not written by the image transport, and there is
no automatic reboot.

Hardware writes remain intentionally blocked because
`installer/validated-recoveries.json` is empty. There is no force override.
Clean setup/reset consent is already recorded; the actual reset operation must
be supplied by the final recovery because it must match the real F2FS/metadata/
encryption configuration.

## What the recovery workstream must close

Before the installer can be enabled, the final recovery must provide physical
evidence for:

1. authenticated Wi-Fi + ADB root on the real watch;
2. stable transport while `super` and all logical partitions inside it are inactive;
3. RAM-backed scratch space and watchdog behavior safe for the long transfer;
4. correct clean-reset handling for `/data`/metadata/encryption;
5. preservation or restoration of rescue Wi-Fi/ADB configuration through reset;
6. recovery persistence/protection after the clean wipe;
7. interruption handling, physical re-entry and verified stock rollback;
8. exact recovery SHA256 and verified rollback image hashes for the recovery profile.

Once those conditions are physically qualified, the profile can be entered in
`installer/validated-recoveries.json`; no additional known offline ROM build gate
is currently waiting behind it.

## What necessarily remains for the first Wear7 boot

These are runtime validation items, not known pre-boot build blockers:

- boot completion and SetupWizard;
- companion pairing / Fast Pair;
- Google Play and GMS runtime;
- native Gemini setup, invocation and response;
- NFC / Tap & Pay;
- Wi-Fi and Bluetooth;
- audio and SoundTrigger;
- display/touch, sensors, GNSS, haptics, health, power, charging and suspend;
- persistent ADB/root and recovery behavior after reboot.

Static presence, ABI/dependency closure and offline compatibility reduce the
risk but cannot prove these behaviors before the software runs on the real watch.

**Flash authorization remains NO until recovery/rollback qualification passes.**
Do not rebuild or replace the frozen V7 images unless the recovery workstream or
the first device boot produces concrete contrary evidence requiring a ROM-side
change.

## Frozen first-build architecture

- SYSTEM: Pixel Watch 3 `solios` Wear OS 7 / Android 17 / API 37, build `CP2A.260603.001.S1`, plus the V7 pinned stock379 ARM32 compatibility repair.
- SYSTEM_EXT: Pixel base + exactly six stock TicWatch compatibility bridges listed in `manifests/STAGE0_SOURCE_HASHES.tsv`.
- PRODUCT: Pixel Wear/Google base + stock Enduro Fast Pair overlay.
- Pairing: retain stock `TicCompanionWear.apk` and Mobvoi vendor pairing properties.
- VENDOR / VENDOR_DLKM / SYSTEM_DLKM: stock TicWatch `TMDB.240925.002/379`.
- BOOT chain: TicWatch kernel/recovery handoff only; never Pixel/Xiaomi boot/vendor firmware.
- No wholesale Android 13 system_ext/JAR/oat/odex/vdex or SELinux transplant.
- Do not include stock `libseccam.so` in the first build.
- Preserve Pixel GMS Wear APEX + Chimera lineage unchanged.
- No persistent Wear OS 7 flash until the dedicated recovery/rollback path is physically validated.

## Historical donor/source checkpoints

The authoritative TicWatch 379 full BLOCK OTA was used to regenerate the frozen
Stage0 source on 2026-09-15:

- Archive SHA-256: `d6c18d45c8fe6b9c0901555465f7fa353cb2f4947cd24dfeb3bec8de574d2072`
- TicWatch OTA SHA-256: `ffa61d822a5c667c230ce2ba9426ce4eb282adcaa0891279ef002f65ca15a08d`
- Payload count: 8
- The six original native bridges were verified ELF32 ARM / Android 33.
- `TicCompanionWear.apk` and `DaceEnduroFastPairOverlay.apk` match the frozen source hashes.

The Pixel Watch 3 donor preflight from `solios / CP2A.260603.001.S1` closed the
framework contracts, Fast Pair resource target, GMS Wear APEX/Chimera base,
Assistant/Gemini system integration, Mobvoi companion SELinux property contract,
and the donor-specific items that had to be sanitized for dace. The image-level
execution gates identified there were subsequently completed by V6 and V7.
