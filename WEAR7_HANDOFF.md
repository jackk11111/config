# TicWatch Pro 5 (dace) — Wear 7 clean rebuild

## Canonical working line
- Branch: `wear7-clean-rebuild-20261003`
- Baseline before repository cleanup: `b53c48cf5a3e1e1c5cdf76d933f84dbeda34eea7`
- Current target: `WEAR7_DACE_CLEAN_V1`
- Current workflow: `.github/workflows/wear7-clean-kernel-515220-noksu-v2-20261003.yml`
- Failed run to diagnose: `37119904617`
- Failed job: `111193832422`
- First real gate: `Compile clean kernel`

## Required clean kernel baseline
- Kernel: `5.15.220`
- Exact expected release: `5.15.220-Xinran_StarBai-Test`
- KMI map: 337 symbols
- First boot must contain NO KernelSU, NO SuSFS and NO AUTOINIT.
- Do not reintroduce KernelSU Next 3.4.0 / SuSFS 2.3.0 until the clean Wear 7 baseline boots and is qualified.

## Platform/source decisions already made
- Wear 7 `system`, `system_ext`, `product`: Pixel Watch 3 donor.
- TicWatch stock 379: hardware/vendor source.
- Xiaomi Watch 2 Pro Wear 5: only a possible minimal Qualcomm W5+ compatibility bridge if evidence requires it.

## Recovery/device state already solved
- Recovery Wi-Fi ADB works.
- `watchadb` works.
- Root in recovery works.
- `/data` is decrypted.
- Physical `super` is writable.
- Do NOT reopen recovery, Wi-Fi, data-decryption or super-write work without new evidence.
- Normal device-side work should use phone + Termux + recovery Wi-Fi; Odroid/fastboot only when bootloader/fastboot is actually required.

## Closed / exhausted routes
- DIAG11/12-style marker accumulation and repeated live `super` micro-patches are not the current route.
- Do not run more device diagnostics while the GitHub clean-kernel compile gate is failing.
- Do not wipe the watch until a successful kernel artifact is audited and an install candidate exists.

## Historical build provenance still relevant
- Last successful 5.15.220 artifact run used by V2: `36862935998`.
- Artifact name used by V2: `sony-kernel-5.15.220-Xinran_StarBai`.
- Useful historical commits/branches remain in git history. Old diagnostic workflows are intentionally removed from the active workflow directory; their commits are not rewritten or destroyed.
- Kernel line checkpoints still referenced by the project include orchestrator `ba33c66c36981cd024e48326b459684605c667a9` and the prior pinned baseline/ASB/tooling values recorded in the build history.

## Next exact action
1. Read the FIRST compiler failure from job `111193832422` / run `37119904617`.
2. Fix only that cause in the clean-kernel V2 workflow/source preparation.
3. Launch exactly one new build.
4. If it succeeds, audit Image, exact release, KMI=337 and absence of KSU/SuSFS/AUTOINIT before touching the watch.

## Repository hygiene rule
Only the current clean-kernel workflow stays active on this branch. Superseded DIAG/probe/final-candidate workflows remain recoverable through git history instead of cluttering the active Actions surface. A future assistant should start from this file and this branch, not revive old experiments unless new evidence points back to them.
