#!/usr/bin/env python3
from pathlib import Path
import sys

if len(sys.argv) != 2:
    raise SystemExit("usage: ticwatch-uplift-v3-ipv4-android.py /tmp/uplift.sh")

p = Path(sys.argv[1])
s = p.read_text()

old_defs = r'''old_net = '\tnet = dev_net_rcu(dst->dev);\n'
new_net = '\tnet = dev_net_rcu(dst_dev(dst));\n'
'''
new_defs = r'''old_net_android = '\tstruct net *net = dev_net(dst->dev);\n'
new_net_android = '\tstruct net *net = dev_net(dst_dev(dst));\n'
old_net_rcu = '\tnet = dev_net_rcu(dst->dev);\n'
new_net_rcu = '\tnet = dev_net_rcu(dst_dev(dst));\n'
'''
if s.count(old_defs) != 1:
    raise SystemExit(f"FAIL_IPV4_ANDROID_DEFS=count={s.count(old_defs)}")
s = s.replace(old_defs, new_defs, 1)

old_logic = r'''net_total = s.count(old_net) + s.count(new_net)
if dev_total != 2:
    raise SystemExit(f'FAIL_IPV4_DSTDEV_DEV_SITES={dev_total}')
if net_total != 1:
    raise SystemExit(f'FAIL_IPV4_DSTDEV_NET_SITES={net_total}')

s = s.replace(old_dev, new_dev)
s = s.replace(old_net, new_net)
if s.count(new_dev) != 2 or s.count(new_net) != 1:
    raise SystemExit('FAIL_IPV4_DSTDEV_POST')
'''
new_logic = r'''net_total = sum(s.count(x) for x in (
    old_net_android, new_net_android, old_net_rcu, new_net_rcu
))
if dev_total != 2:
    raise SystemExit(f'FAIL_IPV4_DSTDEV_DEV_SITES={dev_total}')
if net_total != 1:
    raise SystemExit(f'FAIL_IPV4_DSTDEV_NET_SITES={net_total}')

s = s.replace(old_dev, new_dev)
# Preserve the Android/TicWatch locking model. The device-access semantic delta
# is the same: dst->dev becomes dst_dev(dst). Stable 5.15 has the RCU form here,
# while this Android tree still carries the older declaration form.
s = s.replace(old_net_android, new_net_android)
s = s.replace(old_net_rcu, new_net_rcu)
final_net_total = s.count(new_net_android) + s.count(new_net_rcu)
if s.count(new_dev) != 2 or final_net_total != 1:
    raise SystemExit('FAIL_IPV4_DSTDEV_POST')
'''
if s.count(old_logic) != 1:
    raise SystemExit(f"FAIL_IPV4_ANDROID_LOGIC=count={s.count(old_logic)}")
s = s.replace(old_logic, new_logic, 1)

old_verify = '''                grep -Fq 'net = dev_net_rcu(dst_dev(dst));' "$f" || exit 54'''
new_verify = '''                { grep -Fq 'struct net *net = dev_net(dst_dev(dst));' "$f" || grep -Fq 'net = dev_net_rcu(dst_dev(dst));' "$f"; } || exit 54'''
if s.count(old_verify) != 1:
    raise SystemExit(f"FAIL_IPV4_ANDROID_VERIFY=count={s.count(old_verify)}")
s = s.replace(old_verify, new_verify, 1)

p.write_text(s)
print("V3_IPV4_ANDROID_DSTDEV_COMPAT_APPLIED=1")
