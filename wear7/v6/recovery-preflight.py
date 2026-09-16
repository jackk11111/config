#!/usr/bin/env python3
"""Read-only package/recovery preflight, usable from Termux in Download.

There is deliberately no flash, wipe, reboot, remount or adb-root operation.
The final recovery transport/rollback must be tested before adding an apply path.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import struct
import subprocess


IMAGES={'boot.img','init_boot.img','vendor_boot.img','dtbo.img','vbmeta.img','vbmeta_system.img','super.img'}
GATES=('APEX_INTEGRATION','OFFICIAL_VINTF','SELINUX_POLICY','FASTPAIR_IDMAP2')
SUPER_SIZE=4294967296


def sha(path):
    with path.open('rb') as f:
        return hashlib.file_digest(f,'sha256').hexdigest()


def sparse_size(path):
    """Validate sparse chunk boundaries without writing or allocating 4 GiB."""
    with path.open('rb') as f:
        header=f.read(28)
        if len(header)!=28: raise ValueError('truncated sparse header')
        magic,major,minor,fh,ch,block,blocks,chunks,checksum=struct.unpack('<I4H4I',header)
        if (magic,major,minor,fh,ch,block)!=(0xed26ff3a,1,0,28,12,4096):
            raise ValueError('unsupported sparse format')
        total=0; size=path.stat().st_size
        if chunks>size//12: raise ValueError('impossible sparse chunk count')
        for _ in range(chunks):
            row=f.read(ch)
            if len(row)!=ch: raise ValueError('truncated sparse chunk')
            kind,reserved,n,length=struct.unpack('<2H2I',row)
            payload={0xcac1:n*block,0xcac2:4,0xcac3:0,0xcac4:4}.get(kind)
            if payload is None or length!=ch+payload: raise ValueError('invalid sparse chunk size')
            if kind==0xcac4 and n!=0: raise ValueError('invalid CRC chunk')
            total+=n
            if total>blocks or f.tell()+payload>size: raise ValueError('sparse chunk out of bounds')
            f.seek(payload,1)
        if total!=blocks or f.tell()!=size: raise ValueError('sparse image length mismatch')
        return blocks*block


def verify_package(package):
    package=package.resolve()
    expected=IMAGES|{'CANDIDATE.json'}; rows={}
    sums=package/'SHA256SUMS.txt'
    if sums.is_symlink(): raise ValueError('symlink checksum list')
    for row in sums.read_text().splitlines():
        m=re.fullmatch(r'([0-9a-f]{64})  ([A-Za-z0-9_.-]+)',row)
        if not m or m[2] in rows: raise ValueError('invalid or duplicate checksum entry')
        rows[m[2]]=m[1]
    if set(rows)!=expected: raise ValueError('unexpected package file set')
    for name,want in rows.items():
        f=package/name
        if f.is_symlink() or not f.is_file() or sha(f)!=want:
            raise ValueError('missing, substituted or corrupt package file: '+name)
    manifest=json.loads((package/'CANDIDATE.json').read_text())
    if manifest.get('format')!=1 or manifest.get('device')!='dace' or manifest.get('platform')!='monaco' or manifest.get('ab') is not False:
        raise ValueError('candidate is not for single-slot dace/monaco')
    if set(manifest['images'])!=IMAGES: raise ValueError('unexpected image manifest')
    for name,meta in manifest['images'].items():
        if meta['sha256']!=rows[name] or meta['bytes']!=(package/name).stat().st_size:
            raise ValueError('manifest disagrees with actual file: '+name)
    for name in GATES:
        if manifest.get('offline_gates',{}).get(name,{}).get('status')!='PASS':
            raise ValueError('offline gate not passed: '+name)
    if manifest.get('super_expanded_bytes')!=SUPER_SIZE or sparse_size(package/'super.img')!=SUPER_SIZE:
        raise ValueError('wrong expanded super size')
    return manifest


# All commands below only read properties, partition sizes and mount state.
# Block-device names are a fixed allowlist; no package text becomes shell code.
PROBE=r'''
set -eu
echo "uid=$(id -u)"
for p in ro.product.device ro.product.vendor.device ro.hardware ro.boot.hardware ro.boot.product.vendor.sku ro.boot.slot_suffix ro.boot.slot ro.bootmode ro.boot.mode ro.adb.secure ro.boot.flash.locked ro.boot.vbmeta.device_state; do
    echo "$p=$(getprop "$p")"
done
for p in boot init_boot vendor_boot dtbo vbmeta vbmeta_system super recovery; do
    node="/dev/block/by-name/$p"
    test -b "$node" || { echo "missing_partition=$p"; exit 1; }
    echo "partition.$p.path=$(readlink -f "$node")"
    echo "partition.$p.bytes=$(blockdev --getsize64 "$node")"
done
echo 'MOUNTS_BEGIN'
cat /proc/mounts
echo 'MOUNTS_END'
'''


def probe_recovery(serial,manifest):
    proc=subprocess.run(['adb','-s',serial,'shell','sh','-s'],input=PROBE,text=True,
                        stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=45)
    if proc.returncode: raise RuntimeError('recovery read-only probe failed: '+proc.stderr+' '+proc.stdout)
    text=proc.stdout.replace('\r',''); props={}
    for line in text.split('MOUNTS_BEGIN')[0].splitlines():
        if '=' in line:
            key,value=line.split('=',1)
            if key in props: raise ValueError('duplicate recovery probe field')
            props[key]=value
    errors=[]
    if props.get('uid')!='0': errors.append('ADB is not already root')
    if 'dace' not in (props.get('ro.product.device'),props.get('ro.product.vendor.device')): errors.append('device dace not confirmed')
    if 'monaco' not in (props.get('ro.hardware'),props.get('ro.boot.hardware'),props.get('ro.boot.product.vendor.sku')): errors.append('platform monaco not confirmed')
    if props.get('ro.boot.slot_suffix') or props.get('ro.boot.slot'): errors.append('unexpected slot layout')
    if 'recovery' not in (props.get('ro.bootmode'),props.get('ro.boot.mode')): errors.append('recovery boot mode not confirmed')
    if props.get('ro.adb.secure')!='1': errors.append('authenticated ADB property not confirmed')
    if props.get('ro.boot.flash.locked')!='0' and props.get('ro.boot.vbmeta.device_state')!='unlocked': errors.append('unlocked bootloader not confirmed')
    nodes=[]
    for name in ('boot','init_boot','vendor_boot','dtbo','vbmeta','vbmeta_system','super','recovery'):
        node=props.get(f'partition.{name}.path','')
        if not re.fullmatch(r'/dev/block/[A-Za-z0-9_./-]+',node): errors.append('invalid partition path: '+name)
        nodes.append(node)
        size=int(props.get(f'partition.{name}.bytes','0'))
        if name=='super' and size!=SUPER_SIZE: errors.append('super partition size mismatch')
        if name+'.img' in manifest['images'] and name!='super' and size<manifest['images'][name+'.img']['bytes']: errors.append('partition too small: '+name)
    if len(set(nodes))!=len(nodes): errors.append('partition aliases overlap')
    if 'MOUNTS_BEGIN\n' not in text or '\nMOUNTS_END' not in text: raise ValueError('mount list missing')
    mounts=text.split('MOUNTS_BEGIN\n',1)[1].split('\nMOUNTS_END',1)[0]
    for line in mounts.splitlines():
        fields=line.split()
        if len(fields)>=4 and (fields[0] in nodes or fields[1] in ('/system','/system_root','/vendor','/product','/system_ext')):
            errors.append('target partition is mounted: '+fields[1])
    return {'read_only_probe':'PASS' if not errors else 'BLOCKED','errors':errors,'properties':props,
            'recovery_rollback':'UNTESTED','userdata_migration':'UNTESTED','flash_authorized':False}


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--package',type=Path,required=True)
    p.add_argument('--serial',help='explicit adb device or IP:port; omit for package-only verification')
    p.add_argument('--report',type=Path,required=True)
    a=p.parse_args()
    try:
        manifest=verify_package(a.package)
        result={'package':'PASS','candidate':manifest['candidate'],'flash_authorized':False}
        if a.serial: result['recovery']=probe_recovery(a.serial,manifest)
        else: result['recovery']={'read_only_probe':'UNTESTED'}
    except Exception as e:
        result={'package_or_probe':'FAIL','error':str(e),'flash_authorized':False}
    if a.report.exists(): raise SystemExit('Report already exists; choose a new report name.')
    with a.report.open('x') as f: json.dump(result,f,indent=2); f.write('\n')
    print(json.dumps(result,indent=2))
    print('PRECHECK ONLY: recovery rollback and userdata migration still require validation.')
    if result.get('package')!='PASS' or result.get('recovery',{}).get('read_only_probe')=='BLOCKED': raise SystemExit(1)


if __name__=='__main__': main()
