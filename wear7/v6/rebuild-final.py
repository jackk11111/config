#!/usr/bin/env python3
"""Rebuild only changed filesystems, then verify the shipped super by extraction."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess


SIZES = {'system':1741303808, 'system_ext':283598848, 'product':1613258752,
         'vendor':297361408, 'vendor_dlkm':63889408, 'system_dlkm':348160}
SUPER_SIZE = 4294967296
GROUP_SIZE = 4284481536
SALT = '29ee420fe79a48929c62ab7091d79c9575998f66d7f5e856987e7bbe578d5459'


def sha(p):
    with p.open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()


def main():
    parser=argparse.ArgumentParser()
    for k in ('work','tools','report','output'):
        parser.add_argument('--'+k,type=Path,required=True)
    a=parser.parse_args(); a.output.mkdir(parents=True,exist_ok=True)
    env=os.environ.copy(); env['PATH']=str(a.tools/'bin')+':'+env['PATH']
    env['LD_LIBRARY_PATH']=f'{a.tools}/lib64:{a.tools}/lib'
    def run(cmd,log=None):
        p=subprocess.run(list(map(str,cmd)),env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=600)
        if log: (a.report/(log+'.log')).write_text(p.stdout)
        print(p.stdout[-12000:],flush=True)
        if p.returncode: raise RuntimeError(f'{cmd[0]} exited {p.returncode}')
        return p.stdout
    parts=a.work/'parts'; stage=a.work/'stage-system'; output=a.output
    for name,size in SIZES.items():
        if (parts/(name+'.img')).stat().st_size!=size: raise RuntimeError('geometry changed: '+name)
    original={name:sha(parts/(name+'.img')) for name in SIZES}
    cfg=a.work/'system.fs_config'; contexts=a.work/'system.file_contexts'
    run(['python3','wear7/scripts/generate_exact_fs_config.py',stage,'',cfg])
    context_rows=[]
    for root,dirs,files in os.walk(stage,followlinks=False):
        for name in dirs+files:
            f=Path(root)/name
            label=os.getxattr(f,'security.selinux',follow_symlinks=False).rstrip(b'\0').decode()
            context_rows.append(re.escape('/'+str(f.relative_to(stage)))+' '+label)
    rootlabel=os.getxattr(stage,'security.selinux').rstrip(b'\0').decode()
    contexts.write_text('/ '+rootlabel+'\n'+'\n'.join(context_rows)+'\n')
    run(['python3','wear7/scripts/fs_semantic_manifest.py',stage,a.report/'system_expected.tsv'])
    info=run([a.tools/'bin/tune2fs','-l',parts/'system.img'])
    uuid=re.search(r'^Filesystem UUID:\s*(\S+)',info,re.M).group(1)
    inode_count=int(re.search(r'^Inode count:\s*(\d+)',info,re.M).group(1))+1024
    avb=a.tools/'bin/avbtool'
    maximum=int(run([avb,'add_hashtree_footer','--partition_size',SIZES['system'],'--calc_max_image_size']).strip())
    fs_size=maximum//4096*4096
    rebuilt=a.work/'system.v6.img'
    run([a.tools/'bin/mkuserimg_mke2fs',stage,rebuilt,'ext4','/',fs_size,contexts,
         '--journal_size','0','--timestamp','1230768000','--fs_config',cfg,'--label','system',
         '--inodes',inode_count,'--inode_size','256','--reserved_percent','0',
         '--mke2fs_uuid',uuid,'--share_dup_blocks'],'SYSTEM_REBUILD')
    run(['e2fsck','-fn',rebuilt],'SYSTEM_FSCK')
    run([avb,'add_hashtree_footer','--image',rebuilt,'--partition_name','system',
         '--partition_size',SIZES['system'],'--algorithm','NONE','--salt',SALT])
    images={name:parts/(name+'.img') for name in SIZES}; images['system']=rebuilt
    for n in ('boot','init_boot','vendor_boot','dtbo'):
        shutil.copyfile(a.work/'input'/(n+'.img'),output/(n+'.img'))
    cmd=[avb,'make_vbmeta_image','--output',output/'vbmeta_system.img','--padding_size','4096',
         '--algorithm','NONE','--flags','3','--rollback_index','1730419200']
    for n in ('system','system_ext','product'): cmd+=['--include_descriptors_from_image',images[n]]
    run(cmd)
    cmd=[avb,'make_vbmeta_image','--output',output/'vbmeta.img','--padding_size','8192',
         '--algorithm','NONE','--flags','3','--rollback_index','0']
    for n in ('boot','init_boot','vendor_boot','dtbo'): cmd+=['--include_descriptors_from_image',output/(n+'.img')]
    for n in ('system_dlkm','vendor','vendor_dlkm'): cmd+=['--include_descriptors_from_image',images[n]]
    cmd+=['--include_descriptors_from_image',output/'vbmeta_system.img']; run(cmd)
    cmd=[a.tools/'bin/lpmake','--metadata-size','65536','--metadata-slots','2','--super-name','super',
         '--device',f'super:{SUPER_SIZE}','--group',f'qti_dynamic_partitions:{GROUP_SIZE}']
    for n,size in SIZES.items():
        cmd+=['--partition',f'{n}:readonly:{size}:qti_dynamic_partitions','--image',f'{n}={images[n]}']
    run(cmd+['--sparse','--output',output/'super.img'],'SUPER_BUILD')
    final=a.work/'final-parts'; final.mkdir()
    raw=a.work/'final-super.raw'
    run(['simg2img',output/'super.img',raw])
    if raw.stat().st_size!=SUPER_SIZE: raise RuntimeError('wrong final super size')
    raw_sha256=sha(raw)
    run([a.tools/'bin/lpunpack',raw,final]); raw.unlink()
    for n in SIZES:
        if sha(final/(n+'.img'))!=sha(images[n]): raise RuntimeError('super roundtrip changed '+n)
        if n!='system' and sha(final/(n+'.img'))!=original[n]: raise RuntimeError('unchanged partition changed '+n)
    mount=a.work/'final-system'; mount.mkdir()
    run(['mount','-o','loop,ro',final/'system.img',mount])
    try:
        run(['python3','wear7/scripts/fs_semantic_manifest.py',mount,a.report/'system_final.tsv'])
        if (a.report/'system_expected.tsv').read_bytes()!=(a.report/'system_final.tsv').read_bytes():
            raise RuntimeError('filesystem contents, ownership, modes, links or security xattrs changed')
        # This second validation reads the system actually shipped inside super.
        # The other five images were compared byte for byte after extraction.
        report=a.report/'final'; report.mkdir()
        shutil.copyfile(a.report/'VNDK33_PAYLOAD_SHA256.json',report/'VNDK33_PAYLOAD_SHA256.json')
        run(['python3','wear7/v6/validate-images.py','--system',mount/'system',
             '--system-ext',a.work/'mnt/system_ext','--product',a.work/'mnt/product','--vendor',a.work/'mnt/vendor',
             '--tools',a.tools,'--work',a.work/'final-validation','--report',report],'FINAL_GATES')
    finally:
        run(['umount',mount])
    image_hashes={f.name:{'sha256':sha(f),'bytes':f.stat().st_size} for f in sorted(output.glob('*.img'))}
    manifest={'format':1,'candidate':'Wear7-V6','device':'dace','platform':'monaco','ab':False,
              'super_expanded_bytes':SUPER_SIZE,'super_expanded_sha256':raw_sha256,'partitions':SIZES,'images':image_hashes,
              'kernel':'5.15.220-Xinran_StarBai-Test+','input_run':35094447396,
              'source_commit':os.environ.get('GITHUB_SHA','unknown'),
              'offline_gates':json.loads((a.report/'final/GATES.json').read_text()),
              'flash_authorized':False,'recovery_integration':'UNTESTED','hardware_runtime':'UNTESTED',
              'userdata_migration':'UNTESTED','avb':'unlocked_first_bringup_flags_3'}
    (output/'CANDIDATE.json').write_text(json.dumps(manifest,indent=2)+'\n')
    rows=[f'{sha(f)}  {f.name}' for f in sorted(output.iterdir()) if f.is_file()]
    (output/'SHA256SUMS.txt').write_text('\n'.join(rows)+'\n')
    (a.report/'FINAL_CANDIDATE.json').write_text(json.dumps(manifest,indent=2)+'\n')
    print('FINAL_IMAGE_OFFLINE_GATES=PASS\nFLASH_AUTHORIZED=NO',flush=True)


if __name__=='__main__': main()
