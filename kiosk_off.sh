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
# Optional first argument: minutes to stay down. Defaults to 12 hours —
# maintenance always ends with a reboot, and the boot-id check voids the
# pause the moment that happens, so a long expiry costs nothing and a short
# one puts the kiosk back over an engineer's half-finished SD copy.
PAUSE_MINUTES="${1:-720}"
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

# 4. Bring the taskbar and the desktop icons back.
#
#    kiosk.sh kills the panel on every launch (it pops over the fullscreen
#    window whenever that loses its top layer), so nothing restarts it but us.
#    Which binary and which profile depends on the session — install.sh puts
#    the Pi on X11/Openbox via `raspi-config nonint do_wayland W1`, where the
#    panel is lxpanel, but a device that was never switched may be on labwc
#    with wf-panel-pi. Try each in turn instead of guessing once.
restore_panel() {
    pgrep -f 'lxpanel|wf-panel-pi|xfce4-panel' >/dev/null 2>&1 && return 0

    # Wayland session first, if that is what is actually running.
    if pgrep -x labwc >/dev/null 2>&1 || pgrep -x wayfire >/dev/null 2>&1; then
        if command -v wf-panel-pi >/dev/null 2>&1; then
            nohup wf-panel-pi >/dev/null 2>&1 &
            sleep 1
            pgrep -f wf-panel-pi >/dev/null 2>&1 && return 0
        fi
    fi

    # X11: the profile name differs between Pi OS releases, so try the ones
    # that exist rather than assuming LXDE-pi.
    if command -v lxpanel >/dev/null 2>&1; then
        for PROFILE in LXDE-pi LXDE pi ""; do
            if [ -n "$PROFILE" ]; then
                [ -d "$HOME/.config/lxpanel/$PROFILE" ] || continue
                nohup lxpanel --profile "$PROFILE" >/dev/null 2>&1 &
            else
                nohup lxpanel >/dev/null 2>&1 &
            fi
            sleep 1
            if pgrep -f lxpanel >/dev/null 2>&1; then
                echo "  taskbar restored (lxpanel${PROFILE:+ --profile $PROFILE})"
                return 0
            fi
        done
    fi

    return 1
}

# Desktop icons are drawn by the file manager, not the panel. On a session
# where it was never started there is nothing to click even once the panel is
# back, so make sure it is running too.
restore_desktop_icons() {
    pgrep -f 'pcmanfm.*--desktop' >/dev/null 2>&1 && return 0
    command -v pcmanfm >/dev/null 2>&1 || return 1
    nohup pcmanfm --desktop >/dev/null 2>&1 &
    sleep 1
    pgrep -f 'pcmanfm.*--desktop' >/dev/null 2>&1
}

if restore_panel; then
    :
else
    echo "  could not start a taskbar."
    echo "    session : ${XDG_SESSION_TYPE:-unknown} / ${XDG_CURRENT_DESKTOP:-unknown}"
    printf "    panels  :"
    for B in lxpanel wf-panel-pi xfce4-panel; do
        command -v "$B" >/dev/null 2>&1 && printf " %s" "$B"
    done
    echo ""
    echo "    If none are listed, install one:  sudo apt-get install -y lxpanel"
fi

restore_desktop_icons && echo "  desktop icons restored" || true

echo ""
echo "Kiosk stopped. Desktop icons: Wi-Fi, SD Card Copier, Setup."
echo ""
echo "To put the queue screen back, either reboot, or run:"
echo "    rm -f ${PAUSE_FILE} && nohup bash ${QMED_DIR}/kiosk.sh >/dev/null 2>&1 &"
echo ""
echo "If you do neither, the watchdog restarts it in ${PAUSE_MINUTES} minutes."
