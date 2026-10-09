# Wear 7 sul TicWatch dace — ricerca sospesa (9 ottobre 2026)

**Non funzionante / non qualificato sul dispositivo.** Sono stati prodotti kernel e bootchain, super.img, varianti di init e patch Vold/Keystore2, ma il porting non ha superato l'intera catena di avvio e configurazione utente sul TicWatch. Nella fase finale le indagini riguardavano la fase `initUser0` / FBE e le dipendenze tra Android 13 e il framework piu' recente. Compilazione CI riuscita != avvio, hardware, cifratura dati o pairing verificati.

**Stato congelato:** nessuna nuova build automatica nel `main`; non ripetere V11, DIAG, run e ricostruzioni firmware solo per cercare una modifica casuale. I vecchi sorgenti sperimentali e workflow non sono baseline operative.

**Condizione per riaprire il progetto:** informazioni nuove e verificabili (driver/HAL compatibili, sorgenti OEM, soluzione qualificata per initUser0/FBE, strategia di pairing con companion Mobvoi). Prima identificare il primo gate non passato e discriminare le cause sui log gia' disponibili. Il pairing proprietario Mobvoi non era stato dimostrato su Wear 7.

Riferimenti storici minimi:
- Branch vecchie Wear 7 ancora visibili nel repository: servono SOLO come testimonianza di esperimenti, non come istruzioni di flash.
- Release DIAG3/DIAG5: immagini diagnostiche storiche, non OTA finale ne' pacchetto di installazione garantito.
- Baseline attualmente da NON alterare: Wear OS 4 con kernel 5.15.220 + KernelSU Next + SuSFS e recovery autonoma.

Se nuove informazioni riapriranno il progetto, richiedere all'utente i backup e gli handoff conservati sul telefono, e NON inferire dettagli mancanti dai nomi dei file.
