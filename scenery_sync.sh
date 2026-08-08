#!/bin/bash
#
# QMed Scenery Sync - caches the screen-saver scenery pack on the Pi
# ==================================================================
# Downloads the scenes behind the "Screen Saver" media type so the queue
# screen keeps showing scenery through a network outage, instead of a blank
# media panel.
#
# The pack lands in ~/.qmed/videos/scenery/ ON PURPOSE: start_local_server.sh
# already serves ~/.qmed/videos on port 8888, so the scenes are reachable at
# http://localhost:8888/scenery/<file> with no change to server.py.
#
# Cheap to run: the whole pack is a handful of small SVG files, and anything
# whose sha256 already matches is skipped, so a routine run transfers nothing
# but the manifest.
#
# Installed to ~/.qmed/scenery_sync.sh and kept current by self_update.sh —
# edit it in the repo, not on the device.
#
# Usage:  bash scenery_sync.sh            # sync if the server version differs
#         bash scenery_sync.sh --force    # re-download everything

QMED_DIR="$HOME/.qmed"
CONFIG_FILE="${QMED_DIR}/config.json"
SCENERY_DIR="${QMED_DIR}/videos/scenery"
VERSION_FILE="${QMED_DIR}/scenery_version"
MAP_FILE="${SCENERY_DIR}/scenery_map.json"

FORCE="no"
[ "$1" = "--force" ] && FORCE="yes"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*"; }

[ -f "$CONFIG_FILE" ] || { log "No config.json - run setup.sh first."; exit 0; }
SERVER_URL=$(jq -r '.server_url // empty' "$CONFIG_FILE" 2>/dev/null)
[ -n "$SERVER_URL" ] || { log "No server_url in config.json."; exit 0; }

MANIFEST=$(curl -fsSL --max-time 20 "${SERVER_URL}/screensaver/manifest.json") \
    || { log "Scenery manifest fetch failed."; exit 1; }

VERSION=$(echo "$MANIFEST" | jq -r '.version // empty' 2>/dev/null)
if [ -z "$VERSION" ] || [ "$VERSION" = "none" ]; then
    log "Server publishes no scenery pack (version: '${VERSION:-?}')."
    exit 0
fi

CURRENT=$(cat "$VERSION_FILE" 2>/dev/null || echo "none")
if [ "$VERSION" = "$CURRENT" ] && [ -f "$MAP_FILE" ] && [ "$FORCE" != "yes" ]; then
    exit 0          # already current - stay quiet, this runs from cron
fi

mkdir -p "$SCENERY_DIR" || { log "Cannot create ${SCENERY_DIR}"; exit 1; }
log "Syncing scenery ${CURRENT} -> ${VERSION}"

FILES=$(echo "$MANIFEST" | jq -r '.files | keys[]' 2>/dev/null)
[ -n "$FILES" ] || { log "Manifest lists no scenes."; exit 1; }

DOWNLOADED=0
KEPT=0
FAILED=0

for NAME in $FILES; do
    # Defensive: the name becomes a local path and a URL segment.
    case "$NAME" in
        */*|*..*|"") log "Skipping unsafe scene name: ${NAME}"; continue ;;
    esac

    EXPECTED=$(echo "$MANIFEST" | jq -r --arg n "$NAME" '.files[$n]')
    TARGET="${SCENERY_DIR}/${NAME}"

    if [ "$FORCE" != "yes" ] && [ -f "$TARGET" ]; then
        ACTUAL=$(sha256sum "$TARGET" 2>/dev/null | awk '{print $1}')
        if [ "$ACTUAL" = "$EXPECTED" ]; then
            KEPT=$((KEPT + 1))
            continue
        fi
    fi

    TMP="${TARGET}.part"
    if ! curl -fsSL --max-time 30 "${SERVER_URL}/screensaver/${NAME}" -o "$TMP"; then
        log "Download failed: ${NAME}"
        rm -f "$TMP"
        FAILED=$((FAILED + 1))
        continue
    fi

    ACTUAL=$(sha256sum "$TMP" 2>/dev/null | awk '{print $1}')
    if [ "$ACTUAL" != "$EXPECTED" ]; then
        log "Checksum mismatch for ${NAME} - discarding."
        rm -f "$TMP"
        FAILED=$((FAILED + 1))
        continue
    fi

    # Only now does it become visible to the browser: a half-written scene is
    # never served, because the page reads whole files by name.
    mv -f "$TMP" "$TARGET"
    DOWNLOADED=$((DOWNLOADED + 1))
done

# Drop scenes the server no longer publishes, so a retired image stops
# appearing on devices that already cached it. Matches every supported format,
# not just SVG — a pack can be drawn scenes, photographs, or a mix.
for EXISTING in "$SCENERY_DIR"/*.svg "$SCENERY_DIR"/*.jpg "$SCENERY_DIR"/*.jpeg \
                "$SCENERY_DIR"/*.png "$SCENERY_DIR"/*.webp; do
    [ -f "$EXISTING" ] || continue
    BASE=$(basename "$EXISTING")
    if ! echo "$FILES" | grep -qx "$BASE"; then
        log "Removing retired scene: ${BASE}"
        rm -f "$EXISTING"
    fi
done

# The page reads this to decide whether to use the local copies. Only list
# what is actually on disk — a scene that failed to download must fall back to
# the server URL rather than 404 on localhost.
PRESENT=$(cd "$SCENERY_DIR" 2>/dev/null \
    && ls -1 2>/dev/null | grep -Ei '\.(svg|jpe?g|png|webp)$' | jq -R . | jq -s . \
    || echo "[]")
jq -n --arg v "$VERSION" --argjson f "$PRESENT" '{version: $v, files: $f}' > "$MAP_FILE" 2>/dev/null \
    || echo "{\"version\":\"${VERSION}\",\"files\":[]}" > "$MAP_FILE"

# Only stamp the version when everything arrived; a partial sync must retry.
if [ "$FAILED" -eq 0 ]; then
    echo "$VERSION" > "$VERSION_FILE"
    log "Scenery ${VERSION} ready (${DOWNLOADED} new, ${KEPT} unchanged)."
else
    log "Scenery sync incomplete (${DOWNLOADED} new, ${KEPT} unchanged, ${FAILED} failed) - will retry."
    exit 1
fi
