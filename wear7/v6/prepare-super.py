#!/usr/bin/env python3
"""Convert a verified candidate super to raw on the phone; never access the watch."""
import argparse
import hashlib
import importlib.util
from pathlib import Path
import shutil
import struct

spec=importlib.util.spec_from_file_location('preflight',Path(__file__).with_name('recovery-preflight.py'))
preflight=importlib.util.module_from_spec(spec); spec.loader.exec_module(preflight)


def expand(source,destination,expected_bytes,expected_sha256):
    if preflight.sparse_size(source)!=expected_bytes: raise ValueError('wrong sparse image size')
    created=False
    try:
        with source.open('rb') as src,destination.open('xb') as out:
            created=True
            _,_,_,fh,ch,block,blocks,chunks,_=struct.unpack('<I4H4I',src.read(28))
            for _ in range(chunks):
                kind,_,n,total=struct.unpack('<2H2I',src.read(ch)); remaining=n*block
                if kind==0xcac1:
                    while remaining:
                        data=src.read(min(2*1024*1024,remaining))
                        if not data: raise ValueError('truncated raw chunk')
                        out.write(data); remaining-=len(data)
                elif kind==0xcac2:
                    pattern=src.read(4)
                    if len(pattern)!=4: raise ValueError('truncated fill chunk')
                    data=pattern*(512*1024)
                    while remaining:
                        piece=data[:min(len(data),remaining)]; out.write(piece); remaining-=len(piece)
                elif kind==0xcac3: out.seek(remaining,1)
                elif kind==0xcac4:
                    if len(src.read(4))!=4: raise ValueError('truncated CRC chunk')
                else: raise ValueError('unexpected sparse chunk')
            out.truncate(expected_bytes)
        if destination.stat().st_size!=expected_bytes or preflight.sha(destination)!=expected_sha256:
            raise ValueError('expanded image differs from the raw super verified in CI')
    except BaseException:
        if created: destination.unlink(missing_ok=True)
        raise


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--package',type=Path,required=True)
    p.add_argument('--output',type=Path,required=True,help='new regular file, preferably in Download')
    a=p.parse_args()
    manifest=preflight.verify_package(a.package)
    expected=manifest.get('super_expanded_sha256','')
    if len(expected)!=64 or any(x not in '0123456789abcdef' for x in expected):
        raise SystemExit('candidate lacks a verified raw-super checksum')
    if a.output.exists() or a.output.is_symlink(): raise SystemExit('output already exists')
    if not a.output.parent.is_dir(): raise SystemExit('output parent must already exist')
    if shutil.disk_usage(a.output.parent).free<manifest['super_expanded_bytes']+512*1024*1024:
        raise SystemExit('at least 4.5 GiB of free space is required for raw super')
    expand(a.package/'super.img',a.output,manifest['super_expanded_bytes'],expected)
    print(f'RAW_SUPER_SHA256={expected}\nRAW_SUPER_BYTES={a.output.stat().st_size}\nOUTPUT={a.output}\nFLASH_AUTHORIZED=NO')


if __name__=='__main__': main()
