# TicWatch Pro 5 Enduro — Wear OS 7 ROM staging

Software-side staging branch for `dace` / `monaco`.

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
