#!/bin/bash
# Build/install the dxgkrnl DKMS module (WSL2 kernel driver) and deploy:
#   - Microsoft Linux D3D12 libraries  -> /usr/lib/wsl/lib
#   - Host GPU vendor driver files     -> /usr/lib/wsl/drivers
#   - vgem module + late-load systemd unit for dxgkrnl
#
# Expected DEPLOY layout (default: ~/gpu-pv):
#   assets/dxgkrnl-{5.15,6.6,6.12}-patched.tar.gz
#   lib/libd3d12.so lib/libd3d12core.so lib/libdxcore.so
#   driver-pack.tar.gz
#
# Usage: sudo DEPLOY_DIR=$HOME/gpu-pv ./02-dxgkrnl-deploy.sh
set -e
if [ "$EUID" -ne 0 ]; then exec sudo "$0" "$@"; fi

TARGET_USER="${SUDO_USER:-$(id -un)}"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
DEPLOY="${DEPLOY_DIR:-$TARGET_HOME/gpu-pv}"

KERNEL="$(uname -r)"
KMAJ="${KERNEL%%.*}"
KREST="${KERNEL#*.}"
KMIN="${KREST%%.*}"

# Select the pre-patched source package compatible with the running kernel.
if [ "$KMAJ" -eq 5 ]; then
  PKG_VER="5.15"
elif [ "$KMAJ" -eq 6 ] && [ "$KMIN" -le 6 ]; then
  PKG_VER="6.6"
else
  PKG_VER="6.12"
fi

SRC_TAR="$DEPLOY/assets/dxgkrnl-${PKG_VER}-patched.tar.gz"
DRIVER_PACK="$DEPLOY/driver-pack.tar.gz"
LIB_DIR="$DEPLOY/lib"

echo "[STEP 0] sanity"
echo "  kernel        : $KERNEL"
echo "  target user   : $TARGET_USER"
echo "  deploy dir    : $DEPLOY"
echo "  kernel package: dxgkrnl-${PKG_VER}-patched"
for f in "$SRC_TAR" "$DRIVER_PACK"; do
  [ -f "$f" ] || { echo "[ERROR] missing file: $f"; exit 1; }
done
ls "$LIB_DIR"/*.so >/dev/null 2>&1 || { echo "[ERROR] missing libraries in $LIB_DIR"; exit 1; }

if [ ! -e "/lib/modules/$KERNEL/build" ]; then
  echo "[STEP] kernel headers missing, installing linux-headers-$KERNEL"
  apt-get update -qq
  if ! apt-get install -y "linux-headers-$KERNEL"; then
    echo "[ERROR] cannot install kernel headers for $KERNEL; install a matching kernel first."
    exit 1
  fi
fi

echo "[STEP 1] build and install dxgkrnl via DKMS"
rm -rf /tmp/dxg-src /usr/src/dxgkrnl-custom
mkdir -p /tmp/dxg-src
tar -xzf "$SRC_TAR" -C /tmp/dxg-src
SRC_DIR="$(find /tmp/dxg-src -maxdepth 1 -mindepth 1 -type d | head -1)"
[ -n "$SRC_DIR" ] || { echo "[ERROR] unexpected source archive layout"; exit 1; }
cp -r "$SRC_DIR" /usr/src/dxgkrnl-custom

cat > /usr/src/dxgkrnl-custom/Makefile <<'MAKEEOF'
obj-m := dxgkrnl.o
dxgkrnl-y := dxgmodule.o hmgr.o misc.o dxgadapter.o ioctl.o dxgvmbus.o dxgprocess.o dxgsyncfile.o
ccflags-y := -I$(src)/include -D_MAIN_KERNEL_

all:
	make -C /lib/modules/$(shell uname -r)/build M=$(PWD) modules
clean:
	make -C /lib/modules/$(shell uname -r)/build M=$(PWD) clean
MAKEEOF

cat > /usr/src/dxgkrnl-custom/dkms.conf <<'DKMS'
PACKAGE_NAME="dxgkrnl"
PACKAGE_VERSION="custom"
BUILT_MODULE_NAME="dxgkrnl"
DEST_MODULE_LOCATION="/kernel/drivers/hv/dxgkrnl/"
AUTOINSTALL="yes"
DKMS

dkms add dxgkrnl/custom 2>&1 | tail -1 || true
dkms build dxgkrnl/custom
dkms install dxgkrnl/custom --force
dkms status | grep dxgkrnl || true

echo "[STEP 2] deploy Microsoft D3D12 libraries + GPU driver files"
mkdir -p /usr/lib/wsl/lib /usr/lib/wsl/drivers
tar -xzf "$DRIVER_PACK" -C /usr/lib/wsl/drivers
cp -a "$LIB_DIR/"*.so* /usr/lib/wsl/lib/
ln -sf /usr/lib/wsl/lib/libd3d12core.so /usr/lib/wsl/lib/libD3D12Core.so
chmod -R 0555 /usr/lib/wsl
chown -R root:root /usr/lib/wsl
echo "/usr/lib/wsl/lib" > /etc/ld.so.conf.d/ld.wsl.conf
ldconfig
echo "  driver DLL count: $(find /usr/lib/wsl/drivers -name '*.dll' | wc -l)"
echo "  libs: $(ls /usr/lib/wsl/lib | tr '\n' ' ')"

echo "[STEP 3] kernel module load strategy (vgem + late dxgkrnl)"
echo "vgem" > /etc/modules-load.d/vgem.conf
modprobe vgem || true
echo "blacklist dxgkrnl" > /etc/modprobe.d/blacklist-dxgkrnl.conf
update-initramfs -u >/dev/null 2>&1 || true

cat > /usr/local/bin/load_dxg_driver.sh <<'DGX'
#!/bin/bash
modprobe dxgkrnl
if [ -e /dev/dxg ]; then chmod 666 /dev/dxg; fi
DGX
chmod +x /usr/local/bin/load_dxg_driver.sh

cat > /etc/systemd/system/load-dxg-late.service <<'SVC'
[Unit]
Description=Late load dxgkrnl (GPU-PV)
After=graphical.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/load_dxg_driver.sh
Restart=on-failure
RestartSec=5

[Install]
WantedBy=graphical.target
SVC
systemctl daemon-reload
systemctl enable load-dxg-late.service 2>&1 | tail -1 || true

cat > /etc/udev/rules.d/99-dxgkrnl.rules <<'UDEV'
KERNEL=="dxg", MODE="0666"
UDEV
cat > /etc/udev/rules.d/99-gpu-pv-perms.rules <<'UDEV2'
KERNEL=="card[0-9]*", SUBSYSTEM=="drm", MODE="0666"
KERNEL=="renderD*", SUBSYSTEM=="drm", MODE="0666"
UDEV2

echo "[STEP 4] try loading the module now (informational)"
modprobe dxgkrnl 2>/dev/null && echo "  modprobe OK" || echo "  modprobe deferred to boot (expected)"
ls -l /dev/dxg 2>/dev/null || true

echo "[OK] deployment done. Next: sudo DEPLOY_DIR=$DEPLOY ./03-post-config.sh && sudo reboot"
