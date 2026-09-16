#!/usr/bin/env python3
"""Package the unchanged stock VNDK33 payload as a signed, non-updatable APEX.

Keys are unique to this build and are never published. The resulting signed APEX
is the reusable bridge input for subsequent builds; library updates need a new
system-image release, not an in-place APEX update.
"""
import argparse
import hashlib
import json
import os
import pathlib
import re
import shutil
import subprocess
import zipfile


def digest(p):
    with p.open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()


def run(argv, **kwargs):
    print('RUN', argv[0], ' '.join(map(str, argv[1:])), flush=True)
    subprocess.run(list(map(str, argv)), check=True, timeout=180, **kwargs)


def main():
    p=argparse.ArgumentParser()
    for key in ('source','system','tools','work','report'):
        p.add_argument('--'+key, type=pathlib.Path, required=True)
    a=p.parse_args(); a.work.mkdir(parents=True, exist_ok=True)
    source=a.source
    if not (source/'apex_manifest.pb').is_file():
        raise RuntimeError('exact flattened VNDK payload missing')
    data=(source/'apex_manifest.pb').read_bytes()
    # Read field 1 (name) from the preserved protobuf; Android 13 need not
    # provide the deprecated JSON manifest alongside it.
    offset=0; names=[]
    def varint():
        nonlocal offset
        value=0
        for shift in range(0,70,7):
            if offset>=len(data): raise ValueError('truncated manifest')
            b=data[offset]; offset+=1; value|=(b&127)<<shift
            if not b&128: return value
        raise ValueError('invalid protobuf varint')
    while offset<len(data):
        tag=varint(); field=tag>>3; wire=tag&7
        if wire==0: varint()
        elif wire==2:
            size=varint(); value=data[offset:offset+size]; offset+=size
            if len(value)!=size: raise ValueError('truncated protobuf field')
            if field==1: names.append(value.decode())
        elif wire in (1,5): offset+=8 if wire==1 else 4
        else: raise ValueError('unsupported protobuf wire type')
        if offset>len(data): raise ValueError('manifest out of bounds')
    if len(names)!=1: raise ValueError('ambiguous manifest name')
    manifest={'name':names[0],'protobuf_sha256':hashlib.sha256(data).hexdigest()}
    print('STOCK_VNDK_MANIFEST',json.dumps(manifest),flush=True)
    if manifest['name']!='com.android.vndk.v33':
        raise RuntimeError('wrong VNDK manifest: '+repr(manifest))
    payload=a.work/'payload'
    shutil.copytree(source, payload, symlinks=True)
    for n in ('apex_manifest.pb','apex_manifest.json'):
        (payload/n).unlink(missing_ok=True)
    payload_hashes={str(x.relative_to(payload)):digest(x) for x in sorted(payload.rglob('*')) if x.is_file() and not x.is_symlink()}
    (a.report/'VNDK33_PAYLOAD_SHA256.json').write_text(json.dumps(payload_hashes,indent=2)+'\n')
    keys=a.work/'keys'; keys.mkdir(mode=0o700)
    priv=keys/'com.android.vndk.v33.pem'; pub=keys/'com.android.vndk.v33.avbpubkey'
    # Nothing from keys/ is copied into a published artifact.
    run(['openssl','genrsa','-out',priv,'4096'])
    run([a.tools/'bin/avbtool','extract_public_key','--key',priv,'--output',pub])
    run(['openssl','req','-new','-x509','-newkey','rsa:2048','-nodes','-keyout',keys/'outer.pem','-out',keys/'outer.x509.pem','-days','3650','-subj','/CN=TicWatch Wear7 VNDK33 development bridge/'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    run(['openssl','pkcs8','-topk8','-inform','PEM','-outform','DER','-in',keys/'outer.pem','-out',keys/'outer.pk8','-nocrypt'])
    contexts=a.work/'file_contexts'
    # Preserve the actual stock SELinux labels, including library subtypes.
    context_rows=['/ u:object_r:system_file:s0', '/apex_manifest\\.pb u:object_r:system_file:s0', '/apex_manifest\\.json u:object_r:system_file:s0']
    for x in sorted(source.rglob('*')):
        if x.name in ('apex_manifest.pb','apex_manifest.json'): continue
        label=os.getxattr(x,'security.selinux',follow_symlinks=False).rstrip(b'\0').decode()
        context_rows.append(re.escape('/'+str(x.relative_to(source)))+' '+label)
    contexts.write_text('\n'.join(context_rows)+'\n')
    shutil.copyfile(contexts,a.report/'VNDK33_FILE_CONTEXTS.txt')
    fsconfig=a.work/'fs_config'
    rows=['/ 0 0 0755','/apex_manifest.pb 0 0 0644','/apex_manifest.json 0 0 0644']
    for x in sorted(payload.rglob('*')):
        st=x.lstat(); mode=st.st_mode&0o7777
        rows.append(f'/{x.relative_to(payload)} {st.st_uid} {st.st_gid} {mode:04o}')
    fsconfig.write_text('\n'.join(rows)+'\n')
    unsigned=a.work/'unsigned.apex'; signed=a.work/'com.android.vndk.v33.apex'
    run([a.tools/'bin/apexer','--force','--apexer_tool_path',a.tools/'bin','--manifest',source/'apex_manifest.pb','--file_contexts',contexts,'--canned_fs_config',fsconfig,'--key',priv,'--pubkey',pub,'--min_sdk_version','33','--target_sdk_version','37','--payload_type','image',payload,unsigned])
    run([a.tools/'bin/signapk',keys/'outer.x509.pem',keys/'outer.pk8',unsigned,signed])
    run([shutil.which('apksigner') or a.tools/'bin/apksigner','verify','--verbose',signed])
    with zipfile.ZipFile(signed) as z:
        for name in ('apex_payload.img','apex_pubkey','apex_manifest.pb','AndroidManifest.xml'):
            if name not in z.namelist(): raise RuntimeError('missing '+name)
        image=a.work/'apex_payload.img'; image.write_bytes(z.read('apex_payload.img'))
        if z.read('apex_pubkey')!=pub.read_bytes(): raise RuntimeError('public key mismatch')
    run([a.tools/'bin/avbtool','verify_image','--image',image,'--key',priv])
    dest=a.system/'apex/com.android.vndk.v33.apex'
    shutil.copyfile(signed,dest); dest.chmod(0o644)
    os.setxattr(dest,'security.selinux',os.getxattr(source,'security.selinux'))
    shutil.rmtree(a.system/'apex/com.android.vndk.current')
    shutil.copyfile(signed,a.report/'com.android.vndk.v33.apex')
    result={'name':manifest['name'],'source_payload_files':len(payload_hashes),'signed_apex_sha256':digest(signed),'signing':'unique_build_keys_not_published','update_strategy':'reuse_signed_apex_or_replace_in_system_release','private_keys_published':False}
    (a.report/'VNDK33_BRIDGE.json').write_text(json.dumps(result,indent=2)+'\n')
    shutil.rmtree(keys)
    print('VNDK33_PACKAGED_APEX=PASS',json.dumps(result),flush=True)


if __name__=='__main__':
    main()
