# Wear 7 sul TicWatch Pro 5 Enduro (dace) — archivio tecnico

**Stato al 9 ottobre 2026:** porting NON funzionante e progetto sospeso. Nessuna immagine Wear 7 qui e' qualificata per il flash. Compilare il kernel o super.img non equivale ad avviare il sistema.

## Baseline che NON va modificata
- Sistema funzionante: Wear OS 4 / Android 13.
- Kernel funzionante sul dispositivo: Linux 5.15.220 con KernelSU Next 3.4.0 e SuSFS 2.3.0.
- Recovery autonoma Wi-Fi/ADB e decrypt: mantenere la baseline verificata; immagini di ripristino ed handoff sono sul telefono dell'utente.
- Sorgenti kernel: repository ReSukiSU; branch `ticwatch-max-lts-220` e `ticwatch-max-lts-220-incremental` di questo repository. Il nome di un branch NON identifica necessariamente il boot flashato.

## Risultato storico e primo gate ancora fallito
I tentativi Wear 7 includevano kernel clean/no-KSU, bootchain, super.img, patch per init, Android 13/17 Vold, Keystore2 e FBE. Non e' stata dimostrata l'intera sequenza boot -> initUser0/FBE -> configurazione utente -> pairing Mobvoi. Il fronte finale della diagnosi riguardava initUser0/FBE e dipendenze tra piattaforma stock e framework recente. Il pairing Mobvoi non e' stato qualificato.

L'evidenza di una KMI compatibile e i successi delle build CI non dimostrano un porting realmente avviabile e usabile. Non ripetere DIAG, V11, test casuali o flash senza nuove informazioni discriminanti.

## Condizioni per riaprire il progetto
Solo quando emergano nuove prove verificabili su driver/HAL, sorgenti OEM, initUser0/FBE e pairing/companion. Ripartire dal primo gate fallito, confrontare i log gia' raccolti, usare una modifica alla volta; non interferire con il kernel operativo.

## Pulizia GitHub del 9 ottobre 2026
Rimosse entrambe le release diagnostiche DIAG3/DIAG5, gli 11 branch sperimentali Wear 7 e 138 vecchie esecuzioni CI. Il branch main conserva solo note tecniche; gli artefatti falliti non sono pacchetti di ripristino. Rimangono appositamente i branch kernel 5.15.220 e i sorgenti ReSukiSU. I backup e gli handoff originali possono essere reinviati dal telefono se in futuro servissero.
