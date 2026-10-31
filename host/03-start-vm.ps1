#Requires -RunAsAdministrator
<#
.SYNOPSIS
  Start the GPU-PV VM and wait until it reports an IP address.
.PARAMETER VMName
  Hyper-V VM name (default: "Ubuntu 22.04 LTS")
.PARAMETER TimeoutSec
  How long to wait for an IP (default: 240)
#>
param(
  [string]$VMName = "Ubuntu 22.04 LTS",
  [int]$TimeoutSec = 240
)

$ErrorActionPreference = 'Stop'
$vm = Get-VM -Name $VMName -ErrorAction Stop

if ($vm.State -ne 'Running') {
  Write-Host "Starting VM '$VMName'..."
  Start-VM -Name $VMName
} else {
  Write-Host "VM '$VMName' already running."
}

$deadline = (Get-Date).AddSeconds($TimeoutSec)
$ip = $null
while ((Get-Date) -lt $deadline) {
  Start-Sleep -Seconds 3
  try {
    $ips = @((Get-VMNetworkAdapter -VMName $VMName -ErrorAction Stop).IPAddresses |
             Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' })
    if ($ips.Count -gt 0) { $ip = $ips[0]; break }
  } catch { }
  Write-Host "  waiting for IP... ($([int]((Get-Date) - $deadline).TotalSeconds * -1)s)"
}

# Fall back to ARP table lookup by VM MAC
if (-not $ip) {
  $mac = (Get-VMNetworkAdapter -VMName $VMName).MacAddress
  if ($mac) {
    $macDash = ($mac -replace '(..)(..)(..)(..)(..)(..)', '$1-$2-$3-$4-$5-$6').ToUpper()
    $ip = (Get-NetNeighbor -ErrorAction SilentlyContinue |
           Where-Object { $_.LinkLayerAddress -eq $macDash } |
           Select-Object -First 1 -ExpandProperty IPAddress)
    if ($ip) { Write-Host "  IP found via ARP: $ip" }
  }
}

$vm = Get-VM -Name $VMName
Write-Host "`nVM state : $($vm.State)"
if ($ip) {
  Write-Host "VM IP    : $ip" -ForegroundColor Green
  Write-Host "SSH test : ssh <user>@$ip"
} else {
  Write-Warning "No IP reported. Enable the 'Data Exchange' integration service, or check the ARP table manually:"
  Get-NetNeighbor -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.State -ne 'Unreachable' } |
    Select-Object IPAddress, LinkLayerAddress, State |
    Sort-Object IPAddress |
    Format-Table -AutoSize
}
