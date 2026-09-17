# Wear7 V6 — verifiche ancora possibili prima dell'installazione

**Non rimane soltanto il primo avvio.** Il confronto statico della recovery
R7.2 con l'installer individua un'incompatibilità di integrazione e due punti
da chiudere nella procedura di reset. Nessuno richiede di installare prima Wear7
per essere individuato o progettato; il collaudo finale richiede l'orologio.

## Baseline conservata

Le immagini della run `35146642220` e i controlli V6 già conclusi rimangono
invariati. Sono inclusi anche il controllo KMI mirato già riportato
`PASS_337_OF_337`, il bootstrap KernelSU per installazione pulita e la
preparazione statica del pairing. Non sono stati rilanciati build o test.
Questo documento non riapre quei controlli e non attesta il funzionamento hardware.

## Evidenze nuove: recovery R7.2 e installer

Fonte: `TicWatch-RECOVERY-R7.2-MAPFIX-20260916.zip`, inclusi il checkpoint e
i file letti direttamente dal ramdisk di `recovery-r7.2-mapfix.img`.
SHA256 immagine riportato dalla sua `VALIDAZIONE.json`:
`f417a636f79c2e51d4158fc822ae6393d380a2296d1b64508d8e190156517dfd`.

| Punto | Risultato statico | Conseguenza prima del flash |
| --- | --- | --- |
| Wi-Fi della recovery | Il bootstrap mappa `super`, monta `vendor` e `vendor_dlkm`, carica i moduli e avvia `wpa_supplicant` da `vendor`. Non contiene un passaggio che renda queste partizioni inattive. | Incompatibile con l'attuale scrittura completa di `super`: l'installer rifiuta montaggi e holder attivi. Un test Wi-Fi riuscito da solo non chiude questo punto. |
| Recupero dopo interruzione | Il bootstrap termina se non riesce a mappare/montare quelle partizioni. | Il recupero senza PC dopo un riavvio con `super` incompleta richiede dipendenze disponibili fuori dalle partizioni riscritte. Una sola copia temporanea in RAM non basta per questo caso. |
| Reset | Il `recovery.fstab` dichiara `/data` F2FS, `/cache` e `/metadata` ext4; nel ramdisk esiste `make_f2fs`. | I parametri della recovery sono ora identificati; la procedura coordinata con la cifratura effettiva del candidato resta da implementare e collaudare. La presenza del formatter non dimostra un reset corretto. |
| Configurazione rescue | Wi-Fi, rete e chiavi ADB sono lette da `/cache/ticwatch-recovery/config` o `/metadata/ticwatch-recovery/config`. | Il reset deve conservarle o ripristinarle prima di qualsiasi riavvio. La loro disponibilità dopo il reset è ancora non dimostrata. |
| Persistenza recovery dopo wipe | Il checkpoint R7.2 documenta il guard già provato in Wear4 in `/data/adb/modules/tw_recovery_guard_r71`. | Un reset pulito di `/data` elimina quel guard. Va accertata e, se necessaria, integrata la protezione dal writer stock per Wear7 senza dipendere dal vecchio modulo. Non è dimostrato che Wear7 sovrascriva la recovery, né che sia già protetta dopo il wipe. |
| RAM e watchdog | L'init monta `/tmp` come tmpfs; il watchdog R7.2 è diagnostico e non forza riavvii. I comandi richiesti dal backend sono presenti. | Queste proprietà statiche sono acquisite. Capacità disponibile, stabilità e durata del trasferimento restano prove hardware. |

SHA256 del `system/etc/recovery.fstab` letto:
`a28b8fedda3cdb8e051e0cc719897164cc179486722c78071f6eb59b99b5c901`.
La riga `/data` include `encryptable=footer`, `reservedsize=128M` e
`checkpoint=fs`; `/metadata` include `wrappedkey`. Sono dichiarazioni del
fstab della recovery, non una misura dello stato effettivo della cifratura.

Il bootstrap Wear7 `scripts/add_dace_wireless_root_bootstrap.py` ripristina
ksud e il servizio Wi-Fi/ADB dopo il wipe, ma non reinstalla il guard R7.1.
Il report V6 dichiara `vendor`/`vendor_dlkm` stock379: la questione della
persistenza recovery non si può considerare risolta dal solo bootstrap KSU.

## Passi distinti

1. **Possibili adesso:** completare l'integrazione recovery/installer per
   rendere sicura la riscrittura di `super`, definire reset e conservazione
   della configurazione rescue, risolvere la persistenza della recovery.
   Questa revisione ha verificato i presupposti; non implementa tali soluzioni.
2. **Sull'orologio, prima di installare Wear7:** qualificare la recovery
   effettiva, il trasporto, il rientro fisico e il rollback con i backup ROM
   già disponibili dopo averne associato gli hash. Non ricreare backup
   sufficienti. Il fallback USB/Fastboot già provato resta acquisito, ma non
   equivale al recupero autonomo tramite Wi-Fi.
3. **Dopo il primo avvio di Wear7:** pairing/companion, comportamento dei
   driver e delle periferiche, NFC, Wi-Fi/Bluetooth, audio, sensori, energia,
   accesso ADB/root persistente e Gemini nativo. La presenza statica dei
   componenti non ne garantisce il funzionamento.

Il registro delle recovery qualificate resta vuoto e le scritture restano
bloccate. Il consenso all'installazione pulita è già acquisito; non è un punto
aperto. Il pacchetto V6 resta un candidato offline valido, non un percorso
d'installazione già collaudato.
