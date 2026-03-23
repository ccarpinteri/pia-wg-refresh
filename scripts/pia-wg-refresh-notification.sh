#!/bin/sh

# pia-wg-refresh-notification.sh
# Sends Prowl notifications for pia-wg-refresh events

# Configuration
PROWL_API_KEY="${PROWL_API_KEY:-your-prowl-api-key-here}"  # Set via environment variable or edit here
APP_NAME="pia-wg-refresh"
PROWL_URL="https://api.prowlapp.com/publicapi/add"

# Check if API key is set
if [ -z "$PROWL_API_KEY" ]; then
    echo "Error: PROWL_API_KEY environment variable not set" >&2
    echo "Set it with: export PROWL_API_KEY='your-api-key-here'" >&2
    exit 1
fi

# Check if event type is provided
if [ $# -eq 0 ]; then
    echo "Usage: $0 {failure|recover|ports}" >&2
    exit 1
fi

EVENT_TYPE="$1"

# Set notification parameters based on event type
case "$EVENT_TYPE" in
    failure)
        PRIORITY=2  # Emergency priority
        EVENT="Connection Failure"
        DESCRIPTION="PIA WireGuard connection has failed"
        ;;
    recover)
        PRIORITY=0  # Normal priority
        EVENT="Connection Recovered"
        DESCRIPTION="PIA WireGuard connection has been restored"
        ;;
    ports)
        PRIORITY=-1  # Low priority
        EVENT="Port Changed"
        if [ -z "$PIA_PREVIOUS_PORT" ]; then
            DESCRIPTION="Port forwarding active: ${PIA_FORWARDED_PORT:-unknown} (server: ${PIA_SERVER_NAME:-unknown})"
        else
            DESCRIPTION="Port changed: ${PIA_PREVIOUS_PORT} -> ${PIA_FORWARDED_PORT:-unknown} (server: ${PIA_SERVER_NAME:-unknown})"
        fi
        ;;
    *)
        echo "Error: Invalid event type '$EVENT_TYPE'" >&2
        echo "Usage: $0 {failure|recover|ports}" >&2
        exit 1
        ;;
esac

# Send notification to Prowl
response=$(curl -s -w "\n%{http_code}" -X POST "$PROWL_URL" \
    -d "apikey=$PROWL_API_KEY" \
    -d "application=$APP_NAME" \
    -d "event=$EVENT" \
    -d "description=$DESCRIPTION" \
    -d "priority=$PRIORITY")

http_code=$(echo "$response" | tail -n1)
body=$(echo "$response" | sed '$d')

# Check response
if [ "$http_code" -eq 200 ]; then
    echo "Notification sent successfully: $EVENT"
    exit 0
else
    echo "Failed to send notification. HTTP status: $http_code" >&2
    echo "Response: $body" >&2
    exit 1
fi