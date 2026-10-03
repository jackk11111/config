# TicWatch Pro 5 (dace) — canonical workspace

Standalone repository for the TicWatch Pro 5 `dace` Wear 7 / kernel / recovery project.

## Canonical progression

1. **Kernel — clean baseline (2026-10-03)**
   - Linux `5.15.220-Xinran_StarBai-Test+`
   - no KernelSU, no SuSFS, no diagnostic KEXEC patches
   - KMI gate `337/337`
   - qualified run `37183075933`

2. **Wear 7 — CLEAN V1 (2026-10-04)**
   - canonical source: `wear7/current/`
   - latest verified rebuild run `37204998782`
   - clean kernel is hard-gated before candidate assembly

3. **Recovery — runtime repair in progress (2026-10-04)**
   - isolated from the clean kernel/Wear baseline
   - active branch: `wear7-clean-rebuild-20261003`
   - static CI success is not treated as runtime qualification

## Current tree

- `kernel/` — clean kernel baseline and provenance
- `wear7/` — current Wear 7 CLEAN V1 source only
- `recovery/` — active recovery boundary/status
- `.github/workflows/` — canonical build workflows only

Historical probes, failed experiments, obsolete Wear trees and former NikGapps working-tree content are not part of the canonical `main` tree.

Temporary recovery dependency refs are retained only while recovery repair is active. They must be removed after the final recovery is runtime-qualified and its required provenance has been consolidated.
