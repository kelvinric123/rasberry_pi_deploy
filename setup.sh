#!/bin/bash
#
# QMed Raspberry Pi Queue Screen - Setup
# ========================================
# Interactive setup script that registers this Raspberry Pi as a queue screen
# device on your QMed server.
#
# Prerequisites: Run install.sh first
# Usage:  bash setup.sh
#

set -e

# ── Color helpers ─────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

if [ "$(id -u)" -eq 0 ]; then
    echo -e "${RED}✗ Please DO NOT run this script with sudo or as root.${NC}"
    echo "  Run it as your normal user instead: bash setup.sh"
    exit 1
fi

QMED_DIR="$HOME/.qmed"
mkdir -p "$QMED_DIR"
CONFIG_FILE="${QMED_DIR}/config.json"

echo -e "${CYAN}${BOLD}"
echo "╔══════════════════════════════════════════════════╗"
echo "║     QMed Queue Screen - Device Setup            ║"
echo "╚══════════════════════════════════════════════════╝"
echo -e "${NC}"

# ── Get the kiosk out of the way, until the next restart ─────────────
# Setup is interactive, and a fullscreen queue screen sits on top of the very
# terminal you are answering questions in. Killing it is not enough on its
# own — net_watchdog.sh puts it back within a minute — so leave a pause
# marker as well.
#
# The marker is "<expiry-epoch> <boot-id>", the same format kiosk_off.sh
# writes and net_watchdog.sh reads. The boot id is what makes this last
# exactly "until restart": after a reboot it cannot match, so the pause is
# void and the queue screen comes straight back. The 12-hour expiry is a
# second safety net for a setup that was abandoned half way.
PAUSE_FILE="/tmp/qmed-kiosk-paused"
BOOT_ID=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo unknown)
printf '%s %s\n' "$(( $(date +%s) + 43200 ))" "$BOOT_ID" > "$PAUSE_FILE" 2>/dev/null || true

export DISPLAY="${DISPLAY:-:0}"
pkill -f "${QMED_DIR}/kiosk.sh" 2>/dev/null || true
sleep 1
pkill -f -- '--kiosk' 2>/dev/null || true
pkill -x unclutter 2>/dev/null || true          # give the mouse pointer back

echo -e "${DIM}Queue screen paused for setup — it returns on the next reboot.${NC}"
echo ""

# ── Check if already configured ──────────────────────────────────────
if [ -f "$CONFIG_FILE" ]; then
    echo -e "${YELLOW}⚠  This device is already configured.${NC}"
    EXISTING_NAME=$(jq -r '.device_name' "$CONFIG_FILE" 2>/dev/null || echo "Unknown")
    EXISTING_SERVER=$(jq -r '.server_url' "$CONFIG_FILE" 2>/dev/null || echo "Unknown")
    echo -e "   Device: ${BOLD}${EXISTING_NAME}${NC}"
    echo -e "   Server: ${BOLD}${EXISTING_SERVER}${NC}"
    echo ""
    read -p "Do you want to reconfigure? (y/N): " RECONFIG
    if [[ ! "$RECONFIG" =~ ^[Yy]$ ]]; then
        echo -e "${DIM}Setup cancelled.${NC}"
        exit 0
    fi
    echo ""
fi

# ── Check dependencies ───────────────────────────────────────────────
if ! command -v jq &> /dev/null; then
    echo -e "${RED}✗ jq is not installed. Run install.sh first.${NC}"
    exit 1
fi
if ! command -v curl &> /dev/null; then
    echo -e "${RED}✗ curl is not installed. Run install.sh first.${NC}"
    exit 1
fi

# ── Step 0a: Keyboard layout ─────────────────────────────────────────
# Done BEFORE anything asks you to type. Raspberry Pi OS defaults to the GB
# layout; on a US keyboard that swaps " and @ (and moves # and \), which is
# maddening when the next thing you must enter is a Wi-Fi password.
echo -e "${CYAN}${BOLD}Step 0a: Keyboard Layout${NC}"

CURRENT_KB=$(sed -n 's/^XKBLAYOUT="\?\([^"]*\)"\?/\1/p' /etc/default/keyboard 2>/dev/null | head -1)
echo -e "  Current layout: ${BOLD}${CURRENT_KB:-unknown}${NC}"
echo -e "  ${DIM}Type a double quote and an at sign to test:  \"  @${NC}"
echo -e "  ${DIM}If they come out swapped, the layout does not match your keyboard.${NC}"
echo ""
read -p "  Layout — [u]s, [g]b, or Enter to keep: " KB_CHOICE

NEW_KB=""
case "$KB_CHOICE" in
    u|U|us|US) NEW_KB="us" ;;
    g|G|gb|GB|uk|UK) NEW_KB="gb" ;;
esac

if [ -n "$NEW_KB" ]; then
    if [ -f /etc/default/keyboard ]; then
        sudo sed -i "s/^XKBLAYOUT=.*/XKBLAYOUT=\"${NEW_KB}\"/" /etc/default/keyboard
        # Console + X, applied now rather than at the next boot — the rest of
        # this script is one long typing exercise.
        sudo setupcon --save >/dev/null 2>&1 || true
        sudo dpkg-reconfigure -f noninteractive keyboard-configuration >/dev/null 2>&1 || true
        DISPLAY="${DISPLAY:-:0}" setxkbmap "$NEW_KB" >/dev/null 2>&1 || true
        echo -e "  ${GREEN}✓ Keyboard set to ${NEW_KB} (active now)${NC}"
        echo -e "  ${DIM}Test again:  \"  @${NC}"
    else
        echo -e "  ${YELLOW}⚠ /etc/default/keyboard not found — skipped${NC}"
    fi
else
    echo -e "  ${DIM}Keeping ${CURRENT_KB:-current} layout${NC}"
fi
echo ""

# ── Step 0: Network Setup ────────────────────────────────────────────
# A queue screen must stay online. Make sure Wi-Fi is connected and saved
# so it auto-reconnects across reboots and outages.
echo -e "${CYAN}${BOLD}Step 0: Network Setup${NC}"

WIFI_SSID=""

if ! command -v nmcli &> /dev/null; then
    echo -e "  ${YELLOW}⚠ NetworkManager (nmcli) not found — skipping Wi-Fi setup.${NC}"
    echo -e "  ${YELLOW}  Ensure this device is connected (e.g. Ethernet) before continuing.${NC}"
    echo ""
else
    sudo nmcli radio wifi on >/dev/null 2>&1 || true

    CURRENT_SSID=$(nmcli -t -f active,ssid dev wifi 2>/dev/null | awk -F: '$1=="yes"{print $2; exit}')
    CURRENT_IP=$(hostname -I | awk '{print $1}')
    CONFIGURE_WIFI="no"

    if [ -n "$CURRENT_SSID" ]; then
        echo -e "  ${GREEN}✓ Already connected to Wi-Fi:${NC} ${BOLD}${CURRENT_SSID}${NC}  ${DIM}(IP ${CURRENT_IP:-unknown})${NC}"
        echo ""
        read -p "  Keep this network? (Y/n): " KEEP_WIFI
        if [[ "$KEEP_WIFI" =~ ^[Nn]$ ]]; then
            CONFIGURE_WIFI="yes"
        else
            WIFI_SSID="$CURRENT_SSID"
            ACTIVE_CON=$(nmcli -t -f NAME,DEVICE connection show --active 2>/dev/null | awk -F: '$2 ~ /^wl/ {print $1; exit}')
            if [ -n "$ACTIVE_CON" ]; then
                sudo nmcli connection modify "$ACTIVE_CON" connection.autoconnect yes connection.autoconnect-priority 100 >/dev/null 2>&1 || true
            fi
            echo -e "  ${GREEN}✓ Keeping ${CURRENT_SSID} (set to auto-reconnect)${NC}"
        fi
    else
        echo -e "  ${YELLOW}Not connected to Wi-Fi.${NC}"
        read -p "  Configure Wi-Fi now? (Y/n): " DO_WIFI
        if [[ ! "$DO_WIFI" =~ ^[Nn]$ ]]; then
            CONFIGURE_WIFI="yes"
        fi
    fi

    if [ "$CONFIGURE_WIFI" = "yes" ]; then
        echo -e "  ${DIM}Scanning for networks...${NC}"

        # Pick from a numbered list instead of typing the SSID. Getting a name
        # like "KPJ-Guest_5G" exactly right on a Pi keyboard is where most of
        # the failed setups came from.
        #
        # SIGNAL first so a plain numeric sort works, SSID last because it is
        # the field most likely to contain a colon.
        mapfile -t WIFI_ROWS < <(sudo nmcli -t -f SIGNAL,SECURITY,SSID dev wifi list --rescan yes 2>/dev/null \
            | awk -F: 'NF>=3 && $3!="" && !seen[$3]++ {sec=$2; if(sec=="")sec="open"; print $1"|"sec"|"$3}' \
            | sort -t'|' -k1 -rn | head -20)

        if [ ${#WIFI_ROWS[@]} -eq 0 ]; then
            echo -e "  ${YELLOW}No networks found. Check the Wi-Fi antenna or move closer.${NC}"
        fi

        echo ""
        for i in "${!WIFI_ROWS[@]}"; do
            IFS='|' read -r W_SIG W_SEC W_NAME <<< "${WIFI_ROWS[$i]}"
            printf "    %2d) %-30s %3s%%  %s\n" "$((i+1))" "$W_NAME" "$W_SIG" "$W_SEC"
        done
        echo "     0) Enter a name manually (hidden network)"
        echo ""

        WIFI_SSID=""
        while [ -z "$WIFI_SSID" ]; do
            read -p "  Select network [0-${#WIFI_ROWS[@]}]: " WIFI_PICK
            if [ "$WIFI_PICK" = "0" ]; then
                read -p "  Network name (SSID): " WIFI_SSID
            elif [ "$WIFI_PICK" -ge 1 ] 2>/dev/null && [ "$WIFI_PICK" -le ${#WIFI_ROWS[@]} ] 2>/dev/null; then
                IFS='|' read -r _ _ WIFI_SSID <<< "${WIFI_ROWS[$((WIFI_PICK-1))]}"
            else
                echo -e "  ${YELLOW}Enter a number from the list.${NC}"
            fi
        done
        echo -e "  ${GREEN}Selected:${NC} ${BOLD}${WIFI_SSID}${NC}"

        # Password shown as it is typed, ON PURPOSE. A hidden field plus a
        # possibly-mismatched keyboard layout means a wrong character is only
        # discovered when the connection fails, with nothing to look at.
        WIFI_PASS=""
        while true; do
            echo -e "  ${DIM}(the password is shown as you type, so you can check it)${NC}"
            read -r -p "  Password (blank for an open network): " WIFI_PASS
            if [ -z "$WIFI_PASS" ]; then
                break
            fi
            echo -e "  You typed: ${BOLD}${WIFI_PASS}${NC}  ${DIM}(${#WIFI_PASS} characters)${NC}"
            read -p "  Correct? (Y/n): " PASS_OK
            [[ ! "$PASS_OK" =~ ^[Nn]$ ]] && break
        done
        echo ""

        echo -e "  ${DIM}Connecting to ${WIFI_SSID}...${NC}"
        if [ -n "$WIFI_PASS" ]; then
            sudo nmcli dev wifi connect "$WIFI_SSID" password "$WIFI_PASS" >/dev/null 2>&1 || true
        else
            sudo nmcli dev wifi connect "$WIFI_SSID" >/dev/null 2>&1 || true
        fi
        sleep 3

        CURRENT_SSID=$(nmcli -t -f active,ssid dev wifi 2>/dev/null | awk -F: '$1=="yes"{print $2; exit}')
        if [ "$CURRENT_SSID" = "$WIFI_SSID" ]; then
            sudo nmcli connection modify "$WIFI_SSID" connection.autoconnect yes connection.autoconnect-priority 100 >/dev/null 2>&1 || true
            CURRENT_IP=$(hostname -I | awk '{print $1}')
            echo -e "  ${GREEN}✓ Connected & saved: ${WIFI_SSID} (IP ${CURRENT_IP})${NC}"
        else
            echo -e "  ${RED}✗ Could not connect to ${WIFI_SSID}. Check the name/password.${NC}"
            echo -e "  ${YELLOW}  You can re-run setup.sh to try again once connected.${NC}"
        fi
    fi

    # ── Optional static IP ───────────────────────────────────────────
    echo ""
    read -p "  Use a STATIC IP for this device? (y/N): " DO_STATIC
    if [[ "$DO_STATIC" =~ ^[Yy]$ ]]; then
        TARGET_CON=$(nmcli -t -f NAME,DEVICE connection show --active 2>/dev/null | awk -F: '$2 ~ /^(wl|eth|en)/ {print $1; exit}')
        GW_DEFAULT=$(ip route show default 2>/dev/null | awk '/default/{print $3; exit}')
        echo -e "  ${DIM}Connection to configure: ${TARGET_CON:-unknown}${NC}"
        read -p "  IP address with CIDR (e.g. 192.168.0.50/24): " STATIC_IP
        read -p "  Gateway [${GW_DEFAULT}]: " STATIC_GW
        STATIC_GW="${STATIC_GW:-$GW_DEFAULT}"
        read -p "  DNS server [1.1.1.1]: " STATIC_DNS
        STATIC_DNS="${STATIC_DNS:-1.1.1.1}"

        if [ -n "$TARGET_CON" ] && [ -n "$STATIC_IP" ]; then
            sudo nmcli connection modify "$TARGET_CON" \
                ipv4.method manual \
                ipv4.addresses "$STATIC_IP" \
                ipv4.gateway "$STATIC_GW" \
                ipv4.dns "$STATIC_DNS" >/dev/null 2>&1 || true
            sudo nmcli connection up "$TARGET_CON" >/dev/null 2>&1 || true
            sleep 2
            CURRENT_IP=$(hostname -I | awk '{print $1}')
            echo -e "  ${GREEN}✓ Static IP applied (device is now ${CURRENT_IP})${NC}"
        else
            echo -e "  ${YELLOW}  ⚠ Skipped static IP (missing connection or address).${NC}"
        fi
    fi
    echo ""
fi

# ── Step 1: Server URL ───────────────────────────────────────────────
echo -e "${CYAN}${BOLD}Step 1: Server Connection${NC}"
echo -e "${DIM}Enter the URL of your QMed server (e.g. https://qmed.hospital.com)${NC}"
echo ""
while true; do
    read -p "  Server URL [https://v2.qmed.asia]: " SERVER_URL
    
    # Use default if empty
    SERVER_URL="${SERVER_URL:-https://v2.qmed.asia}"

    # Remove trailing slash
    SERVER_URL="${SERVER_URL%/}"

    if [ -z "$SERVER_URL" ]; then
        echo -e "  ${RED}URL cannot be empty.${NC}"
        continue
    fi

    # Test connection
    echo -e "  ${DIM}Testing connection...${NC}"
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "${SERVER_URL}/api/open/hospitals" 2>/dev/null || echo "000")

    if [ "$HTTP_CODE" = "200" ]; then
        echo -e "  ${GREEN}✓ Connected to server${NC}"
        break
    else
        echo -e "  ${RED}✗ Cannot reach server (HTTP ${HTTP_CODE}). Check the URL and try again.${NC}"
    fi
done
echo ""

# ── Step 2: Select Hospital ──────────────────────────────────────────
echo -e "${CYAN}${BOLD}Step 2: Select Hospital${NC}"
echo -e "${DIM}Fetching hospitals from server...${NC}"
echo ""

HOSPITALS_JSON=$(curl -s --max-time 10 "${SERVER_URL}/api/open/hospitals")
HOSPITAL_COUNT=$(echo "$HOSPITALS_JSON" | jq '.data | length')

if [ "$HOSPITAL_COUNT" = "0" ] || [ -z "$HOSPITAL_COUNT" ]; then
    echo -e "${RED}✗ No hospitals found on this server.${NC}"
    exit 1
fi

echo -e "  Available hospitals:"
echo -e "  ${DIM}─────────────────────────────────────${NC}"

for i in $(seq 0 $((HOSPITAL_COUNT - 1))); do
    NAME=$(echo "$HOSPITALS_JSON" | jq -r ".data[$i].name")
    ID=$(echo "$HOSPITALS_JSON" | jq -r ".data[$i].id")
    echo -e "  ${BOLD}$((i + 1)).${NC} ${NAME} ${DIM}(ID: ${ID})${NC}"
done

echo ""
while true; do
    read -p "  Select hospital [1-${HOSPITAL_COUNT}]: " HOSPITAL_CHOICE

    if [[ "$HOSPITAL_CHOICE" =~ ^[0-9]+$ ]] && [ "$HOSPITAL_CHOICE" -ge 1 ] && [ "$HOSPITAL_CHOICE" -le "$HOSPITAL_COUNT" ]; then
        HOSPITAL_INDEX=$((HOSPITAL_CHOICE - 1))
        HOSPITAL_ID=$(echo "$HOSPITALS_JSON" | jq -r ".data[$HOSPITAL_INDEX].id")
        HOSPITAL_NAME=$(echo "$HOSPITALS_JSON" | jq -r ".data[$HOSPITAL_INDEX].name")
        echo -e "  ${GREEN}✓ Selected: ${HOSPITAL_NAME}${NC}"
        break
    else
        echo -e "  ${RED}Invalid choice. Enter a number between 1 and ${HOSPITAL_COUNT}.${NC}"
    fi
done
echo ""

# ── Step 3: Select Queue Screen ──────────────────────────────────────
echo -e "${CYAN}${BOLD}Step 3: Select Queue Screen${NC}"
echo -e "${DIM}Fetching queue screens for ${HOSPITAL_NAME}...${NC}"
echo ""

SCREENS_JSON=$(curl -s --max-time 10 "${SERVER_URL}/api/open/queue-screens?hospital_id=${HOSPITAL_ID}")
SCREEN_COUNT=$(echo "$SCREENS_JSON" | jq '.data | length')

if [ "$SCREEN_COUNT" = "0" ] || [ -z "$SCREEN_COUNT" ]; then
    echo -e "${RED}✗ No queue screens found for this hospital.${NC}"
    echo -e "${YELLOW}  Please create a queue screen in the admin dashboard first.${NC}"
    exit 1
fi

echo -e "  Available queue screens:"
echo -e "  ${DIM}─────────────────────────────────────${NC}"

for i in $(seq 0 $((SCREEN_COUNT - 1))); do
    NAME=$(echo "$SCREENS_JSON" | jq -r ".data[$i].name")
    ID=$(echo "$SCREENS_JSON" | jq -r ".data[$i].id")
    LOCATIONS=$(echo "$SCREENS_JSON" | jq -r ".data[$i].service_locations // [] | map(.name) | join(\", \")")
    STATUS=$(echo "$SCREENS_JSON" | jq -r ".data[$i].is_active")

    if [ "$STATUS" = "true" ]; then
        STATUS_BADGE="${GREEN}Active${NC}"
    else
        STATUS_BADGE="${RED}Inactive${NC}"
    fi

    echo -e "  ${BOLD}$((i + 1)).${NC} ${NAME} [${STATUS_BADGE}]"
    if [ -n "$LOCATIONS" ] && [ "$LOCATIONS" != "" ]; then
        echo -e "     ${DIM}→ Locations: ${LOCATIONS}${NC}"
    fi
done

echo ""
while true; do
    read -p "  Select queue screen [1-${SCREEN_COUNT}]: " SCREEN_CHOICE

    if [[ "$SCREEN_CHOICE" =~ ^[0-9]+$ ]] && [ "$SCREEN_CHOICE" -ge 1 ] && [ "$SCREEN_CHOICE" -le "$SCREEN_COUNT" ]; then
        SCREEN_INDEX=$((SCREEN_CHOICE - 1))
        QUEUE_SCREEN_ID=$(echo "$SCREENS_JSON" | jq -r ".data[$SCREEN_INDEX].id")
        QUEUE_SCREEN_NAME=$(echo "$SCREENS_JSON" | jq -r ".data[$SCREEN_INDEX].name")
        echo -e "  ${GREEN}✓ Selected: ${QUEUE_SCREEN_NAME}${NC}"
        break
    else
        echo -e "  ${RED}Invalid choice. Enter a number between 1 and ${SCREEN_COUNT}.${NC}"
    fi
done
echo ""

# ── Step 4: Device Name ──────────────────────────────────────────────
# Assigned by the SERVER at registration as "{queue screen name} {number}"
# (e.g. "Suite 7O4 1", "Suite 7O4 2"), so every device is recognizable on the
# admin page without anyone typing a name here. It can be renamed later from
# the admin portal (Raspberry Pi page → pencil icon).
echo -e "${CYAN}${BOLD}Step 4: Device Name${NC}"
DEVICE_NAME=$(hostname)   # fallback only, used if the server predates auto-naming
echo -e "  ${DIM}The server will assign a name automatically: ${QUEUE_SCREEN_NAME} 1, ${QUEUE_SCREEN_NAME} 2, ...${NC}"
echo ""

# ── Step 5: Video Playback Mode ──────────────────────────────────────
echo -e "${CYAN}${BOLD}Step 5: Video Playback Mode${NC}"
echo -e "${DIM}Choose how CMS videos should be played on this device:${NC}"
echo ""
echo -e "  ${BOLD}1.${NC} ${GREEN}Fully Cloud${NC}"
echo -e "     ${DIM}All videos stream from the server. Requires stable internet.${NC}"
echo -e "     ${DIM}YouTube and uploaded videos both play from the web.${NC}"
echo ""
echo -e "  ${BOLD}2.${NC} ${CYAN}Local + Cloud Hybrid${NC} (Recommended)"
echo -e "     ${DIM}Uploaded videos are downloaded and served locally on this Pi.${NC}"
echo -e "     ${DIM}YouTube videos still play from the web as usual.${NC}"
echo -e "     ${DIM}Reduces bandwidth usage and improves reliability.${NC}"
echo ""

while true; do
    read -p "  Select video mode [1-2]: " VIDEO_CHOICE

    case "$VIDEO_CHOICE" in
        1)
            VIDEO_MODE="cloud"
            echo -e "  ${GREEN}✓ Video mode: Fully Cloud${NC}"
            break
            ;;
        2)
            VIDEO_MODE="local_hybrid"
            echo -e "  ${GREEN}✓ Video mode: Local + Cloud Hybrid${NC}"
            break
            ;;
        *)
            echo -e "  ${RED}Invalid choice. Enter 1 or 2.${NC}"
            ;;
    esac
done
echo ""

# ── Step 6: Register Device ──────────────────────────────────────────
echo -e "${CYAN}${BOLD}Step 6: Registering Device${NC}"
echo -e "${DIM}Sending registration to server...${NC}"

# Gather system info
IP_ADDR=$(hostname -I | awk '{print $1}')
MAC_ADDR=$(cat /sys/class/net/$(ip route show default | awk '/default/ {print $5}' | head -1)/address 2>/dev/null || echo "unknown")
HOSTNAME=$(hostname)
OS_INFO=$(cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d= -f2 | tr -d '"' || echo "Raspbian")
SCREEN_RES=$(xdpyinfo 2>/dev/null | grep dimensions | awk '{print $2}' || echo "unknown")

# If this Pi was registered before, send its existing token so the server
# UPDATES that device row (new name/screen) instead of creating a duplicate.
# Without this, every re-run of setup.sh left a stale "Online"-looking row
# behind on the admin page (the old heartbeat cron kept it alive).
#
# CLONE DETECTION: SD cards are provisioned by cloning a master card, so the
# copied config.json carries the MASTER's device_token — re-using it here
# would hijack the master's registration, and two Pis sharing one token
# means one of them silently loses audio announcements. The config stores
# the MAC of the Pi it was set up on; if this hardware's MAC differs, this
# is a clone → drop the token and register as a brand-new device.
EXISTING_TOKEN=""
if [ -f "$CONFIG_FILE" ]; then
    EXISTING_TOKEN=$(jq -r '.device_token // empty' "$CONFIG_FILE" 2>/dev/null)
    STORED_MAC=$(jq -r '.mac_address // empty' "$CONFIG_FILE" 2>/dev/null)
    if [ -n "$EXISTING_TOKEN" ] && [ -n "$STORED_MAC" ] && [ "$STORED_MAC" != "unknown" ] \
        && [ -n "$MAC_ADDR" ] && [ "$MAC_ADDR" != "unknown" ] && [ "$STORED_MAC" != "$MAC_ADDR" ]; then
        echo -e "  ${YELLOW}⚠ Cloned SD card detected (config was created on ${STORED_MAC},${NC}"
        echo -e "  ${YELLOW}  this device is ${MAC_ADDR}) — registering as a NEW device.${NC}"
        EXISTING_TOKEN=""
    fi
fi

REGISTER_RESPONSE=$(curl -s -X POST "${SERVER_URL}/api/open/raspberry-pi/register" \
    -H "Content-Type: application/json" \
    -d "{
        \"device_name\": \"${DEVICE_NAME}\",
        \"hostname\": \"${HOSTNAME}\",
        \"ip_address\": \"${IP_ADDR}\",
        \"mac_address\": \"${MAC_ADDR}\",
        \"queue_screen_id\": ${QUEUE_SCREEN_ID},
        \"os_info\": \"${OS_INFO}\",
        \"screen_resolution\": \"${SCREEN_RES}\",
        \"existing_token\": \"${EXISTING_TOKEN}\"
    }")

# Check response
DEVICE_TOKEN=$(echo "$REGISTER_RESPONSE" | jq -r '.data.device_token // empty')
DEVICE_ID=$(echo "$REGISTER_RESPONSE" | jq -r '.data.device_id // empty')
SCREEN_URL=$(echo "$REGISTER_RESPONSE" | jq -r '.data.screen_url // empty')
# Adopt the server-assigned name ("{screen} {n}"); older servers omit it.
ASSIGNED_NAME=$(echo "$REGISTER_RESPONSE" | jq -r '.data.device_name // empty')
DEVICE_NAME="${ASSIGNED_NAME:-$DEVICE_NAME}"

if [ -z "$DEVICE_TOKEN" ]; then
    echo -e "${RED}✗ Registration failed!${NC}"
    echo -e "${RED}  Server response:${NC}"
    echo "$REGISTER_RESPONSE" | jq . 2>/dev/null || echo "$REGISTER_RESPONSE"
    exit 1
fi

echo -e "${GREEN}  ✓ Device registered as '${DEVICE_NAME}' (ID: ${DEVICE_ID})${NC}"
echo ""

# ── Step 7: Save Config ──────────────────────────────────────────────
echo -e "${CYAN}${BOLD}Step 7: Saving Configuration${NC}"

# For local_hybrid mode, append video_mode param to screen URL
if [ "$VIDEO_MODE" = "local_hybrid" ]; then
    # Add query param to tell the display page to use local video URLs
    if [[ "$SCREEN_URL" == *"?"* ]]; then
        FINAL_SCREEN_URL="${SCREEN_URL}&video_mode=local&video_port=8888"
    else
        FINAL_SCREEN_URL="${SCREEN_URL}?video_mode=local&video_port=8888"
    fi
else
    FINAL_SCREEN_URL="${SCREEN_URL}"
fi

LOCAL_VIDEO_PORT=8888

cat > "$CONFIG_FILE" << EOF
{
    "server_url": "${SERVER_URL}",
    "device_token": "${DEVICE_TOKEN}",
    "device_id": ${DEVICE_ID},
    "device_name": "${DEVICE_NAME}",
    "queue_screen_id": ${QUEUE_SCREEN_ID},
    "queue_screen_name": "${QUEUE_SCREEN_NAME}",
    "hospital_name": "${HOSPITAL_NAME}",
    "wifi_ssid": "${WIFI_SSID}",
    "screen_url": "${FINAL_SCREEN_URL}",
    "video_mode": "${VIDEO_MODE}",
    "local_video_port": ${LOCAL_VIDEO_PORT},
    "local_video_dir": "${QMED_DIR}/videos",
    "mac_address": "${MAC_ADDR}",
    "installed_at": "$(date -Iseconds)"
}
EOF

echo -e "${GREEN}  ✓ Config saved to ${CONFIG_FILE}${NC}"
echo ""

# ── Step 8: Install companion scripts ────────────────────────────────
# Prefer a local sibling file (folder was copied via scp). If it's not there
# (device installed via `curl install.sh + setup.sh`), download it from the
# server so both install methods end up fully featured.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

fetch_asset() {
    local name="$1"
    local dest="${QMED_DIR}/${name}"
    if [ -f "${SCRIPT_DIR}/${name}" ]; then
        cp "${SCRIPT_DIR}/${name}" "$dest"
    else
        echo -e "  ${DIM}Downloading ${name} from server...${NC}"
        if ! curl -fsSL "${SERVER_URL}/raspberry-pi/${name}" -o "$dest"; then
            echo -e "  ${YELLOW}⚠ Could not download ${name} (feature may be unavailable)${NC}"
            rm -f "$dest"
            return 1
        fi
    fi
    chmod +x "$dest" 2>/dev/null || true
    return 0
}

fetch_asset server.py || true
fetch_asset start_local_server.sh || true
# Self-updatable bundle: these used to be heredocs baked into this script;
# now they are versioned assets so the admin Update button can replace them.
fetch_asset heartbeat.sh || { echo -e "  ${RED}✗ Could not install heartbeat.sh${NC}"; exit 1; }
fetch_asset kiosk.sh || { echo -e "  ${RED}✗ Could not install kiosk.sh${NC}"; exit 1; }
fetch_asset net_watchdog.sh || true
fetch_asset self_update.sh || true

# Stamp the installed bundle version so heartbeats can report it and the
# admin page shows this device as up to date.
MANIFEST_VERSION=$(curl -fsSL --max-time 15 "${SERVER_URL}/raspberry-pi/manifest.json" 2>/dev/null | jq -r '.version // empty' 2>/dev/null)
if [ -n "$MANIFEST_VERSION" ] && [ "$MANIFEST_VERSION" != "none" ]; then
    echo "$MANIFEST_VERSION" > "${QMED_DIR}/scripts_version"
fi

if [ "$VIDEO_MODE" = "local_hybrid" ]; then
    echo -e "${CYAN}${BOLD}Step 8b: Setting Up Local Video Cache${NC}"

    mkdir -p "${QMED_DIR}/videos"

    fetch_asset video_sync.sh || true

    if [ -f "${QMED_DIR}/video_sync.sh" ]; then
        echo -e "${DIM}Downloading videos for offline playback...${NC}"
        bash "${QMED_DIR}/video_sync.sh"

        (crontab -l 2>/dev/null | grep -v "video_sync" || true) | crontab -
        (crontab -l 2>/dev/null || true; echo "*/30 * * * * ${QMED_DIR}/video_sync.sh") | crontab -
        echo -e "${GREEN}  ✓ Video sync cron job installed (every 30 minutes)${NC}"
    else
        echo -e "  ${YELLOW}⚠ video_sync.sh unavailable; skipping offline video cache${NC}"
    fi
    echo ""
else
    echo -e "${CYAN}${BOLD}Step 8b: Video Mode${NC}"
    echo -e "${GREEN}  ✓ Cloud mode - videos will stream from server${NC}"
    echo ""
fi

# ── Step 8c: Screen-saver scenery cache ──────────────────────────────
# Runs in BOTH video modes, unlike the video cache: the pack is only a few
# KB, and caching it means the "Screen Saver" media type keeps playing when
# the hospital network drops. Lands under videos/ so the local server on
# :8888 already serves it at /scenery/.
echo -e "${CYAN}${BOLD}Step 8c: Setting Up Screen Saver Scenery${NC}"

mkdir -p "${QMED_DIR}/videos/scenery"

fetch_asset scenery_sync.sh || true

if [ -f "${QMED_DIR}/scenery_sync.sh" ]; then
    echo -e "${DIM}Downloading scenery pack...${NC}"
    bash "${QMED_DIR}/scenery_sync.sh" || true

    (crontab -l 2>/dev/null | grep -v "scenery_sync" || true) | crontab -
    (crontab -l 2>/dev/null || true; echo "17 */6 * * * ${QMED_DIR}/scenery_sync.sh") | crontab -
    echo -e "${GREEN}  ✓ Scenery sync cron job installed (every 6 hours)${NC}"
else
    echo -e "  ${YELLOW}⚠ scenery_sync.sh unavailable; the screen saver will stream from the server${NC}"
fi
echo ""

# ── Step 9: Configure Autostart ──────────────────────────────────────
echo -e "${CYAN}${BOLD}Step 9: Configuring Kiosk Autostart${NC}"

# kiosk.sh is a versioned asset installed in Step 8 (fetch_asset) so the
# self-updater can replace it later. It is fully driven by ~/.qmed/config.json:
# always uses the latest URL, waits for the network before loading, and
# relaunches Chromium if it dies.
LAUNCH_SCRIPT="${QMED_DIR}/kiosk.sh"
if [ ! -f "$LAUNCH_SCRIPT" ]; then
    echo -e "${RED}✗ kiosk.sh missing (asset install failed). Cannot continue.${NC}"
    exit 1
fi
chmod +x "$LAUNCH_SCRIPT"

# Configure standard XDG autostart (works on all modern desktop managers)
XDG_AUTOSTART_DIR="$HOME/.config/autostart"
mkdir -p "$XDG_AUTOSTART_DIR"
cat > "${XDG_AUTOSTART_DIR}/qmed-kiosk.desktop" << EOF
[Desktop Entry]
Type=Application
Name=QMed Queue Screen
Exec=/bin/bash ${LAUNCH_SCRIPT}
X-GNOME-Autostart-enabled=true
StartupNotify=false
Terminal=false
EOF

# ── Desktop icons ────────────────────────────────────────────────────
# Written by a shared script so self_update.sh can refresh them on devices
# that are never re-provisioned. Passing SCRIPT_DIR lets it point the "QMed
# Setup" icon back at this folder.
# The icons are only written for tools that are actually present, so these
# have to be installed BEFORE desktop_shortcuts.sh runs.
fetch_asset kiosk_off.sh || true
fetch_asset wifi_setup.sh || true
fetch_asset pause_autostart.sh || true
fetch_asset desktop_shortcuts.sh || true
if [ -f "${QMED_DIR}/desktop_shortcuts.sh" ]; then
    bash "${QMED_DIR}/desktop_shortcuts.sh" "${SCRIPT_DIR}" | sed "s/^/  /"
else
    echo -e "  ${YELLOW}⚠ desktop_shortcuts.sh unavailable; icons not created${NC}"
fi

# Also keep the legacy LXDE-pi autostart for older systems.
# Deliberately NO @lxpanel here: the taskbar pops over the kiosk whenever the
# fullscreen window loses its top layer (native video overlay), and a queue
# screen never needs it.
AUTOSTART_DIR="$HOME/.config/lxsession/LXDE-pi"
mkdir -p "$AUTOSTART_DIR"
cat > "${AUTOSTART_DIR}/autostart" << EOF
@pcmanfm --desktop --profile LXDE-pi
@bash ${LAUNCH_SCRIPT}
EOF

# labwc (Wayland) autostart — Raspberry Pi OS Trixie's default compositor.
# Harmless on X11 sessions; only used when labwc is the active session.
LABWC_DIR="$HOME/.config/labwc"
mkdir -p "$LABWC_DIR"
if ! grep -qs "kiosk.sh" "${LABWC_DIR}/autostart" 2>/dev/null; then
    echo "/bin/bash ${LAUNCH_SCRIPT} &" >> "${LABWC_DIR}/autostart"
fi
chmod +x "${LABWC_DIR}/autostart" 2>/dev/null || true

echo -e "${GREEN}  ✓ Autostart configured (XDG + labwc + LXDE-pi)${NC}"
echo ""

# ── Step 10: Setup Heartbeat Cron ────────────────────────────────────
echo -e "${CYAN}${BOLD}Step 10: Setting up Heartbeat${NC}"

# Remove existing QMed heartbeat cron if any
(crontab -l 2>/dev/null | grep -v "qmed/heartbeat" || true) | crontab -

# Add heartbeat cron job (every minute)
(crontab -l 2>/dev/null || true; echo "* * * * * ${QMED_DIR}/heartbeat.sh") | crontab -

echo -e "${GREEN}  ✓ Heartbeat cron job installed (every 60 seconds)${NC}"
echo ""

# ── Step 11: Network Watchdog ────────────────────────────────────────
echo -e "${CYAN}${BOLD}Step 11: Setting up Network Watchdog${NC}"

# net_watchdog.sh is a versioned asset installed in Step 8 (fetch_asset) so
# the self-updater can replace it later.
if [ -f "${QMED_DIR}/net_watchdog.sh" ]; then
    chmod +x "${QMED_DIR}/net_watchdog.sh"
else
    echo -e "  ${YELLOW}⚠ net_watchdog.sh unavailable; skipping watchdog install${NC}"
fi

# Install watchdog cron (every minute)
(crontab -l 2>/dev/null | grep -v "qmed/net_watchdog" || true) | crontab -
(crontab -l 2>/dev/null || true; echo "* * * * * ${QMED_DIR}/net_watchdog.sh") | crontab -

echo -e "${GREEN}  ✓ Network watchdog installed (checks every 60 seconds)${NC}"
echo ""

# ── Print Config Summary ─────────────────────────────────────────────
echo -e "${CYAN}${BOLD}═══════════════════════════════════════════════════${NC}"
echo -e "${CYAN}${BOLD}              Configuration Summary${NC}"
echo -e "${CYAN}${BOLD}═══════════════════════════════════════════════════${NC}"
echo ""
echo -e "  ${BOLD}Device Name:${NC}       ${DEVICE_NAME}"
echo -e "  ${BOLD}Device ID:${NC}         ${DEVICE_ID}"
echo -e "  ${BOLD}Hospital:${NC}          ${HOSPITAL_NAME}"
echo -e "  ${BOLD}Queue Screen:${NC}      ${QUEUE_SCREEN_NAME}"
echo -e "  ${BOLD}Server URL:${NC}        ${SERVER_URL}"
echo -e "  ${BOLD}Screen URL:${NC}        ${FINAL_SCREEN_URL}"
echo -e "  ${BOLD}Video Mode:${NC}        ${VIDEO_MODE}"
if [ "$VIDEO_MODE" = "local_hybrid" ]; then
    echo -e "  ${BOLD}Local Video Port:${NC}  ${LOCAL_VIDEO_PORT}"
    echo -e "  ${BOLD}Video Directory:${NC}   ${QMED_DIR}/videos"
    echo -e "  ${BOLD}Video Sync:${NC}        Every 30 minutes"
fi
echo -e "  ${BOLD}Heartbeat:${NC}         Every 60 seconds"
echo -e "  ${BOLD}Network:${NC}           ${WIFI_SSID:-Ethernet/other} (auto-reconnect + watchdog)"
echo -e "  ${BOLD}Config File:${NC}       ${CONFIG_FILE}"
echo ""

# ── Done ─────────────────────────────────────────────────────────────
echo -e "${GREEN}${BOLD}"
echo "╔══════════════════════════════════════════════════════╗"
echo "║           Setup Complete! ✓                         ║"
echo "╠══════════════════════════════════════════════════════╣"
echo "║                                                      ║"
echo "║  The queue screen will launch automatically on       ║"
echo "║  next reboot. To start now, run:                     ║"
echo "║                                                      ║"
echo "║    sudo reboot                                       ║"
echo "║                                                      ║"
echo "╚══════════════════════════════════════════════════════╝"
echo -e "${NC}"

read -p "Reboot now? (y/N): " DO_REBOOT
if [[ "$DO_REBOOT" =~ ^[Yy]$ ]]; then
    echo -e "${YELLOW}Rebooting in 3 seconds...${NC}"
    sleep 3
    sudo reboot
fi
