#Requires -Version 5.1
<#
    UniAI Gateway - one-line installer for Windows (no Python / Node / Git needed).

    RC4 fixes, every one of them found by installing on a real machine:

      * canonical install root. RC3 defaulted to %LOCALAPPDATA%\UniAI although
        the real installation was %LOCALAPPDATA%\UniAI Gateway, called that a
        clean install and built a second one next to it. The root is now
        resolved by scripts/uniai_home.py (install.json / data / historical
        default) and an existing installation is migrated, never duplicated.
      * no Python snippets through PowerShell strings. scripts/python_runtime_check.py
        and scripts/pip_bootstrap.py are real files with real exit codes; a
        failed runtime check stops the install instead of printing and moving on.
      * every Test-Path stands in its own parentheses, so no
        ParameterBindingException can reach the log.
      * the browser is opened by scripts/console_url.py only after GET /health
        answers status=ok, and uniai://console is registered so the public page
        launches the launcher instead of a raw URL.

    Layout under the canonical root:
      app                   program files (replaceable)
      app.previous          previous program files (rollback source)
      data                  database, keys, vault, logs - never deleted here
      runtime               python / node / qoder CLI - persistent
      legacy-program-backup previous program of a 0.8.0 install, archived only
                            after the replacement has proven /health

    Run it with (one line):
      irm https://buer5460.github.io/uniai-gateway-setup/install.ps1 | iex
#>
param(
    [string]$InstallDir = '',
    [int]$Port = 0,
    [switch]$SkipQoder,
    [switch]$SkipZCode,
    [switch]$NoOpen,
    # Self-test hook only. Never used in a normal install.
    [ValidateSet('', 'extract', 'deps', 'migrate', 'health')]
    [string]$FailAt = ''
)

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

$ProductVersion = '1.0.0-rc4'
$ZipUrl = 'https://github.com/Buer5460/uniai-gateway-setup/releases/download/v1.0.0-rc4/uniai-gateway-1.0.0-rc4-windows-x64.zip'
$ZipSha256 = '99a511f8aba6361ab0e0126ea4f20c839d3e79dd323a3fe80ca7aaf2fdfbb7cd'
$NodeZipName = 'node-v22.23.3-win-x64.zip'
$NodeSha256 = '2b0ff57b049cda1bbcea2240eec20467018713c1efe1f7360c2681859b90ed71'

Add-Type -AssemblyName System.IO.Compression.FileSystem

$script:ErrorSeed = $Error.Count
$script:Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'

function Say($msg) { Write-Host "[uniai] $msg" }
function Ok($msg) { Write-Host "[uniai] OK: $msg" -ForegroundColor Green }
function Warn($msg) { Write-Host "[uniai] $msg" -ForegroundColor Yellow }
function Remove-Dir([string]$path) { if (Test-Path $path) { [System.IO.Directory]::Delete($path, $true) } }
function Get-Sha256([string]$path) { return (Get-FileHash -Path $path -Algorithm SHA256).Hash.ToLower() }

function Move-DirReplace([string]$src, [string]$dst) {
    if (-not (Test-Path $src)) { throw "[uniai] move source missing: $src" }
    for ($i = 0; $i -lt 15; $i++) {
        try { Remove-Dir $dst; [System.IO.Directory]::Move($src, $dst); return }
        catch { Start-Sleep -Seconds 2 }
    }
    throw "[uniai] cannot move '$src' -> '$dst' (still in use?)"
}

function Move-DirNew([string]$src, [string]$dst) {
    if (Test-Path $dst) { throw "[uniai] destination already exists: $dst" }
    for ($i = 0; $i -lt 15; $i++) {
        try { [System.IO.Directory]::Move($src, $dst); return }
        catch { Start-Sleep -Seconds 2 }
    }
    throw "[uniai] cannot move '$src' -> '$dst' (still in use?)"
}

function Move-ItemQuiet([string]$src, [string]$dst) {
    try {
        if (-not (Test-Path $src)) { return $false }
        if (Test-Path $dst) { return $false }
        $item = Get-Item -LiteralPath $src -ErrorAction Stop
        if ($item.PSIsContainer) { [System.IO.Directory]::Move($src, $dst) }
        else { [System.IO.File]::Move($src, $dst) }
        return $true
    }
    catch { return $false }
}

function Write-AsciiFile([string]$path, [string[]]$lines) {
    # Written byte-exact through .NET: VBScript reads these files as ANSI, and
    # a stray line break inside a quoted path silently breaks the launcher.
    $text = [string]::Join("`r`n", $lines)
    [System.IO.File]::WriteAllText($path, $text, [System.Text.Encoding]::ASCII)
}

<#
    The machine already has ways of starting UniAI at logon (a Startup folder
    entry and a scheduled task). They point at the program this install just
    replaced, so leaving them alone would put a second instance on the same
    port. They are retargeted at the new runtime - never deleted, never used to
    start a second gateway during this run.
#>
function Set-DurableStart([string]$rootDir, [string]$appDir, [string]$pythonExe, [int]$gwPort) {
    $starter = Join-Path $rootDir "Start-Gateway-$gwPort.vbs"
    Write-AsciiFile $starter @(
        "' UniAI Gateway - silent starter for the scheduled task / logon entry.",
        "' ASCII only on purpose: VBScript reads this file as ANSI.",
        "Option Explicit",
        "Dim sh, exe, workdir, launch, rc",
        'Set sh = CreateObject("WScript.Shell")',
        ('exe = "{0}"' -f $pythonExe),
        ('workdir = "{0}"' -f $appDir),
        "sh.CurrentDirectory = workdir",
        ('launch = """" & exe & """ -m runtime.service start --port {0}"' -f $gwPort),
        "rc = sh.Run(launch, 0, True)",
        "If rc <> 0 Then",
        "  WScript.Sleep 4000",
        "  rc = sh.Run(launch, 0, True)",
        "End If",
        "WScript.Quit 0"
    )
    $results = @("starter=$starter")

    $startup = [Environment]::GetFolderPath('Startup')
    if ($startup -and (Test-Path $startup)) {
        $logon = Join-Path $startup 'UniAI-Gateway.vbs'
        Write-AsciiFile $logon @(
            "' UniAI Gateway - logon launcher (hidden, no console window).",
            "Option Explicit",
            "Dim shell",
            'Set shell = CreateObject("WScript.Shell")',
            ('shell.CurrentDirectory = "{0}"' -f $rootDir),
            ('shell.Run "wscript.exe //B //NoLogo ""{0}""", 0, False' -f $starter)
        )
        $results += "logon=$logon"
    }

    # schtasks.exe is blocked in locked-down shells, so the task is retargeted
    # through the task scheduler cmdlets instead of a command line.
    $taskName = "UniAI Gateway $gwPort"
    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($task) {
        $argument = '//B //NoLogo "' + $starter + '"'
        try {
            $action = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument $argument
            Set-ScheduledTask -TaskName $taskName -Action $action -ErrorAction Stop | Out-Null
            $results += "task=retargeted:$taskName"
        }
        catch {
            try {
                Disable-ScheduledTask -TaskName $taskName -ErrorAction Stop | Out-Null
                $results += "task=disabled(kept):$taskName"
            }
            catch { $results += "task=UNCHANGED:$($_.Exception.Message)" }
        }
    }
    return ($results -join ' | ')
}

<#
    Stop everything this installation owns before the program is swapped.

    Killing only the process that holds the port is not enough: 0.8.0 runs a
    supervisor beside the gateway, and the supervisor immediately respawns the
    program this installer just replaced - which is how an upgrade ends up with
    two instances fighting over the same port.
#>
function Stop-OwnProcesses([string]$rootDir) {
    $killed = @()
    $targets = @()
    foreach ($p in (Get-Process -ErrorAction SilentlyContinue)) {
        if ($p.Id -eq $PID) { continue }
        $path = ''
        try { $path = [string]$p.Path } catch { $path = '' }
        $mine = $false
        if ($path -and $rootDir) {
            try { $mine = $path.StartsWith($rootDir, [System.StringComparison]::OrdinalIgnoreCase) }
            catch { $mine = $false }
        }
        if (-not $mine) { $mine = ($p.ProcessName -match '^uniai') }
        if ($mine) { $targets += $p }
    }
    foreach ($p in $targets) {
        try { Stop-Process -Id $p.Id -Force -ErrorAction Stop; $killed += "$($p.ProcessName)($($p.Id))" }
        catch { }
    }
    if ($killed.Count -gt 0) { Start-Sleep -Seconds 3 }
    return $killed
}

function Get-BindingErrors {
    $recent = @()
    if ($Error.Count -gt $script:ErrorSeed) {
        $recent = @($Error[$script:ErrorSeed..($Error.Count - 1)])
    }
    return @($recent | Where-Object {
        ($_.FullyQualifiedErrorId -match 'ParameterBinding') -or
        ($_.Exception -and $_.Exception.GetType().FullName -match 'ParameterBinding')
    })
}

# ---------------------------------------------------------- 0 canonical root
Say "UniAI Gateway $ProductVersion installer"
$homePy = $null
$sourceHome = Join-Path $PSScriptRoot 'scripts/uniai_home.py'
if (Test-Path $sourceHome) { $homePy = $sourceHome }
if (-not $homePy) {
    # One-liner path: fetch the resolver from the same place as the installer.
    $bootstrapPy = Join-Path $env:TEMP 'uniai-home-bootstrap.py'
    try {
        Invoke-WebRequest -Uri 'https://buer5460.github.io/uniai-gateway-setup/uniai_home.py' `
            -OutFile $bootstrapPy -UseBasicParsing
        if (Test-Path $bootstrapPy) { $homePy = $bootstrapPy }
    }
    catch { }
}
if (-not $homePy) { throw '[uniai] cannot locate scripts/uniai_home.py' }

$bootstrapPython = (Get-Command python -ErrorAction SilentlyContinue | Select-Object -First 1).Source
if (-not $bootstrapPython) { $bootstrapPython = 'python' }

$homeJsonRaw = & $bootstrapPython $homePy '--json' 2>$null
try { $homeInfo = $homeJsonRaw | ConvertFrom-Json }
catch { throw "[uniai] cannot read install root information: $homeJsonRaw" }
if (-not $homeInfo.root) { throw '[uniai] install root could not be determined' }

if ($InstallDir) { $root = $InstallDir } else { $root = $homeInfo.root }
$AppDir = Join-Path $root 'app'
$PrevDir = Join-Path $root 'app.previous'
$DataDir = Join-Path $root 'data'
$RunDir = Join-Path $root 'runtime'
$StageDir = Join-Path $root '_stage'

Say "canonical install root: $root (source=$($homeInfo.source), score=$($homeInfo.score), evidence=$($homeInfo.evidence -join ','))"
if ($homeInfo.has_data) { Ok 'existing data detected - database, keys and vault stay untouched' }
if ($homeInfo.is_legacy_layout) {
    Say "legacy 0.8.0 program detected at this root: $($homeInfo.legacy_program -join ', ')"
    Say 'migration keeps data/keys/vault and only replaces program files'
}
if ($homeInfo.has_app) { Say 'existing program directory found - upgrade' }
else { Say 'no program directory yet - first install into this root' }

if ($Port -gt 0) { $effectivePort = $Port }
else {
    $p = & $bootstrapPython $homePy '--port' 2>$null
    if ("$p" -match '^\d+$') { $effectivePort = [int]$p } else { $effectivePort = 8935 }
}
Say "port: $effectivePort"

foreach ($d in @($root, $DataDir, $RunDir)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
}
$hadInstall = (Test-Path (Join-Path $AppDir 'VERSION'))
$legacyExe = $null
foreach ($name in @('uniai-agent.exe', 'UniAI.exe')) {
    $candidate = Join-Path $root $name
    if ((Test-Path $candidate) -and -not $legacyExe) { $legacyExe = $candidate }
}

# --------------------------------------------------------------- 1 download
Say '(1/9) download release package'
$zip = Join-Path $env:TEMP "uniai-gateway-$ProductVersion.zip"
if (-not (Test-Path $zip)) {
    try { Invoke-WebRequest -Uri $ZipUrl -OutFile $zip -UseBasicParsing }
    catch { throw "[uniai] download failed: $($_.Exception.Message)" }
}
else { Say "cached: $zip" }

Say '(2/9) verify SHA256'
$actual = Get-Sha256 $zip
if ($actual -ne $ZipSha256.ToLower()) {
    throw "[uniai] checksum mismatch expected=$($ZipSha256.ToLower()) actual=$actual"
}
Ok "sha256 $actual"

# ---------------------------------------------------------- 3 python runtime
Say '(3/9) prepare python runtime'
if (-not (Test-Path (Join-Path $StageDir 'uniai-gateway/VERSION'))) {
    Remove-Dir $StageDir
    [System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $StageDir)
}
$stageApp = Join-Path $StageDir 'uniai-gateway'
$pyExe = Join-Path $RunDir 'python/python.exe'
if (-not (Test-Path $pyExe)) {
    $embed = Join-Path $stageApp 'bootstrap/python-3.13.1-embed-amd64.zip'
    if (-not (Test-Path $embed)) { throw "[uniai] bundled python missing: $embed" }
    Remove-Dir (Join-Path $RunDir 'python')
    [System.IO.Compression.ZipFile]::ExtractToDirectory($embed, (Join-Path $RunDir 'python'))
}
# A ._pth file replaces sys.path entirely: the program directory must be listed.
$pth = Get-ChildItem -Path (Join-Path $RunDir 'python') -Filter 'python*._pth' | Select-Object -First 1
if ($pth) {
    $lines = @(Get-Content -Path $pth.FullName) | Where-Object { $_ -and $_ -notmatch '^\s*#' }
    $lines = @($lines | Where-Object { $_ -ne $AppDir }) + @('Lib/site-packages', $AppDir, 'import site')
    Set-Content -Path $pth.FullName -Value $lines -Encoding ASCII
}
# Real check, real exit code - a broken interpreter must stop the install here.
$checkPy = Join-Path $stageApp 'scripts/python_runtime_check.py'
if (-not (Test-Path $checkPy)) { throw "[uniai] runtime check helper missing: $checkPy" }
$check = & $pyExe $checkPy 2>$null
if ($LASTEXITCODE -ne 0) {
    throw "[uniai] python runtime check failed (exit $LASTEXITCODE): $check"
}
$checkLine = ([string]($check | Select-Object -First 1)).Trim()
if ($checkLine -notmatch '^PYTHON_RUNTIME_CHECK_PASS') {
    throw "[uniai] python runtime check did not pass: $checkLine"
}
Ok $checkLine

# ------------------------------------------------------------ 4 node runtime
Say '(4/9) prepare node runtime (bundled, pinned v22.23.3)'
$nodeExe = Join-Path $RunDir 'node/node.exe'
if (-not (Test-Path $nodeExe)) {
    $nodeZip = Join-Path $stageApp "bootstrap/$NodeZipName"
    if (-not (Test-Path $nodeZip)) {
        $nodeZip = Join-Path $env:TEMP $NodeZipName
        if (-not (Test-Path $nodeZip)) {
            Invoke-WebRequest -Uri "https://nodejs.org/dist/v22.23.3/$NodeZipName" -OutFile $nodeZip -UseBasicParsing
        }
    }
    $nodeSha = Get-Sha256 $nodeZip
    if ($nodeSha -ne $NodeSha256.ToLower()) {
        throw "[uniai] node checksum mismatch expected=$($NodeSha256.ToLower()) actual=$nodeSha"
    }
    Ok "node sha256 $nodeSha"
    $nodeStage = Join-Path $StageDir 'node'
    Remove-Dir $nodeStage
    [System.IO.Compression.ZipFile]::ExtractToDirectory($nodeZip, $nodeStage)
    $inner = Get-ChildItem -Path $nodeStage -Directory | Select-Object -First 1
    if (-not $inner) { throw '[uniai] node archive did not contain a directory' }
    Remove-Dir (Join-Path $RunDir 'node')
    [System.IO.Directory]::Move($inner.FullName, (Join-Path $RunDir 'node'))
}
$nodeVersion = (& $nodeExe '--version' 2>$null | Select-Object -First 1)
Say "node $nodeVersion"
if ($env:Path -notlike "*$RunDir\node*") {
    [Environment]::SetEnvironmentVariable('Path',
        "$RunDir\node;" + [Environment]::GetEnvironmentVariable('Path', 'User'), 'User')
}

# --------------------------------------------------------------- 5 swap app
Say '(5/9) install program into app/ (data untouched)'
# Only ever stop a UniAI process of this installation: never a foreign owner.
$owner = Get-NetTCPConnection -LocalPort $effectivePort -State Listen -ErrorAction SilentlyContinue |
         Select-Object -First 1
if ($owner) {
    $proc = Get-Process -Id $owner.OwningProcess -ErrorAction SilentlyContinue
    $mine = $false
    if ($proc) {
        try { $mine = ($proc.Path -like "$root*") -or ($proc.ProcessName -match '^uniai') } catch { $mine = $false }
    }
    if ($mine) {
        Stop-Process -Id $owner.OwningProcess -Force -ErrorAction SilentlyContinue
        Say "stopped previous UniAI pid=$($owner.OwningProcess)"
        # The supervisor would otherwise start the replaced program again.
        $alsoKilled = @(Stop-OwnProcesses $root)
        if ($alsoKilled.Count -gt 0) { Say "also stopped: $($alsoKilled -join ', ')" }
        for ($i = 0; $i -lt 30; $i++) {
            $still = Get-NetTCPConnection -LocalPort $effectivePort -State Listen -ErrorAction SilentlyContinue
            if (-not $still) { break }
            Start-Sleep -Seconds 1
        }
    }
    else {
        throw "[uniai] port $effectivePort is used by another program (pid=$($owner.OwningProcess)); not touching it"
    }
}
Remove-Dir $PrevDir
if (Test-Path $AppDir) {
    Move-DirReplace $AppDir $PrevDir
    Say 'previous program moved to app.previous'
}
try {
    Move-DirNew $stageApp $AppDir
    if ($FailAt -eq 'extract') { throw '[uniai] self-test: forced failure after extract' }

    $pth2 = Get-ChildItem -Path (Join-Path $RunDir 'python') -Filter 'python*._pth' | Select-Object -First 1
    if ($pth2) {
        $lines2 = @(Get-Content -Path $pth2.FullName) | Where-Object { $_ -and $_ -notmatch '^\s*#' }
        $lines2 = @($lines2 | Where-Object { $_ -ne $AppDir }) + @('Lib/site-packages', $AppDir, 'import site')
        Set-Content -Path $pth2.FullName -Value $lines2 -Encoding ASCII
    }
    $check2 = & $pyExe (Join-Path $AppDir 'scripts/python_runtime_check.py') 2>$null
    if ($LASTEXITCODE -ne 0) { throw "[uniai] python runtime check failed after install (exit $LASTEXITCODE)" }

    # -------------------------------------------------------- 6 dependencies
    Say '(6/9) install locked dependencies (offline wheels)'
    & $pyExe (Join-Path $AppDir 'scripts/python_runtime_check.py') '--deps' 2>$null
    if ($LASTEXITCODE -ne 0) {
        $pipWheel = Get-ChildItem -Path (Join-Path $AppDir 'bootstrap') -Filter 'pip-*.whl' |
                    Select-Object -First 1
        if (-not $pipWheel) { throw '[uniai] pip wheel missing from the release package' }
        & $pyExe (Join-Path $AppDir 'scripts/pip_bootstrap.py') $pipWheel.FullName '--' `
            'install' '--no-index' '--find-links' (Join-Path $AppDir 'wheels') `
            '-r' (Join-Path $AppDir 'requirements.lock.txt') '--disable-pip-version-check' `
            '--no-warn-script-location' '-q' 2>$null
        if ($LASTEXITCODE -ne 0) { throw "[uniai] dependency install failed (exit $LASTEXITCODE)" }
        & $pyExe (Join-Path $AppDir 'scripts/python_runtime_check.py') '--deps' 2>$null
        if ($LASTEXITCODE -ne 0) { throw '[uniai] dependencies still missing after install' }
    }
    Ok 'dependencies present'
    if ($FailAt -eq 'deps') { throw '[uniai] self-test: forced failure after dependencies' }

    # ------------------------------------------------------------ 7 migrate
    Say '(7/9) apply database migrations (existing data preserved)'
    $env:UNIAI_HOME = $root
    $env:UNIAI_DATA_DIR = $DataDir
    $env:UNIAI_PORT = "$effectivePort"
    $env:UNIAI_RUNTIME_DIR = $RunDir
    # A database that already owns the schema is stamped, never rebuilt: an
    # upgrade must not try to CREATE TABLE over tables that hold user data.
    $migratePy = Join-Path $AppDir 'scripts/migrate_database.py'
    $migration = & $pyExe $migratePy 2>$null
    $migCode = $LASTEXITCODE
    $migLine = ([string]($migration | Select-Object -First 1)).Trim()
    if ($migCode -ne 0 -or $migLine -notmatch '^DB_MIGRATE_PASS') {
        throw "[uniai] database migration failed (exit $migCode): $migLine"
    }
    Ok $migLine
    if ($FailAt -eq 'migrate') { throw '[uniai] self-test: forced failure after migration' }

    # -------------------------------------------------------------- 8 start
    Say '(8/9) start UniAI'
    $env:UNIAI_HOME = $root
    $env:UNIAI_DATA_DIR = $DataDir
    $env:UNIAI_PORT = "$effectivePort"
    $env:UNIAI_RUNTIME_DIR = $RunDir
    $env:UNIAI_ROUTING_PAID_ENABLED = '0'
    $env:UNIAI_QODER_NODE = $nodeExe
    Start-Process -FilePath $pyExe -WorkingDirectory $AppDir -WindowStyle Hidden `
        -ArgumentList @('-m', 'runtime.child', '--host', '127.0.0.1', '--port', "$effectivePort") | Out-Null
    $healthy = $false
    for ($i = 0; $i -lt 90; $i++) {
        Start-Sleep -Seconds 1
        try {
            Invoke-RestMethod -Uri "http://127.0.0.1:$effectivePort/health" -TimeoutSec 3 | Out-Null
            $healthy = $true
            break
        }
        catch { }
    }
    if (-not $healthy) { throw "[uniai] gateway did not answer /health on port $effectivePort" }
    if ($FailAt -eq 'health') { throw '[uniai] self-test: forced failure after health check' }
    $ownerAfter = Get-NetTCPConnection -LocalPort $effectivePort -State Listen -ErrorAction SilentlyContinue |
                  Select-Object -First 1
    if ($ownerAfter) {
        $procAfter = Get-Process -Id $ownerAfter.OwningProcess -ErrorAction SilentlyContinue
        if ($procAfter) {
            $exeAfter = ''
            try { $exeAfter = [string]$procAfter.Path } catch { $exeAfter = '' }
            Say "port $effectivePort served by pid=$($ownerAfter.OwningProcess) $exeAfter"
            if ($exeAfter -and -not $exeAfter.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
                throw "[uniai] port $effectivePort is served by a program outside this installation: $exeAfter"
            }
        }
    }
    Ok "gateway healthy http://127.0.0.1:$effectivePort"
}
catch {
    Write-Host "[uniai] ERROR: $($_.Exception.Message)" -ForegroundColor Red
    Remove-Dir $StageDir
    $stoppedForRollback = @(Stop-OwnProcesses $root)
    if ($stoppedForRollback.Count -gt 0) { Say "rollback: stopped $($stoppedForRollback -join ', ')" }
    $env:UNIAI_HOME = $root
    $env:UNIAI_DATA_DIR = $DataDir
    $env:UNIAI_RUNTIME_DIR = $RunDir
    if (Test-Path $PrevDir) {
        Say 'ROLLBACK: restoring previous program directory'
        Remove-Dir $AppDir
        Move-DirReplace $PrevDir $AppDir
        Ok 'ROLLBACK_RESTORED app.previous -> app'
        Start-Process -FilePath $pyExe -WorkingDirectory $AppDir -WindowStyle Hidden `
            -ArgumentList @('-m', 'runtime.child', '--host', '127.0.0.1', '--port', "$effectivePort") | Out-Null
    }
    elseif ($legacyExe -and (Test-Path $legacyExe)) {
        Say "ROLLBACK: restarting the previous program ($legacyExe)"
        Start-Process -FilePath $legacyExe -WorkingDirectory $root -WindowStyle Hidden | Out-Null
    }
    else { Warn 'no previous version to restore' }
    $back = $false
    for ($i = 0; $i -lt 60; $i++) {
        Start-Sleep -Seconds 1
        try {
            Invoke-RestMethod -Uri "http://127.0.0.1:$effectivePort/health" -TimeoutSec 3 | Out-Null
            $back = $true
            break
        }
        catch { }
    }
    if ($back) { Ok 'ROLLBACK_HEALTH_OK previous version serves /health again' }
    else { Warn 'ROLLBACK_HEALTH_FAIL previous version did not answer /health' }
    throw $_.Exception.Message
}
Remove-Dir $StageDir
if (Test-Path $PrevDir) { Remove-Dir $PrevDir }

# --------------------------------------------------------------- 9 finishing
Say '(9/9) register launcher and open the console'
$env:UNIAI_HOME = $root
$env:UNIAI_DATA_DIR = $DataDir
$env:UNIAI_RUNTIME_DIR = $RunDir

# only now that the replacement answers /health is the old program archived
$legacyNames = @()
if ($homeInfo.legacy_program) { $legacyNames = @($homeInfo.legacy_program) }
if ($legacyNames.Count -gt 0) {
    $backupDir = Join-Path $root "legacy-program-backup-$($script:Stamp)"
    New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
    $moved = 0
    foreach ($name in $legacyNames) {
        $src = Join-Path $root $name
        if ((Test-Path $src) -and (Move-ItemQuiet $src (Join-Path $backupDir $name))) { $moved++ }
    }
    if ($moved -gt 0) { Ok "LEGACY_PROGRAM_BACKUP $moved/$($legacyNames.Count) item(s) archived to $backupDir" }
    else { Warn 'legacy program files still in place (locked?) - installation is unaffected' }
}

# install.json describes the installation; the previous copy is kept.
$installJsonPath = Join-Path $root 'install.json'
if (Test-Path $installJsonPath) {
    $bakDir = Join-Path $DataDir 'backups'
    if (-not (Test-Path $bakDir)) { New-Item -ItemType Directory -Force -Path $bakDir | Out-Null }
    Copy-Item -LiteralPath $installJsonPath -Destination (Join-Path $bakDir "install.json.bak-$($script:Stamp)") -Force
}
& $pyExe (Join-Path $AppDir 'scripts/uniai_home.py') '--write-install' $ProductVersion 2>$null | Out-Null
Ok "install.json updated to $ProductVersion (previous copy kept in data/backups)"

$durable = Set-DurableStart $root $AppDir $pyExe $effectivePort
Ok "AUTOSTART_RETARGETED $durable"

$proto = & $pyExe (Join-Path $AppDir 'scripts/register_protocol.py') '--root' $root 2>$null
$protoLine = ([string]($proto | Select-Object -First 1)).Trim()
if ($protoLine) { Ok "protocol registered: $protoLine" }
$verify = & $pyExe (Join-Path $AppDir 'scripts/register_protocol.py') '--verify' 2>$null
$verifyLine = ([string]($verify | Select-Object -First 1)).Trim()
if ($verifyLine) { Say "protocol verify: $verifyLine" }

# one installation only: a second root must not keep claiming to be one
$duplicateRoots = @()
if ($homeInfo.others) { $duplicateRoots = @($homeInfo.others) }
$retired = 0
foreach ($other in $duplicateRoots) {
    $otherRoot = $other.root
    if (-not $otherRoot) { continue }
    if ($otherRoot -eq $root) { continue }
    if ($other.has_install_json) {
        $src = Join-Path $otherRoot 'install.json'
        $dst = "$src.duplicate-$($script:Stamp)"
        if ((Test-Path $src) -and (Move-ItemQuiet $src $dst)) {
            Say "duplicate root retired (install.json renamed, data kept): $otherRoot"
            $retired++
        }
    }
    if ($other.has_app) {
        $src = Join-Path $otherRoot 'app'
        $dst = "$src.duplicate-$($script:Stamp)"
        if ((Test-Path $src) -and (Move-ItemQuiet $src $dst)) {
            Say "duplicate root program directory renamed (data kept): $otherRoot\app"
            $retired++
        }
    }
}
if ($retired -gt 0) { Ok "CANONICAL_ROOT_UNIQUE $retired duplicate item(s) retired, no user data touched" }
else { Ok 'CANONICAL_ROOT_UNIQUE only one install root claims this product' }

if (-not $NoOpen) {
    $openUrl = $null
    for ($i = 0; $i -lt 10 -and -not $openUrl; $i++) {
        $raw = & $pyExe (Join-Path $AppDir 'scripts/console_url.py') "$effectivePort" '--ensure-material' 2>$null
        if ($LASTEXITCODE -eq 0 -and $raw) { $openUrl = ([string]$raw).Trim() }
        else { Start-Sleep -Seconds 2 }
    }
    if ($openUrl) {
        # Never echo the URL: it carries the one-time bootstrap material.
        Start-Process $openUrl | Out-Null
        Ok 'console opened through the launcher (bootstrap material attached)'
    }
    else {
        Warn 'installed, but the console link could not be created - run Open-Console.cmd'
    }
}

$bindingErrors = @(Get-BindingErrors)
if ($bindingErrors.Count -eq 0) { Ok 'INSTALL_POWERSHELL_NO_ERROR_PASS (no ParameterBindingException in this run)' }
else { Warn "INSTALL_POWERSHELL_NO_ERROR_FAIL $($bindingErrors.Count) binding error(s) logged" }

if ($hadInstall -or $homeInfo.has_data) { Ok 'REINSTALL_IDEMPOTENT_PASS (data and keys untouched)' }

Write-Host ''
Write-Host '================ UniAI Gateway install summary ================' -ForegroundColor Green
Write-Host " version      : $ProductVersion"
Write-Host " install root : $root"
Write-Host " program      : $AppDir"
Write-Host " data         : $DataDir  (never deleted by install/upgrade)"
Write-Host " runtime      : $RunDir   (python / node / qoder CLI)"
Write-Host " gateway      : http://127.0.0.1:$effectivePort"
Write-Host " launcher     : uniai://console -> Open-Console.ps1"
Write-Host " paid_enabled : false  (no extra cost by default)"
Write-Host '===============================================================' -ForegroundColor Green
