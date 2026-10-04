# Recovery — runtime-qualified baseline

Recovery is now closed and runtime-qualified on-device after a real cold boot.

Canonical final state:

- recovery image SHA-256: `dec15f4b66b16a68a9eb40b5f6f17b92a8429a5e1d73f6eba81c3a524a7993ff`
- embedded AUTODATA wrapper SHA-256: `daa7cbf920367adfebaf83487bc14207157b0f2b34561dd4bb04c5d681d37a6c`
- final AUTODATA SHA-256: `8d6d4f92bce999fbe2bfed0ce5b5bbeb60d08cc8dbd1df4dbdf15b4d623af0c3`
- full A13 runtime bundle SHA-256: `ee0cdd779c1057b8cd5eed2f0e1ba3ea605466b6653b9e84353763dd95807f80`
- final qualification: `RESULT=AUTODATA_FULLROOT755_COLD_BOOT_PASS`

The final blocker was not timing. `/tmp/tw-a13full` was extracted/staged with mode `0700`, so HWSM running as Android user `system` could not traverse the runtime root and the linker reported `android.hidl.token@1.0.so` as missing even though the library was present. The qualified fix is exactly:

```sh
chmod 0755 "$FULL" || fail FULL_RUNTIME_ROOT_CHMOD
```

See [`FINAL_RUNTIME_20261004.md`](FINAL_RUNTIME_20261004.md) for full provenance, hashes, failed-candidate boundaries and the complete cold-boot gate record.

The earlier static recovery-preservation V2C success in run `37190714084` remains useful provenance, but runtime qualification is now established by the later on-device cold-boot pass above.

Recovery is isolated from the clean kernel/Wear 7 baseline. Do not reopen recovery Wi-Fi, wrapper persistence, HWSM/QSEE/Keymaster, `/data` decryption or `/data/adb/modules` RW work without new contradictory evidence.

Temporary historical refs may still exist for provenance, but they are no longer active recovery work branches and must not be used as the project baseline.
