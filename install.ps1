#Requires -Version 5.1
<#
    UniAI Gateway - one-line installer for Windows (no Python / Node / Git needed).

    Guarantees enforced here (V1 RC2):
      * the main package is verified by SHA256 before anything is touched;
      * Node ships inside the same verified package - no un-pinned download;
      * program (app) and user data live in different directories and an
        upgrade NEVER deletes data;
      * running this twice is safe and verifiable (REINSTALL_IDEMPOTENT_PASS);
      * any failure after the app is swapped restores app.previous and proves
        the previous version still serves /health.

    Layout:
      <InstallDir>\app        program files (replaceable)
      <InstallDir>\app.previous  previous program files (rollback source)
      <InstallDir>\data       database, keys, vault, logs  (never deleted here)
      <InstallDir>\runtime    python / node / qoder CLI    (persistent)

    Run it with (one line):
      irm https://buer5460.github.io/uniai-gateway-setup/install.ps1 | iex
#>
param(
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'UniAI'),
    [int]$Port = 8935,
    [switch]$SkipQoder,
    [switch]$SkipZCode,
    # Self-test hook only: force a failure right after the given stage so the
    # rollback path can be exercised end to end. Never used in normal installs.
    [ValidateSet('', 'deps', 'migrate', 'health')]
    [string]$FailAt = ''
)

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

$ProductVersion = '1.0.0-rc3'
$ZipUrl = 'https://github.com/Buer5460/uniai-gateway-setup/releases/download/v1.0.0-rc3/uniai-gateway-1.0.0-rc3-windows-x64.zip'
$ZipSha256 = '2728e9d407f8975765299eadcd614117e957656b79413325a17ea5cb332c2776'
$NodeZipName = 'node-v22.23.3-win-x64.zip'
$NodeSha256 = '2b0ff57b049cda1bbcea2240eec20467018713c1efe1f7360c2681859b90ed71'

$AppDir = Join-Path $InstallDir 'app'
$PrevDir = Join-Path $InstallDir 'app.previous'
$DataDir = Join-Path $InstallDir 'data'
$RunDir = Join-Path $InstallDir 'runtime'
$StageDir = Join-Path $InstallDir '_stage'

function Say($msg) { Write-Host "[uniai] $msg" }
function Ok($msg) { Write-Host "[uniai] OK: $msg" -ForegroundColor Green }
function Warn($msg) { Write-Host "[uniai] $msg" -ForegroundColor Yellow }

Add-Type -AssemblyName System.IO.Compression.FileSystem

function Remove-Dir([string]$path) {
    if (Test-Path $path) { [System.IO.Directory]::Delete($path, $true) }
}

function Get-Sha256([string]$path) {
    return (Get-FileHash -Path $path -Algorithm SHA256).Hash.ToLower()
}

function Start-Gateway([string]$app, [int]$healthTimeout = 90) {
    $py = Join-Path $RunDir 'python/python.exe'
    if (-not (Test-Path $py)) { return $false }
    $env:UNIAI_DATA_DIR = $DataDir
    $env:UNIAI_PORT = "$Port"
    $env:UNIAI_ROUTING_PAID_ENABLED = '0'
    $nodeExe = Join-Path $RunDir 'node/node.exe'
    if (Test-Path $nodeExe) { $env:UNIAI_QODER_NODE = $nodeExe }
    $env:UNIAI_RUNTIME_DIR = $RunDir
    Start-Process -FilePath $py -WorkingDirectory $app -WindowStyle Hidden `
        -ArgumentList @('-m', 'runtime.child', '--host', '127.0.0.1', '--port', "$Port") | Out-Null
    for ($i = 0; $i -lt $healthTimeout; $i++) {
        Start-Sleep -Seconds 1
        try {
            Invoke-RestMethod -Uri "http://127.0.0.1:$Port/health" -TimeoutSec 3 | Out-Null
            return $true
        }
        catch { }
    }
    return $false
}

function Move-DirReplace([string]$src, [string]$dst) {
    if (-not (Test-Path $src)) { throw "[uniai] move source missing: $src" }
    for ($i = 0; $i -lt 15; $i++) {
        try {
            Remove-Dir $dst
            [System.IO.Directory]::Move($src, $dst)
            return
        }
        catch { Start-Sleep -Seconds 2 }
    }
    throw "[uniai] cannot move '$src' -> '$dst' (still in use?)"
}

function Move-DirNew([string]$src, [string]$dst) {
    if (Test-Path $dst) { throw "[uniai] destination already exists: $dst" }
    for ($i = 0; $i -lt 15; $i++) {
        try {
            [System.IO.Directory]::Move($src, $dst)
            return
        }
        catch { Start-Sleep -Seconds 2 }
    }
    throw "[uniai] cannot move '$src' -> '$dst' (still in use?)"
}

function Get-GatewayPid {
    $pidFile = Join-Path $DataDir 'run/uniai.pid'
    if (-not (Test-Path $pidFile)) { return $null }
    $raw = (Get-Content $pidFile -Raw).Trim()
    if ($raw -like '*{*') {
        try { return [int](($raw | ConvertFrom-Json).pid) } catch { return $null }
    }
    try { return [int]$raw } catch { return $null }
}

function Wait-PortFree([int]$probePort, [int]$seconds = 40) {
    for ($i = 0; $i -lt $seconds; $i++) {
        $busy = $false
        $client = New-Object System.Net.Sockets.TcpClient
        try { $client.Connect('127.0.0.1', $probePort); $busy = $true } catch { $busy = $false }
        finally { try { $client.Close() } catch { } }
        if (-not $busy) { return $true }
        Start-Sleep -Seconds 1
    }
    return $false
}

function Stop-Gateway {
    # The runtime writes a JSON pid file; older builds wrote a bare number.
    $procId = Get-GatewayPid
    if ($procId) {
        Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue
        Say "stopped previous gateway pid=$procId"
    }
    Start-Sleep -Seconds 1
    # Leftover children of our own interpreter hold locks on the app directory.
    Get-Process python, pythonw -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            if ($_.Path -and $_.Path.StartsWith((Join-Path $RunDir 'python'))) {
                Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
                Say "stopped stray interpreter pid=$($_.Id)"
            }
        }
        catch { }
    }
    if (Wait-PortFree $Port) { Say "port $Port free" }
    else { Warn "port $Port still busy - the copy may fail" }
}

function Restore-Previous {
    Say 'ROLLBACK: restoring previous program directory'
    Remove-Dir $AppDir
    Move-DirReplace $PrevDir $AppDir
    Ok 'ROLLBACK_RESTORED app.previous -> app'
    if (Start-Gateway $AppDir 60) { Ok 'ROLLBACK_HEALTH_OK previous version serves /health again' }
    else { Warn 'ROLLBACK_HEALTH_FAIL previous version did not answer /health' }
}

# --------------------------------------------------------------- 0 layout
Say "UniAI Gateway $ProductVersion installer"
foreach ($d in @($InstallDir, $DataDir, $RunDir)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
}
$hadInstall = Test-Path (Join-Path $AppDir 'VERSION')
if ($hadInstall) { Say "existing installation detected in $AppDir (data stays untouched)" }
else { Say 'no existing installation - clean install' }

# --------------------------------------------------------------- 1 download
Say '(1/9) download release package'
$zip = Join-Path $env:TEMP "uniai-gateway-$ProductVersion.zip"
if (-not (Test-Path $zip)) {
    Say "url: $ZipUrl"
    try { Invoke-WebRequest -Uri $ZipUrl -OutFile $zip -UseBasicParsing }
    catch { Remove-Dir $StageDir; throw "[uniai] download failed: $($_.Exception.Message)" }
}
else { Say "cached: $zip" }

Say '(2/9) verify SHA256'
$actual = Get-Sha256 $zip
if ($actual -ne $ZipSha256.ToLower()) {
    Remove-Dir $StageDir
    throw "[uniai] checksum mismatch expected=$($ZipSha256.ToLower()) actual=$actual"
}
Ok "sha256 $actual"

# ---------------------------------------------------------- 3 python runtime
Say '(3/9) prepare python runtime'
$pyExe = Join-Path $RunDir 'python/python.exe'
if (-not (Test-Path $pyExe)) {
    $stageBundle = Join-Path $StageDir 'uniai-gateway/bootstrap'
    $bundleDir = if (Test-Path $stageBundle) { $stageBundle }
                 elseif ($hadInstall) { Join-Path $AppDir 'bootstrap' }
                 else { $null }
    if (-not $bundleDir) {
        # nothing extracted yet: peek inside the verified zip for the bundles.
        Remove-Dir $StageDir
        [System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $StageDir)
        $bundleDir = Join-Path $StageDir 'uniai-gateway/bootstrap'
    }
    $embed = Join-Path $bundleDir 'python-3.13.1-embed-amd64.zip'
    if (-not (Test-Path $embed)) { throw "[uniai] bundled python missing: $embed" }
    $pyDst = Join-Path $RunDir 'python'
    Remove-Dir $pyDst
    [System.IO.Compression.ZipFile]::ExtractToDirectory($embed, $pyDst)
}
& $pyExe -c 'import sys;print("[uniai] python "+sys.version.split()[0])'

# ------------------------------------------------------------ 4 node runtime
Say '(4/9) prepare node runtime (bundled, pinned v22.23.3)'
$nodeExe = Join-Path $RunDir 'node/node.exe'
if (-not (Test-Path $nodeExe)) {
    $nodeZip = $null
    foreach ($candidate in @((Join-Path $StageDir "uniai-gateway/bootstrap/$NodeZipName"),
                             (Join-Path $AppDir "bootstrap/$NodeZipName"))) {
        if (Test-Path $candidate) { $nodeZip = $candidate; break }
    }
    $downloaded = $false
    if (-not $nodeZip) {
        $nodeZip = Join-Path $env:TEMP $NodeZipName
        if (-not (Test-Path $nodeZip)) {
            Say "bundled node missing - downloading pinned $NodeZipName"
            Invoke-WebRequest -Uri "https://nodejs.org/dist/v22.23.3/$NodeZipName" -OutFile $nodeZip -UseBasicParsing
            $downloaded = $true
        }
    }
    $nodeSha = Get-Sha256 $nodeZip
    if ($nodeSha -ne $NodeSha256.ToLower()) {
        throw "[uniai] node checksum mismatch expected=$($NodeSha256.ToLower()) actual=$nodeSha"
    }
    Ok "node sha256 $nodeSha$(if ($downloaded) { ' (downloaded)' } else { ' (bundled)' })"
    $nodeStage = Join-Path $StageDir 'node'
    Remove-Dir $nodeStage
    [System.IO.Compression.ZipFile]::ExtractToDirectory($nodeZip, $nodeStage)
    $inner = Get-ChildItem -Path $nodeStage -Directory | Select-Object -First 1
    Remove-Dir (Join-Path $RunDir 'node')
    [System.IO.Directory]::Move($inner.FullName, (Join-Path $RunDir 'node'))
}
& $nodeExe --version | ForEach-Object { Say "node $_" }
if (($env:Path -notlike "*$RunDir\node*")) {
    [Environment]::SetEnvironmentVariable(
        'Path', "$RunDir\node;" + [Environment]::GetEnvironmentVariable('Path', 'User'), 'User')
}

# -------------------------------------------------------------- 5 swap app
Say '(5/9) install program into app/ (data untouched)'
Stop-Gateway
Remove-Dir $PrevDir
if (Test-Path $AppDir) {
    Move-DirReplace $AppDir $PrevDir
    Say 'previous program moved to app.previous'
}
# Reuse the staging tree when the bootstrap step already unpacked the zip.
if (-not (Test-Path (Join-Path $StageDir 'uniai-gateway/VERSION'))) {
    Remove-Dir $StageDir
    [System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $StageDir)
}
try {
    $src = Join-Path $StageDir 'uniai-gateway'
    if (-not (Test-Path (Join-Path $src 'VERSION'))) { throw '[uniai] package layout unexpected' }
    if ($FailAt -eq 'extract') { throw '[uniai] self-test: forced failure after extract' }
    Move-DirNew $src $AppDir
    Remove-Dir $StageDir

    # A ._pth file replaces sys.path entirely: the application root must be
    # listed explicitly or `python -m runtime.child` cannot find the package.
    $pth = Get-ChildItem -Path (Join-Path $RunDir 'python') -Filter 'python*._pth' |
           Select-Object -First 1
    if ($pth) {
        $lines = @(Get-Content -Path $pth.FullName) | Where-Object { $_ -and $_ -notmatch '^\s*#' }
        $lines = @($lines | Where-Object { $_ -ne $AppDir }) +
                 @('Lib/site-packages', $AppDir, 'import site')
        Set-Content -Path $pth.FullName -Value $lines -Encoding ASCII
    }

    # -------------------------------------------------------- 6 dependencies
    Say '(6/9) install locked dependencies (offline wheels)'
    $pipWheel = Get-ChildItem -Path (Join-Path $AppDir 'bootstrap') -Filter 'pip-*.whl' |
                Select-Object -First 1
    & $pyExe -c 'import fastapi, httpx, alembic' 2>$null
    if ($LASTEXITCODE -ne 0) {
        $pipArgs = @('install', '--no-index', '--find-links', (Join-Path $AppDir 'wheels'),
                     '-r', (Join-Path $AppDir 'requirements.lock.txt'),
                     '--disable-pip-version-check', '--no-warn-script-location', '-q')
        & $pyExe -c "import sys;sys.path.insert(0,r'$($pipWheel.FullName)');from pip._internal.cli.main import main;sys.exit(main(sys.argv[1:]))" @pipArgs 2>$null
        if ($LASTEXITCODE -ne 0) { throw "[uniai] dependency install failed (exit $LASTEXITCODE)" }
    }
    if ($FailAt -eq 'deps') { throw '[uniai] self-test: forced failure after dependencies' }

    # ------------------------------------------------------------ 7 migrate
    Say '(7/9) apply database migrations (existing data preserved)'
    $env:UNIAI_DATA_DIR = $DataDir
    $env:UNIAI_PORT = "$Port"
    Push-Location $AppDir
    & $pyExe -m alembic upgrade head 2>$null
    $migCode = $LASTEXITCODE
    Pop-Location
    if ($migCode -ne 0) { throw "[uniai] database migration failed (exit $migCode)" }
    if ($FailAt -eq 'migrate') { throw '[uniai] self-test: forced failure after migration' }

    # -------------------------------------------------------------- 8 start
    Say '(8/9) start UniAI'
    $healthy = Start-Gateway $AppDir
    if (-not $healthy) { throw "[uniai] gateway did not answer /health on port $Port" }
    if ($FailAt -eq 'health') { throw '[uniai] self-test: forced failure after health check' }
    Ok "gateway healthy http://127.0.0.1:$Port"
}
catch {
    Write-Host "[uniai] ERROR: $($_.Exception.Message)" -ForegroundColor Red
    Remove-Dir $StageDir
    if (Test-Path $PrevDir) { Restore-Previous }
    else { Write-Host '[uniai] no previous version to restore' -ForegroundColor Yellow }
    throw $_.Exception.Message
}
if (Test-Path $PrevDir) { Remove-Dir $PrevDir }

# ------------------------------------------------------------ 9 first use
Say '(9/9) detect Qoder and ZCode'
$headers = @{ 'Origin' = "http://127.0.0.1:$Port" }
$adminKey = $null
$tokenFile = Join-Path $DataDir 'run/bootstrap.token'
for ($i = 0; $i -lt 30 -and -not (Test-Path $tokenFile); $i++) { Start-Sleep -Seconds 1 }
$bootstrapState = $null
try {
    $bootstrapState = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/api/bootstrap" -Headers $headers -TimeoutSec 15
}
catch { }
if (Test-Path $tokenFile -and $bootstrapState -and -not $bootstrapState.initialized) {
    try {
        $material = Get-Content -Path $tokenFile -Raw | ConvertFrom-Json
        $claimHeaders = @{ 'Origin' = "http://127.0.0.1:$Port"; 'Content-Type' = 'application/json' }
        $claimed = Invoke-RestMethod -Method Post -Uri "http://127.0.0.1:$Port/api/bootstrap" `
                                     -Headers $claimHeaders `
                                     -Body (@{ bootstrap_token = $material.token } | ConvertTo-Json)
        $adminKey = $claimed.console_key
    }
    catch { Say "admin claim: $($_.Exception.Message)" }
}
if (-not $adminKey) { Say 'no new admin key claimed (browser session will)' }
else { $headers['Authorization'] = "Bearer $adminKey" }

# Every user-facing entry point comes from one helper: the gateway already
# knows its port, and it refuses to answer unless the service is healthy.
$consoleUrl = $null
$openScript = Join-Path $AppDir 'scripts/console_url.py'
for ($i = 0; $i -lt 10 -and -not $consoleUrl; $i++) {
    $raw = & $pyExe $openScript "$Port" 2>$null
    if ($LASTEXITCODE -eq 0 -and $raw) { $consoleUrl = ([string]$raw).Trim() }
    else { Start-Sleep -Seconds 2 }
}
if (-not $consoleUrl) {
    # Fall back to the local helper so the user still gets the right URL even
    # if the packaged helper cannot resolve the port from here.
    $consoleUrl = "http://127.0.0.1:$Port/console/#/"
}
if ($healthy) {
    if ($consoleUrl) { Start-Process $consoleUrl | Out-Null; Ok "console opened: $consoleUrl" }
}
else {
    Warn 'UniAI installed, but the service did not answer /health - start UniAI and open the console again.'
}
Say "console url: $consoleUrl"

$state = $null
if ($adminKey) {
    try { $state = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/api/setup/state" -Headers $headers -TimeoutSec 20 }
    catch { Say "setup state: $($_.Exception.Message)" }
}

if (-not $SkipQoder -and $adminKey -and $state) {
    if ($state.qoder.cli_installed -and $state.qoder.logged_in) {
        Ok 'Qoder already connected (existing login preserved)'
    }
    else {
        Warn 'ACTION REQUIRED: finish the Qoder sign-in in your browser.'
        Say 'the console wizard starts the official OAuth page with one click'
    }
}

if (-not $SkipZCode -and $state -and $state.zcode -and -not $state.zcode.installed) {
    Warn 'ZCode not detected on this PC - UniAI install still succeeded'
    Say 'install ZCode, then press "re-detect" in the console'
}

if ($hadInstall) {
    $dbCount = @(Get-ChildItem -Path $DataDir -Filter '*.db' -File -ErrorAction SilentlyContinue).Count
    $checks = @{
        health          = $healthy
        data_present    = ($dbCount -gt 0)
        identity_kept   = [bool]($bootstrapState -and $bootstrapState.initialized)
    }
    $failed = @($checks.Keys | Where-Object { -not $checks[$_] })
    Say "reinstall checks: health=$($checks.health) data=$($checks.data_present) identity_kept=$($checks.identity_kept)"
    if ($failed.Count -eq 0) { Ok 'REINSTALL_IDEMPOTENT_PASS' }
    else { Warn "REINSTALL_IDEMPOTENT_FAIL: $($failed -join ', ')" }
}

Write-Host ''
Write-Host '================ UniAI Gateway install summary ================' -ForegroundColor Green
Write-Host " version      : $ProductVersion"
Write-Host " program      : $AppDir"
Write-Host " data         : $DataDir  (never deleted by install/upgrade)"
Write-Host " runtime      : $RunDir   (python / node / qoder CLI)"
Write-Host " gateway      : http://127.0.0.1:$Port"
Write-Host " open         : $consoleUrl"
Write-Host " paid_enabled : false  (no extra cost by default)"
Write-Host '===============================================================' -ForegroundColor Green
