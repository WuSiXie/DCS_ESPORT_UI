param(
    [ValidateSet('Start','Stop','Status')][string]$Action = 'Status',
    [ValidateRange(1,65535)][int]$Port = 9170,
    [string]$Upstream = 'http://127.0.0.1:9080',
    [string]$Node = ''
)
$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$runtime = Join-Path $projectRoot "runtime\director-$Port"
$entry = Join-Path $projectRoot 'src\director\server.mjs'
$pidFile = Join-Path $runtime 'process.json'
$owned = $null
if (Test-Path -LiteralPath $pidFile) {
    $saved = Get-Content -LiteralPath $pidFile -Raw -Encoding UTF8 | ConvertFrom-Json
    $candidate = Get-Process -Id $saved.processId -ErrorAction SilentlyContinue
    if ($candidate -and $candidate.Path -eq $saved.executable -and $saved.entry -eq $entry -and
        $candidate.StartTime.ToUniversalTime().Ticks.ToString() -eq [string]$saved.startedTicks) { $owned = $candidate }
}
if ($Action -eq 'Stop') {
    if ($owned) { Stop-Process -InputObject $owned; $owned.WaitForExit(); Write-Output "Director on port $Port stopped." }
    else { Write-Output 'No matching project-owned director process.' }
    return
}
if ($Action -eq 'Status') {
    if (-not $owned) { Write-Output "Director on port $Port is not running under this launcher."; return }
    $health = Invoke-RestMethod "http://127.0.0.1:$Port/healthz" -TimeoutSec 2
    @{processId=$owned.Id;url="http://127.0.0.1:$Port/";version=$health.version;dataDirectory=$runtime} | ConvertTo-Json
    return
}
if ($owned) { Write-Output "Director already running: http://127.0.0.1:$Port/"; return }
if (-not $Node) {
    $installedNode = Join-Path $projectRoot 'runtime-bin\node.exe'
    $command = Get-Command node -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $installedNode) { $Node = $installedNode }
    elseif ($command) { $Node = $command.Source }
    else {
        $bundled = Join-Path $env:USERPROFILE '.cache\codex-runtimes\codex-primary-runtime\dependencies\node\bin\node.exe'
        if (Test-Path -LiteralPath $bundled) { $Node = $bundled }
        else { throw 'Install Node.js 24 LTS, or pass -Node with the full path to node.exe.' }
    }
}
$Node = [IO.Path]::GetFullPath($Node)
$nodeVersion = (& $Node --version)
if ($LASTEXITCODE -ne 0 -or $nodeVersion -notmatch '^v(\d+)\.' -or [int]$Matches[1] -lt 24) {
    throw 'Node.js 24 or newer is required.'
}
[IO.Directory]::CreateDirectory($runtime) | Out-Null
$arguments = @(('"' + $entry + '"'), '--port', $Port, '--upstream', ('"' + $Upstream + '"'), '--data-dir', ('"' + $runtime + '"'))
$owned = Start-Process -FilePath $Node -ArgumentList $arguments -WorkingDirectory $projectRoot -WindowStyle Hidden -PassThru `
    -RedirectStandardOutput (Join-Path $runtime 'stdout.log') -RedirectStandardError (Join-Path $runtime 'stderr.log')
$ready = $false
for ($attempt=0; $attempt -lt 50; $attempt++) {
    Start-Sleep -Milliseconds 100
    if ($owned.HasExited) { throw "Director exited. See $runtime\stderr.log" }
    try { if ((Invoke-RestMethod "http://127.0.0.1:$Port/healthz" -TimeoutSec 1).status -eq 'ok') { $ready=$true;break } } catch { }
}
if (-not $ready) { Stop-Process -InputObject $owned; throw 'Director startup timed out.' }
[IO.File]::WriteAllText($pidFile,(@{processId=$owned.Id;startedTicks=$owned.StartTime.ToUniversalTime().Ticks.ToString();executable=$Node;entry=$entry} | ConvertTo-Json))
Write-Output "Director started: http://127.0.0.1:$Port/ (PID $($owned.Id))"
