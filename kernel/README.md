# Kernel TicWatch dace — stato di riferimento

**Configurazione runtime funzionante:** kernel Linux 5.15.220 + KernelSU Next 3.4.0 + SuSFS 2.3.0 su Wear OS 4 / Android 13. L'immagine esatta flashata e i relativi backup sono conservati dall'utente sul telefono; NON inferire la sua identita' dal solo nome di un workflow GitHub.

**Sorgenti da conservare:** [jackk11111/ReSukiSU](https://github.com/jackk11111/ReSukiSU) (codice di KernelSU e manager) e le branch storiche `ticwatch-max-lts-220`, `ticwatch-max-lts-220-incremental` in questo repository. Queste branch contengono materiali di costruzione della serie 5.15.220, ma non sono una certificazione automatica dell'attuale boot.img.

## Baseline sperimentale distinta dal kernel attivo
Il kernel **clean/no-KSU** compilato per Wear 7 non e' il kernel operativo dell'orologio. I due frammenti `kernel/baseline/clean-5.15.220.config.gz.b64.part00` e `part01` sono conservati SOLO per documentare la configurazione clean usata nella precedente indagine. La prova KMI 337/337 riguarda quell'esperimento, non dimostra un avvio riuscito di Wear 7.

Non riportare nell'immagine funzionante modifiche KEXEC, diagnostiche ARM64 o esperimenti Wear 7. Non avviare una nuova compilazione a meno che un gate realmente fallito non la richieda.
