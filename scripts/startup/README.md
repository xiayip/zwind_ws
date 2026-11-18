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

The saved layout uses `DP-0`, native 600x1600 at 59.991 Hz, rotated `left`
to display in 1600x600 landscape (180° from the previous `right` orientation).
Although connected via HDMI, this Jetson reports the connector as `DP-0`.
The profile matches EDID
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

## HMI browser and desktop autostart

Step 5 of `setup_ws.sh` installs a working Chromium/Chrome browser on the host
and configures the desktop user's existing HMI fullscreen launcher. Run only
this step as `nvidia` on the Jetson host (not as `admin` inside Docker):

```bash
bash /home/nvidia/zephyr_ws/scripts/startup/setup_hmi_kiosk.sh
```

Run without `sudo`; the script requests it only when installing dependencies.
If no usable browser exists, it installs Canonical's [Chromium Snap](https://snapcraft.io/chromium).
It installs the HMI login autostart entry and starts the launcher in the current
desktop session when available, including from SSH using that user's desktop
environment. The launcher waits for `http://127.0.0.1:8765/healthz`, then opens
fullscreen on the unique 1600x600 display. Logs go to
`~/.local/state/zephyr-courier-kiosk/launcher.log`.
On X11, it also requests fullscreen after the browser window appears, matching
only the launched browser PID. This handles Jetson/GNOME sessions that retain
desktop bars despite Chromium's kiosk flags. Required X11/GDK host packages
are installed by this setup step.

When the HMI checkout includes `scripts/host-network-status.py`, the step also
installs `python3-dbus` and enables the user's `zephyr-hmi-network.service`.
The sampler writes Wi-Fi/cellular state and signal readings to
`${XDG_STATE_HOME:-$HOME/.local/state}/zephyr-hmi/network.json`; new development
containers mount that directory read-only at `/run/zephyr-network`.
Older HMI checkouts skip this optional sampler with an update notice, so the
workspace setup can still complete. After updating HMI, rerun this helper.
The host's D-Bus socket is not exposed to the container.

On GNOME 46 the step also installs the user extension
`zephyr-kiosk-lock@zephyr.local`. Reload GNOME Shell or log in again after its
first installation/code update. While the dedicated HMI browser runs, it
disables desktop edge/workspace gestures and window/browser exit shortcuts,
and keeps HMI fullscreen. The **密码退出** button in the top-left device-information dialog opens a touch
keypad and verifies the HMI service's maintenance password before closing
the browser. The packaged `zephyr_hmi/defaults.json` currently sets it to `200440`;
`KIOSK_MAINTENANCE_PIN` can override it, or disable password access with an empty value.
Wrong/disabled passwords and an offline HMI service
do not unlock the screen. The extension restores desktop input on exit.
See [HMI deployment](../../src/zephyr_interaction/zephyr_hmi/docs/DEPLOYMENT.md)
for password setup and administrative recovery over SSH.

`z2_launch_all.launch.py` starts HMI and diagnostics inside Docker by default;
`ros2 launch zephyr_hmi hmi.launch.py mode:=demo` can also start HMI independently.
The host browser is a separate process; it needs no container
rebuild. Desktop login autostart waits for the service, but does not configure
automatic OS login or start ROS/Docker. After manually closing the browser,
rerun the setup helper or HMI's `scripts/run-kiosk.sh` to reopen it.

## Screen blanking: Never

Step 6 of `setup_ws.sh` saves GNOME's **Settings > Power > Screen Blank = Never**
for the desktop user (`org.gnome.desktop.session idle-delay = uint32 0`).
To apply only this setting as `nvidia` on the host, without sudo:

```bash
bash /home/nvidia/zephyr_ws/scripts/startup/setup_screen_blanking.sh
```

The setting applies to the active desktop immediately and persists across
logins/reboots. The helper also supports installation before a desktop login
by writing the user's settings through a temporary D-Bus session.

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
