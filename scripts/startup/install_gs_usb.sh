#!/usr/bin/env bash
set -euo pipefail

# Build, install and load the gs_usb kernel module for USB-CAN adapters.

KERNEL_VERSION="$(uname -r)"
LINUX_TAG="${GS_USB_LINUX_TAG:-v6.8}"
BUILD_DIR="${GS_USB_BUILD_DIR:-$HOME/gs_usb_build}"
MODULE_DIR="/lib/modules/${KERNEL_VERSION}/kernel/drivers/net/can/usb"

log() {
  echo "[gs_usb] $*"
}

if modinfo gs_usb >/dev/null 2>&1; then
  log "gs_usb module already available, nothing to do"
  exit 0
fi

log "Installing build dependencies"
sudo apt update
sudo apt install -y build-essential

log "Preparing build directory: $BUILD_DIR"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

log "Downloading gs_usb.c (linux ${LINUX_TAG})"
curl -fSL -o gs_usb.c \
  "https://raw.githubusercontent.com/torvalds/linux/${LINUX_TAG}/drivers/net/can/usb/gs_usb.c"

log "Writing Makefile"
cat > Makefile <<'EOF'
obj-m := gs_usb.o

KDIR ?= /lib/modules/$(shell uname -r)/build
PWD  := $(shell pwd)

all:
	$(MAKE) -C $(KDIR) M=$(PWD) modules

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean
EOF

log "Building module"
make

log "Installing module to $MODULE_DIR"
sudo mkdir -p "$MODULE_DIR"
sudo cp gs_usb.ko "$MODULE_DIR/"
sudo depmod -a

log "Loading modules"
sudo modprobe can-dev
sudo modprobe gs_usb

log "Verifying installation"
modinfo gs_usb
lsmod | grep gs_usb || true
dmesg | tail -n 20

log "gs_usb setup complete"
