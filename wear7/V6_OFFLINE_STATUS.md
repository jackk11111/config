# Wear7 V6 — risultato verificato del 16 settembre 2026

La build offline è riuscita. Questo documento non autorizza il flash e non
attesta il funzionamento sull'orologio.

- Commit del codice verificato: `d160e4f6b32d29cbecc802f3d9443fe0d2b7de44`.
- [Esecuzione completa 35146642220](https://github.com/jackk11111/config/actions/runs/35146642220).
- [Modifiche nella PR #1](https://github.com/jackk11111/config/pull/1).
- Base V5B: run `35094447396`; kernel conservato `5.15.220-Xinran_StarBai-Test+`.

| Controllo | Risultato osservato |
| --- | --- |
| Bridge VNDK33 | PASS: APEX firmato v3, payload AVB RSA4096 verificato, allineamento 4096 byte |
| Librerie e metadati VNDK | PASS: 119 file e 122 elementi verificati contro lo stock |
| Formato APEX | PASS: nessun APEX flattened residuo e VNDK33 unico nell'estrazione host |
| VINTF ufficiale | PASS sul candidato ricostruito |
| SELinux | PASS: compilazione delle policy combinate e mapping 33.0 |
| Fast Pair RRO | PASS: condizione Enduro e idmap2 reale; risorsa `google_fast_pair_service_model_id` mappata |
| Filesystem system | PASS: contenuti, UID/GID, modi, symlink, SELinux e capability confrontati dopo la ricostruzione |
| Super | PASS: dimensione raw 4 GiB, estrazione e confronto di tutte le partizioni logiche |
| Partizioni diverse da system | PASS: identiche byte per byte alla V5B |
| Pacchetto finale | PASS: checksum, manifest e formato sparse verificati |
| Strumenti per Termux | 12 test passati: rifiuto di input corrotti/stati ambigui e conversione sparse |

La mappatura osservata da idmap2 è
`0x7f11021a -> 0x7f010000 (string/google_fast_pair_service_model_id)`.
L'esecuzione sotto QEMU usa percorsi di libreria espliciti: non collauda i
namespace linker generati durante il boot Android né la selezione degli overlay
da parte del servizio Android in esecuzione. Il pairing resta da verificare.

## File prodotti

Estrarre Bootchain e Super della stessa esecuzione nella stessa cartella.
Non sono uno ZIP di installazione da recovery.

| Artifact | Collegamento | SHA256 dell'archivio GitHub |
| --- | --- | --- |
| Wear7-V6-Bootchain | [Scarica](https://github.com/jackk11111/config/actions/runs/35146642220/artifacts/10467747396) | `4959f970539f93b4c3e23111e201a3fa9f39fb1fb84af7ebad0e576805333d99` |
| Wear7-V6-Super | [Scarica](https://github.com/jackk11111/config/actions/runs/35146642220/artifacts/10466908339) | `97a0ad9b9e16db43974531b3f551f57baab87704053863a05f8712b327e8cf96` |
| Wear7-V6-Offline-Analysis | [Scarica](https://github.com/jackk11111/config/actions/runs/35146642220/artifacts/10467159269) | `9ec9bc1a4e411e76cd7ca272d3383ac352da5ebf89fc1689d500b7e61f6572b1` |

Scadenza corrente dei tre artifact: **15 dicembre 2026, 20:27 UTC**.
I checksum delle singole immagini e della super espansa sono nel pacchetto;
non vanno confusi con quelli degli archivi ZIP indicati nella tabella.

L'APEX firmato è incluso nei report e ha SHA256
`033eb4b936442ed22a6c700890f806819ec89d3c3b266934de9747acd730b828`.
Le chiavi private non sono pubblicate. Archiviare insieme immagini, manifest,
checksum, report e APEX prima della scadenza. La pipeline dipende ancora dagli
artifact V5B originali per una nuova ricostruzione; il loro archivio va conservato
se si desidera riprodurre il processo dopo la scadenza degli input.

## Preparazione installer successiva alla build

Il [kit installer](installer/README.md) anticipa lo sviluppo senza ricompilare
la ROM. Trasferimento da 16 MiB, rilettura, journal sul telefono, ripresa e
ripristino sono implementati; 21 test locali su file simulati sono passati.
Le scritture reali restano bloccate in assenza di una recovery qualificata.
Gli hash delle immagini V6 e i risultati della run sopra non cambiano.

La gestione dati durante il trasporto è definita: userdata e metadata intatti,
nessun wipe e nessun riavvio automatico. Il 17/09/2026 l'utente ha autorizzato
l'installazione pulita e la cancellazione dei dati dell'orologio per il primo
test controllato. Il reset non è stato eseguito; la procedura effettiva attende
l'integrazione con la recovery collaudata.

## Ciò che rimane aperto

Recovery Wi-Fi/root, backup fuori dal dispositivo e ripristino fisico non sono
stati provati da questa build. Il preflight della recovery è in sola lettura.
Il percorso di scrittura/streaming deve essere integrato con la recovery
collaudata e deve gestire interruzioni e verifica in lettura.

La strategia userdata è l'installazione pulita autorizzata il 17/09/2026;
nessun wipe è stato eseguito. La migrazione in-place non viene perseguita. Primo avvio, companion/pairing, Wi-Fi e Bluetooth, display/touch,
sensori, ricarica, sospensione e persistenza ADB/root restano **UNTESTED**.
AVB è nella modalità di primo avvio con bootloader sbloccato, non ribloccabile.

I comandi disponibili e i requisiti sono in [v6/README.md](v6/README.md).

## Requisito Gemini aggiornato il 17 settembre 2026

Gemini nativo è obbligatorio per considerare completa la ROM. La V6 conserva
AssistantWearPrebuilt in system/priv-app, con SHA256
`3434942e08ba875f53783ed4fbd2a2510bdcbc988430177df20247d23eeefecd`,
e la policy privilegiata del donor. La presenza è documentata nel report finale
già prodotto; attivazione, invocazione e risposta di Gemini restano da provare
sul dispositivo. I vecchi moduli/bind-mount Wear4 non soddisfano questo requisito.
