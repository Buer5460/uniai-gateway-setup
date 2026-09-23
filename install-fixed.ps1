#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$InstallerPath = '',
    [string]$ExpectedSHA256 = '',
    [string]$InstallDir = '',
    [switch]$NoOpen,
    [switch]$NoAutostart
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
$version = '0.8.0-installer.1'
$name = "UniAI-Setup-$version-windows-x64.exe"
$release = "https://github.com/Buer5460/uniai-gateway-setup/releases/download/v$version"
$logDir = Join-Path $env:LOCALAPPDATA 'UniAIInstaller\Logs'
[void][IO.Directory]::CreateDirectory($logDir)
$logPath = Join-Path $logDir (('one-line-{0}-{1}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss'),[Guid]::NewGuid().ToString('N').Substring(0,8)))
$mutex = $null
$owned = $false
function Say([string]$Message) {
    Write-Host $Message
    Add-Content -LiteralPath $logPath -Value ((Get-Date -Format 'o') + ' ' + $Message) -Encoding UTF8
}
function Download([string]$Url,[string]$Destination) {
    if (-not $Url.StartsWith('https://github.com/Buer5460/uniai-gateway-setup/releases/download/')) { throw 'Unexpected download origin.' }
    for ($attempt=1; $attempt -le 3; $attempt++) {
        $response=$null; $inputStream=$null; $outputStream=$null
        try {
            $request=[Net.HttpWebRequest]::Create($Url)
            $request.Timeout=30000; $request.ReadWriteTimeout=30000
            $request.UserAgent='UniAI-Installer/0.8.0-installer.1'
            $response=$request.GetResponse()
            $inputStream=$response.GetResponseStream()
            $outputStream=[IO.File]::Open($Destination+'.partial',[IO.FileMode]::Create,[IO.FileAccess]::Write,[IO.FileShare]::None)
            $buffer=New-Object byte[] 131072
            $total=0L; $timer=[Diagnostics.Stopwatch]::StartNew()
            while (($count=$inputStream.Read($buffer,0,$buffer.Length)) -gt 0) {
                $outputStream.Write($buffer,0,$count); $total+=$count
                if ($total -gt 250MB -or $timer.Elapsed.TotalSeconds -gt 300) { throw 'Download exceeded size/time limit.' }
                $percent=0
                if ($response.ContentLength -gt 0) { $percent=[Math]::Min(100,[int](100*$total/$response.ContentLength)) }
                Write-Progress -Activity 'Downloading UniAI' -Status ('{0:N1} MB downloaded' -f ($total/1MB)) -PercentComplete $percent
            }
            $outputStream.Dispose(); $outputStream=$null
            if ($response.ContentLength -gt 0 -and $total -ne $response.ContentLength) { throw 'Incomplete download.' }
            Move-Item -LiteralPath ($Destination+'.partial') -Destination $Destination -Force
            Write-Progress -Activity 'Downloading UniAI' -Completed
            return
        } catch {
            if ($attempt -eq 3) { throw }
            Say ('Download attempt {0} failed; retrying.' -f $attempt)
            Start-Sleep -Seconds (2*$attempt)
        } finally {
            if ($outputStream) { $outputStream.Dispose() }
            if ($inputStream) { $inputStream.Dispose() }
            if ($response) { $response.Dispose() }
        }
    }
}
function RunBounded([string]$Exe,[string]$Arguments,[int]$Seconds) {
    $psi=New-Object Diagnostics.ProcessStartInfo
    $psi.FileName=$Exe; $psi.Arguments=$Arguments
    $psi.WorkingDirectory=[IO.Path]::GetDirectoryName($Exe)
    $psi.UseShellExecute=$false
    $process=[Diagnostics.Process]::Start($psi)
    $timer=[Diagnostics.Stopwatch]::StartNew(); $last=0
    while (-not $process.WaitForExit(500)) {
        if ($timer.Elapsed.TotalSeconds -ge $Seconds) { throw ('Operation timed out; process {0} may still be running. Do not start another installer. Log: {1}' -f $process.Id,$logPath) }
        if ($timer.Elapsed.TotalSeconds-$last -ge 10) { Say ('Working... {0:N0}s' -f $timer.Elapsed.TotalSeconds); $last=$timer.Elapsed.TotalSeconds }
    }
    $code=$process.ExitCode; $process.Dispose()
    if ($code -ne 0) { throw ('Program returned exit code {0}. Installer log: {1}' -f $code,(Join-Path $logDir 'installer.log')) }
}
function LocalGet([string]$Url) {
    $uri=[Uri]$Url
    if ($uri.Scheme -ne 'http' -or $uri.Host -ne '127.0.0.1') { throw 'Local validation must use loopback only.' }
    $req=[Net.HttpWebRequest]::Create($uri); $req.Proxy=$null; $req.Timeout=5000; $req.ReadWriteTimeout=5000; $req.AllowAutoRedirect=$false
    $res=$req.GetResponse()
    try {
        $reader=New-Object IO.StreamReader($res.GetResponseStream())
        try { return @{ Text=$reader.ReadToEnd(); ContentType=$res.ContentType; Code=[int]$res.StatusCode } }
        finally { $reader.Dispose() }
    } finally { $res.Dispose() }
}
try {
    Say '[1/6] Checking Windows and installation location...'
    if ($env:OS -ne 'Windows_NT') { throw 'This installer supports Windows x64 only.' }
    if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') { throw 'Organization policy restricts PowerShell. Contact your administrator; no policy bypass is attempted.' }
    $arch=$env:PROCESSOR_ARCHITEW6432
    if (-not $arch) { $arch=$env:PROCESSOR_ARCHITECTURE }
    if ($arch -ne 'AMD64') { throw ('Unsupported native architecture: '+$arch+'. Use a tested x64 Windows device.') }
    [Net.ServicePointManager]::SecurityProtocol=[Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $mutex=New-Object Threading.Mutex($false,('Local\UniAI.Install.'+$sid))
    try { $owned=$mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $owned=$true }
    if (-not $owned) { throw 'Another UniAI installer is active. This invocation will not modify files.' }
    if (-not $InstallDir) { $InstallDir=Join-Path $env:LOCALAPPDATA 'UniAI Gateway' }
    $InstallDir=[IO.Path]::GetFullPath($InstallDir)
    if ($InstallDir.Contains('"')) { throw 'Invalid installation path.' }
    $entry=Join-Path $InstallDir 'UniAI.exe'
    $installJson=Join-Path $InstallDir 'install.json'
    $alreadyInstalled=(Test-Path -LiteralPath $entry -PathType Leaf) -and (Test-Path -LiteralPath $installJson -PathType Leaf)
    if (-not $alreadyInstalled) {
        if ((Test-Path -LiteralPath $InstallDir) -and @(Get-ChildItem -LiteralPath $InstallDir -Force).Count -gt 0) { throw 'The target folder is nonempty but is not a complete UniAI installation. No files were removed.' }
        Say '[2/6] Preparing the full application and bundled runtime...'
        $cache=Join-Path $env:LOCALAPPDATA ('UniAIInstaller\Cache\'+$version)
        [void][IO.Directory]::CreateDirectory($cache)
        if (-not $InstallerPath) {
            $manifest=Join-Path $cache 'build.json'
            Download ($release+'/'+[IO.Path]::ChangeExtension($name,'.build.json')) $manifest
            $meta=Get-Content -LiteralPath $manifest -Raw -Encoding UTF8 | ConvertFrom-Json
            $ExpectedSHA256=[string]$meta.output_sha256
            $InstallerPath=Join-Path $cache $name
            Download ($release+'/'+$name) $InstallerPath
        }
        $InstallerPath=(Resolve-Path -LiteralPath $InstallerPath).Path
        if ($ExpectedSHA256 -notmatch '^[0-9a-fA-F]{64}$') { throw 'A valid expected SHA-256 is required. Nothing will be executed.' }
        $actual=(Get-FileHash -LiteralPath $InstallerPath -Algorithm SHA256).Hash
        if ($actual -ne $ExpectedSHA256) { throw 'Installer integrity check failed. Nothing was executed; retry from the official release.' }
        Say '[3/6] Installing (Python and application dependencies are included)...'
        # One quoted argument string; no --launch, so installation is separate from runtime lifetime.
        $arguments='--silent --dir "'+$InstallDir+'"'
        if ($NoAutostart) { $arguments+=' --no-autostart' }
        RunBounded $InstallerPath $arguments 240
        foreach ($relative in @('UniAI.exe','uniai-agent.exe','install.json','_internal\python312.dll','_internal\apps\console\dist\index.html')) {
            if (-not (Test-Path -LiteralPath (Join-Path $InstallDir $relative) -PathType Leaf)) { throw ('Installer exited but a required file is missing: '+$relative) }
        }
    } else { Say '[2-3/6] Existing installation found; preserving files, data and credentials.' }
    $cfg=Get-Content -LiteralPath $installJson -Raw -Encoding UTF8 | ConvertFrom-Json
    $port=[int]$cfg.port
    if ($port -lt 1024 -or $port -gt 65535) { throw 'Invalid port in installation metadata.' }
    Say '[4/6] Starting the installed runtime...'
    if ($NoOpen) { RunBounded $entry '--start-only' 240 }
    else { RunBounded $entry '--headless' 300 }
    Say '[5/6] Verifying gateway identity and console assets...'
    $base='http://127.0.0.1:'+$port
    $health=(LocalGet ($base+'/health')).Text | ConvertFrom-Json
    if ($health.service -ne 'uniai-gateway') { throw 'Port belongs to another application. No process was terminated.' }
    $page=LocalGet ($base+'/console/')
    $assets=[regex]::Matches($page.Text,'(?:src|href)="([^"]+)"')
    $checked=0
    foreach ($match in $assets) {
        $assetUrl=[Uri]::new([Uri]($base+'/console/'),$match.Groups[1].Value)
        if ($assetUrl.AbsolutePath -match '\.(js|css)$') {
            $asset=LocalGet $assetUrl.AbsoluteUri
            if ($asset.ContentType -match 'text/html') { throw 'Console asset incorrectly returned HTML.' }
            $checked++
        }
    }
    if ($checked -lt 1) { throw 'No built console JavaScript/CSS assets were verified.' }
    Say ('[6/6] READY: '+$base+'/console/ (gateway and '+$checked+' assets verified)')
    if (-not $NoOpen) { Say 'The trusted local launcher requested an authenticated browser window. Model accounts must be authorized by their owner.' }
    Say ('Log: '+$logPath)
} catch {
    Say ('FAILED: '+$_.Exception.Message)
    Say 'No success is claimed. Do not disable security software or reinstall unrelated development tools.'
    throw
} finally {
    if ($owned -and $mutex) { $mutex.ReleaseMutex() }
    if ($mutex) { $mutex.Dispose() }
}
