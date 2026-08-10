#!/bin/bash
# Join a Wi-Fi network on a kiosk Pi.
#
# The tray applet lives on the taskbar, and a queue screen deliberately has no
# taskbar, so there is otherwise no way in. Reachable from the "QMed Wi-Fi"
# desktop icon, or over SSH.
#
# Same interaction as Step 0 of setup.sh, on purpose: pick the network from a
# NUMBERED LIST rather than typing it, and see the password as you type it.
# Typing "KPJ-Guest_5G" exactly right on a Pi keyboard — often with a layout
# that swaps " and @ — is where most failed setups came from.
#
# For static IPs, Ethernet or editing saved profiles, use the separate
# "Network Connections" icon (nm-connection-editor).
#
# Installed to ~/.qmed/wifi_setup.sh by setup.sh.

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'
BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

# Launched from a desktop icon? Re-run inside a terminal so there is somewhere
# to read the list and type.
if [ ! -t 0 ] || [ ! -t 1 ]; then
    for TERM_BIN in lxterminal x-terminal-emulator xfce4-terminal xterm; do
        if command -v "$TERM_BIN" >/dev/null 2>&1; then
            exec "$TERM_BIN" -e "bash '$0' --in-terminal"
        fi
    done
fi

if ! command -v nmcli >/dev/null 2>&1; then
    echo "NetworkManager (nmcli) is not installed — cannot manage Wi-Fi."
    read -p "Press Enter to close..." _
    exit 1
fi

echo -e "${CYAN}${BOLD}QMed — Connect to Wi-Fi${NC}"
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
read -p "  Press Enter to close..." _
