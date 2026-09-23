param([string]$InstallDir, [string]$EvidencePath)
$ErrorActionPreference = 'Stop'
$config = Get-Content (Join-Path $InstallDir 'install.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$base = 'http://127.0.0.1:' + $config.port
$keyPath = Join-Path $InstallDir 'data\run\launcher-admin.key'
$checks = [Collections.Generic.List[object]]::new()
function Check($name, $ok) {
    $checks.Add(@{name=$name;passed=[bool]$ok})
    Write-Host ($name + ': ' + $ok)
    if (-not $ok) { throw ('FAILED ' + $name) }
}
function Request($url, $method='GET', $key='', $body='') {
    $r = [Net.HttpWebRequest]::Create($url)
    $r.Proxy = $null; $r.Timeout = 5000; $r.Method = $method
    if ($key) { $r.Headers['Authorization'] = 'Bearer ' + $key }
    if ($method -eq 'POST') {
        $r.ContentType = 'application/json'
        $bytes = [Text.Encoding]::UTF8.GetBytes($body); $r.ContentLength = $bytes.Length
        $s = $r.GetRequestStream()
        try { $s.Write($bytes, 0, $bytes.Length) } finally { $s.Dispose() }
    }
    try { $response = $r.GetResponse() }
    catch [Net.WebException] {
        if ($_.Exception.Response) {
            $status = [int]$_.Exception.Response.StatusCode
            $_.Exception.Response.Dispose()
            return @{status=$status;data=$null}
        }
        throw
    }
    try {
        $reader = New-Object IO.StreamReader($response.GetResponseStream())
        try { return @{status=[int]$response.StatusCode;data=($reader.ReadToEnd() | ConvertFrom-Json)} }
        finally { $reader.Dispose() }
    } finally { $response.Dispose() }
}
function ReadPageText($url) {
    $ws = New-Object Net.WebSockets.ClientWebSocket
    $cts = New-Object Threading.CancellationTokenSource
    $cts.CancelAfter(10000)
    try {
        $ws.ConnectAsync([Uri]$url,$cts.Token).GetAwaiter().GetResult()
        $bytes = [Text.Encoding]::UTF8.GetBytes('{"id":1,"method":"Runtime.evaluate","params":{"expression":"document.body.innerText","returnByValue":true}}')
        $ws.SendAsync([ArraySegment[byte]]::new($bytes),[Net.WebSockets.WebSocketMessageType]::Text,$true,$cts.Token).GetAwaiter().GetResult()
        while ($true) {
            $stream = New-Object IO.MemoryStream
            try {
                do {
                    $buffer = New-Object byte[] 65536
                    $received = $ws.ReceiveAsync([ArraySegment[byte]]::new($buffer),$cts.Token).GetAwaiter().GetResult()
                    $stream.Write($buffer,0,$received.Count)
                } while (-not $received.EndOfMessage)
                $message = [Text.Encoding]::UTF8.GetString($stream.ToArray()) | ConvertFrom-Json
            } finally { $stream.Dispose() }
            if ($message.id -eq 1) { return [string]$message.result.result.value }
        }
    } finally { $ws.Dispose(); $cts.Dispose() }
}
$edge = @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe", "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe") | Where-Object {Test-Path $_} | Select-Object -First 1
if (-not $edge) { throw 'No CI browser' }
$profile = Join-Path $env:RUNNER_TEMP ('uni-browser-' + [guid]::NewGuid().ToString('N'))
$env:BROWSER = '"' + $edge + '" --headless=new --remote-debugging-address=127.0.0.1 --remote-debugging-port=9222 --no-first-run --user-data-dir="' + $profile + '" %s &'
$overview = [string][char]0x603B + [char]0x89C8
$scan = [string][char]0x626B + [char]0x63CF + [char]0x672C + [char]0x673A
$ok = $false
$lastErrorType = ''; $text = ''
try {
    for ($round=1; $round -le 2; $round++) {
        $before = if (Test-Path $keyPath) { (Get-FileHash $keyPath).Hash } else { '' }
        Start-Process -FilePath (Join-Path $InstallDir 'UniAI.exe') | Out-Null
        $ready = $false; $changed = $false
        for ($i=0; $i -lt 45; $i++) {
            try {
                $tabs = @((Request 'http://127.0.0.1:9222/json').data) | Where-Object { $_.type -eq 'page' -and $_.url -like ($base + '/console*') }
                foreach ($tab in $tabs) {
                    $text = ReadPageText $tab.webSocketDebuggerUrl
                    if ($text.Contains($overview) -and $text.Contains($scan)) { $ready=$true; break }
                }
                $after = if (Test-Path $keyPath) { (Get-FileHash $keyPath).Hash } else { '' }
                $changed = [bool]($after -and $after -ne $before)
                if ($ready -and $changed) { break }
            } catch { $lastErrorType = $_.Exception.GetType().FullName }
            Start-Sleep -Seconds 2
        }
        Check ('browser_render_round_' + $round) $ready
        Check ('existing_cache_updated_round_' + $round) $changed
        $key = (Get-Content $keyPath -Raw -Encoding UTF8).Trim()
        Check ('cached_session_valid_after_browser_round_' + $round) ((Request ($base + '/api/dashboard') 'GET' $key).status -eq 200)
    }
    $before = (Get-FileHash $keyPath).Hash
    $denied = Request ($base + '/api/bootstrap') 'POST' '' '{"bootstrap_token":"not-a-valid-proof"}'
    Check 'invalid_handoff_is_denied' ($denied.status -in @(400,401,403,409,410))
    Check 'invalid_handoff_does_not_change_cache' ((Get-FileHash $keyPath).Hash -eq $before)
    Check 'anonymous_dashboard_denied' ((Request ($base + '/api/dashboard')).status -in @(401,403))
    $ok = $true
} finally {
    $safeText = [regex]::Replace($text,'(?i)(?:gw_|sk-|vk_|eyJ)[A-Za-z0-9_.-]{10,}','[REDACTED]')
    @{success=$ok;checks=$checks;os=[Environment]::OSVersion.VersionString;source_commit=$env:GITHUB_SHA;scope='real packaged launcher to headless Edge; two browser openings; existing cache sync; negative authorization';model_accounts=$false;last_error_type=$lastErrorType;visible_text=$safeText.Substring(0,[Math]::Min(1800,$safeText.Length))} | ConvertTo-Json -Depth 8 | Set-Content $EvidencePath -Encoding UTF8
    Write-Host ('Browser check outcome: ' + $ok + '; last exception type: ' + $lastErrorType)
    Write-Host ($safeText.Substring(0,[Math]::Min(1200,$safeText.Length)))
}
