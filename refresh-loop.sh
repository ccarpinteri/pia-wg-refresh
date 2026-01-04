#!/bin/sh
set -eu

LOG_FILE="$LOG_DIR/refresh.log"
PIA_LOG="$LOG_DIR/pia-wg-config.log"
DOCKER_LOG="$LOG_DIR/docker.log"
: "${PIA_WG_CONFIG_BIN:=/usr/local/bin/pia-wg-config}"
: "${PIA_WG_CONFIG_URL:=}"
: "${PIA_WG_CONFIG_SHA256:=}"
: "${SELF_TEST:=0}"

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

log() {
  level="$1"
  shift
  if log_should_write "$level"; then
    ts=$(date -u "+%Y-%m-%dT%H:%M:%SZ")
    msg="$*"
    echo "$ts [$level] $msg" | tee -a "$LOG_FILE"
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

  "$PIA_WG_CONFIG_BIN" -r "$PIA_REGION" -o "$WG_CONF_PATH" "$PIA_USERNAME" "$PIA_PASSWORD" >>"$PIA_LOG" 2>&1

  if ! validate_config "$WG_CONF_PATH"; then
    restore_backup
    return 1
  fi

  log info "Replaced config at $WG_CONF_PATH"
  return 0
}

# Exit codes: 0 = success, 1 = failure, 2 = container restarting
check_connectivity() {
  err_file="/tmp/check_connectivity_err.$$"

  docker exec "$GLUETUN_CONTAINER" sh -c '
    url="$1"
    if command -v wget >/dev/null 2>&1; then
      wget -qO- "$url" >/dev/null 2>&1
      exit $?
    fi
    if command -v curl >/dev/null 2>&1; then
      curl -fsSL "$url" >/dev/null 2>&1
      exit $?
    fi
    if command -v busybox >/dev/null 2>&1; then
      busybox wget -qO- "$url" >/dev/null 2>&1
      exit $?
    fi
    exit 127
  ' sh "$CHECK_URL" 2>"$err_file"
  result=$?

  # Check if container is restarting
  if [ -f "$err_file" ] && grep -q "is restarting" "$err_file"; then
    rm -f "$err_file"
    return 2
  fi
  rm -f "$err_file"

  return $result
}

restart_gluetun() {
  log warn "Restarting container $GLUETUN_CONTAINER"
  docker restart "$GLUETUN_CONTAINER" >>"$DOCKER_LOG" 2>&1 || true
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
generation_failures=0
success_count=0
tunnel_confirmed=0

log info "Starting refresh loop (interval=${CHECK_INTERVAL_SECONDS}s, healthy_interval=${HEALTHY_CHECK_INTERVAL_SECONDS}s, threshold=$FAIL_THRESHOLD, max_retries=$MAX_GENERATION_RETRIES)"

while true; do
  check_connectivity
  check_result=$?

  if [ "$check_result" -eq 0 ]; then
    # First success after startup or recovery
    if [ "$tunnel_confirmed" -eq 0 ]; then
      log info "Tunnel up"
      tunnel_confirmed=1
    elif [ "$failure_count" -ne 0 ]; then
      log info "Connectivity restored"
    fi

    failure_count=0
    generation_failures=0
    success_count=$((success_count + 1))

    log debug "Connectivity check passed ($success_count)"

    # Periodic health log at info level
    if [ "$((success_count % HEALTH_LOG_INTERVAL))" -eq 0 ]; then
      log info "Tunnel healthy (${success_count} consecutive checks)"
    fi

    # Use longer interval when healthy
    sleep "$HEALTHY_CHECK_INTERVAL_SECONDS"
  elif [ "$check_result" -eq 2 ]; then
    # Container is restarting, skip this check without counting as failure
    log info "Container is restarting, skipping check"
    sleep "$CHECK_INTERVAL_SECONDS"
  else
    failure_count=$((failure_count + 1))
    success_count=0
    tunnel_confirmed=0
    log warn "Connectivity check failed ($failure_count/$FAIL_THRESHOLD)"

    if [ "$failure_count" -ge "$FAIL_THRESHOLD" ]; then
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
