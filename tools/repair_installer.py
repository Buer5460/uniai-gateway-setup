"""Patch only the verified installer entry; preserve every gateway payload byte.
Build uses CPython 3.12. Input code is parsed, never executed during the build.
"""
from __future__ import annotations
import argparse, hashlib, json, marshal, pathlib, struct, sys, zlib
OLD_SHA='b6dbaa1d5337cb1da065cbaa9c4747cc7959314013d770f99ea782b90c753c7a'
MAGIC=b'MEI\x0c\x0b\x0a\x0b\x0e'
def entries(data):
    cookie=data.rfind(MAGIC)
    if cookie<0: raise ValueError('Not a PyInstaller archive')
    _,size,toff,tlen,version,library=struct.unpack_from('!8sIIII64s',data,cookie)
    start=cookie+88-size
    if version!=312: raise ValueError('Expected bundled Python 3.12')
    rows=[];pos=start+toff
    while pos<start+toff+tlen:
        length,off,clen,ulen,compressed,kind=struct.unpack_from('!IIIIBc',data,pos)
        name=data[pos+18:pos+length].rstrip(b'\0').decode('utf-8');pos+=length
        rows.append((name,kind,compressed,ulen,data[start+off:start+off+clen]))
    if pos!=start+toff+tlen: raise ValueError('Invalid archive index')
    return start,library,rows

def repair(source,output):
    if sys.version_info[:2]!=(3,12): raise RuntimeError('Build requires CPython 3.12, not the user machine')
    data=source.read_bytes()
    if hashlib.sha256(data).hexdigest()!=OLD_SHA: raise ValueError('Input hash mismatch; refusing unknown executable')
    start,lib,rows=entries(data)
    old=next(r for r in rows if r[0]=='product_install' and r[1]==b's')
    module=marshal.loads(zlib.decompress(old[4]) if old[2] else old[4])
    text=pathlib.Path(__file__).with_name('installer_entry.py').read_text(encoding='utf-8')
    replacement_main=next(c for c in compile(text,'product_install_repaired.py','exec').co_consts if hasattr(c,'co_name') and c.co_name=='main')
    found=0;constants=[]
    for value in module.co_consts:
        if hasattr(value,'co_name') and value.co_name=='main': value=replacement_main;found+=1
        constants.append(value)
    if found!=1: raise ValueError('Expected one main function')
    replacement=marshal.dumps(module.replace(co_consts=tuple(constants)))
    body=bytearray();table=bytearray();changed=[]
    for name,kind,compressed,ulen,raw in rows:
        if name=='product_install' and kind==b's':
            ulen=len(replacement);raw=zlib.compress(replacement,9);compressed=1;changed.append(name)
        off=len(body);body.extend(raw)
        n=name.encode()+b'\0';length=18+len(n);padding=(-length)%16;length+=padding
        table.extend(struct.pack('!IIIIBc',length,off,len(raw),ulen,compressed,kind)+n+b'\0'*padding)
    toff=len(body);body.extend(table)
    body.extend(struct.pack('!8sIIII64s',MAGIC,len(body)+88,toff,len(table),312,lib))
    result=data[:start]+body
    output.parent.mkdir(parents=True,exist_ok=True);output.write_bytes(result)
    _,_,newrows=entries(result)
    unchanged=sum(a==b for a,b in zip(rows,newrows))
    if unchanged!=len(rows)-1: raise AssertionError('Unexpected change outside entry script')
    metadata={'original_sha256':OLD_SHA,'repaired_sha256':hashlib.sha256(result).hexdigest(),'bytes':len(result),'changed_entries':changed,'unchanged_archive_entries':unchanged,'core_payload_unchanged':True,'signature':'unsigned; do not bypass Windows security policy','build_python':sys.version}
    output.with_suffix('.json').write_text(json.dumps(metadata,indent=2),encoding='utf-8')
    print(json.dumps(metadata,indent=2))
if __name__=='__main__':
    ap=argparse.ArgumentParser();ap.add_argument('input',type=pathlib.Path);ap.add_argument('output',type=pathlib.Path)
    a=ap.parse_args();repair(a.input,a.output)
