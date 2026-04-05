# pia-wg-refresh

Automatically refreshes Private Internet Access (PIA) WireGuard configs for Gluetun only when the tunnel is actually down. It runs alongside Gluetun in Docker, regenerates `wg0.conf` with a bundled `pia-wg-config` binary built from source, and restarts the Gluetun container only after consecutive failures.

This project bundles the [Ephemeral-Dust fork](https://github.com/Ephemeral-Dust/pia-wg-config) of [pia-wg-config](https://github.com/kylegrantlucas/pia-wg-config) (originally by Kyle Lucas), which generates WireGuard configurations for PIA. It is the tool [recommended by the Gluetun documentation](https://github.com/qdm12/gluetun-wiki/blob/main/setup/providers/private-internet-access.md#wireguard) for PIA WireGuard setups. The fork adds support for server name output and port-forwarding server filtering.

## Why

PIA WireGuard sessions can expire. If Gluetun restarts or loses the tunnel after expiry, it can get stuck until a fresh config is generated, manually or via some other means. This container monitors connectivity inside Gluetun and regenerates the config only when needed. It will also generate the wg0.conf config if it doesn't exist, so useful for those who are installing Gluetun for the first time.

## How it works

1. Check VPN status via Gluetun's control server API (`/v1/publicip/ip`).
2. When healthy, check every `HEALTHY_CHECK_INTERVAL_SECONDS` (default 30 minutes).
3. On failure, switch to faster checks every `CHECK_INTERVAL_SECONDS` (default 60s).
4. After `FAIL_THRESHOLD` consecutive failures, generate a new config and restart Gluetun.
5. If config generation fails repeatedly, stop retrying after `MAX_GENERATION_RETRIES` until connectivity recovers.
6. With port forwarding enabled, also monitors `/v1/portforward` and automatically syncs `SERVER_NAMES`.

## Requirements

- Docker socket mount (`/var/run/docker.sock`) for `docker exec` and `docker restart`/`docker compose`.
- Gluetun config directory mounted into this container at `/config`.

## Environment variables

Required:

- `PIA_USERNAME`
- `PIA_PASSWORD`
- `PIA_REGION`

Optional:

- `GLUETUN_CONTAINER` (default: `gluetun`)
- `WG_CONF_PATH` (default: `/config/wg0.conf`)
- `CHECK_INTERVAL_SECONDS` (default: `60`) - interval when tunnel is down or degraded
- `HEALTHY_CHECK_INTERVAL_SECONDS` (default: `1800`) - interval when tunnel is healthy
- `FAIL_THRESHOLD` (default: `3`) - consecutive failures before regenerating config
- `MAX_GENERATION_RETRIES` (default: `3`) - max config generation attempts before waiting for recovery
- `HEALTH_LOG_INTERVAL` (default: `10`) - log "Tunnel healthy" every N successful checks
- `LOG_LEVEL` (default: `info`) - set to `debug` for verbose logging
- `PIA_PORT_FORWARDING` (default: `false`) - enable port forwarding monitoring and server filtering
- `DOCKER_COMPOSE_HOST_DIR` (optional) - absolute host path to compose directory for automatic `SERVER_NAMES` updates
- `DOCKER_COMPOSE_ENV_FILE` (default: `.env`) - env file name to update with `SERVER_NAMES`
- `ON_FAILURE_SCRIPT` (optional) - script to run when failure threshold is reached
- `ON_RECOVERY_SCRIPT` (optional) - script to run when tunnel recovers
- `ON_PORT_CHANGE_SCRIPT` (optional) - script to run when the forwarded port changes
- `COMPOSE_UP_TIMEOUT` (default: `300`) - seconds before `docker compose up` is killed if hung; prevents pia-wg-refresh from freezing permanently if the docker daemon's container start hangs at the kernel level
- `PIA_WG_CONFIG_BIN` (default: `/usr/local/bin/pia-wg-config`)
- `PIA_WG_CONFIG_URL` (optional: if set, download/replace `pia-wg-config` on startup)
- `PIA_WG_CONFIG_SHA256` (optional: verify the download before installing)
- `SELF_TEST` (optional: set to `1` to exit after startup checks)

## Port forwarding

When using Gluetun's port forwarding feature with `VPN_SERVICE_PROVIDER=custom`, Gluetun requires `SERVER_NAMES` to match the connected PIA server. See [Gluetun issue #3070](https://github.com/qdm12/gluetun/issues/3070) for details.

### Automatic port forwarding management

Set `PIA_PORT_FORWARDING=true` and `DOCKER_COMPOSE_HOST_DIR` to enable fully automatic management:

1. Only connects to PIA servers that support port forwarding (via `-p` flag)
2. Monitors port forwarding status via Gluetun's control server API
3. Automatically syncs `SERVER_NAMES` and recreates Gluetun when needed
4. Updates your `.env` file for persistence (so future `docker compose` commands use the correct value)
5. Auto-detects the docker compose project name from container labels (no manual configuration needed)

Your `.env` file should contain:
```
PIA_USERNAME=your_user
PIA_PASSWORD=your_pass
PIA_REGION=us_chicago
SERVER_NAMES=chicago412
```

### Manual port forwarding

If `DOCKER_COMPOSE_HOST_DIR` is not set, the container will:
- Log the server name on each config generation
- Include the server name in the `wg0.conf` header for reference
- Warn when `SERVER_NAMES` needs to be updated manually

Generated config header example:
```
# Generated by pia-wg-refresh
# Date: 2025-01-11T12:00:00Z
# Region: au_melbourne
# Server: melbourne412 (use this for SERVER_NAMES if port forwarding)
```

## Hooks

You can configure scripts to run when failures occur or when the tunnel recovers. Scripts are executed asynchronously (non-blocking) so they don't delay the main monitoring loop.

Script paths can include arguments (e.g., `/scripts/notify.sh failure`).

### Failure hook

Set `ON_FAILURE_SCRIPT` to a script path (with optional arguments). The script runs when the failure threshold is reached.

Environment variables passed to the script:
- `FAILURE_TYPE` - either `connectivity` or `port_forwarding`

### Recovery hook

Set `ON_RECOVERY_SCRIPT` to a script path. The script runs when the tunnel recovers after a failure.

Environment variables passed to the script:
- `PIA_SERVER_NAME` - the connected PIA server name (e.g., `dublin423`)
- `PIA_FORWARDED_PORT` - the forwarded port number (if port forwarding is enabled)

### Port change hook

Set `ON_PORT_CHANGE_SCRIPT` to a script path. The script runs whenever the forwarded port changes, including on first discovery after startup.

Environment variables passed to the script:
- `PIA_FORWARDED_PORT` - the new forwarded port number
- `PIA_PREVIOUS_PORT` - the previous port number (empty string on first discovery)
- `PIA_SERVER_NAME` - the connected PIA server name

### Example

Using separate scripts:
```yaml
pia-wg-refresh:
  environment:
    - ON_FAILURE_SCRIPT=/scripts/notify-failure.sh
    - ON_RECOVERY_SCRIPT=/scripts/notify-recovery.sh
    - ON_PORT_CHANGE_SCRIPT=/scripts/notify-ports.sh
  volumes:
    - ./scripts:/scripts:ro
```

Using a single script with arguments:
```yaml
pia-wg-refresh:
  environment:
    - ON_FAILURE_SCRIPT=/scripts/notify.sh failure
    - ON_RECOVERY_SCRIPT=/scripts/notify.sh recover
    - ON_PORT_CHANGE_SCRIPT=/scripts/notify.sh ports
  volumes:
    - ./scripts:/scripts:ro
```

Example `notify.sh`:
```bash
#!/bin/sh
ACTION="$1"
if [ "$ACTION" = "failure" ]; then
  curl -X POST "https://your-webhook.com/notify" -d "VPN failure: $FAILURE_TYPE"
elif [ "$ACTION" = "recover" ]; then
  curl -X POST "https://your-webhook.com/notify" \
    -d "VPN recovered on server $PIA_SERVER_NAME with port $PIA_FORWARDED_PORT"
elif [ "$ACTION" = "ports" ]; then
  curl -X POST "https://your-webhook.com/notify" \
    -d "Port changed: $PIA_PREVIOUS_PORT -> $PIA_FORWARDED_PORT (server: $PIA_SERVER_NAME)"
fi
```

A working Prowl notification example covering all three hook types is available in [`scripts/pia-wg-refresh-notification.sh`](scripts/pia-wg-refresh-notification.sh).

**Important**: Hook scripts must use `#!/bin/sh` as the shebang. The container uses Alpine Linux which doesn't include bash. If your script requires bash-specific features, you'll need to modify the Dockerfile to install bash.

Hook output is logged to `/logs/hooks.log`.

## Logs

Logs are append-only in `/logs`:

- `/logs/refresh.log` - main refresh loop logs (plain text)
- `/logs/pia-wg-config.log` - output from config generation
- `/logs/docker.log` - output from docker restart/compose commands
- `/logs/hooks.log` - output from hook scripts

Console output (`docker logs`) includes colored log levels for easier reading:
- `[debug]` - cyan
- `[info]` - green
- `[warn]` - yellow
- `[error]` - red

Log files are kept as plain text without color codes.

## Docker Compose example

Basic setup:

```yaml
services:
  pia-wg-refresh:
    image: ghcr.io/ccarpinteri/pia-wg-refresh:latest
    container_name: pia-wg-refresh
    environment:
      - PIA_USERNAME=${PIA_USERNAME}
      - PIA_PASSWORD=${PIA_PASSWORD}
      - PIA_REGION=${PIA_REGION}
      - GLUETUN_CONTAINER=gluetun
    volumes:
      - ./gluetun/config/wireguard:/config
      - ./logs:/logs
      - /var/run/docker.sock:/var/run/docker.sock
    restart: unless-stopped
    healthcheck:
      test: grep -q "^Endpoint" /config/wg0.conf || exit 1
      start_period: 10s
      interval: 5s

  gluetun:
    # Pin to a specific version - gluetun:latest tracks HEAD and can ship regressions.
    # Check https://github.com/qdm12/gluetun/releases for the latest stable release.
    image: qmcgaw/gluetun:v3.41.1
    container_name: gluetun
    cap_add:
      - NET_ADMIN
    devices:
      - /dev/net/tun:/dev/net/tun
    volumes:
      - ./gluetun/config:/gluetun
    environment:
      - VPN_SERVICE_PROVIDER=custom
      - VPN_TYPE=wireguard
    restart: unless-stopped
```

With automatic port forwarding:

```yaml
services:
  pia-wg-refresh:
    image: ghcr.io/ccarpinteri/pia-wg-refresh:latest
    container_name: pia-wg-refresh
    environment:
      - PIA_USERNAME=${PIA_USERNAME}
      - PIA_PASSWORD=${PIA_PASSWORD}
      - PIA_REGION=${PIA_REGION}
      - PIA_PORT_FORWARDING=true
      - DOCKER_COMPOSE_HOST_DIR=/path/to/your/compose/directory
      - GLUETUN_CONTAINER=gluetun
    volumes:
      - ./gluetun/config/wireguard:/config
      - ./logs:/logs
      - /var/run/docker.sock:/var/run/docker.sock
      - /path/to/your/compose/directory:/path/to/your/compose/directory
    restart: unless-stopped
    healthcheck:
      test: grep -q "^Endpoint" /config/wg0.conf || exit 1
      start_period: 10s
      interval: 5s

  gluetun:
    # Pin to a specific version - gluetun:latest tracks HEAD and can ship regressions.
    # Check https://github.com/qdm12/gluetun/releases for the latest stable release.
    image: qmcgaw/gluetun:v3.41.1
    container_name: gluetun
    cap_add:
      - NET_ADMIN
    devices:
      - /dev/net/tun:/dev/net/tun
    volumes:
      - ./gluetun/config:/gluetun
    environment:
      - VPN_SERVICE_PROVIDER=custom
      - VPN_TYPE=wireguard
      - VPN_PORT_FORWARDING=on
      - VPN_PORT_FORWARDING_PROVIDER=private internet access
      - VPN_PORT_FORWARDING_USERNAME=${PIA_USERNAME}
      - VPN_PORT_FORWARDING_PASSWORD=${PIA_PASSWORD}
      - SERVER_NAMES=${SERVER_NAMES}
    restart: unless-stopped
```

Replace `/path/to/your/compose/directory` with the absolute path where your `docker-compose.yml` and `.env` files are located (e.g., `/home/user/docker/gluetun`).

## Gluetun compatibility

Gluetun v3.39.1 and later make all control server API routes private by default. pia-wg-refresh uses two endpoints (`/v1/publicip/ip` and `/v1/portforward`) to check VPN and port forwarding status. Without configuration these return `401` and pia-wg-refresh will incorrectly treat the VPN as down.

To fix this, create `auth/config.toml` inside the directory you mount to `/gluetun` in the container (e.g. `./gluetun/config/auth/config.toml`):

```toml
[[roles]]
name = "pia-wg-refresh"
routes = ["GET /v1/publicip/ip", "GET /v1/portforward"]
auth = "none"
```

This opens only the two read-only endpoints pia-wg-refresh needs. All other routes — including `/v1/vpn/settings` which exposes VPN credentials — remain protected.

If you are running an older version of Gluetun (pre-v3.39.1), no action is needed.

### Version pinning

`qmcgaw/gluetun:latest` tracks the development branch and can ship regressions before they hit a stable release. It is strongly recommended to pin to a specific version tag (e.g. `qmcgaw/gluetun:v3.41.1`) and update deliberately. Check the [Gluetun releases page](https://github.com/qdm12/gluetun/releases) for the latest stable release. If you use an auto-update tool (e.g. Watchtower, Synology Container Manager), exclude gluetun from automatic updates.

## Security notes

This container requires the Docker socket and can restart other containers. It is intended for trusted, single-host setups.

## Notes

- The bundled generator writes `wg0.conf` inside `/config`. This container validates the new config before replacing the existing one.
- VPN status is checked via Gluetun's control server API at `localhost:8000`, which responds instantly regardless of VPN state.
- Port forwarding status is monitored via the `/v1/portforward` endpoint when `PIA_PORT_FORWARDING=true`.

## Development

Run `make test` to build the image and verify both the bundled and download paths without requiring Gluetun.
Run `make test-bundled` or `make test-download` to exercise a single path.

## Build args

- `PIA_WG_CONFIG_REF` (default: `main`) sets the git ref used to build `pia-wg-config` in the Dockerfile.

## License

MIT
