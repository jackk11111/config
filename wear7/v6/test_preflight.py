"""Boundary tests: corrupt images and wrong-device states must be rejected."""
import importlib.util
import json
from pathlib import Path
import struct
import tempfile
import unittest
from unittest.mock import patch

spec=importlib.util.spec_from_file_location('preflight',Path(__file__).with_name('recovery-preflight.py'))
m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)


def sparse(blocks=1048576):
    return struct.pack('<I4H4I',0xed26ff3a,1,0,28,12,4096,blocks,1,0)+struct.pack('<2H2I',0xcac3,0,blocks,12)


class PackageTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(); self.p=Path(self.temp.name)
        for name in m.IMAGES: (self.p/name).write_bytes(sparse() if name=='super.img' else b'fixture')
        self.manifest={'format':1,'candidate':'test','device':'dace','platform':'monaco','ab':False,
                       'super_expanded_bytes':m.SUPER_SIZE,
                       'offline_gates':{n:{'status':'PASS'} for n in m.GATES},
                       'images':{n:{'sha256':m.sha(self.p/n),'bytes':(self.p/n).stat().st_size} for n in m.IMAGES}}
        self.write_manifest()

    def tearDown(self): self.temp.cleanup()

    def write_manifest(self):
        (self.p/'CANDIDATE.json').write_text(json.dumps(self.manifest))
        (self.p/'SHA256SUMS.txt').write_text(''.join(f'{m.sha(self.p/n)}  {n}\n' for n in sorted(m.IMAGES|{'CANDIDATE.json'})))

    def test_valid_fixture_package(self):
        self.assertEqual(m.verify_package(self.p)['device'],'dace')

    def test_corrupted_image(self):
        (self.p/'boot.img').write_bytes(b'corrupted')
        with self.assertRaisesRegex(ValueError,'corrupt'): m.verify_package(self.p)

    def test_failed_gate(self):
        self.manifest['offline_gates']['SELINUX_POLICY']['status']='FAIL'; self.write_manifest()
        with self.assertRaisesRegex(ValueError,'offline gate'): m.verify_package(self.p)

    def test_wrong_slot_model(self):
        self.manifest['ab']=True; self.write_manifest()
        with self.assertRaisesRegex(ValueError,'single-slot'): m.verify_package(self.p)

    def test_duplicate_checksums(self):
        p=self.p/'SHA256SUMS.txt'; p.write_text(p.read_text()*2)
        with self.assertRaisesRegex(ValueError,'duplicate'): m.verify_package(self.p)

    def test_path_traversal_entry(self):
        p=self.p/'SHA256SUMS.txt'; p.write_text(p.read_text().replace('boot.img','../boot.img'))
        with self.assertRaisesRegex(ValueError,'invalid'): m.verify_package(self.p)

    def test_sparse_size_and_trailing_garbage(self):
        p=self.p/'super.img'; self.assertEqual(m.sparse_size(p),m.SUPER_SIZE)
        p.write_bytes(sparse()+b'garbage')
        with self.assertRaisesRegex(ValueError,'length mismatch'): m.sparse_size(p)

    def test_truncated_raw_sparse_chunk(self):
        p=self.p/'super.img'
        p.write_bytes(struct.pack('<I4H4I',0xed26ff3a,1,0,28,12,4096,1,1,0)+struct.pack('<2H2I',0xcac1,0,1,4108))
        with self.assertRaisesRegex(ValueError,'out of bounds'): m.sparse_size(p)

    def test_aliased_partition_probe_is_blocked(self):
        text='uid=0\nro.product.device=dace\nro.hardware=monaco\nro.bootmode=recovery\nro.adb.secure=1\nro.boot.flash.locked=0\n'
        for n in ('boot','init_boot','vendor_boot','dtbo','vbmeta','vbmeta_system','super','recovery'):
            text+=f'partition.{n}.path=/dev/block/same\npartition.{n}.bytes={m.SUPER_SIZE}\n'
        text+='MOUNTS_BEGIN\nrootfs / rootfs ro 0 0\nMOUNTS_END\n'
        result=type('Result',(),{'returncode':0,'stdout':text,'stderr':''})()
        with patch.object(m.subprocess,'run',return_value=result) as adb:
            report=m.probe_recovery('127.0.0.1:5555',self.manifest)
        self.assertEqual(report['read_only_probe'],'BLOCKED')
        self.assertIn('partition aliases overlap',report['errors'])
        self.assertFalse(report['flash_authorized'])
        self.assertEqual(adb.call_args.args[0][-3:],['shell','sh','-s'])


if __name__=='__main__': unittest.main()
