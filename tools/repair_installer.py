"""Repair verified UniAI 0.8.0 installation entry points.
Build-only dependency: CPython 3.12. Original input is not executed during build.
All embedded gateway payload/runtime bytes remain unchanged.
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
MAIN_SOURCE=r'''
def main(argv=None):
    import datetime, traceback, base64, ctypes
    global create_shortcut
    log_dir=Path(os.environ.get('LOCALAPPDATA',os.environ.get('TEMP','.')))/'UniAI Installer'/'logs'
    log_dir.mkdir(parents=True,exist_ok=True)
    log_path=log_dir/('setup-'+datetime.datetime.now().strftime('%Y%m%d-%H%M%S')+'-'+str(os.getpid())+'.log')
    log=log_path.open('a',encoding='utf-8',buffering=1)
    if sys.stdout is None: sys.stdout=log
    if sys.stderr is None: sys.stderr=log
    arguments=list(sys.argv[1:] if argv is None else argv)
    def reliable_shortcut(link,target,working_dir,description,arguments='',icon=None):
        try:
            link=Path(link);link.parent.mkdir(parents=True,exist_ok=True)
            quote=lambda value: "'"+str(value).replace("'","''")+"'"
            lines=["$ErrorActionPreference='Stop'","$shell=New-Object -ComObject WScript.Shell",
                "$shortcut=$shell.CreateShortcut("+quote(link)+")",
                "$shortcut.TargetPath="+quote(target),
                "$shortcut.WorkingDirectory="+quote(working_dir),
                "$shortcut.Description="+quote(description),
                "$shortcut.Arguments="+quote(arguments or '')]
            if icon: lines.append("$shortcut.IconLocation="+quote(str(icon)+',0'))
            lines.extend(["$shortcut.Save()","if(-not(Test-Path -LiteralPath "+quote(link)+")){throw 'Shortcut was not created'}"])
            encoded=base64.b64encode(';'.join(lines).encode('utf-16le')).decode('ascii')
            host=Path(os.environ.get('SystemRoot',r'C:\Windows'))/'System32'/'WindowsPowerShell'/'v1.0'/'powershell.exe'
            if not host.is_file(): raise FileNotFoundError('Windows PowerShell is unavailable')
            # PyInstaller's DLL search directory must not leak into a system process.
            ctypes.windll.kernel32.SetDllDirectoryW(None)
            try:
                done=subprocess.run([str(host),'-NoLogo','-NoProfile','-NonInteractive','-Sta','-EncodedCommand',encoded],capture_output=True,timeout=45,encoding='utf-8',errors='replace',creationflags=getattr(subprocess,'CREATE_NO_WINDOW',0))
            finally:
                if getattr(sys,'_MEIPASS',None): ctypes.windll.kernel32.SetDllDirectoryW(str(sys._MEIPASS))
            if done.returncode or not link.is_file():
                print('Shortcut creation failed: '+str(link)+' '+done.stderr[-3000:],file=log)
                return False
            print('Shortcut created: '+str(link),file=log)
            return True
        except Exception:
            traceback.print_exc(file=log)
            return False
    create_shortcut=reliable_shortcut
    try:
        print('UniAI installer repair 1: entry reached',file=log)
        parser=argparse.ArgumentParser(description='UniAI Gateway setup')
        for flag in ('--uninstall','--yes','--purge-data','--silent','--no-autostart','--launch'):
            parser.add_argument(flag,action='store_true')
        parser.add_argument('--dir',dest='directory')
        parser.add_argument('--port',type=int)
        args=parser.parse_args(arguments)
        if args.uninstall:
            here=Path(sys.executable).resolve().parent
            config=pc.load_install(here)
            target=Path(config['install_dir']) if isinstance(config,dict) and config.get('install_dir') else here
            keep=not args.purge_data
            if not args.yes and not args.purge_data:
                import tkinter as tk
                from tkinter import messagebox
                root=tk.Tk();root.withdraw()
                keep=messagebox.askyesno(APP_TITLE,'Keep local settings and credentials for a future reinstall?')
                root.destroy()
            return uninstall(target,keep)
        payload_zip()
        if not args.silent:
            # Original __init__ calls show(0) before creating its back/next buttons.
            original_show=Installer.show
            def initialized_show(self,page):
                if not hasattr(self,'back') or not hasattr(self,'next'):
                    self.page=page
                    self.pages[page].tkraise()
                    return
                return original_show(self,page)
            Installer.show=initialized_show
            print('Opening native installation wizard',file=log)
            wizard=Installer()
            wizard.autostart.set(False)
            wizard.show(0)
            return int(wizard.run() or 0)
        target=Path(args.directory or pc.default_install_dir())
        port=int(args.port or pc.first_free_port())
        if not 1024<=port<=65535: raise ValueError('Port must be between 1024 and 65535')
        summary=perform_install(target,port,not args.no_autostart)
        for relative in ('UniAI.exe','uniai-agent.exe','install.json','_internal/python312.dll','_internal/apps/console/dist/index.html'):
            if not (target/relative).is_file(): summary['errors'].append('Required installed file is missing: '+relative)
        if args.launch and not summary.get('errors'): summary['launched']=_launch_entry(target,summary)
        print(json.dumps(summary,ensure_ascii=False,indent=2),file=log)
        return 1 if summary.get('errors') else 0
    except SystemExit as exc:
        return exc.code if isinstance(exc.code,int) else (0 if exc.code is None else 1)
    except Exception:
        traceback.print_exc(file=log)
        if '--silent' not in arguments:
            try: ctypes.windll.user32.MessageBoxW(None,'Installation failed. Log: '+str(log_path),'UniAI setup error',16)
            except Exception: pass
        return 1
    finally: log.flush()
'''
def repair(source,output):
    if sys.version_info[:2]!=(3,12): raise RuntimeError('Build requires CPython 3.12, not the user machine')
    data=source.read_bytes()
    if hashlib.sha256(data).hexdigest()!=OLD_SHA: raise ValueError('Input hash mismatch; refusing unknown executable')
    start,lib,rows=entries(data)
    old=next(r for r in rows if r[0]=='product_install' and r[1]==b's')
    code=zlib.decompress(old[4]) if old[2] else old[4]
    module=marshal.loads(code)
    replacement_main=next(c for c in compile(MAIN_SOURCE,'product_install_repaired.py','exec').co_consts if hasattr(c,'co_name') and c.co_name=='main')
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
