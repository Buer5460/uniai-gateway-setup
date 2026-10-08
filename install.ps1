#Requires -Version 5.1
<#
    UniAI Gateway - one-line installer for Windows.

    Design constraints (V1 RC):
      * the user needs nothing preinstalled - no Python, no Node, no Git;
      * the package is verified by SHA256 before anything is extracted;
      * no interactive questions except the vendor's own OAuth page;
      * the installer never touches another product's running service.

    Run it with (one line):
      irm https://buer5460.github.io/uniai-gateway-setup/install.ps1 | iex
#>
param(
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'UniAI'),
    [int]$Port = 8935,
    [switch]$SkipQoder,
    [switch]$SkipZCode
)

# Native commands (python, pip) write progress to stderr; with 'Stop' that
# becomes a terminating error in Windows PowerShell 5.1. Every step below
# checks $LASTEXITCODE (or an HTTP health probe) explicitly instead.
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

$ProductVersion = '1.0.0-rc1'
$ZipUrl = 'https://github.com/Buer5460/uniai-gateway-setup/releases/download/v1.0.0-rc1/uniai-gateway-1.0.0-rc1-windows-x64.zip'
$ZipSha256 = 'e8997361dfb0aea7116ad1295edd885c428c5b3e74791ff64aa82fe9392bbfdb'
$NodeVersion = 'v22.23.3'
$NodeUrl = "https://nodejs.org/dist/$NodeVersion/node-$NodeVersion-win-x64.zip"

function Say($msg) { Write-Host "[uniai] $msg" }
function Fail($msg) { Write-Host "[uniai] ERROR: $msg" -ForegroundColor Red; exit 1 }
function Step($n, $msg) { Write-Host "[uniai] ($n/9) $msg" -ForegroundColor Cyan }

# ---------------------------------------------------------------- 1 download
Step 1 'download release package'
$zip = Join-Path $env:TEMP "uniai-gateway-$ProductVersion.zip"
if (-not (Test-Path $zip)) {
    Say "url: $ZipUrl"
    try { Invoke-WebRequest -Uri $ZipUrl -OutFile $zip -UseBasicParsing }
    catch { Fail "download failed: $($_.Exception.Message)" }
}
else { Say "cached: $zip" }

# ------------------------------------------------------------------ 2 verify
Step 2 'verify SHA256'
$actualSha = (Get-FileHash -Path $zip -Algorithm SHA256).Hash
if ($actualSha.ToLower() -ne $ZipSha256.ToLower()) {
    Fail "checksum mismatch`n  expected: $ZipSha256`n  actual:   $actualSha"
}
Say "sha256 ok: $actualSha"

# ----------------------------------------------------------------- 3 extract
Step 3 "install into $InstallDir"
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
Add-Type -AssemblyName System.IO.Compression.FileSystem
$target = Join-Path $InstallDir 'uniai-gateway'
if (Test-Path $target) { [System.IO.Directory]::Delete($target, $true) }
[System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $InstallDir)
$app = Join-Path $InstallDir 'uniai-gateway'
if (-not (Test-Path (Join-Path $app 'VERSION'))) { $app = $InstallDir }
Say "app dir: $app"

# ------------------------------------------------------------------ 4 python
Step 4 'prepare python runtime'
$py = Join-Path $app 'runtime/python/python.exe'
if (-not (Test-Path $py)) {
    $embed = Join-Path $app 'bootstrap/python-3.13.1-embed-amd64.zip'
    if (-not (Test-Path $embed)) { Fail "bundled python not found: $embed" }
    $pyDir = Join-Path $app 'runtime/python'
    if (Test-Path $pyDir) { [System.IO.Directory]::Delete($pyDir, $true) }
    [System.IO.Compression.ZipFile]::ExtractToDirectory($embed, $pyDir)
}
$pth = Get-ChildItem -Path (Join-Path $app 'runtime/python') -Filter 'python*._pth' |
       Select-Object -First 1
if ($pth) {
    # A ._pth file replaces sys.path entirely: the application root has to be
    # listed explicitly or `python -m runtime.child` cannot find the package.
    $lines = @(Get-Content -Path $pth.FullName) | Where-Object { $_ -and $_ -notmatch '^\s*#' }
    $lines = @($lines | Where-Object { $_ -ne $app }) + @('Lib/site-packages', $app, 'import site')
    Set-Content -Path $pth.FullName -Value $lines -Encoding ASCII
}
$pyVersion = (& $py -c 'import sys;print(sys.version.split()[0])').Trim()
Say "python: $pyVersion"

# ------------------------------------------------------------- 5 dependencies
Step 5 'install locked dependencies (offline wheels)'
$pipWheel = Get-ChildItem -Path (Join-Path $app 'bootstrap') -Filter 'pip-*.whl' |
            Select-Object -First 1
if (-not $pipWheel) { Fail 'bundled pip wheel missing' }
& $py -c 'import fastapi, httpx, alembic' 2>$null
$needDeps = ($LASTEXITCODE -ne 0)
if ($needDeps) {
    $pipArgs = @('install', '--no-index', '--find-links', (Join-Path $app 'wheels'),
                 '-r', (Join-Path $app 'requirements.lock.txt'),
                 '--disable-pip-version-check', '--no-warn-script-location', '-q')
    & $py -c "import sys;sys.path.insert(0,r'$($pipWheel.FullName)');from pip._internal.cli.main import main;sys.exit(main(sys.argv[1:]))" @pipArgs
    if ($LASTEXITCODE -ne 0) { Fail "dependency install failed (exit $LASTEXITCODE)" }
}
else { Say 'dependencies already present' }

# ------------------------------------------------------------------- 6 node
Step 6 'ensure node runtime (needed by the Qoder official CLI)'
$nodeCmd = Get-Command node -ErrorAction SilentlyContinue
if (-not $nodeCmd) {
    $nodeRoot = Join-Path $app 'runtime/node'
    $nodeExe = Join-Path $nodeRoot 'node.exe'
    if (-not (Test-Path $nodeExe)) {
        Say "downloading node $NodeVersion"
        $nodeZip = Join-Path $env:TEMP "node-$NodeVersion-win-x64.zip"
        try { Invoke-WebRequest -Uri $NodeUrl -OutFile $nodeZip -UseBasicParsing }
        catch { Fail "node download failed: $($_.Exception.Message)" }
        $staging = Join-Path $app 'runtime/_node_stage'
        if (Test-Path $staging) { [System.IO.Directory]::Delete($staging, $true) }
        [System.IO.Compression.ZipFile]::ExtractToDirectory($nodeZip, $staging)
        $inner = Get-ChildItem -Path $staging -Directory | Select-Object -First 1
        if ($inner) {
            if (Test-Path $nodeRoot) { [System.IO.Directory]::Delete($nodeRoot, $true) }
            [System.IO.Directory]::Move($inner.FullName, $nodeRoot)
        }
        if (Test-Path $staging) { [System.IO.Directory]::Delete($staging, $true) }
    }
    if (Test-Path (Join-Path $nodeRoot 'node.exe')) {
        $env:PATH = "$nodeRoot;$env:PATH"
        [Environment]::SetEnvironmentVariable('Path', "$nodeRoot;" + [Environment]::GetEnvironmentVariable('Path', 'User'), 'User')
        Say "node: $nodeRoot"
    }
    else { Say 'node not available; Qoder CLI install may need Node manually' }
}
else { Say "node: $($nodeCmd.Source)" }

# --------------------------------------------------------------- 7 db + start
Step 7 'initialise empty database and start UniAI'
$env:UNIAI_DATA_DIR = Join-Path $app 'data'
$env:UNIAI_PORT = "$Port"
$env:UNIAI_ROUTING_PAID_ENABLED = '0'
$logDir = Join-Path $app 'data/logs'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
Push-Location $app
try { & $py -m alembic upgrade head | Out-Null } catch { Say "migrate: $($_.Exception.Message)" }
Pop-Location
$errLog = Join-Path $logDir 'supervisor.log'
# No -Redirect*: Start-Process builds an environment dictionary that throws
# when a machine defines the same variable twice with different casing
# (http_proxy / HTTP_PROXY). The runtime writes its own logs under data/logs.
Start-Process -FilePath $py `
    -ArgumentList @('-m', 'runtime.child', '--host', '127.0.0.1', '--port', "$Port") `
    -WorkingDirectory $app -WindowStyle Hidden | Out-Null

$healthy = $false
for ($i = 0; $i -lt 90; $i++) {
    Start-Sleep -Seconds 1
    try {
        Invoke-RestMethod -Uri "http://127.0.0.1:$Port/health" -TimeoutSec 3 | Out-Null
        $healthy = $true
        break
    }
    catch { }
}
if (-not $healthy) { Fail "gateway did not start; see $errLog" }
Say "gateway healthy on http://127.0.0.1:$Port"

# ------------------------------------------------------------- 8 admin claim
$headers = @{ 'Origin' = "http://127.0.0.1:$Port" }
$adminKey = $null
$tokenFile = Join-Path $app 'data/run/bootstrap.token'
for ($i = 0; $i -lt 30 -and -not (Test-Path $tokenFile); $i++) { Start-Sleep -Seconds 1 }
if (Test-Path $tokenFile) {
    try {
        $material = Get-Content -Path $tokenFile -Raw | ConvertFrom-Json
        $body = @{ bootstrap_token = $material.token } | ConvertTo-Json
        $claimHeaders = @{ 'Origin' = "http://127.0.0.1:$Port"; 'Content-Type' = 'application/json' }
        $claimed = Invoke-RestMethod -Method Post -Uri "http://127.0.0.1:$Port/api/bootstrap" `
                                     -Headers $claimHeaders -Body $body
        $adminKey = $claimed.console_key
    }
    catch { Say "admin claim: $($_.Exception.Message)" }
}
if (-not $adminKey) { Say 'admin key not obtained; finish setup in the browser' }
else { $headers['Authorization'] = "Bearer $adminKey" }

Start-Process "http://127.0.0.1:$Port/setup" | Out-Null
Say "console opened: http://127.0.0.1:$Port/setup"

# --------------------------------------------------------------- 9 qoder/zcode
Step 8 'detect Qoder and ZCode'
$state = $null
if ($adminKey) {
    try { $state = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/api/setup/state" -Headers $headers -TimeoutSec 15 }
    catch { Say "setup state: $($_.Exception.Message)" }
}

if (-not $SkipQoder -and $adminKey) {
    $qoder = $state.qoder
    if ($qoder -and -not $qoder.logged_in) {
        Say 'Qoder CLI not signed in - starting the official OAuth page'
        try {
            Invoke-RestMethod -Method Post -Uri "http://127.0.0.1:$Port/api/setup/qoder/connect" `
                              -Headers $headers -TimeoutSec 300 | Out-Null
        }
        catch { Say "qoder connect: $($_.Exception.Message)" }
        $login = $null
        for ($i = 0; $i -lt 40; $i++) {
            Start-Sleep -Seconds 3
            try {
                $login = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/api/setup/qoder/login" `
                                           -Headers $headers -TimeoutSec 15
            }
            catch { }
            if ($login -and $login.url -and -not $openedUrl) {
                Start-Process $login.url | Out-Null
                $openedUrl = $true
                if ($login.user_code) { Write-Host "[uniai] Qoder code: $($login.user_code)" -ForegroundColor Yellow }
            }
            if ($login -and $login.logged_in) { break }
        }
        if ($login -and $login.logged_in) {
            $ent = $login.entitlement
            Say "Qoder connected; remaining=$($ent.quota_remaining)/$($ent.quota_total) type=$($ent.entitlement_type)"
        }
        else {
            Write-Host '[uniai] ACTION REQUIRED: finish the Qoder sign-in in your browser.' -ForegroundColor Yellow
        }
    }
    elseif ($qoder -and $qoder.logged_in) { Say 'Qoder already signed in' }
}

if (-not $SkipZCode -and $adminKey -and $state -and $state.zcode -and $state.zcode.installed) {
    Step 9 'auto-configure ZCode'
    try {
        $res = Invoke-RestMethod -Method Post -Uri "http://127.0.0.1:$Port/api/setup/zcode/configure" `
                                 -Headers $headers -TimeoutSec 60
        Say "ZCode configured: $($res.base_url) models=$($res.models.Count) backup=$($res.backup)"
    }
    catch { Say "zcode configure: $($_.Exception.Message)" }
}
elseif ($state -and $state.zcode -and -not $state.zcode.installed) {
    Say 'ZCode not found on this PC - skip (install ZCode first, then rerun)'
}

Write-Host ''
Write-Host '================ UniAI Gateway install summary ================' -ForegroundColor Green
Write-Host " version      : $ProductVersion"
Write-Host " install dir  : $app"
Write-Host " gateway      : http://127.0.0.1:$Port"
Write-Host " console      : http://127.0.0.1:$Port/setup"
Write-Host " paid_enabled : false (no extra cost by default)"
Write-Host '===============================================================' -ForegroundColor Green
