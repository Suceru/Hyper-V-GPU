#Requires -RunAsAdministrator
<#
.SYNOPSIS
  Configure the host VM for GPU-PV: static/checkpoint settings, MMIO space, GPU partition adapter.
.DESCRIPTION
  - VM must be Off (use -Force to turn it off).
  - Disables automatic checkpoints (GPU-PV does not support checkpoints).
  - Disables dynamic memory if enabled (static memory recommended).
  - Sets Low/High MMIO space (memory-mapped IO for the GPU partition).
  - Adds the GPU partition adapter for the first partitionable GPU.
.PARAMETER VMName
  Hyper-V VM name (default: "Ubuntu 22.04 LTS")
.PARAMETER Force
  Turn the VM off instead of failing if it is running.
#>
param(
  [string]$VMName = "Ubuntu 22.04 LTS",
  [switch]$Force
)

$ErrorActionPreference = 'Stop'

$vm = Get-VM -Name $VMName -ErrorAction Stop
Write-Host "VM: $($vm.Name)  State: $($vm.State)  Gen: $($vm.Generation)  Version: $($vm.Version)"

if ($vm.State -ne 'Off') {
  if (-not $Force) { throw "VM must be Off before changing GPU/MMIO settings. Current state: $($vm.State). Use -Force to turn it off." }
  Stop-VM -Name $VMName -TurnOff -Force
  Start-Sleep -Seconds 3
}

$gpu = Get-VMHostPartitionableGpu -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $gpu) { throw "No partitionable GPU found (Get-VMHostPartitionableGpu is empty). Update the GPU driver first." }
Write-Host "Partitionable GPU: $($gpu.Name)" -ForegroundColor Cyan

$cp = @(Get-VMSnapshot -VMName $VMName -ErrorAction SilentlyContinue)
if ($cp.Count -gt 0) {
  Write-Warning "VM has $($cp.Count) checkpoint(s). GPU-PV does not support checkpoints; delete them while the VM is off."
  Write-Warning "Do NOT revert to a pre-deployment checkpoint: the guest-side drivers would be lost."
}

Write-Host "`n[1/4] Disable automatic checkpoints"
Set-VM -Name $VMName -AutomaticCheckpointsEnabled $false
Write-Host "  done"

Write-Host "`n[2/4] Ensure static memory (disable dynamic memory)"
$mem = Get-VMMemory -VMName $VMName
if ($mem.DynamicMemoryEnabled) {
  Set-VMMemory -VMName $VMName -DynamicMemoryEnabled $false
  Write-Host "  dynamic memory disabled (startup: $([math]::Round($mem.Startup/1GB,1)) GB)"
} else {
  Write-Host "  already static (startup: $([math]::Round($mem.Startup/1GB,1)) GB)"
}

Write-Host "`n[3/4] Set MMIO space and guest-controlled cache types"
try {
  Set-VM -Name $VMName -GuestControlledCacheTypes $true -LowMemoryMappedIoSpace 1GB -HighMemoryMappedIoSpace 64GB -ErrorAction Stop
  Write-Host "  Low=1GB High=64GB GuestControlledCacheTypes=on" -ForegroundColor Green
} catch {
  Write-Warning "64GB high MMIO failed ($($_.Exception.Message)); retrying with 32GB"
  Set-VM -Name $VMName -GuestControlledCacheTypes $true -LowMemoryMappedIoSpace 1GB -HighMemoryMappedIoSpace 32GB
  Write-Host "  Low=1GB High=32GB GuestControlledCacheTypes=on"
}

Write-Host "`n[4/4] Add GPU partition adapter"
$existing = @(Get-VMGpuPartitionAdapter -VMName $VMName -ErrorAction SilentlyContinue)
if ($existing.Count -gt 0) {
  Write-Host "  adapter already present:" -ForegroundColor Yellow
  $existing | Select-Object InstancePath | Format-List
} else {
  Add-VMGpuPartitionAdapter -VMName $VMName -InstancePath $gpu.Name
  Write-Host "  added" -ForegroundColor Green
}

Write-Host "`nResult:"
Get-VMGpuPartitionAdapter -VMName $VMName | Select-Object Name, InstancePath | Format-List

Write-Host "Host prep done. Next: .\03-start-vm.ps1 -VMName '$VMName'" -ForegroundColor Green
