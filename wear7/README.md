# TicWatch Pro 5 Enduro — Wear OS 7 ROM staging

Software-side staging branch for `dace` / `monaco`.

## Current checkpoint — verified V6, 2026-09-16

**The latest completed offline candidate is Wear7 V6.** The earlier Stage0
sections below describe its history, not outstanding image-build work.

- Successful [Actions run 35146642220](https://github.com/jackk11111/config/actions/runs/35146642220), completed at 20:31 UTC.
- Verified image-building code: `d160e4f6b32d29cbecc802f3d9443fe0d2b7de44`.
- [Results, artifact links and archive checksums](V6_OFFLINE_STATUS.md).
- [Recovery preparation tools and their limits](v6/README.md).
- [Draft PR #1](https://github.com/jackk11111/config/pull/1) targets `wear7-rom-staging`; the candidate remains on `wear7-v6-offline-validation`.
- Wear7 kernel remains `5.15.220-Xinran_StarBai-Test+`. Recovery revisions R6/R7/R7.1 are a separate workstream.

The existing run closed the signed VNDK33 APEX bridge, official VINTF,
combined SELinux compilation, real Fast Pair idmap2 mapping, filesystem/AVB
reconstruction, final super extraction/comparison and package preflight.
All 12 preparation-tool tests passed. These results come from the completed
run and its downloaded report; no rebuild or test rerun is needed to resume.

**Resume at the hardware recovery/rollback gate.** Before installation,
complete the write/streaming adapter against the validated recovery and settle
the userdata migration strategy. Wi-Fi/ADB root in recovery, first Wear7
boot, pairing, hardware behavior and persistent ADB/root still require
device evidence. GitHub Actions cannot close those runtime checks.

The artifacts are a validated offline candidate, not a recovery installer.
The candidate manifest still records `flash_authorized=false`,
`recovery_integration=UNTESTED` and `userdata_migration=UNTESTED`.
Keep the completed offline gates closed unless their inputs change or new
contradictory evidence appears. Do not merge or flash solely because CI is green.

## Frozen first-build architecture

- SYSTEM: Pixel Watch 3 `solios` Wear OS 7 / Android 17 / API 37, build `CP2A.260603.001.S1`.
- SYSTEM_EXT: Pixel base + exactly six stock TicWatch compatibility bridges listed in `manifests/STAGE0_SOURCE_HASHES.tsv`.
- PRODUCT: Pixel Wear/Google base + stock Enduro Fast Pair overlay.
- Pairing: retain stock `TicCompanionWear.apk` and Mobvoi vendor pairing properties.
- VENDOR / VENDOR_DLKM / SYSTEM_DLKM: stock TicWatch `TMDB.240925.002/379`.
- BOOT chain: only final TicWatch kernel/recovery handoff; never Pixel/Xiaomi boot/vendor firmware.
- No wholesale Android 13 system_ext/JAR/oat/odex/vdex or SELinux transplant.
- Do not include stock `libseccam.so` in the first build.
- Preserve Pixel GMS Wear APEX + Chimera unchanged.
- No persistent Wear OS 7 flash until dedicated recovery/rollback is physically validated.

## Recovered Stage0 source

Source archive regenerated from the authoritative TicWatch 379 full BLOCK OTA on 2026-09-15:

- Archive SHA-256: `d6c18d45c8fe6b9c0901555465f7fa353cb2f4947cd24dfeb3bec8de574d2072`
- TicWatch OTA SHA-256: `ffa61d822a5c667c230ce2ba9426ce4eb282adcaa0891279ef002f65ca15a08d`
- Payload count: 8
- All six native bridges verified ELF32 ARM / Android 33.
- `TicCompanionWear.apk` and `DaceEnduroFastPairOverlay.apk` match the hashes frozen in the V9 handoff.

The binary payload itself is not committed here. It is reproducibly extracted from stock OTA 379 and tracked by hashes.

## Pixel final static preflight — 2026-09-15

`Wear7_Pixel3_FINAL_PREFLIGHT_INPUTS_20260915_084456.tar.gz` was analyzed against the frozen Stage0/V9 architecture.

Result: **PASS — Pixel software donor-side static preflight closed.**

Confirmed:
- all six retained-stock-vendor -> Android17 framework HIDL contracts are satisfied;
- Enduro FastPair resource target still exists in Wear7 SetupWizard;
- GMS Wear APEX hash and required Chimera modules are intact;
- Gemini/Assistant remains wired as a Wear7 system/privileged component;
- Android17 already defines the `oem_companion_prop` SELinux type/rules needed by the Mobvoi companion property contract;
- Pixel SW5100/GoogleBattery/WAC/WatchCharger/DisplayOffload-specific requirements must be sanitized as frozen in Stage0;
- FCM7 remains the target and `wristorientation/default` is retained.

Full findings and remaining image-build gates are in `manifests/PIXEL_FINAL_PREFLIGHT_2026-09-15.txt`.

The offline image gates listed in this historical Stage0 section were subsequently completed by V6 above. Device recovery/rollback validation and the remaining installation/runtime gates are still open; no flash is authorized.
