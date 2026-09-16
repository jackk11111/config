# Wear7 V6 — installer preparato prima della recovery

Lo sviluppo del trasferimento può procedere ora. Il **collaudo sul TicWatch è
ancora aperto**: questa cartella non costituisce una release pronta da flashare.
Le immagini restano esattamente quelle della [run V6 35146642220](https://github.com/jackk11111/config/actions/runs/35146642220).
Non serve ricompilarle per sviluppare l'installer.

## Stato concreto

| Parte | Stato |
| --- | --- |
| Immagini, APEX, VINTF, SELinux, idmap2, AVB e super V6 | PASS già acquisito; non rieseguito qui |
| Trasferimento, journal, confronto e ripresa dopo errore | Implementati; verificati su file locali simulati |
| Backend ADB per staging in RAM e scrittura a blocchi | Implementato; NON provato sulla recovery |
| Backup e ripristino delle sette partizioni ROM | Codice presente; ripristino su file simulati verificato |
| Scrittura reale sul dispositivo | BLOCCATA: nessuna recovery qualificata nel registro |
| Gestione dati durante il trasferimento | userdata, metadata e recovery esclusi da ogni scrittura |
| Strategia per i dati al primo avvio | Installazione pulita proposta; consenso al reset assente |
| Formattazione/reset e primo boot | NON implementati/abilitati; richiedono la recovery finale |

## Trasferimento

Il telefono legge le immagini V6 esistenti e decodifica `super.img` sparse in
blocchi raw da **16 MiB**. Non occorre salvare un secondo file raw da 4 GiB sul
telefono, né depositare tutta la super nella cache dell'orologio. I blocchi
`DONT_CARE` diventano zeri espliciti, coerenti con il checksum raw della build.

Prima di iniziare vengono verificati tutti gli input, il checksum dell'immagine
espansa e i backup completi delle partizioni da modificare. Il candidato è
vincolato al manifest originale della V6; il codice non cambia le immagini.

Per ogni blocco il backend confronta prima la destinazione. Se necessario,
trasferisce il blocco in `/tmp` su RAM, ne verifica dimensione/checksum, lo scrive,
sincronizza e verifica la rilettura. Controlla nuovamente i target prima della
scrittura. Il journal resta sul telefono, nella cartella di sessione scelta in
Download. Dopo un'interruzione, lo stesso comando/sessione rilegge i blocchi
effettivi: non considera sufficiente un vecchio "completato" nel journal.

La sequenza è `super`, `vendor_boot`, `init_boot`, `dtbo`, `boot`,
`vbmeta_system`, `vbmeta`. Non è un aggiornamento atomico: un'interruzione può
lasciare le partizioni in uno stato misto. Si deve restare in recovery e
completare o ripristinare. Non viene impartito alcun riavvio automatico.

## Ciò che deve garantire la recovery

Il backend richiede ADB Wi-Fi già autenticato e UID 0, identità dace/monaco
single-slot, bootloader sbloccato, alias e dimensioni coerenti. Rifiuta target
montati e **qualsiasi holder device-mapper delle partizioni da scrivere**.

Questo è rilevante per una recovery che carica Wi-Fi da `vendor`: il Wi-Fi e
ADB devono continuare a funzionare con `super` e tutte le sue partizioni logiche
inattive. Il codice non smonta `vendor` da solo e non rimuove mapping. Serve
inoltre una cartella temporanea in RAM con spazio sufficiente e un watchdog che
non interrompa un trasferimento lungo. La disponibilità nominale del Wi-Fi
non dimostra queste condizioni.

`validated-recoveries.json` è vuoto. `apply` e `rollback` si fermano **prima
di chiamare ADB** finché non esiste un profilo ricavato da prove hardware reali.
Il profilo deve identificare la recovery tramite SHA256, collegare l'evidenza
del trasporto/ripristino e fissare gli hash dei backup usati per il ritorno allo
stock. I test simulati non possono popolarlo. Non esiste un'opzione `--force`.

## Dati: decisione separata dal trasporto

La regola del codice è già definita: non modifica `userdata`, `metadata`,
`recovery`, `misc` o `persist`. Non contiene erase, mkfs, format o comandi di
reset. Non passa automaticamente dal flash al primo avvio.

Per il primo bring-up è proposta un'**installazione pulita**, per non aggiungere
la migrazione dei dati della vecchia ROM alle variabili del primo test. È una
scelta operativa proposta, non una necessità dimostrata né un'autorizzazione
ricevuta. La conservazione con migrazione in-place non è supportata/collaudata.

Per chiudere questa decisione serve il consenso dell'utente a cancellare i dati
**dell'orologio**. Poi il reset va realizzato tramite la procedura corretta della
recovery, coerente con fstab e cifratura del dispositivo. Non si presume che un
generico `dd`, una cancellazione di file o la formattazione indiscriminata di
metadata equivalgano a un reset corretto. La configurazione necessaria a rientrare
via Wi-Fi deve sopravvivere al reset o essere ripristinabile dalla recovery.

`snapshot` salva solo le sette partizioni ROM. Non salva dati utente o chiavi di
metadata e non prova che il ripristino dei dati cifrati sia possibile. Dopo
l'avvio di Android, il ripristino delle sole immagini ROM non riporta
necessariamente l'intero dispositivo allo stato precedente.

Riferimenti: [FBE Android](https://source.android.com/docs/security/features/encryption/file-based)
e [cifratura dei metadati](https://source.android.com/docs/security/features/encryption/metadata).
Questi descrivono il legame con le chiavi; la configurazione concreta va letta
nel fstab del TicWatch, senza dedurla da un altro dispositivo.

## Uso adesso

Non è richiesto alcun nuovo test sull'orologio per utilizzare il piano offline.
Se si prepara la cartella sul telefono, mantenere la struttura `wear7/installer`
e `wear7/v6/recovery-preflight.py`; usare Python 3.11 o successivo. Estrarre
Bootchain e Super della stessa run V6 in una cartella in Download.

```sh
python wear7/installer/wear7_installer.py plan \
  --package /storage/emulated/0/Download/Wear7-V6 \
  --session /storage/emulated/0/Download/Wear7-V6-sessione
```

Questo comando calcola il piano di trasporto senza collegarsi al watch. Una
cartella di sessione esistente non viene sovrascritta. Il controllo degli input
serve all'integrità del trasferimento; non ricompila la ROM né riesegue VINTF,
SELinux o idmap2. Tutti i file/report destinati all'utente devono restare in Download.

`probe` legge l'interfaccia della recovery. `snapshot` crea, solo su richiesta,
una nuova copia delle partizioni ROM e non sovrascrive backup esistenti. Un
backup preesistente può essere riutilizzato dopo l'inventario e l'associazione
dei suoi hash al profilo del rollback; non va ricreato se è già sufficiente.
Il comando `snapshot` non classifica automaticamente ciò che legge come "stock".

## Verifica effettuata

Sono passati **21 nuovi test locali** su file temporanei: sparse/zeri, trasferimento,
interruzione con scrittura parziale, perdita dell'acknowledgement, ripresa con
journal obsoleto, corruzione dopo scrittura, controllo finale, fonte/backup
corrotti, identità diversa, montaggio sopraggiunto, accesso concorrente,
partizioni protette, ripristino, limite di 4 GiB, errore ADB push e blocco CLI.

I 12 test V6 e i controlli della ROM già conclusi non sono stati rilanciati.
I nuovi test non attestano prestazioni Wi-Fi, persistenza della scrittura sul
TicWatch, primo boot, reset o recupero fisico. Il registro hardware resta vuoto.
