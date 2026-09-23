"""Build fix.2; no original executable is run during this build.
Changes: verified installer entry and one management wrapper inside two
packaged executables. Original authorization handlers execute unchanged.
"""
from __future__ import annotations
import argparse, hashlib, io, json, marshal, pathlib, struct, sys, zipfile, zlib
from repair_installer import entries, repair, MAGIC

def rebuild_archive(data, replacements):
    start,lib,rows=entries(data)
    body=bytearray();table=bytearray()
    for name,kind,compressed,ulen,raw in rows:
        if name in replacements:
            value=replacements[name];ulen=len(value);raw=zlib.compress(value,9);compressed=1
        off=len(body);body.extend(raw)
        encoded=name.encode()+b'\0';length=18+len(encoded);padding=(-length)%16;length+=padding
        table.extend(struct.pack('!IIIIBc',length,off,len(raw),ulen,compressed,kind)+encoded+b'\0'*padding)
    toff=len(body);body.extend(table)
    body.extend(struct.pack('!8sIIII64s',MAGIC,len(body)+88,toff,len(table),312,lib))
    return data[:start]+body

def wrap_management(pyz):
    offset=struct.unpack('!I',pyz[8:12])[0]
    original_toc=marshal.loads(pyz[offset:])
    pairs=list(original_toc.items()) if isinstance(original_toc,dict) else list(original_toc)
    body=bytearray(pyz[:8]+b'\0'*4);toc=[];changed=0
    patch=pathlib.Path(__file__).with_name('console_session_sync.py').read_text(encoding='utf-8')
    for name,(kind,pos,size) in pairs:
        compressed=pyz[pos:pos+size]
        if name=='apps.gateway.mgmt':
            original=zlib.decompress(compressed)
            text="import marshal as _uniai_marshal\nexec(_uniai_marshal.loads(b'__ORIGINAL_VERIFIED_MODULE__'), globals())\n"+patch
            code=compile(text,'uniai_console_cache_fix.py','exec')
            code=code.replace(co_consts=tuple(original if v==b'__ORIGINAL_VERIFIED_MODULE__' else v for v in code.co_consts))
            compressed=zlib.compress(marshal.dumps(code),9);changed+=1
        toc.append((name,(kind,len(body),len(compressed))));body.extend(compressed)
    if changed!=1: raise ValueError('Expected exactly one management module')
    toff=len(body);body.extend(marshal.dumps(dict(toc) if isinstance(original_toc,dict) else toc))
    body[8:12]=struct.pack('!I',toff)
    return bytes(body)

def patch_program(data):
    _,_,rows=entries(data)
    row=next(row for row in rows if row[1]==b'z')
    raw=zlib.decompress(row[4]) if row[2] else row[4]
    return rebuild_archive(data,{row[0]:wrap_management(raw)})

def build(source, output):
    intermediate=output.with_name('installer-entry-intermediate.exe')
    repair(source,intermediate)
    first=intermediate.read_bytes();_,_,rows=entries(first)
    item=next(row for row in rows if row[0]=='payload.zip')
    old_payload=zlib.decompress(item[4]) if item[2] else item[4]
    changed=[];new_stream=io.BytesIO()
    with zipfile.ZipFile(io.BytesIO(old_payload)) as src,zipfile.ZipFile(new_stream,'w') as dst:
        for item in src.infolist():
            value=src.read(item.filename)
            if item.filename in ('UniAI.exe','uniai-agent.exe'):
                before=hashlib.sha256(value).hexdigest();value=patch_program(value)
                changed.append({'file':item.filename,'before':before,'after':hashlib.sha256(value).hexdigest()})
            dst.writestr(item,value)
    if len(changed)!=2: raise ValueError('Expected the GUI and worker executables')
    result=rebuild_archive(first,{'payload.zip':new_stream.getvalue()})
    output.write_bytes(result)
    metadata={'repair':'installer-fix.2','original_sha256':hashlib.sha256(source.read_bytes()).hexdigest(),'sha256':hashlib.sha256(result).hexdigest(),'bytes':len(result),'changed_payload_files':changed,'management_change':'post-success refresh of an existing local launcher cache only; original authorization handler runs first','gateway_model_and_protocol_code_unchanged':True,'unsigned':True}
    output.with_suffix('.json').write_text(json.dumps(metadata,indent=2),encoding='utf-8')
    print(json.dumps(metadata,indent=2))
if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('input',type=pathlib.Path);parser.add_argument('output',type=pathlib.Path)
    args=parser.parse_args();build(args.input,args.output)
