#!/usr/bin/env python3
import hashlib
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import textwrap
import urllib.request
import zipfile

import yaml

BASE_COMMIT = "0402bd118a891fd5802214dd2c64f1855aed4f73"
BASE_WORKFLOW = ".github/workflows/wear7-final-candidate-assembly.yml"
CLEAN_KERNEL_SHA = "c37800338faa30d6600bd9e422c57d839148e6029a03daa351fe338b68b533a7"
CLEAN_KERNEL_RELEASE = "5.15.220-Xinran_StarBai-Test+"
OTATOOLS_URL = "https://ci.android.com/builds/submitted/16102939/aosp_cf_x86_64_only_phone-userdebug/latest/raw/otatools.zip"
OTATOOLS_SHA = "f1da1fb14ad810835679abd5f8a30c0e4f4c5b6210d355b7e1995bc51d739d84"
STOCK_OTA_SHA = "ffa61d822a5c667c230ce2ba9426ce4eb282adcaa0891279ef002f65ca15a08d"

COMPAT32 = (
    "android.hardware.audio.common-V1-ndk.so",
    "android.hardware.bluetooth.audio-V2-ndk.so",
    "android.hardware.security.keymint-V2-ndk.so",
    "android.hardware.soundtrigger@2.0-core.so",
    "android.hardware.soundtrigger@2.0.so",
    "android.media.audio.common.types-V1-ndk.so",
    "android.media.audio.common.types-V1-ndk_platform.so",
    "android.media.soundtrigger.types-V1-ndk.so",
    "android.media.soundtrigger.types-V1-ndk_platform.so",
    "libaudioroute.so",
    "libwifi-system-iface.so",
)

ROOT = pathlib.Path(os.environ["GITHUB_WORKSPACE"]).resolve()
RUNNER_TEMP = pathlib.Path(os.environ["RUNNER_TEMP"]).resolve()
WORK = RUNNER_TEMP / "work"
REPORT = ROOT / "wear7-final-report"
CANDIDATE = ROOT / "wear7-final-candidate"
KERNEL_DIR = RUNNER_TEMP / "kernel-artifact"
TOOLS_ROOT = RUNNER_TEMP / "clean-v1-otatools"
TOOLS = TOOLS_ROOT / "extracted"


def sha256(path: pathlib.Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for b in iter(lambda: f.read(8 * 1024 * 1024), b""):
            h.update(b)
    return h.hexdigest()


def run(argv, *, env=None, cwd=ROOT, stdout=None):
    argv = [str(x) for x in argv]
    print("RUN", " ".join(argv), flush=True)
    subprocess.run(argv, cwd=cwd, env=env, check=True, timeout=1800, stdout=stdout)


def shell(script: str, env: dict, name: str):
    print(f"\n===== CLEAN_V1 CORE: {name} =====", flush=True)
    subprocess.run(["bash", "-Eeuo", "pipefail", "-c", script], cwd=ROOT, env=env, check=True, timeout=5400)


def setup_otatools(env: dict):
    if (TOOLS / "bin/checkvintf").is_file():
        env["PATH"] = f"{TOOLS / 'bin'}:{env.get('PATH','')}"
        env["LD_LIBRARY_PATH"] = f"{TOOLS / 'lib64'}:{TOOLS / 'lib'}"
        return
    TOOLS_ROOT.mkdir(parents=True, exist_ok=True)
    zpath = TOOLS_ROOT / "otatools.zip"
    urllib.request.urlretrieve(OTATOOLS_URL, zpath)
    got = sha256(zpath)
    if got != OTATOOLS_SHA:
        raise RuntimeError(f"otatools SHA mismatch {got}")
    with zipfile.ZipFile(zpath) as z:
        out = TOOLS.resolve()
        for n in z.namelist():
            if not n.startswith(("bin/", "lib64/", "lib/", "framework/")):
                continue
            dst = (out / n).resolve()
            if not dst.is_relative_to(out):
                raise RuntimeError("unsafe otatools path")
            z.extract(n, out)
    zpath.unlink()
    for p in (TOOLS / "bin").iterdir():
        if p.is_file():
            p.chmod(p.stat().st_mode | 0o111)
    dbg = TOOLS / "bin/debugfs"
    if not dbg.exists() and (TOOLS / "bin/debugfs_static").exists():
        dbg.symlink_to("debugfs_static")
    env["PATH"] = f"{TOOLS / 'bin'}:{env.get('PATH','')}"
    env["LD_LIBRARY_PATH"] = f"{TOOLS / 'lib64'}:{TOOLS / 'lib'}"


def root_of_system_mount(mount: pathlib.Path) -> pathlib.Path:
    return mount / "system" if (mount / "system").is_dir() else mount


def mount_ro(image: pathlib.Path, where: pathlib.Path):
    where.mkdir(parents=True, exist_ok=True)
    run(["sudo", "mount", "-o", "loop,ro,noload", image, where])


def umount(where: pathlib.Path):
    subprocess.run(["sudo", "umount", str(where)], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def patch_vendor_ndk_manifest(system_root: pathlib.Path):
    manifest = system_root / "etc/vintf/manifest.xml"
    code = r'''import sys,xml.etree.ElementTree as E
p=sys.argv[1]; t=E.parse(p); r=t.getroot()
vs=[x for x in r.findall('vendor-ndk') if x.findtext('version')=='33']
if len(vs)>1: raise SystemExit('duplicate vendor-ndk 33')
if not vs:
    x=E.Element('vendor-ndk'); E.SubElement(x,'version').text='33'
    s=r.find('system-sdk'); r.insert(list(r).index(s) if s is not None else len(r),x)
E.indent(t,space='    '); t.write(p,encoding='utf-8',xml_declaration=True)
'''
    run(["sudo", "python3", "-c", code, manifest])


def assert_clean_tree(system_partition: pathlib.Path, sx: pathlib.Path, product: pathlib.Path, tag: str):
    forbidden = [
        system_partition / "system/app/KernelSUNextManager",
        system_partition / "system/priv-app/KernelSUNextManager",
        sx / "bin/ksud",
        sx / "etc/init/wear7-dace-wireless-bootstrap.rc",
        sx / "etc/wear7/96-wifi-adb-persistent.sh",
        sx / "etc/init/wear7-v11-stage-marker.rc",
        sx / "etc/manager-cert.der",
    ]
    bad = [str(x) for x in forbidden if x.exists() or x.is_symlink()]
    for base in (system_partition, sx, product):
        for p in base.rglob("*"):
            n = p.name.lower()
            if "kernelsu" in n or n == "ksud" or "brene" in n:
                bad.append(str(p))
    build_prop = system_partition / "system/build.prop"
    if build_prop.is_file():
        text = build_prop.read_text(errors="replace")
        for exact in ("persist.adb.tcp.port=5555", "persist.adb.tls_server.enable=1"):
            if re.search(rf"(?m)^{re.escape(exact)}$", text):
                bad.append(f"{build_prop}:{exact}")
    if bad:
        raise RuntimeError(f"{tag}: custom/root contamination remains: {bad[:30]}")
    (REPORT / f"CLEAN_ABSENCE_{tag}.txt").write_text(
        "CONFIG_KSU=ABSENT_KERNEL_GATE\nKERNELSU_MANAGER=ABSENT\nKSUD=ABSENT\nSUSFS_USERSPACE=ABSENT\nBRENE=ABSENT\nCUSTOM_WIFI_ADB_BOOTSTRAP=ABSENT\nDIAG_STAGE_MARKER=ABSENT\n"
    )


def host_init_gate(system_root: pathlib.Path, sx: pathlib.Path, product: pathlib.Path, vendor: pathlib.Path, tag: str, env: dict):
    h = TOOLS / "bin/host_init_verifier"
    cmd = [str(h), "--out_system", str(system_root), "--out_system_ext", str(sx), "--out_product", str(product), "--out_vendor", str(vendor)]
    for p in (
        system_root / "etc/selinux/plat_property_contexts",
        sx / "etc/selinux/system_ext_property_contexts",
        product / "etc/selinux/product_property_contexts",
        vendor / "etc/selinux/vendor_property_contexts",
    ):
        if p.is_file():
            cmd.append(f"--property-contexts={p}")
    for p in (system_root / "etc/passwd", sx / "etc/passwd", product / "etc/passwd", vendor / "etc/passwd"):
        if p.is_file():
            cmd += ["-p", str(p)]
    proc = subprocess.run(cmd, cwd=ROOT, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=300)
    log = REPORT / f"HOST_INIT_{tag}.log"
    log.write_text(proc.stdout)
    forbidden = ("Unable to serialize property contexts", "Duplicate exact match detected", "Failed to load serialized property info file")
    for x in forbidden:
        if x in proc.stdout:
            raise RuntimeError(f"{tag}: fatal host-init property error: {x}")
    errs = []
    for line in proc.stdout.splitlines():
        if not line.startswith("host_init_verifier: "):
            continue
        if re.search(r"Failed to parse init scripts with \d+ error\(s\)\.$", line):
            continue
        allowed = (
            ("/vendor/etc/init/android.hardware.wifi.supplicant-service.rc:" in line
             or "/vendor/etc/init/boringssl_self_test.rc:" in line
             or "/vendor/etc/init/vendor_flash_recovery.rc:" in line)
            and "No user specified for service '" in line
        )
        if not allowed:
            errs.append(line)
    if errs:
        raise RuntimeError(f"{tag}: new host-init errors: {errs[:20]}")
    (REPORT / f"HOST_INIT_{tag}_VERDICT.txt").write_text("HOST_INIT_DIFFERENTIAL_GATE=PASS\n")


def validate_payload(system_partition: pathlib.Path, sx: pathlib.Path, product: pathlib.Path, vendor: pathlib.Path, stock_system: pathlib.Path, tag: str, env: dict):
    system_root = root_of_system_mount(system_partition)
    vwork = RUNNER_TEMP / f"clean-v1-validation-{tag.lower()}"
    run(["sudo", "env", f"PATH={env['PATH']}", f"LD_LIBRARY_PATH={env['LD_LIBRARY_PATH']}", "python3",
         ROOT / "wear7/current/lib/validate_images.py",
         "--system", system_root, "--system-ext", sx, "--product", product, "--vendor", vendor,
         "--tools", TOOLS, "--work", vwork, "--report", REPORT])
    run(["sudo", "env", f"PATH={env['PATH']}", f"LD_LIBRARY_PATH={env['LD_LIBRARY_PATH']}", "python3",
         ROOT / "wear7/current/lib/validate_native_compat.py",
         "--system", system_root, "--system-ext", sx, "--product", product, "--vendor", vendor,
         "--apex", vwork / "apex", "--stock-system", stock_system,
         "--report", REPORT / f"NATIVE_STOCK32_COMPAT_{tag}.json"])
    host_init_gate(system_root, sx, product, vendor, tag, env)
    assert_clean_tree(system_partition, sx, product, tag)


def inject_clean_bridges(env: dict):
    print("\n===== CLEAN_V1 INJECT PROVEN BRIDGES =====", flush=True)
    setup_otatools(env)
    stage_system_partition = WORK / "stage-system"
    stage_system = stage_system_partition / "system"
    stage_sx = WORK / "stage-system_ext"
    stage_product = WORK / "stage-product"
    stock_sys_mnt = RUNNER_TEMP / "clean-v1-stock-system"
    vendor_mnt = RUNNER_TEMP / "clean-v1-stock-vendor"
    mount_ro(WORK / "tic-system.raw", stock_sys_mnt)
    mount_ro(WORK / "tic-vendor.raw", vendor_mnt)
    try:
        stock_system = root_of_system_mount(stock_sys_mnt)
        source_vndk = stock_system / "apex/com.android.vndk.current"
        staged_vndk = stage_system / "apex/com.android.vndk.current"
        if not (source_vndk / "apex_manifest.pb").is_file():
            raise RuntimeError("stock379 flattened VNDK33 source missing")
        run(["sudo", "rm", "-rf", staged_vndk])
        run(["sudo", "cp", "-a", source_vndk, staged_vndk])
        patch_vendor_ndk_manifest(stage_system)
        run(["sudo", "python3", ROOT / "wear7/current/lib/generate_framework_matrix_from_device_manifest.py",
             "--main", vendor_mnt / "etc/vintf/manifest_monaco.xml", "--fragments", vendor_mnt / "etc/vintf/manifest",
             "--out", stage_system / "etc/vintf/compatibility_matrix.dace.xml", "--sepolicy-version", "33.0",
             "--kernel-sepolicy-version", "30", "--matrix-version", "9.0"])
        run(["sudo", "env", f"PATH={env['PATH']}", f"LD_LIBRARY_PATH={env['LD_LIBRARY_PATH']}", "python3",
             ROOT / "wear7/current/lib/build_bridge.py", "--source", staged_vndk, "--system", stage_system,
             "--tools", TOOLS, "--work", RUNNER_TEMP / "clean-v1-vndk-bridge", "--report", REPORT])
        compat_report = REPORT / "STOCK32_COMPAT_SHA256.txt"
        rows = []
        for name in COMPAT32:
            src = stock_system / "lib" / name
            dst = stage_system / "lib" / name
            if not src.is_file():
                raise RuntimeError(f"stock379 missing ARM32 compat {name}")
            if dst.exists() or dst.is_symlink():
                raise RuntimeError(f"refusing to overwrite Pixel donor ARM32 file {dst}")
            run(["sudo", "cp", "-a", "--preserve=all", src, dst])
            rows.append(f"{sha256(dst)}  {dst}")
        compat_report.write_text("\n".join(rows) + "\n")
        fixrep = REPORT / "property-fix"
        run(["sudo", "python3", ROOT / "wear7/current/lib/fix_property_context_collision.py",
             "--system-root", stage_system, "--system-ext-root", stage_sx, "--product-root", stage_product,
             "--vendor-root", vendor_mnt, "--report", fixrep])
        for p in fixrep.iterdir():
            shutil.copy2(p, REPORT / p.name)
        validate_payload(stage_system_partition, stage_sx, stage_product, vendor_mnt, stock_system, "STAGED", env)
    finally:
        umount(stock_sys_mnt)
        umount(vendor_mnt)


def validate_rebuilt_payload(env: dict):
    print("\n===== CLEAN_V1 VALIDATE REBUILT FILESYSTEMS =====", flush=True)
    setup_otatools(env)
    mounts = {k: RUNNER_TEMP / f"clean-v1-final-{k}" for k in ("system", "system_ext", "product", "vendor", "stock_system")}
    mount_ro(WORK / "system.w7.raw", mounts["system"])
    mount_ro(WORK / "system_ext.w7.raw", mounts["system_ext"])
    mount_ro(WORK / "product.w7.raw", mounts["product"])
    mount_ro(WORK / "tic-vendor.raw", mounts["vendor"])
    mount_ro(WORK / "tic-system.raw", mounts["stock_system"])
    try:
        validate_payload(mounts["system"], mounts["system_ext"], mounts["product"], mounts["vendor"], root_of_system_mount(mounts["stock_system"]), "REBUILT", env)
    finally:
        for m in mounts.values():
            umount(m)


def validate_final_super(env: dict):
    print("\n===== CLEAN_V1 FINAL SUPER ROUNDTRIP =====", flush=True)
    setup_otatools(env)
    raw = RUNNER_TEMP / "clean-v1-final-super.raw"
    parts = RUNNER_TEMP / "clean-v1-final-parts"
    if parts.exists():
        shutil.rmtree(parts)
    parts.mkdir(parents=True)
    run(["simg2img", CANDIDATE / "super.img", raw], env=env)
    if raw.stat().st_size != 4294967296:
        raise RuntimeError("final expanded super is not 4 GiB")
    run(["lpunpack", raw, parts], env=env)
    raw.unlink()
    mounts = {k: RUNNER_TEMP / f"clean-v1-shipped-{k}" for k in ("system", "system_ext", "product", "vendor", "stock_system")}
    for k in ("system", "system_ext", "product", "vendor"):
        mount_ro(parts / f"{k}.img", mounts[k])
    mount_ro(WORK / "tic-system.raw", mounts["stock_system"])
    try:
        validate_payload(mounts["system"], mounts["system_ext"], mounts["product"], mounts["vendor"], root_of_system_mount(mounts["stock_system"]), "SHIPPED", env)
    finally:
        for m in mounts.values():
            umount(m)
    expected = {
        "vendor.img": "150238505037c881b079b7c9de1adc231f2c4a94b64f8dd3a7694ebc7408371e",
        "vendor_dlkm.img": "e9b865fc3eeb54cf1519cda55efbd30b2921e31765f5d98a3060575f95892ab6",
        "system_dlkm.img": "fdd73e1603333b926424fa5526f015701e453b54349efd012f35c714b202d8de",
    }
    rows = []
    for n, want in expected.items():
        got = sha256(parts / n)
        if got != want:
            raise RuntimeError(f"final {n} differs from stock379: {got}")
        rows.append(f"{n}\t{got}")
    (REPORT / "STOCK379_HARDWARE_PARTITIONS_FINAL.tsv").write_text("\n".join(rows) + "\n")


def patch_script(name: str, script: str) -> str:
    canonical_paths = {
        "wear7/scripts/reconstruct_block_ota.py": "wear7/current/tools/reconstruct_block_ota.py",
        "wear7/scripts/apply_stage0_overlay_v8.py": "wear7/current/tools/apply_stage0_overlay_v8.py",
        "wear7/scripts/generate_exact_fs_config.py": "wear7/current/tools/generate_exact_fs_config.py",
        "wear7/scripts/validate_vintf_static_contract.py": "wear7/current/tools/validate_vintf_static_contract.py",
        "wear7/scripts/fs_semantic_manifest.py": "wear7/current/tools/fs_semantic_manifest.py",
        "wear7/manifests/STAGE0_SOURCE_HASHES.tsv": "wear7/current/data/STAGE0_SOURCE_HASHES.tsv",
    }
    for old, new in canonical_paths.items():
        script = script.replace(old, new)
    if name == "Stage exact Pixel trees and apply Stage0 plus wireless root contract":
        drop = (
            "add_dace_wireless_root_bootstrap.py", "WEAR7_DACE_WIRELESS_BOOTSTRAP",
            "persist.adb.tcp.port", "persist.adb.tls_server.enable",
            "96-wifi-adb-persistent.sh", "wear7-dace-wireless-bootstrap.rc",
        )
        script = "\n".join(x for x in script.splitlines() if not any(y in x for y in drop)) + "\n"
    if name == "Mount final filesystem payloads and run exact static gates":
        drop = (
            "WIRELESS_BOOTSTRAP_SELINUX", "wear7-dace-wireless-bootstrap.rc",
            "96-wifi-adb-persistent.sh", "service.adb.tcp.port", "config_wifiSuspendOptimizationsEnabled",
        )
        script = "\n".join(x for x in script.splitlines() if not any(y in x for y in drop)) + "\n"
    return script


def rewrite_final_metadata():
    manifest = CANDIDATE / "CANDIDATE_MANIFEST.txt"
    lines = manifest.read_text().splitlines() if manifest.is_file() else []
    reject_prefixes = (
        "WIRELESS_ADB_", "ROOT_BACKEND=", "ROOT_PATH=", "WIRELESS_ROOT_RUNTIME=",
        "RECOVERY_ROLLBACK_READY_", "FIRST_WEAR7_FLASH=",
    )
    lines = [x for x in lines if not x.startswith(reject_prefixes)]
    lines += [
        "CANDIDATE=WEAR7_DACE_CLEAN_V1",
        f"KERNEL_RELEASE={CLEAN_KERNEL_RELEASE}",
        f"KERNEL_IMAGE_SHA256={CLEAN_KERNEL_SHA}",
        "KERNELSU=ABSENT",
        "SUSFS=ABSENT",
        "AUTOINIT_CUSTOM=ABSENT",
        "TWKEXEC_DIAGNOSTIC=ABSENT",
        "KERNELSU_MANAGER=ABSENT",
        "KSUD=ABSENT",
        "BRENE=ABSENT",
        "CUSTOM_WIFI_ADB_BOOTSTRAP=ABSENT",
        "DIAGNOSTIC_STAGE_MARKERS=ABSENT",
        "VNDK33_BRIDGE=PACKAGED_STOCK379_PAYLOAD",
        "DACE_SUPPLEMENTAL_FRAMEWORK_MATRIX=INSTALLED",
        "STOCK379_ARM32_NATIVE_COMPAT=PASS",
        "V11_PROPERTY_CONTEXT_ROOTCAUSE_FIX=PASS",
        "OFFICIAL_VINTF=PASS",
        "SELINUX_POLICY=PASS",
        "FASTPAIR_IDMAP2=PASS",
        "NATIVE_STOCK32_COMPAT=PASS",
        "HOST_INIT_DIFFERENTIAL=PASS",
        "RECOVERY_BASELINE=TicWatch-R7H-UNIVERSAL-LOCALRT2-FULLDATE-AUTODATA-CEV2-TWDECRYPT8-TWFLASH-20261002.img",
        "FIRST_FLASH_AUTHORIZED=NO_UNTIL_USER_SESSION",
        "HARDWARE_RUNTIME=UNTESTED",
    ]
    seen = set(); clean = []
    for x in lines:
        if x not in seen:
            clean.append(x); seen.add(x)
    manifest.write_text("\n".join(clean) + "\n")
    verdict = REPORT / "FINAL_CLEAN_V1_VERDICT.txt"
    verdict.write_text(
        "WEAR7_DACE_CLEAN_V1_OFFLINE=PASS\n"
        "KERNEL_CLEAN_5_15_220=PASS\n"
        "KMI_STOCK379_337_OF_337=PASS\n"
        "PIXEL_SYSTEM_SYSTEM_EXT_PRODUCT=SOURCE_REBUILT\n"
        "DACE_VENDOR_VENDOR_DLKM_SYSTEM_DLKM=STOCK379_EXACT\n"
        "VNDK33=PASS\nOFFICIAL_CHECKVINTF=PASS\nSELINUX=PASS\nFASTPAIR_IDMAP2=PASS\n"
        "STOCK32_NATIVE_CLOSURE=PASS\nV11_PROPERTY_CONTEXT_FIX=PASS\nHOST_INIT=PASS\n"
        "KERNELSU=ABSENT\nSUSFS=ABSENT\nKSUD=ABSENT\nKERNELSU_MANAGER=ABSENT\n"
        "CUSTOM_WIFI_ADB_BOOTSTRAP=ABSENT\nDIAG_MARKERS=ABSENT\n"
        "HARDWARE_RUNTIME=UNTESTED\nFLASH_PERFORMED=NO\n"
    )
    sums = CANDIDATE / "SHA256SUMS.txt"
    files = sorted(p for p in CANDIDATE.iterdir() if p.is_file() and p.name != sums.name)
    sums.write_text("\n".join(f"{sha256(p)}  {p.name}" for p in files) + "\n")
    report_sums = REPORT / "REPORT_SHA256SUMS.txt"
    rfiles = sorted(p for p in REPORT.iterdir() if p.is_file() and p.name != report_sums.name)
    report_sums.write_text("\n".join(f"{sha256(p)}  {p.name}" for p in rfiles) + "\n")


def main():
    report = KERNEL_DIR / "CLEAN_KERNEL_REPORT.txt"
    image = KERNEL_DIR / "Image"
    if not report.is_file() or not image.is_file():
        raise SystemExit("clean kernel artifact incomplete")
    if sha256(image) != CLEAN_KERNEL_SHA:
        raise SystemExit("clean kernel Image SHA mismatch")
    rt = report.read_text()
    required = (
        f"KERNEL_RELEASE={CLEAN_KERNEL_RELEASE}", "CONFIG_KSU=ABSENT", "KERNELSU_SOURCE=ABSENT",
        "SUSFS_SOURCE=ABSENT", "KEXEC_DIAGNOSTIC_PATCHES=ABSENT", "CONFIG_MODVERSIONS=YES",
        "STOCK379_KMI_TARGETED_GATE=PASS_337_OF_337",
    )
    for x in required:
        if x not in rt:
            raise SystemExit("clean kernel gate missing: " + x)
    (KERNEL_DIR / "docs").mkdir(exist_ok=True)
    shutil.copy2(report, KERNEL_DIR / "docs/CANDIDATE_REPORT.txt")

    base = subprocess.check_output(["git", "show", f"{BASE_COMMIT}:{BASE_WORKFLOW}"], cwd=ROOT, text=True)
    wf = yaml.safe_load(base)
    steps = wf["jobs"]["assemble"]["steps"]
    env = os.environ.copy()
    for k, v in wf.get("env", {}).items():
        env[str(k)] = str(v)
    env["KERNEL_IMAGE_SHA256"] = CLEAN_KERNEL_SHA
    env["KERNEL_RUN_ID"] = "37183075933"
    env["KERNEL_ARTIFACT"] = "TicWatch-Wear7-Clean-Kernel-5.15.220-NoKSU-V2"

    envfile = RUNNER_TEMP / "clean-v1-github-env"
    pathfile = RUNNER_TEMP / "clean-v1-github-path"
    envfile.write_text(""); pathfile.write_text("")
    env["GITHUB_ENV"] = str(envfile); env["GITHUB_PATH"] = str(pathfile)
    ep = pp = 0

    def absorb():
        nonlocal ep, pp
        t = envfile.read_text(); chunk = t[ep:]; ep = len(t)
        for line in chunk.splitlines():
            if line and "=" in line:
                k, v = line.split("=", 1); env[k] = v
        t = pathfile.read_text(); chunk = t[pp:]; pp = len(t)
        added = [x for x in chunk.splitlines() if x]
        if added:
            env["PATH"] = ":".join(reversed(added)) + ":" + env.get("PATH", "")

    ran = 0
    injected = rebuilt_validated = False
    for step in steps:
        script = step.get("run")
        if not script:
            continue
        name = step.get("name", "unnamed")
        if "${{" in script:
            raise SystemExit(f"unexpected Actions expression in historical shell step {name}")
        script = patch_script(name, script)
        if "wear7/scripts/" in script or "wear7/manifests/" in script:
            raise SystemExit(f"legacy Wear7 dependency path remains in historical step {name}")
        shell(script, env, name)
        absorb(); ran += 1
        if name == "Stage exact Pixel trees and apply Stage0 plus wireless root contract":
            inject_clean_bridges(env); injected = True
        elif name == "Mount final filesystem payloads and run exact static gates":
            validate_rebuilt_payload(env); rebuilt_validated = True

    if ran < 10 or not injected or not rebuilt_validated:
        raise SystemExit(f"historical core incomplete ran={ran} injected={injected} rebuilt_validated={rebuilt_validated}")
    validate_final_super(env)

    # Exact kernel bytes must be present in the final boot v4 payload.
    b = (CANDIDATE / "boot.img").read_bytes()
    if b[:8] != b"ANDROID!":
        raise SystemExit("final boot magic invalid")
    ksize = int.from_bytes(b[8:12], "little")
    embedded = b[4096:4096+ksize]
    if hashlib.sha256(embedded).hexdigest() != CLEAN_KERNEL_SHA:
        raise SystemExit("final boot does not embed exact clean kernel")
    (REPORT / "FINAL_BOOT_KERNEL_GATE.txt").write_text(f"KERNEL_SIZE={ksize}\nKERNEL_SHA256={CLEAN_KERNEL_SHA}\nFINAL_BOOT_KERNEL_GATE=PASS\n")

    rewrite_final_metadata()
    print("WEAR7_DACE_CLEAN_V1_OFFLINE=PASS")
    print("FLASH_AUTHORIZED=NO_UNTIL_USER_SESSION")


if __name__ == "__main__":
    main()
