#!/usr/bin/env python3
"""Run independent Android17 compatibility gates and retain every real result.

An XML/label check is never substituted for policy compilation or idmap2.
No result produced here represents a hardware boot or recovery/rollback test.
"""
import argparse
import hashlib
import json
import os
import pathlib
import re
import subprocess
import xml.etree.ElementTree as ET


def main():
    p=argparse.ArgumentParser()
    for k in ('system','system-ext','product','vendor','tools','work','report'):
        p.add_argument('--'+k,type=pathlib.Path,required=True)
    a=p.parse_args(); a.work.mkdir(parents=True,exist_ok=True)
    results={}; env=os.environ.copy()
    env['LD_LIBRARY_PATH']=f'{a.tools}/lib64:{a.tools}/lib'
    def run(name,cmd,override=None):
        proc=subprocess.run(list(map(str,cmd)),stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,env=override or env,timeout=240)
        (a.report/(name+'.log')).write_text(proc.stdout)
        print(f'{name}_EXIT={proc.returncode}',flush=True)
        print(proc.stdout[:16000],flush=True)
        if proc.returncode: raise RuntimeError(name+' failed')
        return proc.stdout
    def gate(name,fn):
        try:
            fn(); results[name]={'status':'PASS'}
        except Exception as e:
            results[name]={'status':'FAIL','error':str(e)}
        print(name,json.dumps(results[name]),flush=True)
    apex=a.work/'apex'; apex.mkdir(exist_ok=True)
    roots={'system':a.system,'system_ext':a.system_ext,'product':a.product,'vendor':a.vendor,'odm':a.vendor/'odm'}
    def apex_gate():
        props={}
        for root in roots.values():
            for rel in ('build.prop','etc/build.prop'):
                f=root/rel
                if f.is_file():
                    props.update(line.split('=',1) for line in f.read_text(errors='replace').splitlines() if '=' in line and not line.startswith('#'))
        if props.get('ro.apex.updatable')!='true': raise RuntimeError('unexpected APEX update mode')
        flat=[str(x) for root in roots.values() for x in (root/'apex').glob('*') if x.is_dir() and (x/'apex_manifest.pb').exists()]
        if flat: raise RuntimeError('mixed flattened APEX remains: '+repr(flat))
        cmd=[a.tools/'bin/apexd_host','--tool_path',a.tools,'--apex_path',apex]
        for key,root in roots.items(): cmd += ['--'+key+'_path',root]
        run('APEXD_HOST',cmd)
        nodes=ET.parse(apex/'apex-info-list.xml').getroot()
        matches=[n.attrib for n in nodes if n.attrib.get('moduleName')=='com.android.vndk.v33' and n.attrib.get('isActive')=='true']
        if len(matches)!=1: raise RuntimeError('VNDK33 not uniquely active in host activation')
        (a.report/'ACTIVE_VNDK33.json').write_text(json.dumps(matches,indent=2)+'\n')
        # Verify that the packaging did not change even one stock library.
        expected=json.loads((a.report/'VNDK33_PAYLOAD_SHA256.json').read_text())
        candidates=[apex/'com.android.vndk.v33']+list(apex.glob('com.android.vndk.v33@*'))
        active=next((x for x in candidates if (x/'lib').is_dir()),None)
        if active is None: raise RuntimeError('activated VNDK33 payload not exposed')
        for rel,want in expected.items():
            with (active/rel).open('rb') as f: got=hashlib.file_digest(f,'sha256').hexdigest()
            if got!=want: raise RuntimeError('changed stock payload '+rel)
    def vintf_gate():
        if not (apex/'apex-info-list.xml').is_file(): raise RuntimeError('APEX activation prerequisite missing')
        cmd=[a.tools/'bin/checkvintf','--check-compat']
        for key,root in roots.items(): cmd += ['--dirmap',f'/{key}:{root}']
        cmd += ['--dirmap',f'/apex:{apex}','--property','ro.product.first_api_level=30','--property','ro.boot.product.hardware.sku=','--property','ro.boot.product.vendor.sku=monaco']
        out=run('OFFICIAL_CHECKVINTF',cmd)
        if not re.search(r'^COMPATIBLE$',out,re.M): raise RuntimeError('no COMPATIBLE verdict')
    def selinux_gate():
        s=a.system/'etc/selinux'; sx=a.system_ext/'etc/selinux'; pr=a.product/'etc/selinux'; v=a.vendor/'etc/selinux'
        vers=(v/'plat_sepolicy_vers.txt').read_text().strip()
        if vers!='33.0': raise RuntimeError('unexpected vendor policy version '+vers)
        required=[s/'plat_sepolicy.cil',s/f'mapping/{vers}.cil',v/'plat_pub_versioned.cil',v/'vendor_sepolicy.cil']
        if not all(x.is_file() for x in required): raise RuntimeError('required split policy input missing')
        inputs=[required[0],required[1]]
        for f in [s/f'mapping/{vers}.compat.cil',sx/'system_ext_sepolicy.cil',sx/f'mapping/{vers}.cil',sx/f'mapping/{vers}.compat.cil',pr/'product_sepolicy.cil',pr/f'mapping/{vers}.cil']:
            if f.is_file(): inputs.append(f)
        inputs+=required[2:]
        od=a.vendor/'odm/etc/selinux/odm_sepolicy.cil'
        if od.is_file(): inputs.append(od)
        genfs=v/'genfs_labels_version.txt'
        genfs_version=genfs.read_text().strip() if genfs.exists() else '202404'
        gf=s/f'plat_sepolicy_genfs_{genfs_version}.cil'
        if gf.is_file(): inputs.append(gf)
        hashes={str(f):hashlib.sha256(f.read_bytes()).hexdigest() for f in inputs}
        (a.report/'SELINUX_INPUT_SHA256.json').write_text(json.dumps(hashes,indent=2)+'\n')
        run('SELINUX_COMPILE',[a.tools/'bin/secilc',*inputs,'-m','-M','true','-G','-N','-c','30','-o',a.work/'combined.sepolicy','-f',a.work/'compiled.file_contexts'])
        if (a.work/'combined.sepolicy').stat().st_size==0: raise RuntimeError('empty compiled policy')
    def idmap_gate():
        target=a.system/'priv-app/ClockworkSetupWizard/ClockworkSetupWizard.apk'
        overlay=a.product/'overlay/DaceEnduroFastPairOverlay/DaceEnduroFastPairOverlay.apk'
        badging=run('RRO_BADGING',[a.tools/'bin/aapt2','dump','badging',overlay])
        m=re.search(r"targetSdkVersion:'(\d+)'",badging)
        if not m: raise RuntimeError('overlay targetSdk unknown')
        target_sdk=int(m.group(1))
        # Match Android IdmapManager: preinstalled pre-Q overlays do not enforce
        # overlayable; Q+ overlays always do. Never modify targetSdk to pass.
        flags=['--policy','public','--policy','product']
        if target_sdk<29: flags+=['--ignore-overlayable']
        binfile=a.system/'bin/idmap2'
        data=binfile.read_bytes()[:20]
        if data[:4]!=b'\x7fELF' or int.from_bytes(data[18:20],'little')!=40: raise RuntimeError('expected ARM32 idmap2')
        linker=apex/'com.android.runtime/bin/linker'
        if not linker.is_file(): raise RuntimeError('exact Android linker unavailable')
        libdirs=[a.system/'lib',a.system_ext/'lib',a.product/'lib']
        for x in apex.iterdir():
            if x.is_dir(): libdirs += [x/'lib',x/'lib/bionic']
        libs=':'.join(str(x) for x in libdirs if x.is_dir())
        targetenv=env.copy(); targetenv.pop('LD_LIBRARY_PATH',None)
        cmd=['/usr/bin/qemu-arm-static',linker,'--library-path',libs,binfile]
        outpath=a.work/'dace.idmap'
        run('IDMAP_CREATE',cmd+['create','--target-apk-path',target,'--overlay-apk-path',overlay,'--idmap-path',outpath,*flags],targetenv)
        if not outpath.is_file() or outpath.stat().st_size==0: raise RuntimeError('no idmap created')
        run('IDMAP_DUMP',cmd+['dump','--idmap-path',outpath],targetenv)
        (a.report/'IDMAP_RUNTIME_POLICY.json').write_text(json.dumps({'target_sdk':target_sdk,'partition':'product','enforce_overlayable':target_sdk>=29,'target_sha256':hashlib.sha256(target.read_bytes()).hexdigest(),'overlay_sha256':hashlib.sha256(overlay.read_bytes()).hexdigest()},indent=2)+'\n')
    gate('APEX_INTEGRATION',apex_gate)
    gate('OFFICIAL_VINTF',vintf_gate)
    gate('SELINUX_POLICY',selinux_gate)
    gate('FASTPAIR_IDMAP2',idmap_gate)
    results['HARDWARE_RUNTIME']={'status':'UNTESTED'}
    results['RECOVERY_ROLLBACK']={'status':'UNTESTED'}
    (a.report/'GATES.json').write_text(json.dumps(results,indent=2)+'\n')
    if any(results[x]['status']!='PASS' for x in ('APEX_INTEGRATION','OFFICIAL_VINTF','SELINUX_POLICY','FASTPAIR_IDMAP2')):
        raise SystemExit(1)


if __name__=='__main__': main()
