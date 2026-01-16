# pia-wg-refresh Test Suite

This document outlines the test cases for validating pia-wg-refresh functionality.

## Test Environment

- **Repository**: This repository
- **Test Environment**: Create a separate test directory (e.g., `pia-wg-refresh-test/`)

### Test Environment Directory Structure

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

### Test docker-compose.yml

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
      - ./gluetun/config:/gluetun
    environment:
      - VPN_SERVICE_PROVIDER=custom
      - VPN_TYPE=wireguard
      - VPN_PORT_FORWARDING=on
      - VPN_PORT_FORWARDING_PROVIDER=private internet access
      - VPN_PORT_FORWARDING_USERNAME=${PIA_USERNAME}
      - VPN_PORT_FORWARDING_PASSWORD=${PIA_PASSWORD}
      - SERVER_NAMES=${SERVER_NAMES}
    ports:
      - "8888:8888"   # Testing connectivity through VPN
      - "8000:8000"   # Control server API
    restart: unless-stopped

  pia-wg-refresh:
    image: pia-wg-refresh:fork-test
    container_name: pia-wg-refresh
    depends_on:
      - gluetun
    environment:
      - PIA_USERNAME=${PIA_USERNAME}
      - PIA_PASSWORD=${PIA_PASSWORD}
      - PIA_REGION=${PIA_REGION}
      - PIA_PORT_FORWARDING=true
      - DOCKER_COMPOSE_HOST_DIR=/absolute/path/to/test/directory
      - CHECK_INTERVAL_SECONDS=10
      - FAIL_THRESHOLD=2
      - LOG_LEVEL=debug
    volumes:
      - ./gluetun/config/wireguard:/config
      - ./pia-wg-refresh/logs:/logs
      - /var/run/docker.sock:/var/run/docker.sock
      - /absolute/path/to/test/directory:/absolute/path/to/test/directory
    restart: unless-stopped
```

### Test .env File

```
PIA_USERNAME=<your_pia_username>
PIA_PASSWORD=<your_pia_password>
PIA_REGION=ireland
SERVER_NAMES=placeholder
```

### Test Configuration

For faster iteration during testing, use these settings:
```yaml
environment:
  - CHECK_INTERVAL_SECONDS=10
  - HEALTHY_CHECK_INTERVAL_SECONDS=30
  - FAIL_THRESHOLD=2
  - LOG_LEVEL=debug
```

### Setup Commands

```bash
# Build test image (from repo directory)
docker build -t pia-wg-refresh:fork-test .

# Clean test environment (from test directory)
docker compose down
rm -f pia-wg-refresh/logs/*.log
rm -f gluetun/config/wireguard/wg0.conf*

# Reset .env for fresh test
# Edit .env and set SERVER_NAMES=placeholder

# Start test
docker compose up -d

# Monitor logs
tail -f pia-wg-refresh/logs/refresh.log
```

### Useful Commands During Testing

```bash
# Check container status
docker ps -a --filter "name=gluetun" --filter "name=pia-wg-refresh"

# Check VPN status
docker exec gluetun wget -qO- http://localhost:8000/v1/publicip/ip

# Check port forwarding status
docker exec gluetun wget -qO- http://localhost:8000/v1/portforward

# Check SERVER_NAMES in container
docker exec gluetun printenv SERVER_NAMES

# Check SERVER_NAMES in .env
grep SERVER_NAMES .env

# Check compose project label
docker inspect gluetun --format '{{index .Config.Labels "com.docker.compose.project"}}'

# View recent logs
tail -50 pia-wg-refresh/logs/refresh.log
tail -20 pia-wg-refresh/logs/docker.log
cat pia-wg-refresh/logs/pia-wg-config.log

# Check wg0.conf header
head -10 gluetun/config/wireguard/wg0.conf
```

---

## Test Cases

### Legend

| Status | Meaning |
|--------|---------|
| ⬜ | Not tested |
| ✅ | Passed |
| ❌ | Failed |
| 🚧 | In progress |

---

## 1. VPN Only (Port Forwarding Disabled)

These tests run with `PIA_PORT_FORWARDING=false` (default).

### 1.1 Fresh Install - No Config Exists

| ID | Status | Description |
|----|--------|-------------|
| 1.1 | ⬜ | **No config, automatic creation** |

**Preconditions:**
- No `wg0.conf` exists in config directory
- Valid PIA credentials
- Valid PIA region

**Steps:**
1. Remove any existing `wg0.conf`
2. Start pia-wg-refresh and gluetun containers
3. Monitor logs

**Expected Results:**
- [ ] pia-wg-refresh detects missing/invalid config
- [ ] Generates new `wg0.conf` via pia-wg-config
- [ ] Restarts Gluetun container
- [ ] Gluetun comes up with working VPN tunnel
- [ ] `/v1/publicip/ip` returns a valid IP
- [ ] Logs show successful config generation and tunnel establishment

**Verification:**
```bash
# Check config was created
ls -la gluetun/config/wireguard/wg0.conf

# Check VPN is working
docker exec gluetun wget -qO- http://localhost:8000/v1/publicip/ip

# Check logs
tail -50 pia-wg-refresh/logs/refresh.log
```

---

### 1.2 Config Issues - Expired Token

| ID | Status | Description |
|----|--------|-------------|
| 1.2 | ⬜ | **Expired config, automatic recreation** |

**Preconditions:**
- Existing `wg0.conf` with expired/invalid token
- Valid PIA credentials
- Valid PIA region

**Steps:**
1. Start with a working setup
2. Corrupt or expire the `wg0.conf` (or wait for natural expiry)
3. Restart Gluetun to trigger connection failure
4. Monitor pia-wg-refresh behavior

**Expected Results:**
- [ ] pia-wg-refresh detects VPN failure via `/v1/publicip/ip`
- [ ] Failure counter increments on each check
- [ ] After `FAIL_THRESHOLD` failures, generates new config
- [ ] Old config backed up as `wg0.conf.bak`
- [ ] New config written to `wg0.conf`
- [ ] Gluetun restarted
- [ ] VPN tunnel re-established successfully

**Verification:**
```bash
# Check backup was created
ls -la gluetun/config/wireguard/wg0.conf*

# Check VPN recovered
docker exec gluetun wget -qO- http://localhost:8000/v1/publicip/ip

# Check logs show failure detection and recovery
grep -E "(fail|generat|restart)" pia-wg-refresh/logs/refresh.log
```

---

### 1.3 Invalid Credentials

| ID | Status | Description |
|----|--------|-------------|
| 1.3 | ⬜ | **Invalid PIA credentials handling** |

**Preconditions:**
- Invalid `PIA_USERNAME` or `PIA_PASSWORD`
- No existing `wg0.conf`

**Steps:**
1. Set invalid credentials in environment
2. Start containers
3. Monitor logs

**Expected Results:**
- [ ] pia-wg-config fails to authenticate
- [ ] Error logged clearly indicating credential issue
- [ ] Does not loop indefinitely attempting generation
- [ ] Respects `MAX_GENERATION_RETRIES` limit

**Verification:**
```bash
# Check for auth errors
grep -i "auth\|credential\|password\|username" pia-wg-refresh/logs/pia-wg-config.log
grep -i "retry\|max" pia-wg-refresh/logs/refresh.log
```

---

### 1.4 Invalid Region

| ID | Status | Description |
|----|--------|-------------|
| 1.4 | ⬜ | **Invalid PIA region handling** |

**Preconditions:**
- Valid credentials
- Invalid `PIA_REGION` (e.g., `invalid_region`)

**Steps:**
1. Set invalid region
2. Start containers
3. Monitor logs

**Expected Results:**
- [ ] pia-wg-config fails with region error
- [ ] Error logged clearly indicating invalid region
- [ ] Does not loop indefinitely

**Verification:**
```bash
grep -i "region" pia-wg-refresh/logs/pia-wg-config.log
```

---

### 1.5 Network Recovery Before Threshold

| ID | Status | Description |
|----|--------|-------------|
| 1.5 | ⬜ | **VPN recovers before fail threshold reached** |

**Preconditions:**
- Working VPN setup
- `FAIL_THRESHOLD=3`

**Steps:**
1. Start with working VPN
2. Cause temporary network issue (1-2 check failures)
3. Allow network to recover before 3rd failure

**Expected Results:**
- [ ] Failure counter increments during outage
- [ ] Failure counter resets when VPN recovers
- [ ] No config regeneration occurs
- [ ] No Gluetun restart occurs

**Verification:**
```bash
# Should see failure count go up then reset
grep -E "(fail|health)" pia-wg-refresh/logs/refresh.log
```

---

### 1.6 Gluetun Container Not Found

| ID | Status | Description |
|----|--------|-------------|
| 1.6 | ⬜ | **Gluetun container missing or wrong name** |

**Preconditions:**
- `GLUETUN_CONTAINER` set to non-existent container name

**Steps:**
1. Set `GLUETUN_CONTAINER=nonexistent`
2. Start pia-wg-refresh
3. Monitor logs

**Expected Results:**
- [ ] Clear error message about container not found
- [ ] Does not crash or loop indefinitely
- [ ] Logs actionable error for user

---

### 1.7 Max Generation Retries Exceeded

| ID | Status | Description |
|----|--------|-------------|
| 1.7 | ⬜ | **Config generation fails repeatedly** |

**Preconditions:**
- Condition that causes config generation to fail (e.g., network issue to PIA)
- `MAX_GENERATION_RETRIES=3`

**Steps:**
1. Create condition where pia-wg-config fails
2. Allow multiple generation attempts
3. Monitor behavior after max retries

**Expected Results:**
- [ ] Attempts generation up to `MAX_GENERATION_RETRIES` times
- [ ] Stops attempting after max reached
- [ ] Logs indicate waiting for recovery
- [ ] Resumes attempts if connectivity recovers

---

## 2. VPN + Port Forwarding

These tests run with `PIA_PORT_FORWARDING=true` and require additional configuration.

### Required Configuration

```yaml
environment:
  - PIA_PORT_FORWARDING=true
  - DOCKER_COMPOSE_HOST_DIR=/absolute/path/to/compose/directory
volumes:
  - /absolute/path/to/compose/directory:/absolute/path/to/compose/directory
```

`.env` file should contain:
```
SERVER_NAMES=placeholder
```

---

### 2.1 Fresh Install - No Config, VPN + Port Forwarding

| ID | Status | Description |
|----|--------|-------------|
| 2.1 | ⬜ | **No config, automatic creation with port forwarding** |

**Preconditions:**
- No `wg0.conf` exists
- Valid PIA credentials
- Region that supports port forwarding (e.g., `ireland`, `us_chicago`)
- `SERVER_NAMES=placeholder` in `.env`

**Steps:**
1. Remove any existing `wg0.conf`
2. Set `SERVER_NAMES=placeholder` in `.env`
3. Start containers
4. Monitor logs

**Expected Results:**
- [ ] Config generated with `-p` flag (port forwarding servers only)
- [ ] Server name extracted from config
- [ ] `.env` file updated with correct `SERVER_NAMES`
- [ ] Gluetun container recreated via `docker compose`
- [ ] VPN tunnel established
- [ ] Port forwarding active (`/v1/portforward` returns port)

**Verification:**
```bash
# Check .env was updated
cat .env | grep SERVER_NAMES

# Check Gluetun has correct SERVER_NAMES
docker exec gluetun printenv SERVER_NAMES

# Check port forwarding is working
docker exec gluetun wget -qO- http://localhost:8000/v1/portforward

# Check VPN is working
docker exec gluetun wget -qO- http://localhost:8000/v1/publicip/ip
```

---

### 2.2 Config Issues - Expired Token with Port Forwarding

| ID | Status | Description |
|----|--------|-------------|
| 2.2 | ⬜ | **Expired config recreation with port forwarding** |

**Preconditions:**
- Existing but expired `wg0.conf`
- Working port forwarding setup
- Known current `SERVER_NAMES` value

**Steps:**
1. Start with working VPN + port forwarding
2. Corrupt/expire the config
3. Restart Gluetun
4. Monitor recovery

**Expected Results:**
- [ ] VPN failure detected
- [ ] New config generated (may connect to different server)
- [ ] If server changed, `SERVER_NAMES` mismatch detected
- [ ] `.env` updated with new server name
- [ ] Gluetun recreated with new `SERVER_NAMES`
- [ ] Both VPN and port forwarding restored

**Verification:**
```bash
# Verify both are working
docker exec gluetun wget -qO- http://localhost:8000/v1/publicip/ip
docker exec gluetun wget -qO- http://localhost:8000/v1/portforward

# Verify SERVER_NAMES matches
grep SERVER_NAMES .env
docker exec gluetun printenv SERVER_NAMES
```

---

### 2.3 Region Without Port Forwarding Support

| ID | Status | Description |
|----|--------|-------------|
| 2.3 | ⬜ | **Region that doesn't support port forwarding** |

**Preconditions:**
- `PIA_PORT_FORWARDING=true`
- `PIA_REGION` set to region without port forwarding servers

**Steps:**
1. Set region to one without port forwarding support
2. Start containers
3. Monitor logs

**Expected Results:**
- [ ] pia-wg-config fails or returns no servers (with `-p` flag)
- [ ] Clear error message indicating no port forwarding servers in region
- [ ] User informed to either change region or disable port forwarding

**Verification:**
```bash
grep -i "port\|forward\|server" pia-wg-refresh/logs/pia-wg-config.log
grep -i "port\|forward" pia-wg-refresh/logs/refresh.log
```

---

### 2.4 SERVER_NAMES Mismatch Detection

| ID | Status | Description |
|----|--------|-------------|
| 2.4 | ⬜ | **Detect and fix SERVER_NAMES mismatch** |

**Preconditions:**
- Working VPN + port forwarding
- Manually set wrong `SERVER_NAMES` in container

**Steps:**
1. Start with working setup
2. Manually update `.env` with wrong `SERVER_NAMES`
3. Restart Gluetun (so it picks up wrong value)
4. Monitor pia-wg-refresh behavior

**Expected Results:**
- [ ] Port forwarding failure detected via `/v1/portforward`
- [ ] Mismatch between config server and container `SERVER_NAMES` detected
- [ ] `.env` corrected with proper server name
- [ ] Gluetun recreated with correct `SERVER_NAMES`
- [ ] Port forwarding restored

---

### 2.5 Port Forwarding Fails but VPN Healthy

| ID | Status | Description |
|----|--------|-------------|
| 2.5 | ⬜ | **Port forwarding issue without VPN issue** |

**Preconditions:**
- Working VPN
- Port forwarding failing (SERVER_NAMES mismatch)

**Steps:**
1. Cause port forwarding failure without breaking VPN
2. Monitor behavior

**Expected Results:**
- [ ] VPN health checks pass
- [ ] Port forwarding failure detected separately
- [ ] Only port forwarding fix applied (SERVER_NAMES sync)
- [ ] Config NOT regenerated (VPN is healthy)

---

### 2.6 DOCKER_COMPOSE_HOST_DIR Not Set

| ID | Status | Description |
|----|--------|-------------|
| 2.6 | ⬜ | **Port forwarding enabled but auto-sync disabled** |

**Preconditions:**
- `PIA_PORT_FORWARDING=true`
- `DOCKER_COMPOSE_HOST_DIR` not set

**Steps:**
1. Enable port forwarding without `DOCKER_COMPOSE_HOST_DIR`
2. Generate new config
3. Check logs

**Expected Results:**
- [ ] Config generated successfully
- [ ] Server name logged for manual reference
- [ ] Server name included in `wg0.conf` header comment
- [ ] Warning logged about manual `SERVER_NAMES` update needed
- [ ] No attempt to update `.env` or recreate container

**Verification:**
```bash
# Check config header
head -10 gluetun/config/wireguard/wg0.conf

# Check for manual update warning
grep -i "manual\|SERVER_NAMES" pia-wg-refresh/logs/refresh.log
```

---

### 2.7 Docker Compose Project Detection

| ID | Status | Description |
|----|--------|-------------|
| 2.7 | ⬜ | **Auto-detect compose project name** |

**Preconditions:**
- Gluetun started via `docker compose`
- Container has `com.docker.compose.project` label

**Steps:**
1. Start setup normally
2. Trigger SERVER_NAMES sync
3. Check docker.log for compose command

**Expected Results:**
- [ ] Project name auto-detected from container label
- [ ] `docker compose -p <project>` uses correct project name
- [ ] Container recreated successfully

**Verification:**
```bash
# Check project label exists
docker inspect gluetun --format '{{index .Config.Labels "com.docker.compose.project"}}'

# Check docker.log for compose command
grep "docker compose" pia-wg-refresh/logs/docker.log
```

---

## 3. Edge Cases (Future Consideration)

These edge cases are documented for future testing but are not the current focus.

| ID | Description | Priority |
|----|-------------|----------|
| 3.1 | Docker socket not mounted | Medium |
| 3.2 | Config directory not writable | Medium |
| 3.3 | Gluetun stuck in restart loop detection | Medium |
| 3.4 | `.env` file not writable | Low |
| 3.5 | `.env` file doesn't exist | Low |
| 3.6 | `DOCKER_COMPOSE_HOST_DIR` incorrect path | Medium |
| 3.7 | Same-path volume mount missing | Medium |
| 3.8 | Docker compose project label missing | Low |
| 3.9 | Rapid successive failures | Low |
| 3.10 | Config file corrupted/malformed | Medium |
| 3.11 | Gluetun API unavailable | Medium |
| 3.12 | Concurrent script execution | Low |
| 3.13 | Container restart during config generation | Low |

---

## Test Results Log

Record test execution results here.

| Date | Tester | Test IDs | Image Version | Results | Notes |
|------|--------|----------|---------------|---------|-------|
| | | | | | |

---

## Notes

- Always rebuild the test image after code changes: `docker build -t pia-wg-refresh:fork-test .`
- Clean logs between test runs for clarity
- Use `LOG_LEVEL=debug` for detailed troubleshooting
- Check all three log files: `refresh.log`, `pia-wg-config.log`, `docker.log`

## Testing Tips

### Switching Between VPN-Only and Port Forwarding Tests

For VPN-only tests (1.x), modify docker-compose.yml:
```yaml
# Gluetun - comment out port forwarding:
#- VPN_PORT_FORWARDING=on
#- VPN_PORT_FORWARDING_PROVIDER=private internet access
#- VPN_PORT_FORWARDING_USERNAME=${PIA_USERNAME}
#- VPN_PORT_FORWARDING_PASSWORD=${PIA_PASSWORD}
#- SERVER_NAMES=${SERVER_NAMES}

# pia-wg-refresh - disable port forwarding:
- PIA_PORT_FORWARDING=false
#- DOCKER_COMPOSE_HOST_DIR=...
```

For port forwarding tests (2.x), restore these settings.

### Simulating Config Expiry/Corruption

To simulate an expired or corrupted config, edit `wg0.conf` and replace the PrivateKey:
```
PrivateKey = INVALIDKEY123456789012345678901234567890abc=
```

Then restart containers to trigger failure detection.

### Testing SERVER_NAMES Mismatch

1. Edit `.env` and set `SERVER_NAMES=wrong_name`
2. Run `docker compose up -d` (container will start with wrong value)
3. pia-wg-refresh will detect mismatch and fix it

### Monitoring Test Progress

Use multiple terminal windows:
```bash
# Terminal 1: Watch logs in real-time
docker logs -f pia-wg-refresh

# Terminal 2: Check status periodically
watch -n 5 'docker exec gluetun wget -qO- http://localhost:8000/v1/publicip/ip 2>/dev/null; echo ""; docker exec gluetun wget -qO- http://localhost:8000/v1/portforward 2>/dev/null'
```

### Quick Reset Between Tests

```bash
docker compose down
rm -f pia-wg-refresh/logs/*.log
rm -f gluetun/config/wireguard/wg0.conf*
# Reset .env if needed
docker compose up -d
```

## Known Observations

### Test 1.6 - Container Not Found (Fixed in v0.5.0)
Previously, when `GLUETUN_CONTAINER` pointed to a non-existent container, the error was only captured in `docker.log`. Now errors are surfaced clearly in `refresh.log` with actionable messages like "container not found" and "Check that GLUETUN_CONTAINER matches your actual container name".
