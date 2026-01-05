# pia-wg-refresh

Refreshes PIA WireGuard configs for Gluetun only when the tunnel is actually down. It runs alongside Gluetun in Docker, regenerates `wg0.conf` with a bundled `pia-wg-config` binary built from source, and restarts the Gluetun container only after consecutive failures.

## Why

PIA WireGuard sessions can expire. If Gluetun restarts or loses the tunnel after expiry, it can get stuck until a fresh config is generated. This container monitors connectivity inside Gluetun and regenerates the config only when needed.

## How it works

1. Check connectivity by running `docker exec` into Gluetun.
2. When healthy, check every `HEALTHY_CHECK_INTERVAL_SECONDS` (default 5 minutes).
3. On failure, switch to faster checks every `CHECK_INTERVAL_SECONDS` (default 60s).
4. After `FAIL_THRESHOLD` consecutive failures, generate a new config and restart Gluetun.
5. If config generation fails repeatedly, stop retrying after `MAX_GENERATION_RETRIES` until connectivity recovers.

## Requirements

- Docker socket mount (`/var/run/docker.sock`) for `docker exec` and `docker restart`.
- Gluetun config directory mounted into this container at `/config`.

## Environment variables

Required:

- `PIA_USERNAME`
- `PIA_PASSWORD`
- `PIA_REGION`

Optional:

- `GLUETUN_CONTAINER` (default: `gluetun`)
- `WG_CONF_PATH` (default: `/config/wg0.conf`)
- `CHECK_URL` (default: `https://www.google.com/generate_204`)
- `CHECK_INTERVAL_SECONDS` (default: `60`) - interval when tunnel is down or degraded
- `HEALTHY_CHECK_INTERVAL_SECONDS` (default: `300`) - interval when tunnel is healthy
- `FAIL_THRESHOLD` (default: `3`) - consecutive failures before regenerating config
- `MAX_GENERATION_RETRIES` (default: `3`) - max config generation attempts before waiting for recovery
- `HEALTH_LOG_INTERVAL` (default: `10`) - log "Tunnel healthy" every N successful checks
- `LOG_LEVEL` (default: `info`) - set to `debug` for verbose logging
- `PIA_WG_CONFIG_BIN` (default: `/usr/local/bin/pia-wg-config`)
- `PIA_WG_CONFIG_URL` (optional: if set, download/replace `pia-wg-config` on startup)
- `PIA_WG_CONFIG_SHA256` (optional: verify the download before installing)
- `SELF_TEST` (optional: set to `1` to exit after startup checks)

## Logs

Logs are append-only in `/logs`:

- `/logs/refresh.log` - main refresh loop logs (plain text)
- `/logs/pia-wg-config.log` - output from config generation
- `/logs/docker.log` - output from docker restart commands

Console output (`docker logs`) includes colored log levels for easier reading:
- `[debug]` - cyan
- `[info]` - green
- `[warn]` - yellow
- `[error]` - red

Log files are kept as plain text without color codes.

## Docker Compose example

```yaml
services:
  gluetun:
    image: qmcgaw/gluetun
    container_name: gluetun
    cap_add:
      - NET_ADMIN
    devices:
      - /dev/net/tun:/dev/net/tun
    volumes:
      - ${DOCKER_PATH}/gluetun/config:/gluetun
    environment:
      - VPN_SERVICE_PROVIDER=custom
      - VPN_TYPE=wireguard
    restart: unless-stopped

  pia-wg-refresh:
    image: ghcr.io/ccarpinteri/pia-wg-refresh:latest
    container_name: pia-wg-refresh
    environment:
      - PIA_USERNAME=your_user
      - PIA_PASSWORD=your_pass
      - PIA_REGION=us_chicago
      - GLUETUN_CONTAINER=gluetun
    volumes:
      - ${DOCKER_PATH}/gluetun/config/wireguard:/config
      - ${DOCKER_PATH}/pia-wg-refresh/logs:/logs
      - /var/run/docker.sock:/var/run/docker.sock
    restart: unless-stopped
```

## Security notes

This container requires the Docker socket and can restart other containers. It is intended for trusted, single-host setups.

## Notes

- The bundled generator writes `wg0.conf` inside `/config`. This container validates the new config before replacing the existing one.
- The connectivity check runs inside the Gluetun container using `wget`, `curl`, or `busybox wget`.

## Development

Run `make test` to build the image and verify both the bundled and download paths without requiring Gluetun.
Run `make test-bundled` or `make test-download` to exercise a single path.

## Build args

- `PIA_WG_CONFIG_REF` (default: `main`) sets the git ref used to build `pia-wg-config` in the Dockerfile.
