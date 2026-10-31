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
# Guards are essential:
#  - /etc/profile is sourced by xrdp's startwm.sh -> without XRDP_SESSION/DISPLAY
#    guards the env leaks into the GNOME Xorg enhanced session and breaks it.
#  - GNOME Shell (Wayland) must not see GALLIUM_DRIVER=d3d12 at startup (black screen).
cat > /etc/profile.d/gpu-pv.sh <<'EOF'
# GPU-PV (Hyper-V GPU partitioning) environment.
# Shell-only on purpose: exporting these in a GUI/X session makes GNOME Shell
# fail to start (Wayland black screen; xrdp/Xorg enhanced session broken).
# Do NOT move these into /etc/environment.
case $- in
  *i*)
    if [ -z "${XRDP_SESSION:-}" ] && [ -z "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ]; then
      export GALLIUM_DRIVER=d3d12
      export DRI_PRIME=1
      export LIBVA_DRIVER_NAME=d3d12
    fi
    ;;
esac
EOF
chmod 644 /etc/profile.d/gpu-pv.sh

for home in "$TARGET_HOME" /root; do
  [ -d "$home" ] || continue
  if ! grep -q "GPU-PV Configuration (interactive shells" "$home/.bashrc" 2>/dev/null; then
    cat >> "$home/.bashrc" <<'EOF'

# GPU-PV Configuration (interactive shells; skipped in xrdp GUI sessions)
if [ -z "${XRDP_SESSION:-}" ]; then
  export GALLIUM_DRIVER=d3d12
  export DRI_PRIME=1
  export LIBVA_DRIVER_NAME=d3d12
fi
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

echo "[STEP 6] optional: repair xrdp TLS cert (needed by Hyper-V enhanced session)"
if [ -d /etc/xrdp ]; then
  if [ ! -r /etc/xrdp/cert.pem ] || [ ! -r /etc/xrdp/key.pem ]; then
    echo "  broken/missing xrdp cert, regenerating"
    rm -f /etc/xrdp/cert.pem /etc/xrdp/key.pem
    openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 3650       -keyout /etc/xrdp/key.pem -out /etc/xrdp/cert.pem       -subj "/CN=$(hostname)" >/dev/null 2>&1
    chown root:xrdp /etc/xrdp/key.pem /etc/xrdp/cert.pem 2>/dev/null || true
    chmod 640 /etc/xrdp/key.pem
    chmod 644 /etc/xrdp/cert.pem
    systemctl restart xrdp xrdp-sesman 2>/dev/null || true
  else
    echo "  xrdp cert OK"
  fi
fi

echo "[OK] post-config done. Reboot now: sudo reboot ; then run: gpu-check"
