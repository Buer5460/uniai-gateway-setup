"""Windows-only installer E2E. CI is NOT claimed to be a clean consumer Windows VM.
The application subprocesses receive no developer PATH/PYTHONPATH or accounts.
The test harness may use Python/Playwright; the installed application may not.
"""
import argparse, ctypes, hashlib, json, os, platform, re, shutil, socket, subprocess, sys, tempfile, time, traceback, urllib.request
from ctypes import wintypes
from pathlib import Path

parser=argparse.ArgumentParser();parser.add_argument('--installer',required=True);parser.add_argument('--bootstrap',required=True);parser.add_argument('--out',required=True)
a=parser.parse_args();out=Path(a.out).resolve();out.mkdir(parents=True,exist_ok=True)
installer=Path(a.installer).resolve();bootstrap=Path(a.bootstrap).resolve()
root=Path(tempfile.mkdtemp(prefix='uniai-e2e-'))
home=root/'空白 用户';local=home/'AppData'/'Local';roaming=home/'AppData'/'Roaming';tmp=home/'Temp';target=local/'UniAI Gateway'
for p in (home,local,roaming,tmp):p.mkdir(parents=True,exist_ok=True)
env=dict(os.environ)
for k in list(env):
    if k.upper().startswith(('PYTHON','PYI','_PYI','CONDA','VIRTUAL_ENV','UNIAI','GITHUB','ACTIONS','GH_TOKEN')):env.pop(k,None)
env.update(USERPROFILE=str(home),HOME=str(home),LOCALAPPDATA=str(local),APPDATA=str(roaming),TEMP=str(tmp),TMP=str(tmp),PATH=os.environ['SystemRoot']+'\\System32;'+os.environ['SystemRoot']+';'+os.environ['SystemRoot']+'\\System32\\WindowsPowerShell\\v1.0')
report={'environment':platform.platform(),'kind':'fresh paths + isolated subprocess environment on hosted Windows CI','real_blank_windows_client_vm':'NOT_RUN','real_different_windows_user':'NOT_RUN','developer_runtimes_on_host':True,'application_PATH':env['PATH'],'python_on_application_PATH':shutil.which('python',path=env['PATH']),'node_on_application_PATH':shutil.which('node',path=env['PATH']),'cases':[]}

def case(name,ok,detail=''):
    report['cases'].append({'name':name,'pass':bool(ok),'detail':detail});print(name, 'PASS' if ok else 'FAIL',detail,flush=True)
    if not ok:raise AssertionError(name+': '+detail)

def request(url):
    op=urllib.request.build_opener(urllib.request.ProxyHandler({}))
    with op.open(url,timeout=5) as r:return r.status,r.read(),r.headers.get('Content-Type','')

def windows():
    result=[];user32=ctypes.windll.user32
    callbacktype=ctypes.WINFUNCTYPE(wintypes.BOOL,wintypes.HWND,wintypes.LPARAM)
    @callbacktype
    def callback(hwnd,lparam):
        n=user32.GetWindowTextLengthW(hwnd)
        if n and user32.IsWindowVisible(hwnd):
            buf=ctypes.create_unicode_buffer(n+1);user32.GetWindowTextW(hwnd,buf,n+1)
            result.append((int(hwnd),buf.value))
        return True
    user32.EnumWindows(callback,0);return result

proc=None;port=None
try:
    case('no_developer_python_or_node_on_application_PATH',not report['python_on_application_PATH'] and not report['node_on_application_PATH'])
    # This is the exact no-argument launch the user double-clicks, not a stub.
    proc=subprocess.Popen([str(installer)],env=env,cwd=str(root))
    deadline=time.monotonic()+60;found=[]
    while time.monotonic()<deadline:
        found=[(h,t) for h,t in windows() if 'UniAI Gateway' in t and '安装' in t]
        if found:break
        if proc.poll() is not None:break
        time.sleep(.5)
    case('no_argument_EXE_creates_visible_installer_window',bool(found),str([t for _,t in found]))
    for hwnd,_ in found:ctypes.windll.user32.PostMessageW(hwnd,0x0010,0,0)
    proc.wait(timeout=30);proc=None
    # Exercise the same PowerShell bootstrap used by end users; only the local asset is supplied pre-download.
    command=[env['SystemRoot']+'\\System32\\WindowsPowerShell\\v1.0\\powershell.exe','-NoProfile','-File',str(bootstrap),'-InstallerPath',str(installer),'-ExpectedSHA256',hashlib.sha256(installer.read_bytes()).hexdigest(),'-InstallDir',str(target),'-NoOpen','-NoAutostart']
    run=subprocess.run(command,env=env,cwd=str(root),capture_output=True,timeout=480)
    (out/'bootstrap.stdout.log').write_bytes(run.stdout);(out/'bootstrap.stderr.log').write_bytes(run.stderr)
    case('real_PowerShell_bootstrap_exit',run.returncode==0,'exit='+str(run.returncode)+'; see bootstrap logs')
    for name in ('UniAI.exe','uniai-agent.exe','install.json','_internal/python312.dll','_internal/apps/console/dist/index.html'):
        case('installed_'+name,(target/name).is_file())
    cfg=json.loads((target/'install.json').read_text(encoding='utf-8'));port=int(cfg['port']);base='http://127.0.0.1:'+str(port)
    case('Unicode_and_space_install_path',Path(cfg['install_dir']).resolve()==target.resolve())
    status,body,_=request(base+'/health');health=json.loads(body)
    case('gateway_is_real_uniai',status==200 and health.get('service')=='uniai-gateway')
    status,html,mime=request(base+'/console/');case('built_console_HTML',status==200 and b'<script' in html)
    # Real browser render and authentication; do not publish credentials or browser traces.
    material=json.loads((target/'data/run/bootstrap.token').read_text(encoding='utf-8'))
    from playwright.sync_api import sync_playwright
    with sync_playwright() as pw:
        browser=pw.chromium.launch(headless=True)
        page=browser.new_page();page.goto(base+'/console/#bootstrap_token='+material['token'],wait_until='networkidle',timeout=60000)
        page.get_by_role('heading',name='总览',exact=True).wait_for(timeout=30000)
        case('actual_browser_renders_dashboard',True)
        page.screenshot(path=str(out/'console.png'),full_page=True)
        page.reload(wait_until='networkidle');page.get_by_role('heading',name='总览',exact=True).wait_for(timeout=30000)
        case('browser_refresh_preserves_console_session',True)
        # Use the same browser session to verify unauthorized requests remain rejected.
        code=page.evaluate("async () => (await fetch('/api/providers')).status")
        case('anonymous_management_request_stays_rejected',code in (401,403))
        browser.close()
    # Re-running is idempotent; it must preserve a sentinel and existing database.
    sentinel=target/'data/user-data-sentinel.txt';sentinel.write_text('keep',encoding='utf-8')
    rerun=subprocess.run(command,env=env,cwd=str(root),capture_output=True,timeout=360)
    (out/'bootstrap-rerun.stdout.log').write_bytes(rerun.stdout);(out/'bootstrap-rerun.stderr.log').write_bytes(rerun.stderr)
    case('repeat_bootstrap_is_nondestructive',rerun.returncode==0 and sentinel.read_text()=='keep')
    # Stop only this installed runtime on its discovered port.
    stop=subprocess.run([str(target/'uniai-agent.exe'),'-m','runtime.service','stop'],env=env,cwd=str(target),capture_output=True,timeout=90)
    time.sleep(3)
    with socket.socket() as sock:closed=sock.connect_ex(('127.0.0.1',port))!=0
    case('installed_runtime_stops',closed,'exit='+str(stop.returncode))
    un=subprocess.run([str(target/'uninstall.exe'),'--uninstall','--yes'],env=env,cwd=str(root),capture_output=True,timeout=120)
    case('uninstall_removes_application_but_preserves_data',un.returncode==0 and not (target/'UniAI.exe').exists() and sentinel.exists())
except Exception as exc:
    report['failure']=str(exc);(out/'failure.txt').write_text(traceback.format_exc(),encoding='utf-8');print(traceback.format_exc(),flush=True)
finally:
    if proc and proc.poll() is None:proc.terminate()
    report['passed']=sum(c['pass'] for c in report['cases']);report['failed']=sum(not c['pass'] for c in report['cases'])
    report['result']='FAIL' if 'failure' in report else 'PASS'
    report['installer_sha256']=hashlib.sha256(installer.read_bytes()).hexdigest()
    # Only copy the new entry log, not application data, keys, database or session cache.
    log=local/'UniAIInstaller/Logs/installer.log'
    if log.exists():(out/'installer-entry.log').write_text(log.read_text(encoding='utf-8',errors='replace'),encoding='utf-8')
    (out/'windows-e2e.json').write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf-8')
    print(json.dumps(report,ensure_ascii=False,indent=2),flush=True)
if report['result']!='PASS':sys.exit(1)
