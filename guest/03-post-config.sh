#!/bin/bash
# Final configuration:
#   - GPU env vars for interactive shells ONLY (NOT /etc/environment -> avoids GNOME black screen)
#   - install gpu-run (launch GUI apps with acceleration) and gpu-check (self test)
#   - DRM permissions/udev rules
#   - restart GDM so the GNOME session picks up the fixed environment
#
# Usage: sudo DEPLOY_DIR=$HOME/gpu-pv ./03-post-config.sh
set -e
if [ "$EUID" -ne 0 ]; then exec sudo "$0" "$@"; fi

TARGET_USER="${SUDO_USER:-$(id -un)}"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "[STEP 1] remove global GL override from /etc/environment (GNOME black screen fix)"
sed -i '/^GALLIUM_DRIVER=/d;/^DRI_PRIME=/d;/^LIBVA_DRIVER_NAME=/d' /etc/environment
cat /etc/environment

echo "[STEP 2] add GPU env for interactive shells only"
cat > /etc/profile.d/gpu-pv.sh <<'EOF'
# GPU-PV (Hyper-V GPU partitioning). Shell-only on purpose:
# putting these in /etc/environment makes GNOME Shell fail to start (black screen).
export GALLIUM_DRIVER=d3d12
export DRI_PRIME=1
export LIBVA_DRIVER_NAME=d3d12
EOF
chmod 644 /etc/profile.d/gpu-pv.sh

for home in "$TARGET_HOME" /root; do
  [ -d "$home" ] || continue
  if ! grep -q "GPU-PV Configuration" "$home/.bashrc" 2>/dev/null; then
    cat >> "$home/.bashrc" <<'EOF'

# GPU-PV Configuration (Hyper-V GPU partition, D3D12/Dozen)
export GALLIUM_DRIVER=d3d12
export DRI_PRIME=1
export LIBVA_DRIVER_NAME=d3d12
EOF
  fi
done

echo "[STEP 3] install helper tools"
install -m 755 "$SCRIPT_DIR/gpu-run" /usr/local/bin/gpu-run
install -m 755 "$SCRIPT_DIR/gpu-check.sh" /usr/local/bin/gpu-check
echo "  /usr/local/bin/gpu-run, /usr/local/bin/gpu-check"

echo "[STEP 4] DRM permissions"
chmod 666 /dev/dri/* 2>/dev/null || true
usermod -a -G video,render "$TARGET_USER" 2>/dev/null || true

echo "[STEP 5] restart GDM (if installed) to recreate the GNOME session"
if systemctl list-unit-files gdm3.service >/dev/null 2>&1; then
  systemctl restart gdm3 || true
  sleep 8
  systemctl is-active gdm3 || true
  ps aux | grep -E '[g]nome-shell' | head -3 || true
fi

echo "[OK] post-config done. Reboot now: sudo reboot ; then run: gpu-check"
