import hashlib
import importlib.util
from pathlib import Path
import struct
import tempfile
import unittest

spec=importlib.util.spec_from_file_location('prepare',Path(__file__).with_name('prepare-super.py'))
m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)


class ExpansionTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(); self.path=Path(self.temp.name)
        self.raw=b'A'*4096+b'\x12\x34\x56\x78'*1024+b'\0'*4096
        sparse=struct.pack('<I4H4I',0xed26ff3a,1,0,28,12,4096,3,3,0)
        sparse+=struct.pack('<2H2I',0xcac1,0,1,4108)+b'A'*4096
        sparse+=struct.pack('<2H2I',0xcac2,0,1,16)+b'\x12\x34\x56\x78'
        sparse+=struct.pack('<2H2I',0xcac3,0,1,12)
        self.source=self.path/'super.img'; self.source.write_bytes(sparse)
        self.dest=self.path/'raw.img'; self.sha=hashlib.sha256(self.raw).hexdigest()

    def tearDown(self): self.temp.cleanup()

    def test_raw_fill_and_dontcare_expand_exactly(self):
        m.expand(self.source,self.dest,len(self.raw),self.sha)
        self.assertEqual(self.dest.read_bytes(),self.raw)

    def test_wrong_hash_removes_partial_result(self):
        with self.assertRaisesRegex(ValueError,'differs'): m.expand(self.source,self.dest,len(self.raw),'0'*64)
        self.assertFalse(self.dest.exists())

    def test_never_overwrites_existing_file(self):
        self.dest.write_bytes(b'keep me')
        with self.assertRaises(FileExistsError): m.expand(self.source,self.dest,len(self.raw),self.sha)
        self.assertEqual(self.dest.read_bytes(),b'keep me')


if __name__=='__main__': unittest.main()
