param([ValidateSet('win-x64')][string]$Runtime = 'win-x64')
$ErrorActionPreference = 'Stop'
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$Version = (Get-Content (Join-Path $ProjectRoot 'VERSION') -Raw).Trim()
if ($Version -notmatch '^\d+\.\d+\.\d+$') { throw 'Invalid version' }
$Output = Join-Path $ProjectRoot "dist/windows-$Runtime"
dotnet publish (Join-Path $ProjectRoot 'windows/CodexUsage.Windows') -c Release -r $Runtime --self-contained true -p:Version=$Version -o $Output
if ($LASTEXITCODE -ne 0) { throw 'Windows publish failed' }
$LicenseOutput = Join-Path $Output 'ThirdPartyLicenses'
New-Item -ItemType Directory -Force $LicenseOutput | Out-Null
$PackageRoots = @($env:NUGET_PACKAGES, (Join-Path $HOME '.nuget/packages')) | Where-Object { $_ }
foreach ($Folder in $PackageRoots) {
  foreach ($Id in @("microsoft.netcore.app.runtime.$Runtime", "microsoft.windowsdesktop.app.runtime.$Runtime")) {
    $Package = Join-Path $Folder $Id
    if (-not (Test-Path $Package)) { continue }
    foreach ($VersionFolder in (Get-ChildItem -Directory $Package)) {
      $Destination = Join-Path $LicenseOutput "$Id-$($VersionFolder.Name)"
      New-Item -ItemType Directory -Force $Destination | Out-Null
      Get-ChildItem -File $VersionFolder.FullName | Where-Object { $_.Name -match 'LICENSE|NOTICE' } | Copy-Item -Destination $Destination
    }
  }
}
if (-not (Get-ChildItem -Recurse -File $LicenseOutput)) { throw 'Runtime license files were not found' }
foreach ($File in @('LICENSE', 'NOTICE', 'THIRD-PARTY-NOTICES.md', 'README.md')) { Copy-Item (Join-Path $ProjectRoot $File) $Output }
$Zip = Join-Path $ProjectRoot 'dist/CodexUsage-Windows-x64.zip'
if (Test-Path $Zip) { Remove-Item $Zip }
Compress-Archive -Path (Join-Path $Output '*') -DestinationPath $Zip -CompressionLevel Optimal
Write-Host "Packaged: $Zip"
