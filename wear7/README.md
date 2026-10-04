# Wear 7 — current CLEAN V1

Canonical source tree: `wear7/current/`.

The latest verified source rebuild is GitHub Actions run `37204998782` (`Wear7 Dace CLEAN V1 source rebuild`), completed successfully on 2026-10-04. It produced the canonical bootchain, super and reports artifacts.

The generated clean super used by the later recovery-preservation audit has SHA-256 `8cb3cb13a0913980a5c53e8ae5f2e1591841f8bf9676afa81dc3a47b66d9d197`.

`wear7/current/lib/`, `wear7/current/tools/` and `wear7/current/data/` contain only the dependencies still required by CLEAN V1. They replace the former mixed `v6`, `v7`, `v11`, diagnostic, installer, probe, `scripts` and `manifests` trees.

A successful CI build is not a substitute for final on-device boot, hardware and pairing validation.
