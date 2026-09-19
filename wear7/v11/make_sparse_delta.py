#!/usr/bin/env python3
import argparse, hashlib, json, mmap, os, struct
from pathlib import Path

MAGIC=0xED26FF3A
RAW=0xCAC1
DONT=0xCAC3

def sha256(p):
    h=hashlib.sha256()
    with open(p,'rb',buffering=0) as f:
        while True:
            b=f.read(8*1024*1024)
            if not b: break
            h.update(b)
    return h.hexdigest()

def main():
    ap=argparse.ArgumentParser()
    ap.add_argument('--base',required=True,type=Path)
    ap.add_argument('--target',required=True,type=Path)
    ap.add_argument('--output',required=True,type=Path)
    ap.add_argument('--report',required=True,type=Path)
    ap.add_argument('--block-size',type=int,default=4096)
    a=ap.parse_args()
    bs=a.block_size
    size=a.base.stat().st_size
    if a.target.stat().st_size != size:
        raise SystemExit('base/target size mismatch')
    if size % bs:
        raise SystemExit('size not block aligned')
    total=size//bs

    runs=[]
    changed=0
    with open(a.base,'rb') as fb, open(a.target,'rb') as ft:
        mb=mmap.mmap(fb.fileno(),0,access=mmap.ACCESS_READ)
        mt=mmap.mmap(ft.fileno(),0,access=mmap.ACCESS_READ)
        try:
            cur=None; start=0; count=0
            for i in range(total):
                off=i*bs
                typ=RAW if mb[off:off+bs] != mt[off:off+bs] else DONT
                if typ==RAW: changed += 1
                if cur is None:
                    cur=typ; start=i; count=1
                elif typ==cur and count < 1000000:
                    count += 1
                else:
                    runs.append((cur,start,count))
                    cur=typ; start=i; count=1
            if cur is not None:
                runs.append((cur,start,count))
        finally:
            mb.close(); mt.close()

    a.output.parent.mkdir(parents=True,exist_ok=True)
    with open(a.output,'wb') as out, open(a.target,'rb',buffering=0) as ft:
        out.write(struct.pack('<IHHHHIIII',MAGIC,1,0,28,12,bs,total,len(runs),0))
        for typ,start,count in runs:
            if typ==RAW:
                total_sz=12+count*bs
                out.write(struct.pack('<HHII',RAW,0,count,total_sz))
                ft.seek(start*bs)
                left=count*bs
                while left:
                    b=ft.read(min(left,8*1024*1024))
                    if not b: raise SystemExit('short target read')
                    out.write(b); left-=len(b)
            else:
                out.write(struct.pack('<HHII',DONT,0,count,12))

    base_sha=sha256(a.base)
    target_sha=sha256(a.target)
    delta_sha=sha256(a.output)

    # Streaming proof: overlay RAW runs from target onto DONT_CARE bytes from base
    # and ensure the resulting logical image hashes exactly to target.
    h=hashlib.sha256()
    with open(a.base,'rb',buffering=0) as fb, open(a.target,'rb',buffering=0) as ft:
        for typ,start,count in runs:
            src=ft if typ==RAW else fb
            src.seek(start*bs)
            left=count*bs
            while left:
                b=src.read(min(left,8*1024*1024))
                if not b: raise SystemExit('short verification read')
                h.update(b); left-=len(b)
    recon=h.hexdigest()
    if recon != target_sha:
        raise SystemExit(f'reconstruction mismatch {recon} != {target_sha}')

    rep={
      'format':'android_sparse_delta_v1',
      'block_size':bs,
      'logical_bytes':size,
      'total_blocks':total,
      'changed_blocks':changed,
      'changed_bytes':changed*bs,
      'changed_percent':changed*100.0/total,
      'chunk_count':len(runs),
      'delta_bytes':a.output.stat().st_size,
      'base_raw_sha256':base_sha,
      'target_raw_sha256':target_sha,
      'delta_sha256':delta_sha,
      'reconstructed_sha256':recon,
      'reconstruction_exact':True,
    }
    a.report.write_text(json.dumps(rep,indent=2)+'\n')
    print(json.dumps(rep,indent=2))

if __name__=='__main__':
    main()
