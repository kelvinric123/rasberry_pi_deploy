# QMed Raspberry Pi Queue Screen — v2.1

This directory contains the scripts needed to configure a fresh Raspberry Pi to run the QMed Queue Management Display.

## What's new in v2.1 (idle-reliability release)

Target problem: **calls + voice announcements occasionally failing after the screen sat idle for a while.** The fixes span these scripts AND the main Laravel app (the queue page itself always comes fresh from the server):

**In this folder:**

| File | Change |
|------|--------|
| `kiosk.sh` | Chromium no-throttling flags (`--disable-background-timer-throttling`, `--disable-backgrounding-occluded-windows`, `--disable-renderer-backgrounding`, `IntensiveWakeUpThrottling` off) so the page's timers never slow down when the mpv overlay occludes the browser. Single-instance `flock` guard. |
| `net_watchdog.sh` | Now also self-heals the processes announcements depend on: relaunches a dead `kiosk.sh` loop, restarts the local config/video server when port 8888 stops answering, and does one preventive Chromium restart per day at 04:00 (leaks can no longer accumulate for weeks). |
| `self_update.sh` | Reports the install outcome to the server (`POST /api/open/raspberry-pi/update-result`) **before** rebooting, and reboots the Pi after a successful install so every changed script — cron entries, kiosk loop, local server — comes back clean. Falls back to the old service-restart behaviour when passwordless sudo is not available. |
| `heartbeat.sh` | Passes the server's `reboot_after_update` decision through to `self_update.sh`. |

**In the main Laravel app (deployed with the server, no device update needed):**

* `raspi_display.blade.php` — the page every Pi loads:
  * **SSE staleness watchdog**: a Wi-Fi blip/NAT timeout can kill the stream *without* the browser noticing (EventSource stays "OPEN" forever, screen silently freezes). The page now force-reconnects after 150s without any stream activity. This was the #1 idle-failure cause.
  * **TTS queue stuck-guard**: a single stalled audio download used to jam `ttsProcessing` forever — every later call flashed but never sounded. Every announcement now has a hard completion timeout.
  * **Shared AudioContext** (the old per-call contexts leaked; Chromium caps them, silently killing the wake-up tone after a few calls) + a **near-silent keep-alive tick every 4 min** so idle HDMI TVs/amps don't drop the audio link and swallow the next announcement.
  * **TTS audio prefetch with retries** (blob playback) so a transient network blip retries instead of losing the announcement; chime has a stall timeout + local fallback.
* `sse_server/server.php` + in-app SSE: heartbeats are now real `event: ping` events (comments are invisible to JS), and pending per-device call events younger than 45s are **delivered** on connect instead of discarded — calls made during the 120s stream-recycle gap or a page reload are no longer lost.
* `QueueScreenEventService` stamps `created_at_ms` on call events; `TtsService` retries synthesis.

## Releasing to the fleet — "Sync from Git"

The scripts in this folder are the **source of truth for a public GitHub repo**. Releasing them no longer needs an SSH session on the server:

1. Run `update_raspi_deploy.bat` (in this folder) to publish it. It mirrors this folder into <https://github.com/kelvinric123/rasberry_pi_deploy> and prints the bundle version the fleet will land on. Add `/dry` to preview without pushing.
2. On <https://v2.qmed.asia/admin/raspberry-pi>, press **Sync** — the card should report the commit and version the .bat printed.
3. The server shallow-clones the repo into `storage/app/raspi_scripts`, checks the bundle is complete, and publishes it. From then on `/raspberry-pi/manifest.json` and `/raspberry-pi/{file}` serve the Git copy instead of the folder that shipped with the deploy.
4. Every self-updatable Pi is armed. On its next heartbeat (≤60s) it downloads the bundle, verifies every sha256, installs, **reports the result, and reboots**.
5. A Pi that is offline, unreachable or that fails keeps its pending flag and is offered the update again every `RASPI_UPDATE_RETRY_HOURS` (default **12h**) — repeatedly, until it reports the published version. Nothing has to be re-pressed for the stragglers.

The admin page shows the last sync (when, by whom, success/failure, commit) and a per-device rollout state: *Updating… / Retry in Xh / Update failed / Scripts up to date*.

Server `.env`:

```
RASPI_SCRIPTS_REPO_URL=https://github.com/your-org/raspi-scripts.git
RASPI_SCRIPTS_BRANCH=main
RASPI_SCRIPTS_SUBDIR=
RASPI_UPDATE_RETRY_HOURS=12
RASPI_REBOOT_AFTER_UPDATE=true
```

Safety properties worth knowing:

* The repo **must be public** — the clone runs with credential prompts disabled, so a private repo fails in seconds instead of hanging.
* A repo missing any of the 7 bundle files is **rejected before publishing**; the fleet keeps running the previous bundle and the run is recorded as failed.
* Leaving `RASPI_SCRIPTS_REPO_URL` empty keeps the old behaviour exactly: the bundle is served from `raspberry_pi/` in the deploy.
* The checkout lives under `storage/app/`, outside the app's own git tree, so it can never dirty the server checkout and block a normal deploy.
* `update_raspi_deploy.bat` refuses to publish a folder missing any of the 7 bundle files, and aborts if the mirror exceeds 20 MB — a scripts repo is ~100 KB, so anything larger means something got swept in that must not be public.
* The `.bat` and the two `.ps1` helpers are mirrored into the deploy repo as well. Devices never fetch them: `/raspberry-pi/{file}` only serves the allow-listed bundle.

**First rollout is special:** devices still run the *old* `self_update.sh`, which has no result reporting and no reboot. The first sync therefore installs correctly but restarts services rather than rebooting, and success shows up via the next heartbeat instead of the report endpoint. Every sync after that has the full behaviour.

## Deploying to the Raspberry Pi

The easiest way to move these files onto your Raspberry Pi is via `scp` (Secure Copy Protocol). You can run this directly from PowerShell or Command Prompt on your Windows machine:

```powershell
scp -r c:\laragon\www\qmed_appointment_4\qmed4.0\raspberry_pi qmed@192.168.0.10:~/Desktop/
```

> **Note:** Replace `192.168.0.10` with your Raspberry Pi's actual IP address, and `qmed` with your Raspberry Pi's login username.

## How It Works

This folder contains a multi-stage process that sets up the Pi securely and pairs it with the main QMed server. Here is what each script does:

### 1. `install.sh`
The first script to run. This acts as the **System Installer**. It must be run as `sudo` (e.g. `sudo bash install.sh`).
* Installs system dependencies (`chromium`, `unclutter`, `xdotool`, `jq`, `curl`, `iw`, `alsa-utils`).
* Disables screen blanking (so your Raspberry Pi monitor won't go to sleep after inactivity).
* **Disables Wi‑Fi power saving persistently** (via NetworkManager) — the single most common cause of a kiosk silently dropping off the network.
* Switches the display backend to X11/Openbox so the kiosk helper tools work.
* Sets up the `.qmed` configuration directory on the Pi.
* Installs the heartbeat script, which pings the main server to report the display's "online" status.

> **Target OS:** Raspberry Pi OS 64-bit (Bookworm / Trixie) with Desktop. It auto-detects the `chromium` vs `chromium-browser` binary. Older Debian releases (Buster and earlier) are not supported.

### 2. `setup.sh`
The second script to run. This is the **Interactive Configuration Wizard** (run normally, e.g. `bash setup.sh`).
* **Network Setup (Step 0):** detects the current Wi‑Fi connection and asks you to confirm/keep it, or lets you enter a new SSID/password (saved persistently so the Pi auto-reconnects). Optionally configures a **static IP**.
* It will ask for your QMed server URL to register the device.
* It queries the remote server to display available Hospitals and pre-configured Queue Screens, letting you pick which one this Pi will display.
* Guides you through deciding if video caching should be "Fully Cloud" (streams from server) or "Local Hybrid" (downloads videos locally to save bandwidth).
* It then sets up Chromium to automatically launch in a **self-healing Kiosk Mode** on boot (waits for the network first, relaunches automatically if it crashes).

### 3. `server.py` & `start_local_server.sh`
A small **local HTTP server** on port `8888` with two jobs:
* Serves locally cached CMS videos and `config.json` to the kiosk page with permissive CORS.
* **Native video playback (Layout G):** drives an `mpv` window (hardware decode) positioned *exactly* over the layout's media area. The kiosk page measures the area and calls `POST /player/show` with the rect + playlist; mpv then plays the locally downloaded files on top of Chromium instead of Chromium software-decoding them. Activates only when the screen's media type is **video** and a **playlist** is assigned, and only when the files are already downloaded — otherwise the page's own `<video>` keeps playing (graceful fallback). `POST /player/hide` stops it; `GET /player/status` shows what's playing.

Voice announcements ("pronounce") are server-generated TTS audio played by the page — nothing is synthesized on the Pi.

### 4. `video_sync.sh`
This script operates only if you chose **Local + Cloud Hybrid** during `setup.sh`.
* It routinely downloads and syncs uploaded videos directly to the `.qmed/videos/` directory from the CMS server. 
* It is automatically tied to a cronjob that loops every 30 minutes, allowing reliable video looping on weak or occasionally disconnected network setups.

---

### Basic First-Time Setup Instructions:

1. **Copy over the files** via SSH/SCP as mentioned above.
2. **Access the Pi shell**, enter the folder: `cd ~/Desktop/raspberry_pi`
3. **Run Install Phase:** `sudo bash install.sh`
4. **Run Setup Phase:** `bash setup.sh`
5. **Reboot:** `sudo reboot` (Your Pi will now automatically boot directly to the queue screen).

---

## Reliability & Network Persistence

The device is designed to run unattended and recover on its own:

| Feature | What it does |
|---------|--------------|
| **Wi‑Fi power‑save disabled** | Persistent NetworkManager setting (`/etc/NetworkManager/conf.d/99-qmed-wifi-powersave-off.conf`) plus a runtime `iw` toggle, so the Pi doesn't drop off Wi‑Fi when idle. |
| **Saved Wi‑Fi (auto‑reconnect)** | `setup.sh` saves the Wi‑Fi connection with `autoconnect` priority, so the Pi rejoins automatically after a reboot or power cut. |
| **Wait‑for‑network on boot** | The kiosk polls the server for up to ~2 minutes before loading, so it never shows a "can't reach site" error on a cold boot. |
| **Self‑healing kiosk** | Chromium runs in a restart loop (`~/.qmed/kiosk.sh`). If it crashes or is OOM‑killed, it relaunches within seconds. |
| **Network watchdog** | `~/.qmed/net_watchdog.sh` runs every minute: if the server is unreachable it reconnects Wi‑Fi, and once it's back it force‑reloads the screen. |
| **Heartbeat** | Reports online status / IP / Chromium state to the admin dashboard every 60s. |

**Logs on the Pi** (useful for debugging): `~/.qmed/kiosk.log`, `~/.qmed/net_watchdog.log`, `~/.qmed/video_server.log`.

> **Tip:** The self-heal loop and watchdog use `sudo -n` (non-interactive) for network commands. Raspberry Pi OS grants the default user passwordless sudo out of the box; if you changed that, those recovery steps will be skipped.
