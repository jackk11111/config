# TicWatch Pro 5 / Enduro (dace) — riferimenti stabili

## Stato corrente (9 ottobre 2026)
- Sistema utilizzato sull'orologio: **Wear OS 4 / Android 13**. Il porting Wear 7 NON e' stato qualificato per l'uso quotidiano e non va presentato come funzionante.
- Kernel attualmente operativo: **Linux 5.15.220**, con **KernelSU Next 3.4.0** e **SuSFS 2.3.0** integrati. Questa e' la configurazione confermata sul dispositivo, distinta dal kernel *clean/no-KSU* usato nei precedenti esperimenti Wear 7.
- Recovery Wi-Fi/ADB e decrypt: e' stata qualificata una variante autonoma dopo test zero-state il 1 ottobre 2026. La presenza di immagini e di ulteriori esperimenti su GitHub non modifica automaticamente tale baseline.
- Funzioni gia' ottenute sul dispositivo: root e spoof persistente, connessioni ADB wireless, watchface personalizzata, Google Wallet, chiamate WhatsApp, YouTube adattato. La migrazione Gemini 1.39 e' un progetto separato, da valutare rispetto ai test realmente conclusi.

## Dove sono i materiali affidabili
- **File di installazione e backup attuali**: copie mantenute sul telefono dell'utente; verificare nome, SHA-256 e provenienza prima di flashare.
- **Codice KernelSU Next**: repository [ReSukiSU](https://github.com/jackk11111/ReSukiSU), da NON ridurre a un elenco di esempi: i sorgenti sono necessari.
- **Lavori storici sul kernel 5.15.220**: branch `ticwatch-max-lts-220` e `ticwatch-max-lts-220-incremental` di questo repository; non presumere che ogni loro build corrisponda esattamente all'immagine flashata.
- **Baseline kernel clean usata per i test Wear 7**: note sotto `kernel/`; non e' il kernel con KSU che sta funzionando oggi.
- **Recovery**: `recovery/README.md`.
- **Wear 7 (stato, failure signature, prerequisiti futuri)**: `wear7/README.md`.

Questo `main` e' intenzionalmente un indice tecnico leggero, NON un sistema di build attivo. Le build e i workflow provvisori Wear 7 sono stati rimossi dal tree corrente per evitare l'uso accidentale di immagini non qualificate.

Regola di prosecuzione: ripartire da baseline, esiti gia' dimostrati e primo gate non passato; non ricostruire catene di test fallite senza nuova evidenza.
