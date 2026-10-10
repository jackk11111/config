# Evolution X Android 17 — POCO F8 Pro / Redmi K90 (annibale)

**Checkpoint 2026-10-10 — GitHub Free prebuild research COMPLETE for selected gates.**
This public repository was repurposed from TicWatch for free targeted preflight tests.
It is **not** a compiled ROM or an official EvoX release.

## Locked objective
- Evolution X branch `cnb`, Android 17, `lineage_annibale` device.
- **GApps FULL integrated** (`WITH_GMS=true`; mini/pico disabled).
- Main annibale camera HAL + Aperture. Separate Xiaomi MiuiCamera excluded from the first CORE build.
- No phone flash or paid server has been authorized or performed.

## Source baseline
- EvoX manifest pinned commit: `8e41c899421748f2738a60e5757a0be2c3e353bb`.
- Four extra annibale/kernel/vendor/hardware projects pinned in [manifest/annibale.xml](manifest/annibale.xml).
- Vendor GitLab pinned commit: `f34647e4a03e376251b8ff32e650ceb9d9c13885`.
- GApps repo `Evolution-X/vendor_gms` cnb **observed/tested at** `3e0987a856ee8bdd21b9ff1983a8e182873a64ad`; it is *not yet locked in the EvoX base manifest* and can move before future full sync.
- The five missing ArcSoft `.so` were reconstructed, SHA-checked and checked for structural ELF ABI off-repo. **Never upload them here.** The GitLab A17 original lacks exactly those five tracked files.

## Verified free GitHub Actions gates

| Gate | Result | Real evidence | Limits |
| --- | --- | --- | --- |
| #3 manifest | PASS | [run](https://github.com/jackk11111/ticwatch-pro5-dace/actions/runs/38038446575) | no full sync |
| #4 device | PASS | [run](https://github.com/jackk11111/ticwatch-pro5-dace/actions/runs/38038920698) | only 3 device-related repositories |
| #5 vendor-metadata | PASS | [run](https://github.com/jackk11111/ticwatch-pro5-dace/actions/runs/38039113614) | GitLab ref only |
| #6 vendor-tree | PASS | [run](https://github.com/jackk11111/ticwatch-pro5-dace/actions/runs/38040480814) | partial tree checkout |
| #7 vendor-checkout | PASS | [run](https://github.com/jackk11111/ticwatch-pro5-dace/actions/runs/38045767664) | 3914 vendor files, 11 LFS pointers |
| #8 vendor-lfs | PASS | [run](https://github.com/jackk11111/ticwatch-pro5-dace/actions/runs/38048838754) | 11/11 original ArcSoft LFS: **305106184 verified bytes** |
| #9 EvoX/GMS integration | PASS | [run](https://github.com/jackk11111/ticwatch-pro5-dace/actions/runs/38050380657) | 14 static checks, LFS batch server available; no Soong |
| #10 GMS LFS integrity | PASS | [run](https://github.com/jackk11111/ticwatch-pro5-dace/actions/runs/38050615264) | 7/7 LFS objects, **1206717451 bytes** SHA256 verified |
| #11 PixelOS OTA HTTP range | BLOCKED (optional) | [run](https://github.com/jackk11111/ticwatch-pro5-dace/actions/runs/38050786433) | SourceForge HTTP 403 from GH runner; not an EvoX defect |
| #12 GMS Git checkout | PASS | [run](https://github.com/jackk11111/ticwatch-pro5-dace/actions/runs/38050890351) | 414 tracked paths; 1845350512 file bytes incl. 7 LFS pointers, whose payloads were separately proven at #10 |

Note: Gate #10 initial run failed due to an incorrect assertion expecting eight **files** from eight `.gitattributes` **patterns**. There are seven actual matching files. The only change was to the assertion; the second run passed. Do not reopen this resolved CI bug.

Offline audit using saved GitLab inventory: `Android.bp` has **1673 distinct module names**. All **1674** referenced proprietary source paths exist except exactly the **five known ArcSoft**; all **2271** proprietary `PRODUCT_COPY_FILES` source paths checked are present. This remains a **static** audit, not a Soong/ABI runtime pass.

## External public precedents (references only)
- [PixelOS Android 17 annibale OTA, 2026-10-02](https://sourceforge.net/projects/annibale-builds/files/pixelos/20261002/) by source maintainer Ramshell688. **Do not flash/mix its boot images by analogy.** Its ZIP could not be accessed from free GitHub runner (403).
- [Evolution X Android 16 annibale builds](https://sourceforge.net/projects/smgreborn/files/roms/). Not a substitute for an EvoX Android 17 build.

## First truly unqualified gate after these tests
A **full repo sync** of EvoX Android 17 on a persistent Linux x86_64 build host with adequate storage (R2 host script requires **400 GiB free before sync**, target ~600 GiB SSD) and RAM (ideally ~64 GiB); then private R6 overlay of five previously recovered ArcSoft, full post-sync/Soong/VINTF/SELinux checks, `repo manifest -r`, and only then an actual ROM build. GitHub standard public runners are free for targeted jobs, **not suited to the complete source/build environment**.

**Do not** start a paid runner/cloud instance, upload proprietary binaries, repeat passed gates, assume zero runtime bugs, or flash the phone without a new explicit step.
