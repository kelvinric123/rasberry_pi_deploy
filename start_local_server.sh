#!/bin/bash
#
# QMed Local Video Server
# ========================
# Starts a lightweight HTTP server to serve downloaded videos
# from the Pi's local storage on port 8888.
#
# Usage:  bash start_local_server.sh
# The server runs in the background and serves files from ~/.qmed/videos/
#

QMED_DIR="$HOME/.qmed"
VIDEOS_DIR="${QMED_DIR}/videos"
PORT=8888
PID_FILE="${QMED_DIR}/video_server.pid"

# Kill existing server if running
if [ -f "$PID_FILE" ]; then
    OLD_PID=$(cat "$PID_FILE")
    if kill -0 "$OLD_PID" 2>/dev/null; then
        kill "$OLD_PID" 2>/dev/null
        sleep 1
    fi
    rm -f "$PID_FILE"
fi

# Create videos directory if it doesn't exist
mkdir -p "$VIDEOS_DIR"

# Expose config.json (which lives in $QMED_DIR, one level up) at the server root.
# The queue-screen page fetches /config.json to read its device_token. Without
# it, the page can't send ?device_token=, so it falls back to the shared,
# NON-destructive SSE path — which lets a transient second reader (Chromium's
# extra renderer, or a reconnect overlap) replay the same call and play the
# announcement twice ("echo"). The per-device path consumes the event on read.
ln -sf "$QMED_DIR/config.json" "$VIDEOS_DIR/config.json"

# Start the local static server (serves cached videos + config.json) in the background
cd "$VIDEOS_DIR"
python3 "$QMED_DIR/server.py" "$PORT" > "${QMED_DIR}/video_server.log" 2>&1 &
SERVER_PID=$!

echo "$SERVER_PID" > "$PID_FILE"
echo "Local QMed static server started on port ${PORT} (PID: ${SERVER_PID})"
echo "Videos served from: ${VIDEOS_DIR}"
echo "Access at: http://localhost:${PORT}/"
