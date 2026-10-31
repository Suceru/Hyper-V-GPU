#Requires -RunAsAdministrator
<#
.SYNOPSIS
  Precheck: can this Windows host expose a partitionable GPU to a Hyper-V VM?
.PARAMETER VMName
  Target Hyper-V VM name (default: "Ubuntu 22.04 LTS")
#>
param([string]$VMName = "Ubuntu 22.04 LTS")

$ErrorActionPreference = 'Continue'
function Section($t) { Write-Host "`n===== $t =====" -ForegroundColor Cyan }

Section "GPU / display adapters"
Get-CimInstance Win32_VideoController -Property * |
  Select-Object Name, DriverVersion, PNPDeviceID, CurrentHorizontalResolution, CurrentVerticalResolution, Status |
  Format-List

Section "GPU-PV capable GPUs (Get-VMHostPartitionableGpu)"
$gpus = @(Get-VMHostPartitionableGpu -ErrorAction SilentlyContinue)
if ($gpus.Count -eq 0) {
  Write-Warning "No partitionable GPU found. Update the GPU driver first, or this GPU does not support GPU-PV."
} else {
  $gpus | Select-Object Name, PartitionCount, ValidPartitionCounts | Format-List
  Write-Host "OK: $($gpus.Count) partitionable GPU(s) found." -ForegroundColor Green
}

Section "DDA assignable devices (normally 0 on Windows client SKUs)"
@(Get-VMHostAssignableDevice -ErrorAction SilentlyContinue).Count

Section "Virtual machines"
Get-VM | Select-Object Name, Generation, Version, State, ProcessorCount, MemoryAssigned | Format-Table -AutoSize

Section "Target VM: $VMName"
$vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
if (-not $vm) {
  Write-Warning "VM '$VMName' not found."
} else {
  $vm | Select-Object Name, Id, Generation, Version, State | Format-List
  Get-VMMemory -VMName $VMName | Select-Object DynamicMemoryEnabled, Startup, Minimum, Maximum | Format-List
  Get-VMFirmware -VMName $VMName | Select-Object SecureBoot, SecureBootTemplate | Format-List
  $cp = @(Get-VMSnapshot -VMName $VMName -ErrorAction SilentlyContinue)
  Write-Host "Checkpoints: $($cp.Count)  (GPU-PV does not support checkpoints)"
  Get-VMNetworkAdapter -VMName $VMName | Select-Object Name, SwitchName, MacAddress, IPAddresses | Format-List
  Write-Host "Existing GPU partition adapters:"
  try { Get-VMGpuPartitionAdapter -VMName $VMName -ErrorAction Stop | Select-Object InstancePath | Format-List }
  catch { Write-Host "  (none)" }
}

Section "Integration services (Data Exchange helps auto IP detection)"
Get-VMIntegrationService -VMName $VMName -ErrorAction SilentlyContinue |
  Select-Object Name, Enabled | Format-Table -AutoSize

Write-Host "`nPrecheck done. Next: .\02-host-prep.ps1 -VMName '$VMName' (VM must be Off)." -ForegroundColor Green
