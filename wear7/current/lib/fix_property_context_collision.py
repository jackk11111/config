#!/usr/bin/env python3
import argparse, json
from pathlib import Path

def parse_file(part, path):
    rows=[]
    if not path.is_file():
        return rows
    for lineno,line in enumerate(path.read_text(errors='replace').splitlines(),1):
        raw=line
        s=line.strip()
        if not s or s.startswith('#'):
            continue
        toks=s.split()
        if len(toks)<2:
            continue
        mode='exact' if len(toks)>=3 and toks[2]=='exact' else 'prefix'
        tail=tuple(toks[1:])
        rows.append({
            'part':part,'path':str(path),'line':lineno,'name':toks[0],
            'context':toks[1],'mode':mode,'tail':tail,'raw':raw,
        })
    return rows

def main():
    ap=argparse.ArgumentParser()
    ap.add_argument('--system-root',type=Path,required=True)
    ap.add_argument('--system-ext-root',type=Path,required=True)
    ap.add_argument('--product-root',type=Path,required=True)
    ap.add_argument('--vendor-root',type=Path,required=True)
    ap.add_argument('--report',type=Path,required=True)
    args=ap.parse_args()
    args.report.mkdir(parents=True,exist_ok=True)

    files={
      'system': args.system_root/'etc/selinux/plat_property_contexts',
      'system_ext': args.system_ext_root/'etc/selinux/system_ext_property_contexts',
      'product': args.product_root/'etc/selinux/product_property_contexts',
      'vendor': args.vendor_root/'etc/selinux/vendor_property_contexts',
    }
    rows=[]
    for part,p in files.items():
        rows += parse_file(part,p)

    by={}
    for r in rows:
        if r['mode']=='exact':
            by.setdefault(r['name'],[]).append(r)
    dups={k:v for k,v in by.items() if len(v)>1}

    def serializable(obj):
        if isinstance(obj, tuple): return list(obj)
        raise TypeError
    (args.report/'PROPERTY_DUPLICATES_BEFORE.json').write_text(
        json.dumps(dups,indent=2,default=serializable)+'\n')

    if not dups:
        raise SystemExit('refusing V11: no exact property-context collision found')

    removals=[]
    for name,items in sorted(dups.items()):
        vendors=[x for x in items if x['part']=='vendor']
        donors=[x for x in items if x['part']!='vendor']
        if len(vendors)!=1 or not donors:
            raise SystemExit(f'refusing V11: duplicate {name!r} is not exactly vendor + donor')
        v=vendors[0]
        if any(x['tail']!=v['tail'] for x in donors):
            detail=' | '.join(f"{x['part']}:{x['line']}:{' '.join(x['tail'])}" for x in items)
            raise SystemExit(f'refusing V11: semantic mismatch for {name}: {detail}')
        if any(x['part']!='system_ext' for x in donors):
            detail=' | '.join(f"{x['part']}:{x['line']}" for x in donors)
            raise SystemExit(f'refusing V11: collision {name} is outside staged system_ext: {detail}')
        removals.extend(donors)

    # Current root-cause evidence requires this exact property to be among the fixed collisions.
    if 'ro.charger_mode_autoboot' not in dups:
        raise SystemExit('refusing V11: expected ro.charger_mode_autoboot collision absent')

    # Remove exact duplicate donor rows from the writable staged system_ext file only.
    target=files['system_ext']
    lines=target.read_text(errors='replace').splitlines()
    remove_lines={x['line'] for x in removals}
    kept=[line for i,line in enumerate(lines,1) if i not in remove_lines]
    target.write_text('\n'.join(kept)+'\n')

    after=[]
    for part,p in files.items():
        after += parse_file(part,p)
    by2={}
    for r in after:
        if r['mode']=='exact':
            by2.setdefault(r['name'],[]).append(r)
    dups2={k:v for k,v in by2.items() if len(v)>1}
    (args.report/'PROPERTY_DUPLICATES_AFTER.json').write_text(
        json.dumps(dups2,indent=2,default=serializable)+'\n')
    if dups2:
        raise SystemExit('refusing V11: exact duplicate property contexts remain after patch')

    report={
      'status':'PASS',
      'policy':'preserve_stock_dace_vendor_mapping_remove_identical_donor_system_ext_duplicate',
      'removed':[{
        'name':x['name'],'part':x['part'],'line':x['line'],
        'context':x['context'],'tail':list(x['tail'])
      } for x in removals],
      'preserved_vendor':[{
        'name':name,
        'context':[x for x in items if x['part']=='vendor'][0]['context'],
        'tail':list([x for x in items if x['part']=='vendor'][0]['tail'])
      } for name,items in sorted(dups.items())],
    }
    (args.report/'PROPERTY_CONTEXT_FIX.json').write_text(json.dumps(report,indent=2)+'\n')
    print('V11_PROPERTY_CONTEXT_FIX=PASS')
    for x in removals:
        print('REMOVED',x['name'],x['part'],x['line'],' '.join(x['tail']))

if __name__=='__main__':
    main()
