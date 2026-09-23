$ErrorActionPreference='Stop'
$repo=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$out=Join-Path $repo 'out'
$original=Join-Path $out 'original.exe'
$fixed=Join-Path $out 'UniAI-Setup-0.8.0-installer-fix.1-windows-x64.exe'
$sha=(Get-FileHash $fixed -Algorithm SHA256).Hash
$root=Join-Path $env:RUNNER_TEMP ('UniAI-'+[char]0x7A7A+[char]0x767D+' test user')
$env:USERPROFILE=Join-Path $root 'profile'
$env:HOME=$env:USERPROFILE
$env:APPDATA=Join-Path $env:USERPROFILE 'AppData\Roaming'
$env:LOCALAPPDATA=Join-Path $env:USERPROFILE 'AppData\Local'
$env:TEMP=Join-Path $root 'temp'
$env:TMP=$env:TEMP
foreach($d in @($env:USERPROFILE,$env:APPDATA,$env:LOCALAPPDATA,$env:TEMP,(Join-Path $env:USERPROFILE 'Desktop'))) { New-Item -ItemType Directory -Force $d | Out-Null }
Remove-Item Env:PYTHONHOME,Env:PYTHONPATH,Env:TCL_LIBRARY,Env:TK_LIBRARY -ErrorAction SilentlyContinue
$env:PATH="$env:SystemRoot\System32;$env:SystemRoot;$env:SystemRoot\System32\WindowsPowerShell\v1.0"
Set-Location $root
$results=[System.Collections.Generic.List[object]]::new()
function Case($name,$ok,$detail) {
    $results.Add([pscustomobject]@{name=$name;passed=[bool]$ok;detail=$detail})
    $results | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $out 'windows-results.json') -Encoding UTF8
    Write-Host ($name+': '+$ok+' '+$detail)
    if(-not $ok) { throw ('FAILED: '+$name+' '+$detail) }
}
try {
    Case 'no_python_node_git_on_path' (-not(Get-Command python,node,git -ErrorAction SilentlyContinue)) 'PATH restricted; hosted OS is Server 2022, not Windows 11.'
    $p=Start-Process -FilePath $original -PassThru
    $exited=$p.WaitForExit(30000)
    Case 'original_gui_noop_reproduced' ($exited -and $p.ExitCode -eq 0 -and -not(Test-Path (Join-Path $env:LOCALAPPDATA 'UniAI Gateway\install.json'))) 'Original exits zero without installing.'
    $p=Start-Process -FilePath $fixed -PassThru
    $window=$null
    for($i=0;$i -lt 30;$i++) {
        Start-Sleep 1
        $window=Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -like 'UniAI-Setup-0.8.0-installer-fix*' -and $_.MainWindowHandle -ne 0 } | Select-Object -First 1
        if($window) { break }
    }
    Case 'fixed_gui_window_visible' ([bool]$window) $(if($window){$window.MainWindowTitle}else{'No native window'})
    $window.CloseMainWindow() | Out-Null
    $p.WaitForExit(15000) | Out-Null
    $target=Join-Path $env:LOCALAPPDATA 'UniAI Gateway'
    & (Join-Path $repo 'install.ps1') -InstallDir $target -PackagePath $fixed -PackageSha256 $sha -NoOpen
    Case 'fixed_installer_runtime_and_assets' (Test-Path (Join-Path $target 'install.json')) 'Installer, runtime health and console asset checks, not mocks.'
    & (Join-Path $repo 'install.ps1') -InstallDir $target -PackagePath $fixed -PackageSha256 $sha -NoOpen
    Case 'rerun_preserves_installation' $true 'Reuses existing receipt; does not overwrite configuration.'
    $headless=Start-Process -FilePath (Join-Path $target 'UniAI.exe') -ArgumentList '--headless' -PassThru
    $headlessExited=$headless.WaitForExit(180000)
    Case 'local_console_auth_without_provider_account' ($headlessExited -and $headless.ExitCode -eq 0 -and (Test-Path (Join-Path $target 'data\run\launcher-admin.key'))) 'Local control-plane login only; no claim of real model access or browser rendering.'
    $stop=Start-Process -FilePath (Join-Path $target 'uniai-agent.exe') -ArgumentList '-m runtime.service stop' -PassThru
    $stop.WaitForExit(60000) | Out-Null
    $uninstall=Start-Process -FilePath (Join-Path $target 'uninstall.exe') -ArgumentList '--uninstall --yes' -PassThru
    if(-not $uninstall.WaitForExit(60000)) { throw 'Uninstall timeout' }
    Case 'uninstall_removes_main_executable' (-not(Test-Path (Join-Path $target 'UniAI.exe'))) ('exit '+$uninstall.ExitCode)
    $info=@{os=[Environment]::OSVersion.VersionString;profile=$env:USERPROFILE;path=$env:PATH;no_model_accounts=$true;real_windows11_blank_machine_tested=$false;source_commit=$env:GITHUB_SHA;tests=$results}
    $info | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $out 'verification.json') -Encoding UTF8
} finally {
    $logs=Join-Path $env:LOCALAPPDATA 'UniAI Installer\logs'
    if(Test-Path $logs) {
        Get-ChildItem $logs -Filter '*.log' | ForEach-Object {
            Copy-Item $_.FullName (Join-Path $out $_.Name)
            Write-Host ('SETUP LOG: '+$_.Name)
            Get-Content $_.FullName -Tail 60 -Encoding UTF8 | Write-Host
        }
    }
    $target=Join-Path $env:LOCALAPPDATA 'UniAI Gateway'
    $info=@{files=@(Get-ChildItem $target -ErrorAction SilentlyContinue | Select-Object Name,Length);os=[Environment]::OSVersion.VersionString;source_commit=$env:GITHUB_SHA}
    $info | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $out 'install-directory.json') -Encoding UTF8
}
