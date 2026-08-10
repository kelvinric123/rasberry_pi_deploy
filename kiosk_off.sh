#!/bin/bash
# Drop out of kiosk mode into a usable desktop, for on-site maintenance —
# copying the SD card, changing Wi-Fi, reading a dialog.
#
# NOTHING here is persistent. A reboot always brings the queue screen back,
# and even without one the pause expires by itself after PAUSE_MINUTES, so a
# Pi that someone walked away from cannot be left dark.
#
# Installed to ~/.qmed/kiosk_off.sh; also the "QMed Exit Kiosk" desktop icon.

QMED_DIR="$HOME/.qmed"
PAUSE_FILE="/tmp/qmed-kiosk-paused"
# Optional first argument: minutes to stay down. setup.sh passes a long one,
# because a device being configured should not have the screen reappear.
PAUSE_MINUTES="${1:-60}"
export DISPLAY="${DISPLAY:-:0}"

echo "Stopping the kiosk..."

# 1. Tell net_watchdog.sh to stand down.
#
#    A marker file, NOT a crontab edit: removing the cron entry would outlive
#    a reboot and quietly leave this device's self-healing switched off
#    forever.
#
#    Format: "<expiry-epoch> <boot-id>". The boot id is what makes "until
#    restart" exact — after a reboot it no longer matches, so the pause is
#    void no matter what /tmp did or how long the expiry was. The expiry is
#    the second safety net, for a pause nobody ever came back to.
BOOT_ID=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo unknown)
printf '%s %s\n' "$(( $(date +%s) + PAUSE_MINUTES * 60 ))" "$BOOT_ID" > "$PAUSE_FILE" 2>/dev/null \
    && echo "  watchdog paused (until reboot, or ${PAUSE_MINUTES} minutes)"

# 2. The launcher loop, THEN the browser. The other order just makes the loop
#    start a fresh Chromium.
pkill -f "${QMED_DIR}/kiosk.sh" 2>/dev/null || true
sleep 1
pkill -f -- '--kiosk' 2>/dev/null || true

# 3. Give the mouse pointer back. kiosk.sh runs "unclutter -idle 0.5", which
#    hides the cursor half a second after it stops moving — fine for a queue
#    screen, unusable for a person.
pkill -x unclutter 2>/dev/null || true

# 4. Bring the taskbar back. Which binary depends on the session, so try the
#    one that matches and let the other be.
if ! pgrep -f 'lxpanel|wf-panel-pi' >/dev/null 2>&1; then
    if command -v wf-panel-pi >/dev/null 2>&1 && pgrep -x labwc >/dev/null 2>&1; then
        nohup wf-panel-pi >/dev/null 2>&1 &
    elif command -v lxpanel >/dev/null 2>&1; then
        nohup lxpanel --profile LXDE-pi >/dev/null 2>&1 &
    fi
    sleep 1
fi

if pgrep -f 'lxpanel|wf-panel-pi' >/dev/null 2>&1; then
    echo "  taskbar restored"
else
    echo "  this session has no taskbar — use the desktop icons instead"
fi

echo ""
echo "Kiosk stopped. Desktop icons: Wi-Fi, SD Card Copier, Setup."
echo ""
echo "To put the queue screen back, either reboot, or run:"
echo "    rm -f ${PAUSE_FILE} && nohup bash ${QMED_DIR}/kiosk.sh >/dev/null 2>&1 &"
echo ""
echo "If you do neither, the watchdog restarts it in ${PAUSE_MINUTES} minutes."
