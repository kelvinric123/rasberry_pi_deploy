#!/bin/bash
# QMed network + process + page watchdog.
# Runs every minute and heals, in order:
#   * Wi-Fi power save and dropped connections
#   * the kiosk launcher loop and the local config/video server
#   * a daily preventive Chromium restart (leaks cannot accumulate for weeks)
#   * the SERVER, judged by HTTP status so an nginx 502 counts as down
#   * the PAGE, so a Chromium error page is reloaded instead of sitting there
#
# The last two are the recovery path for "the screen stopped working after
# the internet blipped": the browser does not retry a failed load by itself,
# and once the page is gone so is every piece of JavaScript that might have
# noticed.
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

# ── Server health ────────────────────────────────────────────────────
# Probe the EXACT page the kiosk displays, not the site root: that is the
# only URL whose health actually predicts whether the screen can recover.
# (Falls back to the root for devices set up before screen_url existed.)
PROBE_URL=$(jq -r '.screen_url // empty' "$CONFIG_FILE" 2>/dev/null)
[ -n "$PROBE_URL" ] || PROBE_URL="$SERVER_URL"

# The STATUS CODE matters, not merely "did curl connect". Plain
# `curl -s -o /dev/null URL` exits 0 for ANY response — including nginx's
# 502/504 — so a broken back end used to be recorded as "up" and nothing
# ever recovered from it. That was the biggest hole here: the screen sat on
# an error page while the watchdog reported everything fine.
#
# -L follows the redirect a shared/queue URL may issue, so we judge the page
# that is finally served.
HTTP_CODE=$(curl -sL -o /dev/null --max-time 8 -w '%{http_code}' "$PROBE_URL" 2>/dev/null || echo "000")
case "$HTTP_CODE" in
    # Servable: the browser will render the queue page.
    2*|3*) SERVER_OK=1 ;;
    # 5xx is nginx or the app failing — the page genuinely cannot load.
    5*)    SERVER_OK=0 ;;
    # No response at all: network, DNS or Wi-Fi.
    000)   SERVER_OK=0 ;;
    # 4xx means the server is alive and answering. Something is misconfigured
    # (wrong screen id, auth), which a reload will not fix — but the server
    # is NOT down, so do not bounce Wi-Fi and do not suppress the page check.
    *)     SERVER_OK=1 ;;
esac

if [ "$SERVER_OK" = "1" ]; then
    PREV=$(cat "$STATE_FILE" 2>/dev/null || echo "up")
    echo "up" > "$STATE_FILE"
    if [ "$PREV" = "down" ]; then
        log "Page servable again (HTTP ${HTTP_CODE}); reloading kiosk."
        pkill -f -- '--kiosk' 2>/dev/null || true   # self-heal loop relaunches it
    fi
    case "$HTTP_CODE" in
        4*) log "Page returned HTTP ${HTTP_CODE} — check the screen URL in config.json; a reload will not fix this." ;;
    esac
else
    echo "down" > "$STATE_FILE"

    # "000" means curl got no response at all — DNS, routing or Wi-Fi. Any
    # other code means the network is fine and the SERVER is unwell, so
    # bouncing Wi-Fi would be pointless churn.
    if [ "$HTTP_CODE" = "000" ]; then
        log "Server unreachable (no response); attempting to reconnect."

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
    else
        log "Server responded HTTP ${HTTP_CODE} (nginx/app error); network is fine, waiting for it to recover."
    fi
fi

# ── Kiosk page health ────────────────────────────────────────────────
# Everything above heals the network and the processes. This heals the case
# none of them can see: Chromium parked on its own error page.
#
# When a navigation fails — Wi-Fi dropped mid-load, DNS gone, nginx 502 —
# Chromium renders an error page and STAYS there indefinitely; it does not
# retry on its own. The queue page's JavaScript went with it, so the in-page
# SSE watchdog cannot help either. Only something outside the browser can,
# and the window title is the cheapest reliable signal: the queue page always
# titles itself "Queue Display - ...", an error page never does.
#
# Checked once a minute by this cron, so a screen is never wrong for long.
PAGE_FAIL_FILE="$QMED_DIR/page_fail_count"
PAGE_TITLE_MARKER="Queue Display"

kiosk_window_id() {
    command -v xdotool >/dev/null 2>&1 || return 1
    # Pattern, not a literal: WM_CLASS is "chromium" on some builds and
    # "Chromium-browser" on others.
    xdotool search --onlyvisible --class '[Cc]hromium' 2>/dev/null | head -1
}

# Only meaningful once the desktop has settled and only when the server is
# actually serving — reloading against a down server just paints another
# error page and would spin every minute for the length of the outage.
if [ "${UPTIME_S:-999}" -gt 180 ] && [ "$SERVER_OK" = "1" ]; then
    export DISPLAY="${DISPLAY:-:0}"
    WID=$(kiosk_window_id)

    if [ -n "$WID" ]; then
        TITLE=$(xdotool getwindowname "$WID" 2>/dev/null || echo "")

        if [ -n "$TITLE" ] && [ "${TITLE#*$PAGE_TITLE_MARKER}" != "$TITLE" ]; then
            # Healthy — forget any earlier trouble.
            [ -f "$PAGE_FAIL_FILE" ] && rm -f "$PAGE_FAIL_FILE"
        else
            FAILS=$(cat "$PAGE_FAIL_FILE" 2>/dev/null || echo 0)
            FAILS=$((FAILS + 1))
            echo "$FAILS" > "$PAGE_FAIL_FILE"
            log "Kiosk is not showing the queue page (title: '${TITLE:-unknown}') — attempt ${FAILS}."

            if [ "$FAILS" -ge 3 ]; then
                # Two soft reloads did not fix it; restart the browser.
                log "Still wrong after ${FAILS} tries; restarting Chromium."
                rm -f "$PAGE_FAIL_FILE"
                pkill -f -- '--kiosk' 2>/dev/null || true
            else
                # Activate first: a key sent with `--window` goes via
                # XSendEvent, which Chromium ignores. Activating and typing
                # into the focused window uses XTEST, which it honours.
                xdotool windowactivate --sync "$WID" key --clearmodifiers F5 2>/dev/null \
                    || pkill -f -- '--kiosk' 2>/dev/null || true
            fi
        fi
    fi
fi
