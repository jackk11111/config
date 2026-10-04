# TicWatch Pro 5 (dace) — canonical workspace

Standalone repository for the TicWatch Pro 5 `dace` Wear 7 / kernel / recovery project.

## Canonical progression

1. **Kernel — clean baseline (2026-10-03)**
   - Linux `5.15.220-Xinran_StarBai-Test+`
   - no KernelSU, no SuSFS, no diagnostic KEXEC patches
   - KMI gate `337/337`
   - qualified run `37183075933`
   - artifact `TicWatch-Wear7-Clean-Kernel-5.15.220-NoKSU-V2`
   - Image SHA-256 `c37800338faa30d6600bd9e422c57d839148e6029a03daa351fe338b68b533a7`

2. **Wear 7 — CLEAN V1 (2026-10-04)**
   - canonical source: `wear7/current/`
   - latest verified source rebuild run `37204998782`
   - clean kernel is hard-gated before candidate assembly
   - final on-device boot, hardware and pairing qualification still pending

3. **Recovery — runtime-qualified (2026-10-04)**
   - final AUTODATA SHA-256 `8d6d4f92bce999fbe2bfed0ce5b5bbeb60d08cc8dbd1df4dbdf15b4d623af0c3`
   - full A13 runtime bundle SHA-256 `ee0cdd779c1057b8cd5eed2f0e1ba3ea605466b6653b9e84353763dd95807f80`
   - real cold boot passed HWSM, QSEE, Keymaster, Keystore2, Vold, `/data` RW and `/data/adb/modules` RW
   - final gate `RESULT=AUTODATA_FULLROOT755_COLD_BOOT_PASS`
   - recovery is closed unless new contradictory runtime evidence appears

## Current tree

- `kernel/` — clean kernel baseline and provenance
- `wear7/` — current Wear 7 CLEAN V1 source only
- `recovery/` — final recovery runtime provenance and freeze boundary
- `.github/workflows/` — canonical kernel and Wear 7 build workflows only

Historical probes, failed experiments, obsolete Wear trees and former NikGapps working-tree content are not part of the canonical `main` tree.

The project focus is now the clean Wear 7 baseline. KernelSU Next 3.4.0 and SuSFS are intentionally deferred until the clean Wear 7 build boots and is qualified on-device.
