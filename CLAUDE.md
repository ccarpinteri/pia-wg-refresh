# pia-wg-refresh - Project Context for Claude

## Project Overview

**pia-wg-refresh** is a Docker container that automatically refreshes Private Internet Access (PIA) WireGuard configs for Gluetun. It monitors VPN connectivity and regenerates `wg0.conf` only when the tunnel is actually down.

**Repository**: This repository
**Test Environment**: Create a separate test directory alongside the repo

## Branching & Release Strategy

### Branches
- `main` - Stable, production-ready code
- `fix/*` - Bug fix branches (e.g., `fix/port-forwarding-regeneration`)
- `feature/*` - Feature branches (e.g., `feature/hooks`)

### Tags
- `v*` (e.g., `v0.5.1`) - Stable releases
  - Triggers Docker build with `:<version>` AND `:latest` tags
  - Creates GitHub Release
- `dev-*` (e.g., `dev-fix-pf-regen`) - Dev/test releases
  - Triggers Docker build with only `:<tag>` tag
  - No `:latest`, no GitHub Release

### Release Flow
1. Create branch from `main` (e.g., `fix/port-forwarding-regeneration`)
2. Make changes and test locally
3. Push branch, then tag as `dev-<description>` for prod testing
4. Test on prod server with dev image
5. If good → merge to `main` → tag as `vX.Y.Z`

### Hotfix Workflow

When a bug fix is needed while feature work is in progress:

1. **Always branch from `main`** for hotfixes, never from a feature branch
2. Create `fix/<description>` branch from `main`
3. Make the fix, test, merge to `main`, tag release
4. Rebase feature branches onto updated `main` if needed

**Never merge a feature branch to release a hotfix.** If you've accidentally committed a fix to a feature branch:
- Cherry-pick the fix commits to a new branch from `main`
- Or reset and redo the work on the correct branch

### Pre-Release Checklist

Before tagging a release:
1. `git log main..<branch> --oneline` - review ALL commits being merged
2. Confirm only intended changes are included
3. If feature work is mixed in, stop and separate

## Key Components

### Files
- `entrypoint.sh` - Entry point that sets up environment variables and launches the main script
- `refresh-loop.sh` - Main monitoring loop with all the logic
- `Dockerfile` - Builds the image, includes bundled `pia-wg-config` binary
- `README.md` - User documentation

### Dependencies
- **pia-wg-config**: Bundled binary from [Ephemeral-Dust fork](https://github.com/Ephemeral-Dust/pia-wg-config) that generates WireGuard configs for PIA
- **Gluetun**: The VPN container this tool manages (qmcgaw/gluetun)

## Port Forwarding Feature (v0.5.0)

### The Problem
When using Gluetun's port forwarding with `VPN_SERVICE_PROVIDER=custom`, Gluetun requires `SERVER_NAMES` env var to match the connected PIA server. See [Gluetun issue #3070](https://github.com/qdm12/gluetun/issues/3070).

When pia-wg-refresh generates a new config, it connects to a new server (e.g., `dublin424`), but the Gluetun container still has the old `SERVER_NAMES` value. This causes port forwarding to fail.

### The Challenge
- `docker restart` does NOT update environment variables - container keeps original env vars
- `docker compose up -d --force-recreate` DOES update env vars, but needs correct project name
- When running docker compose from inside a container, relative paths in docker-compose.yml resolve incorrectly (e.g., `./gluetun/config` becomes `/compose/gluetun/config` instead of the host path)

### The Solution
1. **Auto-detect project name** from container labels: `com.docker.compose.project`
2. **Use `DOCKER_COMPOSE_HOST_DIR`** - the absolute host path to the compose directory
3. **Same-path volume mount** - mount the host path to the same path inside the container
4. **Use `--project-directory`** flag to tell docker compose where to resolve relative paths

### How It Works
1. pia-wg-refresh monitors port forwarding via Gluetun's control server API (`/v1/portforward`)
2. When port forwarding fails, it checks if `SERVER_NAMES` in the container matches the config file
3. If mismatch detected:
   - Updates `.env` file with new server name (for persistence)
   - Runs `docker compose -p <project> --project-directory <host_dir> up -d --force-recreate gluetun`
4. Project name is auto-detected from `com.docker.compose.project` container label

### Key Functions in refresh-loop.sh
```sh
# Auto-detect project name from container labels
get_compose_project() {
  docker inspect "$GLUETUN_CONTAINER" --format '{{index .Config.Labels "com.docker.compose.project"}}' 2>/dev/null || true
}

# Recreate container with updated env vars
restart_gluetun() {
  if [ -n "${DOCKER_COMPOSE_HOST_DIR:-}" ]; then
    project=$(get_compose_project)
    if [ -n "$project" ]; then
      docker compose -p "$project" --project-directory "$DOCKER_COMPOSE_HOST_DIR" up -d --force-recreate "$GLUETUN_CONTAINER"
    fi
  fi
}
```

## Environment Variables

### Required
- `PIA_USERNAME` - PIA account username
- `PIA_PASSWORD` - PIA account password
- `PIA_REGION` - PIA region (e.g., `ireland`, `us_chicago`)

### Port Forwarding (optional)
- `PIA_PORT_FORWARDING` (default: `false`) - Enable port forwarding monitoring
- `DOCKER_COMPOSE_HOST_DIR` - **Absolute host path** to compose directory (required for auto SERVER_NAMES sync)
- `DOCKER_COMPOSE_ENV_FILE` (default: `.env`) - Env file name to update

### Other Optional
- `GLUETUN_CONTAINER` (default: `gluetun`)
- `CHECK_INTERVAL_SECONDS` (default: `60`)
- `HEALTHY_CHECK_INTERVAL_SECONDS` (default: `1800`)
- `FAIL_THRESHOLD` (default: `3`)
- `LOG_LEVEL` (default: `info`)

## Docker Compose Configuration (Port Forwarding)

### User's docker-compose.yml
```yaml
services:
  gluetun:
    image: qmcgaw/gluetun
    container_name: gluetun
    environment:
      - VPN_SERVICE_PROVIDER=custom
      - VPN_TYPE=wireguard
      - VPN_PORT_FORWARDING=on
      - VPN_PORT_FORWARDING_PROVIDER=private internet access
      - VPN_PORT_FORWARDING_USERNAME=${PIA_USERNAME}
      - VPN_PORT_FORWARDING_PASSWORD=${PIA_PASSWORD}
      - SERVER_NAMES=${SERVER_NAMES}
    # ... other config

  pia-wg-refresh:
    image: ghcr.io/ccarpinteri/pia-wg-refresh:latest
    environment:
      - PIA_USERNAME=${PIA_USERNAME}
      - PIA_PASSWORD=${PIA_PASSWORD}
      - PIA_REGION=${PIA_REGION}
      - PIA_PORT_FORWARDING=true
      - DOCKER_COMPOSE_HOST_DIR=/absolute/path/on/host
    volumes:
      - ./gluetun/config/wireguard:/config
      - ./logs:/logs
      - /var/run/docker.sock:/var/run/docker.sock
      - /absolute/path/on/host:/absolute/path/on/host  # Same path mount!
```

### User's .env file
```
PIA_USERNAME=your_user
PIA_PASSWORD=your_pass
PIA_REGION=ireland
SERVER_NAMES=placeholder  # Will be auto-updated
```

## Test Environment

Create a separate test directory alongside the repo (e.g., `pia-wg-refresh-test/`).

### Directory Structure

```
pia-wg-refresh-test/
├── .env                              # PIA credentials + SERVER_NAMES
├── .env.example                      # Template for .env
├── docker-compose.yml                # Test stack configuration
├── gluetun/
│   └── config/
│       ├── wireguard/
│       │   └── wg0.conf              # Generated WireGuard config
│       ├── piaportforward.json       # Port forwarding state (Gluetun)
│       └── servers.json              # PIA server list (Gluetun)
└── pia-wg-refresh/
    └── logs/
        ├── refresh.log               # Main loop logs
        ├── pia-wg-config.log         # Config generation output
        └── docker.log                # Docker command output
```

### Testing Commands
```bash
# Build the image (from repo directory)
docker build -t pia-wg-refresh:fork-test .

# Clean up test environment (from test directory)
docker compose down
rm -f pia-wg-refresh/logs/*.log
rm -f gluetun/config/wireguard/wg0.conf*

# Reset .env for fresh test
# Set SERVER_NAMES=placeholder in .env

# Start test
docker compose up -d

# Monitor logs
tail -f pia-wg-refresh/logs/refresh.log

# Verify results
cat .env  # Should show updated SERVER_NAMES
docker exec gluetun printenv SERVER_NAMES
docker exec gluetun wget -qO- http://localhost:8000/v1/portforward
```

### Test docker-compose.yml specifics
```yaml
pia-wg-refresh:
  image: pia-wg-refresh:fork-test  # Local test image
  environment:
    - DOCKER_COMPOSE_HOST_DIR=/absolute/path/to/test/directory
    - CHECK_INTERVAL_SECONDS=10  # Faster for testing
    - FAIL_THRESHOLD=2
    - LOG_LEVEL=debug
  volumes:
    - /absolute/path/to/test/directory:/absolute/path/to/test/directory
```

## Recent Changes (v0.5.0)

### Changed
- Replaced `DOCKER_COMPOSE_DIR` with `DOCKER_COMPOSE_HOST_DIR`
- Now uses `docker compose --project-directory` instead of `cd` to compose directory
- Auto-detects project name from container labels (no manual config needed)

### Why These Changes
The previous approach using `DOCKER_COMPOSE_DIR=/compose` with a volume mount `.:/compose` failed on Docker Desktop (Mac/Windows) because:
1. Relative paths in docker-compose.yml resolved to container paths (e.g., `/compose/gluetun/config`)
2. Docker Desktop doesn't share these paths from the host
3. The `--project-directory` flag solves this by telling compose where to resolve relative paths

### Migration
Old config:
```yaml
- DOCKER_COMPOSE_DIR=/compose
- .:/compose
```

New config:
```yaml
- DOCKER_COMPOSE_HOST_DIR=/absolute/path/on/host
- /absolute/path/on/host:/absolute/path/on/host
```

## Logs

- `/logs/refresh.log` - Main refresh loop logs
- `/logs/pia-wg-config.log` - Output from config generation
- `/logs/docker.log` - Output from docker restart/compose commands

## Common Issues

### Port forwarding not working
1. Check `SERVER_NAMES` matches the connected server
2. Verify `DOCKER_COMPOSE_HOST_DIR` is set correctly
3. Check docker.log for compose errors

### Docker compose failing inside container
- Ensure same-path volume mount is configured
- Check that the host path exists and is accessible
- Verify Docker socket is mounted

### Container stuck in restart loop
- Usually means wg0.conf is missing or invalid
- Check pia-wg-config.log for generation errors
- Verify PIA credentials are correct

## Architecture Notes

### Why docker compose instead of docker restart?
`docker restart` does NOT update environment variables. The container keeps its original env vars. Only `docker compose up -d --force-recreate` reads the updated `.env` file and applies new env vars.

### Why auto-detect project name?
Docker Compose derives project name from the directory name. Inside the container, the directory might be `/compose`, but on the host it could be anything. Auto-detecting from container labels ensures we always use the correct project name.

### Why same-path volume mount?
When docker compose runs inside the container with `--project-directory /host/path`, it needs to access that path. By mounting `/host/path:/host/path`, the path is accessible and identical inside and outside the container.
