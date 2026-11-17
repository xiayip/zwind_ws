## Set up devices on a new board

```bash
sudo ./setup_device_all.sh
```

The script installs the Zephyr-managed Gemini 305 udev rule and reloads udev.
Reconnect an already attached camera if its USB-device permissions do not
update immediately.

## Waveshare 8.9-inch display and touch (Jetson desktop)

Step 4 of `setup_ws.sh` configures the validated Ubuntu 24.04 / GNOME 46
desktop and GDM login screen for the Waveshare 8.9-inch 600x1600 LCD.
To run only this step from the workspace root:

```bash
sudo bash scripts/startup/setup_waveshare_display.sh nvidia
```

The saved layout uses `DP-0`, native 600x1600 at 59.991 Hz, rotated `right`
to display in 1600x600 landscape. Although connected via HDMI, this Jetson
reports the connector as `DP-0`. The profile matches EDID
`HLT / WaveShsare089 / 0x00000001`; the product spelling is intentional.
Different connectors or panel EDIDs need a corresponding profile update in
`waveshare-monitors.xml` and, for a different EDID, the helper's `TOUCH_OUTPUT`.

The installer merges this single-screen profile into the desktop user's and
GDM's `~/.config/monitors.xml`, preserving unrelated monitor arrangements.
Changed existing files are backed up once as `monitors.xml.before-waveshare`.
It also binds USB touchscreen `0712:000a` to that monitor in each account's
GNOME settings, so touch follows display rotation without a fixed `xinput`
device ID or a second calibration matrix.

The step can run without a connected screen or graphical session. An active
desktop receives the touch mapping immediately; the saved display layout
applies on the next login/boot. It does not restart GDM or reboot. Repeat runs
are safe. Boot firmware and text-console orientation are outside this setup.

This uses GNOME's [saved monitor configuration](https://gitlab.gnome.org/GNOME/mutter/-/blob/gnome-46/doc/monitor-configuration.md)
and [GDM monitor layout](https://discourse.gnome.org/t/how-do-you-configure-your-displays-for-gdm/13762).

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

The fix has four parts:

- Apply the older NVIDIA hardware-CS workaround to `spi-tegra114`. The two
  newer software-CS patches did not restore internal loopback on this BSP.
- Before opening CAN1, clear only the SFIO bit of PY.04 (`0x0243d020`) so the
  MCP2518FD INT signal is handled as GPIO, preventing the IRQ storm.
- Hold CAN1 standby GPIO low with a persistent systemd service. Configure
  CAN0 at 500 kbps for Ranger Mini V3 and CAN1 at 1 Mbps for the RS arm.
  Other boards retain the existing 1 Mbps configuration on both interfaces.
- Keep CAN1's SPI controller powered during operation (`power/control=on`),
  avoiding runtime suspend/resume between the arm's 5 ms command batches.
  The Robotics-board startup branch resolves the controller through CAN1's
  sysfs device path and verifies the setting before opening CAN1. On the
  validated board this controller is `3230000.spi`.

This power setting trades some idle power consumption for more predictable
CAN delivery. Read-only load tests found runtime resume delays up to 4.355 ms
under video load; keeping the controller powered removed those resume events.
It addresses a measured source of latency, but does not guarantee that all
`EAGAIN` or other CAN failures are eliminated. Queue size, CAN bitrate and the
kernel driver are unchanged by this power setting.

After stopping robot control, restore runtime power management temporarily with:

```bash
echo auto | sudo tee /sys/bus/platform/devices/3230000.spi/power/control
```

This lasts until the device setup service next runs or the board reboots;
the installed startup script reapplies `on`. Do not restart the device setup
service during robot operation: it also takes down and reconfigures CAN links.

The installer leaves the vendor module intact and installs an override under
`/lib/modules/6.8.12-1021-tegra/updates/zephyr/`. It installs the startup files
but does not reload the live driver, restart CAN interfaces, or reboot.
The startup script starts the GPIO service. A kernel update requires rebuilding
and revalidating this fix. An image containing SPI in initrd is rejected rather
than silently retaining an old boot module.

Validation before swapping the CAN wiring: CAN1 hardware loopback 100/100; Ranger passive
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
