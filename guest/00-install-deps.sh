#!/bin/bash
# Install build dependencies required for the dxgkrnl DKMS module and graphics stack.
set -e
if [ "$EUID" -ne 0 ]; then exec sudo "$0" "$@"; fi

export DEBIAN_FRONTEND=noninteractive
echo "[STEP] apt-get update"
apt-get update

echo "[STEP] install build dependencies"
apt-get install -y --no-install-recommends \
  build-essential dkms git curl wget unzip software-properties-common ca-certificates

echo "[OK] dependencies installed. Next: sudo ./01-graphics-stack.sh"
