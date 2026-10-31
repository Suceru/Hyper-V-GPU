#!/bin/bash
# GPU-PV self-check for Hyper-V Ubuntu guest (AMD Radeon via D3D12/Dozen)
echo "================ GPU-PV SELF CHECK ================"
echo "[kernel]"
uname -r
echo
echo "[dxgkrnl module]"
lsmod | grep -E 'dxgkrnl|vgem' || echo "dxgkrnl NOT loaded"
echo
echo "[/dev/dxg]"
ls -l /dev/dxg 2>/dev/null || echo "/dev/dxg missing"
echo
echo "[OpenGL renderer (D3D12)]"
DISPLAY=:0 GALLIUM_DRIVER=d3d12 glxinfo -B 2>/dev/null | grep -E "OpenGL renderer|OpenGL version|Accelerated" || echo "no X display / glxinfo unavailable"
echo
echo "[Vulkan (Dozen)]"
VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/dzn_icd.x86_64.json vulkaninfo --summary 2>/dev/null | grep -E "deviceName|driverName|driverInfo"
echo
echo "[late-load service]"
systemctl is-enabled load-dxg-late.service 2>/dev/null
echo "==================================================="
