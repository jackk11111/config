# Kernel — clean 5.15.220 baseline

Canonical kernel baseline for Wear 7 integration:

- kernel: `5.15.220-Xinran_StarBai-Test+`
- KernelSU: absent
- SuSFS: absent
- diagnostic KEXEC patches: absent
- KMI gate: `337/337`
- qualified workflow run: `37183075933`
- artifact: `TicWatch-Wear7-Clean-Kernel-5.15.220-NoKSU-V2`
- Image SHA-256: `c37800338faa30d6600bd9e422c57d839148e6029a03daa351fe338b68b533a7`

Build workflow: `.github/workflows/wear7-clean-kernel-515220-noksu-v2-20261003.yml`.

## Baseline config snapshot

The clean kernel config provenance is stored under `kernel/baseline/` as two transport parts:

- `clean-5.15.220.config.gz.b64.part00`
- `clean-5.15.220.config.gz.b64.part01`

Concatenate `part00` + `part01` to reconstruct the original base64-encoded gzip payload. The split is storage/transport only; the payload content is unchanged.

KernelSU Next 3.4.0 and SuSFS must be reintegrated only after the clean Wear 7 baseline is demonstrated bootable on-device.
