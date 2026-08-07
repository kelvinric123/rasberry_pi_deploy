#!/bin/bash
# QMed Heartbeat — sends device status to the server every 60 seconds (cron).
#
# Besides status, it reports the device's REAL MAC address (so cloned SD
# cards stop showing the staging Pi's MAC on the admin page) and the installed
# scripts bundle version. The server's reply carries {"update": true} when an
# admin pressed the Update button for this device — that triggers
# self_update.sh, which downloads and installs the latest script bundle.
#
# Installed to ~/.qmed/heartbeat.sh by setup.sh and kept current by
# self_update.sh — edit it in the repo, not on the device.

QMED_DIR="$HOME/.qmed"
CONFIG_FILE="$QMED_DIR/config.json"

[ -f "$CONFIG_FILE" ] || exit 0

SERVER_URL=$(jq -r '.server_url // empty' "$CONFIG_FILE" 2>/dev/null)
DEVICE_TOKEN=$(jq -r '.device_token // empty' "$CONFIG_FILE" 2>/dev/null)

if [ -z "$SERVER_URL" ] || [ -z "$DEVICE_TOKEN" ]; then
    exit 0
fi

# Check if Chromium is running
if pgrep -x "chromium-browse" > /dev/null 2>&1 || pgrep -x "chromium" > /dev/null 2>&1; then
    CHROMIUM_STATUS="running"
else
    CHROMIUM_STATUS="stopped"
fi

# Current IP and the live hardware MAC of the default-route interface
IP_ADDR=$(hostname -I | awk '{print $1}')
MAC_ADDR=$(cat /sys/class/net/$(ip route show default 2>/dev/null | awk '/default/ {print $5}' | head -1)/address 2>/dev/null || echo "")

# Get screen resolution (cron has no DISPLAY set, so default to :0 for X11)
export DISPLAY="${DISPLAY:-:0}"
SCREEN_RES=$(xdpyinfo 2>/dev/null | grep dimensions | awk '{print $2}' || echo "unknown")

# Installed script-bundle version (stamped by setup.sh / self_update.sh)
SCRIPTS_VERSION=$(cat "$QMED_DIR/scripts_version" 2>/dev/null || echo "")

RESPONSE=$(curl -s --max-time 15 -X POST "${SERVER_URL}/api/open/raspberry-pi/heartbeat" \
    -H "Content-Type: application/json" \
    -d "{
        \"device_token\": \"${DEVICE_TOKEN}\",
        \"ip_address\": \"${IP_ADDR}\",
        \"mac_address\": \"${MAC_ADDR}\",
        \"chromium_status\": \"${CHROMIUM_STATUS}\",
        \"screen_resolution\": \"${SCREEN_RES}\",
        \"scripts_version\": \"${SCRIPTS_VERSION}\"
    }")

# Admin requested an update for this device (Update button, or a fleet-wide
# "Sync from Git"). flock: the cron fires every minute, so a slow download
# must never overlap with the next trigger.
#
# The server also decides whether the Pi should REBOOT after installing —
# older servers omit the field, in which case we keep the old behaviour and
# only restart the affected services.
if [ "$(echo "$RESPONSE" | jq -r '.update // false' 2>/dev/null)" = "true" ] && [ -f "$QMED_DIR/self_update.sh" ]; then
    if [ "$(echo "$RESPONSE" | jq -r '.reboot_after_update // false' 2>/dev/null)" = "true" ]; then
        REBOOT_FLAG="--reboot"
    else
        REBOOT_FLAG="--no-reboot"
    fi

    flock -n "$QMED_DIR/self_update.lock" \
        bash "$QMED_DIR/self_update.sh" "$REBOOT_FLAG" >> "$QMED_DIR/self_update.log" 2>&1 &
fi
