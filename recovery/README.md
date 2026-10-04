# Recovery — runtime-qualified baseline / self-contained finalization

The current recovery/AUTODATA chain is runtime-qualified on-device after a real cold boot, but it is **not yet accepted as the final recovery** because the Wear 7 AUTODATA path still consumes mutable external state from `/metadata` and `/cache`.

Qualified baseline that must not regress:

- recovery image SHA-256: `dec15f4b66b16a68a9eb40b5f6f17b92a8429a5e1d73f6eba81c3a524a7993ff`
- embedded AUTODATA wrapper SHA-256: `daa7cbf920367adfebaf83487bc14207157b0f2b34561dd4bb04c5d681d37a6c`
- final AUTODATA SHA-256: `8d6d4f92bce999fbe2bfed0ce5b5bbeb60d08cc8dbd1df4dbdf15b4d623af0c3`
- full A13 runtime bundle SHA-256: `ee0cdd779c1057b8cd5eed2f0e1ba3ea605466b6653b9e84353763dd95807f80`
- final runtime gate: `RESULT=AUTODATA_FULLROOT755_COLD_BOOT_PASS`

The last functional blocker was DAC traversal only: `/tmp/tw-a13full` was `0700`, preventing HWSM (`system`) from reaching the correct A13 libraries. The qualified fix remains exactly:

```sh
chmod 0755 "$FULL" || fail FULL_RUNTIME_ROOT_CHMOD
```

## Active finalization gate

The recovery is accepted as final only when AUTODATA can recover after deletion of mutable `/data`, `/metadata` and `/cache` state. No external rescue folder or pre-seeded archive in those partitions may be required.

The first offline hypothesis is to reuse the immutable stock A13 recovery payload already shipped as `/vendor/etc/recovery.img` as the runtime source. The dedicated GitHub audit reconstructs exact TicWatch stock 379 vendor bytes and checks whether that payload contains the same qualified HWSM/servicemanager/Keystore2/Vold/libbinder/token runtime bytes already proven on-device. This avoids adding the ~59 MB full A13 archive to the custom recovery partition if the immutable OEM payload already contains the exact source.

Until this wipe-proof gate is qualified, do not call the recovery final and do not make Wear 7 flashing depend on the current `/metadata` + `/cache` arrangement.

See [`FINAL_RUNTIME_20261004.md`](FINAL_RUNTIME_20261004.md) for the complete functional cold-boot provenance. KernelSU Next 3.4.0 and SuSFS remain deferred until the clean Wear 7 baseline and the final recovery boundary are both qualified.
