# Compiled into the verified installer module; original module supplies pc/Path/etc.
def main(argv=None):
    import datetime, traceback, ctypes
    global create_shortcut
    log_dir=Path(os.environ.get('LOCALAPPDATA',os.environ.get('TEMP','.')))/'UniAI Installer'/'logs'
    log_dir.mkdir(parents=True,exist_ok=True)
    log_path=log_dir/('setup-'+datetime.datetime.now().strftime('%Y%m%d-%H%M%S')+'-'+str(os.getpid())+'.log')
    log=log_path.open('a',encoding='utf-8',buffering=1)
    if sys.stdout is None: sys.stdout=log
    if sys.stderr is None: sys.stderr=log
    arguments=list(sys.argv[1:] if argv is None else argv)

    def reliable_shortcut(link,target,working_dir,description,arguments='',icon=None):
        # Native Unicode COM API; no WScript, pywin32 or external development tool.
        from ctypes import wintypes
        ole=ctypes.OleDLL('ole32')
        class GUID(ctypes.Structure):
            _fields_=[('d1',wintypes.DWORD),('d2',wintypes.WORD),('d3',wintypes.WORD),('d4',ctypes.c_ubyte*8)]
        HRESULT=ctypes.c_long
        VP=ctypes.c_void_p
        PVP=ctypes.POINTER(VP)
        ole.CoInitializeEx.argtypes=[VP,wintypes.DWORD];ole.CoInitializeEx.restype=HRESULT
        ole.CoUninitialize.argtypes=[];ole.CoUninitialize.restype=None
        ole.CLSIDFromString.argtypes=[wintypes.LPCWSTR,ctypes.POINTER(GUID)];ole.CLSIDFromString.restype=HRESULT
        ole.CoCreateInstance.argtypes=[ctypes.POINTER(GUID),VP,wintypes.DWORD,ctypes.POINTER(GUID),PVP];ole.CoCreateInstance.restype=HRESULT
        def check(hr):
            if hr<0: raise OSError('Windows COM HRESULT 0x%08x'%(hr & 0xffffffff))
        def guid(text):
            value=GUID();check(ole.CLSIDFromString(text,ctypes.byref(value)));return value
        def call(ptr,index,types,*args):
            table=ctypes.cast(ptr,ctypes.POINTER(ctypes.POINTER(VP))).contents
            fn=ctypes.WINFUNCTYPE(HRESULT,VP,*types)(table[index])
            result=fn(ptr,*args);check(result);return result
        shell=VP();persist=VP();initialized=False
        try:
            hr=ole.CoInitializeEx(None,2)
            if hr>=0: initialized=True
            elif (hr & 0xffffffff)!=0x80010106: check(hr)
            clsid=guid('{00021401-0000-0000-C000-000000000046}')
            iid=guid('{000214F9-0000-0000-C000-000000000046}')
            iid_file=guid('{0000010B-0000-0000-C000-000000000046}')
            link=Path(link);link.parent.mkdir(parents=True,exist_ok=True)
            target=Path(target).resolve()
            if not target.is_file(): raise FileNotFoundError('Shortcut target is missing: '+str(target))
            check(ole.CoCreateInstance(ctypes.byref(clsid),None,1,ctypes.byref(iid),ctypes.byref(shell)))
            call(shell,20,[wintypes.LPCWSTR],str(target))
            call(shell,9,[wintypes.LPCWSTR],str(working_dir))
            call(shell,7,[wintypes.LPCWSTR],str(description))
            call(shell,11,[wintypes.LPCWSTR],str(arguments or ''))
            if icon: call(shell,17,[wintypes.LPCWSTR,ctypes.c_int],str(icon),0)
            call(shell,0,[ctypes.POINTER(GUID),PVP],ctypes.byref(iid_file),ctypes.byref(persist))
            call(persist,6,[wintypes.LPCWSTR,wintypes.BOOL],str(link),True)
            if not link.is_file(): raise OSError('Windows did not save the shortcut')
            print('Unicode shortcut created: '+str(link),file=log)
            return True
        except Exception:
            traceback.print_exc(file=log)
            return False
        finally:
            for ptr in (persist,shell):
                if ptr.value:
                    try: call(ptr,2,[])
                    except Exception: pass
            if initialized: ole.CoUninitialize()

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
            original_show=Installer.show
            def initialized_show(self,page):
                if not hasattr(self,'back') or not hasattr(self,'next'):
                    self.page=page;self.pages[page].tkraise();return
                return original_show(self,page)
            Installer.show=initialized_show
            print('Opening native installation wizard',file=log)
            wizard=Installer();wizard.autostart.set(False);wizard.show(0)
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
