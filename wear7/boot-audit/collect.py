#!/usr/bin/env python3
"""Collect new boot-analysis evidence from read-only, already-built V6 images.

Does not rebuild images or rerun VINTF/SELinux/idmap/filesystem validation.
An inventory is evidence for review, never a hardware or boot PASS.
"""
import argparse
import gzip
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import tarfile

from elftools.elf.elffile import ELFFile


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def elf_record(path, virtual):
    with path.open('rb') as stream:
        elf = ELFFile(stream)
        row = {'path': virtual, 'class': elf.elfclass,
               'machine': elf['e_machine'], 'type': elf['e_type'],
               'needed': [], 'exports': [], 'imports': [], 'weak_imports': []}
        for segment in elf.iter_segments():
            if segment['p_type'] == 'PT_INTERP':
                row['interpreter'] = segment.get_interp_name()
        dynamic = elf.get_section_by_name('.dynamic')
        if dynamic:
            for tag in dynamic.iter_tags():
                if tag.entry.d_tag == 'DT_NEEDED':
                    row['needed'].append(tag.needed)
                elif tag.entry.d_tag in ('DT_SONAME', 'DT_RPATH', 'DT_RUNPATH'):
                    key = tag.entry.d_tag[3:].lower()
                    row[key] = getattr(tag, key)
        symbols = elf.get_section_by_name('.dynsym')
        if symbols:
            for symbol in symbols.iter_symbols():
                if not symbol.name:
                    continue
                binding = symbol['st_info']['bind']
                if symbol['st_shndx'] == 'SHN_UNDEF':
                    key = 'weak_imports' if binding == 'STB_WEAK' else 'imports'
                    row[key].append(symbol.name)
                elif binding in ('STB_GLOBAL', 'STB_WEAK') and symbol['st_other']['visibility'] in ('STV_DEFAULT', 'STV_PROTECTED'):
                    row['exports'].append(symbol.name)
        for key in ('imports', 'exports', 'weak_imports'):
            row[key] = sorted(set(row[key]))
        return row


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--mounts', type=Path, required=True)
    parser.add_argument('--apex', type=Path, required=True)
    parser.add_argument('--tools', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    out = args.output
    out.mkdir(parents=True, exist_ok=True)
    roots = {name: args.mounts / name for name in
             ('system', 'system_ext', 'product', 'vendor', 'vendor_dlkm', 'system_dlkm')}
    roots['system'] /= 'system'
    roots['apex'] = args.apex
    for root in roots.values():
        if not root.is_dir():
            raise RuntimeError('Missing image root: ' + str(root))
    errors = []
    counts = {'entries': 0, 'elf': 0, 'apk': 0, 'xml': 0}
    apk_index = []
    manifests = out / 'apk-manifests'
    manifests.mkdir(exist_ok=True)
    with gzip.open(out / 'filesystem.jsonl.gz', 'wt') as fsout, \
         gzip.open(out / 'elf.jsonl.gz', 'wt') as elfout, \
         tarfile.open(out / 'configuration.tar.gz', 'w:gz') as config:
        for partition, root in roots.items():
            for current, dirs, files in os.walk(root, followlinks=False):
                dirs.sort()
                for name in sorted(dirs + files):
                    path = Path(current) / name
                    relative = path.relative_to(root)
                    virtual = '/' + partition + '/' + relative.as_posix()
                    info = path.lstat()
                    row = {'path': virtual, 'mode': oct(info.st_mode), 'uid': info.st_uid,
                           'gid': info.st_gid, 'bytes': info.st_size}
                    if path.is_symlink():
                        row['target'] = os.readlink(path)
                    try:
                        row['selinux'] = os.getxattr(path, 'security.selinux', follow_symlinks=False).rstrip(b'\0').decode()
                    except OSError:
                        pass
                    fsout.write(json.dumps(row) + '\n')
                    counts['entries'] += 1
                    if not stat.S_ISREG(info.st_mode):
                        continue
                    with path.open('rb') as stream:
                        magic = stream.read(4)
                    if magic == b'\x7fELF' and path.suffix != '.ko':
                        try:
                            elfout.write(json.dumps(elf_record(path, virtual)) + '\n')
                            counts['elf'] += 1
                        except Exception as exc:
                            errors.append({'path': virtual, 'operation': 'ELF', 'error': str(exc)})
                    is_config = ('etc' in relative.parts or path.name == 'build.prop'
                                 or magic.startswith(b'#!') or path.suffix in ('.rc', '.prop'))
                    if is_config:
                        config.add(path, arcname=virtual.lstrip('/'), recursive=False)
                    if path.suffix == '.xml':
                        counts['xml'] += 1
                    if path.suffix == '.apk':
                        key = hashlib.sha256(virtual.encode()).hexdigest()[:20]
                        item = {'path': virtual, 'sha256': digest(path), 'key': key}
                        for mode, command in (
                            ('badging', ['dump', 'badging', str(path)]),
                            ('manifest', ['dump', 'xmltree', '--file', 'AndroidManifest.xml', str(path)]),
                        ):
                            result = subprocess.run([str(args.tools / 'bin/aapt2'), *command],
                                                    capture_output=True, text=True, timeout=60)
                            (manifests / (key + '.' + mode + '.txt')).write_text(result.stdout + result.stderr)
                            item[mode + '_exit'] = result.returncode
                            if result.returncode:
                                errors.append({'path': virtual, 'operation': mode, 'error': result.stderr})
                        apk_index.append(item)
                        counts['apk'] += 1
    (out / 'apk-index.json').write_text(json.dumps(apk_index, indent=2) + '\n')
    (out / 'COLLECTION.json').write_text(json.dumps({
        'source_run': 35146642220, 'source_commit': 'd160e4f6b32d29cbecc802f3d9443fe0d2b7de44',
        'counts': counts, 'errors': errors, 'mode': 'READ_ONLY_EVIDENCE_COLLECTION',
        'builds_executed': False, 'previous_gates_rerun': False, 'boot_verdict': 'NOT_ESTABLISHED'
    }, indent=2) + '\n')
    print(json.dumps({'counts': counts, 'collection_errors': len(errors)}), flush=True)
    if errors:
        raise SystemExit('Evidence collection incomplete; inspect COLLECTION.json')


if __name__ == '__main__':
    main()
