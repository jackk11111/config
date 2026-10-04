# Recovery — active runtime work

Recovery repair is intentionally isolated from the clean kernel/Wear 7 baseline.

The static recovery-preservation V2C build completed successfully in run `37190714084`, but recovery is currently being reworked because the real runtime path has not yet been accepted as working. Do not promote that static success to a runtime-qualified recovery baseline.

Active recovery work remains on `wear7-clean-rebuild-20261003` until the first failed runtime gate is corrected and verified on-device.

Temporary refs still required by the active recovery/provenance chain:

- branch `ticwatch-max-lts-220`
- branch `ticwatch-max-lts-220-incremental`
- branch `wear7-diag4-init-bisect-20261002`
- tag `wear7-diag3-final-20261002`

These refs are not canonical product branches. Remove them only after the final recovery is runtime-qualified and every still-required input has been consolidated into the canonical tree.
