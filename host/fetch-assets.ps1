#Requires -Version 5.1
<#
.SYNOPSIS
  Download GPU-PV Linux assets: patched dxgkrnl sources + Microsoft Linux D3D12 libraries.
.DESCRIPTION
  These are the same files used by the ExHyperV Linux deployment flow:
      https://github.com/Justsenger/ExHyperV
  They are downloaded at deployment time (not redistributed by this repo).
  Run on the Windows host, then copy assets/ and lib/ into the VM.
.PARAMETER RepoRoot
  Repo root directory (default: parent of this script directory)
#>
param([string]$RepoRoot = (Split-Path -Parent $PSScriptRoot))

$ErrorActionPreference = 'Stop'
$base = 'https://raw.githubusercontent.com/Justsenger/ExHyperV'
$assetsDir = Join-Path $RepoRoot 'assets'
$libDir = Join-Path $RepoRoot 'lib'
New-Item -ItemType Directory -Force -Path $assetsDir, $libDir | Out-Null

$files = @(
  @{ Url = "$base/kernel-assets/dxgkrnl-5.15-patched.tar.gz";  Out = (Join-Path $assetsDir 'dxgkrnl-5.15-patched.tar.gz') },
  @{ Url = "$base/kernel-assets/dxgkrnl-6.6-patched.tar.gz";   Out = (Join-Path $assetsDir 'dxgkrnl-6.6-patched.tar.gz') },
  @{ Url = "$base/kernel-assets/dxgkrnl-6.12-patched.tar.gz";  Out = (Join-Path $assetsDir 'dxgkrnl-6.12-patched.tar.gz') },
  @{ Url = "$base/main/src/Linux/lib/x64/libd3d12.so";         Out = (Join-Path $libDir 'libd3d12.so') },
  @{ Url = "$base/main/src/Linux/lib/x64/libd3d12core.so";     Out = (Join-Path $libDir 'libd3d12core.so') },
  @{ Url = "$base/main/src/Linux/lib/x64/libdxcore.so";        Out = (Join-Path $libDir 'libdxcore.so') }
)

function Get-Curl {
  $c = Get-Command curl.exe -ErrorAction SilentlyContinue
  if ($c) { return $c.Source }
  $c = Get-Command curl -ErrorAction SilentlyContinue
  if ($c) { return $c.Source }
  throw "curl not found. Use 'Invoke-WebRequest' instead or install curl."
}

$curl = Get-Curl
foreach ($f in $files) {
  Write-Host "Downloading $(Split-Path $f.Out -Leaf) ..."
  & $curl -fSL --retry 3 --connect-timeout 20 -o $f.Out $f.Url
  if ($LASTEXITCODE -ne 0) { throw "Download failed: $($f.Url)" }
  $size = (Get-Item $f.Out).Length
  if ($size -le 0) { throw "Empty file: $($f.Out)" }
  Write-Host ("  OK  {0:N0} bytes" -f $size)
}

Write-Host "`nAssets ready:" -ForegroundColor Green
Get-ChildItem $assetsDir, $libDir -File | Select-Object FullName, Length | Format-Table -AutoSize
Write-Host "Next: .\make-driver-pack.ps1   then copy assets/, lib/, driver-pack.tar.gz and guest/ to the VM." -ForegroundColor Green
