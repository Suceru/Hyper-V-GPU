#Requires -RunAsAdministrator
<#
.SYNOPSIS
  Package the host GPU driver files (DriverStore FileRepository folders) for injection into the Linux guest.
.DESCRIPTION
  GPU-PV requires the guest to use the host's vendor user-mode driver files.
  This script resolves the driver-store folder(s) of the installed display adapter(s)
  and creates driver-pack.tar.gz with the same directory layout, which the guest
  script extracts into /usr/lib/wsl/drivers.
.PARAMETER OutFile
  Output tar.gz path (default: <repo>\driver-pack.tar.gz)
#>
param(
  [string]$OutFile = (Join-Path (Split-Path -Parent $PSScriptRoot) 'driver-pack.tar.gz')
)

$ErrorActionPreference = 'Stop'

Write-Host "Resolving display adapter driver locations..."
$driverPaths = @()
Get-CimInstance Win32_VideoController -Property * | ForEach-Object {
  if ($_.InstalledDisplayDrivers) {
    $driverPaths += ($_.InstalledDisplayDrivers -split ',')
  }
}
if ($driverPaths.Count -eq 0) { throw "No InstalledDisplayDrivers found. Is a GPU driver installed?" }

$repoRoot = Join-Path $env:WINDIR 'System32\DriverStore\FileRepository'
$folders = $driverPaths | ForEach-Object {
  if ($_ -match '^(?<dir>[A-Za-z]:\\Windows\\System32\\DriverStore\\FileRepository\\[^\\]+)\\') {
    Split-Path $Matches.dir -Leaf
  }
} | Sort-Object -Unique

if (-not $folders) { throw "Could not parse DriverStore folders from: $($driverPaths -join '; ')" }
Write-Host "DriverStore folders to pack:" -ForegroundColor Cyan
$folders | ForEach-Object { Write-Host "  $_" }

$tar = Join-Path $env:WINDIR 'System32\tar.exe'
if (-not (Test-Path $tar)) { throw "tar.exe not found at $tar" }

if (Test-Path $OutFile) { Remove-Item $OutFile -Force }
$tarArgs = @('-czf', $OutFile, '-C', $repoRoot) + $folders
Write-Host "Creating $OutFile ..."
& $tar @tarArgs
if ($LASTEXITCODE -ne 0) { throw "tar failed with exit code $LASTEXITCODE" }

$size = (Get-Item $OutFile).Length
Write-Host ("Done: {0} ({1:N1} MB)" -f $OutFile, ($size / 1MB)) -ForegroundColor Green
Write-Host "Copy driver-pack.tar.gz into the VM, e.g.: scp driver-pack.tar.gz <user>@<vm-ip>:~/gpu-pv/" -ForegroundColor Green
