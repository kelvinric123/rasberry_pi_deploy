#!/bin/bash
# Skip the queue-screen autostart on the NEXT restart — one boot only.
#
# After running this and rebooting, the Pi comes up as a normal desktop:
# taskbar, icons, mouse — nothing to restore, because the kiosk never ran to
# hide them. The skip is consumed by that one boot, so:
#
#   * restart AGAIN            -> queue screen is back automatically
#   * or click "QMed Queue Screen" on the desktop -> back immediately
#
# Implementation: this writes the CURRENT boot id into ~/.qmed/skip_next_boot.
# kiosk.sh reads it at launch — a DIFFERENT boot id means "this is the first
# boot after the request", so it consumes the file and refuses to run for
# that boot. The current session is not touched (use QMed Exit Kiosk for
# that); this is about the next restart, as the name says.
#
# Installed to ~/.qmed/pause_autostart.sh; also the "QMed Pause Autostart"
# desktop icon.

QMED_DIR="$HOME/.qmed"
SKIP_FILE="${QMED_DIR}/skip_next_boot"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

mkdir -p "$QMED_DIR"
BOOT_ID=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo unknown)

# Run again while a skip is pending = the natural way to cancel it.
if [ -f "$SKIP_FILE" ]; then
    echo -e "${YELLOW}A skip is already scheduled:${NC} the next restart will boot to the desktop."
    read -p "Cancel it, so the next restart boots the queue screen as normal? (y/N): " ANSWER
    if [[ "$ANSWER" =~ ^[Yy]$ ]]; then
        rm -f "$SKIP_FILE"
        echo -e "${GREEN}Cancelled.${NC} Next restart boots the queue screen."
    else
        echo -e "${DIM}Left as scheduled.${NC}"
    fi
    exit 0
fi

echo "$BOOT_ID" > "$SKIP_FILE" || { echo "Could not write ${SKIP_FILE}"; exit 1; }

echo -e "${GREEN}Scheduled.${NC} The ${BOLD}next restart${NC} boots to a normal desktop — taskbar, icons, mouse."
echo ""
echo "To get the queue screen back afterwards, either:"
echo "  - restart again, or"
echo "  - click 'QMed Queue Screen' on the desktop"
echo ""
echo -e "${DIM}(The queue screen keeps running until you restart. Run this script"
echo -e "again to cancel the skip.)${NC}"
echo ""
read -p "Restart now? (y/N): " DO_REBOOT
if [[ "$DO_REBOOT" =~ ^[Yy]$ ]]; then
    sudo reboot
fi
