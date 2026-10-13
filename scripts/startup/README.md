## Set up devices on a new board

```bash
sudo ./setup_device_all.sh
```

The script installs the Zephyr-managed Gemini 305 udev rule and reloads udev.
Reconnect an already attached camera if its USB-device permissions do not
update immediately.

## J401 GMSL (optional, host only)

For the validated J401 / JetPack 7.2 GMSL BSP:

```bash
sudo bash setup_j401_gmsl.sh
# Reboot separately when ready.
```

This board-specific configuration is deliberately separate from setup_device_all.sh.
See [the camera guide](../../docs/gmsl/README.md) for Docker dependencies,
launch commands and rollback via `rollback_j401_gmsl.sh`.

## J401 Robotics CAN (JetPack 7.2 / R39.2)

`setup_device_all.sh` (also called by `setup_ws.sh`) detects the validated
Robotics board and runs `setup_j401_can.sh`. To install only this fix:

```bash
sudo bash scripts/startup/setup_j401_can.sh
# Reboot separately when ready, then check:
ip -s -d link show can1
timeout 10 candump can1
```

Supported kernel: `6.8.12-1021-tegra`. Other kernels are rejected until the
source, ABI and pinmux have been revalidated. Required tools include curl,
patch, make, gcc, kmod, busybox, libgpiod v1 and prepared kernel headers at
the path checked by the installer. Source is downloaded from NVIDIA and
SHA-256 checked; no compiled module or credentials are committed.

The fix has three parts:

- Apply the older NVIDIA hardware-CS workaround to `spi-tegra114`. The two
  newer software-CS patches did not restore internal loopback on this BSP.
- Before opening CAN1, clear only the SFIO bit of PY.04 (`0x0243d020`) so the
  MCP2518FD INT signal is handled as GPIO, preventing the IRQ storm.
- Hold CAN1 standby GPIO low with a persistent systemd service. Configure
  CAN0 at 1 Mbps and CAN1 at 500 kbps for Ranger Mini V3. Other boards retain
  the existing 1 Mbps CAN1 configuration.

The installer leaves the vendor module intact and installs an override under
`/lib/modules/6.8.12-1021-tegra/updates/zephyr/`. It installs the startup files
but does not reload the live driver, restart CAN interfaces, or reboot.
The startup script starts the GPIO service. A kernel update requires rebuilding
and revalidating this fix. An image containing SPI in initrd is rejected rather
than silently retaining an old boot module.

Validation on the affected board: hardware loopback 100/100; Ranger passive
reception at 500 kbps received 14,121 frames in 15 seconds with zero CAN errors.
No motion commands were sent. Boot persistence must be verified after reboot.

To remove only the SPI override and select the original module on next boot:

```bash
sudo bash scripts/startup/setup_j401_can.sh rollback
```

The independent pinmux, standby and bitrate setup remains in place. Original
module and pre-install startup script backups are in `/var/lib/zephyr/j401-can/`.
Re-running setup reinstalls the override.

Upstream workaround:
https://forums.developer.nvidia.com/t/jetson-orin-nano-spi-speed-not-changing/311083/9
