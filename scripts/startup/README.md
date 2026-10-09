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
