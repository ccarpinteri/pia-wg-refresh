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

## Port Forwarding Feature

### The Problem
When using Gluetun's port forwarding with `VPN_SERVICE_PROVIDER=custom`, Gluetun requires `SERVER_NAMES` env var to match the connected PIA server. See [Gluetun issue #3070](https://github.com/qdm12/gluetun/issues/3070).

When pia-wg-refresh generates a new config, it connects to a new server (e.g., `dublin424`), but the Gluetun container still has the old `SERVER_NAMES` value. This causes port forwarding to fail.

### The Challenge
- `docker restart` does NOT update environment variables - container keeps original env vars
- `docker compose up -d --force-recreate` updates env vars BUT causes issues when pia-wg-refresh has `depends_on: [gluetun]` - it recreates pia-wg-refresh instead of gluetun
- When running docker compose from inside a container, relative paths in docker-compose.yml resolve incorrectly (e.g., `./gluetun/config` becomes `/compose/gluetun/config` instead of the host path)

### The Solution
1. **Use raw docker commands** - `docker stop` + `docker rm` + `docker compose up -d` instead of `--force-recreate` to avoid dependency issues
2. **Remove depends_on from gluetun** - prevents compose from recreating wrong container
3. **Auto-detect project name** from container labels: `com.docker.compose.project`
4. **Use `DOCKER_COMPOSE_HOST_DIR`** - the absolute host path to the compose directory
5. **Same-path volume mount** - mount the host path to the same path inside the container
6. **Use `--project-directory`** flag to tell docker compose where to resolve relative paths

### How It Works
1. pia-wg-refresh monitors port forwarding via Gluetun's control server API (`/v1/portforward`)
2. When port forwarding fails, it checks if `SERVER_NAMES` in the container matches the config file
3. If mismatch detected:
   - Updates `.env` file with new server name (for persistence)
   - Stops gluetun: `docker stop gluetun`
   - Removes gluetun: `docker rm gluetun`
   - Recreates gluetun: `docker compose -p <project> --project-directory <host_dir> up -d gluetun`
4. Project name is auto-detected from `com.docker.compose.project` container label

### Key Functions in refresh-loop.sh
```sh
# Auto-detect project name from container labels
get_compose_project() {
  docker inspect "$GLUETUN_CONTAINER" --format '{{index .Config.Labels "com.docker.compose.project"}}' 2>/dev/null || true
}

# Recreate container with updated env vars using raw docker commands
# This avoids issues with depends_on causing the wrong container to be recreated
restart_gluetun() {
  if [ -n "${DOCKER_COMPOSE_HOST_DIR:-}" ]; then
    project=$(get_compose_project)
    if [ -n "$project" ]; then
      log info "Recreating container $GLUETUN_CONTAINER (project: $project)..."

      # Stop and remove the container
      docker stop "$GLUETUN_CONTAINER" 2>&1 >> "$DOCKER_LOG"
      docker rm "$GLUETUN_CONTAINER" 2>&1 >> "$DOCKER_LOG"

      # Recreate using docker compose (reads updated .env)
      docker compose -p "$project" --project-directory "$DOCKER_COMPOSE_HOST_DIR" up -d "$GLUETUN_CONTAINER" 2>&1 >> "$DOCKER_LOG"
    fi
  fi
}
```

## Hooks Feature

pia-wg-refresh supports custom shell scripts that execute when failures occur or when service recovers. This is useful for sending notifications, logging to external systems, or triggering other automation.

### Hook Types

**Failure Hook** (`ON_FAILURE_SCRIPT`)
- Triggered when connectivity checks fail or config generation fails
- Receives `FAILURE_TYPE` environment variable with values:
  - `connectivity` - Network/VPN connectivity check failed
  - `port_forwarding` - Port forwarding check failed (when enabled)
  - `config_generation` - Failed to generate new WireGuard config

**Recovery Hook** (`ON_RECOVERY_SCRIPT`)
- Triggered when service successfully recovers after a failure
- Receives environment variables:
  - `PIA_SERVER_NAME` - The connected server name (e.g., `adelaide402`)
  - `PIA_FORWARDED_PORT` - The forwarded port number (only when port forwarding enabled)

### Hook Execution

- Hooks run **asynchronously** (in background) to not block the monitoring loop
- Hook output is logged to `/logs/hooks.log`
- Exit codes are logged for debugging
- Scripts are executed using `eval`, so they can be inline shell commands or paths to scripts

### Important Requirements

**Shebang**: Hook scripts must use `#!/bin/sh` as the shebang. The container uses Alpine Linux which doesn't include bash by default.

**Dependencies**: If your hook needs tools like `curl`, `jq`, etc., they must be available in the container. The container includes `curl` by default.

### Example: Discord Webhook Notification

```sh
#!/bin/sh
# /scripts/notify-discord.sh

WEBHOOK_URL="https://discord.com/api/webhooks/..."

if [ -n "${FAILURE_TYPE:-}" ]; then
  MESSAGE="⚠️ VPN Failure: $FAILURE_TYPE"
else
  MESSAGE="✅ VPN Recovered: Server=$PIA_SERVER_NAME, Port=${PIA_FORWARDED_PORT:-none}"
fi

curl -X POST "$WEBHOOK_URL" \
  -H "Content-Type: application/json" \
  -d "{\"content\": \"$MESSAGE\"}"
```

### Configuration

```yaml
pia-wg-refresh:
  environment:
    - ON_FAILURE_SCRIPT=/scripts/notify.sh
    - ON_RECOVERY_SCRIPT=/scripts/notify.sh
  volumes:
    - ./scripts:/scripts:ro
```

Or inline:
```yaml
pia-wg-refresh:
  environment:
    - ON_FAILURE_SCRIPT=echo "Failed: $FAILURE_TYPE" >> /logs/alerts.log
    - ON_RECOVERY_SCRIPT=echo "Recovered: $PIA_SERVER_NAME" >> /logs/alerts.log
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

### Hooks (optional)
- `ON_FAILURE_SCRIPT` - Shell command/script to run when failures occur (receives `FAILURE_TYPE` env var)
- `ON_RECOVERY_SCRIPT` - Shell command/script to run when service recovers (receives `PIA_SERVER_NAME` and `PIA_FORWARDED_PORT` env vars)

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
    restart: unless-stopped
    # IMPORTANT: Do NOT add depends_on for pia-wg-refresh
    # This causes issues with container recreation from inside pia-wg-refresh
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
    restart: unless-stopped
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
        ├── docker.log                # Docker command output
        └── hooks.log                 # Hook script output
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

## Recent Changes (v0.7.0)

### Added
- **ON_PORT_CHANGE_SCRIPT hook**: New hook that fires whenever the forwarded port changes (including on first discovery). Receives `PIA_FORWARDED_PORT`, `PIA_PREVIOUS_PORT`, and `PIA_SERVER_NAME`. Runs asynchronously like other hooks.
- **Gluetun v3.39.1+ compatibility note**: Gluetun now makes all control server routes private by default. Users must create `auth/config.toml` in their Gluetun config directory with a targeted role to allow the two read-only endpoints pia-wg-refresh needs (`GET /v1/publicip/ip`, `GET /v1/portforward`).
- **Sample notification script**: `scripts/pia-wg-refresh-notification.sh` — a Prowl notification example covering all three hook types (failure, recover, ports). Uses `PROWL_API_KEY` env var.

### Environment Variables Added
- `ON_PORT_CHANGE_SCRIPT` - hook script path for port change events

### Gluetun Auth Fix (applied to Braavos during testing)
File created at `/volume2/docker/chucktel/gluetun/config/auth/config.toml`:
```toml
[[roles]]
name = "pia-wg-refresh"
routes = ["GET /v1/publicip/ip", "GET /v1/portforward"]
auth = "none"
```

### Gluetun Version Pinning (applied to Braavos 2026-02-25)
`gluetun:latest` broke twice in one week on Synology NAS:
1. **2026-02-21**: Auth change (v3.39.1+) — all API routes private by default → fixed with `auth/config.toml`
2. **2026-02-25**: Conntrack regression (commit `01487b5`, built 2026-02-24) — `flushing conntrack: netfilter query: netlink receive: invalid argument` → Gluetun crashes on startup, incompatible with Synology kernel

Both caused by Synology Container Manager auto-pulling `gluetun:latest`. **Fix: pin to `qmcgaw/gluetun:v3.41.1`** (latest stable, Feb 11 2026) in docker-compose.yml on Braavos and in the repo sample files. Users should disable auto-updates for gluetun or exclude it from Watchtower.

## Recent Changes (v0.6.1)

### Changed
- **Container recreation fix**: Now uses raw docker commands (`docker stop` + `docker rm` + `docker compose up -d`) instead of `--force-recreate` to avoid recreating the wrong container
- **Removed depends_on requirement**: No longer requires `depends_on` relationship between containers, which was causing recreation issues
- **Added hooks feature**: Support for `ON_FAILURE_SCRIPT` and `ON_RECOVERY_SCRIPT` environment variables for custom notifications
- **Added curl**: Included curl in container for webhook/notification scripts
- **Better error detection**: Improved detection of `pia-wg-config` failures to prevent false success

### Why These Changes
The previous approach using `docker compose --force-recreate` had a critical flaw:
1. When gluetun has `depends_on: [pia-wg-refresh]` in docker-compose.yml
2. Running `docker compose up -d --force-recreate gluetun` from inside pia-wg-refresh
3. Compose sees the dependency and recreates pia-wg-refresh instead of gluetun
4. This caused an infinite loop and service disruption

The new approach using raw docker commands bypasses this issue entirely.

### Breaking Changes
None - existing configurations continue to work. The depends_on relationship is no longer needed but won't cause issues if present (as long as you're using the new raw docker approach).

## Previous Changes (v0.5.0)

### Changed
- Replaced `DOCKER_COMPOSE_DIR` with `DOCKER_COMPOSE_HOST_DIR`
- Now uses `docker compose --project-directory` instead of `cd` to compose directory
- Auto-detects project name from container labels (no manual config needed)

### Why These Changes
The previous approach using `DOCKER_COMPOSE_DIR=/compose` with a volume mount `.:/compose` failed on Docker Desktop (Mac/Windows) because:
1. Relative paths in docker-compose.yml resolved to container paths (e.g., `/compose/gluetun/config`)
2. Docker Desktop doesn't share these paths from the host
3. The `--project-directory` flag solves this by telling compose where to resolve relative paths

### Migration (v0.5.0)
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
- `/logs/hooks.log` - Output from failure and recovery hook scripts

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

### Hooks not working
1. Check hooks.log for errors
2. Verify script has `#!/bin/sh` shebang (Alpine doesn't include bash)
3. Ensure required tools (curl, jq, etc.) are available in container
4. Check that script path is accessible inside container (volume mount)
5. Test script manually: `docker exec pia-wg-refresh /path/to/script.sh`

## Architecture Notes

### Why docker compose instead of docker restart?
`docker restart` does NOT update environment variables. The container keeps its original env vars. Only `docker compose up -d` (after removing the container) reads the updated `.env` file and applies new env vars.

### Why raw docker commands instead of --force-recreate?
When running `docker compose --force-recreate` from inside a container that has `depends_on` relationships, docker compose may recreate the wrong container. Using `docker stop` + `docker rm` + `docker compose up -d` avoids this issue by explicitly controlling which container is being recreated.

### Why remove depends_on from gluetun?
The depends_on relationship causes docker compose to think gluetun depends on pia-wg-refresh. When recreating from inside pia-wg-refresh, this can confuse docker compose and cause it to recreate pia-wg-refresh instead. Removing depends_on prevents this issue, and it's not needed anyway since pia-wg-refresh handles gluetun's lifecycle.

### Why auto-detect project name?
Docker Compose derives project name from the directory name. Inside the container, the directory might be `/compose`, but on the host it could be anything. Auto-detecting from container labels ensures we always use the correct project name.

### Why same-path volume mount?
When docker compose runs inside the container with `--project-directory /host/path`, it needs to access that path. By mounting `/host/path:/host/path`, the path is accessible and identical inside and outside the container.

### Why hooks run asynchronously?
Hooks run in the background to prevent blocking the main monitoring loop. If a hook script hangs or takes a long time, it won't prevent the service from continuing to monitor and respond to connectivity issues.
