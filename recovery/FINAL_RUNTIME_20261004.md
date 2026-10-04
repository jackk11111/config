# Recovery — final runtime-qualified baseline (2026-10-04)

This document freezes the on-device recovery/AUTODATA state that passed a real cold boot. It supersedes the earlier "runtime repair in progress" status.

## Canonical runtime state

- Recovery image SHA-256: `dec15f4b66b16a68a9eb40b5f6f17b92a8429a5e1d73f6eba81c3a524a7993ff`
- Embedded `auto-data.sh` wrapper SHA-256: `daa7cbf920367adfebaf83487bc14207157b0f2b34561dd4bb04c5d681d37a6c`
- Final AUTODATA script path: `/metadata/ticwatch-rescue/crypto/auto-data-wear7-final-20261004.sh`
- Final AUTODATA script SHA-256: `8d6d4f92bce999fbe2bfed0ce5b5bbeb60d08cc8dbd1df4dbdf15b4d623af0c3`
- Full Android 13 userspace bundle path: `/cache/ticwatch-recovery/a13crypto/a13-full-autodata-lib.tgz`
- Full Android 13 bundle SHA-256: `ee0cdd779c1057b8cd5eed2f0e1ba3ea605466b6653b9e84353763dd95807f80`
- Q7 runtime archive retained for provenance: `/metadata/ticwatch-rescue/a13crypto/q7-runtime.tgz`
- Q7 runtime archive SHA-256: `80157bb567be9bb8f8d5e936566900211968b776ca8d7502259e88ad45bf7aef`

The embedded wrapper is persistent across reboot and delegates to the final AUTODATA script above. The full A13 bundle is intentionally stored on `cache`, not `metadata`, because `metadata` does not have enough free capacity for the ~59 MB bundle.

## Final cold-boot qualification

The final cold boot produced all of the following gates in one autonomous run:

```text
STOCK_SYSTEM=PASS
STOCK_BINDS=PASS
FULL_RUNTIME_ROOT_MODE=755
HWSM=PASS
QSEE_PID=934
KEYMASTER_PID=983
KEYMASTER_HIDL=PASS
STOCK_SM_PID=1029
KEYSTORE2=PASS
PATCHED_VOLD=PASS
FSTAB_BIND=PASS
VOLD_PID=1061
MOUNTFSTAB_RC=0
DATA_MOUNT=PASS
ENABLEFILECRYPTO_RC=25
SYSTEM_DE_KEY_UNCHANGED=PASS
DATA_RW=PASS
MODULES_RW=PASS
RESULT=AUTODATA_PASS
MODULES_RW_VERIFY=PASS
RESULT=AUTODATA_FULLROOT755_COLD_BOOT_PASS
```

`ENABLEFILECRYPTO_RC=25` is not a failure for this baseline: the system DE key remained unchanged and both `/data` and `/data/adb/modules` passed real RW verification.

## Root cause of the final cold-boot failure

The A13 full runtime itself was correct. The final blocker was DAC traversal of its extraction root:

```text
/tmp/tw-a13full     mode 0700 root:root
/tmp/tw-a13full/lib mode 0755
android.hidl.token@1.0.so mode 0644
```

`tw_r7g_hwsm` runs as Android user `system`. The library `android.hidl.token@1.0.so` existed in both the full A13 runtime and Q7 runtime with SHA-256:

`227196890e0e1f8bc826dd4716e91324e6379f14e69a18df8fa8465f4ea8759a`

but HWSM could not traverse `/tmp/tw-a13full` while its mode was `0700`. The dynamic linker therefore reported the library as "not found" even though it was present.

The final fix is deliberately minimal and must remain after extraction of the full A13 bundle:

```sh
chmod 0755 "$FULL" || fail FULL_RUNTIME_ROOT_CHMOD
```

Do not replace this with recursive permission changes unless new evidence requires them. The inner library directories are already traversable and the libraries are already readable.

## Runtime architecture that passed

The qualified chain is:

`HWSM -> qseecomd -> Keymaster -> stock servicemanager -> Keystore2 -> patched Vold -> mountFstab -> /data RW -> /data/adb/modules RW`

Important runtime constraints:

- HWSM uses the complete A13 library runtime staged at `/tmp/tw-a13full`.
- QSEE/crypto userspace uses the same coherent A13 runtime where required.
- Keymaster is launched under `u:r:vendor_hal_keymaster_qti:s0` with the full A13 `LD_LIBRARY_PATH`; the original init service environment was insufficient after Wear 7.
- A13 VINTF and SELinux files are used as a coherent pair for the crypto runtime.
- Do not globally replace recovery `/system/lib`; that was previously shown to poison unrelated recovery tools.

## Proven false leads / non-final candidates

These are retained only as historical evidence and must not be promoted:

- `b1a2adffc9e963b83ab59ceb97c897125eb040f5755eb80fce105a640ae372f6` — complete hot PASS, but cold boot failed at HWSM before the DAC root fix.
- `ad029c214cf5bc45e18cc316a6da2d11a38f154efe5275a2ed86363a13117b26` — HWSM retry experiment; disproved because retries could not solve the inaccessible runtime root.
- `ce2432d73ec2955fe40a7a142ad0baabd8fdeedd8ebee19e10ee51e0e0af90de` — first stderr diagnostic; invalid capture destination for the `system` HWSM service.
- `b2666b652c92d4a848272bb9a30beccdd3d19b18d94d5362f4521bfdf6d369d8` — valid `/tmp` stderr diagnostic that exposed the missing-library symptom and led to the DAC root cause.

## Freeze rule

Recovery/AUTODATA is now closed and runtime-qualified. Do not reopen Wi-Fi recovery bring-up, wrapper persistence, HWSM/QSEE/Keymaster, `/data` decryption, or module RW work without new evidence that contradicts this cold-boot qualification.

The active project focus returns to the clean Wear 7 / clean kernel baseline. KernelSU Next 3.4.0 and SuSFS remain deferred until the clean Wear 7 baseline boots and is qualified on-device.
