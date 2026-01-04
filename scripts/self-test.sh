#!/bin/sh
set -eu

IMAGE_NAME="${IMAGE_NAME:-pia-wg-refresh}"
MODE="${1:-all}"

if ! docker info >/dev/null 2>&1; then
  echo "Docker daemon is not running or not reachable. Start Docker and try again." >&2
  exit 1
fi

docker build -t "$IMAGE_NAME" .

if [ "$MODE" = "all" ] || [ "$MODE" = "bundled" ]; then
  docker run --rm \
    -e PIA_USERNAME=test \
    -e PIA_PASSWORD=test \
    -e PIA_REGION=us_chicago \
    -e SELF_TEST=1 \
    -e LOG_DIR=/logs \
    "$IMAGE_NAME"
fi

if [ "$MODE" = "all" ] || [ "$MODE" = "download" ]; then
  tmp_bin="$(mktemp /tmp/pia-wg-config.XXXXXX)"
  trap 'rm -f "$tmp_bin"' EXIT

  cat >"$tmp_bin" <<'EOF'
#!/bin/sh
echo "fake pia-wg-config"
EOF
  chmod +x "$tmp_bin"

  hash="$(sha256sum "$tmp_bin" | awk '{print $1}')"

  docker run --rm \
    -e PIA_USERNAME=test \
    -e PIA_PASSWORD=test \
    -e PIA_REGION=us_chicago \
    -e SELF_TEST=1 \
    -e LOG_DIR=/logs \
    -e PIA_WG_CONFIG_URL="file:///mnt/$(basename "$tmp_bin")" \
    -e PIA_WG_CONFIG_SHA256="$hash" \
    -v /tmp:/mnt \
    "$IMAGE_NAME"
fi
