# Kernel TicWatch dace — stato di riferimento

**Configurazione runtime funzionante:** Linux 5.15.220 + KernelSU Next 3.4.0 + SuSFS 2.3.0 su Wear OS 4 / Android 13. I backup esatti del boot/kernel funzionante sono sul telefono dell'utente; non dedurre l'immagine effettivamente flashata dal nome di una build GitHub.

**Sorgenti da conservare:** [ReSukiSU](https://github.com/jackk11111/ReSukiSU) (KernelSU/manager) e i branch `ticwatch-max-lts-220` e `ticwatch-max-lts-220-incremental` di questo repository. Questi branch NON costituiscono da soli prova che una particolare build sia quella attualmente installata.

## Esperimento Wear 7, non funzionante
La precedente baseline **clean/no-KSU**, distinta dal kernel funzionante, era stata usata per esperimenti Wear 7, inclusa verifica KMI 337/337. I frammenti della configurazione sperimentale sono stati rimossi dal branch `main` nella pulizia del 9 ottobre 2026, per mantenere solo i riferimenti testuali. La prova KMI non dimostrava un avvio funzionante di Wear 7.

Per eventuali nuove ricerche leggere `wear7/README.md`. Non applicare KEXEC, diagnostiche ARM64 o modifiche Wear 7 alla configurazione funzionante senza nuova evidenza. I file di ripristino e i pacchetti definitivi sono conservati sul telefono.
