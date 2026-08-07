#!/bin/bash
# One-time bootstrap for Raspberry Pis provisioned BEFORE the self-update
# system existed. After this runs once, the device updates itself whenever
# an admin presses the Update button — no more manual visits.
#
# Run on the Pi (terminal or SSH):
#   curl -fsSL https://v2.qmed.asia/raspberry-pi/bootstrap_update.sh | bash
#
# It: installs self_update.sh, pulls the full current script bundle (which
# includes the new heartbeat.sh that answers Update requests), stamps the
# real MAC address into config.json (fixes "Shared MAC" rows from cloned SD
# cards), and makes sure the heartbeat + watchdog cron jobs exist.

set -e

QMED_DIR="$HOME/.qmed"
CONFIG_FILE="$QMED_DIR/config.json"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "This Pi is not set up yet — run setup.sh instead."
    exit 1
fi

SERVER_URL=$(jq -r '.server_url // empty' "$CONFIG_FILE" 2>/dev/null)
if [ -z "$SERVER_URL" ]; then
    echo "No server_url in ${CONFIG_FILE} — run setup.sh instead."
    exit 1
fi

echo "Bootstrapping self-update from ${SERVER_URL} ..."

curl -fsSL --max-time 30 "${SERVER_URL}/raspberry-pi/self_update.sh" -o "${QMED_DIR}/self_update.sh"
chmod +x "${QMED_DIR}/self_update.sh"

# Pull the whole current bundle (heartbeat.sh, kiosk.sh, net_watchdog.sh,
# server.py, ...) and stamp the version file.
bash "${QMED_DIR}/self_update.sh" --force

# Record this device's REAL MAC in config.json. setup.sh now uses it to
# detect cloned SD cards (stored MAC != live MAC -> register as NEW device
# instead of hijacking the original's registration).
MAC_ADDR=$(cat /sys/class/net/$(ip route show default 2>/dev/null | awk '/default/ {print $5}' | head -1)/address 2>/dev/null || echo "")
if [ -n "$MAC_ADDR" ]; then
    jq --arg mac "$MAC_ADDR" '.mac_address = $mac' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" \
        && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
    echo "Stamped MAC ${MAC_ADDR} into config.json"
fi

# Ensure the cron jobs exist (older installs may predate the watchdog).
(crontab -l 2>/dev/null | grep -v "qmed/heartbeat" || true) | crontab -
(crontab -l 2>/dev/null || true; echo "* * * * * ${QMED_DIR}/heartbeat.sh") | crontab -
(crontab -l 2>/dev/null | grep -v "qmed/net_watchdog" || true) | crontab -
(crontab -l 2>/dev/null || true; echo "* * * * * ${QMED_DIR}/net_watchdog.sh") | crontab -

echo ""
echo "Bootstrap complete. This device now reports its scripts version in every"
echo "heartbeat and installs updates when the admin presses Update."
