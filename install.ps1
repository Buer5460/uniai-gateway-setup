#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'UniAI Gateway'),
    [string]$PackagePath = '',
    [ValidatePattern('^[a-fA-F0-9]{64}$')]
    [string]$PackageSha256 = 'b6dbaa1d5337cb1da065cbaa9c4747cc7959314013d770f99ea782b90c753c7a',
    [ValidateRange(0,65535)][int]$Port = 0,
    [switch]$NoOpen,
    [switch]$EnableAutostart
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'Continue'
$packageUrl = 'https://github.com/Buer5460/uniai-gateway-setup/releases/download/v0.8.0/UniAI-Setup-0.8.0-windows-x64.exe'
$logRoot = Join-Path $env:LOCALAPPDATA 'UniAI Installer\logs'
New-Item -ItemType Directory -Force -Path $logRoot | Out-Null
$logFile = Join-Path $logRoot ('bootstrap-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + $PID + '.log')
$lock = $null
$locked = $false
function Say([string]$Text) {
    $line = '[' + (Get-Date -Format 'HH:mm:ss') + '] ' + $Text
    Write-Host $line
    Add-Content -LiteralPath $logFile -Value $line -Encoding UTF8
}
function Native([string]$Exe, [string]$Arguments, [int]$Seconds) {
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $Exe
    $info.Arguments = $Arguments
    $info.WorkingDirectory = Split-Path -Parent $Exe
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $info
    if (-not $p.Start()) { throw 'Could not start program. Windows security policy may have blocked it.' }
    $deadline = (Get-Date).AddSeconds($Seconds)
    while (-not $p.WaitForExit(3000)) {
        if ((Get-Date) -gt $deadline) {
            throw ('Timed out; process PID ' + $p.Id + ' may still be running. No other processes were stopped.')
        }
        Say 'Working... please do not start a second installer.'
    }
    $code = $p.ExitCode
    $p.Dispose()
    if ($code -ne 0) { throw ('Program exited with code ' + $code + '. See setup/runtime logs.') }
}
function LocalGet([string]$Url) {
    $request = [System.Net.HttpWebRequest]::Create($Url)
    $request.Proxy = $null
    $request.AllowAutoRedirect = $false
    $request.Timeout = 3000
    $response = $request.GetResponse()
    try {
        $reader = New-Object System.IO.StreamReader($response.GetResponseStream())
        try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
    } finally { $response.Dispose() }
}
try {
    Say '1/5 Checking Windows, architecture and existing installation.'
    if ($env:OS -ne 'Windows_NT' -or -not [Environment]::Is64BitOperatingSystem) { throw 'This package requires 64-bit Windows.' }
    $arch = $env:PROCESSOR_ARCHITEW6432
    if (-not $arch) { $arch = $env:PROCESSOR_ARCHITECTURE }
    if ($arch -ne 'AMD64') { throw 'ARM and 32-bit Windows are not supported by this x64 package.' }
    if ([Environment]::OSVersion.Version.Major -lt 10) { throw 'Windows 10 or later is required.' }
    $InstallDir = [IO.Path]::GetFullPath($InstallDir)
    if ($InstallDir -match '["\r\n]' -or $InstallDir -eq [IO.Path]::GetPathRoot($InstallDir)) { throw 'Unsafe installation path.' }
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $lock = New-Object System.Threading.Mutex($false, ('Local\UniAI-Install-' + $sid))
    try { $locked = $lock.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $locked = $true }
    if (-not $locked) { throw 'Another UniAI installation is already running for this user.' }
    $receipt = Join-Path $InstallDir 'install.json'
    $present = Test-Path -LiteralPath $receipt -PathType Leaf
    if (-not $present -and (Test-Path -LiteralPath $InstallDir)) {
        if (@(Get-ChildItem -LiteralPath $InstallDir -Force).Count -gt 0) { throw 'Target contains files but no valid installation receipt. Refusing to overwrite it.' }
    }
    if (-not $present) {
        Say '2/5 Preparing the verified package (bundled Python and runtime libraries).'
        if (-not $PackagePath) {
            $PackagePath = Join-Path $env:TEMP ('UniAI-verified-' + $PackageSha256.Substring(0,12) + '.exe')
            $useCache = (Test-Path -LiteralPath $PackagePath -PathType Leaf) -and ((Get-FileHash -LiteralPath $PackagePath -Algorithm SHA256).Hash -eq $PackageSha256)
            if (-not $useCache) {
                [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
                $part = $PackagePath + '.' + [Guid]::NewGuid().ToString('N') + '.part'
                for ($attempt=1; $attempt -le 3; $attempt++) {
                    try {
                        Say ('Downloading package, attempt ' + $attempt + '/3. Network access to GitHub is required.')
                        Invoke-WebRequest -Uri $packageUrl -OutFile $part -UseBasicParsing -TimeoutSec 300 -ErrorAction Stop
                        if ((Get-FileHash -LiteralPath $part -Algorithm SHA256).Hash -ne $PackageSha256) { throw 'Package checksum mismatch. Execution blocked.' }
                        Move-Item -LiteralPath $part -Destination $PackagePath -Force
                        break
                    } catch {
                        if ($attempt -eq 3) { throw }
                        Start-Sleep -Seconds 3
                    }
                }
            }
        }
        $PackagePath = [IO.Path]::GetFullPath($PackagePath)
        if ((Get-FileHash -LiteralPath $PackagePath -Algorithm SHA256).Hash -ne $PackageSha256) { throw 'Package checksum mismatch. Execution blocked.' }
        if ($Port -eq 0) {
            for ($candidate=8935; $candidate -le 8985; $candidate++) {
                $listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, $candidate)
                try { $listener.Start(); $Port=$candidate; break } catch {} finally { $listener.Stop() }
            }
            if ($Port -eq 0) { throw 'No free loopback port in 8935-8985. No process was stopped.' }
        }
        if ($Port -lt 1024) { throw 'Port must be between 1024 and 65535.' }
        Say ('3/5 Installing to ' + $InstallDir + '; loopback port ' + $Port + '.')
        $arguments = '--silent --dir "' + $InstallDir.TrimEnd('\') + '" --port ' + $Port
        if (-not $EnableAutostart) { $arguments += ' --no-autostart' }
        Native $PackagePath $arguments 600
    } else {
        Say '2/5 Existing installation found; not overwriting files, credentials or configuration.'
        Say '3/5 Verifying existing runtime.'
    }
    foreach ($relative in @('UniAI.exe','uniai-agent.exe','install.json','_internal\python312.dll','_internal\VCRUNTIME140.dll','_internal\apps\console\dist\index.html')) {
        if (-not (Test-Path -LiteralPath (Join-Path $InstallDir $relative) -PathType Leaf)) { throw ('Installer returned but required file is missing: ' + $relative) }
    }
    $config = Get-Content -LiteralPath $receipt -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([IO.Path]::GetFullPath([string]$config.install_dir).TrimEnd('\') -ne $InstallDir.TrimEnd('\')) { throw 'Installation receipt points to a different directory.' }
    $Port = [int]$config.port
    if ($Port -lt 1024 -or $Port -gt 65535) { throw 'Invalid loopback port in receipt.' }
    $base = 'http://127.0.0.1:' + $Port
    Say '4/5 Starting packaged runtime. No system Python or Node is invoked.'
    Native (Join-Path $InstallDir 'UniAI.exe') '--start-only' 240
    $health = LocalGet ($base + '/health') | ConvertFrom-Json
    if ($health.service -ne 'uniai-gateway') { throw 'Port belongs to a different service; refusing to report success.' }
    $html = LocalGet ($base + '/console/')
    if ($html -notmatch '<html' -or $html -notmatch '<script') { throw 'Console HTML is not available.' }
    $scripts = [regex]::Matches($html, '<script[^>]+src=["'']([^"'']+)["'']')
    foreach ($script in $scripts) {
        $asset = New-Object Uri ((New-Object Uri ($base + '/console/')), $script.Groups[1].Value)
        if ($asset.Authority -ne (New-Object Uri $base).Authority) { throw 'Unexpected external console script.' }
        $js = LocalGet $asset.AbsoluteUri
        if ($js.Length -lt 50 -or $js -match '^\s*<!DOCTYPE html') { throw 'Console script is missing or returned HTML.' }
    }
    Say '5/5 Runtime and console files are ready.'
    if (-not $NoOpen) {
        $openInfo = New-Object Diagnostics.ProcessStartInfo
        $openInfo.FileName = Join-Path $InstallDir 'UniAI.exe'
        $openInfo.WorkingDirectory = $InstallDir
        $openInfo.UseShellExecute = $true
        [Diagnostics.Process]::Start($openInfo) | Out-Null
        Say 'Opening the local sign-in/console launcher. Model account authorization may still be required.'
    }
    Say ('Installed runtime: ' + $InstallDir)
    Say ('Console address: ' + $base + '/console/')
    Say ('Log: ' + $logFile)
    Say 'No Windows service installed; no antivirus disabled; existing AI-client keys are not rewritten.'
} catch {
    Say ('FAILED: ' + $_.Exception.Message)
    Say ('Log: ' + $logFile)
    throw
} finally {
    if ($locked -and $lock) { $lock.ReleaseMutex() }
    if ($lock) { $lock.Dispose() }
}
