# pia-wg-refresh

Refreshes PIA WireGuard configs for Gluetun only when the tunnel is actually down. It runs alongside Gluetun in Docker, regenerates `wg0.conf` with a bundled `pia-wg-config` binary built from source, and restarts the Gluetun container only after consecutive failures.

## Why

PIA WireGuard sessions can expire. If Gluetun restarts or loses the tunnel after expiry, it can get stuck until a fresh config is generated. This container monitors connectivity inside Gluetun and regenerates the config only when needed.

## How it works

Every `CHECK_INTERVAL_SECONDS`:

1. `docker exec` into Gluetun to check connectivity.
2. Track consecutive failures.
3. On `FAIL_THRESHOLD`, generate a new config, replace `wg0.conf`, and restart Gluetun.

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
- `CHECK_INTERVAL_SECONDS` (default: `60`)
- `FAIL_THRESHOLD` (default: `3`)
- `LOG_LEVEL` (default: `info`)
- `PIA_WG_CONFIG_BIN` (default: `/usr/local/bin/pia-wg-config`)
- `PIA_WG_CONFIG_URL` (optional: if set, download/replace `pia-wg-config` on startup)
- `PIA_WG_CONFIG_SHA256` (optional: verify the download before installing)
- `SELF_TEST` (optional: set to `1` to exit after startup checks)

## Logs

Logs are append-only in `/logs`:

- `/logs/refresh.log`
- `/logs/pia-wg-config.log`
- `/logs/docker.log`

## Docker Compose example

```yaml
services:
  gluetun:
    image: qmcgaw/gluetun
    container_name: gluetun
    volumes:
      - ${DOCKER_PATH}/gluetun/config:/gluetun
      - ${DOCKER_PATH}/gluetun/config/wireguard/wg0.conf:/gluetun/wireguard/wg0.conf

  pia-wg-refresh:
    image: ccarpinteri/pia-wg-refresh
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
