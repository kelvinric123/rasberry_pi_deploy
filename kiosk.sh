#!/bin/bash
# QMed Queue Screen kiosk launcher (self-healing).
# Reads its target from ~/.qmed/config.json.
#
# Installed to ~/.qmed/kiosk.sh by setup.sh and kept current by
# self_update.sh — edit it in the repo, not on the device.

QMED_DIR="$HOME/.qmed"
CONFIG_FILE="$QMED_DIR/config.json"
LOG_FILE="$QMED_DIR/kiosk.log"

# Trim the log if it grew large across previous boots (it is appended to)
if [ -f "$LOG_FILE" ] && [ "$(wc -c < "$LOG_FILE" 2>/dev/null || echo 0)" -gt 1000000 ]; then
    tail -n 500 "$LOG_FILE" > "$LOG_FILE.tmp" 2>/dev/null && mv "$LOG_FILE.tmp" "$LOG_FILE"
fi

exec >> "$LOG_FILE" 2>&1
echo "==== kiosk starting $(date) ===="

# Single-instance guard: the watchdog cron may relaunch this script if it
# believes the loop died — the lock makes a duplicate launch exit harmlessly
# instead of racing the surviving loop with a second Chromium.
exec 9>"$QMED_DIR/kiosk.lock"
if ! flock -n 9; then
    echo "kiosk.sh already running; exiting."
    exit 0
fi

# Let the desktop settle
sleep 5

export DISPLAY="${DISPLAY:-:0}"

SERVER_URL=$(jq -r '.server_url // empty' "$CONFIG_FILE" 2>/dev/null)
SCREEN_URL=$(jq -r '.screen_url // empty' "$CONFIG_FILE" 2>/dev/null)

if [ -z "$SCREEN_URL" ]; then
    echo "No screen_url in config; run setup.sh. Exiting."
    exit 0
fi

# Stop screen blanking / power management (X11; harmless if unavailable)
xset s off 2>/dev/null || true
xset -dpms 2>/dev/null || true
xset s noblank 2>/dev/null || true

# Best-effort: keep Wi-Fi awake (needs passwordless sudo; skipped otherwise)
for IFACE in $(ls /sys/class/net 2>/dev/null | grep -E '^wl'); do
    sudo -n iw dev "$IFACE" set power_save off 2>/dev/null || true
done

# Hide the mouse cursor when idle
pkill -x unclutter 2>/dev/null || true
unclutter -idle 0.5 -root >/dev/null 2>&1 &

# A kiosk has no use for the desktop taskbar — and it actively breaks the
# native video overlay: whenever the fullscreen kiosk loses its top layer
# (e.g. mpv holds focus), the panel pops in over the screen ("top bar").
# -f: the binary is "lxpanel-pi" on current Pi OS, plain "lxpanel" on older.
pkill -f lxpanel 2>/dev/null || true
pkill -f wf-panel-pi 2>/dev/null || true

# Start the local video/config server (serves cached videos + config.json)
bash "$QMED_DIR/start_local_server.sh" >/dev/null 2>&1 &

# Sync local videos in the background (script self-skips in cloud mode)
if [ -f "$QMED_DIR/video_sync.sh" ]; then
    bash "$QMED_DIR/video_sync.sh" >/dev/null 2>&1 &
fi

# Chromium's binary name varies across OS releases
CHROMIUM_BIN="$(command -v chromium || command -v chromium-browser || echo chromium)"

# ── Wait for the server before first load (max ~120s, then load anyway) ──
echo "Waiting for network..."
for i in $(seq 1 60); do
    if curl -s -o /dev/null --max-time 4 "${SERVER_URL:-$SCREEN_URL}"; then
        echo "Network is up."
        break
    fi
    sleep 2
done

CHROME_PROFILE="$QMED_DIR/chrome-profile"
mkdir -p "$CHROME_PROFILE"

# ── Self-healing launch loop ─────────────────────────────────────────
# Relaunches Chromium if it crashes, is OOM-killed, or is killed by the
# watchdog to force a reload after a network outage.
while true; do
    # Clear crash/restore state so no "Restore pages?" bar appears
    sed -i 's/"exit_type":"[^"]*"/"exit_type":"Normal"/; s/"exited_cleanly":false/"exited_cleanly":true/' \
        "$CHROME_PROFILE/Default/Preferences" 2>/dev/null || true

    echo "Launching Chromium $(date)"
    # The three no-throttling flags (+ IntensiveWakeUpThrottling) keep the
    # page's JS timers at full speed even when Chromium is "occluded" — which
    # is exactly what happens whenever the mpv overlay (layout G) sits on top.
    # A throttled page reacts late to queue calls and can miss its own SSE
    # staleness watchdog.
    "$CHROMIUM_BIN" \
        --user-data-dir="$CHROME_PROFILE" \
        --password-store=basic \
        --ignore-gpu-blocklist \
        --enable-features=VaapiVideoDecoder,VaapiVideoEncoder \
        --enable-hardware-overlays \
        --enable-zero-copy \
        --noerrdialogs \
        --disable-infobars \
        --disable-session-crashed-bubble \
        --disable-features=TranslateUI,IntensiveWakeUpThrottling \
        --check-for-update-interval=31536000 \
        --autoplay-policy=no-user-gesture-required \
        --disable-background-timer-throttling \
        --disable-backgrounding-occluded-windows \
        --disable-renderer-backgrounding \
        --kiosk "$SCREEN_URL"

    echo "Chromium exited $(date); restarting in 3s"
    sleep 3
done
