"""Repair the owned v0.8.0 installer entry; do not alter the gateway payload.
Run using CPython 3.12. Input is pinned by SHA-256. No credentials are embedded.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import marshal
import struct
import sys
import types
import zlib
from pathlib import Path

EXPECTED = 'b6dbaa1d5337cb1da065cbaa9c4747cc7959314013d770f99ea782b90c753c7a'
MAGIC = b'MEI\014\013\012\013\016'
TEMPLATE = '''
def main(argv=None):
    import os, sys, types, traceback
    from pathlib import Path
    args = sys.argv[1:] if argv is None else list(argv)
    legacy = types.FunctionType('__ORIGINAL_CODE__', globals(), 'legacy_main', (None,))
    log = None
    old_out, old_err = sys.stdout, sys.stderr
    try:
        logdir = Path(os.environ.get('LOCALAPPDATA') or os.environ.get('TEMP') or '.') / 'UniAIInstaller' / 'Logs'
        logdir.mkdir(parents=True, exist_ok=True)
        log = (logdir / 'installer.log').open('a', encoding='utf-8')
        log.write('Installer entry hotfix 1: beginning invocation\\n')
        log.flush()
        if sys.stdout is None: sys.stdout = log
        if sys.stderr is None: sys.stderr = log
        result = legacy(args)
        if result is None:
            result = Installer().run()
        return int(result or 0)
    except Exception:
        if log:
            traceback.print_exc(file=log)
            log.flush()
        if '--silent' not in args:
            try:
                import ctypes
                ctypes.windll.user32.MessageBoxW(None,
                    'UniAI installation failed. See the installer log in LOCALAPPDATA/UniAIInstaller/Logs. No successful installation is claimed.',
                    'UniAI installation error', 16)
            except Exception:
                pass
        return 1
    finally:
        sys.stdout, sys.stderr = old_out, old_err
        if log: log.close()
'''

def read_archive(blob):
    cookie = blob.rfind(MAGIC)
    if cookie < 0: raise ValueError('Missing archive cookie')
    _, size, tocpos, toclen, pyver, lib = struct.unpack('!8sIIII64s', blob[cookie:cookie+88])
    if pyver != 312: raise ValueError('Unexpected bundled Python version')
    start = cookie + 88 - size
    entries, pos = [], start + tocpos
    while pos < start + tocpos + toclen:
        length, offset, packed, unpacked, compressed, kind = struct.unpack('!IIIIBc', blob[pos:pos+18])
        if length < 18: raise ValueError('Malformed table entry')
        name = blob[pos+18:pos+length].split(b'\0')[0].decode('utf-8')
        entries.append(dict(name=name, raw=blob[start+offset:start+offset+packed], unpacked=unpacked, compressed=compressed, kind=kind))
        pos += length
    return blob[:start], entries, pyver, lib, blob[cookie+88:]

def unpack(e):
    return zlib.decompress(e['raw']) if e['compressed'] else e['raw']

def write_archive(prefix, entries, pyver, lib, trailer):
    payload, toc = bytearray(), bytearray()
    for e in entries:
        name = e['name'].encode('utf-8') + b'\0'
        entrylen = (18 + len(name) + 15) // 16 * 16
        toc.extend(struct.pack('!IIIIBc', entrylen, len(payload), len(e['raw']), e['unpacked'], e['compressed'], e['kind']))
        toc.extend(name + b'\0' * (entrylen - 18 - len(name)))
        payload.extend(e['raw'])
    cookie = struct.pack('!8sIIII64s', MAGIC, len(payload)+len(toc)+88, len(payload), len(toc), pyver, lib)
    return prefix + payload + toc + cookie + trailer

def repair(source: Path, destination: Path):
    if sys.version_info[:2] != (3, 12):
        raise RuntimeError('Build repair with CPython 3.12; never reinterpret bytecode with another version')
    original = source.read_bytes()
    digest = hashlib.sha256(original).hexdigest()
    if digest != EXPECTED: raise ValueError('Input does not match the reviewed v0.8.0 binary')
    # Refuse to rewrite a signed executable: an authorized publisher must re-sign a normal rebuild.
    pe = struct.unpack_from('<I', original, 0x3c)[0]
    opt = pe + 24
    cert_offset, cert_size = struct.unpack_from('<II', original, opt + 112 + 8*4)
    if cert_offset or cert_size: raise ValueError('Signed input requires a source rebuild and authorized signing')
    prefix, entries, version, lib, trailer = read_archive(original)
    entry = next(e for e in entries if e['name']=='product_install' and e['kind']==b's')
    oldmodule = marshal.loads(unpack(entry))
    oldmain = next(c for c in oldmodule.co_consts if isinstance(c, types.CodeType) and c.co_name=='main')
    if 'Installer' in oldmain.co_names: raise ValueError('Reviewed missing-entry defect no longer matches')
    template = next(c for c in compile(TEMPLATE, 'uniai_installer_entry_hotfix.py', 'exec').co_consts if isinstance(c, types.CodeType))
    newmain = template.replace(co_consts=tuple(oldmain if c=='__ORIGINAL_CODE__' else c for c in template.co_consts))
    newmodule = oldmodule.replace(co_consts=tuple(newmain if c is oldmain else c for c in oldmodule.co_consts))
    fixed = marshal.dumps(newmodule)
    before_payload = hashlib.sha256(unpack(next(e for e in entries if e['name']=='payload.zip'))).hexdigest()
    entry.update(raw=zlib.compress(fixed, 9), unpacked=len(fixed), compressed=1)
    output = write_archive(prefix, entries, version, lib, trailer)
    _, reread, _, _, _ = read_archive(output)
    after_payload = hashlib.sha256(unpack(next(e for e in reread if e['name']=='payload.zip'))).hexdigest()
    if before_payload != after_payload: raise AssertionError('Gateway payload changed')
    # Execute only the two main functions with stubbed, harmless GUI/filesystem actions.
    class DummyWizard:
        def run(self): return 23
    env = {'argparse':argparse,'sys':sys,'Path':Path,'payload_zip':lambda: Path('stub'), 'Installer':DummyWizard}
    before = types.FunctionType(oldmain, env, 'main', (None,))([])
    after = types.FunctionType(newmain, env, 'main', (None,))([])
    if before is not None or after != 23: raise AssertionError((before, after))
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_bytes(output)
    report = {'input_sha256':digest,'output_sha256':hashlib.sha256(output).hexdigest(),
        'output_bytes':len(output),'bundle_python':'3.12','changed_entries':['product_install'],
        'payload_sha256':before_payload,'gateway_payload_unchanged':True,
        'no_argument_before':before,'no_argument_after_spy_result':after,
        'evidence_level':'entry-function test with stub GUI; Windows end-to-end is separate',
        'signature':'unsigned input; repaired binary remains unsigned'}
    destination.with_suffix('.build.json').write_text(json.dumps(report,indent=2),encoding='utf-8')
    destination.with_suffix('.sha256').write_text(report['output_sha256']+'  '+destination.name+'\n',encoding='ascii')
    print(json.dumps(report,indent=2))

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('source',type=Path);p.add_argument('destination',type=Path)
    a=p.parse_args();repair(a.source,a.destination)
