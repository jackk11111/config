# Wear7 V6 — verifiche offline del candidato

Questa è una revisione del pacchetto ROM, distinta dalle revisioni della recovery.
Il punto di partenza è la V5B del run `35094447396`, con kernel
`5.15.220-Xinran_StarBai-Test+`. I checksum degli otto file originali e degli
otatools Android sono fissati nel codice. I quattro file boot/init_boot/
vendor_boot/dtbo restano identici; le immagini vbmeta vengono rigenerate se cambia system.

## Cosa deve verificare la pipeline

1. Riconfezionare le librerie stock VNDK33 in un APEX firmato, preservandone
   contenuto ed etichette SELinux, verificare firma e allineamento a 4096 byte,
   ed eliminare la cartella APEX flattened.
2. Estrarre gli APEX con `apexd_host` e verificare che VNDK33 sia presente una sola volta.
3. Eseguire il `checkvintf` ufficiale sui file effettivi, con SKU monaco.
4. Compilare insieme le policy SELinux platform/system_ext/product/vendor e
   i mapping 33.0 con `secilc`, come fa init quando la policy precompilata non coincide.
5. Creare e leggere l'idmap dell'overlay Fast Pair con il vero `idmap2` ARM
   della ROM sotto QEMU. Questo controlla la mappatura delle risorse, non il pairing Bluetooth.
6. Ricostruire system, AVB e super, riestrarre super, confrontare le partizioni
   e i metadati del filesystem, quindi ripetere i controlli sul risultato finale.

Un errore blocca la pubblicazione degli artifact candidati. Il guardiano della
pipeline usa un errore esplicito, anche quando vengono eseguiti più controlli
indipendenti per raccogliere tutti i risultati. I report vengono
conservati anche in caso di errore e indicano quale controllo è fallito.
Le altre cinque partizioni logiche vengono confrontate byte per byte.

`apexd_host` è uno strumento offline: non dimostra l'attivazione da parte del
kernel sull'orologio. La compilazione SELinux non dimostra l'assenza di denial
durante il funzionamento. Un idmap valido non dimostra che il servizio di
abbinamento o l'app companion funzionino.

## Chiavi e provenienza

Il bridge VNDK33 riceve due chiavi generate nel runner. Le chiavi private non
entrano negli artifact; viene conservato l'APEX firmato. Le librerie stock non
vengono ricompilate. Per riutilizzare lo stesso bridge in una revisione successiva,
conservare l'APEX firmato e il suo checksum. La generazione delle chiavi rende
due esecuzioni non identiche byte per byte. Non è una configurazione per OTA APEX
indipendenti o per ribloccare il bootloader.

## Controllo preliminare da Termux

Estrarre Bootchain e Super della stessa esecuzione in un'unica cartella sotto
`/storage/emulated/0/Download/`. I due artifact non sono uno ZIP installabile da recovery.
Copiare anche gli script di questa cartella accanto al comando preflight.
Servono Python 3.11+ e, solo per interrogare l'orologio, adb già configurato e autorizzato.

Verifica dei soli file, senza collegamento al dispositivo:

```sh
python recovery-preflight.py \
  --package /storage/emulated/0/Download/Wear7-V6 \
  --report /storage/emulated/0/Download/wear7-v6-package-check.json
```

Quando la recovery sarà collaudata e già connessa via ADB autenticato, aggiungere
`--serial IP:PORTA` usando il valore esatto mostrato da `adb devices`.
Il controllo legge UID, identità dace/monaco, stato bootloader, slot, dimensioni
e alias delle partizioni, oltre ai filesystem montati. Non esegue connessioni,
root, reboot, mount, scritture su partizioni o wipe.

Per preparare un file raw sul telefono, dopo un esito positivo dei controlli:

```sh
python prepare-super.py \
  --package /storage/emulated/0/Download/Wear7-V6 \
  --output /storage/emulated/0/Download/Wear7-V6-super.raw.img
```

Servono almeno 4,5 GiB liberi oltre al pacchetto già estratto. Il file deve essere
nuovo: non viene sovrascritto un output esistente. La conversione gestisce chunk
raw/fill/dont-care e verifica il checksum raw della build. Non invia file
all'orologio. L'immagine sparse originale non va scritta direttamente con `dd`.

I report possono contenere informazioni del dispositivo: controllarli prima
di condividerli. Un controllo preliminare positivo lascia comunque
`flash_authorized=false`.

## Condizioni ancora necessarie sull'hardware

- Ingresso nella recovery tramite menu Fastboot e ADB Wi-Fi autenticato con UID 0.
- Backup stock completo fuori dall'orologio, checksum verificati, ripristino e
  ritorno allo stock provati con quella stessa recovery.
- Trasporto dell'immagine super oltre il limite della cache: conversione sparse
  corretta o streaming controllato, gestione delle interruzioni e verifica in lettura.
- Decisione esplicita sulla migrazione di userdata. Non è autorizzato alcun wipe.
- Primo avvio Wear7, pairing con una companion funzionante, Wi-Fi/Bluetooth,
  display e touch, sensori, ricarica, sospensione, ADB/root dopo riavvio.

Il [kit installer](../installer/README.md) aggiunge il trasferimento a blocchi,
la rilettura, il journal e il ripristino, con 21 test locali su file simulati.
Il backend ADB deve essere collaudato contro la recovery finale: le scritture
restano bloccate, userdata/metadata sono esclusi e nessun riavvio è automatico.
L'installazione pulita e il reset dei dati dell'orologio per il primo test
sono autorizzati dal 17/09/2026; la procedura di reset attende la recovery
collaudata. Gemini nativo è un requisito obbligatorio di funzionamento.
Nessuna prova sull'orologio è stata eseguita da questa pipeline.

Gli artifact GitHub Actions hanno conservazione di 90 giorni. Prima della loro
scadenza occorre archiviare Bootchain, Super, report e bridge firmato insieme.
La conservazione non equivale a una release permanente.

## Riferimenti tecnici

- [APEX e incompatibilità dei formati mixed/flattened](https://source.android.com/docs/core/ota/apex#flattened-apex)
- [Compilazione SELinux in init](https://github.com/aosp-mirror/platform_system_core/blob/main/init/selinux.cpp)
- [Invocazione diretta del linker Bionic](https://github.com/aosp-mirror/platform_bionic/blob/main/linker/linker_main.cpp)
- [Regole overlayable in IdmapManager](https://github.com/aosp-mirror/platform_frameworks_base/blob/main/services/core/java/com/android/server/om/IdmapManager.java)

I test di `test_preflight.py` usano piccoli file artificiali: provano il rifiuto
di input corrotti e stati ambigui, non un flash o un rollback reale.

