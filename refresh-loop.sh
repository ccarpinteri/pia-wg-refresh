#!/bin/sh
set -eu

LOG_FILE="$LOG_DIR/refresh.log"
PIA_LOG="$LOG_DIR/pia-wg-config.log"
DOCKER_LOG="$LOG_DIR/docker.log"
: "${PIA_WG_CONFIG_BIN:=/usr/local/bin/pia-wg-config}"
: "${PIA_WG_CONFIG_URL:=}"
: "${PIA_WG_CONFIG_SHA256:=}"
: "${SELF_TEST:=0}"

# ANSI color codes
COLOR_RESET="\033[0m"
COLOR_CYAN="\033[36m"
COLOR_GREEN="\033[32m"
COLOR_YELLOW="\033[33m"
COLOR_RED="\033[31m"

log_level() {
  case "$LOG_LEVEL" in
    debug) echo 0 ;;
    info) echo 1 ;;
    warn) echo 2 ;;
    error) echo 3 ;;
    *) echo 1 ;;
  esac
}

log_should_write() {
  level="$1"
  current=$(log_level)
  case "$level" in
    debug) level_num=0 ;;
    info) level_num=1 ;;
    warn) level_num=2 ;;
    error) level_num=3 ;;
    *) level_num=1 ;;
  esac
  [ "$level_num" -ge "$current" ]
}

log_color() {
  level="$1"
  case "$level" in
    debug) echo "$COLOR_CYAN" ;;
    info) echo "$COLOR_GREEN" ;;
    warn) echo "$COLOR_YELLOW" ;;
    error) echo "$COLOR_RED" ;;
    *) echo "" ;;
  esac
}

log() {
  level="$1"
  shift
  if log_should_write "$level"; then
    ts=$(date -u "+%Y-%m-%dT%H:%M:%SZ")
    msg="$*"
    color=$(log_color "$level")
    # Colored output to stdout (for docker logs)
    printf "%s %b[%s]%b %s\n" "$ts" "$color" "$level" "$COLOR_RESET" "$msg"
    # Plain text to log file
    echo "$ts [$level] $msg" >> "$LOG_FILE"
  fi
}

download_pia_wg_config() {
  if [ -z "$PIA_WG_CONFIG_URL" ]; then
    return 0
  fi

  log info "Downloading pia-wg-config from $PIA_WG_CONFIG_URL"
  tmp="/tmp/pia-wg-config.download"
  rm -f "$tmp"

  case "$PIA_WG_CONFIG_URL" in
    file://*)
      src="${PIA_WG_CONFIG_URL#file://}"
      if ! cp "$src" "$tmp"; then
        log warn "Failed to copy pia-wg-config from $PIA_WG_CONFIG_URL"
        rm -f "$tmp"
        return 1
      fi
      ;;
    *)
      if ! wget -qO "$tmp" "$PIA_WG_CONFIG_URL"; then
        log warn "Failed to download pia-wg-config"
        rm -f "$tmp"
        return 1
      fi
      ;;
  esac

  if [ -n "$PIA_WG_CONFIG_SHA256" ]; then
    if ! echo "$PIA_WG_CONFIG_SHA256  $tmp" | sha256sum -c - >/dev/null 2>&1; then
      log warn "pia-wg-config checksum verification failed"
      rm -f "$tmp"
      return 1
    fi
  fi

  mv "$tmp" "$PIA_WG_CONFIG_BIN"
  chmod +x "$PIA_WG_CONFIG_BIN"
  log info "pia-wg-config updated at $PIA_WG_CONFIG_BIN"
  return 0
}

backup_config() {
  if [ -f "$WG_CONF_PATH" ]; then
    ts=$(date -u "+%Y%m%d%H%M%S")
    cp -p "$WG_CONF_PATH" "$WG_CONF_PATH.bak-$ts"
    log info "Backed up existing config to $WG_CONF_PATH.bak-$ts"
  else
    log info "No existing config found, creating new"
  fi
}

validate_config() {
  path="$1"
  if [ ! -s "$path" ]; then
    log error "Generated config is empty or missing: $path"
    return 1
  fi
  if ! grep -q "^\[Interface\]" "$path"; then
    log error "Generated config missing [Interface] section"
    return 1
  fi
  if ! grep -q "^\[Peer\]" "$path"; then
    log error "Generated config missing [Peer] section"
    return 1
  fi
  # Validate Endpoint exists - Gluetun requires this
  if ! grep -q "^Endpoint" "$path"; then
    log error "Generated config missing Endpoint (required by Gluetun)"
    return 1
  fi
  return 0
}

restore_backup() {
  latest_backup=$(ls -1t "$WG_CONF_PATH".bak-* 2>/dev/null | head -n 1 || true)
  if [ -n "$latest_backup" ]; then
    cp -p "$latest_backup" "$WG_CONF_PATH"
    log warn "Restored config from $latest_backup"
  fi
}

generate_config() {
  log info "Generating new WireGuard config via pia-wg-config"

  backup_config

  # Build pia-wg-config command with optional port forwarding flag
  pf_flag=""
  if [ "$PIA_PORT_FORWARDING" = "true" ]; then
    pf_flag="-p"
  fi

  log debug "Running: pia-wg-config -s $pf_flag -r $PIA_REGION -o $WG_CONF_PATH"
  if pia_output=$("$PIA_WG_CONFIG_BIN" -s $pf_flag -r "$PIA_REGION" -o "$WG_CONF_PATH" "$PIA_USERNAME" "$PIA_PASSWORD" 2>&1); then
    pia_exit_code=0
  else
    pia_exit_code=$?
  fi

  # Log output to file
  echo "$pia_output" >> "$PIA_LOG"

  # Log at appropriate level based on exit code
  if [ "$pia_exit_code" -ne 0 ]; then
    # Detect specific error: no port-forwarding servers in region
    if echo "$pia_output" | grep -q "index out of range \[0\] with length 0"; then
      if [ "$PIA_PORT_FORWARDING" = "true" ]; then
        log error "No port-forwarding servers available in region '$PIA_REGION'"
        log info "Try a different region, or set PIA_PORT_FORWARDING=false"
      else
        log error "No servers available in region '$PIA_REGION'"
      fi
    else
      log warn "pia-wg-config failed (exit code $pia_exit_code)"
      if [ -n "$pia_output" ]; then
        # Log first line of error at warn level, full output at debug
        first_line=$(echo "$pia_output" | head -n 1)
        log warn "pia-wg-config error: $first_line"
      fi
    fi
    log debug "pia-wg-config full output: $pia_output"
    restore_backup
    return 1
  elif [ -n "$pia_output" ]; then
    log debug "pia-wg-config output: $pia_output"
  fi

  if ! validate_config "$WG_CONF_PATH"; then
    restore_backup
    return 1
  fi

  # Extract the server name if present
  server_name=$(grep "^ServerCommonName" "$WG_CONF_PATH" 2>/dev/null | cut -d= -f2 | tr -d ' ' || true)
  if [ -n "$server_name" ]; then
    log info "Config generated for server: $server_name"
  fi

  # Add header comment with metadata
  ts=$(date -u "+%Y-%m-%dT%H:%M:%SZ")
  {
    echo "# Generated by pia-wg-refresh"
    echo "# Date: $ts"
    echo "# Region: $PIA_REGION"
    if [ -n "$server_name" ]; then
      echo "# Server: $server_name (use this for SERVER_NAMES if port forwarding)"
    fi
    echo ""
    cat "$WG_CONF_PATH"
    echo ""
  } > "$WG_CONF_PATH.tmp"
  mv "$WG_CONF_PATH.tmp" "$WG_CONF_PATH"

  log info "Replaced config at $WG_CONF_PATH"
  return 0
}

# Exit codes: 0 = success, 1 = failure
check_connectivity() {
  # First check if container is stuck in a restart loop using docker inspect
  # This is more reliable than parsing stderr from docker exec
  if [ "$(docker inspect "$GLUETUN_CONTAINER" --format '{{.State.Restarting}}' 2>/dev/null)" = "true" ]; then
    log debug "Container $GLUETUN_CONTAINER is in restart loop (detected via docker inspect)"
    return 1
  fi

  # Use Gluetun control server API - responds instantly even when VPN is broken
  public_ip=$(docker exec "$GLUETUN_CONTAINER" wget -qO- --timeout=5 http://localhost:8000/v1/publicip/ip 2>/dev/null | sed -n 's/.*"public_ip":"\([^"]*\)".*/\1/p')

  if [ -n "$public_ip" ]; then
    log debug "VPN connected with public IP: $public_ip"
    return 0
  fi

  log debug "VPN not connected (no public IP)"
  return 1
}

# Check port forwarding status via Gluetun control server
# Returns: 0 = working, 1 = not working
check_port_forwarding() {
  if [ "$PIA_PORT_FORWARDING" != "true" ]; then
    return 0  # Skip check if port forwarding not enabled
  fi

  port=$(docker exec "$GLUETUN_CONTAINER" wget -qO- --timeout=5 http://localhost:8000/v1/portforward 2>/dev/null | sed -n 's/.*"port":\([0-9]*\).*/\1/p')

  if [ -n "$port" ] && [ "$port" -gt 0 ]; then
    log debug "Port forwarding active on port: $port"
    return 0
  fi

  log debug "Port forwarding not active (port: ${port:-0})"
  return 1
}

# Get current server name from wg0.conf
get_current_server_name() {
  grep "^ServerCommonName" "$WG_CONF_PATH" 2>/dev/null | cut -d= -f2 | tr -d ' ' || true
}

# Get SERVER_NAMES from compose env file
get_env_server_names() {
  if [ -z "${DOCKER_COMPOSE_HOST_DIR:-}" ]; then
    return
  fi
  env_file="$DOCKER_COMPOSE_HOST_DIR/$DOCKER_COMPOSE_ENV_FILE"
  if [ -f "$env_file" ]; then
    grep "^SERVER_NAMES=" "$env_file" 2>/dev/null | cut -d= -f2 || true
  fi
}

# Get SERVER_NAMES from running Gluetun container
get_container_server_names() {
  docker exec "$GLUETUN_CONTAINER" printenv SERVER_NAMES 2>/dev/null || true
}

# Update SERVER_NAMES in compose env file (for persistence only)
# Note: This ensures the .env file matches the current config so future
# docker compose commands use the correct value. The restart will use
# the config file directly, so the change takes effect immediately.
update_env_server_names() {
  new_server="$1"
  if [ -z "${DOCKER_COMPOSE_HOST_DIR:-}" ]; then
    log debug "DOCKER_COMPOSE_HOST_DIR not set - skipping .env update"
    return 0
  fi

  env_file="$DOCKER_COMPOSE_HOST_DIR/$DOCKER_COMPOSE_ENV_FILE"
  if [ ! -f "$env_file" ]; then
    log debug "Env file not found: $env_file - skipping update"
    return 0
  fi

  # Update or add SERVER_NAMES in env file
  if grep -q "^SERVER_NAMES=" "$env_file"; then
    sed -i "s/^SERVER_NAMES=.*/SERVER_NAMES=$new_server/" "$env_file"
  else
    echo "SERVER_NAMES=$new_server" >> "$env_file"
  fi

  log debug "Updated SERVER_NAMES=$new_server in $env_file for persistence"
  return 0
}

# Get the docker compose project name from container labels
# This is the most reliable way to determine which project the container belongs to
get_compose_project() {
  docker inspect "$GLUETUN_CONTAINER" --format '{{index .Config.Labels "com.docker.compose.project"}}' 2>/dev/null || true
}

# Perform docker restart with error handling and logging
do_docker_restart() {
  if docker_output=$(docker restart "$GLUETUN_CONTAINER" 2>&1); then
    echo "$docker_output" >> "$DOCKER_LOG"
  else
    echo "$docker_output" >> "$DOCKER_LOG"
    # Check for common errors and surface them clearly
    if echo "$docker_output" | grep -qi "no such container"; then
      log error "Failed to restart container '$GLUETUN_CONTAINER': container not found"
      log error "Check that GLUETUN_CONTAINER matches your actual container name"
    elif echo "$docker_output" | grep -qi "permission denied"; then
      log error "Failed to restart container '$GLUETUN_CONTAINER': permission denied"
      log error "Check that the Docker socket is mounted correctly"
    else
      log error "Failed to restart container '$GLUETUN_CONTAINER'"
      log debug "Docker error: $docker_output"
    fi
  fi
}

# Recreate or restart Gluetun container and wait for it to come up
# Uses docker compose up -d if DOCKER_COMPOSE_HOST_DIR is set (picks up env changes),
# otherwise falls back to docker restart (doesn't update env vars).
# Project name is auto-detected from container labels.
# Sets pending_recovery=1 to force short interval checks until fully recovered.
restart_gluetun() {
  # Reset confirmation flags so recovery is logged properly
  tunnel_confirmed=0
  pf_confirmed=0
  pending_recovery=1

  if [ -n "${DOCKER_COMPOSE_HOST_DIR:-}" ]; then
    # Auto-detect project name from container labels
    project=$(get_compose_project)
    if [ -n "$project" ]; then
      compose_cmd="docker compose -p \"$project\" --project-directory \"$DOCKER_COMPOSE_HOST_DIR\" up -d --force-recreate \"$GLUETUN_CONTAINER\""
      log info "Recreating container $GLUETUN_CONTAINER (project: $project)..."
      log debug "Running compose command: $compose_cmd"

      if ! docker_output=$(docker compose -p "$project" --project-directory "$DOCKER_COMPOSE_HOST_DIR" up -d --force-recreate "$GLUETUN_CONTAINER" 2>&1); then
        compose_exit_code=$?
        echo "$docker_output" >> "$DOCKER_LOG"
        log warn "docker compose up -d failed (exit code: $compose_exit_code)"
        log debug "Compose output: $docker_output"
        log warn "Falling back to docker restart"
        do_docker_restart
      else
        echo "$docker_output" >> "$DOCKER_LOG"
        log debug "Compose output: $docker_output"
        log info "Container recreation command completed successfully"
      fi
    else
      log warn "Could not detect compose project name - falling back to restart"
      do_docker_restart
    fi
  else
    log info "Restarting container $GLUETUN_CONTAINER..."
    do_docker_restart
  fi

  # Wait for container to come up and verify state
  log info "Waiting for $GLUETUN_CONTAINER to come up..."
  sleep 10

  # Verify container is actually running
  if ! docker inspect "$GLUETUN_CONTAINER" >/dev/null 2>&1; then
    log error "Container $GLUETUN_CONTAINER does not exist after recreation attempt"
    return 1
  fi

  container_state=$(docker inspect -f '{{.State.Status}}' "$GLUETUN_CONTAINER" 2>/dev/null)
  log debug "Container state after recreation: $container_state"

  if [ "$container_state" != "running" ]; then
    log error "Container $GLUETUN_CONTAINER is not running (state: $container_state)"
    # Get the last few log lines to see why it failed
    log debug "Container logs: $(docker logs "$GLUETUN_CONTAINER" --tail 10 2>&1 | tr '\n' ' ')"
    return 1
  fi

  # Check if restart/recreation succeeded
  if check_connectivity; then
    log info "Tunnel up"
    tunnel_confirmed=1
    if [ "$PIA_PORT_FORWARDING" = "true" ]; then
      if check_port_forwarding; then
        log info "Port forwarding active"
        pf_confirmed=1
        pending_recovery=0
      else
        log debug "Port forwarding not active yet - will retry"
      fi
    else
      pending_recovery=0
    fi
  else
    log warn "Tunnel not up after restart - will retry"
  fi
}

# Run failure hook script asynchronously
# Args: $1 = failure type (connectivity/port_forwarding)
# Supports arguments in ON_FAILURE_SCRIPT (e.g., "/scripts/notify.sh failure")
run_failure_hook() {
  if [ -z "${ON_FAILURE_SCRIPT:-}" ]; then
    return 0
  fi

  failure_type="$1"
  log info "Running failure hook (type=$failure_type)"

  # Run script asynchronously with environment variables
  # Using eval to support script arguments
  (
    export FAILURE_TYPE="$failure_type"
    eval "$ON_FAILURE_SCRIPT" >> "$LOG_DIR/hooks.log" 2>&1
  ) &
}

# Run recovery hook script asynchronously
# Supports arguments in ON_RECOVERY_SCRIPT (e.g., "/scripts/notify.sh recover")
run_recovery_hook() {
  if [ -z "${ON_RECOVERY_SCRIPT:-}" ]; then
    return 0
  fi

  # Get current server name from config
  server_name=$(get_current_server_name)

  # Get forwarded port if port forwarding is enabled
  forwarded_port=""
  if [ "$PIA_PORT_FORWARDING" = "true" ]; then
    forwarded_port=$(docker exec "$GLUETUN_CONTAINER" wget -qO- --timeout=5 http://localhost:8000/v1/portforward 2>/dev/null | sed -n 's/.*"port":\([0-9]*\).*/\1/p' || true)
  fi

  log info "Running recovery hook (server=$server_name, port=${forwarded_port:-none})"

  # Run script asynchronously with environment variables
  # Using eval to support script arguments
  (
    export PIA_SERVER_NAME="$server_name"
    export PIA_FORWARDED_PORT="${forwarded_port:-}"
    eval "$ON_RECOVERY_SCRIPT" >> "$LOG_DIR/hooks.log" 2>&1
  ) &
}

download_pia_wg_config || true

if [ ! -x "$PIA_WG_CONFIG_BIN" ]; then
  log error "pia-wg-config not found or not executable at $PIA_WG_CONFIG_BIN"
  exit 1
fi

if [ "$SELF_TEST" = "1" ]; then
  log info "Self-test mode enabled; exiting after startup checks"
  exit 0
fi

failure_count=0
pf_failure_count=0
generation_failures=0
success_count=0
tunnel_confirmed=0
pf_confirmed=0
pending_recovery=0
first_check=1

log info "Starting refresh loop (interval=${CHECK_INTERVAL_SECONDS}s, healthy_interval=${HEALTHY_CHECK_INTERVAL_SECONDS}s, threshold=$FAIL_THRESHOLD, max_retries=$MAX_GENERATION_RETRIES)"
if [ "$PIA_PORT_FORWARDING" = "true" ]; then
  log info "Port forwarding monitoring enabled"
  if [ -n "${DOCKER_COMPOSE_HOST_DIR:-}" ]; then
    log info "Compose integration enabled (host_dir=$DOCKER_COMPOSE_HOST_DIR, env=$DOCKER_COMPOSE_ENV_FILE)"
  fi
fi
if [ -n "${ON_FAILURE_SCRIPT:-}" ] || [ -n "${ON_RECOVERY_SCRIPT:-}" ]; then
  log info "Hooks enabled (failure=${ON_FAILURE_SCRIPT:-none}, recovery=${ON_RECOVERY_SCRIPT:-none})"
fi

# Generate initial config if missing or invalid
# This prevents Gluetun from failing on fresh setups where no wg0.conf exists
if [ ! -f "$WG_CONF_PATH" ] || ! validate_config "$WG_CONF_PATH"; then
  log info "No valid config found at $WG_CONF_PATH, generating initial config..."
  if generate_config; then
    log info "Initial config generated successfully"
  else
    log warn "Failed to generate initial config - will retry in monitoring loop"
  fi
fi

while true; do
  if [ "$first_check" -eq 1 ]; then
    log info "Waiting for tunnel..."
    first_check=0
  fi

  log debug "Running connectivity check..."
  if check_connectivity; then
    # First success after startup or recovery
    if [ "$tunnel_confirmed" -eq 0 ]; then
      log info "Tunnel up"
      tunnel_confirmed=1
      # If no port forwarding, recovery is complete
      if [ "$PIA_PORT_FORWARDING" != "true" ]; then
        if [ "$pending_recovery" -eq 1 ]; then
          run_recovery_hook
        fi
        pending_recovery=0
      fi
    elif [ "$failure_count" -ne 0 ]; then
      log info "Connectivity restored"
    fi

    failure_count=0
    generation_failures=0
    success_count=$((success_count + 1))

    log debug "Connectivity check passed ($success_count)"

    # Check port forwarding if enabled
    if [ "$PIA_PORT_FORWARDING" = "true" ]; then
      if check_port_forwarding; then
        if [ "$pf_confirmed" -eq 0 ]; then
          log info "Port forwarding active"
          pf_confirmed=1
          if [ "$pending_recovery" -eq 1 ]; then
            run_recovery_hook
          fi
          pending_recovery=0
        fi
        pf_failure_count=0
      else
        pf_failure_count=$((pf_failure_count + 1))
        pf_confirmed=0

        if [ "$pf_failure_count" -ge "$FAIL_THRESHOLD" ]; then
          log warn "Port forwarding check failed ($pf_failure_count/$FAIL_THRESHOLD)"
          run_failure_hook "port_forwarding"

          # Check if SERVER_NAMES mismatch between config and container
          current_server=$(get_current_server_name)
          container_server=$(get_container_server_names)

          if [ -n "$current_server" ] && [ -n "$container_server" ] && [ "$current_server" != "$container_server" ]; then
            log info "Syncing SERVER_NAMES: $container_server -> $current_server"
            # Update .env file and recreate container to apply the change
            update_env_server_names "$current_server"
            restart_gluetun
            pf_failure_count=0
          else
            log warn "Port forwarding failed with matching SERVER_NAMES - regenerating config"
            if [ "$generation_failures" -ge "$MAX_GENERATION_RETRIES" ]; then
              log error "Max generation retries ($MAX_GENERATION_RETRIES) reached, waiting for recovery"
            elif generate_config; then
              restart_gluetun
              generation_failures=0
            else
              generation_failures=$((generation_failures + 1))
              log error "Config generation failed ($generation_failures/$MAX_GENERATION_RETRIES)"
            fi
            pf_failure_count=0
          fi
        else
          log debug "Port forwarding check failed ($pf_failure_count/$FAIL_THRESHOLD)"
        fi
      fi
    fi

    # Periodic health log at info level
    if [ "$((success_count % HEALTH_LOG_INTERVAL))" -eq 0 ]; then
      if [ "$PIA_PORT_FORWARDING" = "true" ] && [ "$pf_confirmed" -eq 1 ]; then
        log info "Tunnel healthy with port forwarding (${success_count} consecutive checks)"
      else
        log info "Tunnel healthy (${success_count} consecutive checks)"
      fi
    fi

    # Use longer interval when healthy (unless PF is failing or pending recovery)
    if [ "$pf_failure_count" -gt 0 ] || [ "$pending_recovery" -eq 1 ]; then
      sleep "$CHECK_INTERVAL_SECONDS"
    else
      sleep "$HEALTHY_CHECK_INTERVAL_SECONDS"
    fi
  else
    failure_count=$((failure_count + 1))
    success_count=0
    tunnel_confirmed=0
    pf_confirmed=0
    pf_failure_count=0

    if [ "$failure_count" -ge "$FAIL_THRESHOLD" ]; then
      log warn "Connectivity check failed ($failure_count/$FAIL_THRESHOLD)"
    else
      log debug "Connectivity check failed ($failure_count/$FAIL_THRESHOLD)"
    fi

    if [ "$failure_count" -ge "$FAIL_THRESHOLD" ]; then
      run_failure_hook "connectivity"
      if [ "$generation_failures" -ge "$MAX_GENERATION_RETRIES" ]; then
        log error "Max generation retries ($MAX_GENERATION_RETRIES) reached, waiting for connectivity to recover"
      elif generate_config; then
        restart_gluetun
        failure_count=0
        generation_failures=0
      else
        generation_failures=$((generation_failures + 1))
        log error "Config generation failed ($generation_failures/$MAX_GENERATION_RETRIES)"
        failure_count=0
      fi
    fi

    # Use shorter interval when degraded
    sleep "$CHECK_INTERVAL_SECONDS"
  fi
done
