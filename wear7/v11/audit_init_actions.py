#!/usr/bin/env python3
import pathlib,re,sys,json

if len(sys.argv) != 6:
    raise SystemExit("usage: audit_init_actions.py SYSTEM SYSTEM_EXT PRODUCT VENDOR REPORT")

roots = {
    "system": pathlib.Path(sys.argv[1]),
    "system_ext": pathlib.Path(sys.argv[2]),
    "product": pathlib.Path(sys.argv[3]),
    "vendor": pathlib.Path(sys.argv[4]),
}
report = pathlib.Path(sys.argv[5])
report.mkdir(parents=True, exist_ok=True)

rcs = []
for part, root in roots.items():
    if not root.exists():
        continue
    for p in sorted(root.rglob("*.rc")):
        try:
            txt = p.read_text(errors="replace")
        except Exception:
            continue
        rcs.append((part, root, p, txt))

def blocks(txt):
    lines = txt.splitlines()
    out=[]
    i=0
    while i < len(lines):
        raw=lines[i]
        s=raw.strip()
        if s.startswith("on "):
            header=s
            start=i+1
            cmds=[]
            j=i+1
            while j < len(lines):
                t=lines[j]
                ts=t.strip()
                if ts and not t[:1].isspace():
                    break
                if ts and not ts.startswith("#"):
                    cmds.append(ts)
                j+=1
            out.append((header,start,cmds))
            i=j
        else:
            i+=1
    return out

init_blocks=[]
imports=[]
services={}
keywords=re.compile(r"(reboot|shutdown|sys\.powerctl|panic|watchdog|boringssl|keymaster|qsee|servicemanager|vndservicemanager|hwservicemanager|mount_all|exec |exec_start|class_start|start )", re.I)
interesting=[]

for part, root, p, txt in rcs:
    rel=str(p.relative_to(root))
    lines=txt.splitlines()
    for n,line in enumerate(lines,1):
        s=line.strip()
        if s.startswith("import "):
            imports.append({"partition":part,"file":rel,"line":n,"text":s})
        if keywords.search(s):
            interesting.append({"partition":part,"file":rel,"line":n,"text":s})
    for h,n,cmds in blocks(txt):
        if h=="on init":
            init_blocks.append({
                "partition":part,"file":rel,"line":n,"header":h,"commands":cmds
            })
    # basic service extraction
    i=0
    while i < len(lines):
        s=lines[i].strip()
        if s.startswith("service "):
            toks=s.split()
            name=toks[1] if len(toks)>1 else "?"
            cmd=" ".join(toks[2:])
            body=[]
            j=i+1
            while j < len(lines):
                t=lines[j]; ts=t.strip()
                if ts and not t[:1].isspace():
                    break
                if ts and not ts.startswith("#"):
                    body.append(ts)
                j+=1
            services.setdefault(name,[]).append({
                "partition":part,"file":rel,"line":i+1,"command":cmd,"body":body
            })
            i=j
        else:
            i+=1

# resolve services explicitly started by on init
started=[]
start_re=re.compile(r"^(?:start|exec_start)\s+(\S+)")
for b in init_blocks:
    for c in b["commands"]:
        m=start_re.match(c)
        if m:
            n=m.group(1)
            started.append({"name":n,"from":b,"definitions":services.get(n,[])})

# human report
o=[]
o.append("=== ON INIT BLOCKS ===")
for idx,b in enumerate(init_blocks):
    o.append(f"\n[{idx:03d}] {b['partition']}:{b['file']}:{b['line']}")
    for c in b["commands"]:
        o.append("    "+c)

o.append("\n\n=== IMPORT DIRECTIVES ===")
for x in imports:
    o.append(f"{x['partition']}:{x['file']}:{x['line']}: {x['text']}")

o.append("\n\n=== SERVICES STARTED DIRECTLY BY ON INIT ===")
for x in started:
    o.append(f"\nSERVICE {x['name']}")
    fr=x["from"]
    o.append(f"  from {fr['partition']}:{fr['file']}:{fr['line']}")
    if not x["definitions"]:
        o.append("  definition: NOT FOUND")
    for d in x["definitions"]:
        o.append(f"  def {d['partition']}:{d['file']}:{d['line']}: {d['command']}")
        for z in d["body"]:
            o.append("      "+z)

o.append("\n\n=== INTERESTING RC LINES ===")
for x in interesting:
    o.append(f"{x['partition']}:{x['file']}:{x['line']}: {x['text']}")

(report/"INIT_ACTION_AUDIT.txt").write_text("\n".join(o)+"\n")
(report/"INIT_ACTION_AUDIT.json").write_text(json.dumps({
    "on_init_blocks":init_blocks,
    "imports":imports,
    "services_started_by_on_init":started,
    "interesting_lines":interesting,
},indent=2)+"\n")

print(f"INIT_ACTION_AUDIT blocks={len(init_blocks)} imports={len(imports)} started_services={len(started)}")
for i,b in enumerate(init_blocks):
    print(f"[{i:03d}] {b['partition']}:{b['file']}:{b['line']} :: " + " ; ".join(b["commands"]))
