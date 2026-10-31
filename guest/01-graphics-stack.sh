#!/bin/bash
# Install the graphics stack used by GPU-PV on Ubuntu 22.04:
#   - Ubuntu Mesa (contains d3d12_dri.so -> OpenGL on D3D12)
#   - Kisak PPA Mesa (contains dzn_icd -> "Dozen" Vulkan-on-D3D12)
# Optional: USE_CN_MIRROR=1 switches apt sources to mirrors.aliyun.com.
set -e
if [ "$EUID" -ne 0 ]; then exec sudo "$0" "$@"; fi
export DEBIAN_FRONTEND=noninteractive

USE_CN_MIRROR="${USE_CN_MIRROR:-0}"
if [ "$USE_CN_MIRROR" = "1" ]; then
  . /etc/os-release
  CN_CODENAME="${UBUNTU_CODENAME:-${VERSION_CODENAME:-jammy}}"
  echo "[STEP] switching apt mirror to mirrors.aliyun.com ($CN_CODENAME)"
  cp /etc/apt/sources.list "/root/sources.list.bak.$(date +%s)" 2>/dev/null || true
  cat > /etc/apt/sources.list <<EOF
deb http://mirrors.aliyun.com/ubuntu/ ${CN_CODENAME} main restricted universe multiverse
deb http://mirrors.aliyun.com/ubuntu/ ${CN_CODENAME}-updates main restricted universe multiverse
deb http://mirrors.aliyun.com/ubuntu/ ${CN_CODENAME}-backports main restricted universe multiverse
deb http://mirrors.aliyun.com/ubuntu/ ${CN_CODENAME}-security main restricted universe multiverse
EOF
fi

echo "[STEP] apt-get update"
apt-get update -qq

echo "[STEP] pin Ubuntu Mesa GL libraries (native Mesa supports the d3d12 driver)"
cat > /etc/apt/preferences.d/00-mesa-hold-gl <<'EOF'
Package: libgl1-mesa-dri libglapi-mesa libglx-mesa0 libgbm1
Pin: release o=Ubuntu
Pin-Priority: 1001
EOF

echo "[STEP] install/upgrade Ubuntu Mesa GL stack + tools"
apt-get install -y --allow-downgrades \
  libgl1-mesa-dri libglapi-mesa libglx-mesa0 libgbm1 \
  mesa-utils mesa-va-drivers vainfo

echo "[STEP] add kisak/turtle PPA for Mesa Dozen (Vulkan-on-D3D12)"
add-apt-repository -y ppa:kisak/turtle
apt-get update -qq
cat > /etc/apt/preferences.d/99-mesa-pinning <<'EOF'
Package: mesa-vulkan-drivers
Pin: version *kisak*
Pin-Priority: 900
EOF
apt-get install -y mesa-vulkan-drivers vulkan-tools

echo "[STEP] verify"
echo "--- mesa versions ---"
dpkg -l libgl1-mesa-dri mesa-vulkan-drivers mesa-utils vulkan-tools 2>/dev/null | grep '^ii' || true
echo "--- d3d12 gallium driver ---"
ls -l /usr/lib/x86_64-linux-gnu/dri/ | grep -i d3d12 || echo "WARN: d3d12_dri.so missing"
echo "--- vulkan ICDs ---"
ls -l /usr/share/vulkan/icd.d/ 2>/dev/null || true

if ! ls /usr/share/vulkan/icd.d/ 2>/dev/null | grep -q dzn; then
  echo "[WARN] dzn ICD not found; Vulkan (Dozen) may be unavailable."
fi

echo "[OK] graphics stack installed. Next: sudo DEPLOY_DIR=\$HOME/gpu-pv ./02-dxgkrnl-deploy.sh"
