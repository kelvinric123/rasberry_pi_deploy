#!/usr/bin/env python3
# QMed Local Static Server + Native Video Player Agent
# ====================================================
# Serves the Pi's locally cached CMS videos (and config.json) over HTTP with
# permissive CORS, AND drives an mpv window for native (hardware-decoded)
# playlist playback positioned exactly over the layout's media area.
#
# The kiosk page measures its media area (it owns the layout truth) and calls:
#   POST /player/show  {"x":..,"y":..,"width":..,"height":..,"video_ids":[..]}
#       -> starts/repositions mpv over that rect playing the local files.
#          Replies {"ok": false, ...} when mpv or the files aren't available,
#          in which case the page keeps its own <video> — graceful fallback.
#   POST /player/hide  -> stops mpv (page reload, media type changed, ...)
#   GET  /player/status -> debug info
#
# Voice announcements are server-generated TTS played by the page, not here.

import atexit
import http.server
import json
import os
import shutil
import socketserver
import subprocess
import sys
import threading
import time

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8888

QMED_DIR = os.path.join(os.path.expanduser("~"), ".qmed")
VIDEOS_DIR = os.path.join(QMED_DIR, "videos")
VIDEO_SYNC = os.path.join(QMED_DIR, "video_sync.sh")

MPV_TITLE = "qmed-native-player"   # marker for cleanup across restarts
PLAYER_LOG = os.path.join(QMED_DIR, "player.log")
MPV_STDERR = os.path.join(QMED_DIR, "mpv_last.log")   # last mpv run's output


def plog(msg):
    """Player event log — the first place to look when video misbehaves."""
    try:
        if os.path.isfile(PLAYER_LOG) and os.path.getsize(PLAYER_LOG) > 300_000:
            os.replace(PLAYER_LOG, PLAYER_LOG + ".1")
        with open(PLAYER_LOG, "a", encoding="utf-8") as f:
            f.write(time.strftime("%Y-%m-%d %H:%M:%S ") + msg + "\n")
    except OSError:
        pass


class NativePlayer:
    """Owns the single mpv process that covers the layout's media area."""

    def __init__(self):
        self.proc = None
        self.params = None
        self.lock = threading.Lock()
        self.last_sync_kick = 0.0
        self.launched_at = 0.0
        self._watchdog_started = False
        # A previous server instance may have left an mpv behind — clear it.
        try:
            subprocess.run(["pkill", "-f", MPV_TITLE], capture_output=True)
        except OSError:
            pass  # non-Linux test environment
        atexit.register(self.stop)

    # NOTE on focus, learned the hard way (verified on-device by screenshot):
    # mpv must HOLD focus.
    #
    # Under Openbox a *focused* fullscreen window stacks in a layer ABOVE
    # always-on-top windows. While the Chromium kiosk has focus, its
    # fullscreen layer covers mpv — the video plays invisibly behind the
    # browser. Openbox on Pi OS does not focus new windows, so the agent
    # explicitly activates the mpv window after launch and re-asserts it from
    # the watchdog (a Chromium self-heal restart would otherwise re-grab
    # focus and swallow the video again). A focused mpv is inert — its inputs
    # are disabled — and the taskbar that would pop over an unfocused kiosk
    # is removed by kiosk.sh.
    def _assert_native_focus(self):
        """Make the mpv window the focused window. Returns True when it is."""
        env = dict(os.environ)
        env.setdefault("DISPLAY", ":0")
        try:
            active = subprocess.run(
                ["xdotool", "getactivewindow", "getwindowname"],
                env=env, capture_output=True, timeout=5,
            ).stdout.decode(errors="replace")
            if MPV_TITLE in active:
                return True
            subprocess.run(
                ["xdotool", "search", "--name", MPV_TITLE, "windowactivate"],
                env=env, capture_output=True, timeout=5,
            )
        except (OSError, subprocess.TimeoutExpired):
            pass
        return False

    def _focus_after_launch(self):
        """The mpv window takes a moment to map — retry until focused."""
        for delay in (0.6, 1.5, 3.0):
            time.sleep(delay)
            with self.lock:
                if not (self.proc and self.proc.poll() is None):
                    return  # died or was hidden meanwhile
            if self._assert_native_focus():
                plog("mpv focused (video on top)")
                return
        plog("could not focus mpv window (xdotool missing?) — video may sit behind the kiosk")

    def show(self, x, y, width, height, files):
        """(Re)start mpv over the given rect. Idempotent for identical calls."""
        with self.lock:
            params = (x, y, width, height, tuple(files))
            if self.proc and self.proc.poll() is None and params == self.params:
                return True  # already playing exactly this — don't flicker

            if self.proc and self.proc.poll() is not None:
                plog(f"previous mpv found dead exit={self.proc.returncode} (see mpv_last.log)")

            self._kill_locked()

            mpv = shutil.which("mpv")
            if not mpv or not files:
                return False

            env = dict(os.environ)
            env.setdefault("DISPLAY", ":0")   # cron/systemd callers have no DISPLAY

            # Deliberately MINIMAL — kept as close as possible to the plain
            # command that loops flawlessly when run by hand.
            #
            # Looping: a SINGLE video uses --loop-file, which repeats inside
            # the decoder with no playlist-advance/reload — the exact machinery
            # where the agent-launched mpv kept dying (exit=1 at ~video-length).
            # Only a real multi-video playlist uses --loop-playlist.
            loop_flag = "--loop-file=inf" if len(files) == 1 else "--loop-playlist=inf"

            cmd = [
                mpv,
                f"--title={MPV_TITLE}",
                "--no-border",
                "--ontop",                      # above the fullscreen kiosk window
                f"--geometry={width}x{height}+{x}+{y}",
                loop_flag,
                "--mute=yes",                   # matches the muted web <video>
                "--no-osc",
                "--no-input-default-bindings",
                "--no-input-terminal",          # stdin is /dev/null — never read it
                # SOFTWARE decode: this mpv build has no working hwaccel on the
                # Pi (CUDA/Vulkan/VDPAU all fail) and re-attempted the broken
                # init at every loop. Cheap at queue-TV resolutions.
                "--hwdec=no",
                # Quiet, but NOT silent: warnings, errors and the
                # "Exiting... (reason)" line must reach mpv_last.log.
                "--quiet", "--no-msg-color", "--msg-level=statusline=error",
            ] + files

            try:
                out_sink = open(MPV_STDERR, "wb")   # keep the LAST run's output
            except OSError:
                out_sink = subprocess.DEVNULL

            # mpv writes its console messages (incl. "Exiting... (reason)") to
            # STDOUT — capture BOTH streams or the log stays uselessly empty.
            self.proc = subprocess.Popen(
                cmd, env=env,
                stdin=subprocess.DEVNULL,
                stdout=out_sink, stderr=subprocess.STDOUT,
            )
            self.params = params
            self.launched_at = time.time()
            plog(f"mpv started pid={self.proc.pid} geometry={width}x{height}+{x}+{y} files={[os.path.basename(f) for f in files]}")
            threading.Thread(target=self._focus_after_launch, daemon=True).start()
            self._ensure_watchdog()
            return True

    def _ensure_watchdog(self):
        """Every 15s: if mpv is supposed to be playing but the process died,
        relaunch it immediately instead of leaving a blank media area until
        the page's next 60s tick. Rapid deaths (<60s after launch) are NOT
        auto-respawned — that's a crash loop; the page's slower tick becomes
        the retry throttle and player.log records the reason."""
        if self._watchdog_started:
            return
        self._watchdog_started = True

        def watch():
            while True:
                time.sleep(15)
                with self.lock:
                    if not self.params or not self.proc:
                        continue
                    if self.proc.poll() is None:
                        alive = True
                    else:
                        alive = False
                if alive:
                    # Re-assert focus: a Chromium self-heal restart re-grabs
                    # focus, and its fullscreen layer would swallow the video.
                    self._assert_native_focus()
                    continue
                with self.lock:
                    if not self.params or not self.proc or self.proc.poll() is None:
                        continue  # re-check after re-acquiring the lock
                    code = self.proc.returncode
                    age = time.time() - self.launched_at
                    plog(f"mpv DIED exit={code} after {age:.0f}s (see mpv_last.log)")
                    x, y, w, h, files = self.params
                    self.proc = None
                    if age < 60:
                        plog("died too quickly — not respawning (crash loop guard); page tick will retry")
                        self.params = None
                        continue
                    respawn = (x, y, w, h, list(files))
                self.show(*respawn[:4], respawn[4])
                plog("mpv relaunched by watchdog")

        threading.Thread(target=watch, daemon=True).start()

    def stop(self):
        with self.lock:
            if self.proc and self.proc.poll() is None:
                plog("mpv stopped (hide requested)")
            self._kill_locked()

    def status(self):
        with self.lock:
            running = self.proc is not None and self.proc.poll() is None
            return {
                "running": running,
                "geometry": list(self.params[:4]) if (running and self.params) else None,
                "files": list(self.params[4]) if (running and self.params) else [],
                "mpv_available": shutil.which("mpv") is not None,
            }

    def _kill_locked(self):
        if self.proc and self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.proc.kill()
        self.proc = None
        self.params = None

    def kick_video_sync(self):
        """Files missing — run video_sync.sh in the background (throttled)."""
        now = time.time()
        if now - self.last_sync_kick < 300 or not os.path.isfile(VIDEO_SYNC):
            return
        self.last_sync_kick = now
        try:
            subprocess.Popen(["/bin/bash", VIDEO_SYNC],
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except OSError:
            pass


PLAYER = NativePlayer()


def local_files_for(video_ids):
    """Map playlist video ids to already-downloaded files, keeping order."""
    try:
        with open(os.path.join(VIDEOS_DIR, "video_map.json"), encoding="utf-8") as f:
            vmap = {item.get("id"): item for item in json.load(f)}
    except (OSError, ValueError):
        return []

    files = []
    for vid in video_ids:
        item = vmap.get(vid)
        if item and item.get("local") and item.get("file"):
            path = os.path.join(VIDEOS_DIR, item["file"])
            if os.path.isfile(path) and os.path.getsize(path) > 0:
                files.append(path)
    return files


class QMedRequestHandler(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header('Access-Control-Allow-Origin', '*')
        super().end_headers()

    def do_OPTIONS(self):
        # CORS preflight: the kiosk page lives on the QMed server's origin but
        # calls this local server with JSON POSTs — the browser asks permission
        # first. Without this handler every /player/* call fails silently.
        self.send_response(204)
        self.send_header('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
        self.send_header('Access-Control-Allow-Headers', 'Content-Type')
        self.send_header('Access-Control-Max-Age', '86400')
        self.end_headers()

    def _json(self, payload, status=200):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path.split("?")[0] == "/player/status":
            self._json(PLAYER.status())
            return
        super().do_GET()

    def do_POST(self):
        path = self.path.split("?")[0]

        if path == "/player/hide":
            PLAYER.stop()
            self._json({"ok": True})
            return

        if path == "/player/show":
            try:
                length = int(self.headers.get("Content-Length") or 0)
                req = json.loads(self.rfile.read(length) or b"{}")
                x, y = int(req["x"]), int(req["y"])
                width, height = int(req["width"]), int(req["height"])
                video_ids = list(req.get("video_ids") or [])
            except (KeyError, ValueError, TypeError):
                self._json({"ok": False, "reason": "bad request"}, status=400)
                return

            if width < 50 or height < 50:
                PLAYER.stop()
                self._json({"ok": False, "reason": "rect too small"})
                return

            files = local_files_for(video_ids)
            if not files:
                # Nothing downloaded yet — fetch in the background; the page
                # keeps its web player and will retry on its next tick.
                PLAYER.stop()
                PLAYER.kick_video_sync()
                self._json({"ok": False, "reason": "no local files yet"})
                return

            ok = PLAYER.show(x, y, width, height, files)
            self._json({
                "ok": ok,
                "playing": len(files) if ok else 0,
                "reason": None if ok else "mpv not installed",
            })
            return

        self.send_error(404, "Not Found")

    def log_message(self, format, *args):
        # Keep the log quiet; the launcher redirects stderr to a log file.
        pass


class ThreadingServer(socketserver.ThreadingMixIn, socketserver.TCPServer):
    allow_reuse_address = True
    daemon_threads = True


if __name__ == "__main__":
    # Serve from the videos dir regardless of the launcher's cwd —
    # start_local_server.sh used to cd here before launching, and the video
    # map / kiosk page rely on files being at the server root.
    os.makedirs(VIDEOS_DIR, exist_ok=True)
    os.chdir(VIDEOS_DIR)

    with ThreadingServer(("", PORT), QMedRequestHandler) as httpd:
        print(f"QMed local server (videos + config.json + native player) on port {PORT}")
        httpd.serve_forever()
