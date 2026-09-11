TicWatch Ultimate - KernelSU Next 3.3.0 Spoofed ARMv7 - pacchetto completo

CONTENUTO PRINCIPALE
- KernelSU_Next_v3.3.0-spoofed-TicWatch-armeabi-v7a-release.apk : Manager paired corretto
- TicWatch-Ultimate-5.15-KSUNext-3.3.0-Spoofed-SuSFS-PAIRED.zip : ZIP AnyKernel alternativo
- Image : kernel esatto paired al Manager
- wireless-flasher/ : flasher da eseguire sul TicWatch via root
- TERMUX-ADB.sh : helper da eseguire sul telefono con Termux + wireless ADB
- TicWatch-KSUN330-Wireless-Root-Flasher.tar : copia standalone del flasher
- audit/ : config, provenance, simboli, log e patch della build

REQUISITI
1. Bootloader del TicWatch già sbloccato.
2. Root attuale funzionante sul TicWatch, perché il flash da Android usa `su`.
3. Wireless debugging attivo e telefono collegato al TicWatch con ADB.
4. In Termux: `pkg install android-tools`.

PROCEDURA RACCOMANDATA
1. Estrai QUESTO ZIP sul telefono.
2. In Termux vai nella cartella estratta.
3. Se non l'hai già fatto, collega il watch:
     adb pair IP:PORTA_PAIRING
     adb connect IP:PORTA_DEBUG
4. Esegui SOLO il controllo/dry-run:
     bash TERMUX-ADB.sh --check
   Questo NON scrive la boot. Crea il backup originale e lo copia anche nella cartella `backups/` sul telefono.
5. Se tutto termina con PASS:
     bash TERMUX-ADB.sh --flash
   Lo script ripete il dry-run, verifica/copia il backup, installa il Manager paired e poi scrive SOLO la boot dello slot attivo.
6. Il flasher verifica con read-back SHA ciò che ha scritto. NON riavvia automaticamente.
7. Solo dopo tutti i PASS:
     adb reboot

RIPRISTINO (se Android/ADB e root sono ancora disponibili)
  bash TERMUX-ADB.sh --restore

NOTA DI SICUREZZA
Conserva la cartella `backups/` fuori dall'orologio. Se un nuovo kernel non avviasse Android, wireless ADB non sarebbe disponibile e il backup sul telefono diventa essenziale per un eventuale ripristino da bootloader/fastboot.

NON usare il vecchio flasher: era legato alla precedente Image e al precedente SHA256.
