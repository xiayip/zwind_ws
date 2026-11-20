## Set up devices on a new board

```bash
sudo ./setup_device_all.sh
```

The script installs the Zephyr-managed Gemini 305 udev rule and reloads udev.
Reconnect an already attached camera if its USB-device permissions do not
update immediately.

### WHEELTEC C12H / ICM20948

`setup_ws.sh` installs the C12H serial rule with `setup_c12h.sh`, alongside the
existing device setup. Run just this addition with:

```bash
sudo ./scripts/startup/setup_c12h.sh
```

It installs a udev rule for CH9102F `1a86:55d4`, serial `5A9B085467`
(`/dev/c12h`, dialout/uaccess, ModemManager ignore). A replacement board requires
updating the serial in `99-zephyr-c12h.rules`. Rules apply on the next USB
reconnection; the existing `/dev/serial/by-id/...` path remains usable.

The shared `Dockerfile.zephyr` does not add C12H preview dependencies, and
`setup_ws.sh` does not install host `xauth`. RViz testing is optional: the firmware
repository's `setup-gui.sh` builds a separate GUI image with
`ros-jazzy-imu-filter-madgwick` and `ros-jazzy-rviz-imu-plugin` only when requested.
For a local X11/XWayland desktop, run on the host from the workspace root:

```bash
# Only if xauth is missing and desktop testing is needed:
sudo apt-get install --no-install-recommends xauth
cd ../hatch_actuator_node
./scripts/microros/setup-gui.sh
./scripts/microros/rviz.sh
```

The preview defaults to six-axis attitude fusion. All nine raw sensor axes remain
available at 50 Hz. Add `use_mag:=true` only when evaluating magnetic fusion;
the uncalibrated magnetometer can cause attitude correction for seconds after
motion stops. Six-axis yaw is relative and can drift over longer periods.

`z2_bringup real_world.launch.py` starts the serial micro-ROS Agent at
**921600 8N1** when the C12H device is present. Mock bringup does not start it.
The shared image copies the pinned Jazzy ARM64 Agent installation and adds
`psmisc` for checking serial ownership, without GUI dependencies. Older images
need rebuilding/recreating. For a bridge-only test inside the workspace container:

```bash
source install/setup.bash
ros2 launch z2_bringup c12h_agent.launch.py
```

Only one Agent should own the port. Use `start_c12h_agent:=false` on real-world
bringup when keeping a separately managed Agent. The automatic check runs once
at startup; a board absent then requires restarting bringup after connection.
Firmware 0.3.1 uses the default ROS domain 0. There is no C12H-specific ROS
environment file or DDS profile. Containers use the workspace's existing
`--network host --ipc=host` arrangement. The custom `/hatch/status` message additionally
requires the `hatch_interfaces` overlay; standard IMU/magnetic topics do not.

For a non-root, non-mutating installation check, pass an absolute staging root
to `setup_c12h.sh`. The complete `setup_ws.sh` also changes other device/desktop
settings; use the dedicated helper when only updating C12H serial permissions.

## Waveshare 8.9-inch display and touch (Jetson desktop)

Step 4 of `setup_ws.sh` configures the validated Ubuntu 24.04 / GNOME 46
desktop and GDM login screen for the Waveshare 8.9-inch 600x1600 LCD.
To run only this step from the workspace root:

```bash
sudo bash scripts/startup/setup_waveshare_display.sh nvidia
```

The saved layouts cover `DP-0` and `DP-1`, native 600x1600 at 59.991 Hz, rotated `left`
to display in 1600x600 landscape (180° from the previous `right` orientation).
Although connected via HDMI, this Jetson reports `DP-0` with the NVIDIA X driver
or `DP-1` with the modesetting fallback. Both profiles use the same panel EDID.
The profile matches EDID
`HLT / WaveShsare089 / 0x00000001`; the product spelling is intentional.
Different connectors need an update to the helper's connector list. Different
panel EDIDs require updating `waveshare-monitors.xml` and the helper's `TOUCH_OUTPUT`.

The installer merges these single-screen profiles into the desktop user's and
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
rebuild. Desktop login autostart waits for the service; step 7 configures automatic
OS login separately. ROS/Docker startup still needs to be configured separately.
After manually closing the browser,
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

## Desktop automatic login

Step 7 of `setup_ws.sh` enables GDM automatic login for the user running setup
(normally `nvidia`). To run only this step:

```bash
sudo python3 scripts/startup/setup_desktop_autologin.py nvidia
```

The helper sets `AutomaticLoginEnable=true` and `AutomaticLogin=<desktop-user>`
in `/etc/gdm3/custom.conf`, preserving other settings, comments and permissions.
Before the first change it saves `custom.conf.before-zephyr-autologin` beside
the original. Repeat runs are safe. It takes effect on the next boot and does
not restart GDM or the current session. System passwords and HMI's password
exit remain configured; only the desktop login prompt is skipped at boot.

## Desktop notification banners

Step 8 of `setup_ws.sh` enables GNOME's **Do Not Disturb** for the desktop user
and disables low-disk-space notifications. To apply only this step on the host,
without sudo:

```bash
bash /home/nvidia/zephyr_ws/scripts/startup/setup_desktop_notifications.sh
```

The settings apply immediately and persist across logins/reboots. Ordinary
notifications remain in the notification center. GNOME can show critical
notifications even in Do Not Disturb, so the helper also sets housekeeping's
`free-percent-notify` to `0.0` and disables the `org-gnome-baobab` notification
source used by disk-space warnings. Other critical system notifications may
still appear. HMI's own fault display is independent of these desktop settings.
Disk usage is still available through `df -h` or Disk Usage Analyzer.

To restore the GNOME defaults:

```bash
gsettings reset org.gnome.desktop.notifications show-banners
gsettings reset org.gnome.settings-daemon.plugins.housekeeping free-percent-notify
gsettings reset org.gnome.desktop.notifications.application:/org/gnome/desktop/notifications/application/org-gnome-baobab/ enable
```

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
