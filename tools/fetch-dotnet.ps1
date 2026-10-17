param(
    [string]$Path = (Join-Path $PSScriptRoot '../.tools/prerequisites/NDP48-x86-x64-AllOS-ENU.exe'),
    [switch]$VerifyOnly
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSHOME 'Modules/Microsoft.PowerShell.Utility/Microsoft.PowerShell.Utility.psd1')
Import-Module (Join-Path $PSHOME 'Modules/Microsoft.PowerShell.Security/Microsoft.PowerShell.Security.psd1')
$downloadUrl = 'https://download.microsoft.com/download/f/3/a/f3a6af84-da23-40a5-8d1c-49cc10c8e76f/NDP48-x86-x64-AllOS-ENU.exe'
$expectedHash = '0a3a390c47e639d0f7fc65b21195fee6b7f65b066f80f70c60fab191d14b7e40'
$target = [IO.Path]::GetFullPath($Path)
if (-not (Test-Path -LiteralPath $target)) {
    if ($VerifyOnly) { throw 'Missing .NET offline prerequisite. Run tools/fetch-dotnet.ps1 first.' }
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target)) | Out-Null
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $downloadFile = $target + '.download'
    Invoke-WebRequest -UseBasicParsing -Uri $downloadUrl -OutFile $downloadFile
    if ((Get-FileHash -LiteralPath $downloadFile -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expectedHash) {
        throw 'Downloaded .NET package hash does not match the pinned Microsoft release; file was not accepted.'
    }
    Move-Item -LiteralPath $downloadFile -Destination $target
}
$hash = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant()
if ($hash -ne $expectedHash) { throw 'The .NET package does not match the pinned SHA-256.' }
$signature = Get-AuthenticodeSignature -LiteralPath $target
if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch '^CN=Microsoft Corporation,') {
    throw 'The .NET package must have a valid Microsoft Corporation Authenticode signature.'
}
@{file=$target;url=$downloadUrl;sha256=$hash;bytes=(Get-Item -LiteralPath $target).Length;signer=$signature.SignerCertificate.Subject;signatureStatus=$signature.Status.ToString()} | ConvertTo-Json -Compress
