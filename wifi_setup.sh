#!/bin/bash
# Network tools for a kiosk Pi.
#
#   wifi_setup.sh            scan and join a Wi-Fi network (numbered list)
#   wifi_setup.sh --editor   open nm-connection-editor (static IP, profiles)
#
# BOTH modes stop the kiosk first and start it again when you are done. A
# queue screen runs fullscreen and always-on-top, so anything launched under
# it opens invisibly behind — which looks exactly like the app failing to
# start. Pausing is not optional for these tools, it is what makes them work.
#
# Pick from a NUMBERED LIST rather than typing the SSID, and see the password
# as you type it: getting "KPJ-Guest_5G" right on a Pi keyboard — often with a
# layout that swaps " and @ — is where most failed setups came from.
#
# Installed to ~/.qmed/wifi_setup.sh by setup.sh.

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'
BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

QMED_DIR="$HOME/.qmed"
PAUSE_FILE="/tmp/qmed-kiosk-paused"
MODE="picker"
[ "${1:-}" = "--editor" ] && MODE="editor"

# ── Kiosk pause / resume ─────────────────────────────────────────────
# Same marker format kiosk_off.sh writes and net_watchdog.sh reads:
# "<expiry-epoch> <boot-id>". Without the marker the watchdog would put the
# queue screen back over the top of this within a minute.
pause_kiosk() {
    local BOOT_ID
    BOOT_ID=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo unknown)
    printf '%s %s\n' "$(( $(date +%s) + 3600 ))" "$BOOT_ID" > "$PAUSE_FILE" 2>/dev/null || true
    pkill -f "${QMED_DIR}/kiosk.sh" 2>/dev/null || true
    sleep 1
    pkill -f -- '--kiosk' 2>/dev/null || true
    pkill -x unclutter 2>/dev/null || true      # give the mouse pointer back
}

# Runs from a trap, so the screen comes back even if the window is closed
# with the X, the terminal is killed, or the script errors out.
resume_kiosk() {
    rm -f "$PAUSE_FILE" 2>/dev/null || true
    if [ -f "${QMED_DIR}/kiosk.sh" ] && ! pgrep -f "${QMED_DIR}/kiosk.sh" >/dev/null 2>&1; then
        DISPLAY="${DISPLAY:-:0}" nohup bash "${QMED_DIR}/kiosk.sh" >/dev/null 2>&1 &
    fi
}

# ── Editor mode ──────────────────────────────────────────────────────
if [ "$MODE" = "editor" ]; then
    export DISPLAY="${DISPLAY:-:0}"
    if ! command -v nm-connection-editor >/dev/null 2>&1; then
        echo "nm-connection-editor is not installed."
        echo "    sudo apt-get install -y network-manager-gnome"
        exit 1
    fi
    pause_kiosk
    trap resume_kiosk EXIT
    # Blocking on purpose: the queue screen stays down for exactly as long as
    # the window is open.
    nm-connection-editor
    exit 0
fi

# ── Picker mode ──────────────────────────────────────────────────────
# Launched from a desktop icon? Re-run inside a terminal so there is
# somewhere to read the list and type. Pausing happens in the child.
if [ ! -t 0 ] || [ ! -t 1 ]; then
    for TERM_BIN in lxterminal x-terminal-emulator xfce4-terminal xterm; do
        if command -v "$TERM_BIN" >/dev/null 2>&1; then
            exec "$TERM_BIN" -e "bash '$0'"
        fi
    done
fi

if ! command -v nmcli >/dev/null 2>&1; then
    echo "NetworkManager (nmcli) is not installed — cannot manage Wi-Fi."
    read -p "Press Enter to close..." _
    exit 1
fi

pause_kiosk
trap resume_kiosk EXIT

echo -e "${CYAN}${BOLD}QMed — Connect to Wi-Fi${NC}"
echo -e "${DIM}Queue screen paused; it restarts when you close this window.${NC}"
echo ""

CURRENT_SSID=$(nmcli -t -f active,ssid dev wifi 2>/dev/null | awk -F: '$1=="yes"{print $2; exit}')
if [ -n "$CURRENT_SSID" ]; then
    echo -e "  Currently connected to ${BOLD}${CURRENT_SSID}${NC}  ${DIM}(IP $(hostname -I | awk '{print $1}'))${NC}"
    echo ""
fi

sudo nmcli radio wifi on >/dev/null 2>&1 || true
echo -e "  ${DIM}Scanning...${NC}"

# SIGNAL first so a numeric sort works; SSID last because it is the field most
# likely to contain a colon.
mapfile -t ROWS < <(sudo nmcli -t -f SIGNAL,SECURITY,SSID dev wifi list --rescan yes 2>/dev/null \
    | awk -F: 'NF>=3 && $3!="" && !seen[$3]++ {sec=$2; if(sec=="")sec="open"; print $1"|"sec"|"$3}' \
    | sort -t'|' -k1 -rn | head -20)

if [ ${#ROWS[@]} -eq 0 ]; then
    echo -e "  ${YELLOW}No networks found.${NC}"
    read -p "  Press Enter to close..." _
    exit 1
fi

echo ""
for i in "${!ROWS[@]}"; do
    IFS='|' read -r SIG SEC NAME <<< "${ROWS[$i]}"
    printf "    %2d) %-30s %3s%%  %s\n" "$((i+1))" "$NAME" "$SIG" "$SEC"
done
echo "     0) Enter a name manually (hidden network)"
echo "     q) Quit"
echo ""

SSID=""
while [ -z "$SSID" ]; do
    read -p "  Select network [0-${#ROWS[@]}]: " PICK
    case "$PICK" in
        q|Q) exit 0 ;;
        0)   read -p "  Network name (SSID): " SSID ;;
        *)
            if [ "$PICK" -ge 1 ] 2>/dev/null && [ "$PICK" -le ${#ROWS[@]} ] 2>/dev/null; then
                IFS='|' read -r _ _ SSID <<< "${ROWS[$((PICK-1))]}"
            else
                echo -e "  ${YELLOW}Enter a number from the list.${NC}"
            fi
            ;;
    esac
done
echo -e "  ${GREEN}Selected:${NC} ${BOLD}${SSID}${NC}"

# Password shown as typed, ON PURPOSE — see the header.
PASS=""
while true; do
    echo -e "  ${DIM}(the password is shown as you type, so you can check it)${NC}"
    read -r -p "  Password (blank for an open network): " PASS
    [ -z "$PASS" ] && break
    echo -e "  You typed: ${BOLD}${PASS}${NC}  ${DIM}(${#PASS} characters)${NC}"
    read -p "  Correct? (Y/n): " OK
    [[ ! "$OK" =~ ^[Nn]$ ]] && break
done

echo ""
echo -e "  ${DIM}Connecting to ${SSID}...${NC}"
if [ -n "$PASS" ]; then
    sudo nmcli dev wifi connect "$SSID" password "$PASS" >/dev/null 2>&1 || true
else
    sudo nmcli dev wifi connect "$SSID" >/dev/null 2>&1 || true
fi
sleep 3

NOW_SSID=$(nmcli -t -f active,ssid dev wifi 2>/dev/null | awk -F: '$1=="yes"{print $2; exit}')
if [ "$NOW_SSID" = "$SSID" ]; then
    # Match what setup.sh does: auto-reconnect, high priority, power save off.
    sudo nmcli connection modify "$SSID" \
        connection.autoconnect yes connection.autoconnect-priority 100 wifi.powersave 2 >/dev/null 2>&1 || true
    echo -e "  ${GREEN}✓ Connected: ${SSID}  (IP $(hostname -I | awk '{print $1}'))${NC}"
    echo -e "  ${DIM}Saved to reconnect automatically after a reboot or outage.${NC}"
else
    echo -e "  ${YELLOW}✗ Could not connect to ${SSID}.${NC}"
    echo -e "  ${DIM}Usually a wrong password. Run this again and check it as you type.${NC}"
fi

echo ""
echo -e "  ${DIM}Closing this window restarts the queue screen.${NC}"
read -p "  Press Enter to close..." _
