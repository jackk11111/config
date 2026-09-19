#!/usr/bin/env python3
import hashlib, json, mmap, pathlib, sys

base=pathlib.Path(sys.argv[1])
target=pathlib.Path(sys.argv[2])
out=pathlib.Path(sys.argv[3])
bs=4096

if base.stat().st_size != target.stat().st_size:
    raise SystemExit('size mismatch')

(out/'base_segments').mkdir(parents=True, exist_ok=True)
(out/'target_segments').mkdir(parents=True, exist_ok=True)

total=base.stat().st_size//bs
runs=[]
changed_blocks=0
changed_bytes=0

with base.open('rb') as fb, target.open('rb') as ft:
    mb=mmap.mmap(fb.fileno(),0,access=mmap.ACCESS_READ)
    mt=mmap.mmap(ft.fileno(),0,access=mmap.ACCESS_READ)
    try:
        start=None
        count=0
        for i in range(total):
            off=i*bs
            b=mb[off:off+bs]
            t=mt[off:off+bs]
            if b!=t:
                changed_blocks += 1
                changed_bytes += sum(x!=y for x,y in zip(b,t))
                if start is None:
                    start=i; count=1
                elif i==start+count:
                    count += 1
                else:
                    runs.append((start,count))
                    start=i; count=1
            elif start is not None:
                runs.append((start,count))
                start=None; count=0
        if start is not None:
            runs.append((start,count))

        banned={904002,181710,181711}
        touched=set()
        for s,c in runs:
            touched.update(range(s,s+c))
        bad=sorted(touched & banned)
        if bad:
            raise SystemExit(f'BANNED BSSL BLOCKS TOUCHED: {bad}')

        rows=[]
        for idx,(s,c) in enumerate(runs):
            off=s*bs
            n=c*bs
            bb=mb[off:off+n]
            tt=mt[off:off+n]
            bp=out/'base_segments'/f'seg{idx:03d}.bin'
            tp=out/'target_segments'/f'seg{idx:03d}.bin'
            bp.write_bytes(bb)
            tp.write_bytes(tt)
            rows.append({
                'index':idx,
                'start_block':s,
                'count':c,
                'base_sha256':hashlib.sha256(bb).hexdigest(),
                'target_sha256':hashlib.sha256(tt).hexdigest(),
            })

        base_sha=hashlib.sha256(mb).hexdigest()
        target_sha=hashlib.sha256(mt).hexdigest()
    finally:
        mb.close()
        mt.close()

report={
    'base_raw_sha256':base_sha,
    'target_raw_sha256':target_sha,
    'changed_blocks':changed_blocks,
    'changed_bytes_exact':changed_bytes,
    'run_count':len(runs),
    'banned_blocks_checked':[904002,181710,181711],
    'banned_blocks_touched':[],
    'segments':rows,
}
(out/'DELTA_REPORT.json').write_text(json.dumps(report,indent=2)+'\n')
(out/'SEGMENTS.tsv').write_text(
    '\n'.join(
        f"{r['index']:03d}\t{r['start_block']}\t{r['count']}\t{r['base_sha256']}\t{r['target_sha256']}"
        for r in rows
    )+'\n'
)
print(json.dumps(report,indent=2))
