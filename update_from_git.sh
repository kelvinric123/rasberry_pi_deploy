#!/bin/bash
# update_from_git.sh — pull this folder and apply it to the running install.
#
#   bash ~/Desktop/raspberry_pi_v2.1/update_from_git.sh
#
# Lives IN the repo on purpose: `git pull` updates this script together with
# the bundle, so its file list can never go stale — the failure mode that
# bit the hand-written ~/qmed-update helper (it embedded an old list and
# silently skipped every script it did not know about).
#
# What it does, in order:
#   1. git pull (when this folder is a clone; scp copies apply as-is)
#   2. verify the bundle is COMPLETE before touching ~/.qmed
#   3. copy the bundle into ~/.qmed and chmod it
#   4. refresh the desktop icons
#   5. make sure the cron jobs exist
#   6. restart the local server and the kiosk — honouring a maintenance pause
#
# It also installs ~/qmed-update as a shorthand for itself.

DIR="$(cd "$(dirname "$0")" && pwd)"
QMED_DIR="$HOME/.qmed"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; DIM='\033[2m'; NC='\033[0m'

# Keep in step with RaspberryPiScriptBundle::FILES on the server.
BUNDLE="server.py start_local_server.sh video_sync.sh scenery_sync.sh heartbeat.sh kiosk.sh net_watchdog.sh self_update.sh kiosk_off.sh wifi_setup.sh pause_autostart.sh desktop_shortcuts.sh"

# ── 1. Pull ──────────────────────────────────────────────────────────
if [ -d "${DIR}/.git" ]; then
    echo -e "${DIM}Pulling ${DIR}...${NC}"
    if ! git -C "$DIR" pull --ff-only; then
        echo -e "${YELLOW}git pull failed (offline, or local edits).${NC}"
        echo "  To discard local edits:  git -C '$DIR' reset --hard origin/main"
        echo "  Continuing with the files already in the folder."
    fi
else
    echo -e "${YELLOW}${DIR} is not a git clone — applying its files as-is.${NC}"
    echo -e "${DIM}(one-time fix: mv it aside and git clone the deploy repo — see MANUAL_UPDATE.md)${NC}"
fi

# ── 2. Verify before touching anything ───────────────────────────────
MISSING=""
for F in $BUNDLE; do
    [ -f "${DIR}/${F}" ] || MISSING="${MISSING} ${F}"
done
if [ -n "$MISSING" ]; then
    echo -e "${RED}Bundle incomplete:${MISSING}${NC}"
    echo "Nothing was changed. Pull again, or re-clone the folder."
    exit 1
fi

# ── 3. Install ───────────────────────────────────────────────────────
mkdir -p "$QMED_DIR"
for F in $BUNDLE; do
    cp "${DIR}/${F}" "${QMED_DIR}/${F}"
    chmod +x "${QMED_DIR}/${F}" 2>/dev/null || true
done
echo -e "${GREEN}✓ Bundle installed to ${QMED_DIR}${NC}"

# ── 4. Desktop icons ─────────────────────────────────────────────────
bash "${QMED_DIR}/desktop_shortcuts.sh" "$DIR" 2>/dev/null | sed 's/^/  /'

# ── 5. Cron jobs (idempotent; a manual copy installs no crons itself) ─
if command -v crontab >/dev/null 2>&1; then
    ensure_cron() {  # $1 = match, $2 = line
        crontab -l 2>/dev/null | grep -q "$1" && return 0
        (crontab -l 2>/dev/null || true; echo "$2") | crontab -
        echo "  cron added: $2"
    }
    ensure_cron "qmed/heartbeat"    "* * * * * ${QMED_DIR}/heartbeat.sh"
    ensure_cron "qmed/net_watchdog" "* * * * * ${QMED_DIR}/net_watchdog.sh"
    ensure_cron "scenery_sync"      "17 */6 * * * ${QMED_DIR}/scenery_sync.sh"
    mkdir -p "${QMED_DIR}/videos/scenery"
fi

# ── Shorthand for next time ──────────────────────────────────────────
printf '#!/bin/bash\nexec bash "%s/update_from_git.sh" "$@"\n' "$DIR" > "$HOME/qmed-update" 2>/dev/null \
    && chmod +x "$HOME/qmed-update" 2>/dev/null \
    && echo -e "${DIM}(~/qmed-update now runs this script)${NC}"

# ── 6. Restart services ──────────────────────────────────────────────
bash "${QMED_DIR}/start_local_server.sh" >/dev/null 2>&1 || true

# Respect a maintenance pause: an engineer mid-SD-copy must not get the
# queue screen dropped on their desktop by an update.
kiosk_paused() {
    local F=/tmp/qmed-kiosk-paused U B
    [ -f "$F" ] || return 1
    read -r U B < "$F" 2>/dev/null
    U=$(printf '%s' "${U:-}" | tr -cd '0-9')
    [ -n "$U" ] && [ "$U" -gt "$(date +%s)" ] 2>/dev/null \
        && [ "${B:-}" = "$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo unknown)" ]
}

if kiosk_paused; then
    echo -e "${YELLOW}Maintenance pause active — kiosk left stopped.${NC}"
    echo "  Click 'QMed Queue Screen' or reboot when you are done."
else
    pkill -f "${QMED_DIR}/kiosk.sh" 2>/dev/null || true
    sleep 1
    pkill -f -- '--kiosk' 2>/dev/null || true
    export DISPLAY="${DISPLAY:-:0}"
    nohup bash "${QMED_DIR}/kiosk.sh" >/dev/null 2>&1 &
    echo -e "${GREEN}✓ Kiosk restarted${NC} ${DIM}(screen blanks for a few seconds)${NC}"
fi

if [ -d "${DIR}/.git" ]; then
    echo -e "${GREEN}Updated to $(git -C "$DIR" rev-parse --short HEAD 2>/dev/null)${NC}"
fi
echo ""
echo -e "${DIM}Note: the admin page will show this Pi as 'Scripts outdated' until the"
echo -e "server publishes the same bundle — do not press Update there meanwhile,"
echo -e "or the server's copy overwrites this one.${NC}"
