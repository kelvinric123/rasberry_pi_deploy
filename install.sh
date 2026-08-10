#!/bin/bash
#
# QMed Raspberry Pi Queue Screen - Installer
# ============================================
# Run this script ONCE on a fresh Raspberry Pi OS (with Desktop) to install
# all required dependencies for running the queue screen in kiosk mode.
#
# Usage:  sudo bash install.sh
#

set -e

# ── Color helpers ─────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

echo -e "${CYAN}${BOLD}"
echo "╔══════════════════════════════════════════════════╗"
echo "║   QMed Queue Screen - Raspberry Pi Installer    ║"
echo "╚══════════════════════════════════════════════════╝"
echo -e "${NC}"

# ── Check root ────────────────────────────────────────────────────────
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}✗ Please run this script with sudo:${NC}"
    echo "  sudo bash install.sh"
    exit 1
fi

ACTUAL_USER="${SUDO_USER:-pi}"
ACTUAL_HOME=$(eval echo "~${ACTUAL_USER}")

echo -e "${YELLOW}▸ Running as root, target user: ${ACTUAL_USER}${NC}"
echo -e "${YELLOW}▸ Home directory: ${ACTUAL_HOME}${NC}"
echo ""

# ── Check for legacy OS and redirect ─────────────────────────────────
OS_CODENAME=$(lsb_release -cs 2>/dev/null || grep VERSION_CODENAME /etc/os-release 2>/dev/null | cut -d= -f2 || echo "unknown")
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

case "$OS_CODENAME" in
    buster|stretch|jessie)
        echo -e "${YELLOW}▸ Detected legacy OS: ${OS_CODENAME}${NC}"
        echo -e "${YELLOW}  The main package repositories for this OS have been archived.${NC}"
        echo -e "${YELLOW}  Switching to legacy installer...${NC}"
        echo ""

        if [ -f "${SCRIPT_DIR}/install_legacy.sh" ]; then
            exec bash "${SCRIPT_DIR}/install_legacy.sh"
        else
            echo -e "${YELLOW}  ⚠ No legacy installer bundled. This build targets Raspberry Pi OS (Bookworm/Trixie).${NC}"
            echo -e "${YELLOW}  Continuing with the standard installer — some apt steps may fail on archived repos.${NC}"
            echo ""
        fi
        ;;
esac

# ── Step 1: Update system ────────────────────────────────────────────
echo -e "${CYAN}[1/7] Updating system packages...${NC}"
apt-get update -qq
echo -e "${GREEN}  ✓ System updated${NC}"

# ── Step 2: Install dependencies ─────────────────────────────────────
echo -e "${CYAN}[2/7] Installing required packages...${NC}"
apt-get install -y -qq \
    chromium \
    unclutter \
    xdotool \
    jq \
    curl \
    sed \
    iw \
    alsa-utils \
    mpv \
    network-manager-gnome
echo -e "${GREEN}  ✓ Packages installed (chromium, unclutter, xdotool, jq, curl, iw, alsa-utils, mpv, nm-connection-editor)${NC}"

# ── Step 3: Disable screen blanking ──────────────────────────────────
echo -e "${CYAN}[3/7] Disabling screen blanking & power saving...${NC}"

# Disable via lightdm config
LIGHTDM_CONF="/etc/lightdm/lightdm.conf"
if [ -f "$LIGHTDM_CONF" ]; then
    if ! grep -q "xserver-command" "$LIGHTDM_CONF"; then
        sed -i '/^\[Seat:\*\]/a xserver-command=X -s 0 -dpms' "$LIGHTDM_CONF"
    fi
fi

echo -e "${GREEN}  ✓ Screen blanking disabled${NC}"

# ── Step 3b: Switch to X11 Window System ─────────────────────────────
echo -e "${CYAN}[3b] Switching display backend to X11 (required for kiosk tools)...${NC}"
if command -v raspi-config >/dev/null 2>&1; then
    # W1 = Openbox (X11 backend)
    raspi-config nonint do_wayland W1
    echo -e "${GREEN}  ✓ X11 configured${NC}"
else
    echo -e "${YELLOW}  ⚠ raspi-config not found. Skipping X11 switch.${NC}"
fi

# ── Step 3c: Disable Wi-Fi power saving (persistent) ─────────────────
# The Pi's on-board Wi-Fi enables power management by default, which is the
# single most common cause of a kiosk silently dropping off the network.
# Disable it persistently via NetworkManager, plus an immediate best-effort.
echo -e "${CYAN}[3c] Disabling Wi-Fi power saving (keeps the screen online)...${NC}"

NM_CONF_DIR="/etc/NetworkManager/conf.d"
if [ -d "/etc/NetworkManager" ]; then
    mkdir -p "$NM_CONF_DIR"
    cat > "${NM_CONF_DIR}/99-qmed-wifi-powersave-off.conf" << 'NMEOF'
# Installed by QMed Queue Screen installer.
# 2 = disable Wi-Fi power management for all connections.
[connection]
wifi.powersave = 2
NMEOF
    echo -e "${GREEN}  ✓ NetworkManager power-save disabled (applies on next reconnect/reboot)${NC}"
else
    echo -e "${YELLOW}  ⚠ NetworkManager not detected; skipping persistent power-save config${NC}"
fi

# Immediate, best-effort disable for the current session (non-fatal).
for IFACE in $(ls /sys/class/net 2>/dev/null | grep -E '^wl'); do
    iw dev "$IFACE" set power_save off 2>/dev/null || true
done
echo ""

# ── Step 4: Create QMed directory ──────────────────────────────────────
echo -e "${CYAN}[4/7] Creating QMed directory...${NC}"
QMED_DIR="${ACTUAL_HOME}/.qmed"
mkdir -p "$QMED_DIR"
chown -R "${ACTUAL_USER}:${ACTUAL_USER}" "$QMED_DIR"
echo -e "${GREEN}  ✓ Directory ready: ${QMED_DIR}${NC}"

# ── Step 5: Create autostart directory ───────────────────────────────
echo -e "${CYAN}[5/7] Preparing autostart directory...${NC}"
AUTOSTART_DIR="${ACTUAL_HOME}/.config/lxsession/LXDE-pi"
mkdir -p "$AUTOSTART_DIR"
chown -R "${ACTUAL_USER}:${ACTUAL_USER}" "${ACTUAL_HOME}/.config"
echo -e "${GREEN}  ✓ Autostart directory ready: ${AUTOSTART_DIR}${NC}"

# ── Step 6: Heartbeat script ─────────────────────────────────────────
# heartbeat.sh is now a versioned asset installed by setup.sh (fetch_asset)
# and kept current by self_update.sh — it is no longer baked in here.
echo -e "${CYAN}[7/7] Heartbeat script...${NC}"
echo -e "${GREEN}  ✓ Installed by setup.sh (self-updatable asset)${NC}"

# ── Done ─────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}"
echo "╔══════════════════════════════════════════════════╗"
echo "║         Installation Complete! ✓                ║"
echo "╠══════════════════════════════════════════════════╣"
echo "║                                                  ║"
echo "║  Next step: run the setup script:                ║"
echo "║    bash setup.sh                                 ║"
echo "║                                                  ║"
echo "╚══════════════════════════════════════════════════╝"
echo -e "${NC}"
