#!/bin/bash
# Write the QMed desktop icons.
#
# ONE implementation, called from two places:
#   * setup.sh        — during provisioning
#   * self_update.sh  — after every bundle install, so devices already in the
#                       field get new icons without anyone re-running setup
#
# Idempotent: it rewrites the same files every time, so running it twice
# changes nothing.
#
# Usage:  bash desktop_shortcuts.sh [path-to-setup-folder]
#
# The optional argument is the folder holding setup.sh, used for the "QMed
# Setup" icon. Called without it (from self_update.sh, which has no idea where
# the operator keeps that folder) any existing Setup icon is left untouched
# rather than pointed somewhere wrong.

QMED_DIR="$HOME/.qmed"
DESKTOP_DIR="$HOME/Desktop"
SETUP_DIR="${1:-}"
LAUNCH_SCRIPT="${QMED_DIR}/kiosk.sh"

mkdir -p "$DESKTOP_DIR" || exit 0

write_icon() {
    local file="$1"
    shift
    printf '%s\n' "$@" > "${DESKTOP_DIR}/${file}"
    chmod +x "${DESKTOP_DIR}/${file}" 2>/dev/null || true
    # Newer file managers refuse to run a launcher until it is marked trusted.
    gio set "${DESKTOP_DIR}/${file}" metadata::trusted true 2>/dev/null || true
}

# ── Queue screen ─────────────────────────────────────────────────────
write_icon "QMed Queue Screen.desktop" \
    "[Desktop Entry]" "Type=Application" "Name=QMed Queue Screen" \
    "Comment=Launch the queue screen" \
    "Exec=/bin/bash ${LAUNCH_SCRIPT}" \
    "Icon=chromium-browser" "Terminal=false" "Categories=Application;"

# ── Device setup ─────────────────────────────────────────────────────
# Only when we were told where setup.sh lives; otherwise leave whatever is
# already there, since a wrong path is worse than an old one.
if [ -n "$SETUP_DIR" ] && [ -f "${SETUP_DIR}/setup.sh" ]; then
    write_icon "QMed Setup.desktop" \
        "[Desktop Entry]" "Type=Application" "Name=QMed Device Setup" \
        "Comment=Re-run QMed device setup (pauses the queue screen until reboot)" \
        "Exec=bash -c \"cd '${SETUP_DIR}' && bash setup.sh; echo ''; read -p 'Press Enter to close...'\"" \
        "Icon=preferences-system" "Terminal=true" "Categories=Settings;"
fi

# ── Exit kiosk ───────────────────────────────────────────────────────
# The one that makes the others reachable: until the kiosk stops, the desktop
# is behind a fullscreen browser and no icon can be clicked.
if [ -f "${QMED_DIR}/kiosk_off.sh" ]; then
    write_icon "QMed Exit Kiosk.desktop" \
        "[Desktop Entry]" "Type=Application" "Name=QMed Exit Kiosk" \
        "Comment=Stop the queue screen and show the desktop (reboot restores it)" \
        "Exec=bash -c \"bash '${QMED_DIR}/kiosk_off.sh'; echo ''; read -p 'Press Enter to close...'\"" \
        "Icon=system-log-out" "Terminal=true" "Categories=Settings;"
fi

# ── Wi-Fi (pick from a list, password shown as typed) ────────────────
if [ -f "${QMED_DIR}/wifi_setup.sh" ]; then
    write_icon "QMed Wi-Fi.desktop" \
        "[Desktop Entry]" "Type=Application" "Name=QMed Wi-Fi" \
        "Comment=Scan for a wireless network and connect this device to it" \
        "Exec=bash '${QMED_DIR}/wifi_setup.sh'" \
        "Icon=network-wireless" "Terminal=false" "Categories=Settings;"
fi

# ── Network Connections (static IP, Ethernet, saved profiles) ────────
# Goes through wifi_setup.sh --editor rather than launching the binary
# directly: the queue screen is fullscreen and always-on-top, so a window
# opened under it is invisible and looks like the app failed to start. The
# wrapper stops the kiosk first and restarts it when the window closes.
#
# That is also why we do NOT copy the system's own launcher here, even though
# it has a nicer icon — it would exec the binary unwrapped.
if [ -f "${QMED_DIR}/wifi_setup.sh" ] \
    && { command -v nm-connection-editor >/dev/null 2>&1 \
        || [ -f /usr/share/applications/nm-connection-editor.desktop ]; }; then
    write_icon "Network Connections.desktop" \
        "[Desktop Entry]" "Type=Application" "Name=Network Connections" \
        "Comment=Edit network connections, static IP and saved profiles" \
        "Exec=bash '${QMED_DIR}/wifi_setup.sh' --editor" \
        "Icon=preferences-system-network" "Terminal=false" "Categories=Settings;"
fi

# ── SD Card Copier ───────────────────────────────────────────────────
if [ -f /usr/share/applications/piclone.desktop ]; then
    cp /usr/share/applications/piclone.desktop "${DESKTOP_DIR}/SD Card Copier.desktop" 2>/dev/null
    chmod +x "${DESKTOP_DIR}/SD Card Copier.desktop" 2>/dev/null || true
    gio set "${DESKTOP_DIR}/SD Card Copier.desktop" metadata::trusted true 2>/dev/null || true
elif command -v piclone >/dev/null 2>&1; then
    write_icon "SD Card Copier.desktop" \
        "[Desktop Entry]" "Type=Application" "Name=SD Card Copier" \
        "Comment=Copy this SD card to another card" \
        "Exec=sudo piclone" \
        "Icon=drive-removable-media" "Terminal=false" "Categories=System;"
fi

ls -1 "${DESKTOP_DIR}"/*.desktop 2>/dev/null | wc -l | xargs -I{} echo "Desktop icons installed: {}"

# Say why an icon is missing rather than leaving it a mystery — every one of
# these is skipped silently when its tool is absent.
for MISSING in \
    "${QMED_DIR}/kiosk_off.sh|QMed Exit Kiosk|re-run setup.sh, or curl it from the server" \
    "${QMED_DIR}/wifi_setup.sh|QMed Wi-Fi|re-run setup.sh, or curl it from the server"
do
    IFS='|' read -r M_PATH M_NAME M_FIX <<< "$MISSING"
    [ -f "$M_PATH" ] || echo "  (no '${M_NAME}' icon: ${M_PATH##*/} is not installed — ${M_FIX})"
done

if ! command -v nm-connection-editor >/dev/null 2>&1 \
    && [ ! -f /usr/share/applications/nm-connection-editor.desktop ]; then
    echo "  (no 'Network Connections' icon: install it with"
    echo "     sudo apt-get install -y network-manager-gnome"
    echo "   then re-run this script)"
fi
