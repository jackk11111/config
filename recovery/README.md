# Recovery TicWatch — baseline funzionante (Wear OS 4)

La recovery Wi-Fi/ADB autonoma e la catena `tw-decrypt` sono state verificate sull'orologio con test **zero-state** il 1 ottobre 2026, senza dipendenza dalla vecchia cartella di soccorso `/metadata/ticwatch-rescue`. La catena di decrypt includeva HWSM, QSEE, Keymaster, Gatekeeper, Keystore2, Vold e mount `/data`.

Il file definitivo di ripristino, gli script necessari e le eventuali varianti successive sono conservati dall'utente sul telefono. **Non flashare un'immagine scelta solo perche' il nome contiene FINAL**: distinguere fra immagine qualificata, variante test e relativa prova sul dispositivo.

### Distinzione fondamentale
L'esperimento *Wear 7 AUTODATA* del 4 ottobre 2026 ha raggiunto gate runtime validi usando stato esterno su `/metadata` e `/cache`. Non equivale alla qualificazione zero-state della recovery autonoma usata con Wear 4. La documentazione dell'esperimento e' stata rimossa dal `main` per non confondere i due percorsi.

La recovery funzionante e' chiusa: non riaprire Wi-Fi, ADB o decrypt in assenza di nuova evidenza concreta.
