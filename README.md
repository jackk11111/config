# Evolution X Android 17 — POCO F8 Pro / Redmi K90 (annibale)

This public repository is repurposed from an older TicWatch project; its previous
history remains reachable through older Git commits. The GitHub repo name was not
renamed because the available connection cannot change repository settings.

## Purpose
Free, **manual** GitHub Actions preflight only. No full Android sync, no ROM build,
no phone flashing, no Git LFS binary payloads pushed to GitHub.

## Pinned baseline (2026-10-10)
- EvoX cnb manifest SHA: `8e41c899421748f2738a60e5757a0be2c3e353bb`
- Annibale device / kernel / main proprietary vendor / hardware Xiaomi are pinned
  in `manifest/annibale.xml`.
- The five missing proprietary ArcSoft libraries were reconstructed and audited
  locally; the binary files **are intentionally NOT stored in this repository**.
- The standalone MiuiCamera Android 16 vendor is NOT part of CORE.

## Run
Actions → **EvoX Android 17 - annibale preflight (free)** → Run workflow:
1. `manifest` (resolve manifests, check collisions and SHA)
2. If 1 passes, `device` (sync only device/kernel/hardware Xiaomi)
3. `vendor-metadata` only for public GitLab branch SHA, not the vendor binary checkout.

This configuration requires a public repository for free standard GitHub runners.
A passing CI preflight does not demonstrate a successful ROM build or runtime stability.
