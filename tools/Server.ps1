param([ValidateSet('Start','Stop','Status')][string]$Action = 'Status')
$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$runtime = Join-Path $projectRoot 'runtime\server'
$executable = Join-Path $projectRoot 'dist\server\dcs-esport-server.exe'
$settings = Get-Content -LiteralPath (Join-Path $runtime 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$pidFile = Join-Path $runtime 'process.json'
$owned = $null
if (Test-Path -LiteralPath $pidFile) {
    $saved = Get-Content -LiteralPath $pidFile -Raw -Encoding UTF8 | ConvertFrom-Json
    $candidate = Get-Process -Id $saved.processId -ErrorAction SilentlyContinue
    # PowerShell 7 may deserialize ISO timestamps as DateTime; store ticks as text instead.
    $savedTicks = if ($saved.startedTicks) { [string]$saved.startedTicks } else { ([DateTime]$saved.startedUtc).ToUniversalTime().Ticks.ToString() }
    if ($candidate -and $candidate.Path -eq $executable -and $candidate.StartTime.ToUniversalTime().Ticks.ToString() -eq $savedTicks) {
        $owned = $candidate
    }
}
if ($Action -eq 'Stop') {
    if ($owned) { Stop-Process -InputObject $owned; $owned.WaitForExit(); Write-Output 'Server stopped; memory history released.' }
    else { Write-Output 'No matching project-owned server process.' }
    return
}
if ($Action -eq 'Start') {
    if ($owned) { Write-Output "Server already running: PID $($owned.Id)"; return }
    if (-not (Test-Path -LiteralPath $executable)) { throw 'Build and install the C++ server first.' }
    $oldHookToken = $env:DCS_ESPORT_HOOK_TOKEN
    $oldApiToken = $env:DCS_ESPORT_API_TOKEN
    try {
        $env:DCS_ESPORT_HOOK_TOKEN = $settings.hookToken
        $env:DCS_ESPORT_API_TOKEN = $settings.apiToken
        $arguments = @('--port', $settings.hookPort, '--http-port', $settings.httpPort, '--instance', $settings.instanceId)
        $usersFile = Join-Path $runtime 'users.json'
        if (Test-Path -LiteralPath $usersFile) { $arguments += @('--users', 'runtime/server/users.json') }
        if ($settings.tlsPort) {
            if (-not $settings.tlsCertificate -or -not $settings.tlsKey) { throw 'TLS requires tlsCertificate and tlsKey in runtime/server/config.json.' }
            $certificate = [IO.Path]::GetFullPath((Join-Path $projectRoot $settings.tlsCertificate))
            $privateKey = [IO.Path]::GetFullPath((Join-Path $projectRoot $settings.tlsKey))
            if (-not (Test-Path -LiteralPath $certificate) -or -not (Test-Path -LiteralPath $privateKey)) { throw 'TLS certificate/key file does not exist.' }
            $bind = if ($settings.tlsBind) { $settings.tlsBind } else { '127.0.0.1' }
            $arguments += @('--tls-port', $settings.tlsPort, '--tls-bind', $bind, '--tls-cert', ('"' + $certificate + '"'), '--tls-key', ('"' + $privateKey + '"'))
        }
        $owned = Start-Process -FilePath $executable -ArgumentList $arguments -WorkingDirectory $projectRoot -WindowStyle Hidden -PassThru `
            -RedirectStandardOutput (Join-Path $runtime 'stdout.log') -RedirectStandardError (Join-Path $runtime 'stderr.log')
    } finally {
        $env:DCS_ESPORT_HOOK_TOKEN = $oldHookToken
        $env:DCS_ESPORT_API_TOKEN = $oldApiToken
    }
    $ready = $false
    for ($attempt=0; $attempt -lt 30; $attempt++) {
        Start-Sleep -Milliseconds 100
        if ($owned.HasExited) { throw "Server exited. See $runtime\stderr.log" }
        try {
            $reply = Invoke-RestMethod -Uri "http://127.0.0.1:$($settings.httpPort)/healthz" -TimeoutSec 1
            if ($reply.status -eq 'ok') { $ready = $true; break }
        } catch { }
    }
    if (-not $ready) { Stop-Process -InputObject $owned; throw 'Server startup timed out.' }
    [IO.File]::WriteAllText($pidFile, (@{processId=$owned.Id; startedTicks=$owned.StartTime.ToUniversalTime().Ticks.ToString()} | ConvertTo-Json))
    Write-Output "Server started: PID $($owned.Id), TCP 127.0.0.1:$($settings.hookPort), HTTP 127.0.0.1:$($settings.httpPort)"
    return
}
if (-not $owned) { Write-Output 'Server is not running under this project launcher.'; return }
$headers = @{Authorization=('Bearer ' + $settings.apiToken)}
$base = "http://127.0.0.1:$($settings.httpPort)"
$status = Invoke-RestMethod -Uri "$base/api/v1/status" -Headers $headers
$sources = Invoke-RestMethod -Uri "$base/api/v1/sources" -Headers $headers
@{processId=$owned.Id; status=$status; sources=@($sources)} | ConvertTo-Json -Depth 40
