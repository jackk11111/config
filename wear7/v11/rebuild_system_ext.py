#!/usr/bin/env python3
"""Rebuild only V7 system_ext after the confirmed property-context fix.

All other logical partitions must round-trip byte-for-byte from canonical V7.
"""
import argparse, hashlib, json, os, re, shutil, subprocess
from pathlib import Path

SIZES={
 'system':1741303808,
 'system_ext':283598848,
 'product':1613258752,
 'vendor':297361408,
 'vendor_dlkm':63889408,
 'system_dlkm':348160,
}
SUPER_SIZE=4294967296
GROUP_SIZE=4284481536
SALT='29ee420fe79a48929c62ab7091d79c9575998f66d7f5e856987e7bbe578d5459'

def sha(p:Path):
    with p.open('rb') as f:
        return hashlib.file_digest(f,'sha256').hexdigest()

def main():
    ap=argparse.ArgumentParser()
    for k in ('work','tools','report','output'):
        ap.add_argument('--'+k,type=Path,required=True)
    a=ap.parse_args()
    a.output.mkdir(parents=True,exist_ok=True)
    env=os.environ.copy()
    env['PATH']=str(a.tools/'bin')+':'+env['PATH']
    env['LD_LIBRARY_PATH']=f'{a.tools}/lib64:{a.tools}/lib'

    def run(cmd,log=None):
        p=subprocess.run(list(map(str,cmd)),env=env,stdout=subprocess.PIPE,
                         stderr=subprocess.STDOUT,text=True,timeout=600)
        if log:
            (a.report/(log+'.log')).write_text(p.stdout)
        print(p.stdout[-12000:],flush=True)
        if p.returncode:
            raise RuntimeError(f'{cmd[0]} exited {p.returncode}')
        return p.stdout

    parts=a.work/'parts'
    stage=a.work/'stage-system_ext'
    for name,size in SIZES.items():
        p=parts/(name+'.img')
        if p.stat().st_size!=size:
            raise RuntimeError(f'V7 geometry changed: {name}={p.stat().st_size} expected={size}')
    original={n:sha(parts/(n+'.img')) for n in SIZES}

    # Exact fs metadata input for system_ext.
    cfg=a.work/'system_ext.fs_config'
    run(['python3','wear7/scripts/generate_exact_fs_config.py',
         stage,'system_ext',cfg])

    # Use the actual Android17 split file-context sources already shipped by V7.
    plat=a.work/'mnt/system/system/etc/selinux/plat_file_contexts'
    sxctx=stage/'etc/selinux/system_ext_file_contexts'
    contexts=a.work/'system_ext_combined_file_contexts'
    if not plat.is_file() or not sxctx.is_file():
        raise RuntimeError('missing V7 file_contexts inputs')
    contexts.write_bytes(plat.read_bytes()+b'\n'+sxctx.read_bytes())

    run(['python3','wear7/scripts/fs_semantic_manifest.py',
         stage,a.report/'system_ext_expected.tsv'])

    info=run([a.tools/'bin/tune2fs','-l',parts/'system_ext.img'])
    uuid=re.search(r'^Filesystem UUID:\s*(\S+)',info,re.M)
    inode=re.search(r'^Inode count:\s*(\d+)',info,re.M)
    if not uuid or not inode:
        raise RuntimeError('unable to read original system_ext ext4 metadata')
    inode_count=int(inode.group(1))+1024

    avb=a.tools/'bin/avbtool'
    maximum=int(run([avb,'add_hashtree_footer','--partition_size',
                     SIZES['system_ext'],'--calc_max_image_size']).strip())
    fs_size=(maximum//4096)*4096
    rebuilt=a.work/'system_ext.v11.img'

    run([a.tools/'bin/mkuserimg_mke2fs',
         stage,rebuilt,'ext4','/system_ext',fs_size,contexts,
         '--journal_size','0',
         '--timestamp','1230768000',
         '--fs_config',cfg,
         '--label','system_ext',
         '--inodes',inode_count,
         '--inode_size','256',
         '--reserved_percent','0',
         '--mke2fs_uuid',uuid.group(1),
         '--share_dup_blocks'],
        'SYSTEM_EXT_REBUILD')
    run(['e2fsck','-fn',rebuilt],'SYSTEM_EXT_FSCK')

    run([avb,'add_hashtree_footer',
         '--image',rebuilt,
         '--partition_name','system_ext',
         '--partition_size',SIZES['system_ext'],
         '--algorithm','NONE',
         '--salt',SALT])
    if rebuilt.stat().st_size!=SIZES['system_ext']:
        raise RuntimeError('rebuilt system_ext partition size mismatch')

    images={n:parts/(n+'.img') for n in SIZES}
    images['system_ext']=rebuilt

    # Restore canonical V7 bootchain, not V8/V9/V10 experiments.
    for n in ('boot','init_boot','vendor_boot','dtbo'):
        shutil.copyfile(a.work/'input'/(n+'.img'),a.output/(n+'.img'))

    cmd=[avb,'make_vbmeta_image',
         '--output',a.output/'vbmeta_system.img',
         '--padding_size','4096',
         '--algorithm','NONE','--flags','3','--rollback_index','1730419200']
    for n in ('system','system_ext','product'):
        cmd += ['--include_descriptors_from_image',images[n]]
    run(cmd,'VBMETA_SYSTEM')

    cmd=[avb,'make_vbmeta_image',
         '--output',a.output/'vbmeta.img',
         '--padding_size','8192',
         '--algorithm','NONE','--flags','3','--rollback_index','0']
    for n in ('boot','init_boot','vendor_boot','dtbo'):
        cmd += ['--include_descriptors_from_image',a.output/(n+'.img')]
    for n in ('system_dlkm','vendor','vendor_dlkm'):
        cmd += ['--include_descriptors_from_image',images[n]]
    cmd += ['--include_descriptors_from_image',a.output/'vbmeta_system.img']
    run(cmd,'VBMETA_ROOT')

    cmd=[a.tools/'bin/lpmake',
         '--metadata-size','65536','--metadata-slots','2',
         '--super-name','super',
         '--device',f'super:{SUPER_SIZE}',
         '--group',f'qti_dynamic_partitions:{GROUP_SIZE}']
    for n,size in SIZES.items():
        cmd += ['--partition',f'{n}:readonly:{size}:qti_dynamic_partitions',
                '--image',f'{n}={images[n]}']
    run(cmd+['--sparse','--output',a.output/'super.img'],'SUPER_BUILD')

    # Re-extract the exact super we will ship.
    raw=a.work/'v11-super.raw'
    run(['simg2img',a.output/'super.img',raw])
    if raw.stat().st_size!=SUPER_SIZE:
        raise RuntimeError('wrong expanded super size')
    raw_sha=sha(raw)
    final=a.work/'final-parts'
    final.mkdir(exist_ok=True)
    run([a.tools/'bin/lpunpack',raw,final])
    raw.unlink()

    for n in SIZES:
        got=sha(final/(n+'.img'))
        want=sha(images[n])
        if got!=want:
            raise RuntimeError('super roundtrip changed '+n)
        if n!='system_ext' and got!=original[n]:
            raise RuntimeError('V11 unexpectedly changed logical partition '+n)

    mount=a.work/'final-system_ext'
    mount.mkdir(exist_ok=True)
    run(['mount','-o','loop,ro,noload',final/'system_ext.img',mount])
    try:
        run(['python3','wear7/scripts/fs_semantic_manifest.py',
             mount,a.report/'system_ext_final.tsv'])
        if (a.report/'system_ext_expected.tsv').read_bytes() != (a.report/'system_ext_final.tsv').read_bytes():
            raise RuntimeError('rebuilt system_ext semantic contents/metadata changed')
    finally:
        run(['umount',mount])

    image_hashes={
      f.name:{'sha256':sha(f),'bytes':f.stat().st_size}
      for f in sorted(a.output.glob('*.img'))
    }
    manifest={
      'format':1,
      'candidate':'Wear7-V11',
      'device':'dace',
      'platform':'monaco',
      'ab':False,
      'input_candidate':'Wear7-V7',
      'input_run':35198609607,
      'source_commit':os.environ.get('GITHUB_SHA','unknown'),
      'super_expanded_bytes':SUPER_SIZE,
      'super_expanded_sha256':raw_sha,
      'partitions':SIZES,
      'images':image_hashes,
      'kernel':'5.15.220-Xinran_StarBai-Test+',
      'rootcause_fix':{
        'class':'PID1_PROPERTY_CONTEXT_SERIALIZATION_FATAL',
        'property':'ro.charger_mode_autoboot',
        'removed_from':'system_ext/etc/selinux/system_ext_property_contexts',
        'preserved_from':'vendor/etc/selinux/vendor_property_contexts',
        'mapping':'u:object_r:charger_config_prop:s0 exact bool',
      },
      'unchanged_logical_partitions':['system','product','vendor','vendor_dlkm','system_dlkm'],
      'avb':'unlocked_first_bringup_flags_3',
      'flash_authorized':False,
      'hardware_runtime':'UNTESTED',
    }
    (a.output/'CANDIDATE.json').write_text(json.dumps(manifest,indent=2)+'\n')
    (a.report/'FINAL_CANDIDATE_V11.json').write_text(json.dumps(manifest,indent=2)+'\n')
    rows=[f'{sha(f)}  {f.name}' for f in sorted(a.output.iterdir())
          if f.is_file() and f.name!='SHA256SUMS.txt']
    (a.output/'SHA256SUMS.txt').write_text('\n'.join(rows)+'\n')
    print('V11_SYSTEM_EXT_ONLY_REBUILD=PASS',flush=True)
    print('V11_UNCHANGED_LOGICAL_PARTITIONS=system,product,vendor,vendor_dlkm,system_dlkm',flush=True)

if __name__=='__main__':
    main()
