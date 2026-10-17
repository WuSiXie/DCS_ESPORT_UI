param()
$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$configFile = Join-Path $projectRoot 'runtime\server\config.json'
$generatedHook = Join-Path $projectRoot 'dist\DcsEsport\Scripts\Hooks\DcsEsportHook.lua'
$candidateHook = Join-Path $projectRoot 'runtime\deploy\DcsEsportHook.lua'
if (-not (Test-Path -LiteralPath $generatedHook)) { throw 'Run python tools/package.py first.' }
function New-Token {
    $bytes = New-Object byte[] 32
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    return [BitConverter]::ToString($bytes).Replace('-', '').ToLowerInvariant()
}
if (-not (Test-Path -LiteralPath $configFile)) {
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($configFile)) | Out-Null
    $settings = [ordered]@{instanceId='dcs-local'; hookPort=9081; httpPort=9080; hookToken=(New-Token); apiToken=(New-Token)}
    [IO.File]::WriteAllText($configFile, ($settings | ConvertTo-Json), (New-Object Text.UTF8Encoding $false))
}
$settings = Get-Content -LiteralPath $configFile -Raw -Encoding UTF8 | ConvertFrom-Json
if ($settings.instanceId -notmatch '^[a-zA-Z0-9_.-]{1,64}$' -or $settings.hookToken -notmatch '^[a-f0-9]{64}$' -or $settings.apiToken -notmatch '^[a-f0-9]{64}$') {
    throw 'Invalid local network configuration.'
}
foreach ($port in @($settings.hookPort, $settings.httpPort)) {
    if ($port -lt 1 -or $port -gt 65535 -or [int]$port -ne $port) { throw 'Invalid port.' }
}
if ($settings.hookPort -eq $settings.httpPort) { throw 'TCP and HTTP ports must differ.' }
$text = [IO.File]::ReadAllText($generatedHook)
# Replace only the top-level editable CONFIG block, never embedded source text.
$marker = '-- END CONFIG'
$end = $text.IndexOf($marker)
if ($end -lt 0) { throw 'Generated Hook has no CONFIG block.' }
$header = $text.Substring(0, $end)
$header = $header.Replace('network = { enabled = false', 'network = { enabled = true')
$header = $header.Replace('port = 9081', ('port = ' + $settings.hookPort))
$header = $header.Replace('instanceId = "dcs-local"', ('instanceId = "' + $settings.instanceId + '"'))
$header = $header.Replace('token = ""', ('token = "' + $settings.hookToken + '"'))
[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($candidateHook)) | Out-Null
[IO.File]::WriteAllText($candidateHook, ($header + $text.Substring($end)), (New-Object Text.UTF8Encoding $false))
Write-Output "Configuration retained at $configFile; configured single-file Hook: $candidateHook"
