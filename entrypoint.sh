#!/bin/sh
set -eu

: "${GLUETUN_CONTAINER:=gluetun}"
: "${WG_CONF_PATH:=/config/wg0.conf}"
: "${CHECK_URL:=https://www.google.com/generate_204}"
: "${CHECK_INTERVAL_SECONDS:=60}"
: "${HEALTHY_CHECK_INTERVAL_SECONDS:=1800}"
: "${FAIL_THRESHOLD:=3}"
: "${MAX_GENERATION_RETRIES:=3}"
: "${HEALTH_LOG_INTERVAL:=10}"
: "${LOG_LEVEL:=info}"
: "${LOG_DIR:=/logs}"
: "${PIA_PORT_FORWARDING:=false}"

export GLUETUN_CONTAINER WG_CONF_PATH CHECK_URL CHECK_INTERVAL_SECONDS HEALTHY_CHECK_INTERVAL_SECONDS FAIL_THRESHOLD MAX_GENERATION_RETRIES HEALTH_LOG_INTERVAL LOG_LEVEL LOG_DIR
export PIA_USERNAME PIA_PASSWORD PIA_REGION PIA_PORT_FORWARDING PIA_WG_CONFIG_BIN PIA_WG_CONFIG_URL PIA_WG_CONFIG_SHA256 SELF_TEST

if [ -z "${PIA_USERNAME:-}" ] || [ -z "${PIA_PASSWORD:-}" ] || [ -z "${PIA_REGION:-}" ]; then
  echo "PIA_USERNAME, PIA_PASSWORD, and PIA_REGION are required" >&2
  exit 1
fi

mkdir -p "$LOG_DIR"
touch "$LOG_DIR/refresh.log" "$LOG_DIR/pia-wg-config.log" "$LOG_DIR/docker.log"

mkdir -p "$(dirname "$WG_CONF_PATH")"

exec /app/refresh-loop.sh
