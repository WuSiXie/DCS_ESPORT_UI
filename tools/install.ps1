param(
    [Parameter(Mandatory = $true)][string]$SavedGamesPath,
    [string]$HookFile
)
$ErrorActionPreference = 'Stop'
$projectRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$packageRoot = Join-Path $projectRoot 'dist\DcsEsport'
$profileRoot = (Resolve-Path -LiteralPath $SavedGamesPath).Path
if (-not (Test-Path -LiteralPath $profileRoot -PathType Container)) { throw 'SavedGamesPath must be an existing directory.' }
$relativeFiles = @(
    'Scripts\Hooks\DcsEsportHook.lua'
)
# Check every input before copying any file; no directory deletion is involved.
foreach ($relativeFile in $relativeFiles) {
    $sourceFile = if ($HookFile) { (Resolve-Path -LiteralPath $HookFile).Path } else { Join-Path $packageRoot $relativeFile }
    if (-not (Test-Path -LiteralPath $sourceFile -PathType Leaf)) { throw "Build the package first. Missing: $sourceFile" }
}
foreach ($relativeFile in $relativeFiles) {
    $sourceFile = if ($HookFile) { (Resolve-Path -LiteralPath $HookFile).Path } else { Join-Path $packageRoot $relativeFile }
    $targetFile = [System.IO.Path]::GetFullPath((Join-Path $profileRoot $relativeFile))
    if (-not $targetFile.StartsWith($profileRoot.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Destination outside the selected profile: $targetFile"
    }
    [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($targetFile)) | Out-Null
    if (Test-Path -LiteralPath $targetFile) {
        Copy-Item -LiteralPath $targetFile -Destination ($targetFile + '.bak.' + (Get-Date -Format 'yyyyMMdd-HHmmss-fffffff'))
    }
    Copy-Item -LiteralPath $sourceFile -Destination $targetFile -Force
    if ((Get-FileHash -LiteralPath $sourceFile).Hash -ne (Get-FileHash -LiteralPath $targetFile).Hash) { throw 'Installed Hook hash mismatch.' }
}
Write-Output "Installed one self-contained Hook to $profileRoot. Settings are embedded near the top of the Hook. Restart DCS to load it."
