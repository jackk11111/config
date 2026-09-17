# TicWatch Pro 5 Enduro — Kernel / Wear 7 workspace

Workspace tecnico per TicWatch Pro 5 Enduro (dace/monaco).

## Baseline attuale

- Kernel: Linux 5.15.220
- Branch di sviluppo: `ticwatch-max-lts-220`
- Wear 7: integrazione kernel corrente `ticwatch-wear7-integration-kernel-v3.yml`
- Recovery: sviluppo KEXEC ancora attivo; i workflow e gli script KEXEC presenti non vanno considerati obsoleti finché la rescue recovery non è chiusa e validata.

## Struttura utile

- `.github/workflows/` — build, integrazione Wear 7, recovery/KEXEC e bundle TicWatch
- `.github/scripts/` — patch e strumenti kernel/KEXEC ancora usati dal percorso 5.15.220
- `.github/data/` — dati KMI necessari alle verifiche del kernel
- `ticwatch-ultimate/` — strumenti operativi Termux/ADB/KSU e wireless flasher

## Regola di pulizia

Il ramo mantiene solo materiale TicWatch utile o ancora necessario alla riproducibilità del kernel/recovery. Vecchi contenuti NikGapps, workflow 5.15.211 e revisioni Wear 7 sostituite sono rimossi dal ramo di lavoro; restano comunque recuperabili dalla cronologia Git.
