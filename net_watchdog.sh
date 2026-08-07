#!/bin/bash
# QMed network + process watchdog.
# Runs every minute: keeps Wi-Fi awake, reconnects after outages, forces the
# kiosk to reload once the server is reachable again, and (v2.1) also heals
# the two local processes announcements depend on — the kiosk launcher loop
# and the local config/video server — plus a daily preventive Chromium
# restart so leaks can never accumulate for weeks.
#
# Installed to ~/.qmed/net_watchdog.sh by setup.sh and kept current by
# self_update.sh — edit it in the repo, not on the device.

QMED_DIR="$HOME/.qmed"
CONFIG_FILE="$QMED_DIR/config.json"
STATE_FILE="$QMED_DIR/net_state"
LOG_FILE="$QMED_DIR/net_watchdog.log"

[ -f "$CONFIG_FILE" ] || exit 0
SERVER_URL=$(jq -r '.server_url // empty' "$CONFIG_FILE" 2>/dev/null)
[ -n "$SERVER_URL" ] || exit 0

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG_FILE"; }

# Trim the log if it grew large (this script appends forever)
if [ -f "$LOG_FILE" ] && [ "$(wc -c < "$LOG_FILE" 2>/dev/null || echo 0)" -gt 500000 ]; then
    tail -n 300 "$LOG_FILE" > "$LOG_FILE.tmp" 2>/dev/null && mv "$LOG_FILE.tmp" "$LOG_FILE"
fi

# Keep Wi-Fi power management off (cheap, idempotent)
for IFACE in $(ls /sys/class/net 2>/dev/null | grep -E '^wl'); do
    sudo -n iw dev "$IFACE" set power_save off 2>/dev/null || true
done

# ── Process self-heal (v2.1) ─────────────────────────────────────────
# Skipped during the first 3 minutes after boot: the desktop autostart owns
# the initial launch, and racing it from cron could start things twice.
# (kiosk.sh also holds a flock, so even a race cannot double-launch.)
UPTIME_S=$(cut -d. -f1 /proc/uptime 2>/dev/null || echo 999)
if [ "${UPTIME_S:-999}" -gt 180 ]; then
    # 1. The kiosk launcher loop itself. Chromium crashes are covered by the
    #    loop, but if the loop DIES (killed, OOM, bad update) nothing restarts
    #    Chromium ever again — the screen stays frozen until a power cycle.
    if ! pgrep -f "$QMED_DIR/kiosk.sh" >/dev/null 2>&1; then
        log "kiosk.sh loop not running; relaunching."
        export DISPLAY="${DISPLAY:-:0}"
        nohup bash "$QMED_DIR/kiosk.sh" >/dev/null 2>&1 &
    fi
fi

# 2. The local config/video server. Without it the page cannot read its
#    device_token, falls back to the shared SSE path, and announcements can
#    echo or misroute. config.json is the cheapest end-to-end probe.
if ! curl -s -o /dev/null --max-time 4 "http://localhost:8888/config.json"; then
    log "Local server (port 8888) not answering; restarting."
    bash "$QMED_DIR/start_local_server.sh" >/dev/null 2>&1
fi

# 3. Daily preventive Chromium restart at 04:00 (clinic idle hours). A
#    Chromium that has been up for weeks accumulates leaked renderer memory
#    and audio-stack state — the classic "worked for days, then announcements
#    got flaky". One restart/day resets that for the cost of ~10s of black
#    screen at night. Marker file keeps it to once per day.
RESTART_MARK="$QMED_DIR/daily_restart_date"
if [ "$(date +%H)" = "04" ]; then
    TODAY=$(date +%Y-%m-%d)
    if [ "$(cat "$RESTART_MARK" 2>/dev/null)" != "$TODAY" ]; then
        echo "$TODAY" > "$RESTART_MARK"
        log "Daily preventive Chromium restart."
        pkill -f -- '--kiosk' 2>/dev/null || true   # kiosk.sh loop relaunches it
    fi
fi

# ── Network reachability ─────────────────────────────────────────────
if curl -s -o /dev/null --max-time 8 "$SERVER_URL"; then
    PREV=$(cat "$STATE_FILE" 2>/dev/null || echo "up")
    echo "up" > "$STATE_FILE"
    if [ "$PREV" = "down" ]; then
        log "Network recovered; reloading kiosk."
        pkill -f -- '--kiosk' 2>/dev/null || true   # self-heal loop relaunches it
    fi
    exit 0
fi

# Unreachable — try to recover the connection.
echo "down" > "$STATE_FILE"
log "Server unreachable; attempting to reconnect."

if command -v nmcli >/dev/null 2>&1; then
    ACTIVE_WIFI=$(nmcli -t -f NAME,DEVICE connection show --active 2>/dev/null | awk -F: '$2 ~ /^wl/ {print $1; exit}')
    if [ -n "$ACTIVE_WIFI" ]; then
        sudo -n nmcli connection up "$ACTIVE_WIFI" 2>/dev/null || true
    else
        SAVED_WIFI=$(nmcli -t -f NAME,TYPE connection show 2>/dev/null | awk -F: '$2 ~ /wireless/ {print $1; exit}')
        [ -n "$SAVED_WIFI" ] && sudo -n nmcli connection up "$SAVED_WIFI" 2>/dev/null || true
    fi
    WIFI_DEV=$(nmcli -t -f DEVICE,TYPE device 2>/dev/null | awk -F: '$2=="wifi"{print $1; exit}')
    [ -n "$WIFI_DEV" ] && sudo -n nmcli device connect "$WIFI_DEV" 2>/dev/null || true
fi
