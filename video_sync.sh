#!/bin/bash
#
# QMed Video Sync - Downloads uploaded videos to local storage
# =============================================================
# Downloads CMS videos from the server to the Pi's local storage.
# YouTube URLs are skipped (they play directly from the web).
#
# This script is called by setup.sh and can be run manually or via cron.
# Usage:  bash video_sync.sh
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

QMED_DIR="$HOME/.qmed"
CONFIG_FILE="${QMED_DIR}/config.json"
VIDEOS_DIR="${QMED_DIR}/videos"

# ── Check config ─────────────────────────────────────────────────────
if [ ! -f "$CONFIG_FILE" ]; then
    echo -e "${RED}✗ Config not found. Run setup.sh first.${NC}"
    exit 1
fi

SERVER_URL=$(jq -r '.server_url' "$CONFIG_FILE")
QUEUE_SCREEN_ID=$(jq -r '.queue_screen_id' "$CONFIG_FILE")
VIDEO_MODE=$(jq -r '.video_mode // "cloud"' "$CONFIG_FILE")

if [ "$VIDEO_MODE" = "cloud" ]; then
    echo -e "${DIM}Video mode is 'cloud'. No local sync needed.${NC}"
    exit 0
fi

# ── Create videos directory ──────────────────────────────────────────
mkdir -p "$VIDEOS_DIR"

echo -e "${CYAN}${BOLD}QMed Video Sync${NC}"
echo -e "${DIM}Fetching video list from server...${NC}"
echo ""

# ── Fetch video list ─────────────────────────────────────────────────
VIDEOS_JSON=$(curl -s --max-time 15 "${SERVER_URL}/api/open/raspberry-pi/videos?queue_screen_id=${QUEUE_SCREEN_ID}")
VIDEO_COUNT=$(echo "$VIDEOS_JSON" | jq '.data | length' 2>/dev/null || echo "0")

if [ "$VIDEO_COUNT" = "0" ] || [ -z "$VIDEO_COUNT" ]; then
    echo -e "${YELLOW}No videos found for this queue screen.${NC}"
    exit 0
fi

echo -e "${CYAN}Found ${VIDEO_COUNT} video(s)${NC}"
echo ""

DOWNLOADED=0
SKIPPED=0
YOUTUBE=0

for i in $(seq 0 $((VIDEO_COUNT - 1))); do
    TITLE=$(echo "$VIDEOS_JSON" | jq -r ".data[$i].title")
    FILE_NAME=$(echo "$VIDEOS_JSON" | jq -r ".data[$i].file_name")
    DOWNLOAD_URL=$(echo "$VIDEOS_JSON" | jq -r ".data[$i].download_url")
    IS_YOUTUBE=$(echo "$VIDEOS_JSON" | jq -r ".data[$i].is_youtube")
    VIDEO_ID=$(echo "$VIDEOS_JSON" | jq -r ".data[$i].id")
    REMOTE_SIZE=$(echo "$VIDEOS_JSON" | jq -r ".data[$i].file_size // empty")

    if [ "$IS_YOUTUBE" = "true" ]; then
        echo -e "  ${DIM}⏭ ${TITLE} (YouTube - plays from web)${NC}"
        YOUTUBE=$((YOUTUBE + 1))
        continue
    fi

    if [ "$DOWNLOAD_URL" = "null" ] || [ -z "$DOWNLOAD_URL" ]; then
        echo -e "  ${YELLOW}⚠ ${TITLE} (no download URL)${NC}"
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    # Use video ID + original extension as local filename
    EXTENSION="${FILE_NAME##*.}"
    LOCAL_FILE="${VIDEOS_DIR}/${VIDEO_ID}.${EXTENSION}"

    if [ -f "$LOCAL_FILE" ]; then
        LOCAL_SIZE=$(stat -c%s "$LOCAL_FILE" 2>/dev/null || echo 0)
        if [ -n "$REMOTE_SIZE" ] && [ "$REMOTE_SIZE" != "null" ] && [ "$LOCAL_SIZE" != "$REMOTE_SIZE" ]; then
            # The video was REPLACED on the server (same id, different content).
            # Without this check the stale local copy would play forever.
            echo -e "  ${CYAN}↻ ${TITLE} (changed on server: ${LOCAL_SIZE}B -> ${REMOTE_SIZE}B, re-downloading)${NC}"
            rm -f "$LOCAL_FILE"
        else
            echo -e "  ${GREEN}✓ ${TITLE} (already downloaded)${NC}"
            SKIPPED=$((SKIPPED + 1))
            continue
        fi
    fi

    echo -e "  ${CYAN}↓ Downloading: ${TITLE}...${NC}"
    curl -sL "$DOWNLOAD_URL" -o "$LOCAL_FILE"

    if [ -f "$LOCAL_FILE" ] && [ -s "$LOCAL_FILE" ]; then
        echo -e "  ${GREEN}✓ ${TITLE} saved${NC}"
        DOWNLOADED=$((DOWNLOADED + 1))
    else
        echo -e "  ${RED}✗ Failed to download ${TITLE}${NC}"
        rm -f "$LOCAL_FILE"
        SKIPPED=$((SKIPPED + 1))
    fi
done

# ── Build local video mapping ────────────────────────────────────────
echo ""
echo -e "${CYAN}Building local video index...${NC}"

# Create a mapping JSON file: video_id -> local path
VIDEO_MAP="["
FIRST=true
for i in $(seq 0 $((VIDEO_COUNT - 1))); do
    VIDEO_ID=$(echo "$VIDEOS_JSON" | jq -r ".data[$i].id")
    FILE_NAME=$(echo "$VIDEOS_JSON" | jq -r ".data[$i].file_name")
    IS_YOUTUBE=$(echo "$VIDEOS_JSON" | jq -r ".data[$i].is_youtube")
    ORIGINAL_URL=$(echo "$VIDEOS_JSON" | jq -r ".data[$i].url")

    EXTENSION="${FILE_NAME##*.}"
    LOCAL_FILE="${VIDEOS_DIR}/${VIDEO_ID}.${EXTENSION}"

    if [ "$FIRST" = true ]; then
        FIRST=false
    else
        VIDEO_MAP="${VIDEO_MAP},"
    fi

    if [ "$IS_YOUTUBE" = "true" ]; then
        # YouTube URLs stay as-is (play from web)
        VIDEO_MAP="${VIDEO_MAP}{\"id\":${VIDEO_ID},\"local\":false,\"url\":\"${ORIGINAL_URL}\"}"
    elif [ -f "$LOCAL_FILE" ]; then
        # Local file served from localhost
        VIDEO_MAP="${VIDEO_MAP}{\"id\":${VIDEO_ID},\"local\":true,\"file\":\"${VIDEO_ID}.${EXTENSION}\"}"
    else
        # File not downloaded, use remote URL
        VIDEO_MAP="${VIDEO_MAP}{\"id\":${VIDEO_ID},\"local\":false,\"url\":\"${ORIGINAL_URL}\"}"
    fi
done
VIDEO_MAP="${VIDEO_MAP}]"

echo "$VIDEO_MAP" | jq '.' > "${VIDEOS_DIR}/video_map.json"

echo -e "${GREEN}✓ Video index saved to ${VIDEOS_DIR}/video_map.json${NC}"
echo ""
echo -e "${GREEN}${BOLD}Sync complete: ${DOWNLOADED} downloaded, ${YOUTUBE} YouTube, ${SKIPPED} skipped${NC}"
