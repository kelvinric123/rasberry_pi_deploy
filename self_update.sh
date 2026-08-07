#!/bin/bash
# QMed Pi script self-updater.
#
# Fetches the script bundle manifest from the QMed server and, when the
# server's bundle version differs from the locally installed one, downloads
# every file, verifies its sha256 against the manifest, and only then swaps
# the files into ~/.qmed — a half-installed bundle is impossible.
#
# It then REPORTS the outcome back to the server and, when the server asked
# for it, reboots the Pi so the new scripts take effect from a clean state.
# The report goes out BEFORE the reboot on purpose: the admin page has to be
# able to show "installed successfully" even though the device is about to
# disappear for the length of a reboot. A failure leaves the server's pending
# flag set, so the device is offered the update again on the retry window
# (default 12h) until it finally reports the published version.
#
# Usage:
#   bash self_update.sh                # update only if the server version differs
#   bash self_update.sh --force        # always reinstall the bundle
#   bash self_update.sh --reboot       # reboot after a successful install
#   bash self_update.sh --no-reboot    # restart services only (default)
#
# Normally triggered by heartbeat.sh, which passes --reboot when the server's
# heartbeat reply says so. Installed to ~/.qmed/self_update.sh and updates
# ITSELF as part of the bundle — edit it in the repo, not on the device.

QMED_DIR="$HOME/.qmed"
CONFIG_FILE="$QMED_DIR/config.json"
VERSION_FILE="$QMED_DIR/scripts_version"

FORCE="no"
REBOOT="no"
for arg in "$@"; do
    case "$arg" in
        --force)     FORCE="yes" ;;
        --reboot)    REBOOT="yes" ;;
        --no-reboot) REBOOT="no" ;;
    esac
done

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*"; }

[ -f "$CONFIG_FILE" ] || { log "No config.json — run setup.sh first."; exit 0; }
SERVER_URL=$(jq -r '.server_url // empty' "$CONFIG_FILE" 2>/dev/null)
DEVICE_TOKEN=$(jq -r '.device_token // empty' "$CONFIG_FILE" 2>/dev/null)
[ -n "$SERVER_URL" ] || { log "No server_url in config.json."; exit 0; }

# ── Report the outcome to the server ─────────────────────────────────
# Best-effort: if the network is the reason the update failed, this POST
# fails too and the server simply retries on its own schedule.
report() {
    local status="$1" error="$2"
    [ -n "$DEVICE_TOKEN" ] || return 0

    local version
    version=$(cat "$VERSION_FILE" 2>/dev/null || echo "")

    # Strip characters that would break the hand-built JSON below.
    error=$(printf '%s' "$error" | tr -d '"\\\n\r' | cut -c1-400)

    curl -s -o /dev/null --max-time 10 -X POST \
        "${SERVER_URL}/api/open/raspberry-pi/update-result" \
        -H "Content-Type: application/json" \
        -d "{
            \"device_token\": \"${DEVICE_TOKEN}\",
            \"status\": \"${status}\",
            \"scripts_version\": \"${version}\",
            \"error\": \"${error}\"
        }" 2>/dev/null
}

fail() {
    log "$1"
    report "failed" "$1"
    exit 1
}

MANIFEST=$(curl -fsSL --max-time 20 "${SERVER_URL}/raspberry-pi/manifest.json") \
    || fail "Manifest fetch failed."
VERSION=$(echo "$MANIFEST" | jq -r '.version // empty' 2>/dev/null)
if [ -z "$VERSION" ] || [ "$VERSION" = "none" ]; then
    fail "Server has no valid script bundle (version: '${VERSION:-?}')."
fi

CURRENT=$(cat "$VERSION_FILE" 2>/dev/null || echo "none")
if [ "$VERSION" = "$CURRENT" ] && [ "$FORCE" != "yes" ]; then
    exit 0
fi
log "Updating scripts ${CURRENT} -> ${VERSION}"

# Stage inside ~/.qmed so the final mv is an atomic same-filesystem rename.
TMP=$(mktemp -d "${QMED_DIR}/update.XXXXXX") || fail "Cannot create a staging directory (disk full?)."
trap 'rm -rf "$TMP"' EXIT

FILES=$(echo "$MANIFEST" | jq -r '.files | keys[]' 2>/dev/null)
[ -n "$FILES" ] || fail "Manifest lists no files."

# Download and verify EVERYTHING before touching a single installed file.
for NAME in $FILES; do
    curl -fsSL --max-time 60 "${SERVER_URL}/raspberry-pi/${NAME}" -o "${TMP}/${NAME}" \
        || fail "Download failed: ${NAME}"
    EXPECTED=$(echo "$MANIFEST" | jq -r --arg n "$NAME" '.files[$n]')
    ACTUAL=$(sha256sum "${TMP}/${NAME}" | awk '{print $1}')
    if [ "$EXPECTED" != "$ACTUAL" ]; then
        fail "Checksum mismatch for ${NAME} (expected ${EXPECTED}, got ${ACTUAL}) — aborting."
    fi
done

KIOSK_CHANGED="no"
if [ -f "${TMP}/kiosk.sh" ] && ! cmp -s "${TMP}/kiosk.sh" "${QMED_DIR}/kiosk.sh"; then
    KIOSK_CHANGED="yes"
fi

for NAME in $FILES; do
    mv -f "${TMP}/${NAME}" "${QMED_DIR}/${NAME}"
    chmod +x "${QMED_DIR}/${NAME}" 2>/dev/null || true
done
echo "$VERSION" > "$VERSION_FILE"
log "Bundle installed."

# Tell the server now — everything below either reboots the device or
# restarts the processes that would be sending the next heartbeat.
report "success" ""

# ── Reboot (preferred) ───────────────────────────────────────────────
# A reboot is the only restart that is guaranteed to pick up every changed
# script: cron entries, the kiosk loop, the local server and any leaked
# Chromium state all come back fresh. It costs the screen ~40 seconds.
if [ "$REBOOT" = "yes" ]; then
    log "Rebooting to apply ${VERSION}."
    sync
    sleep 2
    if sudo -n reboot 2>/dev/null || sudo -n systemctl reboot 2>/dev/null; then
        exit 0
    fi
    # Passwordless sudo is not available for this user — fall through to the
    # service restarts below rather than leaving the update unapplied.
    log "Reboot not permitted (no passwordless sudo); restarting services instead."
fi

# ── Service restart (fallback / --no-reboot) ─────────────────────────
# Restart the local video/config server (server.py may have changed;
# start_local_server.sh kills the previous instance itself).
bash "${QMED_DIR}/start_local_server.sh" >/dev/null 2>&1

# Restart the kiosk only when its launcher changed — an unnecessary restart
# just blanks the hospital screen for a few seconds.
if [ "$KIOSK_CHANGED" = "yes" ]; then
    log "kiosk.sh changed — restarting kiosk."
    pkill -f "${QMED_DIR}/kiosk.sh" 2>/dev/null || true
    sleep 1
    pkill -f -- '--kiosk' 2>/dev/null || true
    export DISPLAY="${DISPLAY:-:0}"
    nohup bash "${QMED_DIR}/kiosk.sh" >/dev/null 2>&1 &
fi

log "Update to ${VERSION} complete."
