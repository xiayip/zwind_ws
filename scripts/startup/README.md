## Setup environment for a new board

```
./setup_device_all.sh
```

## Tailscale

The setup script installs and enables `tailscaled` on the **host**, then
installs `zephyr_tailscale_join.service`. The ROS container uses host networking,
so it automatically uses the host Tailnet connection.

Before running the setup script, create `/etc/zephyr/robot.env` with root-only
permissions (`0600`) and include a reusable, pre-authorized Tailscale auth key:

```text
TAILSCALE_AUTH_KEY=tskey-auth-...
TAILSCALE_HOSTNAME=zephyr-robot-01
TAILSCALE_ADVERTISE_TAGS=tag:robot
# Optional: true or false. Omit to use Tailscale's default.
TAILSCALE_ACCEPT_DNS=true
```

`TAILSCALE_HOSTNAME`, `TAILSCALE_ADVERTISE_TAGS`, and
`TAILSCALE_ACCEPT_DNS` are optional. The join service does not print the auth
key. Once registered, Tailscale stores the persistent machine identity on the
host and reconnects automatically after Docker or host restarts.